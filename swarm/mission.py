"""Mission Control: plain-English operator commands → hub actions, via OpenAI tool calling.

The operator types a command in /console. The model sees a compact snapshot of the room
and calls tools (phase, planner, candidate, sector assignments, messages, pings, ...).
Each action is executed against the hub immediately and streamed back to the console.
"""
from __future__ import annotations

import asyncio
import itertools
import json
import os
import string
import time
from collections import deque

import openai
from openai import AsyncOpenAI

MAX_STEPS = 6  # model → tools → model rounds per command

SYSTEM = """You are Mission Control for Swarm Sight, a live search run by an audience whose phone cameras
are coordinated from a central console. The operator gives you short commands during a live show.

Act immediately by calling tools. Do not ask clarifying questions: pick the most reasonable reading of
the command and do it. Call several tools in one turn when a command needs several actions.

Do exactly what the operator asked and nothing more. Never add actions they didn't ask for: no extra
messages, pings, flashes, coverage resets, or "looking for" changes, and never invent details about
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
    _tool("cancel_look", "Stop telling phones where to face; the planner takes over again.", {"phones": _int_list}),
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
    _tool("flash_phones", "Flash phones' screens a color, e.g. to show who is being addressed.",
          {"phones": _int_list, "color": {"type": "string", "enum": ["white", "red", "green", "yellow"]}}),
    _tool("reset_coverage", "Mark the whole room as unsearched again.", {}),
]

FLASH_COLORS = {"white": "#ffffff", "red": "#ff4d4d", "green": "#7ae582", "yellow": "#ffd166"}


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

    def status(self) -> dict:
        return {"ready": self.client is not None, "model": self.model, "busy": self.busy,
                "lastMs": self.last_ms, "why": None if self.client else "Add OPENAI_API_KEY to .env"}

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

    async def _complete(self, messages: list[dict]):
        kwargs = {"model": self.model, "messages": messages, "tools": TOOLS, "parallel_tool_calls": True}
        if self.effort:
            try:
                return await self.client.chat.completions.create(**kwargs, reasoning_effort=self.effort)
            except openai.BadRequestError as e:
                if "reasoning" not in str(e).lower():
                    raise
                self.effort = None  # this model doesn't take reasoning_effort; stop sending it
        return await self.client.chat.completions.create(**kwargs)

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
        if name == "flash_phones":
            color = FLASH_COLORS.get(a["color"], "#ffffff")
            targets = hub.phones_by_index(a["phones"])
            await asyncio.gather(*(p.send({"type": "command", "cmd": "flash", "color": color,
                                           "text": f"#{p.index}", "ttlMs": 1500}) for p in targets))
            return f"flashed {len(targets)} phones"
        if name == "reset_coverage":
            hub.coverage.reset()
            hub.planner.reset()
            return "coverage reset"
        raise ValueError(f"unknown tool {name}")

    # ---- what the model sees ------------------------------------------------------------
    def snapshot(self) -> str:
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
