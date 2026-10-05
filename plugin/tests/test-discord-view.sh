#!/usr/bin/env bash
# 결과물 보기 v2(2026-10-05) — Discord 플러그인이 혼자 여는 보기 서버. 설계: docs/superpowers/specs/2026-10-05-discord-file-view-design.md
#  - marina_view: create/resolve/revoke(만료 없음·파일 사라지면 None)·폴더 한정 locate·비밀 이름·allowlist
#  - ViewServer: 토큰 경로 서빙·CSP·md 원문 이스케이프·413·로그 가림·포트 충돌·stop
#  - Loop.view_server: discord.json 의 view 가 있을 때만 데몬 안에서 띄우고, 포트가 바뀌면 다시, 충돌은 죽지 않고 재시도
#  - marina-session view-setup(가짜 tailscale)·view-revoke
#  - 경계: runtime 쪽에 v1 흔적이 없다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# 가짜 tailscale — 호출 인자를 남긴다(진짜 tailscale 은 절대 부르지 않는다)
cat > "$TMPROOT/bin/fake-tailscale" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPROOT/tailscale-calls"
[ "\$1" = --socket ] && shift 2
case "\$1" in
  status) printf '{"Self":{"DNSName":"mac.tail1.ts.net."}}\n' ;;
  funnel) if [ "\$2" = status ]; then cat "$TMPROOT/funnel-status" 2>/dev/null || echo '{}'; fi; exit 0 ;;
esac
SH
chmod +x "$TMPROOT/bin/fake-tailscale"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import http.client, json, os, socket, stat, sys, time
from pathlib import Path
import marina_session as ms, marina_view as mv, marina_discord_bot as mb
tmp = Path(sys.argv[1]); home = Path(os.environ["MARINA_HOME"])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

root = tmp / "wt"; (root / "out" / "sub").mkdir(parents=True); (root / "out" / "sub" / ".git").mkdir()
outside = tmp / "outside"; outside.mkdir(); (outside / "x.css").write_text("secret")
(root / "top.css").write_text("top{}")
(root / "out" / "r.html").write_text("<link rel=stylesheet href=style.css><h1>h</h1><img src=sub/deep.png>")
(root / "out" / "style.css").write_text("h1{}")
(root / "out" / "sub" / "deep.png").write_bytes(b"\x89PNG\r\n\x1a\nx")
(root / "out" / "sub" / ".git" / "a.png").write_bytes(b"x")
(root / "out" / ".env").write_text("K=1"); (root / "out" / "secrets.css").write_text("x"); (root / "out" / "id_rsa.png").write_text("x")
(root / "out" / "data.bin").write_bytes(b"x"); (root / "out" / "data.json").write_text("{}")
os.symlink(outside / "x.css", root / "out" / "link.css")
(root / "out" / "notes.md").write_text("# 제목 <b>\n\n본문 `x` | </script><img src=x onerror=alert(1)> & \u2028 끝\n", encoding="utf-8")
with open(root / "out" / "big.png", "wb") as f: f.truncate(20 * 1024 * 1024 + 1)
(root / "note.txt").write_text("t")

# ── create / resolve / revoke
tok = mv.create(str(root), str(root / "out" / "r.html"), "C1")
check(len(tok) >= 30, f"토큰 길이: {tok}")
d = home / "discord-view"
check(stat.S_IMODE(d.stat().st_mode) == 0o700 and stat.S_IMODE((d / f"{tok}.json").stat().st_mode) == 0o600, "디렉터리 0700·파일 0600")
rec = json.loads((d / f"{tok}.json").read_text())
check(rec["root"] == os.path.realpath(root) and rec["rel"] == "out/r.html" and rec["channel"] == "C1" and "ts" in rec, f"기록: {rec}")
check(mv.create(str(root), "out/r.html", "C2") == tok, "같은 (root, rel) 은 같은 토큰")
check(mv.resolve(tok) == (os.path.realpath(root), "out/r.html"), f"resolve: {mv.resolve(tok)}")
old = json.loads((d / f"{tok}.json").read_text()); old["ts"] = time.time() - 400 * 86400
(d / f"{tok}.json").write_text(json.dumps(old))
check(mv.resolve(tok) is not None, "만료 없음 — 1년 넘은 기록도 열린다")
for bad in ("../outside/x.css", str(outside / "x.css"), "out", "out/nope.html", "out/.env", "out/secrets.css", "out/sub/.git/a.png"):
    try:
        mv.create(str(root), bad); check(False, f"create 가 통과: {bad}")
    except ValueError:
        pass
