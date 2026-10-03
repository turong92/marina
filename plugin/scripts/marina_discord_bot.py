"""마리나 Discord 봇 1단계 — 🛑 정지 · #상태 대시보드 · 주간 숫자판 · 작업 중 '입력 중…'.

discord.json 이 있을 때만 마리나 데몬이 run_forever 를 돌린다(선택 기능). 판단·그리기는 전부 여기(파이썬)에 두고,
봇(marina-discord-bot/bot.ts, bun)은 반응 이벤트를 받아 `interrupt` 를 부르는 일만 한다 — 로직을 두 언어로 나누지 않는다.
설계: docs/superpowers/specs/2026-10-02-marina-discord-bot-design.md
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import marina_session as ms

_MANAGE = 1 << 4
_SEND = 1 << 11
_HISTORY = 1 << 16
TYPING_EVERY = 8.0       # Discord '입력 중…' 은 10초면 꺼진다
BUSY_EVERY = 30.0        # 작업 중일 때만 대시보드를 이 간격으로 다시 그린다
WEEKLY_EVERY = 600.0     # 채널 이름 변경은 10분 2회 제한
USAGE_TTL = 120.0
DASHBOARD_NAME = "상태"
BOT_DIR = Path(__file__).resolve().parent / "marina-discord-bot"

mark_dirty = ms.dashboard_signal


def dirty_mtime() -> float:
    try:
        return ms.dashboard_signal_path().stat().st_mtime
    except OSError:
        return 0.0


def should_render(now: float, last: float, dirty: float, busy: bool) -> bool:
    """신호(턴 시작·끝, 세션 켜짐·꺼짐)는 바로, 작업 중이면 30초마다. 쉬는 동안엔 안 그린다(늦게 바뀌는 표시 금지)."""
    return dirty > last or (busy and now - last >= BUSY_EVERY)


# ── 상태 저장(~/.marina/discord-bot.json) ───────────────────────────────────

def _state_path() -> Path:
    return ms.marina_home() / "discord-bot.json"


def _load_state() -> dict[str, Any]:
    try:
        d = json.loads(_state_path().read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_section(key: str, val: dict[str, Any]) -> None:
    d = _load_state()
    d[key] = val
    ms._write_json(_state_path(), d)


# ── 수집 ────────────────────────────────────────────────────────────────────

def owner_ids(cfg: dict[str, Any]) -> list[str]:
    """형 = 개발 프로젝트(chat 제외)의 allow 목록."""
    out: list[str] = []
    for name, pc in (cfg.get("projects") or {}).items():
        if name == ms.CHAT_PROJECT or not isinstance(pc, dict):
            continue
        for u in pc.get("allow") or []:
            if str(u) not in out:
                out.append(str(u))
    return out


def claude_usage() -> list[dict[str, Any]]:
    try:
        import marina_sessions
        return list(marina_sessions.provider_account_usage("claude").get("windows") or [])
    except Exception:
        return []


_usage_cache: dict[str, Any] = {"at": 0.0, "val": []}


def _usage() -> list[dict[str, Any]]:
    now = time.time()
    if now - _usage_cache["at"] > USAGE_TTL:
        _usage_cache.update(at=now, val=claude_usage())
    return _usage_cache["val"]


_SPINNER = re.compile(r"^\S\s+\S.*…\s*\((?:\d|esc to interrupt)")


def _pane_busy(name: str) -> tuple[bool, bool]:
    """(켜짐, 작업 중). 작업 중 = 입력창(❯) 바로 위에 돌아가는 표시 줄('✢ Schlepping… (5m 41s · …)')이 있음.
    화면 전체를 찾으면 대화 내용에 같은 글자가 있을 때 틀린다 — 입력창 바로 위 블록만 본다(실측)."""
    if not ms.tmux_alive(name):
        return False, False
    lines = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()
    box = max((i for i, l in enumerate(lines) if l.startswith("❯")), default=-1)
    # 입력창 위로 올라가며 빈 줄·구분선·들여쓴 줄(⎿ 팁·할 일 목록 등, 길이 무관)을 건너뛴 첫 줄이 표시 줄이다(리뷰 M1)
    for line in reversed(lines[:max(box, 0)]):
        if not line.strip() or line.lstrip().startswith(("─", "←")) or line[:1].isspace():
            continue                          # '← discord · …' = 막 받은 메시지 알림 줄(실사용: 이걸 표시 줄로 봐서 일하는 세션을 쉰다고 봄)
        return True, bool(_SPINNER.search(line))
    return True, False


def _ctx_percent(rec: dict[str, Any]) -> float | None:
    sid = str(rec.get("sessionId") or "")
    path = ms.find_transcript(sid) if sid else None
    if not path:
        return None
    try:
        import marina_sessions
        return marina_sessions.agent_usage_from_path(path, "claude").get("contextPercent")
    except Exception:
        return None


_BG_SHELL = re.compile(r"Command running in background with ID: (\w+)")
_BG_AGENT = re.compile(r"agentId: (\w+)")
_BG_MOVED = re.compile(r"moved to the background \(ID: (\w+)\)")   # 시간 초과로 하네스가 백그라운드로 옮긴 명령(실측)
_TASK_DONE = re.compile(r"<task-id>(\w+)</task-id>.*?<status>(\w+)</status>", re.S)


def _texts(content: Any) -> list[str]:
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [str(b.get("text") or "") for b in content if isinstance(b, dict)]
    return []


def background_tasks(transcript: Path) -> list[dict[str, Any]]:
    """지금 뒤에서 도는 일(백그라운드 셸·서브에이전트) = 기록에서 시작됨 − 끝남 알림. 기록 끝 2MB 만 본다."""
    started, done = _scan_tasks(transcript)
    return [t for i, t in started.items() if i not in done]


def _scan_tasks(transcript: Path) -> tuple[dict[str, dict[str, Any]], set[str]]:
    try:
        data = transcript.read_bytes()[-2_000_000:].decode("utf-8", "replace")
    except OSError:
        return {}, set()
    descs: dict[str, str] = {}
    bg_use: dict[str, str] = {}          # tool_use_id → 'shell'|'agent' (백그라운드로 띄운 것만, 리뷰 I1)
    started: dict[str, dict[str, Any]] = {}
    done: set[str] = set()
    for raw in data.splitlines():
        if "<task-id>" in raw:
            for m in _TASK_DONE.finditer(raw.replace("\\n", "\n")):
                if m.group(2) != "running":
                    done.add(m.group(1))
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        content = ((row.get("message") or {}) if isinstance(row, dict) else {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and isinstance(b.get("input"), dict):
                descs[str(b.get("id"))] = str(b["input"].get("description") or b.get("name") or "")
                if b["input"].get("run_in_background") and b.get("name") in ("Bash", "Agent", "Task"):
                    bg_use[str(b.get("id"))] = "shell" if b.get("name") == "Bash" else "agent"
                elif b.get("name") == "Bash":
                    bg_use[str(b.get("id"))] = "moved"
                if b.get("name") in ("TaskStop", "KillShell", "KillBash"):    # 손으로 끈 건 알림이 없다(실측)
                    done.add(str(b["input"].get("task_id") or b["input"].get("shell_id") or b["input"].get("bash_id") or ""))
            elif b.get("type") == "tool_result":
                # 백그라운드로 띄운 도구의 결과만 — 동기 에이전트 결과·파일 내용 속 같은 글자는 무시(리뷰 I1)
                kind = bg_use.get(str(b.get("tool_use_id")))
                if not kind:
                    continue
                rx = {"shell": _BG_SHELL, "agent": _BG_AGENT, "moved": _BG_MOVED}[kind]
                for t in _texts(b.get("content")):
                    for m in rx.finditer(t):
                        started[m.group(1)] = {"id": m.group(1), "kind": "agent" if kind == "agent" else "shell",
                                               "desc": descs.get(str(b.get("tool_use_id")), "")}
    return started, done


def _task_output(transcript: Path, task_id: str) -> Path | None:
    base = Path(os.environ.get("MARINA_CLAUDE_TMP") or "/private/tmp")
    hits = list(base.glob(f"claude-*/{transcript.parent.name}/{transcript.stem}/tasks/{task_id}.output"))
    return hits[0] if hits else None


def _agent_last_words(transcript: Path, task_id: str) -> str:
    p = transcript.parent / transcript.stem / "subagents" / f"agent-{task_id}.jsonl"
    try:
        lines = p.read_bytes()[-300_000:].decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    for raw in reversed(lines):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if row.get("type") == "assistant":
            t = " ".join(x for x in _texts((row.get("message") or {}).get("content")) if x).strip()
            if t:
                return t
    return ""


_SHELLS = re.compile(r"(?:· |\b)(\d+) shells?\b")


def _pane_shells(name: str) -> int:
    """화면 아래쪽(입력창 근처)에 하네스가 띄우는 'N shell(s)' — 지금 실제로 도는 백그라운드 셸 수."""
    if not ms.tmux_alive(name):
        return 0
    lines = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()
    box = max((i for i, l in enumerate(lines) if l.startswith("❯")), default=-1)
    if box < 0:
        return 0
    # 입력창 바로 위(턴 끝 줄 '… · 1 shell still running')부터 아래 상태 줄까지만 — 대화 본문의 같은 글자는 무시
    near = lines[max(0, box - 4):]
    return max([int(m.group(1)) for ln in near for m in _SHELLS.finditer(ln)] + [0])


def _session_born(name: str) -> float:
    r = ms._tmux("display-message", "-p", "-t", name, "#{session_created}") if name else None
    try:
        return float((r.stdout or "").strip()) if r else 0.0
    except ValueError:
        return 0.0


_TEAM = re.compile(r"^\s*[◯◐◑◒◓●○]\s+(\S+)\s+(.*)$")


def _pane_team(name: str) -> list[dict[str, Any]]:
    """화면 아래 에이전트 목록(⏺ main 아래) = SendMessage 로 맡긴 팀 에이전트(기록엔 백그라운드로 안 남는다, 실사용)."""
    if not name or not ms.tmux_alive(name):
        return []
    lines = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()[-12:]
    try:
        i = next(k for k, l in enumerate(lines) if l.strip() == "⏺ main")
    except StopIteration:
        return []
    out = []
    for l in lines[i + 1:]:
        m = _TEAM.match(l)
        if m:
            out.append({"id": m.group(1), "kind": "agent", "desc": m.group(2).strip()[:80]})
    return out


def live_tasks(rec: dict[str, Any]) -> list[dict[str, Any]]:
    """기록만 믿으면 틀린다 — 재시작으로 죽은 셸은 끝남 알림이 없다(실측). 셸은 화면의 'N shell' 수만큼(최근 것),
    에이전트는 지금 세션이 뜬 뒤 기록이 움직인 것만."""
    tr = _session_transcript(rec)
    if not tr:
        return _pane_team(str(rec.get("tmux") or ""))
    started, done = _scan_tasks(tr)
    tasks = [t for i, t in started.items() if i not in done]
    n = _pane_shells(str(rec.get("tmux") or ""))
    shells = [t for t in tasks if t["kind"] == "shell"]
    keep = {t["id"] for t in (shells[-n:] if n else [])}
    born = _session_born(str(rec.get("tmux") or ""))
    for t in tasks:
        if t["kind"] == "agent":
            # 지금 세션(tmux)이 뜬 뒤에 움직인 에이전트만 — 그 전 것은 재시작으로 죽었다(알림이 안 와 있을 뿐)
            p = tr.parent / tr.stem / "subagents" / f"agent-{t['id']}.jsonl"
            try:
                if p.stat().st_mtime >= born:
                    keep.add(t["id"])
            except OSError:
                pass
    out = [t for t in tasks if t["id"] in keep]
    seen = {t["id"] for t in out}
    out += [t for t in _recent_agents(tr, born) if t["id"] not in seen and t["id"] not in done]
    return out + _pane_team(str(rec.get("tmux") or ""))


AGENT_FRESH = 300.0      # 빌드·긴 도구 호출로 몇 분 조용한 에이전트도 — 끝난 것은 끝남 알림으로 뺀다(리뷰 I2)


def _recent_agents(tr: Path, born: float = 0.0) -> list[dict[str, Any]]:
    """subagents/ 에서 최근 움직인 에이전트 = 도는 중. 띄운 줄이 기록 끝 2MB 밖이거나(긴 세션) 팀·중첩 에이전트라
    agentId 형식이 아니어도 잡힌다(실사용: ovation 19MB 기록, 팀장 에이전트가 띄운 손자 에이전트). 설명은 .meta.json."""
    d = tr.parent / tr.stem / "subagents"
    now, out = time.time(), []
    try:
        files = list(d.glob("agent-*.jsonl"))
    except OSError:
        return []
    for f in files:
        try:
            m = f.stat().st_mtime
        except OSError:
            continue
        if now - m > AGENT_FRESH or m < born:
            continue
        try:
            meta = json.loads(f.with_suffix(".meta.json").read_text())
        except (OSError, ValueError):
            meta = {}
        if not isinstance(meta, dict):
            meta = {}
        out.append({"id": f.stem[len("agent-"):], "kind": "agent", "desc": str(meta.get("description") or meta.get("name") or "")[:80]})
    return out


def _has_recent_agents(rec: dict[str, Any]) -> bool:
    """4초 판정용 — 파일이 사라지는 경합 등으로 루프를 막지 않게 실패는 '없음'(리뷰 I3)."""
    try:
        tr = _session_transcript(rec)
        return bool(tr and _recent_agents(tr, _session_born(str(rec.get("tmux") or ""))))
    except Exception:
        return False


_PERM = re.compile(r"^\s*❯\s*1\.\s")


def _pane_permission(name: str) -> bool:
    """터미널 권한 창(Do you want to proceed? / ❯ 1. Yes)에서 멈춤 — 서브에이전트 것은 PermissionRequest 버튼이 안 와서
    형이 모른 채 '대기'로 보였다(실사용 2026-10-04)."""
    if not name or not ms.tmux_alive(name):
        return False
    lines = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()[-12:]
    return any("Do you want to " in l for l in lines) and any(_PERM.match(l) for l in lines)


def snapshot(full: bool = True) -> dict[str, Any]:
    """full=False: 4초마다 도는 가벼운 판정(작업 중 여부만). ctx·사용량·서버는 그릴 때만."""
    rows = []
    for rec in ms.load_sessions():
        if str(rec.get("kind") or "").endswith("lobby") or not rec.get("channelId"):
            continue
        alive, busy = _pane_busy(str(rec.get("tmux") or ""))
        bg = alive and (_pane_shells(str(rec.get("tmux") or "")) > 0 or bool(_pane_team(str(rec.get("tmux") or "")))
                        or (not busy and _has_recent_agents(rec)))
        act = ms._activity_state(Path(str(rec.get("stateDir") or "/nonexistent")))
        rows.append({"ref": f"{rec.get('project')}/{rec.get('task')}", "channelId": str(rec["channelId"]),
                     "alive": alive, "busy": busy, "bg": bg, "emoji": str(act.get("emoji") or "") if busy else "",
                     "ctx": _ctx_percent(rec) if alive and full else None,
                     "tasks": live_tasks(rec) if alive and full else [],
                     "asking": alive and full and (Path(str(rec.get("stateDir") or "/nonexistent")) / "question.json").exists(),
                     "permission": alive and full and _pane_permission(str(rec.get("tmux") or ""))})
    if not full:
        # 뒤에서 도는 일(셸·팀 에이전트)도 '바쁨'으로 쳐서 #상태를 30초마다 — 끝나면 바로 보이게(입력 중 표시는 busy 만)
        return {"sessions": rows, "anyBusy": any(r["busy"] or r["bg"] for r in rows)}
    try:
        free = shutil.disk_usage(str(Path.home())).free
    except OSError:
        free = 0
    try:
        load = os.getloadavg()[0]
    except OSError:
        load = 0.0
    return {"usage": _usage(), "diskFree": free, "load": load, "sessions": rows,
            "anyBusy": any(r["busy"] for r in rows)}


def _bar(pct: float, width: int = 10) -> str:
    full = max(0, min(width, round(pct / 100 * width)))
    return "█" * full + "░" * (width - full)


COMPONENTS_V2 = 1 << 15
STOP_PREFIX = "marina-stop:"


def _text(content: str) -> dict[str, Any]:
    return {"type": 10, "content": content}


def _row(r: dict[str, Any], proj_w: int) -> str:
    """앞 칸(ctx·프로젝트)은 같은 너비의 고정폭으로 채우고, 길이가 제각각인 채널 링크는 맨 끝 — 세로 줄이 맞는다(형 요청)."""
    c = r.get("ctx")
    ctx = f"{round(c)}%" if isinstance(c, (int, float)) else "-"
    proj = r["ref"].split("/", 1)[0]
    warn = " ⚠" if isinstance(c, (int, float)) and c >= 70 else ""
    return f"`{ctx:>4}  {proj:<{proj_w}}` <#{r['channelId']}>{warn}"


VIEW_PREFIX = "marina-view:"


def _count(cs: list[dict[str, Any]]) -> int:
    return sum(1 + _count(c.get("components") or []) + (1 if c.get("accessory") else 0) for c in cs)


def _tasks_tag(r: dict[str, Any]) -> str:
    t = r.get("tasks") or []
    sh, ag = sum(x["kind"] == "shell" for x in t), sum(x["kind"] == "agent" for x in t)
    return "  " + " ".join(([f"⏳{sh}"] if sh else []) + ([f"🤖{ag}"] if ag else [])) if t else ""


def _tasks_desc(r: dict[str, Any]) -> str:
    """무슨 일인지 한 줄(설명만 — 명령 원문 아님)."""
    t = r.get("tasks") or []
    d = " · ".join(f"{'⏳' if x['kind'] == 'shell' else '🤖'} {_clean(x['desc'] or x['id'])[:50]}" for x in t[:4])
    return f"\n-# {d}" if d else ""


def _view_button(r: dict[str, Any]) -> dict[str, Any]:
    return {"type": 2, "style": 2, "label": "보기", "custom_id": VIEW_PREFIX + r["channelId"]}


def render(snap: dict[str, Any]) -> list[dict[str, Any]]:
    """#상태 메시지(Components V2). 섹션: 작업 중(줄마다 정지 버튼) · 대기 · 꺼짐. 같으면 고쳐 쓰지 않는다.
    디스크·부하·시각은 꼬리말로 따로 — 매번 바뀌는 값이 비교를 흔들지 않게."""
    use = [f"{w.get('label')} `{_bar(float(w.get('usedPercent') or 0))}` {round(float(w.get('usedPercent') or 0))}%"
           for w in snap["usage"] if w.get("key") in ("fiveHour", "weekly")]
    out: list[dict[str, Any]] = [_text("### 사용량\n" + ("  ·  ".join(use) or "알 수 없음"))]
    rows = sorted(snap["sessions"], key=lambda r: (r["ref"].split("/", 1)[0], r["ref"]))
    proj_w = max([len(r["ref"].split("/", 1)[0]) for r in rows] + [4])
    rows = [dict(r, busy=True, emoji="❓") if r.get("asking") and not r["busy"] else r for r in rows]   # 답 기다리는 질문
    rows = [dict(r, busy=True, emoji="🔐") if r.get("permission") and not r["busy"] else r for r in rows]   # 터미널 권한 창
    busy = [r for r in rows if r["busy"]]
    bg = [r for r in rows if r["alive"] and not r["busy"] and r.get("tasks")]
    idle = [r for r in rows if r["alive"] and not r["busy"] and not r.get("tasks")]
    off = [r for r in rows if not r["alive"]]
    # 메시지당 구성요소 40개(중첩 포함) — 아래 대기·꺼짐·꼬리말 몫(6)을 남기고 넘치면 '외 N개'(리뷰 I2)
    room = [40 - 6 - _count(out) - 4]
    def add(block: list[dict[str, Any]]) -> bool:
        if _count(block) > room[0]:
            return False
        out.extend(block); room[0] -= _count(block)
        return True
    out.append({"type": 14})
    out.append(_text(f"### 🔧 작업 중 {len(busy)}" + ("" if busy else "\n-# 없음")))
    left = [r for r in busy if not add(
        [{"type": 9, "components": [_text(f"{r['emoji'] or '🔧'} {_row(r, proj_w)}{_tasks_tag(r)}{_tasks_desc(r)}")],
          "accessory": {"type": 2, "style": 4, "label": "정지", "custom_id": STOP_PREFIX + r["channelId"]}}]
        + ([{"type": 1, "components": [_view_button(r)]}] if r.get("tasks") else []))]
    if left:
        out.append(_text("-# 외 " + " ".join(f"<#{r['channelId']}>" for r in left)))
    if bg:
        out.append({"type": 14})
        out.append(_text(f"### ⏳ 백그라운드 {len(bg)}\n-# 턴은 끝났고 뒤에서 셸·에이전트가 도는 중 — 세션 재시작하면 같이 죽는다"))
        left = [r for r in bg if not add([{"type": 9, "components": [_text(f"{_row(r, proj_w)}{_tasks_tag(r)}{_tasks_desc(r)}")],
                                            "accessory": _view_button(r)}])]
        if left:
            out.append(_text("-# 외 " + " ".join(f"<#{r['channelId']}>" for r in left)))
    out.append({"type": 14})
    out.append(_text(f"### 💤 대기 {len(idle)}" + "".join("\n" + _row(r, proj_w) for r in idle)))
    if off:
        out.append({"type": 14})
        out.append(_text(f"### ⚫ 꺼짐 {len(off)}" + "".join("\n" + _row(r, proj_w) for r in off)))
    return out


def footer(snap: dict[str, Any]) -> str:
    return (f"-# 디스크 {snap.get('diskFree', 0) // (1 << 30)}GB 남음 · 부하 {snap.get('load', 0.0):.1f}"
            f" · <t:{int(time.time())}:R> 갱신")


# ── Discord ─────────────────────────────────────────────────────────────────

def _dc(cfg: dict[str, Any]) -> ms.Discord:
    return ms.Discord(ms.read_token(cfg))


def _owner_channel(dc: ms.Discord, cfg: dict[str, Any], name: str, kind: int, position: int = 0) -> str:
    """@everyone 은 막고 형·봇만 연다(만들 때 덮어쓰기 — 봇에 역할 관리 권한이 없어도 된다)."""
    guild = str(cfg["guildId"])
    if kind == 4:   # 빈 카테고리 = 숫자판: 보이기만(눌러도 접히기만 — 음성 채널은 서버 주인이 들어가졌다)
        owner = {"allow": str(ms._VIEW), "deny": "0"}
    else:           # #상태: 읽기만
        owner = {"allow": str(ms._VIEW | _HISTORY), "deny": str(_SEND)}
    bot = ms._TALK | (_MANAGE if kind == 4 else 0)
    ow = [{"id": guild, "type": 0, "allow": "0", "deny": str(ms._VIEW)},
          {"id": dc.me(), "type": 1, "allow": str(bot), "deny": "0"}]
    ow += [dict(owner, id=u, type=1) for u in owner_ids(cfg)]
    r = dc._req("POST", f"/guilds/{guild}/channels",
                {"name": name, "type": kind, "position": position, "permission_overwrites": ow})
    return str(r["id"])


def dashboard_tick(st: dict[str, Any], snap: dict[str, Any] | None = None) -> None:
    cfg = ms.load_config()
    dc = _dc(cfg)
    if not st:
        st.update(_load_state().get("dashboard") or {})
    snap = snap or snapshot()
    comps = render(snap)
    body = json.dumps(comps, ensure_ascii=False, sort_keys=True)
    if body == st.get("body") and st.get("messageId"):
        return
    msg = {"flags": COMPONENTS_V2, "components": comps + [_text(footer(snap))], "allowed_mentions": {"parse": []}}
    if st.get("messageId") and st.get("v") != 2:
        # 예전 글자 형식 메시지는 새 형식으로 고칠 수 없다 — 지우고 새로 올린다
        try:
            dc._req("DELETE", f"/channels/{st['channelId']}/messages/{st['messageId']}")
        except ms.SessionError:
            pass
        st.pop("messageId", None)
    for _ in range(2):
        if not st.get("channelId"):
            st.clear()
            st["channelId"] = _owner_channel(dc, cfg, DASHBOARD_NAME, 0)
            _save_section("dashboard", dict(st))      # 다음 단계가 실패해도 채널을 또 만들지 않게(리뷰 M4)
        try:
            if st.get("messageId"):
                dc._req("PATCH", f"/channels/{st['channelId']}/messages/{st['messageId']}", msg)
            else:
                st["messageId"] = str(dc._req("POST", f"/channels/{st['channelId']}/messages", msg).get("id") or "")
            st.update(body=body, v=2)
            break
        except ms.DiscordError as exc:
            if exc.code != 404:
                raise
            # 메시지를 지웠으면 새로 올리고, 채널을 지웠으면 채널부터 다시 만든다
            if st.get("messageId"):
                st.pop("messageId", None)
                try:
                    dc._req("GET", f"/channels/{st['channelId']}")
                except ms.DiscordError as gone:
                    if gone.code != 404:      # 일시 오류로 채널을 새로 만들지 않는다(리뷰 M4)
                        raise
                    st.pop("channelId", None)
            else:
                st.pop("channelId", None)
    _save_section("dashboard", dict(st))


METERS = (("fiveHour", "5시간"), ("weekly", "주간"))


def meter_tick(meters: dict[str, dict[str, Any]]) -> None:
    """사용량 숫자판 — 형만 보이는 빈 카테고리 이름에 5시간·주간 %."""
    cfg = ms.load_config()
    dc = _dc(cfg)
    usage = {x.get("key"): x for x in claude_usage()}
    saved = _load_state()
    for pos, (key, label) in enumerate(METERS):
        st = meters.setdefault(key, {})
        if not st:
            st.update(saved.get(key) or {})
        if st.get("channelId") and st.get("kind") != 4:
            # 예전 음성 숫자판(서버 주인은 눌러서 들어가졌다) — 지우고 카테고리로 다시 만든다
            try:
                dc._req("DELETE", f"/channels/{st['channelId']}")
            except ms.SessionError:
                pass
            st.clear()
        w = usage.get(key)
        if w is None:
            continue
        name = f"📊 {label} {round(float(w.get('usedPercent') or 0))}%"
        if st.get("channelId") and st.get("name") == name:
            continue
        # 이름 변경은 10분 2회 제한 — 데몬을 연달아 재시작해도 넘지 않게 마지막 변경 시각을 저장해 둔다(리뷰 M5)
        if st.get("channelId") and time.time() - float(st.get("renamedAt") or 0) < WEEKLY_EVERY:
            continue
        if st.get("channelId"):
            try:
                dc._req("PATCH", f"/channels/{st['channelId']}", {"name": name})
            except ms.DiscordError as exc:
                if exc.code not in (403, 404):     # 지워졌거나 봇이 못 만지게 됐다 → 새로 만든다
                    raise
                _log(f"{key} meter {st.get('channelId')} gone/forbidden ({exc.code}), recreating")
                st.clear()
        if not st.get("channelId"):
            st.update(channelId=_owner_channel(dc, cfg, name, 4, pos), kind=4)
            _save_section(key, dict(st, name=name, renamedAt=time.time()))   # 다음 단계가 실패해도 또 만들지 않게
        st.update(name=name, renamedAt=time.time())
        _save_section(key, dict(st))


def typing_tick(snap: dict[str, Any], ty: dict[str, float], now: float) -> None:
    busy = [r["channelId"] for r in snap["sessions"] if r["busy"]]
    if not busy:
        return
    dc = _dc(ms.load_config())
    for ch in busy:
        if now - ty.get(ch, 0.0) >= TYPING_EVERY:
            ty[ch] = now
            try:
                dc._req("POST", f"/channels/{ch}/typing")
            except ms.SessionError:
                pass


# ── 🛑 정지 ─────────────────────────────────────────────────────────────────

def _session_transcript(rec: dict[str, Any]) -> Path | None:
    sid = str(rec.get("sessionId") or "")
    if sid:
        return ms.find_transcript(sid)
    d = ms.transcript_path(Path(str(rec.get("root") or "/nonexistent")), "x").parent
    hits = list(d.glob("*.jsonl")) if d.is_dir() else []
    return max(hits, key=lambda p: p.stat().st_mtime) if hits else None


def _allowed(rec: dict[str, Any], channel: str, user: str, dc: ms.Discord) -> bool:
    """허용 목록이 빈 채팅방은 역할로 보이는 사람이 곧 쓸 수 있는 사람이다. 봇 자신(미리 단 🛑)은 제외(리뷰 M8)."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    try:
        allow = json.loads((sd / "access.json").read_text(encoding="utf-8"))["groups"][str(channel)].get("allowFrom") or []
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False
    return not (allow and str(user) not in [str(a) for a in allow]) and str(user) != dc.me()


