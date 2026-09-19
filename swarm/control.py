"""Operator sessions and private inference configuration, without model dependencies."""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import math
import os
import secrets
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit
from typing import TYPE_CHECKING
from pathlib import Path

if TYPE_CHECKING:
    from .hub import Hub

from fastapi import FastAPI, HTTPException, Request, WebSocket, Response


@dataclass(frozen=True)
class Settings:
    inference_url: str = field(default_factory=lambda: os.getenv('SWARM_INFERENCE_URL', '').rstrip('/'))
    inference_key: str = field(default_factory=lambda: os.getenv('SWARM_INFERENCE_API_KEY', ''))
    bridge_key: str = field(default_factory=lambda: os.getenv('SWARM_BRIDGE_KEY', ''))
    operator_code: str = field(default_factory=lambda: os.getenv('SWARM_OPERATOR_CODE', '') or secrets.token_urlsafe(18))
    hub_url: str = field(default_factory=lambda: os.getenv('SWARM_HUB_URL', 'http://127.0.0.1:8000').rstrip('/'))
    max_phones: int = field(default_factory=lambda: int(os.getenv('SWARM_MAX_PHONES', '64')))

    def __post_init__(self) -> None:
        if not 1 <= self.max_phones <= 256:
            raise ValueError('SWARM_MAX_PHONES must be between 1 and 256')
        for url in (self.inference_url, self.hub_url):
            if not url:
                continue
            parsed = urlsplit(url)
            private = parsed.hostname == 'localhost'
            try:
                private = private or ipaddress.ip_address(parsed.hostname or '').is_private
            except ValueError:
                pass
            if parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise ValueError('Service URLs must not contain credentials, query, or fragment')
            if parsed.scheme != 'https' and not (parsed.scheme == 'http' and private):
                raise ValueError('Service URLs require HTTPS or a private IP address')

    @property
    def enabled(self) -> bool:
        return bool(self.inference_url and self.inference_key and self.bridge_key)


class Auth:
    cookie = 'swarm_operator'

    def __init__(self, settings: Settings):
        self.settings = settings
        self.secret = secrets.token_bytes(32)

    def token(self) -> str:
        expires = str(int(time.time()) + 12 * 3600)
        return expires + '.' + hmac.new(self.secret, expires.encode(), hashlib.sha256).hexdigest()

    def operator(self, request: Request | WebSocket) -> bool:
        token = request.cookies.get(self.cookie, '')
        try:
            expires, signature = token.split('.')
            expected = hmac.new(self.secret, expires.encode(), hashlib.sha256).hexdigest()
            return int(expires) > time.time() and hmac.compare_digest(expected, signature)
        except (ValueError, TypeError):
            return False

    @staticmethod
    def same_origin(request: Request | WebSocket) -> bool:
        origin = request.headers.get('origin')
        if not origin:
            return isinstance(request, Request)
        parsed = urlsplit(origin)
        scheme = 'https' if request.url.scheme in ('https', 'wss') else 'http'
        return parsed.scheme == scheme and parsed.netloc == request.headers.get('host')

    def bridge(self, request: Request | WebSocket) -> bool:
        key = self.settings.bridge_key
        return bool(key) and hmac.compare_digest(request.headers.get('authorization', '').encode(), f'Bearer {key}'.encode())

    def require_bridge(self, request: Request | WebSocket) -> None:
        if not self.bridge(request):
            raise HTTPException(401, 'bridge authentication required')

    def require_operator(self, request: Request | WebSocket) -> None:
        if not self.operator(request):
            raise HTTPException(401, 'operator authentication required')
        if not self.same_origin(request):
            raise HTTPException(403, 'same-origin request required')


