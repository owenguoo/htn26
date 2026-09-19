"""Opt in with SWARM_TEST_MODELS=yolo-world,yoloe (add sam3 after gated access)."""

import os
from pathlib import Path

import pytest

from beacon.backends import load_detector
from beacon.images import decode_image


@pytest.mark.model
@pytest.mark.parametrize("backend", ["yolo-world", "yoloe", "sam3"])
def test_pretrained_model_detects_bus_and_switches_prompts(backend):
    if backend not in os.environ.get("SWARM_TEST_MODELS", "").split(","):
        pytest.skip("Opt-in real pretrained weights test")
    source = Path(os.environ.get("SWARM_TEST_IMAGE", "artifacts/bus.jpg"))
    assert source.is_file(), "Download the official bus sample per README first"
    image = decode_image(source.read_bytes())
    detector = load_detector(backend, os.environ.get("SWARM_TEST_DEVICE", "cpu"))
    results = detector.predict([image, image], ("bus", "person"), 0.25)
    assert len(results) == 2
    for detections in results:
        assert any(item.label == "bus" for item in detections)
        for item in detections:
            x1, y1, x2, y2 = item.box
            assert 0 <= x1 < x2 <= image.width
            assert 0 <= y1 < y2 <= image.height
    people = detector.predict([image], ("person",), 0.25)[0]
    assert people
    assert {item.label for item in people} == {"person"}


@pytest.mark.model
def test_yolo_persists_configuration_in_requested_directory(tmp_path):
    import subprocess
    import sys

    if "yolo-world" not in os.environ.get("SWARM_TEST_MODELS", "").split(","):
        pytest.skip("Opt-in real pretrained weights test")
    config = tmp_path / "config"
    checkpoint = Path(".cache/models/yolov8s-worldv2.pt").resolve()
    environment = os.environ | {"YOLO_CONFIG_DIR": str(config)}
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from beacon.backends import YoloDetector; import sys; "
            "YoloDetector('yolo-world', 'cpu', sys.argv[1])",
            str(checkpoint),
        ],
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert (config / "Ultralytics/settings.json").is_file(), result.stdout