def view(channel: str, user: str) -> str:
    """[보기]: 뒤에서 도는 셸의 출력 끝·에이전트의 마지막 말(누른 사람에게만). 명령 원문은 안 보낸다(설명만)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    if not _allowed(rec, channel, user, _dc(ms.load_config())):
        return "볼 권한이 없어"
    tr = _session_transcript(rec)
    tasks = live_tasks(rec) if tr else []
    if not tasks or not tr:
        return "지금 뒤에서 도는 일은 없어"
    parts = []
    budget = max(120, 1800 // len(tasks))
    for t in tasks[:12]:
        head = f"{'⏳' if t['kind'] == 'shell' else '🤖'} **{_clean(t['desc'] or t['id'])[:80]}**"
        room = max(40, budget - len(head) - 12)
        if t["kind"] == "shell":
            p = _task_output(tr, t["id"])
            try:
                tail = _clean(p.read_bytes()[-4000:].decode("utf-8", "replace")) if p else ""
            except OSError:
                tail = ""
            body = "\n".join(tail.rstrip().splitlines()[-8:])[-room:].replace("```", "ʼʼʼ")
            parts.append(head + ("\n```\n" + body + "\n```" if body else "\n-# 출력 없음"))
        else:
            words = _clean(_agent_last_words(tr, t["id"]))[-room:]
            parts.append(head + ("\n" + words if words else "\n-# 아직 말 없음"))
    out = ""
    for part in parts:                 # 조각 단위로 자른다 — 코드 펜스가 중간에 끊기지 않게(리뷰 M2)
        if len(out) + len(part) + 1 > 1900:
            break
        out += ("\n" if out else "") + part
    return out or parts[0][:1900]


def interrupt(channel: str, user: str, message: str) -> str:
    """🛑 → 그 세션에 Esc. 대상 지시 = 기록의 마지막 메시지(누른 메시지가 스레드 상태 줄·옛 메시지여도, 리뷰 I3).
    진행 훅과 같은 잠금 안에서 한다 — 떼자마자 진행 훅이 다시 달거나, 두 번 눌려 Esc 가 두 번 가지 않게(리뷰 I2·I4)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    dc = _dc(ms.load_config())
    if not _allowed(rec, channel, user, dc):
        return "멈출 권한이 없어"
    lockf = ms._wait_lock(sd / "activity.lock", timeout=3.0)
    try:
        alive, busy = _pane_busy(str(rec.get("tmux") or ""))
        if not busy:
            return "지금 쉬고 있어"
        tr = _session_transcript(rec)
        ids = ms.inbound_messages(tr, str(channel)) if tr else []
        mid = ids[-1] if ids else ""
        mark = sd / "interrupted"
        try:
            last_mid, last_at = mark.read_text().split()
            if last_mid == mid and time.time() - float(last_at) < 10:
                return "이미 멈췄어"
        except (OSError, ValueError):
            pass
        ms.tmux_leave_mode(str(rec["tmux"]))        # 보기 모드면 Esc 가 보기 모드만 끈다
        ms._tmux("send-keys", "-t", str(rec["tmux"]), "Escape")
        if sd.is_dir():
            mark.write_text(f"{mid} {time.time()}\n")
        # Esc 로 끝난 턴엔 Stop 훅이 안 돈다 — 턴 끝과 같은 정리(달아 둔 표시 전부 떼기·끝 표시 전진)를 여기서(리뷰 B-I2)
        ms._clear_locked(rec, sd, dc, ids)
        clear_perms(sd, str(channel))                 # 기다리던 권한 요청 버튼도
        if (sd / "question.json").exists():          # 질문 중에 멈췄으면 그 질문 메시지도 정리
            import marina_discord_ask
            marina_discord_ask.done(sd, str(channel), "멈춤")
        if mid:
            try:
                dc.add_reaction(str(channel), mid, "⏹️")
            except ms.SessionError:
                pass
    finally:
        if lockf:
            lockf.close()
    mark_dirty()
    return "멈췄어"


