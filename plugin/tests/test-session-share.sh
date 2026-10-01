#!/usr/bin/env bash
# 채팅 세션 결과물 공유(share_file) — HTML 은 미리보기 이미지로, 모든 결과물은 #자료실 에도.
#  - 미리보기 렌더러는 chat 폴더만 내보내는 전용 서버를 거친다: file:// · 로컬/사설 주소 · 폴더 밖 경로 차단
#  - 크롬이 없으면 미리보기 없이 원본만(실패하지 않는다)
#  - #자료실 = CHAT 카테고리의 결과물 모음 채널(세션 없음), [방 제목] + 원래 방 링크 + 첨부
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{}}\n' > "$MARINA_CLAUDE_JSON"

# 가짜 크롬 — 받은 인자를 남기고 --screenshot= 경로에 PNG 를 쓴다. 페이지도 실제로 받아 본다(전용 서버 확인).
cat > "$TMPROOT/bin/fake-chrome" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$TMPROOT/chrome-argv"
for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}";; http://*) url="\$a";; --proxy-server=*) px="\${a#--proxy-server=}";; esac; done
curl -s -x "\$px" "\$url" > "$TMPROOT/chrome-page" || true
printf '\211PNG\r\n\032\nfake' > "\$out"
SH
chmod +x "$TMPROOT/bin/fake-chrome"
export MARINA_CHROME="$TMPROOT/bin/fake-chrome"

out="$(msess new chat wedding --title "웨딩 준비" 2>&1)" || fail "new chat: $out"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done

PYTHONPATH="$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$FAKE_OUT" "$TMPROOT" <<'PY'
import json, os, socket, subprocess, sys, urllib.request
from pathlib import Path
import marina_session as ms, marina_share as sh
fd, mh, out, tmp = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log():
    return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
root = (mh / "chat").resolve()
rec = ms.find_session("chat/wedding")
cfg = ms.load_config()
arch = cfg["projects"]["chat"].get("archiveChannelId")
apost = [x for x in log() if x["m"] == "POST" and x["b"].get("name") == "자료실"]
check(arch and apost and apost[0]["b"].get("type") == 0 and "모아" in apost[0]["b"].get("topic", ""), f"#자료실 생성: {apost}")

# 채팅 세션은 share_file 도구를 가진다
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
mcp = json.loads(Path(argv[argv.index("--mcp-config") + 1]).read_text())["mcpServers"]["marina"]
check(mcp["args"][-1] == "mcp-chat", f"채팅 MCP: {mcp}")
st = json.loads((Path(rec["stateDir"]) / "settings.json").read_text())
check("mcp__marina__share_file" in st["permissions"]["allow"], "share_file 허용")

# 렌더 서버 — chat 폴더만
(root / "sub").mkdir(exist_ok=True)
(root / "page.html").write_text("<h1>한글</h1>", encoding="utf-8")
(root / "dot.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>")
srv = sh.RenderServer(root); srv.start()
base = f"http://127.0.0.1:{srv.port}"
proxy = urllib.request.ProxyHandler({"http": base})
op = urllib.request.build_opener(proxy)
def get(url):
    try:
        r = op.open(url, timeout=5); return r.status, r.headers.get("Content-Type"), r.read()
    except urllib.error.HTTPError as e:
        return e.code, None, b""
code, ct, body = get(base + "/page.html")
check(code == 200 and ct == "text/html; charset=utf-8" and "한글" in body.decode(), f"폴더 안 HTML: {code} {ct}")
check(get(base + "/dot.svg")[1] == "image/svg+xml", "svg 종류")
check(get(base + "/../channels/x")[0] in (403, 404), "폴더 밖 경로 차단")
check(get(base + "/%2e%2e/discord.json")[0] in (403, 404), "인코딩된 .. 차단")
def raw_get(url):   # urllib 은 로컬 주소에 프록시를 안 거치므로 직접 프록시 형식 요청
    s = socket.create_connection(("127.0.0.1", srv.port), timeout=5)
    s.sendall(f"GET {url} HTTP/1.1\r\nHost: {urllib.parse.urlsplit(url).netloc}\r\n\r\n".encode())
    line = s.recv(100).split(b"\r\n")[0]; s.close(); return line
import urllib.parse
check(b" 403" in raw_get("http://127.0.0.1:3900/"), "다른 로컬 주소 차단")
check(get("http://example.com/")[0] == 403, "평문 http 외부 요청 차단")
def connect(target):
    s = socket.create_connection(("127.0.0.1", srv.port), timeout=5)
    s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
    line = s.recv(100).split(b"\r\n")[0]; s.close(); return line
for t in ("127.0.0.1:3900", "localhost:443", "10.0.0.1:443", "100.100.1.1:443", "169.254.169.254:80", "nonexistent-host.invalid:443", "1.1.1.1:22"):
    check(b" 403" in connect(t), f"CONNECT 차단: {t}")
# 페이지가 알려 주는 높이, 장 나누기
s2 = socket.create_connection(("127.0.0.1", srv.port), timeout=5)
s2.sendall(f"GET /__marina/h?v=3000 HTTP/1.1\r\nHost: 127.0.0.1:{srv.port}\r\n\r\n".encode()); s2.recv(100); s2.close()
check(srv.height == 3000, f"높이 신호: {srv.height}")
srv.stop()
check(sh.plan_shot(600) == (600, 2.0, False), "짧으면 실제 높이, 선명하게")
check(sh.plan_shot(10741) == (10741, 1.49, False), f"길면 배율을 낮춰 한 장에: {sh.plan_shot(10741)}")
check(sh.plan_shot(30000) == (16000, 1.0, True), f"너무 길면 자르고 알림: {sh.plan_shot(30000)}")
check(sh.plan_shot(0) == (200, 2.0, False), "높이를 모르면 최소")

# share_file (MCP)
os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
srvdef = json.loads(Path(argv[argv.index("--mcp-config") + 1]).read_text())["mcpServers"]["marina"]
def call(args):
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
    msg = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "share_file", "arguments": args}}
    p = subprocess.run([srvdef["command"]] + srvdef["args"], input=json.dumps(init) + "\n" + json.dumps(msg) + "\n",
                       text=True, capture_output=True, env=dict(os.environ), timeout=90)
    res = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    return res[-1]["result"], p.stderr
