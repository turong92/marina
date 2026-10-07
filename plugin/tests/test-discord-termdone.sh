#!/usr/bin/env bash
# 터미널 넘기기의 "끝" — 설계 1절: 명령이 끝나면(셸 프롬프트로 돌아옴) 페이지에 '끝났어' + 세션에 알림, 끝난 지 30분 뒤 정리.
#  - marina_termbridge.watch: tmux 가 주는 값(pane_current_command·전경 프로세스 그룹)으로 판정 — 화면 글자 짐작 안 함
#      끝 = (Enter 가 keys 로 들어온 뒤 | 실행 중을 한 번이라도 본 뒤) + 지금 셸이 유휴 + 2초 이상 유지. 터미널당 한 번(doneAt)
#  - screen JSON 의 done·doneAt, term.js 배너
#  - Loop.watch_term: 5초 간격, 세션이 살아 있으면 입력창에 안내(_spawn_type) + term-last.txt(0600), 꺼져 있으면 채널에 조용한 한 줄
#  - 화면 내용은 사람이 넘길 때만 세션에 간다: 끝 알림은 내용 없는 고정 문구, 페이지의 "넘기기" 버튼(POST /t/<토큰>/share)이 비밀을 가린 끝 40줄을
#    <상태 폴더>/term-last-<tmux id>.txt(0600)에 쓰고 두 번째 고정 문구로 경로를 알린다
#  - 오판 줄이기: 사람이 안 쳤을 때의 실행 중 인정은 만든 지 10초 뒤 연속 두 표본, 묻는 프롬프트(y/N·quote>·Password: …)면 끝 아님, 세션이 사라져도 끝
#  - sweep: 끝난 터미널은 max(doneAt, lastActiveAt) + 30분에 정리(term-last 파일도, 오래된 term-last-* 도)
# 전용 tmux 소켓·임시 MARINA_HOME·임시 HOME 만 쓴다. 실제 세션·Discord 는 안 건드린다(가짜 Discord).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
export SHELL=/bin/sh HOME="$TMPROOT/home" HISTFILE=/dev/null
mkdir -p "$HOME"
start_fake_discord
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/t --no-start >/dev/null 2>&1 || { echo "FAIL: new"; exit 1; }

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" "$FD" "$DSCRIPTS" <<'PY'
import http.client, json, os, re, stat, sys, time
from pathlib import Path
import marina_termbridge as tb, marina_view as mv, marina_session as ms, marina_discord_bot as mb
tmp, fd, dscripts = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
home = Path(os.environ["MARINA_HOME"]); d = home / "discord-term"
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def rec(token): return json.loads((d / f"{token}.json").read_text())
def setrec(token, **kw):
    p = d / f"{token}.json"; x = json.loads(p.read_text()); x.update(kw); p.write_text(json.dumps(x))
def wait_screen(token, cookie, needle, secs=6.0):
    end = time.time() + secs; s = ""
    while time.time() < end:
        s = tb.screen(token, cookie) or ""
        if needle in s: return s
        time.sleep(0.1)
    return s
def wait_idle(token, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        if not tb._busy(rec(token)["tmux"]): return True
        time.sleep(0.1)
    return False
def wait_busy(token, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        if tb._busy(rec(token)["tmux"]): return True
        time.sleep(0.05)
    return False
def newterm(cmd, channel="C1", claim=True):
    t = tb.create(str(work), cmd, "w", channel)
    c = "k" * 20
    if claim: tb.claim(t, c)
    return t, c
def fresh(token, now):
    """watch 가 돌려주는(끝났고 아직 알리지 않은) 것 중 이 토큰 — 다른 테스트 터미널은 가린다."""
    return [x for x, _ in tb.watch(now) if x == token]
def log(): return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]

work = tmp / "wt"; work.mkdir()

# ── 1. 짧은 명령(echo): Enter 이후 + 유휴 2초 이상 → 끝. 표본이 '셸 아님'을 못 봐도 잡는다
t, c = newterm("echo SHORT-$((6*7))")
n = time.time()
check(fresh(t, n) == [] and "doneAt" not in rec(t), "Enter 전엔 유휴여도 끝이 아니다")
tb.send(t, c, key="Enter")
check(rec(t).get("enterAt"), f"Enter 시각을 기록: {rec(t)}")
check("SHORT-42" in wait_screen(t, c, "SHORT-42"), "명령이 실행됐다")
wait_idle(t); n = time.time()
check(fresh(t, n) == [] and "doneAt" not in rec(t), "유휴를 처음 본 순간엔 아직(2초 유지 필요)")
check(fresh(t, n + 1.0) == [] and "doneAt" not in rec(t), "1초 유지는 아직")
got = fresh(t, n + 2.2)
check(got == [t] and abs(rec(t).get("doneAt", 0) - (n + 2.2)) < 0.01, f"2초 이상 유지하면 끝: {got} {rec(t)}")
check(fresh(t, n + 9) == [t], "알리기 전엔 계속 알릴 대상으로 돌려준다(알림 실패 재시도)")
tb.mark_notified(t)
check(fresh(t, n + 12) == [] and rec(t).get("notifiedAt"), "알린 뒤엔 다시 안 돌려준다")

# ── 2. 두 번째 명령: 같은 터미널에서 또 쳐도 다시 알리지 않는다(doneAt 그대로)
done1 = rec(t)["doneAt"]
tb.send(t, c, text="echo SECOND"); tb.send(t, c, key="Enter")
wait_screen(t, c, "SECOND"); wait_idle(t)
check(fresh(t, n + 20) == [] and fresh(t, n + 25) == [] and rec(t)["doneAt"] == done1, "두 번째 명령은 다시 알리지 않는다")

# ── 3. 긴 명령(sleep 3): 도는 동안은 끝이 아니고, 끝나면 끝
t, c = newterm("sleep 3")
tb.send(t, c, key="Enter"); wait_busy(t)
check(fresh(t, time.time()) == [] and rec(t).get("sawBusy") is True, f"실행 중엔 끝이 아니다(실행 중을 봤다고 기록): {rec(t)}")
check(fresh(t, time.time() + 600) == [] and "doneAt" not in rec(t), "실행 중이면 시간이 한참 지난 것처럼 봐도 끝이 아니다")
wait_idle(t); n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 2.2) == [t], "sleep 이 끝나면 끝")

