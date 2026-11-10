"""步骤 9：时序稳定。纯逻辑，不依赖 cv2。"""


class GestureDebouncer:
    """新手势需连续 N 帧才切换；从 fist 切走需要更多帧（防蓄力中途抖动）。"""

    def __init__(self, cfg):
        self.n = cfg["tracker"]["debounce_frames"]
        self.n_fist = cfg["tracker"]["fist_release_frames"]
        self.stable = "none"
        self._cand = None
        self._count = 0

    def update(self, raw):
        if raw == self.stable:
            self._cand, self._count = None, 0
            return self.stable
        if raw == self._cand:
            self._count += 1
        else:
            self._cand, self._count = raw, 1
        need = self.n_fist if self.stable == "fist" else self.n
        if self._count >= need:
            self.stable = raw
            self._cand, self._count = None, 0
        return self.stable


class ZoneTracker:
    """方向区：越过外圈进入方向区，回到内圈内才复位 center，两圈之间保持原状态。

    dx, dy 为质心相对操作框中心的偏移，单位是操作框宽度（y 向下为正）。
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
