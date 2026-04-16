#!/usr/bin/env bash
# Hermes Agent Railway Entrypoint — v0.9.0
# Starts the Web Dashboard on Railway's public PORT and the gateway in background.
# CACHE_BUST: 20260416-6
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
export MESSAGING_CWD="${MESSAGING_CWD:-/data/workspace}"

ENV_FILE="${HERMES_HOME}/.env"
CONFIG_FILE="${HERMES_HOME}/config.yaml"

# Create required directories
mkdir -p \
    "${HERMES_HOME}" \
    "${HERMES_HOME}/logs" \
    "${HERMES_HOME}/sessions" \
    "${HERMES_HOME}/cron" \
    "${HERMES_HOME}/pairing" \
    "${HERMES_HOME}/memories" \
    "${HERMES_HOME}/skills" \
    "${HERMES_HOME}/hooks" \
    "${MESSAGING_CWD}"

# ---------------------------------------------------------------------------
# Activate the venv FIRST — all subsequent python/hermes calls use it
# ---------------------------------------------------------------------------
source "/opt/hermes/.venv/bin/activate"

# ---------------------------------------------------------------------------
# Bootstrap .env — write runtime secrets into HERMES_HOME/.env
# This file is read by hermes gateway at startup.
# ---------------------------------------------------------------------------
echo "[bootstrap] Writing runtime env to ${ENV_FILE}"
{
    echo "# Managed by entrypoint.sh — do not edit manually"
    echo "HERMES_HOME=${HERMES_HOME}"
    echo "MESSAGING_CWD=${MESSAGING_CWD}"
} > "${ENV_FILE}"

# Append all relevant env vars (Telegram, OpenRouter, etc.)
env | grep -E "^(OPENROUTER_API_KEY|TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS|TELEGRAM_HOME_CHANNEL|LLM_MODEL|HERMES_INFERENCE_PROVIDER|ADMIN_PASSWORD)" >> "${ENV_FILE}" || true

# ---------------------------------------------------------------------------
# Bootstrap config.yaml — ALWAYS rewrite on startup to guarantee correct
# model and provider are set. This prevents stale/corrupt config from a
# previous deployment on the /data volume from causing "No models provided"
# errors or other LLM call failures.
# ---------------------------------------------------------------------------
_MODEL="${LLM_MODEL:-arcee-ai/trinity-large-thinking}"
_PROVIDER="${HERMES_INFERENCE_PROVIDER:-openrouter}"

echo "[bootstrap] Writing config.yaml: model=${_MODEL}, provider=${_PROVIDER}"

# Write a clean config.yaml — matches the exact format from cli-config.yaml.example
cat > "${CONFIG_FILE}" << EOC
# Hermes Agent config — managed by Railway entrypoint.sh
# Do not edit manually; changes will be overwritten on restart.
model:
  default: "${_MODEL}"
  provider: "${_PROVIDER}"
  base_url: "https://openrouter.ai/api/v1"

terminal:
  backend: "local"
  cwd: "${MESSAGING_CWD}"
  timeout: 180

compression:
  enabled: true
  threshold: 0.85
EOC

echo "[bootstrap] config.yaml written successfully."

# ---------------------------------------------------------------------------
# Start the Web Dashboard on Railway's public PORT
#
# We call uvicorn directly on hermes_cli.web_server:app rather than
# 'hermes dashboard' — this bypasses the _build_web_ui() npm check that
# runs at startup and would delay binding past Railway's 60s health check.
# The web_dist/ was already built during the Docker build step.
# ---------------------------------------------------------------------------
DASHBOARD_PORT="${PORT:-8080}"
HERMES_MODULE_DIR="/opt/hermes"

echo "[bootstrap] Starting Hermes Web Dashboard on 0.0.0.0:${DASHBOARD_PORT}..."
cd "${HERMES_MODULE_DIR}"
python -m uvicorn hermes_cli.web_server:app \
    --host 0.0.0.0 \
    --port "${DASHBOARD_PORT}" \
    --log-level warning &
DASHBOARD_PID=$!
echo "[bootstrap] Dashboard PID: ${DASHBOARD_PID}"

# Give the dashboard a moment to bind before starting the gateway
sleep 3

# Verify dashboard is up
if kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
    echo "[bootstrap] Dashboard is running."
else
    echo "[bootstrap] WARNING: Dashboard process exited early."
fi

# ---------------------------------------------------------------------------
# Start the Hermes Gateway (Telegram + cron scheduler) in the foreground.
# tini (PID 1) will reap the dashboard subprocess when the gateway exits.
# ---------------------------------------------------------------------------
echo "[bootstrap] Starting Hermes gateway (Telegram + cron)..."
exec hermes gateway
