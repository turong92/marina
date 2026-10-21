#!/usr/bin/env bash
# 코덱스 방의 아웃바운드 — marina MCP(mcp-chat)에 더하는 Discord 도구 5개(reply·react·edit_message·fetch_messages·download_attachment).
# 공식 플러그인(server.ts)의 안전장치를 그대로 옮겼는지: 채널 문지기·첨부 제한·2000자 나눔·reply_to 첫 조각만·멘션 없음.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
export MARINA_CODEX_SESSIONS="$TMPROOT/codex-sessions"          # 실 ~/.codex/sessions 를 읽지 않는다
mkdir -p "$MARINA_HOME/accounts/codex-b" "$MARINA_CODEX_SESSIONS/2026/10/21" "$FD/attachments"
echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
msess new proj feat/tools --codex --no-start >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
# 클로드 개발 방 — 같은 도구 목록을 받으면 안 된다
msess new proj feat/claude --no-start >/dev/null 2>&1 || fail "클로드 방 만들기 실패"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$MARINA_SH" "$TMPROOT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
import marina_session as ms
fd, mh, marina_sh, tmp = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

rec = ms.find_session("proj/feat/tools")
crec = ms.find_session("proj/feat/claude")
sd, ch = Path(rec["stateDir"]), rec["channelId"]
api = os.environ["MARINA_DISCORD_API"]

# 이 방이 받은 지시를 담은 rollout (reply_to 자동 채우기용)
def tag(mid): return f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}">\n지시 {mid}\n</channel>'
ro = Path(os.environ["MARINA_CODEX_SESSIONS"]) / "2026/10/21/rollout-2026-10-21T10-00-00-01a15df6-ad2d-74f3-a376-1093930d23a9.jsonl"
ro.write_text("\n".join(json.dumps({"timestamp": "2026-10-21T10:00:00.000Z", "type": "event_msg",
                                    "payload": {"type": "user_message", "message": tag(m)}}) for m in ("5001", "5002")) + "\n")
items = ms.load_sessions()
for x in items:
    if x["task"] == "feat/tools":
        x["rollout"] = str(ro)
ms.save_sessions(items)

class Mcp:
    def __init__(self, state_dir):
        env = dict(os.environ, DISCORD_STATE_DIR=str(state_dir))
        self.p = subprocess.Popen(["bash", marina_sh, "session", "mcp-chat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  env=env, cwd=str(tmp), text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18"})
    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())["result"]
    def call(self, name, args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        return r["content"][0]["text"], r["isError"]
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=10)

def posts(since=0):
    rows = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
    return [r for r in rows[since:] if r["m"] == "POST" and "/messages" in r["p"] and "/threads" not in r["p"]]
def nlog(): return len((fd / "log.jsonl").read_text().splitlines())

NAMES = {"reply", "react", "edit_message", "fetch_messages", "download_attachment"}
m = Mcp(sd)
names = {t["name"] for t in m.rpc("tools/list")["tools"]}
check(NAMES <= names and {"progress", "share_file"} <= names, f"코덱스 방 tools/list: {sorted(names)}")
c = Mcp(Path(crec["stateDir"]))
cnames = {t["name"] for t in c.rpc("tools/list")["tools"]}
check(not (NAMES & cnames), f"클로드 개발 방은 Discord 도구 5개를 안 받는다: {sorted(cnames)}")
text, err = c.call("reply", {"chat_id": crec["channelId"], "text": "x"})
check(err, "클로드 방에서 reply 호출은 거절")
c.close()

# reply 2500자 → 2조각, 첫 조각만 message_reference, 둘 다 멘션 없음
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "가" * 2500, "reply_to": "5001"})
ps = posts(n0)
check(not err and text.startswith("sent 2 parts (ids: "), f"reply 결과: {text!r}")
check(len(ps) == 2 and len(ps[0]["b"]["content"]) == 2000 and len(ps[1]["b"]["content"]) == 500, "2000자 단위로 나눔")
check(ps[0]["b"].get("message_reference", {}).get("message_id") == "5001" and "message_reference" not in ps[1]["b"], "reply_to 는 첫 조각에만")
check(all(p["b"]["allowed_mentions"] == {"parse": []} for p in ps), "멘션 알림 없음")
check(ps[0]["a"] == "Bot test-token", "방 .env 토큰으로 보낸다")
check(json.loads((sd / "replied.json").read_text())["mid"] == "5001", "replied.json 에 답한 지시 기록")

# reply_to 없이 → 마지막 받은 지시(5002)로 채움
(sd / "replied.json").unlink()
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "짧은 답"})
ps = posts(n0)
check(not err and text.startswith("sent (id: "), f"reply 한 조각 결과: {text!r}")
check(ps[0]["b"].get("message_reference", {}).get("message_id") == "5002", f"reply_to 자동 채움: {ps[0]['b']}")
check(json.loads((sd / "replied.json").read_text())["mid"] == "5002", "자동 채운 값이 replied.json 에")
# rollout 이 없으면 reply_to 없이 보낸다
items = ms.load_sessions()
for x in items:
    if x["task"] == "feat/tools":
        x["rollout"] = str(tmp / "gone.jsonl"); x.pop("sessionId", None)
ms.save_sessions(items)
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "기록 없음"})
check(not err and "message_reference" not in posts(n0)[0]["b"], "rollout 이 없으면 reply_to 없이")

# 채널 문지기 — 이 방(또는 그 스레드)만
other = json.loads(subprocess.run(["curl", "-s", "-X", "POST", "-H", "Authorization: Bot test-token", "-H", "Content-Type: application/json",
                                   "-d", '{"name":"elsewhere","type":0}', f"{api}/guilds/G1/channels"], capture_output=True, text=True).stdout)["id"]
