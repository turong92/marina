"""채팅 세션 결과물 공유 — HTML 미리보기 렌더링과 Discord 첨부 업로드.

Discord·텔레그램 모두 HTML 파일을 앱 안에서 그려 주지 않는다(2026-10-01 조사) → 미리보기 이미지를 함께 보낸다.
렌더링은 headless 크롬이 하되, 크롬은 RenderServer 를 프록시로만 밖과 통한다:
  - 페이지 = 공유 폴더 안 파일만(127.0.0.1:<포트>), file:// 는 http 출처에서 막힌다(실측)
  - 밖으로는 https(CONNECT) 공인 주소만 — 확인한 바로 그 IP 로 연결하므로 해석 뒤 바꿔치기도 안 통한다
  - 로컬·사설·tailnet·평문 http 외부 요청은 403
데몬(python3.9)도 import 할 수 있게 3.9 호환."""
from __future__ import annotations

import http.server
import ipaddress
import json
import mimetypes
import os
import select
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

_CHROME_CANDIDATES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
)


def find_chrome() -> str:
    env = os.environ.get("MARINA_CHROME")
    if env:
        return env if os.access(env, os.X_OK) else ""
    for c in _CHROME_CANDIDATES:
        if os.access(c, os.X_OK):
            return c
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge"):
        found = shutil.which(name)
        if found:
            return found
    return ""


