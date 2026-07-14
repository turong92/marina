"""marina_logtext.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import LOG_CHUNK_BYTES

SENSITIVE_ASSIGNMENT_RE = re.compile(
    r"([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|ACCESS|WEBHOOK|CREDENTIAL|PRIVATE)"
    r"[A-Z0-9_]*\s*=\s*)(\"[^\"]*\"|'[^']*'|[^\s│]+)",
    re.IGNORECASE,
)

SENSITIVE_JSON_RE = re.compile(
    r'("(?:[^"]*(?:key|secret|token|password|access|webhook|credential|private)[^"]*)"\s*:\s*)"[^"]*"',
    re.IGNORECASE,
)

SENSITIVE_PY_OBJECT_RE = re.compile(
    r"('(?:[^']*(?:key|secret|token|password|access|webhook|credential|private)[^']*)'\s*:\s*)'[^']*'",
    re.IGNORECASE,
)

SENSITIVE_ENV_SPACE_RE = re.compile(
    r"(\b[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|ACCESS|WEBHOOK|CREDENTIAL|PRIVATE)"
    r"[A-Z0-9_]*[ \t]+)(\"[^\"]*\"|'[^']*'|[^\s│'\";,]+)"
)

SENSITIVE_FLAG_RE = re.compile(
    r"((?:--)(?:api[-_]?key|secret|token|password|access[-_]?token|webhook|credential|private[-_]?key)"
    r"[ \t]+)(\"[^\"]*\"|'[^']*'|[^\s│'\";,]+)",
    re.IGNORECASE,
)

SENSITIVE_AUTHORIZATION_RE = re.compile(
    r"(\bAuthorization\s*:\s*(?:(?:Bearer|Basic)\s+)?)(\"[^\"]*\"|'[^']*'|[^\s│'\";,]+)",
    re.IGNORECASE,
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# 클라 detectLogLevel 과 동일 판정 — 한쪽 수정 시 반드시 양쪽 동기화 (게이지 매치 ↔ 화면 강조 일치)
_TB_START_RE = re.compile(r"Traceback \(most recent call last\)")

_TB_CONT_RE = re.compile(r"^[ \t]")

_TB_END_RE = re.compile(r"^[\w.]+(Error|Exception|Exit|Interrupt|Warning)\b")

_ERR_PATTERNS = (
    re.compile(r"^\s*(Caused by\b|at [\w.$<>/]+\()"),
    re.compile(r"\[(error|window\.error|unhandledrejection)\]", re.IGNORECASE),
    re.compile(r"\b(ERROR|FATAL|SEVERE)\b"),
    re.compile(r"\b[\w.]*(Exception|Error):"),
    re.compile(r"Exception|Traceback"),
)

_WARN_PATTERNS = (re.compile(r"\[warn\]", re.IGNORECASE), re.compile(r"\bWARN(ING)?\b"))

def _detect_log_level(plain: str, state: dict[str, Any]) -> str:
    if _TB_START_RE.search(plain):
        state["tb"] = True
        return "err"
    if state.get("tb"):
        if _TB_CONT_RE.search(plain) or plain == "":
            return "err"
        state["tb"] = False
        if _TB_END_RE.search(plain):
            return "err"
    for pattern in _ERR_PATTERNS:
        if pattern.search(plain):
            return "err"
    for pattern in _WARN_PATTERNS:
        if pattern.search(plain):
            return "warn"
    return ""

LOG_MATCH_CAP = 2000

# 파일 전체를 한 번 훑어 필터/에러 매치 라인을 수집 — 매치 전용 뷰·게이지 틱·점프용
def scan_log_matches(path: Path, query: str, err_only: bool) -> dict[str, Any]:
    query_lower = query.lower()
    matches: list[dict[str, Any]] = []
    total = 0
    state: dict[str, Any] = {}
    offset = 0
    with path.open("rb") as handle:
        for raw in handle:
            start = offset
            offset += len(raw)
            text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            redacted = redact_text(text)
            plain = ANSI_RE.sub("", redacted)
            if err_only and not _detect_log_level(plain, state):
                continue
            if query_lower and query_lower not in plain.lower():
                continue
            total += 1
            if len(matches) < LOG_MATCH_CAP:
                # 텍스트는 redact 만 — ANSI 는 클라 렌더러가 색으로 살린다
                matches.append({"o": start, "t": redacted})
    return {"matches": matches, "total": total, "size": offset, "truncated": total > len(matches)}

# 청크 바이트를 라인 단위로 — 각 라인에 파일 내 끝 오프셋(e)을 달아 클라가 표시 창을 추적
def _chunk_lines(data: bytes, start: int) -> list[dict[str, Any]]:
    pieces = data.split(b"\n")
    items: list[dict[str, Any]] = []
    pos = start
    for raw in pieces[:-1]:
        pos += len(raw) + 1
        items.append({"t": redact_text(raw.decode("utf-8", errors="replace")), "e": pos})
    tail = pieces[-1]
    if tail:  # 개행 없는 꼬리 — EOF 직전이거나 초장문 라인 절단
        pos += len(tail)
        items.append({"t": redact_text(tail.decode("utf-8", errors="replace")), "e": pos})
    return items

# before(역방향)/after(정방향) 한 청크를 라인 경계로 정렬해 반환 — 무한 스크롤 페이징
def read_log_chunk(path: Path, before: int | None = None, after: int | None = None) -> dict[str, Any]:
    size = path.stat().st_size
    if after is not None:
        start = max(0, min(after, size))
        with path.open("rb") as handle:
            if start > 0:
                # 게이지 시크 등 임의 오프셋 허용 — 라인 중간이면 다음 경계로 정렬
                handle.seek(start - 1)
                if handle.read(1) != b"\n":
                    handle.readline()
                start = handle.tell()
            else:
                handle.seek(0)
            data = handle.read(LOG_CHUNK_BYTES)
        end = start + len(data)
        if end < size and not data.endswith(b"\n"):
            cut = data.rfind(b"\n")
            if cut >= 0:
                # 마지막 라인이 중간에서 잘림 — 버리고 다음 페이지 경계로 넘긴다
                data = data[:cut + 1]
                end = start + cut + 1
    else:
        before = max(0, min(before or 0, size))
        start = max(before - LOG_CHUNK_BYTES, 0)
        with path.open("rb") as handle:
            handle.seek(start)
            data = handle.read(before - start)
        end = before
        if start > 0:
            cut = data.find(b"\n")
            if cut >= 0:
                # 첫 라인이 중간에서 잘림 — 버리고 다음 페이지 경계로 넘긴다
                start += cut + 1
                data = data[cut + 1:]
    return {
        "lines": _chunk_lines(data, start),
        "start": start,
        "end": end,
        "size": size,
        "atStart": start == 0,
        "atEnd": end >= size,
    }

# SENSITIVE_*_RE 3종이 공유하는 키워드 — 프리필터용 (패턴 수정 시 여기도 동기화)
_SENSITIVE_HINTS = ("key", "secret", "token", "password", "access", "webhook", "credential", "private", "authorization")

def redact_text(value: str) -> str:
    # 프리필터 — 민감 키워드가 아예 없는 라인(로그 대부분)은 치환 3종을 스킵.
    # 전 라인 무조건 sub 가 매치 스캔·다운로드의 병목이었음 (실측 19MB 4.8s → 0.2s)
    low = value.lower()
    if not any(k in low for k in _SENSITIVE_HINTS):
        return value
    redacted = SENSITIVE_ASSIGNMENT_RE.sub(r"\1<redacted>", value)
    redacted = SENSITIVE_JSON_RE.sub(r'\1"<redacted>"', redacted)
    redacted = SENSITIVE_PY_OBJECT_RE.sub(r"\1'<redacted>'", redacted)
    redacted = SENSITIVE_ENV_SPACE_RE.sub(r"\1<redacted>", redacted)
    redacted = SENSITIVE_FLAG_RE.sub(r"\1<redacted>", redacted)
    redacted = SENSITIVE_AUTHORIZATION_RE.sub(r"\1<redacted>", redacted)
    return redacted
