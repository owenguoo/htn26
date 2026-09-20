"""Mission Control: the hub's central intelligence, via OpenAI.

Two ways in:
- Commands: the operator types plain English in /console; the model calls tools (phase, planner,
  candidate, sector assignments, look / walk-to, messages, pings, ...) that act on the hub at once.
- Autonomy (off until the operator turns it on): a loop reviews the room back to back while searching (and right after
  key events), using signals computed here (tilted phones, unreachable sectors, stalled coverage,
  ...), and takes at most one action per review, logging why. Autonomy can only steer phones, never
  change the phase, move the candidate or reset coverage.
"""
from __future__ import annotations

import asyncio
import itertools
import json
import math
import os
import string
import time
from collections import deque

import openai
from openai import AsyncOpenAI

from .protocol import now_ms

MAX_STEPS = 6  # model → tools → model rounds per command
THINK_EVERY_S = 2          # start a review this soon after the previous one started (reviews take ~2 s)
IDLE_RECHECK_S = 20        # when nothing changed and the last review did nothing, re-check this rarely
STEERING = ("send_phones_to_sector", "look_at", "look_direction", "move_to", "cancel_look")
# Autonomy works a level above the phones: it turns evidence (speech, reports) into
# probability, and the Bayesian planner decides who looks where. It still sends people to someone
# who asked for help (that's rescue, not search), messages, pings and pulls up feeds.
AUTONOMY_TOOLS = ("adjust_likelihood_at", "adjust_likelihood_sectors", "move_to", "message_phones",
                  "ping", "set_responders")
LIKELIHOOD = {"much more likely": 5.0, "more likely": 2.5, "less likely": 0.4, "ruled out": 0.05}
_likelihood = {"type": "string", "enum": list(LIKELIHOOD),
               "description": "How the evidence changes the chance the candidate is there."}

SYSTEM = """You are Mission Control for Beacon, a live search run by an audience whose phone cameras
are coordinated from a central console. The operator gives you short commands during a live show.

Act immediately by calling tools. Do not ask clarifying questions: pick the most reasonable reading of
the command and do it. Call several tools in one turn when a command needs several actions.

Do exactly what the operator asked and nothing more. Never add actions they didn't ask for: no extra
messages, pings, coverage resets, or "looking for" changes, and never invent details about
what is being searched for. Changing the phase already switches the planner (search turns it on;
lobby, calibrate and end turn it off), so don't also call set_planner for that.

Room geometry (all positions in meters):
- x runs left (-) to right (+) as seen by the audience facing the stage; x = 0 is the center.
- y runs from the stage edge (0) to the back wall; larger y is further from the stage.
- The room is split into square sectors named by column letter (left→right) and row number (front→back),
  e.g. A1 is the front-left corner and the last letter + last row is the back-right corner.
- Phones are referred to by their number (#3 = phone 3).
- Room headings: 0° faces the stage, 90° faces right, 180° faces the back, 270° faces left.
- Compass directions (N, NE, E, SE, S, SW, W, NW) are real-world directions from each phone's compass,
  NOT room headings: the room isn't aligned to north. For "look SE", use look_direction with
  reference "compass" and degrees 135 (N=0, E=90, S=180, W=270).
- To make phones face somewhere, use look_direction or look_at. Don't just message them.

When the operator mentions an area ("back left", "near the stage", "around phone 4"), convert it to
coordinates or sectors using the geometry and the current state. "Left"/"right" are from the audience's
point of view. Messages to phones should be short, friendly, and in plain words (under 12 words).

Evidence about where the candidate is ("last seen near the stage", "we already checked the back") goes into
the probability map with ONE adjust_likelihood_at or adjust_likelihood_sectors call per piece of evidence;
the search planner then steers phones by itself.

A search can turn up more than one person. Each one found keeps their own find team, and the search
carries on for whoever is still missing — finding somebody is never a reason to stop or to stand
everyone else down.

After acting, reply with one short sentence (under 20 words) saying what you did."""

_int_list = {"type": "array", "items": {"type": "integer"},
             "description": "Phone numbers. Empty list means every phone."}


def _tool(name: str, description: str, properties: dict) -> dict:
    return {"type": "function", "function": {
        "name": name, "description": description, "strict": True,
        "parameters": {"type": "object", "properties": properties,
                       "required": list(properties), "additionalProperties": False},
    }}


