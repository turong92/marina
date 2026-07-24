# claude·codex 세션 1급화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** marina 워크트리 카드·모바일 채팅이 Claude Code CLI 세션과 codex 세션을 정확히
보여주게 한다 — 발견(카드에 뜸)·렌더(진짜 사용자 메시지만)·상태(작업중/대기중)를 바로잡는다.

**Architecture:** 세 컴포넌트. **A(발견)** `claude_agent_sessions` 에 CLI 트랜스크립트
스캔을 추가하고 진짜 세션 id(파일 stem)를 `cliSessionId` 로 실어 보낸다 — 그러면 기존
`agents_payload` 가 그 진짜 sid 로 상태·preview 를 조회해 **C(상태) 파이프라인이 자동으로
붙는다**(C 는 이미 구현돼 있고 sid 불일치만 문제였다). **B(렌더)** `_transcript_object_turns`
가 주입 메시지(task-notification·system-reminder·isMeta·AGENTS.md·INSTRUCTIONS·
environment_context)를 걸러 진짜 사용자 입력만 turn 으로 낸다.

**Tech Stack:** Python 3.9 (stdlib only), bash 통합 테스트(`plugin/tests/test-*.sh`),
marina 데몬(`marina-control.py`).

## Global Constraints

- 언어/런타임: **Python 3.9, stdlib only**(marina 관례 — 서드파티 import 금지).
- 테스트: `plugin/tests/test-<name>.sh`, `set -euo pipefail`, 가짜 HOME/디렉토리를
  `mktemp -d` 로 만들고 `python3 - <<'PY'` 인라인으로 `marina_sessions` 를 직접 import·호출.
  기존 모델 = `plugin/tests/test-agents-section.sh`(이미 `CLAUDE_PROJECTS_DIR` env +
  `write_transcript` slug 헬퍼 보유).
- 기존 인터페이스 불변: `claude_agent_sessions` 반환 스키마
  `{worktreePath: [{source,title,ts,cliSessionId}]}` 를 유지(A 는 항목을 **추가**만).
  `agents_payload`/`agent_status`/`merge_agent_status` 시그니처 변경 금지.
- 캐시 리듬 존중: `SESSION_TITLES_TTL`(20s), `AGENTS_MAX_AGE`(7일 mtime cutoff) 재사용.
- 구현은 Edit/Write 직접. codex 리뷰는 토큰 여유 시(현재 소진) — 당분간 없이 진행 후 형 검토.
- 커밋: 형 컨벤션 + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- 작업 위치: `chat` 워크트리(`/Users/sumin/IdeaProjects/sumin/marina/.claude/worktrees/chat`).
  절대 `/Users/sumin/IdeaProjects/sumin/marina/plugin`(stale main) 를 편집하지 말 것.

**참조 상수/함수 (chat 브랜치, `plugin/scripts/marina_sessions.py`)**
- `CLAUDE_PROJECTS_DIR`(≈421) = `~/.claude/projects`. `CLAUDE_SESSIONS_DIR`(≈329) = Desktop.
- `_claude_project_slug(root)`(≈431) = `re.sub(r"[/.]", "-", str(root))`.
- `claude_agent_sessions`(≈634), `agents_payload`(≈725), `_transcript_object_turns`(≈835),
  `_texts_of`(≈773), `repo_head_subject(repo)`(트랜스크립트 title 폴백).
- CLI 트랜스크립트 top-level 필드 실측: `cwd`, `sessionId`, `gitBranch`, `aiTitle`, `lastPrompt`.

---

### Task 1: A — Claude CLI 세션 발견 (`_claude_cli_sessions` 헬퍼)

CLI 트랜스크립트(`~/.claude/projects/<slug>/<sid>.jsonl`)에서 세션을 발견하는 순수 헬퍼를
먼저 만든다. `cwd` 필드로 worktree 를 얻고 파일 stem 을 진짜 sid 로 쓴다.

**Files:**
- Modify: `plugin/scripts/marina_sessions.py` (헬퍼 2개 추가: `_read_transcript_cwd`,
  `_claude_cli_sessions`; `claude_agent_sessions` 은 Task 2 에서 병합)
- Test: `plugin/tests/test-claude-cli-discovery.sh` (신규)

