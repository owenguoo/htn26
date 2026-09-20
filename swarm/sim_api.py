"""HTTP routes for the rescue simulator (the console's Simulator tab).

Kept apart from the live hub on purpose: nothing here reads or writes hub state, so a simulation
can't disturb a search in progress. Single runs are quick and go to a worker thread; batches are
minutes of CPU, so they run as a separate `python -m swarm.simulator batch` process and the page
polls for progress.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import uuid

from fastapi import FastAPI, HTTPException, Request

from . import command_sim, simulator
from .simulator import Environment, Params

MAX_SCAN_BYTES = 512 * 1024 * 1024
MAX_BATCH_RUNS = 200      # per team size
MAX_BATCH_SIZES = 8


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:32] or "environment"


def install_sim_routes(app: FastAPI, auth) -> None:
    jobs: dict[str, dict] = {}

    def environment(env_id: str) -> Environment:
        try:
            return simulator.load_environment(env_id)
        except KeyError:
            raise HTTPException(404, "no such environment") from None
        except (ValueError, json.JSONDecodeError) as e:
            raise HTTPException(422, f"environment can't be used: {e}") from None

    @app.get("/api/sim/envs")
    def sim_envs(request: Request) -> dict:
        auth.require_same_origin(request)
        return {"environments": simulator.list_environments()}

    @app.get("/api/sim/envs/{env_id}")
    def sim_env(env_id: str, request: Request) -> dict:
        auth.require_same_origin(request)
        env = environment(env_id)
        spec = env.spec
        # as stored ('.' floor, 'o' furniture, '#' wall, ' ' outside, 'f' fire, 's' smoke), plus '_' and '~'
        # for floor and smoke nobody can reach from an entry, so the page can show they aren't searched
        floor = env.floor.reshape(env.rows, env.cols)
        cut_off = {".": "_", "s": "~"}
        grid = ["".join(ch if ch not in cut_off or floor[r, c] else cut_off[ch] for c, ch in enumerate(row))
                for r, row in enumerate(spec["grid"])]
        lay = command_sim.layout(env)
        return {**env.summary(), "grid": grid,
                # rooms and doorways as the commander knows them (doorway cells 'd' divide the plan)
                "roomOf": lay.room_of.tolist(),
                "roomList": [{k: r[k] for k in ("id", "name", "areaM2", "x", "y")} for r in lay.rooms],
                "doors": [{k: d[k] for k in ("id", "x", "y", "rooms", "cells", "blockable")} for d in lay.doors], "rangeM": env.range, "fovDeg": env.fov,
                "wallHeightM": spec.get("wallHeightM", 2.6), "rooms": spec.get("rooms", []),
                "entryPoints": [{"name": e["name"], "x": e["x"], "y": e["y"]} for e in env.entries],
                "scan": spec.get("scan")}

    @app.post("/api/sim/envs")
    async def sim_env_save(request: Request) -> dict:
        """Save a floor plan drawn or traced in the console. Built-ins are never overwritten:
        editing one saves a copy."""
        auth.require_same_origin(request)
        body = await request.json()
        name = str(body.get("name") or "").strip()[:80]
        if not name:
            raise HTTPException(422, "give the environment a name")
        env_id = str(body.get("id") or "")
        existing = simulator.env_path(env_id) if env_id else None
        if not existing or existing.parent != simulator.USER_ENVS:
            base, n = _slug(name), 1
            env_id = base
            while simulator.env_path(env_id):
                n += 1
                env_id = f"{base}-{n}"
        spec = {"name": name, "description": str(body.get("description") or "")[:400],
                "source": "scan" if body.get("source") == "scan" else "drawn",
                "cell": body.get("cell"), "wallHeightM": float(body.get("wallHeightM") or 2.6),
                "entries": body.get("entries") or [], "rooms": body.get("rooms") or [],
                "grid": [str(row).replace("_", ".").replace("~", "s") for row in body.get("grid") or []]}
        scan = body.get("scan")
        if isinstance(scan, dict):
            # the scan file itself arrives separately (PUT …/scan); this is how it sits on the plan
            spec["scan"] = {"url": f"/web/sim/envs/user/{env_id}.glb",
                            "scale": float(scan.get("scale", 1)), "rotateYDeg": float(scan.get("rotateYDeg", 0)),
                            "offset": [float(v) for v in (scan.get("offset") or [0, 0, 0])][:3]}
        try:
            Environment({**spec, "id": env_id})
        except (ValueError, KeyError, TypeError) as e:
            raise HTTPException(422, f"that floor plan can't be simulated: {e}") from None
        simulator.USER_ENVS.mkdir(parents=True, exist_ok=True)
        (simulator.USER_ENVS / f"{env_id}.json").write_text(json.dumps(spec, indent=1) + "\n")
        return {"id": env_id}

    @app.put("/api/sim/envs/{env_id}/scan")
    async def sim_env_scan(env_id: str, request: Request) -> dict:
        """The 3D scan (.glb) a user environment was traced from, shown under the simulation."""
        auth.require_same_origin(request)
        path = simulator.env_path(env_id)
        if not path or path.parent != simulator.USER_ENVS:
            raise HTTPException(404, "save the environment first")
        tmp = simulator.USER_ENVS / f".{env_id}.{uuid.uuid4().hex}.part"
        size = 0
        try:
            with tmp.open("wb") as f:
                async for part in request.stream():
                    size += len(part)
                    if size > MAX_SCAN_BYTES:
                        raise HTTPException(413, "scan is over 512 MB: decimate it first")
                    f.write(part)
            with tmp.open("rb") as f:
                if f.read(4) != b"glTF":
                    raise HTTPException(415, "expected a binary glTF (.glb) file")
            os.replace(tmp, simulator.USER_ENVS / f"{env_id}.glb")
        finally:
            tmp.unlink(missing_ok=True)
        return {"ok": True, "bytes": size}

    @app.delete("/api/sim/envs/{env_id}")
    def sim_env_delete(env_id: str, request: Request) -> dict:
        auth.require_same_origin(request)
        path = simulator.env_path(env_id)
        if not path or path.parent != simulator.USER_ENVS:
            raise HTTPException(403, "built-in environments can't be deleted")
        path.unlink()
        path.with_suffix(".glb").unlink(missing_ok=True)
        return {"ok": True}

    @app.post("/api/sim/run")
    async def sim_run(request: Request) -> dict:
        auth.require_same_origin(request)
        body = await request.json()
        env = environment(str(body.get("env") or ""))
        try:
            params = Params.from_dict({**body, "record": True})
        except (TypeError, ValueError) as e:
            raise HTTPException(422, f"bad parameters: {e}") from None
        return await asyncio.to_thread(simulator.simulate, env, params)

    @app.post("/api/sim/compare")
    async def sim_compare(request: Request) -> dict:
        """The same building and hidden incident under each policy (swarm/command_sim.py)."""
        auth.require_same_origin(request)
        body = await request.json()
        env = environment(str(body.get("env") or ""))
        try:
            victim = body.get("victim")
            kwargs = {"rescuers": max(1, min(12, int(body.get("rescuers", 3)))),
                      "responders": max(1, min(12, int(body.get("responders", 2)))),
                      "max_time": max(30.0, min(3600.0, float(body.get("maxTime", 900)))),
                      "casualty": (float(victim["x"]), float(victim["y"])) if isinstance(victim, dict) else None}
            seed = int(body.get("seed", 0)) & 0x7FFFFFFF
        except (TypeError, ValueError, KeyError) as e:
            raise HTTPException(422, f"bad parameters: {e}") from None
        return await asyncio.to_thread(command_sim.compare, env.id, seed, **kwargs)

    @app.post("/api/sim/batch")
    async def sim_batch(request: Request) -> dict:
        auth.require_same_origin(request)
        body = await request.json()
        env = environment(str(body.get("env") or ""))
        try:
            sizes = sorted({max(1, min(12, int(s))) for s in body.get("teamSizes") or [1, 2, 4]})[:MAX_BATCH_SIZES]
            runs = max(1, min(MAX_BATCH_RUNS, int(body.get("runs", 30))))
            Params.from_dict(body)
        except (TypeError, ValueError) as e:
            raise HTTPException(422, f"bad parameters: {e}") from None
        for job in jobs.values():  # one batch at a time: a new one replaces the old
            if job["status"] == "running":
                job["process"].kill()
        params = {k: body[k] for k in ("seed", "start", "entry", "strategy", "responders", "maxTime", "walkSpeed") if k in body}
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "swarm.simulator", "batch", "--env", env.id, "--json",
            "--rescuers", ",".join(map(str, sizes)), "--runs", str(runs), "--params", json.dumps(params),
            cwd=simulator.ROOT, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        job = {"status": "running", "done": 0, "total": len(sizes) * runs, "result": None, "error": None,
               "process": process}
        job_id = uuid.uuid4().hex[:12]
        jobs[job_id] = job
        while len(jobs) > 8:
            jobs.pop(next(iter(jobs)))

        async def watch() -> None:
            async for line in process.stdout:
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "progress" in msg:
                    job["done"], job["total"] = msg["progress"], msg["total"]
                elif "result" in msg:
                    job["result"] = msg["result"]
            err = (await process.stderr.read()).decode(errors="replace").strip()
            code = await process.wait()
            if job["result"] is not None:
                job["status"] = "done"
            else:
                job["status"] = "cancelled" if code < 0 else "failed"
                job["error"] = err.splitlines()[-1] if err else f"simulator exited with {code}"

        job["task"] = asyncio.create_task(watch())
        return {"job": job_id, "total": job["total"]}

    @app.get("/api/sim/batch/{job_id}")
    def sim_batch_status(job_id: str, request: Request) -> dict:
        auth.require_same_origin(request)
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(404, "no such batch")
        return {k: job[k] for k in ("status", "done", "total", "result", "error")}

    @app.delete("/api/sim/batch/{job_id}")
    def sim_batch_cancel(job_id: str, request: Request) -> dict:
        auth.require_same_origin(request)
        job = jobs.get(job_id)
        if job and job["status"] == "running":
            job["process"].kill()
        return {"ok": True}
