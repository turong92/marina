#!/usr/bin/env bash
# 터미널 넘기기(2026-10-05) — 세션이 "형이 실행해 줘" 를 Discord 링크 버튼으로 넘기는 runtime 쪽.
#  - marina_term_requests: create(개행·제어문자 거부)·claim(1회·15분·토큰 형식)
#  - CLI marina term-request: 열 주소 한 줄(원격 url 있으면 그것, 없으면 localhost:<포트>), 전역 입구에서도 라우팅
#  - 대시보드: GET /term-run(로그인 필요 페이지), GET /api/term-request(404 없음·만료·사용됨, 403 root 권한 밖)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
EP="$SCR/marina-entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# ── 1) 모듈 ──
PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json, os, stat, sys, time
from pathlib import Path
tmp = Path(sys.argv[1]); home = Path(os.environ["MARINA_HOME"])
reg = (tmp / "reg").resolve(); reg.mkdir()
(home / "projects.json").write_text(json.dumps({"projects": [
    {"id": "reg", "root": str(reg), "kind": "compose", "subrepos": [], "worktreeGlobs": []}]}))
import marina_term_requests as tr
fails = []
def check(c, m):
    if not c: fails.append(m)
def raises(fn, *a):
    try: fn(*a)
    except ValueError: return True
    return False

tok = tr.create(str(reg), "cloud prod db --admin", "prod DB 확인")
f = home / "term-requests" / f"{tok}.json"
check(f.is_file() and stat.S_IMODE(f.stat().st_mode) == 0o600, "0600 파일")
check(len(tok) >= 20, f"토큰 길이 {tok}")
got = tr.claim(tok)
check(got == {"root": str(reg), "command": "cloud prod db --admin", "why": "prod DB 확인", "ts": got and got["ts"]}, f"claim: {got}")
check(not f.exists(), "claim 뒤 파일 없음")
check(tr.claim(tok) is None, "두 번째 claim 은 None(한 번만)")

# 만료 15분
tok = tr.create(str(reg), "ls", "")
p = home / "term-requests" / f"{tok}.json"
d = json.loads(p.read_text()); d["ts"] = time.time() - 16 * 60; p.write_text(json.dumps(d))
check(tr.claim(tok) is None, "15분 지나면 None")
check(not p.exists(), "만료분은 지운다")
tok = tr.create(str(reg), "ls", "")
p = home / "term-requests" / f"{tok}.json"
d = json.loads(p.read_text()); d["ts"] = time.time() - 14 * 60; p.write_text(json.dumps(d))
check(tr.claim(tok) is not None, "14분이면 아직 유효")

# peek — 읽기만(소모 안 함), 만료·형식 오류는 None
tok = tr.create(str(reg), "ls", "p")
check(tr.peek(tok) and tr.peek(tok)["command"] == "ls", "peek 은 몇 번이든 읽힌다")
check(tr.claim(tok) is not None and tr.peek(tok) is None, "claim 뒤엔 peek 도 None")
check(tr.peek("../x") is None and tr.peek(None) is None, "peek 형식 검사")
tok = tr.create(str(reg), "ls", "")
p = home / "term-requests" / f"{tok}.json"
d = json.loads(p.read_text()); d["ts"] = time.time() - 16 * 60; p.write_text(json.dumps(d))
check(tr.peek(tok) is None, "만료분 peek 은 None")
# claim 도 command 를 다시 검증 — 파일을 직접 만들어 넣어도 위험한 명령은 안 나간다
for bad in ("a\nb", "a\u202eb", "x" * 1501):
    p = home / "term-requests" / ("B" * 24 + ".json")
    p.write_text(json.dumps({"root": str(reg), "command": bad, "why": "", "ts": time.time()}))
    check(tr.peek("B" * 24) is None and tr.claim("B" * 24) is None, f"claim 재검증 {bad[:6]!r}")
    p.unlink(missing_ok=True)
check(stat.S_IMODE((home / "term-requests").stat().st_mode) == 0o700, "디렉터리 0700")

# 토큰 형식 — 경로 탈출·빈 값·엉뚱한 값
for bad in ("", "../x", "a/b", "short", "x" * 200, None, "a b" * 10):
    check(tr.claim(bad) is None, f"잘못된 토큰 {bad!r}")