for bad in (other, "777777"):
    n0 = nlog()
    text, err = m.call("reply", {"chat_id": bad, "text": "x"})
    check(err and not posts(n0), f"허용 밖 채널 {bad} 은 거절하고 POST 0: {text!r}")
text, err = m.call("fetch_messages", {"channel": other})
check(err, "fetch_messages 도 문지기 적용")
th = json.loads(subprocess.run(["curl", "-s", "-X", "POST", "-H", "Authorization: Bot test-token", "-H", "Content-Type: application/json",
                                "-d", '{"name":"t"}', f"{api}/channels/{ch}/messages/5001/threads"], capture_output=True, text=True).stdout)["id"]
n0 = nlog()
text, err = m.call("reply", {"chat_id": th, "text": "스레드 답"})
check(not err and posts(n0) and posts(n0)[0]["p"] == f"/channels/{th}/messages", f"이 방의 스레드는 통과: {text!r}")

# 첨부 — 상태 폴더 안 파일 거부, inbox 는 통과, 25MB·11개 초과 거부
(sd / "inbox").mkdir(exist_ok=True)
(sd / "inbox" / "a.png").write_bytes(b"png")
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": [str(sd / ".env")]})
check(err and "상태" in text and not posts(n0), f"상태 폴더 파일(.env) 거부: {text!r}")
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": [str(sd / "access.json")]})
check(err and "상태" in text, "access.json 도 거부")
link = tmp / "sneaky"; link.symlink_to(sd / ".env")
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": [str(link)]})
check(err and "상태" in text, "심볼릭 링크로 돌아가도 realpath 로 거부")
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "사진", "files": [str(sd / "inbox" / "a.png")], "reply_to": "5001"})
mp = posts(n0)
check(not err and mp and mp[0]["b"].get("files") == [{"field": "files[0]", "filename": "a.png", "size": 3}], f"inbox 파일은 multipart 로: {text!r} {mp}")
check(mp and mp[0]["b"]["payload"].get("message_reference", {}).get("message_id") == "5001"
      and mp[0]["b"]["payload"]["allowed_mentions"] == {"parse": []}, "첨부 첫 조각에도 reply_to·멘션 없음")
big = tmp / "big.bin"
with big.open("wb") as f:
    f.truncate(26 * 1024 * 1024)
n0 = nlog()
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": [str(big)]})
check(err and not posts(n0), f"26MB 거부: {text!r}")
many = []
for i in range(11):
    p = tmp / f"f{i}.txt"; p.write_text("x"); many.append(str(p))
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": many})
check(err and not posts(n0), "11개 거부")
text, err = m.call("reply", {"chat_id": ch, "text": "x", "files": [str(tmp / "nope.txt")]})
check(err, "없는 파일 거부")

# react / edit
n0 = nlog()
text, err = m.call("react", {"chat_id": ch, "message_id": "5001", "emoji": "✅"})
rows = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()][n0:]
check(not err and text == "reacted" and any(r["m"] == "PUT" and "/messages/5001/reactions/" in r["p"] for r in rows), f"react: {text!r}")
text, err = m.call("edit_message", {"chat_id": ch, "message_id": "5003", "text": "고친 글"})
rows = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
check(not err and text.startswith("edited (id: ") and any(r["m"] == "PATCH" and r["b"].get("content") == "고친 글" for r in rows), f"edit_message: {text!r}")

text, err = m.call("react", {"chat_id": ch, "message_id": "../../users", "emoji": "✅"})
check(err, "숫자 아닌 message_id 는 거절(경로 주입 방지)")

# fetch_messages — 여러 줄은 ⏎ 로 접고, 첨부 개수, 내 글은 me
(fd / "attachments" / "a.png").write_bytes(b"\x89PNG-bytes")
(fd / "messages.json").write_text(json.dumps({ch: [
    {"id": "6001", "content": "첫 줄\n둘째 줄", "author": {"id": "U1", "username": "형"}, "timestamp": "2026-10-21T10:00:00.123000+00:00", "attachments": []},
    {"id": "6002", "content": "내 답", "author": {"id": "BOT1", "username": "bot"}, "timestamp": "2026-10-21T10:00:05.000000+00:00",
     "attachments": [{"id": "A1", "filename": "a.png", "size": 10, "content_type": "image/png", "url": f"{api}/attachments/a.png"}]}]}))
text, err = m.call("fetch_messages", {"channel": ch, "limit": 20})
lines = text.splitlines()
check(not err and len(lines) == 2 and lines[0] == "[2026-10-21T10:00:00.123Z] 형: 첫 줄 ⏎ 둘째 줄  (id: 6001)"
      and lines[1] == "[2026-10-21T10:00:05.000Z] me: 내 답  (id: 6002 +1att)", f"fetch_messages: {text!r}")

# download_attachment — 상태 폴더 inbox 에 받는다
text, err = m.call("download_attachment", {"chat_id": ch, "message_id": "6002"})
got = list((sd / "inbox").glob("*.png"))
check(not err and text.startswith("downloaded 1 attachment(s):\n") and "(a.png, image/png, 0KB)" in text, f"download 결과: {text!r}")
check(any(f.read_bytes() == b"\x89PNG-bytes" for f in got), "inbox 에 받은 파일 내용")
text, err = m.call("download_attachment", {"chat_id": ch, "message_id": "6001"})
check(not err and text == "message has no attachments", f"첨부 없는 메시지: {text!r}")
m.close()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-codex-discord-tools"
