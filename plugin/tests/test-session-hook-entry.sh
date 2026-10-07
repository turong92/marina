#!/usr/bin/env bash
# 세션 훅은 버전 폴더가 아니라 고정 입구(~/.marina/bin/marina-session-hook)를 부른다 —
# 입구가 부를 때마다 설치 목록에서 최신 마리나를 찾으므로, 새 버전을 깔면 떠 있는 세션도 재시작 없이 새 코드를 쓴다.
# (작업 트리에서 도는 테스트처럼 설치본이 아닌 곳에서 실행되면 예전처럼 직접 경로)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
fail() { echo "FAIL: $*"; exit 1; }
CHOME="$TMPROOT/claudehome"; mkdir -p "$CHOME/plugins"
V1="$(cd "$DSCRIPTS/.." && pwd -P)"
printf '{"version":2,"plugins":{"marina-discord@test-market":[{"installPath":"%s"}]}}\n' "$V1" > "$CHOME/plugins/installed_plugins.json"
export MARINA_CLAUDE_HOME="$CHOME"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" V1="$V1" python3 - "$TMPROOT" "$CHOME" <<'PY'
import json, os, subprocess, sys
V1 = os.environ["V1"]
from pathlib import Path
import marina_session as ms
tmp, chome = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
sd = tmp / "sd"; sd.mkdir()
ms.write_settings(sd)
st = json.loads((sd / "settings.json").read_text())
cmds = [h["command"] for ev in st["hooks"].values() for e in ev for h in e["hooks"]]
shim = ms.marina_home() / "bin" / "marina-session-hook"
check(shim.is_file() and os.access(shim, os.X_OK), "고정 입구 생성")
check(cmds and all(str(shim) in c for c in cmds), f"훅이 전부 고정 입구를 부른다: {cmds}")
check(str(Path(ms.__file__).resolve().parent) not in " ".join(cmds), "버전 폴더 경로가 박히지 않는다")
mcp = json.loads((sd / "mcp.json").read_text())["mcpServers"]["marina"]
check(mcp["command"] == str(shim), f"MCP 도 같은 입구: {mcp}")
r = subprocess.run([str(shim), "hook-stop"], input="{}", text=True, capture_output=True, env=dict(os.environ, DISCORD_STATE_DIR=str(sd)))
check(r.returncode == 0, f"입구로 훅 실행: {r.stderr}")
# 입구 본문은 배포마다 바뀌면 안 된다 — macOS 가 "백그라운드 항목이 추가됨" 알림을 띄운다(LaunchAgent 가 이 파일을 실행). 바뀌는 값은 옆 파일로
body0 = shim.read_text(); side = shim.with_name("marina-session-hook.path")
check(side.is_file(), "바뀌는 값(폴백 경로·파이썬)은 옆 파일 marina-session-hook.path 에")
check(str(Path(ms.__file__).resolve()) not in body0 and sys.executable not in body0, "입구 본문에 설치 버전 폴더·파이썬 경로가 박히지 않는다")
v9 = tmp / "v9"; (v9 / "scripts").mkdir(parents=True)
real_file, real_exe = ms.__file__, sys.executable
ms.__file__ = str(v9 / "scripts" / "marina_session.py"); sys.executable = "/other/python9"
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"marina-discord@test-market": [{"installPath": str(v9)}]}}))
mt = shim.stat().st_mtime_ns; mt_side = side.stat().st_mtime_ns
import time; time.sleep(0.05)
ms._hook_entry()
check(shim.read_text() == body0 and shim.stat().st_mtime_ns == mt, "다른 버전·파이썬으로 다시 써도 입구 본문·mtime 은 그대로")
check("v9" in side.read_text() and "/other/python9" in side.read_text(), f"옆 파일이 새 값을 담는다: {side.read_text()!r}")
mt_side = side.stat().st_mtime_ns; time.sleep(0.05); ms._hook_entry()
check(side.stat().st_mtime_ns == mt_side, "같은 내용이면 옆 파일도 다시 쓰지 않는다")
ms.__file__, sys.executable = real_file, real_exe
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"marina-discord@test-market": [{"installPath": str(V1)}]}}))
ms._hook_entry()
# 새 버전 설치 → 같은 입구가 새 버전을 부른다(재시작 없음)
v2 = tmp / "v2" / "scripts"; v2.mkdir(parents=True)
(v2 / "marina_session.py").write_text("import sys; print('V2', sys.argv[1:])\n")
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"marina-discord@test-market": [{"installPath": str(v2.parent)}]}}))
r = subprocess.run([str(shim), "hook-stop"], input="{}", text=True, capture_output=True)
check(r.stdout.strip() == "V2 ['hook-stop']", f"새 버전을 부른다: {r.stdout!r} {r.stderr!r}")
# 설치 목록이 깨지면 만들 때의 경로로(멈추지 않게)
(chome / "plugins" / "installed_plugins.json").write_text("broken")
r = subprocess.run([str(shim), "hook-stop"], input="{}", text=True, capture_output=True, env=dict(os.environ, DISCORD_STATE_DIR=str(sd)))
check(r.returncode == 0 and "V2" not in r.stdout, f"폴백: {r.stdout!r} {r.stderr!r}")
# 설치 목록도 폴백 경로도 없으면 빈 인자로 python 을 돌리지 않는다 — 조용히 0 으로 끝
side.write_text("\n\n")
(chome / "plugins" / "installed_plugins.json").write_text("broken")
r = subprocess.run([str(shim), "hook-stop"], input="{}", text=True, capture_output=True)
check(r.returncode == 0 and r.stderr.strip() == "", f"대상이 비면 exit 0: rc={r.returncode} {r.stderr!r}")
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"marina-discord@test-market": [{"installPath": V1}]}}))
ms._hook_entry()
# 설치본이 아닌 곳(작업 트리 테스트)에서 실행되면 예전처럼 직접 경로
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {}}))
ms.write_settings(sd)
st = json.loads((sd / "settings.json").read_text())
check("marina-session-hook" not in json.dumps(st), "설치본 밖이면 직접 경로")
# 리뷰 D-I1: 입구는 키 하나에 묶이지 않는다 — marina-discord@ 를 먼저, 그 설치본에 파일이 없으면 다음 키(옛 marina@)
nv = tmp / "nodiscord"; (nv / "scripts").mkdir(parents=True)          # 새 marina@ 설치본(discord 파일 없음)
disc = Path(ms.__file__).resolve().parent.parent
def which(plugins):
    (chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": plugins}))
    return subprocess.run([str(shim)], capture_output=True, text=True, env=dict(os.environ, MARINA_SHIM_WHICH="1")).stdout.strip()
got = which({"marina@test-market": [{"installPath": str(nv)}], "marina-discord@test-market": [{"installPath": str(disc)}]})
check(got == str(disc / "scripts" / "marina_session.py"), f"marina-discord 설치본: {got}")
got = which({"marina@test-market": [{"installPath": str(disc)}]})
check(got == str(disc / "scripts" / "marina_session.py"), f"옛 marina@ 에 파일이 있으면 그것: {got}")
got = which({"marina@test-market": [{"installPath": str(nv)}]})
check(got.endswith("marina_session.py") and str(nv) not in got, f"어디에도 없으면 박힌 경로: {got}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-hook-entry"
