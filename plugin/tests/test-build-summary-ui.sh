#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

grep -qE 'id="buildSummary"' "$WEB/index.html"
grep -qE 'app-4b-build.js' "$WEB/index.html"
grep -qE 'function loadBuildSummary' "$WEB/app-4b-build.js"
grep -qE 'loadBuildSummary\(root, run\)' "$WEB/app-4-logs.js"
grep -qE '\.build-summary' "$WEB/styles.css"
grep -qE 'data-build-step' "$WEB/app-4b-build.js"
grep -qE 'setTimeout.*loadBuildSummary' "$WEB/app-4b-build.js"
grep -qE 'max-height: 180px' "$WEB/styles.css"
grep -qE 'data-build-reasons' "$WEB/app-4b-build.js"
grep -qE '<details class="build-reasons"' "$WEB/app-4b-build.js"
grep -qE '\.build-reasons' "$WEB/styles.css"
grep -qE 'overflow-wrap: anywhere' "$WEB/styles.css"
grep -qE 'function buildMemoryPressureHtml' "$WEB/app-4b-build.js"
grep -qF 'memoryPressure?.sampleCount' "$WEB/app-4b-build.js"
grep -qF 'finiteMemoryMb(memoryPressure?.sampleCount)' "$WEB/app-4b-build.js"
grep -qE 'hostAvailableMinMb' "$WEB/app-4b-build.js"
grep -qE 'containersPeakMb' "$WEB/app-4b-build.js"
grep -qE '관측 압력' "$WEB/app-4b-build.js"
grep -qE 'data-build-pressure' "$WEB/app-4b-build.js"
grep -qE '\.build-pressure' "$WEB/styles.css"

echo "PASS test-build-summary-ui"
