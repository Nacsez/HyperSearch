from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import logging
from typing import Any, Awaitable, Callable

from hypersearch_api.config import Settings

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class CacheEnvelope:
    value: dict[str, Any]
    expires_at: datetime


class MemoryCacheBackend:
    def __init__(self) -> None:
        self._store: dict[str, CacheEnvelope] = {}
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> dict[str, Any] | None:
        async with self._lock:
            envelope = self._store.get(key)
            if not envelope:
                return None
            if envelope.expires_at <= datetime.now(timezone.utc):
                self._store.pop(key, None)
                return None
            return envelope.value

    async def set(self, key: str, value: dict[str, Any], ttl_seconds: int) -> None:
        async with self._lock:
            self._store[key] = CacheEnvelope(
                value=value,
                expires_at=datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds),
            )

    async def delete_namespace(self, namespace: str) -> int:
        async with self._lock:
            keys = [key for key in self._store if key.startswith(f"{namespace}:")]
            for key in keys:
                self._store.pop(key, None)
            return len(keys)


class CacheService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.backend = MemoryCacheBackend()
        self._singleflight: dict[str, asyncio.Lock] = {}
        self._singleflight_lock = asyncio.Lock()
        self._redis = None

    async def connect(self) -> None:
        if not self.settings.valkey_url:
            return
        try:
            from redis.asyncio import from_url  # type: ignore
        except ImportError:
            logger.warning(
                "Valkey URL configured but redis dependency is missing",
                extra={"event_data": {"component": "cache"}},
            )
            return
        self._redis = from_url(self.settings.valkey_url, decode_responses=True)
        try:
            await self._redis.ping()
        except Exception as exc:
            logger.warning(
                "Falling back to in-memory cache",
                extra={"event_data": {"component": "cache", "reason": str(exc)}},
            )
            self._redis = None

    async def close(self) -> None:
        if self._redis is not None:
            await self._redis.close()

    def make_key(self, namespace: str, payload: dict[str, Any]) -> str:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return f"{namespace}:{sha256(encoded).hexdigest()}"

    async def get_json(self, key: str) -> dict[str, Any] | None:
        if self._redis is not None:
            raw = await self._redis.get(key)
            return json.loads(raw) if raw else None
        return await self.backend.get(key)

    async def set_json(self, key: str, value: dict[str, Any], ttl_seconds: int) -> None:
        if self._redis is not None:
            await self._redis.set(key, json.dumps(value, ensure_ascii=True), ex=ttl_seconds)
            return
        await self.backend.set(key, value, ttl_seconds)

    async def invalidate_namespace(self, namespace: str) -> int:
        if self._redis is not None:
            cursor = 0
            deleted = 0
            pattern = f"{namespace}:*"
            while True:
                cursor, keys = await self._redis.scan(cursor=cursor, match=pattern, count=500)
                if keys:
                    deleted += await self._redis.delete(*keys)
                if cursor == 0:
                    break
            return deleted
        return await self.backend.delete_namespace(namespace)

    async def coalesce(
        self,
        *,
        key: str,
        loader: Callable[[], Awaitable[dict[str, Any]]],
        ttl_seconds: int,
    ) -> dict[str, Any]:
        cached = await self.get_json(key)
        if cached is not None:
            return cached
        lock = await self._get_lock(key)
        try:
            async with lock:
                cached = await self.get_json(key)
                if cached is not None:
                    return cached
                value = await loader()
                await self.set_json(key, value, ttl_seconds)
                return value
        finally:
            async with self._singleflight_lock:
                if self._singleflight.get(key) is lock:
                    self._singleflight.pop(key, None)

    async def _get_lock(self, key: str) -> asyncio.Lock:
        async with self._singleflight_lock:
            if key not in self._singleflight:
                self._singleflight[key] = asyncio.Lock()
            return self._singleflight[key]
