#!/usr/bin/env bash
# 다른 앱의 데이터(~/Library/Application Support/…) 읽기를 **기계로** 막는다.
#
# **왜.** macOS 는 그런 접근에 TCC 모달을 띄우는데, Claude Code CLI 는 .app 번들이 아니라
# 버전 경로의 맨 실행파일이라 허용이 저장되지 않는다(anthropics/claude-code #66216·#59608).
# 업데이트마다 경로가 바뀌어 매번 새 앱 취급 → 형이 수십 번 눌러도 계속 뜬다.
# ClaudeCode.app 에 전체 디스크 접근을 줘도 안 통한다(자식이 버전 경로라 그쪽에 귀속).
#
# 더 나쁜 건 성가심이 아니다. 형은 맥을 놔두고 폰으로 원격 조종하는데, 화면 앞에 아무도 없으면
# **모달에 답할 사람이 없어 프로세스가 그대로 멈춰 선다.**
#
# "안 읽겠다"는 약속으로는 안 된다 — 일하다 보면 자연스럽게 건드리게 된다(형 지적). 그래서 막는다.
# 마리나 데몬은 launchd 자식이라 신원이 Python(경로 불변)이고, 그쪽은 허용이 유지되므로
# 정말 필요하면 데몬을 거치면 된다.
set -euo pipefail

payload="$(cat)"
path="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
i = d.get("tool_input") or {}
# Read=file_path · Grep/Glob=path · 그 외 흔한 키까지 훑는다(도구가 늘어도 새지 않게).
for k in ("file_path", "path", "notebook_path"):
    v = i.get(k)
    if isinstance(v, str) and v:
        print(v); raise SystemExit
print("")
' 2>/dev/null || true)"

[ -n "$path" ] || exit 0

case "$path" in
  "$HOME"/Library/Application\ Support/*|~/Library/Application\ Support/*)
    cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"다른 앱 데이터(~/Library/Application Support/) 는 읽지 않습니다 — macOS TCC 모달이 뜨고, 원격으로 쓰는 중이면 아무도 못 눌러 그대로 멈춥니다(claude-code #66216: 번들이 아니라 허용이 저장되지 않음). 정말 필요하면 마리나 데몬을 통해 읽으세요 — 데몬은 신원이 고정이라 허용이 유지됩니다."}}
JSON
    exit 0
    ;;
esac
exit 0
