from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json

from hypersearch_api.schemas.research import ResearchRequest
from hypersearch_api.schemas.search import SearchRequest


@dataclass(slots=True)
class NormalizedQuery:
    query: str
    engines: list[str]
    categories: list[str]
    language: str | None
    time_range: str | None
    page: int
    results_per_page: int
    max_pages: int
    target_result_count: int | None
    safe_search: int
    timeout_ms: int | None
    cache_policy: str

    def cache_key(self) -> str:
        payload = {
            "query": self.query,
            "engines": self.engines,
            "categories": self.categories,
            "language": self.language,
            "time_range": self.time_range,
            "page": self.page,
            "results_per_page": self.results_per_page,
            "max_pages": self.max_pages,
            "target_result_count": self.target_result_count,
            "safe_search": self.safe_search,
        }
        data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return sha256(data).hexdigest()


class QueryNormalizer:
    def normalize_search(self, request: SearchRequest) -> NormalizedQuery:
        return NormalizedQuery(
            query=" ".join(request.query.split()),
            engines=self._unique(request.engines),
            categories=self._unique(request.categories),
            language=request.language,
            time_range=request.time_range,
            page=request.page,
            results_per_page=request.results_per_page,
            max_pages=request.max_pages,
            target_result_count=request.target_result_count,
            safe_search=request.safe_search,
            timeout_ms=request.timeout_ms,
            cache_policy=request.cache_policy,
        )

    def normalize_research(self, request: ResearchRequest) -> NormalizedQuery:
        return NormalizedQuery(
            query=" ".join(request.query.split()),
            engines=self._unique(request.engines),
            categories=self._unique(request.categories),
            language=request.language,
            time_range=request.time_range,
            page=request.page,
            results_per_page=request.results_per_page,
            max_pages=request.max_pages,
            target_result_count=request.target_result_count,
            safe_search=1,
            timeout_ms=request.timeout_ms,
            cache_policy=request.cache_policy,
        )

    @staticmethod
    def _unique(items: list[str] | None) -> list[str]:
        if not items:
            return []
        seen: set[str] = set()
        result: list[str] = []
        for item in items:
            clean = item.strip()
            if not clean or clean in seen:
                continue
            seen.add(clean)
            result.append(clean)
        return result