# ── 4. 실행 중 오래(전경이 셸 이름인 래퍼 스크립트): pane_current_command 는 'bash'/'sh' 로 보여도 끝이 아니다
#      cloud <env> … 같은 래퍼가 이 모양이다 — gcloud auth login 처럼 오래 기다리는 명령에서 중간에 끝으로 오판하면 안 된다
t, c = newterm("sh -c 'sleep 4; echo WRAPPED'")
tb.send(t, c, key="Enter"); wait_busy(t)
check(not tb._busy("x-none"), "없는 세션은 실행 중이 아니다(알 수 없으면 아니다)")
check(tb._busy(rec(t)["tmux"]), "전경 프로세스 그룹이 셸 것이 아니면 이름이 셸이어도 실행 중이다")
n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 3.0) == [] and fresh(t, n + 30) == [] and "doneAt" not in rec(t), f"래퍼 실행 중엔 끝이 아니다: {rec(t)}")
wait_idle(t); n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 2.2) == [t], "래퍼가 끝나면 끝")

# ── 5. Enter 를 안 누른 채: 끝 아님(미리 쳐 둔 명령을 둔 채 오래 놔둬도)
t, c = newterm("echo NEVER")
n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 6) == [] and fresh(t, n + 60) == [] and "doneAt" not in rec(t), "Enter 를 안 눌렀으면 몇 번을 봐도 끝이 아니다")
tb.send(t, c, text="x"); tb.send(t, c, key="Tab"); tb.send(t, c, key="C-c")
check(fresh(t, n + 90) == [] and "doneAt" not in rec(t), "Enter 가 아닌 키는 Enter 기록이 아니다")

# ── 6. 맥 앞에서 tmux attach 로 직접 친 경우(Enter 기록 없음, 링크도 안 연 터미널):
#      만든 지 10초 뒤의 연속 두 표본이 실행 중이어야 '실행 중을 봤다'(셸 rc 가 뜨며 잠깐 도는 외부 명령을 실행으로 안 본다)
t, _ = newterm("sleep 4", claim=False)
name = rec(t)["tmux"]
ms._tmux("send-keys", "-t", "=" + name + ":", "Enter"); wait_busy(t)
n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 1) == [] and not rec(t).get("sawBusy"), f"만든 지 10초 안의 실행 중은 표본으로 안 센다: {rec(t)}")
check(fresh(t, n + 11) == [] and not rec(t).get("sawBusy"), "한 번만 본 실행 중은 아직 아니다(연속 두 표본)")
check(fresh(t, n + 16) == [] and rec(t).get("sawBusy") is True and not rec(t).get("enterAt"), f"연속 두 표본이면 실행 중을 본 것: {rec(t)}")
wait_idle(t); n = time.time()
check(fresh(t, n + 20) == [] and fresh(t, n + 22.2) == [t], "직접 친 명령도 끝나면 끝(페이지를 안 열었어도)")
# 연속이 아니면 센 것이 지워진다 — 짧게 한 번 보이고 끝난 명령은 끝으로 못 잡는다(알려진 한계)
t, _ = newterm("sleep 1", claim=False)
ms._tmux("send-keys", "-t", "=" + rec(t)["tmux"] + ":", "Enter"); wait_busy(t)
fresh(t, time.time() + 11); wait_idle(t)
check(fresh(t, time.time() + 12) == [] and fresh(t, time.time() + 40) == [] and not rec(t).get("sawBusy") and "doneAt" not in rec(t), "한 번 보이고 만 짧은 직접 실행은 끝으로 보지 않는다")

