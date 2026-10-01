# Discord 세션 (`marina session`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `marina session new <프로젝트> <작업>` 한 번으로 워크트리 · 실행 환경 · Discord 채널 · tmux 안의 `claude --channels` 세션을 세우고, `ls/attach/start/stop/rm` 으로 다루며, 워크트리 삭제·유휴 판정과 연동한다.

**Architecture:** 새 모듈 `plugin/scripts/marina_session.py` 하나가 이름 규칙 · 설정/기록 파일 · Discord REST(urllib) · tmux 실행 · 명령을 모두 맡는다. 마리나 기존 기능은 `marina.sh worktree create` / `marina.sh start --all` 를 서브프로세스로 부르는 것만 쓰고, `remove_worktree`·`idle_verdict` 에는 지연 import 한 줄짜리 훅만 넣는다. 세션 대화 배달은 Claude Code Channels(공식 플러그인)가 한다.

**Tech Stack:** Python 3.9 호환(`from __future__ import annotations`), 표준 라이브러리만(urllib · subprocess · argparse), bash, tmux 3.x, Claude Code CLI(`--channels`, `--remote-control`).

**Spec:** `docs/superpowers/specs/2026-10-01-discord-sessions-design.md`

## Global Constraints

- 데몬은 python3.9 로 이 모듈을 import 한다: `marina_session.py` 첫 import 는 `from __future__ import annotations`. 기존 `plugin/tests/test-py39-compat.sh` 가 통과해야 한다.
- 새 의존성 금지 — 표준 라이브러리만. Discord API 주소는 `MARINA_DISCORD_API`(기본 `https://discord.com/api/v10`).
- 채널 플러그인 이름은 정확히 `plugin:discord@claude-plugins-official`.
- claude 실행 인자 순서: `claude [--continue] --channels <플러그인> --remote-control "<프로젝트>/<작업>" --append-system-prompt <채널 규칙> --disallowedTools AskUserQuestion` — `--disallowedTools` 는 가변 인자라 **맨 끝**.
- claude 는 깨끗한 env 로 띄운다: `/usr/bin/env -i` + `HOME PATH USER LOGNAME SHELL LANG LC_ALL TMPDIR`(있는 것만) + `TERM=xterm-256color` + `DISCORD_STATE_DIR`.
- 이름 규칙: 작업 이름은 `[A-Za-z0-9._/-]+`, `..` 금지. 워크트리 폴더 = `/:`→`-`. 채널 이름 = `/:.`→`-` 후 소문자. tmux 이름 = `<프로젝트>-<채널 이름>`. 상태 폴더 = `<channels_root>/discord-<프로젝트>-<채널 이름>`(권한 700). Remote Control 이름 = `<프로젝트>/<작업>`.
- 설정 `~/.marina/discord.json`(`guildId`, `tokenFile`, `projects.<id>.categoryId|allow`), 기록 `~/.marina/sessions.json`(`{"sessions":[...]}`). 둘 다 `MARINA_HOME` 아래.
- 테스트는 모두 `lib/harness.sh` 를 먼저 source 하고, tmux 는 **반드시** `MARINA_TMUX_SOCKET`(테스트 전용 소켓)으로만 돈다. 형의 실제 tmux · 세션 · `~/.claude/channels` 를 건드리지 않는다(`MARINA_CHANNELS_DIR` 로 돌림).
- `marina_sessions.py` · `marina_mobile.py` · `marina_term.py` 등 세션/모바일 코드는 수정하지 않는다.
- 사용자 메시지는 한국어. 
- **커밋:** 작업공간 규칙상 형이 "커밋"을 명시 요청하지 않으면 커밋하지 않는다. 각 태스크 마지막 단계는 `git status` 로 변경 확인까지만 하고, 커밋 요청이 있을 때만 적힌 메시지로 커밋한다.

## Review Focus

1. 대문자·점이 든 작업 이름(`Fix.Login`) — 채널 이름은 소문자·점 없음, tmux 이름에 `.` 없음이어야 한다 → Task 1 테스트.
2. Claude 세션 안에서 `marina session new` 를 부른 경우 — 띄운 claude 에 `CLAUDECODE`·`CLAUDE_CODE_*` 가 없어야 기록이 남는다 → Task 3 테스트.
3. 두 프로젝트에 같은 작업 이름 — `rm feat/x` 는 모호하다고 거부, `rm proj/feat/x` 는 동작 → Task 5 테스트.
4. Discord 에서 카테고리를 직접 지운 뒤 `new` — 저장된 `categoryId` 가 없으면 새로 만들고 설정을 고쳐야 한다 → Task 2 테스트.
5. 데몬 경로(`idle_verdict`)에서 `sessions.json` 이 깨졌거나 없음 — 예외 없이 "살아 있는 세션 없음" → Task 6 테스트.

---

### Task 1: 이름 규칙 · 설정 · 기록 (모듈 뼈대 + 테스트 공통 준비)

**Files:**
- Create: `plugin/scripts/marina_session.py`
- Create: `plugin/tests/lib/session_fixture.sh`
- Test: `plugin/tests/test-session-names.sh`

**Interfaces:**
- Produces (in `marina_session`): `SessionError(Exception)`, `marina_home() -> Path`, `channels_root() -> Path`, `worktree_dirname(task) -> str`, `channel_name(task) -> str`, `tmux_name(project, task) -> str`, `rc_name(project, task) -> str`, `state_dir(project, task) -> Path`, `config_path() -> Path`, `load_config() -> dict`, `save_config(cfg) -> None`, `project_config(cfg, project) -> dict`, `token_file(cfg) -> Path`, `read_token(cfg) -> str`, `project_root(project) -> Path`, `sessions_path() -> Path`, `load_sessions() -> list[dict]`, `save_sessions(items) -> None`, `find_session(ref, items=None) -> dict`, 상수 `PLUGIN`, `API_DEFAULT`, `MARINA_SH`, `CHANNEL_RULES`.
- Produces (fixture, bash): 변수 `SCRIPTS MARINA_SH TMPROOT SRC FD FAKE_OUT`, 환경 `MARINA_TMUX_SOCKET MARINA_CHANNELS_DIR MARINA_SESSION_BOOT_WAIT PATH(가짜 claude 우선)`, 함수 `start_fake_discord`, `msess`, `gi`, 가짜 claude(`$FAKE_OUT/<pid>/{argv(NUL 구분),env,cwd}`, `$TMPROOT/claude-fail` 가 있으면 즉시 exit 1).

- [ ] **Step 1: 테스트 공통 준비 파일 작성**

`plugin/tests/lib/session_fixture.sh`:
```bash
# marina session 테스트 공통 준비 — lib/harness.sh 를 source 한 **다음에** source 한다.
# 만드는 것: 테스트 전용 tmux 소켓 · 가짜 claude · 임시 git 프로젝트(proj) · discord.json · 토큰 파일.
# 가짜 Discord 는 start_fake_discord 로 필요한 테스트만 띄운다.
command -v tmux >/dev/null 2>&1 || { echo "SKIP(tmux 없음)"; exit 0; }
FIX_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "$FIX_HERE/../../scripts" && pwd -P)"
MARINA_SH="$SCRIPTS/marina.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/marina-session.XXXXXX")"; TMPROOT="$(cd "$TMPROOT" && pwd -P)"
export MARINA_TMUX_SOCKET="marina-test-$$"          # 형의 tmux 와 절대 섞이지 않게
export MARINA_CHANNELS_DIR="$MARINA_HOME/channels"  # 형의 ~/.claude/channels 대신
export MARINA_SESSION_BOOT_WAIT=0.5
FD="$TMPROOT/fakediscord"; mkdir -p "$FD"
FAKE_OUT="$TMPROOT/claude-calls"; mkdir -p "$FAKE_OUT"
FD_PID=""
fixture_cleanup() {
  tmux -L "$MARINA_TMUX_SOCKET" kill-server 2>/dev/null || true
  [ -n "$FD_PID" ] && kill "$FD_PID" 2>/dev/null || true
  rm -rf "$TMPROOT"
}
trap fixture_cleanup EXIT

# 가짜 claude — env -i 로 떠서 환경변수를 못 받으므로 경로를 스크립트에 박는다.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/claude" <<SH
#!/bin/sh
d="$FAKE_OUT/\$\$"; mkdir -p "\$d"
printf '%s\0' "\$@" > "\$d/argv"
env > "\$d/env"
pwd -P > "\$d/cwd"
[ -e "$TMPROOT/claude-fail" ] && exit 1
exec sleep 300
SH
chmod +x "$TMPROOT/bin/claude"
export PATH="$TMPROOT/bin:$PATH"

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok > "$1/r"; git -C "$1" add r; git -C "$1" commit -qm init; }
SRC="$TMPROOT/proj"; gi "$SRC"
printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$SRC" > "$MARINA_HOME/projects.json"
printf 'DISCORD_BOT_TOKEN=test-token\n' > "$MARINA_HOME/token.env"
cat > "$MARINA_HOME/discord.json" <<JSON
{"guildId":"G1","tokenFile":"$MARINA_HOME/token.env","projects":{"proj":{"categoryId":null,"allow":["U1"]}}}
JSON

start_fake_discord() {
  python3 "$FIX_HERE/fake_discord.py" "$FD" & FD_PID=$!
  for _ in $(seq 50); do [ -s "$FD/port" ] && break; sleep 0.1; done
  [ -s "$FD/port" ] || { echo "FAIL: 가짜 Discord 기동 실패"; exit 1; }
  export MARINA_DISCORD_API="http://127.0.0.1:$(cat "$FD/port")"
}
msess() { ( cd "$TMPROOT" && bash "$MARINA_SH" session "$@" ); }
```

- [ ] **Step 2: 실패하는 테스트 작성**

`plugin/tests/test-session-names.sh`:
```bash
#!/usr/bin/env bash
# marina session — 이름 규칙 · discord.json · sessions.json · 세션 찾기.
# 브랜치 이름이 Discord 채널(소문자·점 불가 취급)·tmux(점·콜론 불가)·워크트리 폴더로 갈라지는 규칙을 고정한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

PYTHONPATH="$SCRIPTS" python3 - "$SRC" <<'PY'
import json, os, sys
from pathlib import Path
import marina_session as ms
src = sys.argv[1]
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def raises(fn, needle):
    try: fn()
    except ms.SessionError as exc: return needle in str(exc)
    return False

check(ms.channel_name("feature/Fix.Login") == "feature-fix-login", "채널 이름: 소문자 + /. → -")
check(ms.worktree_dirname("feature/Fix.Login") == "feature-Fix.Login", "워크트리 폴더: 기존 규칙(/: → -) 그대로")
check(ms.tmux_name("proj", "feature/Fix.Login") == "proj-feature-fix-login", "tmux 이름에 점 없음")
check(ms.rc_name("proj", "feature/x") == "proj/feature/x", "Remote Control 이름")
check(ms.state_dir("proj", "feature/x") == Path(os.environ["MARINA_CHANNELS_DIR"]) / "discord-proj-feature-x", "상태 폴더 위치")
check(raises(lambda: ms.channel_name("a b"), "작업 이름"), "공백 거부")
check(raises(lambda: ms.channel_name("a..b"), "작업 이름"), "'..' 거부")

cfg = ms.load_config()
check(cfg["guildId"] == "G1", "discord.json 읽기")
check(ms.project_config(cfg, "proj")["allow"] == ["U1"], "프로젝트 설정")
check(raises(lambda: ms.project_config(cfg, "nope"), "nope"), "미등록 프로젝트 거부")
check(ms.read_token(cfg) == "test-token", "토큰 읽기")
check(ms.project_root("proj") == Path(os.path.realpath(src)), "projects.json 에서 root")
check(raises(lambda: ms.project_root("nope"), "등록되지 않은"), "미등록 프로젝트 root 거부")

Path(ms.token_file(cfg)).write_text("OTHER=1\n")
check(raises(lambda: ms.read_token(cfg), "DISCORD_BOT_TOKEN"), "토큰 줄 없음 거부")
ms.config_path().rename(ms.config_path().with_suffix(".bak"))
check(raises(ms.load_config, "discord.json"), "설정 없음 → 만드는 법 안내")
ms.config_path().with_suffix(".bak").rename(ms.config_path())

check(ms.load_sessions() == [], "기록 없음 → 빈 목록")
ms.sessions_path().write_text("{broken")
check(ms.load_sessions() == [], "기록 깨짐 → 빈 목록(예외 없음)")
items = [{"project": "proj", "task": "feature/x"}, {"project": "proj2", "task": "feature/x"}, {"project": "proj", "task": "solo"}]
ms.save_sessions(items)
check(ms.load_sessions() == items, "기록 저장·읽기 왕복")
check(ms.find_session("solo")["project"] == "proj", "작업 이름으로 찾기")
check(ms.find_session("proj2/feature/x")["project"] == "proj2", "프로젝트/작업으로 찾기(작업에 슬래시)")
check(raises(lambda: ms.find_session("feature/x"), "모호"), "두 프로젝트에 같은 작업 → 모호")
check(raises(lambda: ms.find_session("none"), "찾지 못했"), "없는 세션")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-names"
```

