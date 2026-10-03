# 역할 에이전트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 역할 5개(기획·디자인·개발·QA·리뷰)를 정본 파일로 고정하고, 부를 때마다 무엇이 어떤 모델로 돌았는지 Discord 에 남기고, 역할별 사용량을 #상태에 보인다.

**Architecture:** `~/IdeaProjects/sumin/shared/`(로컬 git) 에 역할 정본·`role-hook`·`/team` 스킬 — 사용자 범위 훅으로 모든 세션에 적용, 이벤트를 `~/.local/state/roles/events.jsonl` 에 쓴다. marina-discord 봇 루프가 그 파일만 읽어 지시 스레드 한 줄·#상태 블록을 그린다(역할 코드 import 없음).

**Tech Stack:** Claude Code 서브에이전트 frontmatter(model·effort·skills·tools), 훅(PreToolUse·SubagentStart·SubagentStop), python3(훅: 셸 python, 봇: 데몬 3.9), bash 테스트(`plugin/tests/lib/harness.sh`).

**Spec:** `docs/superpowers/specs/2026-10-04-role-agents-design.md`

## Global Constraints
- 역할표(스펙 4.1): planner opus/high, designer sonnet/medium, developer sonnet/medium, qa haiku/low, code-reviewer opus/high. Codex 없음.
- 훅은 1초 안, 실패해도 도구를 막지 않는다(`|| true`). 역할 호출의 `model` 인자만 지운다.
- 봇 코드는 python 3.9(`from __future__ import annotations`, test-py39-compat). 테스트는 harness 격리 — 실제 `~/.local/state/roles`·Discord 를 안 건드린다(`ROLE_EVENTS` env 로 경로 주입).
- **Ruling(계획): Discord 쪽은 지금 배포된 main 기반 워크트리(`claude/fix-status-subagents`, plugin/scripts/)에 넣는다** — 분리 브랜치는 배포 보류라 거기 넣으면 형이 못 본다. 비용: 분리 배포 때 668c7e1·2323196·64a93d9 와 함께 plugin-discord/ 로 옮길 커밋이 하나 더 는다.
- **Ruling(계획): 주간 = 사용량 API 의 weekly `resetsAt` − 7일, 못 구하면 최근 7일.**
- push·배포는 형 허락. shared/ 는 로컬 git, push 없음.

## Review Focus
1. 훅 payload 실제 필드가 문서와 다를 때(특히 SubagentStart 에 description 없음, transcript 경로가 부모 것) — Task 1 실측으로 고정하고 Task 2 테스트가 그 실측 payload 를 쓴다.
2. 같은 agent_id 의 start 없이 stop 만 오는 경우(훅 등록 전에 뜬 에이전트) — 걸린 시간 없이 토큰만 남긴다.
3. 이벤트 파일이 크거나 깨진 줄 — 봇은 오프셋부터만 읽고 깨진 줄은 건너뛴다.
4. Discord 세션이 아닌 세션의 이벤트 — 파일에만, 스레드 게시 없음. 지시 메시지(mid)가 없으면 게시 안 함.
5. 역할 이름과 같은 general-purpose 등 비역할 — 역할 `-` 로 기록, 모델 인자는 건드리지 않는다.

---

### Task 1: 실측 — 훅 payload·frontmatter 효과
**Files:** 스크래치만(`$SCRATCH/role-probe/`), 결과는 ledger 에 기록.
- [ ] Step 1: 스크래치에 `.claude/agents/probe-dev.md`(`model: haiku`, `effort: low`, `skills: [superpowers:test-driven-development]`, 본문 "Reply with the word PROBE and stop.") + settings.json 훅 3개(PreToolUse matcher `Agent`, SubagentStart, SubagentStop) 가 stdin 을 `$SCRATCH/role-probe/payloads.jsonl` 에 덧붙이게.
- [ ] Step 2: `cd $SCRATCH/role-probe && env -u CLAUDECODE claude -p --settings settings.json "Use the Agent tool with subagent_type probe-dev and model opus, description 'probe task', prompt 'go'. Then stop."`
- [ ] Step 3: 기록: payloads.jsonl 의 세 이벤트 필드 목록, 서브에이전트 기록 파일 위치와 `message.model`(haiku 면 frontmatter 가 이긴 것, opus 면 인자가 이긴 것), meta.json 의 description, skills 가 실렸는지(서브 기록 첫 user 메시지에 스킬 본문).
Expected: 필드 목록이 ledger 에 있다. 이후 Task 2 의 테스트 payload 는 이 실측 모양을 쓴다(Ruling 으로 기록).

