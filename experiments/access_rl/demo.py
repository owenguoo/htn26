"""Serve the simulation page on its own, without the hub."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .replay import ARTIFACTS, Replay

WEB = Path(__file__).resolve().parents[2] / "web"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--artifacts", type=Path, default=ARTIFACTS)
    p.add_argument("--port", type=int, default=8024)
    a = p.parse_args()
    replay = Replay(a.artifacts)

    class Handler(BaseHTTPRequestHandler):
        def send(self, data, mime="application/json", status=200):
            payload = data if isinstance(data, bytes) else json.dumps(data, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path in ("/", "/simulation"):
                self.send((WEB / "simulation.html").read_bytes(), "text/html; charset=utf-8")
            elif url.path == "/web/beacon_logo.png":
                self.send((WEB / "beacon_logo.png").read_bytes(), "image/png")
            elif url.path == "/api/simulation/report":
                self.send(replay.report)
            elif url.path == "/api/simulation/run":
                try:
                    q = parse_qs(url.query)
                    seed = int(q.get("seed", [replay.report["exampleSeed"]])[0])
                    self.send(replay.run(seed, q.get("baseline", ["greedy"])[0]))
                except ValueError as e:
                    self.send(dict(error=str(e)), status=400)
            else:
                self.send(dict(error="Not found"), status=404)

    print(f"Simulation page: http://127.0.0.1:{a.port}/simulation", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
