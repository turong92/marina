#!/usr/bin/env bash
# Default browser-open paths must prefer the stable gateway origin over Docker's rotating published port.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

node - "$WEB/app-3-util.js" <<'JS'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('let gatewayState');
const end = source.indexOf('async function loadGatewayState');
if (start < 0 || end < 0) throw new Error('gateway helper block not found');
const opened = [];
const tests = String.raw`
const session = {id: 'feat', projectId: 'mdc', services: []};
const web = {service: 'web', running: true, port: '55123'};
session.services = [web];

gatewayState = {enabled: true, port: 3902, loaded: true};
const gateway = preferredServiceUrl(session, web);
if (gateway !== 'http://feat.mdc.localhost:3902/') throw new Error('gateway was not preferred: ' + gateway);
if (preferredServiceUrlKind(session, web) !== 'gateway') throw new Error('gateway kind missing');
openServiceInBrowser(session, web);
if (opened[0]?.url !== gateway || opened[0]?.target !== '_blank' || opened[0]?.features !== 'noopener') {
  throw new Error('gateway open contract failed: ' + JSON.stringify(opened));
}

gatewayState = {enabled: false, port: 3902, loaded: true};
const fallback = preferredServiceUrl(session, web);
if (fallback !== 'http://localhost:55123/') throw new Error('host fallback missing: ' + fallback);
if (preferredServiceUrlKind(session, web) !== 'host') throw new Error('host fallback kind missing');
if (preferredServiceUrl(session, {...web, running: false}) !== null) throw new Error('stopped service should not open');
console.log('ok gateway-first URL policy');
`;
vm.runInNewContext(source.slice(start, end) + tests, {
  console,
  opened,
  window: {open: (url, target, features) => opened.push({url, target, features})},
});
JS

grep -q 'preferredServiceUrl(session, svc)' "$WEB/app-4-logs.js" || { echo 'FAIL: log header does not resolve the preferred service URL'; exit 1; }
grep -q 'openServiceInBrowser(session, svc)' "$WEB/app-6-modals.js" || { echo 'FAIL: log header does not use the shared browser opener'; exit 1; }
grep -q 'await loadGatewayState()' "$WEB/app-6-modals.js" || { echo 'FAIL: dashboard renders before gateway availability is known'; exit 1; }
! grep -q 'window.open(`http://localhost:${web.port}/`' "$WEB/app-6-modals.js" || { echo 'FAIL: log header still hard-codes the rotating host port'; exit 1; }
grep -q 'preferredServiceUrl(session, svc)' "$WEB/app-5b-actions.js" || { echo 'FAIL: service menu does not use the preferred URL'; exit 1; }
grep -q '호스트포트로 열기' "$WEB/app-5b-actions.js" || { echo 'FAIL: explicit host-port diagnostic action was removed'; exit 1; }

echo 'PASS test-gateway-first-open'
