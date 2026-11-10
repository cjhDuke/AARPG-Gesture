import os
import sys
import unittest

import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402
import features  # noqa: E402
from segment import Segmenter  # noqa: E402
import main  # noqa: E402

FACE = (60, 70)   # 脸的圆心：半径 55，面积比手大，且离中心的手很远


def scene(hand_center=None, face=True, hand_r=40):
    img = synth.canvas()
    if face:
        cv2.circle(img, FACE, 55, synth.SKIN, -1)
    if hand_center:
        cv2.circle(img, hand_center, hand_r, synth.SKIN, -1)
    return img


class SelectorTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()
        self.seg = Segmenter(self.cfg)

    def centroid(self, img):
        res = self.seg.process(img)
        f = features.extract(res.mask, self.cfg)
        return res, f.centroid

    def calibrate_on_center(self):
        """标定：手在中心采样框上，脸在左上角。"""
        img = scene((140, 180))
        self.seg.calibrate(img)
        return img

    def test_hand_tracked_not_face(self):
        img = self.calibrate_on_center()
        res, c = self.centroid(img)
        self.assertTrue(res.has_hand)
        self.assertAlmostEqual(c[0], 140, delta=5)
        path = [(140, 180), (155, 195), (170, 215), (190, 235), (210, 255), (225, 275),
                (215, 290), (200, 300), (180, 295), (160, 285)]
        for p in path + path[::-1]:  # 来回走，每步位移都不大
            res, c = self.centroid(scene(p))
            self.assertTrue(res.has_hand, p)
            self.assertAlmostEqual(c[0], p[0], delta=6, msg=str(p))
            self.assertAlmostEqual(c[1], p[1], delta=6, msg=str(p))

    def test_hand_leaves_then_returns(self):
        self.calibrate_on_center()
        for _ in range(20):  # 让 static_avg 学到脸
            self.centroid(scene((140, 180)))
        for _ in range(5):  # 手移出画面，只剩脸
            res, c = self.centroid(scene(None))
            self.assertFalse(res.has_hand)
            self.assertIsNone(c)
        res, c = self.centroid(scene((210, 300)))  # 手从别处重新出现
        self.assertTrue(res.has_hand)
        self.assertAlmostEqual(c[0], 210, delta=6)
        self.assertAlmostEqual(c[1], 300, delta=6)

    def test_first_frame_prefers_center_component(self):
        # 刚标定完的第一帧：脸(面积更大)也在画面里，仍应选中心的手
        img = self.calibrate_on_center()
        res, c = self.centroid(img)
        self.assertLess(abs(c[0] - 140), 6)
        self.assertGreater(cv2.countNonZero(res.mask), 0)
        self.assertLess(res.area, 55 * 55 * 3.1)  # 不是脸

    def test_roi_resize_no_crash(self):
        self.calibrate_on_center()
        self.centroid(scene((140, 180)))
        small = cv2.resize(scene((140, 180)), (200, 250))
        res = self.seg.process(small)  # 尺寸变化：自动重置，不能崩
        self.assertEqual(res.mask.shape, (250, 200))
        self.seg.reset_tracking()
        self.seg.process(scene((140, 180)))

    def test_calibrate_clears_state(self):
        self.calibrate_on_center()
        for _ in range(5):
            self.centroid(scene((140, 180)))
        self.assertTrue(self.seg.selector.tracking)
        self.seg.calibrate(scene((140, 180)))
        self.assertFalse(self.seg.selector.tracking)
        self.assertIsNone(self.seg.selector.static_avg)


class RoiAndStageTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()

    def test_roi_index_wraps(self):
        n = len(self.cfg["roi_presets"])
        self.assertEqual(n, 4)
        self.assertEqual([p["name"] for p in self.cfg["roi_presets"]][:2], ["right", "left"])
        self.assertEqual(7 % n, 3)  # load_roi_index 对越界下标取模

    def test_stage0_full_frame(self):
        import numpy as np
        frame = np.full((480, 640, 3), 90, np.uint8)
        roi, rect = main.crop_roi(frame, self.cfg["roi_presets"][0])
        seg = Segmenter(self.cfg)
        res = seg.process(roi)
        feats = features.extract(res.mask, self.cfg)
        jpg = main.encode_stage(0, frame, rect, res, feats, self.cfg)
        img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
        self.assertEqual(img.shape[:2], (96, 128))
        self.assertLess(len(jpg), 60000)
        jpg1 = main.encode_stage(1, frame, rect, res, feats, self.cfg)
        img1 = cv2.imdecode(np.frombuffer(jpg1, np.uint8), cv2.IMREAD_GRAYSCALE)
        self.assertEqual(max(img1.shape), 128)
        self.assertNotEqual(img1.shape, (96, 128))  # 操作框区域，不是整幅


if __name__ == "__main__":
    unittest.main()
