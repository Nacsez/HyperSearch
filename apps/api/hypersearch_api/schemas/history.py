from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


HistoryKind = Literal["search", "research"]


class HistoryRecord(BaseModel):
    history_id: str
    kind: str
    query: str
    request: dict[str, Any]
    response: dict[str, Any]
    debug: dict[str, Any] | None = None
    created_at: str


class HistoryRetentionRequest(BaseModel):
    days: int = Field(ge=1, le=3650)


class HistoryRetentionResponse(BaseModel):
    deleted: int

