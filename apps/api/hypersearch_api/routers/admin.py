from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from hypersearch_api.auth import require_access, require_local_access

router = APIRouter(prefix="/v1/admin", tags=["admin"])


class CacheInvalidateRequest(BaseModel):
    namespace: str


class LlmSettingsUpdate(BaseModel):
    enabled: bool
    reason: str | None = None


@router.post("/cache/invalidate", dependencies=[Depends(require_access)])
async def invalidate_cache(body: CacheInvalidateRequest, request: Request):
    deleted = await request.app.state.cache.invalidate_namespace(body.namespace)
    return {"status": "ok", "deleted": deleted}


@router.post("/maintenance/vacuum", dependencies=[Depends(require_access)])
async def vacuum(request: Request):
    await asyncio.to_thread(request.app.state.database.vacuum)
    return {"status": "ok"}


@router.get("/llm", dependencies=[Depends(require_local_access)])
async def get_llm_settings(request: Request):
    return request.app.state.provider_service.get_llm_settings()


@router.patch("/llm", dependencies=[Depends(require_local_access)])
async def update_llm_settings(body: LlmSettingsUpdate, request: Request):
    return request.app.state.provider_service.set_llm_settings(
        enabled=body.enabled,
        reason=body.reason,
    )
