#!/usr/bin/env bash
# 방 MCP 서버 갈아타기(2026-11-10): 방은 뜰 때 읽은 코드로 계속 돌아 배포가 방을 새로 띄워야 먹혔다(형 "새로 굳이 떠야되냐고").
# 도구 호출이 올 때 설치본이 바뀌었으면 같은 stdin/stdout 그대로 새 코드로 넘어가 그 호출과 뒤 호출을 새 코드가 처리해야 한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
python3 - "$TMPROOT" "$DSCRIPTS" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path

tmp, src = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
home = tmp / "claude"
cache = home / "plugins" / "cache" / "marina-dev" / "marina-discord"
old, new = cache / "aaa111" / "scripts", cache / "bbb222" / "scripts"
for d in (old, new):
    shutil.copytree(src, d, ignore=shutil.ignore_patterns("__pycache__"))
ms = new / "marina_session.py"
probe = ('_orig_chat_tool = chat_tool\n'
         'def chat_tool(name, args):\n'
         '    return "NEW-CODE" if name == "hop_probe" else _orig_chat_tool(name, args)\n\n\n'
         'if __name__ == "__main__":')
ms.write_text(ms.read_text(encoding="utf-8").replace('if __name__ == "__main__":', probe, 1), encoding="utf-8")
(home / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {"marina-discord@marina-dev": [
    {"scope": "user", "installPath": str(new.parent), "lastUpdated": "2026-11-10T00:00:00Z"}]}}))

env = dict(os.environ, MARINA_CLAUDE_HOME=str(home))
env.pop("MARINA_MCP_REPLAY", None)
req = lambda i, m, p: json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n"
call = lambda i: req(i, "tools/call", {"name": "hop_probe", "arguments": {}})
# 도구 호출 두 개를 한 번에 — 갈아탈 때 뒤 요청을 버퍼째 잃으면 안 된다
inp = req(1, "initialize", {}) + call(2) + call(3)
r = subprocess.run([sys.executable, str(old / "marina_session.py"), "mcp-chat"], input=inp, env=env,
                   capture_output=True, text=True, timeout=60)
outs = {m["id"]: m for m in (json.loads(l) for l in r.stdout.splitlines() if l.strip())}
def text(i):
    return ((outs.get(i) or {}).get("result") or {}).get("content", [{}])[0].get("text")
fail = []
if 1 not in outs:
    fail.append("initialize 답이 없다")
if len([l for l in r.stdout.splitlines() if l.strip()]) != 3:
    fail.append(f"답 줄 수가 3이 아니다(중복·유실): {r.stdout[-400:]!r}")
for i in (2, 3):
    if text(i) != "NEW-CODE":
        fail.append(f"호출 {i} 를 새 코드가 처리하지 않았다 ({text(i)!r})")
left = list((Path(env.get("MARINA_HOME", tmp)).glob("mcp-replay-*")))
if left:
    fail.append(f"넘김 파일이 남았다 {left}")
if fail:
    print("FAIL:", "; ".join(fail), "\nstderr:", r.stderr[-800:]); sys.exit(1)

# 설치본이 자기 자신이면 넘어가지 않는다(무한 exec 방지) — 새 코드로 바로 띄워도 같은 답
r = subprocess.run([sys.executable, str(new / "marina_session.py"), "mcp-chat"], input=req(1, "initialize", {}) + call(2),
                   env=env, capture_output=True, text=True, timeout=60)
if '"NEW-CODE"' not in r.stdout:
    print("FAIL: 최신 코드에서 호출이 처리되지 않았다", r.stdout[-400:], r.stderr[-400:]); sys.exit(1)

# 깨진 배포(새 코드가 import 안 됨)면 넘어가지 않고 옛 코드가 그대로 답한다 — 방이 도구를 잃으면 안 된다
broken = cache / "ccc333" / "scripts"
shutil.copytree(src, broken, ignore=shutil.ignore_patterns("__pycache__"))
(broken / "marina_session.py").write_text((broken / "marina_session.py").read_text(encoding="utf-8") + "\ndef (\n", encoding="utf-8")
(home / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {"marina-discord@marina-dev": [
    {"scope": "user", "installPath": str(broken.parent), "lastUpdated": "2026-11-10T01:00:00Z"}]}}))
r = subprocess.run([sys.executable, str(old / "marina_session.py"), "mcp-chat"], input=req(1, "initialize", {}) + call(2),
                   env=env, capture_output=True, text=True, timeout=60)
lines = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
if len(lines) != 2 or "hop_probe" not in json.dumps(lines[-1], ensure_ascii=False):
    print("FAIL: 깨진 새 코드로 넘어가 답을 잃었다", r.stdout[-400:], r.stderr[-400:]); sys.exit(1)
if list(Path(env.get("MARINA_HOME", tmp)).glob("mcp-replay-*")):
    print("FAIL: 넘김 파일이 남았다"); sys.exit(1)
PY
echo "PASS test-session-mcp-hop"