try:
    mv.create(str(root), "out/link.css"); check(False, "root 밖을 가리키는 심볼릭이 통과")
except ValueError:
    pass
check(mv.resolve("x") is None and mv.resolve("A" * 30) is None and mv.resolve(None) is None, "형식 오류·없는 토큰 None")
(d / ("C" * 32 + ".json")).write_text(json.dumps({"root": str(root), "rel": "../outside/x.css", "ts": 1}))
check(mv.resolve("C" * 32) is None, "손으로 넣은 탈출 경로는 None")
(d / ("D" * 32 + ".json")).write_text(json.dumps({"root": str(root), "rel": "out/.env", "ts": 1}))
check(mv.resolve("D" * 32) is None, "손으로 넣은 비밀 이름은 None")
tgone = mv.create(str(root), "note.txt")
(root / "note.txt").unlink()
check(mv.resolve(tgone) is None and (d / f"{tgone}.json").exists(), "파일이 사라지면 None 이지만 기록은 남는다(일시적 rm→쓰기)")
(root / "note.txt").write_text("t")
check(mv.resolve(tgone) is not None, "다시 생기면 같은 링크가 산다")
T0 = 1_000_000.0
mv.sweep(T0); check("missing_since" not in json.loads((d / f"{tgone}.json").read_text()), "있는 파일은 missing_since 없음")
(root / "note.txt").unlink(); mv.sweep(T0)
check(json.loads((d / f"{tgone}.json").read_text()).get("missing_since") == T0, "없으면 missing_since 기록")
mv.sweep(T0 + 3 * 86400); check((d / f"{tgone}.json").exists(), "7일 안엔 안 지운다")
(root / "note.txt").write_text("t"); mv.sweep(T0 + 4 * 86400)
check("missing_since" not in json.loads((d / f"{tgone}.json").read_text()), "돌아오면 missing_since 를 지운다")
(root / "note.txt").unlink(); mv.sweep(T0 + 5 * 86400); mv.sweep(T0 + 5 * 86400 + 7 * 86400 + 1)
check(not (d / f"{tgone}.json").exists(), "7일 넘게 계속 없으면 지운다")
(root / "note.txt").write_text("t")
t1 = mv.create(str(root), "note.txt"); t2 = mv.create(str(root), "out/notes.md")
check(mv.revoke(t1) == 1 and mv.resolve(t1) is None, "토큰으로 끊기")
check(mv.revoke(str(root / "out" / "notes.md")) == 1 and mv.resolve(t2) is None, "경로로 끊기")
t3 = mv.create(str(root), "note.txt"); t4 = mv.create(str(root), "out/notes.md")
check(mv.revoke(all_in=str(root)) >= 3 and mv.resolve(t3) is None and mv.resolve(t4) is None and mv.resolve(tok) is None, "폴더 전체 끊기")
check(mv.revoke("nope") == 0, "없는 대상은 0")
ca = mv.create(str(root), "note.txt", "CHAN-A"); cb = mv.create(str(root), "out/notes.md", "CHAN-B")
check(mv.revoke(channel="CHAN-A") == 1 and mv.resolve(ca) is None and mv.resolve(cb) is not None, "채널로 끊기(그 방 기록만)")
check(mv.revoke(channel="") == 0, "빈 채널은 아무것도 안 끊는다")
tok = mv.create(str(root), "out/r.html"); tmd = mv.create(str(root), "out/notes.md"); tbig = mv.create(str(root), "out/big.png")

# ── redact
check(mv.redact_log('"GET /v/' + "A" * 32 + '/s.css HTTP/1.1" 200 -') == '"GET /v/…/s.css HTTP/1.1" 200 -', "로그 가림")
check(mv.redact_log('"GET /v/' + "A" * 70 + '/s.css HTTP/1.1" 200 -') == '"GET /v/…/s.css HTTP/1.1" 200 -', "M1: 64자 넘는 토큰도 통째로 가림")
check(mv.redact_log("GET /v-md/md-view.js") == "GET /v-md/md-view.js", "정적 경로는 그대로")

