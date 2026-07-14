#!/usr/bin/env bash
# 등록 워크벤치 M4 — 좌 하단 marina 옵션 폼(app-2c-xmarina-form.js) 불변식:
# ① 순수 파서/직렬화기(wbParseXmarina/wbSerializeXmarina/wbReplaceXmarinaBlock) 왕복 —
#    지원키 왕복 동일 · 미지원키 원문 보존 · 깨진 YAML 은 ok:false.
# ② 폼 UI grep 불변식 — R4 라벨 문자열 존재 · 잠금 문구 · innerHTML 미사용.
# ③ 전 웹 JS node --check.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WEB="$HERE/../scripts/marina-web"
J="$WEB/app-2c-xmarina-form.js"

[[ -f "$J" ]] || { echo "FAIL: app-2c-xmarina-form.js 없음"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node 없음 — 왕복 테스트 생략"; exit 0; }

node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }

# ── ① node vm 으로 app-2c 를 그대로 eval — 순수 파서 함수만 호출(DOM 은 최소 스텁) ──────────
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
vm.runInContext(src, sandbox, { filename: 'app-2c-xmarina-form.js' });

const { wbParseXmarina, wbSerializeXmarina, wbReplaceXmarinaBlock } = sandbox;
if (typeof wbParseXmarina !== 'function') throw new Error('wbParseXmarina 를 sandbox 에서 못 찾음(전역 function 선언이어야 vm 컨텍스트에 노출됨)');
if (typeof wbSerializeXmarina !== 'function') throw new Error('wbSerializeXmarina 를 sandbox 에서 못 찾음');
if (typeof wbReplaceXmarinaBlock !== 'function') throw new Error('wbReplaceXmarinaBlock 를 sandbox 에서 못 찾음');

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.error('FAIL:', name, detail !== undefined ? JSON.stringify(detail) : ''); }
}
function canon(v) { return JSON.stringify(v, Object.keys(v).length ? Object.keys(v).sort() : undefined); }
function deepCanon(v) {
  // 키 순서 무관 비교 — 재귀적으로 키를 정렬해 문자열화.
  if (Array.isArray(v)) return '[' + v.map(deepCanon).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + deepCanon(v[k])).join(',') + '}';
  return JSON.stringify(v);
}

// ── 지원 키 왕복(6종 전부) — parse(serialize(xm)) 가 원래 xm 과 구조적으로 동일 ─────────────
const xmFull = {
  links: { symlink: ['node_modules', '.venv'], copy: ["**/*local.yml"], subs: {} },
  forward: { '6379': 'host', '3306': 'host' },
  gateway: { routes: { 'user-api': ['/v1.0'], 'web': [] } },
  prebuild: {
    'legacy-api': './gradlew assemble',
    'user-api': { cwd: 'be-api', command: './gradlew :user-api:bootJar' },
  },
  java: '21',
  build: { args: { BUILD_ENV: 'local' } },
};
const blockFull = wbSerializeXmarina(xmFull, []);
check('직렬화 결과가 x-marina: 로 시작', blockFull.startsWith('x-marina:\n'), blockFull);
const fullDoc = 'services:\n  web:\n    build: ./web\n' + blockFull;
const parsedFull = wbParseXmarina(fullDoc);
check('풀 xm 파싱 ok', parsedFull.ok === true, parsedFull);
check('풀 xm 왕복 동일(구조)', deepCanon(parsedFull.xm) === deepCanon(xmFull), { got: parsedFull.xm, want: xmFull });
check('풀 xm 왕복 — otherKeys 없음', parsedFull.otherKeys.length === 0, parsedFull.otherKeys);
check('서비스 prebuild 는 중첩 YAML 로 직렬화', /user-api:\n\s+cwd: be-api\n\s+command:/.test(blockFull), blockFull);

