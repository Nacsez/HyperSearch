from __future__ import annotations

import logging
from fastapi import FastAPI

from .config import Settings

logger = logging.getLogger(__name__)


def setup_tracing(settings: Settings, app: FastAPI | None = None) -> None:
    if not settings.otel_enabled:
        return
    try:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor  # type: ignore
        from opentelemetry.sdk.resources import Resource  # type: ignore
        from opentelemetry.sdk.trace import TracerProvider  # type: ignore
        from opentelemetry.sdk.trace.export import BatchSpanProcessor  # type: ignore
        from opentelemetry.sdk.trace.export import ConsoleSpanExporter  # type: ignore
        from opentelemetry import trace  # type: ignore
    except ImportError:
        logger.warning(
            "OpenTelemetry requested but dependencies are not installed",
            extra={"event_data": {"component": "tracing"}},
        )
        return

    resource = Resource.create({"service.name": "hypersearch-api"})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    if app is not None:
        FastAPIInstrumentor.instrument_app(app)
