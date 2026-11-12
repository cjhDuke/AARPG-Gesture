"""标定流程：倒计时 -> 采集 -> 完成；剔除肤色样本的中值；采集期间手在动则重来。"""
import copy
import os
import sys
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402  (同时把 gesture/ 加入 sys.path)
from segment import Segmenter  # noqa: E402


class FakeClock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def make(cfg_edit=None):
    cfg = copy.deepcopy(synth.load_cfg())
    if cfg_edit:
        cfg_edit(cfg)
    seg = Segmenter(cfg)
    clock = FakeClock()
    seg._clock = clock
    return seg, clock, cfg


class CountdownTest(unittest.TestCase):
    def test_default_has_no_countdown(self):
        seg, _, cfg = make()
        seg.calibrate()
        self.assertTrue(seg.calibrating)
        self.assertEqual(seg.calib_countdown, 0)
        for _ in range(int(cfg["background"]["frames"])):
            seg.process(synth.canvas())
        self.assertTrue(seg.calibrated)
        self.assertFalse(seg.calibrating)

    def test_countdown_then_collect(self):
        seg, clock, cfg = make()
        frames = int(cfg["background"]["frames"])
        seg.calibrate(3.0)
        self.assertEqual(seg.calib_countdown, 3)
        seg.process(synth.canvas())
        self.assertTrue(seg.calibrating)
        self.assertEqual(len(seg._collect), 0)       # 倒计时期间不采帧
        clock.t += 1.2
        self.assertEqual(seg.calib_countdown, 2)
        seg.process(synth.canvas())
        clock.t += 1.3
        self.assertEqual(seg.calib_countdown, 1)
        seg.process(synth.canvas())
        self.assertEqual(len(seg._collect), 0)
        clock.t += 0.5                               # 倒计时结束
        self.assertEqual(seg.calib_countdown, 0)
        self.assertTrue(seg.calibrating)             # 采集阶段仍在标定中
        for i in range(frames):
            self.assertTrue(seg.calibrating)
            self.assertFalse(seg.process(synth.canvas()).has_hand)
            if i + 1 < frames:
                self.assertEqual(len(seg._collect), i + 1)
        self.assertTrue(seg.calibrated)
        self.assertFalse(seg.calibrating)
        self.assertEqual(seg.calib_countdown, 0)
        self.assertTrue(seg.process(synth.draw_hand(0)).has_hand)


class MovingHandTest(unittest.TestCase):
    def sweep(self, i):
        """每帧换一个位置的手：整段下来扫过很大一块面积。"""
        x = 50 + (i * 7) % 180
        return synth.draw_hand(0, center=(x, 80 + (i * 11) % 220), r=45)

    def test_moving_hand_restarts_countdown_until_retry_limit(self):
        seg, clock, cfg = make()
        frames = int(cfg["background"]["frames"])
        limit = int(cfg["background"]["calib_max_retries"])
        seg.calibrate(2.0)
        clock.t += 2.0
        i = 0
        for retry in range(limit):
            for _ in range(frames):
                seg.process(self.sweep(i))
                i += 1
            self.assertGreater(seg.last_motion_ratio, cfg["background"]["calib_motion_max"])
            self.assertEqual(seg.calib_retries, retry + 1)
            self.assertTrue(seg.calibrating)
            self.assertFalse(seg.calibrated)
            self.assertEqual(seg.calib_countdown, 2)  # 重新倒计时
            clock.t += 2.0
        for _ in range(frames):                       # 重试用完：不再检查，直接接受
            seg.process(self.sweep(i))
            i += 1
        self.assertTrue(seg.calibrated)
        self.assertFalse(seg.calibrating)
        self.assertEqual(seg.calib_retries, limit)

    def test_static_empty_frame_accepted_first_time(self):
        seg, _, cfg = make()
        seg.calibrate(0)
        for _ in range(int(cfg["background"]["frames"])):
            seg.process(synth.canvas())
        self.assertTrue(seg.calibrated)
        self.assertEqual(seg.calib_retries, 0)
        self.assertLess(seg.last_motion_ratio, 0.001)


class SkinExcludedMedianTest(unittest.TestCase):
    def test_hand_over_half_the_frames_still_removed(self):
        def edit(cfg):
            cfg["background"]["calib_max_retries"] = 0   # 只测中值，不测重来
        seg, _, cfg = make(edit)
        frames = int(cfg["background"]["frames"])
        seg.calibrate(0)
        hand_frames = frames * 2 // 3                    # 手有三分之二的帧停在同一处，之后才移开
        for i in range(frames):
            if i < hand_frames:
                seg.process(synth.draw_hand(0, center=(140, 200), r=50))
            else:
                seg.process(synth.canvas())
        self.assertTrue(seg.calibrated)
        # 普通中值在手心位置会是肤色；剔除肤色样本的中值是真实背景
        plain = np.median(np.stack([seg._preprocess(synth.draw_hand(0, center=(140, 200), r=50))] * hand_frames
                                   + [seg._preprocess(synth.canvas())] * (frames - hand_frames)), axis=0)
        true_bg = seg._preprocess(synth.canvas())
        self.assertGreater(abs(float(plain[200, 140, 0]) - float(true_bg[200, 140, 0])), 40)
        self.assertLess(abs(float(seg.bg[200, 140, 0]) - float(true_bg[200, 140, 0])), 3)
        # 再喂一只手进去能检测到
        res = seg.process(synth.draw_hand(0, center=(140, 200), r=50))
        self.assertTrue(res.has_hand)

    def test_always_skin_pixels_fall_back_to_plain_median(self):
        """一直是肤色的像素（非肤色样本不足）退回全部样本的中值，不能出现异常值。"""
        def edit(cfg):
            cfg["background"]["calib_max_retries"] = 0
        seg, _, cfg = make(edit)
        wall = synth.canvas()
        cv2.rectangle(wall, (0, 0), (120, 200), synth.SKIN, -1)
        seg.calibrate(0)
        for _ in range(int(cfg["background"]["frames"])):
            seg.process(wall)
        ref = seg._preprocess(wall)
        self.assertLess(float(np.abs(seg.bg - ref.astype(np.float32)).max()), 1.0)


if __name__ == "__main__":
    unittest.main()
