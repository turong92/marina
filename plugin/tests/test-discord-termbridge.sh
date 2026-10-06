#!/usr/bin/env bash
# 터미널 넘기기를 Discord 플러그인 혼자(2026-10-06) — 설계 1절: docs/superpowers/specs/2026-10-06-terminal-in-discord-and-heavy-queue-design.md
#  - marina_termbridge: create(tmux 세션에 명령을 쳐 두기만)·claim(첫 브라우저에 묶기·10분 만료)·screen·send(허용 키·제어 문자 정리)·sweep
#  - marina_view.ViewServer: GET /t/<토큰>/ · screen · POST keys — 쿠키·Origin·크기·보안 헤더·로그 가림
#  - Loop.sweep_term: 데몬이 1분에 한 번 정리
# 전용 tmux 소켓(MARINA_TMUX_SOCKET)·임시 MARINA_HOME·127.0.0.1 임시 포트만 쓴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
# 테스트 tmux 서버가 쓸 셸 — 사용자 rc·프롬프트가 섞이지 않게. 로그인 셸이 실제 홈에 기록(~/.bash_history 등)을 남기지 않도록
# tmux 서버가 뜨기 전에 HOME 을 임시로 돌리고 HISTFILE 을 끈다.
export SHELL=/bin/sh HOME="$TMPROOT/home" HISTFILE=/dev/null
mkdir -p "$HOME"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import http.client, json, os, stat, sys, time
from pathlib import Path
import marina_termbridge as tb, marina_view as mv, marina_session as ms, marina_discord_bot as mb
tmp = Path(sys.argv[1]); home = Path(os.environ["MARINA_HOME"])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def wait_screen(token, cookie, needle, secs=5.0):
    end = time.time() + secs; s = ""
    while time.time() < end:
        s = tb.screen(token, cookie) or ""
        if needle in s: return s
        time.sleep(0.1)
    return s
def tb_cookie(token, c="k" * 20):
    tb.claim(token, c); return c
def last_line(token, cookie):
    lines = [l for l in (tb.screen(token, cookie) or "").splitlines() if l.strip()]
    return lines[-1] if lines else ""
def wait_end(token, cookie, suffix, secs=4.0):
    end = time.time() + secs
    while time.time() < end:
        if last_line(token, cookie).rstrip().endswith(suffix): return True
        time.sleep(0.1)
    return False
def sessions():
    r = ms._tmux("list-sessions", "-F", "#{session_name}")
    return r.stdout.split() if r.returncode == 0 else []
def rec(token):
    return json.loads((home / "discord-term" / f"{token}.json").read_text())
def setrec(token, **kw):
    p = home / "discord-term" / f"{token}.json"; d = json.loads(p.read_text()); d.update(kw); p.write_text(json.dumps(d))

work = tmp / "wt"; work.mkdir()

# ── create: tmux 세션·기록·명령은 쳐 두기만
tok = tb.create(str(work), "echo MARK-$((6*7))", "확인용", "C1")
d = home / "discord-term"
check(len(tok) >= 30, f"토큰 길이: {tok}")
check(stat.S_IMODE(d.stat().st_mode) == 0o700 and stat.S_IMODE((d / f"{tok}.json").stat().st_mode) == 0o600, "폴더 0700·파일 0600")
r = rec(tok)
check(r["root"] == os.path.realpath(work) and r["command"] == "echo MARK-$((6*7))" and r["why"] == "확인용" and r["channel"] == "C1"
      and r["claimedBy"] is None and isinstance(r["createdAt"], (int, float)) and r["tmux"].startswith("term-"), f"기록: {r}")
check(r["tmux"] in sessions(), f"tmux 세션이 떠 있다: {sessions()}")
check(tok not in r["tmux"], "tmux 세션 이름에 토큰이 없다")
cookie = "cookie-A-" + "x" * 20
check(tb.claim(tok, cookie) is True, "첫 브라우저가 claim")
s = wait_screen(tok, cookie, "MARK-$((6*7))")
check("MARK-$((6*7))" in s, f"명령이 입력창에 쳐져 있다: {s!r}")
check("MARK-42" not in s, f"실행은 안 됐다: {s!r}")
pwd = tb.screen(tok, cookie)
# Enter 를 보내면 실행
check(tb.send(tok, cookie, key="Enter") is True, "Enter 허용")
s = wait_screen(tok, cookie, "MARK-42")
check("MARK-42" in s, f"Enter 뒤 실행 결과: {s!r}")

