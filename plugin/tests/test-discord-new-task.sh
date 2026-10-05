#!/usr/bin/env bash
# 새 작업 버튼(스펙 2026-10-05-new-task-button-design): 로비 고정 패널 → 칸 하나 모달 → new-from-text 가 워크트리·채널·세션을 연다.
#  - slug(haiku → 형식 검사 → 폴백)·충돌 접미사·base 추출·title · 패널 한 번만 · 첫 지시는 argv · 허용 안 된 사용자 거부
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }

# 가짜 claude 를 앞에 하나 더 — -p(이름 짓기)는 파일에 적힌 답을 내고, 그 외(세션)는 픽스처 가짜로 넘긴다.
REAL_BIN="$TMPROOT/bin"; mkdir -p "$TMPROOT/bin2" "$TMPROOT/slugcalls"
cat > "$TMPROOT/bin2/claude" <<SH
#!/bin/sh
case " \$* " in
  *" -p "*)
    d="$TMPROOT/slugcalls/\$\$"; mkdir -p "\$d"; env > "\$d/env"; printf '%s\0' "\$@" > "\$d/argv"
    [ -e "$TMPROOT/slug-fail" ] && exit 1
    cat "$TMPROOT/slug-answer" 2>/dev/null; exit 0 ;;
esac
exec "$REAL_BIN/claude" "\$@"
SH
chmod +x "$TMPROOT/bin2/claude"
export PATH="$TMPROOT/bin2:$PATH"
git -C "$SRC" branch dev
git -C "$SRC" checkout -q dev && echo devonly > "$SRC/devfile" && git -C "$SRC" add devfile && git -C "$SRC" commit -qm "dev only" && git -C "$SRC" checkout -q main
DEVSHA="$(git -C "$SRC" rev-parse dev)"
export DEVSHA

printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess lobby proj || fail "로비 생성"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli python3 - "$FD" "$TMPROOT" <<'PY'
import json, os, re, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
FD, T = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (FD / "log.jsonl").read_text().splitlines()]
def answer(s):
    (T / "slug-answer").write_text(s)

# ── 로비 만들 때 패널이 한 번 올라간다 ────────────────────────────────────────
panels = [x for x in log() if x["m"] == "POST" and "marina-new:proj" in json.dumps(x.get("b"), ensure_ascii=False)]
check(len(panels) == 1, f"로비 생성 시 패널 1개: {len(panels)}")
check(any(x["m"] == "PUT" and "/pins/" in x["p"] for x in log()), "패널 pin")
check(ms.load_config()["projects"]["proj"].get("newPanel", {}).get("messageId") == "m-sent", "패널 메시지 ID 저장")
n = len(log()); check(ms.ensure_new_panel("proj") is False and len(log()) == n + 1 and log()[-1]["m"] == "GET", "있으면 그대로(확인 GET 만)")
(FD / "gone").write_text("m-sent\n")
check(ms.ensure_new_panel("proj") is True, "지워졌으면 다시 올림")
(FD / "gone").unlink()
check(len([x for x in log() if x["m"] == "POST" and "marina-new:proj" in json.dumps(x.get("b"), ensure_ascii=False)]) == 2, "다시 올림 1회")

# ── claude_argv 첫 지시 ───────────────────────────────────────────────────────
base = ms.claude_argv("proj", "t")
check(ms.claude_argv("proj", "t", first="") == base and base[-1].endswith("settings.json"), "first 없으면 기존 동작")
check(ms.claude_argv("proj", "t", first="--hi")[-1] == "--hi" and ms.claude_argv("proj", "t", first="--hi")[:-1] == base, "first 는 마지막 argv 한 원소")

# ── slug ─────────────────────────────────────────────────────────────────────
answer("refund-bug\n")
check(ms.suggest_slug("환불 버그") == "refund-bug", "haiku 답 그대로")
calls = list((T / "slugcalls").iterdir())
envs = "\n".join((c / "env").read_text() for c in calls)
check("CLAUDECODE" not in envs and "CLAUDE_CODE_ENTRYPOINT" not in envs, "이름 짓기 claude 는 CLAUDE* env 제거")
argv = (calls[0] / "argv").read_bytes().split(b"\0")
check(b"haiku" in argv and b"-p" in argv, f"claude -p --model haiku: {argv}")
answer("Bad Slug!\n"); s = ms.suggest_slug("x")
check(re.fullmatch(r"task-\d{4}-\d{4}", s), f"형식 불일치 폴백: {s}")
answer("a" * 80); check(re.fullmatch(r"task-\d{4}-\d{4}", ms.suggest_slug("x")), "너무 길면 폴백")
(T / "slug-fail").write_text("1"); check(re.fullmatch(r"task-\d{4}-\d{4}", ms.suggest_slug("x")), "claude 실패 폴백")
(T / "slug-fail").unlink()

