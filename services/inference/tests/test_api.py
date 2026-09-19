from io import BytesIO

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from swarm_sight.api import Settings, create_app
from swarm_sight.schemas import Detection


class Detector:
    name = "test"

    def predict(self, images, labels, confidence):
        return [[Detection(label=labels[0], score=0.9, box=(1, 2, 10, 12))] for _ in images]


@pytest.fixture
def client():
    with TestClient(create_app(Settings(api_key="test-key-with-16-chars"), Detector())) as client:
        yield client


def request(client, **kwargs):
    data = BytesIO()
    Image.new("RGB", (30, 20)).save(data, "JPEG")
    defaults = {
        "params": {
            "phone_id": "phone-a",
            "frame_id": "frame-1",
            "captured_at": 123.4,
            "labels": ["backpack", "toy"],
        },
        "content": data.getvalue(),
        "headers": {"Authorization": "Bearer test-key-with-16-chars", "Content-Type": "image/jpeg"},
    }
    defaults.update(kwargs)
    return client.post("/v1/detect", **defaults)


def test_http_detection_preserves_metadata_and_coordinate_contract(client):
    response = request(client)
    assert response.status_code == 200, response.text
    body = response.json()
    assert (body["phone_id"], body["frame_id"], body["captured_at"]) == (
        "phone-a",
        "frame-1",
        123.4,
    )
    assert (body["width"], body["height"]) == (30, 20)
    assert body["detections"] == [{"label": "backpack", "score": 0.9, "box": [1, 2, 10, 12]}]
    assert body["queue_ms"] >= 0
    assert body["inference_ms"] >= 0


def test_auth_health_and_invalid_inputs(client):
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").status_code == 200
    assert request(client, headers={}).status_code == 401
    assert request(client, content=b"bad").status_code == 422
    assert request(client, params={"labels": "   "}).status_code == 422
    assert (
        request(
            client,
            headers={
                "Authorization": "Bearer test-key-with-16-chars",
                "Content-Type": "text/plain",
            },
        ).status_code
        == 415
    )


def test_body_limit_is_enforced():
    with TestClient(
        create_app(Settings(api_key="test-key-with-16-chars", max_bytes=10), Detector())
    ) as client:
        assert request(client).status_code == 413


def test_model_failure_returns_503_without_private_details():
    class Broken(Detector):
        def predict(self, images, labels, confidence):
            raise RuntimeError("private checkpoint path")

    with TestClient(create_app(Settings(api_key="test-key-with-16-chars"), Broken())) as client:
        response = request(client)
        assert response.status_code == 503
        assert "private checkpoint" not in response.text


def test_timeout_returns_504_and_worker_stays_usable():
    import time

    class Slow(Detector):
        def predict(self, images, labels, confidence):
            time.sleep(0.05)
            return super().predict(images, labels, confidence)

    settings = Settings(api_key="test-key-with-16-chars", timeout_seconds=0.02)
    with TestClient(create_app(settings, Slow())) as client:
        assert request(client).status_code == 504
        assert client.get("/readyz").status_code == 200


@pytest.mark.parametrize("labels", [[""], ["x" * 81], ["toy"] * 17])
def test_prompt_limits(client, labels):
    assert (
        request(
            client, params={"phone_id": "a", "frame_id": "1", "captured_at": 0, "labels": labels}
        ).status_code
        == 422
    )


def test_openapi_describes_image_upload_and_bearer_auth(client):
    schema = client.get("/openapi.json").json()
    operation = schema["paths"]["/v1/detect"]["post"]
    assert "image/jpeg" in operation["requestBody"]["content"]
    assert operation["security"] == [{"HTTPBearer": []}]


def test_gateway_header_requires_the_worker_secret(client):
    headers = {"Authorization": "Bearer gateway-key", "Content-Type": "image/jpeg"}
    assert request(client, headers=headers).status_code == 401
    headers["X-Swarm-Api-Key"] = "wrong-worker-key"
    assert request(client, headers=headers).status_code == 401
    headers["X-Swarm-Api-Key"] = "test-key-with-16-chars"
    assert request(client, headers=headers).status_code == 200


def test_gateway_preserves_image_type_when_proxy_rewrites_content_type(client):
    headers = {
        "Authorization": "Bearer gateway-key",
        "X-Swarm-Api-Key": "test-key-with-16-chars",
        "Content-Type": "application/json",
        "X-Swarm-Content-Type": "image/jpeg",
    }
    assert request(client, headers=headers).status_code == 200
    assert request(client, headers=headers, content=b"not an image").status_code == 422
    headers["X-Swarm-Content-Type"] = "text/plain"
    assert request(client, headers=headers).status_code == 415
