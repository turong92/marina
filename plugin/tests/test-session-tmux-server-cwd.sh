#!/usr/bin/env bash
# (2026-10-29) tmux 서버는 처음 띄운 프로세스의 cwd 를 물려받는다. 봇이 플러그인 캐시 폴더에서 띄웠더니 자동 업데이트가
#  그 폴더를 지운 뒤 리퍼가 'cwd 사라진 고아'로 보고 서버를 죽여 모든 방이 꺼졌다 → marina 는 tmux 를 홈에서 부른다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"

WORK="$(mktemp -d)"; trap 'tmux -L "$MARINA_TMUX_SOCKET" kill-server 2>/dev/null || true; rm -rf "${WORK:?}"' EXIT
cd "$WORK"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import os, subprocess, sys
from pathlib import Path
import marina_session as ms
r = ms._tmux("new-session", "-d", "-s", "cwdtest", "sleep 30")
assert r.returncode == 0, r.stderr
pid = ms._tmux("display-message", "-p", "-t", "cwdtest", "#{pid}").stdout.strip()
out = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
cwd = next((l[1:] for l in out.splitlines() if l.startswith("n")), "")
want = os.path.realpath(str(Path.home()))
if os.path.realpath(cwd) != want:
    print(f"FAIL: tmux 서버 cwd={cwd!r} (기대 {want!r})"); sys.exit(1)
PY
echo "PASS test-session-tmux-server-cwd"