// ── links 서브레포별(per-subrepo) 왕복 — 실프로젝트(mdc-main) 형태 ─────────────────
const xmPerSub = {
  links: { symlink: [], copy: [], subs: {
    'be-api': { symlink: [], copy: ['**/*local.yml', '**/Dockerfile.local'] },
    'ai-api': { symlink: ['.venv'], copy: ['**/*local.yml'] },
  } },
};
const perSubDoc = 'services:\n  be-api:\n    build: ./be-api\n' + wbSerializeXmarina(xmPerSub, []);
const parsedPerSub = wbParseXmarina(perSubDoc);
check('서브레포별 파싱 ok', parsedPerSub.ok === true, parsedPerSub);
check('서브레포별 otherKeys 없음(잠금·유실 X)', parsedPerSub.otherKeys.length === 0, parsedPerSub.otherKeys);
check('서브레포별 왕복 동일', deepCanon(parsedPerSub.xm) === deepCanon(xmPerSub), { got: parsedPerSub.xm, want: xmPerSub });
// links: 블록이 문서에 딱 하나(중복 방지 — 편집 시 손상 회귀 가드)
check('links 블록 1개(중복 없음)', (perSubDoc.match(/^  links:/gm) || []).length === 1, perSubDoc);

// ── links 전역+서브레포 혼합 왕복 — 단일 links 블록에 공존(백엔드는 전역 우선이지만 폼은 둘 다 보존) ──
const xmMixed = {
  links: { symlink: ['node_modules'], copy: [], subs: { 'web': { symlink: [], copy: ['dist'] } } },
};
const mixedDoc = 'services:\n  web:\n    build: ./web\n' + wbSerializeXmarina(xmMixed, []);
const parsedMixed = wbParseXmarina(mixedDoc);
check('혼합 파싱 ok', parsedMixed.ok === true, parsedMixed);
check('혼합 왕복 동일', deepCanon(parsedMixed.xm) === deepCanon(xmMixed), { got: parsedMixed.xm, want: xmMixed });
check('혼합 links 블록 1개', (mixedDoc.match(/^  links:/gm) || []).length === 1, mixedDoc);

// ── malformed links(서브레포 노드가 리스트) → 폼이 못 읽으니 otherKeys 로 원문 보존(유실 X, 폼은 카드에서 편집 차단) ──
const badLinksDoc = 'services:\n  web:\n    build: ./web\nx-marina:\n  links:\n    web:\n    - not-a-map\n';
const parsedBad = wbParseXmarina(badLinksDoc);
check('malformed links 파싱 자체는 ok(잠금 X)', parsedBad.ok === true, parsedBad);
check('malformed links 는 otherKeys 로 보존', parsedBad.otherKeys.some(o => o.key === 'links'), parsedBad.otherKeys);
check('malformed links 는 xm.links 에 안 들어감', parsedBad.xm.links === undefined, parsedBad.xm);

// 재직렬화(re-serialize) 도 동일 텍스트를 만드는지(정성적 안정성 — 최소한 재파싱하면 다시 같은 구조)
const reBlock = wbSerializeXmarina(parsedFull.xm, parsedFull.otherKeys);
const reParsed = wbParseXmarina('services: {}\n' + reBlock);
check('재직렬화 후 재파싱도 동일 구조', deepCanon(reParsed.xm) === deepCanon(xmFull), reParsed.xm);

// ── 미지원 키 원문 보존 — 폼이 모르는 키(expose 포함 gateway, 임의 커스텀 키)는 그대로 살아남는다 ──
const customDoc = [
  'services:',
  '  web:',
  '    build: ./web',
  'x-marina:',
  '  java: 21',
  '  totallyUnknownKey:',
  '    nested:',
  '      deeper: yes   # 주석도 보존',
  '  gateway:',
  '    expose:',
  '      web:',
  "        NEXT_PUBLIC_API_URL: 'gateway:user-api'",
  '    routes:',
  '      user-api:',
  '      - /v1.0',
].join('\n') + '\n';
const parsedCustom = wbParseXmarina(customDoc);
check('미지원 키 포함 문서도 ok:true(전체 실패 아님)', parsedCustom.ok === true, parsedCustom);
check('java 는 지원 키로 정상 파싱', parsedCustom.xm.java === '21', parsedCustom.xm);
check('gateway 는 expose 동반이라 폼 미지원 → otherKeys 로', !('gateway' in parsedCustom.xm), parsedCustom.xm);
const otherKeyNames = parsedCustom.otherKeys.map(o => o.key).sort();
check('otherKeys 에 totallyUnknownKey·gateway 보존', JSON.stringify(otherKeyNames) === JSON.stringify(['gateway', 'totallyUnknownKey']), otherKeyNames);
const unknownRaw = parsedCustom.otherKeys.find(o => o.key === 'totallyUnknownKey').raw;
check('미지원 키 원문에 중첩 구조 보존', /nested:/.test(unknownRaw) && /deeper: yes/.test(unknownRaw), unknownRaw);
const gatewayRaw = parsedCustom.otherKeys.find(o => o.key === 'gateway').raw;
check('미지원 gateway 원문에 expose 보존', /expose:/.test(gatewayRaw) && /NEXT_PUBLIC_API_URL/.test(gatewayRaw), gatewayRaw);

