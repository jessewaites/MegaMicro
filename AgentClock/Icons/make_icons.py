#!/usr/bin/env python3
"""Render AgentClock's hand-drawn pixel art into GIFs the clock can display.

    python3 Icons/make_icons.py

Source lives in `Icons/src/*.json` as character grids plus a palette, because a
grid you can read as a picture is a grid you can edit:

    {
      "palette": {".": "#000000", "o": "#D97757"},
      "frames": [["...oo...", "..o..o..", ...]],
      "delayMs": 120
    }

Output is `Icons/build/<name>.gif`, and the icon's ID on the device is that
filename without the extension — so `acclaude.gif` is `"icon": "acclaude"`.

Why GIF and not JPEG, which AWTRIX also accepts: at 8x8 a JPEG is a single DCT
block, so a logo's hard edges come back ringing and muddy. GIF is palettized and
pixel-exact. It is also the only animated format the firmware takes, so adding
frames to a source file is the entire cost of animating a mark later.

Constraints the firmware imposes:
  - Icons are at most 32x8. A GIF with any frame larger is rejected outright,
    not cropped.
  - Frame delays below 100ms are clamped up to 100ms.
  - "." is drawn as black, which on an LED panel is simply off.
"""

import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  python3 -m pip install Pillow")

HERE = pathlib.Path(__file__).parent
SRC = HERE / "src"
BUILD = HERE / "build"

MAX_WIDTH, MAX_HEIGHT = 32, 8


