"""Beacon hub: phone sessions, frame routing, and live state for the dashboard.

Run:  uv run python -m swarm.hub [--public-url https://xyz.trycloudflare.com]
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import itertools
import json
import math
import os
import re
import socket
import struct
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, UnidentifiedImageError

import segno
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException
from fastapi.responses import FileResponse, HTMLResponse, Response
from fastapi.staticfiles import StaticFiles

from .detection import FrameSnapshot, SearchState, DetectionResult
from .control import Settings, Auth, install_routes, load_env
from .coverage import Coverage
from .planner import Planner
from .sightings import FOUND_CONF, PERSON_HEIGHT_M, POSSIBLE_CONF, MockDetector, Sightings
from .target import Target
from .protocol import now_ms, pack, unpack

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
CERTS = ROOT / "certs"
ROOM = json.loads((ROOT / "room.json").read_text())

PALETTE = [
    "#4cc9f0", "#f72585", "#b8f35a", "#ffb703", "#9b5de5", "#00f5d4",
    "#fb5607", "#3a86ff", "#ff006e", "#8ac926", "#ffd166", "#06d6a0",
]
STALE_MS = 3000          # no frame for this long → tile shows "stale"
EXTERNAL_POSE_TTL = 5000  # a pose from the positioning service overrides the seat for this long
REAP_AFTER_MS = 30000    # forget disconnected phones after this long
PHASES = ("lobby", "calibrate", "search", "found", "end")  # show flow, driven from /console
SEARCH_PHASES = ("search", "found")  # coverage and candidate detection only run in these
REAL_NEAR_MISS = 0.15   # similarity this far below the match threshold still hints (heatmap only)
PING_TTL_MS = 12000
MESSAGE_TTL_MS = 8000
WORLD_HZ = 2             # how often phones get the shared picture (mini-map, progress)
LOOK_SECONDS = 20        # default time an operator "look" direction holds a phone
GO_SECONDS = 90          # default time a "walk to" order stays active
ARRIVE_M = 1.5           # a phone this close to a walk-to spot has arrived
FOCUS_FPS = 15           # a phone expanded in a console captures and streams this fast
VOICE_MODEL = os.environ.get("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe")
VOICE_RATE = 16000       # phones send 16 kHz mono 16-bit PCM
VOICE_MIN_S = 0.4        # shorter utterances are dropped (coughs, clicks)
VOICE_MAX_S = 12         # longer ones are cut and transcribed in pieces
VOICE_QUIET_MS = 1200    # no audio for this long ends an utterance even without audio_end
CAPTION_SHOW_MS = 8000   # how long a caption stays on screen
FOCUS_INTERVAL_MS = 1000 / FOCUS_FPS


@dataclass
class Phone:
    id: str
    index: int
    name: str = ""
    sim: bool = False
    device: str = ""
    ws: WebSocket | None = None
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    connected: bool = False
    last_seen: float = 0
    # pose inputs
    seat: dict | None = None        # {x, y} in room meters
    heading: float | None = None    # degrees, 0 = facing stage, clockwise
    pitch: float | None = None      # degrees, + = camera tilted up
    calibrated: bool = False
    external_pose: dict | None = None
    gps: dict | None = None          # latest browser geolocation fix
    debug: dict | None = None        # latest diagnostics the phone reported
    hidden: bool = False             # operator hid this feed from the projector
    hud: dict | None = None          # what's on the phone's screen, sent while it's expanded in a console
    build: str = ""                  # version of the page the phone is running (see build_id)
    native: bool = False             # a native app, not the web page: never "old page, reload"
    audio: bytearray = field(default_factory=bytearray)  # current utterance (PCM), until transcribed
    audio_at: float = 0              # when the last audio chunk arrived
    captions: deque = field(default_factory=lambda: deque(maxlen=6))  # {"text", "t"}: what they said
    searched_cells: int = 0          # coverage cells this phone was first to look at
    tilted_since: float | None = None  # when it started pointing at the floor/ceiling
    # latest frame (latest wins, never queued)
    stream_id: str = ""
    frame_pose: dict | None = None
    frame_width: int = 0
    frame_height: int = 0
    frame: bytes | None = None
    frame_seq: int = -1
    frame_t: float = 0              # capture time, server clock
    frame_at: float = 0             # arrival time, server clock
    frames_total: int = 0
    arrivals: deque = field(default_factory=lambda: deque(maxlen=120))  # (arrival ms, bytes)
    latency_ms: float | None = None
    # clock sync: phone_clock - server_clock
    clock_offset: float | None = None
    best_rtt: float = math.inf

    def fps(self, now: float, window_ms: float = 2000) -> float:
        return sum(1 for t, _ in self.arrivals if now - t <= window_ms) * 1000 / window_ms

    def kbps(self, now: float, window_ms: float = 2000) -> float:
        return sum(n for t, n in self.arrivals if now - t <= window_ms) * 8 / window_ms  # bytes/ms → kbit/s

    @property
    def color(self) -> str:
        return PALETTE[self.index % len(PALETTE)]

    def pose(self, now: float) -> dict | None:
        ext = self.external_pose
        if ext and now - ext["t"] < EXTERNAL_POSE_TTL:
            return {k: ext[k] for k in ("x", "y", "heading", "confidence", "source")}
        if self.seat:
            return {
                "x": self.seat["x"], "y": self.seat["y"], "heading": self.heading,
                "confidence": None, "source": "sim" if self.sim else "seat",
            }
        return None

    def summary(self, now: float) -> dict:
        return {
            "id": self.id, "index": self.index, "name": self.name, "color": self.color,
            "sim": self.sim, "device": self.device, "connected": self.connected,
            "pose": self.pose(now), "pitch": self.pitch, "calibrated": self.calibrated,
            "fps": round(self.fps(now), 1), "kbps": round(self.kbps(now)),
            "latencyMs": None if self.latency_ms is None else round(self.latency_ms),
            "stale": self.frame is None or now - self.frame_at > STALE_MS,
            "frames": self.frames_total,
            "debug": self.debug,
            "hidden": self.hidden,
            # Only a browser phone runs "the page"; a native client has its own versioning.
            "oldPage": not self.native and self.build != build_id(),
            "hud": self.hud if self.hud and now - self.hud["t"] < 2000 else None,
            "speaking": now - self.audio_at < 700,
            "caption": (self.captions[-1] | {"ageMs": round(now - self.captions[-1]["t"])})
                       if self.captions and now - self.captions[-1]["t"] < CAPTION_SHOW_MS else None,
            "gps": None if not self.gps else {**self.gps, "ageMs": round(now - self.gps["t"])},
        }

    async def send(self, msg: dict) -> None:
        if not self.ws:
            return
        async with self.send_lock:
            try:
                await self.ws.send_json(msg)
            except Exception:
                pass


class Hub:
    def __init__(self) -> None:
        self.search = SearchState()
        self.phones: dict[str, Phone] = {}
        self.next_index = 1
        self.join_url = ""
        self.coverage = Coverage(ROOM)
        self.planner = Planner(ROOM, self.coverage)
        self.target = Target(ROOM, self.planner.note, lambda: self.search.mode == "rehearsal")
        self.sightings = Sightings(ROOM)        # detections placed in the room and merged
        self.mock_detector = MockDetector(ROOM)  # reports the operator's hidden candidate in rehearsals
        # "search" by default so the hub works without an operator; the show starts at "lobby"
        self.phase = "search"
        self._phase_generation = 0
        self.phase_started = now_ms()
        self.looking_for = ""               # what searchers should look for, shown on phones
        self.pings: list[dict] = []         # {id, x, y, label, t, phones: set | None}
        self.ping_ids = itertools.count(1)
        self.consoles: set = set()          # dashboard/console subscribers, for pushed events
        # operator "look" directions: phone id → {label, until, sent, and compass | heading | point}
        self.directives: dict[str, dict] = {}
        self.directives_cleared: list[str] = []
        self.mission_complete = False       # every responder reached the found candidate
        self.boosted: set[str] = set()      # phones told to capture faster (expanded in a console)
        self.mission = None                 # Mission Control (LLM); created in main()

    # ---- phone lifecycle -------------------------------------------------
    async def register(self, hello: dict, ws: WebSocket) -> Phone:
        pid = str(hello.get("phoneId") or uuid.uuid4())
        phone = self.phones.get(pid)
        if phone is None:
            phone = Phone(id=pid, index=self.next_index)
            self.next_index += 1
            self.phones[pid] = phone
        old = phone.ws
        # Install ownership before awaiting closure so overlapping reconnects keep arrival order.
        phone.stream_id = str(uuid.uuid4())
        phone.frame = None
        phone.frame_seq = -1
        phone.frame_t = phone.frame_at = 0
        phone.frame_pose = None
        phone.frame_width = phone.frame_height = 0
        phone.clock_offset = None
        phone.best_rtt = math.inf
        phone.latency_ms = None
        phone.arrivals.clear()
        self.search.connect(phone.id, phone.stream_id)
        phone.ws = ws
        phone.connected = True
        phone.last_seen = now_ms()
        phone.sim = bool(hello.get("sim"))
        phone.device = "sim" if phone.sim else _device(str(hello.get("ua") or ""))
        phone.name = str(hello.get("name") or "")[:24]
        phone.build = str(hello.get("build") or "")
        phone.native = bool(hello.get("native"))
        if isinstance(hello.get("seat"), dict):
            phone.seat = _seat(hello["seat"])
        if old is not None and old is not ws:
            try:
                await old.close()
            except Exception:
                pass
        return phone

    def disconnect(self, phone: Phone, ws: WebSocket) -> None:
        if phone.ws is ws:
            phone.ws = None
            phone.connected = False
            self.search.disconnect(phone.id, phone.stream_id)
            phone.last_seen = now_ms()

    async def reaper(self) -> None:
        while True:
            await asyncio.sleep(5)
            now = now_ms()
            for pid in [p.id for p in self.phones.values()
                        if not p.connected and now - p.last_seen > REAP_AFTER_MS]:
                del self.phones[pid]

    # ---- inbound -----------------------------------------------------------
    def on_frame(self, phone: Phone, buf: bytes) -> None:
        try:
            header, jpeg = unpack(buf)
        except Exception:
            return
        now = now_ms()
        if header.get("type") == "audio":  # a chunk of speech, not a video frame
            phone.audio += jpeg
            phone.audio_at = now
            if len(phone.audio) >= VOICE_MAX_S * VOICE_RATE * 2:
                self.end_utterance(phone)
            return
        try:
            seq = header.get("seq", phone.frame_seq + 1)
            if isinstance(seq, bool) or not isinstance(seq, int) or not 0 <= seq <= 2**53 - 1 or seq <= phone.frame_seq:
                return
            for key in ("tCapture", "heading", "pitch"):
                if header.get(key) is not None and (isinstance(header[key], bool) or not isinstance(header[key], (int, float))
                                                    or not math.isfinite(header[key])):
                    return
            # Reading image headers avoids pixel decoding on the hub event loop.
            with Image.open(io.BytesIO(jpeg)) as image:
                if image.format != "JPEG":
                    return
                width, height = image.size
                if image.getexif().get(274) in (5, 6, 7, 8):
                    width, height = height, width
            if not 0 < width <= 16384 or not 0 < height <= 16384:
                return
            if any(key in header and (type(header[key]) is not int or header[key] != value)
                   for key, value in (("width", width), ("height", height))):
                return
        except (ValueError, TypeError, OSError, UnidentifiedImageError, Image.DecompressionBombError):
            return
        now = now_ms()
        phone.arrivals.append((now, len(buf)))
        t_phone = header.get("tCapture")
        if t_phone is not None and phone.clock_offset is not None:
            phone.frame_t = t_phone - phone.clock_offset
            lat = max(now - phone.frame_t, 0)
            phone.latency_ms = lat if phone.latency_ms is None else 0.8 * phone.latency_ms + 0.2 * lat
        else:
            phone.frame_t = now
        self._apply_orientation(phone, header)
        phone.frame_pose = phone.pose(now)
        if phone.frame_pose is not None and header.get("heading") is not None:
            phone.frame_pose["heading"] = phone.heading
        phone.frame_width, phone.frame_height = width, height
        phone.frame = jpeg
        phone.frame_seq = seq
        phone.frame_at = now
        phone.frames_total += 1
        self.search.expire(now)
        self.search.record_frame(FrameSnapshot(phone.id, phone.stream_id, seq, phone.frame_t,
                                               width, height, phone.frame_pose))

    def on_message(self, phone: Phone, msg: dict) -> None:
        kind = msg.get("type")
        if kind == "orient":
            self._apply_orientation(phone, msg)
        elif kind == "seat" and isinstance(msg.get("seat"), dict):
            phone.seat = _seat(msg["seat"])
        elif kind == "name":
            phone.name = str(msg.get("name") or "")[:24]
        elif kind == "slam":
            # phone-side world tracking (8th Wall): already in room meters
            self._apply_orientation(phone, msg)
            self.set_external_pose({**msg, "phoneId": phone.id, "source": "slam"})
        elif kind == "audio_end":
            self.end_utterance(phone)
        elif kind == "hud":
            phone.hud = {k: v for k, v in msg.items() if k != "type"} | {"t": now_ms()}
        elif kind == "debug":
            phone.debug = {k: v for k, v in msg.items() if k != "type"}
        elif kind == "gps":
            self._on_gps(phone, msg)
        elif kind == "pong":
            self._on_pong(phone, msg)

    def _apply_orientation(self, phone: Phone, msg: dict) -> None:
        if msg.get("heading") is not None:
            phone.heading = float(msg["heading"]) % 360
        if msg.get("pitch") is not None:
            phone.pitch = float(msg["pitch"])
        if "calibrated" in msg:
            phone.calibrated = bool(msg["calibrated"])

    def _on_gps(self, phone: Phone, msg: dict) -> None:
        try:
            phone.gps = {
                "lat": float(msg["lat"]), "lon": float(msg["lon"]),
                "accuracy": float(msg.get("accuracy") or 0),
                "altitude": msg.get("altitude"), "speed": msg.get("speed"),
                "t": now_ms(),
            }
        except (KeyError, TypeError, ValueError):
            pass

    def _on_pong(self, phone: Phone, msg: dict) -> None:
        t0, tp = msg.get("ts"), msg.get("tp")
        if t0 is None or tp is None:
            return
        rtt = now_ms() - t0
        phone.best_rtt *= 1.05  # let the best sample age out so drift gets corrected
        if rtt <= phone.best_rtt:
            phone.best_rtt = rtt
            phone.clock_offset = tp - (t0 + rtt / 2)

    def set_external_pose(self, body: dict) -> bool:
        phone = self.phones.get(str(body.get("phoneId")))
        if not phone:
            return False
        phone.external_pose = {
            "x": float(body["x"]), "y": float(body["y"]),
            "heading": None if body.get("heading") is None else float(body["heading"]) % 360,
            "confidence": body.get("confidence"),
            "source": str(body.get("source") or "external"),
            "t": now_ms(),
        }
        return True

    async def coverage_loop(self, hz: float = 5) -> None:
        while True:
            now = now_ms()
            viewers = {}
            for p in self.phones.values():
                tilted = p.pitch is not None and abs(p.pitch) > 65
                p.tilted_since = (p.tilted_since or now) if tilted else None
                pose = p.pose(now)
                live = p.connected and p.frame is not None and now - p.frame_at <= STALE_MS
                if live and pose and pose["heading"] is not None:
                    viewers[p.id] = (pose["x"], pose["y"], pose["heading"], p.pitch)
            # Outside a search (lobby, calibrate, end) phones only show where they are:
            # nothing counts as searched and nobody can find the candidate.
            searching = self.phase in SEARCH_PHASES
            if searching:
                for pid, n in self.coverage.update(viewers).items():
                    self.phones[pid].searched_cells += n
                if self.search.mode == "rehearsal" and self.target.pos and not self.target.found_by:  # rehearsal: mock model sees the mock candidate
                    for pid, (x, y, heading, pitch) in viewers.items():
                        if self.search.mode != "rehearsal" or not self.target.pos or self.phase not in SEARCH_PHASES:
                            break
                        boxes = self.mock_detector.detect(x, y, heading, pitch, self.target.pos)
                        if boxes:
                            await self.ingest_detections(self.phones[pid], boxes)
            # responders and phones with an operator "look" direction are not the planner's to steer
            sighting_cmds = self.check_sightings(viewers, now) if searching else []
            busy = self.target.busy() | set(self.directives)
            cmds = self.planner.tick({k: v for k, v in viewers.items() if k not in busy}, now)
            for pid, wx, wy, label in self.planner.walk_requests:  # the planner wants someone to walk
                if pid in self.phones and pid not in busy:
                    self.look([self.phones[pid].index], label, point=(wx, wy), go=True)
            self.planner.walk_requests.clear()
            cmds += self.target.tick(viewers if searching else {}, now)
            for pid in self.target.busy() & set(self.directives):
                del self.directives[pid]  # joining the find team replaces any earlier walk/look order
            cmds += self.directive_tick(now)
            cmds += sighting_cmds
            if cmds:
                await asyncio.gather(*(self.phones[pid].send({"type": "command", **cmd})
                                       for pid, cmd in cmds if pid in self.phones))
            if self.phase == "search" and self.target.found_by:
                await self.set_phase("found")
                if self.mission:
                    self.mission.trigger()  # a find is exactly when the autonomy layer should look
            for p in self.phones.values():
                if p.audio and now - p.audio_at > VOICE_QUIET_MS:
                    self.end_utterance(p)
            done = self.target.complete()
            if done and not self.mission_complete:  # the whole team is on target: stop searching
                self.planner.enabled = False
                released = self.clear_look(None)  # cancel walk/look orders still underway
                self.planner.note("All responders on target: search complete"
                                  + (f", released {', '.join(f'#{n}' for n in released)}" if released else ""))
            self.mission_complete = done
            await asyncio.sleep(1 / hz)

    async def ingest_detections(self, phone: Phone, boxes: list[dict]) -> None:
        """Draw rehearsal detections and add their simulated positions to the heatmap."""
        if self.search.mode != "rehearsal":
            return
        stream_id, seq, revision = phone.stream_id, phone.frame_seq, self.search.revision
        async with phone.send_lock:
            if (self.search.mode != "rehearsal" or phone.stream_id != stream_id
                    or self.search.revision != revision):
                return
            if phone.ws:
                try:
                    await phone.ws.send_json({"type": "command", "cmd": "rehearsal_detections", "boxes": boxes,
                                              "streamId": stream_id, "seq": seq, "searchRevision": revision,
                                              "ttlMs": 1500})
                except (RuntimeError, WebSocketDisconnect):
                    pass
        if self.search.mode != "rehearsal" or self.phase not in SEARCH_PHASES or self.target.found_by:
            return
        pose = phone.pose(now_ms())
        if not pose:
            return
        for x, y, score in self.sightings.ingest(phone.id, pose, boxes, now_ms() / 1000):
            self.coverage.boost(x, y, score)

    def end_utterance(self, phone: Phone) -> None:
        """Someone stopped talking: transcribe what they said (in the background)."""
        pcm, phone.audio = bytes(phone.audio), bytearray()
        if len(pcm) < VOICE_MIN_S * VOICE_RATE * 2 or not (self.mission and self.mission.client):
            return
        asyncio.create_task(self.transcribe(phone, pcm))

    async def transcribe(self, phone: Phone, pcm: bytes) -> None:
        wav = _wav(pcm, VOICE_RATE)
        try:
            r = await self.mission.client.audio.transcriptions.create(
                model=VOICE_MODEL, file=("speech.wav", wav, "audio/wav"), language="en",
                prompt="People searching a room together, talking to each other and to the operator.")
        except Exception as e:  # speech is best-effort: never let it take anything else down
            self.planner.note(f"transcription failed: {str(e)[:60]}", phone.id)
            return
        text = (r.text or "").strip()
        if len(text) < 2:
            return
        phone.captions.append({"text": text[:200], "t": now_ms()})
        self.planner.note(f"🎙 “{text[:120]}”", phone.id)
        if self.mission:
            self.mission.trigger()  # speech can be a request ("I need help here"): look right away

    def check_sightings(self, viewers: dict, now: float) -> list[tuple[str, dict]]:
        """Announce new possible sightings; in rehearsals, confirm the find once one is confident enough.
        A real search never finds on its own: the operator confirms (see /api/search/confirm)."""
        if self.target.found_by:
            return []
        for s in self.sightings.items:
            conf = self.sightings.confidence(s)
            if conf >= POSSIBLE_CONF and not s["announced"]:
                s["announced"] = True
                first = self.phones.get(next(iter(s["phones"])))
                self.planner.note(f"Possible sighting ({round(conf * 100)}%) near ({s['x']:.1f}, {s['y']:.1f})",
                                  first.id if first else None)
                if self.mission:
                    self.mission.trigger()  # a sighting to double-check is exactly what autonomy is for
        if self.search.mode != "rehearsal":
            return []
        best = self.sightings.best()
        if not best or self.sightings.confidence(best) < FOUND_CONF:
            return []
        finder = max(best["phones"], key=best["phones"].get)
        return self.target.confirm(finder, best["x"], best["y"], self.sightings.confidence(best), viewers, now)

    def likely_sectors(self, n: int = 3) -> list[dict]:
        """Where the candidate most probably is: sectors by share of the probability map."""
        prob = self.coverage.prob
        mass = {name: sum(prob[i] for i, _, _ in cells) for name, cells in self.planner.sector_cells.items()}
        return [{"sector": s, "share": round(m, 3)} for s, m in sorted(mass.items(), key=lambda kv: -kv[1])[:n]]

    def real_evidence(self, accepted) -> int:
        """A real detection result as search evidence: people who look like the reference raise the
        probability where they stand and can become possible sightings; near misses nudge the heatmap
        (worth another look); everyone else is someone else. Placed from the pose the phone had when the
        frame was taken. Evidence only: it never confirms a find or claims a position (the operator does)."""
        pose = accepted.pose
        if self.search.mode != "real" or self.phase != "search" or not pose or pose.get("heading") is None:
            return 0
        threshold = self.search.threshold
        boxes = []
        for b in accepted.result.boxes:
            if b.similarity >= threshold:  # a match: 0.55 at the threshold, up to 0.95
                score = 0.55 + 0.4 * min(1.0, (b.similarity - threshold) / max(1 - threshold, 0.05))
            elif b.similarity >= threshold - REAL_NEAR_MISS:  # close: a faint hint, heatmap only
                score = 0.1 + 0.25 * (b.similarity - (threshold - REAL_NEAR_MISS)) / REAL_NEAR_MISS
            else:
                continue
            score *= 0.6 + 0.4 * b.detectionScore  # a shaky detection counts for less
            boxes.append({"x": b.x, "y": b.y, "w": b.w, "h": b.h, "score": round(score, 3), "heightM": PERSON_HEIGHT_M})
        placed = self.sightings.ingest(accepted.result.phoneId, pose, boxes, now_ms() / 1000)
        for x, y, score in placed:
            self.coverage.boost(x, y, score)
        if placed and self.mission:
            self.mission.trigger()
        return len(placed)

    def new_search(self) -> None:
        self.sightings.reset()

    async def enter_real_search(self) -> None:
        self.search.mode = "real"
        self.target.remove()
        self.new_search()
        # Simulated evidence must not bias a real person's search map.
        self.coverage.prob = [1 / len(self.coverage.prob)] * len(self.coverage.prob)
        self.mission_complete = False
        for pid, cmd in self.target.tick({}, now_ms()):
            if pid in self.phones:
                await self.phones[pid].send({"type": "command", **cmd})

    async def clear_detection_overlays(self) -> None:
        revision = self.search.revision
        async def clear(phone: Phone) -> None:
            async with phone.send_lock:
                if self.search.revision == revision and phone.ws:
                    try:
                        await phone.ws.send_json({'type': 'command', 'cmd': 'detections', 'boxes': [],
                                                  'searchRevision': revision, 'clear': True, 'ttlMs': 0})
                    except (RuntimeError, WebSocketDisconnect):
                        pass
        await asyncio.gather(*(clear(phone) for phone in self.phones.values()))

    async def set_phase(self, phase: str, *, confirmed_visual: bool = False) -> bool:
        """Re-selecting the current phase re-applies its effects (e.g. turns the planner back on)."""
        if phase not in PHASES:
            return False
        self._phase_generation += 1
        generation = self._phase_generation
        changed = phase != self.phase
        if changed:
            # The audit keeps its original revision while live callbacks are invalidated.
            self.search.reset(preserve_confirmation=confirmed_visual and phase == "found")
            self.phase, self.phase_started = phase, now_ms()
            self.planner.note(f"Phase → {phase}")
            if self.mission:
                self.mission.trigger()
        if phase == "search":
            self.planner.enabled = True
        elif phase in ("lobby", "calibrate", "end"):
            self.planner.enabled = False

        def current() -> bool:
            return generation == self._phase_generation

        async def publish(phone: Phone) -> None:
            # Recheck after the send lock: another transition can overtake a waiting sender.
            async with phone.send_lock:
                if current() and phone.ws:
                    try:
                        await phone.ws.send_json({"type": "phase", "phase": phase})
                    except (RuntimeError, WebSocketDisconnect):
                        pass

        if changed:
            await self.clear_detection_overlays()
        if not current():
            return False
        await asyncio.gather(*(publish(phone) for phone in self.phones.values()))
        return current()

    # ---- operator actions (console + Mission Control) --------------------------
    def phones_by_index(self, indexes: list[int] | None) -> list[Phone]:
        """Empty or None means every phone."""
        if not indexes:
            return list(self.phones.values())
        wanted = set(indexes)
        return [p for p in self.phones.values() if p.index in wanted]

    async def ping(self, x: float, y: float, label: str = "Check here", phones: list[int] | None = None) -> dict:
        x = max(-ROOM["width"] / 2, min(ROOM["width"] / 2, float(x)))
        y = max(0.0, min(ROOM["depth"], float(y)))
        targets = self.phones_by_index(phones)
        ping = {"id": next(self.ping_ids), "x": x, "y": y, "label": str(label)[:32] or "Check here",
                "t": now_ms(), "phones": {p.id for p in targets} if phones else None}
        self.pings.append(ping)
        self.planner.note(f"Ping “{ping['label']}” at ({x:.1f}, {y:.1f})"
                          + (f" → {', '.join('#' + str(p.index) for p in targets)}" if phones else ""))
        cmd = {"type": "command", "cmd": "ping", "id": ping["id"], "x": x, "y": y,
               "label": ping["label"], "ttlMs": PING_TTL_MS}
        await asyncio.gather(*(p.send(cmd) for p in targets))
        return ping

    async def message(self, text: str, phones: list[int] | None = None) -> int:
        targets = self.phones_by_index(phones)
        text = str(text)[:140]
        self.planner.note(f"Message: “{text}”" + (f" → {len(targets)} phones" if phones else " → everyone"))
        cmd = {"type": "command", "cmd": "message", "text": text, "ttlMs": MESSAGE_TTL_MS}
        await asyncio.gather(*(p.send(cmd) for p in targets))
        return len(targets)

    def assign(self, phones: list[int], sector: str) -> list[int]:
        sector = sector.upper().strip()
        if not self.planner.is_sector(sector):
            raise ValueError(f"unknown sector {sector!r}")
        now = now_ms()
        done = []
        for p in self.phones_by_index(phones):
            pose = p.pose(now)
            if pose:
                self.planner.assign(p.id, sector, pose["x"], pose["y"], now)
                done.append(p.index)
        return done

    def look(self, phones: list[int] | None, label: str, seconds: float | None = None, *,
             compass: float | None = None, heading: float | None = None,
             point: tuple[float, float] | None = None, go: bool = False) -> list[int]:
        """Point phones somewhere: a real compass bearing, a room heading (0 = stage), or a spot.
        With go=True the phones walk to the spot instead, until they arrive."""
        now = now_ms()
        until = now + 1000 * (seconds or (GO_SECONDS if go else LOOK_SECONDS))
        done = []
        for p in self.phones_by_index(phones):
            self.planner.assignments.pop(p.id, None)  # the operator overrides the plan
            self.directives[p.id] = {"label": str(label)[:16], "until": until, "sent": 0.0, "go": go,
                                     "compass": compass, "heading": heading, "point": point}
            done.append(p.index)
        self.planner.note(f"{'Walk to' if go else 'Look'} {label} → " + ", ".join(f"#{i}" for i in done))
        return done

    def clear_look(self, phones: list[int] | None) -> list[int]:
        done = []
        for p in self.phones_by_index(phones):
            if self.directives.pop(p.id, None):
                self.directives_cleared.append(p.id)
                done.append(p.index)
        return done

    def directive_tick(self, now: float) -> list[tuple[str, dict]]:
        out = [(pid, {"cmd": "guide", "clear": True}) for pid in self.directives_cleared]
        self.directives_cleared = []
        for pid, d in list(self.directives.items()):
            phone = self.phones.get(pid)
            if not phone or now > d["until"]:
                del self.directives[pid]
                out.append((pid, {"cmd": "guide", "clear": True}))
                continue
            if pid in self.target.busy() or now - d["sent"] < (500 if d["go"] else 1000):
                continue  # responding to the candidate wins; otherwise refresh once a second
            cmd = {"cmd": "guide", "kind": "go" if d["go"] else "look", "sector": d["label"],
                   "untilMs": round(d["until"] - now)}
            if d["compass"] is not None:
                cmd["compass"] = d["compass"] % 360
            elif d["heading"] is not None:
                cmd["heading"] = d["heading"] % 360
            else:
                pose = phone.pose(now)
                if not pose:
                    continue
                x, y = d["point"]
                dist = math.hypot(x - pose["x"], y - pose["y"])
                if d["go"] and dist <= ARRIVE_M:
                    del self.directives[pid]
                    self.planner.note(f"arrived at {d['label']}", pid)
                    out.append((pid, {"cmd": "guide", "clear": True}))
                    out.append((pid, {"cmd": "flash", "color": "#7ae582", "text": "You're there ✓", "ttlMs": 1500}))
                    continue
                cmd["heading"] = math.degrees(math.atan2(x - pose["x"], -(y - pose["y"]))) % 360
                cmd["distance"] = round(dist, 1)
            d["sent"] = now
            out.append((pid, cmd))
        return out

    def task_of(self, pid: str) -> str | None:
        """What a phone is busy doing, or None if it's free for a new order.
        Routine planner sectors don't count: only explicit orders and the find team do."""
        if pid in self.target.busy():
            return "with the found candidate"
        d = self.directives.get(pid)
        if d:
            return f"{'walking to' if d['go'] else 'looking at'} {d['label']}"
        a = self.planner.assignments.get(pid)
        if a and a.get("manual"):
            return f"searching {a['sector']}"
        return None

    def set_looking_for(self, text: str) -> None:
        self.looking_for = str(text)[:80]
        self.planner.note(f"Looking for: {self.looking_for or '(cleared)'}")

    async def update_boost(self) -> None:
        """Phones someone is viewing large in a console capture faster; the rest go back to normal."""
        wanted = {c.focus for c in self.consoles if c.focus}
        for pid in wanted - self.boosted:
            if pid in self.phones:
                await self.phones[pid].send({"type": "command", "cmd": "rate", "fps": FOCUS_FPS})
                await self.phones[pid].send({"type": "command", "cmd": "hud", "on": True})
        for pid in self.boosted - wanted:
            if pid in self.phones:
                await self.phones[pid].send({"type": "command", "cmd": "rate", "fps": None})
                await self.phones[pid].send({"type": "command", "cmd": "hud", "on": False})
        self.boosted = wanted

    async def emit(self, event: dict) -> None:
        """Push an event (e.g. Mission Control progress) to every open console."""
        await asyncio.gather(*(c.send_json(event) for c in list(self.consoles)), return_exceptions=True)

    def active_pings(self, now: float) -> list[dict]:
        self.pings = [pg for pg in self.pings if now - pg["t"] < PING_TTL_MS]
        return self.pings

    # ---- shared picture for phones --------------------------------------------
    async def world_loop(self) -> None:
        while True:
            await asyncio.sleep(1 / WORLD_HZ)
            now = now_ms()
            live = [p for p in self.phones.values() if p.connected]
            others = []
            for p in live:
                pose = p.pose(now)
                if pose:
                    others.append({"id": p.id, "i": p.index, "x": round(pose["x"], 2), "y": round(pose["y"], 2),
                                   "h": None if pose["heading"] is None else round(pose["heading"])})
            cov = self.coverage.snapshot()
            cell_m2 = self.coverage.cell ** 2
            ranked = sorted(live, key=lambda p: -p.searched_cells)
            found = self.target.fix if self.search.mode == "rehearsal" and self.target.found_by else None
            pings = self.active_pings(now)
            base = {
                "type": "world", "phase": self.phase, "phones": others,
                "coverage": {k: cov[k] for k in ("cols", "rows", "cell", "x0", "cells")},
                "searched": cov["searched"], "searchers": len(live),
                "lookingFor": self.looking_for, "missionComplete": self.mission_complete,
                "candidate": None if found is None else {"x": found[0], "y": found[1]},
            }
            sends = []
            for p in live:
                mine = [{"id": pg["id"], "x": pg["x"], "y": pg["y"], "label": pg["label"],
                         "ageMs": round(now - pg["t"])}
                        for pg in pings if pg["phones"] is None or p.id in pg["phones"]]
                stats = {"m2": round(p.searched_cells * cell_m2, 1),
                         "rank": ranked.index(p) + 1, "of": len(ranked)}
                sends.append(p.send({**base, "me": p.id, "pings": mine, "stats": stats}))
            await asyncio.gather(*sends)

    # ---- outbound ----------------------------------------------------------
    def state(self) -> dict:
        now = now_ms()
        self.search.expire(now)
        phones = sorted(self.phones.values(), key=lambda p: p.index)
        cell_m2 = self.coverage.cell ** 2
        return {"type": "state", "t": now,
                "phones": [p.summary(now) | {"task": self.task_of(p.id), "searchedM2": round(p.searched_cells * cell_m2, 1)}
                           for p in phones],
                "coverage": self.coverage.snapshot(), "planner": self.planner.snapshot(),
                "target": self.target.snapshot(now),
                "phase": self.phase, "phaseStartedAt": self.phase_started,
                "search": self.search_state() if hasattr(self, "search_state") else {},
                "lookingFor": self.looking_for, "missionComplete": self.mission_complete,
                "sightings": self.sightings.snapshot(), "likely": self.likely_sectors(),
                "pings": [{k: pg[k] for k in ("id", "x", "y", "label", "t")} for pg in self.active_pings(now)],
                "mission": self.mission.status() if self.mission else {"ready": False, "why": "not started"}}

    async def command(self, target: str, cmd: dict) -> None:
        phones = self.phones.values() if target == "all" else [self.phones.get(target)]
        await asyncio.gather(*(p.send({"type": "command", **cmd}) for p in phones if p))


