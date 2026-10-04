#!/usr/bin/env bash
# marina session new chat <이름> — 개발이 아닌 검색·파일 만들기용 채팅 세션(실측 2026-10-01).
#  - 워크트리 없이 모든 채팅 세션이 $MARINA_HOME/chat 한 폴더(마리나 모바일 chat 방과 같은 곳)를 함께 쓴다,
#    대화는 세션 ID 로 구분(--session-id 로 시작, start 는 --resume). CHAT 카테고리 채널
#  - --from <기존 대화 ID> = 그 대화의 복사본으로 이어 간다(--fork-session, 원본은 안 건드림 — 데스크톱이 열고 있어도 안전)
#  - 채널 허용 목록은 비움 = 채널이 보이는 사람(Discord chat 역할)이면 누구나 — ID 등록 없음
#  - 형 로그인 그대로 + --restricted(메모리·설정 무시, 파일 도구는 폴더 안만) + 묻지 않고 거절 + 허용 도구만
#  - 커넥터 끔(ENABLE_CLAUDEAI_MCP_SERVERS=false), 답장 첨부는 폴더 안 파일만(PreToolUse 훅)
#  - 새 폴더는 신뢰 확인창에서 멈춰 플러그인이 안 뜬다 → chat 상위 폴더를 미리 신뢰
#  - rm 은 채널·상태만 지우고 폴더(만든 파일)는 남긴다
#  - (리뷰) CHAT 카테고리는 만들 때부터 @everyone 에게 안 보이고 봇·chat 역할에게만 보인다
#  - (리뷰) 가드는 막는 쪽으로 실패한다, 웹 읽기는 사설·루프백·tailnet 주소를 막는다, 폴더 안 설정 파일 쓰기 금지
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}},"keep":1}\n' > "$MARINA_CLAUDE_JSON"

out="$(msess new chat 쇼핑 2>&1)" && fail "한글 이름이 성공함(채널·폴더 규칙 밖)"
out="$(msess new chat .hidden 2>&1)" && fail "'.' 으로 시작하는 이름이 성공함(chat 폴더 전체를 가리킬 수 있음)"
out="$(msess new chat . 2>&1)" && fail "'.' 이름이 성공함"
# 되돌리기 — claude 가 바로 죽으면 채널·상태 폴더·기록을 남기지 않는다
touch "$TMPROOT/claude-fail"
out="$(MARINA_SESSION_BOOT_WAIT=2 msess new chat broken 2>&1)" && fail "claude 실패가 성공으로 끝남: $out"
rm -f "$TMPROOT/claude-fail"
[ ! -e "$MARINA_CHANNELS_DIR/discord-chat-broken" ] || fail "실패했는데 상태 폴더가 남음"
grep -q '"DELETE"' "$FD/log.jsonl" || fail "실패했는데 채널 삭제 요청 없음"
[ ! -s "$MARINA_HOME/sessions.json" ] || python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1]))["sessions"] else 0)' "$MARINA_HOME/sessions.json" || fail "실패한 세션이 기록됨"
out="$(msess new chat shopping 2>&1)" || fail "new chat 실패: $out"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "채널 링크 출력 없음: $out"
echo "$out" | grep -q "chat 역할에게만" || fail "역할 안내 없음: $out"
# 앞의 broken 기동도 argv 를 남긴다 — shopping 것까지 둘이 될 때까지(부하 때 broken 것을 집던 경합)
for _ in $(seq 100); do [ "$(ls "$FAKE_OUT"/*/argv 2>/dev/null | wc -l)" -ge 2 ] && break; sleep 0.1; done

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$FAKE_OUT" "$MARINA_CLAUDE_JSON" <<'PY'
import json, os, stat, subprocess, sys
from pathlib import Path
import marina_session as ms
fd, mh, out, cj = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
folder = (mh / "chat").resolve()
check(folder.is_dir() and stat.S_IMODE(folder.stat().st_mode) == 0o700, "채팅 폴더 700")
posts = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]
cat = ms.load_config()["projects"]["chat"]["categoryId"]
VIEW, SEND, HIST, ATTACH, EMBED, REACT = 1 << 10, 1 << 11, 1 << 16, 1 << 15, 1 << 14, 1 << 6
talk = str(VIEW | SEND | HIST | ATTACH | EMBED | REACT)
catpost = next(x for x in posts if x["b"].get("type") == 4)
check(catpost["b"] == {"name": "CHAT", "type": 4, "permission_overwrites": [
    {"id": "G1", "type": 0, "allow": "0", "deny": str(VIEW)},
    {"id": "BOT1", "type": 1, "allow": talk, "deny": "0"},
    {"id": "R-chat", "type": 0, "allow": talk, "deny": "0"}]}, f"CHAT 카테고리 권한: {catpost}")