# ── claim 규칙
check(tb.claim(tok, cookie) is True, "같은 cookie 는 다시 열어도 True(새로고침)")
check(tb.claim(tok, "cookie-B-" + "y" * 20) is False, "다른 cookie 는 묶인 뒤 False")
check(tb.claim("bad", cookie) is False and tb.claim("N" * 32, cookie) is False and tb.claim(tok, "") is False, "형식 오류·없는 토큰·빈 cookie")
check(tb.screen(tok, "cookie-B-" + "y" * 20) is None, "다른 cookie 는 화면을 못 본다")
check(tb.send(tok, "cookie-B-" + "y" * 20, key="Enter") is False, "다른 cookie 는 키를 못 보낸다")
check("cookie-A" not in (d / f"{tok}.json").read_text(), "cookie 원문은 기록에 안 남긴다(해시)")

# ── send: 글자·허용 키·제어 문자
check(tb.send(tok, cookie, text="echo hi$((1+2))") is True, "text 전송")
check("hi3" not in (tb.screen(tok, cookie) or "").replace("echo hi$((1+2))", ""), "text 만으론 실행 안 됨")
tb.send(tok, cookie, key="Enter")
check("hi3" in wait_screen(tok, cookie, "hi3"), "Enter 로 실행")
for k in ("Enter", "C-c", "C-d", "Tab", "Escape", "Up", "Down", "Left", "Right", "BSpace"):
    # C-d 는 셸을 끝낼 수 있어 마지막에 따로
    if k == "C-d": continue
    check(tb.send(tok, cookie, key=k) is True, f"허용 키 {k}")
for k in ("Enter; kill-server", "C-z", "F1", "", "enter", "x", None):
    if k is None: continue
    check(tb.send(tok, cookie, key=k) is False, f"허용 목록 밖 key 거절: {k!r}")
check(tb.send(tok, cookie) is False and tb.send(tok, cookie, text=None, key=None) is False, "text·key 둘 다 없으면 False")
check(tb.send(tok, cookie, text="x" * 2001) is False, "2000자 초과 text 거절")
tb.send(tok, cookie, key="C-c")
check(tb.send(tok, cookie, text="echo A\x03B\x1b[31mC\nD\tE") is True, "제어 문자가 든 text 는 정리해서 보낸다")
s = wait_screen(tok, cookie, "echo AB[31mCDE")
check("echo AB[31mCDE" in s, f"제어 문자(Ctrl-C·ESC·개행·탭)는 빠지고 글자만: {s!r}")
tb.send(tok, cookie, key="C-c")
check(tb.send(tok, cookie, text="--help -x") is True, "-로 시작하는 text 도 글자 그대로")
check("--help -x" in wait_screen(tok, cookie, "--help -x"), "-로 시작해도 tmux 옵션으로 안 먹는다")
tb.send(tok, cookie, key="C-c")
check(tb.send(tok, cookie, text="\x03\x1b\n") is False, "정리하고 나면 빈 text 는 False")

# ── 끝이 ; 인 입력(tmux 는 마지막 인자가 ; 로 끝나면 명령 구분자로 먹는다)
for cmd in ("echo a;", r"find . -maxdepth 0 -exec echo {} \;", "echo a;;", "a; b"):
    tc = tb.create(str(work), cmd, "", "C1"); ccook = tb_cookie(tc)
    check(wait_end(tc, ccook, cmd[-6:]) , f"create: 끝 세미콜론이 그대로: {cmd!r} → {last_line(tc, ccook)!r}")
    ms._tmux("kill-session", "-t", "=" + rec(tc)["tmux"])
ts = tb.create(str(work), "echo semi", "", "C1"); scook = tb_cookie(ts)
check(tb.send(ts, scook, text=";") is True and wait_end(ts, scook, "echo semi;"), f"send: ; 한 글자: {last_line(ts, scook)!r}")
for txt in ("echo b;", r"x\;", ";;"):
    tb.send(ts, scook, key="C-c"); tb.send(ts, scook, text=txt)
    check(wait_end(ts, scook, txt), f"send: 끝 세미콜론 보존 {txt!r}: {last_line(ts, scook)!r}")
ms._tmux("kill-session", "-t", "=" + rec(ts)["tmux"])

# ── create 실패는 고아 세션을 안 남긴다(입력 실패·기록 쓰기 실패)
_real = tb._tmux
def failing(*a):
    if a and a[0] == "send-keys":
        class R: returncode, stdout, stderr = 1, "", "boom"
        return R()
    return _real(*a)
