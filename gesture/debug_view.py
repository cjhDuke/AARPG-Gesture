"""调试窗口：六格拼图展示完整处理管线。格内标题用英文（cv2.putText 不支持中文）。"""
import os
import time

import cv2
import numpy as np

TILE_W, TILE_H = 320, 384
GREEN, YELLOW, RED, BLUE, WHITE = (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 128, 0), (255, 255, 255)


def draw_overlay(roi, feats, cfg, with_sample_box=True):
    """原图叠加：轮廓、凸包、指缝点、质心、方向区内外圈、采样框。返回新图。"""
    img = roi.copy()
    h, w = img.shape[:2]
    c = (w // 2, h // 2)
    t = cfg["tracker"]
    cv2.circle(img, c, int(t["zone_inner"] * w), WHITE, 1)
    cv2.circle(img, c, int(t["zone_outer"] * w), (180, 180, 180), 1)
    if with_sample_box:
        s = min(int(cfg["calibration"]["sample_size"]), h, w)
        cv2.rectangle(img, (c[0] - s // 2, c[1] - s // 2), (c[0] + s // 2, c[1] + s // 2), YELLOW, 1)
    if feats is not None and feats.contour is not None:
        cv2.drawContours(img, [feats.contour], -1, GREEN, 2)
        cv2.polylines(img, [feats.hull], True, YELLOW, 1)
        for start, far, end in feats.finger_gaps:
            cv2.circle(img, far, 4, RED, -1)
            cv2.circle(img, start, 3, RED, 1)
            cv2.circle(img, end, 3, RED, 1)
        cv2.circle(img, (int(feats.centroid[0]), int(feats.centroid[1])), 5, BLUE, -1)
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
        "defects : %d" % info["defects"],
        "solidity: %.2f" % info["solidity"],
        "fps     : %.1f" % info["fps"],
        "proc    : %.1f ms" % info["proc_ms"],
        "calibrated: %s" % ("YES" if info["calibrated"] else "NO - press c"),
        "",
        "[c] calibrate (hand on yellow box)",
        "[r] move ROI (keep face out)",
        "[s] save screenshot",
        "[q]/Esc quit",
    ]
    for i, line in enumerate(lines):
        cv2.putText(tile, line, (8, 44 + i * 26), cv2.FONT_HERSHEY_SIMPLEX, 0.5, WHITE, 1, cv2.LINE_AA)
    return _title(tile, "6 Result")


def compose(frame, roi_rect, roi, seg, feats, info, cfg):
    """拼出 3x2 的六格图。"""
    x, y, w, h = roi_rect
    full = frame.copy()
    cv2.rectangle(full, (x, y), (x + w, y + h), GREEN, 2)
    s = int(cfg["calibration"]["sample_size"])
    cx, cy = x + w // 2, y + h // 2
    cv2.rectangle(full, (cx - s // 2, cy - s // 2), (cx + s // 2, cy + s // 2), YELLOW, 2)
    tiles = [
        _title(_fit(full, TILE_W, TILE_H), "1 Frame + ROI"),
        _title(_fit(seg.backproj, TILE_W, TILE_H), "2 BackProject"),
        _title(_fit(seg.thresh, TILE_W, TILE_H), "3 Threshold"),
        _title(_fit(seg.morph, TILE_W, TILE_H), "4 Morphology"),
        _title(_fit(draw_overlay(roi, feats, cfg), TILE_W, TILE_H), "5 Contour/Hull/Defects"),
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
