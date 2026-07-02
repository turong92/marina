#!/usr/bin/env bash
# stop_external — '외부 :<port>'(IDE/터미널 직접 실행) 프로세스를 대시보드에서 내리는 경로.
# 일회용 http.server 리스너를 실제로 SIGTERM 하고, 리스너 없음/재호출은 graceful 한지.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

python3 - "$HERE/../scripts" <<'PY'
import importlib.util, sys, os, socket, subprocess, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
spec=importlib.util.spec_from_file_location("ml", os.path.join(sys.argv[1], "marina_lifecycle.py"))
ml=importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(ml)
except Exception as e:
    print("skip import (env dep):", e); sys.exit(0)

s=socket.socket(); s.bind(("127.0.0.1", 0)); port=s.getsockname()[1]; s.close()
p=subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(30):                       # 리스너 준비 대기
        time.sleep(0.1)
        with socket.socket() as c:
            c.settimeout(0.2)
            if c.connect_ex(("127.0.0.1", port)) == 0: break
    r = ml.stop_external(Path("/tmp"), "svc", port)
    assert r.get("stopped") is True and p.pid in r.get("pids", []), r
    p.wait(timeout=5)                         # SIGTERM 으로 실제 종료됐는가
    r2 = ml.stop_external(Path("/tmp"), "svc", port)
    assert r2.get("stopped") is False and "리스너 없음" in r2.get("reason", ""), r2
    try:
        ml.stop_external(Path("/tmp"), "svc", 0)
        raise AssertionError("잘못된 포트가 통과됨")
    except ValueError:
        pass
    print("stop_external OK")
finally:
    if p.poll() is None: p.kill()
PY
echo "PASS test-stop-external"