# ── 서버
srv = mv.ViewServer(0)
check(srv.start() and srv.port > 0 and srv.start(), "start(두 번째는 이미 떠 있음)")
def get(path, headers=None, method="GET"):
    c = http.client.HTTPConnection("127.0.0.1", srv.port, timeout=10)
    c.request(method, path, headers=headers or {})
    r = c.getresponse(); body = r.read(); c.close()
    return r.status, body, r
check(mv._Handler.timeout == 30, "M3: 느린 연결 타임아웃")
SB = "sandbox allow-scripts allow-popups allow-forms; frame-ancestors 'none'"
st, body, r = get(f"/v/{tok}/")
check(st == 200 and r.getheader("content-type").startswith("text/html") and body.startswith(b"<link"), f"html: {st}")
check(r.getheader("content-security-policy") == SB, f"html CSP: {r.getheader('content-security-policy')}")
check(r.getheader("x-content-type-options") == "nosniff" and r.getheader("referrer-policy") == "no-referrer" and r.getheader("cache-control") == "no-store", "보안 헤더")
st, body, r = get(f"/v/{tok}/style.css"); check(st == 200 and body == b"h1{}" and r.getheader("content-type").startswith("text/css"), f"css: {st}")
check(r.getheader("access-control-allow-origin") is None, "Origin 없으면 CORS 없음")
st, _, r = get(f"/v/{tok}/style.css", {"Origin": "null"}); check(r.getheader("access-control-allow-origin") == "null", "샌드박스 문서(Origin: null)의 폰트·모듈용 CORS")
st, _, r = get(f"/v/{tok}/style.css", {"Origin": "https://evil.example"}); check(r.getheader("access-control-allow-origin") is None, "다른 사이트엔 CORS 없음")
check(get(f"/v/{tok}/sub/deep.png")[0] == 200, "하위 폴더 자산")
for p in ("../top.css", "%2e%2e/top.css", "%2e%2e/%2e%2e/outside/x.css", "sub/../../top.css", ".env", "secrets.css", "id_rsa.png", "sub/.git/a.png", "link.css", "data.bin", "data.json", "nope.css", "sub", "%00.css"):
    check(get(f"/v/{tok}/{p}")[0] in (403, 404), f"막혀야 함: {p} → {get(f'/v/{tok}/{p}')[0]}")
check(get(f"/v/{'N' * 32}/")[0] == 404 and get("/v/x/")[0] == 404 and get("/")[0] == 404 and get("/other")[0] == 404, "없는 토큰·형식 오류·다른 경로 404")
st, _, r = get(f"/v/{tok}"); check(st == 301 and r.getheader("location") == f"/v/{tok}/", f"슬래시 없으면 301: {st}")
check(get(f"/v/{tbig}/")[0] == 413, "20MB 초과 413")
check(get(f"/v/{tok}/", method="POST")[0] in (405, 501), "GET 만")
# md
MDCSP = ("sandbox allow-scripts allow-popups; default-src 'none'; script-src 'self' " + " ".join(mv.CDN_SCRIPTS)
         + "; style-src 'unsafe-inline'; img-src 'self' data:; font-src data:; base-uri 'self'; frame-ancestors 'none'")
