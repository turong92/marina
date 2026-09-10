"""묶음 부수효과 층 — 역할 방 띄우기·입력·끄기, 트리거. 규칙은 marina_chains(순수)에 있다.

모듈 전역 `_term_open` 등은 테스트가 갈아끼우는 이음새다. 실제 구현은 아래 기본값이다.
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any

import marina_chains as C
from marina_roles import contract_prompt, load_role, role_cli

ROLE = "reviewer"
DEFAULT_MAX_ROUNDS = 2
_lock = threading.RLock()


def _term_open(root: Path, *args: Any, **kwargs: Any) -> dict[str, Any]:
    from marina_term import term_open
    return term_open(root, *args, **kwargs)


def _term_kill(tid: str) -> None:
    from marina_term import term_kill
    try:
        term_kill(tid)
    except Exception:
        pass


def _deliver(tid: str, text: str) -> None:
    from marina_mobile import _deliver_agent_input
    _deliver_agent_input(tid, "claude", text)      # detached·죽은 PTY 면 ValueError


def _repo_heads(root: Path) -> dict[str, str]:
    return C.repo_heads(root)


def _transcript_size(root: Path, source: str, sid: str) -> int:
    from marina_sessions import agent_transcript_path
    try:
        return int(agent_transcript_path(root, source, sid).stat().st_size)
    except Exception:
        return 0


def _socket_for(sid: str) -> str:
    """~/.claude/sessions/<pid>.json 에서 그 세션의 메시지 소켓. 이름은 바뀌니 소켓을 쓴다."""
    for f in (Path.home() / ".claude" / "sessions").glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("sessionId") == sid and data.get("messagingSocketPath"):
            return "uds:" + str(data["messagingSocketPath"])
    return ""


def _role_settings(root: Path) -> dict[str, Any] | None:
    from marina_registry import project_for
    project = project_for(Path(root)) or {}
    settings = (project.get("roles") or {}).get(ROLE)
    return settings if isinstance(settings, dict) else None


def _claude_sessions_dir() -> Path:
    return Path.home() / ".claude" / "sessions"


def _role_term(chain: dict[str, Any]) -> dict[str, Any] | None:
    tid = (chain.get("roleRoom") or {}).get("tid")
    if not tid:
        return None
    try:
        from marina_term import term_list
        for item in term_list().get("sessions", []):
            if item.get("tid") == tid:
                return item
    except Exception:
        pass
    return None


def _term_sid(item: dict[str, Any]) -> str:
    """term 의 Claude sid. 훅 입양은 데몬 레지스트리만 채우므로, 없으면 Claude 가 pid 이름으로 쓰는 세션 파일을 본다
    (term 은 셸이 exec 로 claude 가 되므로 term pid 가 곧 claude pid)."""
    sid = str((item.get("agent") or {}).get("sid") or "")
    if sid or not item.get("pid"):
        return sid
    try:
        data = json.loads((_claude_sessions_dir() / f"{int(item['pid'])}.json").read_text(encoding="utf-8"))
        return str(data.get("sessionId") or "")
    except (OSError, ValueError, TypeError):
        return ""


def _role_transcript(chain: dict[str, Any]) -> Path | None:
    from marina_sessions import agent_transcript_path
    item = _role_term(chain)
    sid = _term_sid(item) if item else ""
    if not sid:
        return None
    chain.setdefault("roleRoom", {})["sid"] = sid
    try:
        return agent_transcript_path(Path(item.get("root") or ""), "claude", sid)
    except Exception:
        return None


def _baseline_path(source: str, sid: str) -> Path:
    return C.BASELINE_DIR / f"{source}-{''.join(ch for ch in sid if ch.isalnum() or ch == '-')}.json"


def _baseline(source: str, sid: str) -> dict[str, str] | None:
    last = C.last_chain_for(source, sid, ROLE)
    if last:
        return dict(last.get("reviewedHead") or {})
    try:
        return json.loads(_baseline_path(source, sid).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _save_baseline(source: str, sid: str, heads: dict[str, str]) -> None:
    path = _baseline_path(source, sid)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(heads), encoding="utf-8")


def _summary(chain: dict[str, Any]) -> str:
    parts = [f"{r['n']}바퀴: 지적 {r.get('findings') or 0}건" for r in chain.get("rounds") or [] if r.get("resultAt")]
    if chain.get("held"):
        parts.append("보류: " + " / ".join(chain["held"]))
    return "\n".join(parts)


def _launch(chain: dict[str, Any], root: Path, base: dict[str, str], head: dict[str, str], previous: str = "") -> dict:
    defn = load_role(root, ROLE)
    if defn is None:
        raise ValueError("역할 정의를 못 찾았어요: reviewer")
    repos = {name: (base.get(name, "") or head.get(name, ""), sha) for name, sha in head.items()}
    prompt = contract_prompt(role=ROLE, repos=repos, reply_socket=chain["implementer"]["socket"],
                             round_no=chain["round"], unlimited=chain["unlimited"], previous=previous)
    res = _term_open(root, 80, 24, agent_source="claude", agent_sid="", agent_prompt=prompt,
                     agent_role=ROLE, agent_role_argv=role_cli(defn, prompt), agent_role_launch=role_cli(defn, ""))
    chain["roleRoom"] = {"tid": str(res.get("tid") or ""), "model": str(defn.get("model") or "")}
    chain["rounds"][-1]["roleAnchor"] = 0
    return chain


def _run_actions(chain: dict[str, Any], actions: list[dict], root: Path) -> dict[str, Any]:
    tid = (chain.get("roleRoom") or {}).get("tid") or ""
    for action in actions:
        if action["do"] == "kill_role" and tid:
            _term_kill(tid)
        elif action["do"] == "request_round":
            repos = {name: (action["base"].get(name, ""), sha) for name, sha in action["head"].items()}
            prompt = contract_prompt(role=ROLE, repos=repos, reply_socket=chain["implementer"]["socket"],
                                     round_no=action["round"], unlimited=chain["unlimited"])
            path = _role_transcript(chain)
            chain["rounds"][-1]["roleAnchor"] = int(path.stat().st_size) if path and path.exists() else 0
            try:
                _deliver(tid, prompt)
            except Exception:
                # 재시작 뒤 detached 거나 죽었다 — 새로 띄우고 지난 바퀴를 싣는다(스펙 5.5)
                _launch(chain, root, action["base"], action["head"], previous=_summary(chain))
        elif action["do"] == "nudge_role" and tid:
            try:
                _deliver(tid, f'결과를 SendMessage 로 보내 — to 는 정확히 "{chain["implementer"]["socket"]}"')
            except Exception:
                pass
    return chain


def apply_event(chain: dict[str, Any], event: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    with _lock:
        new, actions = C.next_state(chain, event, now)
        new = _run_actions(new, actions, Path(new["implementer"]["root"]))
        C.save_chain(new)
        return new


def chain_trigger(root: Path, source: str, sid: str, reason: str, force: bool = False,
                  now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    if source != "claude":
        return {"ok": False, "reason": "off"}
    settings = _role_settings(root)
    if settings is None and not force:
        return {"ok": False, "reason": "off"}
    settings = settings or {}
    with _lock:
        heads = _repo_heads(root)
        open_chain = C.open_chain_for(source, sid, ROLE)
        if open_chain:
            if open_chain["state"] == "reviewing" and not C.head_advanced(open_chain["reviewedHead"], heads):
                return {"ok": False, "reason": "in-progress", "chain": open_chain["id"]}
            chain = on_implementer_turn_end(open_chain, root, now=now)
            return {"ok": True, "started": False, "chain": chain["id"], "state": chain["state"]}
        base = _baseline(source, sid)
        if base is None and not force:
            _save_baseline(source, sid, heads)
            return {"ok": False, "reason": "baseline"}
        if not force and not C.head_advanced(base or {}, heads):
            return {"ok": False, "reason": "no-commit"}
        implementer = {"root": str(root), "source": source, "sid": sid, "socket": _socket_for(sid)}
        if not implementer["socket"]:
            return {"ok": False, "reason": "no-socket"}
        chain = C.new_chain(role=ROLE, implementer=implementer, base=base or heads, head=heads,
                            max_rounds=int(settings.get("maxRounds") or DEFAULT_MAX_ROUNDS), unlimited=False,
                            now=now, anchor=_transcript_size(root, source, sid))
        chain = _launch(chain, root, base or heads, heads)
        C.save_chain(chain)
        return {"ok": True, "started": True, "chain": chain["id"], "reason": reason}


def on_implementer_turn_end(chain: dict[str, Any], root: Path, now: float | None = None,
                            force_round: bool = False) -> dict[str, Any]:
    event = {"type": "implementer_turn_end", "head": _repo_heads(root),
             "anchor": _transcript_size(root, chain["implementer"]["source"], chain["implementer"]["sid"])}
    return apply_event(chain, event, now)


def on_role_turn_end(chain: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    path = _role_transcript(chain)
    rows = C.read_rows(path, int(chain["rounds"][-1].get("roleAnchor") or 0)) if path else []
    result = C.parse_role_result(rows, chain["implementer"]["socket"])
    imp = chain["implementer"]
    anchor = _transcript_size(Path(imp["root"]), imp["source"], imp["sid"])
    if result is None:
        return apply_event(chain, {"type": "no_result", "anchor": anchor}, now)
    return apply_event(chain, {"type": "result", "noneLeft": result["noneLeft"], "findings": result["findings"],
                               "held": result["held"], "anchor": anchor}, now)


def set_unlimited(source: str, sid: str, on: bool) -> dict[str, Any]:
    chain = C.open_chain_for(source, sid, ROLE)
    if not chain:
        return {"ok": False, "reason": "no-chain"}
    return {"ok": True, **apply_event(chain, {"type": "unlimited", "on": on})}


def stop_chain(source: str, sid: str) -> dict[str, Any]:
    chain = C.open_chain_for(source, sid, ROLE)
    if not chain:
        return {"ok": False, "reason": "no-chain"}
    imp = chain["implementer"]
    anchor = _transcript_size(Path(imp["root"]), imp["source"], imp["sid"])
    return {"ok": True, **apply_event(chain, {"type": "stop", "anchor": anchor})}


# ── 감시층 사건(스펙 6.1) ────────────────────────────────────────────────────────────
import queue as _queue

_last_status: dict[str, str] = {}
_events_q: "_queue.Queue[list[dict]]" = _queue.Queue()
_worker_started = False


def _role_sid_to_chain(sid: str) -> dict[str, Any] | None:
    for chain in C.list_chains():
        if chain.get("state") in C.TERMINAL:
            continue
        if sid and role_room_sid(chain) == sid:
            return chain
    return None


def on_events(events: list[dict[str, Any]], now: float | None = None) -> list[str]:
    done: list[str] = []
    for event in events or []:
        if event.get("source") != "claude" or not event.get("sid"):
            continue
        ended = C.turn_ended(event, _last_status)
        C.remember_status(event, _last_status)
        if not ended:
            continue
        sid = str(event["sid"])
        role_chain = _role_sid_to_chain(sid)
        if role_chain is not None:
            on_role_turn_end(role_chain, now=now)
            done.append(f"role:{role_chain['id']}")
            continue
        open_chain = C.open_chain_for("claude", sid, ROLE)
        root = Path(str(event.get("root") or ""))
        if open_chain is not None:
            on_implementer_turn_end(open_chain, root, now=now)
            done.append(f"impl:{open_chain['id']}")
            continue
        settings = _role_settings(root)
        if settings and settings.get("on") == "commit":
            chain_trigger(root, "claude", sid, "commit", now=now)
            done.append(f"trigger:{sid}")
    tick_all(now)
    return done


def tick_all(now: float | None = None) -> None:
    for chain in C.list_chains():
        if chain.get("state") == "waiting":
            apply_event(chain, {"type": "tick"}, now)


def _worker() -> None:
    while True:
        batch = _events_q.get()
        try:
            on_events(batch)
        except Exception:
            pass           # 묶음이 망가져도 감시 루프·알림은 계속 돈다


def submit_events(events: list[dict[str, Any]]) -> None:
    """감시 스레드를 막지 않는다 — git·프로세스 띄우기는 작업 스레드에서."""
    global _worker_started
    if not events:
        return
    with _lock:
        if not _worker_started:
            threading.Thread(target=_worker, daemon=True, name="marina-chains").start()
            _worker_started = True
    _events_q.put(list(events))


# ── 호출자 확인(스펙 6.3) ────────────────────────────────────────────────────────────
def _belongs(root: Path, source: str, sid: str) -> bool:
    from marina_sessions import agent_belongs_to_root
    return bool(agent_belongs_to_root(root, source, sid))


def _proc_start_utc(pid: int) -> str:
    """Claude 세션 파일의 procStart 는 UTC asctime 이다. ps lstart 는 로컬 시각이라 TZ=UTC 로 맞춘다."""
    import os
    import subprocess
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(int(pid))], check=False, capture_output=True,
                             text=True, timeout=1, env={**os.environ, "TZ": "UTC"})
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""


def verify_caller(pid: int, sid: str, cwd: str, sessions_dir: Path | None = None, pid_start=None) -> dict | None:
    """pid 의 세션 파일이 sid 와 맞고, procStart 가 지금 그 pid 와 맞고(재사용 방지), sid 가 cwd 의 워크트리에 속할 때만."""
    import subprocess
    sessions_dir = sessions_dir or (Path.home() / ".claude" / "sessions")
    if pid_start is None:
        pid_start = _proc_start_utc
    try:
        data = json.loads((sessions_dir / f"{int(pid)}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    if data.get("sessionId") != sid:
        return None
    recorded = str(data.get("procStart") or "")
    if recorded and pid_start(int(pid)) != recorded:
        return None
    try:
        top = subprocess.check_output(["git", "-C", cwd, "rev-parse", "--show-toplevel"], text=True,
                                      stderr=subprocess.DEVNULL, timeout=5.0).strip()
    except Exception:
        return None
    root = Path(top).resolve()
    if not _belongs(root, "claude", sid):
        return None
    return {"root": root, "sid": sid}


def role_room_sid(chain: dict[str, Any]) -> str:
    """역할 방의 sid. 결과가 오기 전엔 장부에 없어서(저장은 사건 처리 때) term 기록의 tid 로 찾는다 — 읽기만."""
    room = chain.get("roleRoom") or {}
    if room.get("sid"):
        return str(room["sid"])
    item = _role_term(chain)
    return _term_sid(item) if item else ""
