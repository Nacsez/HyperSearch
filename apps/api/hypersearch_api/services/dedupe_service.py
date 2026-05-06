from __future__ import annotations

from urllib.parse import urlparse, urlunparse
from typing import Any


class DedupeService:
    def dedupe(self, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
        seen: set[str] = set()
        deduped: list[dict[str, Any]] = []
        for result in results:
            signature = self._signature(result)
            if signature in seen:
                continue
            seen.add(signature)
            deduped.append(result)
        return deduped

    def _signature(self, result: dict[str, Any]) -> str:
        url = result.get("url", "")
        parsed = urlparse(url)
        clean_url = urlunparse(
            (parsed.scheme, parsed.netloc, parsed.path, "", "", "")
        ).lower()
        title = str(result.get("title", "")).strip().lower()
        return f"{clean_url}|{title}"