st, body, r = get(f"/v/{tmd}/"); page = body.decode()
check(st == 200 and r.getheader("content-security-policy") == MDCSP, f"md CSP: {r.getheader('content-security-policy')}")
check('id="md-data"' in page and "integrity=" in page and "/v-md/md-view.js" in page, "md 페이지 골격·SRI")
check("</script><img" not in page and "\\u003c/script\\u003e" in page and "\\u2028" in page and "\\u0026" in page, "원문 이스케이프(<>&·U+2028)")
check("<title>제목 &lt;b&gt;</title>" in page, "제목 이스케이프")
for u in mv.CDN_SCRIPTS: check(u in page or "mermaid" in u, f"CDN 로드 URL 이 CSP 와 같다: {u}")
st, body, r = get("/v-md/md-view.js"); check(st == 200 and b"DOMPurify" in body and r.getheader("content-type").startswith("application/javascript"), "md-view.js 정적")
check(get("/v-md/other.js")[0] == 404, "정적은 md-view.js 만")
st, body, r = get(f"/v/{tmd}/?raw=1"); check(st == 200 and r.getheader("content-type").startswith("text/plain") and b"</script><img" in body, "raw=1 은 원문")
(root / "top.md").write_text("# top 비밀")
for p in ("../top.md", "%2e%2e/top.md", "..%2ftop.md", "sub/../../top.md"):
    check(get(f"/v/{tmd}/{p}")[0] in (403, 404) and get(f"/v/{tmd}/{p}?raw=1")[0] in (403, 404), f"md 도 폴더 밖 md 는 안 열림: {p}")
tup = mv.create(str(root), "top.md"); check(b"top" in get(f"/v/{tup}/?raw=1")[1], "(대조) 자기 토큰이면 열린다")
st, _, _ = get(f"/v/{tok}/../.env?raw=1"); check(st in (403, 404), "raw 로도 비밀 못 읽음")
# 파일이 사라지면 404, 돌아오면 같은 링크가 다시 열린다(I3)
(root / "out" / "r.html").rename(root / "out" / "r2.html")
check(get(f"/v/{tok}/")[0] == 404 and mv.resolve(tok) is None and (d / f"{tok}.json").exists(), "원본이 사라지면 404(기록은 남김)")
(root / "out" / "r2.html").rename(root / "out" / "r.html")
check(get(f"/v/{tok}/")[0] == 200 and mv.create(str(root), "out/r.html") == tok, "돌아오면 같은 토큰으로 열린다")

# ── I2: .markdown
(root / "out" / "d.markdown").write_text("# 마크다운\n")
tmk = mv.create(str(root), "out/d.markdown")
st, body, r = get(f"/v/{tmk}/"); check(st == 200 and r.getheader("content-security-policy") == MDCSP and 'id="md-data"' in body.decode(), f".markdown 은 md 렌더: {st}")
st, body, r = get(f"/v/{tmk}/?raw=1"); check(st == 200 and r.getheader("content-type").startswith("text/plain"), ".markdown raw")

# ── I1: 링크가 가리키는 파일이 실제 참조하는 자산만 열린다
site = root / "site"
for dd in ("css", "img", "js", "fonts", "other"): (site / dd).mkdir(parents=True)
for n in ("img/p.png", "img/p2.png", "img/p3.png", "img/poster.jpg", "img/bg.png", "img/c.png", "img/d.png", "img/e.png", "img/new.png", "img/unref.png", "img/ms.png", "fonts/f.woff2", "other/x.png"):
    (site / n).write_bytes(b"\x89PNG\r\n\x1a\nx")
(site / "js" / "x.js").write_text("1"); (site / "page2.html").write_text("<p>2</p>"); (site / ".env.png").write_bytes(b"x")
(site / "README.md").write_text("# 레포 README"); (site / "other.html").write_text("<p>other</p>"); (site / "css" / "unref.css").write_text("x")
(root / "outside.png").write_bytes(b"x")
(site / "css" / "a.css").write_text('@import "b.css"; body{background:url(../img/c.png)} /* comment */')
(site / "css" / "b.css").write_text('@import url("deep.css"); i{background:url("../img/d.png")}')
(site / "css" / "deep.css").write_text("i{background:url(../img/e.png)}")
INDEX = """<!doctype html><link href="css/a.css" rel=stylesheet><link rel=icon href="img/p.png?v=2#x">
<img src="img/p.png" srcset="img/p2.png 2x, img/p3.png 3x"><script src="js/x.js"></script><video poster="img/poster.jpg"></video>
<a href="page2.html">p</a><a href="#top">t</a><div style="background:url('img/bg.png')"></div>
<style>@font-face{src:url(fonts/f.woff2)}</style>
<img src="https://cdn.example/a.png"><img src="data:image/png;base64,AAAA"><img src="/abs.png"><img src="//cdn.example/b.png">
<img src=".env.png"><img src="../outside.png"><img src="nope.png">"""
(site / "index.html").write_text(INDEX)
(site / "doc.md").write_text("# d\n\n![a](img/ms.png) ![b](<img/p.png> \"t\") <img src=\"img/p3.png\"> ![x](https://x/y.png) [링크](other.html)\n")
tix = mv.create(str(root), "site/index.html"); tdoc = mv.create(str(root), "site/doc.md")
ok = ["", "index.html", "css/a.css", "css/b.css", "css/deep.css", "img/c.png", "img/d.png", "img/p.png", "img/p2.png", "img/p3.png", "js/x.js", "img/poster.jpg",
      "page2.html", "img/bg.png", "fonts/f.woff2", "./img/p.png"]
