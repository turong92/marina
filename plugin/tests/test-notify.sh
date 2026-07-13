#!/usr/bin/env bash
# 브라우저 알림(A3, 옵트인) 불변식:
# ① node vm 으로 app-5-sessions.js(svcState/isInternalService) + app-6b-notify.js 를 같은 컨텍스트에 로드해
#    전이 감지 단위 테스트 — 첫 스냅샷 무음·starting→running 발화·60s 중복 억제·해제 후 재발화·
#    hasFocus() 시 토스트 경로(OS 알림 대신)·starting→error/running→error 문구.
# ② grep — 옵트인 기본 OFF(버튼 초기 🔕), app-6 훅 1줄, index.html 버튼+로드 순서.
# ③ 전 웹 JS node --check(회귀).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J5="$WEB/app-5-sessions.js"
J="$WEB/app-6b-notify.js"
H="$WEB/index.html"
J6="$WEB/app-6-modals.js"

[[ -f "$J" ]] || { echo "FAIL: app-6b-notify.js 없음"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node 없음 — 알림 전이 단위 테스트 생략"; exit 0; }

node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }

# ── ① node vm — app-5(svcState 소스) + app-6b(알림 로직) 를 실제 페이지처럼 같은 전역에 순서대로 eval ──
node <<JSEOF
const fs = require('fs');
const vm = require('vm');

const src5 = fs.readFileSync('$J5', 'utf8');
const src6b = fs.readFileSync('$J', 'utf8');

let fakeNow = 1000000;
const toastCalls = [];
const notificationsCreated = [];
const selectLogCalls = [];
let windowFocusCalled = 0;
let docFocused = false;
let notifPermission = 'granted';

function makeClassList() {
  const set = new Set();
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    toggle: (c, on) => { if (on === undefined) { if (set.has(c)) set.delete(c); else set.add(c); } else if (on) set.add(c); else set.delete(c); },
    contains: (c) => set.has(c),
  };
}
const notifyBtnStub = { textContent: '', title: '', classList: makeClassList(), onclick: null };

const storeMap = new Map();
const localStorage = {
  getItem: (k) => (storeMap.has(k) ? storeMap.get(k) : null),
  setItem: (k, v) => storeMap.set(k, String(v)),
  removeItem: (k) => storeMap.delete(k),
};

class FakeNotification {
  constructor(title, opts) { this.title = title; this.options = opts || {}; notificationsCreated.push(this); }
  close() {}
}
FakeNotification.permission = 'granted';
FakeNotification.requestPermission = async () => notifPermission;

function showToast(msg, kind) { toastCalls.push({ msg, kind }); }
function selectLog(root, service, run, mode) { selectLogCalls.push({ root, service, run, mode }); }

const sandbox = {
  console,
  Date: { now: () => fakeNow },
  document: {
    hasFocus: () => docFocused,
    getElementById: (id) => (id === 'notifyToggle' ? notifyBtnStub : null),
    querySelector: () => null,
    addEventListener: () => {},
  },
  window: { focus: () => { windowFocusCalled++; } },
  Notification: FakeNotification,
  localStorage,
  showToast,
  selectLog,
};
vm.createContext(sandbox);
vm.runInContext(src5, sandbox, { filename: 'app-5-sessions.js' });
vm.runInContext(src6b, sandbox, { filename: 'app-6b-notify.js' });

const { notifyScan, updateNotifyButton } = sandbox;
if (typeof notifyScan !== 'function') throw new Error('notifyScan 을 sandbox 에서 못 찾음(전역 function 선언이어야 함)');

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.error('FAIL:', name, detail !== undefined ? JSON.stringify(detail) : ''); }
}

// 기본 버튼 상태 — 옵트인 기본 OFF(🔕), grant 여부와 무관하게 localStorage 미설정이면 꺼짐
updateNotifyButton();
check('기본 OFF — 초기 아이콘 🔕', notifyBtnStub.textContent === '🔕', notifyBtnStub);

function session(root, alias, state, service) {
  return { root, alias, services: [{ service: service || 'web', state }] };
}

// ── 첫 스냅샷 — 기준선만, 알림/토스트 금지 ──────────────────────────────────
docFocused = false;
localStorage.setItem('marinaNotify', '1');
FakeNotification.permission = 'granted';
notifyScan([session('/r/a', 'wtA', 'starting')]);
check('첫 스냅샷 — 알림 없음', notificationsCreated.length === 0, notificationsCreated);
check('첫 스냅샷 — 토스트 없음', toastCalls.length === 0, toastCalls);

// ── starting → running (비포커스, 옵트인 ON, 권한 grant) — OS 알림 발화 ──────
notifyScan([session('/r/a', 'wtA', 'running')]);
check('starting→running 알림 1건', notificationsCreated.length === 1, notificationsCreated);
check('알림 문구에 워크트리·서비스명 포함', notificationsCreated[0] && notificationsCreated[0].options.body.includes('wtA') && notificationsCreated[0].options.body.includes('web'), notificationsCreated[0]);

