"""Bounded reference lifecycle and appearance matching HTTP endpoints."""

import asyncio
from collections.abc import Awaitable, Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from time import perf_counter
from typing import TYPE_CHECKING, Annotated
from uuid import uuid4

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi import Query as QueryParam
from fastapi.security import HTTPAuthorizationCredentials
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field

from swarm_sight.matching import Embedder, normalize_embedding, rank_candidates, select_reference
from swarm_sight.schemas import Identifier
from swarm_sight.worker import Frame

if TYPE_CHECKING:
    from swarm_sight.api import Settings


class MatchQuery(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    target_id: Identifier
    phone_id: Identifier
    frame_id: Identifier
    captured_at: float = Field(ge=0)
    confidence: float = Field(default=0.25, ge=0.01, le=1)
    similarity_threshold: float = Field(ge=-1, le=1)


@dataclass(frozen=True)
class Target:
    version: str
    embedding: tuple[float, ...]


IMAGE_BODY = {
    "requestBody": {
        "required": True,
        "content": {
            kind: {"schema": {"type": "string", "format": "binary"}}
            for kind in ("image/jpeg", "image/png")
        },
    }
}


def add_person_routes(
    app: FastAPI,
    settings: "Settings",
    authenticate: Callable[[Request, HTTPAuthorizationCredentials | None], Awaitable[None]],
    upload: Callable[[Request], AbstractAsyncContextManager[Image.Image]],
) -> None:
    def require_enabled() -> Embedder:
        if not settings.enable_reid or app.state.embedder is None:
            raise HTTPException(503, "Person matching is disabled")
        return app.state.embedder

    async def encode_bounded[T](operation: Callable[[], T]) -> T:
        # Cancellation keeps the active model slot held until its thread really finishes.
        jobs: set[asyncio.Task] = app.state.reid_jobs
        await app.state.reid_gate.acquire()
        task = asyncio.create_task(asyncio.to_thread(operation))
        jobs.add(task)

        def finished(completed: asyncio.Task[T]) -> None:
            jobs.discard(completed)
            app.state.reid_gate.release()
            if not completed.cancelled():
                completed.exception()

        task.add_done_callback(finished)
        return await asyncio.shield(task)

    @app.put("/v1/targets/{target_id}", openapi_extra=IMAGE_BODY)
    async def register(
        target_id: Identifier,
        request: Request,
        _: Annotated[None, Depends(authenticate)],
        box: Annotated[list[float] | None, QueryParam(min_length=4, max_length=4)] = None,
    ):
        embedder = require_enabled()
        targets: dict[str, Target] = app.state.targets
        if target_id not in targets and len(targets) >= 32:
            raise HTTPException(429, "Reference target capacity is full")
        async with upload(request) as image:
            detections = []
            if box is None:
                outcome = await app.state.worker.submit(
                    Frame(f"reference:{uuid4()}", image, ("person",), 0.25)
                )
                detections = outcome.detections
            try:
                crop = select_reference(image, detections, box)
            except ValueError as error:
                raise HTTPException(422, str(error)) from error

            def encode_reference() -> tuple[float, ...]:
                embeddings = embedder.encode([crop])
                if len(embeddings) != 1:
                    raise ValueError("Embedder returned an incorrect batch length")
                return normalize_embedding(embeddings[0])

            embedding = await encode_bounded(encode_reference)
            # Registration can race across awaits; capacity is checked again at insertion.
            if target_id not in targets and len(targets) >= 32:
                raise HTTPException(429, "Reference target capacity is full")
            target = Target(str(uuid4()), embedding)
            targets[target_id] = target
            return {"target_id": target_id, "target_version": target.version}

    @app.delete("/v1/targets/{target_id}", status_code=204)
    async def delete(target_id: Identifier, _: Annotated[None, Depends(authenticate)]):
        require_enabled()
        if app.state.targets.pop(target_id, None) is None:
            raise HTTPException(404, "Reference target was not found")
        return Response(status_code=204)

    @app.post("/v1/match", openapi_extra=IMAGE_BODY)
    async def match(
        request: Request,
        query: Annotated[MatchQuery, QueryParam()],
        _: Annotated[None, Depends(authenticate)],
    ):
        embedder = require_enabled()
        target: Target | None = app.state.targets.get(query.target_id)
        if target is None:
            raise HTTPException(404, "Reference target was not found")
        # The immutable snapshot is captured before uploading or scheduling model work.
        async with upload(request) as image:
            outcome = await app.state.worker.submit(
                Frame(f"match:{query.phone_id}", image, ("person",), query.confidence)
            )
            started = perf_counter()
            summary = await encode_bounded(
                lambda: rank_candidates(
                    image,
                    outcome.detections,
                    target.embedding,
                    embedder,
                    query.similarity_threshold,
                )
            )
            return {
                "target_id": query.target_id,
                "target_version": target.version,
                "phone_id": query.phone_id,
                "frame_id": query.frame_id,
                "captured_at": query.captured_at,
                "backend": app.state.worker.detector.name,
                "width": image.width,
                "height": image.height,
                "queue_ms": outcome.queue_ms,
                "inference_ms": outcome.inference_ms,
                "matching_ms": (perf_counter() - started) * 1000,
                **summary.model_dump(),
            }
