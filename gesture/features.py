"""步骤 7-8：轮廓、掌心（距离变换）、小臂方向、张开度，以及张开 / 握拳的原始判定。

张开度 = 掌心到最远轮廓点的距离 ÷ 掌心内切圆半径。
实心度 = 沿小臂方向投影不超过 hand_cut 倍半径的那部分填充区域，面积 ÷ 凸包面积：
拳头是实心团块（接近 1），张开的手有指缝（明显更低）；侧握的拳张开度会偏高，靠实心度补充判断。
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
    solidity: float = 0.0          # 实心度：手掌部分（去掉小臂）面积 ÷ 其凸包面积
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


def hand_end_point(filled):
    """手那一端的端点：掩膜沿主轴方向最靠"上"的点（小臂从下方或侧面伸进来，手在另一头）。

    主轴用二阶矩求。主轴接近水平时"上"没有意义，改为远离掩膜贴着的那条左 / 右边界。
    """
    m = cv2.moments(filled, binaryImage=True)
    if m["m00"] <= 0:
        return None
    theta = 0.5 * np.arctan2(2.0 * m["mu11"], m["mu20"] - m["mu02"])
    ux, uy = float(np.cos(theta)), float(np.sin(theta))
    if abs(uy) >= 0.35:
        if uy > 0:
            ux, uy = -ux, -uy
    else:
        left = int(np.count_nonzero(filled[:, 0]))
        right = int(np.count_nonzero(filled[:, -1]))
        if left == right:
            return None
        if (ux > 0) == (right > left):
            ux, uy = -ux, -uy
    ys, xs = np.nonzero(filled)
    k = int(np.argmax(xs * ux + ys * uy))
    return float(xs[k]), float(ys[k])


def locate_palm(filled, fcfg):
    """掌心和内切圆半径。

    整块掩膜里最粗的地方通常是手掌，但露着小臂、小臂又靠近袖口或镜头时，小臂会比手掌粗，
    内切圆就落到小臂上。所以只在"离手那一端不超过 hand_span 倍半径"的范围里找最粗处。
    """
    dt, center, radius = palm_center(filled)
    span = fcfg.get("hand_span", 0.0)
    if radius < 1.0 or span <= 0:
        return dt, center, radius
    end = hand_end_point(filled)
    if end is None:
        return dt, center, radius
    h, w = filled.shape[:2]
    yy, xx = np.ogrid[:h, :w]
    d2 = (xx - end[0]) ** 2 + (yy - end[1]) ** 2
    limit = span * radius
    if (center[0] - end[0]) ** 2 + (center[1] - end[1]) ** 2 <= limit * limit:
        return dt, center, radius
    floor = fcfg.get("hand_min_shrink", 0.5) * radius
    for _ in range(4):
        near = np.where(d2 <= limit * limit, dt, 0.0).astype(np.float32)
        _, r1, _, c1 = cv2.minMaxLoc(near)
        if r1 < floor:
            break  # 手那一端太细（手被裁掉或只是噪声），保持原来的结果
        if np.hypot(c1[0] - end[0], c1[1] - end[1]) < limit - 2.0:
            return dt, c1, float(r1)  # 范围内部的极大值：就是手掌
        limit *= 0.8  # 最粗处贴在范围边上，说明还在越来越粗的小臂上，收紧范围再找
    return dt, center, radius


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


def compute_solidity(filled, center, radius, arm, fcfg):
    """实心度：以掌心为原点，取沿小臂方向投影 <= hand_cut * r 的填充像素，面积 ÷ 凸包面积。

    小臂方向没找到时按正下方 (0, 1)，和排除小臂的约定一致。像素少于 20 个或凸包面积为 0 返回 0。
    """
    ex = arm if arm is not None else (0.0, 1.0)
    ys, xs = np.nonzero(filled)
    proj = (xs - center[0]) * ex[0] + (ys - center[1]) * ex[1]
    keep = proj <= fcfg.get("hand_cut", 1.0) * radius
    n = int(np.count_nonzero(keep))
    if n < 20:
        return 0.0
    pts = np.stack([xs[keep], ys[keep]], axis=1).astype(np.int32).reshape(-1, 1, 2)
    area = cv2.contourArea(cv2.convexHull(pts))
    return float(n / area) if area > 0 else 0.0


def classify(open_ratio, solidity, edge, fcfg):
    """原始判定：又紧又实心为拳，指缝多或张开度大为掌，其余交给时序滞回。

    张开度在严格上限以下，要实心度达到 fist_min_solidity；在严格上限和宽上限之间
    （侧握的拳），要求更高的实心度。手被操作框边界裁住（edge）时形状不可信，只用严格上限。
    """
    strict = fcfg["fist_max_ratio"]
    upper = strict if edge else fcfg.get("fist_max_ratio_wide", strict)
    need = fcfg.get("fist_min_solidity", 0.88) if open_ratio < strict else fcfg.get("fist_min_solidity_wide", 0.90)
    if open_ratio < upper and solidity >= need:
        return "fist"
    if solidity < fcfg.get("palm_max_solidity", 0.88) or open_ratio > fcfg["palm_min_ratio"]:
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


def simplify_contour(contour, roi_w, roi_h, eps_ratio=0.012, max_points=48):
    """把手轮廓简化成多边形，坐标归一化到操作框（0-1，保留 3 位小数）。

    approxPolyDP 的 epsilon 初值 = 操作框宽度 * eps_ratio；点数超过 max_points 就把 epsilon
    放大 1.3 倍重算，直到不超过为止（状态包是 UDP，不能太大）。没有轮廓返回空列表。
    """
    if contour is None or len(contour) < 3 or roi_w <= 0 or roi_h <= 0:
        return []
    eps = max(roi_w * eps_ratio, 0.5)
    poly = cv2.approxPolyDP(contour, eps, True)
    for _ in range(40):
        if len(poly) <= max_points:
            break
        eps *= 1.3
        poly = cv2.approxPolyDP(contour, eps, True)
    pts = poly.reshape(-1, 2).astype(np.float64)
    return [[round(float(x) / roi_w, 3), round(float(y) / roi_h, 3)] for x, y in pts[:max_points]]


def extract(mask, cfg):
    """从掩膜提取全部特征并给出原始手势。"""
    fcfg = cfg["features"]
    contour = largest_contour(mask) if mask.any() else None
    if contour is None or len(contour) < 5:
        return HandFeatures()
    filled = np.zeros_like(mask)
    cv2.drawContours(filled, [contour], -1, 255, -1)
    dt, center, radius = locate_palm(filled, fcfg)
    if radius < 1.0:
        return HandFeatures()
    pts = contour.reshape(-1, 2).astype(np.float32)
    v = pts - np.float32(center)
    dist = np.hypot(v[:, 0], v[:, 1])
    arm = arm_direction(dt, center, radius, fcfg)
    # 没找到小臂时（小臂只露出一小截，或手腕贴着画面下沿）按"小臂在正下方"处理：
    # 否则握拳时那一小截手腕会被当成伸出的手指，张开度偏高
    ex = arm if arm is not None else (0.0, 1.0)
    cos = (v[:, 0] * ex[0] + v[:, 1] * ex[1]) / np.maximum(dist, 1e-6)
    ok = cos < fcfg["arm_exclude_cos"]
    if not ok.any():
        ok[:] = True
    idx = np.nonzero(ok)[0]
    j = int(idx[np.argmax(dist[idx])])
    ratio = float(dist[j]) / radius
    edge = touches_edge(mask, fcfg, center, radius, arm)
    solidity = compute_solidity(filled, center, radius, arm, fcfg)
    gesture = classify(ratio, solidity, edge, fcfg)
    # 最远点落在操作框的上边界上：手指伸出了画面，量到的张开度只是下限。
    # 这时"握拳"的结论不可信（光标移到房间顶部时指尖就会出框），改成 between 保持原状态
    if gesture == "fist" and pts[j][1] <= fcfg.get("clip_margin", 3):
        gesture = "between"
    return HandFeatures(gesture, contour, cv2.convexHull(contour),
                        (float(center[0]), float(center[1])), radius,
                        (int(pts[j][0]), int(pts[j][1])), arm, ratio, solidity, cv2.boundingRect(contour),
                        edge)
