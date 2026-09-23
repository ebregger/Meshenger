"""Rasterize mesh branding bitmaps (splash + launcher) with smooth strokes.

Uses 8× supersampled round-cap stamping so Android launch_background PNGs
stay crisp. Flutter splash draws the same geometry via MeshLogoPainter.

    python tools/generate_launcher_icons.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"
ASSETS = ROOT / "assets" / "branding"

# Keep in sync with MeshLogo: designStroke / designSize (192 * 0.038).
STROKE_FRACTION = 0.038

MIPMAPS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

FOREGROUND = {
    "drawable-mdpi": 108,
    "drawable-hdpi": 162,
    "drawable-xhdpi": 216,
    "drawable-xxhdpi": 324,
    "drawable-xxxhdpi": 432,
}


def _bezier(p0, p1, p2, p3, steps=80):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = (
            u**3 * p0[0]
            + 3 * u**2 * t * p1[0]
            + 3 * u * t**2 * p2[0]
            + t**3 * p3[0]
        )
        y = (
            u**3 * p0[1]
            + 3 * u**2 * t * p1[1]
            + 3 * u * t**2 * p2[1]
            + t**3 * p3[1]
        )
        pts.append((x, y))
    return pts


def _arc(cx, cy, r, deg0, deg1, steps=24):
    """Inclusive arc in degrees (screen y-down), CCW if deg1>deg0."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        a = math.radians(deg0 + (deg1 - deg0) * t)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def _map(pt, size: int, pad: float):
    inner = size * (1 - 2 * pad)
    return (pad * size + pt[0] * inner, pad * size + pt[1] * inner)


def _densify(
    pts: list[tuple[float, float]], spacing: float = 0.4
) -> list[tuple[float, float]]:
    """Resample a polyline so stamps overlap for a continuous round stroke."""
    if len(pts) < 2:
        return pts
    out: list[tuple[float, float]] = [pts[0]]
    for i in range(1, len(pts)):
        x0, y0 = out[-1]
        x1, y1 = pts[i]
        dist = math.hypot(x1 - x0, y1 - y0)
        if dist < 1e-6:
            continue
        n = max(1, int(math.ceil(dist / spacing)))
        for k in range(1, n + 1):
            t = k / n
            out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
    return out


def _stroke_round(
    draw: ImageDraw.ImageDraw,
    pts: list[tuple[float, float]],
    color: tuple[int, int, int, int],
    width: float,
) -> None:
    """Round-cap stroke via overlapping circles (smooth after downsample)."""
    r = width / 2.0
    for x, y in _densify(pts, spacing=max(0.25, r * 0.35)):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def _bubble_outline(size: int, pad: float) -> list[tuple[float, float]]:
    """Rounded rect matching MeshLogoGeometry.bubblePath (no tail)."""

    def S(x, y):
        return _map((x, y), size, pad)

    left, top = S(0.22, 0.20)
    right, bottom = S(0.78, 0.70)
    content = size * (1 - 2 * pad)
    r = content * 0.14

    pts: list[tuple[float, float]] = []
    pts.append((left + r, top))
    pts.append((right - r, top))
    pts += _arc(right - r, top + r, r, -90, 0)[1:]
    pts.append((right, bottom - r))
    pts += _arc(right - r, bottom - r, r, 0, 90)[1:]
    pts.append((left + r, bottom))
    pts += _arc(left + r, bottom - r, r, 90, 180)[1:]
    pts.append((left, top + r))
    pts += _arc(left + r, top + r, r, 180, 270)[1:]
    pts.append((left + r, top))
    return pts


def _tail_poly(size: int, pad: float) -> list[tuple[float, float]]:
    """Filled tip matching MeshLogoGeometry.tailPath."""

    def S(x, y):
        return _map((x, y), size, pad)

    return [S(0.22, 0.64), S(0.12, 0.84), S(0.52, 0.64)]