// 알림 클릭 — window.focus + selectLog
if (notificationsCreated[0] && notificationsCreated[0].onclick) notificationsCreated[0].onclick();
check('알림 클릭 → window.focus 호출', windowFocusCalled === 1);
check('알림 클릭 → selectLog(해당 서비스)', selectLogCalls.length === 1 && selectLogCalls[0].root === '/r/a' && selectLogCalls[0].service === 'web', selectLogCalls);

// ── 60s 이내 재전이 — 중복 억제(같은 svc,event) ────────────────────────────
notifyScan([session('/r/a', 'wtA', 'starting')]);   // running→starting: 추적 대상 전이 아님, 스냅샷만 갱신
fakeNow += 5000;                                    // +5s (60s 이내)
notifyScan([session('/r/a', 'wtA', 'running')]);    // 같은 (svc, 'ready') 재발화 시도
check('60s 이내 같은 이벤트 — 중복 억제(알림 그대로 1건)', notificationsCreated.length === 1, notificationsCreated);

// ── 60s 지남 — 재발화 허용 ──────────────────────────────────────────────
notifyScan([session('/r/a', 'wtA', 'starting')]);
fakeNow += 61000;                                   // 첫 발화로부터 60s 초과
notifyScan([session('/r/a', 'wtA', 'running')]);
check('60s 초과 후 재발화', notificationsCreated.length === 2, notificationsCreated);

// ── starting → error / running → error 문구 ─────────────────────────────
notifyScan([session('/r/b', 'wtB', 'starting', 'api')]);
notifyScan([session('/r/b', 'wtB', 'error', 'api')]);
const failedNotif = notificationsCreated.find(n => n.title.includes('실패'));
check('starting→error 알림(기동 실패)', !!failedNotif && failedNotif.options.body.includes('wtB'), notificationsCreated);

notifyScan([session('/r/c', 'wtC', 'starting', 'db')]);
notifyScan([session('/r/c', 'wtC', 'running', 'db')]);
notifyScan([session('/r/c', 'wtC', 'error', 'db')]);
const issueNotif = notificationsCreated.find(n => n.title.includes('이상'));
check('running→error 알림(서비스 이상)', !!issueNotif && issueNotif.options.body.includes('wtC'), notificationsCreated);

// ── 포커스 상태 — OS 알림 대신 showToast 경로 ────────────────────────────
const notifCountBeforeFocusTest = notificationsCreated.length;
docFocused = true;
notifyScan([session('/r/d', 'wtD', 'starting', 'web')]);
notifyScan([session('/r/d', 'wtD', 'running', 'web')]);
check('포커스 상태 — 알림 대신 토스트', toastCalls.length === 1 && notificationsCreated.length === notifCountBeforeFocusTest, { toastCalls, notificationsCreated });

if (failures > 0) { console.error(failures + '개 실패'); process.exit(1); }
console.log('node 알림 전이 테스트 통과');
JSEOF

# ── ② grep — 옵트인 기본 OFF · app-6 훅 1줄 · index.html 버튼 ────────────────────────
grep -q 'id="notifyToggle"' "$H" || { echo "FAIL: index.html 에 #notifyToggle 버튼 없음"; exit 1; }
grep -q '>🔕<' "$H" || { echo "FAIL: 초기 아이콘이 🔕(꺼짐)가 아님 — 기본 OFF(옵트인) 위반"; exit 1; }
grep -q "if (typeof notifyScan === 'function') notifyScan(sessions);" "$J6" || { echo "FAIL: app-6 훅 1줄 없음"; exit 1; }
grep -q "function notifyScan" "$J" || { echo "FAIL: notifyScan 정의 없음"; exit 1; }
grep -q "function updateNotifyButton" "$J" || { echo "FAIL: updateNotifyButton 정의 없음"; exit 1; }
! grep -qE '\balert\(' "$J" || { echo "FAIL: app-6b 가 alert 를 사용함(금지)"; exit 1; }

python3 - "$H" <<'PY' || { echo "FAIL: app-6b 로드 순서 위반"; exit 1; }
import sys
html = open(sys.argv[1]).read()
i6 = html.index('<script src="/web/app-6-modals.js">')
i6b = html.index('<script src="/web/app-6b-notify.js">')
i8 = html.index('<script src="/web/app-8-git.js">')
assert i6 < i6b < i8, "app-6b 가 app-6 다음·app-8 이전에 로드되지 않음"
PY

# ── ③ 전 웹 JS 문법(전체 회귀) ────────────────────────────────────────────────────────
for f in "$WEB"/app-*.js; do
  node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
done

echo "PASS test-notify"
