"""合成手形工具：在操作框大小的画布上用纯色画拳 / 掌 / 小臂。"""
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

SKIN = (120, 150, 220)       # BGR，落在配置的肤色范围内
BG = (90, 90, 90)            # 灰色背景，Cr=Cb=128，不在肤色范围内
SLEEVE = (200, 120, 60)      # 偏蓝的"袖子"，不是肤色
W, H = 280, 360


def load_cfg():
    with open(os.path.join(os.path.dirname(HERE), "config.json"), encoding="utf-8") as f:
        return json.load(f)


def canvas(color=BG):
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = color
    return img


def draw_hand(n_fingers, color=SKIN, center=(140, 200), r=50, img=None, arm=None):
    """圆 + n 根长条（朝上）。n=0 为拳，5 为手掌。arm 取 down / left 时再画一条通到画面边缘的小臂。"""
    img = canvas() if img is None else img
    cx, cy = center
    if arm == "down":
        cv2.rectangle(img, (cx - 30, cy), (cx + 30, H - 1), color, -1)
    elif arm == "left":
        cv2.rectangle(img, (0, cy - 30), (cx, cy + 30), color, -1)
    cv2.circle(img, (cx, cy), r, color, -1)
    fingers = {0: [], 5: [(-40, 50), (-20, 70), (0, 80), (20, 70), (40, 50)]}[n_fingers]
    for dx, length in fingers:
        x = cx + dx
        cv2.rectangle(img, (x - 7, cy - r - length), (x + 7, cy), color, -1)
        cv2.circle(img, (x, cy - r - length), 7, color, -1)
    return img


def make_segmenter(cfg, background=None):
    """建一个已经有背景模型的分割器（默认背景是纯灰画布）。"""
    from segment import Segmenter
    seg = Segmenter(cfg)
    seg.calibrate()
    bg = canvas() if background is None else background
    for _ in range(int(cfg["background"]["frames"])):
        seg.process(bg)
    assert seg.calibrated
    return seg
