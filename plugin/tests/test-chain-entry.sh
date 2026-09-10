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

# procStart 는 UTC — 로컬 시각 ps 와 비교하면 진짜 호출자를 늘 거절한다.
PYTHONPATH="$SCR" python3 - <<'PY'
import os, subprocess
import marina_chain_runtime as R
mine = R._proc_start_utc(os.getpid())
ref = subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True, text=True,
                     env={**os.environ, "TZ": "UTC"}).stdout.strip()
assert mine and mine == ref and mine == mine.strip(), (mine, ref)
assert R.verify_caller.__defaults__[-1] is None
print("PASS: procStart UTC 비교")
PY
