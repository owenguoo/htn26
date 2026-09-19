import math
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from PIL import Image


def test_osnet_module_available():
    from beacon.osnet import OSNetEmbedder

    assert callable(OSNetEmbedder)


@pytest.fixture
def embedder(monkeypatch, tmp_path):
    torch = pytest.importorskip("torch")
    from beacon._vendor import osnet as architecture
    from beacon.osnet import OSNetEmbedder

    class Backbone(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.scale = torch.nn.Parameter(torch.ones(1))
            self.classifier = torch.nn.Linear(512, 2)
            self.batch_sizes = []
            self.active = threading.Lock()
            self.invalid = None

        def forward(self, batch):
            assert not torch.is_grad_enabled()
            assert self.active.acquire(blocking=False)
            try:
                time.sleep(0.005)
                self.batch_sizes.append(len(batch))
                result = torch.ones((len(batch), 512))
                result[:, 0] = batch[:, 0].mean(dim=(1, 2))
                if self.invalid is not None:
                    result[:] = self.invalid
                return result
            finally:
                self.active.release()

    model = Backbone()
    path = tmp_path / "weights.pth"
    torch.save(model.state_dict(), path)
    monkeypatch.setattr(architecture, "osnet_x1_0", lambda **kwargs: model)
    return OSNetEmbedder(device="cpu", model_path=path)


def test_encoding_batches_preserves_order_and_normalizes(embedder):
    images = [Image.new("RGB", (16, 32), (i * 3, 0, 0)) for i in range(65)]
    vectors = embedder.encode(images)
    assert embedder.model.batch_sizes == [32, 32, 1]
    assert len(vectors) == 65
    assert all(isinstance(v, tuple) and len(v) == 512 for v in vectors)
    assert all(math.isclose(sum(x * x for x in v), 1, abs_tol=1e-6) for v in vectors)
    assert [v[0] for v in vectors] == sorted(v[0] for v in vectors)
    assert embedder.encode([]) == []
    assert len(embedder.encode([Image.new("L", (16, 32))])[0]) == 512


@pytest.mark.parametrize("invalid", [0.0, float("nan"), float("inf")])
def test_invalid_model_vectors_fail(embedder, invalid):
    embedder.model.invalid = invalid
    with pytest.raises(ValueError, match="embedding"):
        embedder.encode([Image.new("RGB", (16, 32))])


def test_concurrent_calls_serialize_model_access(embedder):
    image = Image.new("RGB", (16, 32))
    with ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(lambda _: embedder.encode([image]), range(8)))
    assert all(result == results[0] for result in results)


@pytest.mark.model
@pytest.mark.skipif(os.environ.get("SWARM_TEST_REID") != "1", reason="Set SWARM_TEST_REID=1")
def test_pretrained_osnet_real_encoding():
    from beacon.osnet import OSNetEmbedder

    model = OSNetEmbedder(device="cpu")
    images = [Image.new("RGB", (128, 256), color) for color in ("red", "blue", "red")]
    vectors = model.encode(images)
    assert len(vectors) == 3
    assert all(len(v) == 512 and all(math.isfinite(x) for x in v) for v in vectors)
    assert all(math.isclose(sum(x * x for x in v), 1, abs_tol=1e-6) for v in vectors)
    assert vectors[0] == pytest.approx(vectors[2], abs=1e-6)
    assert sum(x * y for x, y in zip(vectors[0], vectors[1], strict=True)) < 0.999


def test_checkpoint_requires_complete_backbone(embedder, tmp_path):
    import torch

    from beacon.osnet import OSNetEmbedder

    path = tmp_path / "incomplete.pth"
    torch.save({}, path)
    with pytest.raises(RuntimeError, match="Missing key"):
        OSNetEmbedder(device="cpu", model_path=path)


def test_default_download_uses_pinned_reid_weights(embedder, monkeypatch, tmp_path):
    import huggingface_hub
    import torch

    from beacon.osnet import MODEL_FILENAME, MODEL_REPO, MODEL_REVISION, OSNetEmbedder

    path = tmp_path / "weights.pth"
    torch.save(embedder.model.state_dict(), path)
    calls = []

    def download(**kwargs):
        calls.append(kwargs)
        return str(path)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", download)
    OSNetEmbedder(device="cpu")
    assert calls == [dict(repo_id=MODEL_REPO, filename=MODEL_FILENAME, revision=MODEL_REVISION)]
    assert len(MODEL_REVISION) == 40
    assert "msmt17" in MODEL_FILENAME