### Task 2: role-hook (shared)
**Files:**
- Create: `~/IdeaProjects/sumin/shared/bin/role-hook` (python3, 실행 권한)
- Create: `~/IdeaProjects/sumin/shared/bin/test_role_hook.py` (unittest)
- `git init` `~/IdeaProjects/sumin/shared` (첫 커밋에 기존 파일 포함)

**Interfaces — Produces:**
- `role-hook pre|start|stop` — stdin 훅 payload, stdout 훅 응답(pre 만).
- 이벤트 줄(JSON, 한 줄): `{"ev": "start"|"stop"|"override_blocked", "ts": float, "session": str, "agent": str, "role": str ("-" 비역할), "model": str, "effort": str, "skills": [str], "desc": str}`; stop 은 추가로 `"secs": float|null, "tokens": {"in": int, "out": int, "cache_read": int, "cache_write": int}, "models": [str]`.
- 이벤트 경로: `$ROLE_EVENTS` 또는 `~/.local/state/roles/events.jsonl`. 역할 폴더: `$ROLE_AGENTS` 또는 `~/IdeaProjects/sumin/shared/agents`.

- [ ] Step 1: 실패하는 테스트 — `test_role_hook.py`:
```python
import json, os, subprocess, tempfile, time, unittest
from pathlib import Path
HOOK = Path(__file__).with_name("role-hook")
class T(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        (self.d / "agents").mkdir()
        (self.d / "agents" / "developer.md").write_text("---\nname: developer\ndescription: x\nmodel: sonnet\neffort: medium\nskills: [superpowers:test-driven-development]\n---\nbody\n")
        self.env = dict(os.environ, ROLE_EVENTS=str(self.d / "ev.jsonl"), ROLE_AGENTS=str(self.d / "agents"))
    def run_hook(self, mode, payload):
        r = subprocess.run([str(HOOK), mode], input=json.dumps(payload), text=True, capture_output=True, env=self.env, timeout=5)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout
    def events(self):
        p = self.d / "ev.jsonl"
        return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
    def test_pre_strips_model_for_role(self):
        out = json.loads(self.run_hook("pre", {"session_id": "S", "tool_name": "Agent",
              "tool_input": {"subagent_type": "developer", "model": "opus", "prompt": "p", "description": "d"}}))
        upd = out["hookSpecificOutput"]["updatedInput"]
        self.assertNotIn("model", upd); self.assertEqual(upd["prompt"], "p")
        self.assertEqual(self.events()[-1]["ev"], "override_blocked")
    def test_pre_leaves_non_role_alone(self):
        self.assertEqual(self.run_hook("pre", {"tool_name": "Agent", "tool_input": {"subagent_type": "general-purpose", "model": "opus"}}).strip(), "")
    def test_start_stop_records_role_and_tokens(self):
        tr = self.d / "proj" / "S.jsonl"; sub = tr.parent / "S" / "subagents"; sub.mkdir(parents=True); tr.write_text("")
        (sub / "agent-a1.meta.json").write_text(json.dumps({"description": "결제 버그 Task 3", "agentType": "developer"}))
        (sub / "agent-a1.jsonl").write_text("\n".join(json.dumps({"type": "assistant", "message": {"model": "claude-sonnet-5-5",
            "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 7}}}) for _ in range(2)) + "\n")
        base = {"session_id": "S", "transcript_path": str(tr), "agent_id": "a1", "agent_type": "developer"}
        self.run_hook("start", base); self.run_hook("stop", base)
        st, sp = self.events()
        self.assertEqual((st["ev"], st["role"], st["model"], st["effort"], st["desc"]), ("start", "developer", "sonnet", "medium", "결제 버그 Task 3"))
        self.assertEqual(sp["tokens"], {"in": 20, "out": 10, "cache_read": 200, "cache_write": 14})
        self.assertEqual(sp["models"], ["claude-sonnet-5-5"]); self.assertIsNotNone(sp["secs"])
    def test_stop_without_start_and_non_role(self):
        tr = self.d / "p" / "S.jsonl"; tr.parent.mkdir(); tr.write_text("")
        self.run_hook("stop", {"session_id": "S", "transcript_path": str(tr), "agent_id": "zz", "agent_type": "general-purpose"})
        e = self.events()[-1]
        self.assertEqual((e["role"], e["secs"], e["tokens"]["in"]), ("-", None, 0))
    def test_garbage_payload_never_fails(self):
        for m in ("pre", "start", "stop"):
            r = subprocess.run([str(HOOK), m], input="not json", text=True, capture_output=True, env=self.env, timeout=5)
            self.assertEqual(r.returncode, 0)
if __name__ == "__main__":
    unittest.main()
```
- [ ] Step 2: `python3 ~/IdeaProjects/sumin/shared/bin/test_role_hook.py` → Expected: FAIL(role-hook 없음).
- [ ] Step 3: `role-hook` 구현 — frontmatter 는 `---` 사이 `key: value` 줄만(리스트는 `[a, b]` 한 줄) 파싱(PyYAML 금지 — 메모리 marina-test-python-pyyaml); 서브에이전트 기록 = `transcript_path` 의 `<부모폴더>/<session_id>/subagents/agent-<agent_id>.{jsonl,meta.json}`(Task 1 실측과 다르면 실측대로 + Ruling); secs = stop.ts − 같은 agent 의 start.ts(파일 끝 200KB 에서 찾기); 모든 예외는 삼키고 exit 0.
- [ ] Step 4: 테스트 → Expected: 5 passed.
- [ ] Step 5: `cd ~/IdeaProjects/sumin/shared && git init -q && git add -A && git commit -qm "feat: role-hook — 역할 모델 고정·서브에이전트 시작/끝 기록"`

