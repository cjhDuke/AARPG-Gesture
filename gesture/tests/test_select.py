import os
import sys
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402
import features  # noqa: E402
import main  # noqa: E402

FACE = (60, 70)   # 脸的圆心：半径 55，面积比手大


def scene(hand_center=None, face=None, hand_r=40):
    img = synth.canvas()
    if face:
        cv2.circle(img, face, 55, synth.SKIN, -1)
    if hand_center:
        cv2.circle(img, hand_center, hand_r, synth.SKIN, -1)
    return img


class SelectorTest(unittest.TestCase):
    """脸在采集背景之后才进入操作框（所以是前景），手仍应被选中并跟住。"""

    def setUp(self):
        self.cfg = synth.load_cfg()
        self.seg = synth.make_segmenter(self.cfg)

    def palm(self, img):
        res = self.seg.process(img)
        return res, features.extract(res.mask, self.cfg).palm

    def test_hand_tracked_not_face(self):
        res, c = self.palm(scene((140, 180)))
        self.assertTrue(res.has_hand)
        path = [(140, 180), (155, 195), (170, 215), (190, 235), (210, 255), (225, 275),
                (215, 290), (200, 300), (180, 295), (160, 285)]
        for p in path + path[::-1]:  # 来回走，每步位移都不大；期间脸出现在左上角
            res, c = self.palm(scene(p, FACE))
            self.assertTrue(res.has_hand, p)
            self.assertAlmostEqual(c[0], p[0], delta=6, msg=str(p))
            self.assertAlmostEqual(c[1], p[1], delta=6, msg=str(p))

    def test_hand_leaves_then_returns(self):
        self.palm(scene((140, 180)))  # 先只有手：跟踪锁在手上
        for _ in range(20):  # 脸进来后静止不动，让 static_avg 学到它
            self.palm(scene((140, 180), FACE))
        for _ in range(5):  # 手移出画面，只剩脸
            res, c = self.palm(scene(None, FACE))
            self.assertFalse(res.has_hand)
            self.assertIsNone(c)
        res, c = self.palm(scene((210, 300), FACE))  # 手从别处重新出现
        self.assertTrue(res.has_hand)
        self.assertAlmostEqual(c[0], 210, delta=6)
        self.assertAlmostEqual(c[1], 300, delta=6)

    def test_hand_touching_face_is_split(self):
        """脸的一侧露在操作框左边，手靠过去连成一块：手仍然单独被选中，掌心不被脸带偏。"""
        def strip_scene(hand=None):
            img = synth.canvas()
            cv2.rectangle(img, (0, 60), (40, 220), synth.SKIN, -1)
            if hand:
                cv2.circle(img, hand, 40, synth.SKIN, -1)
            return img
        for _ in range(20):  # 只有脸：贴边窄条不算手，并被记成静止肤色
            res, c = self.palm(strip_scene())
            self.assertFalse(res.has_hand)
        for x in (200, 170, 140, 110, 78):  # 手从右边靠过来，最后和脸连在一起
            res, c = self.palm(strip_scene((x, 140)))
            self.assertTrue(res.has_hand, x)
        self.assertGreater(c[0], 60, c)
        self.assertEqual(int(res.mask[100:180, 0:30].max()), 0)  # 脸那一条不在手的掩膜里
        for _ in range(5):  # 手离开后不会跟到脸上
            res, c = self.palm(strip_scene())
            self.assertFalse(res.has_hand)

    def test_hand_at_side_edge_still_tracked(self):
        """手伸到操作框右边、贴着边界，但它比窄条宽得多，不能被当成脸丢掉。"""
        for x in (140, 180, 215, 235):
            res, c = self.palm(scene((x, 200)))
            self.assertTrue(res.has_hand, x)

    def test_calibrate_clears_state(self):
        for _ in range(5):
            self.palm(scene((140, 180)))
        self.assertTrue(self.seg.selector.tracking)
        self.seg.calibrate()
        self.assertFalse(self.seg.selector.tracking)
        self.assertIsNone(self.seg.selector.static_avg)
        self.assertFalse(self.seg.calibrated)


class RoiAndStageTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()

    def test_roi_presets(self):
        presets = self.cfg["roi_presets"]
        self.assertEqual(len(presets), 4)
        self.assertEqual([p["name"] for p in presets][:2], ["right", "left"])
        for p in presets:  # 都在 640x480 画面内
            self.assertTrue(p["x"] >= 0 and p["y"] >= 0 and p["x"] + p["w"] <= 640 and p["y"] + p["h"] <= 480, p)

    def test_stage_frames(self):
        frame = np.full((480, 640, 3), 90, np.uint8)
        cv2.circle(frame, (515, 270), 60, synth.SKIN, -1)
        roi, rect = main.crop_roi(frame, self.cfg["roi_presets"][0])
        seg = synth.make_segmenter(self.cfg, np.full(roi.shape, 90, np.uint8))
        res = seg.process(roi)
        feats = features.extract(res.mask, self.cfg)
        self.assertEqual(feats.gesture, "fist")
        jpg = main.encode_stage(0, frame, rect, res, feats, self.cfg)
        img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
        self.assertEqual(img.shape[:2], (240, 320))  # 阶段 0 是整幅画面
        self.assertLess(len(jpg), 60000)
        for stage in (1, 2, 3):
            jpg1 = main.encode_stage(stage, frame, rect, res, feats, self.cfg)
            img1 = cv2.imdecode(np.frombuffer(jpg1, np.uint8), cv2.IMREAD_GRAYSCALE)
            self.assertEqual(max(img1.shape), 320)
            self.assertNotEqual(img1.shape, (240, 320))  # 操作框区域，不是整幅


if __name__ == "__main__":
    unittest.main()
