from __future__ import annotations

import re
from typing import Any

from hypersearch_api.providers.llm.base import LLMMessage

from .provider_service import ProviderService

MAX_CHAT_USER_CHARS = 18000
RESEARCH_BATCH_SIZE = 5
RESEARCH_BATCH_SOURCE_CHARS = 900
LARGE_RESEARCH_DOCUMENT_THRESHOLD = 18
COMPACT_RESEARCH_BATCH_SIZE = 8
COMPACT_RESEARCH_SOURCE_CHARS = 550
MAX_BATCH_SYNOPSIS_CHARS = 1800
CONSOLIDATION_BRIEF_CHARS = 12000
QUESTION_REFINEMENT_CHARS = 8000
FINAL_EVIDENCE_BRIEF_CHARS = 12000
FINAL_SOURCE_LIST_CHARS = 5000
COMPACT_FINAL_EVIDENCE_BRIEF_CHARS = 8500
COMPACT_FINAL_SOURCE_LIST_CHARS = 3800
BATCH_SUMMARY_TIMEOUT_MS = 60000
SYNTHESIS_TIMEOUT_MS = 90000
SEARCH_SUMMARY_MAX_TOKENS = 1200
BATCH_SUMMARY_MAX_TOKENS = 1000
CONSOLIDATION_MAX_TOKENS = 1400
QUESTION_REFINEMENT_MAX_TOKENS = 700
FINAL_ANSWER_MAX_TOKENS = 2400


