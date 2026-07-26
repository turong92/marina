// app-0b-reconcile.js — 공유 keyed DOM reconciler. 폴링 재렌더가 노드를 부수지 않게 하는 단일 프리미티브.
// 노드를 key 로 재사용하고 바뀐 것만 patch → 포커스·캐럿·미저장 입력값·스크롤·열린 select/메뉴·<details> open 이
// 구조적으로 생존한다(노드가 안 사라지니까). 사이트별 signature-skip/defer/capture-restore 가드를 대체한다.
// 계약: reconcile 은 container 의 자식 전체를 소유한다 — dataset.rkey 가 없는 자식(예: 다른 경로에서
// innerHTML 로 넣은 정적 empty-state 노드)도 매 호출마다 정리 대상이다. 정적 형제를 유지하려면 별도
// 엘리먼트(예: container 바깥의 sibling)에 두어야 한다. container 안에 두면 다음 reconcile 호출 때 사라진다.
function reconcile(container, items, opts) {
  const key = opts.key, create = opts.create, patch = opts.patch;
  // 현재 자식을 key→node 로 색인. key 없는(dataset.rkey 미설정) 자식은 잔재 취급 — 아래 정리 단계에서 제거.
  const existing = new Map();
  const unkeyed = [];
  for (const node of Array.from(container.children)) {
    const k = node.dataset ? node.dataset.rkey : undefined;
    if (k != null) existing.set(k, node);
    else unkeyed.push(node);
  }
  const seen = new Set();
  let index = 0; // 다음에 배치할 슬롯(container.children 기준 인덱스)
  for (const item of items) {
    const k = String(key(item));
    seen.add(k);
    let node = existing.get(k);
    if (node) {
      existing.delete(k); // 이 items 배열 안에서 중복 key 가 다시 나오면 새 노드를 만들도록(같은 노드 재사용 금지)
      if (patch) patch(node, item);
    } else {
      node = create(item);
      if (node.dataset) node.dataset.rkey = k;
    }
    // 이 슬롯에 이미 올바른 노드가 있으면 건드리지 않는다(정체성/DOM 위치 보존)
    const ref = container.children[index] || null;
    if (ref !== node) container.insertBefore(node, ref);
    index += 1;
  }
  // items 에 없는 잔여 노드 제거
  for (const [k, node] of existing) {
    if (!seen.has(k)) container.removeChild(node);
  }
  // key 없는 잔재 노드(정적 empty-state 등) 제거 — container 는 reconcile 이 전부 소유한다.
  for (const node of unkeyed) container.removeChild(node);
}
