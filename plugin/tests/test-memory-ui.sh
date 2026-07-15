#!/usr/bin/env bash
# Dashboard memory contract: compact Docker/host telemetry and guarded lifecycle retries.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
HTML="$WEB/index.html"
UTIL="$WEB/app-3-util.js"
ACTIONS="$WEB/app-5b-actions.js"
SESSIONS="$WEB/app-5-sessions.js"
BUILD="$WEB/app-4b-build.js"
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
rg -Fq 'confirm(memoryBlockConfirmation(result, type))' "$UTIL" || { echo "FAIL: memory override confirmation missing"; exit 1; }
rg -Fq 'return action(type, root, service, true)' "$UTIL" || { echo "FAIL: individual force retry missing"; exit 1; }
rg -Fq 'return sessionAction(type, session, true)' "$UTIL" || { echo "FAIL: start-all force retry missing"; exit 1; }
rg -Fq 'JSON.stringify({root: session.root, force})' "$UTIL" || { echo "FAIL: start-all force payload missing"; exit 1; }
rg -q 'projectedFreeMb' "$UTIL" || { echo "FAIL: projected memory confirmation missing"; exit 1; }
rg -q 'estimatedServices' "$UTIL" || { echo "FAIL: largest estimated services missing"; exit 1; }
rg -q 'unknownServices' "$UTIL" || { echo "FAIL: unknown services confirmation missing"; exit 1; }
rg -q 'docker-projected' "$UTIL" || { echo "FAIL: projected-pressure reason copy missing"; exit 1; }
rg -q 'docker-unknown' "$UTIL" || { echo "FAIL: incomplete-Docker reason copy missing"; exit 1; }