- [ ] **Step 3: 실패 확인**

Run: `bash plugin/tests/test-session-names.sh`
Expected: FAIL — `ModuleNotFoundError: No module named 'marina_session'`

- [ ] **Step 4: 모듈 뼈대 구현**

`plugin/scripts/marina_session.py`:
```python
#!/usr/bin/env python3
"""Discord 세션 — 워크트리 하나 = Discord 채널 하나 = tmux 안의 `claude --channels` 하나.

설계: docs/superpowers/specs/2026-10-01-discord-sessions-design.md
마리나는 실행 계층(worktree create · start)만 부른다. 대화 배달은 Claude Code Channels(공식 플러그인)가 한다.
데몬(python3.9)이 remove_worktree · idle_verdict 경로로 import 하므로 3.9 호환을 지킨다."""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

PLUGIN = "plugin:discord@claude-plugins-official"
API_DEFAULT = "https://discord.com/api/v10"
MARINA_SH = Path(__file__).resolve().parent / "marina.sh"
_TASK_RE = re.compile(r"[A-Za-z0-9._/-]+")
_KEEP_ENV = ("HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR")

CHANNEL_RULES = (
    "이 세션은 Discord 채널에 연결돼 있다. 상대는 Discord 만 보고 이 터미널은 보지 않는다.\n"
    "- 결과·질문·실패/막힘·완료는 반드시 discord reply 도구로 보낸다.\n"
    "- 긴 작업은 시작할 때 진행 메시지 하나를 reply 로 보내고 edit_message 로 갱신한다. "
    "끝나면 새 reply 를 보낸다(알림이 울리도록).\n"
    "- 질문은 번호 선택지 텍스트로 묻는다.\n"
    "- 이미지는 첨부한다. HTML 은 스크린샷과 열어볼 주소를 보낸다. 10MB 를 넘는 파일은 링크로 보낸다.\n"
    "- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다."
)


class SessionError(Exception):
    """사용자에게 그대로 보여줄 실패."""


# ── 경로·이름 ────────────────────────────────────────────────────────────────

def marina_home() -> Path:
    return Path(os.environ.get("MARINA_HOME") or "~/.marina").expanduser()


def channels_root() -> Path:
    return Path(os.environ.get("MARINA_CHANNELS_DIR") or "~/.claude/channels").expanduser()


def _check_task(task: str) -> None:
    if not _TASK_RE.fullmatch(task or "") or ".." in task:
        raise SessionError(f"작업 이름은 영문/숫자/./_/-(슬래시 포함)만 가능 — 공백·'..' 금지: {task!r}")


def worktree_dirname(task: str) -> str:
    """marina worktree create 의 폴더 이름 규칙(tr '/:' '--')과 같다."""
    _check_task(task)
    return re.sub(r"[/:]", "-", task)


def channel_name(task: str) -> str:
    """Discord 는 채널 이름을 소문자로 바꾼다 — 겹침 검사도 이 값으로 한다."""
    _check_task(task)
    return re.sub(r"[/:.]", "-", task).lower()


def tmux_name(project: str, task: str) -> str:
    return f"{project}-{channel_name(task)}"          # tmux 세션 이름엔 '.' ':' 불가


def rc_name(project: str, task: str) -> str:
    return f"{project}/{task}"


def state_dir(project: str, task: str) -> Path:
    return channels_root() / f"discord-{project}-{channel_name(task)}"


# ── 설정 discord.json ────────────────────────────────────────────────────────

def config_path() -> Path:
    return marina_home() / "discord.json"


def load_config() -> dict[str, Any]:
    p = config_path()
    if not p.is_file():
        raise SessionError(
            f"{p} 가 없어 — 예: {{\"guildId\": \"<서버ID>\", \"tokenFile\": \"~/.claude/channels/discord-token.env\", "
            f"\"projects\": {{\"<프로젝트>\": {{\"categoryId\": null, \"allow\": [\"<디스코드 사용자ID>\"]}}}}}}")
    try:
        cfg = json.loads(p.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise SessionError(f"{p} 를 읽지 못했어: {exc}")
    if not isinstance(cfg, dict) or not cfg.get("guildId") or not cfg.get("tokenFile"):
        raise SessionError(f"{p} 에 guildId · tokenFile 이 필요해")
    if not isinstance(cfg.get("projects"), dict):
        cfg["projects"] = {}
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    p = config_path()
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def project_config(cfg: dict[str, Any], project: str) -> dict[str, Any]:
    pc = cfg["projects"].get(project)
    if not isinstance(pc, dict):
        raise SessionError(
            f"{config_path()} 의 projects 에 '{project}' 가 없어 — "
            f"\"{project}\": {{\"categoryId\": null, \"allow\": [\"<디스코드 사용자ID>\"]}} 로 추가해")
    return pc


def token_file(cfg: dict[str, Any]) -> Path:
    return Path(str(cfg["tokenFile"])).expanduser()


def read_token(cfg: dict[str, Any]) -> str:
    p = token_file(cfg)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        raise SessionError(f"토큰 파일이 없어: {p}")
    for line in text.splitlines():
        if line.startswith("DISCORD_BOT_TOKEN="):
            tok = line.split("=", 1)[1].strip()
            if tok:
                return tok
    raise SessionError(f"{p} 에 DISCORD_BOT_TOKEN= 줄이 없어")


def project_root(project: str) -> Path:
    p = marina_home() / "projects.json"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise SessionError(f"{p} 를 읽지 못했어 — marina project add 로 프로젝트를 먼저 등록해")
    for item in data.get("projects", []) if isinstance(data, dict) else []:
        if str(item.get("id")) == project:
            return Path(os.path.realpath(os.path.expanduser(str(item.get("root") or ""))))
    raise SessionError(f"마리나에 등록되지 않은 프로젝트: {project} ('marina project ls' 로 확인)")


# ── 기록 sessions.json ───────────────────────────────────────────────────────

def sessions_path() -> Path:
    return marina_home() / "sessions.json"


def load_sessions() -> list[dict[str, Any]]:
    """깨졌거나 없으면 빈 목록 — 데몬 경로(idle_verdict)에서 예외를 내면 안 된다."""
    try:
        data = json.loads(sessions_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = data.get("sessions") if isinstance(data, dict) else None
    return [s for s in items if isinstance(s, dict)] if isinstance(items, list) else []


def save_sessions(items: list[dict[str, Any]]) -> None:
    p = sessions_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"sessions": items}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def find_session(ref: str, items: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """'<프로젝트>/<작업>' 정확 일치를 먼저, 없으면 작업 이름 일치. 여러 개면 모호."""
    items = load_sessions() if items is None else items
    hits = [s for s in items if f"{s.get('project')}/{s.get('task')}" == ref] \
        or [s for s in items if s.get("task") == ref]
    if not hits:
        raise SessionError(f"세션을 찾지 못했어: {ref} ('marina session ls' 로 확인)")
    if len(hits) > 1:
        names = ", ".join(f"{s.get('project')}/{s.get('task')}" for s in hits)
        raise SessionError(f"'{ref}' 가 여러 프로젝트에 있어 모호해 — <프로젝트>/<작업> 으로 지정해: {names}")
    return hits[0]
```

- [ ] **Step 5: 통과 확인**

Run: `bash plugin/tests/test-session-names.sh && bash plugin/tests/test-py39-compat.sh`
Expected: `PASS test-session-names`, `PASS test-py39-compat`