**Interfaces:**
- Consumes: `CLAUDE_PROJECTS_DIR`, `AGENTS_MAX_AGE`, `repo_head_subject`(기존).
- Produces:
  - `_read_transcript_cwd(path: Path, max_lines: int = 40) -> str | None` — 트랜스크립트
    앞부분에서 첫 top-level `cwd` 문자열, 없으면 None.
  - `_claude_cli_sessions(now: float, cutoff: float) -> dict[str, list[dict]]` —
    `{worktreePath: [{"source":"claude","title","ts","cliSessionId"(=진짜 sid)}]}`.

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-claude-cli-discovery.sh`

```bash
#!/usr/bin/env bash
# A — Claude Code CLI 트랜스크립트(~/.claude/projects/<slug>/<sid>.jsonl)에서 세션 발견.
# Desktop local_*.json 없이도, cwd 필드로 worktree 매핑 + 파일 stem = 진짜 sid.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PROJ_DIR="$TMP/claude-projects"
WT="$TMP/worktree-a"; mkdir -p "$WT" "$PROJ_DIR"

python3 - "$SCR" "$PROJ_DIR" "$WT" <<'PY'
import sys, os, json, time, re
scr, proj_dir, wt = sys.argv[1:4]
os.environ["CLAUDE_PROJECTS_DIR"] = proj_dir
os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"] = os.path.join(os.path.dirname(proj_dir), "no-desktop")
sys.path.insert(0, scr)
import marina_sessions as ms
from pathlib import Path

# 가짜 CLI 트랜스크립트: slug 디렉토리 + <sid>.jsonl, 라인들에 cwd/aiTitle
slug = re.sub(r"[/.]", "-", wt)
d = Path(proj_dir) / slug; d.mkdir(parents=True, exist_ok=True)
sid = "43d8240a-9462-47e4-9877-52cc758e6a0f"
lines = [
    {"type": "last-prompt"},                     # cwd 없는 선두 라인 — 건너뛰어야
    {"type": "attachment", "cwd": wt, "aiTitle": "세션 제목"},
    {"type": "user", "cwd": wt, "message": {"role": "user", "content": "안녕"}},
]
(d / f"{sid}.jsonl").write_text("\n".join(json.dumps(o) for o in lines) + "\n", encoding="utf-8")

