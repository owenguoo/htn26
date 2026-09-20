"""CPU visual keyframe selection. Work runs off the hub's WebSocket event loop.

Edges mean spatially distributed SIFT matches survived homography or epipolar RANSAC checks.
They are overlap evidence, not metric poses or a guarantee of static geometry.
"""
from __future__ import annotations

import hashlib
from collections import Counter, deque
import time

import cv2
import numpy as np

MAX_ARCHIVE = 96
MAX_BATCH = 32
WINDOW_MS = 2500
MAX_STAGED = 64
STAGED_SECONDS = 20
MAX_SEQUENCE_SECONDS = 90
STAGED_NEIGHBORS = 8


class VisualSelector:
    def __init__(self):
        self.features = cv2.SIFT_create(nfeatures=900, contrastThreshold=.025)
        self.matcher = cv2.BFMatcher(cv2.NORM_L2)
        self.staged = []
        self.counts = Counter()
        self.match_counts = Counter()
        self.bootstrap = None
        self.events = deque(maxlen=100)

    def record(self, frame, outcome):
        self.counts[outcome] += 1
        self.events.append({"id": frame["id"], "phoneId": frame["pid"],
                            "t": time.time(), "outcome": outcome})

    def status(self):
        return {"counts": dict(self.counts), "waitingForOverlap": len(self.staged),
                "recent": list(self.events), "overlapChecks": dict(self.match_counts),
                "bootstrap": self.bootstrap}

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
        # A sharp edge in one corner must not rescue an otherwise blurred frame.
        tiles = [tile for row in np.array_split(image, 3, axis=0)
                 for tile in np.array_split(row, 3, axis=1)]
        sharp_tiles = sum(float(cv2.Laplacian(tile, cv2.CV_32F).var()) >= 25 for tile in tiles)
        if sharp_tiles < 4:
            return None, 'Too little clear detail across the image'
        kp, desc = self.features.detectAndCompute(image, None)
        if desc is None or len(kp) < 40:
            return None, 'Aim at textured room details'
        points = np.array([k.pt for k in kp], np.float32)
        return {'points': points, 'desc': desc, 'size': np.array(image.shape[::-1]),
                'sharp': sharp, 'hash': hashlib.sha256(jpeg).hexdigest()}, None

    def compare(self, a, b):
        def result(reason, strength=0., duplicate=False):
            self.match_counts[reason] += 1
            return strength, duplicate
        if a['hash'] == b['hash']:
            return result('Identical image', 1., True)
        pairs = self.matcher.knnMatch(a['desc'], b['desc'], k=2)
        matches = [p for pair in pairs if len(pair) == 2 for p, q in [pair] if p.distance < .75 * q.distance]
        if len(matches) < 20:
            return result('Too few descriptor matches')
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
            return result('Geometry verification failed')
        p, q = p[good] / a['size'], q[good] / b['size']
        # A moving hand or one repeated logo should not establish room overlap.
        for pts in (p, q):
            cells = np.clip((pts * 4).astype(int), 0, 3)
            if len(np.unique(cells, axis=0)) < 3 or np.prod(np.ptp(pts, axis=0)) < .08:
                return result('Matches cover too little image area')
        strength = float(good.sum() / min(len(a['points']), len(b['points'])))
        duplicate = strength > .3 and np.percentile(np.linalg.norm(p - q, axis=1), 90) < .025
        return result('Duplicate view' if duplicate else 'Verified overlap', strength, bool(duplicate))

    def choose(self, groups, archive, protected, bootstrap_min=None):
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
        now = time.monotonic()
        pool = []
        for c in self.staged:
            if now - c['_stagedAt'] > MAX_SEQUENCE_SECONDS:
                self.record(c, 'Expired without overlap')
            else:
                pool.append(c)
        # Keep chronological bridge frames, not just the sharpest image of a sweep.
        for candidates in groups.values():
            for candidate in candidates:
                self.counts['Evaluated'] += 1
                visual, reason = self.describe(candidate['jpeg'])
                if visual is None:
                    hints[candidate['pid']] = reason
                    self.record(candidate, reason)
                elif any(c['_visual']['hash'] == visual['hash'] for c in pool):
                    self.record(candidate, 'Duplicate')
                else:
                    pool.append(candidate | {'_visual': visual, '_stagedAt': now})
        pool.sort(key=lambda c: (int(c['t'] // 500), -c['_visual']['sharp']))
        # Link nearby waiting views before expiring them. A continuing sweep keeps
        # its connecting views alive, but isolated/stale components still expire.
        waiting_edges = {c['id']: set() for c in pool}
        for i, c in enumerate(pool):
            for other in pool[max(0, i-STAGED_NEIGHBORS):i]:
                comparisons = c.setdefault('_matches', {})
                if other['id'] not in comparisons:
                    comparisons[other['id']] = self.compare(c['_visual'], other['_visual'])
                if comparisons[other['id']][0]:
                    waiting_edges[c['id']].add(other['id'])
                    waiting_edges[other['id']].add(c['id'])
        by_id = {c['id']:c for c in pool}
        keep, unseen = set(), set(by_id)
        while unseen:
            component = reachable(waiting_edges, min(unseen))
            unseen -= component
            if now - max(by_id[i]['_stagedAt'] for i in component) <= STAGED_SECONDS:
                keep.update(component)
        for c in pool:
            if c['id'] not in keep:
                self.record(c, 'Expired without overlap')
        pool = [c for c in pool if c['id'] in keep]
        while pool:
            remaining = []
            progress = False
            for c in pool:
                edges, duplicate = {}, False
                for k in archive:
                    if k.get('_visual') is None:
                        continue
                    comparisons = c.setdefault('_matches', {})
                    if k['id'] not in comparisons:
                        comparisons[k['id']] = self.compare(c['_visual'], k['_visual'])
                    strength, same = comparisons[k['id']]
                    if strength:
                        edges[k['id']] = strength
                    duplicate |= same
                if duplicate:
                    hints[c['pid']] = 'View already covered; move slowly to a new angle'
                    self.record(c, 'Duplicate')
                    continue
                if archive and not edges:
                    remaining.append(c)
                    hints[c['pid']] = ('Holding connected sweep; include a mapped area to join it'
                                       if waiting_edges[c['id']] else
                                       'Holding view; sweep back toward a mapped area to connect it')
                    continue
                c['links'] = edges
                c['quality'] = round(c['_visual']['sharp'], 2)
                archive.append(c)
                accepted.append(c)
                hints[c['pid']] = 'Accepted new view'
                progress = True
            pool = remaining
            if not progress:
                break
        # Before the first reconstruction only, a disconnected but coherent sweep
        # can replace an undersized seed. Never mix disconnected coordinate groups.
        if bootstrap_min and not protected and len(archive) < bootstrap_min:
            remaining_ids = {c['id'] for c in pool}
            edges = {i: waiting_edges[i] & remaining_ids for i in remaining_ids}
            components = []
            while remaining_ids:
                component = reachable(edges, min(remaining_ids))
                remaining_ids -= component
                if len(component) >= bootstrap_min:
                    components.append(component)
            components.sort(key=lambda ids: (-len(ids), min(ids)))
            for component in components:
                candidates = [c for c in pool if c['id'] in component]
                seed = []
                for c in candidates:
                    links, duplicate = {}, False
                    for other in seed:
                        cached = c.setdefault('_matches', {})
                        if other['id'] not in cached:
                            cached[other['id']] = self.compare(c['_visual'], other['_visual'])
                        strength, same = cached[other['id']]
                        duplicate |= same
                        if strength:
                            links[other['id']] = strength
                    if not duplicate:
                        seed.append(c | {'links': links, 'quality': round(c['_visual']['sharp'], 2)})
                    if len(seed) >= MAX_BATCH:
                        break
                # Removing near-duplicates can disconnect a chain: recheck it.
                seed_edges = graph(seed)
                seed_ids = set(seed_edges)
                connected = []
                while seed_ids:
                    ids = reachable(seed_edges, min(seed_ids))
                    seed_ids -= ids
                    if len(ids) >= bootstrap_min:
                        connected.append(ids)
                if not connected:
                    continue
                chosen = max(connected, key=lambda ids: (len(ids), min(ids)))
                old = archive
                archive = [c | {'links': {i:v for i,v in c['links'].items() if i in chosen}}
                           for c in seed if c['id'] in chosen]
                accepted = list(archive)
                pool = [c for c in pool if c['id'] not in chosen] + old
                # Retain the original seed for a future bridge, within normal bounds.
                old_edges = graph(old)
                for c in old:
                    c.setdefault('_stagedAt', now)
                    by_id[c['id']] = c
                    waiting_edges[c['id']] = old_edges[c['id']]
                    self.record(c, 'Deferred initial seed')
                self.bootstrap = {'views': len(archive), 'deferredViews': len(old)}
                for c in archive:
                    hints[c['pid']] = 'Starting map from a connected sweep'
                break
        # Evict whole stale components before cutting into a connected sweep.
        remaining_ids = {c['id'] for c in pool}
        components = []
        edges = {i: waiting_edges[i] & remaining_ids for i in remaining_ids}
        while remaining_ids:
            component = reachable(edges, min(remaining_ids))
            remaining_ids -= component
            components.append(component)
        components.sort(key=lambda ids: max((by_id[i]['_stagedAt'], by_id[i]['t'], i) for i in ids), reverse=True)
        retained = set()
        for component in components:
            room = MAX_STAGED-len(retained)
            if room <= 0:
                break
            ordered = sorted(component, key=lambda i:(by_id[i]['_stagedAt'], by_id[i]['t']))
            retained.update(ordered[-room:])
        for c in pool:
            if c['id'] not in retained:
                self.record(c, 'Overlap buffer full')
        self.staged = [c for c in pool if c['id'] in retained]
        archive = trim_archive(archive, protected | {k['id'] for k in accepted})
        kept = {k['id'] for k in archive}
        for c in accepted:
            self.record(c, 'Accepted' if c['id'] in kept else 'Archive full')
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


def working_batch(frames, previous=(), pending=(), limit=MAX_BATCH, stable=False):
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
    reference_budget = max(6, limit - 4) if stable else min(12, limit)
    reference_count = reference_budget if stable else 6
    for i in np.linspace(0, len(refs) - 1, min(reference_count, len(refs)), dtype=int):
        add_path(refs[i], reference_budget)
    pending = set(pending)
    new = [k for k in reversed(frames) if k['id'] in pending]
    while new:
        counts = Counter(by_id[i]['pid'] for i in chosen)
        k = min(new, key=lambda k: counts[k['pid']])
        add_path(k['id'], limit if stable and len(refs) >= limit else max(len(chosen), limit - 8))
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
