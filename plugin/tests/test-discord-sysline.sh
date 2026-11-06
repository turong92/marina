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
import sys
G = 1 << 30
f = lambda **k: mb.footer(dict({"diskFree": 120 * G}, **k))
# 맥 섹션(형 2026-11-06 "안직관적") — 줄마다 `이름 신호등 값 막대`, 못 읽은 값은 그 줄을 뺀다
check(mb.cpu_line(30.0, 3.0, 12) == "CPU 🟢 30% `███░░░░░░░` 12코어 중 3.6개", mb.cpu_line(30.0, 3.0, 12))
check(mb.cpu_line(75.0, 9.0, 12).startswith("CPU 🟡 75% `████████░░`"), mb.cpu_line(75.0, 9.0, 12))
check(mb.cpu_line(72.0, 31.2, 12) == "CPU 🔴 72% `███████░░░` 12코어 중 8.6개 · 밀림 2.6배",f"밀림 2배↑ = 빨강: {mb.cpu_line(72.0, 31.2, 12)}")
check(mb.cpu_line(68.0, 22.8, 12) == "CPU 🟡 68% `███████░░░` 12코어 중 8.2개 · 밀림 1.9배", f"코어보다 일이 많으면 밀림: {mb.cpu_line(68.0, 22.8, 12)}")
check(mb.cpu_line(97.0, 50.0, 12).startswith("CPU 🔴 97% `██████████` 12코어 중 11.6개 · 밀림 4.2배"), mb.cpu_line(97.0, 50.0, 12))
check(mb.cpu_line(250.0, 1.0, 2) == "CPU 🔴 100% `██████████` 2코어 중 2.0개", f"100% 를 넘겨 적지 않는다: {mb.cpu_line(250.0, 1.0, 2)}")
check(mb.cpu_line(None, 3.0, 12) == "" and mb.cpu_line(30.0, 3.0, 0) == "", "못 읽으면 뺀다")
check(mb.mem_line(63.0, 1, 36 * G) == "메모리 🟢 22.7 / 36GB (63%) `██████░░░░`", mb.mem_line(63.0, 1, 36 * G))
check(mb.mem_line(59.0, 2, 36 * G) == "메모리 🟡 21.2 / 36GB (59%) `██████░░░░`", f"압박 단계 2 = 노랑: {mb.mem_line(59.0, 2, 36 * G)}")
check(mb.mem_line(95.0, 4, 36 * G).startswith("메모리 🔴 34.2 / 36GB (95%)"), mb.mem_line(95.0, 4, 36 * G))
check(mb.mem_line(91.0, None, None) == "메모리 🔴 91% `█████████░`" and mb.mem_line(50.0, None, 8 * G).startswith("메모리 🟢 4 / 8GB (50%)"), "압박 단계를 모르면 사용률로, 전체를 모르면 %만")
check(mb.mem_line(None, 2, 36 * G) == "", "못 읽으면 뺀다")
check(mb.swap_line(9 * G, 11 * G) == "스왑 🔴 9 / 11GB `████████░░`" and mb.swap_line(8.5 * G, 11 * G).startswith("스왑 🟡 8.5 / 11GB"), f"≥80% 빨강: {mb.swap_line(9 * G, 11 * G)}")
check(mb.swap_line(6 * G, 11 * G).startswith("스왑 🟡 6 / 11GB") and mb.swap_line(3 * G, 11 * G).startswith("스왑 🟢 3 / 11GB"), "≥50% 노랑, 미만 초록")
check(mb.swap_line(0.9 * G, 1 * G).startswith("스왑 🟢"), "1GB 미만이면 비율이 높아도 초록")
check(mb.swap_line(None, 11 * G) == "" and mb.swap_line(1 * G, None) == "" and mb.swap_line(0, 0) == "", "못 읽거나 스왑이 없으면 뺀다")
line = f(cpu=72.0, load=31.2, ncpu=12, memUsed=59.0, memLevel=2, memTotal=36 * G, swapUsed=9 * G, swapTotal=11 * G)
ls = line.split("\n")
check(ls[0] == "### 🖥 맥" and ls[1].startswith("CPU 🔴 72%") and ls[2].startswith("메모리 🟡 21.2 / 36GB") and ls[3].startswith("스왑 🔴 9 / 11GB"), f"맥 섹션 순서: {ls}")
check(ls[4].startswith("-# 디스크 120GB 남음 · <t:") and len(ls) == 5, f"디스크·시각은 작은 글씨 한 줄: {ls}")
check("부하" not in line, "날것의 부하 숫자는 뺀다")
ls = f(cpu=None, memUsed=None, swapUsed=None).split("\n")
check(ls[0] == "### 🖥 맥" and ls[1].startswith("-# 디스크 120GB 남음 · <t:") and len(ls) == 2, f"값이 없으면 디스크만: {ls}")
ls = f(cpu=30.0, load=1.0, ncpu=4, memUsed=None, swapUsed=None).split("\n")
check(len(ls) == 3 and ls[1].startswith("CPU") and ls[2].startswith("-# 디스크"), f"못 읽은 메모리·스왑 줄만 빠진다: {ls}")
check(mb.footer({"diskFree": G, "resources": "### 🔥 많이 쓰는 곳\nX"}).endswith("\n### 🔥 많이 쓰는 곳\nX") and mb.footer({"diskFree": G, "resources": "R", "boxes": [{"name": "윈도우", "up": False}]}).split("\n")[-2:] == ["-# 윈도우 꺼짐", "R"], "자원 표는 맥 섹션·박스 줄 아래")
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
check(set(s) == {"cpu", "ncpu", "memUsed", "memLevel", "memTotal", "swapUsed", "swapTotal", "heavy"}, f"키: {s}")
check(sys.platform != "darwin" or (s["memTotal"] and s["memTotal"] > 1 << 30), f"맥이면 메모리 전체(hw.memsize): {s}")
check(all(v is None or isinstance(v, (int, float)) for k, v in s.items() if k != "heavy"), f"숫자 또는 None: {s}")
# 원격 박스(형 2026-11-05 "디스코드 상태에 윈도우도") — 설정 statusBoxes 의 ssh 별칭을 뒤에서 읽어 아랫줄에 붙인다
check(mb.parse_box("CPU=12.5 MEM=40.2 HEAVY=1\n") == {"cpu": 12.5, "mem": 40.2, "heavy": 1}, mb.parse_box("CPU=12.5 MEM=40.2 HEAVY=1\n"))
check(mb.parse_box("garbage") is None and mb.parse_box("") is None, "못 읽으면 None")
up = {"name": "윈도우", "up": True, "cpu": 12.5, "mem": 40.2, "heavy": 1}
check(mb.box_text(up) == "윈도우 CPU 🟢 13% · 메모리 🟢 40% · 🧪 1", mb.box_text(up))
check(mb.box_text(dict(up, cpu=95.0, mem=85.0, heavy=0)) == "윈도우 CPU 🔴 95% · 메모리 🟡 85%", mb.box_text(dict(up, cpu=95.0, mem=85.0, heavy=0)))
check(mb.box_text({"name": "윈도우", "up": False}) == "윈도우 꺼짐", mb.box_text({"name": "윈도우", "up": False}))
line = mb.footer({"diskFree": G, "boxes": [up]})
check(line.endswith(" 갱신\n-# 윈도우 CPU 🟢 13% · 메모리 🟢 40% · 🧪 1"), f"박스는 자기 줄로(형 2026-11-05 '줄바꿈'): {line}")
check(line.split("\n")[:2] == ["### 🖥 맥", line.split("\n")[1]] and line.split("\n")[1].startswith("-# 디스크") and line.count("\n") == 2, f"맥 섹션 아래 디스크 줄, 그 아래 박스 줄: {line}")
check("윈도우" not in mb.footer({"diskFree": G, "boxes": []}), "박스가 없으면 안 그린다")
calls = []
mb._box_probe = lambda ssh: calls.append(ssh) or "CPU=1 MEM=2 HEAVY=0"
check(mb.box_stats({}) == [] and calls == [], "설정이 없으면 ssh 를 안 부른다")
first = mb.box_stats({"statusBoxes": [{"name": "윈도우", "ssh": "win-x"}]}, wait=True)
hf = Path(os.environ["MARINA_HOME"], "remote-health", "ssh_win-x.json")
check(hf.is_file() and json.loads(hf.read_text())["up"] is True, "붙으면 런타임 접속 기록에 남긴다(순간 끊김 판단용)")
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