_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_CTRL = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|[\x00-\x08\x0b-\x1f\x7f]")
_SECRET = re.compile(r"(?i)(bearer\s+|authorization:\s*\S+\s+|(?:token|secret|password|passwd|api[_-]?key|key)\s*[=:]\s*)\S+"
                     r"|AKIA[0-9A-Z]{12,}|-----BEGIN [A-Z ]+-----[\s\S]*?(?:-----END [A-Z ]+-----|$)|(?:sk|ghp|xox[bp])-?[A-Za-z0-9_-]{16,}")


def _clean(text: str) -> str:
    """Discord 로 내보내는 셸 출력: 제어문자 제거 + 흔한 비밀 모양 가리기(리뷰 I7)."""
    return _SECRET.sub(lambda m: (m.group(1) or "") + "•••", _CTRL.sub("", text))
_DIM = re.compile(r"\x1b\[2m.*?(?:\x1b\[(?:22|0)?m|$)")


def _input_empty_text(line: str) -> bool:
    """입력창 줄(❯)이 비었나. 흐린 글씨(다음 입력 추천)는 빈 것으로 본다. '❯ 1. Yes' 같은 선택·권한 창은 아니다."""
    t = _ANSI.sub("", _DIM.sub("", line))
    i = t.find("❯")
    return i >= 0 and not t[i + 1:].strip()