for sp in ok: check(get(f"/v/{tix}/{sp}")[0] == 200, f"I1 참조된 자산은 열림: {sp!r} → {get(f'/v/{tix}/{sp}')[0]}")
for sp in ("README.md", "other.html", "img/unref.png", "css/unref.css", "other/x.png", "img/e.png", ".env.png", "img/ms.png", "nope.png", "abs.png"):
    check(get(f"/v/{tix}/{sp}")[0] == 404, f"I1 참조 안 된 건 404: {sp} → {get(f'/v/{tix}/{sp}')[0]}")
check(get(f"/v/{tix}/%2e%2e/outside.png")[0] in (403, 404), "I1 폴더 밖 참조는 안 열림")
for sp in ("img/ms.png", "img/p.png", "img/p3.png"): check(get(f"/v/{tdoc}/{sp}")[0] == 200, f"I1 md 이미지 참조: {sp}")
for sp in ("README.md", "other.html", "img/unref.png", "page2.html"): check(get(f"/v/{tdoc}/{sp}")[0] == 404, f"I1 md 가 참조 안 한 건 404: {sp}")
# 파일을 고치면 집합이 다시 계산된다(mtime)
new = INDEX.replace("<img src=\"nope.png\">", "<img src=\"img/new.png\">").replace('<img src="img/p.png" srcset="img/p2.png 2x, img/p3.png 3x">', "")
(site / "index.html").write_text(new); t = time.time() + 20; os.utime(site / "index.html", (t, t))
check(get(f"/v/{tix}/img/new.png")[0] == 200, "I1 새로 참조한 자산이 열린다")
check(get(f"/v/{tix}/img/p2.png")[0] == 404 and get(f"/v/{tix}/img/p.png")[0] == 200, "I1 참조를 뺀 자산은 닫힌다(favicon 으로 p.png 는 남음)")
(site / "css" / "a.css").write_text("body{background:url(../img/unref.png)}"); t = time.time() + 30; os.utime(site / "css" / "a.css", (t, t))
check(get(f"/v/{tix}/img/unref.png")[0] == 200 and get(f"/v/{tix}/img/c.png")[0] == 404, "I1 CSS 가 바뀌어도 반영")
check(len(mv.assets_of(str(root), "site/index.html")) <= 200, "자산 상한 200")
many = site / "many.html"; many.write_text("".join(f'<img src="img/m{i}.png">' for i in range(300)))
for i in range(300): (site / "img" / f"m{i}.png").write_bytes(b"x")
check(len(mv.assets_of(str(root), "site/many.html")) == 200, "300개 참조는 200개까지만")
# 포트 충돌·stop
srv2 = mv.ViewServer(srv.port)
check(srv2.start() is False and srv2.error, f"포트 충돌은 예외 없이 실패+이유: {srv2.error}")
check(get(f"/v/{tok}/")[0] == 200, "충돌 뒤에도 첫 서버 정상")
port = srv.port; srv.stop()
try:
    socket.create_connection(("127.0.0.1", port), timeout=2).close(); check(False, "stop 뒤에도 연결됨")
except OSError:
    pass
srv.stop()  # 두 번 불러도 괜찮다
srv2.stop()

# ── public_url
check(mv.public_url({"view": {"publicBase": "https://m.ts.net:10000/"}}, "T") == "https://m.ts.net:10000/v/T/", "public_url")
check(mv.public_url({"view": {}}, "T") is None and mv.public_url({}, "T") is None, "publicBase 없으면 None")

