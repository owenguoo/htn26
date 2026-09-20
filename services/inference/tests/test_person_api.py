from io import BytesIO

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from beacon.api import Settings, create_app
from beacon.schemas import Detection

KEY = "test-key-with-16-chars"
HEADERS = {"Authorization": f"Bearer {KEY}", "Content-Type": "image/png"}
META = {
    "target_id": "alice",
    "phone_id": "phone",
    "frame_id": "frame",
    "captured_at": 123,
    "similarity_threshold": 0.8,
}


class Detector:
    name = "test"

    def predict(self, images, labels, confidence):
        assert labels == ("person",)
        return [[Detection(label="person", score=0.9, box=(0, 0, 10, 10))] for _ in images]


class Embedder:
    def encode(self, images):
        return [(1.0,) + (0.0,) * 511 for _ in images]


def png():
    output = BytesIO()
    Image.new("RGB", (20, 20)).save(output, "PNG")
    return output.getvalue()


def app(**settings):
    return create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True, **settings),
        Detector(),
        embedder=Embedder(),
    )


def test_lifecycle_and_metadata():
    with TestClient(app()) as client:
        assert (
            client.post("/v1/match", params=META, headers=HEADERS, content=png()).status_code == 404
        )
        first = client.put("/v1/targets/alice", content=png(), headers=HEADERS)
        assert first.status_code == 200, first.text
        assert "embedding" not in first.text
        result = client.post("/v1/match", params=META, content=png(), headers=HEADERS)
        assert result.status_code == 200, result.text
        body = result.json()
        assert body["target_version"] == first.json()["target_version"]
        assert body["matched"] and body["candidates"][0]["similarity"] == 1
        assert (body["frame_id"], body["phone_id"], body["captured_at"]) == ("frame", "phone", 123)
        second = client.put("/v1/targets/alice", content=png(), headers=HEADERS)
        assert second.json()["target_version"] != first.json()["target_version"]
        assert client.delete("/v1/targets/alice", headers=HEADERS).status_code == 204
        assert client.delete("/v1/targets/alice", headers=HEADERS).status_code == 404


def test_auth_validation_and_disabled():
    with TestClient(app()) as client:
        assert client.put("/v1/targets/alice", content=png()).status_code == 401
        assert client.delete("/v1/targets/alice").status_code == 401
        assert client.post("/v1/match", params=META, content=png()).status_code == 401
        assert (
            client.put(
                "/v1/targets/alice", params={"box": [-1, 0, 10, 10]}, headers=HEADERS, content=png()
            ).status_code
            == 422
        )
        assert client.put("/v1/targets/alice", headers=HEADERS, content=b"bad").status_code == 422
        params = {key: value for key, value in META.items() if key != "similarity_threshold"}
        assert (
            client.post("/v1/match", params=params, headers=HEADERS, content=png()).status_code
            == 422
        )
    with TestClient(create_app(Settings(api_key=KEY, enable_reid=False), Detector())) as client:
        assert client.put("/v1/targets/alice", headers=HEADERS, content=png()).status_code == 503


@pytest.mark.parametrize("setting,status", [({"max_bytes": 10}, 413), ({"max_pixels": 10}, 422)])
def test_upload_limits(setting, status):
    with TestClient(app(**setting)) as client:
        assert client.put("/v1/targets/alice", headers=HEADERS, content=png()).status_code == status


def test_target_cap():
    with TestClient(app()) as client:
        for index in range(32):
            assert (
                client.put(f"/v1/targets/{index}", headers=HEADERS, content=png()).status_code
                == 200
            )
        assert client.put("/v1/targets/full", headers=HEADERS, content=png()).status_code == 429
        assert client.put("/v1/targets/0", headers=HEADERS, content=png()).status_code == 200


async def test_timeout_keeps_embedding_slot_until_thread_finishes():
    import asyncio
    import threading

    import httpx

    class BlockingEmbedder(Embedder):
        calls = 0

        def __init__(self):
            self.started = threading.Event()
            self.release = threading.Event()

        def encode(self, images):
            self.calls += 1
            if self.calls == 2:
                self.started.set()
                assert self.release.wait(2)
            return super().encode(images)

    embedder = BlockingEmbedder()
    application = create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True, timeout_seconds=0.08),
        Detector(),
        embedder=embedder,
    )
    async with application.router.lifespan_context(application):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://test"
        ) as client:
            assert (
                await client.put("/v1/targets/alice", headers=HEADERS, content=png())
            ).status_code == 200
            match = asyncio.create_task(
                client.post("/v1/match", headers=HEADERS, params=META, content=png())
            )
            try:
                assert await asyncio.to_thread(embedder.started.wait, 1)
                assert (await match).status_code == 504
                assert len(application.state.reid_jobs) == 1
                response = await client.put(
                    "/v1/targets/bob",
                    headers=HEADERS,
                    params={"box": [0, 0, 10, 10]},
                    content=png(),
                )
                assert response.status_code == 504
                assert embedder.calls == 2
                assert len(application.state.reid_jobs) == 1
            finally:
                embedder.release.set()
                await asyncio.gather(*application.state.reid_jobs)
            assert (
                await client.put("/v1/targets/bob", headers=HEADERS, content=png())
            ).status_code == 200