# ── 6b. 묻는 프롬프트면 끝이 아니다(막는 방향으로만): 이어쓰기 프롬프트·[y/N]
t, c = newterm('echo "abc')
tb.send(t, c, key="Enter"); wait_screen(t, c, "> "); n = time.time()
check(tb._busy(rec(t)["tmux"]) is False and rec(t).get("enterAt"), "전제: 셸이 이어쓰기 프롬프트(> )에서 기다린다 — 이름으로는 유휴")
check(fresh(t, n) == [] and fresh(t, n + 3) == [] and fresh(t, n + 60) == [] and "doneAt" not in rec(t), "quote 이어쓰기 프롬프트는 끝이 아니다")
tb.send(t, c, key="C-c"); wait_screen(t, c, "$"); time.sleep(0.2); n = time.time()
fresh(t, n); check(fresh(t, n + 2.2) == [t], "프롬프트로 돌아오면 끝")
t, c = newterm("printf 'Go on [y/N] '; read x")
tb.send(t, c, key="Enter"); wait_screen(t, c, "[y/N]"); n = time.time()
check(fresh(t, n) == [] and fresh(t, n + 3) == [] and fresh(t, n + 60) == [], "[y/N] 로 묻는 중이면 끝이 아니다(read 는 셸 안이라 전경이 셸)")
tb.send(t, c, text="n"); tb.send(t, c, key="Enter"); wait_screen(t, c, "$ ")
time.sleep(0.2); n = time.time(); fresh(t, n); check(fresh(t, n + 2.2) == [t], "답하고 나면 끝")
for q in ("zsh: correct 'rm' to 'mv' [nyae]?", "rm: remove regular file 'x'?", "dquote>", "heredoc>", ">", "Password:", "[sudo] password for sumin:", "Continue? [Y/n]",
          "Are you sure you want to continue connecting (yes/no/[fingerprint])?"):
    check(tb._asks_line(q), f"묻는 줄로 본다: {q!r}")
for ok in ("$ ", "sumin@mac ~ % ", "done.", "5 files removed", "❯", "build finished in 3s", "> not a bare prompt"):
    check(not tb._asks_line(ok), f"묻는 줄이 아니다: {ok!r}")

# ── 6c. tmux 세션이 사라졌다(사람이 exit/C-d): Enter·sawBusy 기록이 있으면 끝(내용 없는 알림), 없으면 아니다
t, c = newterm("exit")
tb.send(t, c, key="Enter"); end = time.time() + 5
while time.time() < end and tb._alive(rec(t)["tmux"]): time.sleep(0.05)
check(not tb._alive(rec(t)["tmux"]), "전제: 세션이 닫혔다")
tb.sweep(time.time()); check((d / f"{t}.json").exists(), "닫혔어도 끝을 아직 못 알렸으면 sweep 이 기록을 둔다(알릴 틈)")
got = fresh(t, time.time()); check(got == [t] and rec(t).get("doneAt"), f"세션이 닫혀도 Enter 가 있었으면 끝: {got}")
tb.mark_notified(t); tb.sweep(time.time()); check(not (d / f"{t}.json").exists(), "알린 뒤엔 sweep 이 지운다")
t, c = newterm("exit")
ms._tmux("kill-session", "-t", "=" + rec(t)["tmux"])
check(fresh(t, time.time()) == [] and "doneAt" not in rec(t), "아무것도 안 돌린 채 사라진 세션은 끝이 아니다")
tb.sweep(time.time()); check(not (d / f"{t}.json").exists(), "그 기록은 sweep 이 지운다")

# ── 7. 데몬 재시작: 기록(doneAt·notifiedAt·idleSince)으로 이어간다 — 모듈 상태가 아니라 파일이 진실
t, c = newterm("echo RESTART")
tb.send(t, c, key="Enter"); wait_screen(t, c, "RESTART"); wait_idle(t); n = time.time()
fresh(t, n)
import importlib; importlib.reload(tb)         # 프로세스가 다시 뜬 것처럼
check(rec(t).get("idleSince") is not None, "유휴를 본 시각이 파일에 있다")
check(fresh(t, n + 2.2) == [t], "재시작 뒤에도 파일의 idleSince 로 이어서 끝으로 본다")
tb.mark_notified(t)
importlib.reload(tb)
check(fresh(t, n + 99) == [], "재시작 뒤에도 알린 건 다시 안 돌려준다")

