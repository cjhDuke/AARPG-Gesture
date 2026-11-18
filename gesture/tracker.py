"""步骤 9：时序稳定。纯逻辑，不依赖 cv2。"""


class GestureDebouncer:
    """新手势需连续 N 帧才切换；从 fist 切走需要更多帧（防握拳中途抖动）。

    手贴着操作框边界（edge=True，手形被裁掉）时，从 fist 切走需要的帧数更多
    （fist_release_frames_edge）：手伸远了被裁成别的形状时不至于马上"脱手"，
    但真的张开并保持一会儿仍然能松开。握拳的判定不受贴边影响。

    原始判定为 "between"（张开度落在两个阈值之间）时保持当前状态，这就是双阈值滞回；
    当前没有手时，between 先按张开处理。
    """

    def __init__(self, cfg):
        self.n = cfg["tracker"]["debounce_frames"]
        self.n_fist = cfg["tracker"]["fist_release_frames"]
        self.n_fist_edge = cfg["tracker"].get("fist_release_frames_edge", self.n_fist)
        self.stable = "none"
        self._cand = None
        self._count = 0

    def update(self, raw, edge=False):
        if raw == "between":
            raw = "palm" if self.stable == "none" else self.stable
        if raw == self.stable:
            self._cand, self._count = None, 0
            return self.stable
        if raw == self._cand:
            self._count += 1
        else:
            self._cand, self._count = raw, 1
        if self.stable == "fist":
            need = self.n_fist_edge if edge else self.n_fist
        else:
            need = self.n
        if self._count >= need:
            self.stable = raw
            self._cand, self._count = None, 0
        return self.stable


class PointSmoother:
    """掌心坐标的指数滑动平均 + 死区：小于死区的移动不输出，消除光标抖动。"""

    def __init__(self, cfg):
        self.alpha = cfg["tracker"]["smooth_alpha"]
        self.dead = cfg["tracker"]["dead_zone"]
        self._avg = None
        self._out = None

    def reset(self):
        self._avg = self._out = None

    def update(self, x, y):
        if self._avg is None:
            self._avg = self._out = (x, y)
            return self._out
        a = self.alpha
        self._avg = (self._avg[0] + (x - self._avg[0]) * a, self._avg[1] + (y - self._avg[1]) * a)
        dx, dy = self._avg[0] - self._out[0], self._avg[1] - self._out[1]
        if (dx * dx + dy * dy) ** 0.5 > self.dead:
            self._out = self._avg
        return self._out


class ZoneTracker:
    """方向区（菜单用）：越过外圈进入方向区，回到内圈内才复位 center，两圈之间保持原状态。

    dx, dy 为掌心相对操作框中心的偏移，单位是操作框宽度（y 向下为正）。
    """

    def __init__(self, cfg):
        self.inner = cfg["tracker"]["zone_inner"]
        self.outer = cfg["tracker"]["zone_outer"]
        self.zone = "center"

    @staticmethod
    def sector(dx, dy):
        """四个 90 度扇区（以对角线为界）。"""
        if abs(dx) >= abs(dy):
            return "right" if dx > 0 else "left"
        return "down" if dy > 0 else "up"

    def update(self, hand, dx=0.0, dy=0.0):
        if not hand:
            self.zone = "center"
            return self.zone
        dist = (dx * dx + dy * dy) ** 0.5
        if dist > self.outer:
            self.zone = self.sector(dx, dy)
        elif dist < self.inner:
            self.zone = "center"
        return self.zone
