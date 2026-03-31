#!/bin/bash
set -e

mkdir -p /data/.hermes/sessions
mkdir -p /data/.hermes/skills
mkdir -p /data/.hermes/workspace
mkdir -p /data/.hermes/pairing
mkdir -p /data/.hermes/logs

export PYTHONUNBUFFERED=1

# Force all Python logging to also go to stdout so server.py can capture it
cat > /tmp/_force_console_logging.py << 'PYEOF'
import logging, sys
_h = logging.StreamHandler(sys.stdout)
_h.setLevel(logging.DEBUG)
_h.setFormatter(logging.Formatter('%(asctime)s %(name)s %(levelname)s: %(message)s'))
logging.getLogger().addHandler(_h)
logging.getLogger().setLevel(logging.DEBUG)
PYEOF

export PYTHONPATH="/tmp:${PYTHONPATH}"

exec python /app/server.py
