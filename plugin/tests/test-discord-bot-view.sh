#!/usr/bin/env bash
# (실사용 2026-10-07)
#  1) 새로 연 방(sessionId 없음)은 #상태에 컨텍스트 크기가 안 나왔다 → 그 방 폴더의 가장 최근 기록으로
#  2) [보기] 에 같은 에이전트가 두 번 — 기록에서 찾은 에이전트 + 화면 아래 팀 에이전트 목록 줄이 별개 항목으로 합쳐졌다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"
export MARINA_CLAUDE_TMP="$TMPROOT/claudetmp"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, os, re, subprocess, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_usage as mu
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a")
ms.save_sessions([{k: v for k, v in x.items() if k != "sessionId"} if x.get("stateDir") == rec["stateDir"] else x for x in ms.load_sessions()])
rec = ms.find_session("proj/feat/a"); ch = rec["channelId"]
check(not rec.get("sessionId"), f"전제: sessionId 없음 {rec}")

# ── 1) 컨텍스트 % ──
mu.context_percent = lambda p: 42.0 if Path(p).exists() else None
check(mb._ctx_percent(rec) is None, "기록 없음 → None")
d = ms.transcript_path(Path(rec["root"]), "x").parent; d.mkdir(parents=True, exist_ok=True)
tr = d / "11111111-0000-0000-0000-000000000001.jsonl"
tr.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "hi"}}) + "\n")
check(mb._ctx_percent(rec) == 42.0, f"sessionId 없어도 방 폴더의 최근 기록으로: {mb._ctx_percent(rec)}")
_real_born = mb._session_born
mb._session_born = lambda name: time.time() + 3600      # 세션이 뜬 뒤 안 움직인 파일 = 다른 세션(데스크톱 앱 등)
check(mb._ctx_percent(rec) is None, "세션이 뜨기 전에 끝난 기록은 고르지 않는다")
mb._session_born = _real_born                           # 1절의 stub 은 여기서 끝 — 뒤로 새지 않게 복원

# ── 2) [보기] 중복 ──
# 의도적 stub(2~4절만): pane() 이 절마다 tmux 세션을 다시 만들어 에이전트 기록 mtime 이 세션 시작보다 앞서므로, "세션 뜬 뒤 움직임" 판정은 이 절들의 관심사가 아니다
mb._session_born = lambda name: 0.0
sid = "abcdabcd-0000-1111-2222-333344445555"
ms.save_sessions([dict(x, sessionId=sid) if x.get("stateDir") == rec["stateDir"] else x for x in ms.load_sessions()])
rec = ms.find_session("proj/feat/a")
tr = ms.transcript_path(Path(rec["root"]), sid)
def use(tid, name, inp):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}
def res(tid, text):
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}}
rows = [use("a1", "Agent", {"description": "탈퇴 계정 익명화", "prompt": "x", "run_in_background": True}),
        res("a1", [{"type": "text", "text": "agentId: aone1 (internal ID)"}])]
tr.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
sub = tr.parent / sid / "subagents"; sub.mkdir(parents=True)
LONG = "- **RED** (compile). `Implement` the JDBC lease. " + "x" * 300 + "\n다음 줄은 안 나온다"
def agent(aid, desc, name, words="아직"):
    (sub / f"agent-{aid}.jsonl").write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": words}]}}) + "\n")
    (sub / f"agent-{aid}.meta.json").write_text(json.dumps({"description": desc, "name": name, "customAgentType": "developer"}))
agent("aone1", "탈퇴 계정 익명화", "anon", LONG)
agent("atwo2", "인증번호 카운트다운", "countdown", "Weights are literal 650 throughout; follow that.")
base = ms._tmux_base()
def pane(text):
    subprocess.run(base + ["kill-session", "-t", rec["tmux"]], capture_output=True)
    subprocess.run(base + ["new-session", "-d", "-s", rec["tmux"], "sh", "-c", f"printf '{text}'; exec cat"], check=True)
    time.sleep(0.5)
