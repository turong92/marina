#!/usr/bin/env bash
# #상태 꼬리말의 방별 자원 상위(형 2026-11-06) — 실제 ps·tmux·lsof·docker 대신 가짜 출력을 주입해 귀속 규칙을 본다.
#  - 방 = tmux pane 프로세스 + 자손 합 / java 데몬(부모 1)은 cwd 로 방 또는 공용 / 도커는 이름 접두사
#  - 문턱 미만 제외, CPU 순 상위 5, docker 실패해도 동작, 길이 제한, 캐시 TTL, 꼬리말 줄
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import time
import marina_resources as mr
import marina_discord_bot as mb
fails = []
def check(c, m):
    if not c: fails.append(m)
M = 1 << 20; G = 1 << 30
import json, os
from pathlib import Path
Path(os.environ["MARINA_HOME"], "projects.json").write_text(json.dumps({"projects": [
    {"id": "ovation", "root": "/w/ovation"}, {"id": "mdc", "root": "/w/mdc"}]}))
# lsof 는 일부 pid 가 죽어도 종료 코드 1 로 나오지만 stdout 은 쓸 만하다 — 코드를 무시하고 읽는다
check(mr._out(["sh", "-c", "echo hi; exit 1"], any_rc=True) == "hi\n" and mr._out(["sh", "-c", "echo hi; exit 1"]) == "", "any_rc")

recs = [
    {"project": "ovation", "task": "a2-1-plan-execution", "tmux": "mr-a2", "root": "/w/ovation/.claude/worktrees/a2-1-plan-execution-a7130e"},
    {"project": "ovation", "task": "main", "tmux": "mr-main", "root": "/w/ovation"},
    {"project": "mdc", "task": "cloud", "tmux": "mr-cloud", "root": "/w/mdc/cloud-run-migration-refactor"},
]
# pid ppid pcpu rss(KB) comm
PS = """\
 100     1  0.0  1000 /usr/bin/tmux
 200   100  1.0  100000 -zsh
 201   200 80.0  1048576 claude
 202   201 40.0  524288 node
 300   100  0.5  50000 -zsh
 301   300  2.0  300000 claude
 400     1 150.0 2621440 /opt/jdk/bin/java
 401     1 100.0 1048576 /opt/jdk/bin/java
 402     1  90.0 2621440 /opt/jdk/bin/java
 403     1  60.0 1048576 /opt/jdk/bin/java
 405   403 20.0  102400 /opt/jdk/bin/java
 404     1  50.0 524288 /usr/bin/python3
 500     1  3.0  1000 /usr/sbin/cfprefsd
 600   100  1.0  10000 -zsh
 601   600 90.0  2097152 claude
"""
TMUX = "mr-a2 200\nmr-main 300\nmr-cloud 600\nother 999\n"
LSOF = ("p400\nfcwd\nn/w/mdc/cloud-run-migration-refactor/zero/be-s1\n"
        "p401\nfcwd\nn/Users/x/Library/Application Support/kotlin/daemon\n"
        "p402\nfcwd\nn/Users/x/Library/Application Support/kotlin/daemon\n"
        "p403\nfcwd\nn/Users/x/.gradle/daemon/8.5\n"
        "p405\nfcwd\nn/Users/x/Library/Application Support/kotlin/daemon\n")
DOCKER = ("ovation-a2-1-plan-execution-a7130e-server-1\t120.5%\t1.5GiB / 7.7GiB\n"
          "ovation-a2-1-plan-execution-a7130e-db-1\t10.0%\t512MiB / 7.7GiB\n"
          "ovation-main-server-1\t20.0%\t100MiB / 7.7GiB\n"
          "ovation-other-web-1\t30.0%\t256MiB / 7.7GiB\n"
          "stray_container\t1.0%\t10MiB / 7.7GiB\n")