# ── 충돌 접미사 ───────────────────────────────────────────────────────────────
check(ms.unique_slug("proj", "free") == "free", "비어 있으면 그대로")
wt = Path(ms.project_root("proj")) / ".claude" / "worktrees"
(wt / "free").mkdir(parents=True)
check(ms.unique_slug("proj", "free") == "free-2", "워크트리 폴더 있으면 -2")
(wt / "free-2").mkdir()
check(ms.unique_slug("proj", "free") == "free-3", "-2 도 있으면 -3")
ms.save_sessions(ms.load_sessions() + [{"project": "proj", "task": "free-3", "kind": "dev"}])
check(ms.unique_slug("proj", "free") == "free-4", "세션 기록도 충돌")
ms.save_sessions([s for s in ms.load_sessions() if s.get("task") != "free-3"])

# ── base · title ──────────────────────────────────────────────────────────────
check(ms.extract_base("proj", "결제 버그 고쳐줘 dev에서 시작") == "dev", "dev에서 → dev")
check(ms.extract_base("proj", "nope에서 해줘") == "", "없는 브랜치는 빈 값")
check(ms.extract_base("proj", "서울에서 해줘") == "", "한글 단어는 브랜치 아님")
check(ms.extract_base("proj", "그냥 해줘") == "", "없으면 빈 값")
check(ms.task_title("첫 줄\n둘째 줄") == "첫 줄", "첫 줄만")
check(ms.task_title("가" * 50) == "가" * 40 + "…", f"40자 넘으면 …: {ms.task_title('가' * 50)}")