def _wav(pcm: bytes, rate: int) -> bytes:
    """Wrap 16-bit mono PCM in a WAV header."""
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


def _device(ua: str) -> str:
    for key, label in (("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android")):
        if key in ua:
            return label
    return "Desktop" if ua else ""


def _seat(seat: dict) -> dict | None:
    try:
        return {"x": float(seat["x"]), "y": float(seat["y"])}
    except (KeyError, TypeError, ValueError):
        return None


hub = Hub()
app = FastAPI(title="Beacon hub")
load_env()
settings = Settings()
auth = Auth(settings)
install_routes(app, hub, auth)


@app.middleware("http")
async def no_stale_pages(request, call_next):
    """Pages and scripts change often during development; make browsers (and phones) revalidate every time."""
    response = await call_next(request)
    if request.url.path == "/" or request.url.path == "/console" or request.url.path.startswith("/web/"):
        response.headers["Cache-Control"] = "no-cache"
    return response


class FrameSubscriber:
    """Pushes each phone's latest frame to one socket, throttled per phone.

    Latest-wins: if the socket is slow, intermediate frames are skipped, never queued.
    """

    def __init__(self, ws: WebSocket, fps: float, with_state: bool, skip_hidden: bool = False) -> None:
        self.ws = ws
        self.skip_hidden = skip_hidden  # projector: never show feeds the operator hid
        self.focus: str | None = None   # phone shown large in the console: gets frames faster
        self.min_interval = 1000 / max(fps, 0.1)
        self.with_state = with_state
        self.sent_seq: dict[str, tuple[str, int]] = {}
        self.sent_at: dict[str, float] = {}
        self.lock = asyncio.Lock()

    async def send_json(self, msg: dict) -> None:
        async with self.lock:
            await self.ws.send_json(msg)

    async def run(self) -> None:
        last_state = 0.0
        while True:
            now = now_ms()
            if self.with_state and now - last_state >= 100:
                last_state = now
                await self.send_json(hub.state())
            for p in list(hub.phones.values()):
                if p.frame is None or self.sent_seq.get(p.id) == (p.stream_id, p.frame_seq) or (self.skip_hidden and p.hidden):
                    continue
                interval = FOCUS_INTERVAL_MS if p.id == self.focus else self.min_interval
                # 25% slack: frames arrive with jitter, and a strict check would skip every other one
                if now - self.sent_at.get(p.id, 0) < interval * 0.75:
                    continue
                self.sent_seq[p.id] = (p.stream_id, p.frame_seq)
                self.sent_at[p.id] = now
                header = {"phoneId": p.id, "seq": p.frame_seq, "t": p.frame_t, "pose": p.frame_pose,
                          "streamId": p.stream_id, "width": p.frame_width, "height": p.frame_height,
                          "searchRevision": hub.search.revision}
                packet = pack(header, p.frame)
                async with self.lock:
                    await self.ws.send_bytes(packet)
            await asyncio.sleep(0.015)


