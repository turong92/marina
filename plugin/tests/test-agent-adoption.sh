#!/usr/bin/env bash
# 입양(adoption): PTY 안에서 손으로 띄운 에이전트를 훅의 {sid,pid} 기록으로 사후 등록한다.
# argv 파싱 없이 **실제 프로세스 조상 체인**으로만 매칭하는지 본다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

PYTHONPATH="$SCR" python3 - <<'PY'
import os
import marina_agent_procs as ap

table = ap.ps_table()
me = os.getpid()
assert me in table, "ps 테이블에 자기 자신이 없다"
assert table[me][0] == os.getppid(), (table[me], os.getppid())

chain = ap.ancestors(me, table)
assert os.getppid() in chain, chain
assert me not in chain, "조상 체인에 자기 자신이 들어가면 안 된다"
print("ok agent-procs walks the real process tree")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 기록 → 조회 → 죽은 pid 정리
import json, os, subprocess
from pathlib import Path
import marina_agent_procs as ap

d = ap._dir(); d.mkdir(parents=True, exist_ok=True)
live = {"source": "claude", "sid": "sid-live-0001", "pid": os.getpid(),
        "pidStart": ap._pid_start(os.getpid()), "cwd": os.getcwd(), "ts": __import__("time").time()}
(d / "claude-sid-live-0001.json").write_text(json.dumps(live), encoding="utf-8")

got = ap.lookup("claude", "sid-live-0001")
assert got and got["pid"] == os.getpid(), got

# 죽은 프로세스의 기록은 조회 시 정리된다
dead = subprocess.Popen(["true"]); dead.wait()
rec = dict(live, sid="sid-dead-0002", pid=dead.pid, pidStart="Mon Jan  1 00:00:00 2000")
(d / "claude-sid-dead-0002.json").write_text(json.dumps(rec), encoding="utf-8")
assert ap.lookup("claude", "sid-dead-0002") is None
assert not (d / "claude-sid-dead-0002.json").exists(), "죽은 기록이 정리되지 않았다"

records = ap.live_records()
assert [r["sid"] for r in records] == ["sid-live-0001"], records
print("ok agent-procs keeps only live records")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 입양: term.pid 가 기록된 에이전트 pid 의 **조상**이면 그 term 에 세션을 붙인다.
import os
import marina_term as mt
import marina_agent_procs as ap
import json, time

d = ap._dir(); d.mkdir(parents=True, exist_ok=True)
# 이 파이썬 프로세스를 '손으로 띄운 claude' 로 놓고, 그 부모(테스트 셸)를 PTY 의 셸로 놓는다.
agent_pid, shell_pid = os.getpid(), os.getppid()
(d / "claude-sid-adopt-0003.json").write_text(json.dumps({
    "source": "claude", "sid": "sid-adopt-0003", "pid": agent_pid,
    "pidStart": ap._pid_start(agent_pid), "cwd": os.getcwd(), "ts": time.time(),
}), encoding="utf-8")

term = mt._Term(tid="hand-typed", root=os.getcwd(), fd=-1, pid=shell_pid)
other = mt._Term(tid="unrelated", root=os.getcwd(), fd=-1, pid=1)
with mt._lock:
    mt._by_tid[term.tid] = term
    mt._by_tid[other.tid] = other

assert term.agent is None
adopted = mt.adopt_agent_terms()
assert adopted == 1, adopted
assert term.agent == {"source": "claude", "sid": "sid-adopt-0003"}, term.agent
assert other.agent is None, "관계없는 term 까지 입양하면 안 된다"

# 두 번 돌려도 중복으로 붙지 않는다(이미 agent 가 있는 term 은 건너뛴다)
assert mt.adopt_agent_terms() == 0
print("ok adoption attaches a hand-started agent to its own PTY")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 등록부가 비어 있으면 아무것도 하지 않는다(fail-open — 기존 동작 유지)
import os
import marina_term as mt

term = mt._Term(tid="lonely", root=os.getcwd(), fd=-1, pid=os.getppid())
with mt._lock:
    mt._by_tid[term.tid] = term
assert mt.adopt_agent_terms() == 0
assert term.agent is None
print("ok adoption is a no-op without hook records")
PY



PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
# 인수인계(takeover): 붙들고 있는 실제 프로세스를 SIGTERM 으로 끊고 resume 경로로 넘어간다.
import json, os, subprocess, sys, time
from pathlib import Path
import marina_agent_procs as ap
import marina_mobile as mm

