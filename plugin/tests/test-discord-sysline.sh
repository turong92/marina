#!/usr/bin/env bash
# #상태 맨 아랫줄 — CPU·메모리를 한눈에(형 2026-10-06 "부하 숫자는 직관적이지 않다, 메모리도 넣어 줘").
#  - CPU: 전체 코어 중 몇 % 를 쓰는지 + 코어 수보다 일이 많이 밀렸으면 '밀림 N배'. 신호등(🟢🟡🔴)
#  - 메모리: 사용 % + 스왑(1GB 넘을 때). 신호등은 macOS 가 스스로 매긴 압박 단계
#  - 값을 못 읽으면 그 항목만 뺀다(리눅스·명령 실패)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import marina_discord_bot as mb
fails = []
def check(c, m):
    if not c: fails.append(m)
G = 1 << 30
f = lambda **k: mb.footer(dict({"diskFree": 120 * G}, **k))
check(mb.cpu_text(30.0, 3.0, 12) == "CPU 🟢 30%", mb.cpu_text(30.0, 3.0, 12))
check(mb.cpu_text(75.0, 9.0, 12) == "CPU 🟡 75%", mb.cpu_text(75.0, 9.0, 12))
check(mb.cpu_text(68.0, 22.8, 12) == "CPU 🟡 68% · 밀림 1.9배", f"코어보다 일이 많으면 밀림: {mb.cpu_text(68.0, 22.8, 12)}")
check(mb.cpu_text(97.0, 50.0, 12) == "CPU 🔴 97% · 밀림 4.2배", mb.cpu_text(97.0, 50.0, 12))
check(mb.cpu_text(250.0, 1.0, 2) == "CPU 🔴 100%", f"100% 를 넘겨 적지 않는다: {mb.cpu_text(250.0, 1.0, 2)}")
check(mb.cpu_text(None, 3.0, 12) == "" and mb.cpu_text(30.0, 3.0, 0) == "", "못 읽으면 뺀다")
check(mb.mem_text(63.0, 1, 0.2 * G) == "메모리 🟢 63%", mb.mem_text(63.0, 1, 0.2 * G))
check(mb.mem_text(63.0, 2, 10.6 * G) == "메모리 🟡 63% · 스왑 10.6GB", f"압박 단계 2 = 노랑, 스왑 1GB↑ 표시: {mb.mem_text(63.0, 2, 10.6 * G)}")
check(mb.mem_text(95.0, 4, 30 * G) == "메모리 🔴 95% · 스왑 30GB", mb.mem_text(95.0, 4, 30 * G))
check(mb.mem_text(91.0, None, None) == "메모리 🔴 91%" and mb.mem_text(50.0, None, None) == "메모리 🟢 50%", "압박 단계를 모르면 사용률로")
check(mb.mem_text(None, 2, 1) == "", "못 읽으면 뺀다")
line = f(cpu=68.0, load=22.8, ncpu=12, memUsed=63.0, memLevel=2, swapUsed=10.6 * G)
check(line.startswith("-# 디스크 120GB 남음 · CPU 🟡 68% · 밀림 1.9배 · 메모리 🟡 63% · 스왑 10.6GB · <t:"), f"한 줄: {line}")
check("부하" not in line, "날것의 부하 숫자는 뺀다")
check(f().startswith("-# 디스크 120GB 남음 · <t:"), f"값이 없으면 디스크만: {f()}")
# 무거운 명령 줄(heavy) 현황 — 상태 폴더가 있으면 '🧪 실행 N · 대기 M'. 죽은 pid 가 남긴 파일은 세지 않는다
import json, os, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory() as d:
    os.environ["HEAVY_HOME"] = d
    check(mb.heavy_counts() == (0, 0), f"빈 폴더: {mb.heavy_counts()}")
    me = os.getpid()
    Path(d, "slot-0.json").write_text(json.dumps({"pid": me, "label": "gradlew test"}))
    Path(d, "slot-1.json").write_text(json.dumps({"pid": 99999999, "label": "죽은 것"}))
    Path(d, "slot-2.json").write_text("{깨진")
    Path(d, f"waiting-{me}.json").write_text("{}")
    Path(d, "waiting-99999999.json").write_text("{}")
    check(mb.heavy_counts() == (1, 1), f"산 것만 센다: {mb.heavy_counts()}")
    line = mb.footer(dict({"diskFree": 120 * G}, heavy=mb.heavy_counts()))
    check("· 🧪 실행 1 · 대기 1 ·" in line, f"아랫줄: {line}")
    check("🧪" not in mb.footer({"diskFree": G, "heavy": (0, 0)}) and "🧪" not in mb.footer({"diskFree": G}), "아무것도 없으면 안 그린다")
    check(mb.footer({"diskFree": G, "heavy": (2, 0)}).count("대기") == 0, "대기가 없으면 실행만")
