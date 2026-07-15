#!/usr/bin/env bash
# DNS 리바인딩 가드 — /api/* 는 Host 가 로컬일 때만 응답한다.
# 왜: origin_allowed 는 Origin 이 없으면 통과시킨다(curl·same-origin GET 을 위해). 그런데
# 리바인딩된 페이지의 same-origin GET 은 Origin 을 **안 보낸다** → 악성 사이트가 evil.com 을
# 127.0.0.1 로 되돌린 뒤 그냥 fetch 하면 대시보드 전체가 읽힌다(워크트리 경로·에이전트 sid·
# PTY tid → term-stream 으로 살아있는 셸 스크롤백까지). POST 는 Origin 을 보내 403 이라 RCE 는
# 아니지만 유출은 실재한다. Host 를 보면 닫힌다 — 리바인딩은 Host 를 못 위조한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

python3 - "$SCR" <<'PY'
import sys, threading
from http.server import ThreadingHTTPServer
sys.path.insert(0, sys.argv[1])
import http.client

import marina_handler as MH

srv = ThreadingHTTPServer(("127.0.0.1", 0), MH.Handler)   # 포트 0 = 커널이 빈 포트 배정(다른 세션과 무관)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]

def get(path, host=None, extra=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = dict(extra or {})
    if host:
        h["Host"] = host
    c.request("GET", path, headers=h)
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, body

def post(path, host=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"content-type": "application/json"}
    if host:
        h["Host"] = host
    c.request("POST", path, body=b"{}", headers=h)
    r = c.getresponse()
    r.read()
    c.close()
    return r.status

try:
    # ── 공격: 리바인딩된 Host + Origin 없음(same-origin GET 이라 브라우저가 안 보낸다) ──
    for path in ("/api/term-list", "/api/sessions"):
        st, body = get(path, host="evil.com:1234")
        assert st == 403, f"{path}: 리바인딩 Host 가 {st} — 403 이어야(바디 {body[:80]!r})"
    assert post("/api/term-open", host="evil.com:1234") == 403, "POST 도 Host 가드 뒤여야"

    # ── 정상 경로가 안 깨져야 — 형이 실제로 쓰는 세 가지 ──
    for host in (f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}"):
        st, _ = get("/api/term-list", host=host)
        assert st == 200, f"정상 Host {host} 가 {st} — 형 접근이 깨진다"
    # Host 없음(HTTP/1.0 curl·스크립트) 도 통과 — 브라우저는 Host 를 항상 보내므로 리바인딩 경로가 아니다.
    # http.client 는 Host 를 자동으로 붙여서 이 경로를 못 만든다 → raw 소켓으로 진짜 없이 보낸다.
    import socket
    sk = socket.create_connection(("127.0.0.1", port), timeout=10)
    sk.sendall(b"GET /api/term-list HTTP/1.0\r\n\r\n")
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = sk.recv(4096)
        if not chunk:
            break
        raw += chunk
    sk.close()
    assert b" 200 " in raw.split(b"\r\n")[0], f"Host 없는 요청이 거부됨 — curl/스크립트가 깨진다: {raw.split(chr(13).encode())[0]!r}"

    # ── 정적 파일은 가드 밖(대시보드 자체 로딩) — /api/ 만 막는다 ──
    st, _ = get("/", host="evil.com:1234")
    assert st != 403, "정적 라우트까지 막으면 안 된다(가드는 /api/ 전용)"
finally:
    srv.shutdown()
    srv.server_close()
print("ok host 가드(리바인딩 403 · 정상 3종 200 · Host 없음 200 · 정적 제외)")
PY

grep -q "host_allowed" "$SCR/marina_sessions.py" || { echo "FAIL: host_allowed 없음"; exit 1; }
grep -q "host_allowed" "$SCR/marina_handler.py" || { echo "FAIL: host_allowed 미배선"; exit 1; }
echo "PASS test-host-guard"
