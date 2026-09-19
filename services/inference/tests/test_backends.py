import pytest

from swarm_sight.backends import normalize_detections


def test_normalization_clips_boxes_filters_invalid_predictions_and_sorts():
    detections = normalize_detections(
        boxes=[[-3, 2, 200, 40], [4, 4, 4, 10], [1, 1, 5, 5], [0, 0, 3, 3]],
        scores=[0.8, 0.9, float("nan"), 0.2],
        labels=["toy", "toy", "toy", "bag"],
        size=(100, 50),
        confidence=0.25,
    )
    assert [d.model_dump() for d in detections] == [
        {"label": "toy", "score": 0.8, "box": (0.0, 2.0, 100.0, 40.0)}
    ]


def test_normalization_rejects_misaligned_model_outputs():
    with pytest.raises(ValueError):
        normalize_detections([[0, 0, 1, 1]], [], ["toy"], (10, 10), 0.25)
