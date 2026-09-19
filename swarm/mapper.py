"""Live 3D scan: visually select overlapping keyframes without requiring phone poses.

A short per-phone candidate window feeds a bounded archive of clear connected views.
Each reconstruction uses a connected subset with old coverage and shared references.
VGGT still runs a fresh reconstruction for every batch; this is not persistent fusion.

Configure in .env (off until the operator turns it on in the console):
    MAP_WORKER_SSH=root@154.54.102.55     # pod's direct SSH (RUNPOD_PUBLIC_IP)
    MAP_WORKER_SSH_PORT=15429             # RUNPOD_TCP_PORT_22 (changes when the pod restarts)
    MAP_WORKER_PORT=8765                  # the worker's port on the pod
or MAP_WORKER_URL=http://host:port to skip the tunnel.
"""
from __future__ import annotations

import asyncio
import json
import math
import os
import struct
import time
import urllib.request
from pathlib import Path

from .sections import section_batch, register, SECTION_FRAMES, MAX_SECTIONS
from .protocol import now_ms
from .keyframes import VisualSelector, working_batch, MAX_ARCHIVE, MAX_BATCH, WINDOW_MS

MAX_KEYFRAMES = MAX_BATCH
MAX_WAIT_MS = 10000       # flush small pending updates; also back off failed requests
RUN_AFTER_NEW = 6         # rebuild once this many new keyframes have arrived
PAUSED_PHASES = ("lobby",)  # people are still joining: don't sample or rebuild
MIN_FRAMES = 6            # don't bother with fewer
FRESH_MS = 800
EYE_H = 1.45              # phones are held about this high (m)
LOCAL_PORT = 18765
KEEP_SCANS = 2
POSITION_CLUSTER_M = 0.75  # capture positions closer than this count as one place
MIN_PLACES_FOR_SCALE = 3   # scale from positions only with this many separate places (else camera height)
STEADY = 0.7               # how much a new version keeps the previous one's placement (0 = none)