# ── 8. screen JSON·페이지
t, c = newterm("echo WEBDONE", claim=False)
srv = mv.ViewServer(0); check(srv.start(), "서버 시작")
def req(path, headers=None):
    cn = http.client.HTTPConnection("127.0.0.1", srv.port, timeout=10); cn.request("GET", path, headers=headers or {})
    r = cn.getresponse(); body = r.read(); cn.close(); return r.status, body, r
st, _, r = req(f"/t/{t}/"); ck = (r.getheader("set-cookie") or "").split(";")[0]
st, body, _ = req(f"/t/{t}/screen", {"Cookie": ck}); j = json.loads(body)
check(st == 200 and j.get("done") is False and j.get("doneAt") in (None, 0), f"끝나기 전 JSON: {j}")
ck_val = ck.split("=", 1)[1]
tb.send(t, ck_val, key="Enter"); wait_screen(t, ck_val, "WEBDONE"); wait_idle(t); n = time.time()
tb.watch(n); tb.watch(n + 2.5)
st, body, _ = req(f"/t/{t}/screen", {"Cookie": ck}); j = json.loads(body)
check(st == 200 and j.get("done") is True and abs(j.get("doneAt", 0) - (n + 2.5)) < 0.01 and j.get("alive") is True, f"끝난 뒤 JSON: {j}")
check("WEBDONE" in j.get("screen", ""), "끝나도 화면은 계속 준다")
srv.stop()
js = (Path(dscripts) / "marina-view" / "term.js").read_text()
html = (Path(dscripts) / "marina-view" / "term.html").read_text()
check("j.done" in js and "명령이 끝났어" in js and "Discord 로 돌아가도 돼" in js, "term.js 가 끝 배너를 그린다")
check("innerHTML" not in js and "outerHTML" not in js and "insertAdjacentHTML" not in js, "배너도 textContent 로만")
check('id="done"' in html and "hidden" in html.split('id="done"')[1].split(">")[0], "term.html 에 숨겨진 배너 자리")
check("if (j.alive) schedule();" in js or "schedule()" in js, "폴링은 끝나도 계속")

# ── 9. 정리 시각: doneAt + 30분(마지막 키 입력 무관), 실행 중이면 보류, term-last.txt 도 지움
t, c = newterm("echo CLEAN")
tb.send(t, c, key="Enter"); wait_screen(t, c, "CLEAN"); wait_idle(t); n = time.time()
tb.watch(n); tb.watch(n + 2.5)
name = rec(t)["tmux"]
last = tmp / "term-last-clean.txt"; last.write_text("x"); os.chmod(last, 0o600)
setrec(t, lastActiveAt=n - 5000, lastFile=str(last), lastFileNs=last.stat().st_mtime_ns)    # 키 입력은 오래전 — 그래도 끝 기준으로
tb.sweep(n + 2.5 + 1500)
check(name in ms._tmux("list-sessions", "-F", "#{session_name}").stdout.split(), "끝난 지 25분이면 아직 둔다(마지막 키 입력이 오래돼도)")
tb.sweep(n + 2.5 + 1801)
check(name not in ms._tmux("list-sessions", "-F", "#{session_name}").stdout.split() and not (d / f"{t}.json").exists(), "끝난 지 30분이면 정리")
# 끝난 뒤에도 계속 쓰는 터미널은 마지막 키 입력 + 30분(max(doneAt, lastActiveAt))
t, c = newterm("echo $((6*7))XD"); tb.send(t, c, key="Enter"); wait_screen(t, c, "42XD"); wait_idle(t); n = time.time()
tb.watch(n); tb.watch(n + 2.5); setrec(t, lastActiveAt=n + 1000)
tb.sweep(n + 1000 + 1500); check((d / f"{t}.json").exists(), "끝난 뒤 계속 쓴 터미널은 마지막 키 입력 + 30분까지 둔다")
tb.sweep(n + 1000 + 1801); check(not (d / f"{t}.json").exists(), "마지막 키 입력 30분 뒤엔 정리")
# 오래된 term-last-*·임시 파일 정리(세션 상태 폴더 안) — 터미널 기록이 없어도
sdx = Path(ms.find_session("proj/feat/t")["stateDir"])
old1, old2, new1, other = sdx / "term-last-ab12.txt", sdx / ".tmp-term-last-zz", sdx / "term-last-cd34.txt", sdx / "term-last.txt"
for f in (old1, old2, new1, other): f.write_text("x")
for f in (old1, old2, other): os.utime(f, (time.time() - 1900, time.time() - 1900))
tb.sweep(time.time())
check(not old1.exists() and not old2.exists() and new1.exists() and other.exists(), f"오래된 term-last-*·.tmp-term-last-* 만 지운다: {[x.exists() for x in (old1, old2, new1, other)]}")
new1.unlink(); other.unlink()
# 임시 파일은 쓰다 실패해도 남지 않는다
t, c = newterm("echo $((6*7))XD")
def boomclean(x): raise RuntimeError("x")
try:
    tb.save_tail(t, sdx / "term-last-ee55.txt", clean=boomclean); check(False, "clean 이 실패했는데 통과")
