"""步骤 7-8：轮廓、质心、凸包、凸缺陷、solidity，以及规则分类。"""
import math
from dataclasses import dataclass, field

import cv2
import numpy as np


@dataclass
class HandFeatures:
    gesture: str = "none"          # none / palm / fist / two / other
    contour: np.ndarray = None
    hull: np.ndarray = None        # 凸包点 (N,1,2)
    finger_gaps: list = field(default_factory=list)  # [(起点, 最远点, 终点)]
    defects: int = 0
    solidity: float = 0.0
    centroid: tuple = None         # (cx, cy) 像素坐标（操作框内）
    bbox: tuple = None


def largest_contour(mask):
    """对掩膜取最大外轮廓。"""
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return max(cnts, key=cv2.contourArea) if cnts else None


def centroid_of(contour):
    """图像矩求质心。"""
    m = cv2.moments(contour)
    if m["m00"] == 0:
        x, y, w, h = cv2.boundingRect(contour)
        return (x + w / 2.0, y + h / 2.0)
    return (m["m10"] / m["m00"], m["m01"] / m["m00"])


def _angle_deg(start, far, end):
    """起点-最远点-终点在最远点处的夹角（度）。"""
    v1 = (start[0] - far[0], start[1] - far[1])
    v2 = (end[0] - far[0], end[1] - far[1])
    n = math.hypot(*v1) * math.hypot(*v2)
    if n == 0:
        return 180.0
    c = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / n))
    return math.degrees(math.acos(c))


def finger_gaps(contour, size, fcfg):
    """凸缺陷筛选：深度 > 阈值（相对手外接框尺寸）且夹角 < 上限的认为是指缝。"""
    hull_idx = cv2.convexHull(contour, returnPoints=False)
    if hull_idx is None or len(hull_idx) < 3:
        return []
    try:
        defects = cv2.convexityDefects(contour, hull_idx)
    except cv2.error:
        return []
    if defects is None:
        return []
    min_depth = fcfg["defect_depth_ratio"] * size
    gaps = []
    for s, e, f, d in defects.reshape(-1, 4):
        if d / 256.0 <= min_depth:
            continue
        start, end, far = (tuple(int(v) for v in contour[i][0]) for i in (s, e, f))
        if _angle_deg(start, far, end) < fcfg["defect_max_angle"]:
            gaps.append((start, far, end))
    return gaps


def solidity_of(contour, hull):
    """轮廓面积 / 凸包面积。"""
    hull_area = cv2.contourArea(hull)
    return cv2.contourArea(contour) / hull_area if hull_area > 0 else 0.0


def classify(n_gaps, solidity, fcfg):
    """基于规则的手势分类。"""
    if n_gaps >= fcfg["palm_min_defects"]:
        return "palm"
    if n_gaps == 1:
        return "two"
    if n_gaps == 0 and solidity >= fcfg["fist_solidity"]:
        return "fist"
    return "other"


def extract(mask, cfg):
    """从掩膜提取全部特征并给出原始手势。"""
    fcfg = cfg["features"]
    contour = largest_contour(mask) if mask.any() else None
    if contour is None or len(contour) < 5:
        return HandFeatures()
    x, y, w, h = cv2.boundingRect(contour)
    hull = cv2.convexHull(contour)
    gaps = finger_gaps(contour, max(w, h), fcfg)
    sol = solidity_of(contour, hull)
    return HandFeatures(classify(len(gaps), sol, fcfg), contour, hull, gaps,
                        len(gaps), sol, centroid_of(contour), (x, y, w, h))