// 재직렬화 → 재파싱해도 미지원 키가 계속 otherKeys 로 살아남는지(멱등)
const customBlock = wbSerializeXmarina(parsedCustom.xm, parsedCustom.otherKeys);
const customReparsed = wbParseXmarina('services: {}\n' + customBlock);
check('재직렬화 후에도 미지원 키 보존(멱등)', customReparsed.otherKeys.map(o => o.key).sort().join(',') === 'gateway,totallyUnknownKey', customReparsed.otherKeys);
check('재직렬화 후에도 java 보존', customReparsed.xm.java === '21', customReparsed.xm);

// x-marina 블록 자체가 없는 문서 — 유효한 빈 상태(ok:true, xm={})
const noBlock = wbParseXmarina('services:\n  web:\n    build: ./web\n');
check('x-marina 블록 없음 → ok:true, xm 빈 값', noBlock.ok === true && Object.keys(noBlock.xm).length === 0, noBlock);

// ── 깨진 YAML → ok:false(폼 잠금 트리거) ────────────────────────────────────────────────
const tabBroken = 'services: {}\nx-marina:\n\tjava: 21\n';
check('탭 들여쓰기 → ok:false', wbParseXmarina(tabBroken).ok === false, wbParseXmarina(tabBroken));

const structBroken = 'services: {}\nx-marina:\n  java 21\n';   // 콜론 없음 — 키:값 아님
check('키:값 형태 아님 → ok:false', wbParseXmarina(structBroken).ok === false, wbParseXmarina(structBroken));

const dedentBroken = 'services: {}\nx-marina:\n  links:\n    symlink:\n    - node_modules\n oops:\n';   // 블록 안에서 들여쓰기 얕아짐
check('블록 내 들여쓰기 붕괴 → ok:false', wbParseXmarina(dedentBroken).ok === false, wbParseXmarina(dedentBroken));

// ── wbReplaceXmarinaBlock — services 쪽 텍스트·주석 불변 ────────────────────────────────
const original = [
  'services:',
  '  web:   # 프론트',
  '    build: ./web',
  '    ports: ["3000:3000"]',
  'x-marina:',
  '  java: 17',
].join('\n') + '\n';
const replaced = wbReplaceXmarinaBlock(original, 'x-marina:\n  java: 21\n');
check('services 블록 텍스트·주석 불변', replaced.includes('web:   # 프론트') && replaced.includes('ports: ["3000:3000"]'), replaced);
check('x-marina 블록만 교체됨', replaced.includes('java: 21') && !replaced.includes('java: 17'), replaced);

const noXmDoc = 'services:\n  web:\n    build: ./web\n';
const appended = wbReplaceXmarinaBlock(noXmDoc, 'x-marina:\n  java: 21\n');
check('x-marina 블록 없던 문서에 새로 추가', appended.includes('x-marina:') && appended.includes('java: 21') && appended.startsWith('services:'), appended);

const removed = wbReplaceXmarinaBlock(original, '');
check('빈 블록 지정 시 x-marina 통째 제거', !removed.includes('x-marina:'), removed);
check('제거해도 services 는 남음', removed.includes('build: ./web'), removed);