chpost = [x for x in posts if x["b"].get("type") == 0][-1]
check(chpost["b"] == {"name": "shopping", "type": 0, "parent_id": cat}, f"채널: {chpost}")
rec = ms.find_session("chat/shopping")
check(rec.get("kind") == "chat" and rec["root"] == str(folder) and rec["tmux"] == "chat-shopping", f"기록: {rec}")
sd = Path(rec["stateDir"])
acc = json.loads((sd / "access.json").read_text())
check(acc["allowFrom"] == [] and acc["groups"][rec["channelId"]]["allowFrom"] == [], f"허용 목록은 비움(역할로만): {acc}")
check((sd / "inbox").is_dir(), "받은 첨부 폴더(inbox)를 미리 만든다")

# 신뢰: chat 상위 폴더 하나만, 다른 키는 보존
d = json.loads(cj.read_text())
check(d["projects"].get(str((mh / "chat").resolve()), {}).get("hasTrustDialogAccepted") is True, f"chat 폴더 신뢰(실제 경로): {d}")
check(stat.S_IMODE(cj.stat().st_mode) == 0o600, "claude.json 권한 600")
check(d["keep"] == 1 and d["projects"]["/elsewhere"]["hasTrustDialogAccepted"] is True, "다른 설정 보존")

# 인자
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
sid = rec["sessionId"]
import uuid
check(str(uuid.UUID(sid)) == sid, f"세션 ID: {sid}")
check(argv == ms.chat_argv("chat", "shopping", sid)[1:], f"채팅 인자: {argv}")
check(argv[argv.index("--session-id") + 1] == sid and "--resume" not in argv and "--continue" not in argv, "새 대화는 --session-id 로")
for flag in ("--restricted", "--channels"):
    check(flag in argv, f"{flag} 없음")
check(argv[argv.index("--permission-mode") + 1] == "dontAsk", "묻지 않고 거절")
check(argv[argv.index("--tools") + 1] == "WebSearch,WebFetch,Read,Write,Edit,Glob,Grep", "허용 도구(Bash 없음)")
check(argv[argv.index("--add-dir") + 1] == str(sd / "inbox"), "받은 첨부를 읽게 inbox 만 추가")
check("--remote-control" not in argv, "채팅 세션은 원격 제어를 안 연다")
check((calls[-1] / "cwd").read_text().strip() == str(folder.resolve()), "cwd = 채팅 폴더")
env = dict(l.split("=", 1) for l in (calls[-1] / "env").read_text().splitlines() if "=" in l)
check(env.get("ENABLE_CLAUDEAI_MCP_SERVERS") == "false", "커넥터 끔")
check(env.get("DISCORD_STATE_DIR") == str(sd), "DISCORD_STATE_DIR")

# 설정: 허용 목록·로컬 주소 거절·첨부 가드 훅
st = json.loads((sd / "settings.json").read_text())
allow = st["permissions"]["allow"]
for t in ("Write", "Edit", "WebSearch", "WebFetch", "mcp__plugin_discord_discord__reply"):
    check(t in allow, f"허용 목록에 {t}")
