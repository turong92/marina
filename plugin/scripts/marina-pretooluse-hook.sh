#!/usr/bin/env bash
# marina PreToolUse hook 래퍼 (hooks.json 에서 호출) — 판정은 marina_pretooluse.py.
# 어떤 실패(파이썬 없음·판정기 예외)든 exit 0 + 무출력 = allow (fail-open).
# 매 Bash 호출마다 도는 hot path 라 bash 프리필터로 python 기동을 아낀다(셀프 리뷰):
#  · 레지스트리 자체가 없으면 python 도 항상 allow → 스킵
#  · 기동성 키워드가 입력에 아예 없으면(패턴표의 상위집합) → 스킵. 오탐은 python 정규식이 걸러줌.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INPUT="$(cat 2>/dev/null || true)"
[[ -n "$INPUT" ]] || exit 0
[[ -f "${MARINA_HOME:-$HOME/.marina}/projects.json" ]] || exit 0
printf '%s' "$INPUT" | grep -qiE 'run|start|up|dev|serve|vite|uvicorn|rails' || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$INPUT" | python3 "$SCRIPT_DIR/marina_pretooluse.py" 2>/dev/null || true
exit 0
