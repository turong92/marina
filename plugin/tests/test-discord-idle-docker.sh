#!/usr/bin/env bash
# (형 2026-10-23) 쉰 방을 내려도 그 방 도커는 그대로 떠 있었다(skeleton 10일). 방을 내릴 때 그 워크트리의 compose 프로젝트를 멈추고,
#  다시 켜는 건 자동으로 안 한다(형: 진짜 필요할 때만) — 깨울 때 '멈춰 뒀다, 필요하면 켜라' 한 줄만 넣는다.
#  진짜 도커는 안 건드린다 — PATH 앞에 가짜 docker 를 둔다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
FAKE="$MARINA_HOME/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/docker" <<'SH'
#!/bin/sh
echo "$*" >> "$MARINA_HOME/docker.log"
if [ "$1" = ps ]; then
  printf 'proj-a\t%s\nproj-a\t%s\nother\t/somewhere/else\n' "$ROOM_ROOT" "$ROOM_ROOT"
fi
exit 0
SH
chmod +x "$FAKE/docker"
export PATH="$FAKE:$PATH"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
os.environ["ROOM_ROOT"] = rec["root"]
home = Path(os.environ["MARINA_HOME"]); log = home / "docker.log"
def calls():
    return log.read_text().splitlines() if log.exists() else []
def clear():
    if log.exists(): log.unlink()
real_alive = ms.tmux_alive
ms.tmux_alive = lambda name: False          # 이 방은 막 내린 상태

got = ms.stop_room_docker(rec, sd)
check(got == ["proj-a"], f"그 워크트리의 compose 프로젝트만: {got}")
check("compose -p proj-a stop -t 10" in calls() and not any("other" in c for c in calls() if "stop" in c), f"멈춤: {calls()}")
check(ms._idle_projects(sd) == ["proj-a"], "멈춘 목록을 남긴다")

# (형) 자동으로 안 켠다 — 깨울 때 한 줄 알리고 기록을 지운다
clear()
note = ms.idle_docker_note(sd)
check("proj-a" in note and "marina start" in note and calls() == [], f"안내만, docker 호출 없음: {note} {calls()}")
check(not (sd / ms.IDLE_DOCKER_FILE).exists() and ms.idle_docker_note(sd) == "", "한 번 알리면 끝")

# 다시 내릴 때 앞서 못 켠 것과 합친다
ms._write_json(sd / ms.IDLE_DOCKER_FILE, {"projects": ["old"]})
ms.stop_room_docker(rec, sd)
check(ms._idle_projects(sd) == ["old", "proj-a"], f"합집합: {ms._idle_projects(sd)}")
(sd / ms.IDLE_DOCKER_FILE).unlink()

# 건너뛰는 경우: 채팅방 · 그새 방이 떴음 · 같은 폴더 방이 떠 있음 · 방이 뜨는 중(잠금)
clear()
check(ms.stop_room_docker(dict(rec, kind="chat"), sd) == [], "채팅방은 건너뜀")
ms.tmux_alive = lambda name: name == rec["tmux"]
check(ms.stop_room_docker(rec, sd) == [], "그새 떴으면 안 멈춘다")
other = dict(rec, project="proj", task="other", tmux="proj-other")
real_load = ms.load_sessions
ms.load_sessions = lambda: [rec, other]
ms.tmux_alive = lambda name: name == "proj-other"
check(ms.stop_room_docker(rec, sd) == [], "같은 폴더를 쓰는 방이 떠 있으면 안 멈춘다")
ms.load_sessions = real_load
ms.tmux_alive = lambda name: False
held = ms._try_lock(sd / "docker.lock", 1.0)
real_try = ms._try_lock
ms._try_lock = lambda p, t: real_try(p, 0.3)
check(ms.stop_room_docker(rec, sd) == [], "방이 뜨는 중(잠금)이면 안 멈춘다")
ms._try_lock = real_try; held.close()
check(not any(" stop " in c for c in calls()), f"건너뛸 땐 stop 안 함: {calls()}")

# 방이 뜰 때(cmd_start) 도커를 켜지 않는다
ms._write_json(sd / ms.IDLE_DOCKER_FILE, {"projects": ["proj-a"]}); clear()
ms.tmux_start = lambda *a, **k: None
ms.tmux_alive = lambda name: False
ms.cmd_start("proj/feat/a")
check(not any("start" in c for c in calls()), f"띄울 때 도커 안 켬: {calls()}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-idle-docker"