check(not any(a.startswith("Bash") for a in allow), "Bash 허용 금지")
deny = st["permissions"]["deny"]
for f in (".mcp.json", ".claude/**", "CLAUDE.md", "CLAUDE.local.md"):
    check(f"Edit(/{folder.resolve()}/{f})" in deny, f"폴더 안 설정 파일 쓰기 금지: {f}")
pre = st["hooks"]["PreToolUse"][0]
check(pre["matcher"] == "mcp__plugin_discord_discord__reply|WebFetch|Write|Edit", f"가드 매처: {pre['matcher']}")
guard = pre["hooks"][0]["command"]
def run(cmd, payload):
    p = subprocess.run(["/bin/sh", "-c", cmd], input=json.dumps(payload) if not isinstance(payload, str) else payload,
                       text=True, capture_output=True)
    return p.returncode, p.stdout
def run_guard(files):
    return run(guard, {"tool_name": "mcp__plugin_discord_discord__reply", "tool_input": {"chat_id": "1", "files": files}})
def denied(r):
    code, so = r
    return code == 2 or (code == 0 and so.strip() and json.loads(so)["hookSpecificOutput"]["permissionDecision"] == "deny")
# 막는 쪽으로 실패: 판정기 자체가 없거나 입력이 깨져도 exit 2
check(run(guard.replace(sys.executable, "/nonexistent/python3", 1), {"tool_input": {}})[0] == 2, f"인터프리터가 없으면 exit 2: {guard}")
check(run(guard, "not json")[0] == 2, "깨진 입력이면 exit 2")
check(denied(run_guard("/etc/passwd")), "files 가 문자열이면 거절")
check(denied(run_guard(["ok.txt"])), "상대 경로는 거절(플러그인 기준 폴더가 다름)")
inbox_file = sd / "inbox" / "photo.png"; inbox_file.write_text("img")
check(not denied(run_guard([str(inbox_file)])), "받은 첨부(inbox)는 돌려보낼 수 있다")
def fetch(url):
    return run(guard, {"tool_name": "WebFetch", "tool_input": {"url": url, "prompt": "x"}})
for url in ("http://127.0.0.1:3900/", "http://localhost:3900/", "https://foo.localhost/", "http://[::1]/",
            "http://100.100.1.1/", "http://192.168.0.10/", "http://10.0.0.1/", "http://169.254.169.254/",
            "https://nonexistent-host.invalid/", "file:///etc/passwd", "not a url"):
    check(denied(fetch(url)), f"웹 읽기 거절: {url}")
check(not denied(fetch("https://1.1.1.1/")), "공인 주소는 통과")
def write(tool, path):
    return run(guard, {"tool_name": tool, "tool_input": {"file_path": path, "content": "x"}})
for bad in (".MCP.json", "sub/.mcp.json", ".Claude/settings.json", "sub/.claude/skills/x/SKILL.md", "claude.MD", "sub/CLAUDE.local.md"):
    check(denied(write("Write", str(folder / bad))), f"설정 파일 쓰기 거절(하위·대소문자): {bad}")
    check(denied(write("Edit", str(folder / bad))), f"설정 파일 고치기 거절: {bad}")
check(not denied(write("Write", str(folder / "notes" / "memo.md"))), "일반 파일 쓰기는 통과")
(folder / "ok.txt").write_text("hi")
os.symlink(str(mh / "token.env"), str(folder / "sneaky.txt"))
code, so = run_guard([str(folder / "ok.txt")])
check(code == 0 and "deny" not in so, f"폴더 안 첨부는 통과: {code} {so}")
for bad in (str(mh / "token.env"), str(folder / "sneaky.txt"), str(folder / ".." / ".." / "token.env")):
    code, so = run_guard([str(folder / "ok.txt"), bad])
    check(code == 0 and json.loads(so)["hookSpecificOutput"]["permissionDecision"] == "deny", f"폴더 밖 첨부 거절: {bad} → {so}")
code, so = run_guard([])
check(code == 0 and "deny" not in so, "첨부 없는 답장은 통과")
(folder / "sneaky.txt").unlink()

