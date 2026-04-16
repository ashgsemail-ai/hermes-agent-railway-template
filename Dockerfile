# Hermes Agent Railway Template — v0.9.0
# Pinned to v2026.4.13 (Hermes v0.9.0) with Web Dashboard enabled
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source

FROM debian:13.4

ENV PYTHONUNBUFFERED=1
ENV HERMES_HOME=/data/.hermes
ENV HOME=/data
ENV MESSAGING_CWD=/data/workspace

# System dependencies: nodejs/npm required for the web UI build step
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev \
        libffi-dev procps git ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

COPY --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# Pin to Hermes v0.9.0 (tag v2026.4.13)
ARG HERMES_GIT_REF=v2026.4.13

RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" \
        https://github.com/NousResearch/hermes-agent.git .

# Build the Vite/React web dashboard frontend → hermes_cli/web_dist/
# (vite.config.ts sets outDir: "../hermes_cli/web_dist")
RUN cd web && npm install --prefer-offline --no-audit && npm run build

# Install Python deps including [web] extras (fastapi + uvicorn for dashboard)
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[messaging,cron,cli,pty,web]"

# Patch CORS: allow all origins so Railway's public domain can reach the API.
# The default only allows localhost; we open it up for Railway deployment.
RUN sed -i \
    's|allow_origin_regex=r".*"|allow_origins=["*"]|g' \
    /opt/hermes/hermes_cli/web_server.py && \
    echo "CORS patch applied:" && \
    grep -n "allow_origin" /opt/hermes/hermes_cli/web_server.py | head -5

# Cache-bust: increment to force Railway to rebuild from this layer onward
ARG CACHE_BUST=v7

COPY scripts/entrypoint.sh /opt/hermes/scripts/entrypoint.sh
RUN chmod +x /opt/hermes/scripts/entrypoint.sh

# Note: Railway volumes are configured via Railway dashboard/API, not VOLUME directive
ENTRYPOINT ["tini", "--"]
CMD ["/opt/hermes/scripts/entrypoint.sh"]