def _public_addr(host: str, port: int) -> tuple[str, int] | None:
    """모든 해석 주소가 공인일 때 그중 첫 주소. 아니면 None."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except (OSError, UnicodeError):
        return None
    addrs = [i[4][0].split("%")[0] for i in infos]
    if not addrs or not all(ipaddress.ip_address(a).is_global for a in addrs):
        return None
    return addrs[0], port


class RenderServer:
    """공유 폴더만 내보내는 HTTP 서버 겸 크롬 전용 프록시."""

    def __init__(self, root: Path, fit: str = ""):
        self.root = os.path.realpath(str(root))
        self.fit = os.path.realpath(os.path.join(self.root, fit)) if fit else ""
        self.height = 0
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a: Any) -> None:
                pass

            def _deny(self) -> None:
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self) -> None:
                u = urllib.parse.urlsplit(self.path)
                host = u.netloc or self.headers.get("Host", "")
                if host != f"127.0.0.1:{outer.port}":
                    return self._deny()
                if u.path == "/__marina/h":                    # 페이지가 알려 주는 전체 높이
                    v = urllib.parse.parse_qs(u.query).get("v", ["0"])[0]
                    outer.height = max(outer.height, int(v)) if v.isdigit() else outer.height
                    self.send_response(204)
                    self.end_headers()
                    return
                rel = urllib.parse.unquote(u.path).lstrip("/")
                p = os.path.realpath(os.path.join(outer.root, rel))
                if not p.startswith(outer.root + os.sep) or not os.path.isfile(p):
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                ctype = mimetypes.guess_type(p)[0] or "application/octet-stream"
                if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
                    ctype += "; charset=utf-8"
                with open(p, "rb") as fh:
                    data = fh.read()
                if p == outer.fit:
                    data += _FIT_SCRIPT
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_CONNECT(self) -> None:
                host, _, port = self.path.rpartition(":")
                target = _public_addr(host.strip("[]"), int(port)) if port.isdigit() and int(port) == 443 else None
                if not target:
                    return self._deny()
                try:
                    upstream = socket.create_connection(target, timeout=10)
                except OSError:
                    return self._deny()
                self.send_response(200, "Connection Established")
                self.end_headers()
                conns = [self.connection, upstream]
                try:
                    while True:
                        r, _, _ = select.select(conns, [], [], 15)
                        if not r:
                            break
                        for c in r:
                            data = c.recv(65536)
                            if not data:
                                return
                            (upstream if c is self.connection else self.connection).sendall(data)
                except OSError:
                    pass
                finally:
                    upstream.close()

            do_POST = do_PUT = do_DELETE = do_HEAD = lambda self: self._deny()   # noqa: E731

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self._t = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self) -> None:
        self._t.start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


# PC 폭으로 만든 페이지는 폰 폭 화면 밖으로 넘친다(실측: 오른쪽 잘림) → 넘치면 폭에 맞게 축소
FIRST = 1400        # 1차 촬영(높이 재기) 창 높이(CSS px)
MAX_PX = 16000      # 크롬 캡처 한 장의 높이 한계(장치 픽셀, 대략) — 넘으면 배율을 낮춘다
WIDTH = 500         # 크롬 창 최소 폭이 500 — 더 좁히면 레이아웃(500)과 캡처 폭이 어긋나 오른쪽이 잘린다(실측)

# 페이지에 붙이는 스크립트: ① PC 폭 페이지가 넘치면 폭에 맞게 축소 ② 전체 높이를 서버에 알림
_FIT_SCRIPT = (b"\n<script>(function(){function fit(){var d=document.documentElement;d.style.zoom='';"
               b"var w=Math.max(d.scrollWidth,document.body?document.body.scrollWidth:0),v=window.innerWidth;"
               b"if(w>v+2)d.style.zoom=(v/w).toFixed(3);"
               b"var z=parseFloat(d.style.zoom)||1,h=Math.ceil(Math.max(d.scrollHeight,document.body?document.body.scrollHeight:0)*z);"
               b"new Image().src='/__marina/h?v='+h;}"
               b"window.addEventListener('load',fit);setTimeout(fit,1500);setTimeout(fit,3500);})();</script>\n")


def plan_shot(height: int) -> tuple[int, float, bool]:
    """전체 높이 → (창 높이, 배율, 잘림 여부). 한 장에 담는다 — 길면 배율을 2 → 1 까지 낮추고, 그래도 넘치면 자른다."""
    height = max(int(height or 0), 200)
    scale = max(1.0, min(2.0, MAX_PX / height))
    cap = int(MAX_PX / scale)
    return min(height, cap), round(scale, 2), height > cap


def _chrome_argv(chrome: str, port: int, profile: str, height: int, out: Path, url: str,
                 scale: float = 2.0) -> list[str]:
    return [chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
            "--disable-extensions", f"--user-data-dir={profile}",
            # 프록시를 안 거치는 길을 닫는다: WebRTC UDP, 형 키체인 접근, 핑·DoH(리뷰 S1·S2)
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--use-mock-keychain", "--no-pings", "--disable-features=DnsOverHttps",
            f"--proxy-server=http://127.0.0.1:{port}", "--proxy-bypass-list=<-loopback>",
            f"--window-size={WIDTH},{height}", "--hide-scrollbars", f"--force-device-scale-factor={scale:g}",
            "--virtual-time-budget=4000", f"--screenshot={out}", url]


def _shot(chrome: str, port: int, height: int, out: Path, url: str, timeout: float, scale: float = 2.0) -> bool:
    """크롬 한 번 = 스크린샷 한 장. 외부 연결(CONNECT)을 열어 두면 크롬이 다 쓴 뒤에도 안 끝난다(실측)
    → 파일 크기가 멈추면 끈다."""
    profile = tempfile.mkdtemp(prefix="marina-render-")
    if out.exists():
        out.unlink()
    try:
        try:
            proc = subprocess.Popen(_chrome_argv(chrome, port, profile, height, out, url, scale),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            return False
        deadline, last = time.monotonic() + timeout, -1
        try:
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    break
                size = out.stat().st_size if out.exists() else -1
                if size > 0 and size == last:
                    break
                last = size
                time.sleep(0.5)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        return out.is_file() and out.stat().st_size > 0
    finally:
        shutil.rmtree(profile, ignore_errors=True)


def render_html(page: Path, root: Path, outdir: Path, timeout: float = 45) -> tuple[Path | None, str]:
    """page(root 안) 전체를 폰 폭 미리보기 PNG 한 장으로. (파일, 안내) — 실패면 (None, 이유)."""
    chrome = find_chrome()
    if not chrome:
        return None, "크롬을 찾지 못했어"
    rel = os.path.relpath(os.path.realpath(str(page)), os.path.realpath(str(root)))
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / f"{Path(rel).stem}.png"
    srv = RenderServer(root, fit=rel)
    srv.start()
    try:
        url = f"http://127.0.0.1:{srv.port}/" + urllib.parse.quote(rel)
        if not _shot(chrome, srv.port, FIRST, out, url, timeout):    # 1차: 전체 높이 재기(결과도 예비로 남김)
            return None, "렌더링 결과가 없어"
        if not srv.height:
            return out, ""
        height, scale, cut = plan_shot(srv.height)
        _shot(chrome, srv.port, height, out, url, timeout, scale)     # 2차: 전체를 한 장으로
        if not out.is_file() or out.stat().st_size == 0:
            return None, "렌더링 결과가 없어"
        return out, ("페이지가 너무 길어 앞부분만 미리보기로 보내 — 전체는 HTML 파일로 봐 줘" if cut else "")
    finally:
        srv.stop()


def upload_message(base: str, token: str, channel: str, content: str, files: list[Path],
                   timeout: float = 60) -> dict[str, Any]:
    """첨부가 있는 메시지(multipart). 멘션 알림은 만들지 않는다."""
    boundary = uuid.uuid4().hex
    payload = {"content": content, "allowed_mentions": {"parse": []},
               "attachments": [{"id": i, "filename": f.name} for i, f in enumerate(files)]}
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\n'
             f'Content-Type: application/json\r\n\r\n'.encode() + json.dumps(payload).encode() + b"\r\n"]
    for i, f in enumerate(files):
        name = urllib.parse.quote(f.name)
        head = (f'--{boundary}\r\nContent-Disposition: form-data; name="files[{i}]"; '
                f"filename*=UTF-8''{name}; filename=\"{name}\"\r\n"
                f"Content-Type: {mimetypes.guess_type(f.name)[0] or 'application/octet-stream'}\r\n\r\n")
        parts.append(head.encode() + f.read_bytes() + b"\r\n")
    body = b"".join(parts) + f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{base}/channels/{channel}/messages", data=body, method="POST", headers={
        "Authorization": f"Bot {token}", "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "DiscordBot (https://github.com/sumin/marina, 1)"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}
