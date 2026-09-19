"""CPU visual keyframe selection. Work runs off the hub's WebSocket event loop.

Edges mean spatially distributed SIFT matches survived homography or epipolar RANSAC checks.
They are overlap evidence, not metric poses or a guarantee of static geometry.
"""
from __future__ import annotations

import hashlib
from collections import Counter

import cv2
import numpy as np

MAX_ARCHIVE = 96
MAX_BATCH = 32
WINDOW_MS = 2500


class VisualSelector:
    def __init__(self):
        self.features = cv2.SIFT_create(nfeatures=900, contrastThreshold=.025)
        self.matcher = cv2.BFMatcher(cv2.NORM_L2)

    def describe(self, jpeg):
        # Match only resized grayscale copies; never send these copies to VGGT.
        image = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_GRAYSCALE)
        if image is None:
            return None, 'Invalid image'
        h, w = image.shape
        image = cv2.resize(image, (max(1, round(w * 640 / max(w, h))),
                                  max(1, round(h * 640 / max(w, h)))))
        if np.mean((image < 8) | (image > 247)) > .8:
            return None, 'Too dark or overexposed'
        sharp = float(cv2.Laplacian(image, cv2.CV_32F).var())
        if sharp < 35:
            return None, 'Hold still for a sharper frame'
        kp, desc = self.features.detectAndCompute(image, None)
        if desc is None or len(kp) < 40:
            return None, 'Aim at textured room details'
        points = np.array([k.pt for k in kp], np.float32)
        return {'points': points, 'desc': desc, 'size': np.array(image.shape[::-1]),
                'sharp': sharp, 'hash': hashlib.sha256(jpeg).hexdigest()}, None

    def compare(self, a, b):
        if a['hash'] == b['hash']:
            return 1., True
        pairs = self.matcher.knnMatch(a['desc'], b['desc'], k=2)
        matches = [p for pair in pairs if len(pair) == 2 for p, q in [pair] if p.distance < .75 * q.distance]
        if len(matches) < 20:
            return 0., False
        p = a['points'][[m.queryIdx for m in matches]]
        q = b['points'][[m.trainIdx for m in matches]]
        _, mask = cv2.findHomography(p, q, cv2.RANSAC, 3., maxIters=600, confidence=.99)
        good = mask.ravel().astype(bool) if mask is not None else np.zeros(len(matches), bool)
        # Translation through a 3D room need not fit a single plane. Require
        # stronger evidence for the more flexible epipolar model.
        if len(matches) >= 30:
            _, epipolar = cv2.findFundamentalMat(p, q, cv2.FM_RANSAC, 1.5, .995, 1000)
            if epipolar is not None:
                e = epipolar.ravel().astype(bool)
                if e.sum() >= 24 and e.mean() >= .6 and e.sum() > good.sum():
                    good = e
        if good.sum() < 16 or good.mean() < .4:
            return 0., False
        p, q = p[good] / a['size'], q[good] / b['size']
        # A moving hand or one repeated logo should not establish room overlap.
        for pts in (p, q):
            cells = np.clip((pts * 4).astype(int), 0, 3)
            if len(np.unique(cells, axis=0)) < 3 or np.prod(np.ptp(pts, axis=0)) < .08:
                return 0., False
        strength = float(good.sum() / min(len(a['points']), len(b['points'])))
        duplicate = strength > .3 and np.percentile(np.linalg.norm(p - q, axis=1), 90) < .025
        return strength, bool(duplicate)

    def choose(self, groups, archive, protected):
        """Return accepted frames and updated archive; never mutate input records."""
        archive = [dict(k) for k in archive]
        for index, k in enumerate(archive):
            if '_visual' not in k:
                k['_visual'], _ = self.describe(k['jpeg'])
            if 'links' not in k:
                k['links'] = {}
                if k['_visual'] is not None:
                    for earlier in archive[:index]:
                        if earlier.get('_visual') is not None:
                            strength, _ = self.compare(k['_visual'], earlier['_visual'])
                            if strength:
                                k['links'][earlier['id']] = strength
        accepted, hints = [], {}
        # Phones with fewer retained views choose first; at most one per phone/window.
        counts = Counter(k['pid'] for k in archive)
        for pid, candidates in sorted(groups.items(), key=lambda kv: counts[kv[0]]):
            described = []
            for candidate in candidates:
                visual, reason = self.describe(candidate['jpeg'])
                if visual is None:
                    hints[pid] = reason
                else:
                    described.append(candidate | {'_visual': visual})
            described.sort(key=lambda c: c['_visual']['sharp'], reverse=True)
            for c in described:
                edges, duplicate = {}, False
                for k in archive:
                    if k.get('_visual') is None:
                        continue
                    strength, same = self.compare(c['_visual'], k['_visual'])
                    if strength:
                        edges[k['id']] = strength
                    duplicate |= same
                if duplicate:
                    hints[pid] = 'View already covered; move slowly to a new angle'
                    continue
                if archive and not edges:
                    hints[pid] = 'Point toward a mapped area to connect this view'
                    continue
                c['links'] = edges
                c['quality'] = round(c['_visual']['sharp'], 2)
                archive.append(c)
                accepted.append(c)
                hints[pid] = 'Accepted new view'
                break
            else:
                hints.setdefault(pid, 'Waiting for a clear view')
        archive = trim_archive(archive, protected | {k['id'] for k in accepted})
        return archive, accepted, hints


