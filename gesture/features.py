"""步骤 7-8：轮廓、掌心（距离变换）、小臂方向、张开度，以及张开 / 握拳的原始判定。

张开度 = 掌心到最远轮廓点的距离 ÷ 掌心内切圆半径。
- 掌心和半径来自距离变换：手掩膜内离边界最远的点及其距离。
- 找最远点时要排除小臂：小臂是"粗"的（距离变换值大），手指是"细"的，
  所以把粗的部分去掉掌心圆盘，剩下的又长又不朝上的那块就是小臂，朝它那一侧的轮廓点不参与。
比值不随手离镜头的远近变化。
"""
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class HandFeatures:
    gesture: str = "none"          # none / palm / fist / between（落在两个阈值之间）
    contour: np.ndarray = None
    hull: np.ndarray = None        # 凸包点 (N,1,2)，只用于画面叠加
    palm: tuple = None             # 掌心 (x, y)，操作框内的像素坐标
    radius: float = 0.0            # 掌心内切圆半径（像素）
    far: tuple = None              # 参与计算的最远轮廓点
    arm_dir: tuple = None          # 小臂方向的单位向量；没找到小臂时为 None
    open_ratio: float = 0.0
    bbox: tuple = None
    edge: bool = False             # 掩膜贴到操作框左 / 右 / 上边界（形状被裁掉，不可信）


def largest_contour(mask):
    """对掩膜取最大外轮廓。"""
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return max(cnts, key=cv2.contourArea) if cnts else None


def palm_center(filled):
    """距离变换求掌心和内切圆半径。画面边界按"手的边界"算，手被画面切掉时圆不会贴到边上。"""
    padded = cv2.copyMakeBorder(filled, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    dt = cv2.distanceTransform(padded, cv2.DIST_L2, 5)[1:-1, 1:-1]
    _, radius, _, center = cv2.minMaxLoc(dt)
    return dt, center, float(radius)


def arm_direction(dt, center, radius, fcfg):
    """找小臂方向（单位向量），找不到返回 None。"""
    px, py = center
    thick = (dt > fcfg["arm_thick_ratio"] * radius).astype(np.uint8)
    cv2.circle(thick, (int(px), int(py)), int(fcfg["arm_palm_disc"] * radius), 0, -1)
    n, labels, stats, cents = cv2.connectedComponentsWithStats(thick, connectivity=8)
    best, best_area = None, fcfg["arm_min_area"] * radius * radius
    for i in range(1, n):
        area = stats[i, cv2.CC_STAT_AREA]
        if area <= best_area:
            continue
        ys, xs = np.nonzero(labels == i)
        if np.hypot(xs - px, ys - py).max() < fcfg["arm_min_reach"] * radius:
            continue  # 太短：是掌根之类的残余，不是小臂
        v = cents[i] - (px, py)
        norm = float(np.hypot(v[0], v[1]))
        if norm < 1e-6 or v[1] / norm < fcfg["arm_min_down"]:
            continue  # 小臂不会从上方伸进来；朝上的粗块是并拢的手指
        best, best_area = (v[0] / norm, v[1] / norm), area
    return best


def classify(open_ratio, fcfg):
    """原始判定：低于下阈值为拳，高于上阈值为掌，中间交给时序滞回。"""
    if open_ratio < fcfg["fist_max_ratio"]:
        return "fist"
    if open_ratio > fcfg["palm_min_ratio"]:
        return "palm"
    return "between"


def touches_edge(mask, fcfg, center=None, radius=0.0, arm=None):
    """手本身（不是小臂）是否被操作框的左 / 右 / 上边界裁掉。

    只数边界上"离掌心不超过 edge_reach 倍半径、且不在小臂那一侧"的掩膜像素：
    小臂常常从右下角伸出画面，它贴着边界不代表手形被裁。下边界不算。
    不给掌心时退化成数全部边界像素。
    """
    n = fcfg.get("edge_touch_pixels", 8)
    h, w = mask.shape[:2]
    ys_l = np.nonzero(mask[:, 0])[0]
    ys_r = np.nonzero(mask[:, -1])[0]
    xs_t = np.nonzero(mask[0, :])[0]
    xs = np.concatenate([np.zeros(len(ys_l)), np.full(len(ys_r), w - 1.0), xs_t]).astype(np.float32)
    ys = np.concatenate([ys_l, ys_r, np.zeros(len(xs_t))]).astype(np.float32)
    if len(xs) == 0:
        return False
    if center is None or radius <= 0:
        return len(xs) >= n
    vx, vy = xs - center[0], ys - center[1]
    dist = np.hypot(vx, vy)
    ok = dist <= fcfg.get("edge_reach", 3.5) * radius
    if arm is not None:
        cos = (vx * arm[0] + vy * arm[1]) / np.maximum(dist, 1e-6)
        ok &= cos < fcfg["arm_exclude_cos"]
    return int(np.count_nonzero(ok)) >= n


def extract(mask, cfg):
    """从掩膜提取全部特征并给出原始手势。"""
    fcfg = cfg["features"]
    contour = largest_contour(mask) if mask.any() else None
    if contour is None or len(contour) < 5:
        return HandFeatures()
    filled = np.zeros_like(mask)
    cv2.drawContours(filled, [contour], -1, 255, -1)
    dt, center, radius = palm_center(filled)
    if radius < 1.0:
        return HandFeatures()
    pts = contour.reshape(-1, 2).astype(np.float32)
    v = pts - np.float32(center)
    dist = np.hypot(v[:, 0], v[:, 1])
    arm = arm_direction(dt, center, radius, fcfg)
    ok = np.ones(len(pts), bool)
    if arm is not None:
        cos = (v[:, 0] * arm[0] + v[:, 1] * arm[1]) / np.maximum(dist, 1e-6)
        ok = cos < fcfg["arm_exclude_cos"]
        if not ok.any():
            ok[:] = True
    idx = np.nonzero(ok)[0]
    j = int(idx[np.argmax(dist[idx])])
    ratio = float(dist[j]) / radius
    return HandFeatures(classify(ratio, fcfg), contour, cv2.convexHull(contour),
                        (float(center[0]), float(center[1])), radius,
                        (int(pts[j][0]), int(pts[j][1])), arm, ratio, cv2.boundingRect(contour),
                        touches_edge(mask, fcfg, center, radius, arm))
