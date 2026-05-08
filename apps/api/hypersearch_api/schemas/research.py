from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field, field_validator

from .search import CachePolicy


class ResearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=500)
    engines: list[str] | None = Field(default=None, max_length=20)
    categories: list[str] | None = Field(default=None, max_length=20)
    language: str | None = None
    time_range: str | None = None
    page: int = Field(default=1, ge=1, le=20)
    results_per_page: int = Field(default=10, ge=1, le=50)
    max_pages: int = Field(default=1, ge=1, le=5)
    target_result_count: int | None = Field(default=None, ge=1, le=250)
    safe_search: int = Field(default=1, ge=0, le=2)
    top_n: int = Field(default=5, ge=1, le=250)
    timeout_ms: int | None = Field(default=None, ge=1000, le=600000)
    cache_policy: CachePolicy = "use"
    provider: str | None = None
    streaming: bool = False
    include_debug_trace: bool = True

    @field_validator("page", "results_per_page", "max_pages", "target_result_count", "top_n")
    @classmethod
    def validate_positive(cls, value: int | None) -> int | None:
        if value is not None and value < 1:
            raise ValueError("must be >= 1")
        return value


class ResearchCitation(BaseModel):
    index: int
    title: str
    url: str
    excerpt: str | None = None


class ResearchResponse(BaseModel):
    request_id: str
    query: str
    answer: str
    citations: list[ResearchCitation]
    trace: dict[str, Any] = Field(default_factory=dict)
    raw_search: dict[str, Any] | None = None


class SessionTitleRequest(BaseModel):
    query: str = Field(min_length=1, max_length=500)
    context: str | None = Field(default=None, max_length=4000)
    provider: str | None = None


class SessionTitleResponse(BaseModel):
    title: str
    provider: str | None = None
    model: str | None = None
