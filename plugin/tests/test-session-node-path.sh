#!/usr/bin/env bash
# 세션의 node 는 사용자가 깔아 둔 것 — Codex 에 딸린 node 는 다른 node 가 없을 때만 쓴다.
# marina.sh 가 Codex 의 node 폴더를 PATH 맨 앞에 붙여서, marina 가 띄운 Claude 세션의 node·vitest·pnpm 이 전부
# Codex 번들 node(24)로 돌고 있었다(형 2026-10-06 "넌 클로드잖아"). 사용자가 고른 버전(22)이 아니라 Codex 가
# 업데이트할 때마다 바뀌는 버전이었다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
MINE="$TMPROOT/mine/bin"; CODEX="$TMPROOT/codex-node/bin"; mkdir -p "$MINE" "$CODEX"
printf '#!/bin/sh\necho mine\n' > "$MINE/node"; printf '#!/bin/sh\necho codex\n' > "$CODEX/node"; chmod +x "$MINE/node" "$CODEX/node"
export CODEX_NODE_BIN="$CODEX"
PATH="$MINE:$PATH" msess new proj feat/n >/dev/null 2>&1 || fail "new"
cmd="$(tmux -L "$MARINA_TMUX_SOCKET" display-message -p -t "=proj-feat-n:" '#{pane_start_command}')"
path="$(printf '%s' "$cmd" | grep -o "PATH=[^']*" | head -1)"      # 작은따옴표 안 전체 — PATH 에 공백 든 폴더가 있다
[[ "$path" == *"$MINE"* ]] || fail "세션 PATH 에 사용자 node 폴더가 없다: $path"
[[ "$path" == *"$CODEX"* ]] || fail "Codex node 는 마지막 수단으로 남아 있어야 한다: $path"
before="${path%%"$CODEX"*}"
[[ "$before" == *"$MINE"* ]] || fail "Codex node 가 사용자 node 보다 앞이다: $path"
[[ "$(printf '%s' "$path" | grep -o "$CODEX" | wc -l | tr -d ' ')" == 1 ]] || fail "Codex node 폴더가 여러 번 붙었다: $path"
[[ "$path" == *"$CODEX" ]] || fail "Codex node 는 맨 뒤여야 한다: $path"
echo "PASS test-session-node-path"
