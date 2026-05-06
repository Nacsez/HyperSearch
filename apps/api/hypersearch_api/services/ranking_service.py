from __future__ import annotations

from typing import Any


class RankingService:
    def rank(self, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return sorted(
            results,
            key=lambda item: (
                item.get("score") or 0,
                -(item.get("position") or 0),
            ),
            reverse=True,
        )

