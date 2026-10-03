#!/usr/bin/env bash
# 개발 프로젝트 카테고리에도 로비(#새-작업)·#자료실 — CHAT 과 같은 구조(2026-10-02 형 요청).
#  - marina session lobby <프로젝트>: 프로젝트 루트에서 도구 없는 제한 세션 + open_chat(=새 워크트리+채널+세션)
#  - 로비가 여는 작업은 서비스를 자동 실행하지 않는다(오래 걸림 — 세션 안에서 marina start)
#  - 개발 세션도 share_file 을 받아 결과물을 프로젝트 #자료실 로 모은다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
fail() { echo "FAIL: $*"; exit 1; }
cat > "$TMPROOT/bin/fake-chrome" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; esac; done
printf '\211PNG\r\n\032\nfake' > "\$out"
SH
chmod +x "$TMPROOT/bin/fake-chrome"; export MARINA_CHROME="$TMPROOT/bin/fake-chrome"

out="$(msess lobby proj 2>&1)" || fail "개발 로비 실패: $out"
echo "$out" | grep -q "#새-작업" || fail "로비 이름: $out"
out="$(msess lobby proj 2>&1)" && fail "개발 로비가 두 개"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$SRC" "$FAKE_OUT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
import marina_session as ms
fd, src, out = Path(sys.argv[1]), Path(sys.argv[2]).resolve(), Path(sys.argv[3])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
lob = ms.find_session("proj/lobby")
check(lob.get("kind") == "dev-lobby" and Path(lob["root"]).parent == Path(lob["stateDir"]).resolve(), f"개발 로비는 레포가 아닌 빈 폴더에서: {lob}")
check(not any(Path(lob["root"]).iterdir()), "로비 폴더는 비어 있다")
cfg = ms.load_config(); cat = cfg["projects"]["proj"]["categoryId"]
names = [x["b"].get("name") for x in log() if x["m"] == "POST" and x["b"].get("parent_id") == cat]
check("새-작업" in names and "자료실" in names, f"로비·자료실 채널: {names}")
check(cfg["projects"]["proj"].get("archiveChannelId"), "프로젝트 자료실 ID 저장")
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv[argv.index("--tools") + 1] == "" and "--restricted" in argv, "로비는 도구 없는 제한 세션")
check("작업" in argv[argv.index("--append-system-prompt") + 1], "개발 로비 규칙")
sd = Path(lob["stateDir"])
acc = json.loads((sd / "access.json").read_text())
check(acc["groups"][lob["channelId"]]["allowFrom"] == ["U1"], "개발 로비는 프로젝트 허용자만")
st = json.loads((sd / "settings.json").read_text())
check(st["hooks"]["PreToolUse"][0]["hooks"][0]["command"].split()[-3] != str(src), "로비 첨부 가드는 레포가 아닌 빈 폴더 기준")

srv = json.loads(Path(argv[argv.index("--mcp-config") + 1]).read_text())["mcpServers"]["marina"]
def call(name, args):
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
    msg = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": args}}
    p = subprocess.run([srv["command"]] + srv["args"], input=json.dumps(init) + "\n" + json.dumps(msg) + "\n",
                       text=True, capture_output=True, env=dict(os.environ, DISCORD_STATE_DIR=str(sd)), timeout=120)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()][-1]["result"], p.stderr
r, e = call("open_chat", {"name": "login-fix", "title": "로그인 버그"})
check(not r.get("isError") and "discord.com/channels/G1/" in r["content"][0]["text"], f"작업 열기: {r} {e}")
rec = ms.find_session("proj/login-fix")
check(Path(rec["root"]) == src / ".claude" / "worktrees" / "login-fix", f"새 워크트리: {rec['root']}")
check(rec.get("title") == "로그인 버그" and rec.get("kind") is None, f"개발 세션 기록: {rec}")
welcome = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(welcome and "로그인 버그" in welcome[0]["b"]["content"], f"새 작업 첫 안내: {welcome}")
r, e = call("list_chats", {})
check("login-fix" in r["content"][0]["text"] and "lobby" not in r["content"][0]["text"], f"작업 목록: {r}")

# 개발 세션 share_file → 프로젝트 자료실
sd2 = Path(rec["stateDir"])
st2 = json.loads((sd2 / "settings.json").read_text())
check("mcp__marina__share_file" in st2["permissions"]["allow"], "개발 세션도 share_file 허용")
dargv = ms.claude_argv("proj", "login-fix")
check(dargv[dargv.index("--mcp-config") + 1] == str(sd2 / "mcp.json"), "개발 세션 MCP")
dsrv = json.loads((sd2 / "mcp.json").read_text())["mcpServers"]["marina"]
check(dsrv["args"][-1] == "mcp-chat", "개발 세션은 share_file 서버")
wt = Path(rec["root"]); (wt / "shot.html").write_text("<h1>ok</h1>")
init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
msg = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "share_file", "arguments": {"path": "shot.html", "title": "로그인 화면"}}}
p = subprocess.run([dsrv["command"]] + dsrv["args"], input=json.dumps(init) + "\n" + json.dumps(msg) + "\n",
                   text=True, capture_output=True, env=dict(os.environ, DISCORD_STATE_DIR=str(sd2)), timeout=120)
r = [json.loads(l) for l in p.stdout.splitlines() if l.strip()][-1]["result"]
check(not r.get("isError") and "자료실" in r["content"][0]["text"], f"개발 share_file: {r} {p.stderr[-300:]}")
arch = cfg["projects"]["proj"]["archiveChannelId"]
up = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{arch}/messages"]
check(up and "[로그인 버그] 로그인 화면" in up[-1]["b"]["payload"]["content"], f"프로젝트 자료실 글: {up[-1] if up else None}")
check(not (wt / "미리보기").exists() and (sd2 / "미리보기" / "shot.png").is_file(), "개발 세션 미리보기는 레포가 아닌 상태 폴더에")
# 로비가 있어도 main 체크아웃에서 하던 대화는 옮길 수 있다
import re as _re
SID = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
d = Path(os.environ["MARINA_CLAUDE_PROJECTS"]) / _re.sub(r"[^A-Za-z0-9]", "-", str(src)); d.mkdir(parents=True, exist_ok=True)
(d / f"{SID}.jsonl").write_text(json.dumps({"type": "user", "cwd": str(src)}) + "\n")
try:
    ms.cmd_new("proj", "root-talk", from_id=SID); ok = True
except ms.SessionError as exc:
    ok = str(exc)
check(ok is True, f"로비가 main 체크아웃 옮기기를 막지 않는다: {ok}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-devlobby"
