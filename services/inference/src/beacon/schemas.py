from typing import Annotated, Literal, Protocol

from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

BackendName = Literal["yolo-world", "yoloe", "sam3"]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
Identifier = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_.:-]{1,128}$")]


class Query(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    phone_id: Identifier
    frame_id: Identifier
    captured_at: float = Field(ge=0)
    labels: list[Label] = Field(min_length=1, max_length=16)
    confidence: float = Field(default=0.25, ge=0.01, le=1)


class Detection(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    label: str
    score: float = Field(ge=0, le=1)
    box: tuple[float, float, float, float]


class Result(BaseModel):
    phone_id: str
    frame_id: str
    captured_at: float
    backend: str
    width: int
    height: int
    detections: list[Detection]
    queue_ms: float
    inference_ms: float


class Detector(Protocol):
    name: str

    def predict(
        self, images: list[Image.Image], labels: tuple[str, ...], confidence: float
    ) -> list[list[Detection]]: ...
