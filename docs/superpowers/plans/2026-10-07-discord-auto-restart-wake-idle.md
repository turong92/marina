# Discord 자동 재기동·깨우기·유휴 내림 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(구현 = `developer`, 리뷰 = `code-reviewer` 역할) 또는 superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 재부팅 뒤에도 Discord 봇이 스스로 뜨고, 꺼진 방에 글이 오면 그 방 세션을 깨워 그 글을 넘기고, 오래 쉰 방은 잃을 것이 없을 때만 내린다.

**Architecture:** 봇 데몬은 맥 기본 홈에서 LaunchAgent `marina.discord` 하나가 주인이 된다(그 밖 환경은 지금처럼 훅이 떼어 띄움). `bot.ts` 가 `MessageCreate` 를 받아 파이썬 `marina_discord_wake.py wake` 에 채널·글쓴이·메시지 ID 만 넘기고, 파이썬이 REST 로 밀린 글을 읽어 `<channel …>` 태그로 싼 첫 지시를 만들어 기존 `cmd_start` 로 띄운다. 유휴 내림은 데몬 루프의 1분 틱이 훅이 적은 활동 시각과 기존 `restart_blockers` 로 판정한다.

**Tech Stack:** python3(데몬 3.14, 3.9 호환 유지) · bun + discord.js 14(`bot.ts`) · launchd(`launchctl bootstrap/bootout/kickstart/print`) · tmux · bash 테스트(`plugin/tests/lib/harness.sh`·`session_fixture.sh`·`fake_discord.py`).

**Spec:** `docs/superpowers/specs/2026-10-07-discord-auto-restart-wake-idle-design.md` (이하 "스펙 §N")

## Global Constraints

- **3.9 호환.** `plugin-discord/scripts/*.py` 는 전부 `test-py39-compat` 대상이다. 새 모듈 맨 위에 `from __future__ import annotations`. `match` 문 금지. f-string 표현식 안에 백슬래시·바깥과 같은 따옴표 금지(3.12 전에는 문법 오류).
- **경계.** 새 모듈은 `plugin-discord/scripts/DISCORD_MODULES` 에 넣고 `marina_` 로 시작하는 모듈은 그 목록 안 것만 import 한다. runtime·대시보드 코드 import 금지(`test-discord-boundary`).
- **테스트 격리.** 모든 테스트는 `lib/harness.sh` → `lib/session_fixture.sh` 순으로 source 한다(MARINA_HOME·MARINA_CHANNELS_DIR·MARINA_CLAUDE_PROJECTS·MARINA_TMUX_SOCKET 격리, `MARINA_DISCORD_DAEMON=off`).
  - **실제 `launchctl` 호출 금지.** 가짜 스크립트를 `MARINA_DISCORD_LAUNCHCTL` 로, plist 폴더를 `MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents"` 로 준다.
  - **죽이는 코드의 테스트는 자기가 만든 tmux 세션만**(전용 소켓 `marina-test-$$`). 죽이기 전에 소켓 이름이 `marina-test-` 로 시작하는지 단언한다.
- **빌드·테스트는 아낀다.** 작업 중에는 그 작업의 테스트 파일 하나만 돌린다. 묶음(`run-affected.sh`)은 Task 11 에서 한 번. 명령이 `heavy: …자리가 없다`(종료 코드 75)로 끝나면 실패가 아니다 — 같은 명령을 백그라운드로 다시 건다.
- **커밋·push·배포.** 커밋은 형이 지시할 때만(Conventional Commits, `Co-Authored-By` 없음). 각 작업 끝의 커밋 메시지는 제안이다. push·캐시 설치·데몬 재시작은 형 허락.
- **값(스펙에서 그대로).** 라벨 `marina.discord` · `LANG=en_US.UTF-8` · 표식 `MARINA_DISCORD_SUPERVISED=launchd` · 깨우는 표시 ⏰ · 앞 글 묶는 범위 600초 · 첫 지시 상한 8000바이트 · 깨운 뒤 확인 45초(15초 넘은 글만) · 실패 안내 간격 600초 · 훑기 한도 12시간 · 유휴 기본 6시간(형 결정 전까지)·하한 2시간 · 내림 틱 60초·연속 조용 `RESTART_QUIET`(60초)·막힌 방 재확인 600초 · 한 틱에 하나.
- **수술적 변경.** 기존 함수의 이름·인자·반환은 기본값을 더하는 식으로만 넓힌다. 떠 있는 세션의 옛 설정이 새 코드를 부른다(`hook-*` 계약).

## Review Focus

스펙이 암시하지만 놓치기 쉬운 것. 각 줄의 테스트는 괄호 안 작업에 있다.

1. **데몬이 둘 뜬다** — 업데이트 교체 10초 공백에 훅이 `ensure_daemon()` 을 부르거나, 첫 배포 때 떼어 뜬 데몬과 launchd 데몬이 겹친다. 기대: 봇·#상태를 돌리는 것은 언제나 하나. (Task 3: 핸드오프·자기 이전·동시 ensure)
2. **형이 연달아 쓴 두 번째 글이 사라진다** — 첫 글로 깨어나는 몇 초 사이에 온 글. 기대: 둘 다 답한다. (Task 6: 깨운 뒤 확인)
3. **일하는 세션을 내린다** — 판정이 예외로 죽거나, 계획 승인 창·쓰다 만 입력·붙어 있는 터미널을 못 본다. 기대: 모르면 안 내린다. (Task 9: 조건별·예외)
4. **오래된 밀린 글을 지시로 실행한다** — 사흘 전 "배포해"가 오늘 글에 딸려 온다. 기대: 10분보다 오래된 글은 개수만. 첫 배포 때 옛 글로 방들이 한꺼번에 깨지 않는다. (Task 4·8)
5. **깨운 세션이 손으로 켠 세션과 다르게 돈다** — launchd 의 짧은 PATH·LANG. 기대: 마지막으로 띄운 환경 그대로. (Task 5: launch-env)

---

## 결정이 계획을 바꾸는 곳

스펙 "정해야 할 것"의 추천안으로 쓴다. 형이 다르게 고르면 아래만 바꾼다.

| 결정 | 추천(계획 기본) | 다르게 고르면 |
|---|---|---|
| 1 기준 시간 | 6 | Task 9 `IDLE_DEFAULT_HOURS` 값 |
| 2 로비 | 같은 규칙 | Task 9 `_eligible()` 에서 `LOBBY_KINDS` 제외 + Task 8 `sweep()` 이 꺼진 로비를 `cmd_start` |
| 3 재부팅 때 일하던 방 | 다시 켠다 | Task 8 `RESUME_INTERRUPTED = False` (전부 켜기면 `sweep()` 끝에 `cmd_start(all_=True)`) |
| 4 `stop` 한 방 | 깨운다 | Task 6: `stop` 이 `<상태 폴더>/manual-stop` 을 쓰고 `cmd_start` 가 지운다. `wake()` 는 그 파일이 있으면 `ignored:manual-stop` |
| 5 처음 켜는 방식 | 바로 | Task 9: 예고만이면 `Idler.tick` 이 `~/.marina/discord-idle-since` 로부터 24시간 동안 `tmux_stop` 대신 로그만 |
| 6 내림 알림 | 없음 | Task 9: 내린 뒤 `dc._req("POST", …, {"content": "💤 …", "flags": 4096})` 한 줄 |

---

### Task 1: 전제 실측 (코드 없음)

스펙 §10 의 1·2·4 를 구현 전에 확인한다. 나머지(3·5·6·7)는 뒤 작업의 테스트·마지막 실측이 맡는다. **1·2 는 실제 Claude 를 띄워 토큰이 든다(1은 큰 세션을 한 번 읽는다) — 형 허락 뒤에 한다.**

**Files:** 스크래치만. 결과는 스펙 §10 표에 "결과" 열을 더해 적는다(문서 변경).

- [ ] **Step 1: REST 본문(§10-4).** 형의 테스트 채널에 글 하나를 쓰고(형), 그 채널 ID·메시지 ID 로:
  ```bash
  cd plugin-discord/scripts && python3 -c '
  import sys, marina_session as ms
  m = ms.Discord(ms.read_token(ms.load_config()))._req("GET", f"/channels/{sys.argv[1]}/messages/{sys.argv[2]}")
  print("content 있음" if m.get("content") else "content 비어 있음", "· 글쓴이", (m.get("author") or {}).get("id"))' <채널ID> <메시지ID>
  ```
  Expected: `content 있음`. 본문 자체는 출력하지 않는다. 비어 있으면 멈추고 지휘 세션에 보고(스펙 §4.1 을 "bot.ts 가 본문을 넘긴다"로 바꿔야 한다).
- [ ] **Step 2: 채팅 인자 꼬리(§10-2).** 전용 tmux 소켓·깨끗한 환경에서 새 대화 하나:
  ```bash
  S=$(uuidgen | tr A-Z a-z); D=$(mktemp -d); echo '{}' > "$D/settings.json"
  tmux -L probe new-session -d -s p -x 200 -y 50 -c "$D" \
    "/usr/bin/env -i HOME=$HOME PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin TERM=xterm-256color claude --session-id $S --restricted --permission-mode dontAsk --tools '' --disallowedTools AskUserQuestion --settings $D/settings.json 'PONG 한 단어만 답해'"
  sleep 25; tmux -L probe capture-pane -p -t p | tail -20; tmux -L probe kill-server
  ```
  Expected: 화면에 `PONG` 답이 있다(첫 지시가 도구 이름으로 먹히지 않았다). 폴더 신뢰 창이 뜨면 `$D` 대신 이미 신뢰된 폴더(`~/.marina/chat`)에서 다시 한다.
- [ ] **Step 3: 오래 쉰 큰 세션(§10-1).** 형이 고른 6시간 넘게 쉰 세션 ID 로, 원본을 건드리지 않게 복사본으로:
  ```bash
  tmux -L probe new-session -d -s p -x 200 -y 50 -c <그 세션 워크트리> \
    "/usr/bin/env -i HOME=$HOME PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin TERM=xterm-256color claude --resume <세션ID> --fork-session 'PONG 한 단어만 답해'"
  sleep 40; tmux -L probe capture-pane -p -t p | tail -25; tmux -L probe kill-server
  ```
  Expected: 선택 창 없이 턴이 돌아 `PONG`. 선택 창(요약해서 잇기 등)이 보이면 화면 글자를 그대로 적고 멈춘다 — Task 5·6 의 기동 방식을 바꿔야 한다.
- [ ] **Step 4:** 세 결과를 스펙 §10 에 적는다.

---

### Task 2: LaunchAgent 모듈

**Files:**
- Create: `plugin-discord/scripts/marina_discord_launchd.py`
- Modify: `plugin-discord/scripts/DISCORD_MODULES` (끝에 `marina_discord_launchd`)
- Test: `plugin/tests/test-discord-launchd.sh` (새)

**Interfaces — Produces:**
- `LABEL = "marina.discord"`, `SUPERVISED_ENV = "MARINA_DISCORD_SUPERVISED"`
- `plist_path() -> Path` — `$MARINA_LAUNCH_AGENTS_DIR` 또는 `~/Library/LaunchAgents` 아래 `marina.discord.plist`
- `is_primary() -> bool` — `ms.marina_home()` 이 `~/.marina` 인가
- `supervisor() -> str` — `"launchd"` | `"nohup"`
- `supervised() -> bool` — 이 프로세스가 launchd 가 띄운 데몬인가(env 표식)
- `plist_text(program: list[str]) -> str`
- `status() -> str` — `"running"` | `"loaded"` | `"absent"`
- `ensure(program: list[str]) -> str` — `"installed"` | `"reloaded"` | `"kicked"` | `"running"` | `"failed:<이유>"`
- `uninstall() -> str` — `"removed"` | `"absent"`

