#!/usr/bin/env python3
"""
Patch /opt/hermes/hermes_cli/web_server.py to:
1. Fix CORS to allow all origins
2. Add /v1/* proxy routes that forward to the aiohttp API server on port 8642
   This allows Manny (and any external client) to call Hermes via the single
   Railway public port without needing a second exposed port.
"""

WEB_SERVER = "/opt/hermes/hermes_cli/web_server.py"

with open(WEB_SERVER, "r", encoding="utf-8") as f:
    src = f.read()

# ── 1. CORS: allow all origins ──────────────────────────────────────────────
src = src.replace(
    'allow_origin_regex=r"^https?://(localhost|127\\.0\\.0\\.1)(:\\d+)?$"',
    'allow_origins=["*"]',
)

# ── 2. Add StreamingResponse + Response imports ──────────────────────────────
src = src.replace(
    "from fastapi.responses import FileResponse, JSONResponse",
    "from fastapi.responses import FileResponse, JSONResponse, StreamingResponse, Response",
)

# ── 3. Inject proxy routes before mount_spa() ───────────────────────────────
PROXY_BLOCK = '''
# ---------------------------------------------------------------------------
# /v1/* reverse proxy → Hermes aiohttp API server (port 8642)
#
# The Hermes API server (OpenAI-compatible) runs as a separate aiohttp process
# started by the gateway when API_SERVER_ENABLED=true.  Railway only exposes
# one public port (the dashboard), so we proxy /v1/* through FastAPI to make
# the API server reachable externally.
# ---------------------------------------------------------------------------
_API_SERVER_BASE = os.getenv("API_SERVER_INTERNAL_URL", "http://127.0.0.1:8642")

@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
async def proxy_v1(path: str, request: Request):
    """Proxy all /v1/* requests to the Hermes aiohttp API server."""
    import httpx
    target_url = f"{_API_SERVER_BASE}/v1/{path}"
    params = dict(request.query_params)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
            resp = await client.request(
                method=request.method,
                url=target_url,
                params=params,
                headers=headers,
                content=body,
            )
            # SSE / streaming: stream the response back
            if "text/event-stream" in resp.headers.get("content-type", ""):
                async def _stream():
                    async for chunk in resp.aiter_bytes():
                        yield chunk
                return StreamingResponse(
                    _stream(),
                    status_code=resp.status_code,
                    headers=dict(resp.headers),
                    media_type="text/event-stream",
                )
            return Response(
                content=resp.content,
                status_code=resp.status_code,
                headers=dict(resp.headers),
                media_type=resp.headers.get("content-type"),
            )
    except httpx.ConnectError:
        return JSONResponse(
            {"error": {"message": "Hermes API server is not running. Set API_SERVER_ENABLED=true.", "type": "server_error"}},
            status_code=503,
        )
    except Exception as exc:
        return JSONResponse(
            {"error": {"message": f"Proxy error: {exc}", "type": "server_error"}},
            status_code=502,
        )

'''

# Insert before mount_spa
src = src.replace(
    "def mount_spa(application: FastAPI):",
    PROXY_BLOCK + "def mount_spa(application: FastAPI):",
)

with open(WEB_SERVER, "w", encoding="utf-8") as f:
    f.write(src)

print("✅ web_server.py patched successfully")
print("   - CORS: allow all origins")
print("   - Added StreamingResponse, Response imports")
print("   - Added /v1/* proxy routes → http://127.0.0.1:8642")
