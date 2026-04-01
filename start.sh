#!/bin/bash
set -e

mkdir -p /data/.hermes/sessions
mkdir -p /data/.hermes/skills
mkdir -p /data/.hermes/workspace
mkdir -p /data/.hermes/pairing
mkdir -p /data/.hermes/logs

export PYTHONUNBUFFERED=1

# Debug: test Telegram token directly with curl
echo "=== TELEGRAM TOKEN DEBUG ==="
echo "Token length: ${#TELEGRAM_BOT_TOKEN}"
echo "Token first 15 chars: ${TELEGRAM_BOT_TOKEN:0:15}"
echo "Testing token with curl..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || echo "curl failed"
echo ""
echo "=== ENV FILE DEBUG ==="
cat /data/.hermes/.env 2>/dev/null || echo "No .env file found"
echo "=== END DEBUG ==="

# PATCH: Disable fallback transport that causes 401 on Railway
TELEGRAM_PY="/tmp/hermes-agent/gateway/platforms/telegram.py"
if [ -f "$TELEGRAM_PY" ]; then
    echo "=== PATCHING: Disabling Telegram fallback transport ==="
    sed -i 's/if fallback_ips:/if False:  # PATCHED: fallback disabled/' "$TELEGRAM_PY"
    echo "Patch applied"
fi

# Create a hermes wrapper that dumps gateway.log on crash
REAL_HERMES=$(which hermes)
cat > /usr/local/bin/hermes-wrapper << WEOF
#!/bin/bash
$REAL_HERMES "\$@"
EXIT_CODE=\$?
if [ \$EXIT_CODE -ne 0 ] && [ "\$1" = "gateway" ]; then
    echo "=== GATEWAY LOG FILE ==="
    cat /data/.hermes/logs/gateway.log 2>/dev/null || echo "No gateway.log found"
    echo "=== END GATEWAY LOG ==="
    find /data/.hermes -name "gateway_status*.json" -exec cat {} \; 2>/dev/null || true
fi
exit \$EXIT_CODE
WEOF
chmod +x /usr/local/bin/hermes-wrapper

# Replace hermes with our wrapper
mv /usr/local/bin/hermes /usr/local/bin/hermes-real 2>/dev/null || true
mv /usr/local/bin/hermes-wrapper /usr/local/bin/hermes

exec python /app/server.py
