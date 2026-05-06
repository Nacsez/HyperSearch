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
    providers = await request.app.state.provider_service.list_providers()
    default_provider = next((item for item in providers if item.get("is_default")), None)
    checks = {
        "searxng": searx,
        "default_provider": default_provider,
        "cache": {"ok": True, "detail": "available"},
    }
    ok = bool(searx.get("ok")) and bool(default_provider and default_provider.get("healthy"))
    if not ok:
        response.status_code = 503
    return {
        "status": "ready" if ok else "degraded",
        "service": "hypersearch",
        "environment": request.app.state.settings.environment,
        "checks": checks,
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
