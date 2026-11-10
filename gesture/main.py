"""手势识别主程序。用法见 argparse 帮助；协议见 docs/ai/gesture-protocol.md。"""
import argparse
import json
import os
import sys
import time

import cv2

import debug_view
import features
from capture import CameraSource, ImageSource, VideoSource
from net import Net
from segment import Segmenter
from tracker import GestureDebouncer, ZoneTracker

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_args():
    p = argparse.ArgumentParser(description="传统图像处理手势识别（OpenCV）")
    p.add_argument("--config", default=os.path.join(HERE, "config.json"))
    p.add_argument("--video", help="用视频文件代替摄像头")
    p.add_argument("--image", help="用单张图片代替摄像头")
    p.add_argument("--no-mirror", action="store_true", help="图片/视频源不做水平镜像")
    p.add_argument("--window", dest="window", action="store_true", default=None)
    p.add_argument("--no-window", dest="window", action="store_false")
    p.add_argument("--managed", action="store_true", help="由 Godot 拉起：默认无窗口，5 秒收不到 ping 就退出")
    p.add_argument("--frames", type=int, default=0, help="处理 N 帧后退出（自测用）")
    return p.parse_args()


def open_source(args, cfg):
    cam = cfg["camera"]
    if args.image:
        return ImageSource(args.image, mirror=not args.no_mirror,
                           size=(cam["width"], cam["height"]), fps=cam["image_fps"])
    if args.video:
        return VideoSource(args.video, mirror=not args.no_mirror)
    return CameraSource(cam["index"], cam["width"], cam["height"], cam["mirror"])


STATE_PATH = os.path.join(HERE, "state.json")


def load_roi_index(cfg):
    """读取上次选的操作框预设（存在 state.json 里），没有就用配置里的默认值。"""
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            idx = int(json.load(f)["roi_index"])
    except (OSError, ValueError, KeyError, TypeError):
        idx = int(cfg.get("roi_index", 0))
    return idx % len(cfg["roi_presets"])


def save_roi_index(idx):
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump({"roi_index": idx}, f)
    except OSError:
        pass


def crop_roi(frame, roi):
    """按配置裁出操作框（超出画面时截断），返回 (子图, 实际矩形)。"""
    fh, fw = frame.shape[:2]
    x, y = max(0, roi["x"]), max(0, roi["y"])
    x2, y2 = min(fw, roi["x"] + roi["w"]), min(fh, roi["y"] + roi["h"])
    return frame[y:y2, x:x2], (x, y, x2 - x, y2 - y)


def encode_stage(stage, roi, seg, feats, cfg):
    """按阶段号生成缩略图并编码为 JPEG；失败返回 None。"""
    if stage == 1:
        img = seg.backproj
    elif stage == 2:
        img = seg.thresh
    elif stage == 3:
        img = seg.morph
    else:
        img = debug_view.draw_overlay(roi, feats, cfg)
    n = cfg["net"]
    scale = n["frame_max_side"] / max(img.shape[:2])
    if scale < 1:
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, n["jpeg_quality"]])
    return buf.tobytes() if ok else None