def _input_empty(tmux: str) -> bool:
    lines = (ms._tmux("capture-pane", "-p", "-e", "-t", tmux).stdout or "").rstrip().splitlines()
    box = [ln for ln in lines if "❯" in _ANSI.sub("", ln)]
    return bool(box) and _input_empty_text(box[-1])


_GHOST = re.compile(r"❯[\s\xa0]*\x1b\[2m(.*?)(?:\x1b\[(?:22|0)?m|$)")
SAY_PREFIX = "marina-say:"
SUGGEST_MARK = "[Discord 추천 버튼] "


def ghost_text(line: str) -> str:
    """입력창의 흐린 글씨(ESC[2m) = Claude Code 의 다음 입력 추천(실측). 흐리지 않은 글은 쓰던 초안이라 아니다."""
    m = _GHOST.search(line)
    return _ANSI.sub("", m.group(1)).strip() if m else ""


def run_suggest(tmux: str, channel: str, msg: str, settle: float = 6.0, started: float | None = None) -> None:
    """턴 끝: 추천이 뜰 틈을 두고 입력창을 읽어, 있으면 마지막 답장에 [▶ 추천] 버튼을 단다.
    그 사이 새 지시가 와서 지웠으면(suggest-cleared-at) 단 것을 되돌린다(리뷰 I4)."""
    started = time.time() if started is None else started
    time.sleep(settle)
    if not ms.tmux_alive(tmux):
        return
    lines = (ms._tmux("capture-pane", "-p", "-e", "-t", tmux).stdout or "").rstrip().splitlines()
    box = [ln for ln in lines if "❯" in _ANSI.sub("", ln)]
    text = ghost_text(box[-1]) if box else ""
    rec = next((x for x in ms.load_sessions() if str(x.get("channelId")) == str(channel)), None)
    if not text or not rec or not rec.get("stateDir"):
        return
    sd = Path(str(rec["stateDir"]))
    def cleared() -> bool:
        try:
            return float((sd / "suggest-cleared-at").read_text()) > started
        except (OSError, ValueError):
            return False
    if cleared() or _pane_busy(tmux)[1]:
        return
    dc = _dc(ms.load_config())
    try:
        dc._req("PATCH", f"/channels/{channel}/messages/{msg}", {"components": [{"type": 1, "components": [
            {"type": 2, "style": 1, "label": ("▶ " + text)[:80], "custom_id": SAY_PREFIX + str(channel)}]}]})
    except ms.SessionError:
        return
    ms._write_json(sd / "suggest.json", {"text": text, "msg": str(msg)})
    if cleared():
        ms.clear_suggest(sd, str(channel), dc)


