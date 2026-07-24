#!/usr/bin/env bash
# marina AskUserQuestion 캡처 훅 래퍼 (PreToolUse/PostToolUse matcher "AskUserQuestion").
# pending 질문을 상태파일에 기록/삭제 → 모바일이 pending 창에도 질문 카드를 그릴 수 있게.
# 어떤 실패든 exit 0 = 에이전트 흐름 방해 금지(fail-open).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || exit 0
python3 "$SCRIPT_DIR/marina_question.py" 2>/dev/null || true
exit 0