if (failures > 0) { console.error(failures + '개 실패'); process.exit(1); }
console.log('node 왕복 테스트 통과');
JSEOF

# ── ② 폼 UI grep 불변식 — R4 라벨·잠금 문구·innerHTML 미사용 ──────────────────────────────
grep -q '무거운 폴더 공유' "$J" || { echo "FAIL: R4 라벨(무거운 폴더 공유) 없음"; exit 1; }
grep -q '내 컴퓨터의 DB/Redis 쓰기' "$J" || { echo "FAIL: R4 라벨(내 컴퓨터의 DB/Redis 쓰기) 없음"; exit 1; }
grep -q '브라우저 주소 자동 발급' "$J" || { echo "FAIL: R4 라벨(브라우저 주소 자동 발급) 없음"; exit 1; }
grep -q '이미지 빌드 전에 미리 빌드' "$J" || { echo "FAIL: R4 라벨(이미지 빌드 전에 미리 빌드) 없음"; exit 1; }
grep -q 'wb-prebuild-mode' "$J" || { echo "FAIL: prebuild 서비스/레거시 모드 선택 없음"; exit 1; }
grep -q '@container (max-width: 520px)' "$WEB/styles.css" || { echo "FAIL: 좁은 워크벤치 카드용 prebuild 레이아웃 없음"; exit 1; }
grep -q 'JDK 버전' "$J" || { echo "FAIL: R4 라벨(JDK 버전) 없음"; exit 1; }
grep -q '빌드 변수' "$J" || { echo "FAIL: R4 라벨(빌드 변수) 없음"; exit 1; }
grep -q 'x-marina 를 읽을 수 없어요' "$J" || { echo "FAIL: 폼 잠금 안내 문구 없음"; exit 1; }
grep -q "data-wb-form" "$WEB/index.html" || { echo "FAIL: data-wb-form 마커 소실"; exit 1; }
! grep -q '\.innerHTML' "$J" || { echo "FAIL: app-2c 가 innerHTML 을 사용함(금지)"; exit 1; }
! grep -qE '\balert\(' "$J" || { echo "FAIL: app-2c 가 alert 를 사용함(금지)"; exit 1; }

# 폼→에디터 루프 방지 플래그 존재(스펙 R2 — 폼발 input 이벤트가 폼을 다시 그리지 않게)
grep -q 'wbXmSyncGuard' "$J" || { echo "FAIL: 루프 방지 플래그(wbXmSyncGuard) 없음"; exit 1; }

# app-2b 훅 연결 — 편집기 programmatic 갱신 지점마다 wbFormSyncFromEditor 호출
grep -q 'wbFormSyncFromEditor' "$WEB/app-2b-workbench.js" || { echo "FAIL: app-2b 에 wbFormSyncFromEditor 훅 연결 없음"; exit 1; }
# (위저드 삭제 — R6) 신규 등록 진입은 이제 레포 후보 화면(app-2e-entry.js) → openWorkbench(mode:'new') 하나뿐이고,
# openWorkbench 자신이 mode:'new' 경로에서 wbFormSyncFromEditor 를 호출한다(위 app-2b 체크가 그 지점을 이미 커버) —
# 위저드 전용 재동기화 체크는 더 이상 필요 없음(구 wizAdvanced 만의 별도 진입점이 사라졌으므로).

# index.html 로드 순서 — app-2c 는 app-2b 다음, app-3 이전
python3 - "$WEB/index.html" <<'PY' || { echo "FAIL: app-2c 로드 순서 위반"; exit 1; }
import sys
html = open(sys.argv[1]).read()
i2b = html.index('<script src="/web/app-2b-workbench.js">')
i2c = html.index('<script src="/web/app-2c-xmarina-form.js">')
i3 = html.index('<script src="/web/app-3-util.js">')
assert i2b < i2c < i3, "app-2c 가 app-2b 다음·app-3 이전에 로드되지 않음"
PY

# ── ③ 전 웹 JS 문법 (전체 회귀) ─────────────────────────────────────────────────────────
for f in "$WEB"/app-*.js; do
  node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
done

echo "PASS test-xmarina-form-roundtrip"
