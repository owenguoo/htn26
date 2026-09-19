from types import SimpleNamespace

import pytest
from PIL import Image

from beacon.backends import Sam3Detector


def test_sam3_boxes_use_original_sizes_without_materializing_masks():
    torch = pytest.importorskip("torch")
    transformers = pytest.importorskip("transformers")
    from transformers.feature_extraction_utils import BatchFeature

    class Processor:
        post_process_object_detection = (
            transformers.Sam3ImageProcessor().post_process_object_detection
        )

        def __call__(self, images=None, text=None, return_tensors=None):
            if images is not None:
                return BatchFeature(
                    {
                        "pixel_values": torch.zeros(len(images), 3, 2, 2),
                        "original_sizes": torch.tensor([[im.height, im.width] for im in images]),
                    }
                )
            return BatchFeature({"input_ids": torch.ones(len(text), 2, dtype=torch.long)})

    class Model:
        def get_vision_features(self, pixel_values):
            return pixel_values

        def __call__(self, vision_embeds, input_ids):
            batch_size = len(input_ids)
            return SimpleNamespace(
                pred_boxes=torch.tensor([[[0.1, 0.2, 0.8, 0.9]]] * batch_size),
                pred_logits=torch.full((batch_size, 1), 3.0),
                presence_logits=torch.full((batch_size, 1), 3.0),
            )

    detector = Sam3Detector.__new__(Sam3Detector)
    detector.device = "cpu"
    detector.processor = Processor()
    detector.model = Model()
    results = detector.predict(
        [Image.new("RGB", (100, 50)), Image.new("RGB", (50, 100))], ("toy", "bag"), 0.5
    )
    assert len(results) == 2
    assert {item.label for item in results[0]} == {"toy", "bag"}
    assert results[0][0].box == pytest.approx((10, 10, 80, 45))
    assert results[1][0].box == pytest.approx((5, 20, 40, 90))
    assert results[0][0].score == pytest.approx(0.9074, abs=0.0001)