### Task 3: 역할 정본 + 연결 + 사용자 훅 등록
**Files:**
- Create: `shared/agents/{planner,designer,developer,qa}.md`; Modify: `shared/agents/code-reviewer.md` frontmatter `model: opus`, `effort: high` 추가.
- Symlink: `~/.claude/agents/<역할>.md` → 정본.
- Modify: `~/.claude/settings.json` hooks: PreToolUse(matcher `Agent`) `role-hook pre`, SubagentStart `role-hook start || true`, SubagentStop `role-hook stop || true` (기존 훅 보존 — jq 가 아니라 python 으로 병합, 수정 전 백업 `settings.json.bak-roles`).
- Test: `shared/bin/test_role_agents.py`

정본 본문 요점(각 파일에 그대로 쓴다):
- planner: 요구를 스펙 초안(목적·범위·비목표·검증)과 작업 목록으로. **형에게 묻지 않는다** — 모르는 건 끝에 `## 정해야 할 것` 목록(선택지 2~4개, 추천 표시). 코드 수정 금지, 문서만 `docs/` 아래.
- designer: 화면·흐름. 형 취향(메모리 marina-dashboard-ux-preferences: 컴팩트·아이콘화·상태별 컨트롤·뷰포트 안전 툴팁)을 따른다. 결과는 HTML 목업 파일 경로 + `## 정해야 할 것`.
- developer: 받은 작업 하나만. TDD(실패 테스트 먼저), 범위 밖 수정 금지, 끝에 실행한 테스트 명령과 결과 원문. 커밋은 지시가 있을 때만.
- qa: 브라우저(aside-browser 스킬)로 실제 흐름을 눌러 보고 스크린샷 경로·재현 단계·기대 vs 실제. 코드 수정 금지.
- tools: planner `Read, Grep, Glob, Write, Edit, WebSearch, WebFetch`; designer 같음; developer 생략(전부); qa `Read, Grep, Glob, Bash`; reviewer 기존.

- [ ] Step 1: 실패하는 테스트 — 정본 5개가 있고 frontmatter 가 역할표와 같고(`{"planner": ("opus","high"), "designer": ("sonnet","medium"), "developer": ("sonnet","medium"), "qa": ("haiku","low"), "code-reviewer": ("opus","high")}`), 각 `~/.claude/agents/<역할>.md` 가 정본을 가리키는 심볼릭 링크고, `~/.claude/settings.json` 에 role-hook 3개가 있는지.
- [ ] Step 2: 실행 → FAIL.
- [ ] Step 3: 파일·링크·설정 병합.
- [ ] Step 4: 실행 → PASS. `python3 -c "import json;json.load(open('$HOME/.claude/settings.json'))"` 로 설정이 깨지지 않았는지.
- [ ] Step 5: shared 커밋 `feat: 역할 정본 5개`.

