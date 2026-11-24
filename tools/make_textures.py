"""Generate the anti-aliased route textures in RareCodex/Media/ as 32-bit TGA files.

Lines are drawn in two passes, so each shape has an outline texture (dark, wide) and a
core texture (white, narrow, tinted in game). Profiles are functions of the distance from
the line's center, in texels, with soft edges so lines stay smooth at any zoom.

    line-*.tga  16x16, profile across the rows (u runs along the line, v across it)
    cap-*.tga   16x16, the same profile as a disc, drawn at every joint and end
    area.tga    64x64 soft disc used to fill wander areas
    ring.tga    64x64 soft ring, the ping around a rare's pin hovered in the rare list
"""

from __future__ import annotations

import math
import struct
from collections.abc import Callable
from pathlib import Path

MEDIA = Path(__file__).resolve().parent.parent / "RareCodex" / "Media"
HALF = 8.0  # half the line's width in texels (16 px texture)

Pixel = tuple[int, int, int, int]  # r, g, b, a


def ramp(d: float, inner: float, outer: float) -> float:
    """1 inside ``inner``, 0 beyond ``outer``, linear in between."""
    if d <= inner:
        return 1.0
    if d >= outer:
        return 0.0
    return (outer - d) / (outer - inner)


def core_alpha(d: float) -> float:
    return ramp(d, 2.2, 3.2)


def outline_alpha(d: float) -> float:
    return ramp(d, 5.0, HALF)


def write_tga(path: Path, width: int, height: int, pixel: Callable[[int, int], Pixel]) -> None:
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28)
    body = bytearray()
    for y in range(height):  # descriptor 0x28: top-left origin, 8 alpha bits
        for x in range(width):
            r, g, b, a = pixel(x, y)
            body += bytes((b, g, r, a))
    path.write_bytes(header + bytes(body))


def to_byte(value: float) -> int:
    return max(0, min(255, round(value * 255)))


def line_pixel(alpha: Callable[[float], float], gray: int) -> Callable[[int, int], Pixel]:
    return lambda _x, y: (gray, gray, gray, to_byte(alpha(abs(y + 0.5 - HALF))))


def disc_pixel(alpha: Callable[[float], float], gray: int) -> Callable[[int, int], Pixel]:
    def pixel(x: int, y: int) -> Pixel:
        d = math.hypot(x + 0.5 - HALF, y + 0.5 - HALF)
        return (gray, gray, gray, to_byte(alpha(d)))

    return pixel


def area_pixel(x: int, y: int) -> Pixel:
    d = math.hypot(x + 0.5 - 32, y + 0.5 - 32) / 32
    return (255, 255, 255, to_byte(ramp(d, 0.55, 1.0)))


def ring_pixel(x: int, y: int) -> Pixel:
    d = math.hypot(x + 0.5 - 32, y + 0.5 - 32)
    return (255, 255, 255, to_byte(ramp(abs(d - 26), 2.0, 5.0)))


def main() -> None:
    MEDIA.mkdir(parents=True, exist_ok=True)
    write_tga(MEDIA / "line-outline.tga", 16, 16, line_pixel(outline_alpha, 0))
    write_tga(MEDIA / "line-core.tga", 16, 16, line_pixel(core_alpha, 255))
    write_tga(MEDIA / "cap-outline.tga", 16, 16, disc_pixel(outline_alpha, 0))
    write_tga(MEDIA / "cap-core.tga", 16, 16, disc_pixel(core_alpha, 255))
    write_tga(MEDIA / "area.tga", 64, 64, area_pixel)
    write_tga(MEDIA / "ring.tga", 64, 64, ring_pixel)
    print(f"Wrote textures to {MEDIA}")


if __name__ == "__main__":
    main()
