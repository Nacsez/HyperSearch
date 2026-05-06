from __future__ import annotations

import asyncio
from dataclasses import dataclass
from html.parser import HTMLParser
import httpx

from hypersearch_api.config import Settings


@dataclass(slots=True)
class FetchResult:
    url: str
    status_code: int | None
    content_type: str | None
    text: str | None
    used_playwright: bool
    error: str | None = None


class FetchService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._client = httpx.AsyncClient(
            follow_redirects=True,
            timeout=settings.fetch_timeout_ms / 1000,
            headers={"User-Agent": settings.fetch_user_agent},
        )
        self._sem = asyncio.Semaphore(settings.fetch_concurrency)

    async def close(self) -> None:
        await self._client.aclose()

    async def fetch(self, url: str, *, timeout_ms: int | None = None) -> FetchResult:
        async with self._sem:
            try:
                response = await self._client.get(
                    url,
                    timeout=(timeout_ms or self.settings.fetch_timeout_ms) / 1000,
                )
                response.raise_for_status()
                content_type = response.headers.get("content-type", "")
                body = response.text
                if self._should_try_playwright(body, content_type):
                    fallback = await self._fetch_with_playwright(url)
                    if fallback is not None:
                        return fallback
                return FetchResult(
                    url=url,
                    status_code=response.status_code,
                    content_type=content_type,
                    text=body,
                    used_playwright=False,
                )
            except Exception as exc:
                return FetchResult(
                    url=url,
                    status_code=None,
                    content_type=None,
                    text=None,
                    used_playwright=False,
                    error=str(exc),
                )

    def _should_try_playwright(self, body: str, content_type: str) -> bool:
        if not self.settings.enable_playwright_fallback:
            return False
        if "html" not in content_type.lower():
            return False
        lowered = body.lower()
        return "enable javascript" in lowered or "<noscript" in lowered

    async def _fetch_with_playwright(self, url: str) -> FetchResult | None:
        try:
            from playwright.async_api import async_playwright  # type: ignore
        except ImportError:
            return None
        async with async_playwright() as playwright:
            browser = await playwright.chromium.launch(headless=True)
            try:
                page = await browser.new_page()
                await page.goto(url, timeout=self.settings.fetch_timeout_ms)
                content = await page.content()
            finally:
                await browser.close()
        return FetchResult(
            url=url,
            status_code=200,
            content_type="text/html; charset=utf-8",
            text=content,
            used_playwright=True,
        )


class BasicHTMLStripper(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        clean = " ".join(data.split())
        if clean:
            self.parts.append(clean)

    def text(self) -> str:
        return "\n".join(self.parts)

