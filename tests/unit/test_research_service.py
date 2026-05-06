from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from hypersearch_api.config import Settings
from hypersearch_api.services.research_service import ResearchService
from hypersearch_api.storage.sqlite import Database


class FakeSearchService:
    def __init__(self) -> None:
        self.hydrate_limit = None
        self.request = None

    async def execute(self, request, *, hydrate_limit=None):
        self.hydrate_limit = hydrate_limit
        self.request = request
        return {
            "request_id": "search",
            "query": request.query,
            "page": 1,
            "result_count": 3,
            "results": [
                {"title": "One", "url": "https://example.com/1", "content": "one"},
                {"title": "Two", "url": "https://example.com/2", "content": "two"},
                {"title": "Three", "url": "https://example.com/3", "content": "three"},
            ],
            "cache": {},
            "debug": {},
        }


class FakeProviderService:
    async def ensure_model_available(self, name=None):
        return {"provider": name or "lmstudio", "model": "local-model"}


class FakeSynthesizeService:
    def __init__(self) -> None:
        self.provider_service = FakeProviderService()

    async def synthesize_research(self, *, query, documents, provider_name=None):
        return {
            "answer": "answer",
            "citations": [
                {"index": index, "title": item["title"], "url": item["url"], "excerpt": item["content"]}
                for index, item in enumerate(documents, start=1)
            ],
            "provider": provider_name or "lmstudio",
            "model": "local-model",
        }


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


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        app_name="HyperSearch",
        environment="test",
        debug=False,
        debug_store_prompts=False,
        host="127.0.0.1",
        port=8000,
        allow_origins=[],
        log_level="INFO",
        sqlite_path=tmp_path / "test.db",
        searxng_url="http://127.0.0.1:8081",
        valkey_url=None,
        cache_ttl_search=120,
        cache_ttl_page=900,
        cache_ttl_extract=1800,
        cache_ttl_synthesis=600,
        provider_default="lmstudio",
        lmstudio_base_url="http://127.0.0.1:1234",
        lmstudio_model="local-model",
        vllm_base_url=None,
        vllm_model=None,
        llamacpp_base_url=None,
        llamacpp_model=None,
        fetch_timeout_ms=15000,
        provider_timeout_ms=45000,
        enable_playwright_fallback=False,
        otel_enabled=False,
        lan_enabled=False,
        pairing_token=None,
        fetch_user_agent="test",
        fetch_concurrency=4,
        request_timeout_ms=30000,
        max_query_length=500,
        max_results_per_page=50,
        max_pages=5,
        max_research_top_n=10,
        max_timeout_ms=120000,
    )


@pytest.mark.asyncio
async def test_research_limits_hydration_to_top_n(tmp_path):
    settings = _settings(tmp_path)
    database = Database(settings.sqlite_path)
    database.initialize()
    search = FakeSearchService()
    service = ResearchService(
        settings=settings,
        database=database,
        cache=MemoryCache(),
        search_service=search,
        synthesize_service=FakeSynthesizeService(),
    )
    request = SimpleNamespace(
        query="local research",
        engines=None,
        categories=None,
        language=None,
        time_range=None,
        page=1,
        results_per_page=10,
        max_pages=1,
        safe_search=2,
        top_n=2,
        timeout_ms=None,
        cache_policy="bypass",
        provider=None,
        streaming=False,
        include_debug_trace=False,
        model_dump=lambda mode="json": {"query": "local research"},
    )

    response = await service.execute(request)

    assert search.hydrate_limit == 2
    assert search.request.safe_search == 2
    assert len(response["citations"]) == 2
