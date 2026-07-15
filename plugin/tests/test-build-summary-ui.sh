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
rg -q 'data-build-reasons' "$WEB/app-4b-build.js"
rg -q '<details class="build-reasons"' "$WEB/app-4b-build.js"
rg -q '\.build-reasons' "$WEB/styles.css"
rg -q 'overflow-wrap: anywhere' "$WEB/styles.css"
rg -q 'function buildMemoryPressureHtml' "$WEB/app-4b-build.js"
rg -Fq 'memoryPressure?.sampleCount' "$WEB/app-4b-build.js"
rg -q 'hostAvailableMinMb' "$WEB/app-4b-build.js"
rg -q 'containersPeakMb' "$WEB/app-4b-build.js"
rg -q '관측 압력' "$WEB/app-4b-build.js"
rg -q 'data-build-pressure' "$WEB/app-4b-build.js"
rg -q '\.build-pressure' "$WEB/styles.css"

echo "PASS test-build-summary-ui"
