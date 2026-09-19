#!/usr/bin/env python3
"""Generate ARReferenceImage marker artwork, and a print sheet at true size.

What makes an image work as an ARImageAnchor target is not what makes it look
good. ARKit tracks corner features, so a marker needs:

  - high contrast, and no grey (print and stage lighting eat midtones)
  - many corners, spread evenly, at several scales
  - NO repeating structure — a checkerboard or a QR-like grid gives ARKit many
    identical candidate matches and it either refuses the image or locks onto
    the wrong rotation, which silently mirrors your whole venue
  - asymmetry, so the four 90-degree rotations are distinguishable

Markers are generated as *geometry* — a list of rectangles — and then rendered
twice: to PNG for the app bundle, and to vector PDF for printing. Rendering the
print sheet from the PNG would resample it; drawn as vectors it stays sharp at
any size, and the file is a few kilobytes.

The PDF lays each marker out at the exact physical width recorded in
Fixtures/venue.json, with crop marks and the expected width printed beside it.
**Measure with a tape after printing anyway.** Printers scale, "fit to page"
scales, and a marker 2 cm wider than declared makes every distance in the venue
wrong by that ratio.
"""

import argparse
import json
import os
import random
import zlib

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VENUE = os.path.join(REPO, "Fixtures", "venue.json")
PNG_DIR = os.path.join(REPO, "mobile", "modules", "beacon", "ios", "Resources", "Markers")
PDF_PATH = os.path.join(REPO, "Resources", "markers-print.pdf")

GRID = 16          # coarse cells across the marker
QUIET = 0.08       # white border, as a fraction of the width


def build_geometry(marker_id, seed):
    """Rectangles in a 0..1 unit square, as (x, y, w, h), y down.

    Three scales of block, placed so no row or column repeats: a coarse
    asymmetric skeleton, a medium scatter, and fine detail that gives ARKit
    something to track at close range.
    """
    rng = random.Random(seed)
    rects = []
    inner = 1.0 - 2 * QUIET

    def cell(col, row, span_x=1, span_y=1, grid=GRID):
        step = inner / grid
        return (QUIET + col * step, QUIET + row * step, span_x * step, span_y * step)

    # A solid asymmetric anchor in one corner, different per marker: this is
    # what makes the four rotations tell each other apart.
    corner = rng.randrange(4)
    cx, cy = [(0, 0), (GRID - 5, 0), (0, GRID - 5), (GRID - 5, GRID - 5)][corner]
    rects.append(cell(cx, cy, 5, 5))
    rects.append(("white", cell(cx + 1, cy + 1, 3, 3)))
    rects.append(cell(cx + 2, cy + 2, 1, 1))

    # Coarse blocks, no two in the same row/column pair, so nothing tiles.
    taken = set()
    for _ in range(26):
        for _attempt in range(40):
            col = rng.randrange(GRID - 1)
            row = rng.randrange(GRID - 1)
            span_x = rng.choice([1, 1, 2, 2, 3])
            span_y = rng.choice([1, 1, 2, 2, 3])
            key = (col, row)
            if key in taken:
                continue
            if cx - span_x < col < cx + 5 and cy - span_y < row < cy + 5:
                continue  # keep the anchor clean
            taken.add(key)
            rects.append(cell(col, row, span_x, span_y))
            break

    # Fine detail at half-cell scale, for tracking up close.
    fine = GRID * 2
    for _ in range(90):
        col = rng.randrange(fine - 1)
        row = rng.randrange(fine - 1)
        step = inner / fine
        x, y = QUIET + col * step, QUIET + row * step
        if cx / GRID <= (x - QUIET) / inner < (cx + 5) / GRID and \
           cy / GRID <= (y - QUIET) / inner < (cy + 5) / GRID:
            continue
        rects.append((x, y, step, step))

    return rects


def normalise(rects):
    """Splits the mixed list into (black, white) rectangle lists."""
    black, white = [], []
    for item in rects:
        if isinstance(item[0], str):
            white.append(item[1])
        else:
            black.append(item)
    return black, white