calls = []
def fake(argv, timeout=10.0, any_rc=False):
    base = argv[0].rsplit("/", 1)[-1]
    calls.append(base)
    if base == "ps": return PS
    if base == "tmux" or "tmux" in base: return TMUX
    if base == "lsof":
        # 부모 1 인 java 만 한꺼번에 물어야 한다
        check(sorted(argv[argv.index("-p") + 1].split(",")) == ["400", "401", "402", "403", "405"] and any_rc, f"java 만 한 번에: {argv}")
        return LSOF
    if base == "docker": return DOCKER
    return ""
mr._out = fake
items = {i["ref"]: i for i in mr.room_usage(recs)}
a2 = items["ovation/a2-1-plan-execution"]
check(round(a2["cpu"], 1) == 121.0 and a2["rss"] == (100000 + 1048576 + 524288) * 1024, f"pane 자손 합: {a2}")
check(round(a2["docker_cpu"], 1) == 130.5 and a2["docker_rss"] == int(1.5 * G) + 512 * M, f"도커 접두사 귀속: {a2}")
main = items["ovation/main"]
check(round(main["cpu"], 1) == 2.5 and main["docker_cpu"] == 20.0, f"메인 방은 compose 이름 ovation-main-… 을 가져가고 워크트리 컨테이너는 안 가져간다: {main}")
cloud = items["mdc/cloud"]
check(round(cloud["cpu"], 1) == 241.0, f"cwd 가 방 root 하위인 gradle 데몬은 그 방(90+1 + 150): {cloud}")
check(items["공용 코틀린 데몬"]["cpu"] == 210.0 and items["공용 코틀린 데몬"]["rss"] == (1048576 + 2621440 + 102400) * 1024, f"코틀린 데몬(gradle 데몬 밑 것 포함)은 공용 코틀린으로: {items.get('공용 코틀린 데몬')}")
check(items["공용 gradle 데몬"]["cpu"] == 60.0, f"공용 gradle 데몬: {items.get('공용 gradle 데몬')}")
check(items["공용 도커"]["docker_cpu"] == 31.0, f"주인 모를 컨테이너는 공용 도커: {items.get('공용 도커')}")
check(not any("python" in str(i) for i in items.values()) and calls.count("ps") == 1 and calls.count("lsof") == 1 and calls.count("docker") == 1
      and sum("tmux" in c for c in calls) == 1, f"명령은 한 판에 각 1회: {calls}")

text = mr.usage_text(list(items.values()))
check(text.startswith("🔥 ovation/a2-1-plan-e… 252% · 3.6G · mdc/cloud 241% · 4.5G · "), f"CPU 순 + 20자 자름: {text}")
check(text.count("%") <= 5, f"상위 5개까지: {text}")
check("ovation/main" not in text and "stray" not in text, f"문턱(5%·200MB) 미만은 뺀다: {text}")
check(mr.usage_text([]) == "" and mr.usage_text([{"ref": "x/y", "cpu": 4.0, "rss": 100 * M, "docker_cpu": 0.0, "docker_rss": 0}]) == "", "아무것도 없으면 빈 글")
many = [{"ref": f"p/t{i}", "cpu": 10.0 * (i + 1), "rss": G, "docker_cpu": 0.0, "docker_rss": 0} for i in range(8)]
check(mr.usage_text(many).count("p/t") == 5 and mr.usage_text(many).startswith("🔥 p/t7 80% · 1.0G · p/t6"), f"상위 5: {mr.usage_text(many)}")
check(mr.usage_text([{"ref": "p/t", "cpu": 3.0, "rss": 300 * M, "docker_cpu": 0.0, "docker_rss": 0}]) == "🔥 p/t 3% · 300M", "메모리만 커도 낀다")
check(len(text) < 300, f"텍스트 길이: {len(text)}")
long = [{"ref": "p/" + "x" * 15, "cpu": 100.0 + i, "rss": G, "docker_cpu": 0.0, "docker_rss": 0} for i in range(5)]
check(len(mr.usage_text(long, top=50)) <= 150 and len(mr.usage_text(long)) <= 150, f"자원 줄은 150자 이내: {len(mr.usage_text(long))}")