# Service rows place current use in the existing right metadata slot and retain
# peak/limit/OOM detail in a title. OOM augments the normalized state reason.
rg -q 'memoryUsageMb' "$ACTIONS" || { echo "FAIL: service current memory missing"; exit 1; }
rg -q 'memoryPeakMb' "$ACTIONS" || { echo "FAIL: service peak memory missing"; exit 1; }
rg -q 'memoryLimitMb' "$ACTIONS" || { echo "FAIL: service memory limit missing"; exit 1; }
rg -q 'oomKilled' "$ACTIONS" || { echo "FAIL: service OOM state missing"; exit 1; }
rg -q 'function serviceStateReason' "$ACTIONS" || { echo "FAIL: OOM state reason helper missing"; exit 1; }
rg -q 'data-rss' "$ACTIONS" || { echo "FAIL: service memory metadata slot missing"; exit 1; }
rg -q '\.mem-separator' "$CSS" || { echo "FAIL: compact telemetry separator styles missing"; exit 1; }
node - "$UTIL" "$ACTIONS" "$SESSIONS" "$BUILD" <<'JS'
const fs = require('fs');
const vm = require('vm');
const [utilSource, actionsSource, sessionsSource, buildSource] = process.argv.slice(2).map(path => fs.readFileSync(path, 'utf8'));
const requests = [];
let confirmations = 0;
function element() {
  return {
    textContent: '', hidden: false, title: '', style: {},
    classList: {toggle() {}, contains() { return false; }},
  };
}
const header = {mem: element(), memDocker: element(), memHost: element(), memSeparator: element(), memBar: element()};
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
  document: {
    getElementById: id => header[id],
    querySelector: () => null,
  },
  localStorage: {getItem: () => null, setItem: () => {}},
  CSS: {escape: value => value},
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
vm.runInContext(utilSource, context);
vm.runInContext(actionsSource, context);
vm.runInContext(sessionsSource, context);
vm.runInContext(buildSource, context);
vm.runInContext('this.__test = {action, sessionAction, formatMemoryPair, finiteMemoryMb, renderMemory, memoryBlockConfirmation, serviceMemoryMeta, serviceStateReason, buildMemoryPressureHtml, updateServiceStates};', context);
(async () => {
  const api = context.__test;
  for (const value of [null, undefined, '', '   ', NaN, Infinity, -Infinity]) {
    if (api.finiteMemoryMb(value) !== null) throw new Error(`nullable metric accepted: ${String(value)}`);
  }
  api.renderMemory({docker: {usedMb: null, totalMb: null}, host: {availableMb: null, availablePercent: null}});
  if (!header.mem.hidden || !header.memDocker.hidden || !header.memHost.hidden || /0\.0 GB/.test(`${header.memDocker.textContent}${header.memHost.textContent}`)) {
    throw new Error('null header metrics invented telemetry');
  }
  api.renderMemory({docker: {usedMb: null, totalMb: null}, host: {availableMb: 5120, availablePercent: 50}});
  if (!header.memDocker.hidden || header.memHost.hidden || header.memHost.textContent !== 'Host available 5.0 GB') {
    throw new Error('Docker-unavailable header fallback mismatch');
  }
  const nullConfirmation = api.memoryBlockConfirmation({reason: 'docker-projected', projectedFreeMb: null, reserveMb: null, estimatedServices: [{service: 'web', memoryMb: null}], unknownServices: []});
  if (!nullConfirmation.includes('알 수 없음') || /0\.0 GB|undefined|NaN/.test(nullConfirmation)) {
    throw new Error(`null confirmation invented telemetry: ${nullConfirmation}`);
  }
  const rebuildConfirmation = api.memoryBlockConfirmation(lowMemory, 'rebuild');
  if (!rebuildConfirmation.includes('강제로 재빌드할까?') || rebuildConfirmation.includes('강제로 시작할까?')) {
    throw new Error(`operation-specific confirmation mismatch: ${rebuildConfirmation}`);
  }
  const nullMeta = api.serviceMemoryMeta({memoryUsageMb: null, memoryPeakMb: undefined, memoryLimitMb: '', oomKilled: null});
  if (nullMeta.current || nullMeta.title || /0 MB/.test(`${nullMeta.current} ${nullMeta.title}`)) {
    throw new Error(`null service metadata invented telemetry: ${JSON.stringify(nullMeta)}`);
  }
  if (api.buildMemoryPressureHtml({sampleCount: 1, hostAvailableMinMb: null, containersPeakMb: undefined}) !== '') {
    throw new Error('null build pressure rendered invented telemetry');
  }
  if (api.buildMemoryPressureHtml({sampleCount: null, hostAvailableMinMb: 4096, containersPeakMb: 512}) !== '') {
    throw new Error('null build sample count rendered pressure');
  }
  if (context.__test.formatMemoryPair(11060, 15972) !== '10.8 / 15.6 GB') throw new Error('compact Docker format mismatch');
  await api.action('start', '/project', 'web');
  await api.sessionAction('start-all', {root: '/project'});
  if (confirmations !== 2) throw new Error(`expected two confirmations, got ${confirmations}`);
  if (requests.length !== 4) throw new Error(`expected four lifecycle requests, got ${requests.length}`);
  if (requests[0].body.force !== false || requests[1].body.force !== true) throw new Error('individual retry force contract failed');
  if (requests[2].body.force !== false || requests[3].body.force !== true) throw new Error('start-all retry force contract failed');
  const dot = element();
  const port = element();
  const memory = element();
  const uptime = element();
  const tail = element();
  const row = {
    ...element(),
    title: 'stale title',
    querySelector: selector => ({'.wt-dot': dot, '[data-port]': port, '[data-rss]': memory, '[data-uptime]': uptime, '[data-tail]': tail}[selector] || null),
  };
  const card = {
    classList: {contains() { return false; }},
    querySelector: selector => selector.startsWith('[data-service-key=') ? row : null,
    querySelectorAll: () => [],
  };
  const freshService = {service: 'web', state: 'error', stateReason: '새 원인', memoryUsageMb: 512, memoryPeakMb: 768, memoryLimitMb: 1024, oomKilled: true, running: false};
  context.sessions = [{root: '/project', services: [freshService]}];
  context.document.querySelector = selector => selector.startsWith('[data-root=') ? card : null;
  context.visibleServices = session => session.services;
  context.cardState = () => 'error';
  context.stateCounts = () => '';
  context.whyLines = () => '';
  context.wireWhyLinks = () => {};
  context.fillCardActs = () => {};
  context.fillSvcActs = () => {};
  context.svcState = svc => svc.state;
  context.STATE_META = {error: {dot: 'err', title: '실패'}};
  context.portText = () => '';
  context.portTitle = () => '';
  context.relTime = () => '';
  context.tailVisible = () => false;
  context.renderSelection = () => {};
  api.updateServiceStates();
  if (memory.textContent !== '512 MB' || !memory.title.includes('피크 768 MB') || !memory.title.includes('제한 1024 MB')) {
    throw new Error(`partial update retained stale memory metadata: ${memory.textContent} / ${memory.title}`);
  }
  if (!row.title.includes('새 원인') || !row.title.includes('OOM 종료 감지')) {
    throw new Error(`partial update retained stale state reason: ${row.title}`);
  }
})().catch(error => { console.error(error.stack || error); process.exit(1); });
JS

rg -Fq '@media (max-width: 640px)' "$CSS" || { echo "FAIL: narrow header media rule missing"; exit 1; }
rg -q '\.toolbar \.mem-bar' "$CSS" || { echo "FAIL: narrow header gauge rule missing"; exit 1; }
rg -q 'flex: 1 1 100%' "$CSS" || { echo "FAIL: narrow telemetry wrapping contract missing"; exit 1; }

echo "PASS test-memory-ui"
