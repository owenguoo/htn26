import argparse
import json
import math
from pathlib import Path
from time import perf_counter

from beacon.backends import load_detector
from beacon.images import annotate, decode_image
from beacon.matching import normalize_embedding, rank_candidates, select_reference
from beacon.osnet import OSNetEmbedder
from beacon.schemas import Detection


def similarity(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or not -1 <= number <= 1:
        raise argparse.ArgumentTypeError("Similarity threshold must be finite and between -1 and 1")
    return number


def confidence(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or not 0.01 <= number <= 1:
        raise argparse.ArgumentTypeError("Detection confidence must be between 0.01 and 1")
    return number


def configure_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("reference", type=Path)
    parser.add_argument("image", type=Path)
    parser.add_argument("--reference-box", nargs=4, type=float, metavar=("X1", "Y1", "X2", "Y2"))
    parser.add_argument("--similarity-threshold", type=similarity, required=True)
    parser.add_argument("--confidence", type=confidence, default=0.25)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--detector-model", help="Trusted YOLOE checkpoint override")
    parser.add_argument(
        "--reid-model", type=Path, help="Trusted MSMT17 OSNet x1.0 checkpoint override"
    )
    parser.add_argument("--output", type=Path, default=Path("artifacts/person-match.json"))
    parser.add_argument("--annotated", type=Path)


def run(args: argparse.Namespace) -> int:
    reference = decode_image(args.reference.read_bytes())
    image = decode_image(args.image.read_bytes())
    # Reject explicit box errors before loading either model.
    crop = select_reference(reference, [], args.reference_box) if args.reference_box else None
    started = perf_counter()
    detector = load_detector("yoloe", args.device, args.detector_model)
    embedder = OSNetEmbedder(device=args.device, model_path=args.reid_model)
    load_ms = (perf_counter() - started) * 1000
    started = perf_counter()
    if crop is None:
        reference_detections = detector.predict([reference], ("person",), args.confidence)[0]
        crop = select_reference(reference, reference_detections)
    reference_embedding = normalize_embedding(embedder.encode([crop])[0])
    detections = detector.predict([image], ("person",), args.confidence)[0]
    result = rank_candidates(
        image, detections, reference_embedding, embedder, args.similarity_threshold
    )
    output = result.model_dump() | {
        "detector": "yoloe",
        "embedder": "osnet_x1_0_msmt17",
        "device": args.device,
        "width": image.width,
        "height": image.height,
        "load_ms": load_ms,
        "pipeline_ms": (perf_counter() - started) * 1000,
        "reference": str(args.reference),
        "image": str(args.image),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, allow_nan=False) + "\n")
    if args.annotated:
        labels = [
            Detection(
                label=f"#{index + 1} sim {candidate.similarity:.2f} | det",
                score=candidate.detection_score,
                box=candidate.box,
            )
            for index, candidate in enumerate(result.candidates)
        ]
        args.annotated.parent.mkdir(parents=True, exist_ok=True)
        annotate(image, labels).save(args.annotated)
    print(f"Wrote {args.output}; match={result.matched}, candidates={len(result.candidates)}")
    return 0
