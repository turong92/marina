#!/usr/bin/env bash
# 채팅방이 Discord 로 받은 첨부(수신함)를 작업 폴더 rooms/<channelId>/assets/ 로 가져오는 take_attachment.
#  - 원본 = 자기 방 수신함의 일반 파일만(심볼릭 링크·.. · 다른 방 수신함 · 디렉터리 · 없는 파일 거절)
#  - 대상 = rooms/<channelId>/assets/ 아래만(방별 격리), 이름 정리·중복 번호·원본 확장자 유지, 20MB/500MB 상한
#  - 반환 = 방 폴더 기준·작업 폴더 기준 경로 둘 다 + "HTML 은 rooms/<id>/ 안에"
#  - 돌려준 경로로 HTML 을 만들어 공유하면: 미리보기 렌더와 열어보기(/v/) 가 그 이미지를 실제로 내준다
#  - 로비에는 없다(파일 도구가 없어 쓸 데가 없다), 개발 세션 도구 목록에서도 숨긴다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"

cat > "$TMPROOT/bin/fake-chrome" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; http://*) url="\$a";; --proxy-server=*) px="\${a#--proxy-server=}";; esac; done
# 페이지가 싣는 이미지를 크롬처럼 같은 서버에서 받아 본다(상대 경로 → 전용 서버)
base="\${url%/*}"
curl -s -x "\$px" "\$url" > "$TMPROOT/chrome-page" || true
curl -s -x "\$px" -o "$TMPROOT/chrome-img" -w '%{http_code}' "\$base/assets/pic.jpg" > "$TMPROOT/chrome-img-code" || true
printf '\211PNG\r\n\032\nfake' > "\$out"
SH
chmod +x "$TMPROOT/bin/fake-chrome"
export MARINA_CHROME="$TMPROOT/bin/fake-chrome"

msess new chat shopping --title "홈쇼핑" >/dev/null 2>&1 || fail "new chat shopping"
msess new chat other --title "다른 방" >/dev/null 2>&1 || fail "new chat other"
msess lobby >/dev/null 2>&1 || fail "lobby"
for _ in $(seq 50); do [ "$(ls "$FAKE_OUT"/*/argv 2>/dev/null | wc -l)" -ge 3 ] && break; sleep 0.1; done

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" "$TMPROOT" <<'PY'
import json, os, sys, unicodedata
from pathlib import Path
import marina_session as ms, marina_view as mv
mh, tmp = Path(sys.argv[1]), Path(sys.argv[2])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
recs = [r for r in ms.load_sessions() if r["kind"] == "chat"]
a = next(r for r in recs if r["task"] == "shopping"); b = next(r for r in recs if r["task"] == "other")
lobby = next(r for r in ms.load_sessions() if r["kind"] == "chat-lobby")
root = Path(a["root"]); assert root == Path(b["root"]), "채팅방은 폴더를 함께 쓴다"
rid = str(a["channelId"])
roomdir = f"rooms/{rid}"                     # 작업 폴더 기준
room = f"{roomdir}/assets"
inbox_a, inbox_b = Path(a["stateDir"]) / "inbox", Path(b["stateDir"]) / "inbox"
JPG = b"\xff\xd8\xff\xe0fakejpeg"
(inbox_a / "1700-111.jpg").write_bytes(JPG)
(inbox_b / "1700-222.jpg").write_bytes(JPG + b"B")
os.environ["DISCORD_STATE_DIR"] = a["stateDir"]

def take(**args):
    try:
        return False, ms.chat_tool("take_attachment", args)
    except ms.SessionError as exc:
        return True, str(exc)

