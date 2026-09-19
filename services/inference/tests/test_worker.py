import asyncio
import threading

import pytest
from PIL import Image

from swarm_sight.schemas import Detection
from swarm_sight.worker import Busy, Frame, Replaced, Worker


def frame(phone, labels=("toy",)):
    return Frame(phone, Image.new("RGB", (20, 20)), labels, 0.2)


class ControlledDetector:
    name = "controlled"

    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = []

    def predict(self, images, labels, confidence):
        self.calls.append((len(images), labels))
        self.started.set()
        if not self.release.wait(3):
            raise TimeoutError("test failed to release detector")
        return [[Detection(label=labels[0], score=0.9, box=(0, 0, 10, 10))] for _ in images]


async def test_replaces_pending_phone_and_bounds_queue():
    detector = ControlledDetector()
    async with Worker(detector, capacity=2, batch_size=2, batch_wait=0) as worker:
        active = worker.submit(frame("active"))
        assert await asyncio.to_thread(detector.started.wait, 2)
        old = worker.submit(frame("a"))
        latest = worker.submit(frame("a"))
        other = worker.submit(frame("b"))
        with pytest.raises(Replaced):
            await old
        with pytest.raises(Busy):
            worker.submit(frame("c"))
        detector.release.set()
        assert len((await active).detections) == 1
        assert (await latest).detections[0].label == "toy"
        await other
        assert detector.calls == [(1, ("toy",)), (2, ("toy",))]


async def test_batches_only_matching_prompts_and_drops_cancelled_frames():
    detector = ControlledDetector()
    detector.release.set()
    async with Worker(detector, batch_size=4, batch_wait=0.01) as worker:
        toy = worker.submit(frame("a"))
        bag = worker.submit(frame("b", ("bag",)))
        cancelled = worker.submit(frame("c"))
        cancelled.cancel()
        assert (await toy).detections[0].label == "toy"
        assert (await bag).detections[0].label == "bag"
        assert detector.calls == [(1, ("toy",)), (1, ("bag",))]


async def test_worker_recovers_after_failed_batch():
    class OnceBroken:
        name = "test"
        failed = False

        def predict(self, images, labels, confidence):
            if not self.failed:
                self.failed = True
                raise RuntimeError("broken")
            return [[] for _ in images]

    async with Worker(OnceBroken(), batch_wait=0) as worker:
        with pytest.raises(RuntimeError, match="broken"):
            await worker.submit(frame("a"))
        assert (await worker.submit(frame("b"))).detections == []


async def test_idle_worker_releases_image_references():
    import gc
    import weakref

    detector = ControlledDetector()
    detector.release.set()
    async with Worker(detector, batch_wait=0) as worker:
        item = frame("a")
        reference = weakref.ref(item.image)
        future = worker.submit(item)
        del item
        await future
        await asyncio.sleep(0)
        gc.collect()
        assert reference() is None


async def test_cancelled_pending_frame_is_released_during_active_inference():
    import gc
    import weakref

    detector = ControlledDetector()
    async with Worker(detector, batch_wait=0) as worker:
        active = worker.submit(frame("active"))
        assert await asyncio.to_thread(detector.started.wait, 2)
        queued = frame("waiting")
        reference = weakref.ref(queued.image)
        waiting = worker.submit(queued)
        del queued
        waiting.cancel()
        await asyncio.sleep(0)
        gc.collect()
        try:
            assert reference() is None
        finally:
            detector.release.set()
            await active


async def test_shutdown_finishes_active_batch_and_rejects_pending_frames():
    detector = ControlledDetector()
    worker = await Worker(detector, batch_wait=0).__aenter__()
    active = worker.submit(frame("active"))
    assert await asyncio.to_thread(detector.started.wait, 2)
    waiting = worker.submit(frame("waiting"))
    shutdown = asyncio.create_task(worker.__aexit__(None, None, None))
    await asyncio.sleep(0)
    try:
        with pytest.raises(Busy):
            await waiting
        with pytest.raises(Busy):
            worker.submit(frame("late"))
        assert not shutdown.done()
    finally:
        detector.release.set()
        await shutdown
    assert (await active).detections[0].label == "toy"
    assert worker.task.done()