before = set(sessions()); nrec = len(list(d.glob("*.json")))
tb._tmux = failing
try:
    tb.create(str(work), "ls", "", "C1"); check(False, "send-keys 실패인데 통과")
except ValueError:
    pass
finally:
    tb._tmux = _real
check(set(sessions()) == before and len(list(d.glob("*.json"))) == nrec, "입력이 실패하면 세션·기록을 남기지 않는다")
_real_write = tb._write
def bad_write(*a, **k): raise OSError("disk full")
tb._write = bad_write
try:
    tb.create(str(work), "ls", "", "C1"); check(False, "기록 쓰기 실패인데 통과")
except OSError:
    pass
finally:
    tb._write = _real_write
check(set(sessions()) == before, "기록 쓰기가 실패해도 세션이 안 남는다")

# ── create 검증
for bad in ("a\nb", "a\rb", "a‮b", "a\x1bb", "", "   ", "x" * 1001, "가" * 334):
    before = sessions()
    try:
        tb.create(str(work), bad, "w", "C1"); check(False, f"잘못된 명령 통과: {bad!r}")
    except ValueError:
        pass
    check(sessions() == before, f"거절된 명령은 세션을 안 만든다: {bad!r}")
t_long = tb.create(str(work), "echo " + "a" * 970 + "TAILMARK", "", "C1"); check(bool(t_long), "1000바이트 이하는 통과")
check("TAILMARK" in wait_screen(t_long, tb_cookie(t_long), "TAILMARK"), "긴 명령도 끝까지 들어가 있다(조용히 잘리지 않는다)")
t_ko = tb.create(str(work), "echo " + "가" * 330 + "끝", "", "C1")
check("끝" in wait_screen(t_ko, tb_cookie(t_ko), "끝"), "UTF-8 로캘이 없는 환경에서도 한글 명령이 입력된다(바이트 한도 안)")
try:
    tb.create(str(tmp / "no-such-dir"), "ls", "", "C1"); check(False, "없는 폴더 통과")
except ValueError:
    pass

# ── 만료: 10분 미개봉
t2 = tb.create(str(work), "ls", "", "C1"); name2 = rec(t2)["tmux"]
check(name2 in sessions(), "t2 세션 있음")
setrec(t2, createdAt=time.time() - 601)
check(tb.claim(t2, "c" * 20) is False, "10분 지나도록 안 열면 만료")
check(name2 not in sessions() and not (d / f"{t2}.json").exists(), "만료되면 tmux 세션·기록 정리")
t3 = tb.create(str(work), "ls", "", "C1")
setrec(t3, createdAt=time.time() - 599)
check(tb.claim(t3, "c" * 20) is True, "9분 59초는 아직")

# ── sweep
now = time.time()
t_un = tb.create(str(work), "ls", "", "C1"); n_un = rec(t_un)["tmux"]; setrec(t_un, createdAt=now - 601)
t_idle = tb.create(str(work), "ls", "", "C1"); n_idle = rec(t_idle)["tmux"]; tb.claim(t_idle, "i" * 20); setrec(t_idle, lastActiveAt=now - 1801)
t_act = tb.create(str(work), "ls", "", "C1"); n_act = rec(t_act)["tmux"]; tb.claim(t_act, "a" * 20); tb.send(t_act, "a" * 20, key="Tab")
t_gone = tb.create(str(work), "ls", "", "C1"); ms._tmux("kill-session", "-t", rec(t_gone)["tmux"])
tb.sweep(now)
live = sessions()
check(n_un not in live and not (d / f"{t_un}.json").exists(), "10분 넘게 미개봉이면 세션을 죽이고 기록을 지운다")
check(n_idle not in live and not (d / f"{t_idle}.json").exists(), "마지막 활동 30분 뒤 세션을 죽이고 기록을 지운다")
check(n_act in live and (d / f"{t_act}.json").exists(), "활동 중인 건 그대로")
check(not (d / f"{t_gone}.json").exists(), "tmux 세션이 이미 없으면 기록도 지운다")
check(tok in [p.stem for p in d.glob("*.json")], "다른 기록은 건드리지 않는다")
tb.sweep(now + 1801 + 5)
check(n_act not in sessions() and not (d / f"{t_act}.json").exists(), "활동 뒤 30분이 지나면 그것도")

