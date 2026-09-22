#!/usr/bin/env python3
"""Rasterize an actual tmux capture; never synthesize terminal UI content.

Usage: python3 render_capture.py input.ansi output.png [dark|light]
Captures use tmux capture-pane -p -e. Default colors are the emulator theme;
explicit indexed and RGB colors come from the native terminal frame.
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

source, destination, *mode = sys.argv[1:]
light = mode == ["light"]
foreground = (28, 38, 52) if light else (231, 237, 245)
background = (248, 250, 252) if light else (15, 20, 28)
base = [
    (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
    (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
    (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
    (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
]


def indexed(index):
    if index < 16:
        return base[index]
    if index >= 232:
        value = 8 + 10 * (index - 232)
        return (value, value, value)
    cube = index - 16
    levels = [0, 95, 135, 175, 215, 255]
    return (levels[cube // 36], levels[cube // 6 % 6], levels[cube % 6])


ansi = re.compile(r"\x1b\[([0-9;]*)m")
lines = Path(source).read_text().splitlines()
width = max(len(ansi.sub("", line)) for line in lines)
cell_width, cell_height, margin = 11, 23, 18
font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 17)
image = Image.new("RGB", (width * cell_width + margin * 2,
                          len(lines) * cell_height + margin * 2), background)
draw = ImageDraw.Draw(image)
fg, bg, dim, reverse, bold = foreground, background, False, False, False
for row, line in enumerate(lines):
    column = 0
    pieces = re.split(r"(\x1b\[[0-9;]*m)", line)
    for piece in pieces:
        match = ansi.fullmatch(piece)
        if match:
            values = [int(v or "0") for v in match[1].split(";")]
            i = 0
            while i < len(values):
                value = values[i]
                if value == 0:
                    fg, bg, dim, reverse, bold = foreground, background, False, False, False
                elif value == 1:
                    bold = True
                elif value == 2:
                    dim = True
                elif value == 7:
                    reverse = True
                elif value == 22:
                    dim, bold = False, False
                elif value == 27:
                    reverse = False
                elif value == 39:
                    fg = foreground
                elif value == 49:
                    bg = background
                elif 30 <= value <= 37:
                    fg = indexed(value - 30)
                elif 40 <= value <= 47:
                    bg = indexed(value - 40)
                elif 90 <= value <= 97:
                    fg = indexed(value - 90 + 8)
                elif 100 <= value <= 107:
                    bg = indexed(value - 100 + 8)
                elif value in (38, 48):
                    if values[i + 1] == 2:
                        color = tuple(values[i + 2:i + 5])
                        i += 4
                    elif values[i + 1] == 5:
                        color = indexed(values[i + 2])
                        i += 2
                    else:
                        raise ValueError("unsupported color sequence")
                    if value == 38:
                        fg = color
                    else:
                        bg = color
                i += 1
            continue
        for char in piece:
            x, y = margin + column * cell_width, margin + row * cell_height
            ink, paper = (bg, fg) if reverse else (fg, bg)
            if dim:
                ink = tuple((a + b) // 2 for a, b in zip(ink, paper))
            draw.rectangle((x, y, x + cell_width - 1, y + cell_height - 1), fill=paper)
            draw.text((x, y), char, font=font, fill=ink,
                      stroke_width=0.2 if bold else 0)
            column += 1
image.save(destination)
