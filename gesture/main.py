"""手势识别主程序。用法见 argparse 帮助；UDP 收发见 net.py。"""
import argparse
import json
import os
import tempfile
import sys
import time

import cv2

import debug_view
import features
from capture import CameraSource, ImageSource, VideoSource
from net import Net
from recorder import Recorder, load_sidecar
from segment import Segmenter
from tracker import GestureDebouncer, PointSmoother, ZoneTracker

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_args():
    p = argparse.ArgumentParser(description="传统图像处理手势识别（OpenCV）")
    p.add_argument("--config", default=os.path.join(HERE, "config.json"))
    p.add_argument("--data-dir", help="绝对用户数据目录（保存 state.json、录像和截图）")
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
        # 自己录的视频已经镜像过（旁边有 .json），不再翻转
        meta, _ = load_sidecar(args.video)
        mirrored = bool(meta and meta.get("mirrored"))
        return VideoSource(args.video, mirror=not (args.no_mirror or mirrored))
    return CameraSource(cam["index"], cam["width"], cam["height"], cam["mirror"])


STATE_PATH = os.path.join(HERE, "state.json")


def resolve_user_paths(data_dir=None, script_dir=HERE):
    if data_dir:
        if not os.path.isabs(data_dir):
            raise ValueError("--data-dir must be an absolute path")
        root = os.path.abspath(data_dir)
    else:
        root = os.path.abspath(script_dir)
    return {"root": root, "state": os.path.join(root, "state.json"),
            "recordings": os.path.join(root, "recordings"),
            "screenshots": os.path.join(root, "screenshots")}


def valid_roi_index(path, preset_count):
    try:
        with open(path, "r", encoding="utf-8") as f:
            value = json.load(f).get("roi_index")
        return value if type(value) is int and 0 <= value < preset_count else None
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def load_roi_index(cfg, state_path=STATE_PATH):
    """读取上次选的操作框预设（存在 state.json 里），没有就用配置里的默认值。"""
    try:
        idx = valid_roi_index(state_path, len(cfg["roi_presets"]))
        if idx is None:
            raise ValueError("invalid state")
    except (OSError, ValueError, KeyError, TypeError):
        idx = int(cfg.get("roi_index", 0))
    return idx % len(cfg["roi_presets"])


def save_roi_index(idx, state_path=STATE_PATH):
    temporary = None
    try:
        folder = os.path.dirname(os.path.abspath(state_path))
        os.makedirs(folder, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=folder)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"roi_index": idx}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, state_path)
    except OSError:
        pass
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def crop_roi(frame, roi):
    """按配置裁出操作框（超出画面时截断），返回 (子图, 实际矩形)。"""
    fh, fw = frame.shape[:2]
    x, y = max(0, roi["x"]), max(0, roi["y"])
    x2, y2 = min(fw, roi["x"] + roi["w"]), min(fh, roi["y"] + roi["h"])
    return frame[y:y2, x:x2], (x, y, x2 - x, y2 - y)


def encode_stage(stage, frame, rect, seg, feats, cfg):
    """按阶段号生成缩略图并编码为 JPEG；失败返回 None。

    阶段 0 发整幅镜像画面（叠加操作框等）；阶段 1-3 只发操作框区域。
    """
    if stage == 1:
        img = seg.diff
    elif stage == 2:
        img = seg.thresh
    elif stage == 3:
        img = seg.morph
    else:
        img = debug_view.draw_full_overlay(frame, rect, feats, cfg)
    n = cfg["net"]
    scale = n["frame_max_side"] / max(img.shape[:2])
    if scale < 1:
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, n["jpeg_quality"]])
    return buf.tobytes() if ok else None


