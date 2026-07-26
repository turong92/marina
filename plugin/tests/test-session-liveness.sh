#!/usr/bin/env bash
# 세션 liveness(작업중→유휴 강등) — 정석 신호는 프로세스 cwd.
# 예전엔 `ps command=` 를 파싱해 `claude --resume <sid>` 에서 sid 를 뽑았는데, Claude Code 는 유저 프롬프트를 argv 로
# 넘겨(claude --resume <sid> <프롬프트>) ps 줄에 임의 텍스트가 붙어 따옴표(don't/it's/")에 파싱이 깨졌다 → 작업중
# 세션이 유휴로 오탐. 이 테스트는 (1)인자 없는 comm 으로 pid 를 뽑고 (2)cwd→root 로 liveness 를 세우며 (3)프롬프트
# 내용과 완전히 무관함을 못박는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
from pathlib import Path
scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
import marina_sessions as ms

fails = []

# 1) _parse_agent_pids: `ps -axo pid=,comm=` 출력(실행파일명, 인자 없음)에서 claude/codex pid만.
#    comm 에는 프롬프트가 절대 안 붙으므로 유저 입력에 오염될 여지 자체가 없다(정석).
ps_comm = "\n".join([
    "  111 /Library/Frameworks/Python.app/Contents/MacOS/Python",
    "  222 claude",                                   # bare 세션
    "  333 /opt/homebrew/bin/claude",                 # 경로 있는 resume/일반 세션
    "  444 codex",                                    # codex CLI
    "  555 /Applications/Foo.app/Contents/MacOS/node", # 무관(basename=node)
    "  666 /path/with/esbuild",                        # 무관
])
pids = ms._parse_agent_pids(ps_comm)
if set(pids) != {"222", "333", "444"}:
    fails.append(f"_parse_agent_pids should match by comm basename, got {pids}")

# 프롬프트가 argv 에 붙는 `command=` 형태여도(과거 입력원), comm 엔 인자가 없으니 파싱이 깨질 여지가 없음을 보이기 위해
# "claude" 라는 단어가 프롬프트에 들어가도 comm 이 아니면 잡히지 않는다(오탐 방지).
ps_noise = "  777 /usr/bin/vim   # editing a file about claude and codex"
if ms._parse_agent_pids(ps_noise) != []:
    fails.append(f"comm-based match must not false-positive on prompt words, got {ms._parse_agent_pids(ps_noise)}")

# 2) _root_has_live_agent: root == cwd, root 가 cwd 의 상위(서브폴더 실행), 무관.
ROOT = Path("/Users/sumin/work/wt")
if not ms._root_has_live_agent(ROOT, {ROOT}):
    fails.append("root == live cwd should be live")
if not ms._root_has_live_agent(ROOT, {ROOT / "packages/app"}):
    fails.append("live cwd inside root should mark root live")
if ms._root_has_live_agent(ROOT, {Path("/Users/sumin/work/other")}):
    fails.append("unrelated cwd must not mark root live")
if ms._root_has_live_agent(ROOT, {ROOT.parent}):   # 상위 디렉토리 cwd 는 매치 아님(방향 중요)
    fails.append("parent-dir cwd must not mark root live")
if ms._root_has_live_agent(None, {ROOT}):
    fails.append("None root should never be live")

# 2b) 중첩 워크트리 케이스 — marina 워크트리는 물리적으로 메인 루트 밑에 있다
#     (<main>/.claude/worktrees/<wt>). 메인 root 는 그 안에서 도는 agent 로 live 판정되면 안 된다
#     (메인 세션이 실제로 죽어도 강등 안 되는 버그) — 그러나 워크트리 root 자신은 자기 서브폴더
#     cwd 로 여전히 live 여야 한다.
MAIN_ROOT = Path("/Users/sumin/IdeaProjects/sumin/marina")
WT_ROOT = MAIN_ROOT / ".claude" / "worktrees" / "asdf"
if ms._root_has_live_agent(MAIN_ROOT, {WT_ROOT}):
    fails.append("main root must not be live from a nested worktree root cwd")
if ms._root_has_live_agent(MAIN_ROOT, {WT_ROOT / "packages/app"}):
    fails.append("main root must not be live from a cwd under a nested worktree")
if not ms._root_has_live_agent(WT_ROOT, {WT_ROOT / "packages/app"}):
    fails.append("worktree root should still be live from its own subfolder cwd")
if not ms._root_has_live_agent(WT_ROOT, {WT_ROOT}):
    fails.append("worktree root should still be live from its own exact cwd")

# 3) _downgrade_if_dead: root 에 살아있는 agent cwd 가 있으면 working 유지, 없으면 idle 강등.
#    sid/프롬프트와 완전히 무관 — item 에 sid 가 없어도(수동 bare 세션) root 만 live 면 유지.
live_root = {ROOT}
work = {"source": "claude", "sid": "", "status": "working", "statusTs": 1.0}
ms._downgrade_if_dead(work, live_root, ROOT)
if work["status"] != "working":
    fails.append(f"session in live root should stay working, got {work['status']} ({work.get('statusReason')})")

blocked = {"source": "claude", "sid": "x", "status": "blocked", "statusTs": 1.0}
ms._downgrade_if_dead(blocked, live_root, ROOT)
if blocked["status"] != "blocked":
    fails.append(f"blocked session in live root should stay blocked, got {blocked['status']}")

dead = {"source": "claude", "sid": "x", "status": "working", "statusTs": 1.0}
ms._downgrade_if_dead(dead, set(), ROOT)   # 살아있는 cwd 없음
if dead["status"] != "idle" or dead.get("statusReason") != "프로세스 없음":
    fails.append(f"session with no live agent in its root should downgrade to idle, got {dead}")

# 종료 상태(completed/waiting/idle)는 강등 대상 아님 — 건드리지 않는다.
done = {"source": "claude", "sid": "x", "status": "completed", "statusTs": 1.0}
ms._downgrade_if_dead(done, set(), ROOT)
if done["status"] != "completed":
    fails.append(f"completed status must be untouched, got {done['status']}")

if fails:
    print("FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("PASS: liveness via comm→cwd→root; prompt-content irrelevant; no false idle downgrade")
PY