#!/usr/bin/env bash
# 분리 B: runtime(marina 명령)이 없어도 discord 개발 세션이 돈다(스펙 R0) — 워크트리는 git 으로 직접, 잠금도 git, 서비스 시작은 건너뜀.
# runtime 이 있으면 `marina` 명령(CLI)으로만 부른다 — 파일(marina.sh)을 직접 부르지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
git -C "$SRC" branch dev-base; echo b > "$SRC/b"; git -C "$SRC" add b; git -C "$SRC" commit -qm b; git -C "$SRC" checkout -q -b dummy; git -C "$SRC" checkout -q main
export MARINA_RUNTIME_BIN=none     # runtime 없음
out="$(msess new proj feat/nr 2>&1)" || fail "runtime 없이 new: $out"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$SRC" "$FD" <<'PY'
import json, sys, subprocess
from pathlib import Path
src, fd = Path(sys.argv[1]), Path(sys.argv[2])
import marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
s = ms.find_session("proj/feat/nr"); root = Path(s["root"])
check(root == src / ".claude" / "worktrees" / "feat-nr" and (root / ".git").exists(), f"runtime 과 같은 위치: {root}")
check(subprocess.run(["git", "-C", str(root), "branch", "--show-current"], capture_output=True, text=True).stdout.strip() == "feat/nr", "브랜치 = 작업 이름")
lk = (Path(subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True).stdout.strip()) / "locked")
check(lk.exists() and lk.read_text().startswith("marina-session"), "git 잠금")
check(ms.runtime_bin() is None, "runtime 없음 판정")
import os
os.environ["MARINA_RUNTIME_BIN"] = "/nonexistent/marina"
check(ms.runtime_bin() is None, "가리킨 runtime 이 없으면 없음")
# 리뷰 D-I3: 데몬 PATH 가 짧아도 설치된 marina(runtime) 플러그인의 bin/marina 를 찾는다(옮기며 옛 '같은 플러그인 bin' 은 없어짐)
del os.environ["MARINA_RUNTIME_BIN"]
import tempfile
t = Path(tempfile.mkdtemp()); rt = t / "rt"; (rt / "bin").mkdir(parents=True)
(rt / "bin" / "marina").write_text("#!/bin/sh\n"); (rt / "bin" / "marina").chmod(0o755)
(t / "ch" / "plugins").mkdir(parents=True)
(t / "ch" / "plugins" / "installed_plugins.json").write_text(json.dumps({"plugins": {"marina@m": [{"installPath": str(rt)}]}}))
os.environ.update(MARINA_CLAUDE_HOME=str(t / "ch"), HOME=str(t), PATH="/usr/bin:/bin")
check(ms.runtime_bin() == str(rt / "bin" / "marina"), f"설치된 runtime bin: {ms.runtime_bin()}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
# 기준 브랜치 지정
out="$(msess new proj feat/nr2 --base dev-base 2>&1)" || fail "base: $out"
[ ! -f "$SRC/.claude/worktrees/feat-nr2/b" ] || fail "base=dev-base 에서 시작해야(b 없음)"
# 리뷰 I4: base 를 안 주면 runtime 과 같은 규칙(origin/HEAD) — 메인 체크아웃이 다른 브랜치에 있어도 그 커밋을 안고 태어나지 않는다
git init -q --bare "$TMPROOT/origin.git"; git -C "$SRC" remote add origin "$TMPROOT/origin.git"; git -C "$SRC" push -q origin main
git -C "$SRC" remote set-head origin main
git -C "$SRC" checkout -q -b feature/x; echo fx > "$SRC/fx"; git -C "$SRC" add fx; git -C "$SRC" commit -qm fx
out="$(msess new proj fix/y 2>&1)" || fail "fix/y: $out"
[ ! -f "$SRC/.claude/worktrees/fix-y/fx" ] || fail "I4: 메인 체크아웃의 feature/x 커밋을 안고 태어났다"
git -C "$SRC" checkout -q main
echo "PASS test-session-no-runtime"
