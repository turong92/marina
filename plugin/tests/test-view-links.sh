#!/usr/bin/env bash
# 결과물 보기(2026-10-05) — 세션이 만든 HTML·md 를 폰에서 여는 runtime 쪽.
#  - marina_view_links: create(탈출·비밀 이름 거부·재사용)·resolve(7일 만료)·보기 주소 CLI
#  - 대시보드 GET /view/<token>/...: 로그인(비로그인 302/401)·root 권한 403·sandbox CSP·상대 자산(자산 티켓)·md 렌더 페이지
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
(reg / "docs").mkdir()
(reg / "docs" / "a.html").write_text("<h1>a</h1>")
(reg / "n.md").write_text("# n")
(reg / ".env").write_text("SECRET=1"); (reg / "k.key").write_text("x"); (reg / ".env.local").write_text("x")
(reg / ".git").mkdir(); (reg / ".git" / "config").write_text("x")
(reg / ".claude").mkdir(); (reg / ".claude" / "settings.json").write_text("{}")
(tmp / "outside.txt").write_text("out")
os.symlink(str(tmp / "outside.txt"), str(reg / "link.txt"))
(home / "projects.json").write_text(json.dumps({"projects": [
    {"id": "reg", "root": str(reg), "kind": "compose", "subrepos": [], "worktreeGlobs": []}]}))
import marina_view_links as vl
fails = []
def check(c, m):
    if not c: fails.append(m)
def raises(fn, *a):
    try: fn(*a)
    except ValueError: return True
    return False

tok = vl.create(str(reg), str(reg / "docs" / "a.html"))
f = home / "view-links" / f"{tok}.json"
check(f.is_file() and stat.S_IMODE(f.stat().st_mode) == 0o600, "0600 파일")
check(stat.S_IMODE((home / "view-links").stat().st_mode) == 0o700, "디렉터리 0700")
check(len(tok) >= 20, f"토큰 길이 {tok}")
check(vl.resolve(tok) == (str(reg), "docs/a.html"), f"resolve: {vl.resolve(tok)}")
check(vl.resolve(tok) == (str(reg), "docs/a.html"), "여러 번 쓸 수 있다")
check(vl.create(str(reg), "docs/a.html") == tok, "같은 (root, rel) 이면 토큰 재사용(상대 경로도 root 기준)")
check(vl.create(str(reg), str(reg / "n.md")) != tok, "다른 파일은 다른 토큰")

# 7일 만료
d = json.loads(f.read_text()); d["ts"] = time.time() - 8 * 86400; f.write_text(json.dumps(d))
check(vl.resolve(tok) is None, "7일 지나면 None")
tok2 = vl.create(str(reg), "docs/a.html")
check(tok2 != tok, "만료된 건 재사용하지 않는다")
d = json.loads((home / "view-links" / f"{tok2}.json").read_text()); d["ts"] = time.time() - 6 * 86400
(home / "view-links" / f"{tok2}.json").write_text(json.dumps(d))
check(vl.resolve(tok2) is not None, "6일이면 유효")
check(vl.create(str(reg), "docs/a.html") == tok2, "재사용하면 만료가 새로 시작")
d = json.loads((home / "view-links" / f"{tok2}.json").read_text())
check(time.time() - d["ts"] < 60, "재사용 시 ts 갱신")

# 토큰 형식·경로 탈출
for bad in ("", "../x", "a/b", "short", "x" * 200, None, "a b" * 10):
    check(vl.resolve(bad) is None, f"잘못된 토큰 {bad!r}")
(home / "evil.json").write_text(json.dumps({"root": str(reg), "rel": "n.md", "ts": time.time()}))
check(vl.resolve("../evil") is None, "../ 로 다른 파일을 못 읽는다")
# 파일을 직접 만들어 넣어도 비밀 이름·탈출 rel 은 resolve 가 거부
for rel in (".env", "../outside.txt", "docs/../../outside.txt", "/etc/hosts", ".git/config"):
    (home / "view-links" / ("C" * 24 + ".json")).write_text(json.dumps({"root": str(reg), "rel": rel, "ts": time.time()}))
    check(vl.resolve("C" * 24) is None, f"resolve 재검증 {rel}")

