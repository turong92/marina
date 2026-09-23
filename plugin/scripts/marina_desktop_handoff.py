"""데스크톱 앱이 연 대화를 marina 가 놓아 준다 — "한 대화 = 한 주인".

**왜.** 모바일에서 대화를 이어받으면 marina 가 그 대화의 CLI 를 PTY 로 띄워 쥔다. 그 뒤 데스크톱 앱에서
같은 대화를 열면 앱은 "외부에서 실행 중" 이라며 입력을 막는다 — 한 대화에 쓰는 프로세스는 하나여야
하기 때문이다(형: "데스크탑앱이랑 자꾸 경쟁한다", 2026-09-23). marina 가 손을 놓지 않으니 형이 직접
닫기 전엔 데스크톱이 영영 잠겨 있었다.

**신호.** 데스크톱 앱은 대화를 **열기만 해도** 자기 기록(`local_*.json`)의 `lastFocusedAt` 을 찍는다.
실측(2026-09-23): 대화 하나를 클릭 → 그 파일만 17:42:50 → 19:12:00, 작업 시각(lastActivityAt)은 그대로,
나머지 247개는 안 움직였다. 이 값이 **marina 가 그 대화를 마지막으로 쓴 시각보다 뒤**면 데스크톱이
가져가려는 것이다.

**안전.** 작업 중(working)·질문 대기(blocked)면 놓지 않는다 — 다음 틱에 다시 본다. 턴을 끝내고 쉬는
상태가 되면 그때 PTY 를 내린다(SIGHUP — marina 의 '닫기' 와 같은 경로). 모바일에서 다시 부르면 지금처럼
resume 으로 되받아 온다. 끄기: `MARINA_DESKTOP_HANDOFF=0`.
"""

from __future__ import annotations

import glob
import json
import os
import time
from pathlib import Path

_MARGIN_S = 2.0                    # marina 가 쓴 직후의 포커스는 같은 사건으로 본다(시계 오차 여유)
_INDEX_TTL_S = 60.0                # sid → 기록 파일 색인은 가끔만 다시 만든다(파일 수백 개)
_BUSY = ("working", "blocked")
_index: dict = {}
_index_at = 0.0


def enabled() -> bool:
    return (os.environ.get("MARINA_DESKTOP_HANDOFF", "1") or "1").strip().lower() not in ("0", "false", "no", "off")


def _desktop_dir() -> Path:
    from marina_sessions import CLAUDE_SESSIONS_DIR
    return Path(CLAUDE_SESSIONS_DIR)


def _read(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}


def _focus_path(sid: str, now: float) -> str:
    """이 sid 의 데스크톱 기록 파일. 색인이 낡았거나 못 찾으면 다시 만든다."""
    global _index, _index_at
    if now - _index_at > _INDEX_TTL_S or sid not in _index:
        if now - _index_at > 30.0:         # 없는 sid 때문에 매 틱(5초) 전체를 다시 훑지 않게 — 루프보다 확실히 길게
            idx = {}
            for p in glob.glob(str(_desktop_dir() / "**" / "local_*.json"), recursive=True):
                s = str(_read(p).get("cliSessionId") or "")
                if s:
                    idx[s] = p
            _index, _index_at = idx, now
    return _index.get(sid, "")


def desktop_focus(sid: str, now: float | None = None) -> tuple:
    """(데스크톱이 이 대화를 마지막으로 연 시각(초), 다리로 붙어 있나). 기록이 없으면 (0, False).

    **다리(bridgeSessionIds)** = 데스크톱이 marina 가 띄운 CLI 에 원격 제어로 붙어 그 프로세스로 쓰는 중.
    그땐 경쟁이 아니다 — 여기서 놓으면 오히려 데스크톱이 쓰던 프로세스가 죽는다(실측 2026-09-23: 데스크톱이
    막힌 대화는 다리가 없고, 데스크톱으로 잘 쓰던 대화는 다리가 있었다)."""
    path = _focus_path(sid, time.time() if now is None else now)
    if not path:
        return 0.0, False
    rec = _read(path)
    bridged = bool(rec.get("bridgeSessionIds"))
    v = rec.get("lastFocusedAt")
    if not isinstance(v, (int, float)) or v <= 0:
        return 0.0, bridged
    return (v / 1000.0 if v > 1e12 else float(v)), bridged


def _status(sid: str, root: str) -> str:
    """대시보드가 보여주는 것과 **같은 판정**을 쓴다 — 따로 만들면 화면은 쉬는데 여기선 일한다고 갈린다."""
    import marina_sessions as ms
    from marina_agent_events import latest_agent_event
    r = Path(root)
    jpath = ms.CLAUDE_PROJECTS_DIR / ms._claude_project_slug(r) / f"{sid}.jsonl"
    if not jpath.is_file():
        return "unknown"
    native = ms._native_agent_status(jpath, "claude")
    event = latest_agent_event("claude", sid, r.resolve(), home=Path.home())
    got = ms.resolve_session_liveness("claude", sid, r.resolve(), native=native, event=event,
                                      live_cwds=ms._live_agent_cwds(), live_tids=ms._live_agent_tids())
    return str(got.get("status") or "unknown")


def tick(now: float | None = None, *, kill=None, status=None) -> list:
    """한 번 훑는다. 놓아 준 (tid, sid) 목록을 돌려준다. kill·status 는 테스트용 주입점."""
    if not enabled():
        return []
    import marina_term as mt
    now = time.time() if now is None else now
    kill = kill or mt.term_kill
    status = status or _status
    with mt._lock:
        held = [t for t in mt._by_tid.values()
                if t.alive and (t.agent or {}).get("source") == "claude" and (t.agent or {}).get("sid")]
    released = []
    for term in held:
        sid = term.agent["sid"]
        taken = max(float(term.created or 0), float(getattr(term, "last_input", 0) or 0))
        focus, bridged = desktop_focus(sid, now)
        if bridged:
            continue                       # 데스크톱이 이 프로세스에 붙어서 쓰는 중 — 놓으면 끊긴다
        if not focus or focus <= taken + _MARGIN_S:
            continue                       # 데스크톱이 marina 보다 나중에 연 적이 없다
        st = status(sid, term.root)
        if st in _BUSY or st == "unknown":
            continue                       # 일하는 중·질문 대기·판정 불가 — 끊지 않는다. 다음 틱에
        try:
            kill(term.tid)
            released.append((term.tid, sid))
            _log(f"released {sid[:8]} → desktop (focus {time.strftime('%H:%M:%S', time.localtime(focus))}, status {st})")
        except Exception as exc:
            _log(f"release failed {sid[:8]}: {exc}")
    return released


def _log(line: str) -> None:
    try:
        from marina_state import MARINA_HOME
        with open(MARINA_HOME / "handoff.log", "a", encoding="utf-8") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except Exception:
        pass