now = time.time()
out = ms._claude_cli_sessions(now, now - ms.AGENTS_MAX_AGE)
key = str(Path(wt))
assert key in out, f"worktree 미발견: {list(out)}"
entry = out[key][0]
assert entry["source"] == "claude", entry
assert entry["cliSessionId"] == sid, f"진짜 sid 아님: {entry['cliSessionId']}"
assert entry["title"] == "세션 제목", entry["title"]
print("OK A-discovery")
PY
echo "PASS test-claude-cli-discovery"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-claude-cli-discovery.sh`
Expected: FAIL — `AttributeError: module 'marina_sessions' has no attribute '_claude_cli_sessions'`

- [ ] **Step 3: 헬퍼 구현** — `plugin/scripts/marina_sessions.py`, `claude_agent_sessions`(≈634) **바로 위**에 추가

```python
def _read_transcript_cwd(path: Path, max_lines: int = 40) -> str | None:
    # CLI 트랜스크립트 앞부분에서 첫 top-level cwd. 선두 메타 라인(last-prompt/mode)엔 없다.
    try:
        with path.open(encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                cwd = o.get("cwd") if isinstance(o, dict) else None
                if isinstance(cwd, str) and cwd:
                    return cwd
    except OSError:
        return None
    return None


def _read_transcript_title(path: Path, max_lines: int = 40) -> str:
    # aiTitle 우선, 없으면 lastPrompt 앞부분. 둘 다 없으면 "".
    title = ""
    try:
        with path.open(encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                if isinstance(o.get("aiTitle"), str) and o["aiTitle"].strip():
                    return o["aiTitle"].strip()[:120]
                if not title and isinstance(o.get("lastPrompt"), str) and o["lastPrompt"].strip():
                    title = o["lastPrompt"].strip()[:120]
    except OSError:
        return title
    return title


def _claude_cli_sessions(now: float, cutoff: float) -> dict[str, list[dict[str, Any]]]:
    # ~/.claude/projects/<slug>/<sid>.jsonl 스캔 → cwd 로 worktree, 파일 stem 으로 진짜 sid.
    by_root: dict[str, list[dict[str, Any]]] = {}
    if not CLAUDE_PROJECTS_DIR.is_dir():
        return by_root
    for raw in glob.iglob(str(CLAUDE_PROJECTS_DIR / "*" / "*.jsonl")):
        path = Path(raw)
        try:
            mtime = os.path.getmtime(raw)
        except OSError:
            continue
        if mtime < cutoff:                      # 7일 필터를 파일 열기 전에 (싸게)
            continue
        cwd = _read_transcript_cwd(path)
        if not cwd:
            continue
        sid = path.stem
        title = _read_transcript_title(path) or repo_head_subject(Path(cwd)) or sid[:8]
        by_root.setdefault(cwd, []).append({
            "source": "claude", "title": title, "ts": mtime, "cliSessionId": sid,
        })
    return by_root
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-claude-cli-discovery.sh`
Expected: `PASS test-claude-cli-discovery`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_sessions.py plugin/tests/test-claude-cli-discovery.sh
git commit -m "feat(agents): discover claude CLI sessions from project transcripts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: A — `claude_agent_sessions` 에 CLI 소스 병합 (진짜 sid 우선)

발견 헬퍼를 실제 카드 소스에 합친다. Desktop 항목과 CLI 항목을 병합하되, 같은 sid 중복은
한 번만, 그리고 CLI 의 진짜 sid 가 카드로 흘러 상태 조회가 되게 한다.

**Files:**
- Modify: `plugin/scripts/marina_sessions.py:634-661` (`claude_agent_sessions`)
- Test: `plugin/tests/test-agents-section.sh` (기존 — CLI-only 케이스 어서션 추가)

**Interfaces:**
- Consumes: `_claude_cli_sessions`(Task 1).
- Produces: `claude_agent_sessions` 이 Desktop+CLI 병합 dict 반환(스키마 불변).

- [ ] **Step 1: 실패 테스트 추가** — `plugin/tests/test-agents-section.sh` 의 백엔드 단위
      블록(`write_transcript` 정의 뒤, `PY` 종료 전) 안에 아래 어서션을 추가

```python
# CLI-only 세션(Desktop local_*.json 없음)이 진짜 sid 로 잡히는지 — A 회귀
cli_sid = "aaaabbbb-1111-2222-3333-444455556666"
write_transcript(wt, cli_sid, [
    json.dumps({"type": "attachment", "cwd": wt, "aiTitle": "CLI 세션"}),
    json.dumps({"type": "user", "message": {"role": "user", "content": "hi"}}),
])
os.utime(Path(proj_dir) / re.sub(r"[/.]", "-", wt) / f"{cli_sid}.jsonl", (now, now))
claude = ms.claude_agent_sessions(refresh=True)
entry = next((e for e in claude.get(wt, []) if e["cliSessionId"] == cli_sid), None)
assert entry is not None, f"CLI-only 세션 미발견: {claude.get(wt)}"
assert entry["title"] == "CLI 세션", entry
print("OK A-merge cli-only")
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-agents-section.sh`
Expected: FAIL — `AssertionError: CLI-only 세션 미발견`

- [ ] **Step 3: `claude_agent_sessions` 병합 구현** — 캐시 저장 직전(`_claude_agents_cache = ...` 위)에 삽입

```python
    # CLI 트랜스크립트 소스 병합 — Desktop local_*.json 이 없는 순수 CLI 세션도 잡는다.
    # 진짜 sid(파일 stem)를 cliSessionId 로 실어 agents_payload 가 상태/preview 를 진짜 sid 로 조회.
    for wt, cli_entries in _claude_cli_sessions(now, cutoff).items():
        existing = by_root.setdefault(wt, [])
        seen = {str(e.get("cliSessionId") or "") for e in existing}
        for entry in cli_entries:
            if entry["cliSessionId"] not in seen:      # Desktop 이 같은 sid 를 이미 가지면 skip
                existing.append(entry)
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-agents-section.sh`
Expected: 기존 어서션 + `OK A-merge cli-only` 모두 PASS

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_sessions.py plugin/tests/test-agents-section.sh
git commit -m "feat(agents): merge CLI sessions into card source with real sid

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: C 검증 — 진짜 sid 로 상태가 붙는지 (sid 정합성 회귀)

C 파이프라인(`marina_agent_events` + `merge_agent_status`)은 이미 있다. Task 1-2 로 진짜
sid 가 공급되면 `agents_payload` 가 그 sid 로 이벤트를 조인해 상태를 반영해야 한다. **신규
프로덕션 코드 없음** — 조인이 실제로 되는지 회귀 테스트만 건다.

**Files:**
- Test: `plugin/tests/test-agents-section.sh` (기존 — status 어서션 추가)

**Interfaces:**
- Consumes: `agents_payload`(기존), `marina_agent_events.record_hook_event`/journal 포맷,
  `_claude_cli_sessions`(Task 1).

- [ ] **Step 1: 상태 조인 테스트 추가** — Task 2 어서션 뒤에

```python
# C 정합성: 진짜 sid 로 working 이벤트를 남기면 카드 상태가 working 이어야 한다.
import marina_agent_events as mae
ev_home = Path(TMP) / "evhome"; (ev_home / ".marina").mkdir(parents=True, exist_ok=True)
mae.record_hook_event(
    {"session_id": cli_sid, "hook_event_name": "UserPromptSubmit", "cwd": wt},
    home=ev_home,
)
os.environ["HOME"] = str(ev_home)   # agents_payload 의 event_home=Path.home()
payload = ms.agents_payload(Path(wt), refresh=True)
row = next((p for p in payload if p.get("sid") == cli_sid), None)
assert row is not None, f"카드에 CLI 세션 행 없음: {payload}"
assert row.get("status") == "working", f"상태 미반영: {row.get('status')}"
print("OK C-join working status")
```

> 주: `record_hook_event` 의 정확한 시그니처(`home=` 키워드, 필요한 stdin 키
> `session_id`/`hook_event_name`/`cwd`)는 구현 착수 시 `marina_agent_events.py` 와
> `tests/test-agent-events.sh` 로 확인해 이 스텝의 호출을 맞춘다(여기 값은 그 계약 기준 초안).

- [ ] **Step 2: 실행 — 조인 성립 확인**

Run: `bash plugin/tests/test-agents-section.sh`
Expected: `OK C-join working status` PASS. 만약 FAIL 이면 `record_hook_event` 계약(키워드/
키 이름)을 실제 코드에 맞춰 테스트 호출을 수정(프로덕션 코드는 손대지 않는다).

- [ ] **Step 3: 커밋**

```bash
git add plugin/tests/test-agents-section.sh
git commit -m "test(agents): assert real-sid event join surfaces working status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: B — 주입 메시지 필터 (`_is_injected_user` 헬퍼)

`_transcript_object_turns` 가 진짜 사용자 입력만 user turn 으로 내게 한다. 주입 판별을
순수 헬퍼로 분리해 테스트한다.

**Files:**
- Modify: `plugin/scripts/marina_sessions.py` (`_is_injected_user` 추가 + `_transcript_object_turns` 호출)
- Test: `plugin/tests/test-transcript-inject-filter.sh` (신규)

**Interfaces:**
- Produces: `_is_injected_user(obj: dict, source: str, texts: list[str]) -> bool` —
  True 면 이 user 라인을 turn 에서 제외.
- Modifies: `_transcript_object_turns` — role==user 이고 `_is_injected_user` True 면 `[]` 반환.

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-transcript-inject-filter.sh`

```bash
#!/usr/bin/env bash
# B — 주입 메시지(task-notification·system-reminder·isMeta·AGENTS.md·INSTRUCTIONS·
# environment_context)는 user turn 에서 빠지고, 진짜 사용자 입력만 남는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
python3 - "$SCR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

def turns(obj, source):
    return ms._transcript_object_turns(obj, source)

# claude: 진짜 입력 통과
real = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "야 이거 고쳐줘"}]}}
assert [t["text"] for t in turns(real, "claude")] == ["야 이거 고쳐줘"]