# create 거부
check(raises(vl.create, str(reg), str(tmp / "outside.txt")), "root 밖 파일")
check(raises(vl.create, str(reg), "../outside.txt"), "../ 탈출")
check(raises(vl.create, str(reg), "link.txt"), "root 밖을 가리키는 심볼릭 링크")
check(raises(vl.create, str(reg), "docs"), "폴더")
check(raises(vl.create, str(reg), "없는파일.html"), "없는 파일")
for name in (".env", ".env.local", "k.key", ".git/config", ".claude/settings.json"):
    check(raises(vl.create, str(reg), name), f"비밀·설정 이름 거부 {name}")
check(raises(vl.create, str(tmp / "nowhere"), "x"), "등록 안 된 root")
check(raises(vl.create, "", "n.md"), "root 비면 거부")

# 서빙용 판정
for n in (".git-credentials", ".ssh/id_rsa", "id_ed25519", "x/.aws/credentials", ".docker/config.json", ".kube/config", "a.tfstate",
          "terraform.tfstate.backup", "prod.tfvars", "credentials.json", "credentials-prod.json", "secrets.yml", "secrets.json",
          ".pypirc", ".dev.vars", "a.jks", "b.KEYSTORE", "deep/dir/.SSH/known_hosts"):
    check(vl.blocked_name(Path(n)), f"비밀 이름 거부 {n}")
check(not vl.blocked_name(Path("docs/credentials.md")) and not vl.blocked_name(Path("my-secrets-notes.html")), "과차단 없음")
check(vl.blocked_name(Path("a/.ENV")) and vl.blocked_name(Path("x/.Git/HEAD")) and vl.blocked_name(Path("CLAUDE.md"))
      and vl.blocked_name(Path("a/b.KEY")) and not vl.blocked_name(Path("docs/a.html")), "blocked_name")
(reg / "docs" / "style.css").write_text("b{}")
check(vl.locate(str(reg), "docs/a.html", "style.css") == (reg / "docs" / "style.css"), "토큰 파일 폴더 기준")
check(vl.locate(str(reg), "docs/a.html", "../n.md") == (reg / "n.md"), "root 안 ../ 는 허용")
for sub in ("../../outside.txt", "../.env", "link.txt", "%00x", "a\x00b", "../.git/config", "../.claude/settings.json"):
    check(vl.locate(str(reg), "docs/a.html", sub) is None, f"locate 거부 {sub!r}")
check(vl.locate(str(reg), "docs/a.html", "") == reg / "docs" / "a.html", "빈 sub = 토큰 파일")

check(vl.locate(str(reg), "docs/a.html", "../n.md", confine=True) is None, "confine: 토큰 폴더 밖(root 안) 거부")
check(vl.locate(str(reg), "docs/a.html", "style.css", confine=True) == reg / "docs" / "style.css", "confine: 폴더 안은 허용")
(reg / "docs" / "sub").mkdir(); (reg / "docs" / "sub" / "x.css").write_text("x")
check(vl.locate(str(reg), "docs/a.html", "sub/x.css", confine=True) == reg / "docs" / "sub" / "x.css", "confine: 하위 폴더 허용")
check(vl.locate(str(reg), "docs/a.html", "sub/../../n.md", confine=True) is None, "confine: 우회 .. 거부")
for ok in ("a.css", "a.JS", "a.mjs", "a.png", "a.jpg", "a.jpeg", "a.gif", "a.webp", "a.avif", "a.svg", "a.ico", "a.woff", "a.woff2", "a.ttf", "a.otf", "a.mp4", "a.webm", "a.mp3", "a.wav", "a.html", "a.htm"):
    check(vl.ticket_ext_ok(ok), f"티켓 허용 확장자 {ok}")
for no in ("a.json", "a.txt", "a.log", "a.csv", "a.map", "a.md", "a.yml", "a.pdf", "a.bin", "a", "a.py"):
    check(not vl.ticket_ext_ok(no), f"티켓 거부 확장자 {no}")
