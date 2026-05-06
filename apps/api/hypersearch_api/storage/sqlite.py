from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
from threading import Lock
from typing import Any
from uuid import uuid4

from .models import ProviderRecord, SearchHistoryRecord, SearchPresetRecord


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._connection: sqlite3.Connection | None = None
        self._lock = Lock()

    @property
    def connection(self) -> sqlite3.Connection:
        if self._connection is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._connection = sqlite3.connect(self.path, check_same_thread=False)
            self._connection.row_factory = sqlite3.Row
        return self._connection

    def initialize(self) -> None:
        with self._lock:
            conn = self.connection
            conn.execute("PRAGMA journal_mode=WAL;")
            conn.execute("PRAGMA synchronous=NORMAL;")
            self._run_migrations()
            conn.commit()

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None

    def _run_migrations(self) -> None:
        self.connection.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version TEXT PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
            """
        )
        migrations_dir = Path(__file__).resolve().parent / "migrations"
        for path in sorted(migrations_dir.glob("*.sql")):
            already = self.connection.execute(
                "SELECT 1 FROM schema_migrations WHERE version = ?",
                (path.name,),
            ).fetchone()
            if already:
                continue
            self.connection.executescript(path.read_text(encoding="utf-8"))
            self.connection.execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                (path.name, _utcnow()),
            )

    def list_provider_configs(self) -> list[ProviderRecord]:
        rows = self.connection.execute(
            """
            SELECT name, display_name, provider_type, base_url, model, enabled, is_default,
                   metadata_json, updated_at
            FROM provider_configs
            ORDER BY name
            """
        ).fetchall()
        return [
            ProviderRecord(
                name=row["name"],
                display_name=row["display_name"] or row["name"],
                provider_type=row["provider_type"],
                base_url=row["base_url"],
                model=row["model"],
                enabled=bool(row["enabled"]),
                is_default=bool(row["is_default"]),
                metadata=json.loads(row["metadata_json"] or "{}"),
                updated_at=datetime.fromisoformat(row["updated_at"]),
            )
            for row in rows
        ]

    def get_provider_config(self, name: str) -> ProviderRecord | None:
        rows = [item for item in self.list_provider_configs() if item.name == name]
        return rows[0] if rows else None

    def upsert_provider_config(
        self,
        *,
        name: str,
        display_name: str | None,
        provider_type: str,
        base_url: str | None,
        model: str | None,
        enabled: bool,
        is_default: bool,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        with self._lock:
            if is_default:
                self.connection.execute("UPDATE provider_configs SET is_default = 0")
            self.connection.execute(
                """
                INSERT INTO provider_configs
                    (name, display_name, provider_type, base_url, model, api_key, enabled, is_default,
                     metadata_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET
                    display_name = excluded.display_name,
                    provider_type = excluded.provider_type,
                    base_url = excluded.base_url,
                    model = excluded.model,
                    api_key = NULL,
                    enabled = excluded.enabled,
                    is_default = excluded.is_default,
                    metadata_json = excluded.metadata_json,
                    updated_at = excluded.updated_at
                """,
                (
                    name,
                    display_name or name,
                    provider_type,
                    base_url,
                    model,
                    None,
                    int(enabled),
                    int(is_default),
                    json.dumps(metadata or {}, ensure_ascii=True),
                    _utcnow(),
                ),
            )
            self.connection.commit()

    def set_default_provider(self, name: str) -> None:
        with self._lock:
            row = self.connection.execute(
                "SELECT enabled FROM provider_configs WHERE name = ?",
                (name,),
            ).fetchone()
            if row is None:
                raise ValueError(f"Unknown provider: {name}")
            if not bool(row["enabled"]):
                raise ValueError(f"Provider is disabled: {name}")
            self.connection.execute("UPDATE provider_configs SET is_default = 0")
            self.connection.execute(
                "UPDATE provider_configs SET is_default = 1 WHERE name = ?",
                (name,),
            )
            self.connection.commit()

    def update_provider_profile(
        self,
        *,
        name: str,
        display_name: str,
        provider_type: str,
        base_url: str | None,
        model: str | None,
        enabled: bool,
        is_default: bool,
    ) -> ProviderRecord:
        current = self.get_provider_config(name)
        if current is None:
            raise ValueError(f"Unknown provider: {name}")
        self.upsert_provider_config(
            name=name,
            display_name=display_name,
            provider_type=provider_type,
            base_url=base_url,
            model=model,
            enabled=enabled,
            is_default=is_default,
            metadata=current.metadata,
        )
        updated = self.get_provider_config(name)
        if updated is None:
            raise ValueError(f"Unknown provider after update: {name}")
        return updated

    def get_default_provider_name(self) -> str | None:
        row = self.connection.execute(
            "SELECT name FROM provider_configs WHERE is_default = 1 LIMIT 1"
        ).fetchone()
        return row["name"] if row else None

    def save_preset(self, *, name: str, payload: dict[str, Any]) -> SearchPresetRecord:
        created_at = _utcnow()
        with self._lock:
            existing = self.connection.execute(
                "SELECT preset_id FROM presets WHERE lower(name) = lower(?) ORDER BY created_at DESC LIMIT 1",
                (name,),
            ).fetchone()
            if existing:
                preset_id = existing["preset_id"]
                self.connection.execute(
                    """
                    UPDATE presets
                    SET name = ?, payload_json = ?, created_at = ?
                    WHERE preset_id = ?
                    """,
                    (name, json.dumps(payload, ensure_ascii=True), created_at, preset_id),
                )
                self.connection.execute(
                    "DELETE FROM presets WHERE lower(name) = lower(?) AND preset_id != ?",
                    (name, preset_id),
                )
                self.connection.commit()
                return SearchPresetRecord(
                    preset_id=preset_id,
                    name=name,
                    payload=payload,
                    created_at=datetime.fromisoformat(created_at),
                )
            preset_id = str(uuid4())
            self.connection.execute(
                """
                INSERT INTO presets (preset_id, name, payload_json, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (preset_id, name, json.dumps(payload, ensure_ascii=True), created_at),
            )
            self.connection.commit()
        return SearchPresetRecord(
            preset_id=preset_id,
            name=name,
            payload=payload,
            created_at=datetime.fromisoformat(created_at),
        )

    def list_presets(self) -> list[SearchPresetRecord]:
        rows = self.connection.execute(
            "SELECT preset_id, name, payload_json, created_at FROM presets ORDER BY created_at DESC"
        ).fetchall()
        return [
            SearchPresetRecord(
                preset_id=row["preset_id"],
                name=row["name"],
                payload=json.loads(row["payload_json"]),
                created_at=datetime.fromisoformat(row["created_at"]),
            )
            for row in rows
        ]

    def delete_preset(self, preset_id: str) -> bool:
        with self._lock:
            cursor = self.connection.execute(
                "DELETE FROM presets WHERE preset_id = ?",
                (preset_id,),
            )
            self.connection.commit()
        return cursor.rowcount > 0

    def write_history(
        self,
        *,
        kind: str,
        query: str,
        request_payload: dict[str, Any],
        response_payload: dict[str, Any],
        debug_payload: dict[str, Any] | None,
    ) -> SearchHistoryRecord:
        history_id = str(uuid4())
        created_at = _utcnow()
        with self._lock:
            self.connection.execute(
                """
                INSERT INTO search_history
                    (history_id, kind, query, request_json, response_json, debug_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    history_id,
                    kind,
                    query,
                    json.dumps(request_payload, ensure_ascii=True),
                    json.dumps(response_payload, ensure_ascii=True),
                    json.dumps(debug_payload, ensure_ascii=True)
                    if debug_payload is not None
                    else None,
                    created_at,
                ),
            )
            self.connection.commit()
        return SearchHistoryRecord(
            history_id=history_id,
            kind=kind,
            query=query,
            request_payload=request_payload,
            response_payload=response_payload,
            debug_payload=debug_payload,
            created_at=datetime.fromisoformat(created_at),
        )

    def list_history(
        self,
        *,
        kind: str | None = None,
        query: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list[SearchHistoryRecord]:
        clauses: list[str] = []
        params: list[Any] = []
        if kind:
            clauses.append("kind = ?")
            params.append(kind)
        if query:
            clauses.append("query LIKE ?")
            params.append(f"%{query}%")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self.connection.execute(
            f"""
            SELECT history_id, kind, query, request_json, response_json, debug_json, created_at
            FROM search_history
            {where}
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
            (*params, limit, offset),
        ).fetchall()
        return [self._history_from_row(row) for row in rows]

    def delete_history(self, history_id: str) -> bool:
        with self._lock:
            cursor = self.connection.execute(
                "DELETE FROM search_history WHERE history_id = ?",
                (history_id,),
            )
            self.connection.commit()
            return cursor.rowcount > 0

    def delete_history_older_than(self, cutoff_iso: str) -> int:
        with self._lock:
            cursor = self.connection.execute(
                "DELETE FROM search_history WHERE created_at < ?",
                (cutoff_iso,),
            )
            self.connection.commit()
            return cursor.rowcount

    def export_history(self) -> list[dict[str, Any]]:
        return [
            {
                "history_id": item.history_id,
                "kind": item.kind,
                "query": item.query,
                "request": item.request_payload,
                "response": item.response_payload,
                "debug": item.debug_payload,
                "created_at": item.created_at.isoformat(),
            }
            for item in self.list_history(limit=10000)
        ]

    def _history_from_row(self, row: sqlite3.Row) -> SearchHistoryRecord:
        return SearchHistoryRecord(
            history_id=row["history_id"],
            kind=row["kind"],
            query=row["query"],
            request_payload=json.loads(row["request_json"]),
            response_payload=json.loads(row["response_json"]),
            debug_payload=json.loads(row["debug_json"]) if row["debug_json"] else None,
            created_at=datetime.fromisoformat(row["created_at"]),
        )

    def vacuum(self) -> None:
        with self._lock:
            self.connection.execute("VACUUM")
            self.connection.commit()


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()
