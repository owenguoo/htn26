"""Persistent object observations with conservative flat-floor position estimates."""
from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .detection import SearchState


class ObjectDetection(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    label: Literal['chair', 'person']
    score: float = Field(ge=0, le=1)
    box: tuple[float, float, float, float]


class HazardResult(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False, strict=True)
    phoneId: str
    streamId: str
    seq: int = Field(ge=0)
    t: float = Field(ge=0)
    width: int = Field(gt=0)
    height: int = Field(gt=0)
    searchRevision: str
    detections: list[ObjectDetection] = Field(max_length=100)


def floor_position(chair: ObjectDetection, pose: dict | None, width: int, height: int, room: dict):
    if not pose or not pose.get('calibrated') or pose.get('source') == 'sim':
        return None
    values = [pose.get(k) for k in ('x', 'y', 'heading', 'pitch')]
    if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in values):
        return None
    x1, y1, x2, y2 = chair.box
    if chair.score < .6 or not (0 < x1 < x2 < width and 0 < y1 < y2 < height * .97):
        return None
    # The bottom of an uncut object approximates floor contact. Height and FOV are estimates.
    focal = width / (2 * math.tan(math.radians(room['cameraFovDeg']) / 2))
    right = ((x1 + x2) / 2 - width / 2) / focal
    down = (y2 - height / 2) / focal
    pitch = math.radians(pose['pitch'])
    vertical = math.sin(pitch) - down * math.cos(pitch)
    forward = math.cos(pitch) + down * math.sin(pitch)
    if vertical >= -.15 or forward <= 0:
        return None
    distance = 1.45 / -vertical
    forward, right = forward * distance, right * distance
    if not .4 <= math.hypot(forward, right) <= 6:
        return None
    heading = math.radians(pose['heading'])
    x = pose['x'] + forward * math.sin(heading) + right * math.cos(heading)
    y = pose['y'] - forward * math.cos(heading) + right * math.sin(heading)
    # The room outline is nominal; calibrated observations can lie beyond its walls.
    return x, y


class Hazards:
    def __init__(self):
        self.revision = None
        self.observations: dict[str, dict] = {}
        self.sequences: dict[str, tuple[str, int]] = {}
        self.ids = 0

    def snapshot(self, now: float, revision: str) -> list[dict]:
        if revision != self.revision:
            self.revision = revision
            self.sequences.clear()
        for item in self.observations.values():
            # A staged hazard never goes stale: every consumer works staleness out from
            # `t`, and nothing is coming to re-observe this one. Rolling it forward here
            # is one line in the one place, rather than an `if simulated` in each of the
            # console's drawing code, the phones' world message and whatever comes next.
            if item['phoneId'] == 'sim':
                item['t'] = now
        self.observations = {k: v for k, v in self.observations.items() if v['hits'] >= 2 or now - v['t'] <= 15000}
        return [dict(v) for v in self.observations.values() if v['hits'] >= 2]

    def reset(self) -> None:
        self.observations.clear()
        self.sequences.clear()

    def simulate(self, spots: list[tuple[float, float]], now: float) -> list[dict]:
        """Mock chairs for a drill, at positions someone else chose.

        `hits` starts at 2 because `snapshot` only publishes an object that has been
        seen twice — the second sighting that would normally confirm a real chair is
        never coming for this one. `approximate` stays true for the same reason it is
        true of a real observation: this is a flat-floor guess, not a survey.
        """
        out = []
        for x, y in spots:
            self.ids += 1
            item = dict(id=f'object-{self.ids}', label='chair', x=round(x, 2), y=round(y, 2),
                        t=now, hits=2, approximate=True, phoneId='sim')
            self.observations[item['id']] = item
            out.append(item)
        return out

    def accept(self, result: HazardResult, search: SearchState, room: dict, now: float) -> bool:
        self.snapshot(now, search.revision)
        frame = search.frames.get(result.phoneId, {}).get(result.seq)
        if (result.searchRevision != search.revision or search.streams.get(result.phoneId) != result.streamId
                or not frame or frame.stream_id != result.streamId
                or (frame.t, frame.width, frame.height) != (result.t, result.width, result.height)
                or not 0 <= now - result.t <= 1500):
            return False
        previous = self.sequences.get(result.phoneId)
        if previous and previous[0] == result.streamId and previous[1] >= result.seq:
            return False
        self.sequences[result.phoneId] = (result.streamId, result.seq)
        touched = set()
        for chair in result.detections:
            point = floor_position(chair, frame.pose, frame.width, frame.height, room)
            if point is None:
                continue
            x, y = point
            nearby = [v for v in self.observations.values() if v['id'] not in touched and v['label'] == chair.label
                      and math.hypot(v['x'] - x, v['y'] - y) < .8]
            if nearby:
                item = min(nearby, key=lambda v: math.hypot(v['x'] - x, v['y'] - y))
                item.update(x=(item['x'] + x) / 2, y=(item['y'] + y) / 2, t=result.t, hits=item['hits'] + 1)
            elif len(self.observations) < 100:
                self.ids += 1
                item = dict(id=f'object-{self.ids}', label=chair.label, x=x, y=y, t=result.t,
                            hits=1, approximate=True, phoneId=result.phoneId)
                self.observations[item['id']] = item
            else:
                continue
            touched.add(item['id'])
        return True
