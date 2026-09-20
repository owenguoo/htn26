import math
import os
from pathlib import Path

from PIL import Image

from beacon.schemas import BackendName, Detection, Detector


def normalize_detections(
    boxes: list[list[float]],
    scores: list[float],
    labels: list[str],
    size: tuple[int, int],
    confidence: float,
) -> list[Detection]:
    detections = []
    width, height = size
    for box, score, label in zip(boxes, scores, labels, strict=True):
        if len(box) != 4 or not all(math.isfinite(v) for v in [*box, score]):
            continue
        if not confidence <= score <= 1:
            continue
        x1, y1, x2, y2 = box
        clipped = (
            max(0.0, min(width, x1)),
            max(0.0, min(height, y1)),
            max(0.0, min(width, x2)),
            max(0.0, min(height, y2)),
        )
        if clipped[0] < clipped[2] and clipped[1] < clipped[3]:
            detections.append(Detection(label=label, score=score, box=clipped))
    return sorted(detections, key=lambda detection: detection.score, reverse=True)


def resolve_device(device: str) -> str:
    import torch

    if device == "auto":
        return "cuda:0" if torch.cuda.is_available() else "cpu"
    if device.startswith("cuda") and not torch.cuda.is_available():
        raise RuntimeError("CUDA requested but unavailable; check the GPU driver and PyTorch build")
    if device == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("MPS requested but unavailable")
    torch.device(device)
    return device


class YoloDetector:
    def __init__(self, name: BackendName, device: str, model: str | None = None):
        # Dependency installation is explicit and locked, including the text encoder.
        os.environ["YOLO_AUTOINSTALL"] = "false"
        cache = Path(os.environ.get("SWARM_MODEL_CACHE", ".cache/models")).resolve()
        cache.mkdir(parents=True, exist_ok=True)
        os.environ.setdefault("YOLO_CONFIG_DIR", str(cache.parent / "ultralytics"))
        Path(os.environ["YOLO_CONFIG_DIR"]).expanduser().mkdir(parents=True, exist_ok=True)
        from ultralytics import YOLOE, YOLOWorld, settings

        settings.update({"weights_dir": str(cache), "sync": False})
        self.name = name
        self.device = resolve_device(device)
        default = "yolov8s-worldv2.pt" if name == "yolo-world" else "yoloe-11s-seg.pt"
        model_type = YOLOWorld if name == "yolo-world" else YOLOE
        self.model = model_type(model or str(cache / default)).to(self.device)
        self.labels: tuple[str, ...] = ()

    def predict(
        self, images: list[Image.Image], labels: tuple[str, ...], confidence: float
    ) -> list[list[Detection]]:
        # Reusing a superset avoids rebuilding YOLOE prompts and its predictor each frame.
        if not set(labels).issubset(self.labels):
            self.model.set_classes(list(labels))
            self.labels = labels
        try:
            results = self.model.predict(
                images,
                device=self.device,
                conf=confidence,
                imgsz=640,
                verbose=False,
                save=False,
                max_det=100,
            )
            return [
                [detection for detection in normalize_detections(
                    result.boxes.xyxy.cpu().tolist(),
                    result.boxes.conf.cpu().tolist(),
                    [result.names[int(index)] for index in result.boxes.cls.cpu().tolist()],
                    image.size,
                    confidence,
                ) if detection.label in labels]
                for image, result in zip(images, results, strict=True)
            ]
        finally:
            # Ultralytics retains source frames for visualization; the API discards them.
            if self.model.predictor is not None:
                self.model.predictor.batch = None
                self.model.predictor.results = None
                self.model.predictor.dataset = None
                self.model.predictor.plotted_img = None


class Sam3Detector:
    name = "sam3"

    def __init__(self, device: str, model: str | None = None):
        from transformers import Sam3Model, Sam3Processor

        self.device = resolve_device(device)
        source = model or "facebook/sam3"
        self.processor = Sam3Processor.from_pretrained(source)
        self.model = Sam3Model.from_pretrained(source).to(self.device).eval()

    def predict(
        self, images: list[Image.Image], labels: tuple[str, ...], confidence: float
    ) -> list[list[Detection]]:
        import torch

        detections: list[list[Detection]] = [[] for _ in images]
        with torch.inference_mode():
            inputs = self.processor(images=images, return_tensors="pt").to(self.device)
            vision = self.model.get_vision_features(pixel_values=inputs.pixel_values)
            for label in labels:
                text = self.processor(text=[label] * len(images), return_tensors="pt").to(
                    self.device
                )
                outputs = self.model(vision_embeds=vision, **text)
                results = self.processor.post_process_object_detection(
                    outputs,
                    threshold=confidence,
                    target_sizes=inputs["original_sizes"].tolist(),
                )
                for index, result in enumerate(results):
                    scores = result["scores"].cpu().tolist()
                    detections[index].extend(
                        normalize_detections(
                            result["boxes"].cpu().tolist(),
                            scores,
                            [label] * len(scores),
                            images[index].size,
                            confidence,
                        )
                    )
        return [
            sorted(items, key=lambda item: item.score, reverse=True)[:100] for items in detections
        ]


def load_detector(name: BackendName, device: str = "auto", model: str | None = None) -> Detector:
    if name == "sam3":
        return Sam3Detector(device, model)
    if name in {"yolo-world", "yoloe"}:
        return YoloDetector(name, device, model)
    raise ValueError(f"Unknown backend: {name}")
