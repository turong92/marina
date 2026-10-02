#!/usr/bin/env bash
# marina session new <프로젝트> <이름> --from <대화ID> — 이미 하던 개발 대화를 Discord 채널로 옮긴다.
#  - 워크트리를 새로 만들지 않고 그 대화가 돌던 폴더(워크트리 또는 main 체크아웃)를 그대로 쓴다
#  - 대화는 복사본(--fork-session)으로 이어 간다 — 데스크톱이 원본을 열고 있어도 안전
#  - 이후 start 는 자기 대화 ID 로(--resume) — 같은 워크트리의 다른 대화(--continue)를 집지 않게
#  - 프로젝트 밖 폴더의 대화·없는 대화·이미 세션이 붙은 폴더는 거절, 실행 환경(marina start)은 건드리지 않는다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }

WT="$SRC/.claude/worktrees/feat-x-ab12cd"; mkdir -p "$WT"
OLD=11111111-2222-3333-4444-555555555555; ROOTSID=66666666-7777-8888-9999-000000000000; OUTSID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
mk() {   # mk <cwd> <sid>
  key="$(python3 -c 'import os,re,sys; print(re.sub(r"[^A-Za-z0-9]","-",os.path.realpath(sys.argv[1])))' "$1")"
  mkdir -p "$MARINA_CLAUDE_PROJECTS/$key"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hi"}}\n' "$(cd "$1" && pwd -P)" > "$MARINA_CLAUDE_PROJECTS/$key/$2.jsonl"
}
mk "$WT" "$OLD"; mk "$SRC" "$ROOTSID"; mkdir -p "$TMPROOT/elsewhere"; mk "$TMPROOT/elsewhere" "$OUTSID"

out="$(msess new proj gcp-review --from $OLD 2>&1)" || fail "옮기기 실패: $out"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "채널 링크 없음: $out"
[ ! -e "$SRC/.claude/worktrees/gcp-review" ] || fail "워크트리를 새로 만듦"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done

PYTHONPATH="$SCRIPTS" python3 - "$WT" "$OLD" "$FAKE_OUT" "$SRC" "$ROOTSID" "$OUTSID" <<'PY'
import os, sys, time
from pathlib import Path
import marina_session as ms
wt, old, out, src, rootsid, outsid = Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]).resolve(), sys.argv[5], sys.argv[6]
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/gcp-review")
check(rec["root"] == str(wt), f"원래 대화 폴더를 쓴다: {rec['root']}")
check(rec.get("forkedFrom") == old and rec.get("sessionId") and rec["sessionId"] != old, f"복사본 기록: {rec}")
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv == ms.claude_argv("proj", "gcp-review", session_id=rec["sessionId"], from_id=old)[1:], f"인자: {argv}")
check(argv[argv.index("--resume") + 1] == old and "--fork-session" in argv
      and argv[argv.index("--session-id") + 1] == rec["sessionId"], "복사본으로 시작")
check("--remote-control" in argv and "--channels" in argv, "개발 세션 인자 유지")
check((calls[-1] / "cwd").read_text().strip() == str(wt), "cwd = 원래 워크트리")

# start: 복사본 기록이 없으면 다시 복사본으로, 있으면 자기 ID 로(--continue 금지)
check(ms.session_argv(rec, resume=True) == ms.claude_argv("proj", "gcp-review", session_id=rec["sessionId"], from_id=old),
      f"기록 없을 때 start: {ms.session_argv(rec, resume=True)}")
tr = ms.transcript_path(wt, rec["sessionId"]); tr.write_text("{}\n")
a2 = ms.session_argv(rec, resume=True)
check(a2[a2.index("--resume") + 1] == rec["sessionId"] and "--continue" not in a2 and "--fork-session" not in a2, f"기록 있을 때 start: {a2}")
# --from 없는 보통 세션은 그대로 --continue
check("--continue" in ms.session_argv({"project": "proj", "task": "t", "root": str(wt)}, resume=True), "보통 세션 start 는 그대로")

def new(task, sid):
    try:
        ms.cmd_new("proj", task, from_id=sid); return ""
    except ms.SessionError as exc:
        return str(exc)
