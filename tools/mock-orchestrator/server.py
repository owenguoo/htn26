#!/usr/bin/env python3
"""A stub orchestrator, so the phones have something real to talk to.

This is NOT the real orchestrator. The real one — with the dashboard, the feed
wall, cone rendering and the QR join flow — already exists and is running; see
CLAUDE.md. This exists so the iOS app can be developed and integration-tested
against a socket that behaves, and so somebody can sanity-check the wire format
without standing up the whole stack.

**If this disagrees with the real server, the real server wins.** Change
Packages/SwarmCore/Sources/SwarmCore/Wire.swift to match it, and change this
file to match Wire.swift. Never the other way round.

No third-party dependencies: the WebSocket handshake and framing are about
ninety lines and adding a dependency to a stub is not worth it.

    python3 tools/mock-orchestrator/server.py --port 8765

Point the app at ws://<this machine's LAN address>:8765/device.
"""

import argparse
import base64
import hashlib
import json
import os
import math
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# The server clock. Everything the phones report is converted into this domain
# by ClockSync, which is the entire reason Gate 2 exists.
def server_now():
    return time.time()


class WebSocket:
    """Just enough RFC 6455 to carry JSON text frames."""

    def __init__(self, connection, address):
        self.connection = connection
        self.address = address
        self.buffer = b""
        self.closed = False
        self.send_lock = threading.Lock()

    def request_path(self):
        """The path from the request line, e.g. /device or /viewer."""
        try:
            first = self.buffer.split(b"\r\n", 1)[0].decode("latin-1")
            return first.split(" ")[1]
        except (IndexError, UnicodeDecodeError):
            return "/"

    def serve_file(self, path, content_type):
        body = open(path, "rb").read()
        self.connection.sendall(
            ("HTTP/1.1 200 OK\r\n"
             f"Content-Type: {content_type}\r\n"
             f"Content-Length: {len(body)}\r\n"
             "Connection: close\r\n\r\n").encode() + body)

    def handshake(self):
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.connection.recv(4096)
            if not chunk:
                return False
            self.buffer += chunk
        header_blob, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        headers = {}
        for line in header_blob.decode("latin-1").split("\r\n")[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        key = headers.get("sec-websocket-key")
        if not key:
            # A plain browser request. Serve the debug page rather than dropping
            # the connection, so the URL the server prints is one you can open.
            return False
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.connection.sendall(
            ("HTTP/1.1 101 Switching Protocols\r\n"
             "Upgrade: websocket\r\n"
             "Connection: Upgrade\r\n"
             f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode()
        )
        return True

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.connection.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def receive(self):
        """Returns one message's payload bytes, or None on close."""
        payload = b""
        while True:
            first, second = self._read(2)
            final = first & 0x80
            opcode = first & 0x0F
            masked = second & 0x80
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if masked else None
            data = self._read(length)
            if mask:
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
            if opcode == 0x8:
                return None
            if opcode == 0x9:  # ping
                self._send_frame(data, opcode=0xA)
                continue
            if opcode == 0xA:
                continue
            payload += data
            if final:
                return payload

    def _send_frame(self, payload, opcode=0x1):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(length)
        elif length < 1 << 16:
            header.append(126)
            header += struct.pack(">H", length)
        else:
            header.append(127)
            header += struct.pack(">Q", length)
        with self.send_lock:
            self.connection.sendall(bytes(header) + payload)

    def send_json(self, obj):
        self._send_frame(json.dumps(obj).encode())

    def close(self):
        self.closed = True
        try:
            self.connection.close()
        except OSError:
            pass


class Device:
    def __init__(self, socket_wrapper):
        self.socket = socket_wrapper
        self.hello = None
        self.seq = 0
        self.poses = 0
        self.frames = 0
        self.depth_chunks = 0
        self.last_pose = None
        self.first_pose_at = None
        self.client_latencies = []

    def pose_rate(self):
        if not self.first_pose_at or self.poses < 2:
            return None
        elapsed = time.time() - self.first_pose_at
        return self.poses / elapsed if elapsed > 0 else None

    def record_latency(self, milliseconds):
        self.client_latencies.append(milliseconds)
        # Bounded: this runs for the whole demo.
        if len(self.client_latencies) > 500:
            del self.client_latencies[:-500]

    def latency_summary(self):
        if not self.client_latencies:
            return {}
        ordered = sorted(self.client_latencies)
        def pick(fraction):
            return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]
        return {"last": self.client_latencies[-1], "median": pick(0.5), "p95": pick(0.95),
                "count": len(self.client_latencies),
                "overBudget": sum(1 for v in self.client_latencies if v > 50)}

    def send(self, message_type, data):
        self.seq += 1
        self.socket.send_json({"v": 1, "type": message_type, "seq": self.seq, "data": data})


DEVICES = {}
DEVICES_LOCK = threading.Lock()
VIEWERS = []
VIEWERS_LOCK = threading.Lock()
VENUE = {"markers": []}
DASHBOARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")


def quaternion_yaw(q):
    """Rotation about venue +Y, measured from -Z toward +X, matching
    Geometry.yaw(of:) so the wedge on the plan points where the phone looks."""
    x, y, z, w = q
    # The camera's forward is local -Z rotated by q.
    fx = -2 * (x * z + w * y)
    fz = -(1 - 2 * (x * x + y * y))
    return math.atan2(fx, -fz)


def viewer_state():
    with DEVICES_LOCK:
        devices = {}
        for device_id, device in DEVICES.items():
            pose = device.last_pose or {}
            latency = device.latency_summary()
            devices[device_id] = {
                "position": pose.get("position"),
                "yaw": quaternion_yaw(pose["quaternion"]) if pose.get("quaternion") else None,
                "state": pose.get("trackingState"),
                "confidence": pose.get("confidence"),
                "fix": pose.get("lastCorrectionAge"),
                "stale": pose.get("stale", True),
                "poseHz": device.pose_rate(),
                "latency": latency,
            }
    return {"devices": devices, "markers": VENUE.get("markers", [])}


def broadcast_state():
    payload = json.dumps(viewer_state())
    with VIEWERS_LOCK:
        stale = []
        for viewer in VIEWERS:
            try:
                viewer._send_frame(payload.encode())
            except OSError:
                stale.append(viewer)
        for viewer in stale:
            VIEWERS.remove(viewer)


def viewer_pump():
    """The plan view redraws at a steady rate rather than on every pose, so a
    phone at 10 Hz does not turn into 10 browser repaints a second."""
    while True:
        time.sleep(0.2)
        try:
            broadcast_state()
        except Exception:
            pass


def handle(connection, address, verbose):
    socket_wrapper = WebSocket(connection, address)
    device = Device(socket_wrapper)
    try:
        # Read enough to see the request line before deciding what this is.
        while b"\r\n" not in socket_wrapper.buffer:
            chunk = connection.recv(4096)
            if not chunk:
                return
            socket_wrapper.buffer += chunk
        path = socket_wrapper.request_path()

        if path in ("/", "/index.html", "/dashboard"):
            socket_wrapper.serve_file(DASHBOARD, "text/html; charset=utf-8")
            return

        if not socket_wrapper.handshake():
            return

        if path == "/viewer":
            with VIEWERS_LOCK:
                VIEWERS.append(socket_wrapper)
            try:
                socket_wrapper._send_frame(json.dumps(viewer_state()).encode())
                while socket_wrapper.receive() is not None:
                    pass
            finally:
                with VIEWERS_LOCK:
                    if socket_wrapper in VIEWERS:
                        VIEWERS.remove(socket_wrapper)
            return
        while True:
            payload = socket_wrapper.receive()
            if payload is None:
                break
            try:
                envelope = json.loads(payload)
            except json.JSONDecodeError:
                print(f"  ! {address} sent something that is not JSON")
                continue
            handle_envelope(device, envelope, verbose)
    except (ConnectionError, OSError):
        pass
    finally:
        with DEVICES_LOCK:
            if device.hello:
                DEVICES.pop(device.hello.get("deviceID"), None)
        name = device.hello.get("deviceName") if device.hello else address
        print(f"- disconnected: {name}  "
              f"({device.poses} poses, {device.frames} frames, {device.depth_chunks} depth chunks)")
        socket_wrapper.close()


def handle_envelope(device, envelope, verbose):
    message_type = envelope.get("type")
    data = envelope.get("data", {})

    if message_type == "hello":
        device.hello = data
        with DEVICES_LOCK:
            DEVICES[data.get("deviceID")] = device
        print(f"+ hello: {data.get('deviceName')} ({data.get('deviceModel')}) "
              f"venue={data.get('venueID')} lidar={data.get('hasLiDAR')}")

    elif message_type == "ping":
        # The four-timestamp exchange. t1 is when we received it, t2 when we
        # reply; the phone stamps t3 itself and never trusts us to have done it.
        received = server_now()
        device.send("pong", {"id": data.get("id"), "t0": data.get("t0"),
                             "t1": received, "t2": server_now()})

    elif message_type == "pose":
        device.poses += 1
        if device.first_pose_at is None:
            device.first_pose_at = time.time()
        device.last_pose = data
        if verbose or device.poses % 50 == 1:
            position = data.get("position", [])
            formatted = ", ".join(f"{value:+.2f}" for value in position)
            print(f"  pose #{device.poses:<5} [{formatted}]  "
                  f"state={data.get('trackingState')} conf={data.get('confidence'):.2f} "
                  f"fix={data.get('lastCorrectionAge')} stale={data.get('stale')}")
        if data.get("lastCorrectionAge") is None:
            print("  ! pose arrived with no correction age — its origin is arbitrary "
                  "and must not be fused")

    elif message_type == "frame":
        device.frames += 1
        trace = data.get("trace") or {}
        stamps = {stamp["stage"]: stamp["t"] for stamp in trace.get("stamps", [])}
        if "capture" in stamps and "sent" in stamps:
            client_ms = (stamps["sent"] - stamps["capture"]) * 1000
            device.record_latency(client_ms)
            budget_note = "" if client_ms <= 50 else "  <- over the 50 ms client budget"
            print(f"  frame #{data.get('frameID')} {data.get('width')}x{data.get('height')} "
                  f"client {client_ms:.1f} ms{budget_note}")
        # A real server would append its own stages and send the trace back with
        # the resulting command. This stub just acknowledges.

    elif message_type == "depth":
        device.depth_chunks += 1
        scale = data.get("metricScale")
        scale_note = "no scale (not metric)" if scale is None else f"scale {scale:.3f}"
        print(f"  depth chunk #{data.get('chunkID')} source={data.get('source')} "
              f"{len(data.get('frames', []))} frames, {scale_note}")

    elif message_type == "pong":
        pass

    else:
        print(f"  ? unhandled message type {message_type!r}")


COUNTER = [0]


def build_command(verb, args, expires_ms=1500):
    """Returns a command payload, or None if the verb is not understood."""
    if verb == "flash":
        kind = {"flash": {"r": 1.0, "g": 0.2, "b": 0.0, "durationMs": int(args[0]) if args else 500}}
    elif verb == "arrow" and len(args) == 3:
        kind = {"arrow": {"target": [float(value) for value in args],
                          "bearingRadians": None, "label": "backpack"}}
    elif verb == "bearing" and len(args) >= 1:
        label = args[1] if len(args) > 1 else "target"
        kind = {"arrow": {"target": None, "bearingRadians": float(args[0]), "label": label}}
    elif verb == "buzz":
        kind = {"haptic": {"pattern": "sharp", "intensity": 1.0}}
    elif verb == "clear":
        kind = {"clear": {}}
    elif verb == "rates" and args:
        kind = {"setRates": {"poseHz": float(args[0]), "frameFPS": 1.5, "depthHz": 0.3}}
    else:
        return None
    COUNTER[0] += 1
    return {"id": f"cmd-{COUNTER[0]}", "serverTimestamp": server_now(),
            "kind": kind, "expiresInMs": expires_ms}


def broadcast(payload):
    with DEVICES_LOCK:
        targets = list(DEVICES.values())
    for device in targets:
        try:
            device.send("command", payload)
        except OSError:
            pass
    return len(targets)


def command_console():
    """A tiny REPL, so somebody can poke a phone by hand.

    Only started when stdin is a terminal. Reading stdin unconditionally meant
    that running the server with its input redirected — from a script, from CI,
    from anything in the background — hit EOF immediately and exited, which
    looked exactly like the server refusing connections.
    """
    print("\ncommands: flash [ms] | arrow <x> <y> <z> | bearing <rad> [label] | buzz | "
          "clear | rates <poseHz> | list | quit\n")
    while True:
        try:
            line = input("> ").strip().split()
        except (EOFError, KeyboardInterrupt):
            return
        if not line:
            continue
        verb, args = line[0], line[1:]

        if verb == "quit":
            os._exit(0)
        if verb == "list":
            with DEVICES_LOCK:
                for device_id, device in DEVICES.items():
                    print(f"  {device_id}  {device.hello.get('deviceName')}  "
                          f"{device.poses} poses")
            continue

        payload = build_command(verb, args)
        if payload is None:
            print("  ?")
            continue
        print(f"  sent {verb} to {broadcast(payload)} device(s)")


def demo_loop():
    """Cycles through every command kind, so the UI can be seen without typing.

    Useful for a screenshot pass and for checking a phone end to end before the
    demo: if all four show up on the handset, the command path works.
    """
    steps = [
        ("flash", ["4000"], 6),
        ("clear", [], 2),
        ("bearing", ["1.05", "backpack"], 6),
        ("clear", [], 2),
        ("buzz", [], 3),
        ("arrow", ["3", "1.5", "-2"], 6),
        ("clear", [], 3),
    ]
    while True:
        with DEVICES_LOCK:
            connected = bool(DEVICES)
        if not connected:
            time.sleep(1)
            continue
        for verb, args, hold in steps:
            payload = build_command(verb, args, expires_ms=hold * 1000)
            if payload is not None:
                print(f"  [demo] {verb} -> {broadcast(payload)} device(s)")
            time.sleep(hold)


def outbound_address():
    """The address a phone on the same wifi can actually reach.

    `gethostbyname(gethostname())` is the obvious thing and it is wrong: on many
    networks it resolves to 127.0.0.1, which is precisely the value somebody
    then copies into venue.json and spends twenty minutes wondering why the
    phone will not connect. Opening a UDP socket toward a public address makes
    the routing table pick the real outbound interface; nothing is sent.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # TEST-NET-1, guaranteed unroutable
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--verbose", action="store_true", help="print every pose")
    parser.add_argument("--demo", action="store_true",
                        help="cycle through every command kind once a device connects")
    arguments = parser.parse_args()

    venue_path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))), "Fixtures", "venue.json")
    try:
        VENUE.update(json.load(open(venue_path)))
    except OSError:
        print(f"could not read {venue_path}; the plan view will show no markers")

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((arguments.host, arguments.port))
    listener.listen(8)

    address = outbound_address()
    print(f"stub orchestrator on ws://{address}:{arguments.port}/device")
    print(f"debug plan view:   http://{address}:{arguments.port}/")
    print("this is NOT the real orchestrator or its dashboard; if they disagree, "
          "the real one wins")

    if sys.stdin.isatty():
        threading.Thread(target=command_console, daemon=True).start()
    else:
        print("stdin is not a terminal, so the command console is off. "
              "Use --demo to cycle commands automatically.")
    if arguments.demo:
        threading.Thread(target=demo_loop, daemon=True).start()
    threading.Thread(target=viewer_pump, daemon=True).start()

    while True:
        connection, peer = listener.accept()
        threading.Thread(target=handle, args=(connection, peer, arguments.verbose),
                         daemon=True).start()


if __name__ == "__main__":
    main()
