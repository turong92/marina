#!/usr/bin/env bash
# 채팅방 격리 — 방마다 rooms/<channelId>/ 에 가둔다(받은 사진·결과물이 다른 방·공개 링크로 새지 않게).
#  - chat_guard: 남의 방 폴더를 Read·Glob·Grep·Write·Edit·reply 첨부로 못 쓴다(Glob/Grep 은 rooms/ 를 가로지르면 거절)
#  - share_file: 남의 방 폴더 파일은 공유 거절, 미리보기 렌더 서버는 rooms/ 를 안 내준다(방 폴더 안 페이지는 그 방만)
#  - teardown: chat 방을 지우면 rooms/<channelId>/ 도 지운다(숫자 id 폴더만, 맨 위 assets/ 는 안 건드린다)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
cat > "$TMPROOT/bin/fake-chrome" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; esac; done
printf '\211PNG\r\n\032\nfake' > "\$out"
SH
chmod +x "$TMPROOT/bin/fake-chrome"
export MARINA_CHROME="$TMPROOT/bin/fake-chrome"
msess new chat shopping --title "홈쇼핑" >/dev/null 2>&1 || fail "new shopping"
msess new chat other --title "다른 방" >/dev/null 2>&1 || fail "new other"
for _ in $(seq 50); do [ "$(ls "$FAKE_OUT"/*/argv 2>/dev/null | wc -l)" -ge 2 ] && break; sleep 0.1; done

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" "$TMPROOT" <<'PY'
import json, os, shlex, subprocess, sys
from pathlib import Path
import marina_session as ms, marina_share as sh
mh, tmp = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
recs = [r for r in ms.load_sessions() if r["kind"] == "chat"]
a = next(r for r in recs if r["task"] == "shopping"); b = next(r for r in recs if r["task"] == "other")
root = Path(a["root"]); ra, rb = str(a["channelId"]), str(b["channelId"])
(root / "rooms" / ra).mkdir(parents=True, exist_ok=True); (root / "rooms" / rb).mkdir(parents=True, exist_ok=True)
(root / "rooms" / ra / "mine.txt").write_text("mine"); (root / "rooms" / rb / "secret.txt").write_text("secret")
(root / "top.txt").write_text("top")
inbox = Path(a["stateDir"]) / "inbox"
def guard(tool, room=ra, **ti):
    return ms.chat_guard(root, inbox, {"tool_name": tool, "tool_input": ti}, room=room)
def denied(d): return bool(d) and d["hookSpecificOutput"]["permissionDecision"] == "deny"

# 설정: 훅이 Read·Glob·Grep 에도 걸리고 방 id 를 받는다
st = json.loads((Path(a["stateDir"]) / "settings.json").read_text())
pre = st["hooks"]["PreToolUse"][0]
check(all(t in pre["matcher"].split("|") for t in ("Read", "Glob", "Grep", "Write", "Edit")), f"가드 매처: {pre['matcher']}")
cmd = shlex.split(pre["hooks"][0]["command"])
check(ra in cmd, f"가드 명령에 방 id: {cmd}")

# Read/Write/Edit — 내 방은 되고 남의 방·rooms 자체는 안 된다
check(not denied(guard("Read", file_path=str(root / "rooms" / ra / "mine.txt"))), "내 방 Read")
check(not denied(guard("Read", file_path=str(root / "top.txt"))), "맨 위 파일 Read")
check(denied(guard("Read", file_path=str(root / "rooms" / rb / "secret.txt"))), "남의 방 Read")
check(denied(guard("Read", file_path=str(root / "ROOMS" / rb / "secret.txt"))), "대소문자 바꿔도(APFS) 거절")
check(denied(guard("Read", file_path=str(root / "rooms" / ra / ".." / rb / "secret.txt"))), ".. 로 돌아가도 거절")
os.symlink(root / "rooms" / rb, root / "rooms" / ra / "sneak")
check(denied(guard("Read", file_path=str(root / "rooms" / ra / "sneak" / "secret.txt"))), "내 방 안 심볼릭 링크로 남의 방")
for tool in ("Write", "Edit"):
    check(denied(guard(tool, file_path=str(root / "rooms" / rb / "x.html"))), f"남의 방 {tool}")
    check(not denied(guard(tool, file_path=str(root / "rooms" / ra / "x.html"))), f"내 방 {tool}")
