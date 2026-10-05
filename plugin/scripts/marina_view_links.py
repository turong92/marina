#!/usr/bin/env python3
"""marina_view_links.py — 세션이 만든 결과물(HTML·md·이미지·pdf)을 폰에서 여는 보기 링크(2026-10-05).

<MARINA_HOME>/view-links/<token>.json (0600) = {root, rel, ts}. 대시보드 GET /view/<token>/... 가 resolve 해 root 안 파일을 내준다.
term-request 와 달리 **여러 번** 쓸 수 있고 7일 만료. 열람 권한은 링크가 아니라 대시보드 로그인·root 접근권한이 정한다.
HTML 이 샌드박스(불투명 origin) 안에서 상대 자산(css/js/img)을 불러올 때는 쿠키가 안 가므로, 로그인한 열람이 발급한
자산 티켓(메모리·30분)이 대신한다 — issue_ticket / ticket_lookup.
CLI: `marina view-link <path>` (marina.sh 가 이 파일을 부른다). 데몬(python3.9)도 import 한다.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Optional

from marina_term_requests import _root_registered, base_url, _remote_status

TTL_SECONDS = 7 * 86400
TICKET_IDLE_SECONDS = 5 * 60      # 마지막 사용 후
TICKET_MAX_SECONDS = 2 * 3600     # 계속 써도 발급 후 최대
TICKET_EXTS = frozenset((".css", ".js", ".mjs", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg", ".ico", ".woff", ".woff2",
                         ".ttf", ".otf", ".mp4", ".webm", ".mp3", ".wav", ".html", ".htm"))   # 페이지가 불러오는 자산만 — 데이터·문서는 로그인 경로로만
# md 렌더 페이지가 불러오는 cdnjs 파일(CSP script-src 에 정확히 이 URL 들만) — md-view.html·md-view.js 와 같은 값
CDN_SCRIPTS = (
    "https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js",
)
_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{20,64}")
_TICKET_RE = re.compile(r"[A-Za-z0-9_-]{10,64}")
_CONFIG_NAMES = (".mcp.json", "claude.md", "claude.local.md")           # share_file 의 _CHAT_CONFIG_NAMES 와 같은 정신
_SECRET_SUFFIXES = (".key", ".pem", ".p12", ".pfx", ".jks", ".keystore", ".tfstate", ".tfvars")
_SECRET_NAMES = (".npmrc", ".netrc", ".pgpass", ".pypirc", ".dev.vars", ".git-credentials", ".ssh", ".aws", ".docker", ".kube")
_SECRET_PREFIXES = (".env", "id_", "secrets.")

# ticket -> [발급 시각, 마지막 사용 시각, token, root, 토큰 파일 폴더 rel, principal]. 데몬 프로세스 메모리 — 재시작하면 열린 페이지의 자산만 다시 열어야 한다.
_TICKETS: dict[str, list] = {}
_TICKET_LOCK = threading.Lock()


def blocked_name(rel: Path) -> bool:
    """설정·비밀 이름 — 경로 구성요소 하나라도 걸리면 거부(대소문자 무시: APFS)."""
    for part in rel.parts:
        p = part.casefold()
        if p in (".git", ".claude") or p in _CONFIG_NAMES or p in _SECRET_NAMES or p.startswith(_SECRET_PREFIXES) \
                or p.endswith(_SECRET_SUFFIXES) or ".tfstate" in p or (p.startswith("credentials") and p.endswith(".json")):
            return True
    return False


def _dir() -> Path:
    return Path(os.environ.get("MARINA_HOME") or Path.home() / ".marina") / "view-links"


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


def create(root: str, path: str) -> str:
    root = str(root or "").strip()
    if not root:
        raise ValueError("root 가 비었어")
    if not _root_registered(root):
        raise ValueError(f"등록된 워크트리가 아니야: {root}")
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
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(d, 0o700)
    now = time.time()
    found = ""
    for f in d.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            if now - float(data.get("ts") or 0) > TTL_SECONDS:
                f.unlink()                       # 만료분은 치운다
            elif not found and data.get("root") == root and data.get("rel") == rel:
                found = f.stem
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    token = found or secrets.token_urlsafe(18)
    _write(d, token, {"root": root, "rel": rel, "ts": now})        # 재사용도 ts 갱신 — 막 공유한 링크가 곧 죽지 않게
    return token


def resolve(token: Any) -> Optional[tuple[str, str]]:
    """(root, rel) — 없음·형식 오류·7일 만료·rel 재검증 실패는 None. 여러 번 호출해도 소모되지 않는다."""
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        return None
    try:
        data = json.loads((_dir() / f"{token}.json").read_text(encoding="utf-8"))
        root, rel = data["root"], data["rel"]
        if not isinstance(root, str) or not root or time.time() - float(data.get("ts") or 0) > TTL_SECONDS:
            return None
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None
    return (root, rel) if _rel_ok(rel) else None       # 파일을 직접 만들어 넣어도 비밀·탈출 경로는 안 나간다


def ticket_ext_ok(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in TICKET_EXTS


def redact_view_log(text: str) -> str:
    """접근 로그에서 /view 의 토큰·티켓을 가린다(로그를 읽는 쪽이 링크를 가로채지 못하게)."""
    text = re.sub(r"/view/[A-Za-z0-9_-]{20,64}/~/[A-Za-z0-9_-]{10,64}/", "/view/…/~/…/", text)
    return re.sub(r"/view/[A-Za-z0-9_-]{20,64}/", "/view/…/", text)


def locate(root: str, token_rel: str, sub: str, confine: bool = False) -> Optional[Path]:
    """sub 가 비면 토큰 파일, 아니면 **토큰 파일과 같은 폴더** 기준 상대 경로. realpath 가 root 안의 파일이고 비밀 이름이 아니어야 한다."""
    if "\x00" in sub or os.path.isabs(sub):
        return None
    real_root = os.path.realpath(root)
    joined = os.path.join(real_root, token_rel) if not sub else os.path.join(real_root, os.path.dirname(token_rel), sub)
    real = os.path.realpath(joined)
    if not real.startswith(real_root + os.sep) or not os.path.isfile(real):
        return None
    if confine:       # 티켓 경로: 토큰 파일 폴더 **아래**만(root 안이라도 형제 폴더·상위는 안 된다)
        folder = os.path.realpath(os.path.join(real_root, os.path.dirname(token_rel)))
        if not real.startswith(folder + os.sep):
            return None
    if blocked_name(Path(os.path.relpath(real, real_root))) or blocked_name(Path(os.path.normpath(sub or token_rel))):
        return None
    return Path(real)


def issue_ticket(token: str, root: str, dirrel: str, principal: Any = None) -> str:
    """principal = 발급받은 로그인 사용자(인증 꺼짐이면 None) — 쓸 때마다 그 사용자의 root 접근권한을 다시 본다."""
    now = time.time()
    ticket = secrets.token_urlsafe(12)
    with _TICKET_LOCK:
        for k in [k for k, v in _TICKETS.items() if _dead(v, now)]:
            del _TICKETS[k]
        _TICKETS[ticket] = [now, now, token, root, dirrel, principal]
    return ticket


def _dead(v: list, now: float) -> bool:
    return now - v[1] > TICKET_IDLE_SECONDS or now - v[0] > TICKET_MAX_SECONDS


def ticket_lookup(ticket: Any) -> Optional[tuple[str, str, str, Any]]:
    """(token, root, dirrel, principal) — 조회하면 마지막 사용 시각이 갱신된다(sliding 5분, 최대 2시간)."""
    if not isinstance(ticket, str) or not _TICKET_RE.fullmatch(ticket):
        return None
    now = time.time()
    with _TICKET_LOCK:
        v = _TICKETS.get(ticket)
        if not v or _dead(v, now):
            return None
        v[1] = now
    return v[2], v[3], v[4], v[5]


_HEAD_RE = re.compile(rb"<head(?:\s[^>]*)?>", re.I)
_HTML_RE = re.compile(rb"<html(?:\s[^>]*)?>", re.I)
_DOCTYPE_RE = re.compile(rb"<!doctype[^>]*>", re.I)
# <base> 때문에 #앵커가 기준 주소로 가 버린다 — 문서 안에서만 움직이게 한다(샌드박스 allow-scripts 라 돌아간다)
_ANCHOR_JS = (b"<script>document.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('a[href^=\"#\"]');"
              b"if(!a)return;var id=decodeURIComponent(a.getAttribute('href').slice(1)),t=id&&(document.getElementById(id)||document.getElementsByName(id)[0]);"
              b"e.preventDefault();if(t)t.scrollIntoView();else if(!id)scrollTo(0,0);});</script>")


def _has_head_base(data: bytes) -> bool:
    """<head> 안(주석 제외)에 실제 <base> 가 있는가 — 본문·주석 속 문자열은 세지 않는다."""
    m = _HEAD_RE.search(data)
    start = m.end() if m else 0
    end = re.search(rb"</head\s*>|<body[\s>]", data[start:], re.I)
    head = data[start:start + end.start()] if end else data[start:start + 4096]
    return bool(re.search(rb"<base[\s>/]", re.sub(rb"<!--.*?-->", b"", head, flags=re.S), re.I))


def inject_base(data: bytes, base_href: str) -> bytes:
    """HTML 에 <base href> 를 넣는다 — 샌드박스 문서의 상대 자산이 자산 티켓 경로로 열리게. <head> 에 이미 <base> 가 있으면 건드리지 않는다."""
    import html as _html
    if _has_head_base(data):
        return data
    tag = ('<base href="%s">' % _html.escape(base_href, quote=True)).encode("utf-8") + _ANCHOR_JS
    for rx in (_HEAD_RE, _HTML_RE, _DOCTYPE_RE):      # doctype 앞에 넣으면 quirks 모드가 된다 — 열린 태그 뒤에
        m = rx.search(data)
        if m:
            return data[:m.end()] + tag + data[m.end():]
    return tag + data


def md_page(template: str, text: str, name: str, base_href: str) -> str:
    """md 렌더 페이지 — 원문은 JSON 으로 심는다(<, >, &, U+2028/9 이스케이프라 `</script>` 가 있어도 안 빠져나온다)."""
    import html as _html
    payload = (json.dumps({"text": text}, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e")
               .replace("&", "\\u0026").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    m = re.search(r"^#\s+(.+)$", text, re.M)
    title = (m.group(1).strip() if m else name)[:120]
    vals = {"TITLE": _html.escape(title), "BASE": '<base href="%s">' % _html.escape(base_href, quote=True), "DATA": payload}
    return re.sub(r"__(TITLE|BASE|DATA)__", lambda mm: vals[mm.group(1)], template)


def main(argv: list[str]) -> int:
    """marina view-link <path> — 주소 한 줄. 상대 경로는 현재 폴더 기준."""
    root, rest = "", list(argv)
    if len(rest) >= 2 and rest[0] == "--root":
        root, rest = rest[1], rest[2:]
    if rest[:1] == ["--"]:
        rest = rest[1:]
    if len(rest) != 1:
        print("usage: marina view-link <path>   # 이 워크트리 안 파일의 보기 주소(폰에서 열기) 한 줄 출력", file=sys.stderr)
        return 2
    try:
        token = create(root, os.path.abspath(rest[0]))
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"{base_url(_remote_status())}/view/{token}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
