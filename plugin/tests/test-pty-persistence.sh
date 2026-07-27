#!/usr/bin/env bash
# PTY 레지스트리 영속화 + 부팅 재구성 — marina-control 재시작 후에도 살아있는 에이전트 세션의
# reachability 가 살아남아야 한다(mobile 배달 거부·reuse-by-key miss·waiting 승격 깨짐 방지).
# 인메모리 _by_tid/_by_key 는 재시작에 통째로 날아가므로 terms/<tid>.json 에 최소 메타를 남기고
# 부팅 때 os.kill(pid,0) 로 프로세스 생존을 검증해 fd 없는(detached) term 으로 재등록한다.
# 이 테스트는 (1)살아있는 pid 메타 → term_list/reuse-by-key 에 반영 (2)죽은 pid 메타 → 미등록+파일 삭제
# (3)detached term 에 대한 term_input 은 트레이스백이 아니라 명확한 에러로 실패함을 못박는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# 실 MARINA_HOME 을 건드리지 않도록 임시 디렉토리로 격리(marina_state 가 import 시점에 env 를 읽음).
export MARINA_HOME="$TMP/home"
WT="$TMP/wt"
mkdir -p "$WT"

python3 - "$SCR" "$MARINA_HOME" "$WT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

scr, home, wt = sys.argv[1:4]
sys.path.insert(0, scr)
import marina_term as mt

fails = []
terms_dir = Path(home) / "terms"
terms_dir.mkdir(parents=True, exist_ok=True)

# ── 1) 살아있는 pid 메타 → 재구성 후 term_list/reuse-by-key 에 반영 ──────────────────
live_pid = os.getpid()   # 현재 python 프로세스 — 확실히 살아있다

def pid_start(pid):
    import subprocess
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                         capture_output=True, text=True, timeout=2).stdout.strip()
    return out.splitlines()[0].strip() if out else ""

live_tid = "livetid0000000a"
key = f"{wt}::agent:claude:sid-alive-0001"
(terms_dir / f"{live_tid}.json").write_text(json.dumps({
    "tid": live_tid, "cwd": wt, "pid": live_pid, "pid_start": pid_start(live_pid),
    "source": "claude", "sid": "sid-alive-0001", "key": key,
    "created": 1000.0,
}), encoding="utf-8")

# ── 2) 죽은 pid 메타 → 미등록 + 파일 삭제 ──────────────────────────────────────────
#     자식을 spawn 후 reap 해 확실히 죽은 pid 를 얻는다(pid 재사용 전 os.kill(0)==ESRCH).
p = subprocess.Popen([sys.executable, "-c", "pass"])
p.wait()
dead_pid = p.pid
dead_tid = "deadtid00000000b"
dead_file = terms_dir / f"{dead_tid}.json"
dead_file.write_text(json.dumps({
    "tid": dead_tid, "cwd": wt, "pid": dead_pid,
    "source": "claude", "sid": "sid-dead-0001", "key": "", "created": 900.0,
}), encoding="utf-8")

# ── 2b) pid 재사용 방어 — 살아있는 pid 지만 저장된 pid_start 가 실제와 다름 → 무관 프로세스로 판단, 거부+삭제
recyc_tid = "recyctid000000c"
recyc_file = terms_dir / f"{recyc_tid}.json"
recyc_file.write_text(json.dumps({
    "tid": recyc_tid, "cwd": wt, "pid": live_pid,           # 살아있는 pid
    "pid_start": "Wed Jan  1 00:00:00 2000",                # 실제 시작시각과 절대 안 맞음
    "source": "claude", "sid": "sid-recyc-0001", "key": "", "created": 800.0,
}), encoding="utf-8")

# ── 2c) 파싱 불가 JSON → 재구성 시 삭제(매 부팅 재읽기 방지)
junk_tid = "junktid00000000d"
junk_file = terms_dir / f"{junk_tid}.json"
junk_file.write_text("{ this is not valid json", encoding="utf-8")

# 재구성 트리거(lazy, 1회) — term_list 가 _reconstruct_registry 를 태운다.
sessions = mt.term_list().get("sessions", [])
by_tid = {s["tid"]: s for s in sessions}

# 1) 살아있는 pid → 등록, alive/reachable, agent 메타 보존.
if live_tid not in by_tid:
    fails.append("live-pid meta should be reconstructed into term_list")
else:
    s = by_tid[live_tid]
    if not s.get("alive"):
        fails.append(f"reconstructed live term must report alive, got {s.get('alive')}")
    if str(s.get("root")) != wt:
        fails.append(f"reconstructed root mismatch: {s.get('root')} != {wt}")
    agent = s.get("agent") or {}
    if agent.get("source") != "claude" or agent.get("sid") != "sid-alive-0001":
        fails.append(f"reconstructed agent meta lost: {agent}")

# reuse-by-key: 같은 agent 로 term_open → 재구성된 detached term 을 재사용해야 한다(이중 resume 방지).
d = mt.term_open(Path(wt), 80, 24, agent_source="claude", agent_sid="sid-alive-0001")
if not d.get("reused") or d.get("tid") != live_tid:
    fails.append(f"reuse-by-key should hit reconstructed term, got {d}")

# 2) 죽은 pid → 미등록 + 파일 삭제.
if dead_tid in by_tid:
    fails.append("dead-pid meta must NOT be registered")
if dead_file.exists():
    fails.append("dead-pid meta file must be deleted on reconstruction")

# 2b) 재사용 pid(지문 불일치) → 살아있어도 미등록 + 파일 삭제.
if recyc_tid in by_tid:
    fails.append("recycled-pid meta (pid_start mismatch) must NOT be registered even though pid is alive")
if recyc_file.exists():
    fails.append("recycled-pid meta file must be deleted on reconstruction")

# 2c) 파싱 불가 JSON → 미등록 + 파일 삭제.
if junk_tid in by_tid:
    fails.append("unparseable-json meta must NOT be registered")
if junk_file.exists():
    fails.append("unparseable-json meta file must be deleted on reconstruction")

# ── 3) detached term 에 대한 term_input 은 명확한 에러(트레이스백 X) ─────────────────
try:
    mt.term_input(live_tid, "echo hi\n")
    fails.append("term_input on adopted/detached term should raise, not succeed")
except ValueError:
    pass   # 기대: 사람이 읽을 수 있는 ValueError
except Exception as e:   # bad fd 트레이스백 등은 실패
    fails.append(f"term_input on detached term raised non-graceful {type(e).__name__}: {e}")

# term_resize 는 detached 여도 크래시 없이 no-op 이어야 한다.
try:
    mt.term_resize(live_tid, 100, 30)
except Exception as e:
    fails.append(f"term_resize on detached term should be a safe no-op, raised {type(e).__name__}: {e}")

# detached term 이 term_list 에 계속 보이는지(reachability 유지) — 위에서 이미 alive 확인.
# 마지막으로: 살아있는 term 파일은 재구성 후에도 남아있어야 한다(다음 재시작에도 복원 가능).
if not (terms_dir / f"{live_tid}.json").exists():
    fails.append("live term meta file must remain after reconstruction")

if fails:
    print("FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("PASS: PTY registry persists+reconstructs; live reachable/reusable, dead purged, detached input fails gracefully")
PY
