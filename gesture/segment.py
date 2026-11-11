"""步骤 2-6：预处理、背景建模、前景与肤色分割、去噪、连通域定位。

分割 = "与背景不同" 且 "颜色在宽松肤色范围内"：
- 只用肤色：米色墙面、木纹这类静止的近肤色背景会混进来，手上的高光和阴影又会漏掉。
- 只用背景差分：袖子、身体的晃动都会算作前景。
两者取交集后，静止的近肤色背景被差分去掉，会动的非肤色物体被肤色范围去掉。
"""
from dataclasses import dataclass

import cv2
import numpy as np

from hand_select import HandSelector


@dataclass
class SegResult:
    diff: np.ndarray       # 与背景的差异图（未标定时为 Cr 通道），灰度
    thresh: np.ndarray     # 前景 ∩ 肤色 的二值图
    morph: np.ndarray      # 形态学处理后的二值图
    mask: np.ndarray       # 选中的手的连通域掩膜（无手则全 0）
    has_hand: bool
    area: int              # 选中连通域面积


def _ellipse(k):
    k = max(1, int(k)) | 1  # 保证奇数
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))


class Segmenter:
    def __init__(self, cfg):
        self.seg = cfg["segment"]
        self.bgc = cfg["background"]
        self.skin = cfg["skin_range"]
        self.bg = None          # 背景模型：float32 的 YCrCb 图，None 表示未标定
        self._collect = None    # 正在采集背景时：已收到的帧列表
        self.k_open = _ellipse(self.seg["open_kernel"])
        self.k_close = _ellipse(self.seg["close_kernel"])
        self.k_guard = _ellipse(self.bgc["update_guard_kernel"])
        self.selector = HandSelector(cfg)

    @property
    def calibrated(self):
        return self.bg is not None

    @property
    def calibrating(self):
        return self._collect is not None

    # ---- 标定：采集背景 ----
    def calibrate(self):
        """开始采集背景：接下来的若干帧取中值作为背景模型，期间手要移出操作框。"""
        self._collect = []
        self.bg = None
        self.selector.reset()

    def set_background(self, bg):
        """直接载入已有的背景模型（回放录像时用）。"""
        self.bg = bg.astype(np.float32)
        self._collect = None
        self.selector.reset()

    def reset_tracking(self):
        """换操作框等场合：清空手的跟踪状态。"""
        self.selector.reset()

    # ---- 各步骤 ----
    def _preprocess(self, bgr):
        """步骤 2：高斯滤波 + 转 YCrCb。"""
        k = int(self.seg["blur_kernel"]) | 1
        return cv2.cvtColor(cv2.GaussianBlur(bgr, (k, k), 0), cv2.COLOR_BGR2YCrCb)

    def _foreground(self, ycc):
        """步骤 3：背景差分。色度（Cr、Cb）差异大，或亮度差异很大，判为前景。

        色度阈值低、亮度阈值高：自动曝光会让整幅画面的亮度一起漂，色度则稳定得多。
        """
        d = cv2.absdiff(ycc.astype(np.float32), self.bg)
        chroma = cv2.magnitude(d[:, :, 1], d[:, :, 2])
        fg = (chroma > self.bgc["chroma_threshold"]) | (d[:, :, 0] > self.bgc["luma_threshold"])
        vis = np.clip(chroma * 8.0, 0, 255).astype(np.uint8)
        return fg, vis

    def _skin(self, ycc):
        """步骤 4：宽松的固定肤色范围（只用来排除袖子、衣服这类明显不是皮肤的前景）。"""
        lo = (0, self.skin["cr"][0], self.skin["cb"][0])
        hi = (255, self.skin["cr"][1], self.skin["cb"][1])
        return cv2.inRange(ycc, lo, hi) > 0

    def _morphology(self, binary):
        """步骤 5：开运算去噪点，闭运算填孔洞。"""
        out = cv2.morphologyEx(binary, cv2.MORPH_OPEN, self.k_open)
        return cv2.morphologyEx(out, cv2.MORPH_CLOSE, self.k_close)

    def _update_background(self, ycc, fg):
        """只在判为背景的像素上缓慢更新，跟上光照和曝光的漂移，又不会把停住的手或袖子吸收进背景。"""
        keep = cv2.dilate(fg.astype(np.uint8), self.k_guard) > 0
        a = self.bgc["update_alpha"]
        upd = ~keep
        self.bg[upd] = self.bg[upd] * (1.0 - a) + ycc[upd].astype(np.float32) * a

    def process(self, roi_bgr):
        ycc = self._preprocess(roi_bgr)
        empty = np.zeros(ycc.shape[:2], np.uint8)
        if self._collect is not None:
            self._collect.append(ycc)
            if len(self._collect) >= int(self.bgc["frames"]):
                self.bg = np.median(np.stack(self._collect), axis=0).astype(np.float32)
                self._collect = None
            return SegResult(ycc[:, :, 1], empty, empty, empty, False, 0)
        if self.bg is None or self.bg.shape != ycc.shape:
            self.bg = None  # 操作框尺寸变了：旧背景作废，需要重新标定
            return SegResult(ycc[:, :, 1], empty, empty, empty, False, 0)

        fg, vis = self._foreground(ycc)
        th = (fg & self._skin(ycc)).astype(np.uint8) * 255
        morph = self._morphology(th)
        # 步骤 6：连通域分析 + 有状态选手（跟踪上一帧的手，排除晃动的脸）
        mask, area = self.selector.select(morph, self.seg["min_area_ratio"] * morph.size)
        self._update_background(ycc, fg)
        return SegResult(vis, th, morph, mask, bool(mask.any()), area)
