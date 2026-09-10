"""묶음 — 역할 방 한 왕복 묶음의 장부·상태기계·결과 파서·흐름 항목.

스펙: docs/superpowers/specs/2026-09-10-role-rooms-chain-design.md 5·6·7절.
이 모듈은 **부수효과가 없다**(파일 IO 함수 제외). 역할 방을 띄우거나 끄는 일은 marina_chain_runtime 이 한다.
"""
from __future__ import annotations

import copy
import json
import os
import re
import time
from pathlib import Path
from typing import Any

from marina_state import MARINA_HOME

CHAINS_DIR = MARINA_HOME / "chains"
BASELINE_DIR = CHAINS_DIR / "_baseline"
WAIT_TIMEOUT_S = 1800.0
TERMINAL = {"done", "stopped"}
_CHAIN_ID_RE = re.compile(r"c-[0-9]{8}-[0-9]{6}-[a-z0-9-]{1,40}-[A-Za-z0-9]{1,16}")


def new_chain(*, role: str, implementer: dict[str, Any], base: dict[str, str], head: dict[str, str],
              max_rounds: int, unlimited: bool, now: float, anchor: int) -> dict[str, Any]:
    sid_part = re.sub(r"[^A-Za-z0-9]", "", str(implementer.get("sid") or ""))[:8] or "x"
    chain_id = "c-" + time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + f"-{role}-{sid_part}"
    return {
        "id": chain_id, "role": role, "implementer": dict(implementer), "roleRoom": {},
        "base": dict(base), "reviewedHead": dict(head),
        "round": 1, "maxRounds": int(max_rounds), "unlimited": bool(unlimited),
        "state": "reviewing", "held": [],
        "rounds": [{"n": 1, "head": dict(head), "sentAt": now, "sentAnchor": int(anchor),
                    "resultAt": None, "findings": None, "noneLeft": None}],
        "createdAt": now, "updatedAt": now, "endedAt": None, "endedAnchor": None, "endedReason": None,
    }


def head_advanced(prev: dict[str, str], cur: dict[str, str]) -> bool:
    """저장소 중 하나라도 HEAD 가 달라졌나(새 저장소가 생긴 것도 포함). 빈 값은 '모름'이라 앞선 것으로 안 본다."""
    return any(sha and prev.get(name) != sha for name, sha in (cur or {}).items())


def _end(chain: dict[str, Any], reason: str, now: float, anchor: Any) -> tuple[dict[str, Any], list[dict]]:
    chain["state"] = "done" if reason != "stopped" else "stopped"
    chain["endedReason"] = reason
    chain["endedAt"] = now
    chain["endedAnchor"] = anchor
    return chain, [{"do": "kill_role"}]


def _start_round(chain: dict[str, Any], head: dict[str, str], now: float, anchor: int) -> tuple[dict, list[dict]]:
    base = dict(chain["reviewedHead"])
    chain["round"] += 1
    chain["base"] = base
    chain["reviewedHead"] = dict(head)
    chain.pop("pendingHead", None)
    chain.pop("waitingSince", None)
    chain.pop("nudged", None)
    chain["state"] = "reviewing"
    chain["rounds"].append({"n": chain["round"], "head": dict(head), "sentAt": now, "sentAnchor": int(anchor),
                            "resultAt": None, "findings": None, "noneLeft": None})
    return chain, [{"do": "request_round", "round": chain["round"], "base": base, "head": dict(head)}]


def next_state(chain: dict[str, Any], event: dict[str, Any], now: float) -> tuple[dict[str, Any], list[dict]]:
    """순수 전이(스펙 5.2). 입력을 바꾸지 않고 새 dict 를 돌려준다."""
    if chain.get("state") in TERMINAL:
        return chain, []
    c = copy.deepcopy(chain)
    c["updatedAt"] = now
    kind = event.get("type")
    state = c["state"]

    if kind == "stop":
        return _end(c, "stopped", now, event.get("anchor"))
    if kind == "implementer_gone":
        return _end(c, "implementer-gone", now, event.get("anchor"))
    if kind == "unlimited":
        c["unlimited"] = bool(event.get("on"))
        return c, []

    if kind == "result" and state == "reviewing":
        cur = c["rounds"][-1]
        cur.update({"resultAt": now, "findings": int(event.get("findings") or 0),
                    "noneLeft": bool(event.get("noneLeft"))})
        for line in event.get("held") or []:
            if line not in c["held"]:
                c["held"].append(line)
        if event.get("noneLeft"):
            return _end(c, "clean", now, event.get("anchor"))
        c["state"] = "applying"
        return c, []

    if kind == "no_result" and state == "reviewing":
        if not c.get("nudged"):
            c["nudged"] = True
            return c, [{"do": "nudge_role"}]
        return _end(c, "no-result", now, event.get("anchor"))

    if kind == "implementer_turn_end":
        head = dict(event.get("head") or {})
        if state == "reviewing":
            if head_advanced(c.get("pendingHead") or c["reviewedHead"], head):
                c["pendingHead"] = head
            return c, []
        if state in ("applying", "waiting"):
            target = head if head_advanced(c["reviewedHead"], head) else (c.get("pendingHead") or {})
            if target and head_advanced(c["reviewedHead"], target):
                if c["unlimited"] or c["round"] < c["maxRounds"]:
                    return _start_round(c, target, now, int(event.get("anchor") or 0))
                return _end(c, "max-rounds", now, event.get("anchor"))
            if state == "applying":
                c["state"] = "waiting"
                c["waitingSince"] = now
            return c, []

    if kind == "tick" and state == "waiting":
        if now - float(c.get("waitingSince") or now) >= WAIT_TIMEOUT_S:
            return _end(c, "wait-timeout", now, None)
        return chain, []

    return chain, []


def _chain_path(chain_id: str) -> Path | None:
    if not _CHAIN_ID_RE.fullmatch(chain_id or ""):
        return None
    return CHAINS_DIR / f"{chain_id}.json"


def save_chain(chain: dict[str, Any]) -> None:
    path = _chain_path(str(chain.get("id") or ""))
    if path is None:
        raise ValueError("잘못된 묶음 id")
    CHAINS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(chain, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def load_chain(chain_id: str) -> dict[str, Any] | None:
    path = _chain_path(chain_id)
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def list_chains() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    try:
        files = sorted(CHAINS_DIR.glob("c-*.json"))
    except OSError:
        return out
    for f in files:
        chain = load_chain(f.stem)
        if chain:
            out.append(chain)
    return out


def _mine(chain: dict[str, Any], source: str, sid: str, role: str) -> bool:
    imp = chain.get("implementer") or {}
    return imp.get("source") == source and imp.get("sid") == sid and chain.get("role") == role


def open_chain_for(source: str, sid: str, role: str) -> dict[str, Any] | None:
    for chain in reversed(list_chains()):
        if _mine(chain, source, sid, role) and chain.get("state") not in TERMINAL:
            return chain
    return None


def last_chain_for(source: str, sid: str, role: str) -> dict[str, Any] | None:
    mine = [c for c in list_chains() if _mine(c, source, sid, role)]
    return max(mine, key=lambda c: float(c.get("updatedAt") or 0)) if mine else None