# ── 실행 중인 명령은 무활동 30분이 지나도 안 죽인다 — 단 절대 상한(12시간)은 넘으면 정리
now = time.time()
t_run = tb.create(str(work), "sleep 120", "", "C1"); rcook = tb_cookie(t_run); n_run = rec(t_run)["tmux"]
tb.send(t_run, rcook, key="Enter")
end = time.time() + 5
while time.time() < end and ms._tmux("display-message", "-p", "-t", "=" + n_run + ":", "#{pane_current_command}").stdout.strip() != "sleep": time.sleep(0.1)
setrec(t_run, lastActiveAt=now - 3600)
tb.sweep(now)
check(n_run in sessions() and (d / f"{t_run}.json").exists(), "실행 중(셸이 아닌 명령)이면 무활동 30분이어도 건너뛴다")
setrec(t_run, createdAt=now - 12 * 3600 - 5)
tb.sweep(now)
check(n_run not in sessions() and not (d / f"{t_run}.json").exists(), "절대 상한 12시간을 넘으면 실행 중이어도 정리")
# 요청 시점 수명 검사 — sweep 이 안 돌아도 12시간 넘은 것은 못 쓴다
t_old = tb.create(str(work), "ls", "", "C1"); ocook = tb_cookie(t_old)
check(tb.authorize(t_old, ocook) is True and tb.screen(t_old, ocook) is not None, "살아 있을 땐 쓸 수 있다")
setrec(t_old, createdAt=time.time() - 12 * 3600 - 5)
check(tb.authorize(t_old, ocook) is None and tb.screen(t_old, ocook) is None and tb.send(t_old, ocook, key="Tab") is False and tb.meta(t_old, ocook) is None
      and tb.claim(t_old, ocook) is False, "절대 상한을 넘은 건 sweep 전에도 못 쓴다")
tb.sweep(); check(not (d / f"{t_old}.json").exists(), "sweep 이 정리")
# 채널 단위로 끊기(세션 삭제 때)
tc1 = tb.create(str(work), "ls", "", "CH-DEL"); tc2 = tb.create(str(work), "ls", "", "CH-DEL"); tc3 = tb.create(str(work), "ls", "", "CH-KEEP")
n1 = rec(tc1)["tmux"]
check(tb.revoke_channel("CH-DEL") == 2 and not (d / f"{tc1}.json").exists() and not (d / f"{tc2}.json").exists() and n1 not in sessions(), "revoke_channel 은 그 채널 것만 세션째 끊는다")
check((d / f"{tc3}.json").exists() and rec(tc3)["tmux"] in sessions(), "다른 채널 것은 그대로")
check(tb.revoke_channel("") == 0, "빈 채널은 아무것도 안 지운다")
tb.revoke(tc3)
check(not (d / f"{tc3}.json").exists(), "revoke(token)")

# ── Loop.sweep_term: 1분에 한 번
t_l = tb.create(str(work), "ls", "", "C1"); setrec(t_l, createdAt=time.time() - 700)
lp = mb.Loop(); lp.sweep_term(time.time())
check(not (d / f"{t_l}.json").exists(), "Loop.sweep_term 이 정리한다")
t_l2 = tb.create(str(work), "ls", "", "C1"); setrec(t_l2, createdAt=time.time() - 700)
lp.sweep_term(time.time() + 10)
check((d / f"{t_l2}.json").exists(), "1분 안엔 다시 안 돈다")
lp.sweep_term(time.time() + 61)
check(not (d / f"{t_l2}.json").exists(), "1분 뒤엔 돈다")