@pytest.mark.parametrize("mutation", ["replace", "delete"])
async def test_match_snapshots_reference_before_upload(mutation):
    import asyncio

    import httpx

    class ChangingEmbedder(Embedder):
        calls = 0

        def encode(self, images):
            self.calls += 1
            if mutation == "replace" and self.calls == 2:
                return [(0.0, 1.0) + (0.0,) * 510 for _ in images]
            return super().encode(images)

    application = create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True),
        Detector(),
        embedder=ChangingEmbedder(),
    )
    upload_started = asyncio.Event()
    upload_release = asyncio.Event()

    async def body():
        upload_started.set()
        await upload_release.wait()
        yield png()

    async with application.router.lifespan_context(application):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://test"
        ) as client:
            original = await client.put("/v1/targets/alice", headers=HEADERS, content=png())
            pending = asyncio.create_task(
                client.post("/v1/match", headers=HEADERS, params=META, content=body())
            )
            await asyncio.wait_for(upload_started.wait(), 1)
            if mutation == "replace":
                changed = await client.put("/v1/targets/alice", headers=HEADERS, content=png())
                assert changed.json()["target_version"] != original.json()["target_version"]
            else:
                assert (
                    await client.delete("/v1/targets/alice", headers=HEADERS)
                ).status_code == 204
            upload_release.set()
            response = await pending
            assert response.status_code == 200
            assert response.json()["target_version"] == original.json()["target_version"]
            assert response.json()["matched"]


async def test_admission_applies_across_upload_routes():
    import asyncio

    import httpx

    application = app(max_uploads=1)
    upload_started = asyncio.Event()
    upload_release = asyncio.Event()

    async def body():
        upload_started.set()
        await upload_release.wait()
        yield png()

    async with application.router.lifespan_context(application):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://test"
        ) as client:
            pending = asyncio.create_task(
                client.put("/v1/targets/alice", headers=HEADERS, content=body())
            )
            await asyncio.wait_for(upload_started.wait(), 1)
            try:
                response = await client.put("/v1/targets/bob", headers=HEADERS, content=png())
                assert response.status_code == 429
                response = await client.post(
                    "/v1/detect",
                    headers=HEADERS,
                    content=png(),
                    params={
                        "phone_id": "p",
                        "frame_id": "f",
                        "captured_at": 0,
                        "labels": ["person"],
                    },
                )
                assert response.status_code == 429
            finally:
                upload_release.set()
                assert (await pending).status_code == 200


def test_ambiguous_reference_requires_explicit_box():
    class Ambiguous(Detector):
        def predict(self, images, labels, confidence):
            return [people * 2 for people in super().predict(images, labels, confidence)]

    application = create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True), Ambiguous(), embedder=Embedder()
    )
    with TestClient(application) as client:
        assert client.put("/v1/targets/alice", headers=HEADERS, content=png()).status_code == 422
        assert (
            client.put(
                "/v1/targets/alice", headers=HEADERS, content=png(), params={"box": [0, 0, 10, 10]}
            ).status_code
            == 200
        )


def test_reid_requires_yoloe():
    with pytest.raises(ValueError, match="yoloe"):
        create_app(
            Settings(api_key=KEY, backend="yolo-world", enable_reid=True),
            Detector(), embedder=Embedder(),
        )


@pytest.mark.parametrize("threshold", [-1.1, 1.1, "NaN", "Infinity"])
def test_similarity_threshold_is_validated(threshold):
    with TestClient(app()) as client:
        response = client.post(
            "/v1/match",
            params={**META, "similarity_threshold": threshold},
            content=png(),
            headers=HEADERS,
        )
        assert response.status_code == 422


def test_no_people_returns_no_match_without_encoding_candidates():
    class NoPeople(Detector):
        def predict(self, images, labels, confidence):
            return [[] for _ in images]

    class ReferenceOnly(Embedder):
        calls = 0

        def encode(self, images):
            self.calls += 1
            assert self.calls == 1
            return super().encode(images)

    application = create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True),
        NoPeople(),
        embedder=ReferenceOnly(),
    )
    with TestClient(application) as client:
        assert (
            client.put(
                "/v1/targets/alice", params={"box": [0, 0, 10, 10]}, content=png(), headers=HEADERS
            ).status_code
            == 200
        )
        response = client.post("/v1/match", params=META, content=png(), headers=HEADERS)
        assert response.status_code == 200
        assert response.json()["candidates"] == []
        assert response.json()["matched"] is False


async def test_detect_and_match_phone_ids_cannot_replace_each_other():
    import asyncio

    import httpx

    application = app()
    async with application.router.lifespan_context(application):
        application.state.worker.batch_wait = 0.2
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://test"
        ) as client:
            assert (
                await client.put(
                    "/v1/targets/alice",
                    headers=HEADERS,
                    content=png(),
                    params={"box": [0, 0, 10, 10]},
                )
            ).status_code == 200
            matching = asyncio.create_task(
                client.post(
                    "/v1/match", headers=HEADERS, content=png(), params={**META, "phone_id": "p"}
                )
            )
            async with asyncio.timeout(1):
                while not application.state.worker.pending:
                    await asyncio.sleep(0.001)
            detecting = await client.post(
                "/v1/detect",
                headers=HEADERS,
                content=png(),
                params={
                    "phone_id": "match:p",
                    "frame_id": "f",
                    "captured_at": 0,
                    "labels": ["person"],
                },
            )
            assert detecting.status_code == 200
            result = await matching
            assert result.status_code == 200, result.text


def test_authenticated_reference_health():
    with TestClient(app()) as client:
        assert client.get("/v1/targets/alice").status_code == 401
        assert client.get("/v1/targets/alice", headers=HEADERS).status_code == 404
        version = client.put("/v1/targets/alice", content=png(), headers=HEADERS).json()
        assert client.get("/v1/targets/alice", headers=HEADERS).json() == version
        client.app.state.worker.closed = True
        assert client.get("/v1/targets/alice", headers=HEADERS).status_code == 503
