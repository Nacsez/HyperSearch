from __future__ import annotations

from types import SimpleNamespace

import pytest

from hypersearch_api.providers.llm.base import LLMCompletion, LLMMessage, ProviderHealth
from hypersearch_api.services.provider_service import ProviderService
from hypersearch_api.storage.sqlite import Database


class FakeDraftProvider:
    provider_name = "fake"

    def __init__(self, *, base_url, model, timeout_ms=45000):
        self.base_url = base_url
        self.model = model
        self.timeout_ms = timeout_ms

    async def list_models(self):
        return ["draft-model", "other-model"]

    async def healthcheck(self):
        return ProviderHealth(
            name="fake",
            ok=self.model == "draft-model",
            detail="draft ready",
            model_available=self.model == "draft-model",
            generation_ok=self.model == "draft-model",
            models=await self.list_models(),
        )

    async def chat(
        self,
        *,
        messages: list[LLMMessage],
        temperature: float = 0.2,
        stream: bool = False,
        timeout_ms: int | None = None,
        max_tokens: int | None = None,
    ):
        assert self.model == "draft-model"
        return LLMCompletion(provider="fake", model=self.model, content="pong", raw={})


def _settings(tmp_path):
    return SimpleNamespace(
        provider_default="lmstudio",
        lmstudio_base_url="http://127.0.0.1:1234",
        lmstudio_model="saved-model",
        vllm_base_url=None,
        vllm_model=None,
        llamacpp_base_url=None,
        llamacpp_model=None,
        provider_timeout_ms=45000,
        llm_enabled=True,
        llm_disabled_reason=None,
        llm_settings_source="test",
        sqlite_path=tmp_path / "provider.db",
    )


@pytest.mark.asyncio
async def test_draft_provider_test_and_verify_use_unsaved_model(tmp_path):
    settings = _settings(tmp_path)
    database = Database(settings.sqlite_path)
    database.initialize()
    service = ProviderService(settings, database)
    await service.initialize()
    service._provider_class_for_name = lambda name: FakeDraftProvider

    test_payload = await service.test_provider(
        name="lmstudio",
        base_url="http://127.0.0.1:1234",
        model="draft-model",
        enabled=True,
    )
    verify_payload = await service.verify_model_available(
        "lmstudio",
        base_url="http://127.0.0.1:1234",
        model="draft-model",
        enabled=True,
    )

    assert test_payload["ok"] is True
    assert test_payload["model"] == "draft-model"
    assert verify_payload["model"] == "draft-model"
    assert "draft-model" in verify_payload["available_models"]
