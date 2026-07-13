#!/usr/bin/env bash
# x-marina.startGroup — 시작 그룹: cmd_up 대상 축소(pure fn) · payload 플래그 · 대시보드 집계 제외 · 폼 왕복
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"

# ── ① 백엔드 pure fn: start_group_requested — 전체시작만 축소, 개별 지정은 자율 ──────────
python3 - "$HERE/../scripts/marina-compose.py" <<'PY' || { echo "FAIL: start_group_requested unit"; exit 1; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
ar = mc.start_group_requested
svcs = {"web": {}, "api": {}, "batch": {}}
assert ar({}, [], svcs) == ([], []), "미선언 → 전체(빈 requested 유지)"
assert ar({"startGroup": ["web", "api"]}, [], svcs) == (["web", "api"], []), "선언 → 시작 그룹만"
assert ar({"startGroup": ["web", "ghost"]}, [], svcs) == (["web"], ["ghost"]), "미정의는 unknown 으로 분리"
assert ar({"startGroup": ["web"]}, ["batch"], svcs) == (["batch"], []), "개별 지정(자율)은 startGroup 무시"
assert ar({"startGroup": ["ghost"]}, [], svcs) == ([], ["ghost"]), "전부 미정의 → 빈 targets(호출측 전체 폴백)"
assert ar({"startGroup": "web"}, [], svcs) == ([], []), "리스트 아닌 선언은 무시(방어)"
print("ok start_group_requested")
PY

# ── ② payload 플래그 + 대시보드 집계 계약 (grep) ──────────
grep -q '"inStartGroup"' "$HERE/../scripts/marina_compose_svc.py" || { echo "FAIL: 서비스 payload inStartGroup 플래그 없음"; exit 1; }
grep -q 'endswith("-bind")' "$HERE/../scripts/marina_compose_svc.py" || { echo "FAIL: -bind 사이드카가 본체 startGroup 을 따라가지 않음"; exit 1; }
grep -q "function countedServices" "$WEB/app-5-sessions.js" || { echo "FAIL: countedServices(집계 분모) 없음"; exit 1; }
grep -q "countedServices(services).map(svcState)" "$WEB/app-5-sessions.js" || { echo "FAIL: cardState/stateCounts 가 집계 분모를 안 씀"; exit 1; }
grep -q "svc-opt" "$WEB/app-5b-actions.js" || { echo "FAIL: 옵션 서비스 행 딤(svc-opt) 없음"; exit 1; }
grep -q '\.svc\.svc-opt' "$WEB/styles.css" || { echo "FAIL: .svc-opt CSS 없음"; exit 1; }
grep -q "시작 그룹 시작" "$WEB/app-5-sessions.js" || { echo "FAIL: startGroup 프로젝트 ▶ 문구 없음"; exit 1; }
# --all busy 가 그룹 밖 서비스에 스핀을 돌리지 않게(전부 띄우는 것처럼 오인, 형 실사용 사례) — 조건부 머지 계약
grep -q 'all_busy if s.get("inStartGroup") is not False else None' "$HERE/../scripts/marina_sessions.py" \
  || { echo "FAIL: --all busy 가 startGroup 밖 서비스에도 합쳐짐(전부 기동중으로 오표시)"; exit 1; }

# ── ③ 폼 왕복: startGroup 리스트 파싱→직렬화 보존 (node vm, DOM 스텁) ──────────
command -v node >/dev/null 2>&1 || { echo "PASS test-start-group (node 없음 — 폼 왕복 생략)"; exit 0; }
node <<JSEOF
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync('$WEB/app-2c-xmarina-form.js', 'utf8');
const sandbox = { console, document: { getElementById: () => null, querySelector: () => null, addEventListener: () => {},
  createElement: () => ({ style: {}, classList: { add(){}, remove(){} }, appendChild(){}, addEventListener(){} }) } };
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'app-2c-xmarina-form.js' });
const yaml = 'services:\n  web: {}\nx-marina:\n  startGroup:\n  - web\n  - api\n';
const r = sandbox.wbParseXmarina(yaml);
if (!r.ok) throw new Error('startGroup 파싱 실패');
if (JSON.stringify(r.xm.startGroup) !== '["web","api"]') throw new Error('startGroup 값 불일치: ' + JSON.stringify(r.xm.startGroup));
const out = sandbox.wbSerializeXmarina(r.xm, r.otherKeys);
if (!/  startGroup:\n  - web\n  - api/.test(out)) throw new Error('startGroup 직렬화 불일치:\n' + out);
const bad = sandbox.wbParseXmarina('x-marina:\n  startGroup: web\n');
if (!bad.ok) throw new Error('스칼라 startGroup 은 otherKeys 로 내려가야(폼 잠금 아님)');
if (!bad.otherKeys.some(o => o.key === 'startGroup')) throw new Error('잘못된 모양이 otherKeys 로 보존되지 않음');
console.log('ok startGroup form roundtrip');
JSEOF
echo "PASS test-start-group"