# ── HTTP: /t/<토큰>/
tH = tb.create(str(work), "echo WEB-$((6*7))", "웹 확인 <b>why</b>", "C1")
srv = mv.ViewServer(0)
check(srv.start(), "서버 시작")
def req(path, method="GET", headers=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", srv.port, timeout=10)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse(); data = r.read(); c.close()
    return r.status, data, r
st, page, r = req(f"/t/{tH}/")
sc = r.getheader("set-cookie") or ""
check(st == 200 and b"term.js" in page, f"페이지: {st}")
check(sc.startswith("mterm=") and "HttpOnly" in sc and f"Path=/t/{tH}/" in sc and "Secure" not in sc, f"쿠키 속성(http): {sc}")
check("SameSite=Lax" in sc and "SameSite=Strict" not in sc, f"SameSite=Lax(Discord 링크 클릭=최상위 이동에 쿠키가 실려야 한다): {sc}")
check(r.getheader("content-security-policy") == "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'", f"CSP: {r.getheader('content-security-policy')}")
check(r.getheader("cache-control") == "no-store" and r.getheader("x-content-type-options") == "nosniff" and r.getheader("referrer-policy") == "no-referrer", "보안 헤더")
check(b"WEB-" not in page and "웹 확인".encode() not in page, "명령·이유는 HTML 에 안 끼운다(XSS)")
ck = sc.split(";")[0]          # mterm=<값>
st, js, r = req(f"/t/{tH}/term.js"); check(st == 200 and r.getheader("content-type").startswith("application/javascript") and b"screen" in js, f"term.js: {st}")
st, body, r = req(f"/t/{tH}/screen", headers={"Cookie": ck})
j = json.loads(body) if st == 200 else {}
check(st == 200 and r.getheader("cache-control") == "no-store" and j.get("alive") is True and j.get("command") == "echo WEB-$((6*7))" and j.get("why") == "웹 확인 <b>why</b>", f"screen JSON: {st} {body[:200]}")
check("screen" in j, "screen 필드")
st, _, _ = req(f"/t/{tH}/screen"); check(st == 403, f"쿠키 없으면 403: {st}")
st, _, _ = req(f"/t/{tH}/screen", headers={"Cookie": "mterm=" + "z" * 30}); check(st == 403, f"다른 쿠키 403: {st}")
st, body, r = req(f"/t/{tH}/"); check(st == 410 and "이미 열렸거나 만료된 링크".encode() in body and not r.getheader("set-cookie"), f"쿠키 없는 두 번째 브라우저 410: {st}")
st, _, _ = req(f"/t/{tH}/", headers={"Cookie": "mterm=" + "z" * 30}); check(st == 410, f"다른 쿠키 410: {st}")
st, _, _ = req(f"/t/{tH}/", headers={"Cookie": ck}); check(st == 200, f"같은 쿠키는 새로고침 200: {st}")
st, _, r = req(f"/t/{tH}"); check(st == 301 and r.getheader("location") == f"/t/{tH}/", f"슬래시 없으면 301: {st}")
check(req(f"/t/{'N' * 32}/screen", headers={"Cookie": ck})[0] == 404 and req("/t/x/screen")[0] == 404, "없는 토큰·형식 오류 404")
# POST keys
H = {"Cookie": ck, "Content-Type": "application/json", "Host": f"127.0.0.1:{srv.port}", "Origin": f"http://127.0.0.1:{srv.port}"}
st, _, _ = req(f"/t/{tH}/keys", "POST", H, json.dumps({"key": "Enter"})); check(st == 204, f"key Enter 204: {st}")
s = wait_screen(tH, ck.split("=", 1)[1], "WEB-42"); check("WEB-42" in s, f"HTTP 로 보낸 Enter 가 실행됨: {s!r}")
st, _, _ = req(f"/t/{tH}/keys", "POST", H, json.dumps({"text": "echo T$((2+3))"})); check(st == 204, f"text 204: {st}")
check(req(f"/t/{tH}/keys", "POST", H, json.dumps({"key": "C-z"}))[0] == 400, "허용 밖 key 400")
check(req(f"/t/{tH}/keys", "POST", H, "not json")[0] == 400, "JSON 아님 400")
check(req(f"/t/{tH}/keys", "POST", H, json.dumps({"key": "Enter", "text": "x"}))[0] in (204, 400), "둘 다 와도 죽지 않는다")
check(req(f"/t/{tH}/keys", "POST", dict(H, **{"Origin": "https://evil.example"}), json.dumps({"key": "Enter"}))[0] == 403, "Origin 불일치 403")
check(req(f"/t/{tH}/keys", "POST", dict(H, **{"Origin": f"http://127.0.0.1:{srv.port}"}), json.dumps({"key": "Tab"}))[0] == 204, "Origin 이 자기 호스트면 통과")
check(req(f"/t/{tH}/keys", "POST", H, json.dumps({"text": "x" * 9000}))[0] == 413, "본문 한도 초과 413")
check(req(f"/t/{tH}/keys", "POST", H, json.dumps({"text": "가" * 2000}, ensure_ascii=False).encode("utf-8"))[0] == 204, "글자 한도 2000자가 한글로도 본문 한도에 들어간다")
check(req(f"/t/{tH}/keys", "POST", {k: v for k, v in H.items() if k != "Origin"}, json.dumps({"key": "Tab"}))[0] == 403, "Origin 헤더가 없으면 403(CSRF 방어선)")
for badkey in ('["Enter"]', '5', '{"a":1}', 'null'):
    check(req(f"/t/{tH}/keys", "POST", H, '{"key": %s}' % badkey)[0] == 400, f"문자열 아닌 key 는 400(500 아님): {badkey}")
check(req(f"/t/{tH}/keys", "POST", H, '{"text": 5}')[0] == 400 and req(f"/t/{tH}/keys", "POST", H, "[1]")[0] == 400, "text 가 문자열이 아니거나 본문이 객체가 아니면 400")
check(req(f"/t/{tH}/keys", "POST", {k: v for k, v in H.items() if k != "Cookie"}, json.dumps({"key": "Tab"}))[0] == 403, "쿠키 없으면 403")
check(req(f"/t/{'N' * 32}/keys", "POST", H, json.dumps({"key": "Tab"}))[0] == 404, "없는 토큰 POST 404")
check(req(f"/t/{tH}/keys")[0] in (404, 405), "GET /keys 는 안 열린다")
# 세션이 죽으면 alive false
ms._tmux("kill-session", "-t", rec(tH)["tmux"])
st, body, _ = req(f"/t/{tH}/screen", headers={"Cookie": ck}); check(st == 200 and json.loads(body).get("alive") is False, f"세션이 없으면 alive false: {st} {body[:100]}")
# 기존 /v/ 는 그대로 + 로그 가림
check(req("/v/" + "N" * 32 + "/")[0] == 404, "기존 /v/ 동작")
check(mv.redact_log('"GET /t/' + "A" * 32 + '/screen HTTP/1.1" 200 -') == '"GET /t/…/screen HTTP/1.1" 200 -', "로그에서 /t/ 토큰을 가림")
check(mv.redact_log('"GET /v/' + "A" * 32 + '/s.css HTTP/1.1" 200 -') == '"GET /v/…/s.css HTTP/1.1" 200 -', "/v/ 가림은 그대로")
srv.stop()
# https 공개 주소면 Secure
srvs = mv.ViewServer(0, public_base="https://box.example.ts.net:10000"); srvs.start()
tS = tb.create(str(work), "ls", "", "C1")
c = http.client.HTTPConnection("127.0.0.1", srvs.port, timeout=10); c.request("GET", f"/t/{tS}/"); r = c.getresponse(); r.read(); c.close()
check("Secure" in (r.getheader("set-cookie") or ""), f"https 공개 주소면 Secure: {r.getheader('set-cookie')}")
srvs.stop()
# Loop 가 publicBase 를 서버에 넘긴다
import socket
_s = socket.socket(); _s.bind(("127.0.0.1", 0)); _fp = _s.getsockname()[1]; _s.close()
lp2 = mb.Loop(); lp2.view_server({"view": {"port": _fp, "publicBase": "https://b.example"}}, 100.0)
check(lp2.vsrv is not None and lp2.vsrv.public_base == "https://b.example", "Loop.view_server → public_base")
lp2.stop_view()

# ── 로그에 토큰이 안 남는다: 핸들러 접근 로그 + termbridge 자체 로그
import io, contextlib
buf = io.StringIO()
srv3 = mv.ViewServer(0); srv3.start()
with contextlib.redirect_stderr(buf):
    c = http.client.HTTPConnection("127.0.0.1", srv3.port, timeout=10); c.request("GET", f"/t/{tS}/screen"); c.getresponse().read(); c.close()
    tb.claim("bad-token", "c"); tb.send(tS, "nope", key="Enter"); tb.sweep(time.time())
srv3.stop()
check(tS not in buf.getvalue() and "/t/…" in buf.getvalue(), f"접근 로그에 토큰 없음: {buf.getvalue()[:200]!r}")

# ── 경계
src = (Path(os.environ["DSCRIPTS"]) / "marina_termbridge.py").read_text()
import ast
mods = [a.name for n in ast.walk(ast.parse(src)) if isinstance(n, ast.Import) for a in n.names] + \
       [n.module for n in ast.walk(ast.parse(src)) if isinstance(n, ast.ImportFrom) and n.module]
check(all(not m.startswith("marina_") or m in ("marina_session",) for m in mods), f"runtime 모듈 import 금지: {mods}")
check("marina_termbridge" in (Path(os.environ["DSCRIPTS"]) / "DISCORD_MODULES").read_text().split(), "DISCORD_MODULES 에 등록")

for t in (tok, t_long, t_ko, t3, tS, tH):
    p = d / f"{t}.json"
    if p.exists():
        ms._tmux("kill-session", "-t", json.loads(p.read_text())["tmux"])
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("ok")
PY
echo "PASS test-discord-termbridge"