except RuntimeError:
    pass
check(not list(sdx.glob(".tmp-term-last-*")) and not (sdx / "term-last-ee55.txt").exists(), "저장이 실패하면 임시 파일을 남기지 않는다")
tb.revoke(t)
check(not last.exists(), "term-last.txt 도 같이 지운다")
# 끝난 뒤 두 번째 명령이 도는 중이면 보류
t, c = newterm("echo $((6*7))XD")
tb.send(t, c, key="Enter"); wait_screen(t, c, "42XD"); wait_idle(t); n = time.time()
tb.watch(n); tb.watch(n + 2.5)
tb.send(t, c, text="sleep 30"); tb.send(t, c, key="Enter"); wait_busy(t)
tb.sweep(n + 2.5 + 1801)
check(rec(t)["tmux"] in ms._tmux("list-sessions", "-F", "#{session_name}").stdout.split(), "끝난 뒤에 돌고 있는 명령은 30분이 지나도 안 죽인다")
tb.send(t, c, key="C-c")
# 아직 끝 안 났으면 기존 규칙(마지막 활동 30분) 그대로
t, c = newterm("echo OLD"); tb.send(t, c, key="Tab"); setrec(t, lastActiveAt=time.time() - 1801)
tb.sweep(time.time()); check(not (d / f"{t}.json").exists(), "끝 전엔 기존 규칙(무활동 30분)")
# 한 번도 안 연 터미널이 attach 로 끝났으면 10분 미개봉 규칙 대신 끝 기준
t, _ = newterm("echo UNC", claim=False)
setrec(t, doneAt=time.time(), createdAt=time.time() - 700)
tb.sweep(time.time()); check((d / f"{t}.json").exists(), "끝난 미개봉 터미널은 10분 규칙이 아니라 끝 기준(30분)")

