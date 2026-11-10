"""假的识别端：不开摄像头，按脚本向 Godot 发状态包和（可选）画面包，用于联调。

用法：python fake_sender.py [--script demo|idle] [--duration 秒]
"""
import argparse
import json
import socket
import threading
import time

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None

SEND_ADDR = ("127.0.0.1", 47800)
CMD_ADDR = ("127.0.0.1", 47801)

# (持续秒数, gesture, zone)
DEMO = [
    (1.0, "palm", "center"),
    (0.6, "palm", "right"),
    (0.6, "palm", "center"),
    (0.6, "palm", "up"),
    (0.6, "palm", "center"),
    (1.5, "fist", "center"),
    (0.8, "palm", "center"),
    (0.5, "two", "center"),
    (0.8, "palm", "center"),
]
IDLE = [(1.0, "palm", "center")]
ZONE_XY = {"center": (0.5, 0.5), "up": (0.5, 0.1), "down": (0.5, 0.9),
           "left": (0.1, 0.5), "right": (0.9, 0.5)}


def listen_commands(sock, stop):
    sock.settimeout(0.2)
    while not stop.is_set():
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        print("[cmd]", data.decode("utf-8", "replace"), flush=True)
        try:
            if json.loads(data).get("cmd") == "quit":
                stop.set()
        except ValueError:
            pass


def make_frame(t):
    img = np.zeros((128, 128, 3), np.uint8)
    x = int(64 + 40 * np.sin(t * 3))
    cv2.circle(img, (x, 64), 12, (0, 200, 255), -1)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])
    return b"F" + bytes([0]) + buf.tobytes() if ok else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", choices=["demo", "idle"], default="demo")
    ap.add_argument("--duration", type=float, default=0)
    args = ap.parse_args()
    script = DEMO if args.script == "demo" else IDLE

    cmd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cmd_sock.bind(CMD_ADDR)
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stop = threading.Event()
    threading.Thread(target=listen_commands, args=(cmd_sock, stop), daemon=True).start()

    start = time.monotonic()
    total = sum(s[0] for s in script)
    seq = 0
    while not stop.is_set():
        now = time.monotonic()
        t = now - start
        if args.duration and t >= args.duration:
            break
        pos = t % total
        for dur, gesture, zone in script:
            if pos < dur:
                break
            pos -= dur
        cx, cy = ZONE_XY[zone]
        seq += 1
        st = {"seq": seq, "t_ms": now * 1000, "hand": True, "gesture": gesture,
              "zone": zone, "cx": cx, "cy": cy, "defects": 4, "solidity": 0.7,
              "fps": 30.0, "proc_ms": 5.0, "calibrated": True}
        out.sendto(b"S" + json.dumps(st).encode("utf-8"), SEND_ADDR)
        if cv2 is not None and seq % 3 == 0:
            frame = make_frame(t)
            if frame:
                out.sendto(frame, SEND_ADDR)
        time.sleep(1 / 30)
    stop.set()
    print("fake_sender exit", flush=True)


if __name__ == "__main__":
    main()
