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
import re
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

    def __init__(self, root: Path, fit: str = "", virtual: "dict[str, bytes] | None" = None, block: "tuple[str, ...]" = ()):
        self.root = os.path.realpath(str(root))
        self.block = tuple(x.casefold() for x in block)     # root 바로 아래 이 이름의 폴더는 내주지 않는다(채팅 폴더의 rooms/ — 다른 방 자료)
        self.virtual = virtual or {}     # 파일 없이 내주는 가상 페이지(경로 → HTML) — md 미리보기용
        self.fit = os.path.realpath(os.path.join(self.root, fit)) if fit else ""
        self.height = 0
        self.cuts: list[int] = []        # 페이지가 알려 주는 자를 수 있는 자리(섹션 경계)
        self.failed = False              # 미리보기 페이지가 "라이브러리를 못 불러왔다"고 알렸는가
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
                if u.path == "/__marina/h":                    # 페이지가 알려 주는 전체 높이와 자를 수 있는 자리
                    q = urllib.parse.parse_qs(u.query)
                    v = q.get("v", ["0"])[0]
                    outer.height = max(outer.height, int(v)) if v.isdigit() else outer.height
                    got = [int(c) for c in q.get("c", [""])[0].split(",") if c.isdigit()]
                    if got:
                        outer.cuts = got
                    self.send_response(204)
                    self.end_headers()
                    return
                if u.path in outer.virtual:
                    data = outer.virtual[u.path]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if u.path == "/__marina/fail":
                    outer.failed = True
                    self.send_response(204)
                    self.end_headers()
                    return
                rel = urllib.parse.unquote(u.path).lstrip("/")
                p = os.path.realpath(os.path.join(outer.root, rel))
                first = os.path.relpath(p, outer.root).split(os.sep)[0].casefold() if p.startswith(outer.root + os.sep) else ""
                if not p.startswith(outer.root + os.sep) or not os.path.isfile(p) or first in outer.block:
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
_FIT_SCRIPT = (b"\n<script>(function(){var q=/[?&]__top=(\\d+)/.exec(location.search),top=q?+q[1]:0;"
               b"function fit(){var d=document.documentElement;d.style.zoom='';d.style.marginTop='';"
               b"var w=Math.max(d.scrollWidth,document.body?document.body.scrollWidth:0),v=window.innerWidth;"
               b"if(w>v+2)d.style.zoom=(v/w).toFixed(3);"
               # scrollHeight 는 창 높이(1차 1400)보다 작아지지 않아 짧은 페이지에 빈 공간이 붙었다 → 내용 끝(요소들의 아래 끝 + body 아래 여백)
               b"var b=document.body,e=0;if(b){var a=b.getElementsByTagName('*');for(var i=0;i<a.length;i++){var r=a[i].getBoundingClientRect();"
               b"if(r.height>0&&r.bottom>e)e=r.bottom;}e+=window.scrollY+(parseFloat(getComputedStyle(b).marginBottom)||0)+"
               b"(parseFloat(getComputedStyle(b).paddingBottom)||0);}"
               b"var z=parseFloat(d.style.zoom)||1,h=Math.ceil(e>0?e:Math.max(d.scrollHeight,b?b.scrollHeight:0)*z);"   # 요소 좌표는 이미 축소된 값
               # 자를 수 있는 자리 = body 직계 자식의 아래 끝(= 섹션 경계). 긴 페이지를 의미 단위로 나눌 때 쓴다
               # 단을 감싸는 겉 상자(body > div.wrap > section...)를 지나 진짜 단이 늘어선 곳까지 내려간다.
               # 보이는 것만 센다 — 이 스크립트 자신도 body 의 자식이라 그냥 세면 겉 상자를 못 지나친다
               b"function ks(n){var r=[],c=n?n.children:[];for(var i=0;i<c.length;i++){var q2=c[i].getBoundingClientRect();"
               b"if(q2.height>0)r.push([c[i],Math.round(q2.bottom+window.scrollY)]);}return r;}"
               b"var hs=b,kk=ks(hs);for(var k=0;k<3&&kk.length===1;k++){hs=kk[0][0];kk=ks(hs);}"
               b"var cs=[];for(var j=0;j<kk.length&&j<400;j++)cs.push(kk[j][1]);"
               b"new Image().src='/__marina/h?v='+h+'&c='+cs.join(',');"
               # 한 조각 촬영: 그 자리가 창 맨 위에 오게 민다(zoom 이 걸렸으면 margin 도 같이 줄어드니 나눠 준다)
               b"if(top)d.style.marginTop=(-top/z)+'px';}"
               b"window.addEventListener('load',fit);setTimeout(fit,1500);setTimeout(fit,3500);})();</script>\n")


