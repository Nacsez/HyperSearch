from __future__ import annotations

import httpx
from typing import Any


class SearxClient:
    def __init__(self, *, base_url: str, default_timeout_ms: int = 15000) -> None:
        self.base_url = base_url.rstrip("/")
        self.default_timeout_ms = default_timeout_ms
        self._client = httpx.AsyncClient(timeout=default_timeout_ms / 1000)

    async def close(self) -> None:
        await self._client.aclose()

    async def healthcheck(self) -> dict[str, Any]:
        try:
            response = await self._client.get(f"{self.base_url}/healthz")
            if response.status_code < 400:
                return {"ok": True, "detail": "ok"}
            return {
                "ok": False,
                "detail": f"health endpoint returned HTTP {response.status_code}",
            }
        except Exception as exc:
            return {"ok": False, "detail": str(exc)}

    async def search(
        self,
        *,
        query: str,
        engines: list[str],
        categories: list[str],
        language: str | None,
        time_range: str | None,
        page: int,
        results_per_page: int,
        safe_search: int,
        timeout_ms: int | None = None,
    ) -> dict[str, Any]:
        params = {
            "q": query,
            "format": "json",
            "pageno": page,
            "safesearch": safe_search,
        }
        if engines:
            params["engines"] = ",".join(engines)
        if categories:
            params["categories"] = ",".join(categories)
        if language:
            params["language"] = language
        if time_range:
            params["time_range"] = time_range
        if results_per_page:
            params["count"] = results_per_page
        response = await self._client.get(
            f"{self.base_url}/search",
            params=params,
            timeout=(timeout_ms or self.default_timeout_ms) / 1000,
        )
        response.raise_for_status()
        return response.json()
