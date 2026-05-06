from __future__ import annotations

from pydantic import BaseModel, Field


class ProviderInfo(BaseModel):
    name: str
    display_name: str | None = None
    provider_type: str
    base_url: str | None = None
    model: str | None = None
    enabled: bool = True
    is_default: bool = False
    healthy: bool | None = None
    detail: str | None = None


class ProviderTestRequest(BaseModel):
    name: str = Field(min_length=1)


class ProviderTestResponse(BaseModel):
    ok: bool
    detail: str


class ProviderModelsResponse(BaseModel):
    provider: str
    base_url: str | None = None
    models: list[str]


class DefaultProviderRequest(BaseModel):
    name: str = Field(min_length=1)


class ProviderProfileUpdate(BaseModel):
    display_name: str = Field(min_length=1, max_length=80)
    provider_type: str = Field(default="openai-compatible", pattern="^openai-compatible$")
    base_url: str | None = Field(default=None, max_length=300)
    model: str | None = Field(default=None, max_length=200)
    enabled: bool = True
    is_default: bool = False