def _spawn_type(tmux: str, text: str, channel: str, mid: str, button: str = "") -> None:
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "type", tmux, text, channel, mid, button],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def say(channel: str, user: str, message: str = "") -> str:
    """[▶ 추천] 누름: 한 번만. 허용 명령은 그대로, 글은 '[Discord 추천 버튼]' 을 붙여 입력창에(답은 Discord 로 — 규칙).
    누른 버튼이 지금 추천의 메시지가 아니면(남은 옛 버튼) 치지 않고 그 버튼을 뗀다(리뷰 I3)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    dc = _dc(ms.load_config())
    if not _allowed(rec, channel, user, dc):
        return "누를 권한이 없어"
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    try:
        sug = json.loads((sd / "suggest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sug = {}
    if message and str(sug.get("msg") or "") != str(message):
        try:
            dc._req("PATCH", f"/channels/{channel}/messages/{message}", {"components": []})
        except ms.SessionError:
            pass
        return "지난 추천이라 뗐어" if sug else "지금 누를 추천이 없어"
    claim = sd / f"suggest.json.{os.getpid()}.{time.time_ns()}"
    try:
        os.rename(sd / "suggest.json", claim)      # 먼저 가져간 쪽만 친다 — 두 번 눌러도 한 번(리뷰 I5)
    except OSError:
        return "지금 누를 추천이 없어"
    try:
        sug = json.loads(claim.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sug = {}
    finally:
        claim.unlink(missing_ok=True)
    text = str(sug.get("text") or "")
    # 누른 게 채널에 남게 — 버튼을 '✓ 보냄: …' 회색(못 누름)으로 바꾼다(실사용: 비밀 답장만 떠서 뭘 보냈는지 몰랐다)
    try:
        dc._req("PATCH", f"/channels/{channel}/messages/{sug.get('msg')}", {"components": [{"type": 1, "components": [
            {"type": 2, "style": 2, "label": ("✓ 보냄: " + text)[:80], "custom_id": "marina-said", "disabled": True}]}]} if text
            else {"components": []})
    except ms.SessionError:
        pass
    if not text:
        return "지금 누를 추천이 없어"
    # 봇 답장엔 진행 반응을 달지 않는다(✅ 없음 결정과 맞춤, 리뷰 M5)
    _spawn_type(str(rec.get("tmux") or ""), text if ms.slash_allowed(text) else SUGGEST_MARK + text, str(channel), "",
                str(sug.get("msg") or ""))
    return "입력할게"


SLASH_MARK = "[Discord 슬래시] "
SLASH_COMMANDS = [   # 길드 명령(봇이 켜질 때 등록). 스킬 이름은 자동완성으로
    {"name": "compact", "description": "이 채널 세션 대화 압축(쉬는 순간 입력)", "type": 1},
    {"name": "model", "description": "모델 바꾸기", "type": 1, "options": [
        {"type": 3, "name": "name", "description": "opus · sonnet · haiku · fable …", "required": True, "autocomplete": True}]},
    {"name": "effort", "description": "생각 깊이 바꾸기", "type": 1, "options": [
        {"type": 3, "name": "level", "description": "단계", "required": True,
         "choices": [{"name": x, "value": x} for x in ("low", "medium", "high", "xhigh", "max")]}]},
    {"name": "stop", "description": "이 채널 세션 작업 멈춤(Esc)", "type": 1},
    {"name": "skill", "description": "스킬·명령 실행", "type": 1, "options": [
        {"type": 3, "name": "name", "description": "스킬 이름", "required": True, "autocomplete": True},
        {"type": 3, "name": "args", "description": "덧붙일 말", "required": False}]},
]
MODELS = ("opus", "sonnet", "haiku", "fable", "opusplan", "default")


def _claude_home() -> Path:
    return Path(os.environ.get("MARINA_CLAUDE_HOME") or Path.home() / ".claude")


def list_skills(rec: dict[str, Any], query: str = "") -> list[str]:
    """그 세션에서 쓸 수 있는 스킬·명령 이름(사용자 · 설치된 플러그인 · 프로젝트). 자동완성 최대 25개."""
    home = _claude_home()
    names: set[str] = set()
    def scan(base: Path, prefix: str = "") -> None:
        for d in (base / "skills").glob("*/SKILL.md"):
            names.add(prefix + d.parent.name)
        for f in (base / "commands").glob("*.md"):
            names.add(prefix + f.stem)
    scan(home)
    try:
        installed = json.loads((home / "plugins" / "installed_plugins.json").read_text(encoding="utf-8")).get("plugins") or {}
    except (OSError, ValueError, AttributeError):
        installed = {}
    for key, entries in installed.items():
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and e.get("installPath"):
                scan(Path(str(e["installPath"])), str(key).split("@", 1)[0] + ":")
    root = Path(str(rec.get("root") or "/nonexistent"))
    scan(root / ".claude")
    q = query.strip().lower()
    hits = sorted(n for n in names if q in n.lower())
    return sorted(hits, key=lambda n: (not n.lower().startswith(q), n))[:25]


def slash(channel: str, user: str, name: str, value: str = "", args: str = "", message: str = "") -> str:
    """Discord 슬래시 명령. 기본 명령은 쉬는 순간 입력창에 그대로, 스킬은 '[Discord 슬래시]' 를 붙여(Claude 가 Skill 도구로)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec or rec.get("kind") in ms.CHAT_KINDS:
        return "이 채널은 세션 명령을 안 받아"
    if not _allowed(rec, channel, user, _dc(ms.load_config())):
        return "쓸 권한이 없어"
    if name == "stop":
        return interrupt(channel, user, "")
    if name == "skill":
        if value not in list_skills(rec, value):
            return f"없는 스킬이야: {value}"
        text = (SLASH_MARK + f"/{value} " + " ".join(args.split())[:1500]).strip()
    else:
        text = f"/{name}" + (f" {value.strip()}" if value.strip() else "")
        if not ms.slash_allowed(text):
            return "그 값은 못 넣어"
    # 보낸 명령을 채널에 남긴다 — 그 메시지에 ⚙️/🗜️ → 입력·실행 끝나면 ✅, 못 하면 ⚠️(실사용: 보냈는지 몰랐다)
    shown = text[len(SLASH_MARK):] if text.startswith(SLASH_MARK) else text
    mid = message                        # 봇이 공개로 남긴 명령 응답 — 거기에 ⚙️ → ✅/⚠️
    if not mid:
        try:
            mid = str(_dc(ms.load_config())._req("POST", f"/channels/{channel}/messages", {
                "content": f"⌨️ `{shown[:300]}` — 쉬는 순간 입력할게", "allowed_mentions": {"parse": []}}).get("id") or "")
        except ms.SessionError:
            mid = ""
    _spawn_type(str(rec.get("tmux") or ""), text, str(channel), mid)
    return f"⌨️ `{shown[:300]}` — 쉬는 순간 입력할게"


