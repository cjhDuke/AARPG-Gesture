"""调试窗口：六格拼图展示完整处理管线。格内标题用英文（cv2.putText 不支持中文）。"""
import os
import time

import cv2
import numpy as np

TILE_W, TILE_H = 320, 384
GREEN, YELLOW, RED, BLUE, WHITE = (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 128, 0), (255, 255, 255)


def _draw_hand(img, feats, off=(0, 0), thick=1):
    """轮廓、凸包、掌心内切圆、到最远点的连线、小臂方向。"""
    ox, oy = off
    c = (int(feats.palm[0]) + ox, int(feats.palm[1]) + oy)
    cv2.drawContours(img, [feats.contour], -1, GREEN, 2 * thick, offset=off)
    cv2.polylines(img, [feats.hull + np.array(off, np.int32)], True, YELLOW, thick)
    cv2.circle(img, c, int(feats.radius), BLUE, 2 * thick)
    cv2.line(img, c, (feats.far[0] + ox, feats.far[1] + oy), RED, 2 * thick)
    if feats.arm_dir is not None:
        tip = (int(c[0] + feats.arm_dir[0] * feats.radius * 1.5), int(c[1] + feats.arm_dir[1] * feats.radius * 1.5))
        cv2.line(img, c, tip, WHITE, thick)
    cv2.circle(img, c, 3 * thick, BLUE, -1)


def draw_overlay(roi, feats, cfg):
    """原图叠加：轮廓、凸包、掌心圆、最远点连线、方向区内外圈。返回新图。"""
    img = roi.copy()
    h, w = img.shape[:2]
    c = (w // 2, h // 2)
    t = cfg["tracker"]
    cv2.circle(img, c, int(t["zone_inner"] * w), WHITE, 1)
    cv2.circle(img, c, int(t["zone_outer"] * w), (180, 180, 180), 1)
    if feats is not None and feats.contour is not None:
        _draw_hand(img, feats)
    return img


def draw_full_overlay(frame, rect, feats, cfg):
    """阶段 0 用：整幅画面叠加操作框、手的轮廓 / 掌心圆 / 最远点连线。

    先在全分辨率上用较粗的线画，之后缩成 128x96 缩略图时才看得清。返回新图。
    """
    img = frame.copy()
    x, y, w, h = rect
    cv2.rectangle(img, (x, y), (x + w - 1, y + h - 1), GREEN, 5)
    if feats is not None and feats.contour is not None:
        _draw_hand(img, feats, (x, y), thick=2)
    return img


def _fit(img, w, h):
    """等比缩放并居中放入 w x h 的黑底画布（灰度自动转 BGR）。"""
    if img.ndim == 2:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    scale = min(w / img.shape[1], h / img.shape[0])
    nw, nh = max(1, int(img.shape[1] * scale)), max(1, int(img.shape[0] * scale))
    small = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_NEAREST)
    canvas = np.zeros((h, w, 3), np.uint8)
    y0, x0 = (h - nh) // 2, (w - nw) // 2
    canvas[y0:y0 + nh, x0:x0 + nw] = small
    return canvas


def _title(tile, text):
    cv2.putText(tile, text, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
    return tile


def _text_panel(info):
    tile = np.zeros((TILE_H, TILE_W, 3), np.uint8)
    lines = [
        "gesture : %s (raw %s)" % (info["gesture"], info["raw"]),
        "zone    : %s" % info["zone"],
        "open ratio: %.2f" % info["open_ratio"],
        "palm r  : %.0f px" % info["radius"],
        "fps     : %.1f" % info["fps"],
        "proc    : %.1f ms" % info["proc_ms"],
        "background: %s" % ("OK" if info["calibrated"] else
                            "capturing..." if info["calibrating"] else "NONE - press c"),
        "",
        "[c] capture background (hand OUT)",
        "[r] move ROI (keep face out)",
        "[s] save screenshot",
        "[v] start / stop recording",
        "[q]/Esc quit",
    ]
    for i, line in enumerate(lines):
        cv2.putText(tile, line, (8, 44 + i * 26), cv2.FONT_HERSHEY_SIMPLEX, 0.5, WHITE, 1, cv2.LINE_AA)
    if info.get("rec_s") is not None:
        cv2.circle(tile, (TILE_W - 110, 14), 6, RED, -1)
        cv2.putText(tile, "REC %4.1fs" % info["rec_s"], (TILE_W - 98, 19),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, RED, 1, cv2.LINE_AA)
    return _title(tile, "6 Result")


def compose(frame, roi_rect, roi, seg, feats, info, cfg):
    """拼出 3x2 的六格图。"""
    x, y, w, h = roi_rect
    full = frame.copy()
    cv2.rectangle(full, (x, y), (x + w, y + h), GREEN, 2)
    tiles = [
        _title(_fit(full, TILE_W, TILE_H), "1 Frame + ROI"),
        _title(_fit(seg.diff, TILE_W, TILE_H), "2 Background diff (chroma)"),
        _title(_fit(seg.thresh, TILE_W, TILE_H), "3 Foreground AND skin"),
        _title(_fit(seg.morph, TILE_W, TILE_H), "4 Morphology"),
        _title(_fit(draw_overlay(roi, feats, cfg), TILE_W, TILE_H), "5 Contour / palm circle / reach"),
        _text_panel(info),
    ]
    return np.vstack([np.hstack(tiles[:3]), np.hstack(tiles[3:])])


class DebugView:
    WIN = "gesture debug"

    def __init__(self, out_dir):
        self.out_dir = out_dir

    def show(self, board):
        """显示并处理按键，返回按键字符（无按键为 ''）。"""
        cv2.imshow(self.WIN, board)
        k = cv2.waitKey(1) & 0xFF
        if k == 27:
            return "q"
        return chr(k) if 0 < k < 128 else ""

    def save(self, board):
        os.makedirs(self.out_dir, exist_ok=True)
        path = os.path.join(self.out_dir, time.strftime("%Y%m%d_%H%M%S") + ".png")
        cv2.imwrite(path, board)
        return path

    def close(self):
        cv2.destroyAllWindows()