# claude: task-notification 제외
notif = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<task-notification>\n<task-id>x</task-id>"}]}}
assert turns(notif, "claude") == [], "task-notification 새어나감"

# claude: system-reminder 단독 제외
sysrem = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<system-reminder>\nblah"}]}}
assert turns(sysrem, "claude") == [], "system-reminder 새어나감"

# claude: isMeta 제외
meta = {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": "Continue from where you left off"}]}}
assert turns(meta, "claude") == [], "isMeta 새어나감"

# codex: 진짜 입력 통과
creal = {"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "오르카랑 비교해줘"}]}}
assert [t["text"] for t in turns(creal, "codex")] == ["오르카랑 비교해줘"]

# codex: AGENTS.md 주입 제외
cinj = {"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions\n<INSTRUCTIONS>..."}]}}
assert turns(cinj, "codex") == [], "AGENTS.md 주입 새어나감"

print("OK B-inject-filter")
PY
echo "PASS test-transcript-inject-filter"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-transcript-inject-filter.sh`
Expected: FAIL — 첫 `AttributeError: ... '_is_injected_user'` 또는 어서션(`task-notification 새어나감`)

- [ ] **Step 3: 헬퍼 + 호출 구현** — `_transcript_object_turns`(≈835) **바로 위**에 헬퍼, 함수 안에 게이트

```python
# 사용자 라인 중 하네스/도구가 주입한 것 — 진짜 입력이 아니라 turn 에서 뺀다.
_CLAUDE_INJECT_PREFIXES = ("<task-notification>", "<system-reminder>",
                           "[SYSTEM NOTIFICATION")