check("이미" in new("again", old), "같은 폴더에 세션이 또 붙으면 거절")
check("프로젝트" in new("outside", outsid), "프로젝트 밖 폴더의 대화는 거절")
gone = src / ".claude" / "worktrees" / "gone-0c0c0c"; gone.mkdir(parents=True)
GONE = "44444444-5555-6666-7777-888888888888"
import json as _j, re as _re
_d = Path(os.environ["MARINA_CLAUDE_PROJECTS"]) / _re.sub(r"[^A-Za-z0-9]", "-", str(gone.resolve())); _d.mkdir(parents=True)
(_d / f"{GONE}.jsonl").write_text(_j.dumps({"type": "user", "cwd": str(gone.resolve())}) + "\n")
gone.rmdir()
check("지워" in new("gone", GONE), f"워크트리가 지워졌으면 그렇게 알린다: {new('gone2', GONE)}")
check("찾지 못" in new("nope", "12345678-1234-1234-1234-123456789012"), "없는 대화는 거절")
check("UUID" in new("bad", "not-a-uuid"), "대화 ID 형식")
check(new("root-work", rootsid) == "", "main 체크아웃에서 하던 대화도 옮길 수 있다")
check(ms.find_session("proj/root-work")["root"] == str(src), "main 체크아웃 = 프로젝트 루트")
# 대화 중 하위 폴더로 cd 해도, 워크트리를 옮겨 다녀도 → 기록이 저장된 폴더(= 띄운 곳)를 고른다
import json, re
def key(p): return re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(str(p)))
wt2 = src / ".claude" / "worktrees" / "moved-9f9f9f"; wt2.mkdir(parents=True, exist_ok=True)
proj = Path(os.environ["MARINA_CLAUDE_PROJECTS"])
def mk(home, cwds, sid):
    d = proj / key(home); d.mkdir(parents=True, exist_ok=True)
    (d / f"{sid}.jsonl").write_text("".join(json.dumps({"type": "user", "cwd": str(c)}) + "\n" for c in cwds))
SUB = "22222222-3333-4444-5555-666666666666"; MOV = "33333333-4444-5555-6666-777777777777"
mk(wt2, [wt2, wt2 / "be-api", wt2 / "tasks"], SUB)
check(ms.conversation_home(ms.find_transcript(SUB)) == str(wt2.resolve()), "하위 폴더로 cd 해도 띄운 폴더")
wt3 = src / ".claude" / "worktrees" / "first-1a1a1a"; wt3.mkdir(parents=True, exist_ok=True)
mk(wt2, [wt3, wt3 / "x", wt2], MOV)   # wt3 에서 시작해 wt2 로 옮겨 감 → 기록은 wt2 아래
check(ms.conversation_home(ms.find_transcript(MOV)) == str(wt2.resolve()), "옮겨 간 워크트리")
# (리뷰 1) 워크트리 안 하위 폴더에서 띄운 대화는 거절 — 삭제 연동·중복 검사가 워크트리 경계로 돈다
SUBL = "55555555-6666-7777-8888-999999999999"
(wt2 / "be-api").mkdir(exist_ok=True)
mk(wt2 / "be-api", [wt2 / "be-api"], SUBL)
check("워크트리" in new("sub-launch", SUBL), "하위 폴더에서 띄운 대화 거절")
# (리뷰 3) 같은 대화 기록이 여러 곳 → 가장 최근 것
DUP = "66666666-7777-8888-9999-aaaaaaaaaaaa"
mk(wt3, [wt3], DUP); time.sleep(1.1); mk(wt2, [wt3, wt2], DUP)
check(ms.find_transcript(DUP).parent.name == key(wt2), "여러 사본이면 최신")
# (리뷰 2) 이어받은 세션이 다른 워크트리로 옮겨 가면 start 는 옮겨 간 곳에서 자기 ID 로 잇는다(다시 fork 하지 않음)
rec2 = ms.find_session("proj/root-work")
mk(wt3, [src, wt3], rec2["sessionId"])
cwd, argv = ms.session_launch(rec2, resume=True)
check(cwd == wt3.resolve() and argv[argv.index("--resume") + 1] == rec2["sessionId"] and "--fork-session" not in argv,
      f"옮겨 간 곳에서 잇기: {cwd} {argv[:6]}")
w = ms.teardown(ms.find_session("proj/gcp-review"))
check(wt.is_dir(), "rm 은 워크트리를 안 건드린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-adopt"
