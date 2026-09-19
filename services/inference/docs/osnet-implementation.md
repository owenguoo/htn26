# OSNet embedding adapter

`OSNetEmbedder(device="auto", model_path=None)` returns ordered, finite, L2-normalized 512-dimensional tuples.
It converts crops to RGB, resizes them to 256x128, and applies the standard ImageNet channel normalization used by the authors' feature extractor.
A per-instance lock serializes model access, including preprocessing, with batches of at most 32 images.
The default device follows the existing detector policy: CUDA when available, otherwise CPU.
Explicit supported PyTorch devices and local checkpoint paths are accepted.
Imports of Torch, Torchvision, and Hugging Face Hub are lazy so the basic service can import this module without the optional model stack.

## Provenance and downloads

The single vendored model source is [torchreid/models/osnet.py](https://github.com/KaiyangZhou/deep-person-reid/blob/f8cd150fdf77e8d9e1ed143b7f308c2c609ded50/torchreid/models/osnet.py), pinned to commit `f8cd150fdf77e8d9e1ed143b7f308c2c609ded50`.
Its upstream contents are unchanged, with only a provenance and Ruff-exemption header added.
The original source SHA-256 is `c7c1c29187d6330f859c91da229271531920464c7011aec13842a086b2263cae`.
The upstream MIT license, copyright 2018 Kaiyang Zhou, is preserved in `src/swarm_sight/_vendor/OSNET_LICENSE`.
Only the `osnet_x1_0(pretrained=False)` entry point is used, so the upstream ImageNet downloader and training dependencies are not executed.

The [author's Hugging Face repository](https://huggingface.co/kaiyangzhou/osnet/tree/a5c5cc037c24235cda3b21085b93ad77c9616224) supplies the weights at revision `a5c5cc037c24235cda3b21085b93ad77c9616224`.
The filename is `osnet_x1_0_msmt17_combineall_256x128_amsgrad_ep150_stp60_lr0.0015_b64_fb10_softmax_labelsmooth_flip_jitter.pth`.
The download is 17,273,805 bytes, cached by Hugging Face Hub in its standard cache location; `HF_HOME` or `HF_HUB_CACHE` can configure that location.
The inspected checkpoint is an ordered state dictionary with 567 entries, including a 4101x512 MSMT17 training classifier.
The adapter uses `torch.load(weights_only=True, map_location="cpu")`, discards exactly `classifier.weight` and `classifier.bias`, replaces the unused training classifier with an identity layer, and loads every remaining backbone entry with `strict=True`.
It never falls back to ImageNet weights or partially initialized backbone parameters.

## Verification

Tests were written before the adapter and initially failed because the OSNet module was absent.
`SWARM_TEST_REID=1 .venv/bin/pytest tests/test_osnet.py -q` passed all 9 tests, including a real pretrained CPU encode.
Tests cover input ordering, 32-item batching, RGB conversion, normalization, empty inputs, zero/nonfinite rejection, concurrent inference serialization, strict checkpoint loading, and the pinned default download.
The real test verifies repeated-image consistency and different output for different images.
A direct CPU encode returned two 512-dimensional vectors with norms 1.0000000931 and 1.0000000066; their cosine similarity was 0.3866623929 for synthetic red and blue images.
This verifies inference plumbing, not cross-camera person retrieval accuracy.
`ruff check src/swarm_sight/osnet.py src/swarm_sight/_vendor tests/test_osnet.py` passed.
The verification environment used Torch 2.10.0, Torchvision 0.25.0, Hugging Face Hub 1.32.0, and Pillow 12.3.0.
The real test is opt-in with `SWARM_TEST_REID=1`; ordinary tests do not download pretrained weights.