check(vl.redact_view_log('"GET /view/' + "A" * 24 + "/~/" + "B" * 16 + '/x.css HTTP/1.1" 200 -') == '"GET /view/…/~/…/x.css HTTP/1.1" 200 -', "로그 가리기(티켓)")
check(vl.redact_view_log('"GET /view/' + "A" * 24 + '/?raw=1 HTTP/1.1" 200 -') == '"GET /view/…/?raw=1 HTTP/1.1" 200 -', "로그 가리기(토큰)")
check(vl.redact_view_log('"GET /web/x.js HTTP/1.1"') == '"GET /web/x.js HTTP/1.1"', "다른 경로는 그대로")
# inject_base: <head> 안의 실제 <base> 만 건너뛴다
check(b"<base href=" in vl.inject_base(b"<html><head><title>x</title></head><body>&lt;base&gt; <p>text &lt;base href=1&gt;</p></body></html>", "/b/"), "본문 문자열에 base 가 있어도 주입")
check(b"<base href=" in vl.inject_base(b"<html><head><!-- <base href='/z/'> --></head><body></body></html>", "/b/"), "주석 안 base 는 무시")
check(vl.inject_base(b"<html><head><base href='/z/'></head><body></body></html>", "/b/").count(b"<base") == 1, "head 안 실제 base 는 건너뜀")
# 자산 티켓 — 메모리: 마지막 사용 후 5분 sliding, 최대 2시간, principal 묶기
t = vl.issue_ticket("T" * 24, str(reg), "docs", "PRINCIPAL")
check(vl.ticket_lookup(t) == ("T" * 24, str(reg), "docs", "PRINCIPAL"), "티켓 조회(principal 포함)")
check(vl.ticket_lookup(vl.issue_ticket("T" * 24, str(reg), "docs"))[3] is None, "인증 꺼짐이면 principal None")
vl._TICKETS[t][1] = time.time() - 4 * 60
check(vl.ticket_lookup(t) is not None and time.time() - vl._TICKETS[t][1] < 5, "사용하면 sliding 연장")
vl._TICKETS[t][1] = time.time() - 6 * 60
check(vl.ticket_lookup(t) is None, "마지막 사용 5분 뒤 만료")
t = vl.issue_ticket("T" * 24, str(reg), "docs")
vl._TICKETS[t][0] = time.time() - 2 * 3600 - 5
check(vl.ticket_lookup(t) is None, "발급 2시간 뒤 최대 만료(계속 써도)")
check(vl.ticket_lookup("nope") is None and vl.ticket_lookup(None) is None and vl.ticket_lookup("../x") is None, "티켓 형식")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("module ok")
PY

# ── 2) CLI ──
mkdir -p "$TMP/wt/sub" && git -C "$TMP/wt" init -q -b main
WT="$(cd "$TMP/wt" && pwd -P)"
printf '<h1>x</h1>' > "$WT/sub/p.html"
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
out="$(cd "$WT/sub" && MARINA_TERM_REQUEST_REMOTE_STATUS="$TMP/status-url" bash "$EP" view-link "$WT/sub/p.html" 2>&1)" || fail "view-link(원격): $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "출력은 한 줄이어야: $out"
case "$out" in https://box.example.ts.net/view/*/) ;; *) fail "원격 url 기반 주소가 아님: $out" ;; esac
tok="$(printf '%s' "$out" | sed -E 's#.*/view/([^/]+)/#\1#')"
PYTHONPATH="$SCR" python3 -c 'import sys, marina_view_links as v; assert v.resolve(sys.argv[1]) == (sys.argv[2], "sub/p.html"), v.resolve(sys.argv[1])' "$tok" "$WT" || fail "CLI 가 만든 토큰 내용"
out="$(cd "$WT/sub" && MARINA_TERM_REQUEST_REMOTE_STATUS="$TMP/status-none" bash "$EP" view-link p.html 2>&1)" || fail "view-link(로컬, 상대 경로는 cwd 기준): $out"
case "$out" in http://localhost:3911/view/*/) ;; *) fail "원격 없을 땐 localhost:<포트>: $out" ;; esac
if (cd "$WT" && bash "$EP" view-link >/dev/null 2>&1); then fail "경로 없으면 실패해야"; fi
if (cd "$WT" && bash "$EP" view-link /etc/hosts >/dev/null 2>&1); then fail "root 밖 파일은 실패해야"; fi
if (cd "$TMP" && bash "$EP" view-link "$WT/sub/p.html" >/dev/null 2>&1); then fail "등록 안 된 폴더에선 실패해야"; fi
bash "$EP" --help 2>&1 | grep -q "view-link" || fail "입구 usage 에 view-link 없음"
grep -qx 'marina_view_links' "$SCR/RUNTIME_MODULES" || fail "RUNTIME_MODULES 에 marina_view_links 없음"