@app.websocket("/ws/phone")
async def ws_phone(ws: WebSocket) -> None:
    await ws.accept()
    phone: Phone | None = None
    pinger: asyncio.Task | None = None
    try:
        hello = await ws.receive_json()
        phone = await hub.register(hello, ws)
        if phone.ws is not ws:
            return
        await ws.send_json({
            "type": "welcome", "phoneId": phone.id, "index": phone.index, "streamId": phone.stream_id,
            "color": phone.color, "room": ROOM, "phase": hub.phase,
        })
        if phone.id in hub.boosted:  # a console is watching it: a reconnected phone forgot, so tell it again
            await phone.send({"type": "command", "cmd": "rate", "fps": FOCUS_FPS})
            await phone.send({"type": "command", "cmd": "hud", "on": True})
        pinger = asyncio.create_task(_ping_loop(phone, ws))
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if phone.ws is not ws:
                break
            phone.last_seen = now_ms()
            if msg.get("bytes") is not None:
                hub.on_frame(phone, msg["bytes"])
            elif msg.get("text"):
                try:
                    hub.on_message(phone, json.loads(msg["text"]))
                except (ValueError, TypeError):
                    pass
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        if pinger:
            pinger.cancel()
        if phone:
            hub.disconnect(phone, ws)


async def _ping_loop(phone: Phone, ws: WebSocket) -> None:
    while phone.ws is ws:
        await phone.send({"type": "ping", "ts": now_ms()})
        await asyncio.sleep(0.5 if phone.clock_offset is None else 2)


