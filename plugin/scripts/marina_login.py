"""클로드 CLI 로그인 화면 읽기 — 폰에서 로그인을 끝내기 위한 최소 도구.

왜 필요한가: 클로드 로그인이 풀리면 맥에 가야만 풀 수 있었다. 마리나 모바일에는 터미널
화면이 아예 없어서(모바일에 term 표면이 없다) 로그인 URL 을 볼 방법이 없었기 때문이다.
여기서 화면을 읽어 URL 만 꺼내주면, 폰에서 그 링크를 열고 받은 코드를 입력창에 붙여넣는
것으로 끝난다.

화면 모양은 **실물로 확인했다**(v2.1.237, 격리된 CLAUDE_CONFIG_DIR 로 띄워 형 자격증명과
무관하게):

    /login  → Select login method:
              ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise
    Enter   → Browser didn't open? Use the url below to sign in (c to copy)
              https://claude.com/cai/oauth/authorize?code=true&client_id=…
              Paste code here if prompted >

이 파일은 화면 문자열만 다룬다 — PTY 도 HTTP 도 모른다(그래야 실물 화면으로 테스트된다).
"""
from __future__ import annotations

import re

# 터미널은 링크를 **OSC 8** 로도 보낸다: ESC]8;id=…;<URL>  — 여기엔 URL 이 잘리지 않고
# 통째로 들어 있다(실측). 화면 글자는 80칸에서 잘리므로 이쪽이 훨씬 정확하다.
_OSC8 = re.compile(r"\x1b\]8;[^;]*;(https://[^\x07\x1b\s]+)")
_URL_START = re.compile(r"https://[^\s]+/oauth/authorize\?[^\s]*")
# URL 뒤에 이어지는 조각인지 — 터미널이 80칸에서 자르면 다음 줄이 공백 없이 이어진다.
_URL_TAIL = re.compile(r"^[A-Za-z0-9%&=_\-.~+/:?#\[\]@!$'()*,;]+$")


def extract_login_url(screen: str) -> str:
    """화면에서 로그인 URL 을 꺼낸다. **터미널이 잘라놓은 줄을 다시 잇는다.**

    한 줄만 집으면 URL 이 반토막이라 눌러도 안 열린다 — 실제 화면에서 이 URL 은 80칸에서
    네 줄로 잘려 있었다."""
    text = str(screen or "")
    # 1순위: OSC 8 하이퍼링크. 화면 글자와 달리 잘려 있지 않다.
    for match in _OSC8.finditer(text):
        if "/oauth/authorize?" in match.group(1):
            return match.group(1)
    # 2순위: 화면 글자를 잇는다(OSC 8 을 안 쓰는 터미널).
    lines = [line.strip() for line in text.splitlines()]
    for index, line in enumerate(lines):
        match = _URL_START.search(line)
        if not match:
            continue
        url = match.group(0)
        for tail in lines[index + 1:]:
            # 안내 문구·빈 줄을 만나면 URL 이 끝난 것이다.
            if not tail or " " in tail or not _URL_TAIL.match(tail):
                break
            url += tail
        return url
    return ""


def login_stage(screen: str) -> str:
    """지금 화면이 로그인 흐름의 어느 단계인가 — 다음에 무엇을 보낼지가 여기서 갈린다.

    공백을 지우고 본다: PTY 를 훑다 보면 글자 사이 공백이 뭉개진 화면이 흔하다."""
    text = re.sub(r"\s+", "", str(screen or ""))
    if "Selectloginmethod" in text:
        return "method"
    if "Usetheurlbelowtosignin" in text or "/oauth/authorize?" in text:
        return "url"
    if "Loginsuccessful" in text or "Loggedinas" in text:
        return "done"
    if "Notloggedin" in text or "Pleaserun/login" in text:
        return "logged_out"
    return ""


# ── API 오류 재시도 읽기 ────────────────────────────────────────────────────────
# CLI 는 요청이 튕기면 화면에 이렇게 쓴다(실측 2026-08-24):
#     ✻ API error · Retrying in 1s · attempt 1/10
# 그런데 모바일에는 이 줄이 안 보여서 그냥 "생각 중"으로만 나온다 — 형은 마리나가 먹통인 줄
# 알고 기다렸다(그날 원인은 서버 529 Overloaded 였다). 로그인 화면과 같은 방식으로 읽어 올린다.
#
# 터미널이 좁으면 공백이 뭉개져 붙어 나오므로(실측) 공백을 지우고 본다.
_RETRY_ATTEMPT = re.compile(r"attempt(\d+)/(\d+)", re.I)
_RETRY_MARK = re.compile(r"APIerror|APIError:", re.I)
_OVERLOADED = re.compile(r"overloaded|529", re.I)
_RATE_LIMIT = re.compile(r"ratelimit|429", re.I)


def api_retry(screen: str) -> dict | None:
    """화면이 'API 오류로 재시도 중' 이라고 말하고 있나. 아니면 None.

    반환: {"attempt": 3, "total": 10, "label": "서버 혼잡 · 재시도 중 (3/10)"}
    사람 말로 옮기는 이유: 폰에서 보는 사람은 529 가 뭔지 알 이유가 없고, 알아야 할 것은
    "마리나가 멈춘 게 아니라 서버가 밀린 것" 이라는 사실뿐이다."""
    붙임 = "".join(str(screen or "").split())
    if not 붙임 or not _RETRY_MARK.search(붙임):
        return None
    m = _RETRY_ATTEMPT.search(붙임)
    attempt = int(m.group(1)) if m else 0
    total = int(m.group(2)) if m else 0
    이유 = ("서버 혼잡" if _OVERLOADED.search(붙임)
            else "요청 한도" if _RATE_LIMIT.search(붙임)
            else "연결 문제")
    횟수 = f" ({attempt}/{total})" if attempt and total else ""
    return {"attempt": attempt, "total": total, "reason": 이유,
            "label": f"{이유} · 재시도 중{횟수}"}
