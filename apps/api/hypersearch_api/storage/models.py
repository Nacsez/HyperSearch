from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any


@dataclass(slots=True)
class ProviderRecord:
    name: str
    display_name: str
    provider_type: str
    base_url: str | None
    model: str | None
    enabled: bool
    is_default: bool
    metadata: dict[str, Any]
    updated_at: datetime


@dataclass(slots=True)
class SearchPresetRecord:
    preset_id: str
    name: str
    payload: dict[str, Any]
    created_at: datetime


@dataclass(slots=True)
class SearchHistoryRecord:
    history_id: str
    kind: str
    query: str
    request_payload: dict[str, Any]
    response_payload: dict[str, Any]
    debug_payload: dict[str, Any] | None
    created_at: datetime
