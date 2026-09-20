"""Pure frame identity and appearance-search contracts, independent of model execution."""
from __future__ import annotations

import hashlib
import math
import uuid
import time
from collections import OrderedDict
from copy import deepcopy
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

MAX_RESULT_AGE_MS = 1500
MAX_FRAMES_PER_PHONE = 32
MAX_PEOPLE = 8   # reference people searched at once; every frame is matched against each of them


class Box(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False, strict=True)
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    w: float = Field(gt=0, le=1)
    h: float = Field(gt=0, le=1)
    label: Literal['person'] = 'person'
    detectionScore: float = Field(ge=0, le=1)
    similarity: float = Field(ge=-1, le=1)
    targetId: str | None = Field(default=None, max_length=128)  # which reference person this matched

    @model_validator(mode='after')
    def within_frame(self) -> Box:
        if self.x + self.w > 1 + 1e-9 or self.y + self.h > 1 + 1e-9:
            raise ValueError('box extends beyond frame')
        return self


class DetectionResult(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False, strict=True)
    phoneId: str = Field(min_length=1)
    streamId: str = Field(min_length=1, max_length=128)
    seq: int = Field(ge=0)
    t: float = Field(ge=0)
    searchRevision: str = Field(min_length=1, max_length=128)
    targetVersion: str = Field(min_length=1, max_length=128)
    width: int = Field(gt=0, le=16384)
    height: int = Field(gt=0, le=16384)
    boxes: list[Box] = Field(max_length=100)
    queueMs: float = Field(ge=0)
    inferenceMs: float = Field(ge=0)
    matchingMs: float = Field(ge=0)


@dataclass(frozen=True)
class FrameSnapshot:
    phone_id: str
    stream_id: str
    seq: int
    t: float
    width: int
    height: int
    pose: dict | None

    @property
    def worker_phone_id(self) -> str:
        return self.stream_id

    @property
    def worker_frame_id(self) -> str:
        return f'{self.stream_id}:{self.seq}'


@dataclass(frozen=True)
class AcceptedResult:
    result: DetectionResult
    pose: dict | None
    matched: bool
    matching_boxes: tuple[Box, ...]


def captured_at_seconds(t_ms: float) -> float:
    if not math.isfinite(t_ms) or t_ms < 0:
        raise ValueError('invalid capture timestamp')
    return t_ms / 1000


def normalize_box(bounds: tuple[float, float, float, float], width: int, height: int) -> dict[str, float]:
    x1, y1, x2, y2 = bounds
    if (width <= 0 or height <= 0 or not all(math.isfinite(v) for v in bounds)
            or not 0 <= x1 < x2 <= width or not 0 <= y1 < y2 <= height):
        raise ValueError('invalid pixel bounds')
    return dict(x=x1 / width, y=y1 / height, w=(x2 - x1) / width, h=(y2 - y1) / height)


