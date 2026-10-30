#!/usr/bin/env bash
# (실사용 2026-10-30) 에이전트가 'marina logs web | rg …' 를 부르면 logs -f 가 끝나지 않아 며칠씩 남았다
#  — 방 백그라운드 작업에 찍히고, 원격 프로젝트면 박스 ssh 접속도 하나씩 붙들었다(맥에 15개).
#  터미널이 아니면 따라가지 않고 최근 줄만 찍고 끝난다. 터미널에서는 지금처럼 따라간다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)" python3 - <<'PY'
import importlib.util, os, sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("mc", os.environ["SCRIPTS"] + "/marina-compose.py")
mc = importlib.util.module_from_spec(spec); sys.argv = ["x"]; spec.loader.exec_module(mc)
calls = []
mc.subprocess.call = lambda argv, env=None: calls.append(argv) or 0
mc._lifecycle_env = lambda *a, **k: {}
a = SimpleNamespace(project_id="p", session="s", no_follow=False, service=["web"], session_dir=None)
class Out:
    def __init__(self, tty): self.tty = tty
    def isatty(self): return self.tty
real = sys.stdout
sys.stdout = Out(False); mc.cmd_logs(a); piped = calls.pop()
sys.stdout = Out(True); mc.cmd_logs(a); term = calls.pop()
sys.stdout = real
assert "-f" not in piped, f"터미널이 아니면 따라가면 안 된다: {piped}"
assert any(x.startswith("--tail") for x in piped), f"터미널이 아니면 최근 줄만: {piped}"
assert "-f" in term, f"터미널에서는 따라간다: {term}"
print("PASS")
PY