# start 는 채팅 인자로 다시 띄운다(--continue)
ms.tmux_stop(rec["tmux"])
ck = str((mh / "chat").resolve())
d = json.loads(cj.read_text()); d["projects"].pop(ck); cj.write_text(json.dumps(d))
# 대화 기록이 아직 없으면(아무도 말을 안 건 채 껐다 켬) --resume 은 실패한다 → 다시 --session-id 로
started, failed = ms.cmd_start("chat/shopping")
check(started == ["chat/shopping"] and not failed, f"기록 없는 start: {started} {failed}")
import time
for _ in range(50):
    calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
    argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
    if len(calls) >= 2 and argv.count("--session-id"): break
    time.sleep(0.1)
check(argv == ms.chat_argv("chat", "shopping", sid)[1:], f"기록 없으면 --session-id 로: {argv}")
ms.tmux_stop(rec["tmux"])
tr = ms.transcript_path(folder, sid); tr.parent.mkdir(parents=True, exist_ok=True); tr.write_text("{}\n")
started, failed = ms.cmd_start("chat/shopping")
check(started == ["chat/shopping"] and not failed, f"start: {started} {failed}")
check(json.loads(cj.read_text())["projects"][ck]["hasTrustDialogAccepted"] is True, "start 가 신뢰를 다시 적는다")
import time
for _ in range(50):
    calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
    argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
    if "--resume" in argv: break
    time.sleep(0.1)
check(argv == ms.chat_argv("chat", "shopping", sid, resume=True)[1:], f"start 인자: {argv}")
check(argv[argv.index("--resume") + 1] == sid and "--continue" not in argv and "--session-id" not in argv,
      "start 는 자기 대화 ID 로 이어 간다(같은 폴더의 다른 대화를 집지 않게)")

# sessionId 없는 기록은 그 세션만 실패하고 start --all 을 멈추지 않는다
items = ms.load_sessions()
ms.save_sessions(items + [dict(rec, task="legacy", tmux="chat-legacy", sessionId="")])
started, failed = ms.cmd_start(all_=True)
check(any("legacy" in f and "sessionId" in f for f in failed), f"sessionId 없음은 실패 목록으로: {failed}")
ms.save_sessions(items)
# Stop 훅 폴백(cwd 일치)은 채팅 세션을 고르지 않는다 — 모두 같은 폴더라 엉뚱한 채널에 ✅ 가 붙는다
os.environ.pop("DISCORD_STATE_DIR", None)
check(ms._hook_target({"cwd": str(folder)}, ms.load_sessions()) is None, "채팅 세션은 cwd 로 짐작하지 않는다")

