#!/usr/bin/env bash
# 역할 방은 자기 argv 로 뜨고, 저장본(launch)엔 프롬프트가 없고, role 이 남는다(스펙 4.2·5.5).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, os, tempfile
from pathlib import Path
import marina_term as T
import marina_roles as R

home = Path(os.environ["MARINA_HOME"])
fake = home / "fake-shell"; fake.write_text("#!/bin/sh\nexec sleep 5\n"); fake.chmod(0o755)
os.environ["SHELL"] = str(fake)
root = Path(tempfile.mkdtemp())
defn = R.load_role(root, "reviewer", home=Path(tempfile.mkdtemp()))
비밀 = "역할 방 첫 프롬프트 — 저장본에 남으면 안 된다"
res = T.term_open(root, 80, 24, agent_source="claude", agent_sid="", agent_prompt=비밀,
                  agent_role="reviewer", agent_role_argv=R.role_cli(defn, 비밀),
                  agent_role_launch=R.role_cli(defn, ""))
tid = res["tid"]
try:
    meta = json.loads((T._terms_dir() / f"{tid}.json").read_text())
finally:
    T.term_kill(tid)
blob = json.dumps(meta, ensure_ascii=False)
assert 비밀 not in blob, f"저장본에 프롬프트가 남았다: {blob}"
assert meta["role"] == "reviewer", meta
assert meta["launch"] == R.role_cli(defn, ""), meta["launch"]
assert "--permission-mode" in meta["launch"] and meta["profile"] == "" and meta["lean"] is False, meta
assert meta["key"] == "", "역할 방은 재사용 키가 없다"
# 재시작 복원에도 role 이 남는다
agent = {"source": "claude", "sid": "s", "role": "reviewer"}
T._by_tid.clear(); T._by_key.clear(); T._reconstructed = False
(T._terms_dir()).mkdir(parents=True, exist_ok=True)
pid = os.getpid()
(T._terms_dir() / "t-role.json").write_text(json.dumps({"tid": "t-role", "cwd": str(root), "pid": pid,
    "pid_start": T._pid_start(pid), "source": "claude", "sid": "s", "key": "", "role": "reviewer", "created": 1.0}))
T._reconstruct_registry()
assert T._by_tid["t-role"].agent.get("role") == "reviewer", T._by_tid["t-role"].agent
print("PASS: 역할 방 argv·저장본·role 복원")
PY