def parse_hex(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def render_frame(rows, palette):
    height = len(rows)
    width = len(rows[0])
    if any(len(row) != width for row in rows):
        raise ValueError("all rows in a frame must be the same width")
    if width > MAX_WIDTH or height > MAX_HEIGHT:
        raise ValueError(f"{width}x{height} exceeds the {MAX_WIDTH}x{MAX_HEIGHT} icon limit")

    image = Image.new("RGB", (width, height), (0, 0, 0))
    pixels = image.load()
    for y, row in enumerate(rows):
        for x, key in enumerate(row):
            if key not in palette:
                raise ValueError(f"'{key}' is not in the palette")
            pixels[x, y] = parse_hex(palette[key])
    return image


def trace(spec, base):  # base is the project root, so `file` reads as a repo path
    """Reduce real artwork to an 8x8 silhouette.

    Downscaling a logo to 8x8 gives mud, because averaging a light-on-dark mark
    against its own background lands everything in the middle. Tracing works
    instead: decide per source pixel whether it is *mark* or *background*, then
    ask each output cell how much of it was covered.

    The Claude mark is a light burst on a darker field of nearly the same hue,
    so the background is taken as the most common colour rather than assumed to
    be black or white.
    """
    from PIL import ImageSequence

    source = Image.open((base / spec["file"]).resolve())
    color = spec.get("color", "#FFFFFF")
    cutoff = spec.get("distance", 30)
    coverage = spec.get("coverage", 0.30)
    size = spec.get("size", 8)

    # One background colour for the whole animation, taken from the first
    # frame. Detecting it per frame inverts on any frame where the mark's own
    # glow fills the tile and becomes the most common colour — which is exactly
    # what the Claude burst does at its peak, and it turned that frame into a
    # solid block.
    first = next(ImageSequence.Iterator(source)).convert("RGB")
    background = max(first.getcolors(first.size[0] * first.size[1]),
                     key=lambda pair: pair[0])[1]

    masks = []
    for frame in ImageSequence.Iterator(source):
        rgb = frame.convert("RGB")
        pixels = rgb.load()
        width, height = rgb.size
        mask = [[0] * width for _ in range(height)]
        for y in range(height):
            for x in range(width):
                r, g, b = pixels[x, y]
                far = abs(r - background[0]) + abs(g - background[1]) + abs(b - background[2])
                mask[y][x] = 1 if far > cutoff else 0
        masks.append(mask)

    if not masks:
        raise ValueError("source has no frames")

    # Crop to the union of every frame's mark, so a small first frame doesn't
    # shrink the whole animation — and so the mark fills the 8x8 it is given.
    height, width = len(masks[0]), len(masks[0][0])
    xs = [x for mask in masks for y in range(height) for x in range(width) if mask[y][x]]
    ys = [y for mask in masks for y in range(height) for x in range(width) if mask[y][x]]
    if not xs:
        raise ValueError("nothing distinguishable from the background")
    left, right, top, bottom = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    # Keep it square so the mark isn't stretched.
    span = max(right - left, bottom - top)
    centre_x, centre_y = (left + right) // 2, (top + bottom) // 2
    left, top = centre_x - span // 2, centre_y - span // 2

    frames = []
    for mask in masks:
        rows = []
        for cell_y in range(size):
            row = ""
            for cell_x in range(size):
                lit = total = 0
                y0 = top + cell_y * span // size
                y1 = top + (cell_y + 1) * span // size
                x0 = left + cell_x * span // size
                x1 = left + (cell_x + 1) * span // size
                for y in range(y0, y1):
                    for x in range(x0, x1):
                        total += 1
                        if 0 <= y < height and 0 <= x < width and mask[y][x]:
                            lit += 1
                row += "#" if total and lit / total >= coverage else "."
            rows.append(row)
        frames.append(rows)

    # Identical consecutive frames are wasted bytes and, at 100ms floor, wasted
    # time — the panel would just hold the same picture twice.
    deduped = [frames[0]]
    for rows in frames[1:]:
        if rows != deduped[-1]:
            deduped.append(rows)
    return deduped, {".": "#000000", "#": color}


def build(path):
    spec = json.loads(path.read_text())
    if "trace" in spec:
        rows_per_frame, palette = trace(spec["trace"], HERE.parent)
        frames = [render_frame(rows, palette) for rows in rows_per_frame]
    else:
        palette = spec["palette"]
        frames = [render_frame(rows, palette) for rows in spec["frames"]]
    if not frames:
        raise ValueError("no frames")

    BUILD.mkdir(parents=True, exist_ok=True)
    out = BUILD / f"{path.stem}.gif"
    # Quantize to an exact palette so no dithering invents colours the artwork
    # never had — at 64 pixels, one wrong pixel is 1.5% of the icon.
    converted = [frame.convert("P", palette=Image.ADAPTIVE, colors=256) for frame in frames]
    delay = max(100, int(spec.get("delayMs", 100)))
    converted[0].save(
        out,
        save_all=True,
        append_images=converted[1:],
        duration=delay,
        loop=0,
        optimize=False,
        disposal=1,
    )
    return out, len(frames), frames[0].size


def write_preview(paths, scale=14):
    """A magnified contact sheet, because 8x8 art is unjudgeable at 8x8.

    Still no substitute for the panel itself: a diffused LED matrix eats thin
    single-pixel strokes that look perfectly crisp here.
    """
    from PIL import ImageDraw

    gap, pad, label = 10, 10, 14
    cell = 8 * scale
    width = pad * 2 + len(paths) * cell + (len(paths) - 1) * gap
    sheet = Image.new("RGB", (width, pad * 2 + cell + label), (24, 24, 26))
    draw = ImageDraw.Draw(sheet)
    for index, path in enumerate(paths):
        icon = Image.open(path).convert("RGB").resize((cell, cell), Image.NEAREST)
        x = pad + index * (cell + gap)
        sheet.paste(icon, (x, pad))
        draw.rectangle([x - 1, pad - 1, x + cell, pad + cell], outline=(70, 70, 74))
        draw.text((x, pad + cell + 2), path.stem, fill=(170, 170, 175))
    out = HERE / "preview.png"
    sheet.save(out)
    return out


def main():
    if not SRC.is_dir():
        sys.exit(f"no source directory at {SRC}")
    sources = sorted(SRC.glob("*.json"))
    if not sources:
        sys.exit(f"no icon sources in {SRC}")

    failed = False
    built = []
    for path in sources:
        try:
            out, count, size = build(path)
        except Exception as error:  # noqa: BLE001 - report and keep going
            print(f"  {path.name}: {error}")
            failed = True
            continue
        built.append(out)
        frames = "frame" if count == 1 else "frames"
        print(f"  {out.name}: {size[0]}x{size[1]}, {count} {frames}, {out.stat().st_size} bytes")

    if "--preview" in sys.argv and built:
        print(f"  preview: {write_preview(built)}")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
