from __future__ import annotations

import asyncio
import httpx
from math import ceil
from typing import Any
from uuid import uuid4

from hypersearch_api.config import Settings
from hypersearch_api.exceptions import UpstreamServiceError
from hypersearch_api.storage.sqlite import Database

from .cache_service import CacheService
from .dedupe_service import DedupeService
from .extract_service import ExtractService
from .fetch_service import FetchService
from .query_normalizer import QueryNormalizer
from .ranking_service import RankingService
from .searx_client import SearxClient
from .synthesize_service import SynthesizeService


class SearchService:
    def __init__(
        self,
        *,
        settings: Settings,
        database: Database,
        cache: CacheService,
        normalizer: QueryNormalizer,
        searx_client: SearxClient,
        fetch_service: FetchService,
        extract_service: ExtractService,
        ranking_service: RankingService,
        dedupe_service: DedupeService,
        synthesize_service: SynthesizeService,
    ) -> None:
        self.settings = settings
        self.database = database
        self.cache = cache
        self.normalizer = normalizer
        self.searx_client = searx_client
        self.fetch_service = fetch_service
        self.extract_service = extract_service
        self.ranking_service = ranking_service
        self.dedupe_service = dedupe_service
        self.synthesize_service = synthesize_service

    async def execute(self, request, *, hydrate_limit: int | None = None) -> dict[str, Any]:
        request_id = str(uuid4())
        normalized = self.normalizer.normalize_search(request)
        search_cache_key = self.cache.make_key(
            "search",
            {
                "normalized_key": normalized.cache_key(),
                "target_result_count": self._target_result_count(request, normalized),
                "fetch_pages": request.fetch_pages,
                "extract_text": request.extract_text,
                "dedupe": request.dedupe,
                "summarize": request.summarize,
                "hydrate_limit": hydrate_limit,
            },
        )
        if request.cache_policy in {"use", "only-if-cached"}:
            cached = await self.cache.get_json(search_cache_key)
            if cached is not None:
                cached["cache"] = {**cached.get("cache", {}), "search": "hit"}
                return cached
            if request.cache_policy == "only-if-cached":
                return {
                    "request_id": request_id,
                    "query": request.query,
                    "page": request.page,
                    "result_count": 0,
                    "results": [],
                    "summary": None,
                    "cache": {"search": "miss"},
                    "debug": {"message": "cache miss"},
                }
        if request.cache_policy == "use":
            return await self.cache.coalesce(
                key=search_cache_key,
                loader=lambda: self._execute_uncached(
                    request,
                    request_id=request_id,
                    normalized=normalized,
                    hydrate_limit=hydrate_limit,
                    search_cache_state="miss",
                    should_write_history=True,
                ),
                ttl_seconds=self.settings.cache_ttl_search,
            )

        payload = await self._execute_uncached(
            request,
            request_id=request_id,
            normalized=normalized,
            hydrate_limit=hydrate_limit,
            search_cache_state="miss",
            should_write_history=True,
        )
        if request.cache_policy == "refresh":
            await self.cache.set_json(
                search_cache_key,
                payload,
                self.settings.cache_ttl_search,
            )
        return payload

    async def _execute_uncached(
        self,
        request,
        *,
        request_id: str,
        normalized,
        hydrate_limit: int | None,
        search_cache_state: str,
        should_write_history: bool,
    ) -> dict[str, Any]:
        collection_plan = self._collection_plan(request, normalized)
        pages = range(
            normalized.page,
            normalized.page + collection_plan["page_budget"],
        )
        results: list[dict[str, Any]] = []
        raw_pages: list[dict[str, Any]] = []
        pages_attempted: list[int] = []
        for page in pages:
            pages_attempted.append(page)
            try:
                body = await self.searx_client.search(
                    query=normalized.query,
                    engines=normalized.engines,
                    categories=normalized.categories,
                    language=normalized.language,
                    time_range=normalized.time_range,
                    page=page,
                    results_per_page=collection_plan["searx_results_per_page"],
                    safe_search=normalized.safe_search,
                    timeout_ms=normalized.timeout_ms,
                )
            except httpx.HTTPStatusError as exc:
                raise UpstreamServiceError(
                    "SearXNG returned an error while searching",
                    details={
                        "service": "searxng",
                        "status_code": exc.response.status_code,
                        "url": str(exc.request.url),
                    },
                ) from exc
            except httpx.HTTPError as exc:
                raise UpstreamServiceError(
                    "SearXNG is unavailable",
                    details={"service": "searxng", "reason": str(exc)},
                ) from exc
            raw_pages.append(body)
            for index, item in enumerate(body.get("results", []), start=1):
                results.append(
                    {
                        "title": item.get("title") or item.get("url"),
                        "url": item.get("url"),
                        "engine": item.get("engine"),
                        "score": item.get("score"),
                        "snippet": item.get("content") or item.get("snippet"),
                        "published_date": item.get("publishedDate"),
                        "position": index,
                        "metadata": {
                            "engines": item.get("engines") or [],
                            "category": item.get("category"),
                        },
                        "fetched": False,
                        "extracted": False,
                    }
                )
            if request.dedupe:
                if len(self.dedupe_service.dedupe(results)) >= collection_plan["target_result_count"]:
                    break
            elif len(results) >= collection_plan["target_result_count"]:
                break
        if request.dedupe:
            results = self.dedupe_service.dedupe(results)
        results = self.ranking_service.rank(results)
        result_shortfall = max(0, collection_plan["target_result_count"] - len(results))
        results = results[: collection_plan["target_result_count"]]
        if request.fetch_pages or request.extract_text:
            results = await self._hydrate_results(
                results,
                request=request,
                limit=hydrate_limit,
            )

        summary = None
        summary_cache_state = "not-requested"
        if request.summarize:
            summary_key = self.cache.make_key(
                "synthesis",
                {"query": request.query, "urls": [item.get("url") for item in results]},
            )
            if request.cache_policy in {"use", "only-if-cached"}:
                cached_summary = await self.cache.get_json(summary_key)
                if cached_summary is not None:
                    summary = cached_summary.get("summary")
                    summary_cache_state = "hit"
            if summary is None and request.cache_policy != "only-if-cached":
                if request.cache_policy == "use":
                    synthesized = await self.cache.coalesce(
                        key=summary_key,
                        loader=lambda: self.synthesize_service.summarize_search(
                            query=request.query,
                            results=results,
                        ),
                        ttl_seconds=self.settings.cache_ttl_synthesis,
                    )
                else:
                    synthesized = await self.synthesize_service.summarize_search(
                        query=request.query,
                        results=results,
                    )
                summary = synthesized.get("summary")
                if request.cache_policy == "refresh":
                    await self.cache.set_json(
                        summary_key,
                        {"summary": summary, "meta": synthesized},
                        self.settings.cache_ttl_synthesis,
                    )
                summary_cache_state = "stored"

        payload = {
            "request_id": request_id,
            "query": request.query,
            "page": request.page,
            "result_count": len(results),
            "results": results,
            "summary": summary,
            "cache": {
                "search": search_cache_state,
                "summary": summary_cache_state,
            },
            "debug": {
                "pages_fetched": len(raw_pages),
                "pages_attempted": pages_attempted,
                "target_result_count": collection_plan["target_result_count"],
                "searx_results_per_page": collection_plan["searx_results_per_page"],
                "page_budget": collection_plan["page_budget"],
                "result_shortfall": result_shortfall,
                "searx_pages": raw_pages,
            },
        }
        if should_write_history:
            await asyncio.to_thread(
                self.database.write_history,
                kind="search",
                query=request.query,
                request_payload=request.model_dump(mode="json"),
                response_payload=payload,
                debug_payload=payload["debug"] if self.settings.debug else None,
            )
        return payload

    def _target_result_count(self, request, normalized) -> int:
        configured_cap = max(1, self.settings.max_results_per_page * self.settings.max_pages)
        requested = getattr(request, "target_result_count", None)
        if requested is None:
            requested = normalized.results_per_page * normalized.max_pages
        return min(configured_cap, max(1, int(requested)))

    def _collection_plan(self, request, normalized) -> dict[str, int]:
        target_result_count = self._target_result_count(request, normalized)
        if target_result_count <= self.settings.max_results_per_page:
            searx_results_per_page = min(10, target_result_count)
        else:
            searx_results_per_page = min(
                self.settings.max_results_per_page,
                target_result_count,
            )
        searx_results_per_page = max(1, searx_results_per_page)
        page_budget = max(
            normalized.max_pages,
            ceil(target_result_count / searx_results_per_page),
        )
        if request.dedupe and page_budget < self.settings.max_pages:
            page_budget += 1
        page_budget = min(self.settings.max_pages, max(1, page_budget))
        return {
            "target_result_count": target_result_count,
            "searx_results_per_page": searx_results_per_page,
            "page_budget": page_budget,
        }

    async def _hydrate_results(
        self,
        results: list[dict[str, Any]],
        *,
        request,
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        hydration_count = min(limit or len(results), len(results))
        to_hydrate = results[:hydration_count]
        untouched = results[hydration_count:]

        async def hydrate(result: dict[str, Any]) -> dict[str, Any]:
            page_key = self.cache.make_key("page", {"url": result["url"]})
            extract_key = self.cache.make_key("extract", {"url": result["url"]})
            page_body = None
            if request.cache_policy in {"use", "only-if-cached"}:
                page_body = await self.cache.get_json(page_key)
            if page_body is None and request.cache_policy != "only-if-cached":
                async def load_page() -> dict[str, Any]:
                    fetched = await self.fetch_service.fetch(
                        result["url"],
                        timeout_ms=request.timeout_ms,
                    )
                    return {
                        "text": fetched.text,
                        "status_code": fetched.status_code,
                        "content_type": fetched.content_type,
                        "used_playwright": fetched.used_playwright,
                        "error": fetched.error,
                    }

                if request.cache_policy == "use":
                    page_body = await self.cache.coalesce(
                        key=page_key,
                        loader=load_page,
                        ttl_seconds=self.settings.cache_ttl_page,
                    )
                else:
                    page_body = await load_page()
                    if request.cache_policy == "refresh":
                        await self.cache.set_json(
                            page_key,
                            page_body,
                            self.settings.cache_ttl_page,
                        )
            if page_body:
                result["fetched"] = True
                result["metadata"]["fetch"] = {
                    "status_code": page_body.get("status_code"),
                    "used_playwright": page_body.get("used_playwright"),
                    "error": page_body.get("error"),
                }
            if request.extract_text and page_body and page_body.get("text"):
                extracted = None
                if request.cache_policy in {"use", "only-if-cached"}:
                    extracted = await self.cache.get_json(extract_key)
                if extracted is None and request.cache_policy != "only-if-cached":
                    async def load_extract() -> dict[str, Any]:
                        extract_result = await self.extract_service.extract(
                            page_body["text"],
                            url=result["url"],
                        )
                        return {
                            "title": extract_result.title,
                            "content": extract_result.text,
                            "excerpt": extract_result.excerpt,
                            "metadata": extract_result.metadata,
                        }

                    if request.cache_policy == "use":
                        extracted = await self.cache.coalesce(
                            key=extract_key,
                            loader=load_extract,
                            ttl_seconds=self.settings.cache_ttl_extract,
                        )
                    else:
                        extracted = await load_extract()
                        if request.cache_policy == "refresh":
                            await self.cache.set_json(
                                extract_key,
                                extracted,
                                self.settings.cache_ttl_extract,
                            )
                if extracted:
                    result["extracted"] = True
                    result["content"] = extracted.get("content")
                    result["metadata"]["extract"] = extracted.get("metadata", {})
            return result

        hydrated = await asyncio.gather(*(hydrate(item) for item in to_hydrate))
        return list(hydrated) + untouched
