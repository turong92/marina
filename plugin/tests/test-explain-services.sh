#!/usr/bin/env bash
# 등록 워크벤치 M5 — R3 서비스 해석 줄(app-2d-explain.js) 불변식:
# ① 순수 번역기(xpExplainCompose) — build(shorthand/context+dockerfile)·image·ports/expose·environment(???)·
#    env_file·depends_on·include·미지원 키 집계 전수, 깨진 입력(non-string) → ok:false 정직 폴백.
# ② innerHTML/alert 미사용 · index.html 로드 순서(app-2c < app-2d < app-3) · data-wb-explain-* 마커 존재.
# ③ 전 웹 JS node --check(회귀).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J="$WEB/app-2d-explain.js"

[[ -f "$J" ]] || { echo "FAIL: app-2d-explain.js 없음"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node 없음 — 번역기 단위 테스트 생략"; exit 0; }

node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }

# ── ① node vm 으로 app-2d 를 그대로 eval — 순수 파서/번역기만 호출(DOM 은 최소 스텁) ──────────
node <<JSEOF
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync('$J', 'utf8');
const sandbox = {
  console,
  document: {
    getElementById: () => null,
    querySelector: () => null,
    addEventListener: () => {},
    createElement: () => ({ style: {}, classList: { add(){}, remove(){} }, appendChild(){}, addEventListener(){} }),
  },
};
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'app-2d-explain.js' });

const { xpExplainCompose } = sandbox;
if (typeof xpExplainCompose !== 'function') throw new Error('xpExplainCompose 를 sandbox 에서 못 찾음(전역 function 선언이어야 vm 컨텍스트에 노출됨)');

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.error('FAIL:', name, detail !== undefined ? JSON.stringify(detail) : ''); }
}
function svcByName(result, name) { return (result.services || []).find(s => s.name === name); }

// ── build: shorthand(경로 스칼라) + ports(문자열 매핑) ───────────────────────────────────
const docShorthand = 'services:\n  web:\n    build: ./web\n    ports:\n      - "3000:3000"\n';
const r1 = xpExplainCompose(docShorthand);
check('shorthand build ok', r1.ok === true, r1);
const web1 = svcByName(r1, 'web');
check('shorthand build 문장', !!web1 && web1.lines.some(l => l.includes('./web') && l.includes('Dockerfile') && l.includes('빌드')), web1);
check('ports 문장(컨테이너 포트만)', !!web1 && web1.lines.some(l => l.includes('포트') && l.includes('3000') && l.includes('서빙')), web1);

// ── build: context/dockerfile 블록 형태 + image(별도 서비스) + expose ──────────────────
const docBlock = [
  'services:',
  '  api:',
  '    build:',
  '      context: ./api',
  '      dockerfile: docker/Dockerfile.api',
  '    expose:',
  '      - "8080"',
  '  cache:',
  '    image: redis:7',
].join('\n') + '\n';
const r2 = xpExplainCompose(docBlock);
check('context/dockerfile 블록 ok', r2.ok === true, r2);
const api2 = svcByName(r2, 'api');
check('context+dockerfile 문장', !!api2 && api2.lines.some(l => l.includes('./api') && l.includes('docker/Dockerfile.api') && l.includes('빌드')), api2);
check('expose 도 포트 문장으로', !!api2 && api2.lines.some(l => l.includes('포트') && l.includes('8080')), api2);
const cache2 = svcByName(r2, 'cache');
check('image 문장', !!cache2 && cache2.lines.some(l => l.includes('이미지') && l.includes('redis:7') && l.includes('사용')), cache2);

// ── environment 의 ??? — 블록 매핑 형태(스캐폴드가 실제로 내보내는 모양) ────────────────
const docMarker = [
  'services:',
  '  be-api:',
  '    build: ./be-api',
  '    environment:',
  '      BUILD_ENV: "???"',
  '      APP_MODE: local',
].join('\n') + '\n';
const r3 = xpExplainCompose(docMarker);
check('??? 마커 ok', r3.ok === true, r3);
const be3 = svcByName(r3, 'be-api');
check('??? 인 키만 envWarnings 에 포함', !!be3 && be3.envWarnings.includes('BUILD_ENV') && !be3.envWarnings.includes('APP_MODE'), be3);

