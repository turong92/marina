#!/usr/bin/env bash
# SessionStart 훅이 등록 worktree 에서 규칙 JSON 을 stdout 으로 낸다 (Claude/Codex 분기)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-session-start-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null

# Claude: hookSpecificOutput.additionalContext, marina 규칙 텍스트(caller-독립 ' start <서비스>')
out="$( cd "$proj" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert ' start <서비스>' in a and 'docker compose up' in a, a" \
  || { echo "FAIL: Claude additionalContext"; exit 1; }

# Codex/SDK: top-level additionalContext (caller-독립 ' start <서비스>')
out="$( cd "$proj" && "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in d and ' start <서비스>' in d['additionalContext'], d" \
  || { echo "FAIL: top-level additionalContext"; exit 1; }

# 비-marina repo: 미등록 힌트 1줄 (등록 안내) — 단 .workspace 등 파일 흔적은 안 만듦
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
out="$( cd "$other" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert '미등록' in a and 'project add' in a, a" \
  || { echo "FAIL: 미등록 힌트"; exit 1; }
[[ ! -e "$other/.workspace" ]] || { echo "FAIL: 미등록 repo 에 .workspace 생성"; exit 1; }

# 판정불가(깨진 projects.json)는 침묵 — 등록 레포에 '미등록' 오안내 금지
cp "$MARINA_HOME/projects.json" "$MARINA_HOME/projects.json.bak"
echo '{broken' > "$MARINA_HOME/projects.json"
out="$( cd "$proj" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
[[ -z "$out" ]] || { echo "FAIL: 판정불가에 출력: $out"; exit 1; }
mv "$MARINA_HOME/projects.json.bak" "$MARINA_HOME/projects.json"

echo "PASS test-session-start-context"
