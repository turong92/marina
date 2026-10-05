#!/usr/bin/env bash
# 결과물 보기(2026-10-05) discord 쪽 — share_file 이 열어보기 주소를 돌려주고, md 도 미리보기 이미지(최대 4장)를 만든다.
#  - v2: 주소는 discord 가 혼자 만든다(marina_view.create + discord.json view.publicBase) — runtime(marina CLI)이 없어도 나온다.
#    publicBase 가 없으면 주소 없이 첨부만(+이유). 개발·채팅 세션 둘 다
#  - md 미리보기: marina_share.render_md — 가상 페이지 + 세로 조각(?o=오프셋), 높이가 길어도 4장까지, 크롬 없으면 md 만
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"
msess new proj feat/v --no-start >/dev/null 2>&1 || fail "new"
msess new chat room --title "방" >/dev/null 2>&1 || fail "new chat"
# 가짜 크롬 — --screenshot= 경로에 PNG 를 쓰고 받은 URL 을 남긴다
cat > "$TMPROOT/bin/fake-chrome" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; http://*) url="\$a";; --proxy-server=*) px="\${a#--proxy-server=}";; esac; done
printf '%s\n' "\$url" >> "$TMPROOT/chrome-urls"
curl -s -x "\$px" "\$url" > "$TMPROOT/chrome-page" || true
printf '\211PNG\r\n\032\nfake' > "\$out"
SH
chmod +x "$TMPROOT/bin/fake-chrome"
export MARINA_CHROME="$TMPROOT/bin/fake-chrome"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import json, os, sys, urllib.request
from pathlib import Path
import marina_session as ms, marina_share as sh
tmp = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

