#!/usr/bin/env python3
"""
hermy_bridge.py — Manny ↔ Hermy API Bridge
============================================
Allows Manny (Manus AI) to communicate with Hermy (Hermes Agent on Railway)
programmatically via the OpenAI-compatible HTTP API.

Usage
-----
    # One-shot query (simplest):
    python hermy_bridge.py "What is the capital of France?"

    # With session continuity (multi-turn conversation):
    python hermy_bridge.py --session my-session "Remember: my name is Manny"
    python hermy_bridge.py --session my-session "What is my name?"

    # Streaming (print tokens as they arrive):
    python hermy_bridge.py --stream "Write a haiku about AI agents"

    # Use /v1/runs endpoint (async, SSE events):
    python hermy_bridge.py --runs "Search the web for latest AI news"

    # Import as a module:
    from hermy_bridge import HermyBridge
    bridge = HermyBridge()
    response = bridge.chat("Hello Hermy!")
    print(response)

API Endpoints (all proxied through the Railway dashboard port)
--------------------------------------------------------------
    POST /v1/chat/completions  — OpenAI-compatible, blocking
    POST /v1/responses         — OpenAI Responses API format, blocking
    POST /v1/runs              — Async run (returns run_id immediately)
    GET  /v1/runs/{id}/events  — SSE stream of agent lifecycle events
    GET  /v1/models            — List available models
    GET  /v1/health            — Health check
    GET  /api/jobs             — List cron jobs
    POST /api/jobs             — Create cron job

Authentication
--------------
    All /v1/* requests require:
        Authorization: Bearer <API_SERVER_KEY>
    The default key is: hermy-api-manny-2026
    Set HERMY_API_KEY env var or pass api_key= to HermyBridge() to override.
"""

import json
import os
import sys
import time
import uuid
from typing import Iterator, Optional

try:
    import requests
except ImportError:
    print("Installing requests...")
    import subprocess
    subprocess.run([sys.executable, "-m", "pip", "install", "requests"], check=True)
    import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HERMY_BASE_URL = os.getenv(
    "HERMY_BASE_URL",
    "https://hermes-railway-template-production.up.railway.app",
)
HERMY_API_KEY = os.getenv("HERMY_API_KEY", "hermy-api-manny-2026")
DEFAULT_TIMEOUT = 300  # seconds — agent runs can take a while