- [ ] **Step 1: 실패하는 테스트.** `plugin/tests/test-discord-launchd.sh`:
  ```bash
  #!/usr/bin/env bash
  # LaunchAgent(marina.discord): 로그인하면 봇 데몬이 뜨고 죽으면 다시 뜬다. 맥 기본 홈에서만 launchd 가 주인이고,
  # 테스트·격리 홈은 실제 launchctl 을 절대 부르지 않는다(가짜만).
  set -euo pipefail
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
  fail() { echo "FAIL: $*"; exit 1; }
  LC="$TMPROOT/lc"; mkdir -p "$LC"
  cat > "$TMPROOT/bin/fake-launchctl" <<SH
  #!/bin/sh
  echo "\$*" >> "$LC/log"
  case "\$1" in
    print) [ -f "$LC/loaded" ] || exit 113; echo "state = \$(cat "$LC/state" 2>/dev/null || echo running)" ;;
    bootstrap) [ -e "$LC/fail_bootstrap" ] && { echo "Bootstrap failed: 5"; exit 5; }; touch "$LC/loaded" ;;
    bootout) rm -f "$LC/loaded" ;;
    kickstart) echo running > "$LC/state" ;;
  esac
  SH
  chmod +x "$TMPROOT/bin/fake-launchctl"
  export MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents" LC
  PYTHONPATH="$DSCRIPTS:$SCRIPTS" FAKE="$TMPROOT/bin/fake-launchctl" python3 - <<'PY'
  import os, plistlib, sys, time
  from pathlib import Path
  import marina_session as ms
  import marina_discord_launchd as ld
  fails = []
  def check(c, m):
      if not c: fails.append(m)
  LC = Path(os.environ["LC"]); log = LC / "log"
  def calls(): return log.read_text().splitlines() if log.exists() else []
  prog = [str(ms.marina_home() / "bin" / "marina-session-hook"), "daemon"]
  # 내용
  d = plistlib.loads(ld.plist_text(prog).encode())
  check(d["Label"] == "marina.discord" and d["ProgramArguments"] == prog, f"라벨·실행 인자: {d}")
  check(d["RunAtLoad"] is True and d["KeepAlive"] is True and d["AbandonProcessGroup"] is True, "로그인 때 뜨고·죽으면 다시·자식은 안 죽임")
  env = d["EnvironmentVariables"]
  check(env["LANG"] == "en_US.UTF-8" and env["MARINA_DISCORD_SUPERVISED"] == "launchd" and env["PATH"] == ms.daemon_path()
        and env["MARINA_HOME"] == str(ms.marina_home()), f"환경: {env}")
  check(d["WorkingDirectory"] == str(ms.marina_home()) and d["StandardOutPath"].endswith("discord-daemon.log"), "cwd·로그")
  check(ld.plist_text(prog) == ld.plist_text(prog), "같은 입력이면 같은 내용(누가 써도 안 흔들린다)")
  # 주인: 격리 홈은 nohup — 가짜가 없으면 강제해도 nohup(실제 launchctl 을 안 부른다)
  check(ld.is_primary() is False and ld.supervisor() == "nohup", "격리 홈은 nohup")
  os.environ["MARINA_DISCORD_SUPERVISOR"] = "launchd"
  check(ld.supervisor() == "nohup", "가짜 launchctl 없이 강제해도 격리 홈은 nohup")
  check(ld.status() == "absent" and calls() == [], f"격리 홈은 launchctl 을 부르지 않는다: {calls()}")
  os.environ["MARINA_DISCORD_LAUNCHCTL"] = os.environ["FAKE"]
  check(ld.supervisor() == "launchd", "가짜가 있으면 강제대로")
  # 없으면 등록
  check(ld.ensure(prog) == "installed" and ld.plist_path().is_file(), "없으면 plist 쓰고 bootstrap")
  check(any(c.startswith("bootstrap gui/") and c.endswith(str(ld.plist_path())) for c in calls()), f"bootstrap 호출: {calls()}")
  check(ld.status() == "running" and ld.ensure(prog) == "running", "떠 있으면 그대로")
  # 올라가 있는데 죽어 있으면 kickstart
  (LC / "state").write_text("not running"); log.unlink()
  check(ld.status() == "loaded" and ld.ensure(prog) == "kicked", "죽어 있으면 kickstart")
  check(not any(c.startswith("bootstrap") for c in calls()), f"이미 올라가 있으면 bootstrap 안 함: {calls()}")
  # 내용이 다르면 다시 올린다(떼어 낸 도우미: bootout → bootstrap)
  log.unlink(); ld.plist_path().write_text("old")
  check(ld.ensure(prog) == "reloaded", "내용이 다르면 다시 올림")
  for _ in range(40):
      if any(c.startswith("bootstrap") for c in calls()): break
      time.sleep(0.1)
  cs = calls()
  check([c.split()[0] for c in cs if c.split()[0] in ("bootout", "bootstrap")] == ["bootout", "bootstrap"], f"bootout 다음 bootstrap: {cs}")
  check(plistlib.loads(ld.plist_path().read_bytes())["Label"] == "marina.discord", "파일은 새 내용")
  # 등록 실패는 failed:
  ld.uninstall(); (LC / "fail_bootstrap").touch()
  check(ld.ensure(prog).startswith("failed:"), "bootstrap 실패를 성공으로 적지 않는다")
  (LC / "fail_bootstrap").unlink()
  # 제거
  ld.ensure(prog)
  check(ld.uninstall() == "removed" and not ld.plist_path().exists() and ld.status() == "absent", "제거")
  check(ld.uninstall() == "absent", "없으면 absent")
  # 표식
  check(ld.supervised() is False, "표식 없으면 아님")
  os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
  check(ld.supervised() is True, "표식 있으면 launchd 자식")
  if fails:
      print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
  PY
  REAL="$HOME/Library/LaunchAgents/marina.discord.plist"
  if [ -f "$REAL" ] && grep -q "$MARINA_HOME" "$REAL"; then fail "테스트가 실제 로그인 항목을 건드렸다"; fi
  echo "PASS test-discord-launchd"
  ```
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-launchd.sh` — Expected: `ModuleNotFoundError: No module named 'marina_discord_launchd'`.
- [ ] **Step 3: 구현.** `marina_discord_launchd.py`:
  ```python
  #!/usr/bin/env python3
  """discord 봇 데몬의 LaunchAgent — 로그인하면 뜨고 죽으면 다시 뜬다(스펙 §3). 맥 + 기본 홈에서만 launchd 가 주인."""
  from __future__ import annotations

  import os
  import re
  import shutil
  import subprocess
  import sys
  from pathlib import Path
  from xml.sax.saxutils import escape

  import marina_session as ms

  LABEL = "marina.discord"
  SUPERVISED_ENV = "MARINA_DISCORD_SUPERVISED"


  def plist_path() -> Path:
      return Path(os.environ.get("MARINA_LAUNCH_AGENTS_DIR") or Path.home() / "Library" / "LaunchAgents") / f"{LABEL}.plist"


  def is_primary() -> bool:
      return ms.marina_home().resolve() == (Path.home() / ".marina").resolve()


  def _launchctl_exe() -> str:
      """격리 홈(테스트·프리뷰)은 실제 launchctl 을 절대 부르지 않는다 — 라벨이 사용자 전역이라 진짜 봇을 내린다."""
      fake = os.environ.get("MARINA_DISCORD_LAUNCHCTL")
      if fake:
          return fake
      return (shutil.which("launchctl") or "") if is_primary() else ""


  def supervisor() -> str:
      forced = os.environ.get("MARINA_DISCORD_SUPERVISOR") or ""
      if forced == "nohup" or not _launchctl_exe():
          return "nohup"
      if forced == "launchd":
          return "launchd"
      return "launchd" if sys.platform == "darwin" and is_primary() else "nohup"


  def supervised() -> bool:
      return os.environ.get(SUPERVISED_ENV) == "launchd"


  def _domain() -> str:
      return f"gui/{os.getuid()}"


  def _target() -> str:
      return f"{_domain()}/{LABEL}"


  def _launchctl(*args: str) -> tuple[int, str]:
      exe = _launchctl_exe()
      if not exe:
          return 127, "launchctl 없음"
      try:
          r = subprocess.run([exe, *args], capture_output=True, text=True, timeout=20)
      except (OSError, subprocess.SubprocessError) as exc:
          return 1, str(exc)
      return r.returncode, (r.stdout or "") + (r.stderr or "")


  def plist_text(program: list[str]) -> str:
      """home·실행 인자만으로 정해진다 — 누가 써도 같은 내용이라 '다르면 다시 올림' 이 흔들리지 않는다."""
      home = ms.marina_home()
      env = {"PATH": ms.daemon_path(), "MARINA_HOME": str(home), "PYTHONUNBUFFERED": "1",
             "LANG": "en_US.UTF-8", SUPERVISED_ENV: "launchd"}     # launchd 는 LANG 을 안 준다 — tmux 화면 판정이 UTF-8 이어야
      args = "".join("<string>" + escape(a) + "</string>" for a in program)
      envx = "".join("\n    <key>" + escape(k) + "</key><string>" + escape(v) + "</string>" for k, v in env.items())
      log = escape(str(home / "discord-daemon.log"))
      return ('<?xml version="1.0" encoding="UTF-8"?>\n'
              '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
              '<plist version="1.0">\n<dict>\n'
              f'  <key>Label</key><string>{LABEL}</string>\n'
              f'  <key>ProgramArguments</key><array>{args}</array>\n'
              f'  <key>EnvironmentVariables</key>\n  <dict>{envx}\n  </dict>\n'
              f'  <key>WorkingDirectory</key><string>{escape(str(home))}</string>\n'
              f'  <key>StandardOutPath</key><string>{log}</string>\n'
              f'  <key>StandardErrorPath</key><string>{log}</string>\n'
              '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n'
              '  <key>AbandonProcessGroup</key><true/>\n'     # 데몬이 끝날 때 진행 중인 새 작업 열기·깨우기를 같이 죽이지 않게
              '</dict>\n</plist>\n')


  def status() -> str:
      rc, out = _launchctl("print", _target())
      if rc != 0:
          return "absent"
      return "running" if re.search(r"^\s*state = running\s*$", out, re.M) else "loaded"


  def _write_if_changed(text: str) -> bool:
      p = plist_path()
      try:
          if p.read_text(encoding="utf-8") == text:
              return False
      except OSError:
          pass
      p.parent.mkdir(parents=True, exist_ok=True)
      tmp = p.with_name(f"{p.name}.{os.getpid()}.tmp")
      tmp.write_text(text, encoding="utf-8")
      os.replace(tmp, p)
      return True


  def _reload_detached() -> None:
      """bootout → bootstrap 을 떼어 낸 도우미로 — 데몬 자신이 불러도 자기를 내리다 중간에 죽지 않는다."""
      subprocess.Popen(["/bin/sh", "-c", '"$1" bootout "$2" >/dev/null 2>&1; sleep 1; exec "$1" bootstrap "$3" "$4"', "sh",
                        _launchctl_exe(), _target(), _domain(), str(plist_path())],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


  def ensure(program: list[str]) -> str:
      """plist 를 맞추고 launchd 에 올린다: installed | reloaded | kicked | running | failed:<이유>."""
      try:
          changed = _write_if_changed(plist_text(program))
      except OSError as exc:
          return f"failed:{exc}"
      st = status()
      if st == "absent":
          rc, out = _launchctl("bootstrap", _domain(), str(plist_path()))
          return "installed" if rc == 0 else "failed:" + out.strip()[-200:]
      if changed:
          _reload_detached()
          return "reloaded"
      if st == "loaded":
          rc, out = _launchctl("kickstart", _target())
          return "kicked" if rc == 0 else "failed:" + out.strip()[-200:]
      return "running"


  def uninstall() -> str:
      had = plist_path().exists() or status() != "absent"
      _launchctl("bootout", _target())
      try:
          plist_path().unlink()
      except OSError:
          pass
      return "removed" if had else "absent"
  ```
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-launchd.sh` → `PASS test-discord-launchd`. 이어서 `bash plugin/tests/test-discord-boundary.sh` → PASS.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 봇 데몬 LaunchAgent 모듈(marina.discord)`

---

### Task 3: 데몬 주인 규칙 — launchd 에 맡기기·핸드오프·자기 이전

**Files:**
- Modify: `plugin-discord/scripts/marina_session.py` — `ensure_daemon()`(1400행 부근), `_daemon_handoff()`(1597행 부근), `main()` 의 `daemon`·`daemon-ensure` 분기(3222행 부근) + 새 하위 명령 `daemon-uninstall`, `_PREFLIGHT_MODULES`(1455행)
- Test: `plugin/tests/test-discord-daemon.sh` (끝에 덧붙임)

**Interfaces:**
- Consumes: Task 2 `supervisor()`·`supervised()`·`ensure(program)`·`uninstall()`
- Produces:
  - `_launchd_program(entry: "list[str] | None" = None) -> "list[str] | None"` — 실행 인자가 고정 입구(`marina_home()/bin/marina-session-hook`)면 `[입구, "daemon"]`, 아니면 `None`(작업 트리에서 돌면 등록하지 않는다)
  - `ensure_daemon()` 반환에 `"launchd:installed"`·`"launchd:kicked"`·`"launchd:reloaded"`·`"launchd:running"` 추가(기존 `"off"`·`"running"`·`"started"` 유지)
  - `_daemon_adopt_launchd() -> bool` — 떼어 뜬 데몬이 launchd 에 넘기고 물러나야 하면 True
  - `_trim_daemon_log() -> None` — `discord-daemon.log` 가 1MB 를 넘으면 0 으로 자른다(`os.truncate` — launchd 가 쥔 덧붙이기 파일도 된다)

- [ ] **Step 1: 실패하는 테스트.** `test-discord-daemon.sh` 의 `kill $DUMMY` 줄 **앞**에 새 블록을 넣는다(가짜 launchctl 은 Task 2 테스트와 같은 내용을 `$TMPROOT/bin/fake-launchctl` 로 만든다 — 스크립트 본문을 그대로 다시 적는다):
  ```bash
  LC="$TMPROOT/lc"; mkdir -p "$LC" "$MARINA_HOME/bin"
  cat > "$TMPROOT/bin/fake-launchctl" <<SH
  #!/bin/sh
  echo "\$*" >> "$LC/log"
  case "\$1" in
    print) [ -f "$LC/loaded" ] || exit 113; echo "state = \$(cat "$LC/state" 2>/dev/null || echo running)" ;;
    bootstrap) [ -e "$LC/fail_bootstrap" ] && exit 5; touch "$LC/loaded" ;;
    bootout) rm -f "$LC/loaded" ;;
    kickstart) echo running > "$LC/state" ;;
  esac
  SH
  chmod +x "$TMPROOT/bin/fake-launchctl"
  printf '#!/bin/sh\nexit 0\n' > "$MARINA_HOME/bin/marina-session-hook"; chmod +x "$MARINA_HOME/bin/marina-session-hook"
  export MARINA_LAUNCH_AGENTS_DIR="$MARINA_HOME/LaunchAgents" LC
  PYTHONPATH="$DSCRIPTS:$SCRIPTS" FAKE="$TMPROOT/bin/fake-launchctl" python3 - <<'PY'
  import os, sys, threading
  from pathlib import Path
  import marina_session as ms
  import marina_discord_launchd as ld
  fails = []
  def check(c, m):
      if not c: fails.append(m)
  LC = Path(os.environ["LC"]); log = LC / "log"
  def calls(): return log.read_text().splitlines() if log.exists() else []
  shim = str(ms.marina_home() / "bin" / "marina-session-hook")
  spawned = []
  ms._spawn_daemon = lambda *a: spawned.append(1) or 4242
  ms.daemon_pid_path().unlink(missing_ok=True)
  os.environ.pop("MARINA_DISCORD_DAEMON", None)
  # 고정 입구가 아니면(작업 트리) 등록하지 않는다
  check(ms._launchd_program() is None, "작업 트리에서 돌면 launchd 프로그램 없음")
  check(ms._launchd_program([shim]) == [shim, "daemon"], "고정 입구면 [입구, daemon]")
  # 격리 홈(주인 = nohup): 지금 그대로 떼어 띄운다
  check(ms.ensure_daemon([shim]) == "started" and spawned == [1] and calls() == [], f"nohup 은 예전대로: {spawned} {calls()}")
  ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
  # 주인 = launchd: 떼어 띄우지 않고 등록한다
  os.environ.update(MARINA_DISCORD_SUPERVISOR="launchd", MARINA_DISCORD_LAUNCHCTL=os.environ["FAKE"])
  check(ms.ensure_daemon([shim]) == "launchd:installed" and spawned == [], f"launchd 에 맡김: {spawned}")
  (LC / "state").write_text("not running")
  check(ms.ensure_daemon([shim]) == "launchd:kicked" and spawned == [], "죽어 있으면 kickstart — 직접 띄우지 않는다(둘 방지)")
  # 작업 트리(입구 아님)에서는 launchd 가 주인이어도 예전대로
  check(ms.ensure_daemon() == "started" and spawned == [1], "입구가 아니면 등록 안 하고 예전대로")
  ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
  # 등록 실패 → 예전 방식으로 물러난다(봇이 없는 것보다 낫다)
  ld.uninstall(); (LC / "fail_bootstrap").touch()
  check(ms.ensure_daemon([shim]) == "started" and spawned == [1], "launchctl 실패면 떼어 띄움")
  (LC / "fail_bootstrap").unlink(); ms.daemon_pid_path().unlink(missing_ok=True); spawned.clear()
  # off 면 아무것도
  log.unlink(missing_ok=True); os.environ["MARINA_DISCORD_DAEMON"] = "off"
  check(ms.ensure_daemon([shim]) == "off" and calls() == [] and spawned == [], f"off 면 launchctl 호출 0건: {calls()}")
  check(ms._daemon_adopt_launchd() is False and calls() == [], "off 면 자기 이전도 안 함")
  del os.environ["MARINA_DISCORD_DAEMON"]
  # 동시 ensure 5개 → 등록 한 번
  ld.uninstall(); log.unlink(missing_ok=True)
  ts = [threading.Thread(target=lambda: ms.ensure_daemon([shim])) for _ in range(5)]
  [t.start() for t in ts]; [t.join() for t in ts]
  check(sum(c.startswith("bootstrap") for c in calls()) == 1, f"동시 ensure 도 bootstrap 한 번: {calls()}")
  # 핸드오프: launchd 자식은 아무것도 띄우지 않고 끝나기만 한다
  called = []
  real = ms.ensure_daemon
  ms.ensure_daemon = lambda *a: called.append(a) or "started"
  os.environ["MARINA_DISCORD_SUPERVISED"] = "launchd"
  ms._daemon_handoff()
  check(called == [], f"launchd 아래 핸드오프는 직접 안 띄운다: {called}")
  check(ms._daemon_adopt_launchd() is False, "이미 launchd 자식이면 이전할 것 없음")
  del os.environ["MARINA_DISCORD_SUPERVISED"]
  ms._daemon_handoff()
  check(len(called) == 1, "떼어 뜬 데몬의 핸드오프는 예전대로 다음 데몬을 띄운다")
  ms.ensure_daemon = real
  # 자기 이전: 떼어 뜬 데몬이 입구로 떴으면 등록하고 물러난다 — 입구가 아니면 그대로 돈다
  ld.uninstall()
  ms._hook_entry = lambda: [sys.executable, "/x/marina_session.py"]
  check(ms._daemon_adopt_launchd() is False, "작업 트리 데몬은 등록하지 않는다(LaunchAgent 가 워크트리를 물면 안 된다)")
  ms._hook_entry = lambda: [shim]
  check(ms._daemon_adopt_launchd() is True and ld.status() != "absent", "입구로 뜬 데몬은 등록하고 물러난다")
  # 로그 자르기
  lp = ms.marina_home() / "discord-daemon.log"
  lp.write_bytes(b"x" * ((1 << 20) + 10)); ms._trim_daemon_log()
  check(lp.stat().st_size == 0, "1MB 넘으면 비운다")
  lp.write_bytes(b"x" * 100); ms._trim_daemon_log()
  check(lp.stat().st_size == 100, "작으면 그대로")
  check("marina_discord_launchd" in ms._PREFLIGHT_MODULES, "업데이트 사전 검사에 새 모듈")
  if fails:
      print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
  PY
  ```
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-daemon.sh` — Expected: `AttributeError: … '_launchd_program'`.
- [ ] **Step 3: 구현.** `marina_session.py`:
  ```python
  def _launchd_program(entry: "list[str] | None" = None) -> "list[str] | None":
      """LaunchAgent 가 돌릴 명령. 고정 입구일 때만 — 작업 트리 파일을 가리키면 그 워크트리를 지우는 순간 봇이 죽는다."""
      head = entry or _hook_entry()
      shim = str(marina_home() / "bin" / "marina-session-hook")
      return [shim, "daemon"] if head == [shim] else None
  ```
  `ensure_daemon()` — 잠금 안, 두 번째 `_daemon_alive()` 확인 **바로 뒤**에:
  ```python
          import marina_discord_launchd as ld
          program = _launchd_program(entry)
          if program and ld.supervisor() == "launchd":       # 맥 기본 홈: launchd 가 유일한 주인(스펙 §3.2)
              r = ld.ensure(program)
              if not r.startswith("failed"):
                  return "launchd:" + r
              sys.stderr.write(f"LaunchAgent 등록 실패 — 떼어 띄운다: {r[-200:]}\n")
  ```
  `_daemon_handoff()` — pid 파일을 지운 **뒤**, `shim = …` 줄 **앞**에:
  ```python
      import marina_discord_launchd as ld
      if ld.supervised():
          return          # launchd(KeepAlive)가 새 코드로 다시 띄운다 — 직접 띄우면 둘이 된다(스펙 §3.4)
  ```
  새 함수 둘:
  ```python
  def _daemon_adopt_launchd() -> bool:
      """떼어 띄워진 데몬(옛 방식·첫 배포)이 맥 기본 홈에서 입구로 떴으면 LaunchAgent 를 올리고 물러난다(스펙 §3.3)."""
      if os.environ.get("MARINA_DISCORD_DAEMON") == "off":
          return False
      try:
          import marina_discord_launchd as ld
          program = _launchd_program()
          if not program or ld.supervised() or ld.supervisor() != "launchd":
              return False
          return not ld.ensure(program).startswith("failed")
      except Exception:
          return False


  def _trim_daemon_log() -> None:
      p = marina_home() / "discord-daemon.log"
      try:
          if p.stat().st_size > 1 << 20:
              os.truncate(p, 0)
      except OSError:
          pass
  ```
  `main()`:
  ```python
          elif a.cmd == "daemon":
              if _daemon_adopt_launchd():
                  return 0                     # launchd 가 띄운 데몬이 맡는다
              _trim_daemon_log()
              daemon_pid_path().write_text(f"{os.getpid()}\n")
              …(기존 그대로)
          elif a.cmd == "daemon-uninstall":
              import marina_discord_launchd as ld
              print(ld.uninstall())
  ```
  `sub.add_parser("daemon-uninstall")` 를 `daemon-ensure` 옆에. `_PREFLIGHT_MODULES` 끝에 `"marina_discord_launchd"`.
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-daemon.sh` → `PASS test-discord-daemon`.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 맥 기본 홈에서 봇 데몬을 launchd 가 맡는다 — 핸드오프·자기 이전`

