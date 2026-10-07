"""마리나 Discord 봇 1단계 — 🛑 정지 · #상태 대시보드 · 주간 숫자판 · 작업 중 '입력 중…'.

discord.json 이 있을 때만 마리나 데몬이 run_forever 를 돌린다(선택 기능). 판단·그리기는 전부 여기(파이썬)에 두고,
봇(marina-discord-bot/bot.ts, bun)은 반응 이벤트를 받아 `interrupt` 를 부르는 일만 한다 — 로직을 두 언어로 나누지 않는다.
설계: docs/superpowers/specs/2026-10-02-marina-discord-bot-design.md
"""
from __future__ import annotations

import datetime
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
RECONCILE_EVERY = 60.0
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
        import marina_discord_usage        # discord 자기 사본(분리 B) — 대시보드 코드를 안 부른다
        return marina_discord_usage.claude_windows()
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
    path = _session_transcript(rec)      # sessionId 없는 새 방은 방 폴더의 가장 최근 기록으로
    if path and not rec.get("sessionId"):
        # 같은 폴더에서 사람이 연 다른 세션일 수 있다 — 이 세션이 뜨기 전에 끝난 기록은 이 방 것이 아니다
        try:
            if path.stat().st_mtime < _session_born(str(rec.get("tmux") or "")):
                return None
        except OSError:
            return None
    if not path:
        return None
    try:
        import marina_discord_usage
        return marina_discord_usage.context_percent(path)
    except Exception:
        return None


_BG_SHELL = re.compile(r"Command running in background with ID: (\w+)")
_BG_AGENT = re.compile(r"agentId: (\w+)")
_BG_MOVED = re.compile(r"moved to the background \(ID: (\w+)\)")   # 시간 초과로 하네스가 백그라운드로 옮긴 명령(실측)
_MONITOR_START = re.compile(r"Monitor started \(task (\w+)(?:, (?:timeout (\d+)ms|expires in ([^)]*)))?")
_MONITOR_DEFAULT_S = 3600.0        # 만료 시각을 못 읽으면 이만큼 지나야 끝난 것으로(막는 쪽)
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


def _scan_tasks(transcript: Path, monitors: "dict[str, dict[str, Any]] | None" = None) -> tuple[dict[str, dict[str, Any]], set[str]]:
    """monitors 를 주면 Monitor 도구로 건 감시({id: {"at": 시작 시각(0=모름), "ttl": 만료까지 초}})도 채운다 — 셸·에이전트 목록과는 따로(대시보드 표시를 안 바꾼다)."""
    try:
        data = _tail_text(transcript)          # 끝 2MB 만 seek 로(통째로 읽지 않는다)
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
                if b.get("name") == "Monitor":
                    bg_use[str(b.get("id"))] = "monitor"
                if b.get("name") in ("TaskStop", "KillShell", "KillBash"):    # 손으로 끈 건 알림이 없다(실측)
                    done.add(str(b["input"].get("task_id") or b["input"].get("shell_id") or b["input"].get("bash_id") or ""))
            elif b.get("type") == "tool_result":
                # 백그라운드로 띄운 도구의 결과만 — 동기 에이전트 결과·파일 내용 속 같은 글자는 무시(리뷰 I1)
                kind = bg_use.get(str(b.get("tool_use_id")))
                if not kind:
                    continue
                if kind == "monitor":
                    for t in _texts(b.get("content")):
                        m = _MONITOR_START.search(t)
                        if m and monitors is not None:
                            monitors[m.group(1)] = {"at": _row_time(row), "ttl": float(m.group(2)) / 1000.0 if m.group(2) else _MONITOR_DEFAULT_S}
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
            # 상태 문구 뒤엔 칸 맞춤 공백이 길게 붙는다 — 접어서 80자로. "pane" = 화면에서만 본 것(보기 목록의 중복 제거용 표시, 개수엔 영향 없음)
            out.append({"id": m.group(1), "kind": "agent", "desc": " ".join(m.group(2).split())[:120], "pane": True})
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