- [ ] **Step 6: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short`
Expected: `?? plugin/scripts/marina_session.py`, `?? plugin/tests/lib/session_fixture.sh`, `?? plugin/tests/test-session-names.sh`
커밋 요청이 있으면: `git add` 위 세 파일 → `git commit -m "feat(session): 이름 규칙·설정·기록 뼈대"`

---

### Task 2: Discord REST 클라이언트

**Files:**
- Modify: `plugin/scripts/marina_session.py` (Discord 절 추가)
- Create: `plugin/tests/lib/fake_discord.py`
- Test: `plugin/tests/test-session-discord.sh`

**Interfaces:**
- Consumes: `SessionError`, `load_config`, `save_config`, `project_config`, `API_DEFAULT` (Task 1)
- Produces: `DiscordError(SessionError)`(속성 `code: int`), `class Discord(token, base=None)` 메서드 `list_channels(guild) -> list[dict]`, `create_category(guild, name) -> str`, `create_text_channel(guild, name, parent) -> str`, `delete_channel(cid) -> None`; 함수 `ensure_category(dc, cfg, project) -> str`, `find_text_channel(dc, guild, parent, name) -> str | None`, `channel_ids(dc, guild) -> set[str]`
- 가짜 Discord: `python3 fake_discord.py <dir>` → `<dir>/port`, 요청 로그 `<dir>/log.jsonl`(`{"m","p","b"}`), `<dir>/fail_post` 내용이 `403` 이면 POST 403, `429once` 면 첫 POST 만 429(retry_after 0.05) 후 파일 삭제. 인증 헤더는 `Bot test-token` 만 통과.

- [ ] **Step 1: 가짜 Discord 작성**

`plugin/tests/lib/fake_discord.py`:
```python
#!/usr/bin/env python3
"""테스트용 가짜 Discord REST — marina session 이 쓰는 4개 호출만.
사용: python3 fake_discord.py <dir>  → <dir>/port 에 포트를 쓰고, 받은 요청을 <dir>/log.jsonl 에 남긴다.
스위치: <dir>/fail_post 가 '403' 이면 POST 를 403 으로, '429once' 면 첫 POST 만 429."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

state = Path(sys.argv[1]); state.mkdir(parents=True, exist_ok=True)
TOKEN = "Bot test-token"
channels = {}
next_id = [1000]
lock = threading.Lock()


def log(entry):
    with lock, open(state / "log.jsonl", "a") as f:
        f.write(json.dumps(entry) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        if self.headers.get("Authorization") != TOKEN:
            self._send(401, {"message": "401: Unauthorized"})
            return False
        return True

    def _parts(self):
        return self.path.strip("/").split("/")

    def do_GET(self):
        log({"m": "GET", "p": self.path})
        if not self._auth():
            return
        p = self._parts()
        if len(p) == 3 and p[0] == "guilds" and p[2] == "channels":
            with lock:
                self._send(200, list(channels.values()))
            return
        self._send(404, {"message": "404"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        log({"m": "POST", "p": self.path, "b": body})
        if not self._auth():
            return
        fp = state / "fail_post"
        mode = fp.read_text().strip() if fp.exists() else ""
        if mode == "403":
            self._send(403, {"message": "Missing Permissions"}); return
        if mode == "429once":
            fp.unlink(); self._send(429, {"message": "rate limited", "retry_after": 0.05}); return
        p = self._parts()
        if len(p) == 3 and p[0] == "guilds" and p[2] == "channels":
            with lock:
                next_id[0] += 1
                ch = {"id": str(next_id[0]), "name": body.get("name"), "type": body.get("type", 0),
                      "parent_id": body.get("parent_id"), "guild_id": p[1]}
                channels[ch["id"]] = ch
            self._send(201, ch); return
        self._send(404, {"message": "404"})

    def do_DELETE(self):
        log({"m": "DELETE", "p": self.path})
        if not self._auth():
            return
        p = self._parts()
        if len(p) == 2 and p[0] == "channels":
            with lock:
                ch = channels.pop(p[1], None)
            if ch is None:
                self._send(404, {"message": "Unknown Channel"}); return
            self._send(200, ch); return
        self._send(404, {"message": "404"})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
(state / "port").write_text(str(srv.server_address[1]))
srv.serve_forever()
```

- [ ] **Step 2: 실패하는 테스트 작성**

`plugin/tests/test-session-discord.sh`:
```bash
#!/usr/bin/env bash
# marina session — Discord REST: 카테고리·채널 생성/삭제, 카테고리 ID 저장·재사용·재생성, 401/403/429.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def posts(): return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]

cfg = ms.load_config()
dc = ms.Discord("test-token")

cat = ms.ensure_category(dc, cfg, "proj")
check(posts()[-1]["b"] == {"name": "PROJ", "type": 4}, f"카테고리 생성 요청: {posts()[-1]}")
check(ms.load_config()["projects"]["proj"]["categoryId"] == cat, "categoryId 를 discord.json 에 저장")
n = len(posts())
check(ms.ensure_category(dc, ms.load_config(), "proj") == cat and len(posts()) == n, "두 번째는 재사용(POST 없음)")

ch = dc.create_text_channel("G1", "feat-one", cat)
check(posts()[-1]["b"] == {"name": "feat-one", "type": 0, "parent_id": cat}, "카테고리 아래 텍스트 채널")
check(ms.find_text_channel(dc, "G1", cat, "feat-one") == ch, "이름으로 채널 찾기")
check(ms.find_text_channel(dc, "G1", cat, "nope") is None, "없는 채널 → None")
check(ch in ms.channel_ids(dc, "G1"), "channel_ids")

dc.delete_channel(ch)
check(ch not in ms.channel_ids(dc, "G1"), "채널 삭제")
try:
    dc.delete_channel(ch); check(False, "없는 채널 삭제는 DiscordError")
except ms.DiscordError as exc:
    check(exc.code == 404, f"없는 채널 삭제 → 404: {exc.code}")

dc.delete_channel(cat)                                   # Discord 에서 카테고리를 직접 지운 상황
cat2 = ms.ensure_category(dc, ms.load_config(), "proj")
check(cat2 != cat and ms.load_config()["projects"]["proj"]["categoryId"] == cat2, "사라진 카테고리 → 새로 만들고 설정 갱신")

try:
    ms.Discord("wrong").list_channels("G1"); check(False, "잘못된 토큰은 실패해야")
except ms.DiscordError as exc:
    check(exc.code == 401 and "401" in str(exc), f"401 안내: {exc}")

(fd / "fail_post").write_text("403")
try:
    dc.create_text_channel("G1", "x", cat2); check(False, "403 은 실패해야")
except ms.DiscordError as exc:
    check(exc.code == 403 and "채널 관리" in str(exc), f"403 안내: {exc}")
(fd / "fail_post").write_text("429once")
check(bool(dc.create_text_channel("G1", "after-429", cat2)), "429 한 번 뒤 재시도 성공")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-discord"
```

- [ ] **Step 3: 실패 확인**

Run: `bash plugin/tests/test-session-discord.sh`
Expected: FAIL — `AttributeError: module 'marina_session' has no attribute 'ensure_category'`

- [ ] **Step 4: Discord 절 구현** — `marina_session.py` 의 `find_session` 뒤에 추가:

```python
# ── Discord REST ─────────────────────────────────────────────────────────────

class DiscordError(SessionError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def _explain(code: int, method: str, path: str) -> str:
    if code == 401:
        return "Discord 가 토큰을 거부했어(401) — discord.json 의 tokenFile 을 확인해"
    if code == 403:
        return "봇 권한이 부족해(403) — 서버 설정 → 역할 → 봇 역할에서 '채널 관리하기'를 켜"
    if code == 404:
        return f"Discord 에서 대상을 찾지 못했어(404): {method} {path}"
    return f"Discord API 오류 {code}: {method} {path}"


class Discord:
    def __init__(self, token: str, base: str | None = None):
        self.token = token
        self.base = (base or os.environ.get("MARINA_DISCORD_API") or API_DEFAULT).rstrip("/")

    def _req(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(4):
            req = urllib.request.Request(self.base + path, data=data, method=method, headers={
                "Authorization": f"Bot {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "DiscordBot (https://github.com/sumin/marina, 1)",
            })
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                raw = exc.read() or b"{}"
                if exc.code == 429 and attempt < 3:
                    try:
                        wait = float(json.loads(raw).get("retry_after", 1))
                    except (ValueError, AttributeError):
                        wait = 1.0
                    time.sleep(min(max(wait, 0.0), 10.0))
                    continue
                raise DiscordError(exc.code, _explain(exc.code, method, path))
            except urllib.error.URLError as exc:
                raise SessionError(f"Discord 에 연결하지 못했어: {exc.reason}")
        raise DiscordError(429, "Discord 가 계속 요청을 늦추라고 해(429) — 잠시 뒤 다시 해")

    def list_channels(self, guild: str) -> list[dict[str, Any]]:
        return self._req("GET", f"/guilds/{guild}/channels") or []

    def create_category(self, guild: str, name: str) -> str:
        return str(self._req("POST", f"/guilds/{guild}/channels", {"name": name, "type": 4})["id"])

    def create_text_channel(self, guild: str, name: str, parent: str) -> str:
        body = {"name": name, "type": 0, "parent_id": parent}
        return str(self._req("POST", f"/guilds/{guild}/channels", body)["id"])

    def delete_channel(self, cid: str) -> None:
        self._req("DELETE", f"/channels/{cid}")


def ensure_category(dc: Discord, cfg: dict[str, Any], project: str) -> str:
    """프로젝트 카테고리 ID. 저장된 ID 가 Discord 에 없으면(직접 지움) 새로 만들고 discord.json 을 고친다."""
    pc = project_config(cfg, project)
    cid = str(pc.get("categoryId") or "")
    if cid and any(str(c.get("id")) == cid and c.get("type") == 4 for c in dc.list_channels(cfg["guildId"])):
        return cid
    cid = dc.create_category(cfg["guildId"], project.upper())
    pc["categoryId"] = cid
    save_config(cfg)
    return cid


def find_text_channel(dc: Discord, guild: str, parent: str, name: str) -> str | None:
    for c in dc.list_channels(guild):
        if c.get("type") == 0 and str(c.get("parent_id") or "") == str(parent) \
                and str(c.get("name") or "").lower() == name:
            return str(c["id"])
    return None


def channel_ids(dc: Discord, guild: str) -> set[str]:
    return {str(c.get("id")) for c in dc.list_channels(guild)}
```

- [ ] **Step 5: 통과 확인**

Run: `bash plugin/tests/test-session-discord.sh && bash plugin/tests/test-session-names.sh`
Expected: `PASS test-session-discord`, `PASS test-session-names`

- [ ] **Step 6: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 파일 `plugin/tests/lib/fake_discord.py`, `plugin/tests/test-session-discord.sh` 와 수정 `plugin/scripts/marina_session.py`.
커밋 요청 시 메시지: `feat(session): Discord REST 클라이언트`

---

### Task 3: tmux 실행기 (깨끗한 env · claude 인자)

**Files:**
- Modify: `plugin/scripts/marina_session.py` (tmux 절 추가)
- Test: `plugin/tests/test-session-tmux.sh`

**Interfaces:**
- Consumes: `PLUGIN`, `CHANNEL_RULES`, `rc_name`, `SessionError` (Task 1)
- Produces: `_tmux_base() -> list[str]`, `tmux_alive(name) -> bool`, `clean_env_prefix(extra: dict[str, str]) -> list[str]`, `claude_argv(project, task, resume=False) -> list[str]`, `tmux_start(name, cwd, argv, env_extra) -> None`(죽으면 `SessionError`), `tmux_stop(name) -> None`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-session-tmux.sh`:
```bash
#!/usr/bin/env bash
# marina session — tmux 안에 claude 를 깨끗한 env 로 띄운다.
# Claude 세션 안에서 부르면 CLAUDECODE·CLAUDE_CODE_* 를 물려받아 자식 세션이 되고 기록이 꺼진다(실측 2026-09-10).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
export CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PLUGIN_ROOT=/x   # Claude 세션 안에서 부른 상황

PYTHONPATH="$SCRIPTS" python3 - "$SRC" "$FAKE_OUT" "$TMPROOT" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
import marina_session as ms
src, out, tmproot = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def last_call():
    calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
    return calls[-1] if calls else None

check(ms._tmux_base() == ["tmux", "-L", os.environ["MARINA_TMUX_SOCKET"]], "테스트 소켓으로만 tmux 를 부른다")

argv = ms.claude_argv("proj", "feat/one")
check(argv[:5] == ["claude", "--channels", ms.PLUGIN, "--remote-control", "proj/feat/one"], f"인자 앞부분: {argv[:5]}")
check(argv[5] == "--append-system-prompt" and "reply" in argv[6], "채널 규칙")
check(argv[-2:] == ["--disallowedTools", "AskUserQuestion"], "가변 인자 --disallowedTools 는 맨 끝")
check(ms.claude_argv("proj", "feat/one", resume=True)[:2] == ["claude", "--continue"], "resume → --continue")

ms.tmux_start("proj-feat-one", src, argv, {"DISCORD_STATE_DIR": "/state/x"})
check(ms.tmux_alive("proj-feat-one"), "tmux 세션 살아 있음")
time.sleep(0.3)
call = last_call()
check(call is not None, "가짜 claude 가 실행됨")
if call:
    got = (call / "argv").read_bytes().split(b"\0")[:-1]
    check([a.decode() for a in got] == argv[1:], "claude 가 받은 인자 = claude_argv(프로그램 이름 제외)")
    env = dict(l.split("=", 1) for l in (call / "env").read_text().splitlines() if "=" in l)
    check(env.get("DISCORD_STATE_DIR") == "/state/x", "DISCORD_STATE_DIR 전달")
    check(env.get("TERM") == "xterm-256color", "TERM")
    leaked = sorted(k for k in env if k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_") or k == "CLAUDE_PLUGIN_ROOT")
    check(not leaked, f"자식 세션 표식이 새어 들어감: {leaked}")
    check((call / "cwd").read_text().strip() == str(src.resolve()), "워크트리에서 실행")

ms.tmux_stop("proj-feat-one")
check(not ms.tmux_alive("proj-feat-one"), "tmux_stop 후 꺼짐")
ms.tmux_stop("proj-feat-one")                                   # 없는 세션 정지는 조용히

(tmproot / "claude-fail").touch()
try:
    ms.tmux_start("proj-dies", src, argv, {}); check(False, "바로 죽으면 SessionError")
except ms.SessionError as exc:
    check("꺼졌" in str(exc), f"바로 꺼짐 안내: {exc}")
check(not ms.tmux_alive("proj-dies"), "죽은 세션이 남지 않음")
(tmproot / "claude-fail").unlink()

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-tmux"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-tmux.sh`
Expected: FAIL — `AttributeError: module 'marina_session' has no attribute '_tmux_base'`

- [ ] **Step 3: tmux 절 구현** — `channel_ids` 뒤에 추가:

```python
# ── tmux ─────────────────────────────────────────────────────────────────────

def _tmux_base() -> list[str]:
    """테스트는 MARINA_TMUX_SOCKET 으로 전용 소켓을 쓴다 — 형의 tmux 와 섞이지 않게."""
    sock = os.environ.get("MARINA_TMUX_SOCKET")
    return ["tmux", "-L", sock] if sock else ["tmux"]


def _tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(_tmux_base() + list(args), capture_output=True, text=True)


def tmux_alive(name: str) -> bool:
    if not name or not shutil.which("tmux"):
        return False
    return _tmux("has-session", "-t", f"={name}").returncode == 0


def clean_env_prefix(extra: dict[str, str]) -> list[str]:
    """화이트리스트 env 만 넘긴다. Claude 세션 안에서 부르면 CLAUDECODE·CLAUDE_CODE_* 를 물려받아
    자식 세션이 되고 트랜스크립트 저장이 꺼진다(실측 2026-09-10)."""
    out = ["/usr/bin/env", "-i"]
    out += [f"{k}={os.environ[k]}" for k in _KEEP_ENV if os.environ.get(k)]
    out.append("TERM=xterm-256color")
    out += [f"{k}={v}" for k, v in extra.items()]
    return out


def claude_argv(project: str, task: str, resume: bool = False) -> list[str]:
    argv = ["claude"]
    if resume:
        argv.append("--continue")
    argv += ["--channels", PLUGIN,
             "--remote-control", rc_name(project, task),
             "--append-system-prompt", CHANNEL_RULES,
             # 가변 인자라 뒤따르는 값을 삼킨다 — 맨 끝에 둔다(marina_term 실측 2026-09-10)
             "--disallowedTools", "AskUserQuestion"]
    return argv


def tmux_start(name: str, cwd: Path, argv: list[str], env_extra: dict[str, str]) -> None:
    cmd = shlex.join(clean_env_prefix(env_extra) + argv)
    r = _tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", str(cwd), cmd)
    if r.returncode != 0:
        raise SessionError(f"tmux 실행 실패: {(r.stderr or r.stdout).strip()}")
    time.sleep(float(os.environ.get("MARINA_SESSION_BOOT_WAIT") or 2.0))
    if not tmux_alive(name):
        raise SessionError(f"claude 가 바로 꺼졌어 — 직접 확인: cd {shlex.quote(str(cwd))} && claude --channels {PLUGIN}")


def tmux_stop(name: str) -> None:
    if tmux_alive(name):
        _tmux("kill-session", "-t", f"={name}")
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-session-tmux.sh && bash plugin/tests/test-py39-compat.sh`
Expected: `PASS test-session-tmux`, `PASS test-py39-compat`

- [ ] **Step 5: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-tmux.sh`, 수정 `plugin/scripts/marina_session.py`.
커밋 요청 시 메시지: `feat(session): tmux 실행기·깨끗한 env`

---

### Task 4: `marina session new` (사전 점검 · 되돌리기 · CLI 연결)

**Files:**
- Modify: `plugin/scripts/marina_session.py` (상태 폴더 · 마리나 호출 · new · main)
- Modify: `plugin/scripts/marina.sh` (`session)` 분기 + usage 한 줄)
- Test: `plugin/tests/test-session-new.sh`

**Interfaces:**
- Consumes: Task 1~3 전부
- Produces: `write_state_dir(path, channel_id, allow, token_path) -> None`, `remove_state_dir(path) -> None`, `_run_marina(args, cwd=None, timeout=300) -> CompletedProcess`, `worktree_create(project, task, base="") -> Path`, `marina_start(root) -> str`(성공이면 `""`, 실패면 경고), `preflight(cfg, dc, project, task) -> dict`(키 `root worktree tmux stateDir channel`), `cmd_new(project, task, base="", start=True) -> dict`(기록 + `url` + `warning`), `main(argv=None) -> int`. 기록 키: `project task root channelId tmux stateDir rcName createdAt`.

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-session-new.sh`:
```bash
#!/usr/bin/env bash
# marina session new — 워크트리 + 채널 + 상태 폴더 + tmux claude 를 한 번에. 겹치면 아무것도 안 만들고,
# 중간에 실패하면 채널·상태 폴더를 되돌리되 워크트리는 남긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
nposts() { grep -c '"POST"' "$FD/log.jsonl" 2>/dev/null || echo 0; }

# 1) 정상
out="$(msess new proj feat/one --no-start 2>&1)" || fail "new 실패: $out"
WT="$SRC/.claude/worktrees/feat-one"
[ -d "$WT" ] || fail "워크트리 없음"
[ "$(git -C "$WT" branch --show-current)" = "feat/one" ] || fail "워크트리 브랜치"
tmux -L "$MARINA_TMUX_SOCKET" has-session -t =proj-feat-one 2>/dev/null || fail "tmux 세션 없음"
echo "$out" | grep -q "discord.com/channels/G1/" || fail "채널 링크 출력 없음: $out"

PYTHONPATH="$SCRIPTS" python3 - "$FD" "$WT" "$MARINA_HOME" "$FAKE_OUT" <<'PY'
import json, os, stat, sys
from pathlib import Path
import marina_session as ms
fd, wt, mh, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
posts = [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]
cat = ms.load_config()["projects"]["proj"]["categoryId"]
check(posts[0]["b"] == {"name": "PROJ", "type": 4}, "카테고리 생성")
check(posts[1]["b"] == {"name": "feat-one", "type": 0, "parent_id": cat}, f"채널 생성: {posts[1]}")
rec = ms.find_session("proj/feat/one")
check(rec["root"] == str(wt) and rec["tmux"] == "proj-feat-one" and rec["rcName"] == "proj/feat/one", f"기록: {rec}")
sd = Path(rec["stateDir"])
check(sd == ms.state_dir("proj", "feat/one"), "상태 폴더 위치")
check(stat.S_IMODE(sd.stat().st_mode) == 0o700, "상태 폴더 권한 700")
acc = json.loads((sd / "access.json").read_text())
check(acc["dmPolicy"] == "allowlist" and acc["allowFrom"] == ["U1"], f"access.json 허용자: {acc}")
check(acc["groups"] == {rec["channelId"]: {"requireMention": False, "allowFrom": ["U1"]}}, "access.json 채널")
check((sd / ".env").is_symlink() and os.readlink(sd / ".env") == str(mh / "token.env"), ".env → 토큰 파일 심링크")
calls = sorted((p for p in out.iterdir() if (p / "argv").exists()), key=lambda p: p.stat().st_mtime)
argv = [a.decode() for a in (calls[-1] / "argv").read_bytes().split(b"\0")[:-1]]
check(argv == ms.claude_argv("proj", "feat/one")[1:], "claude 인자(프로그램 이름 제외)")
env = dict(l.split("=", 1) for l in (calls[-1] / "env").read_text().splitlines() if "=" in l)
check(env.get("DISCORD_STATE_DIR") == str(sd), "DISCORD_STATE_DIR")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY

# 2) 사전 점검 — 같은 이름은 아무것도 안 만든다
before="$(nposts)"
out="$(msess new proj feat/one --no-start 2>&1)" && fail "같은 이름이 성공함"
echo "$out" | grep -q "이미" || fail "겹침 안내 없음: $out"
[ "$(nposts)" = "$before" ] || fail "겹침인데 Discord POST 가 나감"

# 3) Discord 에 같은 이름 채널이 이미 있으면 워크트리도 안 만든다
CAT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projects"]["proj"]["categoryId"])' "$MARINA_HOME/discord.json")"
curl -s -X POST -H "Authorization: Bot test-token" -H "Content-Type: application/json" \
  -d "{\"name\":\"feat-two\",\"type\":0,\"parent_id\":\"$CAT\"}" "$MARINA_DISCORD_API/guilds/G1/channels" >/dev/null
out="$(msess new proj feat/two --no-start 2>&1)" && fail "채널 겹침이 성공함"
echo "$out" | grep -q "#feat-two" || fail "채널 겹침 안내 없음: $out"
[ ! -e "$SRC/.claude/worktrees/feat-two" ] || fail "채널 겹침인데 워크트리를 만듦"

# 4) 되돌리기 — claude 가 바로 죽으면 채널·상태 폴더 삭제, 워크트리는 남김, 기록 없음
touch "$TMPROOT/claude-fail"
out="$(msess new proj feat/three --no-start 2>&1)" && fail "claude 실패가 성공으로 끝남"
rm -f "$TMPROOT/claude-fail"
echo "$out" | grep -q "워크트리는 남겨" || fail "워크트리 남김 안내 없음: $out"
[ -d "$SRC/.claude/worktrees/feat-three" ] || fail "워크트리를 지움(남겨야 함)"
[ ! -e "$MARINA_CHANNELS_DIR/discord-proj-feat-three" ] || fail "상태 폴더가 남음"
grep -q '"DELETE"' "$FD/log.jsonl" || fail "만든 채널 삭제 요청 없음"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["sessions"]; sys.exit(0 if all(x["task"]!="feat/three" for x in s) else 1)' "$MARINA_HOME/sessions.json" || fail "실패한 세션이 기록됨"

# 5) 미등록 프로젝트
out="$(msess new nope feat/x --no-start 2>&1)" && fail "미등록 프로젝트가 성공함"
echo "$out" | grep -q "discord.json" || fail "프로젝트 추가 안내 없음: $out"

# 6) marina start 실패는 경고만(세션은 연다) — 함수 단위
PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import subprocess, sys
import marina_session as ms
ms.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 1, stdout="", stderr="compose 없음")
w = ms.marina_start(ms.Path("/tmp"))
sys.exit(0 if "marina start 실패" in w and "compose 없음" in w else 1)
PY
echo "PASS test-session-new"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-new.sh`
Expected: FAIL — `new 실패: ... unknown command: session`

- [ ] **Step 3: 상태 폴더 · 마리나 호출 · new · main 구현** — `tmux_stop` 뒤에 추가:

```python
# ── 상태 폴더 · 마리나 실행 계층 ─────────────────────────────────────────────

def write_state_dir(path: Path, channel_id: str, allow: list[str], token_path: Path) -> None:
    """채널 플러그인의 DISCORD_STATE_DIR. 토큰은 복사하지 않고 심링크 — 기본 폴더에 토큰을 두면
    열린 모든 Claude 세션이 같은 봇으로 접속한다(실측 2026-10-01)."""
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    access = {"dmPolicy": "allowlist", "allowFrom": list(allow),
              "groups": {channel_id: {"requireMention": False, "allowFrom": list(allow)}},
              "ackReaction": "👀", "replyToMode": "first"}
    (path / "access.json").write_text(json.dumps(access, ensure_ascii=False) + "\n", encoding="utf-8")
    env = path / ".env"
    if env.is_symlink() or env.exists():
        env.unlink()
    env.symlink_to(token_path)


def remove_state_dir(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


def _run_marina(args: list[str], cwd: Path | None = None, timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(MARINA_SH)] + args, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True, timeout=timeout)


def worktree_create(project: str, task: str, base: str = "") -> Path:
    r = _run_marina(["worktree", "create", task] + ([base] if base else []) + ["--project", project])
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        raise SessionError("워크트리 생성 실패: " + out.strip()[-800:])
    m = re.search(r"✓ 워크트리:\s*(.+)", out)
    if not m:
        raise SessionError("워크트리 경로를 출력에서 찾지 못했어: " + out.strip()[-400:])
    return Path(m.group(1).strip())


def marina_start(root: Path) -> str:
    """실행 환경 시작. 실패해도 세션은 연다 — 실행 환경은 나중에 켜도 된다. 성공이면 빈 문자열."""
    try:
        r = _run_marina(["start", "--all"], cwd=root, timeout=900)
    except subprocess.TimeoutExpired:
        return "marina start 가 15분 안에 끝나지 않았어 — marina status 로 확인해"
    if r.returncode == 0:
        return ""
    return "marina start 실패(세션은 열었어): " + (r.stderr or r.stdout or "").strip()[-400:]


# ── 명령 ─────────────────────────────────────────────────────────────────────

def preflight(cfg: dict[str, Any], dc: Discord, project: str, task: str) -> dict[str, Any]:
    """아무것도 만들기 전에 전부 본다 — 하나라도 걸리면 SessionError."""
    pc = project_config(cfg, project)
    root = project_root(project)
    tf = token_file(cfg)
    if not tf.is_file():
        raise SessionError(f"토큰 파일이 없어: {tf}")
    for exe in ("tmux", "claude"):
        if not shutil.which(exe):
            raise SessionError(f"'{exe}' 를 찾지 못했어 (PATH 확인)")
    wt = root / ".claude" / "worktrees" / worktree_dirname(task)
    name, sdir, chan = tmux_name(project, task), state_dir(project, task), channel_name(task)
    if wt.exists():
        raise SessionError(f"워크트리가 이미 있어: {wt}")
    if tmux_alive(name):
        raise SessionError(f"tmux 세션이 이미 있어: {name}")
    if sdir.exists():
        raise SessionError(f"상태 폴더가 이미 있어: {sdir}")
    if any(s.get("project") == project and s.get("task") == task for s in load_sessions()):
        raise SessionError(f"세션 기록이 이미 있어: {project}/{task}")
    cat = str(pc.get("categoryId") or "")
    if cat and find_text_channel(dc, cfg["guildId"], cat, chan):
        raise SessionError(f"Discord 채널이 이미 있어: #{chan}")
    return {"root": root, "worktree": wt, "tmux": name, "stateDir": sdir, "channel": chan}


def cmd_new(project: str, task: str, base: str = "", start: bool = True) -> dict[str, Any]:
    cfg = load_config()
    dc = Discord(read_token(cfg))
    plan = preflight(cfg, dc, project, task)
    wt = worktree_create(project, task, base)
    warning = marina_start(wt) if start else ""
    sdir: Path = plan["stateDir"]
    channel_id = ""
    try:
        cat = ensure_category(dc, cfg, project)
        channel_id = dc.create_text_channel(cfg["guildId"], plan["channel"], cat)
        write_state_dir(sdir, channel_id, project_config(cfg, project).get("allow") or [], token_file(cfg))
        tmux_start(plan["tmux"], wt, claude_argv(project, task), {"DISCORD_STATE_DIR": str(sdir)})
    except Exception as exc:
        remove_state_dir(sdir)
        if channel_id:
            try:
                dc.delete_channel(channel_id)
            except SessionError:
                pass
        raise SessionError(f"{exc}\n워크트리는 남겨 뒀어: {wt} (필요 없으면 대시보드에서 삭제)")
    record = {"project": project, "task": task, "root": str(wt), "channelId": channel_id,
              "tmux": plan["tmux"], "stateDir": str(sdir), "rcName": rc_name(project, task),
              "createdAt": int(time.time())}
    items = load_sessions()
    items.append(record)
    save_sessions(items)
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning=warning)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="marina session",
                                 description="워크트리 하나 = Discord 채널 하나 = tmux 안의 claude 하나")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new")
    p.add_argument("project")
    p.add_argument("task")
    p.add_argument("--base", default="")
    p.add_argument("--no-start", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "new":
            r = cmd_new(a.project, a.task, a.base, start=not a.no_start)
            print(f"✓ 세션: {r['project']}/{r['task']}")
            print(f"  Discord: {r['url']}")
            print(f"  Remote Control: {r['rcName']}  (claude.ai/code · 모바일 앱)")
            print(f"  들여다보기: marina session attach {r['project']}/{r['task']}  (나오기: Ctrl-b d)")
            if r["warning"]:
                print("  ⚠ " + r["warning"], file=sys.stderr)
    except SessionError as exc:
        print(f"marina session: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: `marina.sh` 에 분기 추가** — `worktree)` 분기 바로 위에:

```bash
    session)
      # 워크트리 하나 = Discord 채널 하나 = tmux 안의 claude --channels 하나.
      # 설계: docs/superpowers/specs/2026-10-01-discord-sessions-design.md
      PYTHONPATH="$SCRIPT_DIR" MARINA_HOME="$MARINA_HOME" exec python3 "$SCRIPT_DIR/marina_session.py" "$@" ;;
```

그리고 `usage()` 의 `marina.sh worktree create ...` 줄 바로 아래에:
```
    marina.sh session new <project> <task> [--base B] [--no-start] | ls | attach | start | stop | rm   # Discord 채널 = 워크트리 세션(tmux + claude --channels)
```

- [ ] **Step 5: 통과 확인**

Run: `bash plugin/tests/test-session-new.sh && bash plugin/tests/test-worktree-create.sh && bash plugin/tests/test-py39-compat.sh`
Expected: `PASS test-session-new`, `PASS test-worktree-create`, `PASS test-py39-compat`
(실패 시 먼저 볼 것: `marina.sh` 가 `session` 분기에 닿기 전에 cwd 의 프로젝트 해석에서 죽는지 — 테스트는 프로젝트 밖(`$TMPROOT`)에서 부른다. 죽는다면 `reap)` 처럼 전역 명령이 처리되는 위치로 `session)` 을 옮긴다.)

- [ ] **Step 6: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-new.sh`, 수정 `marina_session.py`, `marina.sh`.
커밋 요청 시 메시지: `feat(session): marina session new — 워크트리+채널+tmux claude`

---

### Task 5: `ls` · `attach` · `start` · `stop` · `rm`

**Files:**
- Modify: `plugin/scripts/marina_session.py` (명령 + main 하위 명령)
- Test: `plugin/tests/test-session-lifecycle.sh`

**Interfaces:**
- Consumes: Task 1~4 전부
- Produces: `cmd_ls() -> list[dict]`(기록 + `alive: bool` + `channel: bool | None`), `cmd_start(ref="", all_=False) -> tuple[list[str], list[str]]`(시작함, 실패 메시지), `teardown(s) -> list[str]`(경고, 404 는 이미 지워진 것으로 봄), `teardown_for_root(root) -> list[str]`(절대 예외 안 올림), `has_live_session(root) -> bool`(절대 예외 안 올림). CLI: `ls [--json]`, `attach <ref>`, `start <ref> | --all`, `stop <ref>`, `rm <ref>`.

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-session-lifecycle.sh`:
```bash
#!/usr/bin/env bash
# marina session ls/start/stop/rm — 꺼진 세션은 --continue 로 이어 띄우고, rm 은 tmux·채널·상태 폴더·기록을 지운다
# (워크트리는 그대로). 두 프로젝트에 같은 작업 이름이면 <프로젝트>/<작업> 으로만 지정된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
alive() { tmux -L "$MARINA_TMUX_SOCKET" has-session -t "=$1" 2>/dev/null; }
lsjson() { msess ls --json | python3 -c "import json,sys; r={f\"{s['project']}/{s['task']}\": s for s in json.load(sys.stdin)}; print(json.dumps(r.get(sys.argv[1], {}).get(sys.argv[2])))" "$1" "$2"; }

msess new proj feat/one --no-start >/dev/null 2>&1 || fail "new"
[ "$(lsjson proj/feat/one alive)" = "true" ] || fail "ls: 켜짐"
[ "$(lsjson proj/feat/one channel)" = "true" ] || fail "ls: 채널 있음"
msess ls | grep -q "proj/feat/one" || fail "ls 사람용 출력"

msess stop feat/one >/dev/null || fail "stop"
alive proj-feat-one && fail "stop 후에도 살아 있음"
[ "$(lsjson proj/feat/one alive)" = "false" ] || fail "ls: 꺼짐"

msess start feat/one >/dev/null || fail "start"
alive proj-feat-one || fail "start 후 꺼져 있음"
last="$(ls -t "$FAKE_OUT" | head -1)"
python3 -c 'import sys; a=open(sys.argv[1],"rb").read().split(b"\0"); sys.exit(0 if a[0]==b"--continue" else 1)' "$FAKE_OUT/$last/argv" || fail "start 는 --continue 로 이어야 함"

msess stop feat/one >/dev/null; msess start --all >/dev/null || fail "start --all"
alive proj-feat-one || fail "start --all 후 꺼져 있음"

# Discord 에서 채널을 직접 지운 경우
CH="$(lsjson proj/feat/one channelId | tr -d '"')"
curl -s -X DELETE -H "Authorization: Bot test-token" "$MARINA_DISCORD_API/channels/$CH" >/dev/null
[ "$(lsjson proj/feat/one channel)" = "false" ] || fail "ls: 채널 없음 표시"

# 두 번째 프로젝트에 같은 작업 이름
SRC2="$TMPROOT/proj2"; gi "$SRC2"
python3 - "$MARINA_HOME" "$SRC2" <<'PY'
import json, sys
mh, src2 = sys.argv[1], sys.argv[2]
p = json.load(open(f"{mh}/projects.json")); p["projects"].append({"id": "proj2", "root": src2, "subrepos": []})
json.dump(p, open(f"{mh}/projects.json", "w"))
d = json.load(open(f"{mh}/discord.json")); d["projects"]["proj2"] = {"categoryId": None, "allow": ["U1"]}
json.dump(d, open(f"{mh}/discord.json", "w"))
PY
msess new proj2 feat/one --no-start >/dev/null 2>&1 || fail "proj2 new"
out="$(msess rm feat/one 2>&1)" && fail "모호한 rm 이 성공함"
echo "$out" | grep -q "모호" || fail "모호 안내 없음: $out"

msess rm proj/feat/one >/dev/null 2>&1 || fail "rm proj/feat/one (채널은 이미 없음 → 404 는 무시)"
alive proj-feat-one && fail "rm 후 tmux 살아 있음"
[ ! -e "$MARINA_CHANNELS_DIR/discord-proj-feat-one" ] || fail "rm 후 상태 폴더 남음"
[ -d "$SRC/.claude/worktrees/feat-one" ] || fail "rm 이 워크트리를 지움(남겨야 함)"
[ "$(lsjson proj/feat/one alive)" = "null" ] || fail "rm 후 기록 남음"
alive proj2-feat-one || fail "다른 프로젝트 세션까지 꺼짐"

CH2="$(lsjson proj2/feat/one channelId | tr -d '"')"
msess rm proj2/feat/one >/dev/null 2>&1 || fail "rm proj2"
grep -q "\"DELETE\", \"p\": \"/channels/$CH2\"" "$FD/log.jsonl" || fail "rm 이 채널 삭제를 요청하지 않음"

out="$(msess attach nope 2>&1)" && fail "없는 세션 attach 가 성공함"
echo "$out" | grep -q "찾지 못했" || fail "attach 없는 세션 안내"
echo "PASS test-session-lifecycle"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-lifecycle.sh`
Expected: FAIL — `ls: 켜짐` 단계에서 argparse 오류(`invalid choice: 'ls'`)

- [ ] **Step 3: 명령 구현** — `cmd_new` 뒤에 추가:

```python
def cmd_ls() -> list[dict[str, Any]]:
    items = load_sessions()
    ids: set[str] | None = None
    if items:
        try:
            cfg = load_config()
            ids = channel_ids(Discord(read_token(cfg)), cfg["guildId"])
        except SessionError:
            ids = None                       # Discord 를 못 봐도 목록은 보여준다
    return [dict(s, alive=tmux_alive(str(s.get("tmux") or "")),
                 channel=None if ids is None else str(s.get("channelId")) in ids) for s in items]


def cmd_start(ref: str = "", all_: bool = False) -> tuple[list[str], list[str]]:
    targets = load_sessions() if all_ else [find_session(ref)]
    started: list[str] = []
    failed: list[str] = []
    for s in targets:
        label = f"{s.get('project')}/{s.get('task')}"
        name = str(s.get("tmux") or "")
        if tmux_alive(name):
            continue
        root = Path(str(s.get("root") or ""))
        if not s.get("root") or not root.is_dir():
            failed.append(f"{label}: 워크트리가 없어 건너뜀")
            continue
        try:
            tmux_start(name, root, claude_argv(str(s["project"]), str(s["task"]), resume=True),
                       {"DISCORD_STATE_DIR": str(s.get("stateDir") or "")})
            started.append(label)
        except SessionError as exc:
            failed.append(f"{label}: {exc}")
    return started, failed


def teardown(s: dict[str, Any]) -> list[str]:
    """tmux · 채널 · 상태 폴더 · 기록을 지운다(워크트리는 안 건드림). 채널 404 는 이미 지워진 것."""
    warnings: list[str] = []
    tmux_stop(str(s.get("tmux") or ""))
    if s.get("channelId"):
        try:
            cfg = load_config()
            Discord(read_token(cfg)).delete_channel(str(s["channelId"]))
        except DiscordError as exc:
            if exc.code != 404:
                warnings.append(f"채널 삭제 실패: {exc}")
        except SessionError as exc:
            warnings.append(f"채널 삭제 실패: {exc}")
    if s.get("stateDir"):
        remove_state_dir(Path(str(s["stateDir"])))
    save_sessions([x for x in load_sessions()
                   if not (x.get("project") == s.get("project") and x.get("task") == s.get("task"))])
    return warnings


def _same_root(s: dict[str, Any], target: Path) -> bool:
    return bool(s.get("root")) and Path(str(s["root"])).resolve() == target


def teardown_for_root(root: Path) -> list[str]:
    """remove_worktree 가 부른다. 절대 예외를 올리지 않는다 — 워크트리 삭제를 막으면 안 된다."""
    warnings: list[str] = []
    try:
        target = Path(root).resolve()
        for s in load_sessions():
            if _same_root(s, target):
                warnings += teardown(s)
    except Exception as exc:
        warnings.append(f"세션 정리 실패: {exc}")
    return warnings


def has_live_session(root: Path) -> bool:
    """idle_verdict(데몬)가 부른다. 절대 예외를 올리지 않는다."""
    try:
        target = Path(root).resolve()
        return any(_same_root(s, target) and tmux_alive(str(s.get("tmux") or "")) for s in load_sessions())
    except Exception:
        return False
```

그리고 `main` 의 하위 명령 정의(`p.add_argument("--no-start", ...)` 다음)에 추가:
```python
    p = sub.add_parser("ls")
    p.add_argument("--json", action="store_true")
    for name in ("attach", "stop", "rm"):
        sub.add_parser(name).add_argument("ref")
    p = sub.add_parser("start")
    p.add_argument("ref", nargs="?", default="")
    p.add_argument("--all", action="store_true")
```
`main` 의 `if a.cmd == "new": ...` 블록 뒤(같은 `try` 안)에 추가:
```python
        elif a.cmd == "ls":
            rows = cmd_ls()
            if a.json:
                print(json.dumps(rows, ensure_ascii=False, indent=2))
            elif not rows:
                print("세션 없음")
            for s in ([] if a.json else rows):
                ch = "채널 ?" if s["channel"] is None else ("채널 있음" if s["channel"] else "채널 없음")
                print(f"{s['project']}/{s['task']}\t{'켜짐' if s['alive'] else '꺼짐'}\t{ch}\t{s['root']}")
        elif a.cmd == "attach":
            s = find_session(a.ref)
            os.execvp("tmux", _tmux_base() + ["attach", "-t", f"={s['tmux']}"])
        elif a.cmd == "start":
            if not a.all and not a.ref:
                raise SessionError("start <작업> 또는 start --all")
            started, failed = cmd_start(a.ref, a.all)
            for x in started:
                print(f"✓ 시작: {x}")
            for x in failed:
                print(f"✗ {x}", file=sys.stderr)
            return 1 if failed else 0
        elif a.cmd == "stop":
            s = find_session(a.ref)
            tmux_stop(str(s["tmux"]))
            print(f"✓ 정지: {s['project']}/{s['task']}")
        elif a.cmd == "rm":
            s = find_session(a.ref)
            for x in teardown(s):
                print("⚠ " + x, file=sys.stderr)
            print(f"✓ 정리: {s['project']}/{s['task']} (워크트리는 그대로)")
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-session-lifecycle.sh && bash plugin/tests/test-session-new.sh`
Expected: `PASS test-session-lifecycle`, `PASS test-session-new`

- [ ] **Step 5: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-lifecycle.sh`, 수정 `marina_session.py`.
커밋 요청 시 메시지: `feat(session): ls/attach/start/stop/rm`

---

### Task 6: 워크트리 삭제 · 유휴 판정 연동

**Files:**
- Modify: `plugin/scripts/marina_lifecycle.py` (`remove_worktree`, `stop_all(root)` 줄 다음과 `results = {...}` 줄 다음)
- Modify: `plugin/scripts/marina_worktree_gc.py` (`idle_verdict`, `live_proc = _root_has_live_agent(...)` 줄 다음)
- Test: `plugin/tests/test-session-worktree-hooks.sh`

**Interfaces:**
- Consumes: `marina_session.teardown_for_root(root) -> list[str]`, `marina_session.has_live_session(root) -> bool` (Task 5)
- Produces: `remove_worktree(...)` 결과에 `discordSessions: list[str]`(경고 목록). `idle_verdict` 가 살아 있는 Discord 세션을 `gcLiveProcess=True` 로 본다.

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-session-worktree-hooks.sh`:
```bash
#!/usr/bin/env bash
# 채널 수명 = 워크트리 수명: remove_worktree 가 Discord 세션을 정리하고(실패해도 삭제는 진행),
# 유휴 판정은 살아 있는 Discord 세션의 워크트리를 활동 중으로 본다. sessions.json 이 깨져도 데몬 경로는 무사.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
mkdir -p "$SRC/.claude/worktrees"
for wt in wt-a wt-b; do git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$wt" HEAD; done

PYTHONPATH="$SCRIPTS" python3 - "$SRC" "$FD" <<'PY'
import json, sys, time
from pathlib import Path
src, fd = Path(sys.argv[1]), Path(sys.argv[2])
import marina_session as ms
import marina_lifecycle
import marina_worktree_gc as gc
from marina_registry import discover_all_roots
discover_all_roots(refresh=True)
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
W = lambda n: src / ".claude" / "worktrees" / n
marina_lifecycle.stop_all = lambda root: {"stoppedAll": True}
marina_lifecycle.cleanup_session = lambda root: {"removed": ""}
marina_lifecycle.bootout_session_dashboard = lambda sid: None

# 1) 실제 teardown_for_root — tmux·채널·상태 폴더·기록이 사라진다
cfg = ms.load_config(); dc = ms.Discord("test-token")
cat = ms.ensure_category(dc, cfg, "proj")
ch = dc.create_text_channel("G1", "wt-a", cat)
sd = ms.state_dir("proj", "wt-a")
ms.write_state_dir(sd, ch, ["U1"], ms.token_file(cfg))
ms.tmux_start("proj-wt-a", W("wt-a"), ms.claude_argv("proj", "wt-a"), {"DISCORD_STATE_DIR": str(sd)})
ms.save_sessions([{"project": "proj", "task": "wt-a", "root": str(W("wt-a")), "channelId": ch,
                   "tmux": "proj-wt-a", "stateDir": str(sd), "rcName": "proj/wt-a", "createdAt": 0}])
check(ms.has_live_session(W("wt-a")), "살아 있는 세션 감지")

# 2) 유휴 판정: 30일 전 커밋이어도 살아 있는 Discord 세션이면 활동 중
info = {"lastCommitTs": time.time() - 30 * 86400}
v = gc.idle_verdict(W("wt-a"), info, [], set(), days=14)
check(v["gcLiveProcess"] is True and v["gcIdle"] is False, f"살아 있는 세션 → 활동 중: {v}")
v2 = gc.idle_verdict(W("wt-b"), info, [], set(), days=14)
check(v2["gcLiveProcess"] is False, f"세션 없는 워크트리는 그대로: {v2}")

# 3) remove_worktree 가 세션을 정리한다
res = marina_lifecycle.remove_worktree(W("wt-a"), keep_images=True)
check(res.get("discordSessions") == [], f"정리 경고 없음: {res.get('discordSessions')}")
check(not ms.tmux_alive("proj-wt-a"), "tmux 종료")
check(not sd.exists(), "상태 폴더 삭제")
check(ms.load_sessions() == [], "기록 삭제")
log = (fd / "log.jsonl").read_text()
check(f'"DELETE", "p": "/channels/{ch}"' in log, "채널 삭제 요청")
check(not W("wt-a").exists(), "워크트리 삭제")

# 4) 세션 정리가 터져도 워크트리 삭제는 진행
ms.teardown_for_root = lambda root: (_ for _ in ()).throw(RuntimeError("boom"))
res = marina_lifecycle.remove_worktree(W("wt-b"), keep_images=True)
check(not W("wt-b").exists(), "정리 실패해도 워크트리 삭제")
check(any("boom" in w for w in res.get("discordSessions") or []), f"실패가 결과에 드러남: {res.get('discordSessions')}")

# 5) sessions.json 이 깨져도 데몬 경로는 예외 없음
ms.sessions_path().write_text("{broken")
check(ms.has_live_session(src) is False, "깨진 기록 → False")
check(ms.teardown_for_root(src) == [], "깨진 기록 → 정리할 것 없음")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-worktree-hooks"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-worktree-hooks.sh`
Expected: FAIL — `살아 있는 세션 → 활동 중` 과 `정리 경고 없음: None` 단언 실패

- [ ] **Step 3: `remove_worktree` 훅** — `plugin/scripts/marina_lifecycle.py` 의 `remove_worktree` 안:

`stop_all(root)` 줄 바로 다음에:
```python
    # Discord 세션(tmux claude · 채널 · 상태 폴더) 정리 — 채널 수명 = 워크트리 수명. 실패해도 삭제는 진행.
    try:
        from marina_session import teardown_for_root
        discord_warnings = teardown_for_root(root)
    except Exception as exc:
        discord_warnings = [f"세션 정리 실패: {exc}"]
```
`results: dict[str, Any] = {"subrepos": {}, "branches": {}, "root": None}` 줄 바로 다음에:
```python
    results["discordSessions"] = discord_warnings
```

- [ ] **Step 4: `idle_verdict` 훅** — `plugin/scripts/marina_worktree_gc.py` 의 `idle_verdict` 안 `live_proc = _root_has_live_agent(root, live_cwds or set())` 줄 바로 다음에:
```python
    if not live_proc:
        try:   # 마리나 PTY 밖(tmux)에서 도는 Discord 세션도 활동 신호다
            from marina_session import has_live_session
            live_proc = has_live_session(root)
        except Exception:
            pass
```

- [ ] **Step 5: 통과 확인 (연동한 기존 테스트 포함)**

Run: `bash plugin/tests/test-session-worktree-hooks.sh && bash plugin/tests/test-worktree-remove-reclaim.sh && bash plugin/tests/test-worktree-gc.sh && bash plugin/tests/test-py39-compat.sh`
Expected: 네 개 모두 `PASS`

- [ ] **Step 6: 영향 범위 전체 확인**

Run: `bash plugin/tests/run-affected.sh`
Expected: 고른 테스트 전부 PASS(건너뛴 것과 이유가 출력됨). 실패가 있으면 이 태스크 변경 때문인지 `git stash` 없이 판단 — 기존 실패면 메모리의 플레이키 목록(`marina-test-env-isolation`)과 대조해 보고에 적는다.

- [ ] **Step 7: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-worktree-hooks.sh`, 수정 `marina_lifecycle.py`, `marina_worktree_gc.py`.
커밋 요청 시 메시지: `feat(session): 워크트리 삭제·유휴 판정 연동`

---

### Task 8: 상태 표시 — Stop 훅으로 👀 → ✅

**Files:**
- Modify: `plugin/scripts/marina_session.py` (Discord 메서드 3개, 설정 파일, 훅, env, claude 인자, main)
- Modify: `plugin/tests/lib/fake_discord.py` (반응 PUT/DELETE, 메시지 POST)
- Test: `plugin/tests/test-session-status-hook.sh`

**Interfaces:**
- Consumes: Task 1~5
- Produces: `Discord.add_reaction(cid, mid, emoji) -> None`, `Discord.remove_reaction(cid, mid, emoji) -> None`, `Discord.send_message(cid, content) -> None`, `write_settings(sdir: Path) -> Path`(`<sdir>/settings.json`), `session_env(sdir: Path) -> dict[str, str]`, `last_inbound_message(transcript: Path, channel_id: str) -> str | None`, `hook_stop(payload: dict) -> None`, CLI `hook-stop`(stdin 에 훅 JSON, 항상 exit 0). `claude_argv` 에 `--settings <state_dir>/settings.json` 추가(`--append-system-prompt` 다음, `--disallowedTools` 앞).

- [ ] **Step 1: 가짜 Discord 에 반응·메시지 추가** — `plugin/tests/lib/fake_discord.py`:

`do_POST` 의 `p = self._parts()` 다음 줄에:
```python
        if len(p) == 3 and p[0] == "channels" and p[2] == "messages":
            self._send(200, {"id": "m-sent", "content": body.get("content")}); return
```
`do_DELETE` 의 `p = self._parts()` 다음 줄에:
```python
        if len(p) >= 4 and p[0] == "channels" and p[2] == "messages":
            self._send(204); return
```
`do_DELETE` 메서드 뒤에 새 메서드:
```python
    def do_PUT(self):
        log({"m": "PUT", "p": self.path})
        if not self._auth():
            return
        self._send(204)
```

- [ ] **Step 2: 실패하는 테스트 작성**

`plugin/tests/test-session-status-hook.sh`:
```bash
#!/usr/bin/env bash
# 작업 중/끝남을 Claude 판단이 아니라 훅으로 기계적으로 보인다: 플러그인이 받은 메시지에 👀, Stop 훅이 턴 끝에 👀→✅.
# 훅은 어떤 실패에도 세션을 방해하지 않는다(항상 exit 0).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }

PYTHONPATH="$SCRIPTS" python3 - "$TMPROOT" "$SRC" <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
tmp, src = Path(sys.argv[1]), Path(sys.argv[2])
cfg = ms.load_config(); dc = ms.Discord("test-token")
cat = ms.ensure_category(dc, cfg, "proj"); ch = dc.create_text_channel("G1", "st", cat)
sd = ms.state_dir("proj", "st"); ms.write_state_dir(sd, ch, ["U1"], ms.token_file(cfg))
f = ms.write_settings(sd)
s = json.loads(f.read_text())
assert f == sd / "settings.json"
assert "hook-stop" in s["hooks"]["Stop"][0]["hooks"][0]["command"], s
assert s["enabledPlugins"] == {"discord@claude-plugins-official": True}, s
argv = ms.claude_argv("proj", "st")
i = argv.index("--settings")
assert argv[i + 1] == str(sd / "settings.json") and argv[-2:] == ["--disallowedTools", "AskUserQuestion"], argv
env = ms.session_env(sd)
assert env["DISCORD_STATE_DIR"] == str(sd) and env["MARINA_HOME"] == str(ms.marina_home()), env
ms.save_sessions([{"project": "proj", "task": "st", "root": str(src), "channelId": ch, "tmux": "proj-st",
                   "stateDir": str(sd), "rcName": "proj/st", "createdAt": 0}])
# 세션 기록(jsonl): 다른 채널 메시지 → 이 채널 M1 → 이 채널 M2. JSON 안이라 따옴표가 \" 로 이스케이프된다.
def line(cid, mid):
    text = f'<channel source="plugin:discord:discord" chat_id="{cid}" message_id="{mid}" user="u" ts="t">\nhi\n</channel>'
    return json.dumps({"type": "user", "message": {"role": "user", "content": text}})
(tmp / "t.jsonl").write_text("\n".join([line("999", "MX"), line(ch, "M1"), line(ch, "M2")]) + "\n")
(tmp / "chan").write_text(ch); (tmp / "sd").write_text(str(sd))
PY
CH="$(cat "$TMPROOT/chan")"; SD="$(cat "$TMPROOT/sd")"
hook() { DISCORD_STATE_DIR="$1" PYTHONPATH="$SCRIPTS" python3 "$SCRIPTS/marina_session.py" hook-stop; }

printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "훅이 0 이 아닌 코드로 끝남"
grep -q "\"PUT\", \"p\": \"/channels/$CH/messages/M2/reactions/%E2%9C%85/@me\"" "$FD/log.jsonl" || fail "마지막 메시지(M2)에 ✅ 추가 요청 없음"
grep -q "\"DELETE\", \"p\": \"/channels/$CH/messages/M2/reactions/%F0%9F%91%80/@me\"" "$FD/log.jsonl" || fail "👀 제거 요청 없음"
grep -q "/messages/MX/" "$FD/log.jsonl" && fail "다른 채널 메시지에 반응함"

n="$(wc -l < "$FD/log.jsonl")"
printf '{"cwd":"/nowhere","transcript_path":"%s"}' "$TMPROOT/t.jsonl" | hook "/no/such/state" || fail "모르는 세션에서 실패 코드"
printf 'not json' | hook "$SD" || fail "깨진 입력에서 실패 코드"
printf '{"cwd":"%s","transcript_path":"/no/file"}' "$SRC" | hook "$SD" || fail "기록 파일 없음에서 실패 코드"
[ "$(wc -l < "$FD/log.jsonl")" = "$n" ] || fail "할 일 없는 훅이 Discord 를 불렀음"
mv "$MARINA_HOME/discord.json" "$MARINA_HOME/discord.json.bak"
printf '{"cwd":"%s","transcript_path":"%s"}' "$SRC" "$TMPROOT/t.jsonl" | hook "$SD" || fail "설정 없음에서 실패 코드"
mv "$MARINA_HOME/discord.json.bak" "$MARINA_HOME/discord.json"
echo "PASS test-session-status-hook"
```

- [ ] **Step 3: 실패 확인**

Run: `bash plugin/tests/test-session-status-hook.sh`
Expected: FAIL — `AttributeError: module 'marina_session' has no attribute 'write_settings'`

- [ ] **Step 4: 구현**

`marina_session.py` 맨 위 import 에 `import urllib.parse` 추가(알파벳 순, `import urllib.error` 다음).

`class Discord` 의 `delete_channel` 다음에:
```python
    def add_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("PUT", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def remove_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("DELETE", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def send_message(self, cid: str, content: str) -> None:
        self._req("POST", f"/channels/{cid}/messages", {"content": content})
```

`remove_state_dir` 다음에:
```python
_CHANNEL_TAG = re.compile(r'<channel source=\\?"plugin:discord:discord\\?" chat_id=\\?"(\d+)\\?" message_id=\\?"([^"\\]+)')


def write_settings(sdir: Path) -> Path:
    """채널 세션 전용 설정(--settings). 사용자 설정과 합쳐진다.
    Stop 훅 = 턴이 끝나면 👀→✅. enabledPlugins = 사용자 범위에서 플러그인을 꺼도 이 세션에서만 켜지게."""
    cmd = shlex.join([sys.executable, str(Path(__file__).resolve()), "hook-stop"])
    settings = {"enabledPlugins": {"discord@claude-plugins-official": True},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": cmd, "timeout": 15}]}]}}
    f = sdir / "settings.json"
    f.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return f


def session_env(sdir: Path) -> dict[str, str]:
    """claude 는 깨끗한 env 로 뜨므로, 훅·알림이 마리나 상태를 찾을 변수를 넣어 준다."""
    env = {"DISCORD_STATE_DIR": str(sdir), "MARINA_HOME": str(marina_home())}
    for k in ("MARINA_DISCORD_API", "MARINA_CHANNELS_DIR"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def last_inbound_message(transcript: Path, channel_id: str) -> str | None:
    """세션 기록 끝 2MB 에서 이 채널에서 받은 마지막 메시지 ID(JSON 이스케이프 \" 도 허용)."""
    try:
        data = transcript.read_bytes()[-2_000_000:].decode("utf-8", "replace")
    except OSError:
        return None
    last = None
    for m in _CHANNEL_TAG.finditer(data):
        if m.group(1) == channel_id:
            last = m.group(2)
    return last


def hook_stop(payload: dict[str, Any]) -> None:
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    root = Path(str(payload.get("cwd") or "/nonexistent")).resolve()
    items = load_sessions()
    s = next((x for x in items if sdir and x.get("stateDir") == sdir), None) \
        or next((x for x in items if _same_root(x, root)), None)
    if not s or not s.get("channelId"):
        return
    mid = last_inbound_message(Path(str(payload.get("transcript_path") or "/nonexistent")), str(s["channelId"]))
    if not mid:
        return
    cfg = load_config()
    dc = Discord(read_token(cfg))
    dc.add_reaction(str(s["channelId"]), mid, "✅")
    try:
        dc.remove_reaction(str(s["channelId"]), mid, "👀")
    except DiscordError:
        pass
```

`claude_argv` 의 `"--append-system-prompt", CHANNEL_RULES,` 줄 다음에:
```python
             "--settings", str(state_dir(project, task) / "settings.json"),
```

`cmd_new` 의 `write_state_dir(...)` 줄 다음에 `write_settings(sdir)` 를 넣고, 그 아래 `tmux_start` 의 env 인자를 `session_env(sdir)` 로 바꾼다:
```python
        write_state_dir(sdir, channel_id, project_config(cfg, project).get("allow") or [], token_file(cfg))
        write_settings(sdir)
        tmux_start(plan["tmux"], wt, claude_argv(project, task), session_env(sdir))
```
`cmd_start` 의 `tmux_start(...)` 호출 env 인자도 `session_env(Path(str(s.get("stateDir") or "")))` 로 바꾼다.

`main` 의 하위 명령 정의에 `sub.add_parser("hook-stop")` 추가, 그리고 `a = ap.parse_args(argv)` **바로 다음**(try 앞)에:
```python
    if a.cmd == "hook-stop":
        try:   # 훅은 어떤 실패에도 세션을 방해하지 않는다
            hook_stop(json.loads(sys.stdin.read() or "{}"))
        except Exception:
            pass
        return 0
```

- [ ] **Step 5: 통과 확인 (앞 태스크 회귀 포함)**

Run: `for t in names discord tmux new lifecycle worktree-hooks status-hook; do bash plugin/tests/test-session-$t.sh || break; done && bash plugin/tests/test-py39-compat.sh`
Expected: `PASS` 8줄

- [ ] **Step 6: 실측 — 사용자 범위에서 꺼도 채널 세션에서만 켜지나** (진짜 claude, 형 환경)

```bash
claude plugin disable discord@claude-plugins-official --scope user
S=$(mktemp -d); git -C "$S" init -q; d=$(mktemp -d); chmod 700 "$d"; ln -s ~/.claude/channels/discord-token.env "$d/.env"
echo '{"dmPolicy":"allowlist","allowFrom":[],"groups":{}}' > "$d/access.json"
printf '{"enabledPlugins":{"discord@claude-plugins-official":true}}' > "$d/settings.json"
env -i HOME=$HOME PATH=$PATH USER=$USER TERM=xterm-256color LANG=en_US.UTF-8 tmux new-session -d -s plugprobe -c "$S" \
  "DISCORD_STATE_DIR=$d claude --channels plugin:discord@claude-plugins-official --settings $d/settings.json"
sleep 15; p=$(tmux list-panes -t plugprobe -F '#{pane_pid}'); pgrep -P "$p" | xargs -I{} ps -o command= -p {} | grep -c "bun run"
tmux kill-session -t plugprobe; rm -rf "$S" "$d"
```
(신뢰 확인창이 뜨면 `tmux send-keys -t plugprobe Down Enter` 후 다시 확인.)
- `1` 이상 → 성공: 사용자 범위는 꺼 둔 채로 둔다(형에게 보고).
- `0` → 실패: `claude plugin enable discord@claude-plugins-official --scope user` 로 되돌리고, 지금 상태(사용자 범위 켬 + 기본 폴더 토큰 없음)를 유지한다고 보고.

- [ ] **Step 7: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-status-hook.sh`, 수정 `marina_session.py`, `lib/fake_discord.py`.
커밋 요청 시 메시지: `feat(session): Stop 훅으로 👀→✅ 상태 표시`

---

### Task 9: 세션 죽음 알림 — claude 를 감싸서 끝나면 채널에 알림

**Files:**
- Modify: `plugin/scripts/marina_session.py` (`tmux_start` 감싸기, `notify_exit`, main)
- Test: `plugin/tests/test-session-exit-notice.sh`

**Interfaces:**
- Consumes: Task 8 의 `Discord.send_message`, `session_env`
- Produces: `tmux_start(name, cwd, argv, env_extra, notify_ref="")` — `notify_ref` 가 있으면 `sh -c '"$@"; code=$?; trap "" HUP; <python> marina_session.py notify-exit <ref> "$code" &' sh <argv...>` 로 감싼다. `notify_exit(ref, code) -> None`, CLI `notify-exit <ref> <code>`(항상 exit 0). `cmd_new`·`cmd_start` 는 `notify_ref=f"{project}/{task}"` 를 넘긴다.

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-session-exit-notice.sh`:
```bash
#!/usr/bin/env bash
# 세션 죽음을 상시 감시 없이 안다: claude 가 스스로 끝나면 감싼 셸이 채널에 알린다.
# stop·rm 의 kill-session 은 셸째 죽으므로 알리지 않는다(일부러 끈 건 알림 0).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
notices() { grep -c '"POST", "p": "/channels/[0-9]*/messages"' "$FD/log.jsonl" 2>/dev/null || echo 0; }
claude_pid() { ls -t "$FAKE_OUT" | head -1; }   # 가짜 claude 는 exec sleep 이라 폴더 이름 = 살아 있는 pid

msess new proj feat/one --no-start >/dev/null 2>&1 || fail "new"
kill -TERM "$(claude_pid)"
for _ in $(seq 50); do [ "$(notices)" -ge 1 ] && break; sleep 0.1; done
[ "$(notices)" = 1 ] || fail "claude 가 스스로 끝났는데 알림이 없음(또는 여러 건): $(notices)"
grep '"/messages"' "$FD/log.jsonl" | grep -q "꺼졌어" || fail "알림 문구"
grep '"/messages"' "$FD/log.jsonl" | grep -q "marina session start proj/feat/one" || fail "다시 켜는 명령 안내"

msess start feat/one >/dev/null || fail "start"
msess stop feat/one >/dev/null || fail "stop"
sleep 1
[ "$(notices)" = 1 ] || fail "stop 으로 끈 세션을 알림: $(notices)"
msess start feat/one >/dev/null || fail "start 2"
msess rm proj/feat/one >/dev/null 2>&1 || fail "rm"
sleep 1
[ "$(notices)" = 1 ] || fail "rm 으로 끈 세션을 알림: $(notices)"

PYTHONPATH="$SCRIPTS" python3 "$SCRIPTS/marina_session.py" notify-exit nope/x 1 || fail "모르는 세션 알림이 실패 코드"
echo "PASS test-session-exit-notice"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-exit-notice.sh`
Expected: FAIL — `claude 가 스스로 끝났는데 알림이 없음(또는 여러 건): 0`

- [ ] **Step 3: 구현**

`tmux_start` 를 다음으로 바꾼다:
```python
def tmux_start(name: str, cwd: Path, argv: list[str], env_extra: dict[str, str], notify_ref: str = "") -> None:
    run = list(argv)
    if notify_ref:
        # claude 가 스스로 끝나면 채널에 알린다. kill-session(stop·rm)은 셸째 죽어 알리지 않는다.
        notify = shlex.join([sys.executable, str(Path(__file__).resolve()), "notify-exit", notify_ref])
        # 알림은 떼어 보내 셸이 바로 끝나게 한다("기동 직후 죽음"을 tmux_alive 가 놓치지 않게).
        # nohup 은 셸 종료 시 tmux 의 HUP 과 경쟁해 같이 죽었다(실측) — 부모가 먼저 HUP 를 무시하고 띄운다.
        run = ["/bin/sh", "-c", f'"$@"; code=$?; trap "" HUP; {notify} "$code" >/dev/null 2>&1 </dev/null &', "sh"] + run
    cmd = shlex.join(clean_env_prefix(env_extra) + run)
    r = _tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", str(cwd), cmd)
    if r.returncode != 0:
        raise SessionError(f"tmux 실행 실패: {(r.stderr or r.stdout).strip()}")
    time.sleep(float(os.environ.get("MARINA_SESSION_BOOT_WAIT") or 2.0))
    if not tmux_alive(name):
        raise SessionError(f"claude 가 바로 꺼졌어 — 직접 확인: cd {shlex.quote(str(cwd))} && claude --channels {PLUGIN}")
```
(기동 직후 죽는 경우에도 알림 프로세스가 뜨지만, 기록이 저장되기 전이라 `notify_exit` 가 조용히 끝난다 — 아래 구현이 그렇게 동작한다.)

`hook_stop` 다음에:
```python
def notify_exit(ref: str, code: str) -> None:
    try:
        s = find_session(ref)
    except SessionError:
        return                                   # 기동 실패(기록 전) · 이미 rm 된 세션
    if not s.get("channelId"):
        return
    cfg = load_config()
    Discord(read_token(cfg)).send_message(
        str(s["channelId"]), f"⚠ 세션이 꺼졌어 (종료 코드 {code}) — 다시 켜기: `marina session start {ref}`")
```

`cmd_new` 와 `cmd_start` 의 `tmux_start(...)` 호출 끝에 각각 `notify_ref=f"{project}/{task}"`, `notify_ref=label` 을 넘긴다:
```python
        tmux_start(plan["tmux"], wt, claude_argv(project, task), session_env(sdir), notify_ref=f"{project}/{task}")
```
```python
            tmux_start(name, root, claude_argv(str(s["project"]), str(s["task"]), resume=True),
                       session_env(Path(str(s.get("stateDir") or ""))), notify_ref=label)
```

`main` 하위 명령 정의에:
```python
    p = sub.add_parser("notify-exit")
    p.add_argument("ref")
    p.add_argument("code")
```
`hook-stop` 처리 블록 바로 다음(try 앞)에:
```python
    if a.cmd == "notify-exit":
        try:   # 알림 실패가 아무것도 막지 않게
            notify_exit(a.ref, a.code)
        except Exception:
            pass
        return 0
```

- [ ] **Step 4: 통과 확인 (전체 세션 테스트 + 영향 범위)**

Run: `for t in names discord tmux new lifecycle worktree-hooks status-hook exit-notice; do bash plugin/tests/test-session-$t.sh || break; done && bash plugin/tests/test-py39-compat.sh && bash plugin/tests/run-affected.sh`
Expected: 세션 테스트 9개 `PASS`, `PASS test-py39-compat`, run-affected 가 고른 테스트 전부 PASS

- [ ] **Step 5: 변경 확인 (커밋은 형 요청 시에만)**

Run: `git status --short` — 새 `plugin/tests/test-session-exit-notice.sh`, 수정 `marina_session.py`.
커밋 요청 시 메시지: `feat(session): claude 가 끝나면 채널에 알림`

---

### Task 7 → (실행 순서상 마지막) 실제 확인 (ovation, 수동 1회)

자동 테스트가 못 보는 것 — 진짜 Discord · 진짜 claude · Remote Control — 을 형과 함께 한 번 확인한다. 코드 변경 없음.

**Files:**
- Create: `~/.marina/discord.json` (레포 밖, 비밀값 없음)

- [ ] **Step 1: 실제 설정 파일 작성**

```bash
cat > ~/.marina/discord.json <<'JSON'
{
  "guildId": "1555094662912679966",
  "tokenFile": "~/.claude/channels/discord-token.env",
  "projects": {
    "ovation": { "categoryId": null, "allow": ["770258011330576384"] }
  }
}
JSON
```

- [ ] **Step 2: 세션 열기** — 실행 환경은 생략해 빨리 본다

Run: `marina session new ovation probe/discord-e2e --no-start`
Expected: `✓ 세션`, Discord 링크, Remote Control 이름 `ovation/probe/discord-e2e`. Discord 에 `OVATION` 카테고리와 `#probe-discord-e2e` 채널이 생김.

- [ ] **Step 3: 형 확인 (Discord · claude.ai)**

형이 `#probe-discord-e2e` 에 `README 첫 줄만 알려줘` → 👀 반응 + 답장, 답이 끝나면 👀 가 ✅ 로 바뀜. 멤버 목록에서 봇이 온라인. claude.ai/code 목록에 `ovation/probe/discord-e2e` 가 보이고 진행이 실시간으로 보임.
`marina session ls` → `ovation/probe/discord-e2e	켜짐	채널 있음	...`

- [ ] **Step 4: 정리 확인**

Run: `marina session rm ovation/probe/discord-e2e` 후 대시보드나 `git -C ~/IdeaProjects/sumin/ovation worktree remove .claude/worktrees/probe-discord-e2e && git -C ~/IdeaProjects/sumin/ovation branch -D probe/discord-e2e`
Expected: 채널 사라짐, `tmux ls` 에 세션 없음, `~/.claude/channels/discord-ovation-probe-discord-e2e` 없음. (`OVATION` 카테고리는 남는다 — 다음 세션이 재사용.)

- [ ] **Step 5: 죽음 알림 확인**

`marina session new ovation probe/discord-e2e2 --no-start` 후 `marina session attach ovation/probe/discord-e2e2` 에서 `/exit` → 채널에 "⚠ 세션이 꺼졌어" 알림. 확인 뒤 Step 4 와 같은 방법으로 정리.