---

### Task 4: 밀린 글 모으기 + 첫 지시 조립

**Files:**
- Create: `plugin-discord/scripts/marina_discord_wake.py`
- Modify: `plugin-discord/scripts/marina_session.py` — `class Discord` 에 읽기 둘(366행 `message_exists` 뒤)
- Modify: `plugin-discord/scripts/DISCORD_MODULES`, `_PREFLIGHT_MODULES` (`marina_discord_wake`)
- Modify: `plugin/tests/lib/fake_discord.py` — `do_GET` 에 메시지 목록·심어 둔 메시지 읽기
- Test: `plugin/tests/test-discord-wake.sh` (새)

**Interfaces — Produces:**
- `Discord.get_messages(cid: str, after: str, limit: int = 100) -> list[dict]` — `after` 뒤의 글, **오래된 것부터**
- `Discord.get_message(cid: str, mid: str) -> dict`
- `marina_discord_wake`:
  - 상수 `WAKE_RECENT_S = 600.0`, `WAKE_PROMPT_MAX = 8000`, `WAKE_NOTE`(아래)
  - `enabled(cfg: dict) -> bool` — `cfg.get("wake", True) is not False`
  - `snowflake_ts(mid: str) -> float` — `((int(mid) >> 22) + 1420070400000) / 1000`
  - `allow_list(rec: dict) -> "list[str] | None"` — 빈 목록 = 채널을 보는 모두, `None` = 판단 못 함·멘션 필수(깨우지 않음)
  - `seen_ids(rec: dict) -> set[str]` — 기록 끝 2MB 의 모든 `<channel …>` 메시지 ID(대기열에만 들어온 것 포함)
  - `base_id(rec: dict) -> str` — 마지막으로 **읽은** 이 채널 글 ID 와 `woke.json` 의 `baseId` 중 큰 것, 없으면 `""`
  - `missed(rec: dict, dc, since: float, trigger: str = "", thread: str = "") -> tuple[list[dict], int]` — (넘길 글들 오래된 것부터, 그보다 오래된 못 읽은 글 수)
  - `wake_prompt(msgs: list[dict], older: int = 0, unanswered: bool = False) -> str`
  - `_woke(rec: dict) -> dict`, `_save_woke(sd: Path, **kv) -> None` — `<상태 폴더>/woke.json`(기존 값에 덮어 합친다)

- [ ] **Step 1: 가짜 Discord 보강.** `fake_discord.py` 의 `do_GET` 에서 `p = self._parts()` 를 아래로 바꾸고, 기존 `len(p) == 4 … messages` 분기를 교체한다(나머지 분기는 그대로 — `p` 가 물음표 뒤를 뺀 값이라 동작이 같다):
  ```python
          from urllib.parse import urlsplit, parse_qs
          u = urlsplit(self.path); p = u.path.strip("/").split("/"); q = parse_qs(u.query)
          mf = state / "messages.json"            # {채널ID: [메시지…]} — 테스트가 심는다
          seeded = json.loads(mf.read_text()) if mf.exists() else {}
          if len(p) == 3 and p[0] == "channels" and p[2] == "messages":
              after = int((q.get("after") or ["0"])[0]); limit = int((q.get("limit") or ["50"])[0])
              rows = sorted((m for m in seeded.get(p[1], []) if int(m["id"]) > after), key=lambda m: int(m["id"]))[:limit]
              self._send(200, rows[::-1]); return     # Discord 처럼: after 에 가까운 것부터 limit 개를 최신이 먼저
          if len(p) == 4 and p[0] == "channels" and p[2] == "messages":
              gone = (state / "gone").read_text().split() if (state / "gone").exists() else []
              if p[3] in gone:
                  self._send(404, {"message": "Unknown Message"}); return
              hit = next((m for m in seeded.get(p[1], []) if m["id"] == p[3]), None)
              self._send(200, hit or {"id": p[3]}); return
  ```
