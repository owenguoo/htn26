import math

import pytest
from PIL import Image

from swarm_sight.matching import normalize_embedding, rank_candidates, select_reference
from swarm_sight.schemas import Detection


def vector(x=1, y=0):
    return (x, y) + (0,) * 510


class Embedder:
    def encode(self, images):
        return [vector(0, 1), vector(1, 0)][: len(images)]


def people():
    return [
        Detection(label="person", score=0.8, box=(0, 0, 10, 10)),
        Detection(label="person", score=0.7, box=(10, 0, 20, 10)),
    ]


def test_normalization_and_invalid_embeddings():
    assert normalize_embedding(vector(3, 4))[:2] == (0.6, 0.8)
    for invalid in [(), (1, 2), (0,) * 512, vector(math.nan), vector(math.inf)]:
        with pytest.raises(ValueError):
            normalize_embedding(invalid)


def test_reference_selection_and_bounds():
    image = Image.new("RGB", (20, 20))
    assert select_reference(image, people()[:1]).size == (10, 10)
    assert select_reference(image, [], (1, 2, 11, 12)).size == (10, 10)
    for detections in [[], people()]:
        with pytest.raises(ValueError):
            select_reference(image, detections)
    for box in [(-1, 0, 10, 10), (0, 0, 21, 10), (1, 0, 1, 10), (0, 0, math.nan, 2)]:
        with pytest.raises(ValueError):
            select_reference(image, [], box)


def test_rank_match_and_empty():
    image = Image.new("RGB", (20, 20))
    result = rank_candidates(image, people(), vector(), Embedder(), 0.9)
    assert result.matched
    assert [item.similarity for item in result.candidates] == [1, 0]
    assert result.candidates[0].detection_score == 0.7
    assert not rank_candidates(image, people()[:1], vector(), Embedder(), 0.9).matched
    assert not rank_candidates(image, [], vector(), Embedder(), 0.9).matched
    with pytest.raises(ValueError):
        rank_candidates(image, [], vector(), Embedder(), 1.1)
