from __future__ import annotations

import asyncio
import time
from typing import Any
from uuid import uuid4

from hypersearch_api.config import Settings
from hypersearch_api.exceptions import ProviderModelUnavailableError, ProviderUnavailableError
from hypersearch_api.storage.sqlite import Database
from hypersearch_api.schemas.search import SearchRequest

from .cache_service import CacheService
from .search_service import SearchService
from .synthesize_service import SynthesizeService


class ResearchService:
    def __init__(
        self,
        *,
        settings: Settings,
        database: Database,
        cache: CacheService,
        search_service: SearchService,
        synthesize_service: SynthesizeService,
    ) -> None:
        self.settings = settings
        self.database = database
        self.cache = cache
        self.search_service = search_service
        self.synthesize_service = synthesize_service

    async def execute(self, request) -> dict[str, Any]:
        request_id = str(uuid4())
        search_budget_ms = min(
            (request.timeout_ms or self.settings.request_timeout_ms),
            self.settings.max_timeout_ms,
        )
        search_deadline = time.monotonic() + (search_budget_ms / 1000)

        def remaining_search_seconds() -> float:
            return max(0.1, search_deadline - time.monotonic())

        target_result_count = max(
            request.top_n,
            request.target_result_count
            or request.results_per_page * request.max_pages,
        )
        search_request = SearchRequest(
            query=request.query,
            engines=request.engines,
            categories=request.categories,
            language=request.language,
            time_range=request.time_range,
            page=request.page,
            results_per_page=request.results_per_page,
            max_pages=request.max_pages,
            target_result_count=target_result_count,
            safe_search=request.safe_search,
            fetch_pages=True,
            extract_text=True,
            summarize=False,
            timeout_ms=request.timeout_ms,
            cache_policy=request.cache_policy,
        )
        try:
            search_payload = await asyncio.wait_for(
                self.search_service.execute(
                    search_request,
                    hydrate_limit=request.top_n,
                ),
                timeout=remaining_search_seconds(),
            )
        except TimeoutError:
            payload = self._source_review_payload(
                request_id=request_id,
                request=request,
                search_payload={
                    "request_id": request_id,
                    "query": request.query,
                    "page": request.page,
                    "result_count": 0,
                    "results": [],
                    "summary": None,
                    "cache": {"search": "timeout"},
                    "debug": {
                        "timeout_ms": request.timeout_ms,
                        "target_result_count": target_result_count,
                    },
                },
                documents=[],
                reason=f"Research search exceeded the search collection budget of {search_budget_ms} ms",
                extra_trace={
                    "deadline_exceeded": True,
                    "requested_source_count": request.top_n,
                    "source_shortfall": request.top_n,
                    "search_target_result_count": target_result_count,
                    "search_result_count": 0,
                    "search_budget_ms": search_budget_ms,
                },
            )
            await self._write_history(request, payload)
            return payload
        documents = [
            item
            for item in search_payload["results"]
            if item.get("content") or item.get("snippet")
        ][: request.top_n]
        collection_trace = {
            "requested_source_count": request.top_n,
            "source_shortfall": max(0, request.top_n - len(documents)),
            "search_target_result_count": target_result_count,
            "search_result_count": search_payload.get("result_count", len(search_payload.get("results", []))),
            "search_budget_ms": search_budget_ms,
        }
        llm_ready = False
        provider_readiness: dict[str, Any] | None = None
        fallback_reason: str | None = None
        if not self.synthesize_service.provider_service.is_llm_enabled():
            state = self.synthesize_service.provider_service.get_llm_settings()
            fallback_reason = state.get("reason") or "LLM features are disabled"
        else:
            try:
                provider_readiness_timeout = max(5.0, self.settings.provider_timeout_ms / 1000)
                provider_readiness = await asyncio.wait_for(
                    self.synthesize_service.provider_service.ensure_model_available(
                        request.provider
                    ),
                    timeout=provider_readiness_timeout,
                )
                llm_ready = True
            except (ProviderUnavailableError, ProviderModelUnavailableError) as exc:
                fallback_reason = exc.message
                provider_readiness = exc.details
            except TimeoutError:
                fallback_reason = f"Provider readiness did not complete within {self.settings.provider_timeout_ms} ms"
                provider_readiness = {"deadline_exceeded": True}
        if not llm_ready:
            payload = self._source_review_payload(
                request_id=request_id,
                request=request,
                search_payload=search_payload,
                documents=documents,
                reason=fallback_reason or "LLM synthesis unavailable",
                extra_trace={
                    **collection_trace,
                    "provider_readiness": provider_readiness,
                },
            )
            await self._write_history(request, payload)
            return payload
        synthesis_key = self.cache.make_key(
            "research",
            {
                "pipeline_version": 2,
                "query": request.query,
                "provider": request.provider,
                "timeout_ms": request.timeout_ms,
                "documents": [
                    {
                        "url": item.get("url"),
                        "content": (item.get("content") or item.get("snippet") or "")[:1000],
                    }
                    for item in documents
                ],
            },
        )
        if request.cache_policy in {"use", "only-if-cached"}:
            cached = await self.cache.get_json(synthesis_key)
            if cached is not None:
                cached_trace = cached.get("trace") if isinstance(cached.get("trace"), dict) else {}
                cached_error = cached_trace.get("provider_error")
                if not cached_error:
                    return cached
            if request.cache_policy == "only-if-cached":
                return {
                    "request_id": request_id,
                    "query": request.query,
                    "answer": "",
                    "citations": [],
                    "trace": {"message": "cache miss"},
                    "raw_search": None,
                }
        try:
            synthesis = await self.synthesize_service.synthesize_research(
                query=request.query,
                documents=documents,
                provider_name=request.provider,
                timeout_ms=request.timeout_ms,
            )
        except TimeoutError:
            synthesis = self.synthesize_service.build_source_review(
                query=request.query,
                documents=documents,
                reason="LLM synthesis timed out inside the provider call budget",
            )
        payload = {
            "request_id": request_id,
            "query": request.query,
            "answer": synthesis["answer"],
            "citations": synthesis["citations"],
            "trace": {
                "mode": (
                    "search-only-fallback"
                    if synthesis.get("provider") == "search-only"
                    else "llm-synthesis"
                ),
                "provider": synthesis.get("provider"),
                "model": synthesis.get("model"),
                "document_count": len(documents),
                "research_steps": synthesis.get("research_steps"),
                "provider_error": synthesis.get("error"),
                "provider_readiness": provider_readiness,
                "synthesis_budget_policy": "provider-call-timeouts",
                **collection_trace,
            },
            "raw_search": search_payload if request.include_debug_trace else None,
        }
        if request.cache_policy in {"use", "refresh"} and not synthesis.get("error"):
            await self.cache.set_json(
                synthesis_key,
                payload,
                self.settings.cache_ttl_synthesis,
            )
        await self._write_history(request, payload)
        return payload

    def _source_review_payload(
        self,
        *,
        request_id: str,
        request,
        search_payload: dict[str, Any],
        documents: list[dict[str, Any]],
        reason: str,
        extra_trace: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        synthesis = self.synthesize_service.build_source_review(
            query=request.query,
            documents=documents,
            reason=reason,
        )
        return {
            "request_id": request_id,
            "query": request.query,
            "answer": synthesis["answer"],
            "citations": synthesis["citations"],
            "trace": {
                "mode": "search-only-fallback",
                "provider": synthesis.get("provider"),
                "model": synthesis.get("model"),
                "document_count": len(documents),
                "research_steps": synthesis.get("research_steps"),
                "provider_error": synthesis.get("error"),
                **(extra_trace or {}),
            },
            "raw_search": search_payload if request.include_debug_trace else None,
        }

    async def _write_history(self, request, payload: dict[str, Any]) -> None:
        await asyncio.to_thread(
            self.database.write_history,
            kind="research",
            query=request.query,
            request_payload=request.model_dump(mode="json"),
            response_payload=payload,
            debug_payload=payload["trace"] if self.settings.debug else None,
        )
