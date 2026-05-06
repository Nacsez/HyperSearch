from __future__ import annotations

from hypersearch_api.providers.llm.base import LLMCompletion
from hypersearch_api.services.synthesize_service import SynthesizeService

import pytest


class FakeProviderService:
    def __init__(self, provider) -> None:
        self.provider = provider

    def resolve(self, name=None):
        return self.provider


class ScriptedProvider:
    provider_name = "lmstudio"
    model = "local-test-model"

    def __init__(self, script) -> None:
        self.script = list(script)

    async def chat(self, *, messages, temperature=0.2, stream=False, timeout_ms=None, max_tokens=None):
        next_item = self.script.pop(0)
        if isinstance(next_item, Exception):
            raise next_item
        return LLMCompletion(
            provider=self.provider_name,
            model=self.model,
            content=next_item,
            raw={"choices": [{"message": {"content": next_item}}]},
        )


def _documents(count=3):
    return [
        {
            "title": f"Source {index}",
            "url": f"https://example.com/{index}",
            "content": f"Evidence text for source {index}",
        }
        for index in range(1, count + 1)
    ]


@pytest.mark.asyncio
async def test_research_batch_timeout_keeps_partial_synthesis_available():
    provider = ScriptedProvider(
        [
            TimeoutError(),
            "refined question",
            "final answer [1]",
        ]
    )
    service = SynthesizeService(FakeProviderService(provider))

    payload = await service.synthesize_research(
        query="Which option is best?",
        documents=_documents(),
    )

    assert payload["answer"] == "final answer [1]"
    assert payload["provider"] == "lmstudio"
    assert payload["research_steps"]["summary_meta"]["failed_batches"]
    assert "TimeoutError" in payload["research_steps"]["summary_meta"]["failed_batches"][0]["error"]


@pytest.mark.asyncio
async def test_final_research_timeout_returns_staged_evidence_not_raw_quote_collage():
    provider = ScriptedProvider(
        [
            "batch synopsis [1]",
            "refined question",
            TimeoutError(),
        ]
    )
    service = SynthesizeService(FakeProviderService(provider))

    payload = await service.synthesize_research(
        query="Which option is best?",
        documents=_documents(),
    )

    assert payload["provider"] == "lmstudio"
    assert payload["model"] == "local-test-model"
    assert "could not complete the final synthesis step" in payload["answer"]
    assert "batch synopsis [1]" in payload["answer"]
    assert "TimeoutError" in payload["error"]