# rm: 채널·상태·기록은 지우고 폴더는 남긴다
w = ms.teardown(rec)
check(not w and not sd.exists() and ms.load_sessions() == [], f"rm 정리: {w}")
check((folder / "ok.txt").is_file(), "rm 은 만든 파일을 남긴다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY

# chat 역할이 없으면 @everyone·봇만 설정하고 경고 — '역할에게만 보여' 안내는 안 찍는다
touch "$FD/no_chat_role"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["projects"]["chat"]["categoryId"]=None; json.dump(d,open(p,"w"))' "$MARINA_HOME/discord.json"
out="$(msess new chat norole 2>&1)" || fail "역할 없음 new 실패: $out"
echo "$out" | grep -q "'chat' 역할이 없어" || fail "역할 없음 경고 없음: $out"
echo "$out" | grep -q "chat 역할에게만" && fail "역할이 없는데 '역할에게만 보여' 안내: $out"
python3 - "$FD" <<'PY2' || fail "역할 없음 카테고리 권한"
import json, sys
posts = [json.loads(l) for l in open(sys.argv[1] + "/log.jsonl") if '"POST"' in l]
ow = [x for x in posts if x["b"].get("type") == 4][-1]["b"]["permission_overwrites"]
sys.exit(0 if [o["id"] for o in ow] == ["G1", "BOT1"] else 1)
PY2
rm -f "$FD/no_chat_role"

# 이미 있는 CHAT 카테고리가 공개(@everyone 차단 없음)면 거절 — 서버 기본값에 기대지 않는다
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" <<'PY2' || fail "기존 카테고리 권한 검사"
import json, sys
import marina_session as ms
cfg = ms.load_config(); dc = ms.Discord(ms.read_token(cfg))
ms.save_config(cfg)
pub = dc.create_category("G1", "CHAT")                           # 덮어쓰기 없음 = 공개
cfg["projects"]["chat"]["categoryId"] = pub; ms.save_config(cfg)
try:
    ms.ensure_chat_category(dc, cfg); sys.exit("공개 카테고리를 그대로 씀")
except ms.SessionError as exc:
    assert "@everyone" in str(exc), exc
priv = dc.create_category("G1", "CHAT", [{"id": "G1", "type": 0, "allow": "0", "deny": str(1 << 10)}])
cfg["projects"]["chat"]["categoryId"] = priv; ms.save_config(cfg)
cid, role_ok = ms.ensure_chat_category(dc, cfg)
assert cid == priv and role_ok is False, (cid, role_ok)          # chat 역할 허용이 없으면 안내용 False
PY2

# 같은 이름을 다시 만들어도 폴더(이전 파일)는 그대로
out="$(msess new chat shopping 2>&1)" || fail "같은 이름 재생성 실패: $out"
[ -f "$MARINA_HOME/chat/ok.txt" ] || fail "재생성이 이전 파일을 지움"

# 기존 대화 옮기기 — 복사본으로 이어 간다
out="$(msess new chat moved --from not-a-uuid 2>&1)" && fail "잘못된 대화 ID 가 성공함"
OLD=0eba186f-14e1-4d9d-aa34-c8b6a5e2d1fc
out="$(msess new chat moved --from $OLD 2>&1)" && fail "chat 폴더에 없는 대화가 성공함"
echo "$out" | grep -q "chat 폴더" || fail "없는 대화 안내: $out"
KEY="$(python3 -c 'import os,re,sys; print(re.sub(r"[^A-Za-z0-9]","-",os.path.realpath(sys.argv[1])))' "$MARINA_HOME/chat")"
mkdir -p "$MARINA_CLAUDE_PROJECTS/$KEY"; echo '{}' > "$MARINA_CLAUDE_PROJECTS/$KEY/$OLD.jsonl"
out="$(msess new chat moved --from $OLD 2>&1)" || fail "--from 실패: $out"
for _ in $(seq 50); do grep -lq -- "--fork-session" "$FAKE_OUT"/*/argv 2>/dev/null && break; sleep 0.1; done
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FAKE_OUT" "$OLD" <<'PY2' || fail "--from 인자"
import sys
from pathlib import Path
import marina_session as ms
out, old = Path(sys.argv[1]), sys.argv[2]
rec = ms.find_session("chat/moved")
argv = next(a for a in ([x.decode() for x in (p / "argv").read_bytes().split(b"\0")[:-1]] for p in out.iterdir() if (p / "argv").exists())
            if "--fork-session" in a)
assert rec["sessionId"] != old and rec.get("forkedFrom") == old, rec
assert argv == ms.chat_argv("chat", "moved", rec["sessionId"], from_id=old)[1:], argv
assert argv[argv.index("--resume") + 1] == old and argv[argv.index("--session-id") + 1] == rec["sessionId"], argv
# 복사본 기록은 첫 메시지 전엔 없다 — 그 사이 껐다 켜도 다시 복사본으로(옛 대화를 잃지 않게)
assert ms.session_argv(rec, resume=True) == ms.chat_argv("chat", "moved", rec["sessionId"], from_id=old), ms.session_argv(rec, resume=True)
tr = ms.transcript_path(Path(rec["root"]), rec["sessionId"]); tr.write_text("{}\n")
assert ms.session_argv(rec, resume=True) == ms.chat_argv("chat", "moved", rec["sessionId"], resume=True)
PY2
echo "PASS test-session-chat"
