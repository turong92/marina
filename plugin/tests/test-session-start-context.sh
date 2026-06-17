#!/usr/bin/env bash
# SessionStart 훅이 등록 worktree 에서 규칙 JSON 을 stdout 으로 낸다 (Claude/Codex 분기)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-session-start-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null
"$HERE/../scripts/marina.sh" service add "$(basename "$proj")" '{"name":"web","portBase":3000,"run":"exec true"}' >/dev/null

# Claude: hookSpecificOutput.additionalContext, 규칙 텍스트(caller-독립 ' start <서비스>') + 서비스명 포함
out="$( cd "$proj" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert ' start <서비스>' in a and 'web' in a, a" \
  || { echo "FAIL: Claude additionalContext"; exit 1; }

# Codex/SDK: top-level additionalContext (caller-독립 ' start <서비스>')
out="$( cd "$proj" && "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in d and ' start <서비스>' in d['additionalContext'], d" \
  || { echo "FAIL: top-level additionalContext"; exit 1; }

# 비-marina repo: stdout 비어야 (오염 없음)
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
out="$( cd "$other" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
[[ -z "$out" ]] || { echo "FAIL: 비등록 repo 가 stdout 출력: $out"; exit 1; }

echo "PASS test-session-start-context"