async def _serve_subscriber(ws: WebSocket, fps: float, with_state: bool, hello: dict | None,
                            skip_hidden: bool = False) -> None:
    await ws.accept()
    sub = FrameSubscriber(ws, fps=fps, with_state=with_state, skip_hidden=skip_hidden)
    if hello:
        await sub.send_json(hello)
    if with_state:
        hub.consoles.add(sub)
    pump = asyncio.create_task(sub.run())
    try:
        while True:
            msg = await ws.receive_json()
            if not auth.same_origin(ws):
                await sub.send_json({"error": "same-origin request required"})
                continue
            if msg.get("type") == "command":
                await hub.command(str(msg.get("target", "all")), msg.get("cmd") or {})
            elif msg.get("type") == "reset_coverage":
                hub.coverage.reset()
                hub.planner.reset()
                hub.sightings.reset()
            elif msg.get("type") == "planner":
                hub.planner.enabled = bool(msg.get("enabled"))
            elif msg.get("type") == "target":
                if hub.search.mode != "rehearsal":
                    await sub.send_json({"error": "mock target requires explicit rehearsal mode"})
                    continue
                if msg.get("remove"):
                    hub.target.remove()
                    hub.new_search()
                else:
                    if "x" in msg and "y" in msg and hub.target.place(float(msg["x"]), float(msg["y"])):
                        hub.new_search()
                    if "responders" in msg:
                        hub.target.responders_wanted = max(0, int(msg["responders"]))
            elif msg.get("type") == "phase":
                await hub.set_phase(str(msg.get("phase")))
            elif msg.get("type") == "focus":
                sub.focus = msg.get("phoneId") or None
                await hub.update_boost()
            elif msg.get("type") == "hide":
                phone = hub.phones.get(str(msg.get("phoneId")))
                if phone:
                    phone.hidden = bool(msg.get("hidden"))
            elif msg.get("type") == "ping":
                await hub.ping(msg["x"], msg["y"], msg.get("label") or "Check here", msg.get("phones"))
            elif msg.get("type") == "mission" and hub.mission:
                asyncio.create_task(hub.mission.run(str(msg.get("text", ""))))
            elif msg.get("type") == "autonomy" and hub.mission:
                hub.mission.set_autonomy(bool(msg.get("enabled")))
    except (WebSocketDisconnect, RuntimeError, ValueError, KeyError):
        pass
    finally:
        pump.cancel()
        hub.consoles.discard(sub)
        if sub.focus:
            await hub.update_boost()


