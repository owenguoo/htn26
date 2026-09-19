from io import BytesIO

import pytest
from PIL import Image

from swarm_sight.images import decode_image


def test_decodes_rgb_and_applies_orientation():
    image = Image.new("RGB", (30, 20))
    exif = Image.Exif()
    exif[274] = 6
    data = BytesIO()
    image.save(data, "JPEG", exif=exif)
    assert decode_image(data.getvalue()).size == (20, 30)


def test_rejects_corruption_and_oversized_dimensions():
    with pytest.raises(ValueError):
        decode_image(b"not an image")
    data = BytesIO()
    Image.new("RGB", (100, 100)).save(data, "PNG")
    with pytest.raises(ValueError):
        decode_image(data.getvalue(), max_pixels=500)


def test_decoder_does_not_use_model_patched_format_discovery(monkeypatch):
    def patched_open(*args, **kwargs):
        raise ModuleNotFoundError("Optional HEIF plugin is unavailable")

    monkeypatch.setattr(Image, "open", patched_open)
    for kind in ("JPEG", "PNG"):
        data = BytesIO()
        Image.new("RGB", (10, 20)).save(data, kind)
        assert decode_image(data.getvalue()).size == (10, 20)
    for invalid in (b"bad", b"\xff\xd8\xffbroken", b"\x89PNG\r\n\x1a\nbroken"):
        with pytest.raises(ValueError):
            decode_image(invalid)
