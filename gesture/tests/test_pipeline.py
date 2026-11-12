import os
import sys
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402  (同时把 gesture/ 加入 sys.path)
import features  # noqa: E402
from segment import Segmenter  # noqa: E402
from tracker import GestureDebouncer  # noqa: E402


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()
        self.seg = synth.make_segmenter(self.cfg)

    def run_pipeline(self, img, seg=None):
        res = (seg or self.seg).process(img)
        return res, features.extract(res.mask, self.cfg)

    def test_skin_color_in_range(self):
        ycc = cv2.cvtColor(np.uint8([[synth.SKIN]]), cv2.COLOR_BGR2YCrCb)[0, 0]
        cr, cb = self.cfg["skin_range"]["cr"], self.cfg["skin_range"]["cb"]
        self.assertTrue(cr[0] <= ycc[1] <= cr[1] and cb[0] <= ycc[2] <= cb[1], ycc)

    def test_fist(self):
        res, f = self.run_pipeline(synth.draw_hand(0))
        self.assertEqual(f.gesture, "fist", f.open_ratio)
        self.assertLess(f.open_ratio, 1.3)

    def test_palm(self):
        res, f = self.run_pipeline(synth.draw_hand(5))
        self.assertEqual(f.gesture, "palm", f.open_ratio)
        self.assertGreater(f.open_ratio, 2.5)

    def test_palm_center_and_radius(self):
        for n in (0, 5):
            res, f = self.run_pipeline(synth.draw_hand(n, center=(100, 250)))
            self.assertAlmostEqual(f.palm[0], 100, delta=5)
            self.assertAlmostEqual(f.palm[1], 250, delta=8)
            self.assertAlmostEqual(f.radius, 50, delta=6)

    def test_ratio_scale_invariant(self):
        _, big = self.run_pipeline(synth.draw_hand(5, center=(140, 220), r=50))
        small_img = cv2.resize(synth.draw_hand(5, center=(140, 220), r=50), None, fx=0.6, fy=0.6,
                               interpolation=cv2.INTER_NEAREST)
        canvas = synth.canvas()
        canvas[100:100 + small_img.shape[0], 50:50 + small_img.shape[1]] = small_img
        _, small = self.run_pipeline(canvas)
        self.assertEqual(small.gesture, "palm")
        self.assertAlmostEqual(big.open_ratio, small.open_ratio, delta=0.35)

    def test_fist_with_forearm_stays_fist(self):
        for arm in ("down", "left"):
            res, f = self.run_pipeline(synth.draw_hand(0, center=(150, 150), arm=arm))
            self.assertIsNotNone(f.arm_dir, arm)
            self.assertEqual(f.gesture, "fist", (arm, f.open_ratio))
            self.assertAlmostEqual(f.palm[0], 150, delta=8)
            self.assertAlmostEqual(f.palm[1], 150, delta=8)

    def test_palm_with_forearm_stays_palm(self):
        res, f = self.run_pipeline(synth.draw_hand(5, center=(150, 190), arm="down"))
        self.assertEqual(f.gesture, "palm", f.open_ratio)
        self.assertLess(f.far[1], 190)  # 最远点在手指上，不在小臂上

    def test_palm_stays_on_hand_when_forearm_is_thicker(self):
        """小臂越往下越粗、最粗处比拳头还粗：掌心仍应落在拳头上，不跑到小臂上。"""
        img = synth.canvas()
        cv2.fillPoly(img, [np.int32([(128, 120), (172, 120), (205, 359), (95, 359)])], synth.SKIN)
        cv2.circle(img, (150, 110), 40, synth.SKIN, -1)
        res, f = self.run_pipeline(img)
        self.assertAlmostEqual(f.palm[0], 150, delta=10)
        self.assertLess(f.palm[1], 135, f.palm)
        self.assertEqual(f.gesture, "fist", f.open_ratio)

    def test_closed_fingers_open_hand_is_palm(self):
        """手指并拢的张开手（没有指缝，张开度只有 2.4 左右）也要判成张开。"""
        img = synth.canvas()
        cv2.circle(img, (140, 220), 45, synth.SKIN, -1)
        cv2.rectangle(img, (105, 112), (175, 220), synth.SKIN, -1)
        res, f = self.run_pipeline(img)
        self.assertGreater(f.open_ratio, self.cfg["features"]["palm_min_ratio"])
        self.assertLess(f.open_ratio, 2.6)
        self.assertEqual(f.gesture, "palm", f.open_ratio)

    def test_fingers_clipped_by_top_is_not_fist(self):
        """指尖伸出操作框上沿：量到的张开度偏低，但不能据此判成握拳。"""
        res, f = self.run_pipeline(synth.draw_hand(5, center=(140, 70), r=50))
        self.assertLess(f.open_ratio, self.cfg["features"]["fist_max_ratio"])
        self.assertEqual(f.gesture, "between")
        res, f = self.run_pipeline(synth.draw_hand(0, center=(140, 120), r=50))
        self.assertEqual(f.gesture, "fist")  # 没碰到上沿的拳头照常判定

    def test_between_thresholds(self):
        fc = self.cfg["features"]
        mid = (fc["fist_max_ratio"] + fc["palm_min_ratio"]) / 2
        self.assertEqual(features.classify(mid, fc), "between")

    def test_empty_is_none(self):
        res, f = self.run_pipeline(synth.canvas())
        self.assertFalse(res.has_hand)
        self.assertEqual(f.gesture, "none")
        self.assertIsNone(f.palm)

    def test_small_blob_is_none(self):
        img = synth.canvas()
        cv2.circle(img, (140, 180), 12, synth.SKIN, -1)
        res, f = self.run_pipeline(img)
        self.assertEqual(f.gesture, "none")