class Mapper:
    def __init__(self, hub, room: dict, out_dir: Path) -> None:
        self.hub = hub
        self.room = room
        self.out_dir = out_dir
        self.enabled = False
        self.native_only = os.environ.get("MAP_NATIVE_ONLY") == "1"
        self.include_sims = os.environ.get("MAP_INCLUDE_SIMS") == "1"  # sim frames are drawings: off
        self.keyframes: list[dict] = []
        self.ids = 0
        self.pending: set[str] = set()
        self.previous_batch: list[str] = []
        self.selector = VisualSelector()
        self.selection_hints: dict[str, str] = {}
        self.sample_times: dict[str, float] = {}
        self.pending_since = 0
        self.last_attempt = 0
        self.batch_size = 0
        self.selection_ms = 0
        self.running = False
        self.version = 0
        self.generation = 0     # bumped by reset(): results from before it are thrown away
        self.consolidated = None
        self.sections = []
        self.blocked_batch = None
        self.fit_pivot = None
        self.placed: dict[str, tuple[float, float, float]] = {}  # keyframe id → where the last scan put its camera
        # operator's fit on top of the automatic alignment (scale factor and turn about where the phones
        # are): monocular scans have no true scale, so a quick manual fit is the reliable fallback
        self.fit = {"scale": 1.0, "turnDeg": 0.0}
        self.last: dict | None = None
        self.error: str | None = None
        self.worker_ok: bool | None = None
        self.tunnel: asyncio.subprocess.Process | None = None
        self._restore()
        ssh = os.environ.get("MAP_WORKER_SSH")
        self.local_port = int(os.environ.get("MAP_WORKER_LOCAL_PORT", LOCAL_PORT))
        self.url = os.environ.get("MAP_WORKER_URL") or (f"http://127.0.0.1:{self.local_port}" if ssh else None)

    def _restore(self) -> None:
        """Pick up where we left off after a hub restart: the latest scan and the views it was built from."""
        try:
            saved = json.loads((self.out_dir / "last.json").read_text())
            if saved.get("last") and (self.out_dir / Path(saved["last"]["url"]).name).exists():
                self.last, self.version = saved["last"], saved["last"]["version"]
                self.placed = {k: tuple(v) for k, v in saved.get("placed", {}).items()}
                self.fit = saved.get("fit") or self.fit
                self.last.setdefault("autoTransform", self.last["transform"])
            self.consolidated = saved.get("consolidated")
            self.sections = saved.get("sections", [])
            self.fit_pivot = saved.get("fitPivot")
            self.previous_batch = saved.get("previousBatch", [])
            for k in saved.get("keyframes", []):
                jpeg = self.out_dir / "views" / f"{k['id']}.jpg"
                if jpeg.exists():
                    self.keyframes.append(k | {"jpeg": jpeg.read_bytes()})
            self.pending = set(saved.get("pending", [])) & {k["id"] for k in self.keyframes}
            if self.pending:
                self.pending_since = now_ms()
            self.ids = max([int(k["id"][1:]) for k in self.keyframes] + [0])
        except (OSError, ValueError, KeyError):
            pass

    def _save(self) -> None:
        views = self.out_dir / "views"
        views.mkdir(parents=True, exist_ok=True)
        keep = {f"{k['id']}.jpg" for k in self.keyframes}
        for k in self.keyframes:
            f = views / f"{k['id']}.jpg"
            if not f.exists():
                f.write_bytes(k["jpeg"])
        for f in views.glob("*.jpg"):
            if f.name not in keep:
                f.unlink(missing_ok=True)
        saved = self.out_dir / "last.json.tmp"
        saved.write_text(json.dumps({
            "last": self.last, "placed": self.placed, "fit": self.fit, "sections": self.sections, "fitPivot": self.fit_pivot, "consolidated": self.consolidated,
            "previousBatch": self.previous_batch, "pending": sorted(self.pending),
            "keyframes": [{key: v for key, v in k.items() if key != "jpeg" and not key.startswith("_")}
                          for k in self.keyframes]}))
        saved.replace(self.out_dir / "last.json")

    # ---- controls -------------------------------------------------------------------
    def set_enabled(self, on: bool) -> None:
        if on != self.enabled:
            self.enabled = on
            self.hub.planner.note(f"Live 3D scan {'on' if on else 'off'}")

    def reset(self) -> None:
        """Start the scan over: forget every view and the current model (a rebuild in flight is discarded)."""
        self.blocked_batch = None
        self.fit_pivot = None
        self.consolidated = None
        self.sections.clear()
        self.keyframes.clear()
        self.pending.clear()
        self.previous_batch.clear()
        self.selection_hints.clear()
        self.selector = VisualSelector()
        self.sample_times.clear()
        self.pending_since = 0
        for p in self.hub.phones.values():
            p.scan_candidates.clear()
            p.scan_frame = None
        self.generation += 1
        self.placed = {}
        self.fit = {"scale": 1.0, "turnDeg": 0.0}
        self.last = None
        self.error = None
        for f in [*self.out_dir.glob("scan-*.glb"), *self.out_dir.glob("views/*.jpg"), self.out_dir / "last.json"]:
            f.unlink(missing_ok=True)
        self.hub.planner.note("🧊 Scan reset")

    def install_consolidated(self, filename: str, through: int) -> None:
        if self.running:
            raise ValueError("Wait for the current reconstruction before installing a cleaned map")
        if not self.last or not self.sections or through != max(s["version"] for s in self.sections):
            raise ValueError("Cleaned map must match the current section snapshot")
        if Path(filename).name != filename or not filename.startswith("clean-") or not filename.endswith(".glb"):
            raise ValueError("Invalid cleaned map filename")
        path = self.out_dir / filename
        if not path.exists() or path.read_bytes()[:4] != b"glTF":
            raise ValueError("Cleaned mesh is missing or invalid")
        self.consolidated = {"url": f"/web/models/live/{filename}", "throughVersion": through,
                             "autoTransform": {"scale": 1, "rotateYDeg": 0, "offset": [0, 0, 0]}}
        self.version += 1
        self.last["version"] = self.version
        self.last["consolidated"] = self.consolidated | {"transform": self.display(self.consolidated["autoTransform"])}
        self._save()
        self.hub.planner.note("Cleaned surface installed; original sections preserved")

    def adjust(self, scale: float | None = None, turn: float | None = None, reset: bool = False) -> None:
        f = self.fit
        if reset:
            f.update(scale=1.0, turnDeg=0.0)
        if scale:
            f["scale"] = max(0.05, min(20.0, f["scale"] * scale))
        if turn:
            f["turnDeg"] = (f["turnDeg"] + turn + 180) % 360 - 180
        if self.last:
            self.last["transform"] = self.display(self.last["autoTransform"])
            self.last["fit"] = dict(f)
            if self.consolidated:
                self.last["consolidated"] = self.consolidated | {"transform": self.display(self.consolidated["autoTransform"])}
            self.last["sections"] = [k | {"transform": self.display(k["autoTransform"])} for k in self.sections]
            self._save()

    def display(self, auto: dict) -> dict:
        """The operator's fit applied to the automatic transform, pivoting on where the cameras are."""
        f = self.fit
        if f["scale"] == 1.0 and f["turnDeg"] == 0.0 or not self.placed:
            return auto
        k, d = f["scale"], math.radians(f["turnDeg"])
        cx, cz = self.fit_pivot or (0, 0)
        ox, oy, oz = auto["offset"]
        # rotate (by d about Y, three.js convention) and scale the offset about the pivot
        rx, rz = (ox - cx) * math.cos(d) + (oz - cz) * math.sin(d), -(ox - cx) * math.sin(d) + (oz - cz) * math.cos(d)
        return {"scale": round(auto["scale"] * k, 4), "rotateYDeg": round(auto["rotateYDeg"] + f["turnDeg"], 2),
                "offset": [round(cx + k * rx, 3), round(k * oy, 3), round(cz + k * rz, 3)]}

    def status(self) -> dict:
        return {"enabled": self.enabled, "configured": bool(self.url), "workerOk": self.worker_ok,
                "running": self.running, "keyframes": len(self.keyframes), "maxKeyframes": MAX_ARCHIVE,
                "batchSize": self.batch_size, "maxBatch": SECTION_FRAMES, "sections": len(self.sections),
                "selectionMs": self.selection_ms,
                "selection": self.selector.status(),
                "selectionHints": {p.id: {"name": p.name or f"Phone {p.index}", "message": self.selection_hints[p.id]}
                                   for p in self.hub.phones.values() if p.connected and p.id in self.selection_hints},
                "newSince": len(self.pending), "runAfter": RUN_AFTER_NEW, "error": self.error,
                "paused": self.paused(),
                "last": self.last}

    # ---- sampling -------------------------------------------------------------------
    async def sample(self) -> None:
        now = now_ms()
        groups = {}
        for p in list(self.hub.phones.values()):
            if not p.connected or ((p.sim or p.build.endswith(("-drive", "-replay"))) and not self.include_sims):
                continue
            if self.native_only and not p.native:
                self.selection_hints[p.id] = 'Use the native iPhone app for this scan'
                continue
            if self.native_only and not self.keyframes and p.pose(now) is None:
                self.selection_hints[p.id] = 'Align the iPhone to the room before starting the map'
                continue
            if now - self.sample_times.get(p.id, 0) < 450:
                continue
            # Keep modern clients' sharp captures separate from preview traffic.
            candidates = [dict(c) for c in p.scan_candidates if now - c["at"] <= WINDOW_MS]
            if not candidates and p.scan_frame is None and p.frame and now - p.frame_at <= FRESH_MS:
                candidates = [{"jpeg": p.frame, "pose": p.pose(now), "pitch": p.pitch,
                               "orientation": p.frame_ori, "at": p.frame_at}]
            if not candidates:
                self.selection_hints[p.id] = 'Waiting for fresh camera frames'
                continue
            self.sample_times[p.id] = now
            p.scan_candidates.clear()
            groups[p.id] = []
            for c in candidates:
                pose = c.get("pose") or {}
                self.ids += 1
                groups[p.id].append({"id": f"k{self.ids}", "pid": p.id, "index": p.index,
                    "jpeg": c["jpeg"], "x": pose.get("x"), "y": pose.get("y"),
                    "heading": pose.get("heading"), "pitch": c.get("pitch"), "t": c["at"],
                    "up": camera_up(c.get("orientation"), c.get("pitch"))})
        if not groups:
            return
        gen = self.generation
        start = time.monotonic()
        # CPU image decoding/matching must not interrupt phone/WebSocket traffic.
        archive, added, hints = await asyncio.to_thread(
            self.selector.choose, groups, list(self.keyframes), set(self.previous_batch))
        if gen != self.generation:
            return
        self.selection_ms = round((time.monotonic() - start) * 1000, 1)
        self.keyframes = archive
        self.selection_hints.update(hints)
        retained = {k["id"] for k in archive}
        for k in added:
            if k["id"] not in retained:
                self.selection_hints[k["pid"]] = 'Map archive full; capture overlapping views nearer the mapped area'
        if added and not self.pending:
            self.pending_since = now_ms()
        self.pending = (self.pending | {k["id"] for k in added}) & retained

    def ready_to_rebuild(self, now):
        if self.running or len(self.keyframes) < MIN_FRAMES or not self.pending:
            return False
        if now - self.last_attempt < MAX_WAIT_MS:
            return False
        return len(self.pending) >= RUN_AFTER_NEW or now - self.pending_since >= MAX_WAIT_MS

    # ---- rebuilds -------------------------------------------------------------------
    async def loop(self) -> None:
        while True:
            await asyncio.sleep(0.5)
            if not self.enabled or not self.url or self.paused():
                continue
            try:
                await self.sample()
            except Exception as e:
                self.error = f"Frame selection: {_short(e)}"
                continue
            if self.ready_to_rebuild(now_ms()):
                asyncio.create_task(self.rebuild())

    def paused(self) -> bool:
        return self.hub.phase in PAUSED_PHASES

    async def rebuild(self) -> None:
        if self.running or len(self.keyframes) < 2 or self.paused():
            return
        self.running = True
        gen = self.generation
        try:
            await self._rebuild()
        except Exception as e:
            if gen == self.generation:
                self.error = _short(e)
                self.hub.planner.note(f"Scan update failed: {self.error}")
        finally:
            self.running = False

    async def _rebuild(self) -> None:
        frames = section_batch(self.keyframes, self.placed, self.pending)
        if len(self.sections) >= MAX_SECTIONS:
            self.error = "Section limit reached; current coverage preserved. Start a new scan for another area."
            return
        self.batch_size = len(frames)
        self.last_attempt = now_ms()
        if len(frames) < 2:
            self.error = "Need overlapping views before rebuilding"
            self.running = False
            return
        if self.pending and not self.pending.intersection(k["id"] for k in frames):
            self.error = "New views need a shorter overlap path to the mapped area"
            return
        signature = tuple(sorted(k["id"] for k in frames))
        if signature == self.blocked_batch:
            return
        gen = self.generation
        t0 = time.time()
        try:
            await self._ensure_tunnel()
            head = json.dumps({"frames": [{"id": k["id"], "size": len(k["jpeg"]), "up": k.get("up")} for k in frames],
                               "maxPoints": 150000}).encode()
            body = struct.pack(">I", len(head)) + head + b"".join(k["jpeg"] for k in frames)
            raw = await asyncio.to_thread(_post, f"{self.url}/reconstruct", body)
            (n,) = struct.unpack(">I", raw[:4])
            meta, glb = json.loads(raw[4:4 + n]), raw[4 + n:]
            self.worker_ok, self.error = True, None
        except Exception as e:
            self.error = _short(e)
            self.worker_ok = False
            self.running = False
            self.hub.planner.note(f"🧊 Scan rebuild failed: {self.error}")
            return
        if gen != self.generation:  # reset while this was running
            self.running = False
            return
        if self.sections:
            try:
                transform, alignment = register(meta["cameras"], self.placed)
            except ValueError as exc:
                self.blocked_batch = signature
                self.error = str(exc)
                self.hub.planner.note(self.error)
                return
        else:
            # Only one initial room pose sets the origin; later calibration changes
            # must never move an already reconstructed room.
            first = next((k for k in frames if k.get("x") is not None), None)
            anchor_frames = {first["id"]: first} if first else {}
            transform, alignment = align(meta["cameras"], anchor_frames, meta.get("medianDepth"))
            alignment["method"] = "initial visual anchor; camera-height scale estimate"
        alignment["leveledBy"] = meta.get("leveledBy")
        alignment["floorBy"] = meta.get("floorBy")
        for key, value in place(transform, meta["cameras"]).items():
            self.placed.setdefault(key, value)  # accepted anchors never drift
        self.blocked_batch = None
        if self.fit_pivot is None:
            self.fit_pivot = [sum(v[i] for v in self.placed.values()) / len(self.placed) for i in (0, 2)]
        self.previous_batch = [k["id"] for k in frames]
        self.pending.difference_update(self.previous_batch)
        self.pending_since = now_ms() if self.pending else 0
        self.version += 1
        self.out_dir.mkdir(parents=True, exist_ok=True)
        path = self.out_dir / f"scan-{self.version}.glb"
        path.write_bytes(glb)
        self.sections.append({"url": f"/web/models/live/{path.name}",
                              "autoTransform": transform, "frames": self.previous_batch[:],
                              "version": self.version})
        secs = round(time.time() - t0, 1)
        self.last = {"version": self.version, "url": f"/web/models/live/{path.name}", "transform": self.display(transform),
                     "autoTransform": transform, "fit": dict(self.fit),
                     "alignment": alignment, "frames": meta["frames"], "points": meta["points"],
                     "faces": meta.get("faces"), "representation": meta.get("representation", "points"),
                     "colorSpace": meta.get("colorSpace"), "quality": meta.get("quality"),
                     "phones": len({k["pid"] for k in frames}), "seconds": secs,
                     "gpuSeconds": meta.get("totalSeconds"), "t": time.time(),
                     # typical distance to what the cameras saw, after scaling: a quick sanity check on scale
                     "viewDistanceM": round(transform["scale"] * meta["medianDepth"], 2) if meta.get("medianDepth") else None}
        if self.consolidated:
            self.last["consolidated"] = self.consolidated | {"transform": self.display(self.consolidated["autoTransform"])}
        self.last["sections"] = [k | {"transform": self.display(k["autoTransform"])} for k in self.sections]
        self.running = False
        self._save()
        self.hub.planner.note(f"🧊 Scan v{self.version}: {meta['frames']} views, {meta['points']:,} points in {secs}s"
                              f" · {alignment['method']}")

    async def _ensure_tunnel(self) -> None:
        """Keep an SSH tunnel from LOCAL_PORT to the worker on the pod (when configured that way)."""
        ssh = os.environ.get("MAP_WORKER_SSH")
        if not ssh or os.environ.get("MAP_WORKER_URL"):
            return
        if self.tunnel and self.tunnel.returncode is None:
            return
        port = os.environ.get("MAP_WORKER_SSH_PORT", "22")
        remote = os.environ.get("MAP_WORKER_PORT", "8765")
        self.tunnel = await asyncio.create_subprocess_exec(
            "ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
            "-o", "StrictHostKeyChecking=accept-new", "-L", f"{self.local_port}:127.0.0.1:{remote}", "-p", port, ssh,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        for _ in range(40):  # wait for the forward to come up
            await asyncio.sleep(0.25)
            if self.tunnel.returncode is not None:
                err = (await self.tunnel.stderr.read()).decode()[-200:]
                raise RuntimeError(f"SSH tunnel failed: {err.strip() or 'exited'}")
            try:
                await asyncio.to_thread(_get, f"{self.url}/health")
                return
            except Exception:
                continue
        raise RuntimeError("worker didn't answer through the tunnel (is gpu/vggt_worker.py running on the pod?)")

    async def close(self) -> None:
        if self.tunnel and self.tunnel.returncode is None:
            self.tunnel.terminate()


def align(cameras: list[dict], frames: dict[str, dict], depth: float | None = None) -> tuple[dict, dict]:
    """Similarity transform (scale, rotation about vertical, offset) taking the scan into room meters.
    Output matches room.json's "scene" transform: scale, then rotate about Y, then offset [x, height, y].
    three.js rotation.y = θ adds θ to a direction's angle atan2(X, Z)."""
    pairs = [(c, frames[c["id"]]) for c in cameras if c["id"] in frames
             and all(frames[c["id"]].get(k) is not None for k in ("x", "y", "heading"))]
    if not pairs:
        heights = sorted(c["position"][1] for c in cameras)
        height = heights[len(heights) // 2] if heights else 0
        scale = max(.05, min(200., EYE_H / height)) if height > .01 else 1.
        return {"scale": round(scale, 4), "rotateYDeg": 0, "offset": [0, 0, 7]}, {
            "method": "visual map · estimated scale, not registered to phone positions", "residualM": None}
    # rotation: room heading h faces (X, Z) = (sin h, -cos h), i.e. angle atan2(X, Z) = π - h
    sx = sy = 0.0
    for c, k in pairs:
        f = c["forward"]
        diff = (math.pi - math.radians(k["heading"])) - math.atan2(f[0], f[2])
        sx, sy = sx + math.cos(diff), sy + math.sin(diff)
    theta = math.atan2(sy, sx)
    agreement = math.hypot(sx, sy) / len(pairs)  # 1 = every heading agrees on the rotation
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    q = [(c["position"][0] * cos_t + c["position"][2] * sin_t, -c["position"][0] * sin_t + c["position"][2] * cos_t)
         for c, _ in pairs]
    r = [(k["x"], k["y"]) for _, k in pairs]
    qc = (sum(a for a, _ in q) / len(q), sum(b for _, b in q) / len(q))
    rc = (sum(a for a, _ in r) / len(r), sum(b for _, b in r) / len(r))
    q_spread = math.sqrt(sum((a - qc[0]) ** 2 + (b - qc[1]) ** 2 for a, b in q) / len(q))
    r_spread = math.sqrt(sum((a - rc[0]) ** 2 + (b - rc[1]) ** 2 for a, b in r) / len(r))
    heights = sorted(c["position"][1] for c, _ in pairs)
    cam_h = heights[len(heights) // 2]
    places: list[tuple[float, float]] = []  # separate spots frames were taken from
    for pt in r:
        if all(math.dist(pt, o) > POSITION_CLUSTER_M for o in places):
            places.append(pt)
    # a scale from positions needs several separate places: two tapped seats say little about scale
    if len(places) >= MIN_PLACES_FOR_SCALE and r_spread >= 1.0 and q_spread > 1e-6:
        scale, method = r_spread / q_spread, "aligned by positions + headings"
    elif cam_h > 1e-3:
        scale, method = EYE_H / cam_h, "aligned by camera height + headings"
    else:
        scale, method = 1.0, "rotation only (no scale cue)"
    scale = max(0.05, min(scale, 200.0))
    if depth:  # sanity: people look at things roughly 0.6-8 m away indoors, not 30 m or 10 cm
        lo, hi = 0.6 / depth, 8.0 / depth
        if not lo <= scale <= hi:
            scale, method = min(max(scale, lo), hi), method + ", scale clamped to a plausible view distance"
    offset = [rc[0] - scale * qc[0], max(-1.0, min(1.0, EYE_H - scale * cam_h)), rc[1] - scale * qc[1]]
    residual = sum(math.dist((scale * a + offset[0], scale * b + offset[2]), rr) for (a, b), rr in zip(q, r)) / len(q)
    transform = {"scale": round(scale, 4), "rotateYDeg": round(math.degrees(theta), 2),
                 "offset": [round(v, 3) for v in offset]}
    return transform, {"method": method, "residualM": round(residual, 2), "headingAgreement": round(agreement, 2),
                       "views": len(pairs), "places": len(places)}


def place(transform: dict, cameras: list[dict]) -> dict[str, tuple[float, float, float]]:
    """Where each camera lands in the room (X, height, Z) under this transform."""
    s, th, (ox, oy, oz) = transform["scale"], math.radians(transform["rotateYDeg"]), transform["offset"]
    c, sn = math.cos(th), math.sin(th)
    return {cam["id"]: (s * (cam["position"][0] * c + cam["position"][2] * sn) + ox, s * cam["position"][1] + oy,
                        s * (-cam["position"][0] * sn + cam["position"][2] * c) + oz) for cam in cameras}


def steady(transform: dict, cameras: list[dict], prev: dict[str, tuple[float, float, float]]) -> tuple[dict, int]:
    """Keep consecutive scan versions from jumping around: the views both versions share should land
    where they did last time. Fit the correction taking this version's placement of the shared cameras
    to the previous one's, and apply STEADY of it, so the scan settles and slowly follows new evidence.
    Directions are complex numbers w = Z + iX, where multiplying by e^{iθ} is three.js rotation.y = θ."""
    now = place(transform, cameras)
    shared = [k for k in now if k in prev]
    if len(shared) < 3:
        return transform, 0
    n = [complex(now[k][2], now[k][0]) for k in shared]
    o = [complex(prev[k][2], prev[k][0]) for k in shared]
    nc, oc = sum(n) / len(n), sum(o) / len(o)
    den = sum(abs(v - nc) ** 2 for v in n)
    if den < 1e-9:
        return transform, 0
    a = sum((v - nc).conjugate() * (w - oc) for v, w in zip(n, o)) / den  # full correction: w ≈ a(v - nc) + oc
    if not 0.5 < abs(a) < 2:  # the versions disagree wildly: trust the new measurement
        return transform, 0
    a_part = abs(a) ** STEADY * complex(math.cos(STEADY * math.atan2(a.imag, a.real)),
                                        math.sin(STEADY * math.atan2(a.imag, a.real)))
    b = nc + STEADY * (oc - nc) - a_part * nc  # partial correction: w = a_part·v + b
    t = complex(transform["offset"][2], transform["offset"][0]) * a_part + b
    dy = STEADY * (sum(prev[k][1] for k in shared) - sum(now[k][1] for k in shared)) / len(shared)
    out = {"scale": round(transform["scale"] * abs(a_part), 4),
           "rotateYDeg": round(transform["rotateYDeg"] + math.degrees(math.atan2(a_part.imag, a_part.real)), 2),
           "offset": [round(t.imag, 3), round(transform["offset"][1] + dy, 3), round(t.real, 3)]}
    return out, len(shared)


def camera_up(ori: dict | None, pitch: float | None) -> list[float] | None:
    """Which way is up (against gravity) in a phone's camera image, in camera axes (x right, y down,
    z forward: OpenCV/VGGT). From the W3C device orientation that came with the frame: earth-up in
    device axes is the last row of R = Rz(alpha)·Rx(beta)·Ry(gamma); the back camera looks down device
    -Z with image y down device -Y. Falls back to pitch alone (assumes no roll)."""
    try:
        b, g = math.radians(float(ori["beta"])), math.radians(float(ori["gamma"]))
        dx, dy, dz = -math.cos(b) * math.sin(g), math.sin(b), math.cos(b) * math.cos(g)
        return [round(dx, 4), round(-dy, 4), round(-dz, 4)]
    except (TypeError, KeyError, ValueError):
        if pitch is None:
            return None
        p = math.radians(pitch)
        return [0.0, round(-math.cos(p), 4), round(math.sin(p), 4)]


def _turn(a: float, b: float) -> float:
    return abs((a - b + 540) % 360 - 180)


def _post(url: str, body: bytes) -> bytes:
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.read()


def _get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=3) as r:
        return r.read()


def _short(e: Exception) -> str:
    if hasattr(e, "read"):
        try:
            return json.loads(e.read()).get("error", str(e))[:160]
        except Exception:
            pass
    return str(e)[:160]
