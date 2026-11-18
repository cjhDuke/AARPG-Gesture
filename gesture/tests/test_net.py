import json
import os
import socket
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synth  # noqa: E402
from net import Net  # noqa: E402

FIELDS = {"seq", "t_ms", "hand", "gesture", "zone", "cx", "cy", "px", "py",
          "open_ratio", "radius", "fps", "proc_ms", "calibrated", "calibrating"}
STATE_PORT, CMD_PORT = 47900, 47901  # 避开真实端口 47800/47801


class NetTest(unittest.TestCase):
    def setUp(self):
        cfg = synth.load_cfg()
        cfg["net"]["state_port"], cfg["net"]["command_port"] = STATE_PORT, CMD_PORT
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx.bind(("127.0.0.1", STATE_PORT))
        self.rx.settimeout(1.0)
        self.net = Net(cfg)

    def tearDown(self):
        self.net.close()
        self.rx.close()

    def test_state_packet(self):
        state = {k: 0 for k in FIELDS}
        state.update(gesture="fist", zone="center", hand=True, calibrated=False)
        self.net.send_state(state)
        data, _ = self.rx.recvfrom(65535)
        self.assertEqual(data[:1], b"S")
        self.assertEqual(set(json.loads(data[1:].decode("utf-8"))), FIELDS)

    def test_frame_packet(self):
        self.assertTrue(self.net.send_frame(2, b"\xff\xd8abc"))
        data, _ = self.rx.recvfrom(65535)
        self.assertEqual(data[:2], b"F\x02")
        self.assertEqual(data[2:], b"\xff\xd8abc")
        self.assertFalse(self.net.send_frame(0, b"x" * 60000))

    def test_commands(self):
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for payload in (b'{"cmd":"ping"}', b"garbage", b'{"cmd":"stage","value":2}'):
            tx.sendto(payload, ("127.0.0.1", CMD_PORT))
        tx.close()
        time.sleep(0.1)
        cmds = self.net.poll_commands()
        self.assertEqual([c["cmd"] for c in cmds], ["ping", "stage"])
        self.assertEqual(self.net.poll_commands(), [])


if __name__ == "__main__":
    unittest.main()