# ── Loop.view_server
def freeport():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
loop = mb.Loop(); p1 = freeport()
loop.view_server({"guildId": "G"}, 1000.0); check(loop.vsrv is None, "view 설정이 없으면 안 띄운다")
loop.view_server({"view": {"port": p1}}, 1000.0)
check(loop.vsrv is not None and loop.vsrv.port == p1, "view 설정이 있으면 띄운다")
socket.create_connection(("127.0.0.1", p1), timeout=2).close()
first = loop.vsrv; loop.view_server({"view": {"port": p1}}, 1004.0); check(loop.vsrv is first, "같은 설정이면 그대로")
p2 = freeport(); loop.view_server({"view": {"port": p2}}, 1008.0)
check(loop.vsrv is not first and loop.vsrv.port == p2, "포트가 바뀌면 다시")
blocker = socket.socket(); blocker.bind(("127.0.0.1", 0)); blocker.listen(1); pb = blocker.getsockname()[1]
loop2 = mb.Loop(); loop2.view_server({"view": {"port": pb}}, 2000.0)
check(loop2.vsrv is None, "포트 충돌이어도 데몬은 안 죽는다")
blocker.close()
loop2.view_server({"view": {"port": pb}}, 2010.0); check(loop2.vsrv is None, "충돌 직후 60초 안엔 재시도 안 함")
loop2.view_server({"view": {"port": pb}}, 2061.0); check(loop2.vsrv is not None, "60초 뒤엔 재시도해 띄운다")
loop2.view_server({"guildId": "G"}, 2070.0); check(loop2.vsrv is None, "view 설정이 사라지면 내린다")
loop.stop_view(); check(loop.vsrv is None, "stop_view")
try:
    socket.create_connection(("127.0.0.1", p2), timeout=2).close(); check(False, "stop_view 뒤에도 연결됨")
except OSError:
    pass
loop.stop_view()
sw = mv.create(str(root), "note.txt")   # note.txt 는 .txt 라 서빙은 안 되지만 기록 정리 대상 확인용
(root / "note.txt").unlink()
lp = mb.Loop(); lp.sweep_view(5000.0)
check("missing_since" in json.loads((d / f"{sw}.json").read_text()), "Loop.sweep_view 가 기록을 정리한다")
(root / "note.txt").write_text("t"); lp.sweep_view(5010.0)
check("missing_since" in json.loads((d / f"{sw}.json").read_text()), "한 시간 안엔 다시 안 돈다")
lp.sweep_view(5000.0 + 3601); check("missing_since" not in json.loads((d / f"{sw}.json").read_text()), "한 시간 뒤엔 돈다")

