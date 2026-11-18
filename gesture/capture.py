"""步骤 1：图像采集。所有帧源输出的帧都是 BGR、已水平镜像（可关闭）。"""
import threading
import time
from abc import ABC, abstractmethod

import cv2


class FrameSource(ABC):
    """帧源抽象：read() 返回 (帧, 采集时间毫秒) 或 None。"""

    opened = False

    @abstractmethod
    def read(self, timeout=1.0):
        ...

    def release(self):
        pass


def _now_ms():
    return time.monotonic() * 1000.0


class CameraSource(FrameSource):
    """摄像头源：独立线程不断读帧，只保留最新一帧，避免缓冲积压造成延迟。"""

    def __init__(self, index=0, width=640, height=480, mirror=True):
        self.mirror = mirror
        backend = cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY
        self.cap = cv2.VideoCapture(index, backend)
        if not self.cap.isOpened():
            self.cap.release()
            self.cap = cv2.VideoCapture(index)  # 退回默认后端再试一次
        self.opened = self.cap.isOpened()
        if not self.opened:
            return
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_FPS, 30)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self._cond = threading.Condition()
        self._frame = None
        self._t_ms = 0.0
        self._serial = 0
        self._served = 0
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self):
        while self._running:
            ok, frame = self.cap.read()
            if not ok:
                time.sleep(0.005)
                continue
            if self.mirror:
                frame = cv2.flip(frame, 1)
            with self._cond:
                self._frame, self._t_ms = frame, _now_ms()
                self._serial += 1
                self._cond.notify_all()

    def read(self, timeout=1.0):
        """等待一帧新画面（超时返回 None）。"""
        with self._cond:
            if not self._cond.wait_for(lambda: self._serial != self._served, timeout):
                return None
            self._served = self._serial
            return self._frame, self._t_ms

    def release(self):
        if not self.opened:
            return
        self._running = False
        self._thread.join(timeout=1.0)
        self.cap.release()


class _Paced:
    """按固定间隔限速的小工具。"""

    def __init__(self, interval):
        self.interval = interval
        self._next = time.monotonic()

    def wait(self):
        delay = self._next - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        self._next = max(self._next, time.monotonic() - self.interval) + self.interval


class VideoSource(FrameSource):
    """视频文件源：按文件帧率播放，播完循环。"""

    def __init__(self, path, mirror=True):
        self.cap = cv2.VideoCapture(path)
        self.opened = self.cap.isOpened()
        self.mirror = mirror
        fps = self.cap.get(cv2.CAP_PROP_FPS) if self.opened else 0
        self._pace = _Paced(1.0 / fps if fps and fps > 1 else 1.0 / 30)

    def read(self, timeout=1.0):
        self._pace.wait()
        ok, frame = self.cap.read()
        if not ok:  # 播完，回到开头
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            ok, frame = self.cap.read()
            if not ok:
                return None
        if self.mirror:
            frame = cv2.flip(frame, 1)
        return frame, _now_ms()

    def release(self):
        self.cap.release()


class ImageSource(FrameSource):
    """单张图片源：反复返回同一张图（按 fps 限速，模拟摄像头）。"""

    def __init__(self, path, mirror=True, size=None, fps=30):
        img = cv2.imread(path)
        self.opened = img is not None
        if not self.opened:
            return
        if size is not None and (img.shape[1], img.shape[0]) != tuple(size):
            img = cv2.resize(img, tuple(size))
        self.frame = cv2.flip(img, 1) if mirror else img
        self._pace = _Paced(1.0 / fps if fps else 0.0)

    def read(self, timeout=1.0):
        self._pace.wait()
        return self.frame.copy(), _now_ms()