# ------------------------------------------------------------------------ PNG


def render_png(path, black, white, pixels=1024):
    from PIL import ImageDraw

    image = Image.new("L", (pixels, pixels), 255)
    draw = ImageDraw.Draw(image)
    for colour, group in ((0, black), (255, white)):
        for x, y, w, h in group:
            draw.rectangle([x * pixels, y * pixels,
                            (x + w) * pixels - 1, (y + h) * pixels - 1], fill=colour)
    image.save(path, "PNG", optimize=True)
    return image


# Both thresholds below are calibrated against reference cases rather than
# guessed, because a guessed threshold either passes everything or cries wolf —
# the first version of this flagged perfectly good artwork:
#
#     case                transitions   repetition
#     blank white              0.0000        1.000
#     one big square           0.0049        0.966
#     8x8 checkerboard         0.0275        1.000
#     a generated marker       0.0423        0.760
#
# So: enough transitions to beat a single big shape, and self-similarity clearly
# below a grid's.
MIN_TRANSITIONS = 0.020
MAX_REPETITION = 0.85


def transition_density(image, size=256):
    """Fraction of neighbouring pixel pairs that straddle a contrast edge,
    measured at a fixed resolution so the number does not change when the export
    resolution does. This is the closest cheap proxy for "how many corners will
    ARKit find"."""
    from PIL import ImageChops
    small = image.convert("L").resize((size, size), Image.BILINEAR)
    total = differing = 0
    for dx, dy in ((1, 0), (0, 1)):
        shifted = ImageChops.offset(small, dx, dy)
        diff = ImageChops.difference(small, shifted).crop((dx, dy, size, size))
        values = list(diff.getdata())
        differing += sum(1 for v in values if v > 40)
        total += len(values)
    return differing / total


