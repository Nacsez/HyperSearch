from __future__ import annotations

import os

import pytest
import httpx


@pytest.mark.skipif(
    not os.getenv("HYPERSEARCH_E2E_BASE_URL"),
    reason="Set HYPERSEARCH_E2E_BASE_URL to run e2e smoke tests",
)
def test_live_healthcheck():
    base_url = os.environ["HYPERSEARCH_E2E_BASE_URL"]
    response = httpx.get(f"{base_url}/v1/health", timeout=10.0)
    assert response.status_code == 200

