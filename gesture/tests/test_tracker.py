import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402
from tracker import GestureDebouncer, PointSmoother, ZoneTracker  # noqa: E402


def cfg_with(**tracker):
    cfg = synth.load_cfg()
    cfg["tracker"].update(tracker)
    return cfg


class DebouncerTest(unittest.TestCase):
    def setUp(self):
        self.d = GestureDebouncer(cfg_with(debounce_frames=2, fist_release_frames=3))

    def feed(self, seq):
        return [self.d.update(g) for g in seq]

    def test_single_glitch_ignored(self):
        out = self.feed(["palm", "palm", "fist", "palm", "palm"])
        self.assertEqual(out, ["none", "palm", "palm", "palm", "palm"])

    def test_two_frames_switch(self):
        self.assertEqual(self.feed(["fist", "fist"]), ["none", "fist"])

    def test_fist_release_needs_three(self):
        self.feed(["fist", "fist"])
        out = self.feed(["palm", "palm", "palm"])
        self.assertEqual(out, ["fist", "fist", "palm"])

    def test_fist_glitch_resets_count(self):
        self.feed(["fist", "fist"])
        out = self.feed(["palm", "palm", "fist", "palm", "palm"])
        self.assertEqual(out[-1], "fist")

    def test_between_keeps_current_state(self):
        self.feed(["fist", "fist"])
        self.assertEqual(self.feed(["between"] * 6), ["fist"] * 6)
        self.feed(["palm", "palm", "palm"])
        self.assertEqual(self.feed(["between"] * 6), ["palm"] * 6)

    def test_between_from_none_becomes_palm(self):
        self.assertEqual(self.feed(["between", "between"]), ["none", "palm"])

    def test_hand_lost(self):
        self.feed(["palm", "palm"])
        self.assertEqual(self.feed(["none", "none"])[-1], "none")


class SmootherTest(unittest.TestCase):
    def make(self):
        return PointSmoother(cfg_with(smooth_alpha=0.5, dead_zone=0.01))

    def test_first_sample_passes_through(self):
        self.assertEqual(self.make().update(0.3, 0.7), (0.3, 0.7))

    def test_jitter_inside_dead_zone_is_frozen(self):
        s = self.make()
        s.update(0.5, 0.5)
        for i in range(20):
            out = s.update(0.5 + (0.004 if i % 2 else -0.004), 0.5)
        self.assertEqual(out, (0.5, 0.5))

    def test_follows_real_movement(self):
        s = self.make()
        s.update(0.2, 0.2)
        for _ in range(12):
            out = s.update(0.8, 0.6)
        self.assertAlmostEqual(out[0], 0.8, delta=0.02)
        self.assertAlmostEqual(out[1], 0.6, delta=0.02)

    def test_reset(self):
        s = self.make()
        s.update(0.2, 0.2)
        s.reset()
        self.assertEqual(s.update(0.9, 0.9), (0.9, 0.9))


class ZoneTest(unittest.TestCase):
    def make(self):
        return ZoneTracker(cfg_with(zone_inner=0.10, zone_outer=0.18))

    def test_sectors(self):
        cases = {(0.3, 0.0): "right", (-0.3, 0.05): "left",
                 (0.02, 0.3): "down", (0.0, -0.3): "up"}
        for (dx, dy), want in cases.items():
            self.assertEqual(self.make().update(True, dx, dy), want)

    def test_hysteresis(self):
        z = self.make()
        self.assertEqual(z.update(True, 0.0, 0.0), "center")
        self.assertEqual(z.update(True, 0.17, 0.0), "center")   # 两圈之间，保持 center
        self.assertEqual(z.update(True, 0.25, 0.0), "right")
        self.assertEqual(z.update(True, 0.17, 0.0), "right")    # 两圈之间，保持 right
        self.assertEqual(z.update(True, 0.05, 0.0), "center")   # 回到内圈才复位

    def test_no_hand_resets(self):
        z = self.make()
        z.update(True, 0.3, 0.0)
        self.assertEqual(z.update(False), "center")


if __name__ == "__main__":
    unittest.main()