@app.websocket("/ws/dashboard")
async def ws_dashboard(ws: WebSocket) -> None:
    """Projector and operator console. The console (role=console) still sees hidden feeds."""
    fps = float(ws.query_params.get("thumb_fps", 10))
    console = ws.query_params.get("role") == "console" and auth.same_origin(ws)
    await _serve_subscriber(ws, fps, True, {"type": "hello", "room": ROOM, "joinUrl": hub.join_url},
                            skip_hidden=not console)


@app.websocket("/ws/frames")
async def ws_frames(ws: WebSocket) -> None:
    """For inference/positioning teammates: every phone's latest frame + pose, up to `fps` per phone."""
    if not auth.bridge(ws) and not auth.same_origin(ws):
        await ws.close(code=1008)
        return
    fps = float(ws.query_params.get("fps", 5))
    await _serve_subscriber(ws, fps, False, None)


@app.get("/api/room")
def get_room() -> dict:
    return ROOM


@app.get("/api/state")
def get_state() -> dict:
    return hub.state()


@app.post("/api/pose")
def post_pose(body: dict, request: Request) -> dict:
    """Stub for the positioning service: {phoneId, x, y, heading?, confidence?, source?}."""
    auth.require_bridge(request)
    return {"ok": hub.set_external_pose(body)}


