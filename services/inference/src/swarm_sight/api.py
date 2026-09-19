import asyncio
import secrets
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi import Query as QueryParam
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from PIL import Image
from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from swarm_sight.demo import add_demo_routes, authenticate_demo
from swarm_sight.images import decode_image
from swarm_sight.matching import Embedder
from swarm_sight.person_api import IMAGE_BODY, add_person_routes
from swarm_sight.schemas import BackendName, Detector, Query, Result
from swarm_sight.worker import Busy, Frame, Replaced, Worker


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SWARM_", env_file=".env", extra="ignore")
    api_key: SecretStr = Field(min_length=16)
    backend: BackendName = "yolo-world"
    device: str = "auto"
    model: str | None = None
    enable_reid: bool = False
    reid_model: str | None = None
    demo_code: SecretStr | None = Field(default=None, min_length=16, max_length=128)
    batch_size: int = Field(default=4, ge=1, le=32)
    queue_capacity: int = Field(default=64, ge=1, le=256)
    max_uploads: int = Field(default=64, ge=1, le=256)
    max_bytes: int = Field(default=2_000_000, ge=1, le=20_000_000)
    max_pixels: int = Field(default=4_000_000, ge=1, le=16_000_000)
    timeout_seconds: float = Field(default=30, gt=0, le=300)


def create_app(
    settings: Settings | None = None,
    detector: Detector | None = None,
    embedder: Embedder | None = None,
) -> FastAPI:
    settings = settings or Settings()
    if settings.enable_reid and settings.backend != "yoloe":
        raise ValueError("Person matching requires SWARM_BACKEND=yoloe")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        nonlocal detector, embedder
        if settings.enable_reid and embedder is None:
            from swarm_sight.osnet import OSNetEmbedder

            embedder = await asyncio.to_thread(
                OSNetEmbedder, device=settings.device, model_path=settings.reid_model
            )
        app.state.embedder = embedder
        app.state.targets = {}
        app.state.reid_jobs = set()
        app.state.reid_gate = asyncio.Lock()
        if detector is None:
            from swarm_sight.backends import load_detector

            detector = await asyncio.to_thread(
                load_detector, settings.backend, settings.device, settings.model
            )
            await asyncio.to_thread(
                detector.predict, [Image.new("RGB", (640, 640))], ("person",), 0.25
            )
        async with Worker(
            detector, capacity=settings.queue_capacity, batch_size=settings.batch_size
        ) as worker:
            app.state.worker = worker
            app.state.uploads = 0
            try:
                yield
            finally:
                await asyncio.gather(*app.state.reid_jobs, return_exceptions=True)

    app = FastAPI(title="Swarm Sight Inference", version="0.1.0", lifespan=lifespan)

    @app.get("/healthz")
    async def health():
        return {"status": "ok"}

    @app.get("/readyz")
    async def ready():
        worker = getattr(app.state, "worker", None)
        if worker is None or worker.closed or worker.task is None or worker.task.done():
            raise HTTPException(503, "Worker is not ready")
        return {"status": "ready", "backend": worker.detector.name, "pending": len(worker.pending)}

    bearer = HTTPBearer(auto_error=False)

    async def authenticate(
        request: Request,
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    ) -> None:
        if authenticate_demo(request, settings):
            return
        expected = "Bearer " + settings.api_key.get_secret_value()
        if credentials is None or not secrets.compare_digest(
            request.headers.get("authorization", "").encode(), expected.encode()
        ):
            raise HTTPException(401, "Invalid bearer token", headers={"WWW-Authenticate": "Bearer"})

    @asynccontextmanager
    async def upload(request: Request):
        content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type not in {"image/jpeg", "image/png"}:
            raise HTTPException(415, "Send a raw JPEG or PNG body")
        if app.state.uploads >= settings.max_uploads:
            raise HTTPException(429, "Too many requests", headers={"Retry-After": "1"})
        app.state.uploads += 1
        try:
            async with asyncio.timeout(settings.timeout_seconds):
                data = bytearray()
                async for chunk in request.stream():
                    if len(data) + len(chunk) > settings.max_bytes:
                        raise HTTPException(413, "Image upload is too large")
                    data.extend(chunk)
                try:
                    image = await asyncio.to_thread(decode_image, bytes(data), settings.max_pixels)
                except ValueError as error:
                    raise HTTPException(422, str(error)) from error
                yield image
        except Replaced as error:
            raise HTTPException(409, "Frame replaced by a newer pending frame") from error
        except Busy as error:
            raise HTTPException(429, str(error), headers={"Retry-After": "1"}) from error
        except TimeoutError as error:
            raise HTTPException(504, "Frame processing timed out") from error
        except HTTPException:
            raise
        except Exception as error:
            raise HTTPException(503, "Inference failed; retry a fresh frame") from error
        finally:
            app.state.uploads -= 1

    @app.post(
        "/v1/detect",
        response_model=Result,
        openapi_extra=IMAGE_BODY,
    )
    async def detect(
        request: Request,
        query: Annotated[Query, QueryParam()],
        _: Annotated[None, Depends(authenticate)],
    ):
        async with upload(request) as image:
            future = app.state.worker.submit(
                Frame(
                    f"detect:{query.phone_id}",
                    image,
                    tuple(dict.fromkeys(query.labels)),
                    query.confidence,
                )
            )
            outcome = await future
            return Result(
                phone_id=query.phone_id,
                frame_id=query.frame_id,
                captured_at=query.captured_at,
                backend=app.state.worker.detector.name,
                width=image.width,
                height=image.height,
                detections=outcome.detections,
                queue_ms=outcome.queue_ms,
                inference_ms=outcome.inference_ms,
            )

    add_person_routes(app, settings, authenticate, upload)
    add_demo_routes(app, settings)
    return app
