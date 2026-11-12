"""步骤 2-6：预处理、背景建模、前景与肤色分割、去噪、连通域定位。

分割 = "与背景不同" 且 "颜色在宽松肤色范围内"：
- 只用肤色：米色墙面、木纹这类静止的近肤色背景会混进来，手上的高光和阴影又会漏掉。
- 只用背景差分：袖子、身体的晃动都会算作前景。
两者取交集后，静止的近肤色背景被差分去掉，会动的非肤色物体被肤色范围去掉。

背景鬼影自愈：背景采集时手若还在框里，背景模型里会留下"鬼影手"，手回到那里就差分不出来，
而慢速更新只作用于非前景像素，鬼影永远不消失。所以对"是前景、但当前不是肤色、
且离所有肤色前景都很远"的像素用较快速度更新背景（它们不会进入手掩膜，更新是安全的）。

标定流程分三段：倒计时（提示玩家把手移开，不采帧）-> 采集（若干帧）-> 完成。
静止的手和空框在画面变化上分不开，所以靠倒计时让人把手移开；采集时再做两道保险：
1. 取中值时剔除（膨胀后的）肤色样本：手只是路过某个像素，那里的背景仍取自非肤色样本；
2. 动静检测：采集期间"在动的肤色"占操作框比例过大，说明手还在框里晃，丢弃重来
   （重试 calib_max_retries 次后不再检查，直接接受）。
"""
import math
import time
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
        self._collect = None    # 正在标定时：已收到的帧列表（倒计时期间为空列表）
        self._skins = []        # 与 _collect 对应的每帧肤色掩膜
        self._clock = time.monotonic   # 可替换（测试注入假时钟）
        self._countdown_s = 0.0
        self._start_at = 0.0    # 开始采帧的时刻（倒计时结束时刻）
        self.calib_retries = 0
        self.last_motion_ratio = 0.0   # 最近一次动静检测中"在动的肤色"占操作框的比例
        self.k_open = _ellipse(self.seg["open_kernel"])
        self.k_close = _ellipse(self.seg["close_kernel"])
        self.k_guard = _ellipse(self.bgc["update_guard_kernel"])
        self.ghost_alpha = float(self.bgc.get("ghost_alpha", 0.1))   # 0 = 关闭鬼影自愈
        self.k_ghost = _ellipse(self.bgc.get("ghost_guard_kernel", 51))
        self.selector = HandSelector(cfg)

    @property
    def calibrated(self):
        return self.bg is not None

    @property
    def calibrating(self):
        return self._collect is not None

    @property
    def calib_countdown(self):
        """倒计时剩余秒数（向上取整）；采集阶段和不在标定时为 0。"""
        if self._collect is None:
            return 0
        return max(0, int(math.ceil(self._start_at - self._clock() - 1e-9)))

    # ---- 标定：倒计时 -> 采集背景 ----
    def calibrate(self, countdown_s=0.0):
        """开始标定：先倒计时 countdown_s 秒（不采帧，提示玩家把手移开），再采若干帧取中值作背景模型。"""
        self._countdown_s = max(0.0, float(countdown_s))
        self.calib_retries = 0
        self._begin_collect()
        self.bg = None
        self.selector.reset()

    def _begin_collect(self):
        self._collect = []
        self._skins = []
        self._start_at = self._clock() + self._countdown_s

    def _finish_collect(self):
        """采满帧：剔除肤色样本取中值；采集期间有手在动则丢弃重来。返回是否完成。"""
        frames = np.stack(self._collect)                         # (N,H,W,3) uint8
        skins = np.stack(self._skins)                            # (N,H,W) bool
        k = _ellipse(self.bgc.get("calib_skin_dilate", 15))
        dil = np.stack([cv2.dilate(m.astype(np.uint8), k) > 0 for m in skins])
        n = (~dil).sum(axis=0)                                   # 每个像素的非肤色样本数
        # 肤色样本换成 255 排到最后，再在前 n 个里取中位数
        srt = np.sort(np.where(dil[..., None], np.uint8(255), frames), axis=0)
        last = len(frames) - 1
        lo = np.broadcast_to(np.clip((n - 1) // 2, 0, last)[None, ..., None], (1,) + srt.shape[1:])
        hi = np.broadcast_to(np.clip(n // 2, 0, last)[None, ..., None], (1,) + srt.shape[1:])
        a = np.take_along_axis(srt, lo, axis=0)[0].astype(np.float32)
        b = np.take_along_axis(srt, hi, axis=0)[0].astype(np.float32)
        med = (a + b) * 0.5
        few = n < int(self.bgc.get("calib_min_samples", 3))      # 非肤色样本太少：退回全部样本的中值
        if few.any():
            med[few] = np.median(frames, axis=0).astype(np.float32)[few]

        # 动静检测：在动的肤色 = 某帧是肤色、且亮度偏离中值背景
        luma = float(self.bgc.get("calib_motion_luma", 15))
        moving = np.zeros(med.shape[:2], bool)
        for f, sk in zip(frames, skins):
            moving |= sk & (np.abs(f[:, :, 0].astype(np.float32) - med[:, :, 0]) > luma)
        self.last_motion_ratio = float(moving.mean())
        limit = float(self.bgc.get("calib_motion_max", 0.05))
        if self.calib_retries < int(self.bgc.get("calib_max_retries", 3)) and self.last_motion_ratio > limit:
            self.calib_retries += 1
            self._begin_collect()
            return False
        self.bg = med
        self._collect = None
        self._skins = []
        return True

    def set_background(self, bg):
        """直接载入已有的背景模型（回放录像时用）。"""
        self.bg = bg.astype(np.float32)
        self._collect = None
        self._skins = []
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

    def _heal_ghost(self, ycc, fg, skin, near_src):
        """鬼影自愈：前景 且 非肤色 且 远离肤色前景的像素，用较快速度更新背景。"""
        if self.ghost_alpha <= 0:
            return
        near = cv2.dilate(near_src, self.k_ghost) > 0
        ghost = fg & ~skin & ~near
        if ghost.any():
            a = self.ghost_alpha
            self.bg[ghost] = self.bg[ghost] * (1.0 - a) + ycc[ghost].astype(np.float32) * a

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
            if self._clock() >= self._start_at:   # 倒计时期间不采帧
                self._collect.append(ycc)
                self._skins.append(self._skin(ycc))
                if len(self._collect) >= int(self.bgc["frames"]):
                    self._finish_collect()
            return SegResult(ycc[:, :, 1], empty, empty, empty, False, 0)
        if self.bg is None or self.bg.shape != ycc.shape:
            self.bg = None  # 操作框尺寸变了：旧背景作废，需要重新标定
            return SegResult(ycc[:, :, 1], empty, empty, empty, False, 0)

        fg, vis = self._foreground(ycc)
        skin = self._skin(ycc)
        th = (fg & skin).astype(np.uint8) * 255
        morph = self._morphology(th)
        # 步骤 6：连通域分析 + 有状态选手（跟踪上一帧的手，排除晃动的脸）
        mask, area = self.selector.select(morph, self.seg["min_area_ratio"] * morph.size)
        self._update_background(ycc, fg)
        self._heal_ghost(ycc, fg, skin, cv2.bitwise_or(morph, mask))
        return SegResult(vis, th, morph, mask, bool(mask.any()), area)
