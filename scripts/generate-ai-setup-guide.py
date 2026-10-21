#!/usr/bin/env python3
"""Render the release onboarding guide as matching SVG and PNG.

Run from any directory: python3 scripts/generate-ai-setup-guide.py
Requires Pillow and a local Chinese font. No network or image generation is used.
The composition uses one vertical reading path, large labels and quiet stage
colors: the small application download and the later model download stay distinct.
"""

from __future__ import annotations

import html
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "showcase"
WIDTH, HEIGHT, SCALE = 1000, 2040, 2
PAPER = "#F7F6F1"
WHITE = "#FFFFFF"
INK = "#25352E"
MUTED = "#59675F"
LINE = "#DADFD7"
CORAL = "#C44836"
CORAL_LIGHT = "#FFF1E9"
GREEN = "#276547"
GREEN_LIGHT = "#EAF3EB"


def chinese_font() -> tuple[Path, bool]:
    candidates = [Path("/System/Library/Fonts/PingFang.ttc")]
    asset_root = Path("/System/Library/AssetsV2")
    if asset_root.exists():
        candidates.extend(sorted(asset_root.glob("com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")))
    candidates.extend([
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
        Path("/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"),
    ])
    for path in candidates:
        if path.is_file():
            return path, path.name == "PingFang.ttc"
    raise SystemExit("A local PingFang SC or Noto Sans CJK font is required.")


FONT_PATH, IS_PINGFANG = chinese_font()
bitmap = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), PAPER)
draw = ImageDraw.Draw(bitmap)
svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="title desc">',
    '<title id="title">映述：下载哪个附件，怎样准备本地 AI</title>',
    '<desc id="desc">只下载约15MB的YingShu-Mac.zip。解压保留安装支援，双击准备本地AI.command后才下载约1.89GB的两个模型和运行环境。等待本地 AI 准备完成；用Command Q退出并重开映述，进入语音与整理设置，选择AI识别与整理并点击完成。按R口述再按R结束，看到文字落在画面上，可离线使用。Source code是源码，SHA256SUMS.txt是可选校验表。</desc>',
    f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{PAPER}"/>',
]


def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    index = (11 if weight >= 600 else 7 if weight >= 500 else 3) if IS_PINGFANG else 0
    return ImageFont.truetype(str(FONT_PATH), size * SCALE, index=index)


def rect(x: int, y: int, w: int, h: int, fill: str, radius: int = 18, stroke: str | None = None) -> None:
    box = (x * SCALE, y * SCALE, (x + w) * SCALE, (y + h) * SCALE)
    draw.rounded_rectangle(box, radius=radius * SCALE, fill=fill, outline=stroke, width=2 if stroke else 1)
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}"' + (f' stroke="{stroke}"' if stroke else '') + '/>')


def text(value: str, x: int, baseline: int, size: int = 30, fill: str = INK, weight: int = 400, max_width: int | None = None) -> None:
    face = font(size, weight)
    # PingFang does not contain the macOS Command glyph. Use the local symbol
    # font for that glyph instead of emitting an invisible missing character.
    symbol_path = Path("/System/Library/Fonts/Apple Symbols.ttf")
    symbol_face = ImageFont.truetype(str(symbol_path), size * SCALE) if symbol_path.exists() else face
    pieces = [(part, symbol_face if part == "⌘" else face) for part in re.split("(⌘)", value) if part]
    advance = 0.0
    boxes = []
    for part, part_face in pieces:
        boxes.append(draw.textbbox((x * SCALE + advance, baseline * SCALE), part, font=part_face, anchor="ls"))
        advance += draw.textlength(part, font=part_face)
    box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    if box[0] < 30 * SCALE or box[2] > (WIDTH - 30) * SCALE or box[1] < 15 * SCALE or box[3] > (HEIGHT - 20) * SCALE:
        raise ValueError(f"Text crosses the canvas margin: {value!r}, {box}")
    if max_width is not None and advance > max_width * SCALE:
        raise ValueError(f"Text exceeds its intended column: {value!r}")
    advance = 0.0
    for part, part_face in pieces:
        draw.text((x * SCALE + advance, baseline * SCALE), part, font=part_face, fill=fill, anchor="ls")
        advance += draw.textlength(part, font=part_face)
    svg.append(f'<text x="{x}" y="{baseline}" font-family="\'PingFang SC\',\'Noto Sans CJK SC\',\'Apple Symbols\',sans-serif" font-size="{size}" font-weight="{weight}" fill="{fill}">{html.escape(value)}</text>')


def line(x1: int, y1: int, x2: int, y2: int, fill: str = LINE, width: int = 1) -> None:
    draw.line((x1 * SCALE, y1 * SCALE, x2 * SCALE, y2 * SCALE), fill=fill, width=width * SCALE)
    svg.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{fill}" stroke-width="{width}"/>')


