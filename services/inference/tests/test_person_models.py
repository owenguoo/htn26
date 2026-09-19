"""Real people-only HTTP integration, opt in with SWARM_TEST_REID=1."""

import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from beacon.api import Settings, create_app


@pytest.mark.model
def test_pretrained_reference_match_and_absence():
    if os.environ.get("SWARM_TEST_REID") != "1":
        pytest.skip("Opt-in real YOLOE and OSNet test")
    image = Path("artifacts/bus.jpg").read_bytes()
    settings = Settings(
        api_key="integration-test-secret",
        backend="yoloe",
        device="cpu",
        enable_reid=True,
    )
    headers = {
        "Authorization": "Bearer integration-test-secret",
        "Content-Type": "image/jpeg",
    }
    with TestClient(create_app(settings)) as client:
        registered = client.put(
            "/v1/targets/demo?box=50&box=398&box=247&box=903",
            content=image,
            headers=headers,
        )
        assert registered.status_code == 200, registered.text
        query = {
            "target_id": "demo",
            "phone_id": "phone-1",
            "frame_id": "one",
            "captured_at": 1,
            "similarity_threshold": 0.7,
        }
        response = client.post("/v1/match", params=query, content=image, headers=headers)
        assert response.status_code == 200, response.text
        result = response.json()
        assert result["target_version"] == registered.json()["target_version"]
        assert result["matched"]
        best, second = result["candidates"][:2]
        assert best["similarity"] > second["similarity"] + 0.1
        assert abs(best["box"][0] - 50) < 20
        assert abs(best["box"][2] - 247) < 20

        from io import BytesIO

        from PIL import Image

        buffer = BytesIO()
        with Image.open(BytesIO(image)) as source:
            source.crop((645, 300, 810, 1080)).save(buffer, format="JPEG")
        absent = client.post("/v1/match", params=query, content=buffer.getvalue(), headers=headers)
        assert absent.status_code == 200, absent.text
        assert absent.json()["candidates"]
        assert not absent.json()["matched"]
        assert client.delete("/v1/targets/demo", headers=headers).status_code == 204
        assert (
            client.post("/v1/match", params=query, content=image, headers=headers).status_code
            == 404
        )
