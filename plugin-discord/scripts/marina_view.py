#!/usr/bin/env python3
"""marina_view.py — 세션이 만든 결과물(HTML·md·이미지·pdf)을 폰·다른 사람이 여는 보기 서버(2026-10-05, v2).

설계: docs/superpowers/specs/2026-10-05-discord-file-view-design.md. 마리나 대시보드·로그인과 무관하게 Discord 플러그인이 혼자 한다.
  - 기록 <MARINA_HOME>/discord-view/<token>.json (디렉터리 0700, 파일 0600) = {root, rel, channel, ts}. 링크 자체가 열쇠 — 만료 없음, 파일이 있는 동안 계속.
  - ViewServer: 데몬 안 스레드(127.0.0.1:<view.port>). GET /v/<token>/<sub> 가 토큰 파일과 **같은 폴더 아래**의 허용 확장자 파일만 내준다.
  - discord 모듈이라 runtime(plugin/scripts) 모듈을 import 하지 않는다(test-discord-boundary). 데몬(python3.9)도 import 한다.
"""
from __future__ import annotations

import html as _html
import posixpath
import json
import os
import re
import secrets
import sys
import tempfile
import threading
import time
import urllib.parse
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

DEFAULT_PORT = 3905
MAX_BYTES = 20 * 1024 * 1024
ASSET_DIR = Path(__file__).resolve().parent / "marina-view"
ALLOWED_EXTS = frozenset((".css", ".js", ".mjs", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg", ".ico", ".woff", ".woff2",
                          ".ttf", ".otf", ".mp4", ".webm", ".mp3", ".wav", ".html", ".htm", ".md", ".markdown", ".pdf"))
TYPES = {
    ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon",
    ".avif": "image/avif", ".pdf": "application/pdf", ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8", ".mjs": "application/javascript; charset=utf-8",
    ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
    ".mp4": "video/mp4", ".webm": "video/webm", ".mp3": "audio/mpeg", ".wav": "audio/wav",
    ".md": "text/plain; charset=utf-8", ".markdown": "text/plain; charset=utf-8",
}
SANDBOX = "sandbox allow-scripts allow-popups allow-forms"      # 불투명 origin — 같은 서버의 다른 토큰 페이지에도 못 닿는다
FRAME = "frame-ancestors 'none'"
# md 렌더 페이지가 불러오는 cdnjs 파일(CSP script-src 에 정확히 이 URL 들만) — md-view.html·md-view.js 와 같은 값
CDN_SCRIPTS = (
    "https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js",
)
MD_CSP = ("sandbox allow-scripts allow-popups; default-src 'none'; script-src 'self' " + " ".join(CDN_SCRIPTS)
          + "; style-src 'unsafe-inline'; img-src 'self' data:; font-src data:; base-uri 'self'; frame-ancestors 'none'")

_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{20,64}")
_CONFIG_NAMES = (".mcp.json", "claude.md", "claude.local.md")
_SECRET_SUFFIXES = (".key", ".pem", ".p12", ".pfx", ".jks", ".keystore", ".tfstate", ".tfvars")
_SECRET_NAMES = (".npmrc", ".netrc", ".pgpass", ".pypirc", ".dev.vars", ".git-credentials", ".ssh", ".aws", ".docker", ".kube")
_SECRET_PREFIXES = (".env", "id_", "secrets.")
_lock = threading.Lock()
MISSING_TTL = 7 * 86400          # 원본이 이만큼 넘게 계속 없을 때만 기록을 지운다(일시적 rm→쓰기엔 링크가 안 죽는다)
MAX_ASSETS = 200
CSS_DEPTH = 2                    # HTML 이 직접 가리키는 CSS 와, 그 CSS 가 @import 한 CSS 까지 읽는다
_ASSET_TTL = 5.0


def blocked_name(rel: Path) -> bool:
    """설정·비밀 이름 — 경로 구성요소 하나라도 걸리면 거부(대소문자 무시: APFS)."""
    for part in rel.parts:
        p = part.casefold()
        if p in (".git", ".claude") or p in _CONFIG_NAMES or p in _SECRET_NAMES or p.startswith(_SECRET_PREFIXES) \
                or p.endswith(_SECRET_SUFFIXES) or ".tfstate" in p or (p.startswith("credentials") and p.endswith(".json")):
            return True
    return False


