#!/usr/bin/env python3
"""从应用图标生成官网用的 favicon 一套。

源图是 macOS 的 .icns（四周留白约 10%），网页图标要填满画布才清晰，
所以先按 alpha 裁掉透明边，再按各尺寸导出。
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Apps/macOS/LiteMD/Resources/AppIcons/AppIcon-Blue.icns"
OUT = ROOT / "site/assets"


def load_trimmed() -> Image.Image:
    # PIL 读 .icns 在新版 Python 上会崩（size 是三元组），改用系统的 sips 先转成 PNG。
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "icon.png"
        subprocess.run(
            ["sips", "-s", "format", "png", "--resampleHeightWidthMax", "1024",
             str(SRC), "--out", str(png)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        icon = Image.open(png).convert("RGBA")
    alpha = icon.getchannel("A").point(lambda v: 255 if v > 8 else 0)
    box = alpha.getbbox()
    return icon.crop(box) if box else icon


def square(image: Image.Image, size: int, background=None) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), background or (0, 0, 0, 0))
    scaled = image.resize((size, size), Image.LANCZOS)
    canvas.alpha_composite(scaled)
    return canvas


def main() -> int:
    if not SRC.exists():
        print(f"找不到源图标：{SRC}", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)

    icon = load_trimmed()
    print(f"源图标裁剪后：{icon.size[0]}×{icon.size[1]}")

    # 浏览器标签页
    for size in (16, 32, 48):
        square(icon, size).save(OUT / f"favicon-{size}.png")
    square(icon, 48).save(
        OUT / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)]
    )

    # iOS 主屏：加白底，圆角由系统自己套
    square(icon, 180, background=(255, 255, 255, 255)).convert("RGB").save(
        OUT / "apple-touch-icon.png"
    )

    # PWA / Android
    for size in (192, 512):
        square(icon, size).save(OUT / f"icon-{size}.png")

    for path in sorted(OUT.glob("favicon*")) + sorted(OUT.glob("icon-[0-9]*")) + [
        OUT / "apple-touch-icon.png"
    ]:
        print(f"  {path.name}  {path.stat().st_size / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
