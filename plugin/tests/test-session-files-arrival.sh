#!/usr/bin/env bash
# 방에 **떨어진 파일**은 어떻게 떨어졌든 목록에 잡혀야 한다 — 형: "이딴식으로 주는데? ㅋㅋㅋ
# 그러면 어케받냐 모아보기에도 안들어가고".
#
# **실측(2026-08-25).** 아티팩트를 막았더니 에이전트가 이렇게 했다:
#   Write → 스크래치패드(임시 폴더) · Bash 로 방 폴더에 복사 · SendUserFile 로 건네고
#   본문에는 절대경로를 그대로 출력
# 마리나의 "모아보기"는 Write/Edit 의 경로만 훑어서 방 안 파일을 찾는다. 그래서 정작 방 폴더에
# 놓인 결과물(56KB html)이 목록에 하나도 안 잡혔다 — 폰에서 받을 길이 없다.
#
# 규칙 둘: ① SendUserFile 로 건넨 파일도 결과물로 센다. ② 채팅방은 **폴더에 있는 것**을
# 그대로 보여준다(코드 레포가 아니라 결과물을 담는 폴더라, 어떻게 놓였는지 따질 이유가 없다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_sessions import _tool_file_targets

# ① SendUserFile 은 "이 파일을 형에게 건넨다"는 뜻이다 — 결과물 신호로 이보다 분명한 게 없다.
경로 = _tool_file_targets("SendUserFile", {"files": ["/wt/보고서.html"], "status": "normal"})
assert 경로 == ["/wt/보고서.html"], 경로
# 여러 개도 받는다.
assert _tool_file_targets("SendUserFile", {"files": ["/a.txt", "/b.txt"]}) == ["/a.txt", "/b.txt"]
# Write/Edit 는 그대로.
assert _tool_file_targets("Write", {"file_path": "/wt/x.md"}) == ["/wt/x.md"]
# 관계없는 도구는 아무것도 아니다.
assert _tool_file_targets("WebSearch", {"query": "hi"}) == []
print("ok SendUserFile 로 건넨 파일도 결과물로 센다")
PY

# ② 채팅방은 폴더에 있는 것을 그대로 보여준다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import json
from pathlib import Path

import marina_registry as reg
from marina_sessions import agent_session_files
from marina_state import MARINA_HOME

방 = MARINA_HOME / "chatroom"
(방 / ".workspace").mkdir(parents=True, exist_ok=True)
(방 / "결과물.html").write_text("<h1>hi</h1>", encoding="utf-8")
(방 / ".workspace" / "메모.json").write_text("{}", encoding="utf-8")

reg._projects_cache.clear()
(MARINA_HOME).mkdir(parents=True, exist_ok=True)
(MARINA_HOME / "projects.json").write_text(json.dumps({"projects": [
    {"id": "chatroom", "root": str(방), "subrepos": [], "worktreeGlobs": [], "profile": "chat"}]}), encoding="utf-8")
reg._projects_cache.clear(); reg._roots_cache.clear()

목록 = agent_session_files(방, "claude", "no-such-session")
이름 = [f["relPath"] for f in 목록["files"]]
assert "결과물.html" in 이름, f"방 폴더의 결과물이 목록에 없다: {목록}"
assert not any(".workspace" in n for n in 이름), f"마리나 자기 폴더가 섞였다: {이름}"
print("ok 채팅방은 폴더에 놓인 결과물을 그대로 보여준다")
PY2

echo "PASS test-session-files-arrival"