# ── new-from-text ─────────────────────────────────────────────────────────────
answer("refund-bug\n")
text = "결제 페이지 `환불` 버그 @everyone --dangerously-skip dev에서 시작"
LCH = next(x for x in ms.load_sessions() if x.get("kind") == "dev-lobby")["channelId"]
out = mb.new_from_text("proj", "U2", text, LCH)
check("권한" in out and not any(s.get("task") == "refund-bug" for s in ms.load_sessions()), f"허용 안 된 사용자 거부: {out}")
check("1~500" in mb.new_from_text("proj", "U1", "  ", LCH) and "1~500" in mb.new_from_text("proj", "U1", "가" * 501, LCH), "길이 검사")
check("로비" in mb.new_from_text("nope", "U1", "x", LCH), "모르는 프로젝트")
before = len(log())
check("패널" in mb.new_from_text("proj", "U1", "x", "999"), "(M2) 로비 채널이 아니면 거부")
out = mb.new_from_text("proj", "U1", text, LCH, "수민 \"<@1>\"")
rec = next((s for s in ms.load_sessions() if s.get("task") == "refund-bug"), None)
check(rec is not None and out == f"열었어: <#{rec['channelId']}>", f"열었어 + 채널 링크: {out}")
new = log()[before:]
create = [x for x in new if x["m"] == "POST" and x["p"] == "/guilds/G1/channels"]
check(create and create[0]["b"].get("topic", "").startswith("결제 페이지"), f"채널 주제=title: {create}")
posted = [x for x in new if x["m"] == "POST" and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(posted and posted[0]["b"]["content"].startswith("📝 수민 ") and posted[0]["b"]["allowed_mentions"] == {"parse": []}, f"📝 메시지: {posted}")
check("`" not in posted[0]["b"]["content"] and "@everyone" not in posted[0]["b"]["content"], "백틱·멘션 무력화")
time.sleep(1.5)
calls = [d for d in (T / "claude-calls").iterdir() if (d / "argv").exists() and (d / "cwd").read_text().strip().endswith("worktrees/refund-bug")]
check(calls, "세션 claude 가 새 워크트리에서 뜸")
av = (calls[0] / "argv").read_bytes().split(b"\0")[:-1] if calls else []
last = av[-1].decode() if av else ""
check(last.startswith(f'<channel source="plugin:discord:discord" chat_id="{rec["channelId"]}" message_id="m-sent" user="') and "[Discord 새 작업 버튼]" in last
      and text in last and "채널 reply 로" in last and "</channel>" in last, f"(I1) 첫 지시는 inbound 태그 형식: {last!r}")
check('user="수민 @ 1"' not in last and re.search(r'user="수민 [0-9]*"', last.split(">", 1)[0]) and "<@" not in last.split(">", 1)[0], f"(M7) 표시 이름이 태그 user 에(특수문자 제거): {last[:200]!r}")
check(av.count(last.encode()) == 1 and not any(a.decode().startswith("--dangerously") for a in av), "텍스트는 한 원소로만")
wtbase = subprocess.run(["git", "-C", str(wt / "refund-bug"), "merge-base", "--is-ancestor", "dev", "HEAD"], capture_output=True)
check(wtbase.returncode == 0, "dev 에서 시작")
check(subprocess.run(["git", "-C", str(wt / "refund-bug"), "merge-base", "--is-ancestor", os.environ["DEVSHA"], "HEAD"]).returncode == 0
      and (wt / "refund-bug" / "devfile").exists(), "(I5) dev 에만 있는 커밋·파일이 들어 있음")
out2 = mb.new_from_text("proj", "U1", "또 환불", LCH)
check(not (wt / "refund-bug-2" / "devfile").exists() and subprocess.run(["git", "-C", str(wt / "refund-bug-2"), "merge-base", "--is-ancestor", os.environ["DEVSHA"], "HEAD"]).returncode != 0,
      "(I5) base 없으면 main 기준 — dev 커밋 미포함")
check(any(s.get("task") == "refund-bug-2" for s in ms.load_sessions()) and out2.startswith("열었어"), f"같은 slug → -2: {out2}")
(T / "slug-fail").write_text("1")
rec_ids = {s["task"] for s in ms.load_sessions()}
check(mb.new_from_text("proj", "U1", "폴백이름", LCH).startswith("열었어") and any(re.fullmatch(r"task-\d{4}-\d{4}", s["task"]) for s in ms.load_sessions()), "폴백 이름으로도 열림")

# CLI(C1): 봇이 띄우는 python 의 env 그대로(짧은 PATH) — claude 가 ~/.local/bin 에만 있어도 찾아야 한다
(T / "slug-fail").unlink(); answer("cli-one")
fh = T / "fakehome"; (fh / ".local/bin").mkdir(parents=True)
(fh / ".local/bin/claude").write_text((T / "bin2/claude").read_text()); (fh / ".local/bin/claude").chmod(0o755)
benv = mb.bot_command(ms.load_config())["env"]
benv = {k: v for k, v in benv.items() if k != "DISCORD_BOT_TOKEN"}; benv["HOME"] = str(fh)
benv["PATH"] = benv["PATH"].replace("/opt/homebrew/bin", "")      # bun 위치가 claude 를 가리는 일 방지
check(not any((Path(d) / "claude").exists() for d in benv["PATH"].split(":")), f"전제: 짧은 PATH 엔 claude 없음 {benv['PATH']}")
r = subprocess.run([sys.executable, str(Path(mb.__file__)), "new-from-text", "--project", "proj", "--user", "U1", "--channel", LCH, "--name", "수민", "--text=--weird 글"],
                   capture_output=True, text=True, env=benv)
check(r.returncode == 0 and r.stdout.startswith("열었어"), f"CLI: {r.stdout!r} {r.stderr[-300:]!r}")
check(any(s["task"] == "cli-one" for s in ms.load_sessions()), "(C1) 짧은 PATH 에서도 haiku slug 가 쓰임(폴백 아님)")

# ── I2 예약어·기존 브랜치 / I3 origin·마지막 에서 / M3 title / M4 플래그 ─────────
subprocess.run(["git", "-C", str(ms.project_root("proj")), "branch", "taken-br"], check=True)
check(ms.unique_slug("proj", "taken-br") == "taken-br-2", "(I2) 기존 브랜치와 안 겹침")
check(ms.unique_slug("proj", "dev") == "dev-2" and ms.unique_slug("proj", "main") == "main-2" and ms.unique_slug("proj", "prod") == "prod-2", "(I2) 예약어 금지")
answer("main"); check(ms.suggest_slug("x") != "main", "(I2) haiku 가 main 을 줘도 폴백")
subprocess.run(["git", "-C", str(ms.project_root("proj")), "branch", "loc"], check=True)
check(ms.extract_base("proj", "loc에서 하다가 dev에서 시작") == "dev", "(I3) '에서 시작' 우선")
check(ms.extract_base("proj", "dev에서 보고 loc에서 해줘") == "loc", "(I3) 여러 개면 마지막")
bare = T / "origin.git"; subprocess.run(["git", "clone", "-q", "--bare", str(ms.project_root("proj")), str(bare)], check=True)
subprocess.run(["git", "-C", str(ms.project_root("proj")), "remote", "add", "origin", str(bare)], check=True)
subprocess.run(["git", "-C", str(bare), "branch", "remoteonly", "main"], check=True)
check(ms.extract_base("proj", "remoteonly에서 해줘") == "origin/remoteonly", "(I3) fetch 후 origin 에만 있는 브랜치")
check(ms.extract_base("proj", "dev에서 해줘") == "origin/dev", "(I3) origin 에 있으면 origin/<b>")
subprocess.run(["git", "-C", str(ms.project_root("proj")), "branch", "localonly"], check=True)
check(ms.extract_base("proj", "localonly에서 해줘") == "localonly", "(I3) 로컬뿐이면 로컬")
check(ms.task_title("a@b <c>\n`d`") == "a b c", f"(M3) title 문자 거름: {ms.task_title('a@b <c>')!r}")
check(ms.task_title("@<>") == "새 작업", "(M3) 다 걸러지면 기본")
(T / "slugcalls").mkdir(exist_ok=True); answer("ok-slug"); ms.suggest_slug("x")
last_call = max((T / "slugcalls").iterdir(), key=lambda d: (d / "argv").stat().st_mtime)
av = (last_call / "argv").read_bytes().split(b"\0")
check(b"--strict-mcp-config" in av and av[av.index(b"--setting-sources") + 1] == b"", f"(M4) 플래그: {av}")
check("ENABLE_CLAUDEAI_MCP_SERVERS=false" in (last_call / "env").read_text(), "(M4) claude.ai 커넥터 끔")
# M1: 예상 못 한 예외도 짧은 문구
ms_cmd_new = ms.cmd_new
ms.cmd_new = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom secret"))
r1 = mb.new_from_text("proj", "U1", "x", LCH); ms.cmd_new = ms_cmd_new
check("boom" not in r1 and "못 열었어" in r1, f"(M1) 예외 문구: {r1!r}")

# 패널 틱: 로비가 없는 프로젝트는 건드리지 않고, 한 번 확인 후 간격을 둔다
n = len(log())
check(mb.panel_tick(100.0, 100.0 + mb.PANEL_EVERY - 1) == 100.0 and len(log()) == n, "간격 안엔 확인 안 함")
(FD / "gone").write_text("m-sent\n"); n = len(log())
check(mb.panel_tick(100.0, 100.0 + mb.PANEL_EVERY) == 100.0 + mb.PANEL_EVERY, "간격 지나면 확인하고 새 시각 반환")
check(len([x for x in log()[n:] if x["m"] == "POST" and "marina-new:proj" in json.dumps(x.get("b"), ensure_ascii=False)]) == 1, "틱이 지워진 패널을 다시 올림")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY

# bot.ts: 버튼 → 모달 → 제출(ephemeral → new-from-text → editReply)
BOT="$DSCRIPTS/marina-discord-bot/bot.ts"
grep -q 'marina-new:' "$BOT" || fail "bot.ts: marina-new 버튼 없음"
grep -q 'marina-newt:' "$BOT" || fail "bot.ts: 모달 제출 없음"
grep -q 'new-from-text' "$BOT" || fail "bot.ts: new-from-text 호출 없음"
grep -q 'MessageFlags.Ephemeral\|ephemeral: true' "$BOT" || fail "bot.ts: ephemeral 없음"
grep -q 'timeout: 600000' "$BOT" || fail "bot.ts: 타임아웃 600초"
grep -q -- '--channel", it.channelId' "$BOT" || fail "bot.ts: --channel 전달"
grep -q 'globalName' "$BOT" || fail "bot.ts: 표시 이름 전달"
if sed -n '/marina-newt:/,/^});/p' "$BOT" | grep 'editReply' | grep -q 'errOut\|String(err'; then fail "bot.ts: 에러 원문을 사용자에게 보이면 안 됨(고정 문구)"; fi
grep -q -- '--text=' "$BOT" || fail "bot.ts: --text= 로 넘겨야 '-' 로 시작하는 글도 값"
if command -v bun >/dev/null 2>&1; then
  ( cd "$DSCRIPTS/marina-discord-bot" && bun build bot.ts --target=bun --outfile "$TMPROOT/bot.js" >/dev/null ) || fail "bot.ts 빌드"
fi
echo "PASS test-discord-new-task"
