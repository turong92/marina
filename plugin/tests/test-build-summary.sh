#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/run-001.log" <<'LOG'
$ marina start --all
BUILD SUCCESSFUL in 13s
#17 [search-api stage-0 3/8] RUN apt-get install ffmpeg
#17 CACHED
#29 [web internal] load build context
#29 transferring context: 775.83kB 5.1s done
#29 DONE 5.1s
#33 [web stage-0 5/5] RUN pnpm install --filter "web..."
#33 DONE 22.9s
#34 [web] exporting to image
#34 exporting layers 45.0s done
#34 unpacking to docker.io/library/web:latest 23.4s done
#34 DONE 68.5s
LOG

cat > "$TMP/run-failed.log" <<'LOG'
$ marina rebuild --web
BUILD FAILED in 2m 13s
#41 [web 4/4] RUN pnpm build
#41 ERROR: process "/bin/sh -c pnpm build" did not complete successfully: exit code: 1
LOG

python3 - "$HERE/../scripts" "$TMP/run-001.log" "$TMP/run-failed.log" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from marina_build import build_summary, write_build_meta

log = Path(sys.argv[2])
write_build_meta(log, {
    "status": "success",
    "op": "start",
    "startedAt": 100.0,
    "endedAt": 230.0,
    "durationSec": 130.0,
})
out = build_summary(log)
assert out["status"] == "success", out
assert out["durationSec"] == 130.0, out
assert out["cacheHits"] == 1, out
assert out["cacheMisses"] == 4, out
assert out["bottleneck"]["durationSec"] == 68.5, out
labels = [step["label"] for step in out["steps"]]
assert "Gradle pre-build" in labels, labels
assert any("pnpm install" in label for label in labels), labels
assert "load build context" in labels, labels
assert "exporting to image" in labels, labels
assert any(step["cached"] for step in out["steps"]), out

first = build_summary(log)
second = build_summary(log)
assert first == second
log.write_text(
    log.read_text(encoding="utf-8")
    + "#40 [web] resolving provenance\n#40 DONE 0.2s\n",
    encoding="utf-8",
)
third = build_summary(log)
assert len(third["steps"]) == len(second["steps"]) + 1, (second, third)

failed_log = Path(sys.argv[3])
write_build_meta(failed_log, {"status": "failed", "op": "rebuild"})
failed = build_summary(failed_log)
assert failed["status"] == "failed", failed
assert len(failed["steps"]) == 2, failed
assert failed["steps"][0]["durationSec"] == 133.0, failed
assert all(step["failed"] for step in failed["steps"]), failed
assert failed["bottleneck"]["label"] == "Gradle pre-build", failed
print(json.dumps(third, ensure_ascii=False))
PY

echo "PASS test-build-summary"
