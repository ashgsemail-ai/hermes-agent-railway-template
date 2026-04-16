#!/usr/bin/env bash
# Hermes Agent Railway Entrypoint — v0.9.0
# Starts the Web Dashboard on Railway's public PORT and the gateway in background.
# CACHE_BUST: 20260416-8
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
# Remove the open-brain-monitoring skill if it exists on the volume.
# This skill uses the legacy 'from hermes_tools import ...' API that no
# longer exists in Hermes v0.9.0. It causes crash loops every 30 minutes
# AND corrupts config.yaml via save_config() calls during failed sessions.
# ---------------------------------------------------------------------------
OBM_SKILL="${HERMES_HOME}/skills/open-brain-monitoring"
if [[ -d "${OBM_SKILL}" ]]; then
    echo "[bootstrap] Removing stale open-brain-monitoring skill (incompatible with v0.9.0)..."
    rm -rf "${OBM_SKILL}"
fi

# Also remove any cron jobs that reference open-brain-monitoring
if [[ -d "${HERMES_HOME}/cron" ]]; then
    find "${HERMES_HOME}/cron" -type f -name "*.yaml" -o -name "*.json" 2>/dev/null | while read -r cronfile; do
        if grep -q "open-brain-monitoring\|open_brain_monitoring\|hermes_tools" "${cronfile}" 2>/dev/null; then
            echo "[bootstrap] Removing stale cron job: ${cronfile}"
            rm -f "${cronfile}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Bootstrap .env — write runtime secrets into HERMES_HOME/.env
# NOTE: Do NOT include LLM_MODEL here — Hermes v0.9.0 treats it as a dead
# variable and DELETES it from .env during config migration (v12→v13).
# Model is set exclusively via config.yaml model.default below.
# ---------------------------------------------------------------------------
echo "[bootstrap] Writing runtime env to ${ENV_FILE}"
{
    echo "# Managed by entrypoint.sh — do not edit manually"
    echo "HERMES_HOME=${HERMES_HOME}"
    echo "MESSAGING_CWD=${MESSAGING_CWD}"
} > "${ENV_FILE}"

# Append secrets — deliberately EXCLUDE LLM_MODEL (dead var in v0.9.0)
env | grep -E "^(OPENROUTER_API_KEY|TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS|TELEGRAM_HOME_CHANNEL|ADMIN_PASSWORD)" >> "${ENV_FILE}" || true

# ---------------------------------------------------------------------------
# Bootstrap config.yaml — ALWAYS delete and rewrite on startup.
#
# Why always delete (not just overwrite):
#   - The /data volume may have a corrupt config.yaml from a previous failed
#     deployment (YAML parse error at line 146).
#   - Hermes calls save_config() during sessions, which can re-corrupt the
#     file if it merges in-memory state with a bad base.
#   - Deleting ensures a clean 100% known-good file every boot.
#
# Key settings:
#   - model.default: the model name passed to OpenRouter
#   - model.provider: must be "openrouter" (not "auto") for google/ models
#   - _config_version: 17 — matches DEFAULT_CONFIG version, prevents migration
#     from running and potentially clearing our settings
# ---------------------------------------------------------------------------
_MODEL="${LLM_MODEL:-google/gemini-2.5-flash}"
_PROVIDER="${HERMES_INFERENCE_PROVIDER:-openrouter}"

echo "[bootstrap] Writing config.yaml: model=${_MODEL}, provider=${_PROVIDER}"

# Always delete first to avoid any stale/corrupt content
rm -f "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" << EOC
# Hermes Agent config — managed by Railway entrypoint.sh
# Deleted and rewritten on every restart to ensure correctness.
_config_version: 17

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

echo "[bootstrap] config.yaml written ($(wc -l < "${CONFIG_FILE}") lines)."
echo "[bootstrap] Model config: $(grep 'default:' "${CONFIG_FILE}")"

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
