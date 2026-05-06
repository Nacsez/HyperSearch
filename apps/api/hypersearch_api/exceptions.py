from __future__ import annotations

from typing import Any


class HyperSearchError(Exception):
    status_code = 500
    error_code = "hypersearch_error"

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_code: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        if status_code is not None:
            self.status_code = status_code
        if error_code is not None:
            self.error_code = error_code
        self.message = message
        self.details = details or {}

    def as_payload(self) -> dict[str, Any]:
        return {
            "detail": self.message,
            "error": self.error_code,
            "details": self.details,
        }


class UpstreamServiceError(HyperSearchError):
    status_code = 503
    error_code = "upstream_unavailable"


class ProviderUnavailableError(HyperSearchError):
    status_code = 424
    error_code = "provider_unavailable"


class ProviderModelUnavailableError(HyperSearchError):
    status_code = 424
    error_code = "provider_model_unavailable"

