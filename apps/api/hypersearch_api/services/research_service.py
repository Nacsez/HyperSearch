from __future__ import annotations

import asyncio
from typing import Any
from uuid import uuid4

from hypersearch_api.config import Settings
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
        search_request = SearchRequest(
            query=request.query,
            engines=request.engines,
            categories=request.categories,
            language=request.language,
            time_range=request.time_range,
            page=request.page,
            results_per_page=request.results_per_page,
            max_pages=request.max_pages,
            safe_search=request.safe_search,
            fetch_pages=True,
            extract_text=True,
            summarize=False,
            timeout_ms=request.timeout_ms,
            cache_policy=request.cache_policy,
        )
        await self.synthesize_service.provider_service.ensure_model_available(
            request.provider
        )
        search_payload = await self.search_service.execute(
            search_request,
            hydrate_limit=request.top_n,
        )
        documents = [
            item
            for item in search_payload["results"]
            if item.get("content") or item.get("snippet")
        ][: request.top_n]
        synthesis_key = self.cache.make_key(
            "research",
            {
                "query": request.query,
                "provider": request.provider,
                "documents": [
                    {
                        "url": item.get("url"),
                        "content": (item.get("content") or item.get("snippet") or "")[:1000],
                    }
                    for item in documents
                ],
            },
        )
        synthesis_work_key = self.cache.make_key(
            "synthesis",
            {
                "mode": "research",
                "query": request.query,
                "provider": request.provider,
                "urls": [item.get("url") for item in documents],
            },
        )
        if request.cache_policy in {"use", "only-if-cached"}:
            cached = await self.cache.get_json(synthesis_key)
            if cached is not None:
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
        if request.cache_policy == "use":
            synthesis = await self.cache.coalesce(
                key=synthesis_work_key,
                loader=lambda: self.synthesize_service.synthesize_research(
                    query=request.query,
                    documents=documents,
                    provider_name=request.provider,
                ),
                ttl_seconds=self.settings.cache_ttl_synthesis,
            )
        else:
            synthesis = await self.synthesize_service.synthesize_research(
                query=request.query,
                documents=documents,
                provider_name=request.provider,
            )
        payload = {
            "request_id": request_id,
            "query": request.query,
            "answer": synthesis["answer"],
            "citations": synthesis["citations"],
            "trace": {
                "provider": synthesis.get("provider"),
                "model": synthesis.get("model"),
                "document_count": len(documents),
                "research_steps": synthesis.get("research_steps"),
                "provider_error": synthesis.get("error"),
            },
            "raw_search": search_payload if request.include_debug_trace else None,
        }
        if request.cache_policy in {"use", "refresh"}:
            await self.cache.set_json(
                synthesis_key,
                payload,
                self.settings.cache_ttl_synthesis,
            )
        await asyncio.to_thread(
            self.database.write_history,
            kind="research",
            query=request.query,
            request_payload=request.model_dump(mode="json"),
            response_payload=payload,
            debug_payload=payload["trace"] if self.settings.debug else None,
        )
        return payload