os.environ["HEAVY_HOME"] = "/nonexistent/heavy"
check(mb.heavy_counts() is None, "줄 장치가 없는 맥은 None")
# 실제 읽기 — 형태만(이 맥이든 리눅스든 죽지 않는다)
s = mb.sys_stats()
check(set(s) == {"cpu", "ncpu", "memUsed", "memLevel", "swapUsed", "heavy"}, f"키: {s}")
check(all(v is None or isinstance(v, (int, float)) for k, v in s.items() if k != "heavy"), f"숫자 또는 None: {s}")
# 원격 박스(형 2026-11-05 "디스코드 상태에 윈도우도") — 설정 statusBoxes 의 ssh 별칭을 뒤에서 읽어 아랫줄에 붙인다
check(mb.parse_box("CPU=12.5 MEM=40.2 HEAVY=1\n") == {"cpu": 12.5, "mem": 40.2, "heavy": 1}, mb.parse_box("CPU=12.5 MEM=40.2 HEAVY=1\n"))
check(mb.parse_box("garbage") is None and mb.parse_box("") is None, "못 읽으면 None")
up = {"name": "윈도우", "up": True, "cpu": 12.5, "mem": 40.2, "heavy": 1}
check(mb.box_text(up) == "윈도우 CPU 🟢 13% · 메모리 🟢 40% · 🧪 1", mb.box_text(up))
check(mb.box_text(dict(up, cpu=95.0, mem=85.0, heavy=0)) == "윈도우 CPU 🔴 95% · 메모리 🟡 85%", mb.box_text(dict(up, cpu=95.0, mem=85.0, heavy=0)))
check(mb.box_text({"name": "윈도우", "up": False}) == "윈도우 꺼짐", mb.box_text({"name": "윈도우", "up": False}))
line = mb.footer({"diskFree": G, "boxes": [up]})
check(" · 윈도우 CPU 🟢 13% · 메모리 🟢 40% · 🧪 1 · <t:" in line, f"아랫줄 시각 앞: {line}")
check("윈도우" not in mb.footer({"diskFree": G, "boxes": []}), "박스가 없으면 안 그린다")
calls = []
mb._box_probe = lambda ssh: calls.append(ssh) or "CPU=1 MEM=2 HEAVY=0"
check(mb.box_stats({}) == [] and calls == [], "설정이 없으면 ssh 를 안 부른다")
first = mb.box_stats({"statusBoxes": [{"name": "윈도우", "ssh": "win-x"}]}, wait=True)
check(first == [{"name": "윈도우", "up": True, "cpu": 1.0, "mem": 2.0, "heavy": 0}] and calls == ["win-x"], f"읽기: {first} {calls}")
mb._box_probe = lambda ssh: None
mb._BOX_CACHE.clear()
check(mb.box_stats({"statusBoxes": [{"name": "윈도우", "ssh": "win-x"}]}, wait=True) == [{"name": "윈도우", "up": False}], "연결 실패 = 꺼짐")
import time as _t
mb._BOX_CACHE["win-y"] = (_t.time() - 3600, {"name": "옛", "up": True, "cpu": 95.0, "mem": 1.0, "heavy": 2})
mb._BOX_BUSY.add("win-y")      # 새로 읽는 중이라 쳐도
check(mb.box_stats({"statusBoxes": [{"name": "옛", "ssh": "win-y"}]}) == [], "묵은 값(3분↑)은 안 그린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
PY
echo "PASS test-discord-sysline"
