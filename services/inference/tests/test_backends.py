import pytest

from beacon.backends import normalize_detections


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


def test_yolo_reuses_superset_prompt_without_leaking_other_classes():
    from types import SimpleNamespace

    from PIL import Image

    from beacon.backends import YoloDetector

    class Values:
        def __init__(self, values):
            self.values = values
        def cpu(self):
            return self
        def tolist(self):
            return self.values

    class Model:
        predictor = None
        calls = []
        def set_classes(self, labels):
            self.calls.append(labels)
        def predict(self, images, **kwargs):
            return [SimpleNamespace(names={0: 'person', 1: 'chair'}, boxes=SimpleNamespace(
                xyxy=Values([[1, 1, 9, 9], [2, 2, 8, 8]]),
                conf=Values([.9, .8]), cls=Values([0, 1])))]

    detector = YoloDetector.__new__(YoloDetector)
    detector.model = Model()
    detector.labels = ()
    detector.device = 'cpu'
    image = Image.new('RGB', (10, 10))
    detector.predict([image], ('chair', 'person'), .25)
    result = detector.predict([image], ('person',), .25)
    assert detector.model.calls == [['chair', 'person']]
    assert [d.label for d in result[0]] == ['person']