# 도구 목록·허용·규칙
check(any(t["name"] == "take_attachment" for t in ms._CHAT_TOOLS_MCP), "mcp-chat 도구 목록")
check(not any(t["name"] == "take_attachment" for t in ms._LOBBY_TOOLS), "로비엔 없다")
st = json.loads((Path(a["stateDir"]) / "settings.json").read_text())
check("mcp__marina__take_attachment" in st["permissions"]["allow"], "채팅 허용 목록")
lst = json.loads((Path(lobby["stateDir"]) / "settings.json").read_text())
check("mcp__marina__take_attachment" not in lst["permissions"]["allow"], "로비 허용 목록엔 없다")
check("take_attachment" in ms.CHAT_RULES and "rooms/" in ms.CHAT_RULES, "채팅 규칙: 방 폴더 안")
lines = ms.CHAT_RULES.splitlines()
check(any("터미널 명령을 부탁하지 마라" in l and "take_attachment" not in l for l in lines), "터미널 부탁 금지는 독립 항목")
# 개발 세션 도구 목록에서는 숨긴다
check([t["name"] for t in ms.chat_tools_for({"kind": None})].count("take_attachment") == 0
      and [t["name"] for t in ms.chat_tools_for({"kind": "chat"})].count("take_attachment") == 1, "개발 세션 목록에서 숨김")

# 가져오기 — 파일 이름만 / 절대 경로 둘 다. 반환은 방 폴더 기준과 작업 폴더 기준 둘 다
err, out = take(path="1700-111.jpg")
dest = root / room / "1700-111.jpg"
check(not err and dest.read_bytes() == JPG and f"{room}/1700-111.jpg" in out and "assets/1700-111.jpg" in out
      and f"{roomdir}/" in out and str(root) not in out, f"이름으로: {err} {out}")
err, out = take(path=str(inbox_a / "1700-111.jpg"), name="pic")
check(not err and (root / room / "pic.jpg").read_bytes() == JPG and f"{room}/pic.jpg" in out, f"절대 경로 + name: {out}")
check((inbox_a / "1700-111.jpg").is_file(), "원본 유지")
# 이름 정리 · 확장자 유지 · 중복 번호
err, out = take(path="1700-111.jpg", name="내 사진 (1)!.png")
check(not err and (root / room / "내_사진__1__.jpg").is_file(), f"이름 정리·원본 확장자: {out} {sorted(os.listdir(root / room))}")
err, out = take(path="1700-111.jpg", name="pic")
check(not err and (root / room / "pic-2.jpg").is_file() and f"{room}/pic-2.jpg" in out, f"중복 -2: {out}")
err, out = take(path="1700-111.jpg", name="pic.gif")
check(not err and (root / room / "pic-3.jpg").is_file(), f"중복 -3, 알려진 확장자는 버린다: {out}")
err, out = take(path="1700-111.jpg", name="v1.2")
check(not err and (root / room / "v1.2.jpg").is_file(), f"v1.2 의 꼬리를 확장자로 오인하지 않는다: {out} {sorted(os.listdir(root / room))}")
err, out = take(path="1700-111.jpg", name="../../evil")
check(not err and not (root / "evil.jpg").exists() and any(n.endswith("evil.jpg") for n in os.listdir(root / room)), f"name 으로 폴더 탈출 불가: {out}")
err, out = take(path="1700-111.jpg", name="id_card")
check(not err and (root / room / "_id_card.jpg").is_file(), f"열어보기가 막는 이름(id_ 등)은 접두 _ : {out}")
err, out = take(path="1700-111.jpg", name=".env")
check(not err and (root / room / "env.jpg").is_file() and not (root / room / ".env.jpg").exists(), f"점으로 시작하는 이름: {out}")
nfd = unicodedata.normalize("NFD", "한글사진")
err, out = take(path="1700-111.jpg", name=nfd)
check(not err and (root / room / "한글사진.jpg").is_file()
      and unicodedata.normalize("NFC", "한글사진.jpg") in os.listdir(root / room), f"한글은 NFC 로: {out} {sorted(os.listdir(root / room))}")
names = sorted(os.listdir(root / room))
check(all(not mv.blocked_name(Path(room) / n) for n in names), f"열어보기가 막는 이름(id_ 등)은 안 만든다: {names}")

# 설정 파일 이름(최종 stem+ext 로 검사) — 원본 확장자가 붙어 CLAUDE.md·settings.json 이 될 수 있다
(inbox_a / "t.md").write_text("x"); (inbox_a / "t.json").write_text("{}")
for want, src, expect in (("CLAUDE", "t.md", "_CLAUDE.md"), ("claude.local", "t.md", "_claude.local.md"),
                           ("settings", "t.json", "_settings.json"), ("mcp", "t.json", "mcp.json")):
    err, out = take(path=src, name=want)
    got = sorted(os.listdir(root / room))
    check(not err and expect in got, f"설정 파일 이름 {want}{Path(src).suffix} → {expect}: {out} {got}")
