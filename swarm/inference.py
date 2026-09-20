"""Bounded latest-frame bridge. Run with python -m swarm.inference."""
from __future__ import annotations

import asyncio
import logging
from collections import deque
from contextlib import suppress

import httpx
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from .control import Settings, load_env
from .detection import DetectionResult, captured_at_seconds, normalize_box
from .protocol import now_ms, unpack

log = logging.getLogger(__name__)


class Bridge:
    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        self.settings, self.client = settings, client
        self.state: dict = {}
        self.pending: dict[str, tuple[dict, bytes]] = {}
        self.ready: deque[str] = deque()
        self.busy: set[str] = set()
        self.wake = asyncio.Event()
        self.backoff_until = 0.0
        self.objects_checked: dict[str, float] = {}

    @property
    def headers(self) -> dict[str, str]:
        return {'Authorization': f'Bearer {self.settings.bridge_key}'}

    def clear(self) -> None:
        self.pending.clear()
        self.ready.clear()
        self.objects_checked.clear()

    def offer(self, packet: bytes) -> None:
        header, jpeg = unpack(packet)
        phone = header.get('phoneId')
        if (not isinstance(phone, str) or not (self.state.get('active') or self.state.get('hazardsActive'))
                or header.get('searchRevision') != self.state.get('searchRevision')):
            return
        if phone not in self.pending and len(set(self.pending) | self.busy) >= self.settings.max_phones and phone not in self.busy:
            return
        if phone not in self.pending and phone not in self.busy:
            self.ready.append(phone)
        self.pending[phone] = (header, jpeg)
        self.wake.set()

    def take(self) -> tuple[dict, bytes] | None:
        if not self.ready:
            self.wake.clear()
            return None
        phone = self.ready.popleft()
        self.busy.add(phone)
        return self.pending.pop(phone)

    def release(self, phone: str) -> None:
        self.busy.discard(phone)
        if phone in self.pending:
            self.ready.append(phone)
            self.wake.set()

    async def status(self, revision: str, status: str) -> None:
        with suppress(httpx.HTTPError):
            await self.client.post(self.settings.hub_url + '/api/search/status', headers=self.headers,
                                   json={'searchRevision': revision, 'status': status})

    async def health(self) -> None:
        state = self.state.copy()
        revision = state.get('searchRevision')
        if not revision or not state.get('enabled') or (
                not state.get('targetVersion') and state.get('status') == 'reference_unavailable'):
            return
        value = 'unavailable'
        try:
            people = state.get('people') or [{'id': 'active', 'version': state.get('targetVersion')}]
            responses = await asyncio.gather(*(self.client.get(
                self.settings.inference_url + '/v1/targets/' + person['id'], timeout=2,
                headers=self.settings.inference_headers) for person in people))
            value = 'available'
            for person, response in zip(people, responses):
                if response.status_code == 404:
                    if person['version']:
                        value = 'reference_unavailable'
                else:
                    response.raise_for_status()
                    if person['version'] and response.json()['target_version'] != person['version']:
                        value = 'reference_unavailable'
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            value = 'unavailable'
        # A slow probe belongs only to the search generation it started with.
        if self.state.get('searchRevision') == revision:
            await self.status(revision, value)

    async def poll(self) -> None:
        while True:
            try:
                response = await self.client.get(self.settings.hub_url + '/api/search', headers=self.headers)
                response.raise_for_status()
                state = response.json()
                if state.get('searchRevision') != self.state.get('searchRevision') or not (state.get('active') or state.get('hazardsActive')):
                    self.clear()
                self.state = state
                await self.health()
            except (httpx.HTTPError, ValueError):
                self.state = {}
                self.clear()
            await asyncio.sleep(1)

    async def receive(self) -> None:
        url = self.settings.hub_url.replace('https://', 'wss://').replace('http://', 'ws://') + '/ws/frames?fps=5'
        delay = 1
        while True:
            try:
                async with connect(url, additional_headers=self.headers, max_queue=1, max_size=9 * 1024 * 1024) as ws:
                    delay = 1
                    async for packet in ws:
                        if isinstance(packet, bytes):
                            with suppress(ValueError, TypeError):
                                self.offer(packet)
            except (OSError, WebSocketException) as error:
                # Reconnect independently of model requests so phones continue draining.
                log.warning('Frame connection unavailable: %s', type(error).__name__)
            self.clear()
            await asyncio.sleep(delay)
            delay = min(10, delay * 2)

    async def process(self, header: dict, jpeg: bytes) -> None:
        if self.state.get('hazardsActive'):
            # Isolate hazard failures so person matching keeps its own health and retry behavior.
            await asyncio.gather(self.process_person(header, jpeg), self.process_objects(header, jpeg))
        else:
            await self.process_person(header, jpeg)

    async def process_objects(self, header: dict, jpeg: bytes) -> None:
        now = now_ms()
        self.objects_checked = {k: t for k, t in self.objects_checked.items() if now - t < 1000}
        if header['phoneId'] in self.objects_checked:
            return
        self.objects_checked[header['phoneId']] = now
        revision = self.state.get('searchRevision')
        if header.get('searchRevision') != revision or not 0 <= now_ms() - header['t'] <= 1500:
            return
        try:
            params = dict(phone_id=header['streamId'], frame_id=str(header['seq']),
                          captured_at=captured_at_seconds(header['t']), labels=['chair', 'person'], confidence=.25)
            response = await self.client.post(self.settings.inference_url + '/v1/detect', params=params,
                content=jpeg, headers={**self.settings.inference_headers, 'Content-Type': 'image/jpeg'})
            response.raise_for_status()
            result = response.json()
            if any(result.get(k) != params[k] for k in ('phone_id', 'frame_id', 'captured_at')):
                raise ValueError('hazard frame identity mismatch')
            if (result['width'], result['height']) != (header['width'], header['height']):
                raise ValueError('hazard dimensions mismatch')
            if (self.state.get('searchRevision') != revision or not self.state.get('hazardsActive')
                    or now_ms() - header['t'] > 1500):
                return
            body = {k: header[k] for k in ('phoneId', 'streamId', 'seq', 't', 'width', 'height', 'searchRevision')}
            body['detections'] = [d for d in result['detections']
                                  if (d['label'] == 'chair' and d['score'] >= .6)
                                  or d['label'] == 'person']
            callback = await self.client.post(self.settings.hub_url + '/api/hazards', headers=self.headers, json=body)
            if callback.status_code != 409:
                callback.raise_for_status()
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as error:
            log.warning('Object detection unavailable: %s', type(error).__name__)

    async def unavailable(self, revision: str) -> None:
        """A reference the worker no longer holds: stop offering frames until the hub re-registers."""
        await self.status(revision, 'reference_unavailable')
        self.state = {}
        self.clear()

    async def match(self, person: dict, header: dict, jpeg: bytes, threshold: float,
                    revision: str) -> tuple[list[dict], dict] | None:
        """Match one frame against one person on the roster. None means give up on this frame."""
        params = dict(target_id=person['id'], phone_id=header['streamId'], frame_id=str(header['seq']),
                      captured_at=captured_at_seconds(header['t']), similarity_threshold=threshold)
        response = await self.client.post(self.settings.inference_url + '/v1/match', params=params, content=jpeg,
                                         headers={**self.settings.inference_headers, 'Content-Type': 'image/jpeg'})
        if response.status_code in (409, 504):
            return None
        if response.status_code == 429:
            self.backoff_until = asyncio.get_running_loop().time() + 1
            return None
        if response.status_code == 404:
            await self.unavailable(revision)
            return None
        response.raise_for_status()
        result = response.json()
        if result['target_version'] != person['version']:
            await self.unavailable(revision)
            return None
        if (result['target_id'] != person['id'] or result['phone_id'] != params['phone_id']
                or result['frame_id'] != params['frame_id'] or result['captured_at'] != params['captured_at']
                or (result['width'], result['height']) != (header['width'], header['height'])):
            raise ValueError('worker identity or dimensions mismatch')
        boxes = [normalize_box(tuple(c['box']), header['width'], header['height']) |
                 {'label': 'person', 'detectionScore': c['detection_score'], 'similarity': c['similarity'],
                  'targetId': person['id']}
                 for c in result['candidates']]
        return boxes, result

    async def process_person(self, header: dict, jpeg: bytes) -> None:
        """One frame, matched against everybody on the reference roster. The boxes come back
        tagged with the person they matched, so a frame holding two of them says so."""
        state = self.state.copy()
        revision = state.get('searchRevision', '')
        people = state.get('people') or []
        if not state.get('active') or header.get('searchRevision') != revision or not people:
            return
        if not 0 <= now_ms() - header['t'] <= 1500:
            return
        boxes: list[dict] = []
        queue_ms = inference_ms = matching_ms = 0.0
        for person in people:
            matched = await self.match(person, header, jpeg, state['threshold'], revision)
            if matched is None:
                return
            found, result = matched
            boxes += found
            queue_ms = max(queue_ms, result['queue_ms'])   # one queue wait, not one per person
            inference_ms += result['inference_ms']
            matching_ms += result['matching_ms']
            if self.state.get('searchRevision') != revision or not self.state.get('active'):
                return
        boxes.sort(key=lambda b: -b['similarity'])
        body = DetectionResult.model_validate({k: header[k] for k in ('phoneId', 'streamId', 'seq', 't', 'width', 'height', 'searchRevision')} |
                dict(targetVersion=state['targetVersion'], boxes=boxes[:100], queueMs=queue_ms,
                     inferenceMs=inference_ms, matchingMs=matching_ms))
        if self.state.get('searchRevision') != revision or not self.state.get('active') or now_ms() - body.t > 1500:
            return
        callback = await self.client.post(self.settings.hub_url + '/api/detections', headers=self.headers, json=body.model_dump())
        if callback.status_code != 409:
            callback.raise_for_status()
        await self.status(revision, 'available')

    async def worker(self) -> None:
        while True:
            await self.wake.wait()
            delay = self.backoff_until - asyncio.get_running_loop().time()
            if delay > 0:
                await asyncio.sleep(delay)
            item = self.take()
            if item is None:
                continue
            header, jpeg = item
            try:
                await self.process(header, jpeg)
            except (httpx.HTTPError, ValueError, KeyError, TypeError):
                await self.status(self.state.get('searchRevision', ''), 'unavailable')
                self.backoff_until = asyncio.get_running_loop().time() + 1
            finally:
                self.release(header['phoneId'])

    async def run(self) -> None:
        async with asyncio.TaskGroup() as tasks:
            tasks.create_task(self.poll())
            tasks.create_task(self.receive())
            for _ in range(4):
                tasks.create_task(self.worker())


async def main() -> None:
    load_env()
    settings = Settings()
    if not settings.enabled:
        raise SystemExit('Inference disabled: configure SWARM_INFERENCE_URL, SWARM_INFERENCE_API_KEY, SWARM_BRIDGE_KEY')
    async with httpx.AsyncClient(timeout=5, limits=httpx.Limits(max_connections=8)) as client:
        await Bridge(settings, client).run()


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