### Task 4: `/team` 지휘 스킬
**Files:** Create `shared/skills/team/SKILL.md`; symlink `~/.claude/skills/team` → `shared/skills/team`.
- 내용: 스펙 4.4 를 그대로 — 크기 판정(판정 이유 한 줄을 progress 로), 경로 셋, 되돌림 3바퀴(지적 원문 그대로 developer 에), 멈춤 조건(기획·디자인 확정·push/배포·3바퀴 초과), planner/designer 의 `## 정해야 할 것` 은 AskUserQuestion 버튼으로 형에게. 역할 호출엔 `model` 을 넘기지 않는다(훅이 지운다는 사실 명시).
- [ ] Step 1: 테스트(`test_role_agents.py` 에 추가) — SKILL.md frontmatter name=team, description 있음, 다섯 역할 이름이 본문에 다 나옴, 링크.
- [ ] Step 2: FAIL → Step 3 작성 → Step 4 PASS → Step 5 shared 커밋 `feat: /team 지휘 스킬`.

### Task 5: Discord — 지시 스레드에 시작·끝 한 줄 (main 기반 `fix-status-subagents` 워크트리)
**Files:**
- Modify: `plugin/scripts/marina_discord_bot.py` — `role_events_tick()` + `Loop.view` 에서 호출(try/except).
- Test: `plugin/tests/test-discord-role-events.sh`

**Interfaces — Consumes:** Task 2 이벤트 줄. `ms._progress(rec, {"message_id": mid, "text": line})`(기존), `ms._activity_state(sd)["mid"]`(기존, 지금 처리 중인 지시 메시지).
**Produces:** `role_events_tick() -> None`, 오프셋 `~/.marina/role-events.offset`, `_fmt_role_event(ev) -> str`.

- 줄 형식: 시작 `🤖 developer 시작 · sonnet/medium · TDD · 결제 버그 Task 3`(스킬은 `:` 뒤 이름, 비역할은 `🤖 general-purpose 시작 · 할 일`), 끝 `✅ developer 끝 · 4분 · 52k`(토큰 = in+out+cache_write, 천 단위 k), 차단 `⚠️ developer 모델 지정(opus) 무시 — 역할표대로 sonnet`.
- 이벤트 session 이 `ms.load_sessions()` 의 sessionId 와 같고 그 세션 activity 에 mid 가 있을 때만 게시. 오프셋은 바이트, 파일이 줄었으면(회전) 0 부터. 한 번에 최대 20줄.
- [ ] Step 1: 실패하는 테스트 — 가짜 Discord, 세션 하나(sessionId S, activity mid M1), `ROLE_EVENTS` 에 start/stop/override/다른 세션 이벤트/깨진 줄 → tick → 스레드 POST 3개(형식 확인), 다른 세션 없음; 다시 tick → 추가 POST 없음(오프셋); mid 없으면 게시 안 하되 오프셋은 전진.
- [ ] Step 2: `bash plugin/tests/test-discord-role-events.sh` → FAIL.
- [ ] Step 3: 구현.
- [ ] Step 4: PASS + test-py39-compat.
- [ ] Step 5: 커밋 `feat(discord): 서브에이전트 시작·끝을 지시 스레드에`.

### Task 6: #상태 역할별 사용량
**Files:** Modify `plugin/scripts/marina_discord_bot.py` — `role_usage(since: float) -> list[dict]`, `render` 에 블록; Test: `plugin/tests/test-discord-role-usage.sh`.
- 집계: stop 이벤트를 role 별로 호출 수·토큰 합·모델. since = weekly resetsAt − 7일(사용량 창에서), 없으면 now − 7일. 블록: `### 🤖 이번 주 역할별` + 줄 `` `developer   12회  1.2M` sonnet `` (토큰 많은 순, 최대 6줄, 비역할은 `기타` 로 합침). 이벤트 없으면 블록 생략. 40 구성요소 한도 안(텍스트 1개).
- [ ] Step 1: 실패하는 테스트(이벤트 몇 개 → render 텍스트에 블록·순서·기타 합침, since 이전 것 제외, 이벤트 없으면 블록 없음).
- [ ] Step 2: FAIL → Step 3 구현 → Step 4 PASS + py39 + `run-affected.sh origin/main --deep` → Step 5 커밋 `feat(discord): #상태 역할별 사용량`.

### Task 7: 실측 + 최종 리뷰 + 배포 준비
- [ ] 이 세션에서 `developer` 를 `model: opus` 로 한 번 불러(아주 작은 일) → 서브 기록 message.model 이 sonnet 인지, events.jsonl 에 override_blocked·start·stop.
- [ ] (배포 후) Discord 지시 스레드에 시작·끝 줄, #상태 블록 확인.
- [ ] code-reviewer(이제 opus 고정) 로 shared 커밋들 + main 워크트리 diff 리뷰 → Critical/Important 수정.
- [ ] 형에게 보고, main push·배포는 형 허락.