def _dir() -> Path:
    return Path(os.environ.get("MARINA_HOME") or Path.home() / ".marina").expanduser() / "discord-view"


def _rel_ok(rel: Any) -> bool:
    if not isinstance(rel, str) or not rel or os.path.isabs(rel) or "\x00" in rel:
        return False
    parts = Path(rel).parts
    return bool(parts) and ".." not in parts and not blocked_name(Path(rel))


def _write(d: Path, token: str, payload: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.rename(tmp, d / f"{token}.json")


def _records(d: Path) -> "list[tuple[str, dict]]":
    out = []
    if d.is_dir():
        for f in d.glob("*.json"):
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    out.append((f.stem, data))
            except (OSError, ValueError):
                pass
    return out


def create(root: str, path: str, channel: str = "") -> str:
    """root 안 실제 파일(realpath)의 보기 토큰. 같은 (root, rel) 이면 기존 토큰을 다시 쓴다."""
    root = str(root or "").strip()
    if not root:
        raise ValueError("root 가 비었어")
    real_root = os.path.realpath(root)
    raw = str(path or "")
    real = os.path.realpath(raw if os.path.isabs(raw) else os.path.join(real_root, raw))
    if not real.startswith(real_root + os.sep):
        raise ValueError(f"이 폴더 안 파일만 열 수 있어: {raw}")
    if not os.path.isfile(real):
        raise ValueError(f"파일이 아니야: {raw}")
    rel = os.path.relpath(real, real_root)
    if blocked_name(Path(rel)):
        raise ValueError(f"설정·비밀 파일은 열 수 없어: {rel}")
    d = _dir()
    with _lock:
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(d, 0o700)
        for stem, data in _records(d):
            if data.get("root") == real_root and data.get("rel") == rel:
                return stem
        token = secrets.token_urlsafe(24)
        _write(d, token, {"root": real_root, "rel": rel, "channel": str(channel or ""), "ts": time.time()})
    return token


def resolve(token: Any) -> Optional["tuple[str, str]"]:
    """(root, rel) — 만료 없음. 형식 오류·없음·rel 재검증 실패·파일이 사라진 것은 None(사라진 기록은 남기고 sweep 이 7일 뒤 정리)."""
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        return None
    f = _dir() / f"{token}.json"
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
        root, rel = data["root"], data["rel"]
        if not isinstance(root, str) or not root:
            return None
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None
    if not _rel_ok(rel):          # 파일을 직접 만들어 넣어도 비밀·탈출 경로는 안 나간다
        return None
    if not os.path.isfile(os.path.join(root, rel)):
        return None               # 기록은 지우지 않는다 — 정리는 sweep 이(일시적으로 없는 것일 수 있다)
    return root, rel


def sweep(now: Optional[float] = None) -> int:
    """원본이 7일 넘게 계속 없는 기록만 지운다(데몬이 한 시간마다). 없어진 시각은 missing_since 로, 돌아오면 지운다."""
    now = time.time() if now is None else now
    d, n = _dir(), 0
    with _lock:
        for stem, data in _records(d):
            root, rel = data.get("root"), data.get("rel")
            exists = isinstance(root, str) and isinstance(rel, str) and os.path.isfile(os.path.join(root, rel))
            try:
                if exists and "missing_since" in data:
                    data.pop("missing_since")
                    _write(d, stem, data)
                elif not exists:
                    since = data.get("missing_since")
                    if not isinstance(since, (int, float)):
                        data["missing_since"] = now
                        _write(d, stem, data)
                    elif now - since > MISSING_TTL:
                        (d / f"{stem}.json").unlink()
                        n += 1
            except OSError:
                pass
    return n


def revoke(target: Optional[str] = None, all_in: Optional[str] = None, channel: Optional[str] = None) -> int:
    """토큰·경로·폴더 전체(all_in)·채널(그 방에서 만든 것)로 링크를 끊는다 — 지운 개수."""
    d = _dir()
    victims: "list[str]" = []
    if channel:
        victims = [s for s, r in _records(d) if r.get("channel") == str(channel)]
    elif all_in:
        real = os.path.realpath(all_in)
        victims = [s for s, r in _records(d) if r.get("root") == real]
    elif target:
        if _TOKEN_RE.fullmatch(target) and (d / f"{target}.json").is_file():
            victims = [target]
        else:
            real = os.path.realpath(target)
            victims = [s for s, r in _records(d)
                       if isinstance(r.get("root"), str) and isinstance(r.get("rel"), str)
                       and os.path.realpath(os.path.join(r["root"], r["rel"])) == real]
    n = 0
    for s in victims:
        try:
            (d / f"{s}.json").unlink()
            n += 1
        except OSError:
            pass
    return n


def public_url(cfg: "dict[str, Any]", token: str) -> Optional[str]:
    view = cfg.get("view") if isinstance(cfg, dict) else None
    base = str((view or {}).get("publicBase") or "").strip().rstrip("/") if isinstance(view, dict) else ""
    return f"{base}/v/{token}/" if base else None


def redact_log(text: str) -> str:
    """접근 로그에서 /v/ 의 토큰을 가린다(로그를 읽는 쪽이 링크를 가로채지 못하게)."""
    return re.sub(r"/v/[A-Za-z0-9_-]{20,}", "/v/…", text)


def locate(root: str, token_rel: str, sub: str) -> Optional[Path]:
    """sub 가 비면 토큰 파일, 아니면 **토큰 파일과 같은 폴더 아래**의 파일. realpath 가 그 폴더 안이고 비밀 이름이 아니어야 한다."""
    if "\x00" in sub or os.path.isabs(sub) or ".." in Path(sub).parts:
        return None
    real_root = os.path.realpath(root)
    folder = os.path.realpath(os.path.join(real_root, os.path.dirname(token_rel)))
    real = os.path.realpath(os.path.join(real_root, token_rel) if not sub else os.path.join(folder, sub))
    if not os.path.isfile(real):
        return None
    if sub and not real.startswith(folder + os.sep):
        return None
    if not real.startswith(real_root + os.sep):
        return None
    if blocked_name(Path(os.path.relpath(real, real_root))) or blocked_name(Path(os.path.normpath(sub or token_rel))):
        return None
    return Path(real)


_ASSET_TAGS = frozenset(("img", "script", "link", "source", "video", "audio", "track", "object", "embed", "iframe", "a"))
_CSS_URL = re.compile(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)""", re.I)
_CSS_IMPORT = re.compile(r"""@import\s+(?:"([^"]*)"|'([^']*)')""", re.I)
_MD_IMG = re.compile(r"""!\[[^\]]*\]\(\s*(?:<([^>]*)>|([^)\s]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)""")
_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


