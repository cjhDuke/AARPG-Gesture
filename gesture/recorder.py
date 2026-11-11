"""录像：把镜像后的原始画面存成视频，连同标定直方图和操作框下标，供离线调参回放。

每段录像三个文件（同名不同后缀）：.avi 画面、.json 元数据、.npy 肤色直方图（已标定时才有）。
回放：python main.py --video recordings/xxx.avi（会自动读取旁边的 .json / .npy）。
"""
import json
import os
import time

import cv2
import numpy as np


class Recorder:
    def __init__(self, out_dir, max_seconds=30.0, fps=30.0):
        self.out_dir = out_dir
        self.max_seconds = max_seconds
        self.fps = fps
        self._writer = None
        self._base = None
        self._start = 0.0
        self._frames = 0
        self._meta = {}

    @property
    def active(self):
        return self._writer is not None

    @property
    def elapsed(self):
        return time.monotonic() - self._start if self.active else 0.0

    def start(self, frame, roi_index, hist):
        """开始录像，返回视频路径；打不开写入器时返回 None。"""
        os.makedirs(self.out_dir, exist_ok=True)
        base = os.path.join(self.out_dir, time.strftime("%Y%m%d_%H%M%S"))
        h, w = frame.shape[:2]
        writer = cv2.VideoWriter(base + ".avi", cv2.VideoWriter_fourcc(*"MJPG"), self.fps, (w, h))
        if not writer.isOpened():
            writer.release()
            return None
        self._writer, self._base = writer, base
        self._start, self._frames = time.monotonic(), 0
        self._meta = {"mirrored": True, "width": w, "height": h}
        self.update_meta(roi_index, hist)
        return base + ".avi"

    def update_meta(self, roi_index, hist):
        """录像期间换了操作框或重新标定时调用：以最后一次为准。"""
        if not self.active:
            return
        self._meta["roi_index"] = int(roi_index)
        self._meta["calibrated"] = hist is not None
        if hist is not None:
            np.save(self._base + ".npy", hist)
        self._write_meta()

    def write(self, frame):
        """写一帧；到时长上限时自动停止并返回 True。"""
        if not self.active:
            return False
        self._writer.write(frame)
        self._frames += 1
        if self.elapsed >= self.max_seconds:
            self.stop()
            return True
        return False

    def stop(self):
        if not self.active:
            return None
        self._meta["frames"] = self._frames
        self._meta["seconds"] = round(self.elapsed, 2)
        self._write_meta()
        self._writer.release()
        self._writer = None
        return self._base + ".avi"

    def _write_meta(self):
        with open(self._base + ".json", "w", encoding="utf-8") as f:
            json.dump(self._meta, f)


def load_sidecar(video_path):
    """读取录像旁边的元数据和直方图；没有则返回 (None, None)。"""
    base = os.path.splitext(video_path)[0]
    try:
        with open(base + ".json", "r", encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, ValueError):
        return None, None
    hist = None
    if os.path.exists(base + ".npy"):
        hist = np.load(base + ".npy").astype(np.float32)
    return meta, hist
