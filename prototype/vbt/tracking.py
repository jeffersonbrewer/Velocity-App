"""Find the weight plate in a side-view video and follow its center frame by frame.

The plate is located once with a Hough circle search, then tracked with template
matching for a coarse position and an edge-based circle fit for a sub-pixel center.
The edge fit only uses the plate's outline, so it is unaffected by the plate rotating.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class Circle:
    x: float
    y: float
    r: float
    # Minor/major axis ratio of an ellipse fit to the edge. 1.0 means the camera is
    # square to the plate; lower values mean distances will be distorted.
    roundness: float = 1.0


@dataclass
class Track:
    fps: float
    t: np.ndarray          # seconds, one per frame
    x_px: np.ndarray       # plate center, NaN where tracking was lost
    y_px: np.ndarray
    r_px: np.ndarray       # fitted radius per frame, NaN where lost
    roundness: float       # median roundness over the clip
    frame_size: tuple[int, int]  # (width, height)

    @property
    def radius_px(self) -> float:
        return float(np.nanmedian(self.r_px))

    @property
    def lost_fraction(self) -> float:
        return float(np.mean(np.isnan(self.x_px)))


def detect_plate(gray: np.ndarray, min_frac: float = 0.05, max_frac: float = 0.45) -> Circle | None:
    """Return the largest strong circle in the frame, which is taken to be the plate."""
    h, w = gray.shape
    dim = min(h, w)
    blur = cv2.medianBlur(gray, 5)
    circles = cv2.HoughCircles(
        blur, cv2.HOUGH_GRADIENT, dp=1.5, minDist=dim / 4,
        param1=120, param2=50,
        minRadius=int(dim * min_frac), maxRadius=int(dim * max_frac),
    )
    if circles is None:
        return None
    # Start from the strongest vote. Hough also returns large false circles made of
    # unrelated straight edges (door panels, legs), so a larger candidate only wins when it
    # is concentric with the strongest one, i.e. it is the plate rim around the hub.
    cands = circles[0][:6]
    x, y, r = cands[0]
    for cx, cy, cr in cands[1:]:
        if cr > r and np.hypot(cx - x, cy - y) < 0.2 * cr:
            x, y, r = cx, cy, cr
    return refine_circle(gray, float(x), float(y), float(r)) or Circle(float(x), float(y), float(r))


def refine_circle(gray: np.ndarray, x: float, y: float, r: float, n_rays: int = 180) -> Circle | None:
    """Fit a circle to the plate's outer edge with sub-pixel precision.

    Samples the image along rays from the approximate center, takes the strongest
    edge on each ray, then least-squares fits a circle with outlier rejection.
    """
    angles = np.linspace(0, 2 * np.pi, n_rays, endpoint=False)
    radii = np.linspace(0.75 * r, 1.25 * r, 64)
    xs = x + np.outer(np.cos(angles), radii)
    ys = y + np.outer(np.sin(angles), radii)
    img = gray.astype(np.float32)
    profile = cv2.remap(img, xs.astype(np.float32), ys.astype(np.float32), cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_CONSTANT, borderValue=np.nan)
    grad = np.abs(np.diff(profile, axis=1))
    valid_rays = ~np.isnan(grad).any(axis=1)
    if valid_rays.sum() < n_rays * 0.4:
        return None
    grad = np.nan_to_num(grad)
    k = np.argmax(grad, axis=1)
    # Parabolic interpolation of the gradient peak for sub-sample precision.
    k_safe = np.clip(k, 1, grad.shape[1] - 2)
    rows = np.arange(n_rays)
    g0, g1, g2 = grad[rows, k_safe - 1], grad[rows, k_safe], grad[rows, k_safe + 1]
    denom = g0 - 2 * g1 + g2
    offset = np.where(np.abs(denom) > 1e-6, 0.5 * (g0 - g2) / denom, 0.0)
    step = radii[1] - radii[0]
    edge_r = radii[0] + (k_safe + 0.5 + offset) * step
    strength = g1
    keep = valid_rays & (strength > 0.3 * np.median(strength[valid_rays]))
    px = x + np.cos(angles) * edge_r
    py = y + np.sin(angles) * edge_r
    px, py = px[keep], py[keep]
    if len(px) < 20:
        return None

    for _ in range(3):
        cx, cy, cr = _fit_circle(px, py)
        resid = np.hypot(px - cx, py - cy) - cr
        mad = np.median(np.abs(resid - np.median(resid))) + 1e-6
        inliers = np.abs(resid) < 3 * 1.4826 * mad + 0.5
        if inliers.all() or inliers.sum() < 20:
            break
        px, py = px[inliers], py[inliers]

    roundness = 1.0
    if len(px) >= 5:
        (_, _), (a1, a2), _ = cv2.fitEllipse(np.column_stack([px, py]).astype(np.float32))
        roundness = float(min(a1, a2) / max(a1, a2))
    return Circle(float(cx), float(cy), float(cr), roundness)


def _fit_circle(px: np.ndarray, py: np.ndarray) -> tuple[float, float, float]:
    """Algebraic (Kasa) least-squares circle fit."""
    A = np.column_stack([2 * px, 2 * py, np.ones_like(px)])
    b = px ** 2 + py ** 2
    (cx, cy, c), *_ = np.linalg.lstsq(A, b, rcond=None)
    return float(cx), float(cy), float(np.sqrt(c + cx ** 2 + cy ** 2))


def _match_subpixel(res: np.ndarray) -> tuple[float, float, float]:
    _, score, _, (mx, my) = cv2.minMaxLoc(res)
    dx = dy = 0.0
    if 0 < mx < res.shape[1] - 1:
        l, c, r = res[my, mx - 1], res[my, mx], res[my, mx + 1]
        d = l - 2 * c + r
        dx = 0.5 * (l - r) / d if abs(d) > 1e-9 else 0.0
    if 0 < my < res.shape[0] - 1:
        u, c, dn = res[my - 1, mx], res[my, mx], res[my + 1, mx]
        d = u - 2 * c + dn
        dy = 0.5 * (u - dn) / d if abs(d) > 1e-9 else 0.0
    return mx + dx, my + dy, float(score)


def track_video(path: str, fps: float | None = None, min_score: float = 0.5) -> Track:
    """Track the plate through a whole video.

    fps overrides the frame rate stored in the file. Use it when a slow-motion clip
    was exported with its slow motion "baked in" at a playback rate such as 30 fps.
    """
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise IOError(f"Could not open video: {path}")
    file_fps = cap.get(cv2.CAP_PROP_FPS)
    fps = fps or file_fps
    if not fps or fps <= 0:
        raise ValueError("Video has no frame rate; pass fps explicitly.")

    xs, ys, rs, rounds = [], [], [], []
    template = None
    prev: Circle | None = None
    misses = 0
    ref_r: float | None = None  # plate radius from the first detection; the plate never changes size
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
        circle = None
        if prev is None:
            circle = detect_plate(gray)
            if circle is not None and ref_r is not None and abs(circle.r - ref_r) > 0.12 * ref_r:
                circle = None  # re-detection found something else (the hub ring, a stray circle)
            if circle is not None and ref_r is None:
                ref_r = circle.r
                half = int(round(circle.r * 1.05))
                x0, y0 = int(round(circle.x)) - half, int(round(circle.y)) - half
                if x0 >= 0 and y0 >= 0 and x0 + 2 * half < gray.shape[1] and y0 + 2 * half < gray.shape[0]:
                    template = (gray[y0:y0 + 2 * half, x0:x0 + 2 * half].copy(), half)
        else:
            circle = _track_step(gray, prev, template, min_score, ref_r)

        if circle is None:
            xs.append(np.nan); ys.append(np.nan); rs.append(np.nan)
            # After losing the plate for a few frames, search the whole frame again: the last
            # accepted circle may be slightly off, and searching around it can fail forever.
            misses += 1
            if template is None or misses >= 3:
                prev = None
        else:
            xs.append(circle.x); ys.append(circle.y); rs.append(circle.r)
            misses = 0
            rounds.append(circle.roundness)
            prev = circle
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()

    n = len(xs)
    if n == 0:
        raise ValueError(f"No frames read from {path}")
    return Track(
        fps=float(fps),
        t=np.arange(n) / float(fps),
        x_px=np.array(xs), y_px=np.array(ys), r_px=np.array(rs),
        roundness=float(np.median(rounds)) if rounds else float("nan"),
        frame_size=(width, height),
    )


def _track_step(gray: np.ndarray, prev: Circle, template, min_score: float,
                ref_r: float | None = None) -> Circle | None:
    guess_x, guess_y = prev.x, prev.y
    if template is not None:
        tpl, half = template
        search = int(prev.r * 0.6) + 8
        x0 = max(int(prev.x) - half - search, 0)
        y0 = max(int(prev.y) - half - search, 0)
        x1 = min(int(prev.x) + half + search, gray.shape[1])
        y1 = min(int(prev.y) + half + search, gray.shape[0])
        window = gray[y0:y1, x0:x1]
        if window.shape[0] > tpl.shape[0] and window.shape[1] > tpl.shape[1]:
            res = cv2.matchTemplate(window, tpl, cv2.TM_CCOEFF_NORMED)
            mx, my, score = _match_subpixel(res)
            if score >= min_score:
                guess_x, guess_y = x0 + mx + half, y0 + my + half
    r0 = ref_r or prev.r
    circle = refine_circle(gray, guess_x, guess_y, prev.r)
    if circle is None:
        return None
    # Reject fits that jump implausibly or change size, which signal a wrong edge.
    # Check against the first detection, not the previous frame, so the fit cannot creep
    # inward to the hub ring (about 20% smaller) a few percent at a time while a leg passes
    # in front. 12% leaves room for the plate looking smaller higher in the frame when the
    # camera is tilted.
    if abs(circle.r - r0) > 0.12 * r0 or np.hypot(circle.x - guess_x, circle.y - guess_y) > 0.3 * prev.r:
        return None
    return circle
