from io import BytesIO

from PIL import Image, ImageDraw, ImageFont, ImageOps
from PIL.JpegImagePlugin import JpegImageFile
from PIL.PngImagePlugin import PngImageFile

from swarm_sight.schemas import Detection


def decode_image(data: bytes, max_pixels: int = 4_000_000) -> Image.Image:
    try:
        # Explicit decoders avoid Ultralytics' global Image.open HEIF fallback.
        if data.startswith(b"\xff\xd8\xff"):
            decoder = JpegImageFile
        elif data.startswith(b"\x89PNG\r\n\x1a\n"):
            decoder = PngImageFile
        else:
            raise ValueError("Only JPEG and PNG images are supported")
        with decoder(BytesIO(data)) as image:
            if image.width * image.height > max_pixels:
                raise ValueError(f"Image exceeds {max_pixels} pixels")
            image.load()
            return ImageOps.exif_transpose(image).convert("RGB")
    except (SyntaxError, OSError, Image.DecompressionBombError) as error:
        raise ValueError("Invalid image") from error


def annotate(image: Image.Image, detections: list[Detection]) -> Image.Image:
    output = image.copy()
    draw = ImageDraw.Draw(output)
    font = ImageFont.load_default(size=max(14, min(32, image.width // 40)))
    for detection in detections:
        draw.rectangle(detection.box, outline="#00ff88", width=3)
        label = f"{detection.label} {detection.score:.2f}"
        bounds = draw.textbbox((0, 0), label, font=font)
        width, height = bounds[2] + 8, bounds[3] + 6
        x = min(detection.box[0], max(0, image.width - width))
        y = max(0, detection.box[1] - height)
        draw.rectangle((x, y, x + width, y + height), fill="#10251d")
        draw.text((x + 4, y + 2), label, font=font, fill="white")
    return output
