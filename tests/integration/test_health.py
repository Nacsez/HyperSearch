from fastapi.testclient import TestClient

from hypersearch_api.main import app


def test_root_endpoint():
    with TestClient(app) as client:
        response = client.get("/")
        assert response.status_code == 200
        assert response.json()["service"] == "hypersearch"