def repetition(image, size=128):
    """Highest self-similarity at a non-trivial shift.

    A checkerboard or any regular grid scores near 1. ARKit either refuses such
    an image or locks onto the wrong rotation, which silently mirrors the whole
    venue — the worst possible failure, because everything still looks
    plausible.
    """
    from PIL import ImageChops
    small = image.convert("L").resize((size, size), Image.BILINEAR)
    worst = 0.0
    for shift in range(4, size // 2, 2):
        shifted = ImageChops.offset(small, shift, 0)
        diff = ImageChops.difference(small, shifted).crop((shift, 0, size, size))
        values = list(diff.getdata())
        same = sum(1 for v in values if v < 40)
        worst = max(worst, same / len(values))
    return worst


# ------------------------------------------------------------------------ PDF


def pdf_escape(text):
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def build_pdf(path, markers):
    """One marker per page, drawn as vectors at its true physical width."""
    pages, objects = [], []
    mm = 72 / 25.4
    page_w, page_h = 210 * mm, 297 * mm  # A4 portrait

    for marker in markers:
        width_pt = marker["physicalWidth"] * 1000 * mm
        height_pt = width_pt
        # 20 mm of side margin: enough for any office printer's unprintable
        # edge, and still leaves room for a 180 mm marker at true size.
        if width_pt > page_w - 20 * mm or height_pt > page_h - 50 * mm:
            scale = min((page_w - 20 * mm) / width_pt, (page_h - 50 * mm) / height_pt)
            width_pt *= scale
            height_pt *= scale
            note = " (SCALED DOWN TO FIT A4 - DO NOT USE FOR MEASUREMENT)"
        else:
            note = ""
        ox = (page_w - width_pt) / 2
        oy = page_h - 40 * mm - height_pt

        parts = ["q", "0 0 0 rg"]
        for colour, group in ((0, marker["black"]), (1, marker["white"])):
            parts.append(f"{colour} {colour} {colour} rg")
            for x, y, w, h in group:
                # PDF y is up; the geometry's y is down.
                parts.append(f"{ox + x * width_pt:.3f} "
                             f"{oy + (1 - y - h) * height_pt:.3f} "
                             f"{w * width_pt:.3f} {h * height_pt:.3f} re f")
        parts.append("Q")

        # Crop marks at the true corners, so the width can be checked with a tape.
        parts.append("q 0 0 0 RG 0.5 w")
        for corner_x, corner_y in ((ox, oy), (ox + width_pt, oy),
                                   (ox, oy + height_pt), (ox + width_pt, oy + height_pt)):
            parts.append(f"{corner_x - 6} {corner_y} m {corner_x + 6} {corner_y} l S")
            parts.append(f"{corner_x} {corner_y - 6} m {corner_x} {corner_y + 6} l S")
        parts.append("Q")

        label = (f"{marker['id']}   width between crop marks: "
                 f"{marker['physicalWidth'] * 1000:.1f} mm{note}")
        parts.append("BT /F1 10 Tf 1 0 0 1 %.2f %.2f Tm (%s) Tj ET"
                     % (ox, oy - 18, pdf_escape(label)))
        parts.append("BT /F1 8 Tf 1 0 0 1 %.2f %.2f Tm (%s) Tj ET"
                     % (ox, oy - 32,
                        pdf_escape("Print at 100%. Do not use Fit to Page. Measure with a "
                                   "tape afterwards and put the real number in venue.json.")))
        pages.append("\n".join(parts).encode("latin-1"))

    # Minimal PDF: catalogue, page tree, one page + content stream each, one font.
    def add(body):
        objects.append(body)
        return len(objects)

    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids, content_ids = [], []
    for content in pages:
        stream = zlib.compress(content)
        content_ids.append(add(b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(stream)
                               + stream + b"\nendstream"))
        page_ids.append(None)

    pages_id = len(objects) + len(pages) + 1
    for index, content_id in enumerate(content_ids):
        page_ids[index] = add(
            b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.2f %.2f] "
            b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
            % (pages_id, page_w, page_h, font, content_id))

    kids = b" ".join(b"%d 0 R" % pid for pid in page_ids)
    actual_pages_id = add(b"<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(page_ids)))
    assert actual_pages_id == pages_id, (actual_pages_id, pages_id)
    catalog = add(b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id)

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets[1:]:
        out += b"%010d 00000 n \n" % offset
    out += (b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, catalog, xref))
    open(path, "wb").write(bytes(out))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pixels", type=int, default=1024)
    arguments = parser.parse_args()

    venue = json.load(open(VENUE))
    os.makedirs(PNG_DIR, exist_ok=True)

    markers = []
    failures = []
    for index, marker in enumerate(venue["markers"]):
        black, white = normalise(build_geometry(marker["id"], seed=1000 + index * 97))
        png_path = os.path.join(PNG_DIR, marker["id"] + ".png")
        image = render_png(png_path, black, white, arguments.pixels)
        transitions = transition_density(image)
        repeats = repetition(image)
        markers.append({"id": marker["id"], "physicalWidth": marker["physicalWidth"],
                        "black": black, "white": white})

        problems = []
        if transitions < MIN_TRANSITIONS:
            problems.append("TOO FEW FEATURES")
        if repeats > MAX_REPETITION:
            problems.append("TOO REPETITIVE")
        if problems:
            failures.append(marker["id"])
        flag = "   <-- " + ", ".join(problems) + ", regenerate" if problems else ""
        print(f"  {marker['id']:<20} {arguments.pixels}px  "
              f"{marker['physicalWidth'] * 1000:6.1f} mm  "
              f"transitions {transitions:.3f}  repetition {repeats:.2f}{flag}")

    build_pdf(PDF_PATH, markers)
    print(f"\nwrote {len(markers)} PNGs to {os.path.relpath(PNG_DIR, REPO)}")
    print(f"wrote print sheet to {os.path.relpath(PDF_PATH, REPO)} "
          f"({os.path.getsize(PDF_PATH) / 1024:.0f} KB)")
    if failures:
        raise SystemExit(f"\nunusable marker artwork: {', '.join(failures)}")


if __name__ == "__main__":
    main()
