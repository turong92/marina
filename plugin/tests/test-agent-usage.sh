#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

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
original_rollout_dirs = ms.CODEX_ROLLOUT_DIRS
ms.codex_agent_sessions = lambda *a, **k: {str(tmp): [{"path": str(codex_rollout)}]}
# 계정 범위 글롭이 실 ~/.codex 를 읽으면 테스트가 형의 진짜 사용량을 보고 깨진다 — 비어 있는 곳으로.
ms.CODEX_ROLLOUT_DIRS = (tmp / "no-rollouts-here",)
try:
    discovered_limits = ms._latest_codex_rate_limits(tmp)
finally:
    ms.codex_agent_sessions = original_codex_sessions
    ms.CODEX_ROLLOUT_DIRS = original_rollout_dirs
assert discovered_limits == {
    "primary": {"used_percent": 55, "window_minutes": 10080, "resets_at": 1700600000},
    "secondary": None,
}, discovered_limits

# 계정 한도는 **계정 단위**다: 이 워크트리에서 codex 를 안 써도 다른 곳에서 쓴 최신 값이 이긴다.
scope_dir = tmp / "rollouts"
scope_dir.mkdir(exist_ok=True)
(scope_dir / "rollout-elsewhere.jsonl").write_text(json.dumps({
    "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
        "primary": {"used_percent": 7, "window_minutes": 300, "resets_at": 1700000999},
        "secondary": None,
    }},
}) + "\n", encoding="utf-8")
ms.codex_agent_sessions = lambda *a, **k: {str(tmp): [{"path": str(codex_rollout)}]}
ms.CODEX_ROLLOUT_DIRS = (scope_dir,)
try:
    account_limits = ms._latest_codex_rate_limits(tmp)
finally:
    ms.codex_agent_sessions = original_codex_sessions
    ms.CODEX_ROLLOUT_DIRS = original_rollout_dirs
assert account_limits["primary"]["used_percent"] == 7, account_limits

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

# 공식 /api/oauth/usage 의 실제 모양. 모델별 주간은 **limits 배열에만** 있다 —
# 평평한 seven_day_opus/seven_day_sonnet 은 이 계정에서 전부 null 이라, 배열을 안 보면 페이블이
# 영영 안 뜬다(형이 "페이블 사용량은 어케 가져오냐"고 물은 게 정확히 이 구멍이었다).
claude_official = ms.account_usage_from_claude_cache({
    "five_hour": None, "seven_day": None, "seven_day_opus": None, "seven_day_sonnet": None,
    "limits": [
        {"kind": "session", "percent": 11, "resets_at": "2026-08-03T12:00:00+00:00", "scope": None},
        {"kind": "weekly_all", "percent": 14, "resets_at": "2026-08-06T15:00:00+00:00", "scope": None},
        {"kind": "weekly_scoped", "percent": 0, "resets_at": None,
         "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None}},
    ],
})
assert [item["key"] for item in claude_official["windows"]] == ["fiveHour", "weekly", "fableWeekly"], claude_official
assert [item["usedPercent"] for item in claude_official["windows"]] == [11.0, 14.0, 0.0], claude_official
assert claude_official["windows"][-1]["label"] == "Fable 주간", claude_official

# 우리가 모르는 모델이 배열에 새로 생겨도 하드코딩 없이 그대로 뜬다
claude_unknown = ms.account_usage_from_claude_cache({
    "limits": [{"kind": "weekly_scoped", "percent": 5, "resets_at": None,
                "scope": {"model": {"display_name": "Mythos 9"}}}],
})
assert claude_unknown["windows"] == [{
    "key": "mythosWeekly", "label": "Mythos 주간", "usedPercent": 5.0,
    "remainingPercent": 95.0, "resetsAt": None,
}], claude_unknown

claude_cache = tmp / "claude-usage-cache.json"
claude_cache.write_text(json.dumps({
    "timestamp": int(time.time() * 1000),
    "data": {"fiveHour": 20, "sevenDay": 30},
}), encoding="utf-8")
original_claude_cache = ms.CLAUDE_USAGE_CACHE_FILE
ms.CLAUDE_USAGE_CACHE_FILE = claude_cache
# 1순위인 **직접 가져오기**를 막아야 캐시 폴백을 검증할 수 있다. 안 막으면 이 테스트가 형의
# 키체인을 열고 실제 API 를 쳐서, 실 사용량에 따라 통과·실패가 갈린다.
import marina_usage as mu

original_live = mu.claude_usage_payload
mu.claude_usage_payload = lambda *a, **k: None
try:
    assert [item["key"] for item in ms.provider_account_usage("claude")["windows"]] == ["fiveHour", "weekly"]
    claude_cache.write_text(json.dumps({
        "timestamp": 0,
        "data": {"fiveHour": 99, "sevenDay": 99},
    }), encoding="utf-8")
    assert ms.provider_account_usage("claude")["windows"] == []
    # 라이브가 되면 낡은 캐시(99%)를 덮는다 — 47일 멈춘 캐시를 다시 믿지 않게
    mu.claude_usage_payload = lambda *a, **k: {"limits": [{"kind": "session", "percent": 3, "resets_at": None}]}
    live_first = ms.provider_account_usage("claude")["windows"]
    assert [item["usedPercent"] for item in live_first] == [3.0], live_first
finally:
    mu.claude_usage_payload = original_live
    ms.CLAUDE_USAGE_CACHE_FILE = original_claude_cache

try:
    ms.agent_usage_from_path(empty, "other")
    raise AssertionError("unknown source accepted")
except ValueError as exc:
    assert "source" in str(exc)

print("ok source-aware agent usage")
PY

echo "PASS test-agent-usage"
