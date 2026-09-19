FROM python:3.12-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:0.12.9 /uv /usr/local/bin/uv
RUN apt-get update && apt-get install -y --no-install-recommends git libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --extra yolo --extra reid --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --extra yolo --extra reid --no-dev \
    && useradd --uid 1000 --create-home swarm \
    && mkdir /data && chown swarm:swarm /data
ENV PATH="/app/.venv/bin:$PATH" \
    HF_HOME=/data/huggingface \
    SWARM_MODEL_CACHE=/data/models \
    YOLO_CONFIG_DIR=/data/ultralytics \
    SWARM_DEVICE=cuda:0 \
    PYTHONUNBUFFERED=1
USER swarm
WORKDIR /data
EXPOSE 8001
HEALTHCHECK --interval=30s --timeout=3s --start-period=300s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/readyz', timeout=2)"
CMD ["beacon", "serve", "--host", "0.0.0.0"]
