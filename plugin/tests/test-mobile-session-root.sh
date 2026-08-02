#!/usr/bin/env bash
# 세션 단위 동작은 **그 세션의 root** 를 써야 한다.
#
# 형 신고: "이 세션 모바일에서 안되잖아. do not access this resource 라는데"
# 정체: 전송이 전역 selectedRoot()(워크트리 피커/프로젝트 탭이 움직이는 값)를 보냈다. 선택된 세션이
#       다른 워크트리에 있으면 서버의 agent_belongs_to_root(root, source, sid) 가 False → _forbidden()
#       → 403 "You do not have access to this resource."
#       읽기(transcript/usage)는 session.root 를 써서 200 이 나오니, "읽기는 되는데 전송만 막히는"
#       증상으로 보였다. 실제 로그도 그랬다:
#         GET  /mobile/api/transcript?root=.../worktrees/asdf   200
#         POST /mobile/api/send                                 403
#         GET  /mobile/api/services?root=.../sumin/marina       200   ← 전역 root 는 부모였다
# 드로어에서 프로젝트를 바꿔도 대화를 안 떠나게 만든 뒤 이 어긋남이 훨씬 쉬워졌다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

# ---------- ① 서버: 세션 root 가 아니면 실제로 막힌다(증상의 근거) ----------
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path
import marina_sessions as ms

wt = Path("/tmp/wt-child")
parent = Path("/tmp/wt-parent")
ms.claude_agent_sessions = lambda refresh=False, include_all=False: {
    str(wt): [{"source": "claude", "title": "t", "ts": 0, "cliSessionId": "sid-1234"}],
    str(parent): [],
}
assert ms.agent_belongs_to_root(wt, "claude", "sid-1234") is True, "세션 root 면 통과해야 함"
assert ms.agent_belongs_to_root(parent, "claude", "sid-1234") is False, \
    "부모 root 로 보내면 막힌다 — 이게 형이 본 403 의 원인"
print("PASS ① 서버: 세션 root 만 통과 · 부모 root 는 차단(403 의 근거)")
PY

# ---------- ② 클라이언트: 세션 단위 호출이 sessionRoot() 를 쓴다 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()

# 헬퍼가 있고, 세션이 있으면 세션 root 를 우선한다
assert "function sessionRoot() {" in html, "sessionRoot 헬퍼가 없다"
helper = re.search(r"function sessionRoot\(\) \{(.+?)\n    \}", html, re.S).group(1)
assert "session.root" in helper and "selectedRoot()" in helper, f"세션 root 우선 + 폴백이 아니다: {helper}"

# 세션 단위 엔드포인트는 전역 root 를 쓰면 안 된다.
session_scoped = [
    ("전송", r"const requestContext = \{root: (\w+)\(\)"),
    ("질문 응답", r'const body = \{root: (\w+)\(\), target: \{type: "agent"'),
    ("이미지 ref", r"new URLSearchParams\(\{root: (\w+)\(\), source, sid, ref\}\)"),
    ("모아보기 목록", r"new URLSearchParams\(\{root: (\w+)\(\), source, sid\}\)"),
    ("파일 서빙", r"new URLSearchParams\(\{root: (\w+)\(\), path\}\)"),
    ("첨부 업로드", r"async function uploadFiles\(files\) \{\s*const root = (\w+)\(\)"),
    ("@파일 제안", r"function scheduleFileSuggestions\(query, source\) \{\s*const root = (\w+)\(\)"),
]
for label, pattern in session_scoped:
    found = re.findall(pattern, html)
    assert found, f"{label} 호출을 못 찾음 (패턴 변경?): {pattern}"
    for got in found:
        assert got == "sessionRoot", f"{label} 이 {got}() 를 쓴다 — 세션과 어긋나면 403 이 된다"

# 전송 컨텍스트 비교도 같은 기준이어야 한다 — 아니면 항상 불일치해서 재시도/대기 표시가 깨진다.
assert "sessionRoot() === requestContext.root" in html, "전송 활성 판정이 전역 root 와 비교한다"
assert "failedSend.root !== sessionRoot()" in html, "실패 재시도 판정이 전역 root 와 비교한다"

# 이미 멀쩡했던 두 곳은 계속 session.root 를 쓴다(관례 유지).
assert 'JSON.stringify({root: session.root, source: session.source, sid: session.sid, model, effort})' in html, \
    "설정 저장이 session.root 를 안 쓴다"
assert "JSON.stringify({root: session.root, target: session.target})" in html, \
    "중단(interrupt)이 session.root 를 안 쓴다"

print("PASS ② 클라이언트: 전송·응답·이미지·모아보기·업로드·제안이 모두 sessionRoot() 사용 + 비교 기준 일치")
PY

echo "PASS test-mobile-session-root"
