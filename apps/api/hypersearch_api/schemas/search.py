from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

CachePolicy = Literal["use", "bypass", "refresh", "only-if-cached"]


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=500)
    engines: list[str] | None = Field(default=None, max_length=20)
    categories: list[str] | None = Field(default=None, max_length=20)
    language: str | None = None
    time_range: str | None = None
    page: int = Field(default=1, ge=1, le=20)
    results_per_page: int = Field(default=10, ge=1, le=50)
    max_pages: int = Field(default=1, ge=1, le=5)
    safe_search: int = Field(default=1, ge=0, le=2)
    dedupe: bool = True
    fetch_pages: bool = False
    extract_text: bool = False
    summarize: bool = False
    streaming: bool = False
    timeout_ms: int | None = Field(default=None, ge=1000, le=120000)
    cache_policy: CachePolicy = "use"

    @field_validator("page", "results_per_page", "max_pages")
    @classmethod
    def validate_positive(cls, value: int) -> int:
        if value < 1:
            raise ValueError("must be >= 1")
        return value


class SearchResult(BaseModel):
    title: str
    url: str
    engine: str | None = None
    score: float | None = None
    snippet: str | None = None
    content: str | None = None
    published_date: str | None = None
    fetched: bool = False
    extracted: bool = False
    metadata: dict[str, Any] = Field(default_factory=dict)


class SearchResponse(BaseModel):
    request_id: str
    query: str
    page: int
    result_count: int
    results: list[SearchResult]
    summary: str | None = None
    cache: dict[str, Any] = Field(default_factory=dict)
    debug: dict[str, Any] = Field(default_factory=dict)


class SearchPresetCreate(BaseModel):
    name: str = Field(min_length=1)
    request: dict[str, Any] = Field(default_factory=dict)


class SearchPreset(BaseModel):
    preset_id: str
    name: str
    request: dict[str, Any]
    created_at: str