def plan_shot(height: int) -> tuple[int, float, bool]:
    """전체 높이 → (창 높이, 배율, 잘림 여부). 한 장에 담는다 — 길면 배율을 2 → 1 까지 낮추고, 그래도 넘치면 자른다."""
    height = max(int(height or 0), 200)
    scale = max(1.0, min(2.0, MAX_PX / height))
    cap = int(MAX_PX / scale)
    return min(height, cap), round(scale, 2), height > cap


def _chrome_argv(chrome: str, port: int, profile: str, height: int, out: Path, url: str,
                 scale: float = 2.0, width: int = WIDTH, pdf: bool = False) -> list[str]:
    # PDF 는 페이지의 @page 규격(A4·재단 여백)대로 나온다 — 창 크기로 자르는 그림과 다르다
    tail = [f"--print-to-pdf={out}", "--no-pdf-header-footer"] if pdf else [f"--screenshot={out}"]
    return [chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
            "--disable-extensions", f"--user-data-dir={profile}",
            # 프록시를 안 거치는 길을 닫는다: WebRTC UDP, 형 키체인 접근, 핑·DoH(리뷰 S1·S2)
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--use-mock-keychain", "--no-pings", "--disable-features=DnsOverHttps",
            f"--proxy-server=http://127.0.0.1:{port}", "--proxy-bypass-list=<-loopback>",
            f"--window-size={width},{height}", "--hide-scrollbars", f"--force-device-scale-factor={scale:g}",
            "--virtual-time-budget=4000", *tail, url]


