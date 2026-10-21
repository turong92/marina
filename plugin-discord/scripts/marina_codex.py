"""코덱스 방(kind "codex") 전용 코드 — 스펙 docs/superpowers/specs/2026-10-21-codex-rooms-design.md.

클로드 방과 다른 지점(띄우기 인자·env·막는 화면 검사 …)만 여기에 둔다. 방 기록·상태 폴더·tmux·Discord 인프라는
marina_session 이 그대로 쓴다. marina_session 은 이 모듈을 함수 안에서 늦게 import 한다(순환 방지).
값(트러스트·훅 인자·막는 화면 문구)은 스파이크 실측(스펙 "실측 결과", codex-cli 0.146)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import marina_discord_usage as du
import marina_session as ms
import marina_share

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


# ── 아웃바운드(Task 3) — marina MCP 에 더하는 Discord 도구 5개. 공식 플러그인(server.ts)의 안전장치를 옮겼다 ──

MAX_CHUNK = 2000
MAX_ATTACH = 25 * 1024 * 1024
MAX_FILES = 10

_CHAT = {"chat_id": {"type": "string"}}
DISCORD_TOOLS: "list[dict[str, Any]]" = [
    {"name": "reply",
     "description": "Discord 에 답한다. chat_id 는 받은 메시지 태그의 것. reply_to(message_id)로 지시에 답으로 달고, "
                    "files(절대 경로)로 이미지·파일을 첨부한다(10개·파일당 25MB). 2000자를 넘으면 나눠 보낸다.",
     "inputSchema": {"type": "object", "properties": {
         **_CHAT, "text": {"type": "string"},
         "reply_to": {"type": "string", "description": "답으로 달 메시지 ID — 받은 <channel> 태그의 message_id. 비우면 마지막 지시로 채운다."},
         "files": {"type": "array", "items": {"type": "string"}, "description": "첨부할 절대 경로(최대 10개, 25MB씩)."}},
         "required": ["chat_id", "text"]}},
    {"name": "react",
     "description": "Discord 메시지에 이모지 반응을 단다. 유니코드 이모지는 그대로, 커스텀 이모지는 <:name:id> 형태로.",
     "inputSchema": {"type": "object", "properties": {**_CHAT, "message_id": {"type": "string"}, "emoji": {"type": "string"}},
                     "required": ["chat_id", "message_id", "emoji"]}},
    {"name": "edit_message",
     "description": "봇이 보낸 메시지를 고친다. 중간 진행 갱신에 쓴다. 고침은 알림이 가지 않으니 긴 작업이 끝나면 새 reply 를 보낸다.",
     "inputSchema": {"type": "object", "properties": {**_CHAT, "message_id": {"type": "string"}, "text": {"type": "string"}},
                     "required": ["chat_id", "message_id", "text"]}},
    {"name": "fetch_messages",
     "description": "채널의 최근 메시지를 오래된 것부터 메시지 ID 와 함께 가져온다. 봇은 검색을 못 하니 거슬러 볼 때 쓴다.",
     "inputSchema": {"type": "object", "properties": {"channel": {"type": "string"},
                                                      "limit": {"type": "number", "description": "최대 개수(기본 20, 상한 100)."}},
                     "required": ["channel"]}},
    {"name": "download_attachment",
     "description": "메시지의 첨부를 방 상태 폴더 inbox 로 받는다(fetch_messages 에서 +Natt 로 보인 것). 읽을 수 있는 파일 경로를 돌려준다.",
     "inputSchema": {"type": "object", "properties": {**_CHAT, "message_id": {"type": "string"}},
                     "required": ["chat_id", "message_id"]}},
]
DISCORD_TOOL_NAMES = frozenset(t["name"] for t in DISCORD_TOOLS)


def _chunks(text: str, limit: int = MAX_CHUNK) -> list[str]:
    return [text[i:i + limit] for i in range(0, len(text), limit)] or [""]


def _gate(dc: "ms.Discord", sd: Path, chat_id: str) -> None:
    """채널 문지기 — 이 방(access.json.groups)이거나 그 스레드(부모가 groups)일 때만."""
    if not re.fullmatch(r"\d{1,25}", chat_id or ""):
        raise ms.SessionError(f"허용 목록에 없는 채널이야: {chat_id!r}")
    try:
        groups = json.loads((sd / "access.json").read_text(encoding="utf-8")).get("groups") or {}
    except (OSError, ValueError):
        groups = {}
    if chat_id in groups:
        return
    try:
        info = dc._req("GET", f"/channels/{chat_id}") or {}
    except ms.SessionError:
        info = {}
    if info.get("type") in (10, 11, 12) and str(info.get("parent_id") or "") in groups:
        return
    raise ms.SessionError(f"허용 목록에 없는 채널이야: {chat_id}")


def _assert_sendable(f: str, sd: Path) -> None:
    """방 상태 폴더 안 파일(토큰 링크 .env 포함)은 보내지 않는다 — inbox 만 예외. 글자 그대로의 경로와 realpath 둘 다 본다
    (.env 는 토큰 파일로의 심볼릭 링크라 realpath 만 보면 상태 폴더 밖으로 나가 통과한다)."""
    state = os.path.realpath(str(sd))
    inbox = state + os.sep + "inbox" + os.sep
    real = os.path.realpath(f)
    for cand in (real, os.path.abspath(f)):
        if (cand == state or cand.startswith(state + os.sep)) and not cand.startswith(inbox):
            raise ms.SessionError(f"채널 상태 폴더 안 파일은 못 보내: {f}")
    if real == os.path.realpath(str(sd / ".env")):
        raise ms.SessionError(f"채널 상태(토큰) 파일은 못 보내: {f}")


def _check_files(files: Any, sd: Path) -> list[Path]:
    if not isinstance(files, list):
        files = []
    if len(files) > MAX_FILES:
        raise ms.SessionError(f"첨부는 메시지당 최대 {MAX_FILES}개야")
    out = []
    for f in files:
        _assert_sendable(str(f), sd)
        p = Path(str(f))
        try:
            size = p.stat().st_size
        except OSError:
            raise ms.SessionError(f"첨부 파일이 없어: {f}")
        if not p.is_file():
            raise ms.SessionError(f"첨부는 파일만 돼: {f}")
        if size > MAX_ATTACH:
            raise ms.SessionError(f"파일이 너무 커: {f} ({size / 1024 / 1024:.1f}MB, 최대 25MB)")
        out.append(p)
    return out


def _default_reply_to(rec: dict[str, Any], chat_id: str) -> str:
    """reply_to 가 비면 이 방의 마지막 받은 지시로 — 답 = 끝 표시(클로드 방의 hook_reply_to 와 같은 효과)."""
    ro = rollout_of(rec)
    ids = inbound_ids(ro, chat_id) if ro else []
    return ids[-1] if ids else ""


def _reply(rec: dict[str, Any], dc: "ms.Discord", token: str, args: dict[str, Any]) -> str:
    sd = Path(str(rec["stateDir"]))
    chat_id, text = str(args.get("chat_id") or ""), str(args.get("text") or "")
    _gate(dc, sd, chat_id)
    files = _check_files(args.get("files"), sd)
    reply_to = str(args.get("reply_to") or "") or _default_reply_to(rec, chat_id)
    chunks = _chunks(text)
    ids: list[str] = []
    try:
        for i, part in enumerate(chunks):
            ref = reply_to if i == 0 else ""
            if i == 0 and files:
                sent = marina_share.upload_message(dc.base, token, chat_id, part, files, reply_to=ref)
            else:
                body: dict[str, Any] = {"content": part, "allowed_mentions": {"parse": []}}
                if ref:
                    body["message_reference"] = {"message_id": ref, "fail_if_not_exists": False}
                sent = dc._req("POST", f"/channels/{chat_id}/messages", body)
            ids.append(str((sent or {}).get("id") or ""))
    except (ms.SessionError, urllib.error.URLError, OSError) as exc:
        raise ms.SessionError(f"reply 가 {len(chunks)}조각 중 {len(ids)}조각을 보낸 뒤 실패: {exc}")
    if reply_to:
        ms._write_json(sd / "replied.json", {"mid": reply_to, "at": time.time()})
    return f"sent (id: {ids[0]})" if len(ids) == 1 else f"sent {len(ids)} parts (ids: {', '.join(ids)})"


def _iso(stamp: Any) -> str:
    try:
        d = datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return str(stamp)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03d}Z"


def _fetch(dc: "ms.Discord", sd: Path, args: dict[str, Any]) -> str:
    channel = str(args.get("channel") or "")
    _gate(dc, sd, channel)
    try:
        limit = max(1, min(int(args.get("limit") or 20), 100))
    except (TypeError, ValueError):
        limit = 20
    rows = dc._req("GET", f"/channels/{channel}/messages?limit={limit}") or []
    if not rows:
        return "(no messages)"
    me = dc.me()
    out = []
    for m in reversed(rows):              # Discord 는 최신이 먼저 — 오래된 것부터
        who = "me" if (m.get("author") or {}).get("id") == me else (m.get("author") or {}).get("username", "?")
        atts = f" +{len(m['attachments'])}att" if m.get("attachments") else ""
        body = re.sub(r"[\r\n]+", " ⏎ ", str(m.get("content") or ""))      # 여러 줄이 이웃 줄을 위조하지 못하게
        out.append(f"[{_iso(m.get('timestamp'))}] {who}: {body}  (id: {m.get('id')}{atts})")
    return "\n".join(out)


def _safe_att_name(att: dict[str, Any]) -> str:
    return re.sub(r"[\[\]\r\n;]", "_", str(att.get("filename") or att.get("id") or ""))


def _download(dc: "ms.Discord", sd: Path, args: dict[str, Any]) -> str:
    chat_id, mid = str(args.get("chat_id") or ""), str(args.get("message_id") or "")
    _gate(dc, sd, chat_id)
    if not re.fullmatch(r"\d{1,25}", mid):
        raise ms.SessionError("message_id 는 숫자 ID 여야 해")
    atts = (dc._req("GET", f"/channels/{chat_id}/messages/{mid}") or {}).get("attachments") or []
    if not atts:
        return "message has no attachments"
    inbox = sd / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    lines = []
    for att in atts:
        size = int(att.get("size") or 0)
        if size > MAX_ATTACH:
            raise ms.SessionError(f"첨부가 너무 커: {size / 1024 / 1024:.1f}MB, 최대 25MB")
        ext = re.sub(r"[^a-zA-Z0-9]", "", str(att.get("filename") or "").rpartition(".")[2]) or "bin"
        path = inbox / f"{int(time.time() * 1000)}-{att.get('id')}.{ext}"
        with urllib.request.urlopen(urllib.request.Request(str(att.get("url")), headers={"User-Agent": "marina"}), timeout=60) as r:
            path.write_bytes(r.read(MAX_ATTACH + 1))          # 토큰은 CDN 에 보내지 않는다
        lines.append(f"  {path}  ({_safe_att_name(att)}, {att.get('content_type') or 'unknown'}, {size / 1024:.0f}KB)")
    return f"downloaded {len(lines)} attachment(s):\n" + "\n".join(lines)


def discord_tool(rec: dict[str, Any], name: str, args: dict[str, Any]) -> str:
    """반환 문구는 server.ts 와 같은 모양. 거절·실패는 SessionError. 봇 토큰은 방 .env 링크의 것(방마다 다른 봇 규칙)."""
    sd = Path(str(rec["stateDir"]))
    token = ms.read_token_file(sd / ".env")
    dc = ms.Discord(token)
    if name == "reply":
        return _reply(rec, dc, token, args)
    if name == "fetch_messages":
        return _fetch(dc, sd, args)
    if name == "download_attachment":
        return _download(dc, sd, args)
    chat_id, mid = str(args.get("chat_id") or ""), str(args.get("message_id") or "")
    _gate(dc, sd, chat_id)
    if not re.fullmatch(r"\d{1,25}", mid):
        raise ms.SessionError("message_id 는 숫자 ID 여야 해")
    if name == "react":
        dc.add_reaction(chat_id, mid, str(args.get("emoji") or ""))
        return "reacted"
    if name == "edit_message":
        edited = dc._req("PATCH", f"/channels/{chat_id}/messages/{mid}", {"content": str(args.get("text") or "")})
        return f"edited (id: {(edited or {}).get('id') or mid})"
    raise ms.SessionError(f"없는 도구: {name}")


# ── 인바운드(Task 4) — 떠 있는 코덱스 방의 입력창에 글을 넣고 rollout 으로 전달을 확인한다 ──

PANE_INPUT_RE = re.compile(r"^\x1b\[1m\u203a\x1b\[0m ?(.*)$")      # 입력창 = 마지막 ›(S2). 비었으면 흐린 안내문(ESC[2m…)
PANE_QUEUED = "Messages to be submitted"                              # 바쁠 때 Enter 로 넣은 글의 대기 목록 머리(S3)
DELIVERED_KEEP = 200


def type_text(tmux: str, text: str) -> None:
    """붙여넣기(브래킷 페이스트) → 대기 → Enter 따로. 한 번에 보내면 코덱스가 Enter 를 붙여넣기 묶음으로 보고 삼킨다(S3)."""
    ms.tmux_leave_mode(tmux)
    buf = f"marina-codex-{os.getpid()}"
    subprocess.run(ms._tmux_base() + ["load-buffer", "-b", buf, "-"], input=text, text=True, capture_output=True)
    ms._tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", tmux)
    time.sleep(float(os.environ.get("MARINA_ENTER_DELAY") or 0.6))
    ms._tmux("send-keys", "-t", tmux, "Enter")


def input_holds_text(screen: str) -> bool:
    """입력창(마지막 › 줄, -e 캡처)에 글이 남아 있나 — 흐린 안내문이거나 비었으면 False."""
    for line in reversed(screen.splitlines()):
        m = PANE_INPUT_RE.match(line)
        if m:
            rest = m.group(1)
            return bool(rest.strip()) and not rest.startswith("\x1b[2m")
    return False


def _screen(tmux: str) -> str:
    return ms._tmux("capture-pane", "-p", "-e", "-t", tmux).stdout or ""


def confirm(rollout: "Path | None", offset: int, marker: str, tmux: str = "", timeout: "float | None" = None) -> bool:
    """rollout 의 offset 뒤에 marker 가 나오면 True. 바쁠 때 넣은 글은 기록이 다음 도구 호출 뒤에야 생기므로
    화면의 대기 목록에 marker 가 보여도 접수된 것으로 본다(S3). 입력창에 글이 남아 있으면 Enter 를 다시(최대 3번)."""
    wait = float(os.environ.get("MARINA_CODEX_CONFIRM_TIMEOUT") or 8.0) if timeout is None else timeout
    deadline, resent, last_enter = time.time() + wait, 0, time.time()
    while True:
        if rollout is not None:
            try:
                with rollout.open("rb") as fh:
                    fh.seek(offset)
                    if marker.encode() in fh.read():
                        return True
            except OSError:
                pass
        if tmux:
            screen = _screen(tmux)
            if PANE_QUEUED in screen and marker in screen:
                return True
            if resent < 3 and time.time() - last_enter >= 1.5 and input_holds_text(screen):
                ms._tmux("send-keys", "-t", tmux, "Enter")
                resent, last_enter = resent + 1, time.time()
        if time.time() >= deadline:
            return False
        time.sleep(0.2)


def _taken_sids(rec: dict[str, Any]) -> "set[str]":
    return {str(r.get("sessionId")) for r in ms.load_sessions() if r.get("sessionId") and r.get("stateDir") != rec.get("stateDir")}


def deliver_missed(rec: dict[str, Any], cfg: dict[str, Any], message: str = "", thread: str = "") -> str:
    """살아 있는 코덱스 방에 아직 안 넣은 글을 넣는다. nothing | delivered | failed:* | busy.
    같은 글 두 번 넣기 금지 = 방 잠금 + woke.json.delivered + rollout 의 seen_ids."""
    import marina_discord_bot as mb
    import marina_discord_wake as mw
    sd, name = Path(str(rec["stateDir"])), str(rec.get("tmux") or "")
    with ms.room_lock(sd, wait=30.0) as got:
        if not got:
            return "busy"
        if not ms.tmux_alive(name):
            return mw._wake_locked(rec, cfg, sd, str(message or ""), str(thread or ""), None)
        now = time.time()
        since = (mw.snowflake_ts(message) if str(message).isdigit() else now) - mw.WAKE_RECENT_S
        dc = mb._dc(cfg)
        try:
            msgs, _older = mw.missed(rec, dc, since, trigger=message, thread=thread)
        except ms.SessionError as exc:
            mb._log(f"codex deliver {rec.get('task')}: Discord 읽기 실패 {exc}")
            return "failed:discord"
        done = set(mw._woke(rec).get("delivered") or [])
        msgs = [m for m in msgs if str(m["id"]) not in done]
        if not msgs:
            return "nothing"
        last = msgs[-1]
        lch, lid = str(last.get("channel_id") or rec["channelId"]), str(last["id"])
        text = "\n".join(mw._tag(m, str(rec["channelId"])) for m in msgs)
        ro = rollout_of(rec)
        offset = ro.stat().st_size if ro else 0
        t0 = time.time()
        type_text(name, text)
        if ro is None:                        # 첫 입력 전엔 rollout 을 모른다 — 새로 생긴 것 하나를 찾아 방 기록에 적는다
            deadline = t0 + 8.0
            while ro is None and time.time() < deadline:
                sid = discover_sid(rec.get("root") or "", t0 - 60, _taken_sids(rec))
                ro = find_rollout(sid) if sid else None
                if ro is None:
                    time.sleep(0.3)
            if ro is not None:
                ms._record_session_id(rec, sid)
        if not confirm(ro, offset, lid, tmux=name):
            mb._log(f"codex deliver {rec.get('task')}: 전달 확인 실패 {lid}")
            try:
                dc.add_reaction(lch, lid, "\u26a0\ufe0f")
            except ms.SessionError:
                pass
            return "failed:unconfirmed"
        keep = (list(done) + [str(m["id"]) for m in msgs])[-DELIVERED_KEEP:]
        mw._save_woke(sd, at=now, ok=True, delivered=keep)
        return "delivered"