@app.post("/api/detections")
async def post_detections(body: dict, request: Request) -> dict:
    auth.require_bridge(request)
    if hub.phase != 'search' or not hub.search.accept_result(body, now_ms=now_ms()):
        raise HTTPException(409, 'obsolete or invalid detection')
    result = DetectionResult.model_validate(body)
    phone = hub.phones.get(result.phoneId)
    if phone:
        async with phone.send_lock:
            if (result.searchRevision != hub.search.revision or hub.phase != 'search'
                    or hub.search.streams.get(result.phoneId) != result.streamId
                    or now_ms() - result.t > 1500
                    or hub.search.latest.get(result.phoneId) is None
                    or hub.search.latest[result.phoneId].result.seq != result.seq):
                raise HTTPException(409, 'search changed')
            if phone.ws:
                await phone.ws.send_json({'type': 'command', 'cmd': 'detections', **result.model_dump(), 'threshold': hub.search.threshold, 'ttlMs': 1500})
    accepted = hub.search.latest.get(result.phoneId)
    evidence = hub.real_evidence(accepted) if accepted and accepted.result.seq == result.seq else 0
    return {'ok': True, 'boxes': len(result.boxes), 'evidence': evidence}


@app.get("/api/qr.svg")
def qr(data: str) -> Response:
    buf = io.BytesIO()
    segno.make(data, error="m").save(buf, kind="svg", scale=8, border=2, dark="#0b1020", light="#ffffff")
    return Response(buf.getvalue(), media_type="image/svg+xml")


