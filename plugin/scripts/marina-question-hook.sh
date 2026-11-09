#!/usr/bin/env bash
# marina AskUserQuestion 캡처 훅 래퍼 (PreToolUse/PostToolUse matcher "AskUserQuestion").
# pending 질문을 상태파일에 기록/삭제 → 모바일이 pending 창에도 질문 카드를 그릴 수 있게.
# 어떤 실패든 exit 0 = 에이전트 흐름 방해 금지(fail-open).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || exit 0
payload="$(cat)"
# 매 프롬프트·턴 끝(정리 이벤트)마다 도는데 지울 질문 파일이 거의 없다 — 없으면 python 을 안 띄운다(2026-11-09 점검).
case "$payload" in
  *'"AskUserQuestion"'*) ;;
  *) compgen -G "${MARINA_HOME:-$HOME/.marina}/agent-questions/claude-*.json" >/dev/null || exit 0 ;;
esac
printf '%s' "$payload" | python3 "$SCRIPT_DIR/marina_question.py" 2>/dev/null || true
exit 0
