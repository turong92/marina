#!/usr/bin/env bash
# marina PreToolUse(Write/Edit/NotebookEdit) 훅 래퍼 — 판정은 marina_protected_write.py.
# 어떤 실패(파이썬 없음·판정기 예외)든 exit 0 + 무출력 = allow (fail-open).
# 파일 쓰기마다 도는 hot path 라 bash 프리필터로 python 기동을 아낀다: 보호 폴더 이름이 입력에
# 아예 없으면 판정할 것도 없다(상대경로는 아래 cwd 검사로 따로 받는다).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INPUT="$(cat 2>/dev/null || true)"
[[ -n "$INPUT" ]] || exit 0
if ! grep -qE 'Downloads|Desktop|Documents' <<<"$INPUT"; then
  # 입력에 이름이 없어도 cwd 가 보호 폴더 안이면 상대경로가 그리로 떨어진다 — 그때만 python 을 태운다.
  case "$PWD" in
    "$HOME"/Downloads|"$HOME"/Downloads/*|"$HOME"/Desktop|"$HOME"/Desktop/*|"$HOME"/Documents|"$HOME"/Documents/*) ;;
    *) exit 0 ;;
  esac
fi
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$INPUT" | python3 "$SCRIPT_DIR/marina_protected_write.py" 2>/dev/null || true
exit 0
