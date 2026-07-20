#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

grep -q 'id="authLoginForm"' "$WEB/login.html"
grep -q 'id="authBootstrapForm"' "$WEB/login.html"
grep -q 'id="authClaimForm"' "$WEB/login.html"
grep -q 'id="authPending"' "$WEB/login.html"
grep -q 'id="authUnavailableCommand"' "$WEB/login.html"
grep -q 'marina auth status' "$WEB/login.html"
grep -q 'src="/web/app-0-auth.js"' "$WEB/index.html"

auth_line="$(grep -n 'app-0-auth.js' "$WEB/index.html" | cut -d: -f1)"
core_line="$(grep -n 'app-1-core.js' "$WEB/index.html" | cut -d: -f1)"
[[ "$auth_line" -lt "$core_line" ]]

node --check "$WEB/auth-login.js"
grep -q "error.error === 'auth_unavailable'" "$WEB/auth-login.js"
node --check "$WEB/app-0-auth.js"
grep -q 'id="userManagementBtn"' "$WEB/index.html"
grep -q 'id="accountLogoutBtn"' "$WEB/index.html"
grep -q 'id="userManagementDialog"' "$WEB/index.html"
grep -q 'id="revokeAllSessionsBtn"' "$WEB/index.html"
grep -q 'renderAuthUsers' "$WEB/app-6c-users.js"
grep -q '/api/auth/users/approve' "$WEB/app-6c-users.js"
node --check "$WEB/app-6c-users.js"

node - "$WEB/app-0-auth.js" <<'JS'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const calls = [];
let assigned = '';
class HeadersFake {
  constructor(source) { this.values = Object.assign({}, source || {}); }
  set(name, value) { this.values[name.toLowerCase()] = value; }
  get(name) { return this.values[name.toLowerCase()]; }
}
const context = {
  URL,
  Headers: HeadersFake,
  document: {cookie: 'marina_csrf=csrf-value'},
  location: {
    href: 'http://localhost:3900/', origin: 'http://localhost:3900',
    pathname: '/', search: '', assign(value) { assigned = value; },
  },
  fetch: async (input, options) => {
    calls.push({input, options: options || {}});
    return {status: String(input).includes('unauthorized') ? 401 : 200};
  },
};
context.window = context;
context.fetch.bind = Function.prototype.bind;
vm.createContext(context);
vm.runInContext(source, context);

(async () => {
  await context.fetch('/api/test', {method: 'POST', headers: {'content-type': 'application/json'}});
  if (calls[0].options.headers.get('x-marina-csrf') !== 'csrf-value') throw new Error('POST missing CSRF');
  await context.fetch('/api/test');
  if (calls[1].options.headers && calls[1].options.headers.get('x-marina-csrf')) throw new Error('GET received CSRF');
  await context.fetch('/unauthorized');
  if (assigned !== '/login?next=%2F') throw new Error(`401 redirect mismatch: ${assigned}`);
  console.log('ok auth fetch wrapper');
})().catch(error => { console.error(error); process.exit(1); });
JS

echo "PASS test-auth-ui"
