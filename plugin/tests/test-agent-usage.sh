#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path

import marina_sessions as ms

tmp = Path(sys.argv[1])


def write(name, rows):
    path = tmp / name
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
    return path


codex = write("codex.jsonl", [
    {"type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"total_tokens": 400},
        "last_token_usage": {"total_tokens": 100},
        "model_context_window": 1000,
    }}},
    {"type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"total_tokens": 941459025},
        "last_token_usage": {"total_tokens": 100444},
        "model_context_window": 258400,
    }}},
])
assert ms.agent_usage_from_path(codex, "codex") == {
    "source": "codex",
    "model": "",
    "usedTokens": 100444,
    "contextWindow": 258400,
    "remainingTokens": 157956,
    "contextPercent": 38.9,
}

claude = write("claude.jsonl", [
    {"type": "assistant", "message": {
        "id": "msg-1", "model": "claude-test[200k]",
        "usage": {"input_tokens": 10, "cache_creation_input_tokens": 20,
                  "cache_read_input_tokens": 30, "output_tokens": 5},
    }},
    # Claude persists multiple blocks for one API response. Count its final usage once.
    {"type": "assistant", "message": {
        "id": "msg-1", "model": "claude-test[200k]",
        "usage": {"input_tokens": 10, "cache_creation_input_tokens": 20,
                  "cache_read_input_tokens": 30, "output_tokens": 5},
    }},
    {"type": "assistant", "message": {
        "id": "msg-2", "model": "claude-test[200k]",
        "usage": {"input_tokens": 3, "cache_creation_input_tokens": 4,
                  "cache_read_input_tokens": 100000, "output_tokens": 10000},
    }},
])
assert ms.agent_usage_from_path(claude, "claude") == {
    "source": "claude",
    "model": "claude-test[200k]",
    "usedTokens": 110007,
    "contextWindow": 200000,
    "remainingTokens": 89993,
    "contextPercent": 55.0,
}

unknown = write("claude-unknown.jsonl", [
    {"type": "assistant", "message": {
        "id": "msg-only", "model": "claude-unknown",
        "usage": {"input_tokens": 2, "cache_read_input_tokens": 10, "output_tokens": 3},
    }},
])
assert ms.agent_usage_from_path(unknown, "claude") == {
    "source": "claude",
    "model": "claude-unknown",
    "usedTokens": 15,
    "contextWindow": None,
    "remainingTokens": None,
    "contextPercent": None,
}

empty = write("empty.jsonl", [{"type": "user", "message": {"content": "hello"}}])
assert ms.agent_usage_from_path(empty, "claude") == {
    "source": "claude", "model": "", "usedTokens": None,
    "contextWindow": None, "remainingTokens": None,
    "contextPercent": None,
}

try:
    ms.agent_usage_from_path(empty, "other")
    raise AssertionError("unknown source accepted")
except ValueError as exc:
    assert "source" in str(exc)

print("ok source-aware agent usage")
PY

echo "PASS test-agent-usage"
