"""MSMT17-trained OSNet person appearance embeddings."""

from pathlib import Path
from threading import Lock

from PIL import Image

from swarm_sight.backends import resolve_device

MODEL_REPO = "kaiyangzhou/osnet"
MODEL_REVISION = "a5c5cc037c24235cda3b21085b93ad77c9616224"
MODEL_FILENAME = (
    "osnet_x1_0_msmt17_combineall_256x128_amsgrad_ep150_stp60_lr0.0015_"
    "b64_fb10_softmax_labelsmooth_flip_jitter.pth"
)


class OSNetEmbedder:
    def __init__(self, device: str = "auto", model_path: str | Path | None = None):
        import torch
        from torchvision import transforms

        from swarm_sight._vendor.osnet import osnet_x1_0

        self.device = resolve_device(device)
        self._lock = Lock()
        if model_path is None:
            from huggingface_hub import hf_hub_download

            model_path = hf_hub_download(
                repo_id=MODEL_REPO, filename=MODEL_FILENAME, revision=MODEL_REVISION
            )
        # The checkpoint's classifier predicts training identities, not appearance features.
        self.model = osnet_x1_0(num_classes=1, pretrained=False)
        self.model.classifier = torch.nn.Identity()
        weights = torch.load(model_path, map_location="cpu", weights_only=True)
        if not isinstance(weights, dict):
            raise ValueError("OSNet checkpoint must contain a state dictionary")
        weights = {
            k: v for k, v in weights.items() if k not in {"classifier.weight", "classifier.bias"}
        }
        self.model.load_state_dict(weights, strict=True)
        self.model.to(self.device).eval()
        self._transform = transforms.Compose(
            [
                transforms.Resize((256, 128)),
                transforms.ToTensor(),
                transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
            ]
        )

    def encode(self, images: list[Image.Image]) -> list[tuple[float, ...]]:
        if not images:
            return []
        import torch

        embeddings: list[tuple[float, ...]] = []
        with self._lock, torch.inference_mode():
            for start in range(0, len(images), 32):
                batch = torch.stack(
                    [self._transform(image.convert("RGB")) for image in images[start : start + 32]]
                ).to(self.device)
                features = self.model(batch)
                if features.shape != (len(batch), 512) or not torch.isfinite(features).all():
                    raise ValueError("OSNet returned an invalid embedding")
                norms = features.norm(p=2, dim=1, keepdim=True)
                if not torch.isfinite(norms).all() or (norms <= 0).any():
                    raise ValueError("OSNet returned a zero or invalid embedding")
                embeddings.extend(tuple(row) for row in (features / norms).cpu().tolist())
        return embeddings