class EdgeHoldTest(unittest.TestCase):
    """手（不含小臂）贴到操作框左 / 右 / 上边界时 edge=True；防抖器在贴边时更难从 fist 切走。"""

    def setUp(self):
        self.cfg = synth.load_cfg()
        self.seg = synth.make_segmenter(self.cfg)

    def feats(self, img):
        # 每次用全新的分割器：手跟踪会记住上一帧的位置，连续喂跳变的画面会被当成另一只手
        seg = synth.make_segmenter(self.cfg)
        return features.extract(seg.process(img).mask, self.cfg)

    def test_interior_hand_not_edge(self):
        f = self.feats(synth.draw_hand(0, center=(140, 200)))
        self.assertFalse(f.edge)

    def test_forearm_from_bottom_not_edge(self):
        f = self.feats(synth.draw_hand(0, center=(150, 150), arm="down"))
        self.assertFalse(f.edge)

    def test_left_and_right_touch_is_edge(self):
        for cx in (45, synth.W - 45):  # 拳半径 50：贴着左 / 右边界
            f = self.feats(synth.draw_hand(0, center=(cx, 200)))
            self.assertTrue(f.edge, cx)

    def test_top_touch_is_edge(self):
        f = self.feats(synth.draw_hand(0, center=(140, 45)))
        self.assertTrue(f.edge)

    def test_below_threshold_pixels_ignored(self):
        cfg = synth.load_cfg()
        cfg["features"]["edge_touch_pixels"] = 10 ** 6
        f = features.extract(self.seg.process(synth.draw_hand(0, center=(45, 200))).mask, cfg)
        self.assertFalse(f.edge)

    def test_no_hand_not_edge(self):
        f = self.feats(synth.canvas())
        self.assertFalse(f.edge)

    def test_arm_on_side_edge_not_counted(self):
        """小臂贴着侧边界不算贴边：只看掌心附近、非小臂一侧的边界像素。"""
        mask = np.zeros((synth.H, synth.W), np.uint8)
        cv2.circle(mask, (140, 150), 50, 255, -1)
        cv2.line(mask, (140, 150), (synth.W - 1, synth.H - 40), 255, 44)  # 小臂伸向右下，从右边界出框
        f = features.extract(mask, self.cfg)
        self.assertIsNotNone(f.arm_dir)
        self.assertFalse(f.edge)

    def test_debouncer_slow_release_while_clipped(self):
        """握拳中手贴边：要连续 fist_release_frames_edge 帧张开才松开；握拳的判定不被贴边拖慢。"""
        t = self.cfg["tracker"]
        deb = GestureDebouncer(self.cfg)
        for _ in range(t["debounce_frames"]):
            deb.update("fist", True)
        self.assertEqual(deb.stable, "fist")
        for _ in range(t["fist_release_frames_edge"] - 1):
            self.assertEqual(deb.update("palm", True), "fist")
        self.assertEqual(deb.update("palm", True), "palm")
        deb = GestureDebouncer(self.cfg)
        for _ in range(t["debounce_frames"]):
            deb.update("fist")
        for _ in range(t["fist_release_frames"] - 1):
            self.assertEqual(deb.update("palm"), "fist")
        self.assertEqual(deb.update("palm"), "palm")


