#!/usr/bin/env bash
# 상주 프로세스(runtimed 게이트웨이 갱신)는 projects.json 이 바뀌면 다시 읽어야 한다 —
# 기동 뒤 등록한 프로젝트의 게이트웨이 주소가 빈 200 이던 것(2026-11-09 story-chat qwen-airi-spike).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "${TMPROOT:?}"' EXIT
mkdir -p "$TMPROOT/a" "$TMPROOT/b"
printf '{"projects":[{"id":"a","root":"%s"}]}\n' "$TMPROOT/a" > "$MARINA_HOME/projects.json"
PYTHONPATH="$HERE/../scripts" TMPROOT="$TMPROOT" python3 - <<'PY'
import json, os, time
from pathlib import Path
import marina_registry as reg
from marina_state import PROJECTS_FILE
tmp = os.environ["TMPROOT"]
first = [p["id"] for p in reg.load_projects()]
assert first == ["a"], first
assert [str(r) for r in reg.discover_all_roots()] == [str(Path(tmp, "a").resolve())]
time.sleep(0.01)
PROJECTS_FILE.write_text(json.dumps({"projects": [{"id": "a", "root": tmp + "/a"}, {"id": "b", "root": tmp + "/b"}]}))
got = [p["id"] for p in reg.load_projects()]
assert got == ["a", "b"], f"파일이 바뀌면 다시 읽는다: {got}"
roots = [str(r) for r in reg.discover_all_roots()]
assert str(Path(tmp, "b").resolve()) in roots, f"뿌리 목록 캐시도 같이 비운다: {roots}"
assert reg.load_projects() is reg.load_projects(), "안 바뀌면 캐시 그대로"
PY
echo "PASS test-registry-reload"