TOOLS = [
    _tool("set_phase", "Move the show to a phase. lobby: people join, only locations shown. calibrate: "
          "everyone points at the stage. search: searching with the planner on. found: candidate found. "
          "end: stop everything.",
          {"phase": {"type": "string", "enum": ["lobby", "calibrate", "search", "found", "end"]}}),
    _tool("set_planner", "Turn the automatic sector planner on or off.", {"enabled": {"type": "boolean"}}),
    _tool("place_candidate", "Place (or move) the hidden mock candidate at a position in meters.",
          {"x": {"type": "number"}, "y": {"type": "number"}}),
    _tool("remove_candidate", "Remove the mock candidate.", {}),
    _tool("set_responders", "How many nearest phones get dispatched when the candidate is found.",
          {"count": {"type": "integer"}}),
    _tool("send_phones_to_sector", "Assign phones to search a sector, overriding the planner until it's searched.",
          {"phones": _int_list, "sector": {"type": "string", "description": "Sector name like C4."}}),
    _tool("look_direction", "Make phones turn to face a direction; their screens show which way to turn. "
          "reference 'compass': degrees is a real compass bearing (N=0, E=90, S=180, W=270). "
          "reference 'room': degrees is a room heading (0 = toward the stage, 90 = right, 180 = back, 270 = left). "
          "The planner leaves these phones alone until it expires.",
          {"phones": _int_list, "reference": {"type": "string", "enum": ["compass", "room"]},
           "degrees": {"type": "number"},
           "label": {"type": "string", "description": "Very short name shown on the phone, e.g. 'SE' or 'Stage'."},
           "seconds": {"type": "integer", "description": "How long to hold it; 20 if unsure."}}),
    _tool("look_at", "Make phones turn to face a spot in the room (each phone gets its own direction). "
          "The planner leaves these phones alone until it expires.",
          {"phones": _int_list, "x": {"type": "number"}, "y": {"type": "number"},
           "label": {"type": "string", "description": "Very short name, e.g. 'Back left'."},
           "seconds": {"type": "integer", "description": "How long to hold it; 20 if unsure."}}),
    _tool("move_to", "Tell phones to walk to a spot in the room (e.g. to reach an area nobody can see from "
          "where they are). Their screens guide them there until they arrive.",
          {"phones": _int_list, "x": {"type": "number"}, "y": {"type": "number"},
           "label": {"type": "string", "description": "Very short name, e.g. 'Back right'."}}),
    _tool("cancel_look", "Stop telling phones where to face or walk; the planner takes over again.",
          {"phones": _int_list}),
    _tool("message_phones", "Show a short message on phones' screens.",
          {"text": {"type": "string"}, "phones": _int_list}),
    _tool("ping", "Drop a ping marker at a position; phones see it on their map, compass and camera view.",
          {"x": {"type": "number"}, "y": {"type": "number"},
           "label": {"type": "string", "description": "What the ping says, 2-4 words. If the operator gave "
                     "an instruction for the ping (e.g. 'saying check behind the stage'), use that, e.g. "
                     "'Check behind stage'."},
           "phones": _int_list}),
    _tool("set_looking_for", "Set the description of what searchers are looking for (shown on every phone). "
          "Empty string clears it.", {"text": {"type": "string"}}),
    _tool("reset_coverage", "Mark the whole room as unsearched again.", {}),
    _tool("adjust_likelihood_at", "Change how likely the candidate is to be around a spot, from evidence that "
          "isn't a camera look: a report, where they were last seen, what someone said. The "
          "probability map changes and the search planner sends phones accordingly.",
          {"x": {"type": "number"}, "y": {"type": "number"},
           "radius": {"type": "number", "description": "Meters the evidence covers, 1-6."},
           "change": _likelihood,
           "reason": {"type": "string", "description": "The evidence, under 10 words."}}),
    _tool("adjust_likelihood_sectors", "Change how likely the candidate is to be in whole sectors, e.g. an "
          "area staff already checked (less likely / ruled out) or where they usually sit (more likely).",
          {"sectors": {"type": "array", "items": {"type": "string"}}, "change": _likelihood,
           "reason": {"type": "string", "description": "The evidence, under 10 words."}}),
]


AUTONOMY_SYSTEM = """You are the autonomy layer of Mission Control for Beacon, a live search run by an
audience whose phone cameras are coordinated centrally. Every few seconds you review the current state and
signals and recommend actions that clearly improve the search or fix a problem.

How the search works: a probability map says where the candidate probably is. A Bayesian planner
continuously sends each phone to look wherever it buys the most probability per second (and asks people to
walk when that's worth it). Camera looks and detections update the map automatically. Your job is one level
up: turn evidence the cameras can't turn into probability yourself. What people say ("I think I saw someone
by the door", "she was last seen near the stage", "we already checked the back") and reports become
adjust_likelihood_at / adjust_likelihood_sectors, and the planner does the steering.

Rules:
- Take at most ONE action per review: return at most one recommendation with exactly one action, and only
  when it clearly helps. You review again every couple of seconds, so do the single most useful thing now.
  An empty list is a good answer.
- Base every recommendation on the state and signals. The reason must cite the evidence (under 18 words).
- Titles are short imperative commands a human reads at a glance (under 8 words), e.g.
  "Send #7 to walk to back-right".
- Never repeat something in RECENT RECOMMENDATIONS, whatever its status.
- Don't steer phones to search: the planner does that better. Use move_to only to send people to someone
  who asked for help, and only phones listed as available. Always name the phones explicitly.
- Never "set" something that is already in that state (planner already on, responders already N, ...).
- Prefer doing nothing over low-value moves. Skip generic encouragement or "wait" messages.
- Evidence → likelihood: a sighting report or "over there" from someone → "more likely" (or "much more
  likely" if specific) around where they were facing, radius 2-3 m. "Last seen at X" → "much more likely"
  near X. "Already checked" → "less likely" (or "ruled out" if certain) for that area. Never adjust the same
  evidence twice.
- You do not know where the candidate is. Never guess its location.
- React to SPEECH. If someone asks for help ("I need help", "over here", "can someone come"), send the
  1-2 nearest available phones to them with move_to their position and message the person that help is
  coming. If someone reports seeing something ("I think I see someone"), make the area they're facing more
  likely (a few meters in front of them). Ignore chatter that isn't a request or report, and never act on
  the same thing someone said twice.
- POSSIBLE SIGHTINGS already raise the map there, so the planner sends a second look by itself. Only act
  if something else suggests where to look.
- Once the candidate is FOUND it is confirmed: never send anyone to check or confirm it again. Only
  help the find team if a responder is stuck; otherwise do nothing.
- Typical good moves: turn a report or remark into likelihood; tell a phone pointing at the floor to hold it
  up; send help to someone who asked; pull up a feed the operator must see; after a find, nudge late
  responders.
- severity: "critical" for problems that block the search, "warn" for inefficiencies, "info" otherwise.
- Each action is a tool name plus its arguments as a JSON object string, e.g.
  {"name": "move_to", "arguments": "{\\"phones\\": [7], \\"x\\": 8.5, \\"y\\": 12.5, \\"label\\": \\"Back right\\"}"}.
  Use every argument the tool lists. Phone lists hold phone numbers.
Room geometry: x left (-) to right (+) from the audience's view, y from the stage (0) to the back;
sectors are columns (letters) left→right and rows (numbers) front→back; room headings 0° = toward stage."""

