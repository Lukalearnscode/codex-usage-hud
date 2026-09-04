#!/usr/bin/env python3
"""Read your local Codex rate limits. No dependencies, no credentials.

The Codex desktop app ships an "app server" that speaks JSON-RPC-ish JSON Lines
over stdin/stdout. It already holds your session, so a client never touches
~/.codex/auth.json or any token. Spawn it, shake hands, ask for the limits.

    python3 read_rate_limits.py

Verified against codex-cli 0.153.0 (September 2026). The executable path,
method names and field names are internal to the Codex app and can change with
any release; this script fails loudly rather than guessing when they do.
"""

import json
import subprocess
import sys
import time

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
TIMEOUT = 15.0

# Window lengths, in minutes, as reported by windowDurationMins. Do not rely on
# the "primary"/"secondary" key names to tell you which window is which.
WINDOWS = {300: "5-hour", 10080: "weekly"}


def read_rate_limits(executable=CODEX, timeout=TIMEOUT):
    proc = subprocess.Popen(
        [executable, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    def send(obj):
        # One JSON object per line. Newline is the framing.
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    try:
        # 1. initialize (a request: it carries an id and must be answered)
        send({
            "method": "initialize",
            "id": 1,
            "params": {"clientInfo": {"name": "read_rate_limits", "version": "1.0.0"}},
        })

        deadline = time.time() + timeout
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("app server closed the stream")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # not every line is a message you care about

            if msg.get("id") == 1:
                if "error" in msg:
                    raise RuntimeError(f"initialize failed: {msg['error']}")
                # 2. initialized (a notification: no id, no answer)
                send({"method": "initialized", "params": {}})
                # 3. the actual question
                send({"method": "account/rateLimits/read", "id": 2})

            elif msg.get("id") == 2:
                if "error" in msg:
                    raise RuntimeError(f"rateLimits/read failed: {msg['error']}")
                return parse(msg.get("result", {}))

        raise TimeoutError(
            "no answer within %.0fs. The server can accept a request and never "
            "reply; always time out rather than waiting forever." % timeout
        )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def parse(result):
    """Pull the two windows out of a rateLimits/read result."""
    # Prefer the per-limit bucket; fall back to the flat one on older builds.
    bucket = (result.get("rateLimitsByLimitId") or {}).get("codex")
    if bucket is None:
        bucket = result.get("rateLimits")
    if bucket is None:
        # No bucket at all. Being signed out is only one reason this happens;
        # a renamed field does it too. Do not report it as "please log in".
        raise RuntimeError("no rate-limit data in the response")

    windows = {}
    for key in ("primary", "secondary"):
        raw = bucket.get(key)
        if not isinstance(raw, dict):
            continue
        duration = raw.get("windowDurationMins")
        resets_at = raw.get("resetsAt")
        if not isinstance(duration, int) or duration <= 0 or resets_at is None:
            continue
        used = raw.get("usedPercent", 0)
        used = min(max(float(used), 0.0), 100.0)  # clamp: the API can exceed 100
        windows[duration] = {
            "label": WINDOWS.get(duration, f"{duration}-minute"),
            "used_percent": used,
            "resets_at": float(resets_at),  # Unix seconds
        }
    if not windows:
        raise RuntimeError("no usable window in the response")
    return windows


def humanise(seconds):
    minutes = max(0, int(-(-seconds // 60)))  # round up
    if minutes < 24 * 60:
        return f"{minutes // 60}h{minutes % 60}m" if minutes >= 60 else f"{minutes}m"
    days, rest = divmod(minutes, 24 * 60)
    return f"{days}d{-(-rest // 60)}h"


if __name__ == "__main__":
    try:
        windows = read_rate_limits()
    except Exception as exc:  # noqa: BLE001 - a CLI wants the message, not a trace
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    now = time.time()
    for duration in sorted(windows):
        w = windows[duration]
        bar_filled = round(w["used_percent"] / 100 * 8)
        bar = "█" * bar_filled + "░" * (8 - bar_filled)
        print(f"{w['label']:>7}  {bar}  {w['used_percent']:5.1f}%  "
              f"resets in {humanise(w['resets_at'] - now)}")
