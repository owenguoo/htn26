"""Browser controls and private inference configuration, without model dependencies."""
from __future__ import annotations

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

from fastapi import FastAPI, HTTPException, Request, WebSocket

from .detection import MAX_PEOPLE

# Detection keeps running after the first person is found, because there may be others.
# Mirrors hub.SEARCH_PHASES, which cannot be imported here (hub imports this module).
SEARCHING = ('search', 'found')


@dataclass(frozen=True)
class Settings:
    inference_url: str = field(default_factory=lambda: os.getenv('SWARM_INFERENCE_URL', '').rstrip('/'))
    inference_key: str = field(default_factory=lambda: os.getenv('SWARM_INFERENCE_API_KEY', ''))
    baseten_key: str = field(default_factory=lambda: os.getenv('SWARM_BASETEN_API_KEY', ''), repr=False)
    bridge_key: str = field(default_factory=lambda: os.getenv('SWARM_BRIDGE_KEY', ''))
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
    def inference_headers(self) -> dict[str, str]:
        if self.baseten_key:
            return {'Authorization': f'Bearer {self.baseten_key}',
                    'X-Swarm-Api-Key': self.inference_key, 'X-Swarm-Content-Type': 'image/jpeg'}
        return {'Authorization': f'Bearer {self.inference_key}'}

    @property
    def enabled(self) -> bool:
        return bool(self.inference_url and self.inference_key and self.bridge_key)


class Auth:
    def __init__(self, settings: Settings):
        self.settings = settings

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

    def require_same_origin(self, request: Request | WebSocket) -> None:
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
                'active': auth.settings.enabled and hub.phase in SEARCHING and bool(hub.search.target_version),
                'hazardsActive': auth.settings.enabled and hub.phase in SEARCHING,
                'status': available, 'enabled': auth.settings.enabled,
                'referenceAvailable': bool(hub.search.target_version),
                **hub.search.visual_context(time.time() * 1000)}

    hub.search_state = state

    @app.get('/api/search')
    async def search(request: Request):
        if not auth.bridge(request):
            auth.require_same_origin(request)
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
                    headers={**auth.settings.inference_headers, 'Content-Type': 'image/jpeg'})
                if result.status_code >= 400:
                    raise HTTPException(result.status_code, 'inference request failed')
                return result.json() if result.content else {}
        except (httpx.HTTPError, ValueError) as error:
            raise HTTPException(503, 'inference unavailable') from error

    @app.post('/api/search/reference/people')
    async def people(request: Request):
        auth.require_same_origin(request)
        if gate.locked():
            raise HTTPException(429, 'reference control busy')
        async with gate:
            data = await upload(request)
            return await worker('POST', '/v1/detect', data=data, params=[('phone_id', 'reference'),
                ('frame_id', secrets.token_hex(8)), ('captured_at', str(time.time())), ('labels', 'person')])

    @app.put('/api/search/reference')
    async def reference(request: Request):
        """Register a reference photo. `add=1` puts another person on the roster and every frame
        is then matched against all of them; without it this replaces the roster, which also
        starts the search over with a clean probability map."""
        nonlocal status_value, status_at
        auth.require_same_origin(request)
        boxes = request.query_params.getlist('box')
        if len(boxes) == 1:
            boxes = boxes[0].split(',')
        try:
            if len(boxes) != 4 or not all(math.isfinite(float(x)) for x in boxes):
                raise ValueError()
        except ValueError:
            raise HTTPException(422, 'box requires four finite pixel coordinates')
        adding = request.query_params.get('add') in ('1', 'true') and bool(hub.search.people)
        label = request.query_params.get('label')
        if adding and len(hub.search.people) >= MAX_PEOPLE:
            raise HTTPException(409, f'at most {MAX_PEOPLE} people can be searched for at once')
        if gate.locked():
            raise HTTPException(429, 'reference control busy')
        async with gate:
            if not adding:
                hub.search.set_reference(None)
            revision = hub.search.revision
            if not adding:
                # A fresh roster starts a fresh search; adding somebody must keep the map and
                # everything the swarm has already learned about the people on it.
                await hub.enter_real_search()
                status_value = 'unavailable' if auth.settings.enabled else 'disabled'
            await hub.clear_detection_overlays()
            data = await upload(request)
            if hub.search.revision != revision:
                raise HTTPException(409, 'search changed during upload')
            person_id = hub.search.next_person_id
            result = await worker('PUT', f'/v1/targets/{person_id}', data=data,
                                  params=[('box', x) for x in boxes])
            if hub.search.revision != revision or hub.search.next_person_id != person_id:
                raise HTTPException(409, 'search changed during upload')
            version = result.get('target_version')
            if not isinstance(version, str) or not 1 <= len(version) <= 128:
                raise HTTPException(502, 'invalid target version')
            if adding:
                try:
                    hub.search.add_person(version, label)
                except ValueError as error:
                    raise HTTPException(409, str(error)) from error
            else:
                hub.search.set_reference(version)
                if label:
                    hub.search.people[0]['label'] = label.strip()[:60] or hub.search.people[0]['label']
            status_value, status_at = 'available', time.monotonic()
            await hub.clear_detection_overlays()
            return state()

    async def forget(person_ids: list[str]) -> None:
        """Drop references from the worker. A reference that is already gone is not an error."""
        if not auth.settings.enabled:
            return
        for person_id in person_ids:
            try:
                await worker('DELETE', f'/v1/targets/{person_id}')
            except HTTPException as error:
                if error.status_code != 404:
                    raise

    @app.delete('/api/search/reference/{person_id}')
    async def drop_person(person_id: str, request: Request):
        """Stop looking for one person; everybody else on the roster carries on."""
        auth.require_same_origin(request)
        if gate.locked():
            raise HTTPException(429, 'reference control busy')
        async with gate:
            if not hub.search.remove_person(person_id):
                raise HTTPException(404, 'no such person on the roster')
            await hub.clear_detection_overlays()
            await forget([person_id])
        return state()

    @app.delete('/api/search/reference')
    async def clear(request: Request):
        nonlocal status_value
        auth.require_same_origin(request)
        person_ids = [p['id'] for p in hub.search.people] or ['person-1']
        hub.search.set_reference(None)
        status_value = 'unavailable' if auth.settings.enabled else 'disabled'
        # Take the gate before awaiting overlays so registration cannot overtake deletion.
        async with gate:
            await hub.clear_detection_overlays()
            await forget(person_ids)
        return state()

    @app.put('/api/search/threshold')
    async def threshold(request: Request):
        auth.require_same_origin(request)
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
        auth.require_same_origin(request)
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
        # Confirming from 'found' too: the operator confirms each person separately, and the
        # first confirmation already moved the phase on.
        if hub.phase not in SEARCHING or not hub.search.confirm(body.phoneId, body.streamId, body.seq, body.searchRevision):
            raise HTTPException(409, 'sighting expired or search changed')
        hub.target.remove()
        hub.mission_complete = False
        confirmation = hub.search.confirmation
        published = await hub.set_phase('found', confirmed_visual=True)
        if not published or hub.search.confirmation is not confirmation:
            raise HTTPException(409, 'confirmation superseded by newer search state')
        nth = len(hub.search.confirmations)
        hub.planner.note(f'Operator confirmed visual sighting {nth}; target location unknown' if nth > 1
                         else 'Operator confirmed visual sighting; target location unknown', body.phoneId)
        return state()

    @app.post('/api/search/rehearsal')
    async def rehearsal(request: Request):
        auth.require_same_origin(request)
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