(root / "웨딩홀-비교.html").write_text("<h1>웨딩홀</h1>", encoding="utf-8")
r, e = call({"path": "웨딩홀-비교.html", "title": "웨딩홀 비교"})
txt = r["content"][0]["text"]
prev = root / "미리보기" / "웨딩홀-비교.png"
check(not r.get("isError") and str(prev) in txt and str(root / "웨딩홀-비교.html") in txt, f"share html: {r} {e}")
check(prev.is_file() and prev.read_bytes().startswith(b"\x89PNG"), "미리보기 PNG")
cargv = (tmp / "chrome-argv").read_text().splitlines()
check(any(a.startswith("--proxy-server=http://127.0.0.1:") for a in cargv) and "--proxy-bypass-list=<-loopback>" in cargv, f"크롬은 전용 서버만 거친다: {cargv}")
check(any(a.startswith("--user-data-dir=") for a in cargv) and "--headless=new" in cargv, "임시 프로필·헤드리스")
for f in ("--force-webrtc-ip-handling-policy=disable_non_proxied_udp", "--webrtc-ip-handling-policy=disable_non_proxied_udp",
          "--use-mock-keychain", "--no-pings"):
    check(f in cargv, f"크롬 우회 경로 차단 옵션: {f}")
check("웨딩홀" in (tmp / "chrome-page").read_text(), "크롬이 받은 페이지 = 그 파일")
up = [x for x in log() if x["m"] == "POST" and x["p"] == f"/channels/{arch}/messages"]
check(up and "[웨딩 준비] 웨딩홀 비교" in up[-1]["b"]["payload"]["content"] and f"<#{rec['channelId']}>" in up[-1]["b"]["payload"]["content"], f"자료실 글: {up}")
check(up and [f["filename"] for f in up[-1]["b"]["files"]] == ["웨딩홀-비교.png", "웨딩홀-비교.html"], f"자료실 첨부: {up[-1]['b'] if up else None}")
check(up and up[-1]["b"]["payload"].get("allowed_mentions") == {"parse": []}, "자료실 글은 알림 없음")

(root / "목록.md").write_text("# 목록")
r, e = call({"path": str(root / "목록.md")})
check(not r.get("isError") and "미리보기" not in r["content"][0]["text"], f"html 아닌 파일은 원본만: {r}")
for bad in ("/etc/hosts", "../discord.json", "없는파일.html", str(mh / "discord.json")):
    r, e = call({"path": bad})
    check(r.get("isError") is True, f"공유 거절: {bad} → {r}")
os.environ["MARINA_CHROME"] = "/nonexistent/chrome"
r, e = call({"path": "웨딩홀-비교.html"})
check(not r.get("isError") and "미리보기를 만들지 못했어" in r["content"][0]["text"], f"크롬 없으면 원본만: {r}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-share"
