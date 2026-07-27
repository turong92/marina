#!/usr/bin/env bash
# 에이전트 **새 세션** 직접 launch (A) — sid 없는 실행이 resume 과 갈라지는지, 그리고 그 PTY 가
# 나중에 입양으로 정체를 얻는지. (워크트리 만들고 → 셸 열고 → `claude` 치던 3스텝을 없애는 경로.)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_term as mt

# sid 있음 = resume, sid 없음 = 새 세션
assert mt._agent_cli("claude", "abc-123") == ["claude", "--resume", "abc-123"]
assert mt._agent_cli("claude", "") == ["claude"], mt._agent_cli("claude", "")
assert mt._agent_cli("codex", "abc-123")[:2] == ["codex", "resume"]
assert mt._agent_cli("codex", "") == ["codex"], mt._agent_cli("codex", "")

# 모델/노력은 새 세션에도 그대로 실린다
assert mt._agent_cli("claude", "", "", "claude-opus-5", "high") == [
    "claude", "--model", "claude-opus-5", "--effort", "high"]

# 형식이 틀린 sid 는 여전히 거절한다(빈 값만 새 세션)
for bad in ("../etc", "a b", "x" * 200):
    try:
        mt._agent_cli("claude", bad)
        raise AssertionError(f"잘못된 sid 를 통과시켰다: {bad!r}")
    except ValueError:
        pass
print("ok sid-less launch is a new session, not a resume")
PY

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
# 재사용 키는 같은 세션의 이중 resume 만 막아야 한다. 새 세션 launch 는 누를 때마다 새 PTY 여야 한다.
# 실제 term_open 을 태운다 — pty.fork 만 가짜로 바꿔 자식 프로세스를 만들지 않는다.
import os, sys
from pathlib import Path
import marina_term as mt

root = Path(sys.argv[1]) / "wt"; root.mkdir(parents=True, exist_ok=True)
spawned = []
slaves = []                              # 열어둔다 — 닫으면 읽기 스레드가 즉시 EOF 로 세션을 수거한다
import pty as real_pty
class FakePty:
    @staticmethod
    def fork():
        spawned.append(True)
        master, slave = real_pty.openpty()   # 진짜 tty — term_open 이 winsize ioctl 을 건다
        slaves.append(slave)
        return 4242 + len(spawned), master   # (pid, fd) — 자식은 만들지 않는다
mt.pty = FakePty
mt._pid_start = lambda pid: "fake-start"
mt._alive = lambda pid, start="": True   # 열자마자 수거되지 않게

first = mt.term_open(root, agent_source="claude", agent_sid="")
second = mt.term_open(root, agent_source="claude", agent_sid="")
assert first["tid"] != second["tid"], (first, second)
assert not second.get("reused"), second
assert len(spawned) == 2, spawned        # 진짜로 두 번 띄웠다

resume1 = mt.term_open(root, agent_source="claude", agent_sid="abc-123")
resume2 = mt.term_open(root, agent_source="claude", agent_sid="abc-123")
assert resume1["tid"] == resume2["tid"], (resume1, resume2)   # 같은 세션은 재사용(이중 resume 방지)
assert resume2.get("reused"), resume2
assert len(spawned) == 3, spawned        # resume 두 번째는 새로 띄우지 않았다
print("ok new-session launches never collapse into one PTY")
PY

# 배선 확인: 모바일 launch 엔드포인트와 웹 카드 버튼이 실제로 서빙되는지.
html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')"
for needle in '/mobile/api/launch' 'data-launch="claude"' 'data-launch="codex"' 'function launchAgent' 'wt-group-head'; do
  grep -qF "$needle" <<<"$html" || { echo "FAIL: 모바일 launch 배선 누락 — $needle"; exit 1; }
done
grep -qF "openAgentTerminal(session.root, { source: agent.source })" "$SCR/marina-web/app-5b-actions.js" \
  || { echo "FAIL: 웹 카드 ＋CC/＋CX 배선 누락"; exit 1; }
grep -qF '"/mobile/api/launch"' "$SCR/marina_handler.py" || { echo "FAIL: launch 라우트 없음"; exit 1; }

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
# 갓 launch 한 세션은 **아직 sid 가 없다**(훅이 뜨기 전). 그런 PTY 를 "에이전트 카드가 대신
# 보여주겠지" 하고 목록에서 빼면 카드가 어디에도 안 남아 열 수가 없다 — 실기기에서 잡힌 회귀.
import sys
from pathlib import Path
import marina_mobile as mm

root = Path(sys.argv[1]) / "wt"; root.mkdir(parents=True, exist_ok=True)
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_info = lambda r, refresh=False: {"id": "wt", "alias": "", "projectLabel": "p"}
mm._live_agent_cwds = lambda refresh=False: set()
mm.agents_payload = lambda r, refresh=False: [{"source": "claude", "sid": "sid-known-0001", "status": "idle"}]
mm.term_list = lambda: {"sessions": [
    {"tid": "t-fresh", "root": str(root), "agent": {"source": "claude", "sid": ""}, "alive": True},
    {"tid": "t-known", "root": str(root), "agent": {"source": "claude", "sid": "sid-known-0001"}, "alive": True},
    {"tid": "t-plain", "root": str(root), "alive": True},
]}

keys = [s["key"] for s in mm.mobile_state()["sessions"]]
assert "term:t-fresh" in keys, f"갓 띄운 세션이 목록에서 사라졌다: {keys}"
assert "term:t-plain" in keys, keys
# sid 가 붙은 PTY 는 에이전트 카드가 대신하므로 중복 노출하지 않는다
assert "term:t-known" not in keys, keys
assert f"agent:claude:sid-known-0001:{root}" in keys, keys
print("ok a freshly launched (sid-less) session stays visible in the list")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# 입양으로 sid 가 붙으면 term 카드는 사라지고 agent 카드로 승격된다 —
# 그 순간 열어둔 화면이 빈 세션이 되지 않게 선택을 옮겨줘야 한다.
from marina_mobile import render_mobile_html
html = render_mobile_html()
for needle in ("function migrateSelectionOnPromotion", "migrateSelectionOnPromotion()", "ensureLiveTermSession(d.tid"):
    assert needle in html, f"승격 인수인계 배선 누락 — {needle}"
print("ok promotion hands the open screen over to the agent session")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
# mobile_launch 는 source 를 검증한다(임의 실행 방지)
import marina_mobile as mm
from pathlib import Path
mm.safe_root = lambda v: Path(".").resolve()
for bad in ("", "bash", "claude; rm -rf /"):
    try:
        mm.mobile_launch({"root": ".", "source": bad})
        raise AssertionError(f"허용되면 안 되는 source: {bad!r}")
    except ValueError:
        pass
print("ok launch rejects unknown agent sources")
PY

echo "PASS test-agent-launch"
