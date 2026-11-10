"""步骤 2-6：预处理、肤色建模、分割、去噪、连通域定位。"""
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class SegResult:
    backproj: np.ndarray   # 反向投影图（未标定时为 Cr 通道），灰度
    thresh: np.ndarray     # 阈值分割后的二值图
    morph: np.ndarray      # 形态学处理后的二值图
    mask: np.ndarray       # 最大连通域掩膜（无手则全 0）
    has_hand: bool
    area: int              # 最大连通域面积


def _ellipse(k):
    k = max(1, int(k)) | 1  # 保证奇数
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))


class Segmenter:
    def __init__(self, cfg):
        self.seg = cfg["segment"]
        self.cal = cfg["calibration"]
        self.fixed = cfg["skin_fixed"]
        self.hist = None  # Cr-Cb 直方图，None 表示未标定
        self.k_open = _ellipse(self.seg["open_kernel"])
        self.k_close = _ellipse(self.seg["close_kernel"])
        self.k_smooth = _ellipse(self.cal["smooth_kernel"]).astype(np.float32)
        self.k_smooth /= self.k_smooth.sum()

    @property
    def calibrated(self):
        return self.hist is not None

    # ---- 标定 ----
    def calibrate(self, roi_bgr):
        """取操作框中心的采样框，统计 Cr-Cb 二维直方图并归一化到 0-255。"""
        h, w = roi_bgr.shape[:2]
        s = min(int(self.cal["sample_size"]), h, w)
        y0, x0 = (h - s) // 2, (w - s) // 2
        patch = self._preprocess(roi_bgr[y0:y0 + s, x0:x0 + s])
        bins = int(self.cal["hist_bins"])
        hist = cv2.calcHist([patch], [1, 2], None, [bins, bins], [0, 256, 0, 256])
        cv2.normalize(hist, hist, 0, 255, cv2.NORM_MINMAX)
        self.hist = hist

    def reset_calibration(self):
        self.hist = None

    # ---- 各步骤 ----
    def _preprocess(self, bgr):
        """步骤 2：高斯滤波 + 转 YCrCb。"""
        k = int(self.seg["blur_kernel"]) | 1
        return cv2.cvtColor(cv2.GaussianBlur(bgr, (k, k), 0), cv2.COLOR_BGR2YCrCb)

    def _backproject(self, ycrcb):
        """步骤 3-4：反向投影 -> 椭圆核平滑 -> Otsu。"""
        bp = cv2.calcBackProject([ycrcb], [1, 2], self.hist, [0, 256, 0, 256], 1)
        bp = cv2.filter2D(bp, -1, self.k_smooth)
        otsu, th = cv2.threshold(bp, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)
        floor = self.cal["min_backproj"]
        if otsu < floor:  # 画面里几乎没有肤色，Otsu 会把噪声当前景，改用下限
            _, th = cv2.threshold(bp, floor, 255, cv2.THRESH_BINARY)
        return bp, th

    def _fixed_range(self, ycrcb):
        """未标定：固定 Cr/Cb 范围。"""
        lo = (0, self.fixed["cr"][0], self.fixed["cb"][0])
        hi = (255, self.fixed["cr"][1], self.fixed["cb"][1])
        return ycrcb[:, :, 1], cv2.inRange(ycrcb, lo, hi)

    def _morphology(self, binary):
        """步骤 5：开运算去噪点，闭运算填孔洞。"""
        out = cv2.morphologyEx(binary, cv2.MORPH_OPEN, self.k_open)
        return cv2.morphologyEx(out, cv2.MORPH_CLOSE, self.k_close)

    def _largest_component(self, binary):
        """步骤 6：连通域分析取最大区域；面积过小视为无手。"""
        n, labels, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
        empty = np.zeros_like(binary)
        if n <= 1:
            return empty, 0
        idx = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        area = int(stats[idx, cv2.CC_STAT_AREA])
        if area < self.seg["min_area_ratio"] * binary.size:
            return empty, area
        return (labels == idx).astype(np.uint8) * 255, area

    def process(self, roi_bgr):
        ycrcb = self._preprocess(roi_bgr)
        if self.calibrated:
            bp, th = self._backproject(ycrcb)
        else:
            bp, th = self._fixed_range(ycrcb)
        morph = self._morphology(th)
        mask, area = self._largest_component(morph)
        return SegResult(bp, th, morph, mask, bool(mask.any()), area)
