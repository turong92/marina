"""코덱스 방(kind "codex") 전용 코드 — 스펙 docs/superpowers/specs/2026-10-21-codex-rooms-design.md.

클로드 방과 다른 지점(띄우기 인자·env·막는 화면 검사 …)만 여기에 둔다. 방 기록·상태 폴더·tmux·Discord 인프라는
marina_session 이 그대로 쓴다. marina_session 은 이 모듈을 함수 안에서 늦게 import 한다(순환 방지).
값(트러스트·훅 인자·막는 화면 문구)은 스파이크 실측(스펙 "실측 결과", codex-cli 0.146)."""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import marina_discord_usage as du
import marina_session as ms

KIND = "codex"
DEFAULT_CATEGORY = "chat-bot"
DEFAULT_ACCOUNT = "b"

# 이 화면이 남아 있으면 입력이 조용히 삼켜진다(S1)
PANE_BLOCKING = ("Update available", "Do you trust the contents of this directory", "Hooks need review")

CODEX_RULES = (
    "이 세션은 Discord 채널에 연결돼 있다. 상대는 Discord 만 보고 이 터미널은 보지 않는다.\n"
    "- 받은 메시지는 <channel … chat_id=\"…\" message_id=\"…\"> 태그로 온다. 답은 반드시 marina MCP 의 "
    "mcp__marina__reply 로 보낸다(chat_id 는 받은 태그의 것, 지시에 대한 끝 보고·답은 reply_to = 그 지시의 message_id).\n"
    "- 결과·질문·실패/막힘·완료는 reply 로 보낸다. 아직 안 끝난 중간 보고는 mcp__marina__progress "
    "(message_id = 지시 메시지 ID)로 한 줄 남긴다(알림 없음). 짧은 답은 progress 없이 reply 만.\n"
    "- 이미지는 첨부한다. 10MB 를 넘는 파일은 링크로 보낸다.\n"
    "- 상대가 볼 결과물(스펙·보고서 md, HTML·목업, 스크린샷)을 만들면 mcp__marina__share_file 에 넘기고, "
    "돌려받은 미리보기 파일을 reply 로 첨부하며 열어보기 주소를 reply 본문에 넣는다.\n"
    "- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다."
)


def codex_cfg(cfg: dict[str, Any]) -> dict[str, Any]:
    """discord.json 최상위 "codex" 에 기본값(category·account)을 채운 사본. categoryId 는 있을 때만."""
    raw = cfg.get("codex") if isinstance(cfg.get("codex"), dict) else {}
    out = dict(raw)
    out["category"] = str(raw.get("category") or DEFAULT_CATEGORY)
    out["account"] = str(raw.get("account") or DEFAULT_ACCOUNT)
    return out


def codex_home(account: str) -> Path:
    return ms.marina_home() / "accounts" / f"codex-{account}"


def _q(value: str) -> str:
    """TOML 기본 문자열(JSON 문자열 인용이 그대로 TOML 이다)."""
    return json.dumps(value, ensure_ascii=False)


def trust_args(root: str) -> list[str]:
    """폴더 신뢰 -c — 점 경로(projects."x".trust_level)는 안 먹고 표 형태만 먹는다(S1)."""
    return ["-c", f'projects={{{_q(os.path.realpath(root))}={{trust_level="trusted"}}}}']


