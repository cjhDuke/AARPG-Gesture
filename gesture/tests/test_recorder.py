"""录像器：写出的视频、元数据和直方图能被原样读回。"""
import os
import shutil
import sys
import tempfile
import unittest

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from recorder import Recorder, load_sidecar  # noqa: E402


class RecorderTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _frame(self, v=0):
        return np.full((120, 160, 3), v, np.uint8)

    def test_round_trip(self):
        rec = Recorder(self.dir)
        hist = np.arange(16, dtype=np.float32).reshape(4, 4)
        path = rec.start(self._frame(), 2, hist)
        self.assertTrue(rec.active)
        for i in range(10):
            self.assertFalse(rec.write(self._frame(i * 20)))
        self.assertEqual(rec.stop(), path)
        self.assertFalse(rec.active)

        meta, hist2 = load_sidecar(path)
        self.assertEqual(meta["roi_index"], 2)
        self.assertEqual(meta["frames"], 10)
        self.assertTrue(meta["mirrored"] and meta["calibrated"])
        np.testing.assert_array_equal(hist, hist2)

        cap = cv2.VideoCapture(path)
        n = 0
        while cap.read()[0]:
            n += 1
        cap.release()
        self.assertEqual(n, 10)

    def test_uncalibrated_and_recalibrate(self):
        rec = Recorder(self.dir)
        path = rec.start(self._frame(), 0, None)
        meta, hist = load_sidecar(path)
        self.assertFalse(meta["calibrated"])
        self.assertIsNone(hist)
        rec.update_meta(1, np.ones((4, 4), np.float32))
        rec.stop()
        meta, hist = load_sidecar(path)
        self.assertEqual(meta["roi_index"], 1)
        self.assertTrue(meta["calibrated"])
        self.assertEqual(hist.shape, (4, 4))

    def test_auto_stop(self):
        rec = Recorder(self.dir, max_seconds=0.0)
        rec.start(self._frame(), 0, None)
        self.assertTrue(rec.write(self._frame()))
        self.assertFalse(rec.active)

    def test_missing_sidecar(self):
        self.assertEqual(load_sidecar(os.path.join(self.dir, "nope.avi")), (None, None))


if __name__ == "__main__":
    unittest.main()
