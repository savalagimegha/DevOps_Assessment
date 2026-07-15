# =========================================================================
# Dockerfile - Production-ready multi-stage build for the Flask application
# =========================================================================
# Stage 1: "builder" - install dependencies into an isolated prefix so the
#          final runtime image never contains build tools or caches.
# Stage 2: "runtime" - minimal slim image, non-root user, healthcheck.
# =========================================================================

# ---------------------------
# Stage 1: Builder
# ---------------------------
FROM python:3.12-slim AS builder

# Prevent Python from writing .pyc files / buffering stdout, speeds up builds
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Install only what's needed to build wheels (kept out of final image)
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

# Leverage Docker layer caching: copy requirements first
COPY requirements.txt .

# Build wheels for all dependencies into /build/wheels
RUN pip install --upgrade "pip>=26.0" \
    && pip wheel --wheel-dir /build/wheels -r requirements.txt

# ---------------------------
# Stage 2: Runtime
# ---------------------------
FROM python:3.12-slim AS runtime

LABEL maintainer="devops-team@example.com" \
      description="Production Flask service" \
      org.opencontainers.image.source="https://github.com/example/devops-assessment"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_HOME=/app \
    PORT=5000

WORKDIR ${APP_HOME}

# Install curl only for the HEALTHCHECK, then clean apt cache to keep image small
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Create a dedicated non-root user/group
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid appgroup --shell /bin/false --create-home appuser

# Copy pre-built wheels from the builder stage and install them (no compiler needed here)
COPY --from=builder /build/wheels /wheels
COPY requirements.txt .
RUN pip install --upgrade "pip>=26.0" \
    && pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels requirements.txt

# Copy application source last (changes most often -> keeps layers cache-friendly)
COPY --chown=appuser:appgroup app.py .

# Drop privileges
USER appuser

EXPOSE 5000

# Container-level healthcheck used by Docker / orchestrators that support it
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Gunicorn as the production WSGI server: 2 workers is a sane default for small services
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "2", "--timeout", "30", "app:app"]