class _Refs(HTMLParser):
    """HTML 에서 상대 자산 후보(urls)와 CSS 조각(style 속성·<style>)을 모은다."""

    def __init__(self, only_img: bool = False) -> None:
        super().__init__(convert_charrefs=True)
        self.only_img, self.urls, self.css, self._style = only_img, [], [], False

    def handle_starttag(self, tag: str, attrs: Any) -> None:
        a = {k: v for k, v in attrs if v is not None}
        if tag == "style":
            self._style = True
        if self.only_img:
            if tag == "img" and a.get("src"):
                self.urls.append(a["src"])
            return
        if a.get("style"):
            self.css.append(a["style"])
        if tag in _ASSET_TAGS:
            self.urls += [a[k] for k in ("src", "href", "poster", "data") if a.get(k)]
            if tag in ("img", "source") and a.get("srcset"):
                self.urls += [p.split()[0] for p in a["srcset"].split(",") if p.strip()]

    def handle_endtag(self, tag: str) -> None:
        if tag == "style":
            self._style = False

    def handle_data(self, data: str) -> None:
        if self._style:
            self.css.append(data)


def _css_refs(text: str) -> "list[str]":
    return [next(g for g in m.groups() if g is not None) for rx in (_CSS_URL, _CSS_IMPORT) for m in rx.finditer(text)]


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace") if p.stat().st_size <= MAX_BYTES else ""


