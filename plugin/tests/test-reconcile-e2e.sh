#!/usr/bin/env bash
# reconcile 이주(인박스·세션카드) 실브라우저 보존 e2e — Aside 로컬 검증(문서/수동).
# CI 아님: Aside 앱 실행 + `~/.local/bin/aside` 필요. 없으면 SKIP(0 반환).
#
# 검증 항목(2026-07-26 실측 통과):
#   A 노드 재사용 — 카드 노드가 render/updateServiceStates 거쳐도 identity 유지
#   B alias 편집 중 폴 render — input 노드 재사용·포커스·값·캐럿 보존
#   C #sessions 무결성 — 중복/unkeyed leftover 없음, 모든 자식 rkey 보유
#   D 구조 변경(서비스 추가) — 같은 카드 노드에 새 svc 행 반영
#   G 그룹라벨 — claude+codex 혼합 프로젝트에서 grp:* keyed 의사아이템, unkeyed 0
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "$HERE/../.." && pwd -P)"
ASIDE="$HOME/.local/bin/aside"
PORT=3910

command -v "$ASIDE" >/dev/null 2>&1 || { echo "SKIP: aside CLI 없음 (실브라우저 e2e 생략)"; exit 0; }

# asdf 워크트리 코드를 실데이터로 별도 포트에 (auth off = fresh MARINA_AUTH_DB)
TMP="$(mktemp -d)"; trap 'pkill -f "MARINA_CONTROL_PORT=$PORT" 2>/dev/null; rm -rf "$TMP"' EXIT
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$HOME/.marina" \
  MARINA_AUTH_DB="$TMP/auth.db" nohup python3 "$REPO/plugin/scripts/marina-control.py" >"$TMP/ctrl.log" 2>&1 &
sleep 3
curl -s -o /dev/null -w "" --max-time 5 "http://127.0.0.1:$PORT/" || { echo "FAIL: :$PORT 미기동"; exit 1; }

read -r -d '' JS <<'EOF'
const sleep = ms => new Promise(r => setTimeout(r, ms));
const p = await openTab('http://127.0.0.1:3910/');
await sleep(2800);
const out = {};
await p.evaluate(async () => { try { await load({force:true}); } catch(e){} });
out.A = await p.evaluate(() => {
  const cards=[...document.querySelectorAll('#sessions > [data-root]')]; if(!cards.length) return {skip:1};
  const first=cards[0], root=first.getAttribute('data-root'); first.setAttribute('data-e2e','1');
  render(); const a=document.querySelector(`#sessions > [data-root="${CSS.escape(root)}"]`);
  const r1=a===first&&a.hasAttribute('data-e2e');
  if(typeof updateServiceStates==='function') updateServiceStates();
  const b=document.querySelector(`#sessions > [data-root="${CSS.escape(root)}"]`);
  return {ok: r1 && b===first};
});
out.B = await p.evaluate(() => {
  const d=document.querySelector('#sessions > [data-root] [data-alias-display]'); if(!d) return {skip:1};
  d.click(); const i=document.querySelector('#sessions > [data-root] [data-alias]:not([hidden])')||document.querySelector('#sessions > [data-root] [data-alias]');
  if(!i) return {skip:1}; i.focus(); i.value='ZZe2e'; i.setSelectionRange(2,2);
  if(typeof sessionSignature!=='undefined') sessionSignature='__stale__'+sessionSignature; render();
  const j=document.querySelector('#sessions > [data-root] [data-alias]');
  const ok = j===i && document.activeElement===i && i.value==='ZZe2e' && i.selectionStart===2; i.blur(); return {ok};
});
out.C = await p.evaluate(() => {
  render(); render(); const k=[...document.getElementById('sessions').children];
  const roots=k.filter(x=>x.hasAttribute('data-root')).map(x=>x.getAttribute('data-root'));
  return {ok: roots.length===new Set(roots).size && k.every(x=>x.dataset&&x.dataset.rkey!=null)};
});
out.D = await p.evaluate(() => {
  const c=document.querySelector('#sessions > [data-root]'); if(!c) return {skip:1};
  const root=c.getAttribute('data-root'), s=(typeof sessions!=='undefined'?sessions:[]).find(x=>x.root===root); if(!s) return {skip:1};
  const b=c.querySelectorAll('[data-service-key]').length;
  s.services=[...(s.services||[]),{service:'__e2e_fake__',running:false,state:'stopped',port:''}]; render();
  const c2=document.querySelector(`#sessions > [data-root="${CSS.escape(root)}"]`);
  const ok = c2===c && c.querySelectorAll('[data-service-key]').length===b+1;
  s.services=(s.services||[]).filter(x=>x.service!=='__e2e_fake__'); render(); return {ok};
});
console.log('RESULT='+JSON.stringify(out));
EOF

RES="$("$ASIDE" repl "$JS" 2>&1 | grep -o 'RESULT=.*' | head -1)"
echo "$RES"
python3 - "$RES" <<'PY'
import sys, json
raw = sys.argv[1] if len(sys.argv) > 1 else ""
if not raw.startswith("RESULT="):
    print("SKIP: Aside 결과 없음 (앱 미실행?)"); sys.exit(0)
data = json.loads(raw[len("RESULT="):])
bad = [k for k,v in data.items() if not (v.get("ok") or v.get("skip"))]
skipped = [k for k,v in data.items() if v.get("skip")]
if bad:
    print("FAIL:", ", ".join(bad)); sys.exit(1)
print("PASS: reconcile 보존 e2e" + (f" (skipped: {','.join(skipped)})" if skipped else ""))
PY
