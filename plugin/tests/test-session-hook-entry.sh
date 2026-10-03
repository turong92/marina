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

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" "$CHOME" <<'PY'
import json, os, subprocess, sys
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
# 설치본이 아닌 곳(작업 트리 테스트)에서 실행되면 예전처럼 직접 경로
(chome / "plugins" / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {}}))
ms.write_settings(sd)
st = json.loads((sd / "settings.json").read_text())
check("marina-session-hook" not in json.dumps(st), "설치본 밖이면 직접 경로")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-hook-entry"
