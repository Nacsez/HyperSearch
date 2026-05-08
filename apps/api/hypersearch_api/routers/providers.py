from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from hypersearch_api.auth import require_access
from hypersearch_api.schemas.provider import (
    DefaultProviderRequest,
    ProviderDraftSettings,
    ProviderInfo,
    ProviderModelsResponse,
    ProviderProfileUpdate,
    ProviderTestRequest,
    ProviderTestResponse,
)

router = APIRouter(prefix="/v1/providers", tags=["providers"])


@router.get("", response_model=list[ProviderInfo], dependencies=[Depends(require_access)])
async def list_providers(request: Request):
    return await request.app.state.provider_service.list_providers()


@router.post("/test", response_model=ProviderTestResponse, dependencies=[Depends(require_access)])
async def test_provider(body: ProviderTestRequest, request: Request):
    payload = await request.app.state.provider_service.test_provider(
        name=body.name,
        base_url=body.base_url,
        model=body.model,
        enabled=body.enabled,
    )
    return ProviderTestResponse(**payload)


@router.post("/models", response_model=ProviderModelsResponse, dependencies=[Depends(require_access)])
async def list_draft_provider_models(body: ProviderTestRequest, request: Request):
    return await request.app.state.provider_service.list_draft_provider_models(
        name=body.name,
        base_url=body.base_url,
        model=body.model,
        enabled=True if body.enabled is None else body.enabled,
    )


@router.get("/{name}/models", response_model=ProviderModelsResponse, dependencies=[Depends(require_access)])
async def list_provider_models(name: str, request: Request):
    return await request.app.state.provider_service.list_provider_models(name)


@router.post("/default", dependencies=[Depends(require_access)])
async def set_default_provider(body: DefaultProviderRequest, request: Request):
    await request.app.state.provider_service.set_default_provider(body.name)
    return {"status": "ok", "default_provider": body.name}


@router.patch("/{name}", response_model=ProviderInfo, dependencies=[Depends(require_access)])
async def update_provider(name: str, body: ProviderProfileUpdate, request: Request):
    return await request.app.state.provider_service.update_provider_profile(
        name=name,
        display_name=body.display_name,
        provider_type=body.provider_type,
        base_url=body.base_url,
        model=body.model,
        enabled=body.enabled,
        is_default=body.is_default,
    )


@router.post("/{name}/verify-model", dependencies=[Depends(require_access)])
async def verify_provider_model(
    name: str,
    request: Request,
    body: ProviderDraftSettings | None = None,
):
    if body is None:
        return await request.app.state.provider_service.verify_model_available(name)
    return await request.app.state.provider_service.verify_model_available(
        name=name,
        base_url=body.base_url,
        model=body.model,
        enabled=body.enabled,
    )