def _recent_agents(tr: Path, born: float = 0.0, fresh: float = AGENT_FRESH) -> list[dict[str, Any]]:
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
        if now - m > fresh or m < born:
            continue
        try:
            meta = json.loads(f.with_suffix(".meta.json").read_text())
        except (OSError, ValueError):
            meta = {}
        if not isinstance(meta, dict):
            meta = {}
        out.append({"id": f.stem[len("agent-"):], "kind": "agent", "desc": str(meta.get("description") or meta.get("name") or "")[:80],
                    # 팀 에이전트의 agentType 은 붙인 이름이다 — 역할은 customAgentType 에(실측 2026-10-06)
                    "role": str(meta.get("customAgentType") or meta.get("agentType") or ""), "model": str(meta.get("model") or ""),
                    "name": str(meta.get("name") or "")})
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
    import marina_discord_wake as mw
    try:
        wake_on = mw.enabled(ms.load_config())
    except ms.SessionError:
        wake_on = False
    for rec in ms.load_sessions():
        if str(rec.get("kind") or "").endswith("lobby") or not rec.get("channelId"):
            continue
        alive, busy = _pane_busy(str(rec.get("tmux") or ""))
        bg = alive and (_pane_shells(str(rec.get("tmux") or "")) > 0 or bool(_pane_team(str(rec.get("tmux") or "")))
                        or (not busy and _has_recent_agents(rec)))
        act = ms._activity_state(Path(str(rec.get("stateDir") or "/nonexistent")))
        rows.append({"ref": f"{rec.get('project')}/{rec.get('task')}", "channelId": str(rec["channelId"]),
                     "alive": alive, "busy": busy, "bg": bg, "emoji": str(act.get("emoji") or "") if busy else "",
                     "wakeable": (not alive) and wake_on and Path(str(rec.get("root") or "/nonexistent")).is_dir(),   # 글을 쓰면 깨어나는 방
                     "ctx": _ctx_percent(rec) if alive and full else None,
                     "tasks": live_tasks(rec) if alive and full else [],
                     "asking": alive and full and (Path(str(rec.get("stateDir") or "/nonexistent")) / "question.json").exists(),
                     "permission": alive and full and _pane_permission(str(rec.get("tmux") or ""))})
    if not full:
        # 뒤에서 도는 일(셸·팀 에이전트)도 '바쁨'으로 쳐서 #상태를 30초마다 — 끝나면 바로 보이게(입력 중 표시는 busy·도는 에이전트만)
        return {"sessions": rows, "anyBusy": any(r["busy"] or r["bg"] for r in rows)}
    try:
        free = shutil.disk_usage(str(Path.home())).free
    except OSError:
        free = 0
    try:
        load = os.getloadavg()[0]
    except OSError:
        load = 0.0
    use = _usage()
    try:
        ru = role_usage(_week_start(use))
    except Exception:
        ru = []
    try:
        stats = sys_stats()
    except Exception:
        stats = {}
    return {**stats, "usage": use, "roleUsage": ru, "diskFree": free, "load": load, "sessions": rows,
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


def _agent_roles() -> dict[str, str]:
    """agent_id → '역할(모델)' — role-hook 시작 이벤트(끝 500KB). 역할 아닌 서브에이전트는 없음."""
    try:
        with open(_role_events_path(), "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 500_000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return {}
    out: dict[str, str] = {}
    for raw in lines:
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("ev") == "start" and ev.get("agent") and ev.get("role") not in (None, "-"):
            out[str(ev["agent"])] = f"{ev['role']}({ev.get('model')})"
    return out


def _agent_efforts() -> dict[str, str]:
    """agent_id → effort — role-hook 시작 이벤트(끝 500KB). 에이전트 기록·meta 에는 effort 가 없다."""
    try:
        with open(_role_events_path(), "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 500_000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return {}
    out: dict[str, str] = {}
    for raw in lines:
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("ev") == "start" and ev.get("agent") and ev.get("effort"):
            out[str(ev["agent"])] = str(ev["effort"])
    return out


def _tasks_desc(r: dict[str, Any]) -> str:
    """무슨 일인지 한 줄(설명만 — 명령 원문 아님). 역할 에이전트면 앞에 역할(모델)."""
    t = r.get("tasks") or []
    roles = _agent_roles() if any(x["kind"] == "agent" for x in t) else {}
    def one(x: dict[str, Any]) -> str:
        who = roles.get(x["id"], "") if x["kind"] == "agent" else ""
        return f"{'⏳' if x['kind'] == 'shell' else '🤖'} " + (who + " " if who else "") + _clean(x["desc"] or x["id"])[:50]
    d = " · ".join(one(x) for x in t[:4])
    return f"\n-# {d}" if d else ""


def _view_button(r: dict[str, Any]) -> dict[str, Any]:
    return {"type": 2, "style": 2, "label": "보기", "custom_id": VIEW_PREFIX + r["channelId"]}


def render(snap: dict[str, Any]) -> list[dict[str, Any]]:
    """#상태 메시지(Components V2). 섹션: 작업 중(줄마다 정지 버튼) · 대기 · 잠듦(글을 쓰면 깨어남) · 꺼짐. 같으면 고쳐 쓰지 않는다.
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
    asleep = [r for r in rows if not r["alive"] and r.get("wakeable")]
    off = [r for r in rows if not r["alive"] and not r.get("wakeable")]
    # 메시지당 구성요소 40개(중첩 포함) — 아래 백그라운드 머리·'외 N개'·대기·잠듦·꺼짐·꼬리말 몫(9)을 남기고 넘치면 '외 N개'(리뷰 I2)
    room = [40 - 9 - (2 if snap.get("roleUsage") else 0) - _count(out) - 4]
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
    if snap.get("roleUsage"):
        out.append({"type": 14})
        out.append(_text(_role_block(snap["roleUsage"])))
    out.append({"type": 14})
    out.append(_text(f"### 💤 대기 {len(idle)}" + "".join("\n" + _row(r, proj_w) for r in idle)))
    if asleep:
        out.append({"type": 14})
        out.append(_text(f"### 🌙 잠듦 {len(asleep)}\n-# 글을 쓰면 깨어나" + "".join("\n" + _row(r, proj_w) for r in asleep)))
    if off:
        out.append({"type": 14})
        out.append(_text(f"### ⚫ 꺼짐 {len(off)}" + "".join("\n" + _row(r, proj_w) for r in off)))
    return out


def _cmd_out(argv: list[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=3).stdout or ""
    except Exception:
        return ""


def heavy_counts() -> "tuple[int, int] | None":
    """무거운 명령 줄(heavy — 맥 전체에서 빌드·테스트를 동시에 몇 개만)의 (실행, 대기) 수. 줄 장치가 없으면 None.
    상태 폴더의 파일만 읽는다(잠금은 건드리지 않는다): slot-N.json 은 자리를 쥔 동안만, waiting-<pid>.json 은 기다리는 동안만 있다.
    죽은 프로세스가 남긴 파일은 세지 않는다."""
    d = Path(os.environ.get("HEAVY_HOME") or Path.home() / ".local/state/heavy")
    if not d.is_dir():
        return None

    def alive(pid: Any) -> bool:
        try:
            os.kill(int(pid), 0)
            return True
        except PermissionError:
            return True
        except (OSError, ValueError, TypeError, OverflowError):
            return False
    running = waiting = 0
    for f in d.glob("slot-*.json"):
        try:
            running += alive(json.loads(f.read_text(encoding="utf-8")).get("pid"))
        except (OSError, ValueError, AttributeError):
            pass
    for f in d.glob("waiting-*.json"):
        waiting += alive(f.stem[len("waiting-"):])
    return running, waiting


def sys_stats() -> dict[str, Any]:
    """CPU·메모리 — 못 읽은 값은 None(그 항목은 안 그린다). 맥 기준이고 리눅스에서는 CPU 만 나온다."""
    out: dict[str, Any] = {"cpu": None, "ncpu": os.cpu_count() or None, "memUsed": None, "memLevel": None, "swapUsed": None,
                           "heavy": heavy_counts()}
    try:                                   # 모든 프로세스의 %CPU 합 ÷ 코어 수 = 전체 중 몇 %
        out["cpu"] = sum(float(x) for x in _cmd_out(["ps", "-A", "-o", "%cpu="]).split()) / (out["ncpu"] or 1)
    except ValueError:
        pass
    m = re.search(r"free percentage:\s*(\d+)%", _cmd_out(["memory_pressure"]))
    if m:
        out["memUsed"] = 100.0 - float(m.group(1))
    lv = _cmd_out(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    if lv.isdigit():
        out["memLevel"] = int(lv)          # 1 정상 · 2 경고 · 4 위험(macOS 가 스스로 매긴다)
    m = re.search(r"used = ([\d.]+)([MG])", _cmd_out(["sysctl", "-n", "vm.swapusage"]))
    if m:
        out["swapUsed"] = float(m.group(1)) * (1 << 30 if m.group(2) == "G" else 1 << 20)
    return out


def _gb(n: float) -> str:
    g = n / (1 << 30)
    return f"{g:.0f}GB" if g >= 20 else f"{g:.1f}GB"


def cpu_text(cpu: "float | None", load: "float | None", ncpu: "int | None") -> str:
    """부하 숫자(load) 대신: 전체 코어 중 몇 % 를 쓰나 + 코어 수보다 일이 많으면 '밀림 N배'(형 2026-10-06)."""
    if cpu is None or not ncpu:
        return ""
    pct = min(100, round(cpu))
    wait = (load or 0.0) / ncpu
    light = "🔴" if pct >= 90 or wait >= 2 else "🟡" if pct >= 70 or wait >= 1 else "🟢"
    return f"CPU {light} {pct}%" + (f" · 밀림 {wait:.1f}배" if wait >= 1 else "")


def mem_text(used: "float | None", level: "int | None", swap: "float | None") -> str:
    if used is None:
        return ""
    if level is None:
        light = "🔴" if used >= 90 else "🟡" if used >= 80 else "🟢"
    else:
        light = "🔴" if level >= 4 else "🟡" if level >= 2 else "🟢"
    return f"메모리 {light} {round(used)}%" + (f" · 스왑 {_gb(swap)}" if swap and swap >= (1 << 30) else "")


def heavy_text(counts: "tuple[int, int] | None") -> str:
    if not counts or not (counts[0] or counts[1]):
        return ""
    return f"🧪 실행 {counts[0]}" + (f" · 대기 {counts[1]}" if counts[1] else "")


def footer(snap: dict[str, Any]) -> str:
    parts = [f"디스크 {snap.get('diskFree', 0) // (1 << 30)}GB 남음",
             cpu_text(snap.get("cpu"), snap.get("load"), snap.get("ncpu")),
             mem_text(snap.get("memUsed"), snap.get("memLevel"), snap.get("swapUsed")),
             heavy_text(snap.get("heavy")),
             f"<t:{int(time.time())}:R> 갱신"]
    return "-# " + " · ".join(p for p in parts if p)


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


def typing_tick(snap: dict[str, Any], ty: dict[str, float], now: float, agents: "set[str] | None" = None) -> None:
    # 뒤에서 서브에이전트가 도는 채널(agents)에도 켠다 — 채널만 봐선 멈춘 건지 도는 건지 몰랐다(형 2026-10-06).
    # snap 의 bg 는 안 쓴다: 끝난 에이전트가 5분 남고, 오래 떠 있는 셸·쉬는 팀원 목록에도 켜진다(리뷰 I1)
    busy = sorted({r["channelId"] for r in snap["sessions"] if r["busy"]} | (agents or set()))
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


def _words_line(text: str) -> str:
    """에이전트 마지막 말 → 첫 줄 한 줄 140자. 목록 기호·굵게·백틱은 풀고, 번역하지 않는다."""
    for ln in str(text).splitlines():
        ln = re.sub(r"^[\s>#*+\-•]+", "", ln).replace("**", "").replace("`", "")
        ln = " ".join(ln.split())
        if ln:
            return ln[:139] + "…" if len(ln) > 140 else ln
    return ""


_PANE_TAIL = re.compile(r"\s+(?:(\d+)m\s*)?\d+s\s*·.*$")


def _pane_now(text: str) -> str:
    """화면 상태 문구 끝의 '11m 30s · ↓ 194.7k tokens' 는 '· 11분' 으로 줄인다(초 단위만이면 뗀다)."""
    m = _PANE_TAIL.search(text)
    return text if not m else text[:m.start()] + (f" · {m.group(1)}분" if m.group(1) else "")


def _view_agents(tr: Path, tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """[보기] 표시용 — 같은 에이전트는 한 번만. 화면 아래 팀 목록 줄('pane')은 기록의 에이전트와 같은 이름·같은 역할·같은 설명이면
    그 항목에 합친다(항목의 "now" = 화면 상태 문구) — 같은 역할이 여럿이면 순서대로 짝짓는다. 짝이 없는 줄만 남는다.
    개수 판정(live_tasks 를 쓰는 #상태·restart_blockers)은 이 목록을 안 쓴다 — 표시만 합친다."""
    def norm(x: str) -> str:
        return " ".join(str(x).split())
    recs = [t for t in tasks if not t.get("pane") and t["kind"] == "agent"]
    for t in recs:
        try:
            meta = json.loads((tr.parent / tr.stem / "subagents" / f"agent-{t['id']}.meta.json").read_text())
        except (OSError, ValueError):
            meta = {}
        meta = meta if isinstance(meta, dict) else {}
        t["name"] = str(t.get("name") or meta.get("name") or "")
        t["role"] = str(t.get("role") or meta.get("customAgentType") or meta.get("agentType") or "")
    free = list(recs)
    out = []
    for t in tasks:
        if not t.get("pane"):
            out.append(t)
            continue
        pair = next((r for r in free if r["name"] == t["id"]), None) or next((r for r in free if norm(r["desc"]) == norm(t["desc"])), None) \
            or next((r for r in free if r["role"] == t["id"]), None)      # 이름 → 설명 → 역할 — 같은 역할이 여럿일 때 엉뚱한 항목에 붙는 걸 줄인다
        if pair:
            free.remove(pair)
            pair["now"] = t["desc"]
        else:
            out.append(t)
    return out


def view(channel: str, user: str) -> str:
    """[보기]: 뒤에서 도는 셸의 출력 끝·에이전트의 마지막 말. 응답은 공개(#상태 채널을 보는 사람 누구나 — bot.ts 가 deferReply 를 공개로 한다).
    명령 원문은 안 보낸다(설명만)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    if not _allowed(rec, channel, user, _dc(ms.load_config())):
        return "볼 권한이 없어"
    tr = _session_transcript(rec)
    tasks = _view_agents(tr, live_tasks(rec)) if tr else []
    if not tasks or not tr:
        return "지금 뒤에서 도는 일은 없어"
    parts = []
    budget = max(120, 1800 // len(tasks))
    titles = [_clean(t["id"] if t.get("pane") else (t["desc"] or t["id"])).strip()[:80] for t in tasks]
    for t, title in zip(tasks[:12], titles):
        if t["kind"] == "agent" and titles.count(title) > 1:
            title += " #" + _agent_tag(t["id"], str(t.get("name") or ""))      # 같은 설명으로 둘 띄움 — 진행 줄과 같은 꼬리표
        head = f"{'⏳' if t['kind'] == 'shell' else '🤖'} **{title}**"
        room = max(40, budget - len(head) - 12)
        if t["kind"] == "agent" and not t.get("pane") and t.get("now"):
            room = max(40, room - len(f"\n지금: {_clean(_pane_now(t['now']))}"))      # 지금: 줄도 예산에 넣는다
        if t["kind"] == "shell":
            p = _task_output(tr, t["id"])
            try:
                tail = _clean(p.read_bytes()[-4000:].decode("utf-8", "replace")) if p else ""
            except OSError:
                tail = ""
            body = "\n".join(tail.rstrip().splitlines()[-8:])[-room:].replace("```", "ʼʼʼ")
            parts.append(head + ("\n```\n" + body + "\n```" if body else "\n-# 출력 없음"))
        elif t.get("pane"):
            parts.append(head + (f"\n지금: {_clean(_pane_now(t['desc']))}" if t["desc"] else "\n-# 아직 말 없음"))
        else:
            words = _clean(_words_line(_agent_last_words(tr, t["id"])))[:room]
            now = f"\n지금: {_clean(_pane_now(t['now']))}" if t.get("now") else ""
            parts.append(head + now + ("\n" + words if words else ("" if now else "\n-# 아직 말 없음")))
    if len(parts) == len(tasks) and len("\n".join(parts)) <= 1900:
        return "\n".join(parts)
    out, shown, cap = "", 0, 1900 - 16          # 16 = 맨 끝 "… 외 N개" 줄 자리
    for part in parts:                 # 조각 단위로 자른다 — 코드 펜스가 중간에 끊기지 않게(리뷰 M2)
        if len(out) + len(part) + 1 > cap:
            break
        out += ("\n" if out else "") + part
        shown += 1
    if not out:
        out, shown = parts[0][:cap], 1
    return out + f"\n… 외 {len(tasks) - shown}개"


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


def _clean(text: str) -> str:
    """Discord 로 내보내는 셸 출력: 제어문자 제거 + 흔한 비밀 모양 가리기(리뷰 I7)."""
    return ms.clean_output(text)
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


SLEEPING_TEXT = "이 방은 잠들어 있어 — 글을 쓰면 깨어나"


def _term_rec(channel: str) -> "dict[str, Any] | None":
    """터미널을 요청한 개발 세션 기록 — 모르는 채널(지워진 방)·채팅 세션이면 None(ask_terminal 은 개발 세션 전용)."""
    rec = next((x for x in ms.load_sessions() if channel and str(x.get("channelId")) == channel), None)
    return None if not rec or rec.get("kind") in ms.CHAT_KINDS else rec


def notify_term_done(token: str, data: dict) -> None:
    """ask_terminal 로 넘긴 명령이 끝났다 — 켜진 세션엔 **내용 없는** 고정 문구만 입력창에(턴 중이면 기다렸다 친다), 꺼진 방은 깨우지 않고
    채널에 조용한 한 줄. 화면은 사람이 페이지에서 넘길 때만 간다(share_term_screen). 채널 POST 가 429 아닌 4xx 로 실패하면 다시 해도 같으니 닫는다."""
    channel = str(data.get("channel") or "")
    rec = _term_rec(channel)
    if not rec:
        return
    if ms.tmux_alive(str(rec.get("tmux") or "")):
        _spawn_type(str(rec["tmux"]), TERM_DONE_TEXT, channel, "")
        return
    try:
        _dc(ms.load_config())._req("POST", f"/channels/{channel}/messages",
                                   {"content": TERM_DONE_LINE, "flags": 4096, "allowed_mentions": {"parse": []}})
    except ms.DiscordError as exc:
        if exc.code == 429 or exc.code >= 500:
            raise
        _log(f"term done: 꺼진 방 알림을 못 올려 닫음({exc.code})")


def share_term_screen(token: str) -> dict[str, Any]:
    """페이지의 [화면 끝 40줄을 세션에 넘기기] — 호출 쪽(서버)이 쿠키 주인·Origin 을 이미 확인했다.
    끝 40줄을 `[보기]` 와 같은 비밀 가림으로 <상태 폴더>/term-last-<tmux id>.txt(0600)에 쓰고 세션에 두 번째 고정 문구를 친다.
    돌려줌: {"ok": True} | {"ok": False, "reason": "asleep"(세션 꺼짐) | "failed"}."""
    import marina_termbridge as tb
    data = tb._load(token) or {}
    rec = _term_rec(str(data.get("channel") or ""))
    if not rec or not rec.get("stateDir"):
        return {"ok": False, "reason": "failed"}
    if not ms.tmux_alive(str(rec.get("tmux") or "")):
        return {"ok": False, "reason": "asleep"}
    dest = Path(str(rec["stateDir"])) / f"term-last-{str(data['tmux']).removeprefix('term-')}.txt"
    if not _TERM_PATH_RE.fullmatch(str(dest)):          # 허용 밖 문자가 든 경로는 입력창에 치지 않는다
        return {"ok": False, "reason": "failed"}
    if not tb.save_tail(token, dest, clean=ms.clean_output):
        return {"ok": False, "reason": "failed"}
    _spawn_type(str(rec["tmux"]), f"{TERM_SHARE_PRE}{dest}{TERM_SHARE_POST}", str(data["channel"]), "")
    return {"ok": True}


def say(channel: str, user: str, message: str = "") -> str:
    """[▶ 추천] 누름: 한 번만. 허용 명령은 그대로, 글은 '[Discord 추천 버튼]' 을 붙여 입력창에(답은 Discord 로 — 규칙).
    누른 버튼이 지금 추천의 메시지가 아니면(남은 옛 버튼) 치지 않고 그 버튼을 뗀다(리뷰 I3)."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    dc = _dc(ms.load_config())
    if not _allowed(rec, channel, user, dc):
        return "누를 권한이 없어"
    if not ms.tmux_alive(str(rec.get("tmux") or "")):
        return SLEEPING_TEXT
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
    if not ms.tmux_alive(str(rec.get("tmux") or "")):
        return SLEEPING_TEXT
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
_NO = re.compile(r"^\s*[23]\.\s*No\s*$")
PANE_PERM_TTL = 600.0


def _pane_prompt(name: str) -> "tuple[str, list[str], str, bool] | None | bool":
    """화면 아래 권한 창 → (서명, 머리말, 명령 앞부분, 누를 수 있나). 창이 없으면 None, 화면을 못 읽으면 False(판단 보류 — 리뷰 I7).
    머리말 = 질문 위로 구분선(─)까지의 설명 줄. 서명은 머리말~선택지 끝까지(다른 창·다른 선택지면 달라진다).
    누를 수 있음 = 1번이 정확히 '❯ 1. Yes', 끝이 'No' 인 2·3지선다 — 그 밖의 창(폴더 신뢰 등)엔 Enter 를 안 친다(리뷰 C1)."""
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
    # 2지선다(Yes/No) 또는 3지선다(Yes / Yes, and don't ask again… / No) — 어느 쪽이든 1번 평범한 Yes 에서 Enter = 이번 한 번
    ok = len(opts) in (2, 3) and bool(_YES.match(opts[0])) and bool(_NO.match(opts[-1]))
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
            else "\n-# 평범한 Yes/No 창이 아니라 버튼을 안 달았어 — 터미널에서 골라 줘")
    body: dict[str, Any] = {"content": title + tail, "allowed_mentions": {"parse": []}}
    if ok:
        body["components"] = [{"type": 1, "components": [
            {"type": 2, "style": 3, "label": "한 번만 허용", "custom_id": f"mperm:a:{ch}:{token}"},
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


def _role_events_path() -> Path:
    return Path(os.environ.get("ROLE_EVENTS") or Path.home() / ".local/state/roles/events.jsonl")


def _fmt_secs(x: Any) -> str:
    if not isinstance(x, (int, float)):
        return ""
    x = int(x)
    if x < 60:
        return f"{x}초"
    if x < 3600:
        return f"{x // 60}분"
    return f"{x // 3600}시간 {x % 3600 // 60}분"


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    return f"{round(n / 1000)}k" if n >= 1000 else str(n)


def _agent_tag(agent_id: str, name: str = "") -> str:
    """에이전트 꼬리표 — 줄들이 같은 에이전트 것인지 새로 뜬 것인지 구분(형 2026-10-06). 붙인 이름이 있으면 그것, 없으면 id 끝 4자."""
    return _clean(name)[:24] if name else agent_id[-4:]


def _fmt_role_event(ev: dict[str, Any]) -> str:
    """역할 이벤트 한 줄(role-hook 형식). 비역할 서브에이전트는 '서브에이전트'. 진행 줄(agent_words_tick)과 같은 꼬리표를 붙인다."""
    role = str(ev.get("role") or "-")
    who = role if role != "-" else "서브에이전트"
    if ev.get("agent"):
        who += "#" + _agent_tag(str(ev["agent"]))
    desc = _clean(str(ev.get("desc") or ""))[:80]
    kind = ev.get("ev")
    if kind == "override_blocked":
        return f"⚠️ {who} 모델 지정({ev.get('asked')}) 무시 — 역할표대로 {ev.get('model')}"
    if kind == "start":
        parts = [f"🤖 {who} 시작"]
        if role != "-":
            parts.append(f"{ev.get('model')}/{ev.get('effort')}" if ev.get("effort") else str(ev.get("model")))
            sk = [str(x).split(":")[-1] for x in ev.get("skills") or []]
            if sk:
                parts.append(", ".join(sk))
        if desc:
            parts.append(desc)
        return " · ".join(parts)
    if kind == "stop":
        t = ev.get("tokens") if isinstance(ev.get("tokens"), dict) else {}
        n = sum(int(t.get(k) or 0) for k in ("in", "out", "cache_write"))
        return " · ".join([f"✅ {who} 끝"] + [x for x in (_fmt_secs(ev.get("secs")), _fmt_tokens(n)) if x])
    return ""


ROLE_EVENTS_MAX = 20
ROLE_ROWS = 6


def _week_start(usage: list[dict[str, Any]]) -> float:
    """이번 주 시작 = 주간 한도 리셋 − 7일. 모르면 최근 7일."""
    for w in usage or []:
        if w.get("key") == "weekly" and isinstance(w.get("resetsAt"), (int, float)):
            return float(w["resetsAt"]) - 7 * 86400
    return time.time() - 7 * 86400


def role_usage(since: float) -> list[dict[str, Any]]:
    """역할별 호출 수·토큰(입력+출력+캐시 쓰기 — 캐시 읽기는 싸서 뺀다)·모델. 많은 순, 비역할·넘친 역할은 '기타'."""
    try:
        with open(_role_events_path(), "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 4_000_000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    agg: dict[str, dict[str, Any]] = {}
    last: dict[str, dict[str, Any]] = {}
    stops: list[dict[str, Any]] = []
    for raw in lines:
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("ev") != "stop" or float(ev.get("ts") or 0) < since:
            continue
        aid = ev.get("agent")
        if aid:                                       # SendMessage 로 이어 쓰면 같은 id 로 stop 이 또 난다 — 토큰은 누적값이라 창 안 마지막 것만
            if str(aid) in last and float(last[str(aid)].get("ts") or 0) > float(ev.get("ts") or 0):
                continue
            last[str(aid)] = ev
            continue
        stops.append(ev)                              # agent 칸 없는 옛 이벤트는 줄마다
    stops.extend(last.values())
    for ev in stops:
        t = ev.get("tokens") if isinstance(ev.get("tokens"), dict) else {}
        n = sum(int(t.get(k) or 0) for k in ("in", "out", "cache_write"))
        if not n:
            continue                                  # 토큰 0 = 하네스 내부·기록 못 읽음 — 통계에서 뺀다
        role = str(ev.get("role") or "-")
        if role == "-":                               # 비역할은 종류(Explore·general-purpose …)로, 모르면 기타(형 2026-10-04)
            role = str(ev.get("type") or "-")
            role = "기타" if role == "-" else role
        a = agg.setdefault(role, {"role": role, "calls": 0, "tokens": 0, "models": []})
        a["calls"] += 1
        a["tokens"] += n
        for m in ev.get("models") or []:
            m = str(m).replace("claude-", "", 1)
            if m not in a["models"]:
                a["models"].append(m)
    rows = sorted((a for a in agg.values() if a["role"] != "기타"), key=lambda a: -a["tokens"])
    other = [agg["기타"]] if "기타" in agg else []
    if len(rows) > ROLE_ROWS - 1:
        extra = rows[ROLE_ROWS - 1:]
        rows = rows[:ROLE_ROWS - 1]
        o = other[0] if other else {"role": "기타", "calls": 0, "tokens": 0, "models": []}
        for a in extra:
            o["calls"] += a["calls"]; o["tokens"] += a["tokens"]
        other = [o]
    return rows + other


def _role_block(rows: list[dict[str, Any]]) -> str:
    w = max([12] + [len(r["role"]) + 1 for r in rows])     # general-purpose 같은 긴 종류 이름에도 줄이 맞게
    return "### 🤖 이번 주 역할별" + "".join(
        f"\n`{r['role']:<{w}}{r['calls']:>3}회  {_fmt_tokens(r['tokens']):>5}`" + (f" {','.join(r['models'])}" if r["models"] and r["role"] != "기타" else "")
        for r in rows)


def role_events_tick() -> None:
    """role-hook 이벤트 파일을 오프셋부터 읽어, Discord 세션이면 지금 지시 메시지 스레드에 한 줄씩(역할 에이전트 2026-10-04).
    파일이 줄었으면(회전) 처음부터. 깨진 줄·남의 세션·지시 메시지 없는 세션은 건너뛰고 오프셋만 전진."""
    path, off_f = _role_events_path(), ms.marina_home() / "role-events.offset"
    try:
        size = path.stat().st_size
    except OSError:
        return
    if not off_f.exists():                       # 처음(또는 지워짐) — 지난 일을 지금 스레드에 쏟지 않게 끝에서 시작(리뷰 I4)
        off_f.write_text(str(size))
        return
    try:
        off = int(off_f.read_text().strip() or 0)
    except (OSError, ValueError):
        off = size
    if off > size:
        off = 0
    if off == size:
        return
    with open(path, "rb") as fh:
        fh.seek(off)
        chunk = fh.read(256_000)
    lines = chunk.split(b"\n")[:-1][:ROLE_EVENTS_MAX]          # 끝나지 않은 마지막 줄은 다음 판에
    by_sid = {str(r.get("sessionId")): r for r in ms.load_sessions() if r.get("sessionId") and r.get("channelId")}
    try:
        _role_events_post(lines, off, by_sid, off_f)
    except Exception as exc:                      # 예상 밖 오류여도 오프셋은 보내기 전에 저장됨(리뷰 I5)
        _log(f"role event: {exc!r}")


def _role_events_post(lines: list[bytes], off: int, by_sid: dict[str, Any], off_f: Path) -> None:
    """한 판의 줄들은 스레드마다 메시지 하나로 묶는다 — 서브에이전트가 몰려도 도배 안 함(리뷰 M3)."""
    groups: dict[tuple[str, str], tuple[dict[str, Any], list[str]]] = {}
    for raw in lines:
        off += len(raw) + 1
        try:
            ev = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        rec = by_sid.get(str(ev.get("session") or "")) if isinstance(ev, dict) else None
        if not rec:
            continue
        mid = str(ms._activity_state(Path(str(rec.get("stateDir") or "/nonexistent"))).get("mid") or "")
        text = _fmt_role_event(ev)
        if not mid or not text:
            continue
        groups.setdefault((str(rec.get("stateDir")), mid), (rec, []))[1].append(text)
    off_f.write_text(str(off))                    # 보내기 전에 — 보내다 죽어도 같은 줄을 다시 안 보낸다
    for (_, mid), (rec, texts) in groups.items():
        chunks, cur = [], ""
        for t in texts:                               # 1900자에서 잘리지 않게 줄 경계로 나눈다(리뷰 I1)
            if cur and len(cur) + 1 + len(t) > 1900:
                chunks.append(cur); cur = ""
            cur = (cur + "\n" + t) if cur else t[:1900]
        if cur:
            chunks.append(cur)
        for c in chunks:
            try:
                ms._progress(rec, {"message_id": mid, "text": c})
            except Exception as exc:                  # 한 그룹 실패가 나머지를 막지 않게(리뷰 M3)
                _log(f"role event: {exc!r}")


AGENT_WORDS_EVERY = 120.0    # 에이전트마다 — 하는 일이 바뀌어도 이보다 자주는 안 올린다(도배 방지)
AGENT_WORDS_MAX = 6          # 한 판에 올리는 줄 수 — 메시지 길이 제한(1900자) 안쪽


def _agent_ends(path: Path) -> tuple[bytes, bytes]:
    """기록의 앞 20KB · 끝 300KB 만 — 수십 MB 기록을 30초마다 통째로 읽지 않게(리뷰 M2)."""
    with open(path, "rb") as fh:
        head = fh.read(20_000)
        size = fh.seek(0, 2)
        fh.seek(max(0, size - 300_000))
        return head, fh.read()


def _agent_finished(tail: bytes) -> bool:
    """마지막 줄이 end_turn 인 assistant = 끝난 에이전트. 동기·중첩·팀 에이전트는 끝남 알림이 본 기록에 안 찍힌다(리뷰 I2)."""
    for raw in reversed(tail.decode("utf-8", "replace").splitlines()):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except ValueError:
            return False
        return (isinstance(row, dict) and row.get("type") == "assistant"
                and (row.get("message") or {}).get("stop_reason") == "end_turn")
    return False


_MODEL_USED = re.compile(r'"model"\s*:\s*"(claude-[\w.-]+)"')


def _short_model(model: str) -> str:
    """claude-sonnet-5-5 → 'sonnet 5.5' · claude-haiku-4-5-20251001 → 'haiku 4.5'. 이미 짧은 이름(sonnet · inherit)은 그대로."""
    m = re.match(r"claude-([a-z]+)(?:-(\d+)(?:-(\d{1,2}))?(?!\d))?", model)
    if not m:
        return model
    ver = ".".join(x for x in (m.group(2), m.group(3)) if x)
    return m.group(1) + (f" {ver}" if ver else "")


def _agents_running(rec: dict[str, Any], fresh: float = AGENT_FRESH) -> list[dict[str, Any]]:
    """지금 도는 서브에이전트 + 그 기록 파일. 끝남 알림이 왔거나 기록이 end_turn 으로 끝난 것은 뺀다.
    채팅방 세션은 Agent 도구가 없다 — 보지 않는다(혼잣말이 방 사람들에게 나가지 않게, 리뷰 M3)."""
    name = str(rec.get("tmux") or "")
    if rec.get("kind") in ms.CHAT_KINDS or not name or not ms.tmux_alive(name):
        return []
    tr = _session_transcript(rec)
    recent = _recent_agents(tr, _session_born(name), fresh) if tr else []
    if not tr or not recent:
        return []
    done = _scan_tasks(tr)[1]
    d = tr.parent / tr.stem / "subagents"
    out = []
    for a in recent:
        p = d / f"agent-{a['id']}.jsonl"
        try:
            tail = _agent_ends(p)[1]
        except OSError:
            continue
        if a["id"] in done or _agent_finished(tail):
            continue
        used = _MODEL_USED.findall(tail.decode("utf-8", "replace"))      # meta 는 지정값(sonnet) — 실제 쓴 모델·버전은 기록에
        out.append(dict(a, path=p, model=_short_model(used[-1] if used else str(a.get("model") or ""))))
    return out


def _one_line(text: Any) -> str:
    """첫 줄만 · 코드 펜스가 묶음 메시지를 깨지 않게(리뷰 M8)."""
    lines = str(text).strip().splitlines()
    return _clean(lines[0] if lines else "").replace("`" * 3, "'")


def _agent_now(path: Path) -> tuple[str, float]:
    """(지금 하는 일 한 줄, 시작 시각). 마지막 assistant 줄의 마지막 조각 — 글이면 첫 줄, 도구면 설명(명령 원문은 안 쓴다)."""
    try:
        head, tail = _agent_ends(path)
    except OSError:
        return "", 0.0
    born = 0.0
    try:
        first = json.loads(head.split(b"\n", 1)[0].decode("utf-8", "replace"))
        born = datetime.datetime.fromisoformat(str(first.get("timestamp") or "").replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        pass
    doing = ""                                        # 설명 없는 도구 호출(예: '명령 실행 중') — 직전에 한 말을 찾아 붙인다
    for raw in reversed(tail.decode("utf-8", "replace").splitlines()):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        content = (row.get("message") or {}).get("content")
        for b in reversed(content if isinstance(content, list) else []):
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and not doing:
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                # 설명은 '하는 일'을 적는 도구 것만 — 다른 도구의 description 은 본문일 수 있다(리뷰 M3)
                desc = str(inp.get("description") or "").strip() if b.get("name") in ("Bash", "Agent", "Task") else ""
                if desc:
                    return _one_line(desc)[:140], born
                _, label, what = ms.tool_activity(str(b.get("name") or ""), inp)
                doing = _clean(label + (f" {what}" if what else ""))[:60]
            elif b.get("type") == "text" and str(b.get("text") or "").strip():
                said = _one_line(b["text"])[:140]
                return (f"{said} ({doing})" if doing else said), born
    return doing, born


def agent_words_tick(st: dict[str, tuple[str, float]], now: float) -> set[str]:
    """뒤에서 도는 서브에이전트가 지금 뭘 하는지 지시 스레드에 한 줄씩 쌓는다 — 시작·끝 줄만으론 그 사이가 비었다
    (형 2026-10-06 "작업중인거 안 보이니까 답답"). 하는 일이 바뀐 에이전트만, 에이전트마다 AGENT_WORDS_EVERY 에 한 번.
    돌려주는 것 = 에이전트가 도는 채널들('입력 중…' 을 켤 곳)."""
    seen: set[str] = set()
    live: set[str] = set()
    failed = False
    efforts: "dict[str, str] | None" = None           # 올릴 줄이 있을 때만 읽는다
    for rec in ms.load_sessions():
        if not rec.get("channelId") or not rec.get("stateDir"):
            continue
        try:
            agents = _agents_running(rec)
        except Exception as exc:
            failed = True
            _log(f"agent_words {rec.get('tmux')}: {exc!r}")
            continue
        if agents:
            live.add(str(rec["channelId"]))
        seen.update(str(a["id"]) for a in agents)
        mid = str(ms._activity_state(Path(str(rec["stateDir"]))).get("mid") or "")
        if not mid:
            continue
        lines: list[str] = []
        for a in agents:
            aid = str(a["id"])
            words, born = _agent_now(Path(str(a["path"])))
            old = st.get(aid)
            if not words or (old and (old[0] == words or now - old[1] < AGENT_WORDS_EVERY)):
                continue
            if len(lines) >= AGENT_WORDS_MAX:         # 넘치는 건 기록하지 않고 다음 판에(리뷰 M5)
                break
            st[aid] = (words, now)
            age = f" · {_fmt_secs(max(0.0, now - born))}" if born else ""
            if efforts is None:
                efforts = _agent_efforts()
            model = "/".join(x for x in (str(a.get("model") or ""), efforts.get(aid, "")) if x)
            who = " · ".join(x for x in ((str(a.get("role") or "") + "#" + _agent_tag(aid, str(a.get("name") or ""))) if a.get("role") else "",
                                         model) if x)
            lines.append(f"🤖 {f'`{_clean(who)}` ' if who else ''}{_clean(str(a.get('desc') or aid))}{age} — {words}")
        if lines:
            try:
                ms._progress(rec, {"message_id": mid, "text": "\n".join(lines)})
            except Exception as exc:
                _log(f"agent_words: {exc!r}")
    if not failed:                                    # 한 번 못 읽었다고 지우면 다음 판에 같은 줄을 또 올린다(리뷰 M4)
        for aid in [k for k in st if k not in seen]:
            del st[aid]
    return live


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


# 터미널 끝 알림은 내용 없는 고정 문구 — 화면(prod 조회 결과·토큰이 있을 수 있다)은 사람이 넘길 때만 세션에 간다
TERM_DONE_TEXT = "[마리나] 터미널에서 넘긴 명령이 끝났어 — 결과는 형이 넘겨 주거나 말해 줄 때까지 기다려."
TERM_SHARE_PRE = "[마리나] 형이 터미널 화면을 넘겼어: "
TERM_SHARE_POST = " — 읽고 이어서 해. 내용을 Discord 에 그대로 옮기지 마."
TERM_SHARE_RE = re.compile(re.escape(TERM_SHARE_PRE) + r"(/[A-Za-z0-9._/-]+/term-last-[0-9a-f]+\.txt)" + re.escape(TERM_SHARE_POST))
_TERM_PATH_RE = re.compile(r"/[A-Za-z0-9._/-]+/term-last-[0-9a-f]+\.txt")
TERM_DONE_LINE = "🖥️ 터미널 명령이 끝났어"
TERM_WATCH_EVERY = 5.0


def typeable(text: str, channel: str = "") -> bool:
    """`type` 하위명령이 입력창에 칠 수 있는 글 — 추천 버튼·슬래시 표시가 붙은 글, 이어받기 안내, 터미널 끝 안내(고정 문구 정확 일치),
    화면 넘김 안내(고정 앞뒤 + 그 채널 상태 폴더 아래 term-last-<id>.txt 정확 경로 — channel 을 모르면 거절), 허용 명령만."""
    import marina_discord_wake as mw
    if text in (TERM_DONE_TEXT, ms.RESUME_TEXT, mw.WAKE_LATE_TEXT):
        return True
    m = TERM_SHARE_RE.fullmatch(text)
    if m:
        rec = next((x for x in ms.load_sessions() if channel and str(x.get("channelId")) == str(channel)), None)
        return bool(rec and rec.get("stateDir")) and os.path.dirname(m.group(1)) == str(rec["stateDir"])
    return ms.slash_allowed(text) or text.startswith((SUGGEST_MARK, SLASH_MARK))


RESTART_AGENT_FRESH = 1800.0     # 재시작 판정: 안 끝난 에이전트는 30분 조용해야 죽은 것으로 본다(긴 빌드·녹화로 5분 넘게 조용한 에이전트가 있었다, 2026-10-07 사고)
WAKEUP_GRACE = 120.0             # 예약 시각이 이만큼 지나도 안 울렸으면 죽은 예약
RESTART_QUIET = 60.0             # 막는 이유 없는 상태가 이만큼 이어져야 재시작한다


def _tail_text(path: Path, size: int = 2_000_000) -> str:
    """파일 끝 size 바이트만(seek) — 수십 MB 기록을 통째로 읽지 않는다."""
    with open(path, "rb") as fh:
        end = fh.seek(0, 2)
        fh.seek(max(0, end - size))
        return fh.read().decode("utf-8", "replace")


def _row_time(row: dict[str, Any]) -> float:
    try:
        return datetime.datetime.fromisoformat(str(row.get("timestamp") or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _live_monitors(tr: Path, born: float) -> list[str]:
    """Monitor 도구로 건 감시 중 안 끝난 것 — 끝남 알림(status)·TaskStop·만료 시각 경과로 끝난 것은 뺀다. 세션이 뜨기 전 것은 그 세션과 함께 죽었다.
    시작 시각을 못 읽으면 끝났는지 모르니 막는다."""
    mons: dict[str, dict[str, Any]] = {}
    _started, done = _scan_tasks(tr, mons)
    now = time.time()
    out = []
    for tid, m in mons.items():
        if tid in done:
            continue
        at = m["at"]
        if at and at < born:
            continue
        if at and at + m["ttl"] < now:
            continue
        out.append(tid)
    return out


_CRON_JOB = re.compile(r"\bjob (\w+)")


CRON_EXPIRE_S = 7 * 86400.0         # 결과 문구 "Auto-expires after 7 days" — 만든 지 이만큼 지난 예약은 이미 사라졌다


def _cron_next(expr: str, after: float) -> float:
    """숫자로만 적힌 5필드 크론 식(분 시 일 월 요일, 일·월·요일은 *도 가능)의 after 다음 발화 시각(로컬). 못 풀면 0."""
    f = str(expr).split()
    if len(f) != 5 or not f[0].isdigit() or not f[1].isdigit() or any(not (x == "*" or x.isdigit()) for x in f[2:]):
        return 0.0
    minute, hour = int(f[0]), int(f[1])
    base = datetime.datetime.fromtimestamp(after)
    for d in range(0, 400):
        day = (base + datetime.timedelta(days=d)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        if f[2] != "*" and day.day != int(f[2]) or f[3] != "*" and day.month != int(f[3]):
            continue
        if f[4] != "*" and (day.weekday() + 1) % 7 != int(f[4]) % 7:
            continue
        if day.timestamp() > after:
            return day.timestamp()
    return 0.0


def _pending_crons(tr: Path | None, born: float = 0.0) -> list[str]:
    """세션이 뜬(born) 뒤 CronCreate 로 걸었고 아직 끝나지 않은 예약들(세션 안에만 사는 작업 — 세션을 끄면 같이 죽는다).
    끝난 것: 그 job 의 CronDelete · 만든 지 7일 · recurring:false 인데 예정 시각이 지났거나 그 뒤 scheduled_task_fire 가 있음.
    job id 를 못 찾거나 시각·식을 못 읽으면 살아 있다고 본다. 기록 전체를 줄 단위로 훑는다(예약은 오래전에 걸렸을 수 있다)."""
    if not tr:
        return []
    created: dict[str, dict[str, Any]] = {}    # CronCreate tool_use id → {job, at, once, cron}
    deleted: set[str] = set()
    fires: list[float] = []
    with open(tr, "rb") as fh:
        for rawb in fh:
            if b"Cron" not in rawb and b"Scheduled" not in rawb and b"scheduled_task_fire" not in rawb:
                continue
            try:
                row = json.loads(rawb)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            if row.get("type") == "system" and row.get("subtype") == "scheduled_task_fire":
                fires.append(_row_time(row))
                continue
            content = (row.get("message") or {}).get("content")
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") == "CronCreate":
                    at = _row_time(row)
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    if not at or at >= born:
                        created[str(b.get("id") or "")] = {"job": "", "at": at, "once": inp.get("recurring") is False, "cron": inp.get("cron") or ""}
                elif b.get("type") == "tool_use" and b.get("name") == "CronDelete":
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    deleted.add(str(inp.get("id") or ""))
                elif b.get("type") == "tool_result" and str(b.get("tool_use_id") or "") in created:
                    res = b.get("content")
                    text = res if isinstance(res, str) else " ".join(str(x.get("text") or "") for x in res or [] if isinstance(x, dict))
                    m = _CRON_JOB.search(text)
                    if m:
                        created[str(b["tool_use_id"])]["job"] = m.group(1)
    now = time.time()
    live = []
    for tid, c in created.items():
        if c["job"] and c["job"] in deleted:
            continue
        at = c["at"]
        if at and now - at > CRON_EXPIRE_S:
            continue
        if c["once"] and at:
            if any(f > at for f in fires if f):
                continue
            nxt = _cron_next(c["cron"], at)
            if nxt and nxt < now:
                continue
        live.append(tid)
    return live


def _pending_wakeup(tr: Path | None, born: float = 0.0) -> float:
    """기록 끝에서 아직 안 울린 ScheduleWakeup 의 예정 시각(epoch). 없으면 0.
    마지막 ScheduleWakeup 이 {stop:true} 면 없음 · 그 뒤 scheduled_task_fire 가 있으면 없음 ·
    세션이 뜨기(born) 전에 건 예약은 재시작으로 죽었다. 읽기 실패는 예외로 올린다."""
    if not tr:
        return 0.0
    due = 0.0
    for raw in _tail_text(tr).splitlines():
        if '"ScheduleWakeup"' not in raw and '"scheduled_task_fire"' not in raw:
            continue
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        if row.get("type") == "system" and row.get("subtype") == "scheduled_task_fire":
            due = 0.0
            continue
        content = (row.get("message") or {}).get("content")
        for b in content if isinstance(content, list) else []:
            if not (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "ScheduleWakeup"):
                continue
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            if inp.get("stop"):
                due = 0.0
                continue
            at = _row_time(row)
            if not at:
                due = time.time() + WAKEUP_GRACE      # 시각을 못 읽으면 막는 쪽
            elif at < born:
                due = 0.0
            else:
                try:
                    due = at + float(inp.get("delaySeconds") or 0)
                except (ValueError, TypeError):
                    due = time.time() + WAKEUP_GRACE
    return due


TURN_STALE = 1800.0              # 마지막 줄이 이보다 오래됐으면(Esc·오류로 끝난 턴) 진행 중으로 안 본다
_TURN_END = ("stop_hook_summary", "turn_duration")


def _turn_in_progress(tr: Path | None) -> bool:
    """작업 기록으로 본 턴 진행 중 — 마지막 의미 있는 줄이 턴 끝 표시(system stop_hook_summary·turn_duration)나
    Esc 표시가 아니고 user(tool_result 포함)·assistant 면 진행 중. 그 줄이 30분 넘게 오래됐으면 아님.
    attachment·queue-operation·bridge_status 등은 건너뛴다. 읽기 실패는 예외로 올린다."""
    if not tr:
        return False
    for raw in reversed(_tail_text(tr, 300_000).splitlines()):
        try:
            row = json.loads(raw)
        except ValueError:
            continue                                  # 끝에서 자른 첫 줄 등
        if not isinstance(row, dict):
            continue
        kind = row.get("type")
        if kind == "system" and row.get("subtype") in _TURN_END:
            return False
        if kind not in ("user", "assistant"):
            continue
        if kind == "user" and "[Request interrupted by user" in raw:
            return False
        at = _row_time(row) or tr.stat().st_mtime
        return time.time() - at < TURN_STALE
    return False


def _restart_blockers(rec: dict[str, Any]) -> list[str]:
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    def num(name: str) -> float:
        try:
            return float((sd / name).read_text())
        except (OSError, ValueError):
            return 0.0
    out = []
    name = str(rec.get("tmux") or "")
    alive = bool(name) and ms.tmux_alive(name)
    tr = _session_transcript(rec)
    # 턴 끝 기록은 Esc·API 오류로 끝난 턴엔 안 남는다 — 10분 지난 턴은 화면만 본다(리뷰 I1)
    turn = num("turn-at")
    if (turn > num("stopped-at") and time.time() - turn < 600) or _pane_busy(name)[1]:
        out.append("작업 중")
    if _turn_in_progress(tr):                        # 화면·turn-at 이 놓친 긴 턴(2026-10-07 사고)
        out.append("턴 진행 중")
    t = live_tasks(rec) if alive else []
    if t:
        out.append(f"백그라운드 {len(t)}")
    shells = _pane_shells(name) if alive else 0     # 기록(끝 2MB)이 놓친 셸도 — 화면에 N shell 이 보이면 그것으로 막는다
    if shells > 0:
        out.append(f"백그라운드 셸 {shells}")
    if alive:
        tail = (ms._tmux("capture-pane", "-p", "-t", name).stdout or "").rstrip().splitlines()[-8:]
        if any(l.strip() == "⏺ main" for l in tail):    # 아래 에이전트 목록 = SendMessage 로 맡긴 팀 에이전트(재시작하면 같이 죽는다, 실사용)
            out.append("팀 에이전트 일하는 중")
        if _pane_permission(name):                   # 서브에이전트 권한 창은 perm-*.json 이 안 생긴다
            out.append("권한 창 기다림")
    # 화면 말고 작업 기록으로도 — 백그라운드·이름 붙은 팀 에이전트, 안 끝났으면 30분까지 조용해도 일하는 중
    agents = _agents_running(rec, RESTART_AGENT_FRESH)
    if agents:
        out.append(f"에이전트 {len(agents)}개 일하는 중")
    due = _pending_wakeup(tr, _session_born(name) if alive else 0.0)
    if due and due + WAKEUP_GRACE > time.time():
        out.append("예약 기다림")
    if alive and _pending_crons(tr, _session_born(name)):
        out.append("예약 기다림(cron)")
    if alive and tr and _live_monitors(tr, _session_born(name)):
        out.append("감시 중(Monitor)")
    if (sd / "question.json").exists():
        out.append("질문 답 기다림")
    if list(sd.glob("perm-*.json")):
        out.append("권한 버튼 기다림")
    try:
        if tr and time.time() - tr.stat().st_mtime < 30:
            out.append("방금 메시지·작업 기록이 움직임")
    except OSError:
        pass
    return out


def restart_blockers(rec: dict[str, Any]) -> list[str]:
    """안전 재시작을 막는 이유(훅·작업 기록 기준). 빈 목록이면 지금 재시작해도 된다.
    판정 중 예외(기록 못 읽음 등)는 '막는다' — 모르면 죽이지 않는다."""
    try:
        return _restart_blockers(rec)
    except Exception as exc:
        return [f"판정 실패({type(exc).__name__}: {str(exc)[:80]})"]


def _restart_lock_path() -> Path:
    return ms.marina_home() / "restart-wait.lock"


def _write_restart_status(fh: Any, remaining: list[str], started: float) -> None:
    fh.seek(0)
    fh.truncate()
    fh.write(json.dumps({"pid": os.getpid(), "startedAt": started, "remaining": remaining}, ensure_ascii=False))
    fh.flush()


def _acquire_restart_lock(remaining: list[str]) -> Any:
    """재시작 대기는 한 번에 하나 — flock. 이미 있으면 SessionError(pid). 잠금 파일에 pid·시작·남은 세션을 적는다."""
    import fcntl
    path = _restart_lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        st = restart_status(_locked=True)
        raise ms.SessionError(f"이미 재시작 대기가 돌고 있다(pid {st['pid'] if st else '?'}) — 끝내려면 marina session restart --cancel")
    _write_restart_status(fh, remaining, time.time())
    return fh


def _release_restart_lock(fh: Any) -> None:
    import fcntl
    try:
        fh.seek(0)
        fh.truncate()
        fcntl.flock(fh, fcntl.LOCK_UN)
    finally:
        fh.close()


def restart_status(_locked: bool = False) -> dict[str, Any] | None:
    """돌고 있는 재시작 대기의 {pid, startedAt, remaining}. 없으면 None(잠금이 안 잡혀 있으면 남은 파일은 낡은 것)."""
    import fcntl
    try:
        fh = open(_restart_lock_path(), "a+")
    except OSError:
        return None
    try:
        if not _locked:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                pass                                   # 누가 쥐고 있다 = 돌고 있다
            else:
                fcntl.flock(fh, fcntl.LOCK_UN)
                return None
        fh.seek(0)
        try:
            st = json.loads(fh.read() or "null")
        except ValueError:
            return None
        return st if isinstance(st, dict) and st.get("pid") else None
    finally:
        fh.close()


def restart_cancel() -> int | None:
    """돌고 있는 재시작 대기 프로세스를 끝낸다. 끝낸 pid, 없으면 None."""
    import signal
    st = restart_status()
    if not st:
        return None
    try:
        os.kill(int(st["pid"]), signal.SIGTERM)
    except (OSError, ValueError):
        return None
    return int(st["pid"])


def safe_restart(refs: list[str], wait: float = 30 * 60.0, poll: float = 15.0,
                 log: Any = None, quiet: float = RESTART_QUIET,
                 reasons: dict[str, str] | None = None) -> tuple[list[str], list[str]]:
    """막는 이유가 없는 상태가 quiet 초 연속으로 이어질 때만(폴링마다 다시 확인, 중간에 막히면 처음부터) 하나씩 재시작한다.
    tmux_stop 직전에도 한 번 더 확인(살아 있는 세션만 — 꺼진 세션은 그냥 시작). 풀릴 때까지 기다리다 시간이 지나면 남은 것을 돌려준다.
    reasons 를 주면 못 한 세션의 마지막 막은 이유를 채운다. 재시작 대기는 한 번에 하나(잠금)."""
    lock = _acquire_restart_lock(list(dict.fromkeys(refs)))
    try:
        return _safe_restart(refs, wait, poll, log, quiet, reasons if reasons is not None else {}, lock)
    finally:
        _release_restart_lock(lock)


def _stop_start(ref: str, rec: dict[str, Any], stop: bool, on_stop: Any = None) -> tuple[list[str], list[str], bool]:
    """(started, failed, up) — 방 잠금을 쥔 채 stop → start. 그 사이에 글이 와도 깨우기(wake)는 busy 로 물러난다.
    잠금을 기다리는 사이 깨우기가 먼저 띄웠으면 cmd_start 는 아무것도 안 하고 돌아온다 — 떠 있으면 up(실패 아님)."""
    name, sd, t0 = str(rec.get("tmux") or ""), Path(str(rec.get("stateDir") or "/nonexistent")), time.time()
    t_start = t0
    with ms.room_lock(sd, wait=ms.ROOM_LOCK_WAIT) as got:
        if not got:
            _log(f"restart {ref}: 방 잠금을 못 잡고 진행(깨우기와 겹칠 수 있다)")
        killed_at = 0.0
        if stop and ms.tmux_alive(name):
            killed_at = time.time()
            ms.tmux_stop(name)
            if on_stop:
                on_stop()
        t_start = time.time()                  # 실제 기동 시각 — 잠금을 기다린 시간은 빼고
        started, failed = ms.start_with_launch_env(ref, sd) if ms.launched_by() == "daemon" else ms.cmd_start(ref)
        if started:
            up = True
        elif failed:
            up = False
        else:                                  # 아무것도 안 했다 = 이미 떠 있다. 죽인 방이면 '새로 뜬' 세션일 때만 성공(kill 이 안 먹은 옛 세션을 가리지 않게)
            up = ms.tmux_alive(name) and (not killed_at or _session_born(name) >= int(killed_at))
    _settle_after_restart(rec, sd, t0, t_start)
    return started, failed, up


def _settle_after_restart(rec: dict[str, Any], sd: Path, t0: float, started: "float | None" = None) -> None:
    """재시작한 방은 항상 — 새 세션이 못 받은 글이 있는지 한 번 보게 한다(깨우기가 busy 표식을 못 남기고 지나간 경합도 덮는다).
    기준은 실제 기동 시각. 재시작 중에 온 글을 깨우기가 busy 로 돌려보냈다면(표식) 그 글까지 닿게 t0(재시작 시작)부터."""
    base = time.time() if started is None else started
    try:
        if float((sd / "wake-busy-at").read_text()) >= t0:
            base = t0
            (sd / "wake-busy-at").unlink(missing_ok=True)
    except (OSError, ValueError):
        pass
    if rec.get("channelId") and ms.tmux_alive(str(rec.get("tmux") or "")):
        import marina_discord_wake as mw
        mw._spawn_settle(str(rec["channelId"]), base)


def force_restart(refs: list[str], log: Any = None) -> tuple[list[str], list[str]]:
    """사람이 시킨 강제 재시작 — 막는 이유는 찍기만 하고 무시, 대기·조용한 시간 없이 바로 stop → start.
    재시작 대기 잠금은 그대로 지킨다(다른 대기가 돌고 있으면 SessionError). 못 켠 세션은 사유와 켜는 법을 담은 줄로 돌려준다.
    세션 하나가 예외로 실패해도 나머지는 계속한다."""
    lock = _acquire_restart_lock(list(dict.fromkeys(refs)))
    try:
        done, failed = [], []
        for ref in dict.fromkeys(refs):
            try:
                rec = ms.find_session(ref)
                name = str(rec.get("tmux") or "")
                alive = ms.tmux_alive(name)
                why = restart_blockers(rec) if alive else []
                if log:
                    log(f"강제 재시작: {ref} — 무시한 것: {'·'.join(why) if why else '막는 이유 없음'}")
                started, why_not, up = _stop_start(ref, rec, alive, on_stop=lambda r=rec: _drop_pending_prompts(r))
                if up:
                    done.append(ref)
                    if log:
                        log(f"✓ 재시작: {ref}" if started else f"✓ 이미 떠 있음: {ref}")
                    continue
                detail = "; ".join(why_not) or "시작되지 않았다"
            except Exception as exc:
                detail = str(exc) or type(exc).__name__
            failed.append(f"✗ {detail} — 지금 꺼져 있다: marina session start {ref}")
        return done, failed
    finally:
        _release_restart_lock(lock)


def _drop_pending_prompts(rec: dict[str, Any]) -> None:
    """죽은 세션이 남긴 질문·권한 버튼과 기록을 정리한다(기존 정리 함수 — 버튼은 늦게 눌러도 소용없다)."""
    sd, ch = Path(str(rec.get("stateDir") or "/nonexistent")), str(rec.get("channelId") or "")
    if not sd.is_dir():
        return
    try:
        import marina_discord_ask
        marina_discord_ask.done(sd, ch, "재시작으로 취소")
        (sd / "question.json").unlink(missing_ok=True)
    except Exception:
        pass
    try:
        clear_perms(sd, ch)
    except Exception:
        pass


def _safe_restart(refs: list[str], wait: float, poll: float, log: Any, quiet: float,
                  reasons: dict[str, str], lock: Any) -> tuple[list[str], list[str]]:
    pending, done, failures = list(dict.fromkeys(refs)), [], []
    started_at = time.time()
    end = started_at + wait
    clear_since: dict[str, float] = {}
    while pending:
        for ref in list(pending):
            try:
                rec = ms.find_session(ref)
            except ms.SessionError:
                pending.remove(ref)          # 기다리는 사이 지워진 세션 — 나머지는 계속(리뷰 S3)
                continue
            if ms.tmux_alive(str(rec.get("tmux") or "")):
                why = restart_blockers(rec)
                if not why:
                    since = clear_since.setdefault(ref, time.time())
                    if time.time() - since < quiet:
                        reasons[ref] = "조용한 시간 재는 중"
                        continue
                    why = restart_blockers(rec)      # 죽이기 직전 한 번 더
                if why:
                    clear_since.pop(ref, None)
                    reasons[ref] = "·".join(why)
                    continue
                stop = True
            else:
                stop = False                 # 꺼진 세션은 막는 이유 없이 시작만
            started, failed, up = _stop_start(ref, rec, stop)
            pending.remove(ref)
            reasons.pop(ref, None)
            if up:
                done.append(ref)             # 그 사이 깨우기가 먼저 띄웠어도(이미 떠 있음) 떠 있으니 성공
            else:
                failures.append(ref)         # 꺼진 채 남았다 — 성공으로 세지 않는다(리뷰 I4)
            if log:
                log((f"✓ 재시작: {ref}" if started else f"✓ 이미 떠 있음: {ref}") if up else f"✗ {failed}")
        _write_restart_status(lock, list(pending), started_at)
        if not pending or time.time() >= end:
            break
        if log:
            log("기다리는 중: " + ", ".join(f"{r}({reasons.get(r, '')})" for r in pending))
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
    env = {k: v for k, v in os.environ.items() if k.startswith("MARINA_") or k in ("HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "SSH_AUTH_SOCK")}
    env.update(PATH=f"{Path(bun).parent}:/usr/bin:/bin", DISCORD_BOT_TOKEN=ms.read_token(cfg),
               MARINA_GUILD=str(cfg["guildId"]), MARINA_PY=sys.executable, MARINA_BOT_PY=str(Path(__file__).resolve()),
               MARINA_PARENT_PID=str(os.getpid()), **{ms.BOT_MARK: "1"})     # 자식(new-from-text 등)이 '데몬이 띄운다'를 알게
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


def _plain(text: str) -> str:
    """Discord 에 그대로 보일 글 — 백틱(코드 블록 깨기)·멘션을 무력화."""
    return text.replace("`", "ʼ").replace("@", "@\u200b")


def new_from_text(project: str, user: str, text: str, channel: str, name: str = "형") -> str:
    """[🛠 새 작업 열기] 모달 제출: 글 한 덩이로 워크트리·채널·세션을 연다. 결과는 누른 사람에게 보일 한 줄.
    channel = 버튼이 눌린 채널(그 프로젝트 로비여야 한다)."""
    text = (text or "").strip()
    if not 1 <= len(text) <= 500:
        return "글은 1~500자로 적어 줘"
    try:
        lobby = next((s for s in ms.load_sessions() if s.get("project") == project and s.get("kind") == "dev-lobby"), None)
        if not lobby:
            return "이 프로젝트엔 로비가 없어"
        if str(lobby.get("channelId")) != str(channel):
            return "이 채널의 새 작업 패널이 아니야"
        cfg = ms.load_config()
        dc = _dc(cfg)
        if not _allowed(lobby, str(lobby.get("channelId")), user, dc):
            return "새 작업을 열 권한이 없어"
        who = (name or "형").strip() or "형"

        def first(ch: str) -> str:
            """채널이 생긴 뒤·세션이 뜨기 전에 📝 를 올려 그 메시지 ID 를 첫 지시에 넣는다(세션이 자기 채널을 알게)."""
            mid = ""
            try:
                mid = dc.post_message(ch, f"📝 {_plain(who)[:40]}: " + _plain(text)[:1800])
            except ms.SessionError:
                pass
            return ms.new_task_first_prompt(text, who, ch, mid)

        slug = ms.unique_slug(project, ms.suggest_slug(text))
        with ms.launch_env_scope(None):        # 새 세션도 사람의 환경(로그인 셸)으로 — 봇의 짧은 PATH 로 뜨지 않게
            r = ms.cmd_new(project, slug, ms.extract_base(project, text), start=False, title=ms.task_title(text), first=first)
        return f"열었어: <#{r['channelId']}>"
    except ms.SessionError as exc:
        return str(exc)[:1500]
    except Exception as exc:        # 예상 밖 오류의 원문은 Discord 에 안 보인다 — 로그에만
        _log(f"new-from-text {project} 실패: {exc!r}")
        return "못 열었어 — 마리나 로그를 확인해 줘"


PANEL_EVERY = 600.0


def panel_tick(last: float, now: float) -> float:
    """로비마다 새 작업 패널을 보장(10분마다 + 봇이 뜰 때). 새로 확인한 시각을 돌려준다."""
    if now - last < PANEL_EVERY:
        return last
    for s in ms.load_sessions():
        if s.get("kind") == "dev-lobby":
            try:
                ms.ensure_new_panel(str(s.get("project")))
            except Exception as exc:
                _log(f"new panel {s.get('project')} 실패: {exc!r}")
    return now


_spawn = subprocess.Popen


class Loop:
    """마리나 데몬 스레드 한 바퀴(4초). discord.json 이 없으면 봇을 내리고 아무것도 안 한다(생기면 그때 시작)."""

    def __init__(self) -> None:
        self.dash: dict[str, Any] = {}
        self.meters: dict[str, dict[str, Any]] = {}
        self.ty: dict[str, float] = {}
        self.words: dict[str, tuple[str, float]] = {}
        self.last_words = 0.0
        self.live: set[str] = set()
        self.last_render = -1.0          # 데몬이 막 떴으면 한 번은 그린다
        self.last_weekly = -WEEKLY_EVERY
        self.last_panel = -PANEL_EVERY
        self.last_reconcile = -RECONCILE_EVERY
        self.proc: subprocess.Popen | None = None
        self.next_start, self.backoff, self.started = 0.0, 5.0, 0.0
        self.lockf: Any = None
        self.last_err = ""
        self.vsrv: Any = None            # 결과물 보기 서버(marina_view.ViewServer) — discord.json 의 view 가 있을 때만
        self.last_vsweep = -3600.0       # 보기 기록 정리(원본이 7일 넘게 없는 것) — 한 시간마다
        self.vnext = 0.0                 # 포트를 못 열었으면 이 시각 전엔 다시 안 시도
        self.last_tsweep = -60.0         # 터미널 넘기기 정리(미개봉 10분·무활동 30분) — 1분마다
        self.last_twatch = -TERM_WATCH_EVERY   # 터미널 넘기기 끝 감지 — 5초마다
        self.idler: Any = None           # 쉰 방 내리기(marina_discord_idle.Idler) — 속도 제한(20초 표본·1분에 하나)은 Idler 안
        self.born = time.time()          # 이 데몬이 뜬 시각 — 쉰 방 내리기는 그 뒤 글 이벤트를 받은 표식이 있어야 동작

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

    def view_server(self, cfg: dict[str, Any], now: float) -> None:
        """결과물 보기 서버(스레드). 설정 view 가 있어야 띄우고(없거나 사라지면 내림), 포트가 바뀌면 다시 띄운다.
        포트 충돌은 데몬을 죽이지 않고 60초 뒤 다시 시도한다."""
        import marina_view as mv
        view = cfg.get("view")
        if not isinstance(view, dict):
            self.stop_view()
            return
        try:
            port = int(view.get("port") or mv.DEFAULT_PORT)
        except (TypeError, ValueError):
            port = mv.DEFAULT_PORT
        base = str(view.get("publicBase") or "").strip().rstrip("/")
        if self.vsrv is not None and self.vsrv.want == port and self.vsrv.public_base == base:
            return
        self.stop_view()
        if now < self.vnext:
            return
        srv = mv.ViewServer(port, base, on_share=share_term_screen)
        if srv.start():
            self.vsrv = srv
            _log(f"view server: 127.0.0.1:{srv.port}")
        else:
            self.vnext = now + 60.0
            _log(srv.error)

    def sweep_view(self, now: float) -> None:
        if now - self.last_vsweep < 3600.0:
            return
        self.last_vsweep = now
        import marina_view as mv
        mv.sweep()

    def sweep_term(self, now: float) -> None:
        if now - self.last_tsweep < 60.0:
            return
        self.last_tsweep = now
        import marina_termbridge as tb
        try:
            tb.sweep()
        except Exception as exc:         # 정리가 실패해도 데몬은 계속(토큰은 로그에 안 남는다)
            _log(f"term sweep failed: {exc!r}")

    def watch_term(self, now: float) -> None:
        """넘긴 명령이 끝났는지 5초마다 본다(페이지가 안 열려 있어도). 끝났으면 요청한 세션에 한 번 알린다."""
        if now - self.last_twatch < TERM_WATCH_EVERY:
            return
        self.last_twatch = now
        import marina_termbridge as tb
        for token, data in tb.watch(now):
            try:
                notify_term_done(token, data)
                tb.mark_notified(token)
            except Exception as exc:     # 한 터미널의 실패가 나머지를 막지 않는다 — 알렸다고 안 적었으니 다음 훑기에 다시
                _log(f"term done notify failed: {exc!r}")

    def stop_view(self) -> None:
        srv, self.vsrv = self.vsrv, None
        if srv is not None:
            srv.stop()

    def step(self, now: float) -> bool:
        """설정이 있으면 True."""
        try:
            cfg = ms.load_config()
        except ms.SessionError:
            self.stop_bot()
            self.stop_view()
            return False
        if not self.own():
            return False
        for name, fn in (("bot", lambda: self.supervise(cfg, now)), ("viewsrv", lambda: self.view_server(cfg, now)), ("viewsweep", lambda: self.sweep_view(now)), ("termsweep", lambda: self.sweep_term(now)), ("termwatch", lambda: self.watch_term(now)),
                         ("view", lambda: self.view(now))):
            try:
                fn()
            except Exception as exc:     # 데몬 스레드는 죽으면 안 된다 — 남기되 같은 오류는 한 번만(리뷰 M3)
                err = f"{name} failed: {exc!r}"
                if err != self.last_err:
                    _log(err)
                self.last_err = err
        return True

    def view(self, now: float) -> None:
        # 사라진 워크트리 정리·세션 잠금은 그리기보다 먼저 — #상태가 계속 실패해도 돌아야 한다(리뷰 M6)
        if now - self.last_reconcile >= RECONCILE_EVERY:
            self.last_reconcile = now
            try:
                gone = ms.reconcile_gone(now)      # 밖에서 지워진 워크트리의 채널 정리(runtime 은 Discord 를 모른다)
                if gone:
                    _log(f"reconcile: 워크트리가 사라진 세션 정리 {gone}")
            except Exception as exc:
                _log(f"reconcile 실패: {exc!r}")
        try:                              # import 도 안에서 — 내리기 모듈이 깨져도 아래 #상태·typing·권한 창은 계속
            import marina_discord_idle as mi
            self.idler = self.idler or mi.Idler(started=self.born)
            self.idler.tick(now, bot_up=self.proc is not None and self.proc.poll() is None)
        except Exception as exc:          # 내리기가 실패해도 데몬은 계속(모르면 안 내린다)
            _log(f"idle 실패: {exc!r}")
        self.last_panel = panel_tick(self.last_panel, now)
        light = snapshot(full=False)
        typing_tick(light, self.ty, now, self.live)
        try:
            pane_perm_tick()
        except Exception as exc:
            _log(f"pane_perm failed: {exc!r}")
        try:
            role_events_tick()
        except Exception as exc:
            _log(f"role_events failed: {exc!r}")
        if now - self.last_words >= 30.0:
            self.last_words = now
            try:
                self.live = agent_words_tick(self.words, now)
            except Exception as exc:
                _log(f"agent_words failed: {exc!r}")
        if should_render(now, self.last_render, dirty_mtime(), light["anyBusy"]):
            self.last_render = now
            dashboard_tick(self.dash)
        if now - self.last_weekly >= WEEKLY_EVERY:
            self.last_weekly = now
            meter_tick(self.meters)


def beat_path() -> Path:
    return ms.marina_home() / "discord-daemon.beat"


def _boot_time() -> float:
    """맥이 부팅한 시각(kern.boottime). 못 읽으면 0 — 모르면 '재부팅 아님'으로 본다(끊긴 방을 켜지 않는 쪽)."""
    try:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"sec\s*=\s*(\d+)", out)
        return float(m.group(1)) if m else 0.0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0.0


def _spawn_sweep(since: float, resume: bool = False) -> None:
    wake_py = Path(__file__).resolve().with_name("marina_discord_wake.py")
    subprocess.Popen([sys.executable, str(wake_py), "sweep", str(since), *(["--resume"] if resume else [])], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def run_forever(stop: "Callable[[], bool] | None" = None, max_steps: "int | None" = None) -> None:
    """stop() 이 참이면 끝낸다 — discord 데몬은 플러그인이 업데이트되면 스스로 끝나고 다음 훅이 새 코드로 다시 띄운다(분리 B).
    max_steps 는 테스트용(기본 None = 끝없이)."""
    loop = Loop()
    try:
        prev = beat_path().stat().st_mtime     # 지난 데몬이 마지막으로 살아 있던 때 — 그 뒤 온 글은 이벤트로 못 받았다
    except OSError:
        prev = 0.0                             # 첫 배포: 훑지 않는다(옛 글로 방들이 한꺼번에 깨지 않게)
    swept, last_beat, steps = False, 0.0, 0
    last_check = time.time()
    while True:
        ok = loop.step(time.time())
        if ok and not swept:
            swept = True
            if prev:
                try:
                    _spawn_sweep(prev, resume=_boot_time() > prev)     # 일하던 방 다시 켜기는 재부팅 뒤 첫 훑기만(업데이트·크래시 재시작은 아님)
                except OSError as exc:
                    _log(f"sweep 띄우기 실패: {exc!r}")
        if ok and time.time() - last_beat >= 60:
            last_beat = time.time()
            try:
                beat_path().touch()
            except OSError:
                pass
        steps += 1
        if max_steps is not None and steps >= max_steps:
            return
        time.sleep(4 if ok else 30)
        if stop and time.time() - last_check >= 60:
            last_check = time.time()
            if stop():
                loop.stop_bot()      # bun 봇도 기다려 끝낸다 — 새 데몬의 봇과 겹치지 않게(리뷰 M2)
                loop.stop_view()     # 보기 서버 포트도 놓는다 — 새 데몬이 같은 포트를 잡게
                return


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
    nt = sub.add_parser("new-from-text")
    nt.add_argument("--project", required=True); nt.add_argument("--user", required=True); nt.add_argument("--text", required=True)
    nt.add_argument("--channel", required=True); nt.add_argument("--name", default="형")
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
        if typeable(a.text, a.channel):
            typed = run_slash(a.tmux, a.text, a.channel, a.mid,
                              timeout=float(os.environ.get("MARINA_TYPE_TIMEOUT") or type_timeout(a.text)))
            if not typed and a.button:
                _restore_suggest(a.channel, a.button, a.text[len(SUGGEST_MARK):] if a.text.startswith(SUGGEST_MARK) else a.text)
        return 0
    if a.cmd == "new-from-text":
        # 봇이 띄운 python 의 PATH 는 짧다(<bun>:/usr/bin:/bin) — claude·tmux·git 을 찾게 데몬과 같은 경로로 보강
        os.environ["PATH"] = ms.daemon_path() + ":" + os.environ.get("PATH", "")
        print(new_from_text(a.project, a.user, a.text, a.channel, a.name))
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