def graph(frames):
    edges = {k['id']: set() for k in frames}
    for k in frames:
        for other in k.get('links', {}):
            if other in edges:
                edges[k['id']].add(other)
                edges[other].add(k['id'])
    return edges


def reachable(edges, start, omit=None):
    seen, todo = set(), [start]
    while todo:
        cur = todo.pop()
        if cur in seen or cur == omit:
            continue
        seen.add(cur)
        todo.extend(edges[cur] - seen)
    return seen


def trim_archive(frames, protected):
    if not frames:
        return frames
    root = frames[0]['id']
    while len(frames) > MAX_ARCHIVE:
        edges = graph(frames)
        counts = Counter(k['pid'] for k in frames)
        options = [k for k in frames if k['id'] != root and k['id'] not in protected
                   and len(reachable(edges, root, k['id'])) == len(frames) - 1]
        if not options:
            # A long chain cannot be shortened without losing its connection. Drop
            # the newest addition instead of silently destroying the old map's graph.
            frames = frames[:-1]
            continue
        drop = max(options, key=lambda k: (counts[k['pid']], max(k.get('links', {}).values(), default=0),
                                           -k.get('quality', 0)))
        frames = [k for k in frames if k['id'] != drop['id']]
    keep = {k['id'] for k in frames}
    return [k | {'links': {i: v for i, v in k.get('links', {}).items() if i in keep}} for k in frames]


def working_batch(frames, previous=(), pending=(), limit=MAX_BATCH):
    """Connected batch: shared references, fair new views, then older coverage.

Adding shortest overlap paths keeps cross-phone bridge views in the batch.
"""
    if not frames:
        return []
    by_id = {k['id']: k for k in frames}
    edges = graph(frames)
    chosen = [frames[0]['id']]

    def add_path(target, cap):
        if target not in by_id or target in chosen:
            return
        todo = [(target, [target])]
        visited = {target}
        for cur, path in todo:
            if cur in chosen:
                addition = list(reversed(path[:-1]))
                if len(chosen) + len(addition) <= cap:
                    chosen.extend(addition)
                return
            for nxt in sorted(edges[cur]):
                if nxt not in visited:
                    visited.add(nxt)
                    todo.append((nxt, path + [nxt]))

    refs = [i for i in previous if i in by_id]
    # Spread reference choices across the preceding batch rather than only its start.
    for i in np.linspace(0, len(refs) - 1, min(6, len(refs)), dtype=int):
        add_path(refs[i], min(12, limit))
    pending = set(pending)
    new = [k for k in reversed(frames) if k['id'] in pending]
    while new:
        counts = Counter(by_id[i]['pid'] for i in chosen)
        k = min(new, key=lambda k: counts[k['pid']])
        add_path(k['id'], max(len(chosen), limit - 8))
        new.remove(k)
    # Alternate phone coverage; prefer candidates weakly connected to selected
    # views, which are more likely to reveal a different part of the scene.
    remaining = [k for k in frames if k['id'] not in chosen]
    while remaining and len(chosen) < limit:
        counts = Counter(by_id[i]['pid'] for i in chosen)
        k = min(remaining, key=lambda k: (counts[k['pid']], k['id'] in refs,
                max((k.get('links', {}).get(i, by_id[i].get('links', {}).get(k['id'], 0)) for i in chosen),
                    default=0), -k.get('quality', 0)))
        add_path(k['id'], limit)
        remaining.remove(k)
    return [by_id[i] for i in chosen]