# ── CLI view-setup / view-revoke
cfgp = ms.config_path(); cfg0 = json.loads(cfgp.read_text())
os.environ["MARINA_TAILSCALE"] = "none"
check(ms.main(["view-setup"]) == 1 and "view" not in json.loads(cfgp.read_text()), "tailscale 없으면 안내만(설정 안 바뀜)")
os.environ["MARINA_TAILSCALE"] = str(tmp / "bin" / "fake-tailscale")
# M4: port 가 숫자가 아니면 깔끔한 에러(트레이스백·funnel 호출 없음)
bad = dict(cfg0, view={"port": "abc"}); cfgp.write_text(json.dumps(bad))
def calls(): return (tmp / "tailscale-calls").read_text() if (tmp / "tailscale-calls").exists() else ""
n0 = len(calls())
check(ms.main(["view-setup"]) == 1 and "funnel --bg" not in calls()[n0:], "port 가 숫자 아니면 실패 코드(funnel 안 부름)")
cfgp.write_text(json.dumps(cfg0))
# M4: 10000 에 다른 매핑이 이미 있으면 덮지 않고 안내하고 멈춘다
(tmp / "funnel-status").write_text(json.dumps({"TCP": {"10000": {"HTTPS": True}}, "Web": {"mac.tail1.ts.net:10000": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}}}}))
before = calls()
check(ms.main(["view-setup"]) == 1 and "view" not in json.loads(cfgp.read_text()), "M4: 기존 10000 매핑이 다르면 중단(설정 안 바뀜)")
check("funnel --bg" not in calls()[len(before):], "M4: 중단 땐 funnel 을 안 부른다")
check(ms.main(["view-setup", "--force"]) == 0 and "funnel --bg --https=10000 http://127.0.0.1:3905" in (tmp / "tailscale-calls").read_text(), "M4: --force 로만 덮는다")
cfgp.write_text(json.dumps(cfg0))
(tmp / "funnel-status").write_text(json.dumps({"TCP": {"10000": {"HTTPS": True}}, "Web": {"mac.tail1.ts.net:10000": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3905"}}}}}))
check(ms.main(["view-setup"]) == 0, "M4: 이미 우리 서버로 매핑돼 있으면 그대로 진행(멱등)")
cfgp.write_text(json.dumps(cfg0)); (tmp / "funnel-status").unlink()
check(ms.main(["view-setup"]) == 0, "view-setup")
v = json.loads(cfgp.read_text())["view"]
check(v == {"port": 3905, "publicBase": "https://mac.tail1.ts.net:10000"}, f"설정 저장: {v}")
# 맥에 오픈소스 tailscaled 와 Tailscale 앱이 같이 있으면 --socket 없는 CLI 는 앱을 본다(2026-09-28) — 형 Funnel 은 tailscaled 쪽
sock = tmp / "tailscaled.socket"; sock.write_text("")
os.environ["MARINA_TAILSCALE_SOCKET"] = str(sock)
n1 = len(calls())
cfgp.write_text(json.dumps(cfg0))
check(ms.main(["view-setup"]) == 0 and bool(calls()[n1:].split()) and all(c.startswith(f"--socket {sock} ") for c in calls()[n1:].splitlines() if c.strip()), f"소켓 지정: {calls()[n1:]}")
del os.environ["MARINA_TAILSCALE_SOCKET"]
calls = (tmp / "tailscale-calls").read_text().splitlines()
check("funnel --bg --https=10000 http://127.0.0.1:3905" in calls, f"funnel 인자: {calls}")
tcli = mv.create(str(root), "out/r.html")
check(ms.main(["view-revoke", tcli]) == 0 and mv.resolve(tcli) is None, "view-revoke <토큰>")
tcli = mv.create(str(root), "out/r.html")
check(ms.main(["view-revoke", str(root / "out" / "r.html")]) == 0 and mv.resolve(tcli) is None, "view-revoke <경로>")
check(ms.main(["view-revoke", "nope-nothing"]) == 1, "없는 대상은 실패 코드")
check(ms.main(["view-revoke", "--all-in", str(root)]) == 0, "view-revoke --all-in")

if fails:
    print("FAIL:\n  " + "\n  ".join(f for f in fails if f)); raise SystemExit(1)
print("ok")
PY

# ── md-view 자산: 문법·보안 설정
node --check "$DSCRIPTS/marina-view/md-view.js" || fail "md-view.js 문법"
grep -q 'DOMPurify' "$DSCRIPTS/marina-view/md-view.js" && grep -q 'marked' "$DSCRIPTS/marina-view/md-view.js" || fail "md-view.js 가 marked·DOMPurify 를 안 쓴다"
grep -q "securityLevel *: *'strict'" "$DSCRIPTS/marina-view/md-view.js" || fail "mermaid securityLevel strict 아님"

# ── 경계: runtime 에 v1 흔적 0, discord 모듈 목록에 marina_view
if grep -rIl 'marina_view_links\|view-link\|/view/\|md-view' "$SCRIPTS" --exclude-dir=__pycache__ 2>/dev/null | grep -q .; then
  grep -rIl 'marina_view_links\|view-link\|/view/\|md-view' "$SCRIPTS" --exclude-dir=__pycache__; fail "runtime 쪽에 v1 보기 흔적"
fi
[ ! -e "$HERE/test-view-links.sh" ] || fail "test-view-links.sh 가 남았다"
grep -qx 'marina_view' "$DSCRIPTS/DISCORD_MODULES" || fail "DISCORD_MODULES 에 marina_view 없음"
! grep -qx 'marina_view_links' "$SCRIPTS/RUNTIME_MODULES" || fail "RUNTIME_MODULES 에 marina_view_links 가 남았다"
echo "PASS test-discord-view"