(home / "evil.json").write_text(json.dumps({"root": "/", "command": "x", "why": "", "ts": time.time()}))
check(tr.claim("../evil") is None and (home / "evil.json").exists(), "../ 로 다른 파일을 못 가져간다")

# 입력 검증 — 개행·제어문자는 거부(입력만 해 두는데 개행이면 실행돼 버린다)
for bad in ("", "a\nb", "a\rb", "a\x00b", "a\x1bb", "a\tb\n", "x" * 1501,
            "a\u202eb", "a\u2066b", "a\u2069b", "a\u200bb", "a\u200db", "a\ufeffb", "a\u0085b", "a\u009bb"):
    check(raises(tr.create, str(reg), bad, ""), f"command 거부 {bad[:12]!r}")
check(not raises(tr.create, str(reg), "x" * 1500, ""), "1500자는 허용")
check(not raises(tr.create, str(reg), "echo 한글 😀 é", ""), "한글·이모지는 허용")
check(raises(tr.create, str(tmp / "nowhere"), "ls", ""), "등록 안 된 root 는 거부")
check(raises(tr.create, "", "ls", ""), "root 비면 거부")
tok = tr.create(str(reg), "ls -la", "a\nb\x1b" + "y" * 500)
w = tr.claim(tok)["why"]
check("\n" not in w and "\x1b" not in w and len(w) <= 300, f"why 는 한 줄·300자 이하: {w!r}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("module ok")
PY

# ── 2) CLI ──
mkdir -p "$TMP/wt/sub" && git -C "$TMP/wt" init -q -b main
WT="$(cd "$TMP/wt" && pwd -P)"
printf '{"projects":[{"id":"wt","root":"%s","kind":"compose","subrepos":[],"worktreeGlobs":[]}]}\n' "$WT" > "$MARINA_HOME/projects.json"
cat > "$TMP/status-url" <<'SH'
#!/bin/sh
printf 'state=funnel\nurl=https://box.example.ts.net\ndashboardHost=localhost\ndashboardPort=3911\n'
SH
cat > "$TMP/status-none" <<'SH'
#!/bin/sh
printf 'state=off\nurl=\ndashboardHost=localhost\ndashboardPort=3911\n'
SH
chmod +x "$TMP/status-url" "$TMP/status-none"

out="$(cd "$WT/sub" && MARINA_TERM_REQUEST_REMOTE_STATUS="$TMP/status-url" bash "$EP" term-request --why 'prod 확인' 'cloud prod db --admin' 2>&1)" || fail "term-request(원격): $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "출력은 한 줄이어야: $out"
case "$out" in https://box.example.ts.net/term-run\?t=*) ;; *) fail "원격 url 기반 주소가 아님: $out" ;; esac
tok="${out##*t=}"
PYTHONPATH="$SCR" python3 - "$tok" "$WT" <<'PY' || fail "CLI 가 만든 요청 내용"
import sys, marina_term_requests as tr
d = tr.claim(sys.argv[1])
assert d and d["root"] == sys.argv[2] and d["command"] == "cloud prod db --admin" and d["why"] == "prod 확인", d
PY
out="$(cd "$WT" && MARINA_TERM_REQUEST_REMOTE_STATUS="$TMP/status-none" bash "$EP" term-request 'ls' 2>&1)" || fail "term-request(로컬): $out"
case "$out" in http://localhost:3911/term-run\?t=*) ;; *) fail "원격 없을 땐 localhost:<포트>: $out" ;; esac
if (cd "$WT" && bash "$EP" term-request $'a\nb' >/dev/null 2>&1); then fail "개행 명령은 실패해야"; fi
if (cd "$WT" && bash "$EP" term-request >/dev/null 2>&1); then fail "명령 없으면 실패해야"; fi
err="$(cd "$WT" && bash "$EP" term-request cloud prod db 2>&1 >/dev/null)" && fail "인자 여러 개면 실패해야"
echo "$err" | grep -q "따옴표" || fail "여러 인자 에러가 따옴표를 안내해야: $err"
if (cd "$WT" && bash "$EP" term-request 'ls' --why x >/dev/null 2>&1); then fail "--why 는 명령 앞에서만"; fi
out="$(cd "$WT" && MARINA_TERM_REQUEST_REMOTE_STATUS="$TMP/status-none" bash "$EP" term-request --why 'w' -- '--why x' 2>&1)" || fail "-- 뒤는 명령: $out"
PYTHONPATH="$SCR" python3 -c 'import sys, marina_term_requests as tr; d = tr.claim(sys.argv[1].split("t=")[1]); assert d and d["command"] == "--why x", d' "$out" || fail "-- 뒤 명령 내용"
if (cd "$TMP" && bash "$EP" term-request 'ls' >/dev/null 2>&1); then fail "등록 안 된 폴더에선 실패해야"; fi
bash "$EP" --help 2>&1 | grep -q "term-request" || fail "입구 usage 에 term-request 없음"

# ── 3) 대시보드 ──
PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import http.client, json, os, sys, threading, urllib.parse
from http.server import ThreadingHTTPServer
from pathlib import Path
tmp = Path(sys.argv[1]); home = Path(os.environ["MARINA_HOME"])
alpha, beta = tmp / "alpha", tmp / "beta"
alpha.mkdir(); beta.mkdir()
(home / "projects.json").write_text(json.dumps({"projects": [
    {"id": "alpha", "root": str(alpha), "kind": "compose", "subrepos": [], "worktreeGlobs": []},
    {"id": "beta", "root": str(beta), "kind": "compose", "subrepos": [], "worktreeGlobs": []}]}))
os.environ.update({"MARINA_AUTH_DB": str(home / "auth.db"), "MARINA_AUTH_PBKDF2_ITERATIONS": "1000",
                   "MARINA_CONTROL_HOST": "127.0.0.1"})
import marina_term_requests as tr
import marina_handler
marina_handler.safe_root = lambda text: Path(text).resolve()
server = ThreadingHTTPServer(("127.0.0.1", 0), marina_handler.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
fails = []
def check(c, m):
    if not c: fails.append(m)
def get(path, session=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    h = {"Host": f"127.0.0.1:{port}"}
    if session: h["Cookie"] = f"marina_session={session.token}; marina_csrf={session.csrf_token}"
    conn.request("GET", path, headers=h)
    r = conn.getresponse(); raw = r.read(); conn.close()
    ctype = r.getheader("content-type", "")
    return r.status, (json.loads(raw) if ctype.startswith("application/json") else raw.decode("utf-8", "replace")), r

# 인증 꺼진 상태(로컬 기본)
status, body, r = get("/term-run?t=whatever")
check(status == 200 and "term-run.js" in body, f"/term-run 페이지: {status}")
check(r.getheader("cache-control", "").startswith("no-store"), "no-store")
tok = tr.create(str(alpha), "echo hi", "인사")
status, body, _ = get(f"/api/term-request?t={tok}")
check(status == 200 and body == {"root": str(alpha), "command": "echo hi", "why": "인사"}, f"api: {status} {body}")
status, body, _ = get(f"/api/term-request?t={tok}")
check(status == 404 and "error" in body, f"두 번째는 404: {status} {body}")
status, body, _ = get("/api/term-request?t=nope")
check(status == 404, f"없는 토큰 404: {status}")
status, body, _ = get("/api/term-request")
check(status == 404, f"토큰 없음 404: {status}")

# 기존 터미널과 같은 가드 — 인증 꺼진 채 프록시(X-Forwarded-*) 경유는 거부(원격 코드 실행 입구)
tok = tr.create(str(alpha), "echo hi", "")
def get_h(path, headers):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    conn.request("GET", path, headers={"Host": f"127.0.0.1:{port}", **headers})
    r = conn.getresponse(); r.read(); conn.close(); return r.status
check(get_h(f"/api/term-request?t={tok}", {"X-Forwarded-For": "1.2.3.4"}) == 403, "x-forwarded-for 는 403")
check(get_h(f"/api/term-request?t={tok}", {"X-Forwarded-Host": "evil"}) == 403, "x-forwarded-host 는 403")
status, body, _ = get(f"/api/term-request?t={tok}")
check(status == 200, f"가드에 막힌 요청은 토큰을 안 쓴다: {status}")

# 인증 켠 상태 — 로그인 필요, root 접근권한
from marina_auth import AuthStore
store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
member = store.add_user("dev-one", "Dev One", actor_user_id=admin.id)
with store._transaction() as conn:
    conn.execute("update users set status='active' where id=?", (member.id,))
store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)
store.assign_resource_owner("worktree", str(alpha.resolve()), member.id, actor_user_id=admin.id)
admin_s, member_s = store.create_session(admin.id), store.create_session(member.id)

status, _, r = get("/term-run?t=x")
check(status == 302 and r.getheader("location", "").startswith("/login?next="), f"비로그인 페이지는 로그인 리다이렉트: {status} {r.getheader('location')}")
tok = tr.create(str(alpha), "echo hi", "")
status, body, _ = get(f"/api/term-request?t={tok}")
check(status == 401, f"비로그인 api 401: {status}")
status, body, _ = get(f"/api/term-request?t={tok}", member_s)
check(status == 200 and body["root"] == str(alpha), f"권한 있는 member 는 200: {status} {body}")
tok = tr.create(str(beta), "echo hi", "")
status, body, _ = get(f"/api/term-request?t={tok}", member_s)
check(status == 403, f"권한 밖 root 는 403: {status} {body}")
status, body, _ = get(f"/api/term-request?t={tok}", admin_s)
check(status == 200 and body["command"] == "echo hi", f"403 으로 막힌 토큰은 안 쓰였다(admin 이 이어 씀): {status}")
# root 가 더는 유효하지 않으면(safe_root 거부) 토큰을 소모하지 않는다
tok = tr.create(str(alpha), "echo hi", "")
good_safe_root = marina_handler.safe_root
def _bad(text): raise ValueError("unknown worktree root")
marina_handler.safe_root = _bad
status, body, _ = get(f"/api/term-request?t={tok}", admin_s)
check(status in (400, 404) and tr.peek(tok) is not None, f"safe_root 거부는 토큰 보존: {status}")
marina_handler.safe_root = good_safe_root
status, body, _ = get("/term-run?t=x", member_s)
check(status == 200, f"로그인하면 페이지 200: {status}")
# 인증 저장소가 죽어도 /term-run 은 로그인 리다이렉트(/ 와 같은 처리)
ctl = marina_handler.auth_controller()
def _boom(): raise RuntimeError("db down")
orig_enabled = ctl.store.auth_enabled
ctl.store.auth_enabled = _boom
status, _, r = get("/term-run?t=x")
check(status == 302 and r.getheader("location", "").startswith("/login"), f"저장소 예외도 리다이렉트: {status}")
ctl.store.auth_enabled = orig_enabled
server.shutdown()
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("http ok")
PY
# ── 4) 프론트 정적 점검 — 명령은 개행 없이 입력만, Enter 는 버튼이 따로 ──
WEB="$SCR/marina-web"
node --check "$WEB/term-run.js" || fail "term-run.js 문법"
grep -q 'term-run.js' "$WEB/term-run.html" && grep -q 'vendor-xterm.js' "$WEB/term-run.html" && grep -q 'app-0-auth.js' "$WEB/term-run.html" || fail "term-run.html 스크립트 로드"
grep -q 'send(req.command)' "$WEB/term-run.js" || fail "명령 입력 호출 없음"
if grep -nE "req\.command *\+|command *\+ *['\"]\\\\[rn]" "$WEB/term-run.js"; then fail "명령 뒤에 개행을 붙이면 안 된다"; fi
grep -q "send('\\\\r')" "$WEB/term-run.js" || fail "Enter 버튼이 \\r 을 보내지 않음"
grep -q 'sessionStorage' "$WEB/term-run.js" && grep -q '/api/term-list' "$WEB/term-run.js" || fail "새로고침 재접속(sessionStorage·term-list) 없음"
grep -qE "termrun[^\n]*token|token[^\n]*termrun" "$WEB/term-run.js" || fail "sessionStorage 키에 토큰이 없다"
grep -q 'term-open' "$WEB/term-run.js" && grep -qE "opened\.status|error" "$WEB/term-run.js" || fail "term-open 실패 이유 표시 없음"
echo "PASS test-term-request"