- [ ] **Step 2: 실패하는 테스트.** `plugin/tests/test-discord-wake.sh`:
  ```bash
  #!/usr/bin/env bash
  # 꺼진 방 깨우기(스펙 §4): 꺼져 있던 동안 온 글을 REST 로 모아 채널 플러그인과 같은 <channel> 태그의 첫 지시 하나로 넘긴다.
  set -euo pipefail
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
  start_fake_discord
  fail() { echo "FAIL: $*"; exit 1; }
  msess new proj feat/a >/dev/null 2>&1 || fail "new"
  export FD
  PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
  import json, os, sys, time
  from pathlib import Path
  import marina_session as ms
  import marina_discord_bot as mb
  import marina_discord_wake as mw
  fails = []
  def check(c, m):
      if not c: fails.append(m)
  FD = Path(os.environ["FD"])
  rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"]); ch = rec["channelId"]
  sid = "abcdabcd-0000-1111-2222-333344445555"
  ms.save_sessions([dict(x, sessionId=sid) if x.get("stateDir") == str(sd) else x for x in ms.load_sessions()])
  rec = ms.find_session("proj/feat/a")
  tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
  now = time.time()
  def snow(t): return str((int(t * 1000) - 1420070400000) << 22)
  def msg(t, text, user="U1", bot=False, typ=0, atts=None, chan=None):
      return {"id": snow(t), "type": typ, "content": text, "channel_id": chan or ch,
              "author": {"id": user, "username": "sumin", "bot": bot}, "attachments": atts or []}
  def seed(*ms_, extra=None):
      d = {ch: list(ms_)}; d.update(extra or {})
      (FD / "messages.json").write_text(json.dumps(d))
  def tag(mid): return f'<channel source="plugin:discord:discord" chat_id="{ch}" message_id="{mid}" user="u">\nhi\n</channel>'
  def row(r): return json.dumps(r, ensure_ascii=False) + "\n"
  read = snow(now - 7200)             # 세션이 마지막으로 읽은 글
  queued = msg(now - 300, "대기열에만 들어온 글")
  tr.write_text(row({"type": "user", "message": {"role": "user", "content": tag(read)}})
                + row({"type": "queue-operation", "content": tag(queued["id"])}))
  dc = mb._dc(ms.load_config())
  # ── 기본 규칙 ──
  check(mw.enabled({}) and mw.enabled({"wake": True}) and not mw.enabled({"wake": False}), "wake 기본 켜짐·false 면 끔")
  check(abs(mw.snowflake_ts(snow(now)) - now) < 0.01, "메시지 ID → 시각")
  check(mw.allow_list(rec) == ["U1"], f"허용 목록: {mw.allow_list(rec)}")
  check(mw.base_id(rec) == read, "기준 = 마지막으로 읽은 글")
  check(queued["id"] in mw.seen_ids(rec) and read in mw.seen_ids(rec), "기록에 흔적이 있는 글(대기열 포함)")
  # ── 무엇을 넘기나 ──
  old = msg(now - 3 * 86400 + 86000, "사흘 전: 배포해")              # 기준 뒤지만 10분보다 한참 전
  a = msg(now - 60, "이거 해줘"); b = msg(now - 20, "아 그리고 저것도")
  seed(old, queued, a, msg(now - 50, "남의 글", user="U9"), msg(now - 40, "봇 글", bot=True),
       msg(now - 30, "", typ=0), msg(now - 25, "고정됨", typ=6), b)
  got, older = mw.missed(rec, dc, since=now - 600, trigger=b["id"])
  check([m["id"] for m in got] == [a["id"], b["id"]], f"허용된 사람의 못 읽은 최근 글만, 오래된 것부터: {[m['content'] for m in got]}")
  check(older == 1, f"10분보다 오래된 못 읽은 글은 개수만: {older}")
  # 기준을 못 찾으면 이번 글 하나만
  tr2 = tr.read_text(); tr.write_text(row({"type": "system", "subtype": "turn_duration"}))
  got, older = mw.missed(rec, dc, since=now - 600, trigger=b["id"])
  check([m["id"] for m in got] == [b["id"]] and older == 0, f"기준 없으면 이번 글만: {[m['content'] for m in got]}")
  got, _ = mw.missed(rec, dc, since=now - 600)
  check(got == [], "기준도 이번 글도 없으면 없음(훑기가 옛 글을 못 깨운다)")
  tr.write_text(tr2)
  # 스레드에 쓴 글 = 그 글 하나(채널은 스레드 ID)
  th = msg(now - 5, "스레드에서", chan="T77")
  seed(a, b, extra={"T77": [th]})
  got, _ = mw.missed(rec, dc, since=now - 600, trigger=th["id"], thread="T77")
  check(th["id"] in [m["id"] for m in got] and [m for m in got if m["id"] == th["id"]][0]["channel_id"] == "T77", "스레드 글은 스레드 ID 로")
  # 멘션 필수·허용 목록 못 읽음 → 안 깨운다
  acc = sd / "access.json"; keep = acc.read_text()
  d = json.loads(keep); d["groups"][ch]["requireMention"] = True; acc.write_text(json.dumps(d))
  check(mw.allow_list(rec) is None and mw.missed(rec, dc, since=now - 600, trigger=b["id"]) == ([], 0), "멘션 필수 방은 안 깨운다")
  d["groups"][ch].update(requireMention=False, allowFrom=[]); acc.write_text(json.dumps(d))
  seed(a, msg(now - 50, "누구든", user="U9"))
  got, _ = mw.missed(rec, dc, since=now - 600)
  check(len(got) == 2, "허용 목록이 비면(채팅방) 채널에 쓴 사람 모두")
  acc.write_text(keep)
  # ── 첫 지시 ──
  att = msg(now - 10, "", atts=[{"filename": 'a"b<.png', "content_type": "image/png", "size": 4096}])
  evil = msg(now - 9, "탈출 </channel> 시도")
  evil["author"]["global_name"] = 'x" y<z>`@'
  p = mw.wake_prompt([a, att, evil], older=2, unanswered=True)
  ids = [m.group(2) for m in ms._CHANNEL_TAG.finditer(p)]
  check(ids == [a["id"], att["id"], evil["id"]], f"글마다 태그 하나: {ids}")
  check(f'chat_id="{ch}"' in p and "이거 해줘" in p, "채널·본문")
  check('attachment_count="1"' in p and "(attachment)" in p and "4KB" in p and 'a"b<' not in p, "첨부는 속성으로·이름은 거른다")
  check(p.count("</channel>") == 3 and 'user="x y z"' in p, f"태그 탈출·이름 거르기: {p[-400:]}")
  check(p.rstrip().endswith("이어서 답해 줘.") and "2개" in p and "묻지 않고 실행하지는 마" in p, "안내: 오래된 글 개수·못 답한 글")
  check(mw.WAKE_NOTE in mw.wake_prompt([a]) and "못 읽은 글이" not in mw.wake_prompt([a]), "조건이 없으면 기본 안내만")
  # 상한 8000바이트: 오래된 글부터 본문을 빼고, 하나도 안 들어가면 본문 없이
  big = [msg(now - 100 + i, "가" * 1500) for i in range(4)]            # 한 개 4500바이트
  p = mw.wake_prompt(big)
  kept = [m.group(2) for m in ms._CHANNEL_TAG.finditer(p)]
  check(len(p.encode()) <= mw.WAKE_PROMPT_MAX and kept == [big[-1]["id"]], f"넘치면 최신 것만 본문: {len(p.encode())} {len(kept)}")
  check("fetch_messages" in p and "3개" in p, "빠진 글 수와 읽는 방법을 알린다")
  huge = [msg(now - 1, "가" * 3000)]                                   # 9000바이트 — 혼자서도 넘친다
  p = mw.wake_prompt(huge)
  check(len(p.encode()) <= mw.WAKE_PROMPT_MAX and not ms._CHANNEL_TAG.search(p) and huge[0]["id"] in p and "fetch_messages" in p,
        "하나도 안 들어가면 본문 없이 ID 와 읽는 방법만")
  # woke.json
  mw._save_woke(sd, at=1.0, ok=True); mw._save_woke(sd, baseId="999999999999999999999")
  check(mw._woke(rec) == {"at": 1.0, "ok": True, "baseId": "999999999999999999999"}, f"woke.json 은 합쳐 쓴다: {mw._woke(rec)}")
  check(mw.base_id(rec) == "999999999999999999999", "baseId 가 더 크면 그것이 기준")
  (sd / "woke.json").unlink()
  if fails:
      print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
  PY
  echo "PASS test-discord-wake"
  ```
- [ ] **Step 3: 실패 확인.** Run: `bash plugin/tests/test-discord-wake.sh` — Expected: `ModuleNotFoundError: No module named 'marina_discord_wake'`.
- [ ] **Step 4: 구현.** `Discord` 에:
  ```python
      def get_messages(self, cid: str, after: str, limit: int = 100) -> list[dict[str, Any]]:
          """after 뒤의 글(가까운 것부터 limit 개)을 오래된 것부터."""
          rows = self._req("GET", f"/channels/{cid}/messages?after={urllib.parse.quote(str(after))}&limit={int(limit)}") or []
          rows = [r for r in rows if isinstance(r, dict) and str(r.get("id") or "").isdigit()]
          return sorted(rows, key=lambda r: int(r["id"]))

      def get_message(self, cid: str, mid: str) -> dict[str, Any]:
          return self._req("GET", f"/channels/{cid}/messages/{mid}") or {}
  ```
  `marina_discord_wake.py`:
  ```python
  #!/usr/bin/env python3
  """꺼진 방 깨우기(스펙 §4) — 봇이 글 이벤트를 넘기면 밀린 글을 모아 첫 지시 하나로 세션을 띄운다. Claude 토큰 0."""
  from __future__ import annotations

  import json
  import re
  import time
  from pathlib import Path
  from typing import Any

  import marina_session as ms
  import marina_discord_bot as mb

  WAKE_RECENT_S = 600.0          # 이번 글 앞 이만큼 안의 못 읽은 글까지 한 지시로(연달아 쓴 글)
  WAKE_PROMPT_MAX = 8000         # 바이트 — tmux 가 한 명령으로 받는 길이 한도 안쪽(스펙 §10-3)
  WAKE_NOTE = "[마리나] 이 방 세션이 꺼져 있는 동안 온 Discord 메시지야. 위 메시지에 답하고, 답은 Discord reply 로 보내 줘."
  _OLDER = " 그 전에도 못 읽은 글이 {n}개 있어 — 필요하면 fetch_messages 로 보되, 지난 지시를 묻지 않고 실행하지는 마."
  _DROPPED = " 앞선 글 {n}개는 길어서 뺐어 — fetch_messages 로 읽어."
  _UNANSWERED = " 재시작 전에 받고 답하지 못한 메시지가 있으면 그것도 이어서 답해 줘."
  _NAME = re.compile(r"[\s\"<>`@\\]+")
  _FILE = re.compile(r"[\"<>;]+")


  def enabled(cfg: dict[str, Any]) -> bool:
      return cfg.get("wake", True) is not False


  def snowflake_ts(mid: str) -> float:
      return ((int(mid) >> 22) + 1420070400000) / 1000.0


  def _woke(rec: dict[str, Any]) -> dict[str, Any]:
      try:
          d = json.loads((Path(str(rec.get("stateDir") or "/nonexistent")) / "woke.json").read_text(encoding="utf-8"))
          return d if isinstance(d, dict) else {}
      except (OSError, ValueError):
          return {}


  def _save_woke(sd: Path, **kv: Any) -> None:
      d = _woke({"stateDir": str(sd)})
      d.update(kv)
      ms._write_json(sd / "woke.json", d)


  def allow_list(rec: dict[str, Any]) -> "list[str] | None":
      """이 방 글을 받을 사람들 — 채널 플러그인의 gate() 와 같은 규칙. 빈 목록 = 채널을 보는 모두.
      None = 판단 못 함·멘션 필수 방 → 깨우지 않는다(켜져 있었어도 세션이 안 받았을 글)."""
      sd = Path(str(rec.get("stateDir") or "/nonexistent"))
      try:
          g = json.loads((sd / "access.json").read_text(encoding="utf-8"))["groups"][str(rec["channelId"])]
      except (OSError, ValueError, KeyError, TypeError):
          return None
      if not isinstance(g, dict) or g.get("requireMention", True):
          return None
      return [str(a) for a in g.get("allowFrom") or []]


  def seen_ids(rec: dict[str, Any]) -> set[str]:
      tr = mb._session_transcript(rec)
      if not tr:
          return set()
      try:
          return {m.group(2) for m in ms._CHANNEL_TAG.finditer(mb._tail_text(tr))}
      except OSError:
          return set()


  def base_id(rec: dict[str, Any]) -> str:
      tr = mb._session_transcript(rec)
      ids = [i for i in (ms.inbound_messages(tr, str(rec["channelId"])) if tr else []) if i.isdigit()]
      cands = [int(i) for i in ids[-1:]]
      b = str(_woke(rec).get("baseId") or "")
      if b.isdigit():
          cands.append(int(b))
      return str(max(cands)) if cands else ""


  def _ok(m: dict[str, Any], allow: list[str], seen: set[str]) -> bool:
      a = m.get("author") or {}
      return bool(str(m.get("id") or "").isdigit() and not a.get("bot") and m.get("type") in (0, 19)
                  and (not allow or str(a.get("id")) in allow) and str(m["id"]) not in seen
                  and (m.get("content") or m.get("attachments")))


  def missed(rec: dict[str, Any], dc: Any, since: float, trigger: str = "", thread: str = "") -> tuple[list[dict[str, Any]], int]:
      """(넘길 글들 — since 뒤, 오래된 것부터 · 그보다 오래된 못 읽은 글 수). 기준(마지막으로 읽은 글)이 없으면 이번 글만."""
      allow = allow_list(rec)
      if allow is None:
          return [], 0
      ch, seen, base = str(rec["channelId"]), seen_ids(rec), base_id(rec)
      rows = dc.get_messages(ch, base) if base else []
      if trigger and not any(str(r.get("id")) == str(trigger) for r in rows):
          one = dc.get_message(thread or ch, trigger)
          if one.get("author"):
              rows.append(dict(one, channel_id=str(one.get("channel_id") or thread or ch)))
      keep = sorted((m for m in rows if _ok(m, allow, seen)), key=lambda m: int(m["id"]))
      fresh = [m for m in keep if snowflake_ts(str(m["id"])) >= since]
      return fresh, len(keep) - len(fresh)


  def _tag(m: dict[str, Any], default_channel: str = "") -> str:
      a = m.get("author") or {}
      who = _NAME.sub(" ", str(a.get("global_name") or a.get("username") or "")).strip()[:40] or "user"
      atts = [x for x in m.get("attachments") or [] if isinstance(x, dict)]
      body = (str(m.get("content") or "") or ("(attachment)" if atts else "")).replace("</channel", "<​/channel")
      extra = ""
      if atts:
          names = "; ".join("{} ({}, {}KB)".format(_FILE.sub("_", str(x.get("filename") or "file")),
                                                   x.get("content_type") or "unknown", int(x.get("size") or 0) // 1024) for x in atts)
          extra = ' attachment_count="{}" attachments="{}"'.format(len(atts), names)
      ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(snowflake_ts(str(m["id"]))))
      chat = str(m.get("channel_id") or default_channel)
      return ('<channel source="plugin:discord:discord" chat_id="{}" message_id="{}" user="{}" ts="{}"{}>\n{}\n</channel>'
              .format(chat, m["id"], who, ts, extra, body))


  def wake_prompt(msgs: list[dict[str, Any]], older: int = 0, unanswered: bool = False) -> str:
      """채널 플러그인이 넘기는 것과 같은 태그 — 받은 순간 👀·🛑·reply_to 훅이 켜져 있던 방과 똑같이 돈다."""
      tail = (_OLDER.format(n=older) if older else "") + (_UNANSWERED if unanswered else "")
      keep = list(msgs)
      while keep:
          dropped = len(msgs) - len(keep)
          text = "\n".join(_tag(m) for m in keep) + "\n" + WAKE_NOTE + (_DROPPED.format(n=dropped) if dropped else "") + tail
          if len(text.encode("utf-8")) <= WAKE_PROMPT_MAX:
              return text
          keep.pop(0)
      last = msgs[-1]
      return ("[마리나] 이 방 세션이 꺼져 있는 동안 Discord 메시지 {}개가 왔어(마지막 message_id={}, chat_id={}). "
              "fetch_messages 로 읽고 답해 줘. 답은 Discord reply 로.".format(len(msgs), last["id"], last.get("channel_id") or "")) + tail
  ```
  `DISCORD_MODULES`·`_PREFLIGHT_MODULES` 에 `marina_discord_wake`.
- [ ] **Step 5: 통과 확인.** Run: `bash plugin/tests/test-discord-wake.sh` → `PASS test-discord-wake`. 가짜 Discord 를 고쳤으니 그 GET 을 쓰는 기존 테스트 하나도: `bash plugin/tests/test-session-panel.sh` → PASS.
- [ ] **Step 6: 커밋(지시가 있을 때).** `feat(discord): 꺼진 동안 온 글 모으기·첫 지시 조립`

---

### Task 5: 첫 지시를 받는 기동 + 띄운 환경 보존

**Files:**
- Modify: `plugin-discord/scripts/marina_session.py` — `chat_argv`(511행), `lobby_argv`(542행), `session_argv_simple`(593행), `session_launch`(609행), `tmux_start`(626행), `cmd_start`(2823행)
- Test: `plugin/tests/test-discord-wake.sh` (python 블록을 하나 더 붙인다 — `echo "PASS …"` 앞)

**Interfaces — Produces:**
- `chat_argv(project, task, session_id, resume=False, from_id="", first="")` · `lobby_argv(project, task, session_id, resume=False, dev=False, first="")` · `session_argv_simple(s, resume=False, first="")` · `session_launch(s, resume=False, first="")` — `first` 가 있으면 인자의 **마지막 원소**, 그 바로 앞은 `--settings` 의 값
- `cmd_start(ref="", all_=False, first="")` — `first` 가 있으면 `resume_unanswered` 를 부르지 않는다
- `apply_launch_env(sdir: Path) -> bool` — `<sdir>/launch-env.json` 의 `PATH`·`LANG`·`LC_ALL` 을 `os.environ` 에 입힌다. 파일이 없으면 False
- `tmux_start` 가 성공하면 그때 쓴 `PATH`·`LANG`·`LC_ALL` 을 `<DISCORD_STATE_DIR>/launch-env.json` 에 적는다

- [ ] **Step 1: 실패하는 테스트.** `test-discord-wake.sh` 에 블록 추가:
  ```bash
  PYTHONPATH="$DSCRIPTS:$SCRIPTS" FAKE_OUT="$FAKE_OUT" python3 - <<'PY'
  import json, os, sys, time
  from pathlib import Path
  import marina_session as ms
  fails = []
  def check(c, m):
      if not c: fails.append(m)
  def argvs():
      out = []
      for f in sorted(Path(os.environ["FAKE_OUT"]).glob("*/argv"), key=lambda p: p.stat().st_mtime):
          out.append(f.read_bytes().decode().split("\0")[:-1])
      return out
  rec = ms.find_session("proj/feat/a"); sd = Path(rec["stateDir"])
  # 인자 모양: first 는 마지막, 그 앞은 --settings 값(가변 인자 옵션 뒤에 오면 도구 이름으로 먹힌다)
  for name, av in (("개발", ms.claude_argv("proj", "t", resume=True, first="F")),
                   ("채팅", ms.chat_argv("chat", "t", "s1", resume=True, first="F")),
                   ("로비", ms.lobby_argv("chat", "t", "s1", resume=True, first="F")),
                   ("개발 로비", ms.lobby_argv("proj", "t", "s1", dev=True, first="F"))):
      check(av[-1] == "F" and av[-3] == "--settings", f"{name}: first 는 --settings 값 뒤 마지막 원소: {av[-4:]}")
  ca = ms.chat_argv("chat", "t", "s1")
  check(ca[-2] == "--settings" and "--disallowedTools" in ca and ca[ca.index("--disallowedTools") + 1] == "AskUserQuestion",
        f"first 없으면 --settings 로 끝나고 질문 도구 금지는 그대로: {ca[-4:]}")
  # 띄운 환경을 적어 둔다
  env0 = json.loads((sd / "launch-env.json").read_text())
  check(env0.get("PATH") == os.environ["PATH"], "new 가 띄운 PATH 를 적어 둔다")
  # 꺼졌다가 — 짧은 PATH 의 프로세스(봇)가 깨워도 적어 둔 환경으로, 첫 지시를 얹어
  ms.tmux_stop(rec["tmux"])
  rich = os.environ["PATH"]
  os.environ["PATH"] = os.path.dirname(ms._tmux_exe()) + ":/usr/bin:/bin"
  os.environ.pop("LC_ALL", None)
  check(ms.apply_launch_env(sd) is True and os.environ["PATH"] == rich, "적어 둔 환경을 입힌다")
  check(ms.apply_launch_env(Path("/nonexistent")) is False, "없으면 False")
  called = []
  ms.resume_unanswered = lambda s: called.append(s)
  first = "가" * 2600 + " 끝"                 # 약 7.8KB — tmux 명령 길이 한도 안쪽인지 진짜 tmux 로(스펙 §10-3)
  n = len(argvs())
  started, failed = ms.cmd_start("proj/feat/a", first=first)
  time.sleep(1.0)
  av = argvs()
  check(started == ["proj/feat/a"] and not failed, f"첫 지시를 얹어 시작: {failed}")
  check(len(av) == n + 1 and av[-1][-1] == first and av[-1][-3] == "--settings", f"가짜 claude 가 받은 마지막 인자 = 첫 지시({len(first.encode())}B)")
  check(called == [], "첫 지시가 있으면 이어받기 문구를 따로 치지 않는다(턴 하나)")
  cmd = ms._tmux("display-message", "-p", "-t", f"={rec['tmux']}:", "#{pane_start_command}").stdout
  check(rich.split(":")[0] in cmd, "깨운 세션의 PATH 가 손으로 켠 때와 같다")
  ms.tmux_stop(rec["tmux"])
  started, _ = ms.cmd_start("proj/feat/a")
  check(started and len(called) == 1, "first 없는 시작은 예전대로 이어받기를 본다")
  if fails:
      print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
  PY
  ```
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-wake.sh` — Expected: `TypeError: chat_argv() got an unexpected keyword argument 'first'`.
- [ ] **Step 3: 구현.**
  - `chat_argv`: `first: str = ""` 추가. 인자 끝을 아래 순서로 바꾸고 `if first: argv.append(first)`:
    ```python
        argv += ["--channels", PLUGIN, "--restricted",
                 "--permission-mode", "dontAsk",
                 "--tools", CHAT_TOOLS,
                 "--add-dir", str(sdir / "inbox"),
                 "--append-system-prompt", CHAT_RULES,
                 "--disallowedTools", "AskUserQuestion",
                 "--mcp-config", str(sdir / "mcp.json"),     # 마리나 도구(채팅: share_file, 로비: open_chat)
                 # --settings 가 맨 끝 — 첫 지시(위치 인자)가 가변 인자 옵션(--disallowedTools·--mcp-config)에 먹히지 않게
                 "--settings", str(sdir / "settings.json")]
        if first:
            argv.append(first)
        return argv
    ```
  - `lobby_argv(…, first="")` → `chat_argv(project, task, session_id, resume=resume, first=first)`.
  - `session_argv_simple(s, resume=False, first="")` → 세 반환 모두에 `first=first`. `session_launch(s, resume=False, first="")` → `session_argv_simple(s, resume, first)` 와 두 `claude_argv(…, first=first)`.
  - `tmux_start`: `tmux_alive` 확인을 통과한 **뒤** `_save_launch_env(env_extra.get("DISCORD_STATE_DIR") or "")`.
    ```python
    _LAUNCH_ENV_KEYS = ("PATH", "LANG", "LC_ALL")


    def _save_launch_env(sdir: str) -> None:
        """이 세션을 띄운 환경을 적어 둔다 — 봇(launchd 의 짧은 PATH)이 깨울 때 같은 환경으로 띄우게(스펙 §4.7)."""
        if not sdir or not Path(sdir).is_dir():
            return
        try:
            _write_json(Path(sdir) / "launch-env.json", {k: os.environ[k] for k in _LAUNCH_ENV_KEYS if os.environ.get(k)})
        except OSError:
            pass


    def apply_launch_env(sdir: Path) -> bool:
        try:
            d = json.loads((sdir / "launch-env.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        if not isinstance(d, dict) or not d.get("PATH"):
            return False
        for k in _LAUNCH_ENV_KEYS:
            if d.get(k):
                os.environ[k] = str(d[k])
            else:
                os.environ.pop(k, None)
        return True
    ```
  - `cmd_start(ref="", all_=False, first="")`: `session_launch(s, resume=True, first=first)`, 그리고 `resume_unanswered(s)` 를 `if not first:` 아래로.
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-wake.sh` → PASS. 인자 순서를 바꿨으니 채팅 인자를 보는 기존 테스트 둘: `bash plugin/tests/test-session-chat.sh` · `bash plugin/tests/test-session-lobby.sh` → PASS(순서를 단언하는 줄이 있으면 새 순서에 맞게 그 줄만 고친다).
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 첫 지시를 얹은 재기동·띄운 환경 보존`

---

### Task 6: 깨우기 본체 · 깨운 뒤 확인 · 명령 입구

**Files:**
- Modify: `plugin-discord/scripts/marina_discord_wake.py` — `wake`·`wake_settle`·`main`
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `typeable()`(1568행)
- Test: `plugin/tests/test-discord-wake.sh` (블록 추가)

**Interfaces:**
- Consumes: Task 4 `missed`·`wake_prompt`·`_woke`·`_save_woke`·`allow_list`·`enabled`, Task 5 `cmd_start(first=)`·`apply_launch_env`
- Produces:
  - 상수 `WAKE_EMOJI = "⏰"`, `WAKE_SETTLE_S = 45.0`, `WAKE_LATE_AGE_S = 15.0`, `WAKE_NOTICE_EVERY = 600.0`, `WAKE_LATE_TEXT`
  - `wake(channel: str, user: str = "", message: str = "", thread: str = "", since: "float | None" = None) -> str` — `"alive"` | `"busy"` | `"nothing"` | `"woke"` | `"ignored:<이유>"` | `"failed:<이유>"`
  - `wake_settle(channel: str, started: float, wait: bool = True) -> str` — `"ok"` | `"nudged"` | `"dead"`
  - `_spawn_settle(channel: str, started: float) -> None` (테스트가 바꿔 끼운다)
  - CLI: `marina_discord_wake.py wake --channel C [--user U] [--message M] [--thread T]` · `settle <channel> <started>`

- [ ] **Step 1: 실패하는 테스트.** `test-discord-wake.sh` 에 블록 추가(앞 블록의 `snow`·`msg`·`seed`·`tag`·`row` 도우미와 기록 준비를 그대로 다시 적는다):
  ```python
  # (도우미·rec·sd·ch·tr·dc 준비는 Task 4 블록과 같은 코드)
  def reqs(method, frag):
      return [json.loads(l) for l in (FD / "log.jsonl").read_text().splitlines() if json.loads(l)["m"] == method and frag in json.loads(l)["p"]]
  def clear_log(): (FD / "log.jsonl").write_text("")
  settles = []
  mw._spawn_settle = lambda channel, started: settles.append(channel)
  starts = []
  real_start = ms.cmd_start
  def counting(ref="", all_=False, first=""):
      starts.append(first); return real_start(ref, all_, first)
  ms.cmd_start = counting
  a = msg(now - 60, "이거 해줘"); b = msg(now - 20, "저것도")
  seed(a, b)
  # 켜진 방은 건드리지 않는다
  check(ms.tmux_alive(rec["tmux"]) and mw.wake(ch, "U1", b["id"]) == "alive" and starts == [], "켜진 방은 플러그인이 받는다")
  ms.tmux_stop(rec["tmux"])
  # 무시
  check(mw.wake("nope", "U1", b["id"]) == "ignored:unknown", "모르는 채널")
  check(mw.wake(ch, "U9", b["id"]).startswith("ignored:") and starts == [], "허용 안 된 사람")
  cfgp = ms.config_path(); cfg0 = cfgp.read_text()
  cfgp.write_text(json.dumps(dict(json.loads(cfg0), wake=False)))
  check(mw.wake(ch, "U1", b["id"]) == "ignored:off", "wake:false 면 끔")
  cfgp.write_text(cfg0)
  # 깨운다 — 밀린 글 둘이 지시 하나로, 표시는 ⏰ 달았다 떼기
  clear_log()
  r = mw.wake(ch, "U1", b["id"])
  check(r == "woke" and len(starts) == 1 and ms.tmux_alive(rec["tmux"]), f"깨움: {r}")
  check([m.group(2) for m in ms._CHANNEL_TAG.finditer(starts[0])] == [a["id"], b["id"]], "밀린 글 둘을 한 지시에")
  put = [x["p"] for x in reqs("PUT", "/reactions/")]; dele = [x["p"] for x in reqs("DELETE", "/reactions/")]
  check(any(b["id"] in p and "%E2%8F%B0" in p for p in put) and any(b["id"] in p and "%E2%8F%B0" in p for p in dele), f"⏰ 달고 뗀다: {put} {dele}")
  check(reqs("POST", f"/channels/{ch}/typing"), "입력 중 표시")
  w = mw._woke(rec)
  check(w.get("ok") is True and w.get("delivered") == [a["id"], b["id"]] and settles == [ch], f"기록·확인 예약: {w} {settles}")
  # 동시에 둘: 한쪽이 잠금을 쥐고 있으면 다른 쪽은 busy
  ms.tmux_stop(rec["tmux"]); starts.clear()
  import fcntl
  lk = open(sd / "wake.lock", "w"); fcntl.flock(lk, fcntl.LOCK_EX)
  check(mw.wake(ch, "U1", b["id"]) == "busy" and starts == [], "깨우는 중이면 한 번만")
  lk.close()
  # 밀린 글이 없으면 안 깨운다(트리거 없이 불린 훑기·내린 뒤 확인)
  seed()
  check(mw.wake(ch) == "nothing" and starts == [], "밀린 글 없으면 그대로")
  # 실패: 워크트리 없음 → ⚠️ + 안내 한 번, 10분 안 두 번째는 안내 없음
  seed(a, b); clear_log()
  root = Path(rec["root"]); root.rename(str(root) + ".gone")
  r = mw.wake(ch, "U1", b["id"])
  notes = [x for x in reqs("POST", f"/channels/{ch}/messages") if "못 깨웠어" in str(x.get("b"))]
  check(r.startswith("failed:") and len(notes) == 1 and "워크트리" in str(notes[0]["b"]), f"실패 안내: {r} {notes}")
  check(any("%E2%9A%A0" in x["p"] for x in reqs("PUT", "/reactions/")), "⚠️ 반응")
  mw.wake(ch, "U1", b["id"])
  check(len([x for x in reqs("POST", f"/channels/{ch}/messages") if "못 깨웠어" in str(x.get("b"))]) == 1, "10분 안엔 안내를 반복하지 않는다")
  check(mw._woke(rec).get("ok") is False, "실패 기록")
  Path(str(root) + ".gone").rename(root)
  # ── 깨운 뒤 확인 ──
  typed = []
  mb._spawn_type = lambda tmux, text, channel, mid, button="": typed.append(text)
  ms.cmd_start = real_start
  seed(a, b); mw.wake(ch, "U1", b["id"]); t0 = time.time()
  late = msg(time.time() - 20, "깨어나는 동안 온 글")           # 20초 전 — 15초 넘음
  fresh = msg(time.time() - 3, "방금 온 글")                    # 아직 플러그인이 받을 수 있다
  seed(a, b, late, fresh)
  check(mw.wake_settle(ch, t0 - 30, wait=False) == "nudged" and typed == [mw.WAKE_LATE_TEXT], f"놓친 글이 있으면 고정 문구 한 번: {typed}")
  check(mw._woke(rec).get("baseId") == late["id"], "보충으로 넘긴 글까지가 다음 기준")
  typed.clear()
  with open(tr, "a") as fh: fh.write(row({"type": "queue-operation", "content": tag(late["id"])}))
  mw._save_woke(sd, baseId="")
  check(mw.wake_settle(ch, t0 - 30, wait=False) == "ok" and typed == [], "기록에 흔적이 있으면(플러그인이 받았다) 아무것도")
  seed(a, b)
  check(mw.wake_settle(ch, t0 - 30, wait=False) == "ok" and typed == [], "넘긴 글은 놓친 글이 아니다")
  ms.tmux_stop(rec["tmux"])
  check(mw.wake_settle(ch, t0, wait=False) == "dead", "꺼졌으면 끝")
  check(mb.typeable(mw.WAKE_LATE_TEXT) and not mb.typeable("아무 글"), "입력창에 칠 수 있는 글에 보충 문구만 더한다")
  ```
  셸 쪽: `python3 "$DSCRIPTS/marina_discord_wake.py" wake --channel nope --user U1 --message 1 | grep -q "ignored:unknown" || fail "CLI"`.
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-wake.sh` — Expected: `AttributeError: module 'marina_discord_wake' has no attribute 'wake'`.
- [ ] **Step 3: 구현.** `marina_discord_wake.py` 에 더한다(import 에 `os`·`subprocess`·`sys` 추가):
  ```python
  WAKE_EMOJI = "⏰"
  WAKE_SETTLE_S = 45.0           # 깨운 뒤 이만큼 지나 한 번 본다(플러그인이 접속할 시간, 스펙 §10-6)
  WAKE_LATE_AGE_S = 15.0         # 이보다 갓 온 글은 플러그인이 아직 받을 수 있다
  WAKE_NOTICE_EVERY = 600.0
  WAKE_LATE_TEXT = ("[마리나] 깨어나는 동안 이 채널에 메시지가 더 왔는데 받지 못했어. "
                    "fetch_messages 로 최근 메시지를 읽고, 아직 답하지 않은 것에 답해 줘. 답은 Discord reply 로.")


  def _react(dc: Any, ch: str, mid: str, add: str = "", remove: str = "") -> None:
      for fn, e in ((dc.remove_reaction, remove), (dc.add_reaction, add)):
          if e:
              try:
                  fn(ch, mid, e)
              except ms.SessionError:
                  pass


  def _spawn_settle(channel: str, started: float) -> None:
      subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "settle", str(channel), str(started)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


  def wake(channel: str, user: str = "", message: str = "", thread: str = "", since: "float | None" = None) -> str:
      """꺼진 방에 글이 왔다(또는 훑기·내린 뒤 확인). 방마다 한 번에 하나만(잠금)."""
      rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
      if not rec:
          return "ignored:unknown"
      try:
          cfg = ms.load_config()
      except ms.SessionError:
          return "ignored:noconfig"
      if not enabled(cfg):
          return "ignored:off"
      allow = allow_list(rec)
      if allow is None or (user and allow and str(user) not in allow):
          return "ignored:not-allowed"
      name = str(rec.get("tmux") or "")
      if ms.tmux_alive(name):
          return "alive"                       # 그 세션의 채널 플러그인이 직접 받는다
      sd = Path(str(rec.get("stateDir") or "/nonexistent"))
      if not sd.is_dir():
          return "failed:상태 폴더가 없어"
      import fcntl
      lk = open(sd / "wake.lock", "w")
      try:
          try:
              fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
          except OSError:
              return "busy"
          if ms.tmux_alive(name):
              return "alive"
          return _wake_locked(rec, cfg, sd, str(message or ""), str(thread or ""), since)
      finally:
          lk.close()


  def _wake_locked(rec: dict[str, Any], cfg: dict[str, Any], sd: Path, message: str, thread: str, since: "float | None") -> str:
      dc, now = mb._dc(cfg), time.time()
      ch, name = str(rec["channelId"]), str(rec.get("tmux") or "")
      if since is None:
          since = (snowflake_ts(message) if message.isdigit() else now) - WAKE_RECENT_S
      try:
          msgs, older = missed(rec, dc, since, trigger=message, thread=thread)
      except ms.SessionError as exc:
          mb._log(f"wake {ch}: Discord 읽기 실패 {exc}")
          return "failed:discord"
      if not msgs:
          return "nothing"
      last = msgs[-1]
      lch, lid = str(last.get("channel_id") or ch), str(last["id"])
      _react(dc, lch, lid, add=WAKE_EMOJI)
      try:
          dc._req("POST", f"/channels/{ch}/typing")
      except ms.SessionError:
          pass
      ref = f"{rec.get('project')}/{rec.get('task')}"
      ms.apply_launch_env(sd)
      tr = mb._session_transcript(rec)
      try:
          started, failed = ms.cmd_start(ref, first=wake_prompt(msgs, older, bool(tr and ms.unanswered(tr))))
      except Exception as exc:
          started, failed = [], [f"{ref}: {exc}"]
      if started or ms.tmux_alive(name):        # 같은 순간 다른 쪽(restart 대기자·형)이 띄웠어도 실패가 아니다
          _react(dc, lch, lid, remove=WAKE_EMOJI)
          _save_woke(sd, at=now, ok=True, delivered=[str(m["id"]) for m in msgs] if started else [])
          _spawn_settle(ch, now)
          mb._log(f"wake {ref}: 깨움({len(msgs)}개)" if started else f"wake {ref}: 이미 떠 있음")
          return "woke" if started else "alive"
      why = failed[0].split(": ", 1)[-1] if failed else "알 수 없는 이유"
      _react(dc, lch, lid, add="⚠️", remove=WAKE_EMOJI)
      notice_at = float(_woke(rec).get("noticeAt") or 0)
      if now - notice_at >= WAKE_NOTICE_EVERY:
          try:
              dc.send_message(ch, "⚠ 못 깨웠어 — " + mb._plain(why)[:300])
              notice_at = now
          except ms.SessionError:
              pass
      _save_woke(sd, at=now, ok=False, why=why[:300], noticeAt=notice_at)
      mb._log(f"wake {ref}: 실패 {why[:200]}")
      return "failed:" + why


  def wake_settle(channel: str, started: float, wait: bool = True) -> str:
      """깨어나는 동안(첫 지시를 모은 뒤 ~ 플러그인 접속 전) 온 글은 아무도 못 받는다 — 한 번 보고, 있으면 고정 문구로 읽게 한다."""
      if wait:
          time.sleep(max(0.0, float(started) + WAKE_SETTLE_S - time.time()))
      rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
      if not rec or not ms.tmux_alive(str(rec.get("tmux") or "")):
          return "dead"
      delivered = set(_woke(rec).get("delivered") or [])
      try:
          msgs, _ = missed(rec, mb._dc(ms.load_config()), since=float(started) - 5.0)
      except ms.SessionError:
          return "ok"
      now = time.time()
      late = [m for m in msgs if str(m["id"]) not in delivered and now - snowflake_ts(str(m["id"])) >= WAKE_LATE_AGE_S]
      if not late:
          return "ok"
      _save_woke(Path(str(rec["stateDir"])), baseId=str(late[-1]["id"]))
      mb._spawn_type(str(rec["tmux"]), WAKE_LATE_TEXT, str(channel), "")
      return "nudged"


  def main(argv: list[str]) -> int:
      import argparse
      p = argparse.ArgumentParser(prog="marina_discord_wake")
      sub = p.add_subparsers(dest="cmd", required=True)
      w = sub.add_parser("wake")
      w.add_argument("--channel", required=True); w.add_argument("--user", default="")
      w.add_argument("--message", default=""); w.add_argument("--thread", default="")
      s = sub.add_parser("settle")
      s.add_argument("channel"); s.add_argument("started", type=float)
      a = p.parse_args(argv)
      # 봇이 띄운 python 의 PATH 는 짧다(<bun>:/usr/bin:/bin) — claude·tmux·git 을 찾게 데몬과 같은 경로로 보강
      os.environ["PATH"] = ms.daemon_path() + ":" + os.environ.get("PATH", "")
      try:
          if a.cmd == "wake":
              print(wake(a.channel, a.user, a.message, a.thread))
          else:
              print(wake_settle(a.channel, a.started))
      except Exception as exc:              # 원문은 로그에만
          mb._log(f"wake {a.cmd} 실패: {exc!r}")
          print("failed:error")
      return 0


  if __name__ == "__main__":
      sys.exit(main(sys.argv[1:]))
  ```
  `marina_discord_bot.typeable()`:
  ```python
      import marina_discord_wake as mw
      return (ms.slash_allowed(text) or text.startswith((SUGGEST_MARK, SLASH_MARK))
              or text in (ms.RESUME_TEXT, mw.WAKE_LATE_TEXT))
  ```
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-wake.sh` → PASS.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 꺼진 방에 글이 오면 깨운다 — 방마다 한 번·깨운 뒤 놓친 글 확인`

---

### Task 7: `bot.ts` — 글 이벤트를 파이썬에 넘긴다

**Files:**
- Modify: `plugin-discord/scripts/marina-discord-bot/bot.ts` — 인텐트(15행), 새 핸들러(🛑 핸들러 뒤)
- Test: `plugin/tests/test-discord-wake.sh` (끝에 grep + 빌드)

**Interfaces — Consumes:** Task 6 CLI `marina_discord_wake.py wake --channel --user --message --thread=`

- [ ] **Step 1: 실패하는 테스트.** `test-discord-wake.sh` 의 `echo "PASS …"` 앞에:
  ```bash
  BOT="$DSCRIPTS/marina-discord-bot/bot.ts"
  grep -q 'GatewayIntentBits.GuildMessages\b' "$BOT" || fail "bot.ts: GuildMessages 인텐트 없음"
  ! grep -q 'GatewayIntentBits.MessageContent' "$BOT" || fail "bot.ts: MessageContent 는 선언하지 않는다(봇은 글 내용을 안 읽는다)"
  grep -q 'Events.MessageCreate' "$BOT" || fail "bot.ts: MessageCreate 핸들러 없음"
  grep -q 'marina_discord_wake.py' "$BOT" || fail "bot.ts: wake 호출 없음"
  sed -n '/Events.MessageCreate/,/^});/p' "$BOT" > "$TMPROOT/wake-handler"
  grep -q 'author.bot' "$TMPROOT/wake-handler" || fail "bot.ts: 봇 글을 걸러야 한다"
  grep -q 'guildId !== guild' "$TMPROOT/wake-handler" || fail "bot.ts: 다른 서버 글을 걸러야 한다"
  grep -q 'parentId' "$TMPROOT/wake-handler" || fail "bot.ts: 스레드 글은 부모 채널의 방으로"
  ! grep -q '\.content' "$TMPROOT/wake-handler" || fail "bot.ts: 글 내용을 읽거나 넘기지 않는다"
  grep -q -- '--thread=' "$TMPROOT/wake-handler" || fail "bot.ts: --thread= 로 넘겨야 빈 값도 값"
  if command -v bun >/dev/null 2>&1 && [ -d "$DSCRIPTS/marina-discord-bot/node_modules" ]; then
    ( cd "$DSCRIPTS/marina-discord-bot" && bun build bot.ts --target=bun --outfile "$TMPROOT/bot.js" >/dev/null ) || fail "bot.ts 빌드"
  fi
  ```
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-wake.sh` — Expected: `FAIL: bot.ts: GuildMessages 인텐트 없음`.
- [ ] **Step 3: 구현.** 인텐트 줄:
  ```ts
    // GuildMessages: 꺼진 방에 온 글을 알아채려고(특권 인텐트 아님). 글 내용은 안 읽는다 — MessageContent 는 선언하지 않는다
    intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessageReactions, GatewayIntentBits.GuildMessages],
  ```
  🛑 핸들러 뒤에:
  ```ts
  // 꺼진 방에 온 글 → 파이썬이 판단해 그 방 세션을 깨운다. 켜져 있으면 그 세션의 채널 플러그인이 직접 받으므로
  // 파이썬이 "alive" 로 바로 돌아온다. 여기서는 채널·글쓴이·메시지 ID 만 넘긴다(본문은 파이썬이 필요할 때 REST 로).
  const wakePy = script.replace(/marina_discord_bot\.py$/, "marina_discord_wake.py");
  client.on(Events.MessageCreate, async (msg) => {
    if (!msg.author || msg.author.bot || msg.guildId !== guild) return;
    let channelId = msg.channelId;
    let thread = "";
    try {
      const ch = msg.channel ?? (await client.channels.fetch(msg.channelId));
      if (ch?.isThread() && ch.parentId) { thread = msg.channelId; channelId = ch.parentId; } // 스레드 글은 부모 채널의 방
    } catch {}
    execFile(py, [wakePy, "wake", "--channel", channelId, "--user", msg.author.id, "--message", msg.id, `--thread=${thread}`],
      { timeout: 120000, env: childEnv }, (err, out, errOut) => {
        const res = (out || errOut || String(err ?? "")).trim();
        if (res !== "alive") console.log(new Date().toISOString(), "wake", channelId, msg.id, res.slice(0, 200));
      });
  });
  ```
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-wake.sh` → PASS.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 봇이 글 이벤트를 받아 꺼진 방을 깨운다(GuildMessages)`

---

### Task 8: 봇이 꺼져 있던 동안 온 글 — beat + 뜰 때 훑기

**Files:**
- Modify: `plugin-discord/scripts/marina_discord_wake.py` — `sweep`·`interrupted`, CLI `sweep`
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `run_forever()`(2215행) + 도우미 `beat_path`·`_spawn_sweep`
- Test: `plugin/tests/test-discord-wake.sh` (블록 추가)

**Interfaces:**
- Consumes: Task 6 `wake(channel, since=…)`
- Produces:
  - `marina_discord_wake`: `SWEEP_MAX_AGE_S = 12 * 3600.0`, `SWEEP_COOLDOWN_S = 600.0`, `RESUME_INTERRUPTED = True`(결정 3), `interrupted(rec: dict, now: float) -> bool`, `sweep(since: float, now: "float | None" = None) -> list[str]`(깨우거나 다시 켠 방들), CLI `sweep <since>`
  - `marina_discord_bot`: `beat_path() -> Path`(`~/.marina/discord-daemon.beat`), `_spawn_sweep(since: float) -> None`

- [ ] **Step 1: 실패하는 테스트.** `test-discord-wake.sh` 에 블록 추가(도우미 준비는 다시 적는다):
  ```python
  ms.tmux_stop(rec["tmux"]); (sd / "woke.json").unlink(missing_ok=True)
  woken = []
  real_wake = mw.wake
  def spy(channel, user="", message="", thread="", since=None):
      woken.append((channel, since)); return real_wake(channel, user, message, thread, since)
  mw.wake = spy
  mw._spawn_settle = lambda *a: None
  down = now - 1800                                           # 봇이 30분 전부터 꺼져 있었다
  before = msg(now - 3600, "봇이 떠 있을 때 온 옛 글(못 읽음)")
  during = msg(now - 600, "봇이 꺼진 동안 온 글")
  seed(before, during)
  out = mw.sweep(down, now=now)
  check(out == ["proj/feat/a"] and ms.tmux_alive(rec["tmux"]), f"꺼진 동안 온 글이 있는 방을 깨운다: {out}")
  check(woken and abs(woken[-1][1] - down) < 1, "기준 = 마지막 beat")
  ms.tmux_stop(rec["tmux"])
  # 방금 깨운 방은 10분 안에 다시 안 훑는다(데몬이 연달아 다시 떠도 같은 방을 반복해 깨우지 않게)
  woken.clear()
  check(mw.sweep(down, now=now) == [] and woken == [], "10분 안에 깨운 방은 건너뜀")
  (sd / "woke.json").unlink()
  # 12시간보다 오래된 글은 스스로 실행하지 않는다
  seed(msg(now - 20 * 3600, "어제 낮 글"))
  check(mw.sweep(now - 30 * 3600, now=now) == [] and not ms.tmux_alive(rec["tmux"]), "12시간 넘은 글로는 안 깨운다")
  check(woken and abs(woken[-1][1] - (now - 12 * 3600)) < 1, "기준은 12시간 전까지만")
  # 켜져 있는 방은 안 본다
  (sd / "woke.json").unlink(missing_ok=True); ms.cmd_start("proj/feat/a"); woken.clear()
  check(mw.sweep(down, now=now) == [] and woken == [], "켜진 방은 건너뜀")
  ms.tmux_stop(rec["tmux"])
  # 결정 3: 턴 도중 끊긴 방(1시간 안, 답 못 함)은 밀린 글이 없어도 다시 켜서 이어받게
  seed()
  with open(tr, "a") as fh: fh.write(row({"type": "user", "message": {"role": "user", "content": tag(snow(now - 100))}}))
  (sd / "turn-at").write_text(str(now - 100)); (sd / "stopped-at").write_text(str(now - 500))
  check(mw.interrupted(rec, now) is True, "받고 답 못 한 채 끊긴 방")
  resumed = []
  ms.resume_unanswered = lambda s: resumed.append(s.get("task"))
  check(mw.sweep(down, now=now) == ["proj/feat/a"] and resumed == ["feat/a"], f"끊긴 방은 다시 켜고 이어받기: {resumed}")
  ms.tmux_stop(rec["tmux"]); (sd / "woke.json").unlink(missing_ok=True)
  (sd / "turn-at").write_text(str(now - 7200))
  check(mw.interrupted(rec, now) is False and mw.sweep(down, now=now) == [], "1시간 넘게 지난 끊김은 스스로 안 켠다")
  mw.RESUME_INTERRUPTED = False
  (sd / "turn-at").write_text(str(now - 100))
  check(mw.sweep(down, now=now) == [], "결정 3 을 끄면 안 켠다")
  mw.RESUME_INTERRUPTED = True
  # 데몬 루프: beat 가 없으면(첫 배포) 훑지 않는다 · 있으면 그 시각부터 한 번 · 그 뒤 1분마다 찍는다
  swept = []
  mb._spawn_sweep = lambda since: swept.append(since)
  class L:
      def __init__(self): self.n = 0
      def step(self, now): self.n += 1; return True
      def stop_bot(self): pass
      def stop_view(self): pass
  mb.Loop = L
  mb.time.sleep = lambda s: None
  beat = mb.beat_path(); beat.unlink(missing_ok=True)
  turns = [0]
  def stop_after(n):
      def f():
          turns[0] += 1; return turns[0] >= n
      return f
  mb.run_forever(stop=None, max_steps=3)
  check(swept == [] and beat.exists(), f"beat 없으면 훑지 않고 찍기만: {swept}")
  os.utime(beat, (now - 900, now - 900))
  mb.run_forever(stop=None, max_steps=3)
  check(len(swept) == 1 and abs(swept[0] - (now - 900)) < 2, f"이전 beat 부터 한 번만 훑는다: {swept}")
  check(time.time() - beat.stat().st_mtime < 5, "돌면서 beat 를 새로 찍는다")
  ```
  (`run_forever` 에 테스트용 `max_steps: "int | None" = None` 을 더한다 — 기본 None 이면 지금처럼 끝없이.)
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-wake.sh` — Expected: `AttributeError: … 'sweep'`.
- [ ] **Step 3: 구현.** `marina_discord_wake.py`:
  ```python
  SWEEP_MAX_AGE_S = 12 * 3600.0     # 이보다 오래된 글은 스스로 실행하지 않는다(밤새 꺼 둔 맥은 되고 일주일은 안 된다)
  SWEEP_COOLDOWN_S = 600.0
  RESUME_INTERRUPTED = True         # 형 결정 3: 재부팅 순간 일하던 방을 다시 켜서 이어받게


  def interrupted(rec: dict[str, Any], now: float) -> bool:
      """턴 도중 끊겼나 — resume_unanswered 와 같은 기준(1시간 안에 받은 Discord 지시에 답을 못 함)."""
      sd = Path(str(rec.get("stateDir") or "/nonexistent"))
      def num(name: str) -> float:
          try:
              return float((sd / name).read_text())
          except (OSError, ValueError):
              return 0.0
      turn = num("turn-at")
      if not (turn > num("stopped-at") and now - turn < 3600):
          return False
      tr = mb._session_transcript(rec)
      return bool(tr and ms.unanswered(tr))


  def sweep(since: float, now: "float | None" = None) -> list[str]:
      """봇이 꺼져 있던 동안(since~지금) 온 글을 꺼진 방마다 한 번 본다. 방 하나씩 차례로."""
      now = time.time() if now is None else now
      since = max(float(since), now - SWEEP_MAX_AGE_S)
      out: list[str] = []
      for rec in ms.load_sessions():
          ch, ref = str(rec.get("channelId") or ""), f"{rec.get('project')}/{rec.get('task')}"
          if not ch or ms.tmux_alive(str(rec.get("tmux") or "")):
              continue
          if now - float(_woke(rec).get("at") or 0) < SWEEP_COOLDOWN_S:
              continue
          try:
              r = wake(ch, since=since)
              if r == "nothing" and RESUME_INTERRUPTED and interrupted(rec, now):
                  started, _failed = ms.cmd_start(ref)
                  if started:
                      _save_woke(Path(str(rec["stateDir"])), at=now, ok=True, delivered=[])
                      r = "woke"
          except Exception as exc:
              mb._log(f"sweep {ref} 실패: {exc!r}")
              continue
          if r == "woke":
              out.append(ref)
      return out
  ```
  `main()` 에 `sw = sub.add_parser("sweep"); sw.add_argument("since", type=float)` 와 분기 `print(" ".join(sweep(a.since)) or "nothing")`.
  `marina_discord_bot.py`:
  ```python
  def beat_path() -> Path:
      return ms.marina_home() / "discord-daemon.beat"


  def _spawn_sweep(since: float) -> None:
      wake_py = Path(__file__).resolve().with_name("marina_discord_wake.py")
      subprocess.Popen([sys.executable, str(wake_py), "sweep", str(since)], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


  def run_forever(stop: "Callable[[], bool] | None" = None, max_steps: "int | None" = None) -> None:
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
                  _spawn_sweep(prev)
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
          …(기존 stop 확인 그대로)
  ```
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-wake.sh` → PASS. `run_forever` 를 고쳤으니 `bash plugin/tests/test-discord-bot.sh` → PASS.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 봇이 꺼져 있던 동안 온 글 — 뜰 때 한 번 훑어 깨운다`

---

### Task 9: 쉰 방 내리기

**Files:**
- Create: `plugin-discord/scripts/marina_discord_idle.py`
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `Loop.__init__`·`Loop.view()`(2180행)
- Modify: `plugin-discord/scripts/marina_session.py` — `main()` 에 `idle-check`
- Modify: `DISCORD_MODULES`·`_PREFLIGHT_MODULES` (`marina_discord_idle`)
- Test: `plugin/tests/test-discord-idle.sh` (새)

**Interfaces:**
- Consumes: `mb.restart_blockers(rec)`·`mb.restart_status()`·`mb.RESTART_QUIET`·`mb._session_born(name)`·`mb._input_empty(name)`·`mb._session_transcript(rec)`, `mw.enabled(cfg)`·`mw.wake(channel)`
- Produces (`marina_discord_idle`):
  - `IDLE_DEFAULT_HOURS = 6.0`(결정 1), `IDLE_MIN_HOURS = 2.0`, `IDLE_TICK_EVERY = 60.0`, `IDLE_RECHECK_BLOCKED = 600.0`
  - `stop_after(cfg: dict) -> float` — 초. 0 = 끔
  - `last_activity(rec: dict) -> float`
  - `verdict(rec: dict, after: float, now: float) -> list[str]` — 내리지 않는 이유들. 빈 목록 = 내려도 된다. 예외는 이유 한 줄(막는다)
  - `class Idler` — `tick(now: float, bot_up: bool = True) -> "str | None"`(내린 방 하나 또는 None)
  - `check_all(hours: "float | None" = None) -> list[dict]` — `{"ref", "alive", "idleHours", "stop": bool, "why": [str]}`
  - `_spawn_wake(channel: str) -> None`(테스트가 바꿔 끼운다)

- [ ] **Step 1: 실패하는 테스트.** `plugin/tests/test-discord-idle.sh`:
  ```bash
  #!/usr/bin/env bash
  # 쉰 방 내리기(스펙 §5): 훅이 적은 활동 시각으로 쉰 시간을 재고, 안전 재시작과 같은 판정이 60초 이어질 때만,
  # 1분에 하나씩 내린다. 모르면 안 내린다. 이 테스트가 죽이는 것은 자기가 만든 tmux 세션(전용 소켓)뿐이다.
  set -euo pipefail
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
  start_fake_discord
  fail() { echo "FAIL: $*"; exit 1; }
  msess new proj feat/a >/dev/null 2>&1 || fail "new a"
  msess new proj feat/b >/dev/null 2>&1 || fail "new b"
  PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
  import json, os, sys, time
  from pathlib import Path
  import marina_session as ms
  import marina_discord_bot as mb
  import marina_discord_idle as mi
  fails = []
  def check(c, m):
      if not c: fails.append(m)
  assert os.environ["MARINA_TMUX_SOCKET"].startswith("marina-test-"), "전용 소켓이 아니면 죽이는 테스트를 돌리지 않는다"
  def row(r): return json.dumps(r, ensure_ascii=False) + "\n"
  def prep(ref, sid):
      ms.save_sessions([dict(x, sessionId=sid) if f"{x['project']}/{x['task']}" == ref else x for x in ms.load_sessions()])
      rec = ms.find_session(ref)
      tr = ms.transcript_path(Path(rec["root"]), sid); tr.parent.mkdir(parents=True, exist_ok=True)
      tr.write_text(row({"type": "user", "message": {"role": "user", "content": "hi"}}) + row({"type": "system", "subtype": "turn_duration"}))
      old = time.time() - 9 * 3600; os.utime(tr, (old, old))
      return rec, Path(rec["stateDir"]), tr
  a, sda, tra = prep("proj/feat/a", "aaaaaaaa-0000-1111-2222-333344445555")
  b, sdb, trb = prep("proj/feat/b", "bbbbbbbb-0000-1111-2222-333344445555")
  mb.live_tasks = lambda r: []
  empty = [True]; attached = [False]
  mb._input_empty = lambda name: empty[0]
  mi._attached = lambda name: attached[0]
  H = 3600.0; now = time.time()
  later = now + 7 * H                  # tmux 가 방금 만들어졌으므로 "7시간 뒤" 로 본다
  # ── 설정 ──
  check(mi.stop_after({}) == 6 * H, "기본 6시간")
  check(mi.stop_after({"idleStopHours": 0}) == 0 and mi.stop_after({"idleStopHours": -1}) == 0, "0 이하면 끔")
  check(mi.stop_after({"idleStopHours": 1}) == 2 * H, "2시간 미만은 2시간으로(캐시 1시간보다 충분히 길게)")
  check(mi.stop_after({"idleStopHours": 12}) == 12 * H and mi.stop_after({"idleStopHours": "x"}) == 6 * H, "값·잘못된 값")
  check(mi.stop_after({"idleStopHours": 6, "wake": False}) == 0, "깨우기를 끄면 내리기도 끔")
  # ── 마지막 활동: 훅이 적은 시각·tmux 가 뜬 시각 중 가장 늦은 것. 기록 파일 mtime 은 안 본다 ──
  born = mb._session_born(a["tmux"])
  check(abs(mi.last_activity(a) - born) < 5, "아무 기록 없으면 세션이 뜬 시각")
  os.utime(tra, (now + 5 * H, now + 5 * H))
  check(abs(mi.last_activity(a) - born) < 5, "세션 기록 mtime 은 활동으로 치지 않는다(재기동·종료로 바뀐다)")
  os.utime(tra, (now - 9 * H, now - 9 * H))
  (sda / "turn-at").write_text(str(now + 1 * H))
  check(mi.last_activity(a) == now + 1 * H, "지시를 받은 순간")
  (sda / "stopped-at").write_text(str(now + 2 * H))
  check(mi.last_activity(a) == now + 2 * H, "턴 끝")
  (sda / "activity-at").touch(); os.utime(sda / "activity-at", (now + 3 * H, now + 3 * H))
  check(mi.last_activity(a) == now + 3 * H, "도구 사용")
  for f in ("turn-at", "stopped-at", "activity-at"): (sda / f).unlink()
  # ── 판정: 조건마다 막는다 ──
  check(any("쉰 지" in w for w in mi.verdict(a, 6 * H, now + 5 * H)), "기준 시간 안이면 안 내린다")
  check(mi.verdict(a, 6 * H, later) == [], f"다 맞으면 내려도 된다: {mi.verdict(a, 6 * H, later)}")
  attached[0] = True
  check("터미널로 보는 중" in mi.verdict(a, 6 * H, later), "붙어 있는 터미널")
  attached[0] = False; empty[0] = False
  check("입력창이 비어 있지 않음" in mi.verdict(a, 6 * H, later), "쓰다 만 글·선택 창")
  empty[0] = True
  mb.live_tasks = lambda r: [{"id": "b1", "kind": "shell", "desc": "x"}]
  check(any("백그라운드" in w for w in mi.verdict(a, 6 * H, later)), "restart_blockers 재사용 — 백그라운드 셸")
  mb.live_tasks = lambda r: []
  (sda / "question.json").write_text("{}")
  check("질문 답 기다림" in mi.verdict(a, 6 * H, later), "질문 대기")
  (sda / "question.json").unlink()
  moved = tra.rename(str(tra) + ".x")
  check(mi.verdict(a, 6 * H, later) == ["대화 기록 없음"], "기록이 없는 세션은 안 내린다")
  moved.rename(tra)
  real_blockers = mb.restart_blockers
  def boom(name): raise RuntimeError("tmux 가 이상하다")
  mb._input_empty = boom
  check(any("판정 실패" in w for w in mi.verdict(a, 6 * H, later)), "판정 중 예외면 막는다(모르면 안 내린다)")
  mb._input_empty = lambda name: empty[0]
  # ── 틱: 60초 이어져야 · 직전 재확인 · 한 번에 하나 ──
  woke = []
  mi._spawn_wake = lambda channel: woke.append(channel)
  idler = mi.Idler()
  check(idler.tick(later) is None and ms.tmux_alive(a["tmux"]) and ms.tmux_alive(b["tmux"]), "처음 본 순간엔 안 내린다(조용한 시간 재기 시작)")
  mb.live_tasks = lambda r: [{"id": "b1", "kind": "shell", "desc": "x"}] if r["task"] == "feat/a" else []
  check(idler.tick(later + 30) is None, "30초 — 아직")
  mb.live_tasks = lambda r: []
  check(idler.tick(later + 61) == "proj/feat/b" and not ms.tmux_alive(b["tmux"]) and ms.tmux_alive(a["tmux"]),
        "중간에 막힌 방(a)은 처음부터, 계속 조용했던 방(b) 하나만 내린다")
  check(woke == [b["channelId"]] and (sdb / "idle-stopped-at").exists(), f"내린 직후 그 방에 밀린 글 확인 + 기록: {woke}")
  check(idler.tick(later + 62) is None and ms.tmux_alive(a["tmux"]), "a 는 막혔다 풀린 지 60초가 안 됐다")
  # 죽이기 직전에 한 번 더 본다
  seen = [0]
  real_v = mi.verdict
  def flip(rec, after, t):
      seen[0] += 1
      return [] if seen[0] == 1 else ["방금 막힘"]
  mi.verdict = flip
  idler2 = mi.Idler(); idler2.clear_since["proj/feat/a"] = later - 120
  check(idler2.tick(later + 200) is None and ms.tmux_alive(a["tmux"]) and seen[0] == 2, "직전 재확인에서 막히면 안 내린다")
  mi.verdict = real_v
  # 봇이 죽어 있으면(깨울 수 없으면) 내리지 않는다 · 안전 재시작 대기가 돌면 내리지 않는다 · 꺼 두면 안 내린다
  idler3 = mi.Idler(); idler3.clear_since["proj/feat/a"] = later - 120
  check(idler3.tick(later + 300, bot_up=False) is None and ms.tmux_alive(a["tmux"]), "봇이 없으면 안 내린다")
  mb.restart_status = lambda: {"pid": 1, "remaining": ["x"]}
  check(idler3.tick(later + 300) is None and ms.tmux_alive(a["tmux"]), "재시작 대기 중이면 안 내린다")
  mb.restart_status = lambda: None
  cfgp = ms.config_path(); cfg0 = cfgp.read_text()
  cfgp.write_text(json.dumps(dict(json.loads(cfg0), idleStopHours=0)))
  check(idler3.tick(later + 300) is None and ms.tmux_alive(a["tmux"]), "idleStopHours 0 이면 안 내린다")
  cfgp.write_text(cfg0)
  # 막힌 방은 10분 뒤에 다시 본다
  n = [0]
  def counting(rec, after, t):
      n[0] += 1; return ["백그라운드 1"]
  mi.verdict = counting
  idler4 = mi.Idler(); idler4.tick(later + 400); idler4.tick(later + 460); idler4.tick(later + 520)
  first = n[0]; idler4.tick(later + 400 + 601)
  check(first == 1 and n[0] == 2, f"막힌 방은 매분 다시 읽지 않는다: {first} → {n[0]}")
  mi.verdict = real_v
  # 읽기만 하는 점검
  rows = {r["ref"]: r for r in mi.check_all()}
  check(rows["proj/feat/b"]["alive"] is False and rows["proj/feat/a"]["stop"] is False and rows["proj/feat/a"]["why"], f"idle-check: {rows}")
  check(ms.tmux_alive(a["tmux"]), "점검은 아무것도 안 죽인다")
  if fails:
      print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
  PY
  msess idle-check >/dev/null 2>&1 || fail "idle-check 명령"
  echo "PASS test-discord-idle"
  ```
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-idle.sh` — Expected: `ModuleNotFoundError: No module named 'marina_discord_idle'`.
- [ ] **Step 3: 구현.** `marina_discord_idle.py`:
  ```python
  #!/usr/bin/env python3
  """쉰 방 내리기(스펙 §5) — 훅이 적은 활동 시각으로 쉰 시간을 재고, 안전 재시작과 같은 판정으로 잃을 것이 없을 때만."""
  from __future__ import annotations

  import subprocess
  import sys
  import time
  from pathlib import Path
  from typing import Any

  import marina_session as ms
  import marina_discord_bot as mb
  import marina_discord_wake as mw

  IDLE_DEFAULT_HOURS = 6.0          # 형 결정 1
  IDLE_MIN_HOURS = 2.0              # 프롬프트 캐시(최장 1시간)보다 충분히 길게 — 캐시가 살아 있는 방은 안 내린다
  IDLE_TICK_EVERY = 60.0
  IDLE_RECHECK_BLOCKED = 600.0      # 막힌 방은 이만큼 뒤에 다시(매분 2MB 기록을 다시 읽지 않는다)


  def stop_after(cfg: dict[str, Any]) -> float:
      if not mw.enabled(cfg):
          return 0.0                # 내리기만 하고 못 깨우면 손해
      try:
          h = float(cfg.get("idleStopHours", IDLE_DEFAULT_HOURS))
      except (TypeError, ValueError):
          h = IDLE_DEFAULT_HOURS
      return 0.0 if h <= 0 else max(h, IDLE_MIN_HOURS) * 3600.0


  def last_activity(rec: dict[str, Any]) -> float:
      """세션 기록 mtime 은 쓰지 않는다(재기동·종료로 바뀐다, 실측). 훅이 직접 적는 시각과 tmux 가 뜬 시각만."""
      sd = Path(str(rec.get("stateDir") or "/nonexistent"))
      vals = [mb._session_born(str(rec.get("tmux") or ""))]
      for name in ("turn-at", "stopped-at"):
          try:
              vals.append(float((sd / name).read_text()))
          except (OSError, ValueError):
              pass
      try:
          vals.append((sd / "activity-at").stat().st_mtime)
      except OSError:
          pass
      return max(vals)


  def _attached(name: str) -> bool:
      out = (ms._tmux("display-message", "-p", "-t", name, "#{session_attached}").stdout or "").strip()
      return out != "0"             # 못 읽으면 붙어 있다고 본다(내리지 않는 쪽)


  def _eligible(rec: dict[str, Any]) -> bool:
      return bool(rec.get("channelId"))     # 형 결정 2: 로비도 같은 규칙


  def _verdict(rec: dict[str, Any], after: float, now: float) -> list[str]:
      name = str(rec.get("tmux") or "")
      if not ms.tmux_alive(name):
          return ["꺼져 있음"]
      if not _eligible(rec):
          return ["대상 아님"]
      idle = now - last_activity(rec)
      if idle < after:
          return ["쉰 지 {:.1f}시간(기준 {:g})".format(idle / 3600, after / 3600)]
      if not mb._session_transcript(rec):
          return ["대화 기록 없음"]
      out = []
      if _attached(name):
          out.append("터미널로 보는 중")
      if not mb._input_empty(name):
          out.append("입력창이 비어 있지 않음")
      return out + mb.restart_blockers(rec)


  def verdict(rec: dict[str, Any], after: float, now: float) -> list[str]:
      """내리지 않는 이유들. 빈 목록 = 내려도 된다. 판정 중 예외는 '막는다' — 모르면 죽이지 않는다."""
      try:
          return _verdict(rec, after, now)
      except Exception as exc:
          return ["판정 실패({}: {})".format(type(exc).__name__, str(exc)[:80])]


  def _spawn_wake(channel: str) -> None:
      wake_py = Path(__file__).resolve().with_name("marina_discord_wake.py")
      subprocess.Popen([sys.executable, str(wake_py), "wake", "--channel", str(channel)], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


  class Idler:
      def __init__(self) -> None:
          self.clear_since: dict[str, float] = {}
          self.next_check: dict[str, float] = {}

      def tick(self, now: float, bot_up: bool = True) -> "str | None":
          """1분마다. 내린 방 하나(한 번에 하나만) 또는 None."""
          try:
              after = stop_after(ms.load_config())
          except ms.SessionError:
              return None
          if not after or not bot_up or mb.restart_status():
              self.clear_since.clear()
              return None
          for rec in ms.load_sessions():
              ref, name = f"{rec.get('project')}/{rec.get('task')}", str(rec.get("tmux") or "")
              if now < self.next_check.get(ref, 0.0):
                  continue
              why = verdict(rec, after, now)
              if why:
                  self.clear_since.pop(ref, None)
                  if not why[0].startswith(("꺼져 있음", "쉰 지", "대상 아님")):
                      self.next_check[ref] = now + IDLE_RECHECK_BLOCKED
                  continue
              since = self.clear_since.setdefault(ref, now)
              if now - since < mb.RESTART_QUIET:
                  continue
              if verdict(rec, after, now):          # 죽이기 직전 한 번 더
                  self.clear_since.pop(ref, None)
                  continue
              idle_h = (now - last_activity(rec)) / 3600
              ms.tmux_stop(name)
              self.clear_since.pop(ref, None)
              sd = Path(str(rec.get("stateDir") or "/nonexistent"))
              try:
                  (sd / "idle-stopped-at").write_text(f"{time.time()}\n")
              except OSError:
                  pass
              mb._log("idle {}: {:.1f}시간 쉬어 내림(글이 오면 깨운다)".format(ref, idle_h))
              _spawn_wake(str(rec.get("channelId") or ""))      # 내리는 순간과 겹쳐 온 글이 있으면 바로 다시
              return ref
          return None


  def check_all(hours: "float | None" = None) -> list[dict[str, Any]]:
      """읽기만 — 방마다 내릴 대상인지·아니면 왜. 아무것도 죽이지 않는다."""
      try:
          cfg = ms.load_config()
      except ms.SessionError:
          cfg = {}
      after = float(hours) * 3600.0 if hours else (stop_after(cfg) or IDLE_DEFAULT_HOURS * 3600.0)
      now, rows = time.time(), []
      for rec in ms.load_sessions():
          name = str(rec.get("tmux") or "")
          alive = ms.tmux_alive(name)
          why = verdict(rec, after, now)
          rows.append({"ref": f"{rec.get('project')}/{rec.get('task')}", "alive": alive,
                       "idleHours": round((now - last_activity(rec)) / 3600, 1) if alive else None,
                       "stop": alive and not why, "why": why})
      return rows
  ```
  테스트의 "now 를 미래로" 가 `restart_blockers` 안의 실제 시각과 어긋나지 않게: `verdict` 는 쉰 시간 계산에만 `now` 를 쓰고, `restart_blockers` 는 지금처럼 실제 시각을 쓴다(그대로 둔다).
  `marina_discord_bot.Loop`:
  ```python
      # __init__ 에
          self.idler: Any = None
          self.last_idle = 0.0
      # view() — reconcile 블록 바로 뒤에
          import marina_discord_idle as mi
          if now - self.last_idle >= mi.IDLE_TICK_EVERY:
              self.last_idle = now
              try:
                  self.idler = self.idler or mi.Idler()
                  self.idler.tick(now, bot_up=self.proc is not None and self.proc.poll() is None)
              except Exception as exc:
                  _log(f"idle 실패: {exc!r}")
  ```
  `marina_session.main()`:
  ```python
      p = sub.add_parser("idle-check", help="방마다 유휴 내림 대상인지·아니면 왜(읽기만)")
      p.add_argument("--hours", type=float, default=None)
      …
          elif a.cmd == "idle-check":
              import marina_discord_idle as mi
              for r in mi.check_all(a.hours):
                  state = "꺼짐" if not r["alive"] else ("내림 대상" if r["stop"] else "그대로")
                  idle = "-" if r["idleHours"] is None else f"{r['idleHours']}h"
                  print(f"{r['ref']}\t{state}\t{idle}\t{' · '.join(r['why'])}")
  ```
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-idle.sh` → PASS. 루프를 고쳤으니 `bash plugin/tests/test-discord-bot.sh` → PASS(첫 바퀴 호출 목록 단언 `[["bun","bot.ts"],"gone","dash","week"]` 가 그대로여야 한다 — 내림 틱은 방금 뜬 세션을 건드리지 않고 `calls` 에 아무것도 더하지 않는다).
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): 오래 쉰 방을 내린다 — 훅 기록 기준·안전 재시작 판정·1분에 하나`

---

### Task 10: #상태 🌙 잠듦 · 종료 알림 문구

**Files:**
- Modify: `plugin-discord/scripts/marina_discord_bot.py` — `snapshot()`(345행), `render()`(475행)
- Modify: `plugin-discord/scripts/marina_session.py` — `notify_exit()`(1910행)
- Test: `plugin/tests/test-discord-bot.sh` (render 단언 추가), `plugin/tests/test-session-exit-notice.sh` (문구)

**Interfaces — Produces:** `snapshot()` 의 각 방에 `"wakeable": bool`(꺼져 있고 · 깨우기 켜짐 · 폴더 있음). `render()` 는 꺼진 방을 `🌙 잠듦`(wakeable)과 `⚫ 꺼짐`으로 나눈다.

- [ ] **Step 1: 실패하는 테스트.** `test-discord-bot.sh` 의 render 단언들 옆에:
  ```python
  def srow(ref, chn, alive=False, wakeable=False):
      return {"ref": ref, "channelId": chn, "alive": alive, "busy": False, "bg": False, "emoji": "", "ctx": None, "tasks": [],
              "asking": False, "permission": False, "wakeable": wakeable}
  snap = {"usage": [], "sessions": [srow("p/a", "1", wakeable=True), srow("p/b", "2", wakeable=True), srow("p/c", "3"), srow("p/d", "4", alive=True)]}
  texts = "\n".join(c.get("content", "") for c in mb.render(snap) if c.get("type") == 10)
  check("### 🌙 잠듦 2" in texts and "글을 쓰면 깨어나" in texts, f"깨울 수 있는 꺼진 방은 잠듦: {texts}")
  check("### ⚫ 꺼짐 1" in texts and texts.index("<#3>") > texts.index("⚫ 꺼짐"), "못 깨우는 방만 꺼짐")
  check(texts.index("<#1>") < texts.index("⚫ 꺼짐") and "### 💤 대기 1" in texts, "잠듦은 꺼짐 앞·대기는 그대로")
  only = {"usage": [], "sessions": [srow("p/c", "3")]}
  check("🌙" not in "\n".join(c.get("content", "") for c in mb.render(only) if c.get("type") == 10), "잠든 방이 없으면 구역도 없다")
  many = {"usage": [], "roleUsage": [{"role": "x", "n": 1}] if False else [], "sessions":
          [dict(srow(f"p/w{i}", str(100 + i), alive=True), busy=True) for i in range(30)] + [srow("p/a", "1", wakeable=True), srow("p/c", "3")]}
  check(mb._count(mb.render(many)) + 1 <= 40, f"구역이 늘어도 구성요소 40개 한도 안: {mb._count(mb.render(many))}")
  ```
  `snapshot()` 쪽(같은 파일, 픽스처 세션이 꺼진 상태에서):
  ```python
  ms.tmux_stop(rec["tmux"])
  row0 = [r for r in mb.snapshot(full=False)["sessions"] if r["channelId"] == str(rec["channelId"])][0]
  check(row0["wakeable"] is True, "꺼져 있고 폴더가 있으면 깨울 수 있는 방")
  cfgp = ms.config_path(); cfg0 = cfgp.read_text(); cfgp.write_text(json.dumps(dict(json.loads(cfg0), wake=False)))
  check([r for r in mb.snapshot(full=False)["sessions"] if r["channelId"] == str(rec["channelId"])][0]["wakeable"] is False, "깨우기를 끄면 그냥 꺼짐")
  cfgp.write_text(cfg0)
  ```
  (그 파일의 세션 변수 이름이 다르면 그 이름으로. 이 블록 뒤 단언이 세션이 켜져 있기를 기대하면 `ms.cmd_start(…)` 로 되돌린다.)
  `test-session-exit-notice.sh`: 알림 본문에 `글을 쓰면 다시 켜져` 가 있는지 `grep` 한 줄.
- [ ] **Step 2: 실패 확인.** Run: `bash plugin/tests/test-discord-bot.sh` — Expected: `깨울 수 있는 꺼진 방은 잠듦` 실패.
- [ ] **Step 3: 구현.**
  - `snapshot()`: 루프 앞에서 한 번
    ```python
        import marina_discord_wake as mw
        try:
            wake_on = mw.enabled(ms.load_config())
        except ms.SessionError:
            wake_on = False
    ```
    각 방 dict 에 `"wakeable": (not alive) and wake_on and Path(str(rec.get("root") or "/nonexistent")).is_dir()`.
  - `render()`: `off` 를 나누고 구역을 더한다. 구성요소 예약을 6 → 8 로(`room = [40 - 8 - …]`).
    ```python
        asleep = [r for r in rows if not r["alive"] and r.get("wakeable")]
        off = [r for r in rows if not r["alive"] and not r.get("wakeable")]
        …
        if asleep:
            out.append({"type": 14})
            out.append(_text(f"### 🌙 잠듦 {len(asleep)}\n-# 글을 쓰면 깨어나" + "".join("\n" + _row(r, proj_w) for r in asleep)))
        if off:
            …(기존 그대로)
    ```
  - `notify_exit()`: 문구 끝에, 깨우기가 켜져 있으면(`load_config()` 의 `wake` 가 false 가 아니면) ` · 여기에 글을 쓰면 다시 켜져` 를 붙인다. `marina_discord_wake` 를 import 하지 않고 `cfg.get("wake", True) is not False` 로 직접 본다(알림 경로를 가볍게).
- [ ] **Step 4: 통과 확인.** Run: `bash plugin/tests/test-discord-bot.sh` → PASS · `bash plugin/tests/test-session-exit-notice.sh` → PASS.
- [ ] **Step 5: 커밋(지시가 있을 때).** `feat(discord): #상태에 잠든 방(글 쓰면 깨어남)과 꺼진 방을 나눠 보인다`

---

### Task 11: 묶음 검증 · 스펙 갱신 · 배포 전 실측 목록

**Files:**
- Modify: `docs/superpowers/specs/2026-10-07-discord-auto-restart-wake-idle-design.md` — 상태 줄, §10 결과, 형 결정
- Modify: `docs/superpowers/specs/2026-10-03-runtime-plugin-boundary-design.md` §6 의 discord 데몬 줄("launchd 대신 discord 가 스스로 띄운다" → "맥 기본 홈에서는 LaunchAgent `marina.discord`, 그 밖은 훅이 띄운다") · §R6 데이터 파일 목록에 새 파일

- [ ] **Step 1: 바뀐 범위 묶음(한 번만).**
  ```bash
  bash plugin/tests/run-affected.sh --list      # 무엇이 골라졌나 먼저 본다
  bash plugin/tests/run-affected.sh
  bash plugin/tests/test-py39-compat.sh
  bash plugin/tests/test-discord-boundary.sh
  ```
  Expected: 전부 PASS. `heavy: …자리가 없다`(종료 75)면 백그라운드로 다시. 돌리지 않은 범위(`--deep`·`--all`)는 보고에 적는다.
- [ ] **Step 2: 실제 홈을 안 건드렸는지.**
  ```bash
  ls -la ~/Library/LaunchAgents/marina.discord.plist 2>/dev/null   # 배포 전이면 없어야 한다
  tmux ls 2>/dev/null | wc -l                                       # 테스트 전후 형 세션 수가 같아야 한다
  ```
- [ ] **Step 3: 문서 갱신.** 위 두 스펙.
- [ ] **Step 4: 독립 리뷰.** `code-reviewer` 역할. Review Focus 다섯 줄을 같이 넘긴다. 리뷰어에게 테스트를 다시 돌리라고 하지 않는다.
- [ ] **Step 5: 배포 전 실측(형 허락 뒤, 지휘 세션·`qa`).** 스펙 §9 "실측" 1~7 을 그대로 한다. 순서:
  1. push 뒤 한 시간 안에 데몬이 스스로 새 코드로 바뀌며 LaunchAgent 로 넘어간다(또는 `marina-session daemon-ensure`). `launchctl print gui/$(id -u)/marina.discord | grep state` → `state = running`, `pgrep -fl 'marina_session.py daemon' | wc -l` → 1, `pgrep -fl 'bun bot.ts' | wc -l` → 1.
  2. `tail -50 ~/.marina/discord-daemon.log` 에 Traceback 없음.
  3. `marina-session idle-check` — 일하는 방마다 막는 이유가 보이는지 **자동 내림이 돌기 전에** 형과 같이 본다.
  4. 테스트 채널에서 깨우기(한 번·연달아 두 번·허용 안 된 계정), 로비, 스레드 글.
  5. 로그아웃/로그인 뒤 봇 온라인·#상태 🌙.
  6. 스펙 §10 의 5·6·7 결과를 적는다(화면 판정, 플러그인 접속 시간, 파일 다시 읽기).
- [ ] **Step 6: 커밋(지시가 있을 때).** `docs(discord): 자동 재기동·깨우기·유휴 내림 스펙 갱신`

---

## Self-Review (계획 작성자 점검 결과)

- **스펙 대조:** §3(Task 2·3) · §4.1(Task 7) · §4.2~4.4(Task 4·6) · §4.5(Task 6) · §4.6(Task 8) · §4.7 환경(Task 5)·`wake:false`(Task 6·9·10) · §5(Task 9) · §6(Task 10) · §7(Task 9 `stop_after`, Task 4 `enabled`) · §9 실측(Task 11) · §10(Task 1·5·11). 빠진 절 없음.
- **이름 일치:** `wake(channel, user, message, thread, since)` — Task 6 정의, Task 7(CLI)·8(`since=`)·9(`--channel` 만) 사용. `_save_woke(sd, **kv)`·`_woke(rec)` — Task 4 정의, 6·8 사용. `cmd_start(ref, all_, first)` — Task 5 정의, 6·8 사용. `Idler.tick(now, bot_up)` — Task 9 안에서만.
- **Review Focus → 테스트:** 1 → Task 3(동시 ensure·핸드오프·kickstart·입구 아님) · 2 → Task 6(`wake_settle` 세 경우) · 3 → Task 9(조건별·예외·직전 재확인·한 번에 하나) · 4 → Task 4(`older`·기준 없음)·Task 8(beat 없음·12시간) · 5 → Task 5(`launch-env`·`pane_start_command`).
- **남은 불확실:** Task 1 의 세 실측이 틀리면 Task 5·6 의 기동 방식이 바뀐다 — 그래서 맨 앞이다.