for f in sub.glob("agent-*.jsonl"): os.utime(f)
mb.claude_usage = lambda: []
HEAD = "✻ Worked\\n────\\n❯ \\n────\\n  ⏵⏵ bypass · ← for agents\\n  ⏺ main\\n"
pad = " " * 40
# 기록 에이전트 2 + 화면 목록 2(같은 에이전트) → 2줄
pane(HEAD + f"  ◯ anon  Awaiting other-module test results{pad}\\n  ◯ countdown  Exporting time helpers{pad}\\n")
out = mb.view(ch, "U1")
heads = [l for l in out.splitlines() if l.startswith("🤖")]
check(len(heads) == 2, f"기록 2 + 화면 2(같은 에이전트) → 2줄: {out}")
check(all(h == h.rstrip() and "  " not in h for h in heads), f"제목 뒤 공백 없음: {heads}")
check("지금: Awaiting other-module test results" in out and "**Awaiting" not in out, f"화면 상태 문구는 기록 항목의 지금: 줄로: {out}")
# 마지막 말: 첫 줄·마크다운 풀고 140자 한 줄
w = next(l for l in out.splitlines() if "RED" in l)
check("**" not in w and "`" not in w and not w.startswith("- ") and len(w) <= 141 and "다음 줄" not in out, f"마지막 말 한 줄 140자: {w!r} {len(w)}")
check("Weights are literal 650 throughout; follow that." in out, f"영어 그대로: {out}")
# 기록 1 + 화면 2 → 2줄(보충 1), 보충 줄은 '지금: …'
os.utime(sub / "agent-atwo2.jsonl", (time.time() - 900, time.time() - 900))
pane(HEAD + f"  ◯ anon  Awaiting other-module test results{pad}\\n  ◯ helper-9  Exporting time helpers{pad}\\n")
out = mb.view(ch, "U1")
heads = [l for l in out.splitlines() if l.startswith("🤖")]
check(len(heads) == 2 and heads[1] == "🤖 **helper-9**" and "지금: Exporting time helpers" in out, f"기록 1 + 화면 2 → 2줄(보충 1): {out}")
# 같은 description 이 정말 둘이면 구분
agent("athree3", "탈퇴 계정 익명화", "anon-b")
pane(HEAD)
out = mb.view(ch, "U1")
heads = [l for l in out.splitlines() if l.startswith("🤖")]
check(len(heads) == 2 and len(set(heads)) == 2 and "#anon" in heads[0] and "#anon-b" in heads[1], f"같은 설명 둘 → 구분: {heads}")
# 개수 판정은 그대로 — live_tasks 는 합치기만(화면 줄도 센다)
pane(HEAD + f"  ◯ anon  Awaiting other-module test results{pad}\\n  ◯ helper-9  Exporting time helpers{pad}\\n")
lt = mb.live_tasks(rec)
check(len(lt) == 4, f"live_tasks 개수 불변(기록 2 + 화면 2): {[(t['id'], t['desc']) for t in lt]}")
rb = mb.restart_blockers(rec) if hasattr(mb, "restart_blockers") else None
check(rb is None or any("백그라운드 4" in x for x in rb), f"막는 판정 불변: {rb}")
# (실사용) 이름 없는 에이전트 — 화면 줄의 이름이 역할(developer·code-reviewer). 기록 항목에 합친다
for f in sub.glob("agent-*"): f.unlink()
agent("ad1", "카운트다운 만들기", "", "Prettier had reformatted that; fix by hand.")
agent("ad2", "화면 정리", "", "정리 중")
agent("arv1", "익명 브랜치 코드 리뷰", "", "")
for a, d in (("ad1", "카운트다운 만들기"), ("ad2", "화면 정리")):
    (sub / f"agent-{a}.meta.json").write_text(json.dumps({"description": d, "customAgentType": "developer"}))