_ASSET_CACHE: "dict[tuple[str, str], tuple[float, list, set]]" = {}


def assets_of(root: str, token_rel: str) -> "set[str]":
    """토큰 파일이 **실제로 참조하는** 상대 자산(토큰 파일 폴더 기준 정규화 경로) — 이것만 서빙한다(같은 폴더의 다른 파일은 안 열린다).
    HTML: src·href·srcset·poster·data 와 style 의 url(). CSS 는 url()/@import 를 CSS_DEPTH 단계까지 따라간다. md: 이미지.
    각 자산도 locate(폴더 한정·비밀 이름)·확장자 allowlist 를 통과해야 한다. 최대 MAX_ASSETS 개. 원본 mtime 이 바뀌면 다시 계산한다."""
    key = (os.path.realpath(root), token_rel)
    hit = _ASSET_CACHE.get(key)
    if hit and time.monotonic() - hit[0] < _ASSET_TTL and all(_mtime(p) == m for p, m in hit[1]):
        return hit[2]
    start = locate(root, token_rel, "")
    found: "set[str]" = set()
    sig: list = []
    if start is not None:
        sig.append((str(start), _mtime(str(start))))

        def add(ref: str, base: str) -> Optional[str]:
            ref = urllib.parse.unquote(ref.strip().split("#")[0].split("?")[0])
            if not ref or ref.startswith(("/", "#")) or _SCHEME.match(ref) or len(found) >= MAX_ASSETS:
                return None
            rel = posixpath.normpath(posixpath.join(base, ref))
            if rel.startswith("..") or rel == ".":
                return None
            p = locate(root, token_rel, rel)
            if p is None or p.suffix.lower() not in ALLOWED_EXTS:
                return None
            found.add(rel)
            return rel
        try:
            text, suffix, css_queue = _read(start), start.suffix.lower(), []
            if suffix in (".md", ".markdown"):
                p = _Refs(only_img=True)
                p.feed(text)
                refs = [next(g for g in m.groups() if g is not None) for m in _MD_IMG.finditer(text)] + p.urls
            elif suffix in (".html", ".htm"):
                p = _Refs()
                p.feed(text)
                refs = p.urls + [u for c in p.css for u in _css_refs(c)]
            else:
                refs = []
            for ref in refs:
                rel = add(ref, "")
                if rel and rel.endswith(".css"):
                    css_queue.append((rel, 1))
            seen: "set[str]" = set()
            while css_queue:
                rel, depth = css_queue.pop(0)
                if rel in seen:
                    continue
                seen.add(rel)
                cp = locate(root, token_rel, rel)
                if cp is None:
                    continue
                sig.append((str(cp), _mtime(str(cp))))
                for ref in _css_refs(_read(cp)):
                    sub = add(ref, posixpath.dirname(rel))
                    if sub and sub.endswith(".css") and depth < CSS_DEPTH:
                        css_queue.append((sub, depth + 1))
        except (OSError, ValueError):
            pass
    _ASSET_CACHE[key] = (time.monotonic(), sig, found)
    return found


def _mtime(path: str) -> int:
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return -1