def build_id() -> str:
    """Changes whenever any page or script changes. Stamped onto script URLs so browsers can't reuse
    stale code, and reported back by phones so the console can flag ones running an old page."""
    h = hashlib.sha1()
    for f in sorted(WEB.glob("*.*")):
        st = f.stat()
        h.update(f"{f.name}:{st.st_mtime_ns}:{st.st_size};".encode())
    return h.hexdigest()[:8]


def _versioned(text: str, build: str) -> str:
    """Point every /web/*.js reference (script tags and module imports) at ?v=build."""
    return re.sub(r"(/web/[\w.-]+\.js)(?=['\"])", rf"\1?v={build}", text)


ROOT_PAGE = """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Beacon</title><style>body{background:#0b0b0c;color:#ededed;font:16px/1.5 -apple-system,system-ui,sans-serif;
margin:0;display:grid;place-items:center;height:100vh;text-align:center}div{max-width:22rem;padding:24px}
b{font-size:20px}p{color:#9b9b9b}</style><div><b>Beacon</b><p>Open the Beacon app on this phone and scan the
join code there. The browser client is no longer used.</p></div>"""


def _page(name: str) -> HTMLResponse:
    build = build_id()
    html = _versioned((WEB / name).read_text(), build)
    html = html.replace("<head>", f'<head>\n  <meta name="swarm-build" content="{build}">', 1)
    return HTMLResponse(html, headers={"Cache-Control": "no-cache"})