def run():
    args = parse_args()
    cfg = load_config(args.config)
    paths = resolve_user_paths(args.data_dir)
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
    debouncer, zones, smoother = GestureDebouncer(cfg), ZoneTracker(cfg), PointSmoother(cfg)
    view = debug_view.DebugView(paths["screenshots"]) if show_window else None
    stage, seq = 0, 0
    roi_idx = load_roi_index(cfg, paths["state"])
    if args.video:  # 回放自己录的视频：沿用录制时的操作框和背景模型
        meta, bg = load_sidecar(args.video)
        if meta:
            roi_idx = int(meta.get("roi_index", roi_idx)) % len(cfg["roi_presets"])
            if bg is not None and bg.ndim == 3:
                segmenter.set_background(bg)
    recorder = Recorder(paths["recordings"], cfg.get("record_max_seconds", 30.0))
    toggle_rec = False
    auto_cal_at = int(cfg["calibration"].get("auto_start_frame", 0))
    was_calibrated = segmenter.calibrated
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
            if toggle_rec:
                toggle_rec = False
                if recorder.active:
                    print("录像已保存：%s" % recorder.stop())
                else:
                    path = recorder.start(frame, roi_idx, segmenter.bg)
                    print("开始录像：%s" % path if path else "错误：无法创建录像文件。")
            if recorder.active and recorder.write(frame):  # 写的是未叠加任何标记的原始画面
                print("录像到达时长上限，已自动保存。")
            t0 = time.perf_counter()
            if cycle_roi:  # 换操作框位置：脸或杂物在框里时用
                cycle_roi = False
                roi_idx = (roi_idx + 1) % len(cfg["roi_presets"])
                save_roi_index(roi_idx, paths["state"])
                debouncer, zones = GestureDebouncer(cfg), ZoneTracker(cfg)
                smoother.reset()
                segmenter.calibrate()  # 换了位置，背景要重新采集
            roi, rect = crop_roi(frame, cfg["roi_presets"][roi_idx])
            # 开机后自动采一次背景（此时手通常不在框里）；不对就按 F3 / c 重采
            if auto_cal_at and n_done == auto_cal_at and not segmenter.calibrated and not segmenter.calibrating:
                segmenter.calibrate()
            seg = segmenter.process(roi)
            if segmenter.calibrated and not was_calibrated:
                recorder.update_meta(roi_idx, segmenter.bg)
            was_calibrated = segmenter.calibrated
            feats = features.extract(seg.mask, cfg)
            gesture = debouncer.update(feats.gesture, feats.edge)
            w, h = rect[2], rect[3]
            if feats.palm:
                cx, cy = feats.palm
                zone = zones.update(True, (cx - w / 2) / w, (cy - h / 2) / w)
                ncx, ncy = cx / w, cy / h
                px, py = smoother.update(ncx, ncy)
            else:
                zone = zones.update(False)
                smoother.reset()
                ncx = ncy = px = py = 0.5
            proc_ms = (time.perf_counter() - t0) * 1000.0

            now = time.monotonic()
            if last_t is not None:
                inst = 1.0 / max(now - last_t, 1e-6)
                fps = inst if fps == 0 else fps * 0.9 + inst * 0.1
            last_t = now
            n_done += 1
            proc_sum += proc_ms
            seq += 1

            state = {"seq": seq, "t_ms": round(t_ms, 1), "hand": feats.palm is not None,
                     "gesture": gesture, "zone": zone, "cx": round(ncx, 3), "cy": round(ncy, 3),
                     "px": round(px, 3), "py": round(py, 3),
                     "open_ratio": round(feats.open_ratio, 2), "edge": bool(feats.edge), "radius": round(feats.radius / w, 3),
                     "fps": round(fps, 1), "proc_ms": round(proc_ms, 2),
                     "calibrated": segmenter.calibrated, "calibrating": segmenter.calibrating,
                     # 手影用：操作框在整幅画面里的像素矩形、画面尺寸、手轮廓多边形（操作框内归一化）
                     "roi": [int(v) for v in rect], "frame": [int(frame.shape[1]), int(frame.shape[0])],
                     "contour": features.simplify_contour(feats.contour, w, h) if feats.palm else []}
            net.send_state(state)
            jpg = encode_stage(stage, frame, rect, seg, feats, cfg)
            if jpg:
                net.send_frame(stage, jpg)

            for cmd in net.poll_commands():
                name = cmd.get("cmd")
                if name == "ping":
                    last_ping = now
                elif name == "calibrate":
                    segmenter.calibrate()
                elif name == "record":
                    toggle_rec = True
                elif name == "stage" and cmd.get("value") in (0, 1, 2, 3):
                    stage = int(cmd["value"])
                elif name == "roi":
                    cycle_roi = True
                elif name == "quit":
                    return exit_code  # Leave the frame loop and flush resources in finally.

            if view:
                info = {"gesture": gesture, "raw": feats.gesture, "zone": zone,
                        "open_ratio": feats.open_ratio, "solidity": feats.solidity, "radius": feats.radius,
                        "fps": fps, "proc_ms": proc_ms, "calibrated": segmenter.calibrated,
                        "calibrating": segmenter.calibrating,
                        "rec_s": recorder.elapsed if recorder.active else None}
                board = debug_view.compose(frame, rect, roi, seg, feats, info, cfg)
                key = view.show(board)
                if key == "q":
                    break
                if key == "c":
                    segmenter.calibrate()
                elif key == "v":
                    toggle_rec = True
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
        if recorder.active:
            print("录像已保存：%s" % recorder.stop())
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
