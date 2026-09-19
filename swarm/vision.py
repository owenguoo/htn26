"""Vision: central intelligence looks through every phone's camera.

Each phone has its own pipeline: its latest frame goes to a vision model on its own (one frame per
call is ~1 s, where batching several is 3+ s), and the next look starts as soon as that one comes
back. A phone whose frame the detection model scored as uncertain jumps the queue, so a hint from
the fast detector gets a smarter second opinion within about a second. For each frame it reports:
- whether what we're looking for (the operator's "looking for" description; none set = no target
  reports) is in view, with a box and a confidence: fed into the same
  sightings pipeline as the detection model (heatmap, possible sighting, find)
- a short note of what it sees, which Mission Control reads when deciding what to do
- whether it's urgent (someone collapsed, calling for help, a hazard): the console pulls up
  that phone's feed on its own, and autonomy gets a nudge to act

Off until the operator turns it on: every look costs a model call.
"""
from __future__ import annotations

import asyncio
import base64
import itertools
import json
import os
import time
from collections import deque

from .protocol import now_ms

LOOK_EVERY_S = 1.0        # at most one look per phone this often (a look takes ~1 s anyway)
MAX_IN_FLIGHT = 10        # looks running at once, across all phones
FRESH_MS = 1500           # only look at frames this recent
NOTE_TTL_S = 20           # how long an observation stays in Mission Control's picture
REPEAT_LOG_S = 15         # log "still sees the target" for the same phone at most this often
SPOTLIGHT_COOLDOWN_S = 20  # don't pull the same phone up again this soon
TRIGGER_MIN, TRIGGER_MAX = 0.3, 0.8  # detector scores worth a second opinion
DEFAULT_MODEL = "gpt-4.1-mini"  # fastest model that reliably got the target right in benchmarks
NO_TARGET = "nothing specific yet (so target_visible is always false): just describe and flag anything urgent"

PROMPT = """You are the eyes of a search-and-rescue coordinator, looking through one phone camera that is
searching a room (an event hall) for: {target}.

Report:
- target_visible: is what we're looking for clearly in this frame?
- confidence: 0-1, how sure you are that it's the target (0 if not visible)
- box: where it is in the frame as fractions of the image (x, y = top-left corner, w, h; 0-1), or null
- sees: what the camera shows, under 12 words, concrete ("rows of chairs, two people standing")
- urgent: true only for something the coordinator must see right now: someone collapsed, injured
  or calling for help, fire or smoke, a hazard. Ordinary people, rooms and objects are never urgent.
- urgent_reason: under 8 words, or "" if not urgent

Be conservative: blurry or ambiguous frames are not the target and not urgent. Only report the target
when it matches the description; ordinary people sitting, standing or walking are not a match unless the
description says so."""

FORMAT = {"type": "json_schema", "json_schema": {"name": "frame", "strict": True, "schema": {
    "type": "object", "additionalProperties": False,
    "required": ["target_visible", "confidence", "box", "sees", "urgent", "urgent_reason"],
    "properties": {
        "target_visible": {"type": "boolean"},
        "confidence": {"type": "number"},
        "box": {"anyOf": [{"type": "null"}, {
            "type": "object", "additionalProperties": False, "required": ["x", "y", "w", "h"],
            "properties": {k: {"type": "number"} for k in ("x", "y", "w", "h")}}]},
        "sees": {"type": "string"},
        "urgent": {"type": "boolean"},
        "urgent_reason": {"type": "string"},
    }}}}