REC_FORMAT = {"type": "json_schema", "json_schema": {"name": "recommendations", "strict": True, "schema": {
    "type": "object", "additionalProperties": False, "required": ["recommendations"],
    "properties": {"recommendations": {"type": "array", "items": {
        "type": "object", "additionalProperties": False,
        "required": ["title", "reason", "severity", "actions"],
        "properties": {
            "title": {"type": "string"},
            "reason": {"type": "string"},
            "severity": {"type": "string", "enum": ["info", "warn", "critical"]},
            "actions": {"type": "array", "items": {
                "type": "object", "additionalProperties": False, "required": ["name", "arguments"],
                "properties": {"name": {"type": "string", "enum": list(AUTONOMY_TOOLS)},
                               "arguments": {"type": "string"}},
            }},
        },
    }}},
}}}


class MissionControl:
    def __init__(self, hub, room: dict) -> None:
        self.hub = hub
        self.room = room
        self.model = os.environ.get("OPENAI_MODEL", "gpt-5-mini")
        self.effort = os.environ.get("OPENAI_REASONING_EFFORT", "minimal") or None
        self.client = AsyncOpenAI() if os.environ.get("OPENAI_API_KEY") else None
        self.history: deque[dict] = deque(maxlen=8)  # recent commands and replies, for follow-ups
        self.lock = asyncio.Lock()
        self.ids = itertools.count(1)
        self.busy = False
        self.last_ms: int | None = None
        # autonomy
        self.autonomy = False               # the operator turns it on from the console
        self.last_fingerprint = None        # what the room looked like at the last review
        self.last_review_acted = True
        self.recs: deque[dict] = deque(maxlen=12)
        self.rec_ids = itertools.count(1)
        self.thinking = False
        self.last_think = 0.0
        self.last_think_ms: int | None = None
        self.triggered = False
        self.coverage_history: deque[tuple[float, float]] = deque(maxlen=120)  # (t, searched fraction)
        self.calls = 0
        self.tokens = 0
        self.speech_shown: list[tuple[str, dict]] = []  # (phone id, caption) in the review being thought about


    def status(self) -> dict:
        now = time.time()
        return {"ready": self.client is not None, "model": self.model, "busy": self.busy,
                "lastMs": self.last_ms, "why": None if self.client else "Add OPENAI_API_KEY to .env",
                "autonomy": self.autonomy, "thinking": self.thinking, "lastThinkMs": self.last_think_ms,
                "calls": self.calls, "tokens": self.tokens,
                "recs": [{k: r.get(k) for k in ("id", "title", "reason", "severity", "actions", "status", "results", "evidence")}
                         | {"ageS": round(now - r["t"])} for r in reversed(self.recs)]}

    def set_autonomy(self, on: bool) -> None:
        if on != self.autonomy:
            self.autonomy = on
            self.hub.planner.note(f"Autonomy {'on' if on else 'paused'}")
            if on:
                self.trigger()

    def trigger(self) -> None:
        """Review as soon as possible (e.g. after a find or a phase change)."""
        self.triggered = True

    async def emit(self, rid: int, event: str, **data) -> None:
        await self.hub.emit({"type": "mission", "id": rid, "event": event, **data})

    async def run(self, text: str) -> None:
        text = text.strip()[:500]
        if not text:
            return
        rid = next(self.ids)
        await self.emit(rid, "start", text=text)
        if not self.client:
            await self.emit(rid, "error", message="Add OPENAI_API_KEY to .env and restart the hub")
            return
        async with self.lock:  # one command at a time, in order
            self.busy = True
            t0 = time.time()
            try:
                reply = await self._loop(rid, text)
                self.last_ms = round((time.time() - t0) * 1000)
                self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": reply}]
                await self.emit(rid, "done", reply=reply, ms=self.last_ms)
            except openai.AuthenticationError:
                await self.emit(rid, "error", message="OpenAI rejected the API key")
            except openai.RateLimitError:
                await self.emit(rid, "error", message="Rate limited by OpenAI, try again in a moment")
            except openai.APIConnectionError:
                await self.emit(rid, "error", message="Can't reach OpenAI (network)")
            except openai.APIStatusError as e:
                await self.emit(rid, "error", message=f"OpenAI error {e.status_code}: {e.message}")
            finally:
                self.busy = False

    async def _loop(self, rid: int, text: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM},
            *self.history,
            {"role": "user", "content": f"{self.snapshot()}\n\nOperator command: {text}"},
        ]
        for _ in range(MAX_STEPS):
            resp = await self._complete(messages)
            msg = resp.choices[0].message
            calls = [tc for tc in (msg.tool_calls or []) if tc.type == "function"]
            if not calls:
                return (msg.content or msg.refusal or "Done.").strip()
            messages.append({
                "role": "assistant", "content": msg.content,
                "tool_calls": [{"id": tc.id, "type": "function",
                                "function": {"name": tc.function.name, "arguments": tc.function.arguments}}
                               for tc in calls],
            })
            for tc in calls:
                try:
                    args = json.loads(tc.function.arguments or "{}")
                    result, ok = await self.execute(tc.function.name, args), True
                except Exception as e:  # report tool failures back to the model instead of crashing
                    args, result, ok = {}, f"Error: {e}", False
                await self.emit(rid, "action", name=tc.function.name, args=args, result=result, ok=ok)
                messages.append({"role": "tool", "tool_call_id": tc.id, "content": result})
        return "Stopped: that took too many steps."

    async def _complete(self, messages: list[dict], **extra):
        kwargs = {"model": self.model, "messages": messages, **extra}
        if "response_format" not in extra:
            kwargs |= {"tools": TOOLS, "parallel_tool_calls": True}
        resp = None
        if self.effort:
            try:
                resp = await self.client.chat.completions.create(**kwargs, reasoning_effort=self.effort)
            except openai.BadRequestError as e:
                if "reasoning" not in str(e).lower():
                    raise
                self.effort = None  # this model doesn't take reasoning_effort; stop sending it
        if resp is None:
            resp = await self.client.chat.completions.create(**kwargs)
        self.calls += 1
        self.tokens += resp.usage.total_tokens if resp.usage else 0
        return resp

    # ---- autonomy ------------------------------------------------------------------------
    async def autonomy_loop(self) -> None:
        while True:
            await asyncio.sleep(0.5)
            self.coverage_history.append((time.time(), self.hub.coverage.snapshot()["searched"]))
            due = self.triggered or time.time() - self.last_think >= THINK_EVERY_S
            if (not self.autonomy or not self.client or self.thinking or not due
                    or self.hub.phase not in ("search", "found") or self.hub.target.complete()):
                continue
            # don't spend tokens on an empty room, or on a room that hasn't changed since a review
            # that found nothing to do (re-check now and then in case slow drift matters)
            if not any(p.connected and p.pose(now_ms()) for p in self.hub.phones.values()):
                continue
            fp = self.fingerprint()
            quiet = time.time() - self.last_think < IDLE_RECHECK_S
            if not self.triggered and not self.last_review_acted and fp == self.last_fingerprint and quiet:
                continue
            self.last_fingerprint = fp
            self.triggered = False
            self.last_think = time.time()
            asyncio.create_task(self.review())

    def fingerprint(self) -> tuple:
        """A coarse picture of the room: if this hasn't changed, another review won't say anything new."""
        hub, now = self.hub, now_ms()
        phones = []
        for p in sorted(hub.phones.values(), key=lambda p: p.index):
            pose = p.pose(now) if p.connected else None
            phones.append((p.index, bool(pose),
                           pose and round(pose["x"]), pose and round(pose["y"]),
                           pose and pose["heading"] is not None and round(pose["heading"] / 30),
                           hub.task_of(p.id), p.tilted_since is not None))
        cov = round(hub.coverage.snapshot()["searched"] * 20)  # 5% steps
        t = hub.target
        return (hub.phase, cov, tuple(phones), len(t.victims),
                tuple(sorted((pid, r["arrived"]) for pid, r in t.responders.items())),
                len(hub.active_pings(now)), hub.planner.enabled)

    async def review(self) -> None:
        self.thinking = True
        t0 = time.time()
        try:
            recs = await self._recommend()
        except (openai.OpenAIError, ValueError) as e:
            self.hub.planner.note(f"Mission Control review failed: {str(e)[:80]}")
            return
        finally:
            self.thinking = False
            self.last_think_ms = round((time.time() - t0) * 1000)
        # one action per review: fast, legible, and easy to follow on stage
        raw = next((r for r in recs if r["actions"]), None)
        self.last_review_acted = raw is not None
        if not raw or not self.autonomy or self.hub.target.complete():
            self._settle_speech(None)
            return  # nothing to do, paused, or the mission finished while this review was thinking
        a = raw["actions"][0]
        why_not = self._blocked(a)
        if why_not:  # the model ignored a rule; skip this review rather than churn phones
            self.hub.planner.note(f"skipped “{raw['title'][:40]}”: {why_not}")
            self.last_review_acted = False  # nothing happened, so don't re-review an unchanged room
            self._settle_speech(None)
            return
        rec = {"id": next(self.rec_ids), "t": time.time(), "title": raw["title"][:80],
               "reason": raw["reason"][:160], "severity": raw["severity"],
               "actions": [{"name": a["name"], "args": a["args"]}], "status": "executed", "results": [],
               "evidence": self._evidence(a)}
        try:
            rec["results"].append(await self.execute(a["name"], a["args"]))
        except Exception as e:
            rec["status"] = "failed"
            rec["results"].append(f"failed: {e}")
        self.recs.append(rec)
        self.hub.planner.note(f"⚡ {rec['title']}")
        self._settle_speech(a if rec["status"] == "executed" else None)

    def _evidence(self, a: dict) -> dict:
        """What this decision was based on, captured when it was made (for "explain this decision")."""
        hub, now = self.hub, now_ms()
        args = a["args"]
        point = [float(args["x"]), float(args["y"])] if "x" in args and "y" in args else None
        sector = str(args.get("sector") or "").upper() or None
        if sector and hub.planner.is_sector(sector):
            point = list(hub.planner.sector_center(sector))
        phones = []
        for n in args.get("phones") or []:
            p = next((q for q in hub.phones.values() if q.index == n), None)
            pose = p.pose(now) if p else None
            phones.append({"index": n, "x": pose["x"] if pose else None, "y": pose["y"] if pose else None})
        speech = []
        for pid, cap in self.speech_shown:
            p = hub.phones.get(pid)
            pose = p.pose(now) if p else None
            if p:
                speech.append({"index": p.index, "text": cap["text"],
                               "x": pose["x"] if pose else None, "y": pose["y"] if pose else None})
        open_sightings = [sg for sg in hub.sightings.items if not hub.target.at(sg["x"], sg["y"])]
        best = (max(open_sightings, key=hub.sightings.confidence, default=None)
                if hub.search.mode == "rehearsal" else None)
        sighting = ({"x": best["x"], "y": best["y"], "confidence": round(hub.sightings.confidence(best), 2)}
                    if best and hub.sightings.confidence(best) >= 0.4 else None)
        return {"tool": a["name"], "point": point, "sector": sector, "phones": phones, "speech": speech,
                "sighting": sighting, "likely": hub.likely_sectors(3)}

    def _settle_speech(self, action: dict | None) -> None:
        """After a review: speech it acted on is handled; speech seen twice without action was chatter."""
        for pid, cap in self.speech_shown:
            cap["reviews"] = cap.get("reviews", 0) + 1
            if (action and self._addresses(action, pid)) or cap["reviews"] >= 2:
                cap["handled"] = True
        self.speech_shown = []

    def _addresses(self, a: dict, pid: str) -> bool:
        """Does this action respond to what this phone said: sent to them, or aimed at where they are?"""
        phone = self.hub.phones.get(pid)
        if not phone:
            return False
        args = a["args"]
        if phone.index in (args.get("phones") or []):
            return True
        pose = phone.pose(now_ms())
        if pose and "x" in args and "y" in args:
            return math.hypot(float(args["x"]) - pose["x"], float(args["y"]) - pose["y"]) <= 3
        return False

    def busy_phones(self) -> dict[int, str]:
        """Phone number → task, for phones that haven't finished what they were told to do."""
        return {p.index: task for pid, p in self.hub.phones.items() if (task := self.hub.task_of(pid))}

    def _blocked(self, a: dict) -> str | None:
        """Rules enforced in code, because a fast model doesn't always follow them:
        steering orders go only to named phones that have finished their current task."""
        if a["name"] not in STEERING:
            return None
        phones = a["args"].get("phones") or []
        if not phones:
            return "steering orders must name specific available phones"
        busy = self.busy_phones()
        clash = [n for n in phones if n in busy]
        if clash:
            return "; ".join(f"#{n} is still {busy[n]}" for n in clash)
        if a["name"] == "move_to":
            x, y = float(a["args"].get("x", 0)), float(a["args"].get("y", 0))
            for pid, d in self.hub.directives.items():
                if d["go"] and d["point"] and math.hypot(d["point"][0] - x, d["point"][1] - y) < 2:
                    other = self.hub.phones.get(pid)
                    return f"#{other.index if other else '?'} is already walking there"
        return None

    async def _recommend(self) -> list[dict]:
        tools = [t["function"] for t in TOOLS if t["function"]["name"] in AUTONOMY_TOOLS]
        tool_ref = "\n".join(
            f"- {t['name']}({', '.join(t['parameters']['properties'])}): {t['description']}" for t in tools)
        now = time.time()
        recent = [f"- {round(now - r['t'])}s ago [{r['status']}] {r['title']}" for r in self.recs if now - r["t"] < 120]
        messages = [
            {"role": "system", "content": AUTONOMY_SYSTEM + "\n\nTools you can use:\n" + tool_ref},
            {"role": "user", "content": "\n\n".join([
                self.snapshot(reveal_candidate=False), self.signals(),
                "RECENT RECOMMENDATIONS (don't repeat these):\n" + ("\n".join(recent) or "- none"),
            ])},
        ]
        resp = await self._complete(messages, response_format=REC_FORMAT)
        data = json.loads(resp.choices[0].message.content or "{}")
        out = []
        for r in data.get("recommendations", []):
            actions = []
            for a in r.get("actions", []):
                if a.get("name") not in AUTONOMY_TOOLS:
                    continue
                try:
                    args = json.loads(a.get("arguments") or "{}")
                except json.JSONDecodeError:
                    continue
                if isinstance(args, dict):
                    actions.append({"name": a["name"], "args": args})
            out.append({**r, "actions": actions})
        return out

    def signals(self) -> str:
        """Things plain code can tell reliably, so the model reasons about facts, not guesses."""
        hub, pl = self.hub, self.hub.planner
        now = time.time() * 1000
        out = ["SIGNALS"]
        live = [p for p in hub.phones.values() if p.connected]
        for p in sorted(live, key=lambda p: p.index):
            if p.tilted_since and now - p.tilted_since > 8000:
                out.append(f"- #{p.index} has pointed at the {'floor' if (p.pitch or 0) < 0 else 'ceiling'} "
                           f"for {round((now - p.tilted_since) / 1000)}s (not searching)")
            if p.frame is None or now - p.frame_at > 3000:
                out.append(f"- #{p.index} camera feed is stale")
            if not p.pose(now):
                out.append(f"- #{p.index} is not placed on the map")
        busy = {pid for pid in hub.phones if hub.task_of(pid)}  # still carrying out an order
        if pl.enabled:
            idle = [p for p in live if p.pose(now) and p.id not in pl.assignments and p.id not in busy]
            if idle:
                out.append("- idle (nothing left in reach): " + ", ".join(f"#{p.index}" for p in idle))
        # sectors with floor left that no phone can see from where it stands
        reach = set()
        for p in live:
            pose = p.pose(now)
            if pose:
                reach |= set(pl.reachable(pose["x"], pose["y"]))
        left = self.sector_unsearched()
        unreachable = [s for s, v in left.items() if v > 0.15 and s not in reach]
        if unreachable:
            out.append("- unsearched sectors nobody can see from where they stand (someone must walk there): "
                       + ", ".join(f"{s} ({round(left[s] * 100)}%)" for s in unreachable))
            # for the biggest gaps, who is the nearest free phone and how far would they walk
            free = [p for p in live if p.pose(now) and p.id not in busy]
            for s in sorted(unreachable, key=lambda s: -left[s])[:4]:
                cx, cy = pl.sector_center(s)
                near = min(free, key=lambda p: math.hypot(p.pose(now)["x"] - cx, p.pose(now)["y"] - cy), default=None)
                if near:
                    pose = near.pose(now)
                    d = math.hypot(pose["x"] - cx, pose["y"] - cy)
                    out.append(f"  - {s} center ({cx:g}, {cy:g}): nearest free phone #{near.index}, {d:.1f} m away")
        # what people said recently (they may be asking for help or reporting something).
        # Each caption is shown until a review acts on it, or for 2 reviews at most, so a request
        # gets answered once rather than on every review while it's still recent.
        self.speech_shown = []
        for p in sorted(live, key=lambda p: p.index):
            for cap in p.captions:
                age = (now - cap["t"]) / 1000
                if age <= 30 and not cap.get("handled"):
                    self.speech_shown.append((p.id, cap))
                    pose = p.pose(now)
                    where = f" at ({pose['x']:.1f}, {pose['y']:.1f})" if pose else ""
                    out.append(f"- SPEECH: #{p.index}{where} said {round(age)}s ago: “{cap['text']}”")
        # where the candidate probably is, and sightings that need a second look
        likely = hub.likely_sectors(4)
        out.append("- most likely sectors (share of probability): "
                   + ", ".join(f"{s['sector']} {round(s['share'] * 100)}%" for s in likely))
        if hub.search.mode == "rehearsal" and not hub.target.complete():
            for sg in sorted(hub.sightings.items, key=hub.sightings.confidence, reverse=True)[:3]:
                conf = hub.sightings.confidence(sg)
                if conf < 0.4 or hub.target.at(sg["x"], sg["y"]):
                    continue
                looking = hub.sightings.weights(sg)
                seen_by = ", ".join(f"#{hub.phones[pid].index}" for pid in looking if pid in hub.phones)
                near = min((p for p in live if p.pose(now) and p.index not in self.busy_phones()
                            and p.id not in looking),
                           key=lambda p: math.hypot(p.pose(now)["x"] - sg["x"], p.pose(now)["y"] - sg["y"]),
                           default=None)
                hint = ""
                if near:
                    pose = near.pose(now)
                    d = math.hypot(pose["x"] - sg["x"], pose["y"] - sg["y"])
                    hint = f"; nearest available phone that hasn't seen it: #{near.index}, {d:.1f} m away"
                out.append(f"- POSSIBLE SIGHTING at ({sg['x']:.1f}, {sg['y']:.1f}), {round(conf * 100)}% confident, "
                           f"seen by {seen_by}{hint}. A second phone confirming it raises the confidence.")
        # coverage progress
        hist = self.coverage_history
        if len(hist) > 20:
            t_old, c_old = next(((t, c) for t, c in hist if hist[-1][0] - t <= 20), hist[0])
            gained = hist[-1][1] - c_old
            out.append(f"- coverage {round(hist[-1][1] * 100)}%, +{round(gained * 100)}% in the last "
                       f"{round(hist[-1][0] - t_old)}s" + (" (stalled)" if gained < 0.01 else ""))
            rate = gained / max(hist[-1][0] - t_old, 1)
            if rate > 0 and hist[-1][1] < 0.95:
                out.append(f"- at this rate, 95% coverage in ~{round((0.95 - hist[-1][1]) / rate)}s")
        if left and max(left.values()) <= 0.15:
            out.append("- the whole room has been searched: don't recommend more coverage moves")
        t = hub.target
        if hub.search.mode == "rehearsal" and t.victims:
            for v in t.victims:
                since = round((now - v.found_at) / 1000)
                team = ", ".join(f"#{hub.phones[pid].index}" for pid in v.responders if pid in hub.phones)
                out.append(f"- person {v.id} found {since}s ago; their find team ({team}) stays with them: "
                           "never steer, message-redirect or reassign them")
            if t.unfound():
                out.append(f"- {len(t.unfound())} more still missing: keep everyone else searching")
            if late:
                out.append(f"- responders still en route: {', '.join(late)}")
        busy_now = self.busy_phones()
        if busy_now:
            out.append("- busy, don't give new orders until done: "
                       + "; ".join(f"#{n} {task}" for n, task in sorted(busy_now.items())))
        free_now = sorted(p.index for p in live if p.pose(now) and p.index not in busy_now)
        out.append("- available for new orders: " + (", ".join(f"#{n}" for n in free_now) or "none"))
        return "\n".join(out if len(out) > 1 else out + ["- nothing notable"])

    def sector_unsearched(self) -> dict[str, float]:
        looked = self.hub.coverage.looked
        return {name: sum(not looked[i] for i, _, _ in cells) / len(cells)
                for name, cells in self.hub.planner.sector_cells.items()}

    # ---- tools → hub -----------------------------------------------------------------
    async def execute(self, name: str, a: dict) -> str:
        hub = self.hub
        if hub.search.mode == 'real' and name in ('place_candidate', 'remove_candidate', 'set_responders'):
            raise ValueError('mock candidate controls require explicit rehearsal mode')
        if name == "set_phase":
            await hub.set_phase(a["phase"])
            return f"phase is now {hub.phase}"
        if name == "set_planner":
            hub.planner.enabled = bool(a["enabled"])
            return f"planner {'on' if hub.planner.enabled else 'off'}"
        if name == "place_candidate":
            x = max(-self.room["width"] / 2, min(self.room["width"] / 2, float(a["x"])))
            y = max(0.0, min(self.room["depth"], float(a["y"])))
            if hub.target.place(x, y):
                hub.new_search()
            return f"candidate at ({x:.1f}, {y:.1f})"
        if name == "remove_candidate":
            hub.target.remove()
            hub.new_search()
            return "candidate removed"
        if name == "set_responders":
            hub.target.set_responders_wanted(min(10, int(a["count"])))
            return f"{hub.target.responders_wanted} responders"
        if name == "send_phones_to_sector":
            done = hub.assign(a["phones"], a["sector"])
            if not done:
                return "no matching placed phones"
            return f"sent #{', #'.join(map(str, done))} to {a['sector'].upper()}"
        if name == "look_direction":
            key = "compass" if a["reference"] == "compass" else "heading"
            done = hub.look(a["phones"], a["label"], a["seconds"], **{key: float(a["degrees"])})
            return f"#{', #'.join(map(str, done))} turning to face {a['label']}" if done else "no matching phones"
        if name == "look_at":
            done = hub.look(a["phones"], a["label"], a["seconds"], point=(float(a["x"]), float(a["y"])))
            return f"#{', #'.join(map(str, done))} turning toward {a['label']}" if done else "no matching phones"
        if name == "move_to":
            done = hub.look(a["phones"], a["label"], None, point=(float(a["x"]), float(a["y"])), go=True)
            return f"#{', #'.join(map(str, done))} walking to {a['label']}" if done else "no matching phones"
        if name == "cancel_look":
            done = hub.clear_look(a["phones"])
            return f"released #{', #'.join(map(str, done))}" if done else "nobody was being pointed"
        if name == "message_phones":
            n = await hub.message(a["text"], a["phones"])
            return f"message shown on {n} phones"
        if name == "ping":
            pg = await hub.ping(a["x"], a["y"], a["label"], a["phones"])
            return f"pinged “{pg['label']}” at ({pg['x']:.1f}, {pg['y']:.1f})"
        if name == "set_looking_for":
            hub.set_looking_for(a["text"])
            return "looking-for updated"
        if name in ("adjust_likelihood_at", "adjust_likelihood_sectors"):
            factor = LIKELIHOOD.get(a["change"])
            if factor is None:
                return f"unknown change {a['change']}"
            if name == "adjust_likelihood_at":
                x = max(-self.room["width"] / 2, min(self.room["width"] / 2, float(a["x"])))
                y = max(0.0, min(self.room["depth"], float(a["y"])))
                r = max(1.0, min(6.0, float(a["radius"])))
                hub.coverage.adjust(factor, x, y, r)
                where = f"({x:.1f}, {y:.1f}) ±{r:g} m"
            else:
                names = [s.upper() for s in a["sectors"] if hub.planner.is_sector(s.upper())]
                if not names:
                    return "no valid sectors"
                hub.coverage.adjust(factor, cells=[i for s in names for i, _, _ in hub.planner.sector_cells[s]])
                where = ", ".join(names)
            hub.planner.note(f"🧭 {a['change']}: {where} · {a['reason']}")
            return f"{a['change']} at {where}"
        if name == "reset_coverage":
            hub.reset_coverage()
            hub.sightings.reset()
            hub.planner.reset()
            return "coverage reset"
        raise ValueError(f"unknown tool {name}")

    # ---- what the model sees ------------------------------------------------------------
    def snapshot(self, reveal_candidate: bool = True) -> str:
        """reveal_candidate=False hides where the mock candidate is: the autonomy layer must search
        for it like everyone else, not cheat."""
        hub, room = self.hub, self.room
        now = time.time() * 1000
        pl = hub.planner
        cols = string.ascii_uppercase[:pl.cols]
        lines = [
            "CURRENT STATE",
            "VISUAL SEARCH " + json.dumps(hub.search.visual_context(now)),
            "Visual evidence does not establish map position. Observer pose is not target position. "
            "Never dispatch responders to visual sightings without a separate known target position.",
            f"phase: {hub.phase} | planner: {'on' if pl.enabled else 'off'} | "
            f"area searched: {round(hub.coverage.snapshot()['searched'] * 100)}%"
            + (f" | looking for: {hub.looking_for}" if hub.looking_for else ""),
            f"room: {room['width']} m wide (x {-room['width'] / 2:g} to {room['width'] / 2:g}), "
            f"{room['depth']} m deep (y 0 at the stage to {room['depth']:g} at the back)",
            f"sectors: {pl.cols}x{pl.rows} squares of {pl.cols and room['width'] / pl.cols:g} m, "
            f"columns {cols[0]}–{cols[-1]} left→right, rows 1–{pl.rows} front→back",
            "sector centers: column x = " + ", ".join(f"{c} {pl.sector_center(c + '1')[0]:g}" for c in cols)
            + "; row y = " + ", ".join(f"{r + 1} {pl.sector_center('A' + str(r + 1))[1]:g}" for r in range(pl.rows)),
        ]
        # unsearched share per sector, as a small grid
        looked = hub.coverage.looked
        grid = []
        for r in range(pl.rows):
            row = []
            for c in range(pl.cols):
                cells = pl.sector_cells[f"{cols[c]}{r + 1}"]
                left = sum(not looked[i] for i, _, _ in cells) / len(cells)
                row.append(f"{cols[c]}{r + 1}:{round(left * 100)}")
            grid.append(" ".join(row))
        lines.append("unsearched % by sector:\n  " + "\n  ".join(grid))

        phones = sorted(hub.phones.values(), key=lambda p: p.index)
        lines.append("phones:")
        if not phones:
            lines.append("  (none)")
        t = hub.target
        for p in phones:
            pose = p.pose(now)
            # Where the position came from, because it changes what the position is worth: "slam"
            # is tracked by the phone, "seat" is the spot its operator claimed and has not moved
            # from since, "sim" is made up. Everything downstream — area searched, where a sighting
            # lands on the map, who gets dispatched — inherits that difference, so the model that
            # reasons over this (and anyone training on it later) has to see it.
            where = (f"at ({pose['x']:.1f}, {pose['y']:.1f})"
                     + (f" facing {round(pose['heading'])}°" if pose["heading"] is not None else "")
                     + f" [{pose.get('source') or 'unknown'}]"
                     ) if pose else "not placed"
            tags = []
            if not p.connected:
                tags.append("offline")
            job = pl.assignments.get(p.id)
            if job:
                tags.append(f"searching {job['sector']}")
            if hub.search.mode == "rehearsal":
                for v in t.victims:
                    if v.found_by == p.id:
                        tags.append(f"found person {v.id}")
                    if p.id in v.responders:
                        tags.append(f"{'with' if v.responders[p.id]['arrived'] else 'heading to'} person {v.id}")
            name = f" {p.name}" if p.name else ""
            lines.append(f"  #{p.index}{name} {where}" + (f" [{', '.join(tags)}]" if tags else ""))
            recent = [c for c in p.captions if now - c["t"] < 60_000]
            if recent:
                lines.append(f"    last said ({round((now - recent[-1]['t']) / 1000)}s ago): “{recent[-1]['text']}”")

        if hub.search.mode == "real":
            lines.append("candidate: visual evidence only; target location unknown; no responder team")
        else:
            for v in t.victims:
                finder = hub.phones.get(v.found_by)
                lines.append(f"person {v.id}: FOUND at ({v.fix[0]:.1f}, {v.fix[1]:.1f}) by "
                             f"#{finder.index if finder else '?'} ({round(v.confidence * 100)}% sure)")
            missing = t.unfound()
            if not t.candidates and not t.victims:
                lines.append("candidates: no mock candidate placed" if reveal_candidate
                             else "candidates: location unknown (nobody found yet)")
            elif not missing:
                lines.append(f"everyone hidden has been found ({len(t.victims)} in total)")
            elif not reveal_candidate:
                lines.append(f"still missing: {len(missing)}, somewhere in the room, location unknown")
            else:
                spots = ", ".join(f"({x:.1f}, {y:.1f})" for x, y in missing)
                lines.append(f"still missing: {len(missing)} hidden at {spots}; "
                             f"{t.responders_wanted} responders will be sent to each")
        pings = hub.active_pings(now)
        if pings:
            lines.append("active pings: " + "; ".join(f"“{pg['label']}” at ({pg['x']:.1f}, {pg['y']:.1f})"
                                                     for pg in pings))
        return "\n".join(lines)