def _mcp_env(sdir: Path) -> dict[str, str]:
    """MCP 서버는 코덱스 env 를 물려받지 않는다(S4) — 서버가 쓸 변수는 env 칸에 따로 적는다."""
    env = {"DISCORD_STATE_DIR": str(sdir), "MARINA_HOME": str(ms.marina_home())}
    for k in ("MARINA_DISCORD_API", "MARINA_CHANNELS_DIR", "MARINA_CODEX_SESSIONS"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def mcp_args(sdir: Path) -> list[str]:
    entry = ms._hook_entry()
    args = ", ".join(_q(a) for a in entry[1:] + ["mcp-chat"])
    env = ", ".join(f"{k}={_q(v)}" for k, v in _mcp_env(sdir).items())
    return ["-c", f"mcp_servers.marina={{command={_q(entry[0])},args=[{args}],env={{{env}}}}}"]


def rules_args() -> list[str]:
    return ["-c", f"developer_instructions={_q(CODEX_RULES)}"]


def hook_args(sdir: Path) -> list[str]:
    """인라인 훅(-c hooks={…}) — 훅 하위명령은 Task 5 가 채운다."""
    return []


def codex_argv(rec: dict[str, Any], resume: bool = False, first: str = "") -> list[str]:
    """codex 는 sid 를 미리 못 정한다 — sid 가 있고 resume 일 때만 `resume <sid>`, 아니면 새 대화(S7)."""
    sid = str(rec.get("sessionId") or "")
    sdir = Path(str(rec.get("stateDir") or ""))
    root = str(rec.get("root") or "")
    argv = ["codex"]
    if resume and sid:
        argv += ["resume", sid]
    argv += ["-C", root, "-a", "never", "-c", "check_for_update_on_startup=false",
             *trust_args(root), "--dangerously-bypass-hook-trust",
             *mcp_args(sdir), *rules_args(), *hook_args(sdir)]
    if first:
        argv.append(first)
    return argv


def codex_env(sdir: Path, account: str) -> dict[str, str]:
    """clean_env_prefix 에 더할 변수 — 클로드 토큰 변수는 넣지 않는다."""
    env = _mcp_env(sdir)
    env["CODEX_HOME"] = str(codex_home(account))
    return env


def boot_check(tmux: str, timeout: "float | None" = None) -> str:
    """막는 화면 문구가 보이면 그 문구, 입력창(›)이 먼저 보이거나 시간이 다 되면 ""."""
    wait = float(os.environ.get("MARINA_CODEX_BOOT_WAIT") or 8.0) if timeout is None else timeout
    deadline = time.time() + wait
    while True:
        screen = ms._tmux("capture-pane", "-p", "-t", tmux).stdout or ""
        for phrase in PANE_BLOCKING:
            if phrase in screen:
                return phrase
        if any(line.startswith("› ") for line in screen.splitlines()) or time.time() >= deadline:
            return ""
        time.sleep(0.3)


# ── rollout 읽기(Task 2) — 줄 모양은 스펙 "실측 결과". 파일은 끝에서부터 잘라 읽는다(전체 읽기 금지) ──

def sessions_root() -> Path:
    """rollout 뿌리 — 테스트가 MARINA_CODEX_SESSIONS 로 바꾼다. 계정 폴더의 sessions 는 ~/.codex/sessions 로의 링크다."""
    return Path(os.environ.get("MARINA_CODEX_SESSIONS") or Path.home() / ".codex" / "sessions")


_SID = re.compile(r"[0-9A-Fa-f-]{8,64}")


def find_rollout(sid: str) -> "Path | None":
    if not _SID.fullmatch(sid or ""):
        return None
    hits = list(sessions_root().glob(f"*/*/*/rollout-*-{sid}.jsonl"))
    return max(hits, key=lambda f: f.stat().st_mtime) if hits else None


def rollout_of(rec: dict[str, Any]) -> "Path | None":
    """방 기록의 rollout 캐시 경로, 없거나 사라졌으면 sid 로 다시 찾는다."""
    cached = str(rec.get("rollout") or "")
    if cached and Path(cached).is_file():
        return Path(cached)
    return find_rollout(str(rec.get("sessionId") or ""))


def discover_sid(root: "Path | str", since: float, taken: "set[str]") -> str:
    """띄운 뒤 만들어진 rollout 중 첫 줄(session_meta)의 cwd 가 root 이고 다른 방이 안 가진 것이 **정확히 하나**면 그 sid.
    둘 이상이면 ""(짐작 금지). session_meta 는 18KB 넘는 한 줄이라 첫 줄을 통째로 읽는다."""
    want = os.path.realpath(str(root))
    found: list[str] = []
    for f in sessions_root().glob("*/*/*/rollout-*.jsonl"):
        try:
            if f.stat().st_mtime < since:
                continue
            with f.open("rb") as fh:
                meta = json.loads(fh.readline())
        except (OSError, ValueError):
            continue
        p = meta.get("payload") if isinstance(meta, dict) and isinstance(meta.get("payload"), dict) else {}
        sid = str(p.get("id") or "")
        if sid and sid not in taken and os.path.realpath(str(p.get("cwd") or "")) == want:
            found.append(sid)
    return found[0] if len(found) == 1 else ""


def _tail_lines(path: Path, nbytes: int) -> list[str]:
    """파일 끝 nbytes 에서 온전한 줄들(잘린 첫 줄은 버린다)."""
    try:
        with path.open("rb") as fh:
            size = fh.seek(0, os.SEEK_END)
            start = max(0, size - nbytes)
            fh.seek(start)
            raw = fh.read()
    except OSError:
        return []
    lines = raw.decode("utf-8", "ignore").split("\n")
    return lines[1:] if start > 0 else lines


def _epoch(stamp: Any) -> float:
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _objs(lines: list[str]) -> "list[dict[str, Any]]":
    out = []
    for ln in lines:
        if ln.startswith("{"):
            try:
                o = json.loads(ln)
            except ValueError:
                continue
            if isinstance(o, dict):
                out.append(o)
    return out


BUSY_TAIL = 300 * 1024
BUSY_STALE_S = 1800.0


def turn_busy(rollout: Path, now: "float | None" = None) -> bool:
    """마지막 턴 경계가 task_started(뒤에 task_complete·turn_aborted 없음)이고 마지막 줄이 30분 안이면 바쁨.
    끝 300KB 안에 경계가 하나도 없으면(도구 출력이 아주 큰 긴 턴) 모른다 → False — 화면 판정(`esc to interrupt`)이 보조한다."""
    objs = _objs(_tail_lines(rollout, BUSY_TAIL))
    if not objs:
        return False
    last = ""
    for o in objs:
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        if o.get("type") == "event_msg" and p.get("type") in ("task_started", "task_complete", "turn_aborted"):
            last = str(p["type"])
    if last != "task_started":
        return False
    return (time.time() if now is None else now) - _epoch(objs[-1].get("timestamp")) <= BUSY_STALE_S


INBOUND_TAIL = 2 * 1024 * 1024


def inbound_ids(rollout: Path, channel: str) -> list[str]:
    """이 채널로 받은 지시의 message_id 들 — 순서대로, 중복 없이(한 글이 두 줄로 기록돼도 한 번)."""
    try:
        with rollout.open("rb") as fh:
            size = fh.seek(0, os.SEEK_END)
            fh.seek(max(0, size - INBOUND_TAIL))
            text = fh.read().decode("utf-8", "ignore")
    except OSError:
        return []
    out: list[str] = []
    for m in ms._CHANNEL_TAG.finditer(text):
        if m.group(1) == channel and m.group(2) not in out:
            out.append(m.group(2))
    return out


def window_label(minutes: int) -> "tuple[str, str]":
    """rate_limits 창 이름: 300분 = 5시간, 10080분 = 주간, 그 밖 = N일/N시간(키는 w<분>)."""
    if minutes == 300:
        return "fiveHour", "5시간"
    if minutes == 10080:
        return "weekly", "주간"
    if minutes % 1440 == 0:
        return f"w{minutes}", f"{minutes // 1440}일"
    return f"w{minutes}", f"{max(1, round(minutes / 60))}시간"


RATE_TAIL = 2 * 1024 * 1024
RATE_TTL_S = 60.0
_RATE_CACHE: "dict[tuple[str, ...], tuple[float, list[dict[str, Any]]]]" = {}


def _latest_rate_limits(rollout: Path) -> "tuple[float, dict[str, Any]] | None":
    for o in reversed(_objs(_tail_lines(rollout, RATE_TAIL))):
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        if o.get("type") == "event_msg" and p.get("type") == "token_count" and isinstance(p.get("rate_limits"), dict):
            return _epoch(o.get("timestamp")), p["rate_limits"]
    return None


def rate_windows(recs: "list[dict[str, Any]]", account: str, now: "float | None" = None) -> list[dict[str, Any]]:
    """이 계정으로 뜬 코덱스 방들의 rollout 에서 가장 최근 rate_limits → 창 목록(primary·secondary 중 있는 것).
    방 기록에 없는 rollout(데스크톱 다른 계정)은 더 최근이어도 읽지 않는다. 60초 캐시, resets_at 이 지났으면 0%."""
    paths = sorted({str(f) for f in (rollout_of(r) for r in recs
                                    if r.get("kind") == KIND and r.get("codexAccount") == account) if f})
    key = (account, *paths)
    hit = _RATE_CACHE.get(key)
    if hit and time.time() - hit[0] < RATE_TTL_S:
        raw = hit[1]
    else:
        best: "tuple[float, dict[str, Any]] | None" = None
        for path in paths:
            got = _latest_rate_limits(Path(path))
            if got and (best is None or got[0] > best[0]):
                best = got
        raw = [w for w in ((best[1].get("primary"), best[1].get("secondary")) if best else ()) if isinstance(w, dict)]
        _RATE_CACHE[key] = (time.time(), raw)
    clock = time.time() if now is None else now
    out = []
    for w in raw:
        minutes = w.get("window_minutes")
        if isinstance(minutes, bool) or not isinstance(minutes, (int, float)):
            continue
        k, label = window_label(int(minutes))
        reset = w.get("resets_at")
        expired = isinstance(reset, (int, float)) and reset <= clock
        win = du._usage_window(k, label, 0.0 if expired else w.get("used_percent"), None if expired else reset)
        if win:
            out.append(win)
    return out
