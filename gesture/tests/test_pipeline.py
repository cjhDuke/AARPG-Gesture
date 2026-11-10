import os
import sys
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402  (同时把 gesture/ 加入 sys.path)
import features  # noqa: E402
from segment import Segmenter  # noqa: E402


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()

    def run_pipeline(self, img, seg=None):
        seg = seg or Segmenter(self.cfg)
        res = seg.process(img)
        return res, features.extract(res.mask, self.cfg)

    def test_default_skin_in_fixed_range(self):
        ycc = cv2.cvtColor(np.uint8([[synth.SKIN]]), cv2.COLOR_BGR2YCrCb)[0, 0]
        cr, cb = self.cfg["skin_fixed"]["cr"], self.cfg["skin_fixed"]["cb"]
        self.assertTrue(cr[0] <= ycc[1] <= cr[1] and cb[0] <= ycc[2] <= cb[1], ycc)

    def test_fist(self):
        res, f = self.run_pipeline(synth.draw_hand(0))
        self.assertEqual(f.gesture, "fist", (f.defects, f.solidity))

    def test_palm(self):
        res, f = self.run_pipeline(synth.draw_hand(5))
        self.assertEqual(f.gesture, "palm", (f.defects, f.solidity))
        self.assertEqual(f.defects, 4)

    def test_two(self):
        res, f = self.run_pipeline(synth.draw_hand(2))
        self.assertEqual(f.gesture, "two", (f.defects, f.solidity))

    def test_centroid(self):
        img = synth.draw_hand(0, center=(100, 250))
        res, f = self.run_pipeline(img)
        self.assertAlmostEqual(f.centroid[0], 100, delta=5)
        self.assertAlmostEqual(f.centroid[1], 250, delta=5)

    def test_empty_is_none(self):
        res, f = self.run_pipeline(synth.canvas())
        self.assertFalse(res.has_hand)
        self.assertEqual(f.gesture, "none")

    def test_small_blob_is_none(self):
        img = synth.canvas()
        cv2.circle(img, (140, 180), 12, synth.SKIN, -1)
        res, f = self.run_pipeline(img)
        self.assertEqual(f.gesture, "none")

    def test_calibration_nondefault_color(self):
        blue = (200, 120, 60)  # 偏蓝，Cr 远低于默认范围
        img = synth.draw_hand(5, color=blue, center=(140, 180))
        seg = Segmenter(self.cfg)
        res, f = self.run_pipeline(img, seg)
        self.assertEqual(f.gesture, "none")      # 未标定：固定范围找不到
        seg.calibrate(img)
        self.assertTrue(seg.calibrated)
        res, f = self.run_pipeline(img, seg)
        self.assertTrue(res.has_hand)
        self.assertEqual(f.gesture, "palm", (f.defects, f.solidity))


if __name__ == "__main__":
    unittest.main()
