#!/usr/bin/env bash
# reconcile() 순수 로직 — 노드 재사용/추가/삭제/재정렬. DOM 없는 node vm + 최소 스텁.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$HERE/../scripts/marina-web/app-0b-reconcile.js"

node - "$SRC" <<'JS'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

// 최소 DOM 스텁: childNodes 배열, appendChild/insertBefore/removeChild, dataset, 간단 textContent.
function makeEl(tag='div') {
  const el = {
    tagName: tag.toUpperCase(), dataset: {}, _children: [], parentNode: null,
    get children(){ return this._children; },
    appendChild(c){ if(c.parentNode) c.parentNode.removeChild(c); c.parentNode=this; this._children.push(c); return c; },
    insertBefore(c, ref){ if(c.parentNode) c.parentNode.removeChild(c); c.parentNode=this;
      const i = ref? this._children.indexOf(ref): -1; if(i<0) this._children.push(c); else this._children.splice(i,0,c); return c; },
    removeChild(c){ const i=this._children.indexOf(c); if(i>=0)this._children.splice(i,1); c.parentNode=null; return c; },
    get firstChild(){ return this._children[0] || null; },
  };
  return el;
}
const ctx = { document: { createElement: makeEl }, console };
vm.createContext(ctx);
vm.runInContext(src, ctx, {filename:'app-0b-reconcile.js'});
const { reconcile } = ctx;
if (typeof reconcile !== 'function') { console.log('FAIL reconcile not defined'); process.exit(1); }

const box = makeEl();
const create = it => { const e = makeEl(); e._id = it.id; e._patched = it.v; return e; };
const patch = (e, it) => { e._patched = it.v; };
const key = it => String(it.id);

// 1) 최초 생성 — 순서대로
reconcile(box, [{id:'a',v:1},{id:'b',v:2},{id:'c',v:3}], {key,create,patch});
let ids = box.children.map(c=>c._id);
if (ids.join() !== 'a,b,c') { console.log('FAIL initial order', ids); process.exit(1); }
const nodeA = box.children[0], nodeB = box.children[1];

// 2) 값만 변경 — 같은 노드 재사용(정체성 유지) + patch 반영
reconcile(box, [{id:'a',v:10},{id:'b',v:2},{id:'c',v:3}], {key,create,patch});
if (box.children[0] !== nodeA) { console.log('FAIL node A not reused'); process.exit(1); }
if (box.children[0]._patched !== 10) { console.log('FAIL patch not applied'); process.exit(1); }

// 3) 중간 삭제
reconcile(box, [{id:'a',v:10},{id:'c',v:3}], {key,create,patch});
if (box.children.map(c=>c._id).join() !== 'a,c') { console.log('FAIL delete', box.children.map(c=>c._id)); process.exit(1); }

// 4) 재정렬 + 신규 삽입 — 기존 노드 재사용
reconcile(box, [{id:'c',v:3},{id:'d',v:4},{id:'a',v:10}], {key,create,patch});
if (box.children.map(c=>c._id).join() !== 'c,d,a') { console.log('FAIL reorder', box.children.map(c=>c._id)); process.exit(1); }
if (box.children[2] !== nodeA) { console.log('FAIL A identity lost after reorder'); process.exit(1); }

// 5) 같은 items 배열 안에 중복 key — 기존에 매칭된 노드를 두 번째 중복 항목이 다시 가로채면 안 됨
//    (existing 에서 매치된 key 를 제거하지 않으면 두 항목이 노드 하나로 붕괴하는 회귀 버그를 잡는 테스트)
const box2 = makeEl();
reconcile(box2, [{id:'x',v:1}], {key,create,patch}); // 기존 노드 하나를 미리 만들어 둔다(rkey='x')
reconcile(box2, [{id:'x',v:1},{id:'x',v:2}], {key,create,patch});
if (box2.children.length !== 2) { console.log('FAIL duplicate key collapsed to', box2.children.length, 'node(s)'); process.exit(1); }
if (box2.children[0] === box2.children[1]) { console.log('FAIL duplicate key items share the same node'); process.exit(1); }
if (box2.children.map(c=>c._patched).join() !== '1,2') { console.log('FAIL duplicate key patch values wrong', box2.children.map(c=>c._patched)); process.exit(1); }

// 6) 컨테이너 안에 key 없는(dataset.rkey 미설정) 정적 노드(예: empty-state div)가 있으면
//    reconcile 이 소유권을 가지므로 제거해야 한다 — 안 그러면 empty→items 전환 때 좌초된다.
const box3 = makeEl();
const staleEmpty = makeEl(); // dataset={} 라 rkey 없음 — innerHTML 로 넣은 정적 empty-state 시뮬레이션
box3.appendChild(staleEmpty);
reconcile(box3, [{id:'a',v:1},{id:'b',v:2}], {key,create,patch});
if (box3.children.length !== 2) { console.log('FAIL stale unkeyed node not removed, count=', box3.children.length); process.exit(1); }
if (box3.children.includes(staleEmpty)) { console.log('FAIL stale unkeyed node still present'); process.exit(1); }
if (box3.children.map(c=>c._id).join() !== 'a,b') { console.log('FAIL post-cleanup order', box3.children.map(c=>c._id)); process.exit(1); }

console.log('PASS reconcile keyed reuse/add/remove/reorder');
JS
