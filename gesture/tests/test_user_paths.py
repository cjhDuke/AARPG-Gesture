import importlib.util
import json
import os
import tempfile
import unittest
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
spec = importlib.util.spec_from_file_location("gesture_main", os.path.join(ROOT, "main.py"))
main = importlib.util.module_from_spec(spec)
spec.loader.exec_module(main)


class UserPathsTests(unittest.TestCase):
    def test_managed_and_standalone_paths(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            user = main.resolve_user_paths(os.path.join(tmp, "userdata"))
            dev = main.resolve_user_paths(script_dir=tmp)
            self.assertEqual(user["recordings"], os.path.join(tmp, "userdata", "recordings"))
            self.assertEqual(user["screenshots"], os.path.join(tmp, "userdata", "screenshots"))
            self.assertEqual(dev["state"], os.path.join(tmp, "state.json"))
            self.assertNotEqual(user["state"], dev["state"])
            with self.assertRaises(ValueError):
                main.resolve_user_paths("relative")

    def test_bad_state_falls_back_to_default(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            path = os.path.join(tmp, "state.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{")
            self.assertIsNone(main.valid_roi_index(path, 4))
            self.assertEqual(main.load_roi_index({"roi_presets": [0, 1, 2], "roi_index": 2}, path), 2)

    def test_save_replaces_user_state_without_leaving_staging_files(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            target = os.path.join(tmp, "new", "state.json")
            main.save_roi_index(3, target)
            main.save_roi_index(2, target)
            with open(target, encoding="utf-8") as f:
                self.assertEqual(json.load(f), {"roi_index": 2})
            self.assertEqual(os.listdir(os.path.dirname(target)), ["state.json"])


if __name__ == "__main__":
    unittest.main()
