"""Bounded overlapping sections registered to an immutable visual map frame."""
import math
import numpy as np
from .keyframes import graph

SECTION_FRAMES = 12
MAX_SECTIONS = 32


def section_batch(frames, placed, pending):
    if not frames:
        return []
    edges = graph(frames)
    by_id = {k['id']: k for k in frames}
    anchors = set(placed) & by_id.keys()
    pending = set(pending) & by_id.keys()
    seeds = [k['id'] for k in frames if k['id'] in pending] or [frames[-1]['id']]
    best, score = [], (-1, -1, -1)
    for seed in seeds:
        chosen = [seed]
        while len(chosen) < SECTION_FRAMES:
            frontier = set().union(*(edges[i] for i in chosen)) - set(chosen)
            if not frontier:
                break
            need_refs = len(set(chosen) & anchors) < 4
            nxt = max(frontier, key=lambda i: (i in anchors if need_refs else i in pending,
                      i in pending, by_id[i].get('quality', 0)))
            chosen.append(nxt)
        refs = len(set(chosen) & anchors)
        rank = (int(not anchors or refs >= 3), len(set(chosen) & pending),
                max((by_id[i].get('t', 0) for i in chosen if i in pending), default=0))
        if rank > score:
            best, score = chosen, rank
    return [by_id[i] for i in best]


def register(cameras, placed):
    """Yaw/scale/translation fit; reject weak baselines and inconsistent shared cameras.

All shared references must agree, rather than silently accepting a fitted outlier.
    """
    pairs = [(c, placed[c['id']]) for c in cameras if c['id'] in placed]
    if len(pairs) < 3:
        raise ValueError('Need at least 3 shared reference views; sweep back toward the existing map')
    p = np.array([c['position'] for c, _ in pairs], dtype=float)
    q = np.array([v for _, v in pairs], dtype=float)
    if not np.isfinite(p).all() or not np.isfinite(q).all():
        raise ValueError('Invalid reference camera positions')
    pc, qc = p.mean(axis=0), q.mean(axis=0)
    a = (p[:, 2]-pc[2]) + 1j*(p[:, 0]-pc[0])
    b = (q[:, 2]-qc[2]) + 1j*(q[:, 0]-qc[0])
    spread = float(np.sqrt(np.mean(np.abs(b)**2)))
    if spread < .15 or np.sum(np.abs(a)**2) < 1e-8:
        raise ValueError('Reference views need more camera movement to establish scale')
    fit = np.sum(np.conj(a)*b) / np.sum(np.abs(a)**2)
    scale, theta = float(abs(fit)), float(np.angle(fit))
    if not .01 < scale < 200:
        raise ValueError('Unstable section scale')
    rot = np.array([[math.cos(theta),0,math.sin(theta)], [0,1,0],
                    [-math.sin(theta),0,math.cos(theta)]])
    offset = qc - scale * (rot @ pc)
    residuals = np.linalg.norm(scale*(p @ rot.T)+offset-q,axis=1)
    rms = float(np.sqrt(np.mean(residuals**2)))
    if rms > min(.25, max(.08, spread*.15)) or float(residuals.max()) > .5:
        raise ValueError(f'Section held: shared views disagree by {rms:.2f} m; capture more overlap')
    return {'scale':scale,'rotateYDeg':math.degrees(theta),'offset':offset.tolist()}, {
        'method':'fixed shared-camera registration', 'residualM':round(rms,3),
        'views':len(pairs), 'referenceSpreadM':round(spread,3)}


def register_joint(cameras, placed):
    """Fit one replacement map with majority consensus, without stacking outliers.

A changed depth estimate can move a few predicted cameras. Require at least 70%
shared-camera agreement and retain the same bounded residual gate for that set.
"""
    from itertools import combinations
    pairs = [(c, placed[c['id']]) for c in cameras if c['id'] in placed]
    if len(pairs) < 5:
        return register(cameras, placed)
    p = np.array([c['position'] for c, _ in pairs], dtype=float)
    q = np.array([v for _, v in pairs], dtype=float)
    spread = float(np.sqrt(np.mean(np.sum((q[:, [0,2]]-q[:, [0,2]].mean(0))**2,axis=1))))
    threshold = min(.2, max(.08, spread*.15))
    candidates = list(combinations(range(len(pairs)), 3))
    best = []
    for slot in np.linspace(0, len(candidates)-1, min(96, len(candidates)), dtype=int):
        subset = {pairs[i][0]['id']:pairs[i][1] for i in candidates[slot]}
        try:
            tf, _ = register(cameras, subset)
        except ValueError:
            continue
        theta = math.radians(tf['rotateYDeg'])
        rot = np.array([[math.cos(theta),0,math.sin(theta)],[0,1,0],[-math.sin(theta),0,math.cos(theta)]])
        residual = np.linalg.norm(tf['scale']*(p@rot.T)+tf['offset']-q,axis=1)
        inliers = np.flatnonzero(residual <= threshold).tolist()
        if len(inliers) > len(best):
            best = inliers
    if len(best) < max(4, math.ceil(.7*len(pairs))):
        raise ValueError('Joint map held: shared cameras lack 70% alignment agreement')
    tf, meta = register(cameras, {pairs[i][0]['id']:pairs[i][1] for i in best})
    meta.update(sharedViews=len(pairs), rejectedViews=len(pairs)-len(best))
    return tf, meta