_YES = re.compile(r"^\s*❯\s*1\.\s*Yes\s*$")
_NO = re.compile(r"^\s*2\.\s*No\s*$")
PANE_PERM_TTL = 600.0


def _pane_prompt(name: str) -> "tuple[str, list[str], str, bool] | None | bool":
    """화면 아래 권한 창 → (서명, 머리말, 명령 앞부분, 누를 수 있나). 창이 없으면 None, 화면을 못 읽으면 False(판단 보류 — 리뷰 I7).
    머리말 = 질문 위로 구분선(─)까지의 설명 줄. 서명은 머리말~선택지 끝까지(다른 창·다른 선택지면 달라진다).
    누를 수 있음 = 선택지가 정확히 '❯ 1. Yes' / '2. No' 두 개 — 영구 허용·폴더 신뢰 같은 창엔 Enter 를 안 친다(리뷰 C1)."""
    if not name or not ms.tmux_alive(name):
        return None
    r = ms._tmux("capture-pane", "-p", "-t", f"={name}:")
    if r.returncode != 0:
        return False
    lines = (r.stdout or "").rstrip().splitlines()[-20:]
    q = max((i for i, l in enumerate(lines) if "Do you want to " in l), default=-1)
    if q < 0 or not any(_PERM.match(l) for l in lines[q:]):
        return None
    head: list[str] = []
    cmd = ""
    top = q
    for i in range(q - 1, max(-1, q - 16), -1):
        t = lines[i].strip()
        top = i
        if t and set(t) <= set("─━"):
            break
        if t.startswith("│"):
            cmd = t.lstrip("│ ").strip() or cmd       # 위로 올라가며 — 마지막에 남는 게 첫 줄
            continue
        if not t or set(t) <= set("╌┄-"):
            continue
        head.append(t[:100])
    opts = [l for l in lines[q + 1:] if re.match(r"^\s*(❯\s*)?\d+\.", l)]
    ok = len(opts) == 2 and bool(_YES.match(opts[0])) and bool(_NO.match(opts[1]))
    sig = hashlib.sha1("\n".join(lines[top:]).encode("utf-8", "replace")).hexdigest()[:16]
    return sig, list(reversed(head))[-3:], _clean(cmd)[:80], ok


