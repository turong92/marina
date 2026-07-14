#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

rg -q 'id="buildSummary"' "$WEB/index.html"
rg -q 'app-4b-build.js' "$WEB/index.html"
rg -q 'function loadBuildSummary' "$WEB/app-4b-build.js"
rg -q 'loadBuildSummary\(root, run\)' "$WEB/app-4-logs.js"
rg -q '\.build-summary' "$WEB/styles.css"
rg -q 'data-build-step' "$WEB/app-4b-build.js"
rg -q 'setTimeout.*loadBuildSummary' "$WEB/app-4b-build.js"
rg -q 'max-height: 180px' "$WEB/styles.css"

echo "PASS test-build-summary-ui"