(sub / "agent-arv1.meta.json").write_text(json.dumps({"description": "익명 브랜치 코드 리뷰", "customAgentType": "code-reviewer"}))
(sub / "agent-arv1.jsonl").write_text("{}\n")
for f in sub.glob("agent-*.jsonl"): os.utime(f)
pane(HEAD + "  ◯ developer  Diagnosing SignUp.stories.tsx failures 11m 30s · ↓ 194.7k tokens\\n  ◯ developer  Second thing 2m 5s · ↓ 1k tokens\\n  ◯ code-reviewer  Checking V2026__accounts.sql migration history 3m 42s · ↓ 147.3k token\\n  ◯ developer  Extra one\\n")
out = mb.view(ch, "U1")
heads = [l for l in out.splitlines() if l.startswith("🤖")]
check(sorted(heads[:3]) == sorted(["🤖 **카운트다운 만들기**", "🤖 **화면 정리**", "🤖 **익명 브랜치 코드 리뷰**"]) and heads[3:] == ["🤖 **developer**"], f"역할로 짝지어 합침(developer 2쌍 + 1개 보충): {out}")
check("지금: Diagnosing SignUp.stories.tsx failures · 11분" in out and "194.7k" not in out and "30s" not in out, f"시간·토큰 꼬리 줄임: {out}")
check("지금: Checking V2026__accounts.sql migration history · 3분\n" in out + "\n", f"리뷰어도 합침: {out}")
i = out.index("카운트다운 만들기")
check(out[i:].splitlines()[1].startswith("지금:") and out[i:].splitlines()[2].startswith("Prettier"), f"제목 → 지금 → 마지막 말 순: {out}")
check("아직 말 없음" not in out.split("🤖 **익명")[1].split("🤖")[0], f"지금: 줄이 있으면 '아직 말 없음' 생략: {out}")
# ── 3) 짝짓기 순서: 이름 → 설명 → 역할 — 같은 역할(developer)이 둘이어도 설명이 같은 쪽에 붙는다
for f in sub.glob("agent-*"): f.unlink()
agent("ax1", "첫번째 일", "", "w1")
agent("ax2", "둘째 일 정확", "", "w2")
for f in sub.glob("agent-*.jsonl"): os.utime(f)
pane(HEAD + "  ◯ developer  둘째 일 정확\\n")
out = mb.view(ch, "U1")
check("**둘째 일 정확**\n지금: 둘째 일 정확" in out and "**첫번째 일**\nw1" in out and "**첫번째 일**\n지금" not in out, f"설명이 같은 항목에 붙는다(역할 순서가 아니라): {out}")

# ── 4) 글자 예산: 지금: 줄도 계산하고, 넘치면 마지막에 "… 외 N개"
real_live = mb.live_tasks
def fake_agent(i):
    aid = f"bud{i:02d}"
    (sub / f"agent-{aid}.jsonl").write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "말" * 300}]}}) + "\n")
    return {"kind": "agent", "id": aid, "desc": f"예산 작업 {i:02d}", "now": "상" * 300}
tasks14 = [fake_agent(i) for i in range(14)]
mb.live_tasks = lambda r: [dict(t) for t in tasks14]
out = mb.view(ch, "U1")
heads = [l for l in out.splitlines() if l.startswith("🤖")]
m = re.search(r"\n… 외 (\d+)개$", out)
check(len(out) <= 1900 and m and len(heads) + int(m.group(1)) == 14, f"넘치면 마지막 줄에 외 N개(보인 {len(heads)} + N = 14, 길이 {len(out)}): {out[-80:]!r}")
mb.live_tasks = lambda r: [dict(t) for t in tasks14[:2]]
out = mb.view(ch, "U1")
check("… 외" not in out and len([l for l in out.splitlines() if l.startswith("🤖")]) == 2, f"다 들어가면 외 N개 없음: {out}")
mb.live_tasks = real_live
mb._session_born = _real_born
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-bot-view"
