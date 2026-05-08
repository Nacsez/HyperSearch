from __future__ import annotations

from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastapi import FastAPI

from .config import Settings
from .logging import configure_logging
from .metrics import MetricsRegistry
from .services.cache_service import CacheService
from .services.dedupe_service import DedupeService
from .services.extract_service import ExtractService
from .services.fetch_service import FetchService
from .services.provider_service import ProviderService
from .services.query_normalizer import QueryNormalizer
from .services.ranking_service import RankingService
from .services.research_service import ResearchService
from .services.search_service import SearchService
from .services.searx_client import SearxClient
from .services.synthesize_service import SynthesizeService
from .storage.sqlite import Database
from .tracing import setup_tracing


@dataclass(slots=True)
class ServiceContainer:
    settings: Settings
    database: Database
    metrics: MetricsRegistry
    cache: CacheService
    provider_service: ProviderService
    searx_client: SearxClient
    fetch_service: FetchService
    extract_service: ExtractService
    synthesize_service: SynthesizeService
    search_service: SearchService
    research_service: ResearchService


def build_lifespan():
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        settings = Settings.load()
        configure_logging(settings)
        setup_tracing(settings, app)

        database = Database(settings.sqlite_path)
        database.initialize()
        database.seed_app_setting(
            "llm_enabled",
            settings.llm_enabled,
            source=settings.llm_settings_source,
        )
        database.seed_app_setting(
            "llm_disabled_reason",
            settings.llm_disabled_reason,
            source=settings.llm_settings_source,
        )

        metrics = MetricsRegistry()
        cache = CacheService(settings)
        await cache.connect()

        searx_client = SearxClient(
            base_url=settings.searxng_url,
            default_timeout_ms=settings.request_timeout_ms,
        )
        fetch_service = FetchService(settings)
        extract_service = ExtractService()
        provider_service = ProviderService(settings, database)
        await provider_service.initialize()
        synthesize_service = SynthesizeService(provider_service)

        search_service = SearchService(
            settings=settings,
            database=database,
            cache=cache,
            normalizer=QueryNormalizer(),
            searx_client=searx_client,
            fetch_service=fetch_service,
            extract_service=extract_service,
            ranking_service=RankingService(),
            dedupe_service=DedupeService(),
            synthesize_service=synthesize_service,
        )
        research_service = ResearchService(
            settings=settings,
            database=database,
            cache=cache,
            search_service=search_service,
            synthesize_service=synthesize_service,
        )

        app.state.settings = settings
        app.state.database = database
        app.state.metrics = metrics
        app.state.cache = cache
        app.state.provider_service = provider_service
        app.state.searx_client = searx_client
        app.state.fetch_service = fetch_service
        app.state.extract_service = extract_service
        app.state.synthesize_service = synthesize_service
        app.state.search_service = search_service
        app.state.research_service = research_service
        app.state.container = ServiceContainer(
            settings=settings,
            database=database,
            metrics=metrics,
            cache=cache,
            provider_service=provider_service,
            searx_client=searx_client,
            fetch_service=fetch_service,
            extract_service=extract_service,
            synthesize_service=synthesize_service,
            search_service=search_service,
            research_service=research_service,
        )
        try:
            yield
        finally:
            await cache.close()
            await searx_client.close()
            await fetch_service.close()
            database.close()

    return lifespan