class BackgroundTest(unittest.TestCase):
    def setUp(self):
        self.cfg = synth.load_cfg()

    def test_uncalibrated_outputs_nothing(self):
        seg = Segmenter(self.cfg)
        res = seg.process(synth.draw_hand(5))
        self.assertFalse(seg.calibrated)
        self.assertFalse(res.has_hand)

    def test_calibrate_collects_frames(self):
        seg = Segmenter(self.cfg)
        seg.calibrate()
        for _ in range(int(self.cfg["background"]["frames"])):
            self.assertTrue(seg.calibrating)
            self.assertFalse(seg.process(synth.canvas()).has_hand)
        self.assertTrue(seg.calibrated)
        self.assertFalse(seg.calibrating)
        self.assertTrue(seg.process(synth.draw_hand(0)).has_hand)

    def test_static_skin_colored_background_ignored(self):
        # 背景里本来就有一大块肤色（米色墙面）：不能被当成手
        wall = synth.canvas()
        cv2.rectangle(wall, (0, 0), (120, 200), synth.SKIN, -1)
        seg = synth.make_segmenter(self.cfg, wall)
        self.assertFalse(seg.process(wall).has_hand)
        hand = wall.copy()
        cv2.circle(hand, (200, 260), 45, synth.SKIN, -1)
        res = seg.process(hand)
        self.assertTrue(res.has_hand)
        f = features.extract(res.mask, self.cfg)
        self.assertAlmostEqual(f.palm[0], 200, delta=6)

    def test_moving_non_skin_object_ignored(self):
        seg = synth.make_segmenter(self.cfg)
        img = synth.canvas()
        cv2.circle(img, (140, 180), 60, synth.SLEEVE, -1)
        self.assertFalse(seg.process(img).has_hand)

    def test_brightness_drift_tolerated(self):
        seg = synth.make_segmenter(self.cfg)
        brighter = synth.canvas((105, 105, 105))
        for _ in range(60):
            self.assertFalse(seg.process(brighter).has_hand)
        self.assertAlmostEqual(float(seg.bg[0, 0, 0]), 105, delta=4)  # 背景跟上了亮度变化

    def test_still_hand_not_absorbed(self):
        seg = synth.make_segmenter(self.cfg)
        img = synth.draw_hand(0)
        for _ in range(120):
            res = seg.process(img)
        self.assertTrue(res.has_hand)

    def test_still_hand_area_kept(self):
        seg = synth.make_segmenter(self.cfg)
        img = synth.draw_hand(0)
        first = seg.process(img).area
        for _ in range(120):
            res = seg.process(img)
        self.assertTrue(res.has_hand)
        self.assertGreater(res.area, first * 0.9)

    def _ghost_run(self, ghost_alpha):
        # 背景模型里留着一只肤色"鬼影手"，真实画面里那里其实是灰墙
        cfg = synth.load_cfg()
        cfg["background"]["ghost_alpha"] = ghost_alpha
        seg = synth.make_segmenter(cfg, synth.draw_hand(0))
        for _ in range(60):
            self.assertFalse(seg.process(synth.canvas()).has_hand)
        return seg.process(synth.draw_hand(0)).has_hand

    def test_ghost_background_heals(self):
        self.assertTrue(self._ghost_run(0.1))

    def test_ghost_persists_without_healing(self):
        self.assertFalse(self._ghost_run(0.0))

    def test_roi_resize_needs_recalibration(self):
        seg = synth.make_segmenter(self.cfg)
        small = cv2.resize(synth.draw_hand(0), (200, 250))
        res = seg.process(small)  # 尺寸变化：背景作废，不能崩
        self.assertEqual(res.mask.shape, (250, 200))
        self.assertFalse(seg.calibrated)


class ContourSimplifyTest(unittest.TestCase):
    """手影用的轮廓多边形：点数上限、归一化范围、状态包体积。"""

    def setUp(self):
        self.cfg = synth.load_cfg()
        self.seg = synth.make_segmenter(self.cfg)

    def contour_of(self, n_fingers):
        res = self.seg.process(synth.draw_hand(n_fingers))
        return features.extract(res.mask, self.cfg).contour

    def test_limits_and_range(self):
        for n in (0, 5):
            poly = features.simplify_contour(self.contour_of(n), synth.W, synth.H)
            self.assertGreaterEqual(len(poly), 3)
            self.assertLessEqual(len(poly), 48)
            for x, y in poly:
                self.assertTrue(0.0 <= x <= 1.0 and 0.0 <= y <= 1.0, (x, y))
                self.assertEqual(round(x, 3), x)

    def test_point_cap_enforced(self):
        # 很毛糙的圆：epsilon 初值下点数会很多，必须被压到 48 以内
        c = np.int32([[[140 + 80 * np.cos(a) * (1 + 0.15 * np.sin(40 * a)),
                        150 + 80 * np.sin(a) * (1 + 0.15 * np.sin(40 * a))]]
                      for a in np.linspace(0, 2 * np.pi, 600, endpoint=False)])
        poly = features.simplify_contour(c, 280, 360, eps_ratio=0.001)
        self.assertLessEqual(len(poly), 48)

    def test_empty(self):
        self.assertEqual(features.simplify_contour(None, 280, 360), [])

    def test_state_packet_small(self):
        import json
        poly = features.simplify_contour(self.contour_of(5), synth.W, synth.H)
        st = {"seq": 1, "roi": [370, 0, 270, 480], "frame": [640, 480], "contour": poly}
        self.assertLess(len(json.dumps(st)) + 600, 2000)  # 其余字段约 350 字节，单包远小于 8KB


if __name__ == "__main__":
    unittest.main()
