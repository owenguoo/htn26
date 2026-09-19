import json

import pytest
from PIL import Image, ImageStat

from swarm_sight import cli, match_cli
from swarm_sight.schemas import Detection


class Detector:
    name = "yoloe"

    def predict(self, images, labels, confidence):
        assert labels == ("person",)
        return [
            [
                Detection(label="person", score=0.6, box=(0, 0, 10, 20)),
                Detection(label="person", score=0.95, box=(10, 0, 20, 20)),
            ]
            for _ in images
        ]


class Embedder:
    def __init__(self, *args, **kwargs):
        pass

    def encode(self, images):
        return [tuple(ImageStat.Stat(image).mean[:2]) + (0.0,) * 510 for image in images]


def test_match_cli_ranks_appearance_separately_from_detector_confidence(tmp_path, monkeypatch):
    reference = tmp_path / "reference.png"
    target = tmp_path / "target.png"
    Image.new("RGB", (20, 20), (255, 0, 0)).save(reference)
    frame = Image.new("RGB", (20, 20), (255, 0, 0))
    frame.paste(Image.new("RGB", (10, 20), (0, 255, 0)), (10, 0))
    frame.save(target)
    monkeypatch.setattr(match_cli, "load_detector", lambda *args: Detector())
    monkeypatch.setattr(match_cli, "OSNetEmbedder", Embedder)
    output, annotated = tmp_path / "match.json", tmp_path / "match.jpg"
    code = cli.main(
        [
            "match",
            str(reference),
            str(target),
            "--reference-box",
            "0",
            "0",
            "20",
            "20",
            "--similarity-threshold",
            "0.7",
            "--output",
            str(output),
            "--annotated",
            str(annotated),
        ]
    )
    assert code == 0
    result = json.loads(output.read_text())
    assert result["matched"] is True
    assert result["candidates"][0]["box"] == [0, 0, 10, 20]
    assert result["candidates"][0]["detection_score"] == 0.6
    assert result["candidates"][0]["similarity"] == pytest.approx(1)
    assert result["candidates"][1]["similarity"] == pytest.approx(0)
    assert annotated.is_file()


@pytest.mark.parametrize("threshold", ["nan", "inf", "1.01", "-1.1"])
def test_bad_similarity_threshold_is_rejected_before_model_load(threshold, monkeypatch):
    def unexpected(*args):
        pytest.fail("Invalid input reached model loading")

    monkeypatch.setattr(match_cli, "load_detector", unexpected)
    with pytest.raises(SystemExit):
        cli.main(["match", "reference.png", "query.png", "--similarity-threshold", threshold])