rec = ms.find_session("proj/feat/v")
root = Path(os.path.realpath(rec["root"]))
(root / "out").mkdir()
(root / "out" / "r.html").write_text("<h1>h</h1>")
(root / "out" / "n.md").write_text("# 제목\n\n본문 `x` | </script> & 끝\n", encoding="utf-8")
(root / "out" / "z.zip").write_bytes(b"PK")
(root / "out" / "p.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
(root / "out" / "img.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]

# ── publicBase 가 없으면 주소 없이 첨부만(+이유)
out = ms.chat_tool("share_file", {"path": "out/r.html"})
check("열어보기:" not in out and "설정 전" in out and str(root / "out" / "r.html") in out, f"publicBase 없음: {out}")
check(not (Path(os.environ["MARINA_HOME"]) / "discord-view").exists(), "설정 전엔 토큰도 안 만든다")
cfg = ms.load_config(); cfg["view"] = {"port": 3905, "publicBase": "https://box.example.ts.net:10000"}; ms.save_config(cfg)

# ── share_file: 열어보기 주소
out = ms.chat_tool("share_file", {"path": "out/r.html"})
check("열어보기: https://box.example.ts.net:10000/v/" in out and "reply 본문" in out, f"html 열어보기: {out}")
url = [l for l in out.splitlines() if l.startswith("열어보기:")][0].split()[1]
check(url.endswith("/"), f"주소 끝 슬래시: {url}")
tok = url.rstrip("/").rsplit("/", 1)[1]
vl = json.loads((Path(os.environ["MARINA_HOME"]) / "discord-view" / f"{tok}.json").read_text())
check(vl["root"] == str(root) and vl["rel"] == "out/r.html" and vl["channel"] == rec["channelId"], f"토큰이 이 세션 root·파일·채널로: {vl}")
check(ms.chat_tool("share_file", {"path": "out/r.html"}).count("열어보기:") == 1, "한 번만")
check(url in ms.chat_tool("share_file", {"path": "out/r.html"}), "다시 공유해도 같은 주소")
out = ms.chat_tool("share_file", {"path": "out/p.png"})
check("열어보기: " in out, f"png 도 열어보기: {out}")
out = ms.chat_tool("share_file", {"path": "out/z.zip"})
check("열어보기:" not in out and "설정 전" not in out and str(root / "out" / "z.zip") in out, f"zip 은 주소 없음: {out}")

# ── md: 열어보기 + 미리보기 이미지(크롬이 가짜라 1장)
out = ms.chat_tool("share_file", {"path": "out/n.md"})
lines = out.splitlines()
files = [l for l in lines if l.startswith("/")]
check(files and files[-1] == str(root / "out" / "n.md") and any(f.endswith(".png") for f in files[:-1]), f"md: 미리보기 png + 원본: {files}")
check("열어보기: " in out, "md 도 열어보기")
page = (tmp / "chrome-page").read_text()
check("marked" in page and "integrity=" in page and "제목" in page and "</script> &" not in page, f"크롬이 받은 가상 페이지: {page[:200]}")
check("<base href=\"/out/\">" in page, "md 폴더 기준 base(상대 이미지)")

# ── runtime(marina CLI)이 없어도 링크는 나온다 — discord 혼자
os.environ["MARINA_RUNTIME_BIN"] = "none"
out = ms.chat_tool("share_file", {"path": "out/r.html"})
check(f"열어보기: {url}" in out and str(root / "out" / "r.html") in out, f"runtime 없이도 링크: {out}")
os.environ["MARINA_RUNTIME_BIN"] = str(tmp / "bin" / "marina")

# ── 비밀 이름은 링크를 안 만든다(첨부 자체는 기존 규칙)
(root / "out" / ".env.png").write_bytes(b"x")
out = ms.chat_tool("share_file", {"path": "out/.env.png"})
check("열어보기:" not in out and "만들지 못했어" in out, f"비밀 이름: {out}")

# ── 크롬이 없으면 md 만(+이유)
os.environ["MARINA_CHROME"] = "/nonexistent/chrome"
out = ms.chat_tool("share_file", {"path": "out/n.md"})
check(str(root / "out" / "n.md") in out and "미리보기를 만들지 못했어" in out and not [l for l in out.splitlines() if l.endswith(".png")], f"크롬 없음: {out}")
os.environ["MARINA_CHROME"] = str(tmp / "bin" / "fake-chrome")

# ── 채팅 세션도 링크(채팅 폴더 안 파일, 그 채널 기록) + 미리보기
crec = ms.find_session("chat/room")
croot = Path(os.path.realpath(crec["root"]))
(croot / "m.md").write_text("# c")
os.environ["DISCORD_STATE_DIR"] = crec["stateDir"]
out = ms.chat_tool("share_file", {"path": "m.md"})
check("열어보기: https://box.example.ts.net:10000/v/" in out and any(l.endswith(".png") for l in out.splitlines()), f"채팅 세션: {out}")
ctok = [l for l in out.splitlines() if l.startswith("열어보기:")][0].split()[1].rstrip("/").rsplit("/", 1)[1]
cvl = json.loads((Path(os.environ["MARINA_HOME"]) / "discord-view" / f"{ctok}.json").read_text())
check(cvl["root"] == str(croot) and cvl["rel"] == "m.md" and cvl["channel"] == crec["channelId"], f"채팅 토큰: {cvl}")

# ── render_md 단위: 장수 제한·조각 오프셋(가짜 _shot 이 페이지를 받아 높이를 알린다)
calls = []
def fake_shot_factory(height_px):
    def fake(chrome, port, height, out, url, timeout, scale=2.0):
        calls.append((height, url.split("?")[-1]))
        body = urllib.request.urlopen(url, timeout=5).read().decode()
        assert "marked" in body, body[:100]
        urllib.request.urlopen(f"http://127.0.0.1:{port}/__marina/h?v={height_px}", timeout=5).read()
        Path(out).write_bytes(b"\x89PNG\r\n\x1a\nfake")
        return True
    return fake
orig_shot, orig_chrome = sh._shot, sh.find_chrome
sh.find_chrome = lambda: "/fake/chrome"
md = root / "out" / "n.md"
try:
    for h, want in ((30000, 4), (5000, 4), (3300, 3), (1000, 1), (0, 1)):
        calls.clear()
        sh._shot = fake_shot_factory(h)
        imgs, why = sh.render_md(md, root, tmp / "pv")
        check(len(imgs) == want and all(p.is_file() for p in imgs), f"높이 {h} → {want}장: {len(imgs)} {why}")
        if h > 4 * sh.SLICE:
            check("앞" in why, f"잘렸다는 안내: {why!r}")
        else:
            check(why == "", f"안 잘리면 안내 없음: {why!r}")
        offs = [c[1] for c in calls if c[1].startswith("o=")]
        check(offs[:want] == [f"o={i * sh.SLICE}" for i in range(want)] or want == 1, f"높이 {h} 오프셋: {calls}")
    # 첫 장은 높이를 모르니 SLICE 로 찍고, 짧은 문서는 실제 높이로 다시 찍는다
    calls.clear(); sh._shot = fake_shot_factory(1000); sh.render_md(md, root, tmp / "pv")
    check(calls[0][0] == sh.SLICE and calls[-1][0] == 1000, f"짧은 문서 재촬영: {calls}")
    # 마지막 장은 남은 높이만큼
    calls.clear(); sh._shot = fake_shot_factory(3500); sh.render_md(md, root, tmp / "pv")
    check(calls[-1][0] == 3500 - 2 * sh.SLICE, f"마지막 장 높이: {calls}")
    # I4 라이브러리(marked 등)를 못 불러오면 페이지가 /__marina/fail 로 알린다 → 이미지 없이 실패 + 이유
    def fail_shot(chrome, port, height, out, url, timeout, scale=2.0):
        urllib.request.urlopen(f"http://127.0.0.1:{port}/__marina/fail", timeout=5).read()
        Path(out).write_bytes(b"\x89PNG\r\n\x1a\nfake")
        return True
    sh._shot = fail_shot
    imgs, why = sh.render_md(md, root, tmp / "pv2")
    check(imgs == [] and "라이브러리" in why and not list((tmp / "pv2").glob("*.png")), f"라이브러리 실패는 실패로: {imgs} {why!r}")
    check("/__marina/fail" in sh.md_preview_page("x", "/").decode(), "페이지가 라이브러리 부재를 알린다")
    # 크기 상한 2MB — 넘으면 크롬을 부르지 않고 생략
    big = root / "out" / "big.md"; big.write_text("a" * (2 * 1024 * 1024 + 1))
    called = []
    sh._shot = lambda *a, **k: called.append(1) or True
    imgs, why = sh.render_md(big, root, tmp / "pv3")
    check(imgs == [] and "생략" in why and not called, f"2MB 초과 생략: {imgs} {why!r} {called}")
    # 촬영 실패 → 빈 목록 + 이유
    sh._shot = lambda *a, **k: False
    imgs, why = sh.render_md(md, root, tmp / "pv")
    check(imgs == [] and why, f"실패: {imgs} {why!r}")
finally:
    sh._shot, sh.find_chrome = orig_shot, orig_chrome
# 가상 페이지는 폴더 밖·다른 경로를 열어 주지 않는다
srv = sh.RenderServer(root, virtual={"/__marina/md.html": b"<p>v</p>"}); srv.start()
check(urllib.request.urlopen(f"http://127.0.0.1:{srv.port}/__marina/md.html", timeout=5).read() == b"<p>v</p>", "가상 페이지 서빙")
try:
    urllib.request.urlopen(f"http://127.0.0.1:{srv.port}/__marina/other.html", timeout=5); check(False, "다른 가상 경로가 열림")
except urllib.error.HTTPError as e:
    check(e.code == 404, f"없는 경로 404: {e.code}")
srv.stop()
# ── I3: 세션 정리(teardown)는 그 세션의 링크를 끊는다 — 개발=root 전체, 채팅=그 방(channel) 것만
import marina_view as mv
(croot / "n2.md").write_text("# n2"); other = mv.create(str(croot), "n2.md", "OTHER-ROOM")        # 같은 폴더의 다른 방 기록(채팅 폴더는 방끼리 공유)
check(mv.resolve(ctok) is not None, "teardown 전엔 열림")
ms.teardown(crec)
check(mv.resolve(ctok) is None, "채팅방 삭제 → 그 방 링크 끊김")
check(mv.resolve(other) is not None, "같은 폴더의 다른 방 링크는 그대로")
ms.teardown(rec)
check(mv.resolve(tok) is None, "개발 세션 삭제 → 그 워크트리 링크 끊김")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); raise SystemExit(1)
print("ok")
PY
echo "PASS test-discord-share-view"
