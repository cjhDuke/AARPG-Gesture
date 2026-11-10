"""合成手形工具：在 ROI 大小的画布上用纯色画拳 / 掌 / 两指。"""
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

SKIN = (120, 150, 220)       # BGR，落在默认 Cr/Cb 范围内
BG = (90, 90, 90)            # 灰色背景，Cr=Cb=128，不在默认范围内
W, H = 280, 360


def load_cfg():
    with open(os.path.join(os.path.dirname(HERE), "config.json"), encoding="utf-8") as f:
        return json.load(f)


def canvas():
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = BG
    return img


def draw_hand(n_fingers, color=SKIN, center=(140, 200), r=50, img=None):
    """圆 + n 根长条（朝上）。n=0 为拳，2 为两指，5 为手掌。"""
    img = canvas() if img is None else img
    cx, cy = center
    cv2.circle(img, (cx, cy), r, color, -1)
    # (x 偏移, 指长)；指长不一、指尖为圆头，避免指尖共线时凸包漏掉内侧指尖
    fingers = {0: [], 2: [(-13, 70), (13, 80)],
               5: [(-52, 50), (-26, 70), (0, 80), (26, 70), (52, 50)]}[n_fingers]
    for dx, length in fingers:
        x = cx + dx
        cv2.rectangle(img, (x - 7, cy - r - length), (x + 7, cy), color, -1)
        cv2.circle(img, (x, cy - r - length), 7, color, -1)
    return img
