#!/usr/bin/env python3
"""Compose documentation SVGs from original art and unmodified application output."""
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/showcase'
FONT = "-apple-system,BlinkMacSystemFont,'PingFang SC','Microsoft YaHei',sans-serif"
INK, PAPER, MUTED, RED, DARK = '#25352e', '#f5f1e8', '#6b796d', '#e95240', '#192720'


def text(x, y, value, size=24, color=INK, weight=400, **attrs):
    extra = ' '.join(f'{key.replace("_", "-")}="{escape(str(value))}"' for key, value in attrs.items())
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}" {extra}>{escape(value)}</text>'


def rect(x, y, w, h, fill, radius=16, stroke='none'):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" stroke="{stroke}"/>'


def pic(name, x, y, w, h):
    if not (OUT / 'images' / name).is_file():
        raise FileNotFoundError(name)
    return f'<image x="{x}" y="{y}" width="{w}" height="{h}" href="images/{name}" preserveAspectRatio="xMidYMid meet"/>'


def save(name, height, title, desc, body, dark=False):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="{height}" viewBox="0 0 1440 {height}" role="img" aria-labelledby="title desc">
<title id="title">{escape(title)}</title><desc id="desc">{escape(desc)}</desc>
{rect(0, 0, 1440, height, DARK if dark else PAPER, 24)}
<g font-family="{FONT}">{''.join(body)}</g></svg>'''
    (OUT / f'{name}.svg').write_text(svg)


# The hero foreground is a real app view, never a drawn imitation of its controls.
body = [text(64, 58, '映述  /  YINGSHU', 22, '#c1cec0', 600),
        text(1376, 58, '原生 Mac · v0.11', 18, '#aebfac', text_anchor='end'),
        text(60, 139, '边看边说，回忆成片。', 64, PAPER, 600),
        text(65, 184, '照片、视频与实况  →  按 R 暂停口述  →  文字留在画面', 23, '#b8c8b7'),
        rect(60, 220, 1320, 829, '#fffdf8', 13), pic('editor.png', 64, 224, 1312, 820),
        text(64, 1090, '真实应用视图 · 原创示例画面与预置文字', 17, '#9eb29c'),
        text(1376, 1090, 'MP4 短片  /  带字 PNG', 19, '#dce5d4', 500, text_anchor='end')]
save('hero', 1126, '映述：边看边说，回忆成片', '真实原生编辑器的离屏渲染，使用原创示例画面与预置文字，不代表麦克风或模型识别结果。', body, True)

body = [text(58, 57, '01  /  THE R WORKFLOW', 16, RED, 600), text(58, 117, '把一句话，留在刚才的画面。', 40, INK, 600),
        text(1382, 112, '流程示意', 18, MUTED, text_anchor='end')]
steps = [('导入', '相册 / 本地文件', '照片、视频与实况'), ('按 R，说一句', '画面与配乐暂停', '表达不赶时间'), ('再按 R，落字', '识别完成后绑定原片段', '从刚才的位置续播'), ('检查，带走', '修文字、选样式与配乐', '导出 MP4 / PNG')]
for i, (title, a, b) in enumerate(steps):
    x = 58 + i * 338
    red = i == 1
    body += [rect(x, 169, 310, 258, RED if red else '#fffcf5', 16), text(x+24, 210, f'0{i+1}', 21, '#ffe3d4' if red else MUTED, 500),
             text(x+24, 276, title, 29, PAPER if red else INK, 600), text(x+24, 333, a, 21, '#ffe8df' if red else MUTED),
             text(x+24, 371, b, 21, '#ffe8df' if red else MUTED)]
    if i < 3:
        body.append(text(x+319, 305, '›', 27, '#9aa995'))
body += [text(58, 482, '画面与文字共同叙事，配乐负责氛围。', 24, INK, 500),
         text(58, 525, '口述用于转文字；当前成片不包含口述录音和素材原声。', 21, MUTED)]
save('workflow', 566, '映述的 R 口述工作流', '导入素材，按 R 暂停口述，再按 R 结束，识别完成后在原片段落字并续播，检查并导出。', body)

body = [text(58, 57, '02  /  FOUR WAYS TO REMEMBER', 16, RED, 600), text(58, 119, '同一句感想，四种留法。', 42, INK, 600),
        text(58, 159, '应用真实导出 · 同一张海边图，同一句预置文字', 21, MUTED)]
styles = [('subtitle', '字幕', '沿画面读下去'), ('sticker', '贴纸', '给那一刻贴个标记'), ('note', '手记', '留一页安静的回忆'), ('companion', '小人气泡', '一位无声的旅行同伴')]
for i, (name, title, desc) in enumerate(styles):
    x, y = 58+(i % 2)*674, 205+(i//2)*455
    body += [rect(x-1, y-1, 650, 367, '#d5d9cc', 1), pic(f'caption-{name}.png', x, y, 648, 364.5),
             text(x, y+407, title, 28, INK, 600), text(x+146, y+406, desc, 21, MUTED)]
body += [text(58, 1122, '字幕、贴纸、手记与气泡使用应用共用渲染规则；小人动作在 MP4 中保留，PNG 为静态。', 20, MUTED)]
save('captions', 1165, '四种真实文字样式', '字幕、贴纸、手记和小人气泡均由 CaptionImageExporter 用原创海岸画面和相同预置文字生成，完整显示。', body)

body = [text(58, 57, '03  /  READY TO TAKE WITH YOU', 16, '#efa38b', 600), text(58, 120, '横着看，竖着发，方形收藏。', 42, PAPER, 600),
        text(58, 163, '三种画幅的真实 PNG 输出 · 完整显示原素材，比例不同处留黑', 21, '#acbfa8')]
# Scale whole outputs; do not crop black bars or shift application-rendered captions.
body += [pic('export-landscape.png', 58, 255, 640, 360), pic('export-square.png', 730, 275, 330, 330), pic('export-portrait.png', 1092, 220, 288, 512),
         text(58, 673, '横屏 16:9', 26, PAPER, 600), text(58, 714, '1920 × 1080', 20, '#acbfa8'),
         text(730, 673, '方形 1:1', 26, PAPER, 600), text(730, 714, '1080 × 1080', 20, '#acbfa8'),
         text(1092, 783, '竖屏 9:16', 26, PAPER, 600), text(1092, 824, '1080 × 1920', 20, '#acbfa8'),
         rect(58, 786, 978, 90, '#273b2c', 13), text(82, 822, 'MP4：画面 + 文字 + 配乐', 23, '#edf0df', 500),
         text(82, 857, 'PNG：静态画面 + 文字，附顺序 / 时间 / 原文索引', 20, '#acbfa8'),
         text(58, 926, '应用 PNG 导出器生成 · 原创海边画面与预置文字 · 完整保留输出画幅', 20, '#93aa91')]
save('exports', 970, '三种真实导出画幅', '横屏1920×1080、方形1080×1080和竖屏1080×1920，同一素材按比例完整显示，黑边为应用真实导出行为。', body, True)

body = [text(58, 57, '04  /  LOCAL AI PATH', 16, '#efa38b', 600), text(58, 119, '准备好模型，识别与整理留在本机。', 38, PAPER, 600),
        rect(58, 160, 1324, 428, '#25382b', 20, '#64785e'), text(82, 200, '这台 Mac  /  未开启可选云端整理的独立 AI 模式', 20, '#b5c7ae')]
for x, title, lines in [(84,'识别声音',['Qwen3-ASR · MLX','麦克风音频暂存在内存']), (528,'整理表达',['Qwen2.5 · MLX','保留识别原稿，可检查还原']), (972,'留在画面',['原生编辑器 + 共享渲染','预览 / MP4 / 带字 PNG'])]:
    body += [rect(x, 234, 382, 180, PAPER, 14), text(x+24, 282, title, 30, INK, 600), text(x+24, 335, lines[0], 22, MUTED), text(x+24, 376, lines[1], 21, MUTED)]
for x in [482, 926]: body.append(text(x, 330, '→', 27, '#afc1a7'))
body += [text(84, 468, '声音转成文字，原始录音不写文件、不进项目或成片。', 24, '#e1ead8', 500),
         text(84, 519, '模型仍可能听错或改错；检查未通过时保留完整原稿。', 22, '#b0c2a9'),
         rect(58, 626, 646, 143, '#2b3b2f', 14), rect(736, 626, 646, 143, '#2b3b2f', 14),
         text(82, 667, '首次准备：联网下载公开模型与运行环境', 23, PAPER, 500), text(82, 715, '安装包不含模型；约 1.89 GB 模型 + 运行环境', 20, '#acbfa8'),
         text(760, 667, '联网曲库：搜索关键词与获取公开音频', 23, PAPER, 500), text(760, 715, '音乐推荐不发送画面或感想原文', 20, '#acbfa8'),
         text(58, 822, '本图只描述独立本地 AI 链路；其他语音模式、可选整理与 iCloud 获取范围见语音设置说明。', 20, '#a4b89f')]
save('architecture', 868, '本地 AI 模式的处理路径', '模型准备完成且未启用可选云端整理时，Qwen3-ASR识别、Qwen2.5整理与媒体渲染均在本机。首次模型准备和公开曲库分别联网。', body, True)
print('Generated 5 documentation SVGs from original samples and real application output')
