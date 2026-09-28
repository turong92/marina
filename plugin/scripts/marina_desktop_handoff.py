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


# ── 반대 방향: marina 가 만든 대화를 데스크톱 목록에 올린다 ────────────────────────────────
# 데스크톱 앱은 **자기가 만든 대화만** 목록에 보여준다. 다만 CLI 대화를 입양하는 장치가 이미 있다 —
# `adoptedFromOtherSurface: true` 기록(9/9 에 앱이 25건을 한 번에 입양). 앱이 쓴 그 모양 그대로 써 주면
# 앱이 받아들이고 자기 필드를 채워 정식 대화로 편입한다(실측 2026-09-24: 733B → 62KB, 클릭·인계까지 확인).
# 제약: 앱은 **켜질 때만** 폴더를 읽는다 — 켜 있는 동안 쓴 건 다음 실행에 보인다(지우지는 않는다, 실측).
_adopted: set = set()               # 이번 데몬 수명에서 이미 판단한 sid — 같은 걸 매 틱 다시 보지 않게


_account_cache: tuple = (-1e18, None)   # (잰 시각, 폴더) — 없음(None)도 캐시한다


def _account_dir(now: float):
    """기록이 사는 폴더(계정/조직 두 단계). 가장 최근에 바뀐 기록의 폴더를 쓴다.
    계정이 여럿이면 **데스크톱 앱에 지금 로그인한 쪽**이 그 폴더다 — 앱은 대화를 클릭만 해도 lastFocusedAt 을
    찍으므로 가장 최근에 바뀐다. 입양 기록은 그 계정 목록에만 보이니 거기 써야 맞다(다른 계정은 어차피 안 보인다).
    파일 수백 개를 훑으므로 5초 루프에서 매번 돌지 않게 30초 캐시한다(리뷰 지적)."""
    global _account_cache
    at, cached = _account_cache
    if now - at < 30.0:
        return cached
    newest, best = 0.0, None
    for p in glob.glob(str(_desktop_dir() / "*" / "*" / "local_*.json")):
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        if m > newest:
            newest, best = m, Path(p).parent
    _account_cache = (now, best)
    return best


def _desktop_lineages(cwd: str) -> set:
    """같은 cwd 에 이미 있는 데스크톱 대화들의 혈통. resume 으로 sid 만 바뀐 같은 대화를 또 올리면
    데스크톱 목록에 두 줄이 생긴다(marina 목록에서 혈통으로 접은 것과 같은 문제)."""
    import marina_sessions as ms
    out = set()
    slug_dir = ms.CLAUDE_PROJECTS_DIR / ms._claude_project_slug(Path(cwd))
    for sid, path in list(_index.items()):
        rec = _read(path)
        if rec.get("cwd") != cwd:
            continue
        lin = ms._read_transcript_lineage(slug_dir / f"{sid}.jsonl")
        if lin:
            out.add(lin)
    return out


def adoption_record(sid: str, transcript: Path, now_ms: int):
    """데스크톱 앱이 CLI 대화를 입양할 때 쓰는 모양 그대로(필드·값 모두 앱이 쓴 기록에서 복사). 못 만들면 None."""
    import datetime
    import marina_sessions as ms
    cwd = ms._read_transcript_cwd(transcript)
    if not cwd:
        return None
    first, model = None, None
    budget = 2 * 1024 * 1024                # 5초 루프 안에서 도는 함수 — 수십 MB 대화를 통째로 읽지 않는다(리뷰 지적)
    try:
        with transcript.open(encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                budget -= len(line)
                if i >= 400 or budget < 0:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                if first is None and isinstance(o.get("timestamp"), str):
                    first = o["timestamp"]
                msg = o.get("message")
                m = msg.get("model") if isinstance(msg, dict) else None
                if isinstance(m, str) and m and not m.startswith("<"):
                    model = m
    except OSError:
        return None
    try:
        created = int(datetime.datetime.fromisoformat(first.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        created = int(transcript.stat().st_mtime * 1000)
    rec = {"sessionId": "local_" + sid, "cliSessionId": sid, "cwd": cwd, "originCwd": cwd,
           "createdAt": created, "lastActivityAt": int(transcript.stat().st_mtime * 1000),
           "isArchived": False, "title": ms._read_transcript_title(transcript) or sid[:8],
           "titleSource": "auto", "permissionMode": "auto",
           "chromePermissionMode": "skip_all_permission_checks", "indexedAt": now_ms,
           "alwaysAllowedReasons": [], "sessionPermissionUpdates": [], "adoptedFromOtherSurface": True}
    if model:
        rec["model"] = model
    return rec


def adopt_missing(held, now: float, *, write=None) -> list:
    """marina 가 쥔 대화 중 데스크톱 기록이 없는 것을 입양시킨다. 쓴 sid 목록."""
    import tempfile
    import marina_sessions as ms
    written = []
    # `_adopted` 에는 **다시 볼 필요가 없을 때만** 넣는다(썼다·이미 있다·같은 대화가 있다). 계정 폴더가 아직
    # 없거나 쓰기가 실패한 건 다음 틱에 다시 — 먼저 넣어 두면 데스크톱 앱을 처음 켜기 전에 쥔 대화나
    # 일시적 I/O 실패가 데몬 수명 내내 영영 입양되지 않는다(리뷰 지적).
    pending = [t for t in held if t.agent["sid"] not in _adopted]
    if not pending:
        return written
    folder = _account_dir(now)
    if folder is None:
        return written                     # 데스크톱 앱을 아직 안 쓴 맥 — 폴더가 생기면 그때
    for term in pending:
        sid = term.agent["sid"]
        if _focus_path(sid, now):
            _adopted.add(sid)              # 이미 데스크톱에 있다
            continue
        transcript = ms.CLAUDE_PROJECTS_DIR / ms._claude_project_slug(Path(term.root)) / f"{sid}.jsonl"
        if not transcript.is_file():
            continue                       # 아직 첫 말 전 — 기록이 생기면 다음 틱에
        rec = adoption_record(sid, transcript, int(now * 1000))
        if rec is None:
            continue
        lin = ms._read_transcript_lineage(transcript)
        if lin and lin in _desktop_lineages(rec["cwd"]):
            _adopted.add(sid)
            _log(f"skip adopt {sid[:8]} — same conversation already on desktop (lineage {lin[:8]})")
            continue
        target = folder / f"local_{sid}.json"
        if target.exists():
            _adopted.add(sid)
            continue
        try:
            if write is not None:
                write(target, rec)
            else:
                fd, tmp = tempfile.mkstemp(dir=str(folder), prefix=".marina-")
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as f:
                        json.dump(rec, f, ensure_ascii=False, indent=2)
                    os.replace(tmp, str(target))   # 원자 교체 — 앱이 반쪽 파일을 읽지 않게
                except BaseException:
                    Path(tmp).unlink(missing_ok=True)
                    raise
        except Exception as exc:
            _log(f"adopt write failed {sid[:8]}: {exc!r} — retry next tick")
            continue
        _adopted.add(sid)
        written.append(sid)
        _log(f"adopted {sid[:8]} → {folder.parent.name[:8]}/{folder.name[:8]} (visible after next app launch)")
    return written


def tick(now: float | None = None, *, kill=None, status=None, write=None) -> list:
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
    try:
        adopt_missing(held, now, write=write)
    except Exception as exc:
        _log(f"adopt failed: {exc!r}")
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
