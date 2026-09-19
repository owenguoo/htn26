"""Opt-in camera demo with signed, narrowly scoped browser sessions."""

import hashlib
import hmac
import secrets
from pathlib import Path
from time import time
from typing import TYPE_CHECKING
from uuid import uuid4

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

if TYPE_CHECKING:
    from beacon.api import Settings

COOKIE = "swarm_demo"
TTL = 8 * 3600
ASSETS = Path(__file__).with_name("static")


def same_origin(request: Request) -> bool:
    origin = request.headers.get("origin")
    return origin is None or origin == str(request.base_url).rstrip("/")


def signature(payload: str, settings: "Settings") -> str:
    return hmac.new(
        settings.api_key.get_secret_value().encode(), payload.encode(), hashlib.sha256
    ).hexdigest()


def session_id(request: Request, settings: "Settings") -> str | None:
    if settings.demo_code is None or not same_origin(request):
        return None
    token = request.cookies.get(COOKIE, "")
    if len(token) > 200:
        return None
    try:
        identity, expiry, supplied = token.split(".")
        if len(identity) != 32 or any(c not in "0123456789abcdef" for c in identity):
            return None
        if int(expiry) <= time():
            return None
        if not secrets.compare_digest(
            signature(f"{identity}.{expiry}", settings).encode(), supplied.encode()
        ):
            return None
        return identity
    except ValueError:
        return None


def authenticate_demo(request: Request, settings: "Settings") -> bool:
    identity = session_id(request, settings)
    if identity is None:
        return False
    target = f"demo_{identity}"
    if request.url.path == f"/v1/targets/{target}":
        return request.method in {"PUT", "DELETE"}
    if request.method == "POST" and request.query_params.get("phone_id") == identity:
        if request.url.path == "/v1/detect":
            return request.query_params.getlist("labels") == ["person"]
        if request.url.path == "/v1/match":
            return request.query_params.get("target_id") == target
    return False


class Login(BaseModel):
    code: str = Field(max_length=128)


def add_demo_routes(app: FastAPI, settings: "Settings") -> None:
    if settings.demo_code is None:
        return
    if settings.backend != "yoloe" or not settings.enable_reid:
        raise ValueError("The camera demo requires YOLOE and person matching")

    @app.middleware("http")
    async def private_responses(request: Request, call_next):
        response = await call_next(request)
        response.headers.update(
            {
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "Permissions-Policy": "camera=(self), microphone=()",
                "Content-Security-Policy": (
                    "default-src 'self'; script-src 'self'; style-src 'self'; "
                    "img-src 'self' blob: data:; media-src 'self' blob:; "
                    "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"
                ),
            }
        )
        return response

    @app.get("/demo", include_in_schema=False)
    async def page():
        return FileResponse(ASSETS / "demo.html")

    @app.get("/demo/assets/{name}", include_in_schema=False)
    async def asset(name: str):
        if name not in {"demo.css", "demo.js"}:
            raise HTTPException(404)
        return FileResponse(ASSETS / name)

    @app.post("/demo/login", include_in_schema=False)
    async def login(body: Login, request: Request, response: Response):
        if not same_origin(request):
            raise HTTPException(403, "Open the demo directly in your browser")
        if not secrets.compare_digest(
            body.code.encode(), settings.demo_code.get_secret_value().encode()
        ):
            raise HTTPException(401, "Incorrect access code")
        identity = session_id(request, settings) or uuid4().hex
        payload = f"{identity}.{int(time()) + TTL}"
        response.set_cookie(
            COOKIE,
            f"{payload}.{signature(payload, settings)}",
            max_age=TTL,
            httponly=True,
            secure=request.url.scheme == "https",
            samesite="strict",
        )
        return {"status": "connected"}

    @app.get("/demo/session", include_in_schema=False)
    async def session(request: Request):
        identity = session_id(request, settings)
        if identity is None:
            raise HTTPException(401, "Enter the demo access code")
        target = app.state.targets.get(f"demo_{identity}")
        return {
            "phone_id": identity,
            "target_id": f"demo_{identity}",
            "target_version": target.version if target else None,
        }
