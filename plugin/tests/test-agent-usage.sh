#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json
import sys
import time
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

codex_limits = ms.account_usage_from_rate_limits({
    "primary": {"used_percent": 42.5, "window_minutes": 300, "resets_at": 1700000300},
    "secondary": {"used_percent": 18.0, "window_minutes": 10080, "resets_at": 1700600000},
})
assert codex_limits == {
    "source": "codex",
    "windows": [
        {"key": "fiveHour", "label": "5시간", "usedPercent": 42.5, "remainingPercent": 57.5, "resetsAt": 1700000300},
        {"key": "weekly", "label": "주간", "usedPercent": 18.0, "remainingPercent": 82.0, "resetsAt": 1700600000},
    ],
}, codex_limits

codex_swapped_limits = ms.account_usage_from_rate_limits({
    "primary": {"used_percent": 55, "window_minutes": 10080, "resets_at": 1700600000},
    "secondary": {"used_percent": 12, "window_minutes": 300, "resets_at": 1700000300},
})
assert [item["key"] for item in codex_swapped_limits["windows"]] == ["fiveHour", "weekly"], codex_swapped_limits
assert [item["usedPercent"] for item in codex_swapped_limits["windows"]] == [12.0, 55.0], codex_swapped_limits

codex_rollout = write("codex-rate-limits.jsonl", [
    {"type": "event_msg", "payload": {
        "type": "token_count",
        "info": {"model_context_window": 258400},
        "rate_limits": {
            "primary": {"used_percent": 55, "window_minutes": 10080, "resets_at": 1700600000},
            "secondary": None,
        },
    }},
])
original_codex_sessions = ms.codex_agent_sessions
ms.codex_agent_sessions = lambda: {str(tmp): [{"path": str(codex_rollout)}]}
try:
    discovered_limits = ms._latest_codex_rate_limits(tmp)
finally:
    ms.codex_agent_sessions = original_codex_sessions
assert discovered_limits == {
    "primary": {"used_percent": 55, "window_minutes": 10080, "resets_at": 1700600000},
    "secondary": None,
}, discovered_limits

claude_limits = ms.account_usage_from_claude_cache({
    "data": {
        "fiveHour": 31,
        "sevenDay": 22,
        "fiveHourResetAt": "2026-07-23T05:00:00Z",
        "sevenDayResetAt": "2026-07-30T00:00:00Z",
        "fableWeekly": 47,
        "fableWeeklyResetAt": "2026-07-30T00:00:00Z",
    },
})
assert [item["key"] for item in claude_limits["windows"]] == ["fiveHour", "weekly", "fableWeekly"], claude_limits
assert claude_limits["windows"][2]["usedPercent"] == 47.0, claude_limits
assert claude_limits["windows"][2]["remainingPercent"] == 53.0, claude_limits

claude_native_limits = ms.account_usage_from_claude_cache({
    "data": {
        "five_hour": {"utilization": 11},
        "seven_day": {"utilization": 24},
        "limits": [
            {"display_name": "Fable 5", "utilization": 63, "resets_at": 1785369600},
        ],
    },
})
assert [item["key"] for item in claude_native_limits["windows"]] == ["fiveHour", "weekly", "fableWeekly"], claude_native_limits
assert [item["usedPercent"] for item in claude_native_limits["windows"][:2]] == [11.0, 24.0], claude_native_limits
assert claude_native_limits["windows"][-1] == {
    "key": "fableWeekly", "label": "Fable 주간", "usedPercent": 63.0,
    "remainingPercent": 37.0, "resetsAt": 1785369600,
}, claude_native_limits

claude_cache = tmp / "claude-usage-cache.json"
claude_cache.write_text(json.dumps({
    "timestamp": int(time.time() * 1000),
    "data": {"fiveHour": 20, "sevenDay": 30},
}), encoding="utf-8")
original_claude_cache = ms.CLAUDE_USAGE_CACHE_FILE
ms.CLAUDE_USAGE_CACHE_FILE = claude_cache
try:
    assert [item["key"] for item in ms.provider_account_usage("claude")["windows"]] == ["fiveHour", "weekly"]
    claude_cache.write_text(json.dumps({
        "timestamp": 0,
        "data": {"fiveHour": 99, "sevenDay": 99},
    }), encoding="utf-8")
    assert ms.provider_account_usage("claude")["windows"] == []
finally:
    ms.CLAUDE_USAGE_CACHE_FILE = original_claude_cache

try:
    ms.agent_usage_from_path(empty, "other")
    raise AssertionError("unknown source accepted")
except ValueError as exc:
    assert "source" in str(exc)

print("ok source-aware agent usage")
PY

echo "PASS test-agent-usage"
