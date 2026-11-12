"""标定流程：采集 -> 完成；剔除肤色样本的中值。"""
import copy
import os
import sys
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402  (同时把 gesture/ 加入 sys.path)
from segment import Segmenter  # noqa: E402


def make(cfg_edit=None):
    cfg = copy.deepcopy(synth.load_cfg())
    if cfg_edit:
        cfg_edit(cfg)
    return Segmenter(cfg), cfg


class CalibrateTest(unittest.TestCase):
    def test_collect_then_done(self):
        seg, cfg = make()
        frames = int(cfg["background"]["frames"])
        seg.calibrate()
        self.assertTrue(seg.calibrating)
        for i in range(frames):
            self.assertTrue(seg.calibrating)
            self.assertFalse(seg.process(synth.canvas()).has_hand)
        self.assertTrue(seg.calibrated)
        self.assertFalse(seg.calibrating)
        self.assertTrue(seg.process(synth.draw_hand(0)).has_hand)


class SkinExcludedMedianTest(unittest.TestCase):
    def test_hand_over_half_the_frames_still_removed(self):
        seg, cfg = make()
        frames = int(cfg["background"]["frames"])
        seg.calibrate()
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
        seg, cfg = make()
        wall = synth.canvas()
        cv2.rectangle(wall, (0, 0), (120, 200), synth.SKIN, -1)
        seg.calibrate()
        for _ in range(int(cfg["background"]["frames"])):
            seg.process(wall)
        ref = seg._preprocess(wall)
        self.assertLess(float(np.abs(seg.bg - ref.astype(np.float32)).max()), 1.0)


if __name__ == "__main__":
    unittest.main()
