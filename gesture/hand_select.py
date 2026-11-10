"""手的选择与跟踪：在形态学处理后的所有连通域里挑出"那只手"，避免把脸（同为肤色）当成手。

状态：
- prev_hand：上一帧选中的手的掩膜，None 表示当前没在跟踪。
- static_avg：与操作框同尺寸的 float32，"不是手的肤色像素"的指数滑动平均，
  值越高说明该处长期有静止的肤色物体（比如脸）。

已知局限：手挡在脸前面时两者会连成一个连通域，此时无法分开，整块都会被当成手。
"""
import cv2
import numpy as np


class HandSelector:
    def __init__(self, cfg):
        t = cfg["tracking"]
        k = max(1, int(t["dilate_kernel"])) | 1
        self.k_dilate = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        self.static_ratio = float(t["static_hand_ratio"])    # 候选里静止像素占比上限
        self.static_thresh = float(t["static_threshold"])    # static_avg 超过它算"静止肤色"
        self.alpha = float(t["static_alpha"])
        self.prev_hand = None
        self.static_avg = None
        self.just_calibrated = False

    def reset(self, just_calibrated=False):
        """清空全部状态。just_calibrated=True 时下一次选择优先取包含操作框中心的连通域。"""
        self.prev_hand = None
        self.static_avg = None
        self.just_calibrated = just_calibrated

    @property
    def tracking(self):
        return self.prev_hand is not None

    def select(self, morph, min_area):
        """返回 (手的掩膜 uint8 0/255, 面积)；无手时掩膜全 0。"""
        if self.static_avg is None or self.static_avg.shape != morph.shape:
            # 首帧或操作框尺寸变了：丢掉旧状态（保留"刚标定"标志）
            self.prev_hand = None
            self.static_avg = np.zeros(morph.shape, np.float32)

        n, labels, stats, _ = cv2.connectedComponentsWithStats(morph, connectivity=8)
        areas = stats[:, cv2.CC_STAT_AREA]
        chosen = 0  # 0 = 背景 = 无手

        if self.prev_hand is not None:
            # 正在跟踪：取与上一帧的手（膨胀后）重叠最多的连通域
            near = cv2.dilate(self.prev_hand, self.k_dilate) > 0
            overlap = np.bincount(labels[near], minlength=n)
            overlap[0] = 0
            best = int(np.argmax(overlap)) if n > 1 else 0
            if best > 0 and overlap[best] > 0 and areas[best] >= min_area:
                chosen = best
        else:
            if self.just_calibrated and n > 1:
                h, w = morph.shape
                c = int(labels[h // 2, w // 2])
                if c > 0 and areas[c] >= min_area:
                    chosen = c
            if chosen == 0:
                chosen = self._recapture(labels, areas, n, min_area)
        self.just_calibrated = False

        if chosen > 0:
            hand = (labels == chosen).astype(np.uint8) * 255
            self.prev_hand = hand
            area = int(areas[chosen])
        else:
            hand = np.zeros_like(morph)
            self.prev_hand = None
            area = 0

        # 更新静止肤色背景：形态学掩膜中不属于手的像素
        non_hand = ((morph > 0) & (hand == 0)).astype(np.float32)
        self.static_avg = self.static_avg * (1.0 - self.alpha) + non_hand * self.alpha
        return hand, area

    def _recapture(self, labels, areas, n, min_area):
        """重新捕获：面积够大且"静止肤色像素"占比低的连通域里取最大的。"""
        if n <= 1:
            return 0
        static = self.static_avg > self.static_thresh
        static_cnt = np.bincount(labels[static], minlength=n)
        best, best_area = 0, 0
        for i in range(1, n):
            a = int(areas[i])
            if a < min_area or a <= best_area:
                continue
            if static_cnt[i] / a >= self.static_ratio:
                continue
            best, best_area = i, a
        return best
