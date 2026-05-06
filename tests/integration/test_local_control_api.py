from __future__ import annotations

from fastapi.testclient import TestClient

from hypersearch_api.main import app


def test_invalid_search_bounds_return_422():
    payload = {
        "query": "bounds",
        "results_per_page": 1,
        "max_pages": 1,
        "page": 1,
        "safe_search": 99,
        "dedupe": True,
        "fetch_pages": False,
        "extract_text": False,
        "summarize": False,
        "streaming": False,
        "cache_policy": "only-if-cached",
    }
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        response = client.post("/v1/search", json=payload)
    assert response.status_code == 422


def test_invalid_research_cache_policy_returns_422():
    payload = {
        "query": "bounds",
        "results_per_page": 1,
        "max_pages": 1,
        "page": 1,
        "top_n": 1,
        "timeout_ms": 1000,
        "cache_policy": "invalid",
        "provider": None,
        "streaming": False,
        "include_debug_trace": False,
    }
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        response = client.post("/v1/research", json=payload)
    assert response.status_code == 422


def test_unknown_default_provider_is_rejected():
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        response = client.post("/v1/providers/default", json={"name": "missing"})
    assert response.status_code == 424
    assert response.json()["error"] == "provider_unavailable"


def test_provider_profile_rejects_external_endpoint():
    payload = {
        "display_name": "External",
        "provider_type": "openai-compatible",
        "base_url": "https://api.openai.com",
        "model": "external",
        "enabled": True,
        "is_default": False,
    }
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        response = client.patch("/v1/providers/lmstudio", json=payload)
    assert response.status_code == 424
    assert response.json()["error"] == "provider_unavailable"


def test_lan_access_requires_pairing_token(monkeypatch):
    monkeypatch.setenv("HYPERSEARCH_LAN_ENABLED", "true")
    monkeypatch.setenv("HYPERSEARCH_PAIRING_TOKEN", "paired")
    with TestClient(app, client=("192.168.1.25", 50000)) as client:
        missing = client.get("/v1/metrics")
        paired = client.get("/v1/metrics", headers={"X-HyperSearch-Token": "paired"})
    assert missing.status_code == 403
    assert paired.status_code == 200


def test_local_proxy_access_is_allowed_without_lan_token(monkeypatch):
    monkeypatch.setenv("HYPERSEARCH_LAN_ENABLED", "false")
    monkeypatch.delenv("HYPERSEARCH_PAIRING_TOKEN", raising=False)
    headers = {
        "X-HyperSearch-Proxy": "caddy",
        "X-Forwarded-For": "127.0.0.1",
    }
    with TestClient(app, client=("172.18.0.3", 50000)) as client:
        response = client.get("/v1/live", headers=headers)
    assert response.status_code == 200


def test_lan_proxy_access_requires_token_when_lan_enabled(monkeypatch):
    monkeypatch.setenv("HYPERSEARCH_LAN_ENABLED", "true")
    monkeypatch.setenv("HYPERSEARCH_PAIRING_TOKEN", "paired")
    headers = {
        "X-HyperSearch-Proxy": "caddy",
        "X-Forwarded-For": "192.168.1.25",
    }
    with TestClient(app, client=("172.18.0.3", 50000)) as client:
        missing = client.get("/v1/metrics", headers=headers)
        paired = client.get(
            "/v1/metrics",
            headers={**headers, "X-HyperSearch-Token": "paired"},
        )
    assert missing.status_code == 403
    assert paired.status_code == 200
