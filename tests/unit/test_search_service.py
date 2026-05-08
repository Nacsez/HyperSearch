from types import SimpleNamespace

import pytest

from hypersearch_api.schemas.search import SearchRequest
from hypersearch_api.services.dedupe_service import DedupeService
from hypersearch_api.services.query_normalizer import QueryNormalizer
from hypersearch_api.services.ranking_service import RankingService
from hypersearch_api.services.search_service import SearchService


class MemoryCache:
    def __init__(self) -> None:
        self.values = {}

    def make_key(self, namespace, payload):
        return f"{namespace}:{len(str(payload))}"

    async def get_json(self, key):
        return self.values.get(key)

    async def set_json(self, key, value, ttl_seconds):
        self.values[key] = value

    async def coalesce(self, *, key, loader, ttl_seconds):
        if key not in self.values:
            self.values[key] = await loader()
        return self.values[key]


class FakeDatabase:
    def __init__(self) -> None:
        self.history = []

    def write_history(self, **payload):
        self.history.append(payload)


class FakeSearxClient:
    def __init__(self) -> None:
        self.calls = []

    async def search(self, *, page, results_per_page, **kwargs):
        self.calls.append({"page": page, "results_per_page": results_per_page})
        return {
            "results": [
                {
                    "title": f"Result {page}-{index}",
                    "url": f"https://example.com/{page}/{index}",
                    "engine": "test",
                    "score": float(1000 - ((page - 1) * results_per_page + index)),
                    "content": f"snippet {page}-{index}",
                }
                for index in range(1, results_per_page + 1)
            ]
        }


def _service(searx_client: FakeSearxClient, database: FakeDatabase) -> SearchService:
    return SearchService(
        settings=SimpleNamespace(
            cache_ttl_search=120,
            cache_ttl_page=120,
            cache_ttl_extract=120,
            cache_ttl_synthesis=120,
            debug=False,
            max_results_per_page=50,
            max_pages=5,
        ),
        database=database,
        cache=MemoryCache(),
        normalizer=QueryNormalizer(),
        searx_client=searx_client,
        fetch_service=SimpleNamespace(),
        extract_service=SimpleNamespace(),
        ranking_service=RankingService(),
        dedupe_service=DedupeService(),
        synthesize_service=SimpleNamespace(),
    )


@pytest.mark.asyncio
async def test_search_collects_explicit_target_across_extra_pages():
    searx_client = FakeSearxClient()
    database = FakeDatabase()
    service = _service(searx_client, database)
    request = SearchRequest(
        query="long collection",
        page=1,
        results_per_page=30,
        max_pages=1,
        target_result_count=30,
        safe_search=1,
        dedupe=True,
        fetch_pages=False,
        extract_text=False,
        summarize=False,
        streaming=False,
        cache_policy="bypass",
    )

    response = await service.execute(request)

    assert response["result_count"] == 30
    assert [call["page"] for call in searx_client.calls] == [1, 2, 3]
    assert {call["results_per_page"] for call in searx_client.calls} == {10}
    assert response["debug"]["target_result_count"] == 30
    assert response["debug"]["result_shortfall"] == 0
    assert database.history