_CODEX_INJECT_PREFIXES = ("# AGENTS.md instructions", "<INSTRUCTIONS>",
                          "<user_instructions>", "<environment_context>")


def _is_injected_user(obj: dict[str, Any], source: str, texts: list[str]) -> bool:
    if source == "claude" and obj.get("isMeta"):
        return True
    prefixes = _CLAUDE_INJECT_PREFIXES if source == "claude" else _CODEX_INJECT_PREFIXES
    # 모든 텍스트 블록이 주입 래퍼로 시작하면 주입 라인(혼합이면 진짜 입력이 섞인 것 → 보존).
    return bool(texts) and all(t.lstrip().startswith(prefixes) for t in texts)
```

그리고 `_transcript_object_turns` 안, `for index, text in enumerate(_texts_of(content)):`
**직전**에 게이트를 넣는다:

```python
    texts = _texts_of(content)
    if role == "user" and _is_injected_user(obj, source, texts):
        return []
    turns: list[dict[str, str]] = []
    for index, text in enumerate(texts):
```

(기존 `for index, text in enumerate(_texts_of(content)):` 를 위 `texts` 변수 사용으로 교체 —
`_texts_of` 를 두 번 호출하지 않게.)

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-transcript-inject-filter.sh`
Expected: `PASS test-transcript-inject-filter`

- [ ] **Step 5: 실 rollout 회귀** — 이 세션·codex 세션 축약 픽스처가 있으면 함께 검증
      (없으면 Step 3 유닛으로 충분). 커밋:

```bash
git add plugin/scripts/marina_sessions.py plugin/tests/test-transcript-inject-filter.sh
git commit -m "fix(agents): drop injected user messages from chat timeline

task-notification·system-reminder·isMeta(claude)·AGENTS.md·INSTRUCTIONS(codex)
주입 라인을 user turn 에서 제외 — 진짜 사용자 입력만 남긴다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: e2e 실측 (실 데몬 + 모바일 뷰)

유닛을 넘어 실제로 이 세션이 카드에 뜨고 상태가 반영되는지, 모바일 타임라인이 깨끗한지
확인한다. 코드 변경 없음 — 검증 단계.

**Files:** 없음(수동/스크립트 검증).

- [ ] **Step 1: 전체 테스트 스위트**

Run: `bash plugin/tests/test-agents-section.sh && bash plugin/tests/test-claude-cli-discovery.sh && bash plugin/tests/test-transcript-inject-filter.sh && bash plugin/tests/test-agent-events.sh`
Expected: 전부 PASS(회귀 없음).

- [ ] **Step 2: 실 데몬 재시작 후 카드 확인**

marina 대시보드를 재기동(또는 자동 리로드)하고 `chat` 워크트리 카드에 현재 claude
세션(진짜 sid)이 뜨는지, 상태 배지가 working/대기중으로 붙는지 확인.
Run(payload 직접): `curl -s localhost:3900/api/worktrees | python3 -m json.tool | grep -A3 agents`
Expected: `chat` 워크트리 항목에 `"source":"claude"` + `"status"` 존재.

- [ ] **Step 3: 모바일 타임라인 실측 (Aside)**

marina-preview 로 서버 확인 후, Aside 로 모바일 채팅을 열어 타임라인에 형 실제 메시지만
말풍선으로 뜨고 task-notification/system-reminder 잡동사니가 사라졌는지 확인
(글로벌 지침: e2e 는 Aside 우선).

- [ ] **Step 4: 최종 상태 커밋(있으면)** — 문서/메모 갱신만. 프로덕션 코드 변경 없음.

---

## Self-Review 결과 (계획 작성자 체크)

- **Spec 커버리지**: A(발견)=Task1-2, B(렌더)=Task4, C(상태)=Task3(검증), 데이터흐름/전제=Task5.
  스펙의 "codex 발견 이미 됨/변경없음"·"PTY 소유 부가"는 무작업이라 태스크 없음(의도적).
- **Placeholder 스캔**: 실코드/실명령 채움. 유일한 유보 = Task3 의 `record_hook_event` 계약은
  착수 시 실코드로 확정(테스트 전용, 프로덕션 무영향)하도록 명시.
- **타입 일관성**: `_claude_cli_sessions`→`claude_agent_sessions`→`agents_payload` 의
  `cliSessionId`(=진짜 sid) 흐름 일치. `_is_injected_user(obj, source, texts)` 시그니처가
  Task4 호출과 일치.