def md_page(template: str, text: str, name: str, base_href: str) -> str:
    """md 렌더 페이지 — 원문은 JSON 으로 심는다(<, >, &, U+2028/9 이스케이프라 `</script>` 가 있어도 안 빠져나온다)."""
    payload = (json.dumps({"text": text}, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e")
               .replace("&", "\\u0026").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    m = re.search(r"^#\s+(.+)$", text, re.M)
    title = (m.group(1).strip() if m else name)[:120]
    vals = {"TITLE": _html.escape(title), "BASE": '<base href="%s">' % _html.escape(base_href, quote=True), "DATA": payload}
    return re.sub(r"__(TITLE|BASE|DATA)__", lambda mm: vals[mm.group(1)], template)


class _Handler(BaseHTTPRequestHandler):
    server_version = "marina-view"
    protocol_version = "HTTP/1.0"
    timeout = 30                      # 느린 연결(slowloris)이 스레드를 오래 붙잡지 않게

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[view] " + redact_log(fmt % args) + "\n")

    def _send(self, status: int, ctype: str, data: bytes, csp: str = "", cors: bool = False, location: str = "") -> None:
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.send_header("x-content-type-options", "nosniff")
        self.send_header("referrer-policy", "no-referrer")
        self.send_header("content-security-policy", f"{csp}; {FRAME}" if csp and "frame-ancestors" not in csp else (csp or FRAME))
        if location:
            self.send_header("location", location)
        if cors and self.headers.get("origin") == "null":      # 샌드박스 문서의 폰트·모듈 fetch(불투명 origin 은 "null"). 다른 사이트의 sandbox iframe 도 null 이라
            # 출처 구분이 아니다 — 토큰(링크)을 모르면 이 응답을 읽을 수 없다는 것이 방어선
            self.send_header("access-control-allow-origin", "null")
            self.send_header("vary", "origin")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _text(self, status: int) -> None:
        self._send(status, "text/plain; charset=utf-8", b"not found" if status == 404 else b"error")

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/v-md/md-view.js":
            self._send(200, "application/javascript; charset=utf-8", (ASSET_DIR / "md-view.js").read_bytes())
            return
        if not parsed.path.startswith("/v/"):
            self._text(404)
            return
        token, slash, tail = parsed.path[len("/v/"):].partition("/")
        resolved = resolve(token)
        if resolved is None:
            self._text(404)
            return
        if not slash:
            self._send(301, "text/plain; charset=utf-8", b"", location=f"/v/{token}/")
            return
        root, token_rel = resolved
        sub = urllib.parse.unquote(tail)
        if sub and posixpath.normpath(sub) not in assets_of(root, token_rel) | {os.path.basename(token_rel)}:
            self._text(404)           # 토큰 파일이 참조하지 않는 같은 폴더의 다른 파일은 안 열린다
            return
        target = locate(root, token_rel, sub)
        if target is None or target.suffix.lower() not in ALLOWED_EXTS:
            self._text(404)
            return
        try:
            size = target.stat().st_size
        except OSError:
            self._text(404)
            return
        if size > MAX_BYTES:
            self._send(413, "text/plain; charset=utf-8", "20MB 가 넘는 파일은 열 수 없어".encode("utf-8"))
            return
        data = target.read_bytes()
        suffix = target.suffix.lower()
        if suffix in (".md", ".markdown"):
            if urllib.parse.parse_qs(parsed.query).get("raw", [""])[0] == "1":
                self._send(200, TYPES[".md"], data, cors=True)
                return
            reldir = os.path.dirname(os.path.relpath(str(target), os.path.join(os.path.realpath(root), os.path.dirname(token_rel))))
            base = f"/v/{token}/" + ((urllib.parse.quote(reldir) + "/") if reldir else "")
            template = (ASSET_DIR / "md-view.html").read_text(encoding="utf-8")
            page = md_page(template, data.decode("utf-8", "replace"), target.name, base)
            self._send(200, "text/html; charset=utf-8", page.encode("utf-8"), csp=MD_CSP, cors=True)
            return
        sandboxed = suffix in (".html", ".htm", ".svg")
        self._send(200, TYPES[suffix], data, csp=SANDBOX if sandboxed else "", cors=True)


class ViewServer:
    """127.0.0.1:<port> 보기 서버(스레드). start() 는 예외를 안 던지고 성공 여부를 돌려준다 — 실패 이유는 .error."""

    def __init__(self, port: int = DEFAULT_PORT) -> None:
        self.want = int(port)
        self.port = 0
        self.error = ""
        self._srv: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None

    def start(self) -> bool:
        if self._srv is not None:
            return True
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", self.want), _Handler)
        except OSError as exc:
            self.error = f"포트 {self.want} 를 못 열었어: {exc}"
            return False
        srv.daemon_threads = True
        self._srv, self.port, self.error = srv, srv.server_address[1], ""
        self._thread = threading.Thread(target=srv.serve_forever, name="marina-view", daemon=True)
        self._thread.start()
        return True

    def stop(self) -> None:
        srv, self._srv = self._srv, None
        if srv is None:
            return
        srv.shutdown()
        srv.server_close()
        if self._thread:
            self._thread.join(5)
