"""Mission Control: the hub's central intelligence, via OpenAI.

Two ways in:
- Commands: the operator types plain English in /console; the model calls tools (phase, planner,
  candidate, sector assignments, look / walk-to, messages, pings, ...) that act on the hub at once.
- Autonomy (on by default): a loop reviews the room back to back while searching (and right after
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

MAX_STEPS = 6  # model → tools → model rounds per command
THINK_EVERY_S = 2          # start a review this soon after the previous one started (reviews take ~2 s)
STEERING = ("send_phones_to_sector", "look_at", "look_direction", "move_to", "cancel_look")
# tools the autonomy layer may use: steering phones only
AUTONOMY_TOOLS = ("send_phones_to_sector", "look_at", "look_direction", "move_to", "cancel_look",
                  "message_phones", "ping", "set_planner", "set_responders")

SYSTEM = """You are Mission Control for Swarm Sight, a live search run by an audience whose phone cameras
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
]


AUTONOMY_SYSTEM = """You are the autonomy layer of Mission Control for Swarm Sight, a live search run by an
audience whose phone cameras are coordinated centrally. Every few seconds you review the current state and
signals and recommend actions that clearly improve the search or fix a problem.

Rules:
- Take at most ONE action per review: return at most one recommendation with exactly one action, and only
  when it clearly helps. You review again every couple of seconds, so do the single most useful thing now.
  An empty list is a good answer.
- Base every recommendation on the state and signals. The reason must cite the evidence (under 18 words).
- Titles are short imperative commands a human reads at a glance (under 8 words), e.g.
  "Send #7 to walk to back-right".
- Never repeat something in RECENT RECOMMENDATIONS, whatever its status.
- Only give steering orders (move, look, sector, cancel) to phones listed as available. Busy phones are
  still carrying out a task; leave them alone until it's done. Always name the phones explicitly.
- Never "set" something that is already in that state (planner already on, responders already N, ...).
- Prefer doing nothing over low-value moves. Skip generic encouragement or "wait" messages.
- send_phones_to_sector and look_at only help for areas within a phone's camera reach (about 5 m from where
  it stands). For sectors nobody can see from where they stand, use move_to to walk a nearby phone there.
- You do not know where the candidate is. Never guess its location.
- Typical good moves: walk a nearby idle phone to a sector nobody can reach; tell a phone pointing at the
  floor to hold it up; point idle phones at unsearched areas; ping an unreached area; after a find, nudge
  late responders.
- Don't micromanage phones the planner is already handling well.
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
        self.autonomy = True
        self.recs: deque[dict] = deque(maxlen=12)
        self.rec_ids = itertools.count(1)
        self.thinking = False
        self.last_think = 0.0
        self.last_think_ms: int | None = None
        self.triggered = False
        self.coverage_history: deque[tuple[float, float]] = deque(maxlen=120)  # (t, searched fraction)
        self.calls = 0
        self.tokens = 0


    def status(self) -> dict:
        now = time.time()
        return {"ready": self.client is not None, "model": self.model, "busy": self.busy,
                "lastMs": self.last_ms, "why": None if self.client else "Add OPENAI_API_KEY to .env",
                "autonomy": self.autonomy, "thinking": self.thinking, "lastThinkMs": self.last_think_ms,
                "calls": self.calls, "tokens": self.tokens,
                "recs": [{k: r[k] for k in ("id", "title", "reason", "severity", "actions", "status", "results")}
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
            self.triggered = False
            self.last_think = time.time()
            asyncio.create_task(self.review())

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
        if not raw or not self.autonomy or self.hub.target.complete():
            return  # nothing to do, paused, or the mission finished while this review was thinking
        a = raw["actions"][0]
        why_not = self._blocked(a)
        if why_not:  # the model ignored a rule; skip this review rather than churn phones
            self.hub.planner.note(f"skipped “{raw['title'][:40]}”: {why_not}")
            return
        rec = {"id": next(self.rec_ids), "t": time.time(), "title": raw["title"][:80],
               "reason": raw["reason"][:160], "severity": raw["severity"],
               "actions": [{"name": a["name"], "args": a["args"]}], "status": "executed", "results": []}
        try:
            rec["results"].append(await self.execute(a["name"], a["args"]))
        except Exception as e:
            rec["status"] = "failed"
            rec["results"].append(f"failed: {e}")
        self.recs.append(rec)
        self.hub.planner.note(f"⚡ {rec['title']}")

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
        if t.found_by and t.found_at:
            late = [f"#{hub.phones[pid].index}" for pid, r in t.responders.items()
                    if not r["arrived"] and pid in hub.phones]
            since = round((now - t.found_at) / 1000)
            team = ", ".join(f"#{hub.phones[pid].index}" for pid in t.responders if pid in hub.phones)
            out.append(f"- candidate found {since}s ago; the find team ({team}) stays with it: "
                       "never steer, message-redirect or reassign them")
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
        if name == "set_phase":
            await hub.set_phase(a["phase"])
            return f"phase is now {hub.phase}"
        if name == "set_planner":
            hub.planner.enabled = bool(a["enabled"])
            return f"planner {'on' if hub.planner.enabled else 'off'}"
        if name == "place_candidate":
            x = max(-self.room["width"] / 2, min(self.room["width"] / 2, float(a["x"])))
            y = max(0.0, min(self.room["depth"], float(a["y"])))
            hub.target.place(x, y)
            return f"candidate at ({x:.1f}, {y:.1f})"
        if name == "remove_candidate":
            hub.target.remove()
            return "candidate removed"
        if name == "set_responders":
            hub.target.responders_wanted = max(0, min(10, int(a["count"])))
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
        if name == "reset_coverage":
            hub.coverage.reset()
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
            where = (f"at ({pose['x']:.1f}, {pose['y']:.1f})"
                     + (f" facing {round(pose['heading'])}°" if pose["heading"] is not None else "")
                     ) if pose else "not placed"
            tags = []
            if not p.connected:
                tags.append("offline")
            job = pl.assignments.get(p.id)
            if job:
                tags.append(f"searching {job['sector']}")
            if t.found_by == p.id:
                tags.append("found the candidate")
            if p.id in t.responders:
                tags.append("arrived" if t.responders[p.id]["arrived"] else "responding")
            name = f" {p.name}" if p.name else ""
            lines.append(f"  #{p.index}{name} {where}" + (f" [{', '.join(tags)}]" if tags else ""))

        if t.pos is None:
            lines.append("candidate: none")
        elif not reveal_candidate and not t.found_by:
            lines.append("candidate: somewhere in the room, location unknown (not found yet)")
        elif t.found_by:
            finder = hub.phones.get(t.found_by)
            lines.append(f"candidate: found at ({t.pos[0]:.1f}, {t.pos[1]:.1f}) by #{finder.index if finder else '?'}")
        else:
            lines.append(f"candidate: hidden at ({t.pos[0]:.1f}, {t.pos[1]:.1f}), not found yet; "
                         f"{t.responders_wanted} responders will be sent")
        pings = hub.active_pings(now)
        if pings:
            lines.append("active pings: " + "; ".join(f"“{pg['label']}” at ({pg['x']:.1f}, {pg['y']:.1f})"
                                                     for pg in pings))
        return "\n".join(lines)