class HermyBridge:
    """
    Client for communicating with Hermy (Hermes Agent on Railway).

    Parameters
    ----------
    base_url : str
        The Railway public URL of the Hermes deployment.
    api_key : str
        The API_SERVER_KEY set on the Railway service.
    timeout : int
        Request timeout in seconds.
    """

    def __init__(
        self,
        base_url: str = HERMY_BASE_URL,
        api_key: str = HERMY_API_KEY,
        timeout: int = DEFAULT_TIMEOUT,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })

    # ------------------------------------------------------------------
    # Health / status
    # ------------------------------------------------------------------

    def health(self) -> dict:
        """Check if the Hermes API server is reachable and healthy."""
        resp = self._session.get(f"{self.base_url}/v1/health", timeout=10)
        resp.raise_for_status()
        return resp.json()

    def status(self) -> dict:
        """Get the full gateway status (no auth required)."""
        resp = self._session.get(f"{self.base_url}/api/status", timeout=10)
        resp.raise_for_status()
        return resp.json()

    # ------------------------------------------------------------------
    # Chat Completions (OpenAI-compatible, blocking)
    # ------------------------------------------------------------------

    def chat(
        self,
        message: str,
        history: Optional[list] = None,
        system_prompt: Optional[str] = None,
        session_id: Optional[str] = None,
        stream: bool = False,
    ) -> str:
        """
        Send a message to Hermy and return the response text.

        Parameters
        ----------
        message : str
            The user message to send.
        history : list, optional
            Previous conversation messages as [{"role": "user"|"assistant", "content": "..."}].
        system_prompt : str, optional
            An ephemeral system prompt layered on top of Hermy's core prompt.
        session_id : str, optional
            Continue an existing session by ID (requires API_SERVER_KEY).
        stream : bool
            If True, stream the response and return the full text when done.

        Returns
        -------
        str
            Hermy's response text.
        """
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        if history:
            messages.extend(history)
        messages.append({"role": "user", "content": message})

        payload = {"messages": messages, "stream": stream}
        headers = {}
        if session_id:
            headers["X-Hermes-Session-Id"] = session_id

        if stream:
            return self._chat_stream(payload, headers)

        resp = self._session.post(
            f"{self.base_url}/v1/chat/completions",
            json=payload,
            headers=headers,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]

    def _chat_stream(self, payload: dict, extra_headers: dict) -> str:
        """Stream a chat completion and return the full text."""
        full_text = ""
        with self._session.post(
            f"{self.base_url}/v1/chat/completions",
            json=payload,
            headers=extra_headers,
            stream=True,
            timeout=self.timeout,
        ) as resp:
            resp.raise_for_status()
            for line in resp.iter_lines():
                if not line:
                    continue
                line = line.decode("utf-8") if isinstance(line, bytes) else line
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str.strip() == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk["choices"][0].get("delta", {}).get("content", "")
                        if delta:
                            full_text += delta
                            print(delta, end="", flush=True)
                    except (json.JSONDecodeError, KeyError):
                        pass
        print()  # newline after streaming
        return full_text

    # ------------------------------------------------------------------
    # Responses API (OpenAI Responses format, blocking)
    # ------------------------------------------------------------------

    def respond(
        self,
        message: str,
        instructions: Optional[str] = None,
        previous_response_id: Optional[str] = None,
    ) -> dict:
        """
        Send a message using the OpenAI Responses API format.

        Returns the full response dict including response_id for chaining.
        """
        payload = {"input": message}
        if instructions:
            payload["instructions"] = instructions
        if previous_response_id:
            payload["previous_response_id"] = previous_response_id

        resp = self._session.post(
            f"{self.base_url}/v1/responses",
            json=payload,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        return resp.json()

    # ------------------------------------------------------------------
    # Async Runs with SSE event streaming
    # ------------------------------------------------------------------

    def run(
        self,
        message: str,
        instructions: Optional[str] = None,
        wait: bool = True,
        print_events: bool = True,
    ) -> dict:
        """
        Start an async agent run and optionally wait for completion.

        Parameters
        ----------
        message : str
            The user message / task for Hermy.
        instructions : str, optional
            Ephemeral system instructions.
        wait : bool
            If True, block until the run completes and return the final result.
        print_events : bool
            If True and wait=True, print agent events as they arrive.

        Returns
        -------
        dict
            {"run_id": ..., "status": ..., "final_response": ..., "events": [...]}
        """
        payload = {"input": message}
        if instructions:
            payload["instructions"] = instructions

        # Start the run
        resp = self._session.post(
            f"{self.base_url}/v1/runs",
            json=payload,
            timeout=30,
        )
        resp.raise_for_status()
        run_data = resp.json()
        run_id = run_data["run_id"]

        if not wait:
            return run_data

        # Stream events
        return self._stream_run_events(run_id, print_events=print_events)

    def _stream_run_events(self, run_id: str, print_events: bool = True) -> dict:
        """Stream SSE events from a run until completion."""
        events = []
        final_response = ""
        error = None

        with self._session.get(
            f"{self.base_url}/v1/runs/{run_id}/events",
            stream=True,
            timeout=self.timeout,
        ) as resp:
            resp.raise_for_status()
            for line in resp.iter_lines():
                if not line:
                    continue
                line = line.decode("utf-8") if isinstance(line, bytes) else line
                if not line.startswith("data: "):
                    continue
                data_str = line[6:]
                try:
                    event = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                events.append(event)
                event_type = event.get("event", "")

                if print_events:
                    if event_type == "message.delta":
                        print(event.get("delta", ""), end="", flush=True)
                    elif event_type == "tool.start":
                        tool = event.get("tool_name", "?")
                        print(f"\n[tool: {tool}]", flush=True)
                    elif event_type == "tool.end":
                        print(f"[/tool]", flush=True)
                    elif event_type == "run.completed":
                        final_response = event.get("final_response", "")
                        if print_events:
                            print()  # newline after streaming
                    elif event_type == "run.failed":
                        error = event.get("error", "Unknown error")
                        if print_events:
                            print(f"\n[ERROR] {error}", flush=True)

        return {
            "run_id": run_id,
            "status": "failed" if error else "completed",
            "final_response": final_response,
            "error": error,
            "events": events,
        }

    # ------------------------------------------------------------------
    # Conversation helper (multi-turn with history tracking)
    # ------------------------------------------------------------------

    def conversation(self, session_id: Optional[str] = None):
        """
        Return a Conversation object for multi-turn chat with history tracking.

        Example
        -------
            conv = bridge.conversation()
            print(conv.send("Hello! My name is Manny."))
            print(conv.send("What is my name?"))
        """
        return Conversation(self, session_id=session_id)


class Conversation:
    """
    Multi-turn conversation with Hermy, tracking history locally.

    Parameters
    ----------
    bridge : HermyBridge
        The bridge instance to use.
    session_id : str, optional
        A session ID for server-side history (requires API_SERVER_KEY).
    """

    def __init__(self, bridge: HermyBridge, session_id: Optional[str] = None):
        self.bridge = bridge
        self.session_id = session_id or f"manny-{uuid.uuid4().hex[:8]}"
        self.history: list = []

    def send(self, message: str, system_prompt: Optional[str] = None) -> str:
        """Send a message and return Hermy's response, updating history."""
        response = self.bridge.chat(
            message=message,
            history=self.history.copy(),
            system_prompt=system_prompt,
            session_id=self.session_id,
        )
        self.history.append({"role": "user", "content": message})
        self.history.append({"role": "assistant", "content": response})
        return response

    def clear(self):
        """Clear the local conversation history."""
        self.history = []
        print(f"[Conversation {self.session_id} cleared]")


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------

def _parse_args():
    import argparse
    parser = argparse.ArgumentParser(
        description="Manny ↔ Hermy API Bridge — send messages to Hermes Agent on Railway",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("message", nargs="?", help="Message to send to Hermy")
    parser.add_argument("--url", default=HERMY_BASE_URL, help="Hermy base URL")
    parser.add_argument("--key", default=HERMY_API_KEY, help="API key")
    parser.add_argument("--session", help="Session ID for multi-turn conversation")
    parser.add_argument("--stream", action="store_true", help="Stream the response")
    parser.add_argument("--runs", action="store_true", help="Use /v1/runs (async SSE)")
    parser.add_argument("--status", action="store_true", help="Show gateway status and exit")
    parser.add_argument("--health", action="store_true", help="Check API server health and exit")
    return parser.parse_args()


def main():
    args = _parse_args()
    bridge = HermyBridge(base_url=args.url, api_key=args.key)

    if args.health:
        try:
            result = bridge.health()
            print(f"✅ API server healthy: {json.dumps(result, indent=2)}")
        except Exception as e:
            print(f"❌ API server unreachable: {e}")
            print("   Make sure API_SERVER_KEY is set on Railway and the deployment is running.")
        return

    if args.status:
        result = bridge.status()
        print(json.dumps(result, indent=2))
        return

    if not args.message:
        print("Usage: python hermy_bridge.py [options] <message>")
        print("       python hermy_bridge.py --help")
        sys.exit(1)

    print(f"[Hermy @ {args.url}]")
    print(f"[You] {args.message}")
    print("[Hermy] ", end="", flush=True)

    if args.runs:
        result = bridge.run(args.message, print_events=True)
        if not result.get("final_response"):
            print(f"\n[status: {result['status']}]")
    else:
        response = bridge.chat(
            message=args.message,
            session_id=args.session,
            stream=args.stream,
        )
        if not args.stream:
            print(response)


if __name__ == "__main__":
    main()