class Vision:
    def __init__(self, hub, mission) -> None:
        self.hub = hub
        self.mission = mission
        self.model = os.environ.get("VISION_MODEL") or DEFAULT_MODEL
        self.enabled = False
        self.in_flight: set[str] = set()            # phones with a look underway
        self.looked_at: dict[str, float] = {}       # phone id → when its last look started
        self.triggered: dict[str, float] = {}       # phone id → detector score that asked for a look
        self.notes: dict[str, dict] = {}            # phone id → latest observation
        self.logged_at: dict[str, float] = {}
        self.spotlit_at: dict[str, float] = {}
        self.spotlights: deque[dict] = deque(maxlen=10)
        self.durations: deque[float] = deque(maxlen=20)
        self.looks: deque[float] = deque(maxlen=200)  # when looks finished, for looks per second
        self.ids = itertools.count(1)
        self.calls = 0
        self.tokens = 0
        self.error: str | None = None

    def set_enabled(self, on: bool) -> None:
        if on != self.enabled:
            self.enabled = on
            self.hub.planner.note(f"Vision {'on' if on else 'off'}")

    def status(self) -> dict:
        now = time.time()
        return {"enabled": self.enabled, "ready": self.mission.client is not None, "model": self.model,
                "lastMs": round(sum(self.durations) / len(self.durations) * 1000) if self.durations else None,
                "perSec": round(sum(1 for t in self.looks if now - t < 10) / 10, 1),
                "inFlight": len(self.in_flight), "frames": self.calls,
                "calls": self.calls, "tokens": self.tokens, "error": self.error}

    def recent(self, pid: str) -> dict | None:
        n = self.notes.get(pid)
        return n if n and time.time() - n["t"] < NOTE_TTL_S else None

    def trigger(self, pid: str, score: float) -> None:
        """The detection model isn't sure about something in this phone's view: look next."""
        if TRIGGER_MIN <= score < TRIGGER_MAX:
            self.triggered[pid] = max(score, self.triggered.get(pid, 0))

    # ---- cadence ---------------------------------------------------------------------
    async def loop(self) -> None:
        while True:
            await asyncio.sleep(0.1)
            if not self.enabled or not self.mission.client or self.hub.target.complete():
                continue
            now, t = now_ms(), time.time()
            ready = []
            for p in self.hub.phones.values():
                pose = p.pose(now)
                if (p.id in self.in_flight or not p.connected or not p.frame or now - p.frame_at > FRESH_MS
                        or not pose or pose.get("heading") is None):
                    continue
                if p.id in self.triggered or t - self.looked_at.get(p.id, 0) >= LOOK_EVERY_S:
                    # detector hints first, then whoever has waited longest
                    ready.append((p.id not in self.triggered, self.looked_at.get(p.id, 0), p, pose))
            for _, _, p, pose in sorted(ready, key=lambda r: r[:2])[: MAX_IN_FLIGHT - len(self.in_flight)]:
                self.in_flight.add(p.id)
                self.looked_at[p.id] = t
                asyncio.create_task(self.look(p, pose, p.frame, self.triggered.pop(p.id, None)))

    # ---- one look ------------------------------------------------------------------
    async def look(self, p, pose: dict, jpeg: bytes, hint: float | None) -> None:
        t0 = time.time()
        target = self.hub.looking_for or NO_TARGET
        try:
            kwargs = {"model": self.model, "response_format": FORMAT, "messages": [
                {"role": "system", "content": PROMPT.format(target=target)},
                {"role": "user", "content": [{"type": "image_url", "image_url": {
                    "url": "data:image/jpeg;base64," + base64.b64encode(jpeg).decode(), "detail": "low"}}]}]}
            if self.model.startswith("gpt-5"):
                kwargs["reasoning_effort"] = "minimal"
            resp = await self.mission.client.chat.completions.create(**kwargs)
            self.calls += 1
            self.tokens += resp.usage.total_tokens if resp.usage else 0
            f = json.loads(resp.choices[0].message.content or "{}")
            self.error = None
        except Exception as e:  # vision is best-effort: never take the rest of the hub down
            self.error = str(e)[:120]
            return
        finally:
            self.in_flight.discard(p.id)
        self.durations.append(time.time() - t0)
        self.looks.append(time.time())
        if self.enabled:
            await self.observe(p, pose, f, hint)

    async def observe(self, p, pose: dict, f: dict, hint: float | None) -> None:
        hub, now = self.hub, time.time()
        conf = max(0.0, min(1.0, float(f.get("confidence") or 0)))
        visible = bool(f.get("target_visible")) and conf >= 0.2 and bool(self.hub.looking_for)
        before = self.notes.get(p.id) or {}
        note = {"t": now, "sees": str(f.get("sees") or "")[:100], "target": visible, "confidence": conf,
                "urgent": bool(f.get("urgent")), "reason": str(f.get("urgent_reason") or "")[:60],
                "hint": hint}
        self.notes[p.id] = note
        await hub.emit({"type": "look", "phoneId": p.id, "index": p.index, "ms": round(self.durations[-1] * 1000)}
                       | {k: note[k] for k in ("sees", "target", "confidence", "urgent", "reason", "hint")})
        box = f.get("box")
        if visible and box and box.get("h", 0) > 0:
            b = {k: max(0.0, min(1.0, float(box[k]))) for k in ("x", "y", "w", "h")}
            await hub.ingest_detections(p, [b | {"label": "vision", "score": round(conf, 2)}], pose=pose)
        # log and nudge autonomy when something changes, not on every look
        new_find = visible and (not before.get("target") or now - self.logged_at.get(p.id, 0) > REPEAT_LOG_S)
        if new_find:
            self.logged_at[p.id] = now
            why = f" (checking a {round(hint * 100)}% detection)" if hint else ""
            hub.planner.note(f"👁 sees the target ({round(conf * 100)}%){why}: {note['sees']}", p.id)
            self.mission.trigger()
        elif hint and not visible and now - self.logged_at.get(p.id + ":miss", 0) > REPEAT_LOG_S:
            self.logged_at[p.id + ":miss"] = now
            hub.planner.note(f"👁 checked a {round(hint * 100)}% detection: not the target ({note['sees']})", p.id)
        if note["urgent"] and await self.spotlight(p, note["reason"] or note["sees"], source="vision"):
            hub.planner.note(f"👁 ⚠ {note['reason'] or note['sees']}", p.id)
            self.mission.trigger()

    async def spotlight(self, p, reason: str, source: str) -> bool:
        """Pull this phone's feed up on the console (at most once per cooldown per phone)."""
        now = time.time()
        if now - self.spotlit_at.get(p.id, 0) < SPOTLIGHT_COOLDOWN_S:
            return False
        self.spotlit_at[p.id] = now
        ev = {"id": next(self.ids), "phoneId": p.id, "index": p.index, "reason": reason, "source": source}
        self.spotlights.append(ev | {"t": now})
        await self.hub.emit({"type": "spotlight", **ev})
        return True