# ── 3) 대시보드 ──
PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import http.client, json, os, re, sys, threading, urllib.parse
from http.server import ThreadingHTTPServer
from pathlib import Path
tmp = Path(sys.argv[1]); home = Path(os.environ["MARINA_HOME"])
alpha, beta = (tmp / "alpha").resolve(), (tmp / "beta").resolve()
for p in (alpha, beta): p.mkdir()
(alpha / "docs").mkdir()
(alpha / "docs" / "page.html").write_text("<!doctype html><html><head><title>t</title></head><body><link rel=stylesheet href=style.css><img src=img.png><a href='#x'>x</a></body></html>")
(alpha / "docs" / "style.css").write_text("body{color:red}")
(alpha / "docs" / "img.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
(alpha / "docs" / "note.md").write_text("# 제목\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```mermaid\ngraph TD; A-->B\n```\n\n</script><script>alert(1)</script> & <b>\n", encoding="utf-8")
(alpha / "docs" / "rep.pdf").write_bytes(b"%PDF-1.4 fake")
(alpha / "docs" / "data.bin").write_bytes(b"\x00\x01")
(alpha / "docs" / "pic.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>")
(alpha / ".env").write_text("SECRET=1")
(alpha / "top.css").write_text("top{}")
(alpha / "secret.txt").write_text("TOPSECRET")
(alpha / "docs" / "d.json").write_text("{}")
(alpha / "docs" / "n.txt").write_text("t")
(alpha / "big.html").write_bytes(b"x" * (20 * 1024 * 1024 + 1))
(beta / "b.html").write_text("<h1>beta</h1>")
(home / "projects.json").write_text(json.dumps({"projects": [
    {"id": "alpha", "root": str(alpha), "kind": "compose", "subrepos": [], "worktreeGlobs": []},
    {"id": "beta", "root": str(beta), "kind": "compose", "subrepos": [], "worktreeGlobs": []}]}))
os.environ.update({"MARINA_AUTH_DB": str(home / "auth.db"), "MARINA_AUTH_PBKDF2_ITERATIONS": "1000",
                   "MARINA_CONTROL_HOST": "127.0.0.1"})
import marina_view_links as vl
import marina_handler
marina_handler.safe_root = lambda text: Path(text).resolve()
server = ThreadingHTTPServer(("127.0.0.1", 0), marina_handler.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
fails = []
def check(c, m):
    if not c: fails.append(m)
def get(path, session=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    h = {"Host": f"127.0.0.1:{port}", **(headers or {})}
    if session: h["Cookie"] = f"marina_session={session.token}; marina_csrf={session.csrf_token}"
    conn.request("GET", path, headers=h)
    r = conn.getresponse(); raw = r.read(); conn.close()
    return r.status, raw, r
def txt(raw): return raw.decode("utf-8", "replace")

# ── 인증 꺼진 상태(로컬 기본)
t_html = vl.create(str(alpha), "docs/page.html")
status, body, r = get(f"/view/{t_html}/")
csp = r.getheader("content-security-policy", "")
check(status == 200 and r.getheader("content-type", "").startswith("text/html"), f"html 200: {status}")
check(csp == "sandbox allow-scripts allow-popups allow-forms; frame-ancestors 'none'", f"html CSP sandbox+frame-ancestors: {csp!r}")
check(r.getheader("x-content-type-options") == "nosniff" and r.getheader("cache-control", "").startswith("no-store"), "nosniff·no-store")
m = re.search(r'<base href="(/view/[^"]+/~/([A-Za-z0-9_-]+)/)"', txt(body))
check(m, f"상대 자산용 <base> 주입: {txt(body)[:300]}")
check(txt(body).index("<base") < txt(body).index("<link"), "base 가 자산 링크보다 앞")
base = m.group(1) if m else "/x/"
# 상대 자산 — 쿠키 없이도(샌드박스 문서는 SameSite 쿠키를 못 보낸다) 티켓으로 열린다
status, body, r = get(base + "style.css")
check(status == 200 and txt(body) == "body{color:red}" and r.getheader("content-type", "").startswith("text/css"), f"css: {status}")
check(r.getheader("access-control-allow-origin") is None, "Origin 없으면 CORS 헤더 없음")
_, _, r_null = get(base + "style.css", headers={"Origin": "null"})
check(r_null.getheader("access-control-allow-origin") == "null", "Origin: null(샌드박스 fetch)만 허용")
_, _, r_evil = get(base + "style.css", headers={"Origin": "https://evil.example"})
check(r_evil.getheader("access-control-allow-origin") is None, "다른 Origin 은 CORS 없음")
status, body, r = get(base + "img.png")
check(status == 200 and r.getheader("content-type") == "image/png" and body.startswith(b"\x89PNG"), f"img: {status}")
check(r.getheader("content-security-policy") == "frame-ancestors 'none'", "png: sandbox 없이 frame-ancestors 만")
status, _, r = get(f"/view/{t_html}/rep.pdf")
check(status == 200 and r.getheader("content-type") == "application/pdf" and "attachment" not in (r.getheader("content-disposition") or "") and "sandbox" not in (r.getheader("content-security-policy") or ""), "pdf 는 토큰 경로로 인라인(sandbox CSP 면 크롬이 못 연다)")
status, _, r = get(f"/view/{t_html}/data.bin")
check(status == 200 and r.getheader("content-type") == "application/octet-stream" and "attachment" in (r.getheader("content-disposition") or ""), "모르는 확장자는 attachment")
status, _, r = get(base + "pic.svg")
check(status == 200 and r.getheader("content-type", "").startswith("image/svg+xml") and (r.getheader("content-security-policy") or "").startswith("sandbox"), "svg 는 sandbox")
# C1 ② 티켓 경로는 확장자 allowlist 만
for name in ("rep.pdf", "data.bin", "d.json", "n.txt", "note.md"):
    check(get(base + name)[0] == 404, f"티켓 경로 확장자 거부 {name}")
    check(get(f"/view/{t_html}/{name}")[0] == 200, f"같은 파일도 토큰(로그인) 경로는 열림 {name}")
# C1 ① 토큰 파일 폴더 밖(root 안)은 티켓으로 못 읽는다
for name in ("../top.css", "../secret.txt", "%2e%2e/top.css", "sub/../../top.css"):
    check(get(base + name)[0] == 404, f"티켓 경로 폴더 탈출 거부 {name}")
check(get(f"/view/{t_html}/../top.css")[0] == 200, "토큰 경로는 root 안 ../ 허용(로그인)")
# C1 ④ 주소창 이동(Sec-Fetch-Dest: document)은 쿠키 경로로 돌려보낸다
status, _, r = get(base + "style.css", headers={"Sec-Fetch-Dest": "document"})
check(status == 302 and r.getheader("location") == f"/view/{t_html}/style.css", f"document 이동은 302: {status} {r.getheader('location')}")
check(get(base + "style.css", headers={"Sec-Fetch-Dest": "style"})[0] == 200, "subresource 는 그대로")
# 티켓 경로도 토큰 만료·삭제를 다시 본다
(alpha / "docs" / "page2.html").write_text((alpha / "docs" / "page.html").read_text()); t_tmp = vl.create(str(alpha), "docs/page2.html")
_, bb, _ = get(f"/view/{t_tmp}/")
mt = re.search(r'<base href="(/view/[^"]+/~/[A-Za-z0-9_-]+/)"', txt(bb)).group(1)
check(get(mt + "style.css")[0] == 200, "삭제 전 200")
(home / "view-links" / f"{t_tmp}.json").unlink()
check(get(mt + "style.css")[0] == 404, "토큰이 사라지면 티켓 경로도 404")
# I1 로그에 토큰·티켓이 안 남는다
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    marina_handler.Handler.log_message(None, '"%s" %s -', f"GET {base}style.css HTTP/1.1", "200")
    marina_handler.Handler.log_message(None, '"%s" %s -', f"GET /view/{t_html}/ HTTP/1.1", "200")
check(m.group(2) not in buf.getvalue() and t_html not in buf.getvalue() and "/view/…/~/…/style.css" in buf.getvalue(), f"로그 가림: {buf.getvalue()}")
for bad in ("../../.env", "../.env", "nope.css", "%2e%2e/%2e%2e/outside", ""):
    status, _, _ = get(base + bad)
    check(status in (403, 404), f"티켓 경로 거부 {bad!r}: {status}")
check(get(base.replace(m.group(2), "A" * 16) + "style.css")[0] in (401, 404), "모르는 티켓")
for hdr in ({"X-Forwarded-For": "1.2.3.4"}, {"X-Forwarded-Host": "evil"}):     # I3
    check(get(base + "style.css", headers=hdr)[0] == 403, f"인증 꺼진 채 프록시 경유는 티켓 경로도 403 {hdr}")
# 토큰 경로로도 같은 폴더 기준 상대 경로(로그인 필요)
status, body, _ = get(f"/view/{t_html}/style.css")
check(status == 200 and txt(body) == "body{color:red}", f"토큰 경로 상대 자산: {status}")
status, _, _ = get(f"/view/{t_html}/../.env"); check(status in (403, 404), f".env: {status}")
status, _, _ = get(f"/view/{t_html}/%2e%2e/.env"); check(status in (403, 404), f"%2e .env: {status}")
status, _, _ = get(f"/view/{t_html}/%2e%2e/%2e%2e/outside"); check(status in (403, 404), f"탈출: {status}")
status, _, _ = get(f"/view/nope-token-nope-token-xx/"); check(status == 404, f"없는 토큰 404: {status}")
status, _, _ = get(f"/view/x/"); check(status == 404, f"형식 오류 404: {status}")
tb = vl.create(str(alpha), "big.html")
status, _, _ = get(f"/view/{tb}/"); check(status == 413, f"20MB 초과 413: {status}")
# 기존 터미널과 같은 가드 — 인증 꺼진 채 프록시(X-Forwarded-*) 경유는 거부
for hdr in ({"X-Forwarded-For": "1.2.3.4"}, {"X-Forwarded-Host": "evil"}):
    check(get(f"/view/{t_html}/", headers=hdr)[0] == 403, f"프록시 경유 403 {hdr}")

# md 렌더 페이지
t_md = vl.create(str(alpha), "docs/note.md")
status, body, r = get(f"/view/{t_md}/")
page = txt(body)
check(status == 200 and r.getheader("content-type", "").startswith("text/html"), f"md 페이지: {status}")
csp = r.getheader("content-security-policy", "")
check(csp.startswith("sandbox allow-scripts") and "default-src 'none'" in csp and "frame-ancestors 'none'" in csp, f"md CSP: {csp!r}")
sp = [d for d in csp.split(";") if "script-src" in d][0]
check("https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js" in sp and "mermaid/10.9.1/mermaid.min.js" in sp and "dompurify/3.1.6/purify.min.js" in sp
      and "https://cdnjs.cloudflare.com " not in sp + " " and "'self'" in sp and "'unsafe-inline'" not in sp, f"script-src 는 정확한 파일 URL: {sp!r}")
ip = [d for d in csp.split(";") if "img-src" in d][0]
check("https:" not in ip and "'self'" in ip and "data:" in ip, f"img-src 원격 이미지 막음: {ip!r}")
check("</script><script>alert(1)" not in page, "원문의 </script> 가 그대로 박히면 안 된다")
mm = re.search(r'<script type="application/json" id="md-data">(.*?)</script>', page, re.S)
check(mm and json.loads(mm.group(1))["text"] == (alpha / "docs" / "note.md").read_text(encoding="utf-8"), "원문 JSON 이 그대로 복원된다")
check("marked" in page and "purify" in page.lower() and "md-view.js" in page, "marked·DOMPurify·md-view.js 로드")
check(re.search(r'integrity="sha384-[A-Za-z0-9+/=]{64}"', page), "SRI")
check("cdnjs.cloudflare.com/ajax/libs/marked/12.0.2" in page and "dompurify/3.1.6" in page, "고정 버전")
check("<base href=" in page and "~/" in page, "md 상대 이미지용 base")
status, body, r = get(f"/view/{t_md}/?raw=1")
check(status == 200 and r.getheader("content-type", "").startswith("text/plain") and txt(body) == (alpha / "docs" / "note.md").read_text(encoding="utf-8"), f"raw=1 원문: {status}")
check(get(f"/view/{t_md}/note.md")[0] == 200 and "md-data" in txt(get(f"/view/{t_md}/note.md")[1]), "상대 경로로 연 md 도 렌더")
check(get(f"/view/{t_html}/../.env?raw=1")[0] in (403, 404), "raw 로도 비밀 못 읽음")

# ── 인증 켠 상태 — 로그인 필요, root 접근권한
from marina_auth import AuthStore
store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
member = store.add_user("dev-one", "Dev One", actor_user_id=admin.id)
with store._transaction() as conn:
    conn.execute("update users set status='active' where id=?", (member.id,))
store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)
store.assign_resource_owner("worktree", str(alpha), member.id, actor_user_id=admin.id)
admin_s, member_s = store.create_session(admin.id), store.create_session(member.id)

status, _, r = get(f"/view/{t_html}/")
check(status == 302 and r.getheader("location", "").startswith("/login?next=%2Fview%2F"), f"비로그인 302 로그인: {status} {r.getheader('location')}")
status, body, r = get(f"/view/{t_html}/style.css")
check(status == 302, f"비로그인 상대 경로도 로그인 리다이렉트: {status}")
status, body, _ = get(f"/view/{t_html}/", member_s)
check(status == 200 and "<base" in txt(body), f"권한 있는 member 200: {status}")
m2 = re.search(r'<base href="(/view/[^"]+/~/[A-Za-z0-9_-]+/)"', txt(body)); base2 = m2.group(1)
status, body, _ = get(base2 + "style.css")        # 쿠키 없이
check(status == 200 and txt(body) == "body{color:red}", f"인증 켜도 티켓은 쿠키 없이: {status}")
check(get(base2.rsplit("/~/", 1)[0] + "/~/" + "A" * 16 + "/style.css")[0] in (401, 404), "모르는 티켓은 막힌다")
# C1 ③ 티켓은 발급 때 principal 에 묶인다 — 접근권한이 회수되면 티켓도 죽는다
store.set_project_access(member.id, [], actor_user_id=admin.id)
check(get(base2 + "style.css")[0] == 403, "권한 회수 뒤 티켓 403")
store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)
check(get(base2 + "style.css")[0] == 200, "권한 복구하면 다시 200")
tbeta = vl.create(str(beta), "b.html")
status, _, _ = get(f"/view/{tbeta}/", member_s); check(status == 403, f"권한 밖 root 403: {status}")
status, body, _ = get(f"/view/{tbeta}/", admin_s); check(status == 200 and "beta" in txt(body), f"admin 은 200: {status}")
# root 가 더는 유효하지 않으면(safe_root 거부) 404
good = marina_handler.safe_root
def _bad(text): raise ValueError("unknown worktree root")
marina_handler.safe_root = _bad
status, _, _ = get(f"/view/{t_html}/", admin_s); check(status == 404, f"safe_root 거부 404: {status}")
marina_handler.safe_root = good
# 인증 저장소가 죽어도 /view 는 로그인 리다이렉트
ctl = marina_handler.auth_controller()
def _boom(): raise RuntimeError("db down")
orig = ctl.store.auth_enabled
ctl.store.auth_enabled = _boom
status, _, r = get(f"/view/{t_html}/")
check(status == 302 and r.getheader("location", "").startswith("/login"), f"저장소 예외도 리다이렉트: {status}")
ctl.store.auth_enabled = orig
server.shutdown()
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("http ok")
PY

# ── 4) 프론트 정적 점검 ──
WEB="$SCR/marina-web"
node --check "$WEB/md-view.js" || fail "md-view.js 문법"
grep -q 'DOMPurify' "$WEB/md-view.js" && grep -q 'marked' "$WEB/md-view.js" || fail "md-view.js 가 marked·DOMPurify 를 안 쓴다"
grep -q "securityLevel *: *'strict'\|securityLevel *: *\"strict\"" "$WEB/md-view.js" || fail "mermaid securityLevel strict 아님"
grep -q 'md-data' "$WEB/md-view.js" || fail "md-view.js 가 md-data 를 안 읽는다"
PYTHONPATH="$SCR" python3 - "$WEB" <<'PY' || fail "CSP 의 CDN URL 과 md-view 의 로드 URL 불일치"
import sys; from pathlib import Path
import marina_view_links as vl
web = Path(sys.argv[1]); blob = (web / "md-view.html").read_text() + (web / "md-view.js").read_text()
missing = [u for u in vl.CDN_SCRIPTS if u not in blob]
assert not missing, missing
PY
echo "PASS test-view-links"
