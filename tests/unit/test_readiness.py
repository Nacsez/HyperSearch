from __future__ import annotations

from types import SimpleNamespace

import pytest
from starlette.responses import Response

from hypersearch_api.routers.health import ready


class FakeSearxClient:
    async def healthcheck(self):
        return {"ok": True, "detail": "ready"}


class FakeProviderService:
    async def llm_capability(self):
        return {
            "enabled": False,
            "ready": False,
            "mode": "disabled",
            "detail": "Search-only capability mode",
            "provider": "lmstudio",
            "model": "local-model",
        }


@pytest.mark.asyncio
async def test_ready_is_search_ready_when_llm_disabled():
    request = SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                searx_client=FakeSearxClient(),
                provider_service=FakeProviderService(),
                cache=SimpleNamespace(_redis=None),
                settings=SimpleNamespace(environment="test"),
            )
        )
    )
    response = Response()

    payload = await ready(request, response)

    assert response.status_code == 200
    assert payload["status"] == "ready"
    assert payload["capabilities"]["search"]["ready"] is True
    assert payload["capabilities"]["llm"]["enabled"] is False
