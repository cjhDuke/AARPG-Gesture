"""手的选择与跟踪：在形态学处理后的所有连通域里挑出"那只手"，避免把晃动的脸（同为肤色的前景）当成手。

状态：
- prev_hand：上一帧选中的手的掩膜，None 表示当前没在跟踪。
- static_avg：与操作框同尺寸的 float32，"不是手的肤色像素"的指数滑动平均，
  值越高说明该处长期有静止的肤色物体（比如脸）。

"静止肤色"区域（static_avg 高的地方）在找连通域之前先从掩膜里挖掉：
脸的一侧常常露在操作框边上，手靠过去时两者会连成一块，挖掉后手和脸就分开了，
手离开后也不会"跟"到脸上去。被手盖住的像素不衰减，所以手停在脸前面时脸不会被忘掉。

已知局限：脸刚进操作框、还没被记成静止肤色的那零点几秒里，手碰上去仍会连成一块。
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
        kc = max(1, int(t.get("static_cut_kernel", 7))) | 1
        self.k_cut = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kc, kc))
        # 贴着左 / 右边界、宽度不到这么多像素的窄条不算手（多半是脸或肩膀）
        self.side_width = float(t.get("side_strip_width", 70))
        self.contested_alpha = float(t.get("static_contested_alpha", 0.02))
        self.prev_hand = None
        self.static_avg = None

    def reset(self):
        """清空全部状态。"""
        self.prev_hand = None
        self.static_avg = None

    @property
    def tracking(self):
        return self.prev_hand is not None

    def select(self, morph, min_area):
        """返回 (手的掩膜 uint8 0/255, 面积)；无手时掩膜全 0。"""
        if self.static_avg is None or self.static_avg.shape != morph.shape:
            # 首帧或操作框尺寸变了：丢掉旧状态
            self.prev_hand = None
            self.static_avg = np.zeros(morph.shape, np.float32)

        # 挖掉长期静止的肤色区域（略微膨胀，切断手和它之间的连接）
        static = (self.static_avg > self.static_thresh).astype(np.uint8)
        cand = morph.copy()
        cut = None
        if static.any():
            cut = cv2.dilate(static, self.k_cut) > 0
            cand[cut] = 0
        n, labels, stats, cents = cv2.connectedComponentsWithStats(cand, connectivity=8)
        areas = stats[:, cv2.CC_STAT_AREA]
        chosen = 0  # 0 = 背景 = 无手

        if self.prev_hand is not None:
            # 正在跟踪：取与上一帧的手（膨胀后）重叠最多的连通域
            near = cv2.dilate(self.prev_hand, self.k_dilate) > 0
            overlap = np.bincount(labels[near], minlength=n)
            overlap[0] = 0
            best = int(np.argmax(overlap)) if n > 1 else 0
            if (best > 0 and overlap[best] > 0 and areas[best] >= min_area
                    and not self._side_strip(stats, cents, best, morph.shape[1])):
                chosen = best
        else:
            chosen = self._recapture(labels, areas, stats, cents, n, min_area)

        if chosen > 0:
            hand = (labels == chosen).astype(np.uint8) * 255
            self.prev_hand = hand
            area = int(areas[chosen])
        else:
            hand = np.zeros_like(morph)
            self.prev_hand = None
            area = 0

        # 更新静止肤色：不属于手的肤色前景上升，没有肤色前景的地方衰减，被手盖住的地方保持。
        # 紧挨着手、被挖掉的那部分分不清是脸还是手（手可能正盖在脸原来的位置上），让它慢慢衰减：
        # 手只是路过时仍然分得开，脸已经移走时手上被挖掉的那块约 1 秒后长回来。
        skin = morph > 0
        non_hand = skin & (hand == 0)
        a = self.alpha
        if cut is not None and chosen > 0:
            contested = non_hand & cut & (cv2.dilate(hand, self.k_dilate) > 0)
            non_hand &= ~contested
            self.static_avg[contested] *= (1.0 - self.contested_alpha)
        self.static_avg[non_hand] += (1.0 - self.static_avg[non_hand]) * a
        self.static_avg[~skin] *= (1.0 - a)
        return hand, area

    def _side_strip(self, stats, cents, i, w):
        """连通域 i 是否是贴在左 / 右边界上的窄条（宽度不到 side_strip_width）。"""
        x0 = stats[i, cv2.CC_STAT_LEFT]
        bw = stats[i, cv2.CC_STAT_WIDTH]
        return bool(bw < self.side_width and (x0 <= 0 or x0 + bw >= w))

    def _recapture(self, labels, areas, stats, cents, n, min_area):
        """重新捕获：面积够大、"静止肤色像素"占比低、不是贴在左右边上的窄条的连通域里取最大的。"""
        if n <= 1:
            return 0
        w = labels.shape[1]
        static = self.static_avg > self.static_thresh
        static_cnt = np.bincount(labels[static], minlength=n)
        best, best_area = 0, 0
        for i in range(1, n):
            a = int(areas[i])
            if a < min_area or a <= best_area:
                continue
            if static_cnt[i] / a >= self.static_ratio:
                continue
            if self._side_strip(stats, cents, i, w):
                continue
            best, best_area = i, a
        return best