def arrow(y: int) -> None:
    line(500, y, 500, y + 12, MUTED, 2)
    points = [(492, y + 9), (500, y + 18), (508, y + 9)]
    draw.polygon([(x * SCALE, p * SCALE) for x, p in points], fill=MUTED)
    svg.append('<polygon points="' + ' '.join(f'{x},{p}' for x, p in points) + f'" fill="{MUTED}"/>')


def card(number: int, y: int, h: int, title: str, accent: bool = False) -> None:
    rect(40, y, 920, h, CORAL_LIGHT if accent else WHITE, stroke=LINE)
    rect(64, y + 24, 44, 44, CORAL if accent else GREEN, radius=22)
    text(str(number), 77, y + 57, size=29, fill=WHITE, weight=600)
    text(title, 126, y + 58, size=34, weight=600, max_width=800)


text("映述 v0.14.0 · 首次下载与 AI 准备", 40, 55, 27, MUTED, 500)
text("想用 AI？先下载这个 ZIP", 40, 118, 47, INK, 600)
text("ZIP 内有准备器，AI 模型在第 3 步才下载。", 40, 166, 31, MUTED)

card(1, 200, 326, "GitHub 附件：只选这一项")
text("YingShu-Mac.zip", 126, 323, 45, INK, 600)
rect(713, 282, 202, 50, GREEN_LIGHT, radius=9)
text("约 15 MB", 735, 317, 29, GREEN, 500)
text("含 App + AI 准备器；此时尚未安装 AI 模型。", 126, 376, 30, CORAL, 500, 800)
line(126, 402, 915, 402)
text("Source code（zip / tar.gz）只是源码，普通使用不下载", 126, 448, 27, MUTED, max_width=800)
text("SHA256SUMS.txt 是可选校验表，不是软件", 126, 492, 28, MUTED, max_width=800)
arrow(535)

card(2, 565, 206, "解压，保留配套文件")
text("映述.app → 可以拖到「应用程序」", 126, 675, 31, INK, 500, 800)
text("“准备本地AI.command”与“安装支援”保持同一目录", 126, 723, 28, MUTED, max_width=800)
arrow(783)

card(3, 816, 282, "双击「准备本地AI.command」", accent=True)
text("此时才自动下载 AI 模型", 126, 930, 35, CORAL, 600, 800)
text("两个模型约 1.89 GB + 独立运行环境", 126, 978, 31, INK, 500, 800)
text("首次需要联网 · 至少 6 GB 可用空间", 126, 1024, 29, MUTED, max_width=800)
text("无需 API Key · 无需自己安装 Python", 126, 1070, 29, MUTED, max_width=800)
arrow(1110)

card(4, 1143, 187, "等待最后的成功提示")
rect(126, 1224, 545, 56, GREEN_LIGHT, radius=9)
text("本地 AI 准备完成", 149, 1264, 36, GREEN, 600)
text("只看到下载 100%，还不算完成。", 126, 1312, 28, MUTED)
arrow(1342)

card(5, 1375, 245, "重开 App，并选择 AI 模式")
text("⌘Q 退出映述 → 重新打开（不用重启 Mac）", 126, 1485, 30, INK, 500, 800)
text("… → 语音与整理设置 → AI 识别与整理", 126, 1533, 31, INK, 600, 800)
text("确认“本地 AI 已准备” → 点右下角【完成】", 126, 1585, 29, CORAL, 500, 800)
arrow(1632)

card(6, 1665, 225, "用一句话，确认已经准备好")
text("无素材时：点「先试一下」载入示例", 126, 1775, 30, MUTED, max_width=800)
text("按 R 说一句 → 再按 R 结束 → 看到落字", 126, 1823, 33, INK, 600, 800)
text("之后可离线使用本地 AI 识别与整理。", 126, 1866, 29, GREEN, 500, 800)

text("ZIP ≠ 已装模型；AI 也不是额外一个 GitHub 附件。", 40, 1960, 30, INK, 600, 920)
text("只下载 ZIP → 运行准备器 → 在 App 内选 AI 模式。", 40, 2004, 29, MUTED, max_width=920)

svg.append("</svg>")
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "ai-setup.svg").write_text("\n".join(svg) + "\n", encoding="utf-8")
metadata = PngImagePlugin.PngInfo()
metadata.add_text("Title", "映述：下载哪个附件，怎样准备本地 AI")
metadata.add_text("Description", "Only YingShu-Mac.zip is required. The included AI preparer downloads the models separately after extraction.")
bitmap.save(OUT / "ai-setup.png", optimize=True, pnginfo=metadata)
print(f"Wrote {OUT / 'ai-setup.svg'} and {OUT / 'ai-setup.png'} ({bitmap.width}×{bitmap.height})")