# ── 10. Loop.watch_term — 세션에 알림(내용 없는 고정 문구)
rec_s = ms.find_session("proj/feat/t"); ch, sd = str(rec_s["channelId"]), Path(rec_s["stateDir"])
calls = []
mb._spawn_type = lambda tmux, text, channel, mid, button="": calls.append((tmux, text, channel, mid))
def posts(): return [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{ch}/messages"]
DONE = "[마리나] 터미널에서 넘긴 명령이 끝났어 — 결과는 형이 넘겨 주거나 말해 줄 때까지 기다려."
SHARE_PRE, SHARE_POST = "[마리나] 형이 터미널 화면을 넘겼어: ", " — 읽고 이어서 해. 내용을 Discord 에 그대로 옮기지 마."
check(mb.TERM_DONE_TEXT == DONE and mb.typeable(DONE), "고정 문구는 typeable")
check(not mb.typeable(DONE + " 화면 끝 40줄: /a/b/term-last.txt") and not mb.typeable(DONE + " 아무거나") and not mb.typeable(DONE[:-1])
      and not mb.typeable("[마리나] 터미널에서 넘긴 명령이 끝났어 — 화면 끝 몇 줄을 보고 이어서 해."), "정확 일치만(옛 경로 정규식·옛 문구 없음)")
check(not hasattr(mb, "TERM_DONE_RE"), "경로 정규식은 지웠다")
ms._tmux("new-session", "-d", "-s", rec_s["tmux"], "-x", "100", "-y", "20")
t, c = newterm("echo ALIVE-$((1+1))", channel=ch)
tb.send(t, c, key="Enter"); wait_screen(t, c, "ALIVE-2"); wait_idle(t)
lp = mb.Loop(); n = time.time()
before = len(posts())
lp.watch_term(n); check(calls == [], "처음 본 유휴엔 알리지 않는다")
lp.watch_term(n + 1); check(calls == [], "5초 안엔 다시 안 본다(간격)")
lp.watch_term(n + 6)
check(calls == [(rec_s["tmux"], DONE, ch, "")], f"끝나면 세션 입력창에 내용 없는 고정 문구 한 번: {calls}")
check(not list(sd.glob("term-last*")), f"끝 감지 시점엔 term-last 파일을 만들지 않는다: {list(sd.glob('term-last*'))}")
check("ALIVE-2" not in calls[0][1], "화면 내용이 세션으로 가지 않는다")
check(len(posts()) == before, "켜진 세션엔 채널 한 줄을 안 올린다")
check(rec(t).get("notifiedAt"), "알렸다고 기록")
lp.watch_term(n + 12); lp.watch_term(n + 18); check(len(calls) == 1, "한 번만 알린다")
lp2 = mb.Loop(); lp2.watch_term(n + 30); check(len(calls) == 1, "데몬이 다시 떠도(새 Loop) 중복 알림이 없다")
tb.send(t, c, text="echo AGAIN"); tb.send(t, c, key="Enter"); wait_screen(t, c, "AGAIN\n"); wait_idle(t)
lp2.watch_term(n + 40); lp2.watch_term(n + 50); check(len(calls) == 1, "같은 터미널의 두 번째 명령은 다시 안 알린다")
# 알림이 못 나가면(예외) 기록을 남기지 않고 다음 틱에 다시
t2, c2 = newterm("echo RETRY-$((1+1))", channel=ch)
tb.send(t2, c2, key="Enter"); wait_screen(t2, c2, "RETRY-2"); wait_idle(t2)
def boom(*a, **k): raise OSError("x")
mb._spawn_type = boom
lp3 = mb.Loop(); n3 = time.time()
lp3.watch_term(n3); lp3.watch_term(n3 + 6); lp3.watch_term(n3 + 12)    # 한 터미널의 알림 실패가 루프를 죽이지 않는다
check(not rec(t2).get("notifiedAt"), "알림이 실패하면 알렸다고 적지 않는다")
mb._spawn_type = lambda tmux, text, channel, mid, button="": calls.append((tmux, text, channel, mid))
lp3.watch_term(n3 + 20); check(len(calls) == 2 and rec(t2).get("notifiedAt"), f"다음 틱에 다시 알린다: {len(calls)}")

# ── 10b. 사람이 넘길 때만 화면이 간다: POST /t/<토큰>/share
import socket
_s = socket.socket(); _s.bind(("127.0.0.1", 0)); _fp = _s.getsockname()[1]; _s.close()
lpv = mb.Loop(); lpv.view_server({"view": {"port": _fp}}, 100.0)
check(lpv.vsrv is not None and lpv.vsrv.on_share is mb.share_term_screen, "Loop 가 서버에 share 처리기를 건다")
srv = lpv.vsrv
def req(method, path, headers=None, body=None):
    cn = http.client.HTTPConnection("127.0.0.1", srv.port, timeout=10); cn.request(method, path, body=body, headers=headers or {})
    r = cn.getresponse(); data = r.read(); cn.close(); return r.status, data, r
t5, _ = newterm("echo KEEP=$((6*7)) token=abcd1234efgh5678 PW", channel=ch, claim=False)
st, _, r = req("GET", f"/t/{t5}/"); ck = (r.getheader("set-cookie") or "").split(";")[0]; ckv = ck.split("=", 1)[1]
H = {"Cookie": ck, "Host": f"127.0.0.1:{srv.port}", "Origin": f"http://127.0.0.1:{srv.port}", "Content-Length": "0"}
ncalls = len(calls)
check(req("POST", f"/t/{t5}/share", H)[0] == 409 and len(calls) == ncalls, "끝나기 전엔 넘길 수 없다(409)")
tb.send(t5, ckv, key="Enter"); wait_screen(t5, ckv, "KEEP=42"); wait_idle(t5); n = time.time()
tb.watch(n); tb.watch(n + 2.5)
check(req("POST", f"/t/{t5}/share", {k: v for k, v in H.items() if k != "Origin"})[0] == 403, "Origin 이 없으면 403")
check(req("POST", f"/t/{t5}/share", dict(H, Origin="https://evil.example"))[0] == 403, "Origin 이 다르면 403")
check(req("POST", f"/t/{t5}/share", {k: v for k, v in H.items() if k != "Cookie"})[0] == 403, "쿠키가 없으면 403")
check(req("POST", f"/t/{t5}/share", dict(H, Cookie="mterm=" + "z" * 30))[0] == 403, "주인이 아닌 쿠키는 403")
check(req("POST", f"/t/{'N' * 32}/share", H)[0] == 404, "없는 토큰 404")
check(req("GET", f"/t/{t5}/share")[0] in (404, 405), "GET 은 안 열린다")
check(len(calls) == ncalls and not list(sd.glob("term-last*")), "거절된 요청은 아무것도 안 넘긴다")
# 세션이 꺼져 있으면 안내만
ms._tmux("kill-session", "-t", "=" + rec_s["tmux"])
st, body, _ = req("POST", f"/t/{t5}/share", H); j = json.loads(body)
check(st == 200 and j.get("ok") is False and j.get("reason") == "asleep" and len(calls) == ncalls and not list(sd.glob("term-last*")), f"잠든 세션: {st} {j}")
# 켜진 세션이면 가린 끝 40줄 + 두 번째 고정 문구
ms._tmux("new-session", "-d", "-s", rec_s["tmux"], "-x", "100", "-y", "20")
st, body, _ = req("POST", f"/t/{t5}/share", H); j = json.loads(body)
tf = sd / f"term-last-{rec(t5)['tmux'][len('term-'):]}.txt"
check(st == 200 and j.get("ok") is True and tf.exists(), f"넘김: {st} {j} {list(sd.glob('term-last*'))}")
check(stat.S_IMODE(tf.stat().st_mode) == 0o600, f"0600: {oct(tf.stat().st_mode)}")
txt = tf.read_text()
check("KEEP=42" in txt and "abcd1234efgh5678" not in txt and "token=•••" in txt, f"비밀 가림(_clean 과 같은 규칙): {txt!r}")
check(len(txt.splitlines()) <= 40, "끝 40줄 이내")
check(len(calls) == ncalls + 1 and calls[-1][1] == f"{SHARE_PRE}{tf}{SHARE_POST}" and calls[-1][0] == rec_s["tmux"] and calls[-1][2] == ch, f"두 번째 고정 문구: {calls[-1:]}")
check(mb.typeable(calls[-1][1], ch), "생성한 문구는 typeable 이 받는다(채널 stateDir 아래 정확 경로)")
check(not mb.typeable(calls[-1][1]) , "채널을 모르면(type 에 channel 이 없으면) 경로 문구를 받지 않는다")
st, body, _ = req("POST", f"/t/{t5}/share", H); check(st == 200 and json.loads(body).get("ok") and len(calls) == ncalls + 2, "다시 누르면 다시 넘긴다(허용)")
# 같은 채널의 다른 터미널은 다른 파일
t6, _ = newterm("echo OTHER-TERM", channel=ch, claim=False)
st, _, r6 = req("GET", f"/t/{t6}/"); ck6 = (r6.getheader("set-cookie") or "").split(";")[0]; ck6v = ck6.split("=", 1)[1]
tb.send(t6, ck6v, key="Enter"); wait_screen(t6, ck6v, "OTHER-TERM\n"); wait_idle(t6); n = time.time(); tb.watch(n); tb.watch(n + 2.5)
H6 = dict(H, Cookie=ck6)
st, body, _ = req("POST", f"/t/{t6}/share", H6)
tf6 = sd / f"term-last-{rec(t6)['tmux'][len('term-'):]}.txt"
check(st == 200 and tf6.exists() and tf6 != tf and "KEEP=42" in tf.read_text() and "OTHER-TERM" in tf6.read_text(), "같은 채널의 터미널 둘이 서로 덮어쓰지 않는다")
# typeable 거절 목록
good = f"{SHARE_PRE}{tf}{SHARE_POST}"
bads = {"공백": good.replace("term-last-", "term last-"), "따옴표": f"{SHARE_PRE}'{tf}'{SHARE_POST}", "세미콜론": f"{SHARE_PRE}{tf};rm{SHARE_POST}",
        "백틱": f"{SHARE_PRE}`{tf}`{SHARE_POST}", "제어문자": f"{SHARE_PRE}{tf}\x1b{SHARE_POST}", "개행": f"{SHARE_PRE}{tf}\n{SHARE_POST}",
        "다른 폴더": f"{SHARE_PRE}/tmp/term-last-ab12.txt{SHARE_POST}", "상위 경로": f"{SHARE_PRE}{sd}/../x/term-last-ab12.txt{SHARE_POST}",
        "접미 다름": f"{SHARE_PRE}{tf}{SHARE_POST} 그리고 rm -rf", "접두 다름": "x" + good, "확장자": good.replace(".txt", ".sh"), "대문자 id": good.replace(tf.name, "term-last-AB12.txt")}
for k, v in bads.items():
    check(not mb.typeable(v, ch), f"typeable 거절: {k}")
check(not mb.typeable(good, "NOPE-CH"), "다른 채널이면 그 채널 stateDir 가 아니라서 거절")
# 허용 밖 문자가 든 stateDir 면 치지 않고 "못 넘겼어"
sd_bad = tmp / "sd with space"; sd_bad.mkdir()
orig = json.loads(json.dumps(ms.load_sessions()))
ms.save_sessions([dict(x, stateDir=str(sd_bad)) if str(x.get("channelId")) == ch else x for x in ms.load_sessions()])
nc = len(calls); st, body, _ = req("POST", f"/t/{t5}/share", H); j = json.loads(body)
check(st == 200 and j.get("ok") is False and j.get("reason") == "failed" and len(calls) == nc and not list(sd_bad.glob("term-last*")), f"허용 밖 문자 경로는 못 넘긴다: {j} {list(sd_bad.iterdir())}")
ms.save_sessions(orig)
# 터미널을 정리하면 그 파일도 같이 지운다
tb.revoke(t5); check(not tf.exists() and tf6.exists(), "터미널 정리 때 그 터미널의 term-last 파일을 같이 지운다")
tb.revoke(t6); check(not tf6.exists(), "두 번째도")
# 화면·JSON 쪽 정적 점검(페이지)
js = (Path(dscripts) / "marina-view" / "term.js").read_text(); html = (Path(dscripts) / "marina-view" / "term.html").read_text()
check('id="share"' in html and "화면 끝 40줄을 세션에 넘기기" in html and "hidden" in html.split('id="share"')[1].split(">")[0], "넘기기 버튼(끝나기 전엔 숨김)")
check('fetch("share"' in js and "넘겼어" in js and "넘기지 못했어" in js and "세션이 잠들어 있어 — Discord 에 글을 써서 깨운 뒤 다시 눌러" in js, "버튼 동작·안내 문구")
check("innerHTML" not in js, "넘기기도 textContent 로만")
srv.stop()

# ── 10c. 꺼진 방: 깨우지 않고 채널에 조용한 한 줄
ms._tmux("kill-session", "-t", "=" + rec_s["tmux"])
t3, c3 = newterm("echo OFFLINE-$((1+1))", channel=ch)
tb.send(t3, c3, key="Enter"); wait_screen(t3, c3, "OFFLINE-2"); wait_idle(t3)
n4 = time.time(); lp4 = mb.Loop(); before = len(posts()); ncalls = len(calls)
lp4.watch_term(n4); lp4.watch_term(n4 + 6)
new = posts()[before:]
check(len(calls) == ncalls, "꺼진 세션은 깨우지 않는다(입력 시도 없음)")
check(len(new) == 1 and new[0]["b"].get("content") == "🖥️ 터미널 명령이 끝났어" and new[0]["b"].get("flags") == 4096 and new[0]["b"].get("allowed_mentions") == {"parse": []}, f"채널에 조용한 한 줄: {new}")
check(not list(sd.glob("term-last*")), "꺼진 세션엔 파일을 안 쓴다")
check(rec(t3).get("notifiedAt"), "알렸다고 기록")
lp4.watch_term(n4 + 12); check(len(posts()) == before + 1, "한 줄도 한 번만")
# 채널 POST 가 429 아닌 4xx 로 실패하면 알린 것으로 닫는다(매 틱 재시도 금지)
(fd / "fail_post").write_text("403")
t7, c7 = newterm("echo FOURXX-$((1+1))", channel=ch)
tb.send(t7, c7, key="Enter"); wait_screen(t7, c7, "FOURXX-2"); wait_idle(t7)
n7 = time.time(); lp7 = mb.Loop(); lp7.watch_term(n7); lp7.watch_term(n7 + 6)
tries = len(posts())
check(rec(t7).get("notifiedAt"), "403 같은 4xx 는 알린 것으로 닫는다")
lp7.watch_term(n7 + 12); lp7.watch_term(n7 + 18); check(len(posts()) == tries, "닫은 뒤엔 다시 시도하지 않는다")
(fd / "fail_post").unlink()
# 연결 실패(일시 오류)는 닫지 않고 다시 시도
t8, c8 = newterm("echo NETFAIL-$((1+1))", channel=ch)
tb.send(t8, c8, key="Enter"); wait_screen(t8, c8, "NETFAIL-2"); wait_idle(t8)
api = os.environ["MARINA_DISCORD_API"]; os.environ["MARINA_DISCORD_API"] = "http://127.0.0.1:1"
n8 = time.time(); lp8 = mb.Loop(); lp8.watch_term(n8); lp8.watch_term(n8 + 6)
check(not rec(t8).get("notifiedAt"), "연결 실패는 알렸다고 안 적는다(다음 틱에 재시도)")
os.environ["MARINA_DISCORD_API"] = api
before = len(posts()); lp8.watch_term(n8 + 12)
check(rec(t8).get("notifiedAt") and len(posts()) == before + 1, "복구되면 알린다")
# 채널이 모르는 세션(지워진 방)이면 조용히 알린 것으로 끝
t4, c4 = newterm("echo GONE-$((1+1))", channel="NOPE")
tb.send(t4, c4, key="Enter"); wait_screen(t4, c4, "GONE-2"); wait_idle(t4)
n5 = time.time(); lp5 = mb.Loop(); before = len(posts()); lp5.watch_term(n5); lp5.watch_term(n5 + 6)
check(len(posts()) == before and rec(t4).get("notifiedAt"), "모르는 채널은 아무것도 안 보내고 닫는다")

for f in d.glob("*.json"):
    ms._tmux("kill-session", "-t", "=" + json.loads(f.read_text())["tmux"])
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("ok")
PY
echo "PASS test-discord-termdone"
