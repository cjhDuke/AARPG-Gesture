"""在一段录像上逐帧跑完整识别管线，统计张开度分布和张开 / 握拳的判定正确率。

用法：
    python eval_recording.py recordings/xxx.avi --open 5-175 --fist 200-370,660-900
    python eval_recording.py recordings/xxx.avi --bg-frames 575-590 --save-bg   # 录像没带背景时，从无手的帧生成

--open / --fist 是人工标注的帧区间（含两端）。不给标注时只打印每半秒的张开度。
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np

import features
from recorder import load_sidecar
from segment import Segmenter
from tracker import GestureDebouncer

HERE = os.path.dirname(os.path.abspath(__file__))


def parse_ranges(text):
    out = []
    for part in (text or "").split(","):
        if part.strip():
            a, b = part.split("-")
            out.append((int(a), int(b)))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("video")
    p.add_argument("--config", default=os.path.join(HERE, "config.json"))
    p.add_argument("--roi", type=int, help="操作框预设下标，默认用录像元数据里的")
    p.add_argument("--open", dest="open_", default="")
    p.add_argument("--fist", default="")
    p.add_argument("--bg-frames", help="用这段帧（例如 575-590）的中值作背景")
    p.add_argument("--save-bg", action="store_true", help="把背景和操作框下标写回录像旁边的 .npy / .json")
    args = p.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)
    meta, bg = load_sidecar(args.video)
    meta = meta or {}
    roi_idx = args.roi if args.roi is not None else int(meta.get("roi_index", 0))
    roi = cfg["roi_presets"][roi_idx % len(cfg["roi_presets"])]

    cap = cv2.VideoCapture(args.video)
    frames = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if not meta.get("mirrored"):
            frame = cv2.flip(frame, 1)
        frames.append(frame[roi["y"]:roi["y"] + roi["h"], roi["x"]:roi["x"] + roi["w"]])
    cap.release()
    if not frames:
        print("错误：读不到任何帧。", file=sys.stderr)
        return 2

    seg = Segmenter(cfg)
    if args.bg_frames:
        a, b = parse_ranges(args.bg_frames)[0]
        bg = np.median(np.stack([seg._preprocess(f) for f in frames[a:b + 1]]), axis=0).astype(np.float32)
        if args.save_bg:
            base = os.path.splitext(args.video)[0]
            np.save(base + ".npy", bg)
            meta.update({"roi_index": roi_idx, "calibrated": True})
            with open(base + ".json", "w", encoding="utf-8") as f:
                json.dump(meta, f)
    if bg is None or bg.shape != frames[0].shape:
        print("错误：录像没有可用的背景模型（或尺寸与操作框不符），请用 --bg-frames 指定无手的帧。", file=sys.stderr)
        return 2
    seg.set_background(bg)

    deb = GestureDebouncer(cfg)
    ratios, raw, stable, palms, edges = [], [], [], [], []
    for f in frames:
        ft = features.extract(seg.process(f).mask, cfg)
        ratios.append(ft.open_ratio if ft.palm else np.nan)
        raw.append(ft.gesture)
        stable.append(deb.update(ft.gesture, ft.edge))
        edges.append(ft.edge)
        palms.append(ft.palm or (np.nan, np.nan))
    ratios, raw, stable = np.array(ratios), np.array(raw), np.array(stable)

    for s in range(0, len(frames), 15):
        x = ratios[s:s + 15]
        x = x[~np.isnan(x)]
        tag = "无手" if not len(x) else "张开度 中位 %.2f 范围 %.2f-%.2f" % (np.median(x), x.min(), x.max())
        print("帧 %3d-%3d  %s  稳定输出 %s" % (s, min(s + 14, len(frames) - 1), tag, stable[min(s + 7, len(frames) - 1)]))

    def pick(ranges):
        idx = [i for a, b in ranges for i in range(a, min(b, len(frames) - 1) + 1)]
        return np.array(idx, int)

    for name, label, ranges in (("张开", "palm", parse_ranges(args.open_)), ("握拳", "fist", parse_ranges(args.fist))):
        idx = pick(ranges)
        if not len(idx):
            continue
        x = ratios[idx]
        x = x[~np.isnan(x)]
        print("%s %d 帧：张开度 1%%/50%%/99%% 分位 = %.2f / %.2f / %.2f；逐帧原始判定正确 %.1f%%，防抖后正确 %.1f%%"
              % (name, len(idx), *np.percentile(x, [1, 50, 99]),
                 100.0 * np.mean(raw[idx] == label), 100.0 * np.mean(stable[idx] == label)))
    print("贴边帧数：%d / %d" % (sum(edges), len(edges)))
    changes = [i for i in range(1, len(stable)) if stable[i] != stable[i - 1]]
    print("稳定输出切换的帧号：", [(i, str(stable[i])) for i in changes])
    return 0


if __name__ == "__main__":
    sys.exit(main())