// ── environment 의 ??? — 인라인 flow map 형태({ K: V }) ─────────────────────────────
const docMarkerFlow = 'services:\n  web:\n    image: nginx\n    environment: { APP_ENV: "???" }\n';
const r3b = xpExplainCompose(docMarkerFlow);
check('flow map ??? 도 감지', svcByName(r3b, 'web').envWarnings.includes('APP_ENV'), r3b);

// ── env_file / depends_on / include — 각 한 문장 ────────────────────────────────────
const docRefs = [
  'services:',
  '  web:',
  '    image: nginx',
  '    env_file: .env',
  '    depends_on:',
  '      - be-api',
  '      - cache',
  'include:',
  '  - ai-api/docker-compose.yml',
].join('\n') + '\n';
const r4 = xpExplainCompose(docRefs);
check('env_file/depends_on/include ok', r4.ok === true, r4);
const web4 = svcByName(r4, 'web');
check('env_file 문장', web4.lines.some(l => l.includes('.env') && l.includes('환경변수')), web4);
check('depends_on 문장', web4.lines.some(l => l.includes('be-api') && l.includes('cache')), web4);
check('include 문장(top-level, 서비스 아님)', r4.includes.length === 1 && r4.includes[0] === 'ai-api/docker-compose.yml', r4);

// ── 지원 외 키 집계 — n개(YAML 참조) ────────────────────────────────────────────────
const docOther = [
  'services:',
  '  web:',
  '    image: nginx',
  '    restart: always',
  '    volumes:',
  '      - ./data:/data',
  '    container_name: fixed',
].join('\n') + '\n';
const r5 = xpExplainCompose(docOther);
check('미지원 키 집계 3개(restart/volumes/container_name)', svcByName(r5, 'web').otherCount === 3, r5);

// ── services 자체가 없는 문서 — ok:true, 빈 배열(정직한 빈 상태) ───────────────────────
const r6 = xpExplainCompose('x-marina:\n  java: 21\n');
check('services 없음 → ok:true, 빈 목록', r6.ok === true && r6.services.length === 0 && r6.includes.length === 0, r6);

// ── 깨진 입력(문자열이 아님) → 예외를 던지는 대신 ok:false 로 정직한 폴백 ───────────────
const r7 = xpExplainCompose(12345);
check('non-string 입력 → ok:false(예외 미던짐)', r7.ok === false && typeof r7.error === 'string', r7);
const r8 = xpExplainCompose(undefined);
check('undefined 입력도 안전(services: 없음 취급)', r8.ok === true, r8);

// ── 깨진 YAML(탭 들여쓰기) → ok:false 로 정직한 폴백(app-2c 의 x-marina 탭 검사와 같은 신호) ──
const r9 = xpExplainCompose('services:\n  web:\n\t build: ./web\n');
check('탭 들여쓰기 services → ok:false', r9.ok === false, r9);

if (failures > 0) { console.error(failures + '개 실패'); process.exit(1); }
console.log('node 번역기 테스트 통과');
JSEOF

# ── ② innerHTML/alert 미사용 · index.html 마커/로드 순서 ─────────────────────────────────
! grep -q '\.innerHTML' "$J" || { echo "FAIL: app-2d 가 innerHTML 을 사용함(금지)"; exit 1; }
! grep -qE '\balert\(' "$J" || { echo "FAIL: app-2d 가 alert 를 사용함(금지)"; exit 1; }
grep -q 'data-wb-explain-toggle' "$WEB/index.html" || { echo "FAIL: data-wb-explain-toggle 마커 소실"; exit 1; }
grep -q 'wbExplainPanel' "$WEB/index.html" || { echo "FAIL: wbExplainPanel 마커 소실"; exit 1; }

python3 - "$WEB/index.html" <<'PY' || { echo "FAIL: app-2d 로드 순서 위반"; exit 1; }
import sys
html = open(sys.argv[1]).read()
i2c = html.index('<script src="/web/app-2c-xmarina-form.js">')
i2d = html.index('<script src="/web/app-2d-explain.js">')
i3 = html.index('<script src="/web/app-3-util.js">')
assert i2c < i2d < i3, "app-2d 가 app-2c 다음·app-3 이전에 로드되지 않음"
PY

# ── ③ 전 웹 JS 문법(전체 회귀) ────────────────────────────────────────────────────────────
for f in "$WEB"/app-*.js; do
  node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
done

echo "PASS test-explain-services"
