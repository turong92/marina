#!/usr/bin/env bash
# 에이전트가 **건네준 파일**은 임시 폴더에 있어도 형에게 닿아야 한다 — 형: "지시문을 매번
# 그딴식으로 쳐야돼?" 아니다. 지시문은 안 들으면 그만이라, 마리나가 집어오는 쪽이 맞다.
#
# **실측(2026-08-25).** 아티팩트를 막자 에이전트는 스크래치패드에 Write 하고 Bash 로 방에
# 복사한 뒤 SendUserFile 로 건넸다. 마침 복사를 했으니 망정이지, 임시 폴더에만 두고 건넸다면
# 마리나는 그 파일을 "워크트리 밖"이라며 거부했을 것이다(session_file_in_root).
#
# 규칙: **그 세션이 SendUserFile 로 건넨 파일**은 방 밖이라도 목록에 넣고 받을 수 있게 한다.
# 아무 경로나 여는 게 아니라 "그 세션이 형에게 주겠다고 기록에 남긴 파일"만이다(명시적 동의).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import json
from pathlib import Path

import marina_sessions as ms
from marina_state import MARINA_HOME

방 = MARINA_HOME / "chatroom"; 방.mkdir(parents=True, exist_ok=True)
바깥 = MARINA_HOME / "tmpdir"; 바깥.mkdir(parents=True, exist_ok=True)
결과 = 바깥 / "보고서.html"
결과.write_text("<h1>결과</h1>", encoding="utf-8")

기록 = MARINA_HOME / "fake-transcript.jsonl"
기록.write_text(json.dumps({"message": {"content": [
    {"type": "tool_use", "name": "SendUserFile", "input": {"files": [str(결과)]}}]}}) + "\n", encoding="utf-8")
ms.agent_transcript_path = lambda root, source, sid: 기록

목록 = ms.agent_session_files(방, "claude", "s1")
이름 = [f["relPath"] for f in 목록["files"]]
assert "보고서.html" in 이름, f"건네준 파일이 목록에 없다: {목록}"
받기 = [f for f in 목록["files"] if f["relPath"] == "보고서.html"][0]
assert 받기["servable"], 받기

# 받아지는지 — 방 밖이라도 **그 세션이 건넨 것**이면 준다.
데이터, 종류 = ms.agent_session_file_bytes(방, str(결과), source="claude", sid="s1")
assert "결과".encode() in 데이터, 데이터[:40]

# 건넨 적 없는 남의 파일은 여전히 거부한다.
남의것 = 바깥 / "비밀.txt"; 남의것.write_text("secret", encoding="utf-8")
try:
    ms.agent_session_file_bytes(방, str(남의것), source="claude", sid="s1")
    raise AssertionError("건넨 적 없는 파일을 내줬다")
except ValueError:
    pass
print("ok 건네준 파일만 방 밖에서도 받을 수 있다")
PY

echo "PASS test-handoff-collect"