for n in os.listdir(root / room):
    check(n.casefold() not in ("claude.md", "claude.local.md", ".mcp.json", "settings.json", "settings.local.json"), f"설정 이름이 만들어짐: {n}")

# 거절
(inbox_a / "dir").mkdir()
(tmp / "secret.jpg").write_bytes(b"s")
os.symlink(tmp / "secret.jpg", inbox_a / "link.jpg")
os.symlink(inbox_b, inbox_a / "dirlink")
for label, args in (("수신함 밖 절대 경로", {"path": str(tmp / "secret.jpg")}),
                    ("..", {"path": "../discord.json"}), ("점점 중간", {"path": "dir/../1700-111.jpg"}),
                    ("심볼릭 링크", {"path": "link.jpg"}), ("링크 폴더 경유", {"path": "dirlink/1700-222.jpg"}),
                    ("없는 파일", {"path": "nope.jpg"}), ("디렉터리", {"path": "dir"}),
                    ("다른 방 수신함", {"path": str(inbox_b / "1700-222.jpg")}),
                    ("빈 path", {"path": ""}), ("수신함 자체", {"path": str(inbox_a)})):
    err, out = take(**args)
    check(err and "\n" not in out.strip(), f"거절 {label}: {err} {out}")
before = sorted(os.listdir(root / room))
check("link.jpg" not in before and "secret.jpg" not in before and "1700-222.jpg" not in before, f"거절한 것은 안 생김: {before}")
# 다른 방은 자기 폴더로, 서로 안 섞인다
os.environ["DISCORD_STATE_DIR"] = b["stateDir"]
ms.chat_tool("take_attachment", {"path": "1700-222.jpg"})
check((root / f"rooms/{b['channelId']}/assets/1700-222.jpg").read_bytes() == JPG + b"B", "다른 방은 자기 rooms 폴더")
check(not (root / room / "1700-222.jpg").exists(), "방끼리 섞이지 않는다")
err, out = take(path=str(inbox_a / "1700-111.jpg"))
check(err, f"다른 방(A) 수신함 거절(B 세션에서): {out}")
os.environ["DISCORD_STATE_DIR"] = a["stateDir"]

# 크기 상한: 파일 20MB(열어보기 서버 상한과 같다) — 넘으면 거절하고 이유, 흔적 없음
check(ms.TAKE_MAX_FILE == mv.MAX_BYTES, f"파일 상한 = 열어보기 상한: {ms.TAKE_MAX_FILE} vs {mv.MAX_BYTES}")
with open(inbox_a / "big.jpg", "wb") as fh:
    fh.truncate(ms.TAKE_MAX_FILE + 1)
err, out = take(path="big.jpg")
check(err and "20MB" in out, f"파일 상한: {out}")
check(not (root / room / "big.jpg").exists() and not [n for n in os.listdir(root / room) if n.startswith(".")], "상한 넘으면 안 만든다(임시 파일도)")
used = sum(p.stat().st_size for p in (root / room).iterdir())
ms.TAKE_MAX_ROOM = used + 10
(inbox_a / "mid.jpg").write_bytes(b"y" * 11)
err, out = take(path="mid.jpg")
check(err and "500MB" in out and "터미널" not in out and "cp" not in out and "주인" in out, f"방 합계 상한 — 터미널을 부탁하게 하지 않는다: {out}")
check(not (root / room / "mid.jpg").exists(), "합계 넘으면 안 만든다")
ms.TAKE_MAX_ROOM = 500 * 1024 * 1024
# 복사는 처음 잰 size 까지만(그동안 원본이 커져도)
import io
src, dst = io.BytesIO(b"g" * 150), io.BytesIO()
ms._copy_limited(src, dst, 100)
check(len(dst.getvalue()) == 100, f"size 만큼만 복사: {len(dst.getvalue())}")
# 복사 실패 시 대상이 남지 않는다(임시 이름 → rename)
orig_copy = ms._copy_limited
def boom(*a, **k): raise OSError("disk full")
ms._copy_limited = boom
err, out = take(path="1700-111.jpg", name="fails")
ms._copy_limited = orig_copy
check(err and not [n for n in os.listdir(root / room) if n.startswith("fails") or n.startswith(".")], f"실패하면 흔적 없음: {out} {sorted(os.listdir(root / room))}")
check(str(root) not in out, f"절대 경로를 내보내지 않는다: {out}")

