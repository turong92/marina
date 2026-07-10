# 팀 사용성 페인포인트 해소 구현 플랜

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 엮기 선언을 x-marina.forward 로 일원화(레거시 hostForward 도 제대로 읽기)하고, LLM 에이전트가 등록 프로젝트에서 dev 서버를 직접 띄우면 PreToolUse 훅으로 차단해 marina 로 안내한다.

**Architecture:** Part A 는 `marina-compose.py` 의 `_normalize_forward` 확장 + 경고문/요약출력/README. Part B 는 새 PreToolUse 훅(셸 래퍼 + 파이썬 판정기, fail-open) + SessionStart 훅 보강(금지 문구·미등록 힌트) + 플러그인 스킬 1개. 스펙: `docs/superpowers/specs/2026-07-10-team-adoption-fixes-design.md`.

**Tech Stack:** bash + python3 (기존 marina 스크립트 관례), plugin/tests/*.sh 단위 테스트 (각각 `bash plugin/tests/test-X.sh` 로 실행, PASS/FAIL 출력).

**작업 디렉토리:** 이 worktree (`.claude/worktrees/upbeat-shtern-c27104`), 브랜치 `claude/orca-marina-comparison-c1fec7`. push 는 형 검토 후 (팀 규약).

---

### Task 1: A2 — 경고문이 레거시(backing.json)로 유도하는 것 수정

**Files:**
- Modify: `plugin/scripts/marina-compose.py:617-618`

- [ ] **Step 1: 경고 문구 교체**

현재 (marina-compose.py 617-618):

```python
        sys.stderr.write("warning: backing.json 의 옛 service-redirect endpoints 는 이제 무시됩니다(엮기로 일원화). "
                         "host 타겟(redis/db 등)은 backing.json top-level forward 로 선언하세요 — 서비스↔서비스는 자동.\n")
```

교체:

```python
        sys.stderr.write("warning: backing.json 의 옛 service-redirect endpoints 는 이제 무시됩니다(엮기로 일원화). "
                         "host 타겟(redis/db 등)은 x-marina.forward 로 선언하세요 — 서비스↔서비스는 자동.\n")
```

- [ ] **Step 2: 회귀 확인**

Run: `bash plugin/tests/test-compose-forward.sh && bash plugin/tests/test-compose-overlay.sh`
Expected: 둘 다 `PASS ...` (이 문구를 검증하는 테스트는 없음 — 회귀만 확인)

- [ ] **Step 3: Commit**

```bash
git add plugin/scripts/marina-compose.py
git commit -m "fix(marina): 엮기 경고문이 레거시 backing.json 으로 유도하던 것 → x-marina.forward 안내"
```

---

### Task 2: A3 — top-level hostForward 를 제대로 읽기 (+ 조용한 무시 제거)

README 가 안내해 온 `hostForward: ["6379"]` 포맷을 코드가 무시하던 것을 복원한다. 마이그레이션 없음(형 결정) — 읽기만 고친다.

**Files:**
- Modify: `plugin/scripts/marina-compose.py:496-510` (`_normalize_forward`)
- Modify: `plugin/scripts/marina-compose.py` cmd_up 의 경고 블록 (615-618 근방)
- Test: `plugin/tests/test-compose-forward.sh`, `plugin/tests/test-compose-overlay.sh:60-61`

- [ ] **Step 1: 실패하는 테스트로 바꾸기**

`plugin/tests/test-compose-forward.sh` 의 두 줄:

```python
assert mc._normalize_forward({"forward":{"8081":"be"},"hostForward":["6379"]})=={"8081":"be"}                              # legacy hostForward 무시
assert mc._normalize_forward({"services":{"app":{"hostForward":["6379"]}}})=={}                                             # legacy service hostForward 무시
```

를 다음으로 교체:

```python
assert mc._normalize_forward({"forward":{"8081":"be"},"hostForward":["6379"]})=={"8081":"be","6379":"host"}                # top-level hostForward 반영(README 포맷)
assert mc._normalize_forward({"services":{"app":{"hostForward":["6379"]}}})=={}                                             # 서비스별 hostForward 는 미지원(경고는 cmd_up)
assert mc._normalize_forward({"hostForward":["6379","abc","3306"]})=={"6379":"host","3306":"host"}                          # 숫자 아닌 항목 무시
assert mc._normalize_forward({"forward":{"6379":"redis"},"hostForward":["6379"]})=={"6379":"redis"}                         # 같은 포트 → forward 가 이김
assert mc._normalize_forward({"hostForward":"6379"})=={}                                                                    # 리스트 아니면 무시(방어)
```

`plugin/tests/test-compose-overlay.sh` 60줄:

```python
assert mc._normalize_forward({"hostForward":["6379","3306"]})=={}                               # legacy top-level hostForward 무시
```

를 다음으로 교체 (61줄 서비스별 케이스는 그대로 둠):

```python
assert mc._normalize_forward({"hostForward":["6379","3306"]})=={"6379":"host","3306":"host"}    # top-level hostForward 반영(README 포맷)
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-compose-forward.sh`
Expected: FAIL — `AssertionError` (hostForward 가 아직 빈 dict)

- [ ] **Step 3: `_normalize_forward` 구현**

`plugin/scripts/marina-compose.py:496` 의 함수 전체를 교체:

```python
def _normalize_forward(conn: dict) -> dict:
    """backing.json/x-marina 의 forward 선언 → {port(str): target(str)}. target="host"(host.docker.internal) 또는 같은 compose 서비스명(DNS).
    소스: top-level forward({port:{target:svc|host}} 또는 {port:"svc"|"host"}) + legacy top-level hostForward(["6379"] → {"6379":"host"}).
    hostForward 는 README 가 안내해 온 포맷이라 계속 읽는다(조용한 무시 금지) — 같은 포트가 forward 에도 있으면 forward 가 이긴다."""
    fwd: dict = {}
    hf = conn.get("hostForward")
    for port in (hf if isinstance(hf, (list, tuple)) else []):
        p = str(port).strip()
        if p.isdigit():
            fwd[p] = "host"
    for port, spec in (conn.get("forward") or {}).items():
        p = str(port).strip()
        if not p.isdigit():
            continue
        tgt = spec.get("target") if isinstance(spec, dict) else spec
        tgt = str(tgt or "").strip()
        if tgt:
            fwd[p] = tgt
    # 옛 services.<svc>.endpoints(삭제된 모달 저장분)·서비스별 hostForward 는 무시한다 — 서비스타겟은 _auto_service_forward 가,
    # host 타겟은 top-level 로 선언한다. 전역 승격은 서비스별 스코프가 깨져 auto 라우트를 잘못 덮는다(코덱스 리뷰 P1). 발견 시 경고는 cmd_up.
    return fwd
```

(기존 함수 끝의 endpoints 주석은 위 주석으로 흡수 — 별도 유지 불필요.)

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-compose-forward.sh && bash plugin/tests/test-compose-overlay.sh`
Expected: 둘 다 PASS

- [ ] **Step 5: cmd_up 에 조용한-무시 경고 + backing.json 사용 안내 추가**

`marina-compose.py` cmd_up, 기존 endpoints 경고 블록(Task 1 에서 문구 고친 곳) 바로 아래에 추가:

```python
    if any((_sc or {}).get("hostForward") for _sc in (conn.get("services") or {}).values()):   # 서비스별 hostForward — 조용한 무시 금지
        sys.stderr.write("warning: services.*.hostForward 는 지원되지 않습니다 — top-level forward 또는 x-marina.forward 로 선언하세요.\n")
    if conn:                                                        # backing.json 을 실제로 읽은 경우 — 신규 선언은 x-marina 로 유도(강제 아님)
        sys.stderr.write("notice: backing.json 을 읽었습니다 — 설정은 x-marina.forward 로 compose 파일 하나에 모으는 걸 권장합니다.\n")
```

- [ ] **Step 6: 전체 compose 테스트 회귀**

Run: `for t in plugin/tests/test-compose-forward.sh plugin/tests/test-compose-overlay.sh plugin/tests/test-compose-config.sh plugin/tests/test-compose-validate.sh; do bash "$t" || break; done`
Expected: 전부 PASS

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-forward.sh plugin/tests/test-compose-overlay.sh
git commit -m "fix(marina): 엮기 hostForward 읽기 복원 — README 안내 포맷이 조용히 무시되던 것 (팀원 페인포인트)"
```

---

### Task 3: A4 — start 출력에 엮기 적용 요약 1줄

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (`_forward_summary` 신설 + cmd_up 출력)
- Test: `plugin/tests/test-compose-forward.sh`

- [ ] **Step 1: 실패하는 테스트 추가**

`test-compose-forward.sh` 의 `_normalize_forward` assert 묶음 아래에 추가:

```python
# --- _forward_summary: start 성공 시 1줄 요약 (설정했는데 먹었는지 모름 방지) ---
assert mc._forward_summary({"8081":"be","6379":"host"})=="엮기: localhost:6379→host · localhost:8081→be"
assert mc._forward_summary({})==""
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-compose-forward.sh`
Expected: FAIL — `AttributeError: module 'mc' has no attribute '_forward_summary'`

- [ ] **Step 3: 구현**

`marina-compose.py` 의 `_normalize_forward` 바로 아래에 추가:

```python
def _forward_summary(forward: dict) -> str:
    """{port:target} → '엮기: localhost:6379→host · localhost:8081→be' (빈 dict 는 ''). start 성공 출력용 — 적용 상태 가시화."""
    if not forward:
        return ""
    return "엮기: " + " · ".join(f"localhost:{p}→{forward[p]}" for p in sorted(forward, key=int))
```

cmd_up 끝부분:

```python
    rc = subprocess.call(argv, env=env)                            # P1: same env to up
    if rc == 0:
        _show_ports(name)
    return rc
```

을 다음으로 교체:

```python
    rc = subprocess.call(argv, env=env)                            # P1: same env to up
    if rc == 0:
        summary = _forward_summary(forward)
        if summary:
            print(summary)
        _show_ports(name)
    return rc
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-compose-forward.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-forward.sh
git commit -m "feat(marina): start 성공 출력에 엮기 적용 요약 1줄 — 설정이 먹었는지 보이게"
```

---

### Task 4: A1 — README 엮기 섹션을 x-marina.forward 로 통일

**Files:**
- Modify: `README.md:285` (엮기 섹션의 "호스트 인프라만 선언" 항목)

- [ ] **Step 1: README 수정**

현재 285줄:

```markdown
- **호스트 인프라(redis/db 등)만 선언**: 대시보드 "호스트 백킹 포트" 또는 `~/.marina/<id>/backing.json` 의 `hostForward: ["6379"]` → `localhost:6379→host.docker.internal`(리눅스는 default gateway 폴백).
```

교체 (marina 설정은 compose 하나 원칙 + x-marina 예시 + 레거시 한 줄):

```markdown
- **호스트 인프라(redis/db 등)만 선언**: compose 의 `x-marina.forward` 에 — marina 설정은 compose 파일 하나(x-marina)에 모인다. 포트 키는 따옴표 문자열(`"6379"`).

  ```yaml
  x-marina:
    forward:
      "6379": host   # 컨테이너의 localhost:6379 → 호스트 redis (리눅스는 default gateway 폴백)
  ```

  대시보드 위저드의 "호스트 백킹 연결" 체크와 동일하다. 레거시 `~/.marina/<id>/backing.json`(`forward`/`hostForward`)도 계속 읽히지만 신규 선언은 x-marina 로.
```

- [ ] **Step 2: 예시 YAML 이 docker-valid 한지 확인**

```bash
cat > /tmp/marina-readme-check.yml <<'EOF'
services:
  app:
    image: alpine
x-marina:
  forward:
    "6379": host
EOF
docker compose -f /tmp/marina-readme-check.yml config >/dev/null && echo OK
```

Expected: `OK` (docker 없으면 이 단계 스킵하고 커밋 메시지에 미검증 명기)

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(marina): 엮기 선언을 x-marina.forward 로 안내 — 무시되던 backing.json hostForward 예시 제거"
```

---

### Task 5: B1 — PreToolUse 차단 훅 (Claude Code)

등록 프로젝트 안에서 dev 서버 직접 기동 명령을 deny 하고 marina 명령을 안내한다. 판정기는 파이썬(테스트 용이), 래퍼는 셸(fail-open 보장).

**Files:**
- Create: `plugin/scripts/marina_pretooluse.py`
- Create: `plugin/scripts/marina-pretooluse-hook.sh`
- Modify: `plugin/hooks/hooks.json`
- Test: `plugin/tests/test-pretooluse-block.sh` (신규)

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-pretooluse-block.sh` 신규:

```bash
#!/usr/bin/env bash
# PreToolUse 훅: 등록 프로젝트 안 dev 서버 직접 기동 → deny JSON, 그 외(조회성·탈출구·미등록·깨진 입력)는 전부 무출력(allow)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-pretooluse-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null

req() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"; }
deny()  { out="$(req "$1" "$2" | "$HOOK")"; echo "$out" | grep -q '"permissionDecision": *"deny"' || { echo "FAIL(deny 기대): $1 → [$out]"; exit 1; }; }
allow() { out="$(req "$1" "$2" | "$HOOK")"; [[ -z "$out" ]] || { echo "FAIL(allow 기대): $1 → [$out]"; exit 1; }; }

# 차단: 패턴표 각 계열 대표
deny  "npm run dev" "$proj"
deny  "pnpm run serve" "$proj"
deny  "yarn start" "$proj"
deny  "docker compose up -d" "$proj"
deny  "docker-compose up" "$proj"
deny  "./gradlew bootRun" "$proj"
deny  "cd be && ./mvnw spring-boot:run" "$proj"
deny  "python manage.py runserver 0.0.0.0:8000" "$proj"
deny  "npx vite" "$proj"
deny  "git pull && npm run dev" "$proj"
# 통과: 조회성·빌드·테스트
allow "npm run build" "$proj"
allow "npm test" "$proj"
allow "docker compose ps" "$proj"
allow "docker compose logs -f be" "$proj"
allow "docker compose config" "$proj"
allow "./gradlew test --dry-run" "$proj"
allow "vite build" "$proj"
# 통과: 탈출구
allow "MARINA_DIRECT=1 npm run dev" "$proj"
# 통과: 미등록 레포
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
allow "npm run dev" "$other"
# fail-open: 깨진 stdin 이어도 exit 0 + 무출력
out="$(echo 'kaput{' | "$HOOK")" && [[ -z "$out" ]] || { echo "FAIL: 깨진 stdin 에 fail-open 아님: [$out]"; exit 1; }
echo "PASS test-pretooluse-block"
```

- [ ] **Step 2: 실행 권한 부여 후 실패 확인**

```bash
chmod +x plugin/tests/test-pretooluse-block.sh
bash plugin/tests/test-pretooluse-block.sh
```

Expected: FAIL — `marina-pretooluse-hook.sh: No such file or directory`

- [ ] **Step 3: 판정기 구현 — `plugin/scripts/marina_pretooluse.py`**

```python
#!/usr/bin/env python3
"""marina PreToolUse(Bash) 판정기: 등록 프로젝트 안에서 dev 서버 직접 기동 명령이면 deny JSON 을 stdout 으로,
아니면 무출력(=allow). 어떤 오류든 무출력 exit 0 (fail-open) — marina 문제로 세션의 Bash 전체를 막지 않는다.
stdin: Claude Code PreToolUse JSON({tool_name, tool_input:{command}, cwd})."""
import json
import os
import re
import subprocess
import sys

# dev 서버 직접 기동 패턴표 — 추가/삭제는 여기 한 줄. 조회성(config/ps/logs)·build·test 는 표에 없음 = 통과.
PATTERNS = [
    r"\bdocker([ \t]+|-)compose\b[^|;&]*[ \t](up|start|restart)\b",
    r"\b(npm|yarn|pnpm|bun)\b[^|;&]*\brun[ \t]+(dev|start|serve)\b",
    r"\b(npm|yarn|pnpm|bun)[ \t]+start\b",
    r"\b(next|nuxt|astro)[ \t]+dev\b",
    r"(^|[ \t;&|(])vite\b(?![ \t]+(build|preview))",
    r"\bgradlew?\b[^|;&]*[ \t](bootRun|run)([ \t]|$)",
    r"\bmvnw?\b[^|;&]*[ \t]spring-boot:run\b",
    r"\bmanage\.py[ \t]+runserver\b",
    r"\bflask[ \t]+run\b",
    r"\buvicorn[ \t]+\S",
    r"\brails[ \t]+s(erver)?\b",
]

REASON = ("이 워크트리는 marina 가 관리합니다. dev 서버는 `marina start <서비스>` (전체 --all) 로 띄우세요 — "
          "포트가 워크트리별로 격리됩니다. 상태·실제 포트 `marina status` · 로그 `marina logs <서비스>` · "
          "정지 `marina stop <서비스>`. 정말 직접 실행해야 하면 명령 앞에 `MARINA_DIRECT=1 ` 를 붙이세요.")


def _registered(root: str, projects_file: str) -> bool:
    """세션훅(marina-session-start-hook.sh is_registered)과 동일 판정: root 자신/하위 또는 codex 레이아웃 basename."""
    try:
        data = json.load(open(projects_file, encoding="utf-8"))
    except Exception:
        return False
    root = os.path.realpath(root)
    codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
    in_codex = os.path.dirname(os.path.dirname(root)) == codex_wt
    for p in data.get("projects", []):
        pr = os.path.realpath(os.path.expanduser(p.get("root", "")))
        if not pr:
            continue
        if root == pr or root.startswith(pr + os.sep):
            return True
        if in_codex and os.path.basename(root) == os.path.basename(pr):
            return True
    return False


def main() -> int:
    try:
        d = json.load(sys.stdin)
    except Exception:
        return 0
    if d.get("tool_name") not in (None, "Bash"):
        return 0
    cmd = str((d.get("tool_input") or {}).get("command") or "")
    if not cmd or "MARINA_DIRECT=1" in cmd:                        # 의도적 직접 실행 탈출구
        return 0
    if not any(re.search(p, cmd) for p in PATTERNS):               # 싼 검사 먼저 — git/파일 IO 전에
        return 0
    cwd = d.get("cwd") or os.getcwd()
    try:
        root = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return 0
    if not root:
        return 0
    projects_file = os.path.join(os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina"), "projects.json")
    if not os.path.isfile(projects_file) or not _registered(root, projects_file):
        return 0
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": REASON}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 래퍼 구현 — `plugin/scripts/marina-pretooluse-hook.sh`**

```bash
#!/usr/bin/env bash
# marina PreToolUse hook 래퍼 (hooks.json 에서 호출) — 판정은 marina_pretooluse.py.
# 어떤 실패(파이썬 없음·판정기 예외)든 exit 0 + 무출력 = allow (fail-open).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || exit 0
python3 "$SCRIPT_DIR/marina_pretooluse.py" 2>/dev/null || true
exit 0
```

```bash
chmod +x plugin/scripts/marina-pretooluse-hook.sh
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash plugin/tests/test-pretooluse-block.sh`
Expected: `PASS test-pretooluse-block`

- [ ] **Step 6: hooks.json 에 PreToolUse 등록**

`plugin/hooks/hooks.json` 전체를 다음으로 교체 (SessionStart 는 그대로 + PreToolUse 추가):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/marina-session-start-hook.sh\"",
            "async": false
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/marina-pretooluse-hook.sh\""
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 7: hooks.json 문법 확인**

Run: `python3 -c "import json; json.load(open('plugin/hooks/hooks.json')); print('OK')"`
Expected: `OK`

- [ ] **Step 8: Commit**

```bash
git add plugin/scripts/marina_pretooluse.py plugin/scripts/marina-pretooluse-hook.sh plugin/hooks/hooks.json plugin/tests/test-pretooluse-block.sh
git commit -m "feat(marina): PreToolUse 훅 — 등록 프로젝트에서 dev 서버 직접 기동 차단 + marina 안내 (MARINA_DIRECT=1 탈출구, fail-open)"
```

---

### Task 6: B3 — SessionStart 보강: docker compose up 금지 명시 + 미등록 힌트

**Files:**
- Modify: `plugin/scripts/marina-session-start-hook.sh:44` (미등록 분기), `:108` (금지 문구)
- Test: `plugin/tests/test-session-start-context.sh`

- [ ] **Step 1: 실패하는 테스트로 바꾸기**

`test-session-start-context.sh` 의 Claude 케이스 assert 에 `docker compose up` 검증 추가:

```bash
out="$( cd "$proj" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert ' start <서비스>' in a and 'docker compose up' in a, a" \
  || { echo "FAIL: Claude additionalContext"; exit 1; }
```

마지막 "비-marina repo" 케이스:

```bash
# 비-marina repo: stdout 비어야 (오염 없음)
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
out="$( cd "$other" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
[[ -z "$out" ]] || { echo "FAIL: 비등록 repo 가 stdout 출력: $out"; exit 1; }
```

를 다음으로 교체 (힌트 1줄 + 파일 흔적 없음 검증):

```bash
# 비-marina repo: 미등록 힌트 1줄 (등록 안내) — 단 .workspace 등 파일 흔적은 안 만듦
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
out="$( cd "$other" && CLAUDE_PLUGIN_ROOT=x "$HOOK" 2>/dev/null )"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d['hookSpecificOutput']['additionalContext']; assert '미등록' in a and 'project add' in a, a" \
  || { echo "FAIL: 미등록 힌트"; exit 1; }
[[ ! -e "$other/.workspace" ]] || { echo "FAIL: 미등록 repo 에 .workspace 생성"; exit 1; }
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-session-start-context.sh`
Expected: FAIL (docker compose up 문구 없음에서 먼저 걸림)

- [ ] **Step 3: 훅 수정 — 금지 문구**

`marina-session-start-hook.sh:108`:

```
[marina] 이 worktree 는 marina 가 관리합니다. dev 서버는 직접(npm/gradlew 등) 띄우지 말고 $caller 로 — worktree 별 포트가 자동 격리됩니다.
```

를 다음으로 교체:

```
[marina] 이 worktree 는 marina 가 관리합니다. dev 서버는 직접(npm/gradlew/docker compose up 등) 띄우지 말고 $caller 로 — worktree 별 포트가 자동 격리됩니다.
```

- [ ] **Step 4: 훅 수정 — 미등록 힌트**

`marina-session-start-hook.sh:44`:

```bash
PROJECT_ID="$(is_registered)" || exit 0
```

를 다음으로 교체 (파일 흔적 없이 1줄 힌트만 — JSON escape 는 아래 escape_for_json 이 아직 정의 전이므로 인라인 최소 escape):

```bash
if ! PROJECT_ID="$(is_registered)"; then
  # 미등록 git 레포: 파일 흔적 없이 힌트 1줄만 — 에이전트가 marina 존재를 모른 채 dev 서버를 직접 띄우는 것 방지.
  caller="marina"; command -v marina >/dev/null 2>&1 || caller="$SCRIPT_DIR/marina-entrypoint.sh"
  hint="[marina] 이 레포는 marina 미등록입니다. worktree 별 dev 서버 격리(포트 자동 분리)가 필요하면 '$caller project add .' 또는 대시보드(:3900)에서 등록하세요."
  esc="${hint//\\/\\\\}"; esc="${esc//\"/\\\"}"
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -z "${COPILOT_CLI:-}" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
  else
    printf '{"additionalContext":"%s"}\n' "$esc"
  fi
  exit 0
fi
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash plugin/tests/test-session-start-context.sh`
Expected: `PASS test-session-start-context`

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina-session-start-hook.sh plugin/tests/test-session-start-context.sh
git commit -m "feat(marina): SessionStart 보강 — docker compose up 금지 명시 + 미등록 레포에도 등록 힌트 1줄"
```

---

### Task 7: B2 — dev-server 스킬 동봉

"dev 서버 실행/로그/포트" 상황에서 자동 발동해 차단 전에 marina 경로로 유도하는 스킬.

**Files:**
- Create: `plugin/skills/dev-server/SKILL.md`
- Test: `plugin/tests/test-skill-dev-server.sh` (신규, frontmatter 스모크)

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-skill-dev-server.sh`:

```bash
#!/usr/bin/env bash
# dev-server 스킬: SKILL.md 존재 + frontmatter(name/description) + 핵심 명령 포함 스모크
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
F="$HERE/../skills/dev-server/SKILL.md"
[[ -f "$F" ]] || { echo "FAIL: SKILL.md 없음"; exit 1; }
head -1 "$F" | grep -qx -- '---' || { echo "FAIL: frontmatter 시작 없음"; exit 1; }
grep -q '^name: dev-server$' "$F" || { echo "FAIL: name"; exit 1; }
grep -q '^description: .*dev server' "$F" || { echo "FAIL: description 트리거 문구"; exit 1; }
grep -q 'marina start' "$F" || { echo "FAIL: marina start 안내 없음"; exit 1; }
grep -q 'MARINA_DIRECT=1' "$F" || { echo "FAIL: 탈출구 안내 없음"; exit 1; }
echo "PASS test-skill-dev-server"
```

```bash
chmod +x plugin/tests/test-skill-dev-server.sh
bash plugin/tests/test-skill-dev-server.sh
```

Expected: FAIL — SKILL.md 없음

- [ ] **Step 2: 스킬 작성 — `plugin/skills/dev-server/SKILL.md`**

```markdown
---
name: dev-server
description: Use when starting, stopping, or restarting a dev server, or checking service logs, ports, or preview URLs in this project — the dev runtime is managed by marina (do not run npm run dev / gradlew bootRun / docker compose up directly)
---

# marina dev-server

이 프로젝트의 dev 서버는 marina 가 worktree 별로 격리 실행한다. 직접 실행(`npm run dev`·`./gradlew bootRun`·`docker compose up`)은 PreToolUse 훅이 차단한다 — 워크트리 간 포트 충돌·상태 간섭 때문이다.

## 명령

- 기동: `marina start <서비스>` (전체는 `--all`)
- 정지/재시작: `marina stop <서비스>` · `marina restart <서비스>`
- 상태·실제 포트: `marina status` — 호스트 포트는 Docker 자동할당이라 워크트리마다 다르다. 포트는 항상 여기서 확인.
- 로그: `marina logs <서비스>`
- 브라우저 URL: 게이트웨이 `http://<워크트리>.<프로젝트>.localhost:3902` (`marina gateway status` 로 확인)

## 문제 해결

- 포트를 코드·설정에 하드코딩하지 말 것 — worktree 마다 다르다. `marina status` 로 조회해서 쓴다.
- compose 정의(서비스·env·마운트) 변경: 대시보드(:3900)의 ✎ compose 편집 또는 `marina project add <path> --compose`.
- 엮기(컨테이너 안 localhost → 호스트 인프라)는 compose 의 `x-marina.forward` 에 선언한다.
- 정말 직접 실행이 필요하면 명령 앞에 `MARINA_DIRECT=1 ` 을 붙인다(차단 우회) — 포트 충돌은 감수.
```

- [ ] **Step 3: 테스트 통과 확인**

Run: `bash plugin/tests/test-skill-dev-server.sh`
Expected: `PASS test-skill-dev-server`

- [ ] **Step 4: Commit**

```bash
git add plugin/skills/dev-server/SKILL.md plugin/tests/test-skill-dev-server.sh
git commit -m "feat(marina): dev-server 스킬 동봉 — 에이전트가 dev 서버 작업에서 marina 경로로 자연 유도"
```

---

### Task 8: B4 — Codex 폴백 확인 + 문서화 (MARINA_DIRECT 포함)

**Files:**
- Modify: `README.md` (Codex 설치 안내 부근 79-81줄 + LLM 규약 관련 문단)

- [ ] **Step 1: Codex 의 PreToolUse 상당 기능 확인**

```bash
grep -rin "pretooluse\|pre_tool\|before.*tool" ~/.codex/config.toml 2>/dev/null; codex --help 2>/dev/null | grep -i hook; true
```

공식 문서(Codex CLI 릴리스 노트/설정 스키마)도 확인. 판정:
- 지원함 → `plugin/.codex-plugin` 매니페스트/설정에 동일 래퍼 연결 (플랫폼 분기는 SessionStart 방식 그대로), 테스트 케이스 추가.
- 지원 안 함(예상) → 코드 변경 없음, Step 2 문서화만.

- [ ] **Step 2: README 문서화**

README 의 Codex 안내(79-81줄 근방)에 1줄 추가:

```markdown
- Codex 는 SessionStart 규칙 주입 + dev-server 스킬로 안내한다 — dev 서버 직접 실행의 **차단**(PreToolUse)은 Claude Code 한정.
```

게이트웨이/엮기 섹션 근처의 적절한 위치(에이전트 규약 언급부)에 탈출구 문서화:

```markdown
- 에이전트/사용자가 의도적으로 직접 실행해야 할 때: 명령 앞에 `MARINA_DIRECT=1 ` (marina 의 dev 서버 차단 훅 우회).
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(marina): dev 서버 차단은 Claude Code 한정(Codex 는 규칙+스킬) · MARINA_DIRECT=1 탈출구 명기"
```

---

### Task 9: 전체 회귀 + 실세션 e2e

- [ ] **Step 1: 관련 테스트 일괄 회귀**

```bash
for t in test-compose-forward.sh test-compose-overlay.sh test-compose-config.sh test-compose-validate.sh \
         test-session-start-context.sh test-pretooluse-block.sh test-skill-dev-server.sh \
         test-compose-weave-e2e.sh; do
  echo "== $t"; bash "plugin/tests/$t" || { echo "FAIL: $t"; break; }
done
```

Expected: 전부 PASS (`test-compose-weave-e2e.sh` 는 docker 필요 — 없으면 스킵 사유 출력 확인)

- [ ] **Step 2: 실세션 e2e (수동 1회)**

등록 프로젝트 worktree 에서 새 Claude Code 세션을 열고:
1. `npm run dev` 실행 시도 → PreToolUse deny 메시지(`marina start` 안내) 확인
2. `MARINA_DIRECT=1 npm run dev` → 통과 확인 (바로 Ctrl-C)
3. 미등록 레포에서 세션 시작 → "[marina] 이 레포는 marina 미등록입니다" 힌트 확인

- [ ] **Step 3: 스펙 상태 갱신 + 최종 커밋**

`docs/superpowers/specs/2026-07-10-team-adoption-fixes-design.md` 상단 `상태:` 를 `구현 완료 (형 검토 대기)` 로 수정.

```bash
git add docs/superpowers/specs/2026-07-10-team-adoption-fixes-design.md
git commit -m "docs(spec): 팀 사용성 페인포인트 — 구현 완료 표시"
```

push 는 하지 않는다 — 형이 검토 후 결정 (팀 규약).