def _perm_entries(sd: Path) -> "list[tuple[Path, dict[str, Any]]]":
    out = []
    for f in sd.glob("perm-*.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict):
            out.append((f, d))
    return out


def _pane_perm_close(f: Path, d: dict[str, Any], channel: str, note: str) -> None:
    for x in (f, f.with_suffix(".answer")):
        try:
            x.unlink()
        except OSError:
            pass
    if d.get("msg"):
        try:
            _dc(ms.load_config())._req("PATCH", f"/channels/{channel}/messages/{d['msg']}",
                                       {"content": str(d.get("title") or "🔐 권한 요청") + f"\n-# {note}", "components": []})
        except ms.SessionError:
            pass


def pane_perm_tick(names: "set[str] | None" = None) -> None:
    """터미널 권한 창(서브에이전트 것은 훅 버튼이 안 온다) → 채널에 [허용][거부]. 풀리면 버튼을 거둔다(실사용 2026-10-04)."""
    for rec in ms.load_sessions():
        try:
            _pane_perm_one(rec, names)
        except Exception as exc:                      # 한 세션 오류가 나머지를 막지 않게(리뷰 I9)
            _log(f"pane_perm {rec.get('tmux')}: {exc!r}")


def _pane_perm_one(rec: dict[str, Any], names: "set[str] | None") -> None:
    name, ch = str(rec.get("tmux") or ""), str(rec.get("channelId") or "")
    if not ch or not rec.get("stateDir") or (names is not None and name not in names):
        return
    sd = Path(str(rec["stateDir"]))
    got = _pane_prompt(name)
    if got is False:
        return
    entries = _perm_entries(sd)
    mine = [(f, d) for f, d in entries if d.get("pane")]
    if got and any(d.get("sig") == got[0] and d.get("msg") for _, d in mine):
        return
    for f, d in mine:
        _pane_perm_close(f, d, ch, "터미널에서 처리됨" if not got else "창이 바뀜")
    if not got or any(not d.get("pane") for _, d in entries):     # 훅이 이미 버튼을 올린 요청(본 세션)
        return
    sig, head, cmd, ok = got
    token = uuid.uuid4().hex[:12]
    title = "🔐 **권한 창에서 멈춤** — " + (" · ".join(head) or "터미널 확인 필요") + (f"\n`{cmd}`" if cmd else "")
    tail = ("\n-# 누르면 터미널에 Yes(Enter)/취소(Esc)를 대신 쳐" if ok
            else "\n-# 선택지가 Yes/No 가 아니라 버튼을 안 달았어 — 터미널에서 골라 줘")
    body: dict[str, Any] = {"content": title + tail, "allowed_mentions": {"parse": []}}
    if ok:
        body["components"] = [{"type": 1, "components": [
            {"type": 2, "style": 3, "label": "허용", "custom_id": f"mperm:a:{ch}:{token}"},
            {"type": 2, "style": 4, "label": "거부", "custom_id": f"mperm:d:{ch}:{token}"}]}]
    try:
        msg = str(_dc(ms.load_config())._req("POST", f"/channels/{ch}/messages", body).get("id") or "")
    except ms.SessionError:
        return                                        # 파일을 안 남겨 다음 판에 다시 올린다(리뷰 I6)
    if msg:
        ms._write_json(sd / f"perm-{token}.json", {"token": token, "msg": msg, "pane": True, "sig": sig, "ok": ok,
                                                    "title": title, "at": time.time()})


def _pane_answer(rec: dict[str, Any], sd: Path, token: str, d: dict[str, Any], allow: bool) -> str:
    f = sd / f"perm-{token}.json"
    ch, name = str(rec.get("channelId")), str(rec.get("tmux") or "")
    if not d.get("ok"):
        return "누를 수 있는 권한 창이 아니야 — 터미널에서 골라 줘"
    try:                                              # 두 번 눌러도 한 번만 친다
        os.close(os.open(str(f.with_suffix(".answer")), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    except OSError:
        return "이미 결정됐어"
    if time.time() - float(d.get("at") or 0) > PANE_PERM_TTL:
        _pane_perm_close(f, d, ch, "오래된 버튼이라 안 눌렀어")
        return "오래된 버튼이라 안 눌렀어 — 아직 창이 있으면 새 버튼이 와"
    got = _pane_prompt(name)
    if not got or got[0] != d.get("sig") or not got[3]:
        _pane_perm_close(f, d, ch, "화면이 바뀌어서 안 눌렀어")
        return "화면이 바뀌어서 안 눌렀어 — 지금 창이 있으면 새 버튼이 와"
    ms.tmux_leave_mode(name)
    r = ms._tmux("send-keys", "-t", f"={name}:", "Enter" if allow else "Escape")
    if r.returncode != 0:
        return "터미널에 못 쳤어 — 터미널에서 직접 골라 줘"
    _pane_perm_close(f, d, ch, "✅ 허용함" if allow else "⛔ 거부함")
    return "허용했어" if allow else "거부했어"


def perm(channel: str, user: str, token: str, allow: bool) -> str:
    """권한 요청 [허용]/[거부] — 기다리는 훅이 읽어 결정한다. 먼저 누른 것만(O_EXCL, 리뷰 I1).
    허용 목록이 빈 채널(역할로 보이는 누구나)은 승인 못 한다 — 메시지와 달리 실행 권한이다(리뷰 I6)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec or not re.fullmatch(r"[0-9a-f]{12}", token or ""):
        return "모르는 요청이야"
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    try:
        allow_from = json.loads((sd / "access.json").read_text(encoding="utf-8"))["groups"][str(channel)].get("allowFrom") or []
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        allow_from = []
    if not allow_from or not _allowed(rec, channel, user, _dc(ms.load_config())):
        return "누를 권한이 없어"
    if not (sd / f"perm-{token}.json").exists():
        return "이미 끝났거나 없는 요청이야"
    try:
        pd = json.loads((sd / f"perm-{token}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pd = {}
    if isinstance(pd, dict) and pd.get("pane"):       # 화면 권한 창 — 기다리는 훅이 없다, 여기서 친다(리뷰 I8: 선점 전에 판정)
        return _pane_answer(rec, sd, token, pd, allow)
    try:
        fd = os.open(str(sd / f"perm-{token}.answer"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return "이미 결정됐어"
    except OSError:
        return "이미 끝났거나 없는 요청이야"
    with os.fdopen(fd, "w") as fh:
        fh.write("allow" if allow else "deny")
    return "허용했어" if allow else "거부했어"


def clear_perms(sd: Path, channel: str) -> None:
    """멈춤(🛑) 등으로 기다리던 권한 요청이 끝났다 — 버튼과 기록을 정리(리뷰 I2)."""
    dc = None
    for f in sd.glob("perm-*.json"):
        try:
            msg = str(json.loads(f.read_text(encoding="utf-8")).get("msg") or "")
        except (OSError, ValueError):
            msg = ""
        for x in (f, f.with_suffix(".answer")):
            try:
                x.unlink()
            except OSError:
                pass
        if msg:
            dc = dc or _dc(ms.load_config())
            try:
                dc._req("PATCH", f"/channels/{channel}/messages/{msg}", {"components": []})
            except ms.SessionError:
                pass


def typeable(text: str) -> bool:
    """`type` 하위명령이 입력창에 칠 수 있는 글 — 추천 버튼·슬래시 표시가 붙은 글, 이어받기 안내, 허용 명령만."""
    return ms.slash_allowed(text) or text.startswith((SUGGEST_MARK, SLASH_MARK)) or text == ms.RESUME_TEXT


def restart_blockers(rec: dict[str, Any]) -> list[str]:
    """안전 재시작을 막는 이유(훅 기록 기준 — 화면 짐작 아님). 빈 목록이면 지금 재시작해도 된다."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    def num(name: str) -> float:
        try:
            return float((sd / name).read_text())
        except (OSError, ValueError):
            return 0.0
    out = []
    # 턴 끝 기록은 Esc·API 오류로 끝난 턴엔 안 남는다 — 10분 지난 턴은 화면만 본다(리뷰 I1)
    turn = num("turn-at")
    if (turn > num("stopped-at") and time.time() - turn < 600) or _pane_busy(str(rec.get("tmux") or ""))[1]:
        out.append("작업 중")
    t = live_tasks(rec) if ms.tmux_alive(str(rec.get("tmux") or "")) else []
    if t:
        out.append(f"백그라운드 {len(t)}")
    name = str(rec.get("tmux") or "")
    if name and ms.tmux_alive(name):
        tail = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()[-8:]
        if any(l.strip() == "⏺ main" for l in tail):    # 아래 에이전트 목록 = SendMessage 로 맡긴 팀 에이전트(재시작하면 같이 죽는다, 실사용)
            out.append("팀 에이전트 일하는 중")
    if (sd / "question.json").exists():
        out.append("질문 답 기다림")
    if list(sd.glob("perm-*.json")):
        out.append("권한 버튼 기다림")
    tr = _session_transcript(rec)
    try:
        if tr and time.time() - tr.stat().st_mtime < 30:
            out.append("방금 메시지·작업 기록이 움직임")
    except OSError:
        pass
    return out


def safe_restart(refs: list[str], wait: float = 6 * 3600.0, poll: float = 15.0,
                 log: Any = None) -> tuple[list[str], list[str]]:
    """막는 이유가 없을 때만 하나씩 재시작한다. 풀릴 때까지 기다리다 시간이 지나면 남은 것을 돌려준다."""
    pending, done, failures = list(dict.fromkeys(refs)), [], []
    end = time.time() + wait
    while pending:
        for ref in list(pending):
            try:
                rec = ms.find_session(ref)
            except ms.SessionError:
                pending.remove(ref)          # 기다리는 사이 지워진 세션 — 나머지는 계속(리뷰 S3)
                continue
            why = restart_blockers(rec) if ms.tmux_alive(str(rec.get("tmux") or "")) else []
            if why:
                continue
            ms.tmux_stop(str(rec.get("tmux") or ""))
            started, failed = ms.cmd_start(ref)
            pending.remove(ref)
            if started:
                done.append(ref)
            else:
                failures.append(ref)         # 꺼진 채 남았다 — 성공으로 세지 않는다(리뷰 I4)
            if log:
                log(f"✓ 재시작: {ref}" if started else f"✗ {failed}")
        if not pending or time.time() >= end:
            break
        if log:
            log("기다리는 중: " + ", ".join(f"{r}({'·'.join(restart_blockers(ms.find_session(r)))})" for r in pending))
        time.sleep(poll)
    return done, pending + failures


def type_timeout(text: str) -> float:
    """추천은 금방 안 쉬면 포기(옛 추천을 나중에 치지 않게), 슬래시·명령은 끝날 때까지 기다린다(리뷰 I5)."""
    return 120.0 if text.startswith(SUGGEST_MARK) else 1800.0


def _restore_suggest(channel: str, msg: str, text: str) -> None:
    """누른 추천을 못 쳤다(세션이 계속 바쁨) — 조용히 사라지지 않게 버튼을 '⚠️ 다시' 로 되살린다(실사용: '둘다해' 유실)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec or not rec.get("stateDir"):
        return
    try:
        _dc(ms.load_config())._req("PATCH", f"/channels/{channel}/messages/{msg}", {"components": [{"type": 1, "components": [
            {"type": 2, "style": 1, "label": ("⚠️ 못 보냄 · 다시: " + text)[:80], "custom_id": SAY_PREFIX + str(channel)}]}]})
    except ms.SessionError:
        return
    ms._write_json(Path(str(rec["stateDir"])) / "suggest.json", {"text": text, "msg": str(msg)})


def run_slash(tmux: str, cmd: str, channel: str, mid: str, poll: float = 2.0, settle: float = 3.0,
              timeout: float = 1800.0) -> bool:
    """Discord 로 온 /compact·/model X·/effort X: 세션이 쉬고 입력창이 정말 비었을 때만 직접 친다(허용 목록은 훅이 거른다).
    권한·선택 창이 떠 있으면 Enter 가 '승인'이 되므로 치지 않는다(리뷰 I1). 대기자끼리는 잠금으로 하나씩(리뷰 I6).
    🗜️/⚙️ → 끝나면 ✅, 못 하면 ⚠️ — 어떤 길로 끝나도 표시가 남지 않게(리뷰 I4)."""
    import fcntl
    emoji, ok, lockf = ms.slash_emoji(cmd), False, None
    dc = None
    try:
        dc = _dc(ms.load_config()) if mid else None
        if dc is not None:
            try:
                dc.add_reaction(channel, mid, emoji)
            except ms.SessionError:
                pass
        end = time.time() + timeout
        rec = next((x for x in ms.load_sessions() if str(x.get("channelId")) == str(channel)), {})
        sd = Path(str(rec.get("stateDir") or ms.marina_home()))
        lockf = open(sd / "slash.lock", "w")
        while True:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.time() > end:
                    return False
                time.sleep(poll)
        time.sleep(settle)                   # Claude 가 '실행할게' 답하고 턴을 끝낼 틈
        typed = False
        while time.time() < end:
            alive, busy = _pane_busy(tmux)
            if not alive:
                return False
            ms.tmux_leave_mode(tmux)
            if not busy and _input_empty(tmux):
                ms._tmux("send-keys", "-t", tmux, "-l", cmd)
                # 글과 Enter 가 한꺼번에 들어가면 붙여넣기로 보고 Enter 를 줄바꿈으로 먹는다(실사용: '입력함' 인데 안 보내짐)
                time.sleep(float(os.environ.get("MARINA_ENTER_DELAY") or 0.6))
                ms._tmux("send-keys", "-t", tmux, "Enter")
                typed = True
                time.sleep(1.5)
                after = ms._tmux("capture-pane", "-p", "-t", tmux).stdout or ""
                box = [ln for ln in after.splitlines() if "❯" in ln]
                head = cmd[:12]
                if box and head in box[-1]:              # 아직 입력창에 남아 있다 — Enter 한 번 더
                    ms._tmux("send-keys", "-t", tmux, "Enter")
                    _log(f"type {tmux}: 입력창에 남아 Enter 다시")
                _log(f"type {tmux}: 입력함 {cmd[:60]!r} · 화면 끝: {' | '.join(after.rstrip().splitlines()[-6:])[:400]!r}")
                break
            time.sleep(poll)
        if not typed:
            _log(f"type {tmux}: 못 침(쉬는 순간이 안 옴) {cmd[:60]!r}")
            return False
        seen, start = False, time.time()
        while time.time() < end:             # 명령이 돌기 시작했다가(짧으면 못 볼 수도) 끝날 때까지
            time.sleep(poll)
            alive, busy = _pane_busy(tmux)
            if not alive:
                return typed
            seen = seen or busy
            if not busy and (seen or time.time() - start > 10 * poll):
                ok = True
                break
        return typed          # 친 것까지가 성공 — 그 턴이 길어 끝을 못 봐도 입력은 들어갔다(리뷰 C1)
    finally:
        if dc is not None:
            for fn, e in ((dc.remove_reaction, emoji), (dc.add_reaction, "✅" if ok else "⚠️")):
                try:
                    fn(channel, mid, e)
                except ms.SessionError:
                    pass
        if lockf:
            lockf.close()
        mark_dirty()


# ── 봇 프로세스·데몬 루프 ────────────────────────────────────────────────────

def _bun() -> str:
    found = shutil.which("bun")
    if found:
        return found
    for cand in ("/opt/homebrew/bin/bun", str(Path.home() / ".bun/bin/bun"), "/usr/local/bin/bun"):
        if os.access(cand, os.X_OK):
            return cand
    return ""


def bot_command(cfg: dict[str, Any]) -> dict[str, Any] | None:
    bun = _bun()
    if not bun:
        return None
    env = {k: v for k, v in os.environ.items() if k.startswith("MARINA_") or k in ("HOME", "USER", "LANG", "TMPDIR")}
    env.update(PATH=f"{Path(bun).parent}:/usr/bin:/bin", DISCORD_BOT_TOKEN=ms.read_token(cfg),
               MARINA_GUILD=str(cfg["guildId"]), MARINA_PY=sys.executable, MARINA_BOT_PY=str(Path(__file__).resolve()),
               MARINA_PARENT_PID=str(os.getpid()))
    return {"argv": [bun, "bot.ts"], "cwd": str(BOT_DIR), "env": env, "bun": bun}


def _log(msg: str) -> None:
    p = ms.marina_home() / "discord-bot.log"
    try:
        if p.exists() and p.stat().st_size > 1 << 20:
            p.unlink()
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


_spawn = subprocess.Popen


class Loop:
    """마리나 데몬 스레드 한 바퀴(4초). discord.json 이 없으면 봇을 내리고 아무것도 안 한다(생기면 그때 시작)."""

    def __init__(self) -> None:
        self.dash: dict[str, Any] = {}
        self.meters: dict[str, dict[str, Any]] = {}
        self.ty: dict[str, float] = {}
        self.last_render = -1.0          # 데몬이 막 떴으면 한 번은 그린다
        self.last_weekly = -WEEKLY_EVERY
        self.proc: subprocess.Popen | None = None
        self.next_start, self.backoff, self.started = 0.0, 5.0, 0.0
        self.lockf: Any = None
        self.last_err = ""

    def own(self) -> bool:
        """같은 마리나 홈에선 한 인스턴스만(프리뷰 데몬이 실 ~/.marina 를 공유해도 봇이 둘 뜨지 않게, 리뷰 I1)."""
        if self.lockf:
            return True
        import fcntl
        try:
            f = open(ms.marina_home() / "discord-bot.lock", "w")
        except OSError:
            return False
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            f.close()
            return False
        self.lockf = f
        return True

    def stop_bot(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def supervise(self, cfg: dict[str, Any], now: float) -> None:
        if self.proc is not None and self.proc.poll() is None:
            return
        if self.proc is not None:        # 죽었다 — 1분 안에 또 죽으면 간격을 늘린다
            self.backoff = min(self.backoff * 2, 300.0) if now - self.started < 60 else 5.0
            _log(f"bot exited {self.proc.returncode}, restart in {self.backoff:.0f}s")
            self.proc = None
            self.next_start = now + self.backoff
            return
        if now < self.next_start:
            return
        cmd = bot_command(cfg)
        if not cmd:
            return
        if not (BOT_DIR / "node_modules").is_dir():
            # 설치 스크립트엔 토큰을 넘기지 않고, 잠금 파일에 적힌 버전만 받는다(리뷰 M2)
            env = {k: v for k, v in cmd["env"].items() if k != "DISCORD_BOT_TOKEN"}
            subprocess.run([cmd["bun"], "install", "--no-summary", "--frozen-lockfile"], cwd=cmd["cwd"], env=env,
                           capture_output=True, timeout=300)
        with open(ms.marina_home() / "discord-bot.log", "a") as logf:
            self.proc = _spawn(cmd["argv"], cwd=cmd["cwd"], env=cmd["env"], stdout=logf, stderr=logf,
                                         stdin=subprocess.DEVNULL)
        self.started = now

    def step(self, now: float) -> bool:
        """설정이 있으면 True."""
        try:
            cfg = ms.load_config()
        except ms.SessionError:
            self.stop_bot()
            return False
        if not self.own():
            return False
        for name, fn in (("bot", lambda: self.supervise(cfg, now)), ("view", lambda: self.view(now))):
            try:
                fn()
            except Exception as exc:     # 데몬 스레드는 죽으면 안 된다 — 남기되 같은 오류는 한 번만(리뷰 M3)
                err = f"{name} failed: {exc!r}"
                if err != self.last_err:
                    _log(err)
                self.last_err = err
        return True

    def view(self, now: float) -> None:
        light = snapshot(full=False)
        typing_tick(light, self.ty, now)
        try:
            pane_perm_tick()
        except Exception as exc:
            _log(f"pane_perm failed: {exc!r}")
        if should_render(now, self.last_render, dirty_mtime(), light["anyBusy"]):
            self.last_render = now
            dashboard_tick(self.dash)
        if now - self.last_weekly >= WEEKLY_EVERY:
            self.last_weekly = now
            meter_tick(self.meters)


def run_forever() -> None:
    loop = Loop()
    while True:
        time.sleep(4 if loop.step(time.time()) else 30)


def main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="marina_discord_bot")
    sub = p.add_subparsers(dest="cmd", required=True)
    it = sub.add_parser("interrupt")
    it.add_argument("--channel", required=True)
    it.add_argument("--user", required=True)
    it.add_argument("--message", required=True)
    pm = sub.add_parser("perm")
    pm.add_argument("--channel", required=True); pm.add_argument("--user", required=True)
    pm.add_argument("--token", required=True); pm.add_argument("--allow", action="store_true")
    sc = sub.add_parser("slash-cmd")
    sc.add_argument("--channel", required=True); sc.add_argument("--user", required=True); sc.add_argument("--name", required=True)
    sc.add_argument("--value", default=""); sc.add_argument("--args", default=""); sc.add_argument("--message", default="")
    sk = sub.add_parser("skills")
    sk.add_argument("--channel", required=True); sk.add_argument("--query", default="")
    sub.add_parser("commands")
    sy = sub.add_parser("say")
    sy.add_argument("--channel", required=True); sy.add_argument("--user", required=True); sy.add_argument("--message", default="")
    sg = sub.add_parser("suggest")
    sg.add_argument("tmux"); sg.add_argument("channel"); sg.add_argument("msg"); sg.add_argument("started", type=float)
    ty = sub.add_parser("type")
    ty.add_argument("tmux"); ty.add_argument("text"); ty.add_argument("channel"); ty.add_argument("mid")
    ty.add_argument("button", nargs="?", default="")
    vw = sub.add_parser("view")
    vw.add_argument("--channel", required=True)
    vw.add_argument("--user", required=True)
    sl = sub.add_parser("slash")
    sl.add_argument("tmux")
    sl.add_argument("command")
    sl.add_argument("channel")
    sl.add_argument("message")
    a = p.parse_args(argv)
    if a.cmd == "perm":
        try:
            print(perm(a.channel, a.user, a.token, a.allow))
        except ms.SessionError as exc:
            print(str(exc))
        return 0
    if a.cmd == "slash-cmd":
        try:
            print(slash(a.channel, a.user, a.name, a.value, a.args, a.message))
        except ms.SessionError as exc:
            print(str(exc))
        return 0
    if a.cmd == "skills":
        rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(a.channel)), None)
        print(json.dumps(list_skills(rec, a.query) if rec and rec.get("kind") not in ms.CHAT_KINDS else [], ensure_ascii=False))
        return 0
    if a.cmd == "commands":
        print(json.dumps(SLASH_COMMANDS, ensure_ascii=False))
        return 0
    if a.cmd == "say":
        try:
            print(say(a.channel, a.user, a.message))
        except ms.SessionError as exc:
            print(str(exc))
        return 0
    if a.cmd == "suggest":
        run_suggest(a.tmux, a.channel, a.msg, started=a.started)
        return 0
    if a.cmd == "type":
        if typeable(a.text):
            typed = run_slash(a.tmux, a.text, a.channel, a.mid,
                              timeout=float(os.environ.get("MARINA_TYPE_TIMEOUT") or type_timeout(a.text)))
            if not typed and a.button:
                _restore_suggest(a.channel, a.button, a.text[len(SUGGEST_MARK):] if a.text.startswith(SUGGEST_MARK) else a.text)
        return 0
    if a.cmd == "view":
        try:
            print(view(a.channel, a.user))
        except ms.SessionError as exc:
            print(str(exc))
        return 0
    if a.cmd == "slash":
        if ms.slash_allowed(a.command):
            run_slash(a.tmux, a.command, a.channel, a.message)
        return 0
    try:
        print(interrupt(a.channel, a.user, a.message))
        return 0
    except ms.SessionError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
