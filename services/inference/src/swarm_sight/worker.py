import asyncio
import logging
from collections import OrderedDict
from dataclasses import dataclass
from time import perf_counter
from types import TracebackType

from PIL import Image

from swarm_sight.schemas import Detection, Detector

logger = logging.getLogger(__name__)


class Busy(Exception):
    pass


class Replaced(Exception):
    pass


@dataclass
class Frame:
    phone_id: str
    image: Image.Image
    labels: tuple[str, ...]
    confidence: float


@dataclass
class Outcome:
    detections: list[Detection]
    queue_ms: float
    inference_ms: float


@dataclass
class Pending:
    frame: Frame
    future: asyncio.Future[Outcome]
    submitted: float


class Worker:
    def __init__(
        self,
        detector: Detector,
        capacity: int = 64,
        batch_size: int = 4,
        batch_wait: float = 0.01,
    ):
        self.detector = detector
        self.capacity = capacity
        self.batch_size = batch_size
        self.batch_wait = batch_wait
        self.pending: OrderedDict[str, Pending] = OrderedDict()
        self.wake = asyncio.Event()
        self.closed = False
        self.task: asyncio.Task[None] | None = None

    async def __aenter__(self) -> "Worker":
        self.task = asyncio.create_task(self.run())
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.closed = True
        for item in self.pending.values():
            if not item.future.done():
                item.future.set_exception(Busy("Worker is shutting down"))
        self.pending.clear()
        self.wake.set()
        if self.task:
            await self.task

    def submit(self, frame: Frame) -> asyncio.Future[Outcome]:
        if self.closed:
            raise Busy("Worker is shutting down")
        for key, item in list(self.pending.items()):
            if item.future.done():
                del self.pending[key]
        if frame.phone_id not in self.pending and len(self.pending) >= self.capacity:
            raise Busy("Inference queue is full")
        old = self.pending.get(frame.phone_id)
        if old and not old.future.done():
            old.future.set_exception(Replaced("A newer frame replaced this pending frame"))
        future = asyncio.get_running_loop().create_future()
        # Preserve each phone's queue position so frequent senders cannot starve other phones.
        self.pending[frame.phone_id] = Pending(frame, future, perf_counter())
        phone_id = frame.phone_id
        future.add_done_callback(lambda completed: self.remove_done(phone_id, completed))
        self.wake.set()
        return future

    def remove_done(self, phone_id: str, future: asyncio.Future[Outcome]) -> None:
        current = self.pending.get(phone_id)
        if current is not None and current.future is future:
            del self.pending[phone_id]

    async def run(self) -> None:
        while not self.closed:
            await self.wake.wait()
            self.wake.clear()
            if self.batch_wait:
                await asyncio.sleep(self.batch_wait)
            while self.pending and not self.closed:
                await self.process_batch()

    async def process_batch(self) -> None:
        batch: list[Pending] = []
        for key, item in list(self.pending.items()):
            if item.future.done():
                del self.pending[key]
                continue
            if batch and (item.frame.labels, item.frame.confidence) != (
                batch[0].frame.labels,
                batch[0].frame.confidence,
            ):
                continue
            batch.append(self.pending.pop(key))
            if len(batch) == self.batch_size:
                break
        if not batch:
            return
        started = perf_counter()
        try:
            results = await asyncio.to_thread(
                self.detector.predict,
                [item.frame.image for item in batch],
                batch[0].frame.labels,
                batch[0].frame.confidence,
            )
            if len(results) != len(batch):
                raise RuntimeError("Detector returned an incorrect batch length")
            elapsed = (perf_counter() - started) * 1000
            for item, detections in zip(batch, results, strict=True):
                if not item.future.done():
                    item.future.set_result(
                        Outcome(detections, (started - item.submitted) * 1000, elapsed)
                    )
        except Exception as error:
            logger.exception("Inference batch failed")
            for item in batch:
                if not item.future.done():
                    item.future.set_exception(error)
