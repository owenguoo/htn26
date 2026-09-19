"""People-only appearance matching, independent of model runtimes."""

import math
from collections.abc import Sequence
from typing import Protocol

from PIL import Image
from pydantic import BaseModel

from swarm_sight.schemas import Detection


class Embedder(Protocol):
    def encode(self, images: list[Image.Image]) -> list[tuple[float, ...]]: ...


class Candidate(BaseModel):
    box: tuple[float, float, float, float]
    detection_score: float
    similarity: float


class MatchSummary(BaseModel):
    candidates: list[Candidate]
    matched: bool
    similarity_threshold: float


def normalize_embedding(vector: Sequence[float]) -> tuple[float, ...]:
    if len(vector) != 512 or not all(math.isfinite(value) for value in vector):
        raise ValueError("Embedding must contain 512 finite values")
    norm = math.hypot(*vector)
    if norm == 0 or not math.isfinite(norm):
        raise ValueError("Embedding must have a finite nonzero norm")
    return tuple(value / norm for value in vector)


def select_reference(
    image: Image.Image,
    detections: Sequence[Detection],
    box: Sequence[float] | None = None,
) -> Image.Image:
    if box is None:
        people = [item for item in detections if item.label == "person"]
        if len(people) != 1:
            raise ValueError("Reference must contain exactly one person, or supply an explicit box")
        box = people[0].box
    if len(box) != 4 or not all(math.isfinite(value) for value in box):
        raise ValueError("Box must contain four finite xyxy coordinates")
    x1, y1, x2, y2 = box
    if not (0 <= x1 < x2 <= image.width and 0 <= y1 < y2 <= image.height):
        raise ValueError("Box must have positive area and lie inside the upright image")
    # Outward rounding preserves subpixel boxes without producing an empty crop.
    return image.crop((math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2))).convert("RGB")


def rank_candidates(
    image: Image.Image,
    detections: Sequence[Detection],
    reference_embedding: Sequence[float],
    embedder: Embedder,
    threshold: float,
) -> MatchSummary:
    if not math.isfinite(threshold) or not -1 <= threshold <= 1:
        raise ValueError("Similarity threshold must be finite and between -1 and 1")
    reference = normalize_embedding(reference_embedding)
    people = [item for item in detections if item.label == "person"]
    crops = [select_reference(image, [], item.box) for item in people]
    embeddings = embedder.encode(crops) if crops else []
    if len(embeddings) != len(people):
        raise ValueError("Embedder returned an incorrect batch length")
    candidates = [
        Candidate(
            box=person.box,
            detection_score=person.score,
            similarity=max(
                -1.0,
                min(
                    1.0,
                    math.fsum(
                        a * b
                        for a, b in zip(reference, normalize_embedding(embedding), strict=True)
                    ),
                ),
            ),
        )
        for person, embedding in zip(people, embeddings, strict=True)
    ]
    candidates.sort(key=lambda item: item.similarity, reverse=True)
    return MatchSummary(
        candidates=candidates,
        matched=bool(candidates and candidates[0].similarity >= threshold),
        similarity_threshold=threshold,
    )
