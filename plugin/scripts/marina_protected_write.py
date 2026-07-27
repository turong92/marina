#!/usr/bin/env python3
"""marina PreToolUse(Write/Edit/NotebookEdit) 판정기 — macOS 보호 폴더에 파일을 만들면 deny.

**왜.** LLM 이 리포트·산출물을 ~/Downloads 에 떨구면, 그 뒤로 그 폴더를 읽을 때마다 macOS 가
권한 팝업을 띄운다(실측: "'2.1.220'이(가) 다운로드 폴더의 파일에 접근하려고 합니다").
claude CLI 는 `.app` 번들이 아니라 **버전 이름의 단일 실행파일**(~/.local/share/claude/versions/2.1.220)
이라, 서명이 멀쩡해도 macOS 가 경로로 신원을 잡아 **업데이트마다 다시 물어본다**. 즉 한 번 허용해도
안 끝난다. 그래서 파일이 애초에 거기 안 생기게 막는 게 유일한 항구적 해결이다.

보호 대상은 TCC 가 지키는 세 폴더뿐(Downloads·Desktop·Documents) — 나머지 경로는 관여하지 않는다.

stdin: Claude Code PreToolUse JSON({tool_name, tool_input:{file_path}, cwd}).
출력: deny JSON 또는 무출력(=allow). 어떤 오류든 무출력 exit 0 (fail-open) —
marina 문제로 세션의 파일 쓰기 전체를 막지 않는다.
"""
from __future__ import annotations

import json
import os
import sys

TOOLS = {"Write", "Edit", "NotebookEdit", "apply_patch"}   # apply_patch = Codex 의 파일 쓰기
PROTECTED = ("Downloads", "Desktop", "Documents")   # macOS TCC 가 지키는 폴더

REASON = ("macOS 가 지키는 폴더(~/Downloads·Desktop·Documents)에는 파일을 만들지 마세요. "
          "여기에 산출물이 쌓이면 그 폴더를 읽을 때마다 시스템 권한 팝업이 뜨고, claude CLI 는 "
          "버전마다 경로가 바뀌는 단일 실행파일이라 한 번 허용해도 업데이트 때 또 물어봅니다. "
          "지금 작업 중인 **워크트리 안**에 쓰세요(예: ./docs/, ./tmp/). "
          "형이 명시적으로 그 폴더를 원한 경우에만 MARINA_ALLOW_PROTECTED_WRITE=1 로 여세요.")


def _protected_roots() -> list[str]:
    home = os.path.expanduser("~")
    return [os.path.realpath(os.path.join(home, name)) for name in PROTECTED]


def is_protected(path: str, cwd: str = "") -> bool:
    """path 가 보호 폴더(또는 그 하위)를 가리키면 True.

    상대경로·`~`·심볼릭 링크를 전부 같은 자리로 모은 뒤 비교한다 — 하나라도 빠지면 그게 우회로가 된다.
    접두사만 같은 폴더(~/Downloadsnot)는 os.path.commonpath 로 걸러진다.
    """
    if not path:
        return False
    expanded = os.path.expanduser(str(path))
    if not os.path.isabs(expanded):
        expanded = os.path.join(cwd or os.getcwd(), expanded)
    target = os.path.realpath(expanded)
    for root in _protected_roots():
        if target == root:
            return True
        try:
            if os.path.commonpath([target, root]) == root:
                return True
        except ValueError:          # 다른 드라이브/상대-절대 혼용 — 비교 불가면 관여하지 않는다
            continue
    return False


def main() -> int:
    try:
        if os.environ.get("MARINA_ALLOW_PROTECTED_WRITE"):     # 형이 명시적으로 연 경우
            return 0
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            return 0
        if str(payload.get("tool_name") or "") not in TOOLS:
            return 0
        tool_input = payload.get("tool_input")
        if not isinstance(tool_input, dict):
            return 0
        if not is_protected(str(tool_input.get("file_path") or ""), str(payload.get("cwd") or "")):
            return 0
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": "deny",
                                                 "permissionDecisionReason": REASON}}, ensure_ascii=False))
    except Exception:
        return 0                                               # fail-open
    return 0


if __name__ == "__main__":
    sys.exit(main())