check(denied(guard("Read", file_path=str(root / "rooms"))), "rooms 자체")
check(denied(guard("Read", room="", file_path=str(root / "rooms" / ra / "mine.txt"))), "방을 모르면 rooms 는 전부 거절")
# Glob/Grep
check(denied(guard("Glob", pattern="*", path=str(root / "rooms" / rb))), "Glob path 가 남의 방")
check(denied(guard("Grep", pattern="x", path=str(root / "rooms"))), "Grep path = rooms")
check(not denied(guard("Glob", pattern="**/*.txt", path=str(root / "rooms" / ra))), "Glob 내 방 안")
check(not denied(guard("Grep", pattern="x", path=str(root / "rooms" / ra))), "Grep 내 방 안")
check(denied(guard("Glob", pattern="**/*.txt")), "Glob 맨 위에서 ** 는 rooms 를 가로지른다")
check(denied(guard("Glob", pattern="*/secret.txt", path=str(root))), "Glob 맨 위에서 */ 는 가로지른다")
check(denied(guard("Glob", pattern="rooms/*/secret.txt")), "Glob 패턴이 rooms/ 를 가리킨다")
check(denied(guard("Glob", pattern="ROOMS/**")), "Glob 대소문자")
check(not denied(guard("Glob", pattern="*.txt")), "Glob 맨 위 단일 패턴은 가로지르지 않는다")
check(not denied(guard("Glob", pattern="assets/*.jpg")), "Glob 맨 위 assets/ 는 된다")
check(denied(guard("Glob", pattern="/" + str(root).lstrip("/") + "/rooms/*/secret.txt")), "Glob 절대 패턴")
check(denied(guard("Grep", pattern="secret")), "Grep 맨 위(path 없음)는 rooms 를 훑는다 → 거절, 방 폴더를 path 로 지정하라고 안내")
check("rooms/" in guard("Grep", pattern="secret")["hookSpecificOutput"]["permissionDecisionReason"], "거절 사유에 안내")
check(denied(guard("Grep", pattern="x", path=str(root))), "Grep path = 맨 위")
check(not denied(guard("Grep", pattern="x", path=str(root / "top.txt"))), "Grep 파일 하나")
# reply 첨부
check(denied(guard("mcp__plugin_discord_discord__reply", files=[str(root / "rooms" / rb / "secret.txt")])), "reply 첨부: 남의 방")
check(not denied(guard("mcp__plugin_discord_discord__reply", files=[str(root / "rooms" / ra / "mine.txt")])), "reply 첨부: 내 방")
check(not denied(guard("mcp__plugin_discord_discord__reply", files=[str(root / "top.txt")])), "reply 첨부: 맨 위")
# 기존 동작 유지
check(denied(guard("Write", file_path=str(root / "CLAUDE.md"))), "설정 파일 거절은 그대로")

# share_file — 남의 방 파일 거절, 내 방 HTML 은 방 폴더만 서빙하는 렌더
os.environ["DISCORD_STATE_DIR"] = a["stateDir"]
try:
    ms.chat_tool("share_file", {"path": f"rooms/{rb}/secret.txt"}); other_ok = True
except ms.SessionError as exc:
    other_ok = False; why = str(exc)
check(not other_ok and str(root) not in why, f"share_file 남의 방 거절: {why if not other_ok else ''}")
(root / "rooms" / rb / "p.html").write_text("<h1>b</h1>")
try:
    ms.chat_tool("share_file", {"path": f"rooms/{rb}/p.html"}); other_ok = True
except ms.SessionError:
    other_ok = False
check(not other_ok, "share_file 남의 방 HTML 거절")
srv = sh.RenderServer(root / "rooms" / ra)
srv.start()
import urllib.request
op = urllib.request.build_opener(urllib.request.ProxyHandler({"http": f"http://127.0.0.1:{srv.port}"}))
def get(base, path):
    try: return op.open(f"http://127.0.0.1:{base.port}{path}", timeout=5).status
    except urllib.error.HTTPError as e: return e.code
check(get(srv, "/mine.txt") == 200 and get(srv, "/../" + rb + "/secret.txt") in (403, 404), "방 폴더 렌더 서버는 그 방만")
srv.stop()
srv = sh.RenderServer(root, block=("rooms",)); srv.start()
check(get(srv, "/top.txt") == 200 and get(srv, f"/rooms/{rb}/secret.txt") == 404 and get(srv, f"/ROOMS/{rb}/secret.txt") == 404,
      "맨 위 렌더 서버는 rooms/ 를 안 내준다")
srv.stop()

# teardown
(root / "assets").mkdir(exist_ok=True); (root / "assets" / "hairband.jpg").write_bytes(b"H")
(root / "rooms" / "notanid").mkdir(parents=True, exist_ok=True)
w = ms.teardown(b)
check(not (root / "rooms" / rb).exists(), f"teardown: 방 폴더 삭제 {w}")
check((root / "rooms" / ra / "mine.txt").exists() and (root / "assets" / "hairband.jpg").exists() and (root / "rooms" / "notanid").exists(),
      "다른 방·맨 위 assets·숫자 아닌 폴더는 그대로")
# 위험한 channelId 는 지우지 않는다
fake = dict(a, channelId="..", task="x")
ms._remove_room_dir(fake)
check((root / "rooms").is_dir() and (root / "rooms" / ra).exists(), "channelId 가 이상하면 아무것도 안 지운다")
victim = tmp / "victim"; victim.mkdir(); (victim / "keep").write_text("k")
os.symlink(victim, root / "rooms" / "999")
ms._remove_room_dir(dict(a, channelId="999"))
check((victim / "keep").exists(), "링크 폴더 너머는 안 지운다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-chat-rooms"
