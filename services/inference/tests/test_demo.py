from fastapi.testclient import TestClient
from test_person_api import KEY, Detector, Embedder, png

from beacon.api import Settings, create_app

CODE = "demo-access-code-12345"


def demo_app():
    return create_app(
        Settings(api_key=KEY, backend="yoloe", enable_reid=True, demo_code=CODE),
        Detector(),
        embedder=Embedder(),
    )


def test_demo_disabled_by_default():
    with TestClient(create_app(Settings(api_key=KEY), Detector())) as client:
        assert client.get("/demo").status_code == 404
        assert client.post("/demo/login", json={"code": CODE}).status_code == 404


def test_demo_cookie_is_scoped_and_matches_real_http_flow():
    with TestClient(demo_app()) as client:
        assert client.get("/demo").status_code == 200
        assert KEY not in client.get("/demo").text
        assert client.get("/demo/session").status_code == 401
        assert client.post("/demo/login", json={"code": "wrong"}).status_code == 401
        login = client.post("/demo/login", json={"code": CODE})
        assert login.status_code == 200
        assert "httponly" in login.headers["set-cookie"].lower()
        session = client.get("/demo/session").json()
        target = session["target_id"]
        image_headers = {"Content-Type": "image/png"}
        assert (
            client.put(f"/v1/targets/{target}", content=png(), headers=image_headers).status_code
            == 200
        )
        params = dict(
            target_id=target,
            phone_id=session["phone_id"],
            frame_id="1",
            captured_at=1,
            similarity_threshold=0.7,
        )
        match = client.post("/v1/match", params=params, content=png(), headers=image_headers)
        assert match.status_code == 200, match.text
        assert match.json()["matched"]
        assert (
            client.put("/v1/targets/someone-else", content=png(), headers=image_headers).status_code
            == 401
        )
        params["phone_id"] = "someone-else"
        assert (
            client.post(
                "/v1/match", params=params, content=png(), headers=image_headers
            ).status_code
            == 401
        )
        assert client.delete(f"/v1/targets/{target}").status_code == 204


def test_demo_rejects_cross_origin_and_tampered_cookie():
    with TestClient(demo_app()) as client:
        assert (
            client.post(
                "/demo/login", json={"code": CODE}, headers={"Origin": "https://evil.example"}
            ).status_code
            == 403
        )
        assert client.post("/demo/login", json={"code": CODE}).status_code == 200
        session = client.get("/demo/session").json()
        assert (
            client.delete(
                f"/v1/targets/{session['target_id']}", headers={"Origin": "https://evil.example"}
            ).status_code
            == 401
        )
        client.cookies.clear()
        client.cookies.set("swarm_demo", "invalid.99999999999.fake")
        assert client.get("/demo/session").status_code == 401


def test_demo_https_cookie_and_expiry(monkeypatch):
    import beacon.demo as demo

    with TestClient(demo_app(), base_url="https://testserver") as client:
        login = client.post("/demo/login", json={"code": CODE})
        assert "; Secure" in login.headers["set-cookie"]
        current = demo.time()
        monkeypatch.setattr(demo, "time", lambda: current + 9 * 3600)
        assert client.get("/demo/session").status_code == 401
