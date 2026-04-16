# Hermes Agent Railway Template — v0.9.0
# Pinned to v2026.4.13 (Hermes v0.9.0) with Web Dashboard enabled
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source

FROM debian:13.4

ENV PYTHONUNBUFFERED=1
ENV HERMES_HOME=/data/.hermes
ENV HOME=/data
ENV MESSAGING_CWD=/data/workspace

# Store Playwright/agent-browser Chromium outside the volume so it survives
# the /data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# ---------------------------------------------------------------------------
# System dependencies
#
# Core tools:
#   curl wget git sudo          — network, VCS, privilege escalation
#   ca-certificates             — TLS trust store
#   build-essential gcc         — compile C extensions (e.g. cryptography)
#   python3 python3-dev         — Python runtime + headers
#   python3-pip                 — pip / pip3 for runtime package installs
#   python3-venv                — venv support
#   ripgrep                     — fast file search (hermes file tools)
#   ffmpeg                      — audio conversion for TTS (edge-tts → OGG)
#                                 and transcription (faster-whisper)
#   libffi-dev                  — cffi / cryptography build dep
#   procps                      — ps, kill, etc. (process management)
#   tini                        — PID-1 init / zombie reaping
#   nodejs npm                  — web dashboard Vite build + agent-browser
#   ssh openssh-client          — SSH terminal backend
#   jq                          — JSON parsing in shell scripts / skills
#   unzip zip                   — archive handling
#   less                        — pager used by some CLI tools
#   locales                     — UTF-8 locale for Python/Rich
# ---------------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl wget git sudo ca-certificates \
        build-essential gcc \
        python3 python3-dev python3-pip python3-venv \
        ripgrep ffmpeg \
        libffi-dev procps tini \
        nodejs npm \
        openssh-client ssh \
        jq unzip zip less \
        locales && \
    # Generate UTF-8 locale so Rich/Python don't fall back to ASCII
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen && \
    # Make pip3 available as pip (convenience + Hermes runtime installs)
    ln -sf /usr/bin/pip3 /usr/local/bin/pip && \
    # Allow the runtime user (root in Railway containers) to run sudo without
    # a password — Hermes uses sudo for package installs and Docker probing.
    echo "ALL ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/hermes-nopasswd && \
    chmod 0440 /etc/sudoers.d/hermes-nopasswd && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

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

# Make the venv's pip/pip3 globally accessible so Hermes can install
# packages at runtime without knowing the venv path.
RUN ln -sf /opt/hermes/.venv/bin/pip  /usr/local/bin/pip-hermes && \
    ln -sf /opt/hermes/.venv/bin/pip3 /usr/local/bin/pip3-hermes

# Patch CORS: allow all origins so Railway's public domain can reach the API.
# The default only allows localhost; we open it up for Railway deployment.
RUN sed -i \
    's|allow_origin_regex=r".*"|allow_origins=["*"]|g' \
    /opt/hermes/hermes_cli/web_server.py && \
    echo "CORS patch applied:" && \
    grep -n "allow_origin" /opt/hermes/hermes_cli/web_server.py | head -5

# Cache-bust: increment to force Railway to rebuild from this layer onward
ARG CACHE_BUST=v9

COPY scripts/entrypoint.sh /opt/hermes/scripts/entrypoint.sh
RUN chmod +x /opt/hermes/scripts/entrypoint.sh

# Note: Railway volumes are configured via Railway dashboard/API, not VOLUME directive
ENTRYPOINT ["tini", "--"]
CMD ["/opt/hermes/scripts/entrypoint.sh"]
