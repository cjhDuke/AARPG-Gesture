"""假的识别端：不开摄像头，按脚本向 Godot 发状态包和（可选）画面包，用于联调。

用法：python fake_sender.py [--script demo|idle|uncal] [--duration 秒]

脚本：
  demo   张开手沿矩形轨迹移动 -> 握拳并移动 -> 张开 -> 手消失 1 秒 -> 重复
  idle   已标定、操作框内没有手
  uncal  未标定（calibrated=false，没有手势）
状态包字段见 docs/ai/gesture-protocol.md。
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

# 每段：(持续秒数, 手势, 路径点列表)。手势 "none" 表示无手。
# 路径是操作框归一化坐标的折线，段内按时间均匀走完。
RECT = [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8), (0.2, 0.2)]
DEMO = [
    (8.0, "palm", RECT),
    (2.0, "fist", [(0.2, 0.2), (0.7, 0.5)]),
    (1.5, "palm", [(0.7, 0.5), (0.5, 0.5)]),
    (1.0, "none", [(0.5, 0.5)]),
]
IDLE = [(1.0, "none", [(0.5, 0.5)])]
UNCAL = [(1.0, "none", [(0.5, 0.5)])]
OPEN_RATIO = {"palm": 2.9, "fist": 1.7, "none": 0.0}


def zone_of(x, y):
    """方向区：中心 0.3-0.7 的方框内为 center，否则按偏离最大的轴取方向。"""
    dx, dy = x - 0.5, y - 0.5
    if abs(dx) <= 0.2 and abs(dy) <= 0.2:
        return "center"
    if abs(dx) >= abs(dy):
        return "right" if dx > 0 else "left"
    return "down" if dy > 0 else "up"


def sample_path(points, u):
    """折线上 u(0-1) 处的点，按各段长度加权。"""
    if len(points) == 1:
        return points[0]
    lens = [((points[i + 1][0] - points[i][0]) ** 2 + (points[i + 1][1] - points[i][1]) ** 2) ** 0.5
            for i in range(len(points) - 1)]
    d = u * sum(lens)
    for i, ln in enumerate(lens):
        if d <= ln or i == len(lens) - 1:
            f = 0.0 if ln == 0 else min(d / ln, 1.0)
            a, b = points[i], points[i + 1]
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
        d -= ln


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
    ap.add_argument("--script", choices=["demo", "idle", "uncal"], default="demo")
    ap.add_argument("--duration", type=float, default=0)
    args = ap.parse_args()
    script = {"demo": DEMO, "idle": IDLE, "uncal": UNCAL}[args.script]
    calibrated = args.script != "uncal"

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
        for dur, gesture, path in script:
            if pos < dur:
                break
            pos -= dur
        hand = gesture != "none"
        x, y = sample_path(path, pos / dur)
        seq += 1
        st = {"seq": seq, "t_ms": now * 1000, "hand": hand, "gesture": gesture,
              "zone": zone_of(x, y) if hand else "center",
              "cx": round(x, 4), "cy": round(y, 4), "px": round(x, 4), "py": round(y, 4),
              "open_ratio": OPEN_RATIO[gesture], "radius": 0.12 if hand else 0.0,
              "fps": 30.0, "proc_ms": 5.0,
              "calibrated": calibrated, "calibrating": False}
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
