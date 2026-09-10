# 역할 방과 묶음 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 구현 방이 커밋하면 읽기 전용 역할 방(첫 버전 reviewer)이 떠서 리뷰하고, 결과를 네이티브 세션간 메시지로 돌려보내 구현 방이 반영하는 묶음을 마리나가 지휘한다.

**Architecture:** 역할 정의 파일 → CLI 하네스(`marina_roles.py`). 묶음 장부·순수 상태기계·결과 파서(`marina_chains.py`). 데몬 `_on_events` 에서 턴 끝 전이를 보고 트리거, 폰 API·루프백 API·`marina chain` CLI 가 같은 `chain_trigger` 로 모인다. 폰 화면은 공유 렌더러에 흐름 항목, 모바일 호스트에 고정 줄·배지.

**Tech Stack:** Python 3.9 stdlib(데몬), 순수 JS(공유 렌더러·모바일 페이지), bash 테스트 + node vm.

**Spec:** `docs/superpowers/specs/2026-09-10-role-rooms-chain-design.md`

## Global Constraints

- Python 3.9 호환(`from __future__ import annotations` 로 `X | None` 사용 가능, 새 문법 금지)
- 새 의존성 금지(stdlib 만)
- 테스트는 반드시 `. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"` 로 실 `~/.marina` 격리
- 셸은 zsh 에서도 돈다 — 테스트 스크립트 안 반복문은 명시적 목록으로(unquoted 변수 분할에 기대지 않는다)
- 역할 방은 항상 `--permission-mode plan`, 편집 도구(`Edit`·`Write`·`NotebookEdit`·`MultiEdit`) 제외, `ToolSearch`·`SendMessage` 추가
- 첫 프롬프트는 argv 에서 `claude` 바로 뒤
- 답장 주소는 `uds:<messagingSocketPath>` (이름 쓰지 않음)
- 사용자에게 보이는 글자는 전부 이스케이프
- **배포 금지:** push·플러그인 캐시 설치·데몬 재시작 하지 않는다. 커밋은 로컬만
- 커밋 메시지 끝 두 줄: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b`
- 테스트 실행: 단일 `bash plugin/tests/<name>.sh`, 단계 끝 `bash plugin/tests/run-affected.sh HEAD`, 마지막 `bash plugin/tests/run-affected.sh origin/main --deep`

## File Structure

| 파일 | 책임 |
|---|---|
| Modify `plugin/scripts/marina_term.py` | `_claude_cli`·`_codex_cli` 프롬프트 위치(P0), `term_open(agent_extra_args=…)`(P1) |
| Create `plugin/scripts/marina_roles.py` | 역할 정의 찾기·파싱·역할 방 argv·연결 계약 문단 |
| Create `plugin/roles/reviewer.md` | 기본 리뷰어 정의 |
| Create `plugin/scripts/marina_chains.py` | 장부 파일 IO·순수 상태기계·결과 파서·저장소 HEAD·턴 끝 판정·흐름 항목 병합 |
| Create `plugin/scripts/marina_chain_runtime.py` | 부수효과 층: 역할 방 띄우기/입력/끄기, `chain_trigger`, `on_events` 작업 스레드 |
| Create `plugin/scripts/marina_chain_cli.py` | `marina chain request\|unlimited\|stop` — 호출자 확인 후 루프백 API |
| Modify `plugin/scripts/marina_registry.py` | 프로젝트 dict 에 `roles` |
| Modify `plugin/scripts/marina_handler.py` | `_on_events` 연결, `/api/chain`, `/mobile/api/chain/*`, transcript 병합 |
| Modify `plugin/scripts/marina_auth_http.py` | `PUBLIC_PATHS` 에 `/api/chain` |
| Modify `plugin/scripts/marina-entrypoint.sh` | `chain)` 분기 |
| Modify `plugin/scripts/marina-session-start-hook.sh` | 역할 켠 프로젝트에 지시문 한 줄 |
| Modify `plugin/scripts/marina_mobile.py` | 세션 `chain` 필드, 역할 방 `roleOf`, 고정 줄·배지·딸린 줄·메뉴 |
| Modify `plugin/scripts/marina-web/chat-render.js` | `kind:"chain"` 흐름 줄·요약 카드 |

---

## P0 — 첫 프롬프트를 argv 맨 앞으로

### Task 1: `_claude_cli`·`_codex_cli` 프롬프트 위치

**Files:**
- Modify: `plugin/scripts/marina_term.py` (`_claude_cli` ~371, `_codex_cli` ~389)
- Test: `plugin/tests/test-agent-cli-prompt-first.sh` (Create)
- Modify: `plugin/tests/test-term.sh:20` (옛 argv 순서를 박아둔 정확-모양 단정을 새 순서로 — 실행 중 발견)

**Interfaces:**
- Produces: `_agent_cli(source, sid, prompt, model, effort, profile, lean) -> list[str]` — claude 는 `["claude", prompt, *flags]`(prompt 있을 때). 시그니처 불변

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-agent-cli-prompt-first.sh <<'SH'
#!/usr/bin/env bash
# 첫 프롬프트는 argv 에서 `claude` 바로 뒤 — 가변 인자 플래그(--tools/--allowedTools)가 뒤 값을 삼킨다.
# 실측 2026-09-10: lean + 프롬프트(모델·effort 없음) = ['claude','--strict-mcp-config','--tools','Read','Write','첫 프롬프트'].
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import marina_term as T
p = "첫 프롬프트"
for profile, lean in (("", True), ("chat", False), ("chat", True), ("", False)):
    argv = T._agent_cli("claude", "", p, "", "", profile, lean)
    assert argv[:2] == ["claude", p], f"프롬프트가 맨 앞이 아니다(profile={profile!r} lean={lean}): {argv}"
    assert argv.count(p) == 1, argv
# resume 도 순서와 무관하게 동작해야 한다
argv = T._agent_cli("claude", "sid0001", p, "claude-opus-5", "high", "", True)
assert argv[:2] == ["claude", p] and argv[argv.index("--resume") + 1] == "sid0001", argv
# 프롬프트 없으면 그대로
assert T._agent_cli("claude", "", "", "", "", "", True)[0] == "claude"
assert "첫 프롬프트" not in T._agent_cli("claude", "", "", "", "", "", True)
print("PASS: 첫 프롬프트는 claude 바로 뒤")
PY
SH
chmod +x plugin/tests/test-agent-cli-prompt-first.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-agent-cli-prompt-first.sh`
Expected: FAIL `AssertionError: 프롬프트가 맨 앞이 아니다(profile='' lean=True)`

- [ ] **Step 3: Write minimal implementation**

`_claude_cli` 에서 `cmd = ["claude"]` 를 다음으로 바꾸고, 함수 끝의 `if prompt: cmd.append(prompt)` 두 줄을 지운다:

```python
    # 첫 프롬프트는 **claude 바로 뒤**. --tools/--allowedTools 는 뒤따르는 값을 모두 삼키는 가변 인자라,
    # 끝에 붙이면 lean(모델·effort 없음)에서 프롬프트가 도구 이름으로 먹힌다(실측 argv 2026-09-10).
    cmd = ["claude", prompt] if prompt else ["claude"]
```

`_codex_cli` 는 `codex` 가 가변 인자 플래그를 쓰지 않으므로 바꾸지 않는다.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-agent-cli-prompt-first.sh && bash plugin/tests/test-term.sh && bash plugin/tests/test-harness-view.sh && bash plugin/tests/test-mobile-fresh-term-send.sh`
Expected: 모두 PASS. `test-harness-view.sh` 의 `_harness_flags` 는 argv[1] 부터 `-` 로 시작하지 않는 낱말을 건너뛰므로 영향 없음 — FAIL 이면 `_harness_flags` 의 시작 인덱스를 프롬프트 건너뛰기 전제로 확인한다(저장본 launch 는 프롬프트가 없어 원래 영향 없음).

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_term.py plugin/tests/test-agent-cli-prompt-first.sh
git -c commit.gpgsign=false commit -m "fix(term): 첫 프롬프트를 argv 맨 앞으로 — 가변 인자 플래그에 삼켜지던 잠복 버그" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

---

## P1 — 역할 정의와 역할 방 하네스

### Task 2: `marina_roles.py` + 기본 `reviewer.md`

**Files:**
- Create: `plugin/scripts/marina_roles.py`
- Create: `plugin/roles/reviewer.md`
- Test: `plugin/tests/test-roles.sh` (Create)

**Interfaces:**
- Produces:
  - `parse_definition(text: str) -> dict` → `{"name","description","model","tools": list[str],"body"}`
  - `split_tools(raw: str) -> list[str]` (괄호 안 쉼표 보존)
  - `find_role(root: Path, role: str, home: Path | None = None) -> tuple[Path, str] | None` → `(경로, "project"|"user"|"marina")`
  - `load_role(root: Path, role: str, home: Path | None = None) -> dict | None` → parse 결과 + `"path"`, `"origin"`
  - `role_tools(defn: dict) -> tuple[list[str], list[str]]` → `(허용, 뺀 편집도구)`
  - `role_cli(defn: dict, prompt: str) -> list[str]` (prompt `""` 이면 저장용 launch)
  - `contract_prompt(*, role: str, repos: dict[str, tuple[str, str]], reply_socket: str, round_no: int, unlimited: bool, previous: str = "") -> str`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-roles.sh <<'SH'
#!/usr/bin/env bash
# 역할 = 에이전트 정의 파일 한 장. 찾는 순서·하네스 변환·연결 계약(스펙 4절).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import tempfile
from pathlib import Path
import marina_roles as R

md = """---
name: code-reviewer
description: "Senior reviewer. Read-only."
tools: Read, Grep, Glob, Bash(git diff:*), Bash(git log:*), Edit, Write
model: sonnet
---

You are a senior reviewer.
"""
d = R.parse_definition(md)
assert d["name"] == "code-reviewer" and d["model"] == "sonnet", d
assert d["tools"] == ["Read", "Grep", "Glob", "Bash(git diff:*)", "Bash(git log:*)", "Edit", "Write"], d["tools"]
assert d["body"] == "You are a senior reviewer.", repr(d["body"])
assert R.split_tools("Bash(a, b), Read") == ["Bash(a, b)", "Read"]          # 괄호 안 쉼표 보존
assert R.parse_definition("no frontmatter")["body"] == "no frontmatter"

allowed, dropped = R.role_tools(d)
assert "Edit" not in allowed and "Write" not in allowed and set(dropped) == {"Edit", "Write"}, (allowed, dropped)
assert allowed[-2:] == ["ToolSearch", "SendMessage"], allowed                  # 실측: SendMessage 는 ToolSearch 로 불러온다
assert R.role_tools({"tools": ["Read", "SendMessage"]})[0].count("SendMessage") == 1

argv = R.role_cli(d, "첫 프롬프트")
assert argv[:2] == ["claude", "첫 프롬프트"], argv                            # 가변 인자 앞
assert argv[argv.index("--permission-mode") + 1] == "plan"
assert argv[argv.index("--model") + 1] == "sonnet"
assert argv[argv.index("--append-system-prompt") + 1] == "You are a senior reviewer."
i = argv.index("--allowedTools"); j = argv.index("--append-system-prompt")
assert argv[i + 1:j] == allowed, argv
launch = R.role_cli(d, "")
assert "첫 프롬프트" not in launch and launch[1] == "--model", launch
assert "--model" not in R.role_cli({**d, "model": ""}, "p")

# 찾는 순서: project > user > marina
tmp = Path(tempfile.mkdtemp()); root = tmp / "wt"; home = tmp / "home"
assert R.find_role(root, "reviewer", home=home)[1] == "marina"                 # 기본 역할 파일이 있다
(home / ".claude/agents").mkdir(parents=True); (home / ".claude/agents/reviewer.md").write_text(md)
assert R.find_role(root, "reviewer", home=home)[1] == "user"
(root / ".claude/agents").mkdir(parents=True); (root / ".claude/agents/reviewer.md").write_text(md)
assert R.find_role(root, "reviewer", home=home)[1] == "project"
for bad in ("../x", "Reviewer", "", "a/b"):
    assert R.find_role(root, bad, home=home) is None, bad                       # 경로 탈출·이상한 이름 거부
loaded = R.load_role(root, "reviewer", home=home)
assert loaded["origin"] == "project" and loaded["path"].endswith("reviewer.md")

base = R.load_role(tmp / "none", "reviewer", home=tmp / "nohome")
assert base["origin"] == "marina" and base["model"] == "claude-sonnet-5" and base["body"], base

c = R.contract_prompt(role="reviewer", repos={"marina": ("cb675c6", "e04dc5f")},
                      reply_socket="uds:/tmp/cc-socks/3741.sock", round_no=1, unlimited=False)
for need in ('"uds:/tmp/cc-socks/3741.sock"', "cb675c6..e04dc5f", "새 지적 없음", "SendMessage", "고치지"):   # 따옴표째 정확한 소켓 주소
    assert need in c, (need, c)
assert "[보류]" not in c                                                         # 무제한일 때만
c2 = R.contract_prompt(role="reviewer", repos={"a": ("1", "2"), "b/c": ("3", "4")}, reply_socket="uds:/x",
                       round_no=2, unlimited=True, previous="지적 요약")
assert "[보류]" in c2 and "b/c" in c2 and "지적 요약" in c2 and "2바퀴" in c2, c2
print("PASS: 역할 정의·하네스·연결 계약")
PY
SH
chmod +x plugin/tests/test-roles.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-roles.sh`
Expected: FAIL `ModuleNotFoundError: No module named 'marina_roles'`

- [ ] **Step 3: Write `plugin/roles/reviewer.md`**

```markdown
---
name: reviewer
description: "마리나 기본 리뷰어. 구현 방의 커밋을 읽고 지적만 돌려준다. 코드를 고치지 않는다."
tools: Read, Grep, Glob, Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git status:*)
model: claude-sonnet-5
---

너는 코드 리뷰어다. 구현 방이 방금 만든 변경만 읽고, 고칠 점을 구현 방에 돌려준다.

보는 것(중요한 순서):
1. 버그 — 잘못된 조건, 경계값, 빠진 에러 처리, 경쟁 상태
2. 보안 — 입력 검증, 인증 누락, 시크릿, 이스케이프
3. 테스트 — 새 동작에 테스트가 있나, 실패하는 경우를 다루나
4. 이 레포의 규칙 — CLAUDE.md·AGENTS.md 가 있으면 먼저 읽고 어긋난 곳

쓰는 법:
- 지적마다 머리 줄을 `### [CRITICAL] 제목` · `### [WARNING] 제목` · `### [SUGGESTION] 제목` 중 하나로
- 그 아래 한두 줄: `파일:줄` 과 무엇이 왜 문제인지, 어떻게 고치면 되는지
- 취향·스타일만의 지적은 SUGGESTION 으로 두고 3개를 넘기지 않는다
- 확신이 없으면 지적하지 말고 넘어간다
```

- [ ] **Step 4: Write `plugin/scripts/marina_roles.py`**

```python
"""역할 = 에이전트 정의 파일 한 장. 찾기·파싱·역할 방 하네스(argv)·연결 계약.

스펙: docs/superpowers/specs/2026-09-10-role-rooms-chain-design.md 4절.
새 형식을 만들지 않는다 — Claude 서브에이전트 파일(name·description·tools·model + 본문)을 그대로 쓴다.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

# 첫 버전 역할은 읽기 전용이다. 정의에 편집 도구가 있어도 뺀다(plan 모드가 막지만 두 겹으로).
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
# SendMessage 는 지연 로드 도구라 ToolSearch 로 불러와야 쓴다(실측 2026-09-10).
ALWAYS_TOOLS = ("ToolSearch", "SendMessage")
_ROLE_NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,40}")
_META_RE = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*$")


def plugin_dir() -> Path:
    """플러그인 루트(scripts/ 의 부모)."""
    return Path(__file__).resolve().parent.parent


def split_tools(raw: str) -> list[str]:
    """`Read, Grep, Bash(git diff:*)` → 낱말 목록. 괄호 안 쉼표는 쪼개지 않는다."""
    out: list[str] = []
    cur: list[str] = []
    depth = 0
    for ch in raw or "":
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            word = "".join(cur).strip()
            if word:
                out.append(word)
            cur = []
            continue
        cur.append(ch)
    word = "".join(cur).strip()
    if word:
        out.append(word)
    return out


def parse_definition(text: str) -> dict[str, Any]:
    """프론트매터(한 줄짜리 `키: 값`만) + 본문. 닫는 `---` 가 없으면 전체를 본문으로 본다."""
    meta: dict[str, str] = {}
    body = text or ""
    lines = body.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                body = "\n".join(lines[i + 1:])
                break
            match = _META_RE.match(lines[i])
            if match:
                meta[match.group(1)] = match.group(2).strip().strip("'\"")
    return {
        "name": meta.get("name", ""),
        "description": meta.get("description", ""),
        "model": meta.get("model", ""),
        "tools": split_tools(meta.get("tools", "")),
        "body": body.strip(),
    }


def find_role(root: Path, role: str, home: Path | None = None) -> tuple[Path, str] | None:
    """찾는 순서: 프로젝트 → 사용자 → 마리나 기본. 이름이 규칙에 안 맞으면 None(경로 탈출 차단)."""
    if not _ROLE_NAME_RE.fullmatch(role or ""):
        return None
    home = home if home is not None else Path.home()
    candidates = (
        (Path(root) / ".claude" / "agents" / f"{role}.md", "project"),
        (home / ".claude" / "agents" / f"{role}.md", "user"),
        (plugin_dir() / "roles" / f"{role}.md", "marina"),
    )
    for path, origin in candidates:
        if path.is_file():
            return path, origin
    return None


def load_role(root: Path, role: str, home: Path | None = None) -> dict[str, Any] | None:
    found = find_role(root, role, home)
    if found is None:
        return None
    path, origin = found
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    return {**parse_definition(text), "path": str(path), "origin": origin}


def role_tools(defn: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(허용 도구, 뺀 편집 도구). 편집 도구는 `Edit` 처럼 이름만, `Edit(...)` 처럼 괄호가 붙어도 뺀다."""
    allowed: list[str] = []
    dropped: list[str] = []
    for tool in defn.get("tools") or []:
        bare = tool.split("(", 1)[0].strip()
        if bare in EDIT_TOOLS:
            dropped.append(tool)
        elif tool not in allowed:
            allowed.append(tool)
    for tool in ALWAYS_TOOLS:
        if tool in allowed:
            allowed.remove(tool)
        allowed.append(tool)
    return allowed, dropped


def role_cli(defn: dict[str, Any], prompt: str) -> list[str]:
    """역할 방 argv. **프롬프트는 claude 바로 뒤** — --allowedTools 가 뒤따르는 값을 삼킨다.
    prompt 가 빈 문자열이면 저장용 launch(프롬프트 없는 argv)를 만든다."""
    cmd = ["claude", prompt] if prompt else ["claude"]
    if defn.get("model"):
        cmd += ["--model", str(defn["model"])]
    cmd += ["--permission-mode", "plan"]
    allowed, _ = role_tools(defn)
    cmd += ["--allowedTools", *allowed]
    if defn.get("body"):
        cmd += ["--append-system-prompt", str(defn["body"])]
    return cmd


def contract_prompt(*, role: str, repos: dict[str, tuple[str, str]], reply_socket: str,
                    round_no: int, unlimited: bool, previous: str = "") -> str:
    """마리나가 역할 방 요청마다 붙이는 연결 계약(스펙 4.3). 정의 본문과 별개로 역할이 무엇이든 같다."""
    범위 = "\n".join(f"- `{name}`: `git diff {base}..{head}` + 커밋 안 한 변경(staged·unstaged)"
                   for name, (base, head) in repos.items())
    lines = [
        f"[마리나 · {role} · {round_no}바퀴]",
        "검토 범위(저장소 경로는 이 워크트리 기준):",
        범위,
        "",
        "규칙:",
        f'- 결과는 **한 번의** SendMessage 로 보낸다. to 는 정확히 "{reply_socket}" (이름 말고 이 주소).',
        "- 지적할 게 없으면 메시지 마지막 줄을 정확히 `새 지적 없음` 으로 쓴다.",
        "- 파일은 절대 고치지 않는다. 읽고 지적만 한다.",
    ]
    if unlimited:
        lines.append("- 지난 바퀴에 이미 한 지적과 같은 것은 줄 머리를 `[보류]` 로 시작한다(다시 설명하지 않는다).")
    if previous:
        lines += ["", "지난 바퀴 요약:", previous]
    return "\n".join(lines)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugin/tests/test-roles.sh`
Expected: `PASS: 역할 정의·하네스·연결 계약`

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_roles.py plugin/roles/reviewer.md plugin/tests/test-roles.sh
git -c commit.gpgsign=false commit -m "feat(roles): 역할 = 에이전트 정의 파일 — 찾기·하네스 argv·연결 계약 + 기본 reviewer" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

### Task 3: `term_open` 역할 방 인자

**Files:**
- Modify: `plugin/scripts/marina_term.py` (`term_open` ~441, `_persist_term` ~112, `_reconstruct_registry`)
- Test: `plugin/tests/test-term-role-room.sh` (Create)

**Interfaces:**
- Consumes: `marina_roles.role_cli(defn, prompt)` (Task 2)
- Produces: `term_open(root, cols=80, rows=24, agent_source="", agent_sid="", agent_prompt="", agent_model="", agent_effort="", agent_role="", agent_role_argv=None, agent_role_launch=None) -> {"tid": str, ...}`. `agent_role_argv` 가 있으면 그 argv 로 띄우고 프로젝트 profile/lean 을 **입히지 않는다**(역할 방은 자기 하네스만). term 메타·`term_list()` 의 `agent` 에 `"role"` 이 실린다

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-term-role-room.sh <<'SH'
#!/usr/bin/env bash
# 역할 방은 자기 argv 로 뜨고, 저장본(launch)엔 프롬프트가 없고, role 이 남는다(스펙 4.2·5.5).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, os, tempfile
from pathlib import Path
import marina_term as T
import marina_roles as R

home = Path(os.environ["MARINA_HOME"])
fake = home / "fake-shell"; fake.write_text("#!/bin/sh\nexec sleep 5\n"); fake.chmod(0o755)
os.environ["SHELL"] = str(fake)
root = Path(tempfile.mkdtemp())
defn = R.load_role(root, "reviewer", home=Path(tempfile.mkdtemp()))
비밀 = "역할 방 첫 프롬프트 — 저장본에 남으면 안 된다"
res = T.term_open(root, 80, 24, agent_source="claude", agent_sid="", agent_prompt=비밀,
                  agent_role="reviewer", agent_role_argv=R.role_cli(defn, 비밀),
                  agent_role_launch=R.role_cli(defn, ""))
tid = res["tid"]
try:
    meta = json.loads((T._terms_dir() / f"{tid}.json").read_text())
finally:
    T.term_kill(tid)
blob = json.dumps(meta, ensure_ascii=False)
assert 비밀 not in blob, f"저장본에 프롬프트가 남았다: {blob}"
assert meta["role"] == "reviewer", meta
assert meta["launch"] == R.role_cli(defn, ""), meta["launch"]
assert "--permission-mode" in meta["launch"] and meta["profile"] == "" and meta["lean"] is False, meta
assert meta["key"] == "", "역할 방은 재사용 키가 없다"
# 재시작 복원에도 role 이 남는다
agent = {"source": "claude", "sid": "s", "role": "reviewer"}
T._by_tid.clear(); T._by_key.clear(); T._reconstructed = False
(T._terms_dir()).mkdir(parents=True, exist_ok=True)
pid = os.getpid()
(T._terms_dir() / "t-role.json").write_text(json.dumps({"tid": "t-role", "cwd": str(root), "pid": pid,
    "pid_start": T._pid_start(pid), "source": "claude", "sid": "s", "key": "", "role": "reviewer", "created": 1.0}))
T._reconstruct_registry()
assert T._by_tid["t-role"].agent.get("role") == "reviewer", T._by_tid["t-role"].agent
print("PASS: 역할 방 argv·저장본·role 복원")
PY
SH
chmod +x plugin/tests/test-term-role-room.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-term-role-room.sh`
Expected: FAIL `TypeError: term_open() got an unexpected keyword argument 'agent_role'`

- [ ] **Step 3: Implement**

`term_open` 시그니처 끝에 인자 셋을 더한다:
```python
def term_open(root: Path, cols: int = 80, rows: int = 24,
              agent_source: str = "", agent_sid: str = "",
              agent_prompt: str = "", agent_model: str = "",
              agent_effort: str = "", agent_role: str = "",
              agent_role_argv: list[str] | None = None,
              agent_role_launch: list[str] | None = None) -> dict[str, Any]:
```
`if agent_source:` 블록 안에서 `프로필, 가볍게 = _project_profile(root), _project_lean(root)` 부터 `launch = _agent_cli(...)` 두 번째 호출까지를 다음으로 바꾼다:
```python
        if agent_role_argv:
            # **역할 방은 자기 하네스만 입는다.** 프로젝트 profile(chat 의 --append-system-prompt 등)을 겹치면
            # 같은 플래그가 두 번 들어가고 역할 정의가 흐려진다. 저장본은 호출자가 빈 프롬프트로 다시 만든 것.
            프로필, 가볍게 = "", False
            cmd = list(agent_role_argv)
            launch = list(agent_role_launch or [])
        else:
            프로필, 가볍게 = _project_profile(root), _project_lean(root)
            cmd = _agent_cli(agent_source, agent_sid, agent_prompt, agent_model, agent_effort,
                             프로필, 가볍게)
            launch = _agent_cli(agent_source, agent_sid, "", agent_model, agent_effort,
                                프로필, 가볍게)
```
그 아래 `key = ...` 줄을 `key = "" if (agent_role_argv or agent_prompt or not agent_sid) else f"{cwd}::agent:{agent_source}:{agent_sid}"` 로, `agent = {...}` 다음 줄에 추가:
```python
        if agent_role:
            agent["role"] = agent_role
```
`_persist_term` 의 meta dict 에 `"lean": bool(agent.get("lean")),` 다음 줄로 `"role": str(agent.get("role") or ""),` 를 넣는다.
`_reconstruct_registry` 의 `if meta.get("lean"): agent["lean"] = True` 다음에:
```python
                if meta.get("role"):
                    agent["role"] = str(meta.get("role"))
```

- [ ] **Step 4: Run tests**

Run: `bash plugin/tests/test-term-role-room.sh && bash plugin/tests/test-term.sh && bash plugin/tests/test-harness-view.sh`
Expected: 모두 PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_term.py plugin/tests/test-term-role-room.sh
git -c commit.gpgsign=false commit -m "feat(term): 역할 방을 자기 하네스로 띄운다 — agent_role_argv·launch·role 저장" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

---

## P2 — 묶음 장부와 상태기계

### Task 4: `marina_chains.py` — 장부 파일과 순수 상태기계

**Files:**
- Create: `plugin/scripts/marina_chains.py`
- Test: `plugin/tests/test-chains-state.sh` (Create)

**Interfaces:**
- Produces:
  - `CHAINS_DIR: Path` (`MARINA_HOME/"chains"`), `WAIT_TIMEOUT_S = 1800.0`, `TERMINAL = {"done", "stopped"}`
  - `new_chain(*, role: str, implementer: dict, base: dict[str,str], head: dict[str,str], max_rounds: int, unlimited: bool, now: float, anchor: int) -> dict`
  - `head_advanced(prev: dict[str,str], cur: dict[str,str]) -> bool`
  - `next_state(chain: dict, event: dict, now: float) -> tuple[dict, list[dict]]` — 순수. 이벤트 `type`: `result`(noneLeft, findings, held, anchor) · `implementer_turn_end`(head, anchor) · `tick` · `stop`(anchor) · `unlimited`(on) · `no_result`(anchor) · `implementer_gone`(anchor). 액션 `do`: `kill_role` · `request_round`(round, base, head) · `nudge_role`
  - `save_chain(chain: dict) -> None`, `load_chain(chain_id: str) -> dict | None`, `list_chains() -> list[dict]`, `open_chain_for(source: str, sid: str, role: str) -> dict | None`, `last_chain_for(source: str, sid: str, role: str) -> dict | None`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chains-state.sh <<'SH'
#!/usr/bin/env bash
# 묶음 상태기계(스펙 5.2) — 순수 함수라 파일·프로세스·시계 없이 모든 전이를 본다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import copy
import marina_chains as C

IMP = {"root": "/wt", "source": "claude", "sid": "s-impl", "socket": "uds:/tmp/cc-socks/1.sock"}
def fresh(max_rounds=2, unlimited=False):
    return C.new_chain(role="reviewer", implementer=IMP, base={"marina": "a"}, head={"marina": "b"},
                       max_rounds=max_rounds, unlimited=unlimited, now=100.0, anchor=10)
def do(actions): return [a["do"] for a in actions]

c = fresh()
assert c["state"] == "reviewing" and c["round"] == 1 and c["reviewedHead"] == {"marina": "b"}, c
assert c["rounds"][0]["sentAnchor"] == 10 and c["id"].startswith("c-"), c

# 결과(지적 없음) → done, 역할 방 끔
d, acts = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": True, "findings": 0, "held": [], "anchor": 20}, 110.0)
assert d["state"] == "done" and d["endedReason"] == "clean" and do(acts) == ["kill_role"], (d, acts)
assert d["endedAnchor"] == 20 and d["rounds"][0]["noneLeft"] is True

# 결과(지적 있음) → applying
a, acts = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": False, "findings": 2, "held": [], "anchor": 20}, 110.0)
assert a["state"] == "applying" and acts == [] and a["rounds"][0]["findings"] == 2, a

# applying + 턴 끝 + HEAD 앞섬 → 2바퀴 요청
r2, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 30}, 120.0)
assert r2["state"] == "reviewing" and r2["round"] == 2, r2
assert acts == [{"do": "request_round", "round": 2, "base": {"marina": "b"}, "head": {"marina": "c"}}], acts
assert r2["reviewedHead"] == {"marina": "c"} and r2["rounds"][1]["sentAnchor"] == 30

# 2바퀴 결과(지적) 후 또 커밋 → 상한 도달 done
a2, _ = C.next_state(r2, {"type": "result", "noneLeft": False, "findings": 1, "held": [], "anchor": 40}, 130.0)
m, acts = C.next_state(a2, {"type": "implementer_turn_end", "head": {"marina": "d"}, "anchor": 50}, 140.0)
assert m["state"] == "done" and m["endedReason"] == "max-rounds" and do(acts) == ["kill_role"], (m, acts)

# 무제한이면 상한을 넘어 계속
u = copy.deepcopy(a2); u["unlimited"] = True
u3, acts = C.next_state(u, {"type": "implementer_turn_end", "head": {"marina": "d"}, "anchor": 50}, 140.0)
assert u3["state"] == "reviewing" and u3["round"] == 3 and do(acts) == ["request_round"], (u3, acts)

# 보류 누적(중복 제거)
h, _ = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": False, "findings": 1, "held": ["[보류] X", "[보류] X"], "anchor": 20}, 110.0)
h2, _ = C.next_state(C.next_state(h, {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 30}, 120.0)[0],
                     {"type": "result", "noneLeft": False, "findings": 1, "held": ["[보류] X", "[보류] Y"], "anchor": 40}, 130.0)
assert h2["held"] == ["[보류] X", "[보류] Y"], h2["held"]

# applying + 턴 끝 + HEAD 그대로 → waiting, 30분 뒤 tick → done
w, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_turn_end", "head": {"marina": "b"}, "anchor": 30}, 120.0)
assert w["state"] == "waiting" and w["waitingSince"] == 120.0 and acts == [], w
still, acts = C.next_state(copy.deepcopy(w), {"type": "tick"}, 120.0 + C.WAIT_TIMEOUT_S - 1)
assert still["state"] == "waiting" and acts == []
t, acts = C.next_state(copy.deepcopy(w), {"type": "tick"}, 120.0 + C.WAIT_TIMEOUT_S)
assert t["state"] == "done" and t["endedReason"] == "wait-timeout" and do(acts) == ["kill_role"], t
# waiting 중 커밋 → 다음 바퀴
wr, acts = C.next_state(copy.deepcopy(w), {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 60}, 130.0)
assert wr["state"] == "reviewing" and wr["round"] == 2 and do(acts) == ["request_round"]

# reviewing 중 커밋 → 새 요청 없이 다음 바퀴 범위에 합친다
p, acts = C.next_state(copy.deepcopy(c), {"type": "implementer_turn_end", "head": {"marina": "z"}, "anchor": 15}, 105.0)
assert p["state"] == "reviewing" and acts == [] and p["pendingHead"] == {"marina": "z"}, p
pa, _ = C.next_state(p, {"type": "result", "noneLeft": False, "findings": 1, "held": [], "anchor": 20}, 110.0)
pr, acts = C.next_state(pa, {"type": "implementer_turn_end", "head": {"marina": "z"}, "anchor": 30}, 120.0)
assert do(acts) == ["request_round"] and acts[0]["head"] == {"marina": "z"} and "pendingHead" not in pr, (pr, acts)

# 결과 없음: 한 번 찌르고, 두 번째면 끝
n1, acts = C.next_state(copy.deepcopy(c), {"type": "no_result", "anchor": 20}, 110.0)
assert n1["state"] == "reviewing" and n1["nudged"] is True and do(acts) == ["nudge_role"]
n2, acts = C.next_state(n1, {"type": "no_result", "anchor": 25}, 115.0)
assert n2["state"] == "done" and n2["endedReason"] == "no-result" and do(acts) == ["kill_role"]

# 멈추기·무제한 토글·구현 방 사라짐·끝난 묶음은 무시
s, acts = C.next_state(copy.deepcopy(a), {"type": "stop", "anchor": 31}, 121.0)
assert s["state"] == "stopped" and do(acts) == ["kill_role"] and s["endedAnchor"] == 31
on, acts = C.next_state(copy.deepcopy(c), {"type": "unlimited", "on": True}, 101.0)
assert on["unlimited"] is True and acts == []
g, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_gone", "anchor": 32}, 122.0)
assert g["endedReason"] == "implementer-gone" and do(acts) == ["kill_role"]
same, acts = C.next_state(copy.deepcopy(d), {"type": "stop", "anchor": 99}, 200.0)
assert same == d and acts == [], "끝난 묶음이 다시 움직였다"

assert C.head_advanced({"a": "1"}, {"a": "2"}) and not C.head_advanced({"a": "1"}, {"a": "1"})
assert C.head_advanced({"a": "1"}, {"a": "1", "b": "9"}) and not C.head_advanced({"a": "1"}, {"a": ""})

# 파일 IO
C.save_chain(c)
assert C.load_chain(c["id"]) == c and C.open_chain_for("claude", "s-impl", "reviewer")["id"] == c["id"]
C.save_chain(d)                                   # 같은 id 를 done 으로 덮는다
assert C.open_chain_for("claude", "s-impl", "reviewer") is None and C.last_chain_for("claude", "s-impl", "reviewer")["state"] == "done"
assert C.load_chain("../etc/passwd") is None
print("PASS: 묶음 상태기계·장부")
PY
SH
chmod +x plugin/tests/test-chains-state.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chains-state.sh`
Expected: FAIL `ModuleNotFoundError: No module named 'marina_chains'`

- [ ] **Step 3: Write `plugin/scripts/marina_chains.py` (장부·상태기계 부분)**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-chains-state.sh`
Expected: `PASS: 묶음 상태기계·장부`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_chains.py plugin/tests/test-chains-state.sh
git -c commit.gpgsign=false commit -m "feat(chains): 묶음 장부와 순수 상태기계 — 바퀴·무제한·보류·대기·멈추기" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

### Task 5: 결과 파서·저장소 HEAD·턴 끝 판정·흐름 항목 병합

**Files:**
- Modify: `plugin/scripts/marina_chains.py` (Task 4 파일 끝에 덧붙인다)
- Test: `plugin/tests/test-chains-parse.sh` (Create)

**Interfaces:**
- Consumes: `marina_sessions.compose_scoped_subrepos(root) -> list[str]`, `marina_sessions.project_label(root) -> str` (함수 안에서 import — 순환 방지)
- Produces:
  - `read_rows(path: Path, after_offset: int) -> list[tuple[int, dict]]`
  - `parse_role_result(rows: list[tuple[int, dict]], reply_socket: str) -> dict | None` → `{"text","noneLeft","findings","held"}`
  - `worktree_repos(root: Path) -> list[tuple[str, Path]]`, `repo_heads(root: Path) -> dict[str, str]`
  - `turn_ended(event: dict, last_status: dict[str, str]) -> bool`, `remember_status(event: dict, last_status: dict[str, str]) -> None`
  - `chain_items(chain: dict) -> list[dict]` (`kind:"chain"` 항목들, 각자 `anchor`)
  - `merge_chain_items(timeline: list[dict], chains: list[dict], is_latest_page: bool) -> list[dict]`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chains-parse.sh <<'SH'
#!/usr/bin/env bash
# 결과는 역할 방 **자기 트랜스크립트**의 SendMessage 입력에서 읽는다(스펙 5.3). 흐름 줄은 오프셋으로 끼운다(7.1).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, subprocess, tempfile
from pathlib import Path
import marina_chains as C

SOCK = "uds:/tmp/cc-socks/3741.sock"
def send(to, msg): return {"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "tool_use", "id": "t", "name": "SendMessage", "input": {"to": to, "message": msg}}]}}
body = "### [CRITICAL] 트랜잭션 밖\n`a.kt:41`\n### [WARNING] 경계값\n**[보류]** 공용 모듈로 빼자\n[보류] 이름 바꾸자"
rows = [(0, send("uds:/tmp/other.sock", "남에게")), (10, {"type": "user"}), (20, send(SOCK, "첫 초안")), (30, send(SOCK, body))]
r = C.parse_role_result(rows, SOCK)
assert r["findings"] == 2 and r["noneLeft"] is False, r
assert r["held"] == ["[보류] 공용 모듈로 빼자", "[보류] 이름 바꾸자"], r["held"]      # 마지막 메시지만 · 굵게 표시 정리
clean = C.parse_role_result([(0, send(SOCK, "앞 지적 반영 확인.\n\n새 지적 없음\n"))], SOCK)
assert clean["noneLeft"] is True and clean["findings"] == 0, clean
plain = C.parse_role_result([(0, send(SOCK, "문단 하나\n\n문단 둘"))], SOCK)
assert plain["findings"] == 2 and plain["noneLeft"] is False, plain                     # 머리 줄 없으면 문단 수
assert C.parse_role_result([(0, send("uds:/x", "남"))], SOCK) is None
assert C.parse_role_result([], SOCK) is None

p = Path(tempfile.mkdtemp()) / "t.jsonl"
lines = [json.dumps(send(SOCK, "old")), json.dumps(send(SOCK, "new"))]
p.write_text(lines[0] + "\n" + lines[1] + "\n")
cut = len(lines[0]) + 1
got = C.read_rows(p, cut)
assert [o for o, _ in got] == [cut] and C.parse_role_result(got, SOCK)["text"] == "new", got

# 턴 끝: 알림층 kind 가 아니라 status 전이
last = {}
work = {"session": "k", "kind": "status", "status": "working"}
C.remember_status(work, last)
assert C.turn_ended({"session": "k", "kind": "status", "status": "waiting"}, last) is True
assert C.turn_ended({"session": "k", "kind": "idle", "status": "idle"}, {}) is True
assert C.turn_ended({"session": "new", "kind": "status", "status": "waiting"}, last) is False   # 직전 모름
assert C.turn_ended({"session": "k", "kind": "message"}, last) is False

# 저장소 HEAD: 루트 + .git 있는 서브레포
root = Path(tempfile.mkdtemp())
subprocess.run(["git", "init", "-q", str(root)], check=True)
subprocess.run(["git", "-C", str(root), "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
heads = C.repo_heads(root)
assert list(heads.values())[0] == subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(), heads

# 흐름 항목 병합
chain = {"id": "c-20260910-183210-reviewer-916b67c1", "role": "reviewer", "round": 2, "maxRounds": 2, "unlimited": False,
         "state": "done", "held": ["[보류] X"], "endedReason": "clean", "endedAnchor": 250, "roleRoom": {"model": "claude-sonnet-5"},
         "rounds": [{"n": 1, "sentAnchor": 120, "findings": 2}, {"n": 2, "sentAnchor": 210, "findings": 0}]}
items = C.chain_items(chain)
assert [i["event"] for i in items] == ["request", "request", "end"] and items[-1]["applied"] == 1, items
tl = [{"id": "claude:message:100:0", "kind": "message"}, {"id": "claude:activity:toolu_1", "kind": "activity"},
      {"id": "claude:peer:200:a", "kind": "message"}, {"id": "claude:message:300:0", "kind": "message"}]
merged = C.merge_chain_items(tl, [chain], is_latest_page=True)
ids = [i["id"] for i in merged]
assert ids == ["claude:message:100:0", "claude:activity:toolu_1", "chain:c-20260910-183210-reviewer-916b67c1:r1",
               "claude:peer:200:a", "chain:c-20260910-183210-reviewer-916b67c1:r2",
               "chain:c-20260910-183210-reviewer-916b67c1:end", "claude:message:300:0"], ids
older = [{"id": "claude:message:500:0", "kind": "message"}]            # 이 페이지보다 앞선 사건은 넣지 않는다
assert C.merge_chain_items(older, [chain], is_latest_page=False) == older
tail = C.merge_chain_items([{"id": "claude:message:10:0", "kind": "message"}], [chain], is_latest_page=True)
assert [i["event"] for i in tail if i["kind"] == "chain"] == ["request", "request", "end"]      # 최신 페이지면 끝에 붙인다
print("PASS: 결과 파서·HEAD·턴 끝·흐름 병합")
PY
SH
chmod +x plugin/tests/test-chains-parse.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chains-parse.sh`
Expected: FAIL `AttributeError: module 'marina_chains' has no attribute 'parse_role_result'`

- [ ] **Step 3: Append to `plugin/scripts/marina_chains.py`**

```python
# ── 결과 읽기(스펙 5.3) ──────────────────────────────────────────────────────────────
_FINDING_RE = re.compile(r"^\s*#{0,6}\s*\[(CRITICAL|WARNING|SUGGESTION)\]")
_HELD_STRIP_RE = re.compile(r"^[\s>*_\-•]+")
_OFFSET_RE = re.compile(r"^[a-z]+:(?:message|queue|peer|activity|question):(\d+)")
NONE_LEFT = "새 지적 없음"


def read_rows(path: Path, after_offset: int) -> list[tuple[int, dict]]:
    """트랜스크립트를 바이트 오프셋부터 읽는다(전체 읽기 금지 — 이미지로 수십 MB)."""
    rows: list[tuple[int, dict]] = []
    try:
        with Path(path).open("rb") as fh:
            fh.seek(max(0, int(after_offset)))
            offset = fh.tell()
            for raw in fh:
                try:
                    obj = json.loads(raw)
                except ValueError:
                    obj = None
                if isinstance(obj, dict):
                    rows.append((offset, obj))
                offset += len(raw)
    except OSError:
        return []
    return rows


def parse_role_result(rows: list[tuple[int, dict]], reply_socket: str) -> dict[str, Any] | None:
    """rows 중 구현 방 소켓으로 보낸 **마지막** SendMessage 입력을 결과로 본다."""
    text = None
    for _, obj in rows:
        content = (obj.get("message") or {}).get("content")
        for block in content if isinstance(content, list) else []:
            if (isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "SendMessage"
                    and str((block.get("input") or {}).get("to") or "") == reply_socket):
                msg = (block.get("input") or {}).get("message")
                if isinstance(msg, str):
                    text = msg
    if text is None:
        return None
    lines = text.splitlines()
    tail = [ln.strip() for ln in lines if ln.strip()]
    none_left = bool(tail) and tail[-1] == NONE_LEFT
    held: list[str] = []
    for ln in lines:
        bare = _HELD_STRIP_RE.sub("", ln).replace("**", "").strip()
        if bare.startswith("[보류]") and bare not in held:
            held.append(bare)
    findings = sum(1 for ln in lines if _FINDING_RE.match(ln))
    if not findings and not none_left:
        findings = sum(1 for para in re.split(r"\n\s*\n", text) if para.strip())
    return {"text": text, "noneLeft": none_left, "findings": findings, "held": held}


# ── 저장소 HEAD(스펙 5.1) ────────────────────────────────────────────────────────────
def worktree_repos(root: Path) -> list[tuple[str, Path]]:
    from marina_sessions import compose_scoped_subrepos, project_label   # 순환 방지
    root = Path(root)
    repos = [(project_label(root), root)] + [(name, root / name) for name in compose_scoped_subrepos(root)]
    return [(name, repo) for name, repo in repos if (repo / ".git").exists()]


def repo_heads(root: Path) -> dict[str, str]:
    import subprocess
    heads: dict[str, str] = {}
    for name, repo in worktree_repos(root):
        try:
            heads[name] = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True,
                                                  stderr=subprocess.DEVNULL, timeout=5.0).strip()
        except Exception:
            heads[name] = ""
    return heads


# ── 턴 끝(스펙 6.1) ──────────────────────────────────────────────────────────────────
_TURN_BUSY = ("working", "blocked")
_TURN_DONE = ("idle", "completed", "waiting")


def remember_status(event: dict[str, Any], last_status: dict[str, str]) -> None:
    if event.get("status"):
        last_status[str(event.get("session") or "")] = str(event["status"])


def turn_ended(event: dict[str, Any], last_status: dict[str, str]) -> bool:
    """알림층 kind 에 기대지 않는다 — 턴 끝낸 Claude 세션은 `waiting` 인데 diff_marks 는 그걸 kind:"status" 로 낸다."""
    if event.get("kind") == "idle":
        return True
    return (event.get("kind") == "status" and event.get("status") in _TURN_DONE
            and last_status.get(str(event.get("session") or "")) in _TURN_BUSY)


# ── 흐름 항목(스펙 7.1) ──────────────────────────────────────────────────────────────
def chain_items(chain: dict[str, Any]) -> list[dict[str, Any]]:
    base = {"kind": "chain", "chainId": chain["id"], "role": chain.get("role"),
            "maxRounds": chain.get("maxRounds"), "unlimited": bool(chain.get("unlimited")),
            "model": str((chain.get("roleRoom") or {}).get("model") or "")}
    items = [{**base, "id": f"chain:{chain['id']}:r{r['n']}", "event": "request", "round": r["n"],
              "anchor": int(r.get("sentAnchor") or 0)} for r in chain.get("rounds") or []]
    if chain.get("state") in TERMINAL and chain.get("endedAnchor") is not None:
        total = sum(int(r.get("findings") or 0) for r in chain.get("rounds") or [])
        held = list(chain.get("held") or [])
        items.append({**base, "id": f"chain:{chain['id']}:end", "event": "end", "round": chain.get("round"),
                      "reason": chain.get("endedReason"), "held": held, "applied": max(0, total - len(held)),
                      "anchor": int(chain["endedAnchor"])})
    return items


def _offset_of(item: dict[str, Any]) -> int | None:
    match = _OFFSET_RE.match(str(item.get("id") or ""))
    return int(match.group(1)) if match else None


def merge_chain_items(timeline: list[dict[str, Any]], chains: list[dict[str, Any]],
                      is_latest_page: bool) -> list[dict[str, Any]]:
    """각 흐름 항목을 `anchor` 이하 오프셋을 가진 마지막 타임라인 항목 **뒤**에 끼운다.
    오프셋 없는 항목(call_id 로 된 activity·question)은 앞 항목의 오프셋을 물려받는다.
    이 페이지의 첫 오프셋보다 앞선 사건은 이전 페이지 몫이라 넣지 않는다."""
    if not timeline:
        return timeline
    offsets: list[int | None] = []
    last: int | None = None
    for item in timeline:
        own = _offset_of(item)
        last = own if own is not None else last
        offsets.append(last)
    known = [o for o in offsets if o is not None]
    if not known:
        return timeline
    first = min(known)
    after: dict[int, list[dict]] = {}
    for chain in chains:
        for ci in chain_items(chain):
            if ci["anchor"] < first:
                continue
            slot = None
            for idx, off in enumerate(offsets):
                if off is not None and off <= ci["anchor"]:
                    slot = idx
            if slot == len(timeline) - 1 and not is_latest_page:
                continue
            if slot is not None:
                after.setdefault(slot, []).append(ci)
    out: list[dict[str, Any]] = []
    for idx, item in enumerate(timeline):
        out.append(item)
        out.extend(sorted(after.get(idx, []), key=lambda ci: ci["anchor"]))
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugin/tests/test-chains-parse.sh && bash plugin/tests/test-chains-state.sh`
Expected: 둘 다 PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina_chains.py plugin/tests/test-chains-parse.sh
git -c commit.gpgsign=false commit -m "feat(chains): 결과 파서·저장소 HEAD·턴 끝 판정·흐름 항목 오프셋 병합" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

---

## P3 — 트리거와 실행

### Task 6: `marina_chain_runtime.py` — 시작·액션 실행

**Files:**
- Create: `plugin/scripts/marina_chain_runtime.py`
- Modify: `plugin/scripts/marina_registry.py:91` (`"roles"` 추가)
- Test: `plugin/tests/test-chain-runtime.sh` (Create)

**Interfaces:**
- Consumes: Task 2 `load_role`·`role_cli`·`contract_prompt`, Task 3 `term_open(agent_role_argv=…)`, Task 4 `new_chain`·`next_state`·`save_chain`·`load_chain`·`open_chain_for`·`last_chain_for`, Task 5 `repo_heads`·`read_rows`·`parse_role_result`
- Produces (모듈 전역은 테스트가 갈아끼운다):
  - `HOOKS = {"term_open", "term_kill", "deliver", "repo_heads", "transcript_size", "socket_for", "role_settings", "role_transcript"}` 에 해당하는 모듈 함수: `_term_open`, `_term_kill`, `_deliver(tid, text)`, `_repo_heads(root)`, `_transcript_size(root, source, sid) -> int`, `_socket_for(sid) -> str`, `_role_settings(root) -> dict | None`, `_role_transcript(chain) -> Path | None`
  - `chain_trigger(root: Path, source: str, sid: str, reason: str, force: bool = False, now: float | None = None) -> dict`
  - `apply_event(chain: dict, event: dict, now: float | None = None) -> dict`
  - `set_unlimited(source: str, sid: str, on: bool) -> dict`, `stop_chain(source: str, sid: str) -> dict`
  - 프로젝트 dict `roles: dict` (`load_projects`)

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chain-runtime.sh <<'SH'
#!/usr/bin/env bash
# 부수효과 층 — 역할 방 띄우기·재리뷰 입력·찌르기·끄기가 상태기계 액션대로 실행되나(가짜로 갈아끼워 본다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, tempfile
from pathlib import Path
import marina_chain_runtime as RT
import marina_chains as C

root = Path(tempfile.mkdtemp())
calls = {"open": [], "kill": [], "deliver": []}
heads = {"v": {"proj": "a1"}}
role_t = Path(tempfile.mkdtemp()) / "role.jsonl"; role_t.write_text("")
RT._term_open = lambda root, *a, **kw: (calls["open"].append(kw), {"tid": f"t{len(calls['open'])}"})[1]
RT._term_kill = lambda tid: calls["kill"].append(tid)
RT._deliver = lambda tid, text: calls["deliver"].append((tid, text))
RT._repo_heads = lambda root: dict(heads["v"])
RT._transcript_size = lambda root, source, sid: 1000
RT._socket_for = lambda sid: "uds:/tmp/cc-socks/9.sock"
RT._role_settings = lambda root: {"on": "commit", "maxRounds": 2}
RT._role_transcript = lambda chain: role_t

# 기준 없음 → 기록만, 역할 방 안 띄움
r = RT.chain_trigger(root, "claude", "impl", "commit", now=100.0)
assert r["reason"] == "baseline" and calls["open"] == [], r
# 커밋 → 묶음 시작, 역할 방은 프롬프트-맨앞 argv·plan·계약(소켓) 으로
heads["v"] = {"proj": "b2"}
r = RT.chain_trigger(root, "claude", "impl", "commit", now=110.0)
assert r["ok"] and r["started"], r
kw = calls["open"][0]
argv = kw["agent_role_argv"]
assert argv[0] == "claude" and "uds:/tmp/cc-socks/9.sock" in argv[1] and "a1..b2" in argv[1], argv[:2]
assert "--permission-mode" in argv and kw["agent_role"] == "reviewer" and kw["agent_prompt"] == argv[1]
assert argv[1] not in kw["agent_role_launch"], "저장본에 프롬프트"
chain = C.open_chain_for("claude", "impl", "reviewer")
assert chain["roleRoom"]["tid"] == "t1" and chain["rounds"][0]["sentAnchor"] == 1000, chain

# 커밋 없는 트리거는 무시(열린 묶음이 reviewing 이면 pendingHead 도 안 생김)
assert RT.chain_trigger(root, "claude", "impl", "commit", now=111.0)["reason"] == "in-progress"

# 역할 결과(지적) → applying
role_t.write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "SendMessage",
    "input": {"to": "uds:/tmp/cc-socks/9.sock", "message": "### [WARNING] x"}}]}}) + "\n")
chain = RT.on_role_turn_end(C.open_chain_for("claude", "impl", "reviewer"), now=120.0)
assert chain["state"] == "applying" and chain["rounds"][0]["findings"] == 1, chain
# 구현 방 반영 커밋 → 2바퀴 요청이 역할 방 PTY 로 간다
heads["v"] = {"proj": "c3"}
chain = RT.on_implementer_turn_end(chain, root, now=130.0)
assert chain["state"] == "reviewing" and chain["round"] == 2, chain
tid, text = calls["deliver"][-1]
assert tid == "t1" and "b2..c3" in text and "2바퀴" in text, (tid, text)
assert chain["rounds"][1]["roleAnchor"] == role_t.stat().st_size

# 역할 방 PTY 가 죽었으면(입력 실패) 새로 띄우고 지난 요약을 싣는다
def boom(tid, text): raise ValueError("detached")
RT._deliver = boom
heads["v"] = {"proj": "d4"}
a = dict(chain); a["state"] = "applying"; a["unlimited"] = True; C.save_chain(a)   # 상한(2)에 걸리지 않게
chain = RT.on_implementer_turn_end(C.load_chain(a["id"]), root, now=140.0, force_round=True)
assert calls["open"][-1]["agent_role_argv"][1].count("지난 바퀴 요약") == 1 and chain["roleRoom"]["tid"] == "t2", chain

# 결과(지적 없음) → done + 역할 방 끔
role_t.write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "SendMessage",
    "input": {"to": "uds:/tmp/cc-socks/9.sock", "message": "반영 확인\n\n새 지적 없음"}}]}}) + "\n")
chain["rounds"][-1]["roleAnchor"] = 0; C.save_chain(chain)
done = RT.on_role_turn_end(C.load_chain(chain["id"]), now=150.0)
assert done["state"] == "done" and calls["kill"][-1] == "t2", (done, calls["kill"])

# 폰·명령: 무제한·멈추기
heads["v"] = {"proj": "e5"}; RT._deliver = lambda tid, text: calls["deliver"].append((tid, text))
RT.chain_trigger(root, "claude", "impl", "commit", now=160.0)
assert RT.set_unlimited("claude", "impl", True)["unlimited"] is True
assert RT.stop_chain("claude", "impl")["state"] == "stopped" and calls["kill"][-1] == "t3"
# force(폰 버튼): 커밋 없어도 시작
assert RT.chain_trigger(root, "claude", "impl", "button", force=True, now=170.0)["started"]
# 역할 꺼진 프로젝트 → off (force 는 기본 설정으로 시작)
RT._role_settings = lambda root: None
assert RT.chain_trigger(root, "claude", "impl2", "commit", now=180.0)["reason"] == "off"
print("PASS: 런타임 — 시작·재리뷰·재기동·끝·무제한·멈추기")
PY
SH
chmod +x plugin/tests/test-chain-runtime.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chain-runtime.sh`
Expected: FAIL `ModuleNotFoundError: No module named 'marina_chain_runtime'`

- [ ] **Step 3: `marina_registry.py` — `"lean"` 줄 다음에 추가**

```python
                # 역할 방(스펙 6.5) — {"reviewer": {"on": "commit", "maxRounds": 2}}. 없으면 꺼짐.
                "roles": dict(entry.get("roles") or {}) if isinstance(entry.get("roles"), dict) else {},
```

- [ ] **Step 4: Write `plugin/scripts/marina_chain_runtime.py`**

```python
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


def _role_transcript(chain: dict[str, Any]) -> Path | None:
    from marina_sessions import agent_transcript_path
    from marina_term import term_list
    tid = (chain.get("roleRoom") or {}).get("tid")
    for item in term_list().get("sessions", []):
        agent = item.get("agent") or {}
        if item.get("tid") == tid and agent.get("sid"):
            chain.setdefault("roleRoom", {})["sid"] = agent["sid"]
            try:
                return agent_transcript_path(Path(item.get("root") or ""), "claude", agent["sid"])
            except Exception:
                return None
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
```

Note: 테스트의 `force_round=True` 는 상태를 applying 으로 되돌려 저장한 뒤 부르는 경우라 인자는 받기만 한다(시그니처 호환).

- [ ] **Step 5: Run tests**

Run: `bash plugin/tests/test-chain-runtime.sh && bash plugin/tests/test-chains-state.sh && bash plugin/tests/test-chains-parse.sh`
Expected: 모두 PASS

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_chain_runtime.py plugin/scripts/marina_registry.py plugin/tests/test-chain-runtime.sh
git -c commit.gpgsign=false commit -m "feat(chains): 런타임 — 역할 방 시작·재리뷰 입력·재기동·찌르기·끄기" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

### Task 7: 사건 작업자 + `_on_events` 연결

**Files:**
- Modify: `plugin/scripts/marina_chain_runtime.py` (끝에 덧붙인다)
- Modify: `plugin/scripts/marina_handler.py` (`_on_events` ~3013)
- Test: `plugin/tests/test-chain-events.sh` (Create)

**Interfaces:**
- Consumes: Task 5 `turn_ended`·`remember_status`, Task 6 `chain_trigger`·`on_implementer_turn_end`·`on_role_turn_end`·`apply_event`
- Produces: `on_events(events: list[dict], now: float | None = None) -> list[str]` (한 일 로그), `submit_events(events: list[dict]) -> None` (작업 스레드 큐), `tick_all(now: float | None = None) -> None`, `_role_sid_to_chain(sid: str) -> dict | None`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chain-events.sh <<'SH'
#!/usr/bin/env bash
# 감시층 사건 → 묶음. 턴 끝 판정은 status 전이(waiting 포함), 역할 방 사건은 결과 읽기로(스펙 6.1).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_chain_runtime as RT
import marina_chains as C

log = []
RT.chain_trigger = lambda root, source, sid, reason, force=False, now=None: log.append(("trigger", sid, reason)) or {"ok": True}
RT.on_implementer_turn_end = lambda chain, root, now=None, force_round=False: log.append(("impl", chain["id"])) or chain
RT.on_role_turn_end = lambda chain, now=None: log.append(("role", chain["id"])) or chain
RT._role_settings = lambda root: {"on": "commit"}

def ev(sid, kind, status, root="/wt"):
    return {"session": f"agent:claude:{sid}:{root}", "root": root, "source": "claude", "sid": sid, "kind": kind, "status": status}

RT._last_status.clear()
RT.on_events([ev("impl", "status", "working")], now=1.0)
assert log == [], log                                              # 일 시작은 트리거 아님
RT.on_events([ev("impl", "status", "waiting")], now=2.0)
assert log == [("trigger", "impl", "commit")], log                  # working → waiting = 턴 끝
log.clear()
RT.on_events([ev("other", "status", "waiting")], now=3.0)
assert log == [], "직전 상태를 모르면 턴 끝으로 보지 않는다"

# 열린 묶음이 있는 구현 방 → 트리거가 아니라 impl 경로
chain = C.new_chain(role="reviewer", implementer={"root": "/wt", "source": "claude", "sid": "impl", "socket": "uds:/x"},
                    base={"p": "a"}, head={"p": "b"}, max_rounds=2, unlimited=False, now=1.0, anchor=0)
chain["roleRoom"] = {"tid": "t1", "sid": "role-sid"}
C.save_chain(chain)
RT.on_events([ev("impl", "status", "working"), ev("impl", "idle", "idle")], now=4.0)
assert log == [("impl", chain["id"])], log
log.clear()
# 역할 방 사건 → 결과 읽기, 트리거 안 함(역할 방이 커밋해도 새 묶음이 생기면 안 된다)
RT.on_events([ev("role-sid", "status", "working"), ev("role-sid", "status", "waiting")], now=5.0)
assert log == [("role", chain["id"])], log

# 끝난 묶음의 역할 방 sid 는 더는 역할 방으로 안 본다
chain["state"] = "done"; C.save_chain(chain); log.clear()
assert RT._role_sid_to_chain("role-sid") is None
print("PASS: 사건 → 묶음")
PY

# _on_events 가 주 데몬 확인 직후·알림 필터 전에 넘긴다(순서가 계약)
python3 - "$SCR/marina_handler.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("def _on_events"):src.index("def _events_loop")]
primary = body.index("is_primary_notifier(PORT)")
submit = body.index("submit_events(events)")
notify = body.index("should_notify(")
assert primary < submit < notify, (primary, submit, notify)
print("PASS: _on_events 연결 순서")
PY
SH
chmod +x plugin/tests/test-chain-events.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chain-events.sh`
Expected: FAIL `AttributeError: module 'marina_chain_runtime' has no attribute '_last_status'`

- [ ] **Step 3: Append to `marina_chain_runtime.py`**

```python
# ── 감시층 사건(스펙 6.1) ────────────────────────────────────────────────────────────
import queue as _queue

_last_status: dict[str, str] = {}
_events_q: "_queue.Queue[list[dict]]" = _queue.Queue()
_worker_started = False


def _role_sid_to_chain(sid: str) -> dict[str, Any] | None:
    for chain in C.list_chains():
        if chain.get("state") in C.TERMINAL:
            continue
        room = chain.get("roleRoom") or {}
        if room.get("sid") == sid:
            return chain
        if not room.get("sid") and room.get("tid"):
            try:
                from marina_term import term_list
                for item in term_list().get("sessions", []):
                    if item.get("tid") == room["tid"] and (item.get("agent") or {}).get("sid") == sid:
                        return chain
            except Exception:
                continue
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
```

- [ ] **Step 4: `marina_handler.py` `_on_events` — `if not is_primary_notifier(PORT): return` 다음 줄에**

```python
        # 역할 방 묶음(스펙 6.1) — **알림 필터보다 먼저.** 알림은 폰을 울릴 사건만 남기는데 조용한 커밋도
        # 묶음을 움직여야 한다. 주 데몬만 넘긴다(둘이면 리뷰어도 둘이 뜬다).
        try:
            from marina_chain_runtime import submit_events
            submit_events(events)
        except Exception:
            pass
```

- [ ] **Step 5: Run tests**

Run: `bash plugin/tests/test-chain-events.sh && bash plugin/tests/test-chain-runtime.sh`
Expected: 둘 다 PASS

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_chain_runtime.py plugin/scripts/marina_handler.py plugin/tests/test-chain-events.sh
git -c commit.gpgsign=false commit -m "feat(chains): 감시층 사건을 묶음으로 — 턴 끝 전이·역할 방 결과·작업 스레드" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

### Task 8: 폰 API · 루프백 `/api/chain` · `marina chain` CLI · 지시문 한 줄

**Files:**
- Create: `plugin/scripts/marina_chain_cli.py`
- Modify: `plugin/scripts/marina_chain_runtime.py` (호출자 확인 함수)
- Modify: `plugin/scripts/marina_handler.py` (`/mobile/api/chain/*`, `/api/chain`)
- Modify: `plugin/scripts/marina_auth_http.py:18` (`PUBLIC_PATHS`)
- Modify: `plugin/scripts/marina-entrypoint.sh` (`CHAIN_CLI` · `chain)`)
- Modify: `plugin/scripts/marina-session-start-hook.sh` (`emit_context "$rules"` 직전)
- Test: `plugin/tests/test-chain-entry.sh` (Create)

**Interfaces:**
- Consumes: Task 6 `chain_trigger`·`set_unlimited`·`stop_chain`, `marina_agent_procs.ps_table()`·`ancestors(pid, table)`·`_pid_start(pid)`
- Produces:
  - `verify_caller(pid: int, sid: str, cwd: str, sessions_dir: Path | None = None, pid_start=None) -> dict | None` → `{"root": Path, "sid": str}` 또는 None
  - `marina_chain_cli.find_caller(table: dict, start_pid: int, sessions_dir: Path) -> dict | None` → `{"pid","sid"}`
  - HTTP: `POST /api/chain {action, pid, sid, cwd}`(루프백), `POST /mobile/api/chain/request|unlimited|stop {root, source, sid}`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chain-entry.sh <<'SH'
#!/usr/bin/env bash
# 트리거 입구 — 남의 방 대신 부를 수 없게 호출자를 확인하고(스펙 6.3), 역할 켠 프로젝트에만 지시문을 넣는다(6.4).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
PYTHONPATH="$SCR" python3 - <<'PY'
import json, os, subprocess, tempfile
from pathlib import Path
import marina_chain_cli as CLI
import marina_chain_runtime as RT

sess = Path(tempfile.mkdtemp())
(sess / "500.json").write_text(json.dumps({"sessionId": "sid-impl", "procStart": "S500", "cwd": "/wt"}))
table = {900: (800, "python3"), 800: (700, "bash"), 700: (500, "zsh"), 500: (1, "claude")}
assert CLI.find_caller(table, 900, sess) == {"pid": 500, "sid": "sid-impl"}
assert CLI.find_caller({900: (1, "python3")}, 900, sess) is None

root = Path(tempfile.mkdtemp()); subprocess.run(["git", "init", "-q", str(root)], check=True)
RT._belongs = lambda root, source, sid: sid == "sid-impl"
ok = RT.verify_caller(500, "sid-impl", str(root), sessions_dir=sess, pid_start=lambda pid: "S500")
assert ok and ok["sid"] == "sid-impl" and Path(ok["root"]) == root.resolve(), ok
assert RT.verify_caller(500, "sid-other", str(root), sessions_dir=sess, pid_start=lambda pid: "S500") is None   # sid 불일치
assert RT.verify_caller(500, "sid-impl", str(root), sessions_dir=sess, pid_start=lambda pid: "OTHER") is None   # pid 재사용
assert RT.verify_caller(501, "sid-impl", str(root), sessions_dir=sess, pid_start=lambda pid: "S500") is None    # 세션 파일 없음
RT._belongs = lambda root, source, sid: False
assert RT.verify_caller(500, "sid-impl", str(root), sessions_dir=sess, pid_start=lambda pid: "S500") is None    # 다른 워크트리
print("PASS: 호출자 확인")
PY

python3 - "$SCR" <<'PY'
import sys
scr = sys.argv[1]
h = open(f"{scr}/marina_handler.py", encoding="utf-8").read()
for route in ('"/api/chain"', '"/mobile/api/chain/request"', '"/mobile/api/chain/unlimited"', '"/mobile/api/chain/stop"'):
    assert route in h, f"라우트 없음: {route}"
seg = h[h.index('"/api/chain"'):][:1200]
assert "is_loopback_client(self)" in seg and "x-forwarded-for" in seg and "verify_caller(" in seg, "루프백·포워딩·호출자 확인 누락"
assert '"/api/chain"' in open(f"{scr}/marina_auth_http.py", encoding="utf-8").read()
e = open(f"{scr}/marina-entrypoint.sh", encoding="utf-8").read()
assert 'CHAIN_CLI="$SCRIPT_DIR/marina_chain_cli.py"' in e and "\n  chain)" in e
print("PASS: 라우트·엔트리포인트 배선")
PY

# SessionStart: roles 켠 프로젝트에만 한 줄
tmpwt="$(mktemp -d)"; git -C "$tmpwt" init -q
python3 - "$MARINA_HOME" "$tmpwt" <<'PY'
import json, sys, pathlib
home, wt = pathlib.Path(sys.argv[1]), sys.argv[2]
home.mkdir(parents=True, exist_ok=True)
(home / "projects.json").write_text(json.dumps({"projects": [{"id": "p", "root": wt, "roles": {"reviewer": {"on": "commit"}}}], "schemaVersion": 1}))
PY
out="$(cd "$tmpwt" && CLAUDE_PLUGIN_ROOT=x "$SCR/marina-session-start-hook.sh" </dev/null)"
case "$out" in *"marina chain request"*) echo "PASS: 역할 켠 프로젝트에 지시문";; *) echo "FAIL: 지시문 없음: $out"; exit 1;; esac
python3 - "$MARINA_HOME" "$tmpwt" <<'PY'
import json, sys, pathlib
home, wt = pathlib.Path(sys.argv[1]), sys.argv[2]
(home / "projects.json").write_text(json.dumps({"projects": [{"id": "p", "root": wt}], "schemaVersion": 1}))
PY
out="$(cd "$tmpwt" && CLAUDE_PLUGIN_ROOT=x "$SCR/marina-session-start-hook.sh" </dev/null)"
case "$out" in *"marina chain"*) echo "FAIL: 역할 없는 프로젝트에 지시문이 들어갔다"; exit 1;; *) echo "PASS: 역할 없으면 지시문 없음";; esac
SH
chmod +x plugin/tests/test-chain-entry.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chain-entry.sh`
Expected: FAIL `ModuleNotFoundError: No module named 'marina_chain_cli'`

- [ ] **Step 3: `marina_chain_runtime.py` 에 호출자 확인 추가**

```python
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
```

Note: `procStart` 문자열 형식이 `marina_agent_procs._pid_start` 와 다르면(실측으로 확인) 이 비교를 `str(data.get("procStart"))` 와 `ps -o lstart` 정규화 비교로 바꾼다 — Step 5 실측에서 확인한다.

- [ ] **Step 4: Write `plugin/scripts/marina_chain_cli.py`**

```python
#!/usr/bin/env python3
"""marina chain request|unlimited|stop — 구현 에이전트가 형 말을 듣고 부른다(스펙 6.3).

내가 어느 세션인지는 **프로세스 조상**으로 찾는다: 부모를 따라 올라가 ~/.claude/sessions/<pid>.json 을 가진
claude 를 만난다. 데몬이 그 pid·sid·procStart·워크트리를 다시 확인한다.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path


def find_caller(table: dict, start_pid: int, sessions_dir: Path) -> dict | None:
    from marina_agent_procs import ancestors
    for pid in ancestors(start_pid, table):
        path = sessions_dir / f"{pid}.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("sessionId"):
            return {"pid": pid, "sid": str(data["sessionId"])}
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="marina chain")
    parser.add_argument("action", choices=["request", "unlimited", "stop"])
    args = parser.parse_args(argv)
    from marina_agent_procs import ps_table
    from marina_state import HOST, PORT
    caller = find_caller(ps_table(), os.getpid(), Path.home() / ".claude" / "sessions")
    if caller is None:
        print("marina chain: Claude 세션 안에서만 쓸 수 있어요", file=sys.stderr)
        return 2
    body = json.dumps({"action": args.action, **caller, "cwd": os.getcwd()}).encode("utf-8")
    req = urllib.request.Request(f"http://{HOST}:{PORT}/api/chain", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            print(resp.read().decode("utf-8"))
            return 0
    except Exception as exc:
        print(f"marina chain: 데몬에 못 닿았어요 · {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 배선**

`marina_auth_http.py` `PUBLIC_PATHS` 의 `"/api/events-poke",` 줄 다음에 `"/api/chain",` 을 넣는다.

`marina_handler.py` — `/api/events-poke` 라우트 블록 바로 뒤에:
```python
            if self.path == "/api/chain":
                # `marina chain` CLI 전용. 로그인 없이 받되 **루프백 + 호출자 확인**(스펙 6.3) — 남의 방 대신 못 부른다.
                if (not is_loopback_client(self)
                        or self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host")):
                    self.send_json({"error": "local only"}, 403)
                    return
                try:
                    from marina_chain_runtime import chain_trigger, set_unlimited, stop_chain, verify_caller
                    body = self.read_json()
                    who = verify_caller(int(body.get("pid") or 0), str(body.get("sid") or ""), str(body.get("cwd") or ""))
                    if who is None:
                        self.send_json({"error": "caller not verified"}, 403)
                        return
                    action = str(body.get("action") or "")
                    if action == "request":
                        self.send_json(chain_trigger(who["root"], "claude", who["sid"], "command", force=True))
                    elif action == "unlimited":
                        self.send_json(set_unlimited("claude", who["sid"], True))
                    elif action == "stop":
                        self.send_json(stop_chain("claude", who["sid"]))
                    else:
                        self.send_json({"error": "unknown action"}, 400)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
```
같은 파일 `/mobile/api/harness` 라우트 블록 바로 앞에:
```python
            if parsed.path in ("/mobile/api/chain/request", "/mobile/api/chain/unlimited", "/mobile/api/chain/stop"):
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    from marina_chain_runtime import chain_trigger, set_unlimited, stop_chain
                    body = self.read_json()
                    root = safe_root(str(body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    source, sid = str(body.get("source") or ""), str(body.get("sid") or "")
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    if parsed.path.endswith("/request"):
                        self.send_json(chain_trigger(root, source, sid, "button", force=True))
                    elif parsed.path.endswith("/unlimited"):
                        self.send_json(set_unlimited(source, sid, bool(body.get("on", True))))
                    else:
                        self.send_json(stop_chain(source, sid))
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
```
`marina-entrypoint.sh` — `REMOTE_CLI=` 줄 다음에 `CHAIN_CLI="$SCRIPT_DIR/marina_chain_cli.py"`, `auth|user)` 분기 앞에:
```bash
  chain)
    exec "${MARINA_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}" "$CHAIN_CLI" "$@"
    ;;
```
`marina-session-start-hook.sh` — `emit_context "$rules"` 바로 앞에:
```bash
# 역할 방(스펙 6.4) — 이 프로젝트가 roles.reviewer 를 켰을 때만 한 줄.
role_line="$(python3 - "$ROOT" <<'PY' 2>/dev/null || true
import json, os, sys
home = os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina")
root = os.path.realpath(sys.argv[1])
try:
    projects = json.load(open(os.path.join(home, "projects.json"), encoding="utf-8")).get("projects", [])
except Exception:
    projects = []
best = None
for p in projects:
    pr = os.path.realpath(os.path.expanduser(str(p.get("root") or "")))
    if pr and (root == pr or root.startswith(pr + os.sep)) and (best is None or len(pr) > len(best[0])):
        best = (pr, p)
roles = (best[1].get("roles") if best else None) or {}
if isinstance(roles, dict) and isinstance(roles.get("reviewer"), dict):
    print("[marina] 이 방엔 리뷰어가 붙어 있다. 형이 리뷰를 부탁하면 `marina chain request`, 쭉 진행하라면 "
          "`marina chain unlimited`, 멈추라면 `marina chain stop` 을 실행한다. 다른 세션이 보낸 리뷰 결과는 바로 "
          "반영하고 커밋한다. `[보류]` 로 시작하는 줄은 참고만 하고 반영하지 않는다.")
PY
)"
[[ -n "$role_line" ]] && rules="$rules"$'\n'"$role_line"
```
Note: 이 훅의 등록 판정(`classify_root`)이 테스트 워크트리를 등록 프로젝트로 보지 않으면 앞에서 `exit 0` 한다 — 그 경우 테스트의 `projects.json` 이 `marina_pretooluse.py --is-registered` 기준(루트 일치)을 만족하는지 확인한다.

- [ ] **Step 6: Run tests**

Run: `bash plugin/tests/test-chain-entry.sh && bash plugin/tests/test-session-start-hook.sh 2>/dev/null || true; bash plugin/tests/run-affected.sh HEAD`
Expected: `test-chain-entry` 전 항목 PASS, affected 전부 PASS. `procStart` 형식 불일치로 실패하면 Step 3 Note 대로 정규화한다(실측: `python3 -c "import json;print(json.load(open('$HOME/.claude/sessions/'+str(PID)+'.json'))['procStart'])"` 와 `marina_agent_procs._pid_start(PID)` 비교).

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina_chain_cli.py plugin/scripts/marina_chain_runtime.py plugin/scripts/marina_handler.py plugin/scripts/marina_auth_http.py plugin/scripts/marina-entrypoint.sh plugin/scripts/marina-session-start-hook.sh plugin/tests/test-chain-entry.sh
git -c commit.gpgsign=false commit -m "feat(chains): 입구 — 폰 API·루프백 /api/chain(호출자 확인)·marina chain CLI·지시문 한 줄" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

---

## P4 — 폰 화면

### Task 9: 공유 렌더러 흐름 줄·요약 카드 + transcript 병합

**Files:**
- Modify: `plugin/scripts/marina-web/chat-render.js` (`renderTimelineMessage` 첫 줄, 새 `CHAIN_ITEM` 블록, `window.MarinaChat` 노출)
- Modify: `plugin/scripts/marina_handler.py` (`/mobile/api/transcript` ~806)
- Modify: `plugin/scripts/marina_mobile.py` (CSS: `.turn.user` 줄 다음 · 다크 블록)
- Modify: `plugin/scripts/marina-web/styles.css` (`.chat-turns .turn.peer .turnBody` 줄 다음)
- Test: `plugin/tests/test-chain-render.sh` (Create)

**Interfaces:**
- Consumes: Task 5 `chain_items`·`merge_chain_items`·`list_chains`
- Produces: `MarinaChat.renderChainItem(item) -> string`; `renderTimelineMessage` 가 `kind:"chain"` 을 그린다

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chain-render.sh <<'SH'
#!/usr/bin/env bash
# 흐름 줄·요약 카드(스펙 7.2). 역할 이름·모델·보류 문장은 남이 정한 글자라 이스케이프.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
node - "$SCR/marina-web/chat-render.js" <<'JS'
const fs = require("fs"), vm = require("vm"), assert = require("assert/strict");
const ctx = {window: {}, console}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx);
const M = ctx.window.MarinaChat;
M.configure({displayModel: m => m === "claude-sonnet-5" ? "Sonnet 5" : m});
const R = it => M.renderTimelineMessage(it);
const req = R({kind: "chain", chainId: "c1", event: "request", role: "reviewer", model: "claude-sonnet-5", round: 1, maxRounds: 2});
assert.match(req, /class="chainLine"/); assert.match(req, /리뷰 요청 · reviewer\(Sonnet 5\)/); assert.match(req, /1\/2/);
assert.ok(!/class="turn /.test(req), "흐름 줄을 말풍선으로 그렸다");
assert.match(R({kind: "chain", event: "request", role: "reviewer", round: 2, maxRounds: 2}), /재리뷰/);
assert.match(R({kind: "chain", event: "request", role: "reviewer", round: 3, maxRounds: 2, unlimited: true}), /3\/∞/);
const end = R({kind: "chain", event: "end", reason: "clean", round: 2, applied: 2, held: ["[보류] 공용 모듈로"]});
assert.match(end, /class="chainDone"/); assert.match(end, /리뷰 끝 · 2바퀴 · 반영 2/); assert.match(end, /보류 1/); assert.match(end, /공용 모듈로/);
assert.match(R({kind: "chain", event: "end", reason: "stopped", round: 1, applied: 0, held: []}), /리뷰 멈춤/);
assert.match(R({kind: "chain", event: "end", reason: "max-rounds", round: 2, applied: 3, held: []}), /상한/);
const evil = R({kind: "chain", event: "end", reason: "clean", round: 1, applied: 0, held: ['<img src=x onerror=alert(1)>']})
  + R({kind: "chain", event: "request", role: '<script>x</script>', model: '"><b>', round: 1, maxRounds: 2});
assert.ok(!evil.includes("<img src=x") && !evil.includes("<script>") && !evil.includes('"><b>'), "이스케이프 누락");
console.log("PASS: 흐름 줄·요약 카드");
JS
python3 - "$SCR" <<'PY'
import sys
h = open(f"{sys.argv[1]}/marina_handler.py", encoding="utf-8").read()
seg = h[h.index('if parsed.path == "/mobile/api/transcript":'):][:2600]
assert "merge_chain_items(" in seg and "is_latest_page=before is None" in seg, "transcript 에 묶음 병합이 없다"
print("PASS: transcript 병합 배선")
PY
bash "$HERE/test-mobile-css-tokens.sh" >/dev/null && echo "PASS: CSS 토큰"
SH
chmod +x plugin/tests/test-chain-render.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chain-render.sh`
Expected: FAIL `AssertionError ... chainLine`

- [ ] **Step 3: `chat-render.js`**

`function renderTimelineMessage(item) {` 다음 첫 줄에 `if (item && item.kind === "chain") return renderChainItem(item);` 를 넣고, `renderTimelineMessage` 함수 바로 **앞**에 블록을 추가한다:
```js
    // CHAIN_ITEM_START
    // 역할 방 묶음의 흐름(스펙 7.2) — 형의 말도 에이전트 답도 아니다. 무슨 일이 도는지만 알린다.
    const CHAIN_END_LABEL = {
      "clean": "리뷰 끝", "max-rounds": "리뷰 끝 · 상한 도달", "stopped": "리뷰 멈춤",
      "wait-timeout": "리뷰 끝 · 커밋 없이 30분", "no-result": "리뷰 끝 · 결과를 못 받음",
      "implementer-gone": "리뷰 끝 · 구현 대화가 꺼짐",
    };
    function renderChainItem(item) {
      const id = esc(String(item.chainId || ""));
      if (item.event === "end") {
        const held = Array.isArray(item.held) ? item.held : [];
        const label = CHAIN_END_LABEL[item.reason] || "리뷰 끝";
        const count = held.length ? ` · <span class="held">보류 ${held.length}</span>` : "";
        const list = held.length ? `<ul>${held.map(h => `<li class="held">${esc(String(h))}</li>`).join("")}</ul>` : "";
        return `<details class="chainDone${item.reason === "stopped" ? " stopped" : ""}" data-chain-id="${id}"${held.length ? " open" : ""}>`
          + `<summary>✓ ${esc(label)} · ${esc(String(item.round || 0))}바퀴 · 반영 ${esc(String(item.applied || 0))}${count}</summary>${list}</details>`;
      }
      const shown = item.model ? (typeof host.displayModel === "function" ? host.displayModel(item.model) : item.model) : "";
      const model = shown ? `(${esc(String(shown))})` : "";
      const verb = Number(item.round) > 1 ? "재리뷰" : "리뷰 요청";
      const max = item.unlimited ? "∞" : esc(String(item.maxRounds || ""));
      return `<div class="chainLine" data-chain-id="${id}">🔁 ${verb} · ${esc(String(item.role || "역할"))}${model} `
        + `<span class="n">${esc(String(item.round || 1))}/${max}</span></div>`;
    }
    // CHAIN_ITEM_END
```
`window.MarinaChat = {` 노출 목록의 `renderTimelineMessage,` 앞에 `renderChainItem,` 을 넣는다. `configure` 가 `displayModel` 을 이미 받는지 `host` 정의를 확인하고, 없으면 `host` 기본값에 `displayModel: model => model,` 을 더한다.

- [ ] **Step 4: transcript 병합 (`marina_handler.py` `/mobile/api/transcript`)**

`payload = agent_transcript(...)` 호출 다음 줄에(같은 `try` 안):
```python
                # 역할 방 묶음 흐름 줄 — 사건은 트랜스크립트에 없어 오프셋으로 끼운다(스펙 7.1). 실패해도 대화는 보인다.
                try:
                    from marina_chains import list_chains, merge_chain_items
                    src_q, sid_q = query.get("source", [""])[0], query.get("sid", [""])[0]
                    mine = [c for c in list_chains()
                            if (c.get("implementer") or {}).get("source") == src_q
                            and (c.get("implementer") or {}).get("sid") == sid_q]
                    if mine:
                        payload["timeline"] = merge_chain_items(payload.get("timeline") or [], mine,
                                                                is_latest_page=before is None)
                except Exception:
                    pass
```

- [ ] **Step 5: CSS**

`marina_mobile.py` — `.turn.user { align-self: flex-end; background: #dcecff; }` 줄 다음:
```css
    /* 역할 방 묶음 흐름(스펙 7.2) — 가운데 점선 알약·요약 카드. 말풍선이 아니다. */
    .chainLine { align-self: center; display: inline-flex; align-items: center; gap: 6px; padding: 5px 11px;
                 border: 1px dashed #b9a6e8; border-radius: 999px; background: #faf7ff; color: #5b3fb0;
                 font-size: 11.5px; font-weight: 700; }
    .chainLine .n { font-variant-numeric: tabular-nums; opacity: .8; }
    .chainDone { align-self: stretch; border: 1px solid #cfe3d5; background: #f3faf5; border-radius: 10px;
                 padding: 9px 11px; font-size: 12px; }
    .chainDone.stopped { border-color: #e5d2d2; background: #fbf5f5; }
    .chainDone summary { cursor: pointer; font-weight: 800; color: #1f6b3a; }
    .chainDone.stopped summary { color: #8a3b3b; }
    .chainDone ul { margin: 7px 0 0; padding-left: 16px; line-height: 1.55; }
    .chainDone .held { color: #8a5a00; font-weight: 700; }
```
다크 블록의 `.turn.peer { background: #231d36; border-color: #4d3f7a; }` 줄 다음:
```css
      .chainLine { background: #1d1830; border-color: #4d3f7a; color: #c9b8f5; }
      .chainDone { background: #14231a; border-color: #2c4a36; }
      .chainDone summary { color: #8fd3a4; }
      .chainDone .held { color: #e0b35a; }
```
`marina-web/styles.css` — `.chat-turns .peerFrom` 줄 다음:
```css
    .chat-turns .chainLine { align-self: center; padding: 3px 10px; border: 1px dashed var(--st-boot); border-radius: 999px; font-size: 11px; font-weight: 700; opacity: .9; }
    .chat-turns .chainDone { padding: 7px 10px; border: 1px solid var(--line, #d8dde5); border-radius: 8px; font-size: 12px; }
```

- [ ] **Step 6: Run tests**

Run: `bash plugin/tests/test-chain-render.sh && bash plugin/tests/test-chat-render-shared.sh && bash plugin/tests/test-chat-peer-bubble.sh`
Expected: 모두 PASS

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-web/chat-render.js plugin/scripts/marina_handler.py plugin/scripts/marina_mobile.py plugin/scripts/marina-web/styles.css plugin/tests/test-chain-render.sh
git -c commit.gpgsign=false commit -m "feat(chat): 묶음 흐름 줄·요약 카드 — 트랜스크립트 오프셋으로 끼운다" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

### Task 10: 모바일 호스트 — 고정 줄·배지·딸린 줄·메뉴

**Files:**
- Modify: `plugin/scripts/marina_mobile.py` (서버: `mobile_state` 세션·방 조립 / 클라이언트: `ROOM_LIST`·`ROOM_TABS` 블록, `renderChatMenu`, `#chatComposer` 마크업, `renderLiveQuestion(session)` 호출부 ~6391, 위임 클릭 핸들러, CSS)
- Test: `plugin/tests/test-chain-mobile-ui.sh` (Create)

**Interfaces:**
- Consumes: Task 4 `open_chain_for`·`last_chain_for`, Task 8 `/mobile/api/chain/*`
- Produces:
  - 서버 `_session_chain_summary(source: str, sid: str, now: float | None = None) -> dict | None` → `{id, role, state, round, maxRounds, unlimited, heldCount, roleModel, endedReason}` (열린 묶음, 없으면 끝난 지 600초 안의 것)
  - 세션 dict `chain`, 방 dict `chain`(열린 것만), 탭 dict `roleOf: {chainId, role}` · `chainEnabled: bool`
  - 클라이언트 `renderChainStrip(session) -> string` (`CHAIN_STRIP_START/END` 블록), `renderRooms` 가 배지·딸린 줄을 그린다, `renderChatMenu(key, tab)` 가 `tab.chainEnabled` 면 `data-chain-request`

- [ ] **Step 1: Write the failing test**

```bash
cat > plugin/tests/test-chain-mobile-ui.sh <<'SH'
#!/usr/bin/env bash
# 폰 화면 요소(스펙 7.2) — 고정 줄·배지·딸린 줄·메뉴. 역할 방은 "대화 N개"에 안 센다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_chains as C
import marina_mobile as MM
imp = {"root": "/wt", "source": "claude", "sid": "impl", "socket": "uds:/x"}
c = C.new_chain(role="reviewer", implementer=imp, base={"p": "a"}, head={"p": "b"}, max_rounds=2, unlimited=False, now=1000.0, anchor=0)
c["roleRoom"] = {"tid": "t1", "model": "claude-sonnet-5"}; c["held"] = ["[보류] x"]
C.save_chain(c)
s = MM._session_chain_summary("claude", "impl", now=1001.0)
assert s["state"] == "reviewing" and s["round"] == 1 and s["heldCount"] == 1 and s["roleModel"] == "claude-sonnet-5", s
c["state"] = "done"; c["endedAt"] = 1002.0; c["endedReason"] = "clean"; C.save_chain(c)
assert MM._session_chain_summary("claude", "impl", now=1500.0)["state"] == "done"
assert MM._session_chain_summary("claude", "impl", now=1002.0 + 601) is None, "끝난 지 10분 넘은 묶음을 보여준다"
assert MM._session_chain_summary("claude", "nobody", now=1001.0) is None
print("PASS: 세션 묶음 요약")
PY

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
helpers = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
def block(tag, text=src):
    a, b = text.find(f"// {tag}_START"), text.find(f"// {tag}_END")
    if a < 0 or b < 0: raise SystemExit(f"{tag} 경계 없음")
    return text[a:b]
code = block("ESC_HELPERS", helpers) + block("STATUS_REASON") + block("ROOM_LIST") + block("ROOM_TABS") + block("CHAIN_STRIP")
print("const src = " + json.dumps(code) + ";")
print(r'''
const vm = require("vm"), assert = require("assert/strict");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(src + "\nthis.renderRooms=renderRooms; this.renderChatMenu=renderChatMenu; this.renderChainStrip=renderChainStrip;", ctx);
const room = {root: "/pay", name: "결제", shortName: "결제", status: "작업중", lastAt: 1, chain: {state: "reviewing", round: 1, maxRounds: 2, unlimited: false},
  tabs: [{title: "쿠폰", source: "claude", sid: "impl", primary: true, chainEnabled: true},
         {title: "리뷰어", source: "claude", sid: "role", roleOf: {chainId: "c1", role: "reviewer"}}]};
const html = ctx.renderRooms([room], 10, false, "", "", "/pay", [{id: "claude", label: "Claude"}]);
assert.match(html, /class="roomChainBadge"[^>]*>🔁 리뷰 1\/2/, "배지 없음");
assert.match(html, />대화 1개/, "역할 방을 대화 수에 셌다");
assert.match(html, /class="roleRow"/, "딸린 줄 없음");
assert.ok(!/data-tab="claude:role"/.test(html), "역할 방을 일반 대화 줄로 그렸다");
assert.match(ctx.renderChatMenu("claude:impl", room.tabs[0]), /data-chain-request="claude:impl"/);
assert.ok(!/data-chain-request/.test(ctx.renderChatMenu("claude:x", {title: "x"})), "역할 없는 방에 리뷰 보내기");
const strip = ctx.renderChainStrip({chain: {state: "applying", role: "reviewer", round: 1, maxRounds: 2, unlimited: false}});
assert.match(strip, /리뷰 도는 중/); assert.match(strip, /data-chain-action="unlimited"/); assert.match(strip, /data-chain-action="stop"/);
assert.match(ctx.renderChainStrip({chain: {state: "reviewing", role: "reviewer", round: 3, maxRounds: 2, unlimited: true}}), /class="chipBtn on"[^>]*data-chain-action="unlimited"|data-chain-action="unlimited"[^>]*class="chipBtn on"/);
assert.equal(ctx.renderChainStrip({chain: {state: "done"}}), "");
assert.equal(ctx.renderChainStrip({}), "");
console.log("PASS: 배지·딸린 줄·메뉴·고정 줄");
''')
PY
bash "$HERE/test-mobile-element-refs.sh" >/dev/null && echo "PASS: 엘리먼트 참조"
bash "$HERE/test-room-accordion.sh" >/dev/null && echo "PASS: 기존 아코디언 계약"
SH
chmod +x plugin/tests/test-chain-mobile-ui.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugin/tests/test-chain-mobile-ui.sh`
Expected: FAIL `AttributeError: module 'marina_mobile' has no attribute '_session_chain_summary'`

- [ ] **Step 3: 서버 (`marina_mobile.py`)**

`def mobile_watch_state` 바로 앞에:
```python
def _session_chain_summary(source: str, sid: str, now: float | None = None) -> dict[str, Any] | None:
    """폰에 보일 묶음 요약 — 열린 묶음, 없으면 끝난 지 10분 안의 것(요약 카드용)."""
    try:
        from marina_chains import TERMINAL, last_chain_for, open_chain_for
        chain = open_chain_for(source, sid, "reviewer")
        if chain is None:
            last = last_chain_for(source, sid, "reviewer")
            now = time.time() if now is None else now
            if last and last.get("state") in TERMINAL and now - float(last.get("endedAt") or 0) <= 600:
                chain = last
        if chain is None:
            return None
        return {"id": chain["id"], "role": chain.get("role"), "state": chain.get("state"),
                "round": chain.get("round"), "maxRounds": chain.get("maxRounds"),
                "unlimited": bool(chain.get("unlimited")), "heldCount": len(chain.get("held") or []),
                "roleModel": str((chain.get("roleRoom") or {}).get("model") or ""),
                "endedReason": chain.get("endedReason")}
    except Exception:
        return None
```
`mobile_state` 세션 dict 의 `"pendingQuestion": question,` 다음 줄에 `"chain": _session_chain_summary(source, sid),`.
방 조립에서 `room["tabs"]` 가 확정된 **뒤**(`room["tabs"] = room["tabs"] + extra` 블록이 끝난 곳; 그 블록이 조건문이면 조건문 밖)에:
```python
                # 역할 방 묶음(스펙 7.2) — 역할 방 탭은 딸린 줄로, 방에 열린 묶음이 있으면 배지로.
                try:
                    from marina_chains import TERMINAL, list_chains
                    열린 = [c for c in list_chains() if c.get("state") not in TERMINAL]
                    역할켬 = isinstance(((project_for(Path(room["root"])) or {}).get("roles") or {}).get("reviewer"), dict)
                    room["chain"] = None
                    for tab in room["tabs"]:
                        tab["chainEnabled"] = 역할켬
                        for c in 열린:
                            if (c.get("roleRoom") or {}).get("sid") == tab.get("sid"):
                                tab["roleOf"] = {"chainId": c["id"], "role": c.get("role")}
                            if (c.get("implementer") or {}).get("sid") == tab.get("sid") and room["chain"] is None:
                                room["chain"] = {"state": c["state"], "round": c["round"],
                                                 "maxRounds": c["maxRounds"], "unlimited": bool(c.get("unlimited"))}
                except Exception:
                    pass
```
`project_for` 가 이 파일에 import 돼 있지 않으면 파일 상단 import 목록(`from marina_registry import …` 또는 `marina_sessions` 재수출)에 추가한다.

- [ ] **Step 4: 클라이언트 (`marina_mobile.py` 안 JS)**

`ROOM_LIST` 블록 `renderRooms` 의 방마다 반복에서 `const tabs = room.tabs || [];` 를:
```js
        // 역할 방 탭은 대화가 아니다 — 수에 안 세고 딸린 줄로 그린다(스펙 7.2).
        const tabs = (room.tabs || []).filter(tab => !tab.roleOf);
```
부제줄 배지(`const 배지 = …`) 다음에:
```js
        const 묶음 = room.chain && ["reviewing", "applying", "waiting"].includes(room.chain.state)
          ? `<span class="roomChainBadge">🔁 리뷰 ${esc(String(room.chain.round))}/${room.chain.unlimited ? "∞" : esc(String(room.chain.maxRounds))}</span>`
          : "";
```
그리고 `${배지}` 가 들어간 metaRow 템플릿 자리에 `${배지}${묶음}` 으로 바꾼다.
`ROOM_TABS` 블록 `renderRoomAccordion` 에서 `const tabs = room.tabs || [];` 를 `const tabs = (room.tabs || []).filter(tab => !tab.roleOf); const 역할들 = (room.tabs || []).filter(tab => tab.roleOf);` 로, `strip` 계산 뒤 `const 딸린 = 역할들.map(tab => `<div class="roleRow"><span>↳ 🔍</span><span class="grow">${esc(tab.roleOf.role === "reviewer" ? "리뷰어" : tab.roleOf.role)} <span class="st">· 읽기 전용</span></span><span class="st">진행 중</span></div>`).join("");` 를 두고 반환을 `return 시작줄 + 가름줄 + `<div class="roomTabs">${strip}${딸린}</div>`;` 로.
`renderChatMenu(key, tab)` 반환 템플릿의 `<div class="roomMenu" role="menu">` 바로 뒤에:
```js
        ${tab && tab.chainEnabled ? `<button type="button" role="menuitem" class="hot" data-chain-request="${esc(key)}">🔁 리뷰 보내기</button>` : ""}
```
`// ROOM_TABS_END` 줄 **다음**에 블록(ROOM_TABS 경계 안에 두면 테스트가 같은 함수를 두 번 싣는다):
```js
    // CHAIN_STRIP_START  (테스트가 이 블록을 vm 에 싣는다)
    // 입력창 위 고정 줄 — 대화를 올려봐도 사라지지 않아 언제든 끝까지/멈추기(스펙 7.2).
    function renderChainStrip(session) {
      const c = session && session.chain;
      if (!c || !["reviewing", "applying", "waiting"].includes(c.state)) return "";
      const 바퀴 = `${esc(String(c.round || 1))}/${c.unlimited ? "∞" : esc(String(c.maxRounds || ""))}바퀴`;
      const 단계 = c.state === "applying" ? " · 반영 중" : c.state === "waiting" ? " · 커밋 기다리는 중" : "";
      return `<span>🔁</span><span class="grow"><b>리뷰 도는 중</b> · ${esc(String(c.role || "reviewer"))} · ${바퀴}${단계}</span>`
        + `<button class="chipBtn${c.unlimited ? " on" : ""}" type="button" data-chain-action="unlimited">끝까지</button>`
        + `<button class="chipBtn stop" type="button" data-chain-action="stop">멈추기</button>`;
    }
    // CHAIN_STRIP_END
```
마크업: `<div class="liveQuestion" id="liveQuestion"></div>` 바로 **앞**에 `<div class="chainStrip" id="chainStrip" hidden></div>`.
상수: `const liveQuestionEl = document.getElementById("liveQuestion");` 다음에 `const chainStripEl = document.getElementById("chainStrip");`.
`renderLiveQuestion(session);` (세션 렌더 흐름, ~6391) 다음 줄에:
```js
      { const html = renderChainStrip(session); chainStripEl.hidden = !html; if (chainStripEl.innerHTML !== html) chainStripEl.innerHTML = html; }
```
클릭: `chainStripEl.addEventListener("click", async event => { const b = event.target.closest && event.target.closest("[data-chain-action]"); if (!b) return; const s = selectedSession(); const v = currentTargetValue(); if (!s || !v.startsWith("agent:")) return; const [, source, sid] = v.split(":"); const action = b.getAttribute("data-chain-action"); try { const r = await fetch(`/mobile/api/chain/${action}`, {method: "POST", headers: headers(true), body: JSON.stringify({root: sessionRoot(), source, sid, on: true})}); if (!r.ok) throw new Error(await responseError(r)); showToast(action === "stop" ? "리뷰를 멈췄어요" : "끝까지 돌려요"); load({quiet: true}).catch(() => {}); } catch (error) { showToast(`리뷰 조작 실패 · ${String(error)}`); } });`
위임 핸들러 목록(`[data-tab],[data-rename],…,[data-harness]`)에 `,[data-chain-request]` 를 더하고 `handleRoomAction` 에:
```js
      if (target.hasAttribute("data-chain-request")) {
        const key = target.getAttribute("data-chain-request");
        const source = key.slice(0, key.indexOf(":")), sid = key.slice(key.indexOf(":") + 1);
        const r = await fetch("/mobile/api/chain/request", {method: "POST", headers: headers(true), body: JSON.stringify({root: openRoomRoot, source, sid})});
        const body = await r.json().catch(() => ({}));
        showToast(r.ok && body.ok ? "리뷰어를 불렀어요" : `리뷰 못 보냄 · ${body.reason || body.error || r.status}`);
        await load({force: true});
        return;
      }
```
CSS(`.chainLine` 규칙들 다음):
```css
    .chainStrip { display: flex; align-items: center; gap: 8px; margin: 0 0 6px; padding: 8px 10px; border-radius: 10px;
                  background: #efe9ff; border: 1px solid #d6c9f5; font-size: 12px; color: #43308a; }
    .chainStrip .grow { flex: 1; min-width: 0; }
    .chipBtn { min-height: 0; padding: 4px 9px; border-radius: 999px; border: 1px solid #b9a6e8; background: #fff; color: #43308a; font-size: 11.5px; font-weight: 700; }
    .chipBtn.on { background: #43308a; color: #fff; border-color: #43308a; }
    .chipBtn.stop { border-color: #e3b3b3; color: #a33; }
    .roomChainBadge { flex: 0 0 auto; padding: 2px 7px; border-radius: 999px; background: #efe9ff; color: #43308a; font-size: 11px; font-weight: 800; }
    .roleRow { display: flex; align-items: center; gap: 8px; padding: 8px 11px; border: 1px dashed #cdbff0; border-radius: 9px; background: #faf8ff; color: #5b4a8f; font-size: 12px; }
    .roleRow .grow { flex: 1; min-width: 0; } .roleRow .st { font-size: 11px; opacity: .75; }
    .roomMenu button.hot { background: #efe9ff; color: #43308a; font-weight: 800; }
```
다크 블록:
```css
      .chainStrip { background: #221b38; border-color: #4d3f7a; color: #d7c9ff; }
      .chipBtn { background: #171d27; color: #d7c9ff; border-color: #4d3f7a; }
      .roomChainBadge { background: #2a2145; color: #d7c9ff; }
      .roleRow { background: #1d1830; border-color: #4d3f7a; color: #c9b8f5; }
```

- [ ] **Step 5: Run tests + 390px 확인**

Run: `bash plugin/tests/test-chain-mobile-ui.sh && bash plugin/tests/test-mobile-css-tokens.sh && bash plugin/tests/run-affected.sh HEAD`
Expected: 모두 PASS.
그다음 `docs` 가 아니라 스크래치패드에서 목업과 같은 방식(실 `render_mobile_html()` + `/web/chat-render.js` 서빙 + 격리 컨테이너)으로 A·B·C 장면을 헤드리스 크롬 `--window-size=1320,700` 로 찍고, 각 `.chainStrip`·`.roleRow`·`.chainLine` 의 `scrollWidth <= clientWidth` 를 콘솔로 확인한다.

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_mobile.py plugin/tests/test-chain-mobile-ui.sh
git -c commit.gpgsign=false commit -m "feat(mobile): 리뷰 묶음 화면 — 고정 줄·배지·딸린 줄·리뷰 보내기" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WUPgQTjvcBRefTnvfk167b"
```

---

## P5 — 실측과 마무리

### Task 11: 한 묶음 실측 + 전체 테스트 + 배포 전 멈춤

**Files:**
- Create (스크래치패드, 커밋 안 함): `$SP/chain-live.py`
- 코드 변경 없음(실측에서 버그가 나오면 해당 Task 로 돌아가 테스트부터 추가)

**Interfaces:**
- Consumes: Task 6·7 `chain_trigger`·`on_role_turn_end`, Task 2 `load_role`

- [ ] **Step 1: 전체 테스트**

Run: `bash plugin/tests/run-affected.sh origin/main --deep`
Expected: `PASS=N FAIL=0`

- [ ] **Step 2: 실측 스크립트 작성 (데몬 재시작 없이, 이 워크트리에서, Haiku 역할 방)**

```bash
SP=/private/tmp/claude-501/-Users-sumin-IdeaProjects-sumin-marina--claude-worktrees-chat/916b67c1-2ec2-4751-a125-fd9f2105d494/scratchpad
cat > "$SP/chain-live.py" <<'PY'
import json, os, sys, time
from pathlib import Path
sys.path.insert(0, "plugin/scripts")
import marina_chain_runtime as RT
import marina_chains as C
import marina_roles as R

root = Path.cwd()
me = json.load(open(Path.home() / ".claude/sessions" / f"{os.environ['ME_PID']}.json"))
sid = me["sessionId"]
real_load = R.load_role
RT.load_role = lambda root, role, home=None: {**real_load(root, role, home), "model": "claude-haiku-4-5"}
RT._role_settings = lambda root: {"on": "commit", "maxRounds": 1}
# 실행 중 이 파이썬이 PTY 주인이라 끝날 때까지 산다
res = RT.chain_trigger(root, "claude", sid, "live", force=True)
print("trigger:", res, flush=True)
chain = C.load_chain(res["chain"])
deadline = time.time() + 300
while time.time() < deadline:
    path = RT._role_transcript(chain)
    if path and path.exists() and C.parse_role_result(C.read_rows(path, 0), chain["implementer"]["socket"]):
        break
    time.sleep(3)
chain = RT.on_role_turn_end(C.load_chain(chain["id"]))
print("state:", chain["state"], "findings:", chain["rounds"][-1]["findings"], "held:", chain["held"], flush=True)
if chain["state"] not in C.TERMINAL:
    print("stop:", RT.stop_chain("claude", sid).get("state"), flush=True)
PY
```

- [ ] **Step 3: 실행**

Run: `ME_PID=<이 세션 pid> python3 "$SP/chain-live.py"` (이 세션 pid 는 `~/.claude/sessions/*.json` 중 `cwd` 가 이 워크트리이고 `status` 가 `busy` 인 것)
Expected:
- `trigger: {'ok': True, 'started': True, ...}`
- 이 세션에 `<cross-session-message from-name="…">` 로 리뷰 결과가 도착
- `state: applying` 또는 `done`, `findings` 가 숫자, 역할 방 종료
- `~/.marina/chains/c-*.json` 에 `roleRoom.tid`·`rounds[0].findings`·`endedReason` 기록

- [ ] **Step 4: 정리**

실측 역할 방 프로세스가 남아 있으면 끈다(`ps` 로 `--permission-mode plan` claude 확인 후 SIGHUP). 실측 장부 파일은 남긴다(형이 볼 수 있게). 스크래치패드 스크립트는 커밋하지 않는다.

- [ ] **Step 5: 멈추고 보고 (배포 금지)**

`git log --oneline origin/main..HEAD` 로 쌓인 커밋 목록, 딥 테스트 결과, 실측 결과(장부 요약·도착한 리뷰 메시지 첫 줄), 남은 것(스펙 11절)을 형에게 보고하고 **"커밋 N개 준비됐어 — 배포할까?"** 로 끝낸다. push·캐시 설치·데몬 재시작은 하지 않는다. `projects.json` 에 `roles` 를 넣는 것도 배포와 함께 형 허락 뒤에 한다.
