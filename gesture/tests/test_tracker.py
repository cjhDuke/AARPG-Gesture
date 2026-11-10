import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402
from tracker import GestureDebouncer, ZoneTracker  # noqa: E402


class DebouncerTest(unittest.TestCase):
    def setUp(self):
        self.d = GestureDebouncer(synth.load_cfg())

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


class ZoneTest(unittest.TestCase):
    def setUp(self):
        self.z = ZoneTracker(synth.load_cfg())  # 内 0.10 外 0.18

    def test_sectors(self):
        cases = {(0.3, 0.0): "right", (-0.3, 0.05): "left",
                 (0.02, 0.3): "down", (0.0, -0.3): "up"}
        for (dx, dy), want in cases.items():
            z = ZoneTracker(synth.load_cfg())
            self.assertEqual(z.update(True, dx, dy), want)

    def test_hysteresis(self):
        self.assertEqual(self.z.update(True, 0.0, 0.0), "center")
        self.assertEqual(self.z.update(True, 0.17, 0.0), "center")   # 两圈之间，保持 center
        self.assertEqual(self.z.update(True, 0.25, 0.0), "right")
        self.assertEqual(self.z.update(True, 0.17, 0.0), "right")    # 两圈之间，保持 right
        self.assertEqual(self.z.update(True, 0.05, 0.0), "center")   # 回到内圈才复位

    def test_no_hand_resets(self):
        self.z.update(True, 0.3, 0.0)
        self.assertEqual(self.z.update(False), "center")


if __name__ == "__main__":
    unittest.main()
