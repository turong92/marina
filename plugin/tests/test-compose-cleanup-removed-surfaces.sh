#!/usr/bin/env bash
# cleanup regression: removed legacy compose surfaces must not be referenced from runtime scripts/UI.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"

hits="$(grep -rnE "compose-mounts|compose-assist|compose-analyze|composeHostForward|composeMounts|_save_project_hostforward|mounts\\.json|_parse_mounts|--mount" \
  "$ROOT/plugin/scripts" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "FAIL: removed compose cleanup refs remain"
  printf '%s\n' "$hits"
  exit 1
fi

echo "PASS test-compose-cleanup-removed-surfaces"