def draw_logo(
    size: int,
    *,
    bg: tuple[int, int, int, int] | None,
    stroke: tuple[int, int, int, int],
    fill_nodes: tuple[int, int, int, int],
    pad: float = 0.12,
) -> Image.Image:
    # High supersample + round stamps → clean AA after LANCZOS downsample.
    scale = 8
    big = size * scale
    img = Image.new("RGBA", (big, big), bg or (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    content = big * (1 - 2 * pad)
    sw = max(2.0, content * STROKE_FRACTION)

    def S(x: float, y: float):
        return _map((x, y), big, pad)

    _stroke_round(draw, _bubble_outline(big, pad), stroke, sw)
    draw.polygon(_tail_poly(big, pad), fill=stroke)

    left_node = S(0.28, 0.58)
    right_node = S(0.72, 0.48)
    curve: list[tuple[float, float]] = []
    curve += _bezier(S(0.02, 0.52), S(0.10, 0.48), S(0.18, 0.55), left_node)
    curve += _bezier(left_node, S(0.38, 0.62), S(0.48, 0.40), right_node)[1:]
    curve += _bezier(right_node, S(0.82, 0.38), S(0.90, 0.18), S(0.98, 0.08))[1:]
    _stroke_round(draw, curve, stroke, sw)

    node_r = max(2.0, sw * 1.2)
    for cx, cy in (left_node, right_node):
        draw.ellipse(
            [cx - node_r, cy - node_r, cx + node_r, cy + node_r],
            fill=fill_nodes,
        )
    return img.resize((size, size), Image.Resampling.LANCZOS)


def draw_circular_icon(
    size: int,
    *,
    stroke: tuple[int, int, int, int],
    disc: tuple[int, int, int, int] | None = None,
    pad: float = 0.0,
    crop_scale: float = 1.08,
) -> Image.Image:
    """Circle-masked logo (icon-style). [crop_scale]>1 clips protruding arms."""
    # Draw oversized, then mask to [size] so extremities are cropped.
    big = max(size + 2, int(round(size * crop_scale)))
    logo = draw_logo(big, bg=None, stroke=stroke, fill_nodes=stroke, pad=pad)
    # Center-crop to size.
    origin = (big - size) // 2
    logo = logo.crop((origin, origin, origin + size, origin + size))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if disc is not None:
        disc_layer = Image.new("RGBA", (size, size), disc)
        out.paste(disc_layer, mask=mask)
    out.alpha_composite(logo)
    clear = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clear.paste(out, mask=mask)
    return clear


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    white = (255, 255, 255, 255)
    black = (0, 0, 0, 255)

    master = draw_logo(
        1024,
        bg=black,
        stroke=white,
        fill_nodes=white,
        pad=0.08,
    )
    master.save(ASSETS / "mesh_logo_1024.png")

    for folder, px in MIPMAPS.items():
        out_dir = RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        draw_logo(
            px,
            bg=black,
            stroke=white,
            fill_nodes=white,
            pad=0.10,
        ).save(out_dir / "ic_launcher.png")

    for folder, px in FOREGROUND.items():
        out_dir = RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        draw_logo(
            px,
            bg=None,
            stroke=white,
            fill_nodes=white,
            pad=0.18,
        ).save(out_dir / "ic_launcher_foreground.png")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values" / "colors.xml").write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#000000</color>
</resources>
""",
        encoding="utf-8",
    )
    (anydpi / "ic_launcher.xml").write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
""",
        encoding="utf-8",
    )
    drawable = RES / "drawable"
    drawable.mkdir(parents=True, exist_ok=True)
    import shutil

    shutil.copyfile(
        RES / "drawable-xxhdpi" / "ic_launcher_foreground.png",
        drawable / "ic_launcher_foreground.png",
    )

    # Full-bleed circle crop for windowBackground (scales via dp in XML).
    ink = (28, 27, 31, 255)
    splash_light = draw_circular_icon(1024, stroke=ink, disc=None)
    splash_dark = draw_circular_icon(1024, stroke=white, disc=None)
    splash_light.save(ASSETS / "splash_icon.png")
    splash_dark.save(ASSETS / "splash_icon_dark.png")

    # Inset copies for Android 12+ system splash (~240dp plate).
    def _inset(core_img: Image.Image, glyph: int = 1024, frac: float = 0.45) -> Image.Image:
        canvas = Image.new("RGBA", (glyph, glyph), (0, 0, 0, 0))
        side = int(glyph * frac)
        scaled = core_img.resize((side, side), Image.Resampling.LANCZOS)
        origin = (glyph - side) // 2
        canvas.paste(scaled, (origin, origin), scaled)
        return canvas

    system_light = _inset(splash_light)
    system_dark = _inset(splash_dark)

    for folder, px in {
        "drawable-mdpi": 192,
        "drawable-hdpi": 288,
        "drawable-xhdpi": 384,
        "drawable-xxhdpi": 576,
        "drawable-xxxhdpi": 768,
        "drawable": 576,
    }.items():
        out = RES / folder
        out.mkdir(parents=True, exist_ok=True)
        splash_light.resize((px, px), Image.Resampling.LANCZOS).save(
            out / "splash_icon.png"
        )
        splash_dark.resize((px, px), Image.Resampling.LANCZOS).save(
            out / "splash_icon_dark.png"
        )
        system_light.resize((px, px), Image.Resampling.LANCZOS).save(
            out / "splash_icon_system.png"
        )
        system_dark.resize((px, px), Image.Resampling.LANCZOS).save(
            out / "splash_icon_system_dark.png"
        )

    print("Wrote launcher icons, splash_icon +", ASSETS / "mesh_logo_1024.png")


if __name__ == "__main__":
    main()