root = Path(sys.argv[1]).resolve(); root.mkdir(parents=True, exist_ok=True)
holder = subprocess.Popen(["sleep", "120"])          # 세션을 붙들고 있는 '에이전트'
d = ap._dir(); d.mkdir(parents=True, exist_ok=True)
(d / "claude-sid-take-0004.json").write_text(json.dumps({
    "source": "claude", "sid": "sid-take-0004", "pid": holder.pid,
    "pidStart": ap._pid_start(holder.pid), "cwd": str(root), "ts": time.time(),
}), encoding="utf-8")

mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}              # 조작 가능한 PTY 없음
mm.agents_payload = lambda value, refresh=False, include_all=False: []
opens = []
mm.term_open = lambda *a, **k: opens.append(k) or {"tid": "resumed", "reused": False}

out = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "claude", "sid": "sid-take-0004"},
    "text": "이어서 해줘",
})
assert out == {"ok": True, "tid": "resumed", "opened": True, "takeover": True}, out
assert "interrupted" not in out, "유휴 세션을 넘겨받을 땐 조용해야 한다(잃은 게 없다)"
assert opens and opens[0].get("agent_sid") == "sid-take-0004", opens
assert holder.poll() is not None, "붙들고 있던 프로세스를 끊지 못했다"
assert ap.lookup("claude", "sid-take-0004") is None, "넘겨받은 뒤 옛 등록이 남아 있다"
print("ok takeover terminates the holder and resumes")
PY

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
# pid 를 모르는 세션(데스크톱 앱)도 같은 규칙이다: 작업 중이면 보류, 유휴면 이어받는다.
# 죽일 프로세스를 못 찾아도 유휴 상태면 resume 으로 잇는다 — 그게 이 기능의 목적이다.
import sys
from pathlib import Path
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
busy = {"now": True}
mm.agents_payload = lambda value, refresh=False, include_all=False: [
    {"source": "claude", "sid": "sid-desktop-0005", "status": "working" if busy["now"] else "idle"},
]
opens = []
mm.term_open = lambda *a, **k: opens.append(k) or {"tid": "resumed", "reused": False}

out = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "claude", "sid": "sid-desktop-0005"},
    "text": "데스크톱에서 하던 거 이어서",
})
assert out["delivery"] == "queue", out
assert not opens, "작업 중인 데스크톱 세션에 끼어들었다"

busy["now"] = False
assert mm.mobile_outbox_drain() == 1
assert opens and opens[0].get("agent_sid") == "sid-desktop-0005", opens
print("ok desktop-held sessions queue while busy, resume when idle")
PY
PYTHONPATH="$SCR" python3 - "$TMP" <<'PYEOF'
# **작업 중인 세션은 끊지 않는다.** 보류함에 넣었다가 유휴가 되면 그때 인수인계 후 전달한다.
# (몇 시간짜리 진행을 끼어들기로 날리지 않기 위한 규칙 — 형 지시.)
import json, subprocess, sys, time
from pathlib import Path
import marina_agent_procs as ap
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
holder = subprocess.Popen(["sleep", "120"])
d = ap._dir(); d.mkdir(parents=True, exist_ok=True)
(d / "claude-sid-busy-0006.json").write_text(json.dumps({
    "source": "claude", "sid": "sid-busy-0006", "pid": holder.pid,
    "pidStart": ap._pid_start(holder.pid), "cwd": str(root), "ts": time.time(),
}), encoding="utf-8")

mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
working = {"now": True}
mm.agents_payload = lambda value, refresh=False, include_all=False: [
    {"source": "claude", "sid": "sid-busy-0006", "status": "working" if working["now"] else "idle"},
]
opens = []
mm.term_open = lambda *a, **k: opens.append(k) or {"tid": "resumed", "reused": False}

out = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "claude", "sid": "sid-busy-0006"},
    "text": "끝나면 이거 해줘",
})
assert out["delivery"] == "queue" and out["queued"] == 1, out
assert holder.poll() is None, "작업 중인 세션을 끊었다 — 절대 안 된다"
assert not opens, "작업 중인데 resume 을 열었다"
assert mm.mobile_outbox_pending(root, "claude", "sid-busy-0006") == ["끝나면 이거 해줘"]

# 아직 작업 중이면 드레이너는 아무것도 하지 않는다
assert mm.mobile_outbox_drain() == 0
assert holder.poll() is None
assert mm.mobile_outbox_pending(root, "claude", "sid-busy-0006") == ["끝나면 이거 해줘"]

# 유휴가 되는 순간 인수인계 + 전달
working["now"] = False
assert mm.mobile_outbox_drain() == 1
assert holder.poll() is not None, "유휴가 된 뒤에도 인수인계하지 않았다"
assert opens and opens[0].get("agent_prompt") == "끝나면 이거 해줘", opens
assert mm.mobile_outbox_pending(root, "claude", "sid-busy-0006") == []
print("ok busy sessions are queued, never interrupted")
PYEOF

echo "PASS test-agent-adoption"
