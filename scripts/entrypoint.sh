#!/usr/bin/env bash
# Hermes Agent Railway Entrypoint — v0.9.0
# Starts the Web Dashboard on Railway's public PORT and the gateway in background.
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
export MESSAGING_CWD="${MESSAGING_CWD:-/data/workspace}"

INIT_MARKER="${HERMES_HOME}/.initialized"
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

# Activate the venv
source "/opt/hermes/.venv/bin/activate"

# ---------------------------------------------------------------------------
# Bootstrap .env — write runtime secrets into HERMES_HOME/.env
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
# Bootstrap config.yaml — set model, provider, and terminal settings
# ---------------------------------------------------------------------------
echo "[bootstrap] Configuring Hermes v0.9 (model: ${LLM_MODEL:-arcee-ai/trinity-large-thinking})..."

if [[ -f "${CONFIG_FILE}" ]]; then
    # Update model.default in-place using Python (preserves all other user settings)
    python3 - <<PYEOF
import yaml, os
cfg_path = os.environ['CONFIG_FILE']
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}
if 'model' not in cfg:
    cfg['model'] = {}
cfg['model']['default'] = os.environ.get('LLM_MODEL', 'arcee-ai/trinity-large-thinking')
cfg['model']['provider'] = os.environ.get('HERMES_INFERENCE_PROVIDER', 'openrouter')
cfg['model']['base_url'] = 'https://openrouter.ai/api/v1'
with open(cfg_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print(f"[config-fix] Set model={cfg['model']['default']}")
PYEOF
else
    # First run — write a clean config
    cat > "${CONFIG_FILE}" <<EOC
model:
  default: "${LLM_MODEL:-arcee-ai/trinity-large-thinking}"
  provider: "${HERMES_INFERENCE_PROVIDER:-openrouter}"
  base_url: "https://openrouter.ai/api/v1"

terminal:
  backend: "local"
  cwd: "${MESSAGING_CWD}"
  timeout: 180

compression:
  enabled: true
  threshold: 0.85
EOC
    echo "[config-fix] Set model=${LLM_MODEL:-arcee-ai/trinity-large-thinking}"
fi

# ---------------------------------------------------------------------------
# First-time initialization marker
# ---------------------------------------------------------------------------
if [[ ! -f "${INIT_MARKER}" ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${INIT_MARKER}"
    echo "[bootstrap] First-time initialization completed."
else
    echo "[bootstrap] Existing Hermes data found. Skipping one-time init."
fi

# ---------------------------------------------------------------------------
# Start the Web Dashboard on Railway's public PORT
# The dashboard serves the Vite/React SPA + REST API for config management.
# Railway routes external HTTPS traffic to $PORT (default 8080).
# ---------------------------------------------------------------------------
DASHBOARD_PORT="${PORT:-8080}"
echo "[bootstrap] Starting Hermes Web Dashboard on 0.0.0.0:${DASHBOARD_PORT}..."
hermes dashboard --host 0.0.0.0 --port "${DASHBOARD_PORT}" --no-open &
DASHBOARD_PID=$!
echo "[bootstrap] Dashboard PID: ${DASHBOARD_PID}"

# Give the dashboard a moment to bind before starting the gateway
sleep 2

# ---------------------------------------------------------------------------
# Start the Hermes Gateway (Telegram + cron scheduler) in the foreground.
# tini (PID 1) will reap the dashboard subprocess when the gateway exits.
# ---------------------------------------------------------------------------
echo "[bootstrap] Starting Hermes gateway (Telegram + cron)..."
exec hermes gateway
