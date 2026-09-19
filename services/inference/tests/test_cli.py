import json

import pytest
from PIL import Image

from swarm_sight import cli
from swarm_sight.schemas import Detection


class Detector:
    name = "test"
    device = "cpu"

    def predict(self, images, labels, confidence):
        return [[Detection(label=labels[0], score=0.8, box=(0, 0, 5, 5))] for _ in images]


def test_detect_writes_structured_and_annotated_output(tmp_path, monkeypatch):
    image = tmp_path / "input.png"
    Image.new("RGB", (10, 10)).save(image)
    monkeypatch.setattr(cli, "load_detector", lambda *args: Detector())
    output, annotated = tmp_path / "out.json", tmp_path / "out.jpg"
    assert (
        cli.main(
            [
                "detect",
                str(image),
                "--labels",
                "toy",
                "--output",
                str(output),
                "--annotated",
                str(annotated),
            ]
        )
        == 0
    )
    assert json.loads(output.read_text())["detections"][0]["label"] == "toy"
    with Image.open(annotated) as result_image:
        assert result_image.size == (10, 10)


def test_benchmark_counts_frames_including_partial_batches(tmp_path, monkeypatch):
    images = []
    for index in range(3):
        path = tmp_path / f"{index}.png"
        Image.new("RGB", (10, 10)).save(path)
        images.append(str(path))
    monkeypatch.setattr(cli, "load_detector", lambda *args: Detector())
    output = tmp_path / "bench.json"
    assert (
        cli.main(
            [
                "benchmark",
                *images,
                "--labels",
                "toy",
                "--batch-size",
                "2",
                "--warmup",
                "1",
                "--runs",
                "2",
                "--output",
                str(output),
            ]
        )
        == 0
    )
    result = json.loads(output.read_text())
    assert result["frames_processed"] == 6
    assert len(result["batch_latency_ms"]) == 4
    assert result["frames_per_second"] > 0
    assert len(result["detections"]) == 3


@pytest.mark.parametrize(
    "args", [["benchmark", "x", "--labels", "toy", "--runs", "0"], ["detect", "x", "--labels", " "]]
)
def test_invalid_cli_inputs_fail_before_loading_model(args, monkeypatch):
    def unexpected(*args):
        pytest.fail("Invalid inputs reached the model loader")

    monkeypatch.setattr(cli, "load_detector", unexpected)
    with pytest.raises(SystemExit):
        cli.main(args)


def test_demo_starts_people_service_without_exposing_service_key(monkeypatch, capsys):
    import os

    import uvicorn

    seen = {}
    monkeypatch.setenv("SWARM_DEMO_CODE", "")
    monkeypatch.setenv("SWARM_BACKEND", "yolo-world")
    monkeypatch.setenv("SWARM_ENABLE_REID", "false")
    monkeypatch.setenv("SWARM_DEVICE", "cpu")
    monkeypatch.setenv("SWARM_API_KEY", "private-service-secret")

    def run(*args, **kwargs):
        seen.update(kwargs)
        assert os.environ["SWARM_BACKEND"] == "yoloe"
        assert os.environ["SWARM_ENABLE_REID"] == "true"
        assert len(os.environ["SWARM_DEMO_CODE"]) >= 16

    monkeypatch.setattr(uvicorn, "run", run)
    assert cli.main(["demo", "--port", "8765"]) == 0
    assert seen["port"] == 8765
    assert "private-service-secret" not in capsys.readouterr().out


def test_serve_defaults_to_inference_port(monkeypatch):
    import uvicorn

    seen = {}
    monkeypatch.setattr(uvicorn, "run", lambda *args, **kwargs: seen.update(kwargs))

    assert cli.main(["serve"]) == 0
    assert seen["port"] == 8001
