from __future__ import annotations

from dataclasses import dataclass

from .fetch_service import BasicHTMLStripper


@dataclass(slots=True)
class ExtractResult:
    title: str | None
    text: str
    excerpt: str | None
    metadata: dict[str, str]


class ExtractService:
    async def extract(self, html: str, *, url: str) -> ExtractResult:
        try:
            import trafilatura  # type: ignore
        except ImportError:
            return self._fallback_extract(html, url=url)
        text = trafilatura.extract(html, output_format="txt", include_links=False) or ""
        metadata = trafilatura.extract_metadata(html)
        title = getattr(metadata, "title", None) if metadata else None
        excerpt = text[:320] if text else None
        return ExtractResult(
            title=title,
            text=text,
            excerpt=excerpt,
            metadata={"url": url},
        )

    def _fallback_extract(self, html: str, *, url: str) -> ExtractResult:
        parser = BasicHTMLStripper()
        parser.feed(html)
        text = parser.text()
        return ExtractResult(
            title=None,
            text=text,
            excerpt=text[:320] if text else None,
            metadata={"url": url, "extractor": "basic-html-stripper"},
        )