# docker 가 없거나 실패해도 나머지는 나온다
def nodocker(argv, timeout=10.0, any_rc=False):
    return "" if argv[0].endswith("docker") else fake(argv, timeout, any_rc)
mr._out = nodocker
no = {i["ref"]: i for i in mr.room_usage(recs)}
check(no["ovation/a2-1-plan-execution"]["docker_cpu"] == 0 and "공용 도커" not in no and round(no["mdc/cloud"]["cpu"]) == 241, "docker 실패 = 빼고 진행")
mr._out = lambda argv, timeout=10.0, any_rc=False: ""
check(mr.usage_text(mr.room_usage(recs)) == "", "전부 실패해도 죽지 않고 빈 글")

# 캐시: 읽기는 캐시만, 60초 뒤 재측정, 180초 넘게 묵으면 안 그린다
mr._out = fake
mr._CACHE.clear()
t1 = mr.cached_text(recs, wait=True)
check(t1.startswith("🔥 "), f"처음 재기: {t1}")
n = len(calls); mr.cached_text(recs, wait=True)
check(len(calls) == n, "60초 안엔 다시 재지 않는다")
mr._CACHE[0] = (time.time() - 100, mr._CACHE[0][1]); mr.cached_text(recs, wait=True)
check(len(calls) > n, "60초 지나면 다시 잰다")
mr._CACHE[0] = (time.time() - 1000, mr._CACHE[0][1]); mr._BUSY.set()    # 새로 재는 중이라 쳐도
check(mr.cached_text(recs) == "", "180초 넘게 묵은 값은 안 그린다")
mr._BUSY.clear()

# 스레드를 못 띄워도 BUSY 가 안 남는다
import threading
_real = threading.Thread
class _Boom:
    def __init__(self, *a, **k): pass
    def start(self): raise RuntimeError("no threads")
mr._CACHE.clear(); mr.threading.Thread = _Boom
try:
    mr.cached_text(recs)
except RuntimeError:
    pass
mr.threading.Thread = _real
check(not mr._BUSY.is_set(), "Thread.start 실패 뒤에도 BUSY 해제")

# render: 본체 + 꼬리말이 4000자를 넘지 않게 — 넘치면 자원 줄부터 뺀다
import marina_discord_bot as mb2
def body_of(n): return [{"type": 10, "content": "x" * n}]
mb2._render = lambda snap, lean: body_of(3700)
sn = {"diskFree": G, "resources": "🔥 " + "y" * 140}
out = mb2.render(sn)
check(sn["resources"] and mb2._chars(out) + len(mb2.footer(sn)) < 4000, "한도 안이면 자원 줄을 둔다")
mb2._render = lambda snap, lean: body_of(3880)
sn = {"diskFree": G, "resources": "🔥 " + "y" * 140}
out = mb2.render(sn)
check(sn["resources"] == "" and mb2._chars(out) + len(mb2.footer(sn)) < 4000, f"넘치면 자원 줄을 뺀다: {mb2._chars(out) + len(mb2.footer(sn))}")

# 꼬리말: 맥 줄 다음·박스 줄 앞, 없으면 안 그린다
G_ = 1 << 30
line = mb.footer({"diskFree": 120 * G_, "resources": "🔥 a/b 90% · 1.0G", "boxes": [{"name": "윈도우", "up": False}]})
ls = line.split("\n")
check(len(ls) == 3 and ls[1] == "-# 🔥 a/b 90% · 1.0G" and ls[2] == "-# 윈도우 꺼짐", f"줄 순서: {ls}")
check(mb.footer({"diskFree": G_}).count("\n") == 0, "값이 없으면 줄을 더하지 않는다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-discord-resources"
