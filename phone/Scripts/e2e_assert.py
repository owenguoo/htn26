"""Asserts what the hub believes about one phone. Run with the hub's own interpreter:

    uv run python phone/Scripts/e2e_assert.py --port 8077 --phone swarm-replay-e2e --alignment marker

Exits non-zero, naming every expectation that failed, if the hub's /api/state does
not show the phone the way a working client must look. Polls until --timeout, since
fps and latency need a couple of seconds of frames and a pong to exist at all.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request


def state(port: int) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=3) as r:
        return json.load(r)


def check(phone: dict | None, args: argparse.Namespace) -> list[str]:
    if phone is None:
        return [f"phone {args.phone} is not registered"]
    bad = []
    pose, debug = phone.get("pose") or {}, phone.get("debug") or {}

    def expect(ok: bool, what: str) -> None:
        if not ok:
            bad.append(what)

    expect(phone.get("connected") is True, "connected")
    expect(phone.get("device") == "iPhone", f"device == iPhone (got {phone.get('device')!r})")
    expect(phone.get("stale") is False, "stale == false")
    expect((phone.get("fps") or 0) > 0, f"fps > 0 (got {phone.get('fps')})")
    expect(phone.get("latencyMs") is not None, "latencyMs non-null")
    expect(debug.get("client") == "swarmsight-ios", "debug.client")
    expect(debug.get("alignment") == args.alignment,
           f"debug.alignment == {args.alignment} (got {debug.get('alignment')!r})")
    if args.alignment == "none":
        expect(pose.get("source") != "slam", "no slam pose while unaligned")
        expect(phone.get("calibrated") is False, "calibrated == false while unaligned")
    else:
        expect(pose.get("source") == "slam", f"pose.source == slam (got {pose.get('source')!r})")
        expect(pose.get("heading") is not None, "pose.heading non-null")
        expect(phone.get("calibrated") is True, "calibrated == true")
    if args.alignment == "marker":
        expect(len(debug.get("venuePosition") or []) == 3, "debug.venuePosition is 6DoF")
        expect(len(debug.get("venueQuaternion") or []) == 4, "debug.venueQuaternion is 6DoF")
    else:
        expect(debug.get("venuePosition") is None, "no venue 6DoF without a marker")
    if args.last_command:
        got = (debug.get("lastCommand") or {}).get("cmd")
        expect(got == args.last_command, f"debug.lastCommand.cmd == {args.last_command} (got {got!r})")
    if args.index is not None:
        expect(phone.get("index") == args.index, f"index == {args.index} (got {phone.get('index')})")
    if args.min_fps is not None:
        expect((phone.get("fps") or 0) >= args.min_fps, f"fps >= {args.min_fps} (got {phone.get('fps')})")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--phone", required=True)
    ap.add_argument("--alignment", choices=("marker", "seat", "none"), default="marker")
    ap.add_argument("--last-command")
    ap.add_argument("--index", type=int)
    ap.add_argument("--min-fps", type=float)
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--print-index", action="store_true")
    args = ap.parse_args()

    deadline, bad, phone = time.time() + args.timeout, ["never polled"], None
    while time.time() < deadline:
        try:
            phone = next((p for p in state(args.port)["phones"] if p["id"] == args.phone), None)
            bad = check(phone, args)
        except OSError as e:
            bad = [f"hub unreachable: {e}"]
        if not bad:
            break
        time.sleep(0.5)
    if bad:
        print("FAIL " + "; ".join(bad), file=sys.stderr)
        if phone:
            print(json.dumps(phone, indent=1)[:1500], file=sys.stderr)
        return 1
    if args.print_index:
        print(phone["index"])
    else:
        print(f"ok   #{phone['index']} {phone['pose']} fps={phone['fps']} latencyMs={phone['latencyMs']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
