import argparse
import importlib.metadata
import json
import math
import os
import secrets
import subprocess
import sys
from pathlib import Path
from statistics import median
from time import perf_counter

from beacon.backends import load_detector
from beacon.images import annotate, decode_image
from beacon.schemas import Query

BACKENDS = ("yolo-world", "yoloe", "sam3")


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("Must be positive")
    return number


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    print(f"Wrote {path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Beacon cloud GPU inference")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser(
        "serve", help="Start the API configured by SWARM_* environment variables"
    )
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=positive, default=8001)
    demo = commands.add_parser("demo", help="Run the phone camera testing page")
    demo.add_argument("--host", default="127.0.0.1")
    demo.add_argument("--port", type=positive, default=8001)
    demo.add_argument("--device", default="auto")
    for command in ("detect", "benchmark", "compare"):
        sub = commands.add_parser(command)
        sub.add_argument("images", type=Path, nargs="+" if command != "detect" else None)
        sub.add_argument("--labels", nargs="+", required=True)
        sub.add_argument("--device", default="auto")
        sub.add_argument("--confidence", type=float, default=0.25)
        sub.add_argument("--output", type=Path, default=Path(f"artifacts/{command}.json"))
        if command == "compare":
            sub.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(BACKENDS))
        else:
            sub.add_argument("--backend", choices=BACKENDS, default="yolo-world")
            sub.add_argument("--model", help="Trusted local checkpoint or model identifier")
        if command == "detect":
            sub.add_argument("--annotated", type=Path)
        else:
            sub.add_argument("--batch-size", type=positive, default=1)
            sub.add_argument("--warmup", type=positive, default=2)
            sub.add_argument("--runs", type=positive, default=5)
    from beacon import match_cli

    match_cli.configure_parser(
        commands.add_parser("match", help="Match a reference person with OSNet")
    )
    args = parser.parse_args(argv)
    if args.command == "match":
        return match_cli.run(args)
    if args.command == "demo":
        os.environ.setdefault("SWARM_API_KEY", secrets.token_urlsafe(32))
        os.environ["SWARM_DEMO_CODE"] = os.environ.get("SWARM_DEMO_CODE") or secrets.token_urlsafe(
            18
        )
        os.environ["SWARM_BACKEND"] = "yoloe"
        os.environ["SWARM_ENABLE_REID"] = "true"
        os.environ["SWARM_DEVICE"] = args.device
        print(f"Camera demo: http://localhost:{args.port}/demo", flush=True)
        print(f"Demo access code: {os.environ['SWARM_DEMO_CODE']}", flush=True)
        print("For a phone, use an HTTPS tunnel to this port and open /demo.", flush=True)
    if args.command in {"serve", "demo"}:
        import uvicorn

        uvicorn.run(
            "beacon.api:create_app",
            factory=True,
            host=args.host,
            port=args.port,
            workers=1,
            timeout_keep_alive=5,
        )
        return 0
    try:
        query = Query(
            phone_id="cli",
            frame_id="cli",
            captured_at=0,
            labels=args.labels,
            confidence=args.confidence,
        )
    except ValueError as error:
        parser.error(str(error))
    args.labels = list(dict.fromkeys(query.labels))
    if args.command == "compare":
        return compare(args)
    paths = [args.images] if args.command == "detect" else args.images
    images = [decode_image(path.read_bytes()) for path in paths]
    started = perf_counter()
    detector = load_detector(args.backend, args.device, args.model)
    load_ms = (perf_counter() - started) * 1000
    labels = tuple(args.labels)
    if args.command == "detect":
        started = perf_counter()
        detections = detector.predict(images, labels, args.confidence)[0]
        write_json(
            args.output,
            {
                "backend": detector.name,
                "width": images[0].width,
                "height": images[0].height,
                "load_ms": load_ms,
                "inference_ms": (perf_counter() - started) * 1000,
                "detections": [item.model_dump() for item in detections],
            },
        )
        if args.annotated:
            args.annotated.parent.mkdir(parents=True, exist_ok=True)
            annotate(images[0], detections).save(args.annotated)
        return 0
    batches = [
        images[index : index + args.batch_size] for index in range(0, len(images), args.batch_size)
    ]
    for _ in range(args.warmup):
        for batch in batches:
            detector.predict(batch, labels, args.confidence)
    latencies = []
    detections = []
    started = perf_counter()
    for run in range(args.runs):
        for batch in batches:
            batch_started = perf_counter()
            results = detector.predict(batch, labels, args.confidence)
            latencies.append((perf_counter() - batch_started) * 1000)
            if run == 0:
                detections.extend([[item.model_dump() for item in result] for result in results])
    elapsed = perf_counter() - started
    versions = {}
    for package in ("torch", "ultralytics", "transformers"):
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            pass
    write_json(
        args.output,
        {
            "backend": detector.name,
            "device": getattr(detector, "device", args.device),
            "model_override": args.model,
            "versions": versions,
            "labels": args.labels,
            "confidence": args.confidence,
            "images": [str(path) for path in paths],
            "load_ms": load_ms,
            "batch_size": args.batch_size,
            "warmup_runs": args.warmup,
            "runs": args.runs,
            "frames_processed": len(images) * args.runs,
            "batch_latency_ms": latencies,
            "p50_batch_ms": median(latencies),
            "p95_batch_ms": sorted(latencies)[math.ceil(len(latencies) * 0.95) - 1],
            "frames_per_second": len(images) * args.runs / elapsed,
            "detections": detections,
            "scope": (
                "Warm inference only; excludes upload, decode, queueing, and target confirmation"
            ),
        },
    )
    return 0


def compare(args: argparse.Namespace) -> int:
    results = {}
    failed = False
    for backend in args.backends:
        output = args.output.parent / f"{args.output.stem}-{backend}.json"
        command = [
            sys.executable,
            "-m",
            "beacon.cli",
            "benchmark",
            *[str(path) for path in args.images],
            "--backend",
            backend,
            "--labels",
            *args.labels,
            "--device",
            args.device,
            "--confidence",
            str(args.confidence),
            "--batch-size",
            str(args.batch_size),
            "--warmup",
            str(args.warmup),
            "--runs",
            str(args.runs),
            "--output",
            str(output),
        ]
        result = subprocess.run(command, check=False)
        if result.returncode:
            failed = True
            results[backend] = {"status": "failed", "exit_code": result.returncode}
        else:
            results[backend] = {"status": "ok", "report": json.loads(output.read_text())}
    write_json(args.output, results)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