def _shot(chrome: str, port: int, height: int, out: Path, url: str, timeout: float, scale: float = 2.0,
          width: int = WIDTH, pdf: bool = False) -> bool:
    """크롬 한 번 = 결과 파일 하나(그림 한 장, pdf 면 PDF 하나). 외부 연결(CONNECT)을 열어 두면 크롬이 다 쓴 뒤에도 안 끝난다(실측)
    → 파일 크기가 멈추면 끈다."""
    profile = tempfile.mkdtemp(prefix="marina-render-")
    if out.exists():
        out.unlink()
    try:
        try:
            proc = subprocess.Popen(_chrome_argv(chrome, port, profile, height, out, url, scale, width, pdf),
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


def render_html(page: Path, root: Path, outdir: Path, timeout: float = 45, block: "tuple[str, ...]" = ()) -> tuple[Path | None, str]:
    """page(root 안) 전체를 폰 폭 미리보기 PNG 한 장으로. (파일, 안내) — 실패면 (None, 이유)."""
    chrome = find_chrome()
    if not chrome:
        return None, "크롬을 찾지 못했어"
    rel = os.path.relpath(os.path.realpath(str(page)), os.path.realpath(str(root)))
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / f"{Path(rel).stem}.png"
    srv = RenderServer(root, fit=rel, block=block)
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


# ── 올릴 이미지: 미리보기(폰 폭 확인용)와 달리 쇼핑몰·인쇄에 그대로 쓰는 제 크기 PNG
UPLOAD_WIDTH = 860      # 네이버 스마트스토어 기준(만드는법/상세페이지.md). 쿠팡은 780
UPLOAD_SLICE = 3000     # 한 장의 최대 높이 — 넘으면 섹션 경계에서 나눈다
MIN_PART = 0.4          # 경계를 고를 때 이보다 이른 자리는 안 고른다 — 조각이 토막나지 않게
MAX_PARTS = 12          # 이보다 많이 나뉘면 페이지를 나눠 만드는 게 맞다
OVER = 0.1              # 최대 높이를 넘겨도 되는 만큼 — 섹션 경계에 맞추려고, 또 꼬리를 앞 장에 붙이려고
TAIL = 0.1              # 끝에 이보다 짧게 남으면 한 장으로 치지 않고 앞 장에 붙인다(1px 꼬리 같은 것)
MERGE = 0.4             # 그 꼬리를 붙일 때 허용하는 초과 — OVER 로 이미 늘어난 장 뒤에서도 붙을 수 있게


def slice_plan(total: int, cuts: "list[int]", slice_h: int) -> list[tuple[int, int]]:
    """전체 높이 → [(시작, 높이)]. slice_h 를 넘지 않게 자르되, 가능하면 cuts(섹션 경계)에 맞춘다."""
    total, slice_h = max(int(total), 1), max(int(slice_h), 200)
    pts = sorted({int(c) for c in cuts if 0 < int(c) < total})
    out, pos = [], 0
    while total - pos > slice_h:
        # 조금 넘기더라도 경계에 맞추는 쪽이 낫다 — 딱 잘라 버리면 다음 장이 토막난다
        lim, lo = pos + int(slice_h * (1 + OVER)), pos + int(slice_h * MIN_PART)
        nxt = max((c for c in pts if lo < c <= lim), default=pos + slice_h)
        out.append((pos, nxt - pos))
        pos = nxt
    out.append((pos, total - pos))
    # 끝이 토막(1px 꼬리 같은 것)으로 남으면 앞 장에 붙인다 — 상한을 조금 넘겨도 한 장이 낫다
    if len(out) > 1 and out[-1][1] <= slice_h * TAIL and out[-2][1] + out[-1][1] <= slice_h * (1 + MERGE):
        (top, head), (_, tail) = out[-2], out[-1]
        out[-2:] = [(top, head + tail)]
    return out


def export_html(page: Path, root: Path, outdir: Path, width: int = UPLOAD_WIDTH, slice_h: int = UPLOAD_SLICE,
                timeout: float = 60, block: "tuple[str, ...]" = ()) -> tuple[list[Path], str]:
    """page 를 올릴 수 있는 제 크기 PNG 로. 길면 섹션 경계에서 여러 장. (파일들, 안내) — 실패면 ([], 이유)."""
    chrome = find_chrome()
    if not chrome:
        return [], "크롬을 찾지 못했어"
    rel = os.path.relpath(os.path.realpath(str(page)), os.path.realpath(str(root)))
    outdir.mkdir(parents=True, exist_ok=True)
    stem = Path(rel).stem
    srv = RenderServer(root, fit=rel, block=block)
    srv.start()
    try:
        url = f"http://127.0.0.1:{srv.port}/" + urllib.parse.quote(rel)
        tmpdir = tempfile.mkdtemp(prefix="marina-export-")                      # 결과 폴더의 같은 이름 파일을 건드리지 않게
        try:
            ok = _shot(chrome, srv.port, FIRST, Path(tmpdir) / "probe.png", url, timeout,  # 1차: 높이·경계 재기
                       scale=1.0, width=width)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
        if not ok:
            return [], "렌더링 결과가 없어"
        for _ in range(20):          # 크롬은 그림을 다 쓰고 나서 높이를 알려 줄 때가 있다 — 조금 기다려 준다
            if srv.height:
                break
            time.sleep(0.1)
        if not srv.height:
            return [], "페이지 높이를 재지 못했어"
        plan = slice_plan(srv.height, srv.cuts, slice_h)
        if len(plan) > MAX_PARTS:
            return [], f"페이지가 너무 길어({srv.height}px, {len(plan)}장) — 내용을 나눠 만들어 줘"
        files = []
        for i, (top, height) in enumerate(plan, 1):
            out = outdir / (f"{stem}.png" if len(plan) == 1 else f"{stem}-{i}.png")
            if not _shot(chrome, srv.port, height, out, f"{url}?__top={top}", timeout, scale=1.0, width=width) \
                    or not out.is_file() or out.stat().st_size == 0:
                return [], f"{i}번째 장을 못 찍었어"              # 꼬리 빠진 채로 올리면 안 된다 — 다 되거나 아니거나
            files.append(out)
        # 지난번에 다르게 나뉘었던 조각만 치운다 — 이름이 비슷한 다른 페이지의 결과물(`상세-B.png`)까지 지우면 안 된다.
        # 다 찍은 뒤에 지운다: 중간에 실패하면 옛 것이라도 남아 있어야 한다
        keep, mine = {f.name for f in files}, re.compile(rf"{re.escape(stem)}(-\d+)?\.png")
        for stale in outdir.glob(f"{stem}*.png"):
            if stale.name not in keep and mine.fullmatch(stale.name):
                try:
                    stale.unlink()
                except OSError:
                    pass
        tall = max(h for _, h in plan)
        return files, (f"{len(files)}장으로 나눴어(제일 긴 장 {tall}px)" if len(files) > 1 else "")
    finally:
        srv.stop()


PRINT_WIDTH = 1123       # 인쇄 경로의 창 폭(CSS px) = A4 가로 297mm — 폭 기준 미디어쿼리가 폰 폭으로 걸리지 않게


def export_pdf(page: Path, root: Path, outdir: Path, timeout: float = 60,
               block: "tuple[str, ...]" = ()) -> tuple["Path | None", str]:
    """page 를 인쇄용 PDF 로. 페이지가 정한 @page 규격(A4·재단 여백)을 그대로 따른다 — 폭에 맞춰 줄이지 않는다
    (리플렛은 줄어들면 못 쓴다). (파일, 안내) — 실패면 (None, 이유)."""
    chrome = find_chrome()
    if not chrome:
        return None, "크롬을 찾지 못했어"
    rel = os.path.relpath(os.path.realpath(str(page)), os.path.realpath(str(root)))
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / f"{Path(rel).stem}.pdf"
    srv = RenderServer(root, block=block)        # fit 주입 없음 — 화면용 축소는 인쇄를 망친다
    srv.start()
    try:
        url = f"http://127.0.0.1:{srv.port}/" + urllib.parse.quote(rel)
        if not _shot(chrome, srv.port, FIRST, out, url, timeout, scale=1.0, width=PRINT_WIDTH, pdf=True) \
                or not out.is_file() or out.stat().st_size == 0:
            return None, "PDF 를 만들지 못했어"
        return out, ""
    finally:
        srv.stop()


# ── md 미리보기: md → (가상) HTML → 크롬. marina_view 의 md-view(marina-view/md-view.html)와 같은 라이브러리·버전·SRI(CDN 값이 두 곳이라 test-discord-view 가 CSP 와의 일치를 본다)
MAX_MD_BYTES = 2 * 1024 * 1024   # 이보다 큰 md 는 미리보기를 생략(크롬에 거대한 페이지를 먹이지 않는다)
SLICE = 1600          # 한 장의 높이(CSS px) — 폰 폭(500)에서 배율 2 면 3200px
_MD_LIBS = (
    ("https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js", "sha384-/TQbtLCAerC3jgaim+N78RZSDYV7ryeoBCVqTuzRrFec2akfBkHS7ACQ3PQhvMVi"),
    ("https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js", "sha384-+VfUPEb0PdtChMwmBcBmykRMDd+v6D/oFmB3rZM/puCMDYcIvF968OimRh4KQY9a"),
)
_MERMAID = ("https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js", "sha384-WmdflGW9aGfoBdHc4rRyWzYuAjEmDwMdGdiPNacbwfGKxBW/SO6guzuQ76qjnSlr")
_MD_JS = """(function(){
var off=parseInt((location.search.match(/[?&]o=(\\d+)/)||[])[1]||'0',10),w=document.getElementById('w');
function report(){new Image().src='/__marina/h?v='+Math.ceil(w.offsetHeight);}
function done(){w.style.transform='translateY(-'+off+'px)';report();setTimeout(report,800);}
function fail(){new Image().src='/__marina/fail';}
if(typeof marked==='undefined'||typeof DOMPurify==='undefined'){fail();return;}
try{var d=JSON.parse(document.getElementById('md-data').textContent);
w.innerHTML=DOMPurify.sanitize(marked.parse(d.text,{gfm:true}));}catch(e){fail();return;}
var bl=w.querySelectorAll('pre > code.language-mermaid');
if(!bl.length){done();return;}
var nodes=[];Array.prototype.forEach.call(bl,function(c){var x=document.createElement('div');x.className='mermaid';x.textContent=c.textContent;c.parentNode.parentNode.replaceChild(x,c.parentNode);nodes.push(x);});
var s=document.createElement('script');s.src=%s;s.integrity=%s;s.crossOrigin='anonymous';
s.onload=function(){mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'default'});mermaid.run({nodes:nodes}).then(done,done);};
s.onerror=done;document.head.appendChild(s);})();"""
_MD_CSS = ("html,body{margin:0;overflow:hidden;background:#fff}body{font:16px/1.65 -apple-system,'Apple SD Gothic Neo',sans-serif;color:#1f2328}"
           "#w{padding:16px;overflow-wrap:anywhere}h1,h2{border-bottom:1px solid #d1d9e0;padding-bottom:.25em}h1,h2,h3{line-height:1.3}"
           "code{font:.88em ui-monospace,Menlo,monospace;background:#f6f8fa;padding:.15em .35em;border-radius:5px}"
           "pre{background:#f6f8fa;border:1px solid #d1d9e0;border-radius:8px;padding:12px;white-space:pre-wrap;overflow-wrap:anywhere}pre code{background:none;padding:0}"
           "table{border-collapse:collapse;width:100%}th,td{border:1px solid #d1d9e0;padding:6px 10px;text-align:left}th{background:#f6f8fa}"
           "blockquote{margin-left:0;padding:0 1em;color:#59636e;border-left:4px solid #d1d9e0}img,svg{max-width:100%;height:auto}.mermaid{text-align:center}")


def md_preview_page(text: str, base_href: str) -> bytes:
    """md 미리보기용 한 장짜리 HTML. 원문은 JSON 으로 심는다(`</script>` 가 있어도 안 빠져나오게 <>& 이스케이프)."""
    import html as _html
    payload = (json.dumps({"text": text}, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e")
               .replace("&", "\\u0026").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    libs = "".join(f'<script src="{u}" integrity="{i}" crossorigin="anonymous"></script>' for u, i in _MD_LIBS)
    js = _MD_JS % (json.dumps(_MERMAID[0]), json.dumps(_MERMAID[1]))
    return (f'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<base href="{_html.escape(base_href, quote=True)}"><style>{_MD_CSS}</style></head><body><div id="w"></div>'
            f'<script type="application/json" id="md-data">{payload}</script>{libs}<script>{js}</script></body></html>').encode("utf-8")


def render_md(page: Path, root: Path, outdir: Path, max_images: int = 4, timeout: float = 45,
              block: "tuple[str, ...]" = ()) -> "tuple[list[Path], str]":
    """md(root 안)를 폰 폭 미리보기 PNG 로 — 길면 세로로 잘라 최대 max_images 장(앞쪽부터). (파일들, 안내) — 실패면 ([], 이유)."""
    chrome = find_chrome()
    if not chrome:
        return [], "크롬을 찾지 못했어"
    real_root = os.path.realpath(str(root))
    real = os.path.realpath(str(page))
    try:
        if os.path.getsize(real) > MAX_MD_BYTES:
            return [], "문서가 너무 커서(2MB 초과) 미리보기를 생략했어"
    except OSError:
        return [], "파일을 읽지 못했어"
    reldir = os.path.relpath(os.path.dirname(real), real_root)
    base = "/" if reldir == "." else "/" + urllib.parse.quote(reldir.replace(os.sep, "/")) + "/"
    html = md_preview_page(Path(real).read_text(encoding="utf-8", errors="replace"), base)
    outdir.mkdir(parents=True, exist_ok=True)
    stem = Path(real).stem
    srv = RenderServer(root, virtual={"/__marina/md.html": html}, block=block)
    srv.start()
    try:
        url = f"http://127.0.0.1:{srv.port}/__marina/md.html"
        first = outdir / f"{stem}-1.png"
        if not _shot(chrome, srv.port, SLICE, first, f"{url}?o=0", timeout):       # 1차: 높이 재기 겸 첫 조각
            return [], "렌더링 결과가 없어"
        if srv.failed:                                                             # marked·DOMPurify 를 못 불러왔다 — 빈 이미지를 보내지 않는다
            first.unlink(missing_ok=True)
            return [], "렌더 라이브러리(marked·DOMPurify)를 불러오지 못했어"
        h = srv.height
        if not h:
            return [first], ""
        if h < SLICE:                                                              # 짧은 문서는 실제 높이로 다시 찍어 빈 공백을 없앤다
            _shot(chrome, srv.port, max(h, 200), first, f"{url}?o=0", timeout)
            return ([first] if first.is_file() and first.stat().st_size > 0 else []), ""
        n = min(max_images, -(-h // SLICE))
        out = [first]
        for i in range(1, n):
            f = outdir / f"{stem}-{i + 1}.png"
            if not _shot(chrome, srv.port, max(min(SLICE, h - i * SLICE), 200), f, f"{url}?o={i * SLICE}", timeout):
                break
            out.append(f)
        return out, (f"문서가 길어 앞쪽 {len(out)}장만 미리보기로 보내 — 전체는 열어보기 주소로 봐 줘" if h > len(out) * SLICE else "")
    finally:
        srv.stop()


def upload_message(base: str, token: str, channel: str, content: str, files: list[Path],
                   timeout: float = 60, reply_to: str = "") -> dict[str, Any]:
    """첨부가 있는 메시지(multipart). 멘션 알림은 만들지 않는다. reply_to = 답장으로 달 메시지 ID."""
    boundary = uuid.uuid4().hex
    payload = {"content": content, "allowed_mentions": {"parse": []},
               "attachments": [{"id": i, "filename": f.name} for i, f in enumerate(files)]}
    if reply_to:
        payload["message_reference"] = {"message_id": reply_to, "fail_if_not_exists": False}
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
