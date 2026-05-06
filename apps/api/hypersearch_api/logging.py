from __future__ import annotations

from contextvars import ContextVar
from datetime import datetime, timezone
import json
import logging
from typing import Any

from .config import Settings

request_id_ctx: ContextVar[str | None] = ContextVar("request_id", default=None)
trace_id_ctx: ContextVar[str | None] = ContextVar("trace_id", default=None)

_REDACT_KEYS = {
    "authorization",
    "x-api-key",
    "x-hypersearch-token",
    "api_key",
    "pairing_token",
    "token",
    "password",
    "secret",
}


def set_request_context(*, request_id: str, trace_id: str) -> None:
    request_id_ctx.set(request_id)
    trace_id_ctx.set(trace_id)


def clear_request_context() -> None:
    request_id_ctx.set(None)
    trace_id_ctx.set(None)


def sanitize_mapping(payload: dict[str, Any] | None) -> dict[str, Any]:
    if not payload:
        return {}
    sanitized: dict[str, Any] = {}
    for key, value in payload.items():
        lower_key = key.lower()
        if lower_key in _REDACT_KEYS:
            sanitized[key] = "***redacted***"
        elif isinstance(value, dict):
            sanitized[key] = sanitize_mapping(value)
        else:
            sanitized[key] = value
    return sanitized


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_ctx.get(),
            "trace_id": trace_id_ctx.get(),
        }
        event_data = getattr(record, "event_data", None)
        if isinstance(event_data, dict):
            payload["event"] = sanitize_mapping(event_data)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=True)


def configure_logging(settings: Settings) -> None:
    root = logging.getLogger()
    root.handlers.clear()
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root.addHandler(handler)
    root.setLevel(settings.log_level)