@app.get("/")
def root() -> HTMLResponse:
    """The browser phone client is retired: phones run the native app, which speaks /ws/phone.
    This page is what someone gets if they scan the join QR with the system camera."""
    return HTMLResponse(ROOT_PAGE, headers={"Cache-Control": "no-cache"})


@app.get("/console")
def console_page() -> HTMLResponse:
    return _page("console.html")


@app.get("/web/{name}.js")
def script(name: str) -> Response:
    path = WEB / f"{name}.js"
    if not path.is_file() or path.parent != WEB:
        return Response(status_code=404)
    return Response(_versioned(path.read_text(), build_id()), media_type="text/javascript",
                    headers={"Cache-Control": "no-cache"})


app.mount("/web", StaticFiles(directory=WEB), name="web")


def lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # no packet is sent; just picks the outbound interface
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"



def main() -> None:
    load_env()
    from .mission import MissionControl  # after load_env so it sees the API key
    hub.mission = MissionControl(hub, ROOM)
    ap = argparse.ArgumentParser(description="Beacon hub")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000, help="plain HTTP (dashboard, simulator, tunnel)")
    ap.add_argument("--https-port", type=int, default=8443, help="HTTPS for phones on the LAN (needs certs/)")
    ap.add_argument("--public-url", default="", help="URL phones should open, e.g. your tunnel URL")
    args = ap.parse_args()

    cert, key = CERTS / "cert.pem", CERTS / "key.pem"
    has_tls = cert.exists() and key.exists()
    ip = lan_ip()
    lan_url = f"https://{ip}:{args.https_port}/" if has_tls else f"http://{ip}:{args.port}/"
    hub.join_url = args.public_url.rstrip("/") + "/" if args.public_url else lan_url

    configs = [uvicorn.Config(app, host=args.host, port=args.port, log_level="warning", lifespan="off")]
    if has_tls:
        configs.append(uvicorn.Config(app, host=args.host, port=args.https_port, log_level="warning",
                                      lifespan="off", ssl_certfile=str(cert), ssl_keyfile=str(key)))

    print("\n  Beacon hub")
    print(f"  Console:     http://localhost:{args.port}/console")
    print(f"  Phones join: {hub.join_url}")
    if not has_tls and not args.public_url:
        print("  ! iPhone cameras need HTTPS: use a tunnel (--public-url) or run scripts/make-cert.sh")
    print(flush=True)

    async def serve() -> None:
        asyncio.create_task(hub.reaper())
        asyncio.create_task(hub.coverage_loop())
        asyncio.create_task(hub.world_loop())
        asyncio.create_task(hub.mission.autonomy_loop())
        await asyncio.gather(*(uvicorn.Server(c).serve() for c in configs))

    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