class SynthesizeService:
    def __init__(self, provider_service: ProviderService) -> None:
        self.provider_service = provider_service

    def _fit_prompt_text(self, value: str, *, max_chars: int, label: str) -> str:
        if len(value) <= max_chars:
            return value
        return (
            value[:max_chars].rstrip()
            + f"\n\n[HyperSearch truncated {label} to fit the configured local model context budget.]"
        )

    def _error_detail(self, exc: Exception) -> str:
        detail = str(exc).strip() or repr(exc)
        return f"{type(exc).__name__}: {detail}"

    def _extractive_search_summary(
        self,
        *,
        query: str,
        results: list[dict[str, Any]],
        error: str | None = None,
    ) -> str:
        excerpts = []
        for index, item in enumerate(results[:8], start=1):
            text = item.get("snippet") or item.get("content") or ""
            excerpts.append(
                f"{index}. {item.get('title') or item.get('url')} - {self._fit_prompt_text(str(text), max_chars=260, label='source excerpt')}"
            )
        prefix = (
            "The local model could not complete a generated search summary"
            + (f" ({error})." if error else ".")
            + " The strongest matching sources are:\n\n"
        )
        return prefix + "\n".join(excerpts)

    def _extractive_batch_synopsis(
        self,
        *,
        documents: list[dict[str, Any]],
        start_index: int,
        error: str | None = None,
    ) -> str:
        lines = []
        if error:
            lines.append(f"Batch model synopsis unavailable ({error}); using compact source notes.")
        for offset, document in enumerate(documents):
            index = start_index + offset
            text = self._document_text(document, max_chars=300).replace("\n", " ")
            lines.append(f"[{index}] {document.get('title') or document.get('url')}: {text}")
        return "\n".join(lines)

    def _partial_research_answer(
        self,
        *,
        evidence_brief: str,
        citations: list[dict[str, Any]],
        error: str,
    ) -> str:
        if evidence_brief.strip():
            return (
                "The local model could not complete the final synthesis step within the current model budget. "
                f"HyperSearch preserved the staged evidence review instead. Error: {error}\n\n"
                f"{evidence_brief}"
            )
        return self._extractive_batch_synopsis(
            documents=[
                {
                    "title": item.get("title"),
                    "url": item.get("url"),
                    "content": item.get("excerpt"),
                }
                for item in citations
            ],
            start_index=1,
            error=error,
        )

    async def _chat(
        self,
        *,
        provider,
        system: str,
        user: str,
        temperature: float = 0.2,
        timeout_ms: int | None = None,
        max_tokens: int | None = None,
    ):
        user = self._fit_prompt_text(
            user,
            max_chars=MAX_CHAT_USER_CHARS,
            label="the prompt",
        )
        return await provider.chat(
            messages=[
                LLMMessage(role="system", content=system),
                LLMMessage(role="user", content=user),
            ],
            temperature=temperature,
            timeout_ms=timeout_ms,
            max_tokens=max_tokens,
        )

    def _document_text(self, document: dict[str, Any], *, max_chars: int = 1600) -> str:
        return (document.get("content") or document.get("snippet") or "")[:max_chars]

    def _research_citations(self, documents: list[dict[str, Any]]) -> list[dict[str, Any]]:
        citations = []
        for index, document in enumerate(documents, start=1):
            citations.append(
                {
                    "index": index,
                    "title": document.get("title") or document.get("url"),
                    "url": document.get("url"),
                    "excerpt": self._document_text(document, max_chars=320),
                }
            )
        return citations

    def _research_evidence_block(
        self,
        documents: list[dict[str, Any]],
        *,
        start_index: int = 1,
        max_chars: int = 1600,
    ) -> str:
        blocks = []
        for offset, document in enumerate(documents):
            index = start_index + offset
            blocks.append(
                f"[{index}] {document.get('title')}\n"
                f"URL: {document.get('url')}\n"
                f"Text: {self._document_text(document, max_chars=max_chars)}"
            )
        return "\n\n".join(blocks)

    def _clean_session_title(self, value: str, fallback: str) -> str:
        cleaned = re.sub(r"^[\"'`]+|[\"'`]+$", "", value.strip())
        cleaned = re.sub(r"^(title|session name)\s*:\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s+", " ", cleaned)
        cleaned = re.sub(r"[<>:\"/\\|?*\x00-\x1f]", " ", cleaned).strip(" .")
        if not cleaned:
            cleaned = fallback.strip()
        return (cleaned[:48].strip(" .") or "Research Session")

    async def title_session(
        self,
        *,
        query: str,
        context: str | None = None,
        provider_name: str | None = None,
    ) -> dict[str, Any]:
        provider = self.provider_service.resolve(provider_name)
        prompt = (
            "Please name this active search session by topic using 48 characters or less.\n"
            "Return only the title. Do not add quotes, bullets, punctuation decoration, or explanations.\n\n"
            f"User query: {query}\n\n"
            f"Context:\n{(context or '')[:4000]}"
        )
        completion = await self._chat(
            provider=provider,
            system="You create short, specific titles for local research sessions.",
            user=prompt,
            temperature=0.1,
        )
        return {
            "title": self._clean_session_title(completion.content, query),
            "provider": completion.provider,
            "model": completion.model,
        }

    async def _summarize_research_material(
        self,
        *,
        provider,
        query: str,
        documents: list[dict[str, Any]],
    ) -> tuple[list[str], dict[str, Any]]:
        if not documents:
            return [], {"compact_mode": False, "failed_batches": [], "consolidation_error": None}
        compact_mode = len(documents) >= LARGE_RESEARCH_DOCUMENT_THRESHOLD
        chunk_size = COMPACT_RESEARCH_BATCH_SIZE if compact_mode else RESEARCH_BATCH_SIZE
        source_chars = COMPACT_RESEARCH_SOURCE_CHARS if compact_mode else RESEARCH_BATCH_SOURCE_CHARS
        synopses: list[str] = []
        meta: dict[str, Any] = {
            "compact_mode": compact_mode,
            "batch_size": chunk_size,
            "batch_source_chars": source_chars,
            "failed_batches": [],
            "consolidation_error": None,
        }
        for chunk_start in range(0, len(documents), chunk_size):
            chunk = documents[chunk_start : chunk_start + chunk_size]
            evidence = self._research_evidence_block(
                chunk,
                start_index=chunk_start + 1,
                max_chars=source_chars,
            )
            prompt = (
                "Review this batch of source material for a research task.\n"
                "Produce a concise analytical synopsis, not a list of copied quotes.\n"
                "Keep useful distinctions, agreements, contradictions, dates, and source quality notes.\n"
                "Use inline citations like [1] when recording facts.\n\n"
                f"Original user question: {query}\n\n"
                f"Source batch:\n{evidence}"
            )
            try:
                completion = await self._chat(
                    provider=provider,
                    system="You turn source material into compact, cited research notes without inventing facts.",
                    user=prompt,
                    temperature=0.15,
                    timeout_ms=BATCH_SUMMARY_TIMEOUT_MS,
                    max_tokens=BATCH_SUMMARY_MAX_TOKENS,
                )
                synopsis = completion.content.strip()
                if not synopsis:
                    raise RuntimeError("model returned an empty batch synopsis")
                synopses.append(
                    self._fit_prompt_text(
                        synopsis,
                        max_chars=MAX_BATCH_SYNOPSIS_CHARS,
                        label="batch synopsis",
                    )
                )
            except Exception as exc:
                error = self._error_detail(exc)
                meta["failed_batches"].append(
                    {
                        "start_index": chunk_start + 1,
                        "source_count": len(chunk),
                        "error": error,
                    }
                )
                synopses.append(
                    self._extractive_batch_synopsis(
                        documents=chunk,
                        start_index=chunk_start + 1,
                        error=error,
                    )
                )
        if len(synopses) <= 1 or compact_mode:
            return synopses, meta
        combined = "\n\n".join(f"Batch {index + 1}:\n{synopsis}" for index, synopsis in enumerate(synopses))
        combined = self._fit_prompt_text(
            combined,
            max_chars=CONSOLIDATION_BRIEF_CHARS,
            label="batch synopses",
        )
        try:
            consolidation = await self._chat(
                provider=provider,
                system="You consolidate cited research notes into a clean analyst brief without losing citations.",
                user=(
                    "Consolidate these batch synopses into a single evidence brief for final answer synthesis.\n"
                    "Preserve inline citations. Merge duplicates. Keep contradictions and uncertainty explicit.\n\n"
                    f"Original user question: {query}\n\n"
                    f"Batch synopses:\n{combined}"
                ),
                temperature=0.15,
                timeout_ms=SYNTHESIS_TIMEOUT_MS,
                max_tokens=CONSOLIDATION_MAX_TOKENS,
            )
            content = consolidation.content.strip()
            if content:
                return [content], meta
            raise RuntimeError("model returned an empty consolidated synopsis")
        except Exception as exc:
            meta["consolidation_error"] = self._error_detail(exc)
            return [combined], meta

    async def _refine_research_question(self, *, provider, query: str, synopsis: str) -> str:
        completion = await self._chat(
            provider=provider,
            system="You clarify research questions while preserving the user's intent.",
            user=(
                "Restate the user's question as one precise research question that gets to the heart of what they are asking.\n"
                "Do not answer yet. Do not add assumptions that are not supported by the question or evidence brief.\n\n"
                f"User question: {query}\n\n"
                f"Evidence brief:\n{self._fit_prompt_text(synopsis, max_chars=QUESTION_REFINEMENT_CHARS, label='evidence brief')}"
            ),
            temperature=0.1,
            timeout_ms=BATCH_SUMMARY_TIMEOUT_MS,
            max_tokens=QUESTION_REFINEMENT_MAX_TOKENS,
        )
        return completion.content.strip() or query

    async def summarize_search(
        self,
        *,
        query: str,
        results: list[dict[str, Any]],
        provider_name: str | None = None,
    ) -> dict[str, Any]:
        excerpts = [
            f"[{index}] {item.get('title')}: {item.get('snippet') or item.get('content') or ''}"
            for index, item in enumerate(results[:10], start=1)
        ]
        prompt = (
            "Summarize these search findings in a compact analyst style. "
            "Use inline numeric citations like [1] when making claims.\n\n"
            f"Query: {query}\n\n"
            "Evidence:\n"
            + "\n".join(excerpts)
        )
        try:
            provider = self.provider_service.resolve(provider_name)
            completion = await self._chat(
                provider=provider,
                system="You summarize search results honestly and cite the supplied evidence.",
                user=prompt,
                temperature=0.15,
                timeout_ms=BATCH_SUMMARY_TIMEOUT_MS,
                max_tokens=SEARCH_SUMMARY_MAX_TOKENS,
            )
            if not completion.content.strip():
                raise RuntimeError("model returned an empty search summary")
            return {
                "summary": completion.content,
                "provider": completion.provider,
                "model": completion.model,
            }
        except Exception as exc:
            error = self._error_detail(exc)
            return {
                "summary": self._extractive_search_summary(
                    query=query,
                    results=results,
                    error=error,
                ),
                "provider": provider_name or "fallback",
                "model": None,
                "error": error,
            }

    async def synthesize_research(
        self,
        *,
        query: str,
        documents: list[dict[str, Any]],
        provider_name: str | None = None,
    ) -> dict[str, Any]:
        citations = self._research_citations(documents)
        provider = None
        try:
            provider = self.provider_service.resolve(provider_name)
            synopses, summary_meta = await self._summarize_research_material(
                provider=provider,
                query=query,
                documents=documents,
            )
            compact_mode = bool(summary_meta.get("compact_mode"))
            untrimmed_evidence_brief = "\n\n".join(synopses)
            evidence_brief = self._fit_prompt_text(
                untrimmed_evidence_brief,
                max_chars=COMPACT_FINAL_EVIDENCE_BRIEF_CHARS if compact_mode else FINAL_EVIDENCE_BRIEF_CHARS,
                label="the final evidence brief",
            )
            question_refinement_error = None
            try:
                refined_question = await self._refine_research_question(
                    provider=provider,
                    query=query,
                    synopsis=evidence_brief,
                )
            except Exception as exc:
                question_refinement_error = self._error_detail(exc)
                refined_question = query
            source_list = self._fit_prompt_text(
                "\n".join(f"[{item['index']}] {item['title']} - {item['url']}" for item in citations),
                max_chars=COMPACT_FINAL_SOURCE_LIST_CHARS if compact_mode else FINAL_SOURCE_LIST_CHARS,
                label="the source list",
            )
            research_steps = {
                "source_count": len(documents),
                "synopsis_count": len(synopses),
                "refined_question": refined_question,
                "question_refinement_error": question_refinement_error,
                "summary_meta": summary_meta,
                "prompt_budget": {
                    "max_chat_user_chars": MAX_CHAT_USER_CHARS,
                    "batch_size": summary_meta.get("batch_size"),
                    "batch_source_chars": summary_meta.get("batch_source_chars"),
                    "compact_mode": compact_mode,
                    "untrimmed_evidence_brief_chars": len(untrimmed_evidence_brief),
                    "final_evidence_brief_chars": len(evidence_brief),
                    "source_list_chars": len(source_list),
                },
            }
            try:
                completion = await self._chat(
                    provider=provider,
                    system=(
                        "You are a careful research analyst. Synthesize an actual answer, not a quote collage. "
                        "Use only the cited evidence brief and source list. Use inline citations and state uncertainty. "
                        "Write in a factual, analytical, welcoming, and non-condescending tone."
                    ),
                    user=(
                        "Write a direct, useful answer to the refined research question.\n"
                        "Start immediately with the conclusion sentence. Do not label the opening as Brief Response, Brief Conclusion, Summary, or Answer.\n"
                        "Then include key reasoning and caveats sections if useful.\n"
                        "Be concise and not over-wordy, but support important arguments with citations.\n"
                        "Do not paste long source excerpts. Do not invent citations. Cite claims with source numbers like [1].\n\n"
                        f"Original user question: {query}\n\n"
                        f"Refined research question: {refined_question}\n\n"
                        f"Evidence brief:\n{evidence_brief}\n\n"
                        "Available sources:\n"
                        + source_list
                    ),
                    temperature=0.2,
                    timeout_ms=SYNTHESIS_TIMEOUT_MS,
                    max_tokens=FINAL_ANSWER_MAX_TOKENS,
                )
                answer = completion.content.strip()
                if not answer:
                    raise RuntimeError("model returned an empty final research answer")
            except Exception as exc:
                final_error = self._error_detail(exc)
                research_steps["final_synthesis_error"] = final_error
                return {
                    "answer": self._partial_research_answer(
                        evidence_brief=evidence_brief,
                        citations=citations,
                        error=final_error,
                    ),
                    "citations": citations,
                    "provider": provider.provider_name,
                    "model": getattr(provider, "model", None),
                    "error": final_error,
                    "research_steps": research_steps,
                }
            return {
                "answer": answer,
                "citations": citations,
                "provider": completion.provider,
                "model": completion.model,
                "research_steps": research_steps,
            }
        except Exception as exc:
            error = self._error_detail(exc)
            fallback_answer = self._partial_research_answer(
                evidence_brief="",
                citations=citations,
                error=error,
            )
            return {
                "answer": fallback_answer,
                "citations": citations,
                "provider": getattr(provider, "provider_name", None) or provider_name or "fallback",
                "model": getattr(provider, "model", None),
                "error": error,
            }
