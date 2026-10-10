# syntax=docker/dockerfile:1

# ---- build stage: validate and byte-compile the source ----
FROM python:3.12.7-slim-bookworm AS builder
WORKDIR /build
COPY app.py .
RUN python -m py_compile app.py \
 && python -c "import app" \
 && python -m compileall -q .

# ---- runtime stage: minimal image, non-root ----
FROM python:3.12.7-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    APP_NAME=demo \
    VERSION=0.0.0

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=app:app /build/app.py /build/__pycache__ ./

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status == 200 else 1)"]

CMD ["python", "app.py"]