def run():
    args = parse_args()
    cfg = load_config(args.config)
    show_window = args.window if args.window is not None else (not args.managed)

    source = open_source(args, cfg)
    if not source.opened:
        what = args.image or args.video or "摄像头（索引 %d）" % cfg["camera"]["index"]
        print("错误：无法打开 %s。请检查设备是否被其他程序占用、是否有摄像头权限，或改用 --video / --image。" % what,
              file=sys.stderr)
        return 2

    try:
        net = Net(cfg)
    except OSError as e:
        source.release()
        print("错误：无法绑定命令端口（%s）。可能已有一个识别进程在运行，请先关掉它。" % e, file=sys.stderr)
        return 3
    segmenter = Segmenter(cfg)
    debouncer, zones = GestureDebouncer(cfg), ZoneTracker(cfg)
    view = debug_view.DebugView(os.path.join(HERE, "screenshots")) if show_window else None
    stage, seq = 0, 0
    roi_idx = load_roi_index(cfg)
    cycle_roi = False
    last_ping = time.monotonic()
    fps, last_t, n_done, proc_sum = 0.0, None, 0, 0.0
    start = time.monotonic()
    exit_code = 0

    try:
        while True:
            got = source.read(timeout=1.0)
            if got is None:
                if args.managed and time.monotonic() - last_ping > cfg["net"]["managed_timeout_s"]:
                    break
                if not isinstance(source, CameraSource):
                    break
                continue
            frame, t_ms = got
            t0 = time.perf_counter()
            if cycle_roi:  # 换操作框位置：脸或杂物在框里时用
                cycle_roi = False
                roi_idx = (roi_idx + 1) % len(cfg["roi_presets"])
                save_roi_index(roi_idx)
                debouncer, zones = GestureDebouncer(cfg), ZoneTracker(cfg)
            roi, rect = crop_roi(frame, cfg["roi_presets"][roi_idx])
            seg = segmenter.process(roi)
            feats = features.extract(seg.mask, cfg)
            # 未标定时固定范围容易把脸和背景当成手，所以默认要求先标定才输出手势
            active = segmenter.calibrated or not cfg["calibration"]["required"]
            gesture = debouncer.update(feats.gesture if active else "none")
            w, h = rect[2], rect[3]
            if feats.centroid and active:
                cx, cy = feats.centroid
                zone = zones.update(True, (cx - w / 2) / w, (cy - h / 2) / w)
                ncx, ncy = cx / w, cy / h
            else:
                zone = zones.update(False)
                ncx = ncy = 0.5
            proc_ms = (time.perf_counter() - t0) * 1000.0

            now = time.monotonic()
            if last_t is not None:
                inst = 1.0 / max(now - last_t, 1e-6)
                fps = inst if fps == 0 else fps * 0.9 + inst * 0.1
            last_t = now
            n_done += 1
            proc_sum += proc_ms
            seq += 1

            state = {"seq": seq, "t_ms": round(t_ms, 1), "hand": bool(feats.centroid) and active,
                     "gesture": gesture, "zone": zone, "cx": round(ncx, 3), "cy": round(ncy, 3),
                     "defects": feats.defects, "solidity": round(feats.solidity, 3),
                     "fps": round(fps, 1), "proc_ms": round(proc_ms, 2),
                     "calibrated": segmenter.calibrated}
            net.send_state(state)
            jpg = encode_stage(stage, roi, seg, feats, cfg)
            if jpg:
                net.send_frame(stage, jpg)

            for cmd in net.poll_commands():
                name = cmd.get("cmd")
                if name == "ping":
                    last_ping = now
                elif name == "calibrate":
                    segmenter.calibrate(roi)
                elif name == "stage" and cmd.get("value") in (0, 1, 2, 3):
                    stage = int(cmd["value"])
                elif name == "roi":
                    cycle_roi = True
                elif name == "quit":
                    return 0

            if view:
                info = {"gesture": gesture, "raw": feats.gesture, "zone": zone,
                        "defects": feats.defects, "solidity": feats.solidity,
                        "fps": fps, "proc_ms": proc_ms, "calibrated": segmenter.calibrated}
                board = debug_view.compose(frame, rect, roi, seg, feats, info, cfg)
                key = view.show(board)
                if key == "q":
                    break
                if key == "c":
                    segmenter.calibrate(roi)
                elif key == "r":
                    cycle_roi = True
                elif key == "s":
                    print("截图已保存：" + view.save(board))

            if args.frames and n_done >= args.frames:
                break
            if args.managed and now - last_ping > cfg["net"]["managed_timeout_s"]:
                print("超过 %.0f 秒未收到 ping，退出。" % cfg["net"]["managed_timeout_s"])
                break
    except KeyboardInterrupt:
        pass
    finally:
        source.release()
        net.close()
        if view:
            view.close()

    elapsed = max(time.monotonic() - start, 1e-6)
    if n_done:
        print("处理 %d 帧，平均 fps %.1f，平均处理耗时 %.2f ms" % (n_done, n_done / elapsed, proc_sum / n_done))
    return exit_code


if __name__ == "__main__":
    sys.exit(run())
