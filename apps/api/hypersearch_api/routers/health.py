from __future__ import annotations

from fastapi import APIRouter, Depends, Request, Response

from hypersearch_api.auth import require_access

router = APIRouter(tags=["health"])


@router.get("/v1/live")
async def live():
    return {"status": "ok", "service": "hypersearch"}


@router.get("/v1/ready", dependencies=[Depends(require_access)])
async def ready(request: Request, response: Response):
    searx = await request.app.state.searx_client.healthcheck()
    llm = await request.app.state.provider_service.llm_capability()
    cache_mode = "valkey" if getattr(request.app.state.cache, "_redis", None) is not None else "memory"
    search_ready = bool(searx.get("ok"))
    checks = {
        "searxng": searx,
        "cache": {"ok": True, "detail": "available", "mode": cache_mode},
    }
    if not search_ready:
        response.status_code = 503
    return {
        "status": "ready" if search_ready else "degraded",
        "service": "hypersearch",
        "environment": request.app.state.settings.environment,
        "checks": checks,
        "capabilities": {
            "search": {
                "enabled": True,
                "ready": search_ready,
                "mode": "search",
                "detail": searx.get("detail") or ("ready" if search_ready else "SearXNG unavailable"),
            },
            "llm": llm,
        },
    }


@router.get("/v1/health", dependencies=[Depends(require_access)])
async def health(request: Request):
    searx = await request.app.state.searx_client.healthcheck()
    providers = await request.app.state.provider_service.list_providers()
    return {
        "status": "ok" if searx.get("ok") else "degraded",
        "service": "hypersearch",
        "environment": request.app.state.settings.environment,
        "searxng": searx,
        "providers": providers,
    }


@router.get("/v1/metrics", dependencies=[Depends(require_access)])
async def metrics(request: Request):
    body = request.app.state.metrics.render_prometheus()
    return Response(content=body, media_type="text/plain; version=0.0.4")
