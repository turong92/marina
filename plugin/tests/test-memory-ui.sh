#!/usr/bin/env bash
# Dashboard memory contract: compact Docker/host telemetry and guarded lifecycle retries.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
HTML="$WEB/index.html"
UTIL="$WEB/app-3-util.js"
ACTIONS="$WEB/app-5b-actions.js"
CSS="$WEB/styles.css"

# The old derived RSS/system summary is ambiguous. The toolbar exposes paired,
# independently hideable Docker and host fields instead.
! rg -q 'dev = marina 추적 서비스' "$HTML" || { echo "FAIL: old ambiguous memory tooltip remains"; exit 1; }
rg -q 'id="memDocker"' "$HTML" || { echo "FAIL: Docker memory field missing"; exit 1; }
rg -q 'id="memHost"' "$HTML" || { echo "FAIL: host memory field missing"; exit 1; }
rg -q 'Docker \$\{formatMemoryPair' "$UTIL" || { echo "FAIL: Docker usage copy missing"; exit 1; }
rg -q 'Host available \$\{formatMemoryGb' "$UTIL" || { echo "FAIL: host availability copy missing"; exit 1; }
rg -q 'docker\.usedMb' "$UTIL" || { echo "FAIL: Docker snapshot use missing"; exit 1; }
rg -q 'host\.availableMb' "$UTIL" || { echo "FAIL: host snapshot use missing"; exit 1; }
rg -q 'function formatMemoryGb' "$UTIL" || { echo "FAIL: safe GB formatter missing"; exit 1; }
rg -q 'function formatMemoryPair' "$UTIL" || { echo "FAIL: compact Docker formatter missing"; exit 1; }
rg -q 'function memoryBlockConfirmation' "$UTIL" || { echo "FAIL: memory block confirmation formatter missing"; exit 1; }
! rg -q 'toFixed.*undefined|NaN' "$UTIL" || { echo "FAIL: unsafe memory formatting remains"; exit 1; }

# Both individual and start-all actions must ask before issuing their one forced retry.
rg -Fq "if (result?.blocked === 'low-memory' && !force)" "$UTIL" || { echo "FAIL: guarded block handling missing"; exit 1; }
rg -Fq 'confirm(memoryBlockConfirmation(result))' "$UTIL" || { echo "FAIL: memory override confirmation missing"; exit 1; }
rg -Fq 'return action(type, root, service, true)' "$UTIL" || { echo "FAIL: individual force retry missing"; exit 1; }
rg -Fq 'return sessionAction(type, session, true)' "$UTIL" || { echo "FAIL: start-all force retry missing"; exit 1; }
rg -Fq 'JSON.stringify({root: session.root, force})' "$UTIL" || { echo "FAIL: start-all force payload missing"; exit 1; }
rg -q 'projectedFreeMb' "$UTIL" || { echo "FAIL: projected memory confirmation missing"; exit 1; }
rg -q 'estimatedServices' "$UTIL" || { echo "FAIL: largest estimated services missing"; exit 1; }
rg -q 'unknownServices' "$UTIL" || { echo "FAIL: unknown services confirmation missing"; exit 1; }
rg -q 'docker-projected' "$UTIL" || { echo "FAIL: projected-pressure reason copy missing"; exit 1; }

# Service rows place current use in the existing right metadata slot and retain
# peak/limit/OOM detail in a title. OOM augments the normalized state reason.
rg -q 'memoryUsageMb' "$ACTIONS" || { echo "FAIL: service current memory missing"; exit 1; }
rg -q 'memoryPeakMb' "$ACTIONS" || { echo "FAIL: service peak memory missing"; exit 1; }
rg -q 'memoryLimitMb' "$ACTIONS" || { echo "FAIL: service memory limit missing"; exit 1; }
rg -q 'oomKilled' "$ACTIONS" || { echo "FAIL: service OOM state missing"; exit 1; }
rg -q 'function serviceStateReason' "$ACTIONS" || { echo "FAIL: OOM state reason helper missing"; exit 1; }
rg -q 'data-rss' "$ACTIONS" || { echo "FAIL: service memory metadata slot missing"; exit 1; }
rg -q '\.mem-separator' "$CSS" || { echo "FAIL: compact telemetry separator styles missing"; exit 1; }

node - "$UTIL" <<'JS'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const requests = [];
let confirmations = 0;
const lowMemory = {
  blocked: 'low-memory',
  reason: 'docker-projected',
  projectedFreeMb: 512,
  reserveMb: 4096,
  estimatedServices: [{service: 'web', memoryMb: 8192}],
  unknownServices: ['worker'],
};
const context = {
  console,
  fetch: async (path, options) => {
    requests.push({path, body: JSON.parse(options.body)});
    const blocked = requests.length === 1 || requests.length === 3;
    return {ok: true, json: async () => blocked ? lowMemory : {starting: true}};
  },
  confirm: message => {
    confirmations += 1;
    if (/undefined|NaN/.test(message)) throw new Error(`unsafe confirmation: ${message}`);
    if (!message.includes('예상 Docker 여유') || !message.includes('큰 추정') || !message.includes('알 수 없는 서비스')) {
      throw new Error(`missing memory details: ${message}`);
    }
    return true;
  },
  load: async () => {},
  selectLog: () => {},
  selected: {mode: 'service'},
};
vm.createContext(context);
vm.runInContext(`${source}\nthis.__test = {action, sessionAction, formatMemoryPair};`, context);
(async () => {
  if (context.__test.formatMemoryPair(11060, 15972) !== '10.8 / 15.6 GB') throw new Error('compact Docker format mismatch');
  await context.__test.action('start', '/project', 'web');
  await context.__test.sessionAction('start-all', {root: '/project'});
  if (confirmations !== 2) throw new Error(`expected two confirmations, got ${confirmations}`);
  if (requests.length !== 4) throw new Error(`expected four lifecycle requests, got ${requests.length}`);
  if (requests[0].body.force !== false || requests[1].body.force !== true) throw new Error('individual retry force contract failed');
  if (requests[2].body.force !== false || requests[3].body.force !== true) throw new Error('start-all retry force contract failed');
})().catch(error => { console.error(error.stack || error); process.exit(1); });
JS

echo "PASS test-memory-ui"