class SearchState:
    def __init__(self) -> None:
        self.mode: Literal["real", "rehearsal"] = "rehearsal"
        # A real search can turn up more than one person: the operator confirms each sighting
        # separately and every confirmation is kept. `confirmation` is the most recent one.
        self.confirmations: list[dict] = []
        self.map_sighting: dict | None = None
        self.revision = str(uuid.uuid4())
        # The reference roster: everybody we're looking for, one entry per uploaded photo.
        # Every frame is matched against each of them, so a search can look for several people.
        self.people: list[dict] = []   # {"id", "label", "version"}
        self._next_person = 1
        self.threshold = .70
        self.streams: dict[str, str] = {}
        self.frames: dict[str, OrderedDict[int, FrameSnapshot]] = {}
        self.latest: dict[str, AcceptedResult] = {}
        self._accepted_seq: dict[str, int] = {}

    @property
    def target_version(self) -> str | None:
        """The reference version results must carry. One person: theirs, so a single-target search
        is unchanged. Several: a fingerprint of the roster, so adding or dropping anybody
        invalidates every result still in flight."""
        if not self.people:
            return None
        if len(self.people) == 1:
            return self.people[0]['version']
        joined = '|'.join(f'{p["id"]}:{p["version"]}' for p in self.people)
        return 'roster-' + hashlib.sha256(joined.encode()).hexdigest()[:32]

    @property
    def confirmation(self) -> dict | None:
        """The most recent operator-confirmed sighting."""
        return self.confirmations[-1] if self.confirmations else None

    def reset(self, *, preserve_confirmation: bool = False, preserve_sighting: bool = False) -> None:
        """Invalidate callbacks and visible results while preserving the active reference."""
        self.revision = str(uuid.uuid4())
        if not preserve_sighting:
            self.map_sighting = None
        if not preserve_confirmation:
            self.confirmations.clear()
        self.latest.clear()
        self._accepted_seq.clear()

    def set_reference(self, target_version: str | None, *, threshold: float | None = None) -> None:
        """Replace the whole roster with one person, or with nobody."""
        if threshold is not None:
            self._validate_threshold(threshold)
            self.threshold = threshold
        if target_version is not None:
            self.mode = "real"
        self._next_person = 1
        self.people = [] if target_version is None else [self._person(target_version, None)]
        self.reset()

    @property
    def next_person_id(self) -> str:
        """The worker target id the next reference photo will be registered under."""
        return f'person-{self._next_person}'

    def _person(self, version: str, label: str | None) -> dict:
        person = {'id': f'person-{self._next_person}', 'version': version,
                  'label': (label or '').strip()[:60] or f'Person {self._next_person}'}
        self._next_person += 1
        return person

    def add_person(self, version: str, label: str | None = None) -> dict:
        """Another reference photo: somebody else to look for, searched at the same time as the
        people already on the roster. Their confirmed sightings survive; in-flight results don't,
        because the roster fingerprint they were matched under has changed."""
        if len(self.people) >= MAX_PEOPLE:
            raise ValueError(f'at most {MAX_PEOPLE} people can be searched for at once')
        self.mode = "real"
        person = self._person(version, label)
        self.people.append(person)
        self.reset(preserve_confirmation=True)
        return person

    def remove_person(self, person_id: str) -> dict | None:
        """Stop looking for one person. The rest of the roster carries on."""
        found = next((p for p in self.people if p['id'] == person_id), None)
        if found:
            self.people.remove(found)
            self.reset()
        return found

    @staticmethod
    def _validate_threshold(value: float) -> None:
        if isinstance(value, bool) or not math.isfinite(value) or not -1 <= value <= 1:
            raise ValueError('threshold must be finite and between -1 and 1')

    def set_threshold(self, value: float) -> None:
        self._validate_threshold(value)
        if self.threshold != value:
            self.threshold = value
            self.reset()

    def _drop_confirmations(self, phone_id: str) -> None:
        """A phone's stream restarted: nothing it confirmed is still verifiable."""
        self.confirmations = [c for c in self.confirmations if c["phoneId"] != phone_id]

    def connect(self, phone_id: str, stream_id: str) -> None:
        self._drop_confirmations(phone_id)
        self.streams[phone_id] = stream_id
        self.frames[phone_id] = OrderedDict()
        self.latest.pop(phone_id, None)
        self._accepted_seq.pop(phone_id, None)

    def disconnect(self, phone_id: str, stream_id: str) -> None:
        if self.streams.get(phone_id) == stream_id:
            self._drop_confirmations(phone_id)
            self.streams.pop(phone_id, None)
            self.frames.pop(phone_id, None)
            self.latest.pop(phone_id, None)
            self._accepted_seq.pop(phone_id, None)

    def record_frame(self, frame: FrameSnapshot) -> None:
        if self.streams.get(frame.phone_id) != frame.stream_id:
            return
        frames = self.frames[frame.phone_id]
        frames[frame.seq] = deepcopy(frame)
        while len(frames) > MAX_FRAMES_PER_PHONE:
            frames.popitem(last=False)

    def expire(self, now_ms: float) -> None:
        for phone_id, accepted in list(self.latest.items()):
            if now_ms - accepted.result.t > MAX_RESULT_AGE_MS:
                del self.latest[phone_id]
        for frames in self.frames.values():
            for seq, frame in list(frames.items()):
                if now_ms - frame.t > MAX_RESULT_AGE_MS:
                    del frames[seq]

    def accept_result(self, result: DetectionResult | dict, *, now_ms: float) -> bool:
        self.expire(now_ms)
        try:
            result = DetectionResult.model_validate(result)
        except ValidationError:
            return False
        if (not self.target_version or result.targetVersion != self.target_version
                or result.searchRevision != self.revision
                or self.streams.get(result.phoneId) != result.streamId
                or not 0 <= now_ms - result.t <= MAX_RESULT_AGE_MS
                or result.seq <= self._accepted_seq.get(result.phoneId, -1)):
            return False
        frame = self.frames.get(result.phoneId, {}).get(result.seq)
        if frame is None or (frame.t, frame.width, frame.height) != (result.t, result.width, result.height):
            return False
        matches = tuple(box for box in result.boxes if box.similarity >= self.threshold)
        self.latest[result.phoneId] = AcceptedResult(result.model_copy(deep=True), deepcopy(frame.pose), bool(matches), matches)
        self._accepted_seq[result.phoneId] = result.seq
        return True

    def confirm(self, phone_id: str, stream_id: str, seq: int, search_revision: str,
                *, now_ms: float | None = None) -> bool:
        now_ms = time.time() * 1000 if now_ms is None else now_ms
        self.expire(now_ms)
        entry = self.latest.get(phone_id)
        if (self.mode != 'real' or not self.target_version or entry is None or not entry.matched
                or self.streams.get(phone_id) != stream_id or search_revision != self.revision
                or entry.result.streamId != stream_id or entry.result.seq != seq
                or entry.result.targetVersion != self.target_version
                or not 0 <= now_ms - entry.result.t <= MAX_RESULT_AGE_MS):
            return False
        if self.map_sighting and all(self.map_sighting[k] == v for k, v in
                [('phoneId', phone_id), ('streamId', stream_id), ('seq', seq)]):
            self.map_sighting['confirmed'] = True
        self.confirmations = [c for c in self.confirmations
                              if (c["phoneId"], c["streamId"], c["seq"]) != (phone_id, stream_id, seq)]
        self.confirmations.append(entry.result.model_dump() | {
            'status': 'operator_confirmed_visual', 'confirmedAt': now_ms, 'threshold': self.threshold,
            'observerPose': deepcopy(entry.pose), 'targetPosition': None, 'locationStatus': 'unknown'})
        return True

    def visual_context(self, now_ms: float) -> dict:
        self.expire(now_ms)
        return {'mode': self.mode, 'people': deepcopy(self.people),
                'confirmation': deepcopy(self.confirmation),
                'confirmations': deepcopy(self.confirmations),
                'sightings': [entry.result.model_dump() | {
                    'status': 'likely' if entry.matched else 'no_match', 'matched': entry.matched,
                    'observerPose': deepcopy(entry.pose), 'targetPosition': None, 'locationStatus': 'unknown'}
                    for entry in self.latest.values()]}