# rooms/<id>/assets 자리에 파일이 있으면 SessionError(절대 경로 없이)
os.environ["DISCORD_STATE_DIR"] = lobby["stateDir"]       # 로비엔 도구가 없다(직접 호출도 거절)
err, out = take(path="x")
check(err, f"로비 직접 호출 거절: {out}")
os.environ["DISCORD_STATE_DIR"] = b["stateDir"]
import shutil
shutil.rmtree(root / f"rooms/{b['channelId']}/assets"); (root / f"rooms/{b['channelId']}/assets").write_text("file")
err, out = take(path="1700-222.jpg")
check(err and str(root) not in out and "Traceback" not in out, f"assets 자리에 파일: {out}")
os.environ["DISCORD_STATE_DIR"] = a["stateDir"]

# 반환 경로로 HTML 을 만들어 공유 — 방 폴더 안 HTML(rooms/<id>/page.html, src=assets/…) 이 미리보기·열어보기에 실린다
(root / roomdir / "page.html").write_text('<img src="assets/pic.jpg">', encoding="utf-8")
r = ms.chat_tool("share_file", {"path": f"{roomdir}/page.html"})
check("page.png" in r, f"share: {r}")
check("assets/pic.jpg" in (tmp / "chrome-page").read_text(), "크롬이 받은 페이지에 상대 경로")
check((tmp / "chrome-img-code").read_text().strip() == "200" and (tmp / "chrome-img").read_bytes() == JPG,
      f"렌더 서버가 방 assets 이미지를 내준다: {(tmp / 'chrome-img-code').read_text()}")

# 열어보기(/v/): 방 폴더 안 HTML 은 그 폴더 안만, 맨 위 HTML 은 rooms/ 를 못 싣는다
os.environ["MARINA_HOME"] = str(mh)
tok = mv.create(str(root), f"{roomdir}/page.html")
check(f"assets/pic.jpg" in mv.assets_of(str(root), f"{roomdir}/page.html")
      and mv.locate(str(root), f"{roomdir}/page.html", "assets/pic.jpg") is not None, "열어보기: 방 폴더 안 자산 허용")
check(mv.locate(str(root), f"{roomdir}/page.html", f"../../{b['channelId']}/assets/1700-222.jpg") is None, "열어보기: 방 폴더 위로 못 나간다")
(root / "top.html").write_text(f'<img src="{room}/pic.jpg"><img src="rooms/{b["channelId"]}/assets/1700-222.jpg">', encoding="utf-8")
(root / f"rooms/{b['channelId']}/assets").unlink(); (root / f"rooms/{b['channelId']}/assets").mkdir()
(root / f"rooms/{b['channelId']}/assets/1700-222.jpg").write_bytes(b"B")
check(mv.locate(str(root), "top.html", f"rooms/{b['channelId']}/assets/1700-222.jpg") is None, "열어보기: 맨 위 HTML 로 rooms/ 를 못 연다")
check(mv.locate(str(root), "top.html", f"{room}/pic.jpg") is None, "열어보기: 맨 위 HTML 은 자기 방 rooms/ 도 안 싣는다(방 폴더에 두라고 안내)")
check(not any(x.startswith("rooms/") for x in mv.assets_of(str(root), "top.html")), "열어보기: rooms/ 참조는 자산 목록에 없다")
(root / "assets").mkdir(exist_ok=True); (root / "assets" / "hand.jpg").write_bytes(b"H")
(root / "top2.html").write_text('<img src="assets/hand.jpg">', encoding="utf-8")
check(mv.locate(str(root), "top2.html", "assets/hand.jpg") is not None, "예전 맨 위 assets/ 는 그대로 열린다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-take-attachment"