def install_routes(app: FastAPI, hub: Hub, auth: Auth) -> None:
    """Install controls separately from frame routing; model waits never lock frame state."""
    import asyncio
    import httpx
    from pydantic import BaseModel, Field, ConfigDict

    class Threshold(BaseModel):
        model_config = ConfigDict(allow_inf_nan=False, strict=True)
        threshold: float = Field(ge=-1, le=1)

    gate = asyncio.Lock()
    status_value = 'unavailable' if auth.settings.enabled else 'disabled'
    status_at = 0.0

    def state() -> dict:
        available = status_value
        if available == 'available' and time.monotonic() - status_at > 10:
            available = 'unavailable'
        return {'searchRevision': hub.search.revision, 'targetVersion': hub.search.target_version,
                'threshold': hub.search.threshold, 'phase': hub.phase,
                'active': auth.settings.enabled and hub.phase == 'search' and bool(hub.search.target_version),
                'status': available, 'enabled': auth.settings.enabled,
                'referenceAvailable': bool(hub.search.target_version),
                **hub.search.visual_context(time.time() * 1000)}

    hub.search_state = state

    @app.get('/api/session')
    async def session(request: Request):
        return {'authenticated': auth.operator(request)}

    @app.post('/api/session')
    async def login(request: Request, response: Response):
        if not auth.same_origin(request):
            raise HTTPException(403, 'same-origin request required')
        body = await request.json()
        code = body.get('code') if isinstance(body, dict) else None
        if not isinstance(code, str) or len(code) > 256 or not hmac.compare_digest(code.encode(), auth.settings.operator_code.encode()):
            raise HTTPException(401, 'invalid operator code')
        response.set_cookie(auth.cookie, auth.token(), httponly=True, samesite='strict',
                            secure=request.url.scheme == 'https', max_age=12 * 3600)
        return {'authenticated': True}

    @app.delete('/api/session')
    async def logout(request: Request, response: Response):
        auth.require_operator(request)
        response.delete_cookie(auth.cookie)
        return {'authenticated': False}

    @app.get('/api/search')
    async def search(request: Request):
        if not auth.bridge(request) and not auth.operator(request):
            raise HTTPException(401, 'authentication required')
        hub.search.expire(time.time() * 1000)
        return state()

    async def upload(request: Request) -> bytes:
        body = bytearray()
        try:
            async with asyncio.timeout(10):
                async for part in request.stream():
                    body.extend(part)
                    if len(body) > 8 * 1024 * 1024:
                        raise HTTPException(413, 'reference image too large')
        except TimeoutError:
            raise HTTPException(408, 'reference upload timed out')
        return bytes(body)

    async def worker(method: str, path: str, *, data: bytes = b'', params=None) -> dict:
        if not auth.settings.enabled:
            raise HTTPException(503, 'inference disabled')
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                result = await client.request(method, auth.settings.inference_url + path, params=params, content=data,
                    headers={'Authorization': f'Bearer {auth.settings.inference_key}', 'Content-Type': 'image/jpeg'})
                if result.status_code >= 400:
                    raise HTTPException(result.status_code, 'inference request failed')
                return result.json() if result.content else {}
        except (httpx.HTTPError, ValueError) as error:
            raise HTTPException(503, 'inference unavailable') from error

    @app.post('/api/search/reference/people')
    async def people(request: Request):
        auth.require_operator(request)
        if gate.locked():
            raise HTTPException(429, 'reference control busy')
        async with gate:
            data = await upload(request)
            return await worker('POST', '/v1/detect', data=data, params=[('phone_id', 'reference'),
                ('frame_id', secrets.token_hex(8)), ('captured_at', str(time.time())), ('labels', 'person')])

    @app.put('/api/search/reference')
    async def reference(request: Request):
        nonlocal status_value, status_at
        auth.require_operator(request)
        boxes = request.query_params.getlist('box')
        if len(boxes) == 1:
            boxes = boxes[0].split(',')
        try:
            if len(boxes) != 4 or not all(math.isfinite(float(x)) for x in boxes):
                raise ValueError()
        except ValueError:
            raise HTTPException(422, 'box requires four finite pixel coordinates')
        if gate.locked():
            raise HTTPException(429, 'reference control busy')
        async with gate:
            hub.search.set_reference(None)
            revision = hub.search.revision
            await hub.enter_real_search()
            status_value = 'unavailable' if auth.settings.enabled else 'disabled'
            await hub.clear_detection_overlays()
            data = await upload(request)
            if hub.search.revision != revision:
                raise HTTPException(409, 'search changed during upload')
            result = await worker('PUT', '/v1/targets/active', data=data, params=[('box', x) for x in boxes])
            if hub.search.revision != revision:
                raise HTTPException(409, 'search changed during upload')
            version = result.get('target_version')
            if not isinstance(version, str) or not 1 <= len(version) <= 128:
                raise HTTPException(502, 'invalid target version')
            hub.search.set_reference(version)
            status_value, status_at = 'available', time.monotonic()
            await hub.clear_detection_overlays()
            return state()

    @app.delete('/api/search/reference')
    async def clear(request: Request):
        nonlocal status_value
        auth.require_operator(request)
        hub.search.set_reference(None)
        status_value = 'unavailable' if auth.settings.enabled else 'disabled'
        # Take the gate before awaiting overlays so registration cannot overtake deletion.
        async with gate:
            await hub.clear_detection_overlays()
            if auth.settings.enabled:
                try:
                    await worker('DELETE', '/v1/targets/active')
                except HTTPException as error:
                    if error.status_code != 404:
                        raise
        return state()

    @app.put('/api/search/threshold')
    async def threshold(request: Request):
        auth.require_operator(request)
        from pydantic import ValidationError
        try:
            body = Threshold.model_validate(await request.json())
        except (ValidationError, ValueError):
            raise HTTPException(422, 'invalid threshold')
        hub.search.set_threshold(body.threshold)
        await hub.clear_detection_overlays()
        return state()

    @app.post('/api/search/confirm')
    async def confirm(request: Request):
        auth.require_operator(request)
        from pydantic import ValidationError

        class Confirmation(BaseModel):
            model_config = ConfigDict(strict=True, extra='forbid')
            phoneId: str = Field(min_length=1)
            streamId: str = Field(min_length=1, max_length=128)
            seq: int = Field(ge=0)
            searchRevision: str = Field(min_length=1, max_length=128)

        try:
            body = Confirmation.model_validate(await request.json())
        except (ValidationError, ValueError):
            raise HTTPException(422, 'invalid sighting identity')
        if hub.phase != 'search' or not hub.search.confirm(body.phoneId, body.streamId, body.seq, body.searchRevision):
            raise HTTPException(409, 'sighting expired or search changed')
        hub.target.remove()
        hub.mission_complete = False
        confirmation = hub.search.confirmation
        published = await hub.set_phase('found', confirmed_visual=True)
        if not published or hub.search.confirmation is not confirmation:
            raise HTTPException(409, 'confirmation superseded by newer search state')
        hub.planner.note('Operator confirmed visual sighting; target location unknown', body.phoneId)
        return state()

    @app.post('/api/search/rehearsal')
    async def rehearsal(request: Request):
        auth.require_operator(request)
        await clear(request)
        hub.target.remove()
        hub.search.mode = 'rehearsal'
        hub.mission_complete = False
        if not await hub.set_phase('search'):
            raise HTTPException(409, 'rehearsal superseded by newer search state')
        return state()

    @app.post('/api/search/status')
    async def status(request: Request):
        nonlocal status_value, status_at
        auth.require_bridge(request)
        body = await request.json()
        if body.get('searchRevision') != hub.search.revision:
            raise HTTPException(409, 'search changed')
        value = body.get('status')
        if value not in ('available', 'unavailable', 'reference_unavailable'):
            raise HTTPException(422, 'invalid status')
        status_value, status_at = value, time.monotonic()
        if value == 'reference_unavailable':
            hub.search.set_reference(None)
            await hub.clear_detection_overlays()
        return state()


def load_env(path: Path = Path(__file__).resolve().parent.parent / ".env") -> None:
    """Minimal .env reader (KEY=VALUE lines); real environment variables win."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))

