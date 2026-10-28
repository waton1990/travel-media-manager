#!/usr/bin/env python3
"""Add a clean alpha contour to the approved pale-blue icon; requires Pillow.

Usage: python3 scripts/prepare-icon-alpha.py APPROVED_PREVIEW.png assets/icon-source.png
Only alpha is changed. The original RGB artwork is copied pixel for pixel.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


def convex_hull(points):
    """Monotone chain over samples from the single convex outer tile."""
    points = sorted(set(points))

    def cross(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def half(values):
        result = []
        for point in values:
            while len(result) >= 2 and cross(result[-2], result[-1], point) <= 0:
                result.pop()
            result.append(point)
        return result[:-1]

    return half(points) + half(reversed(points))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with Image.open(args.source) as source:
        rgb = source.convert("RGB")
        profile = source.info.get("icc_profile")
    if rgb.size != (1254, 1254):
        raise ValueError("This contour is calibrated for the approved 1254 × 1254 pale-blue preview.")

    # The preview's neutral white margin is distinct from the blue tile edge.
    # Sample only the first and last blue pixels per row, ignoring interior art.
    pixels = rgb.load()
    edge = []
    for y in range(rgb.height):
        positions = [x for x in range(rgb.width)
                     if pixels[x, y][2] - pixels[x, y][0] > 12]
        if positions:
            edge.extend(((positions[0], y), (positions[-1], y)))
    hull = convex_hull(edge)
    bounds = (min(x for x, _ in hull), min(y for _, y in hull),
              max(x for x, _ in hull), max(y for _, y in hull))
    if bounds != (107, 109, 1146, 1145):
        raise ValueError(f"Unexpected tile boundary {bounds}; inspect a changed source before exporting.")

    # A convex contour removes detached flecks. Supersampling and a one-pixel
    # inset remove the exterior white matte while retaining the original shape.
    scale = 8
    mask = Image.new("L", (rgb.width * scale, rgb.height * scale), 0)
    ImageDraw.Draw(mask).polygon([(x * scale, y * scale) for x, y in hull], fill=255)
    mask = mask.filter(ImageFilter.MinFilter(2 * scale + 1))
    mask = mask.resize(rgb.size, Image.Resampling.LANCZOS)
    rgba = rgb.convert("RGBA")
    rgba.putalpha(mask)
    assert rgba.convert("RGB").tobytes() == rgb.tobytes()
    assert mask.getextrema() == (0, 255)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    metadata = {"icc_profile": profile} if profile else {}
    rgba.save(args.output, **metadata)
    print(f"Saved {args.output}: {rgb.width} × {rgb.height} RGBA; RGB unchanged; tile boundary {bounds}.")


if __name__ == "__main__":
    main()
