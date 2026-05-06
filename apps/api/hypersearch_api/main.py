from __future__ import annotations

import logging
from time import perf_counter
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .config import Settings
from .exceptions import HyperSearchError
from .lifespan import build_lifespan
from .logging import clear_request_context, sanitize_mapping, set_request_context
from .routers import admin, health, history, providers, research, search

logger = logging.getLogger(__name__)

bootstrap_settings = Settings.load()
app = FastAPI(title="HyperSearch", version="1.0.0", lifespan=build_lifespan())
app.add_middleware(
    CORSMiddleware,
    allow_origins=bootstrap_settings.allow_origins or ["http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(HyperSearchError)
async def hypersearch_error_handler(request: Request, exc: HyperSearchError):
    request_id = request.headers.get("x-request-id")
    payload = exc.as_payload()
    if request_id:
        payload["request_id"] = request_id
    logger.warning(
        "handled_hypersearch_error",
        extra={
            "event_data": {
                "path": request.url.path,
                "status_code": exc.status_code,
                "error": exc.error_code,
                "detail": exc.message,
            }
        },
    )
    return JSONResponse(status_code=exc.status_code, content=payload)


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    start = perf_counter()
    request_id = request.headers.get("x-request-id", str(uuid4()))
    forwarded_for = request.headers.get("x-forwarded-for", "")
    client_host = (
        forwarded_for.split(",")[0].strip()
        if forwarded_for
        else (request.client.host if request.client else "unknown")
    )
    trace_id = request.headers.get("x-trace-id", request_id)
    set_request_context(request_id=request_id, trace_id=trace_id)
    try:
        response = await call_next(request)
    except Exception:
        logger.exception(
            "request_failed",
            extra={
                "event_data": sanitize_mapping(
                    {
                        "method": request.method,
                        "path": request.url.path,
                        "client_host": client_host,
                    }
                )
            },
        )
        clear_request_context()
        return JSONResponse(
            status_code=500,
            content={"detail": "Internal server error", "request_id": request_id},
        )
    elapsed = perf_counter() - start
    response.headers["X-Request-ID"] = request_id
    response.headers["X-Trace-ID"] = trace_id
    response.headers["X-Process-Time"] = f"{elapsed:.6f}"
    logger.info(
        "request_complete",
        extra={
            "event_data": {
                "method": request.method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_s": round(elapsed, 6),
                "client_host": client_host,
            }
        },
    )
    try:
        metrics = getattr(request.app.state, "metrics", None)
        if metrics is not None:
            metrics.increment(
                "hypersearch_http_requests_total",
                method=request.method,
                path=request.url.path,
                status=str(response.status_code),
            )
            metrics.observe(
                "hypersearch_http_request_seconds",
                elapsed,
                method=request.method,
                path=request.url.path,
            )
    finally:
        clear_request_context()
    return response


@app.get("/")
async def root() -> dict[str, str]:
    return {"service": "hypersearch", "status": "ok"}


app.include_router(search.router)
app.include_router(research.router)
app.include_router(providers.router)
app.include_router(admin.router)
app.include_router(history.router)
app.include_router(health.router)
