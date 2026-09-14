// 헤더 Docker 디스크 배지 + GC 정책 팝오버 — 워크트리에 안 묶인 도커 산출물(빌드캐시·dangling·익명 볼륨·e2e 잔재)의
// 주기 정리를 marina 안에서 보고·고치고·지금 돌린다. 엔진은 데몬·CLI 와 같은 /api/docker-gc (marina_docker_gc.py).
// 배지 하나(글리프+합계)가 상태를 색으로 알린다: 자동 정리 꺼짐=흐림(.off), 마지막 실행 실패=적색(.warn). 별도 칩 없음.
(() => {
  const box = document.getElementById('dgc');
  const btn = document.getElementById('dgcBtn');
  const sizeEl = document.getElementById('dgcSize');
  const menu = document.getElementById('dgcMenu');
  if (!box || !btn || !menu) return;

  const POLICY_ROWS = [   // [key, 라벨, 종류, 단위]  — 정책 파일(~/.marina/docker-gc.json) 키와 1:1
    ['enabled', '자동 정리', 'bool', ''],
    ['interval_hours', '주기', 'int', 'h'],
    ['build_cache_keep_days', '빌드캐시 보관', 'int', '일'],
    ['dangling_images', 'dangling 이미지', 'bool', ''],
    ['anonymous_volumes', '익명 볼륨', 'bool', ''],
    ['stale_test_artifacts_days', 'e2e 잔재', 'int', '일'],
    ['stale_test_artifact_names', 'e2e 이름 글롭', 'text', ''],   // 라벨 없는 옛 누수(mdce2e*·proj-*-weaveapp) 도 여기 글롭을 더하면 같은 규칙으로 회수
  ];
  const TITLES = {
    enabled: '데몬이 주기대로 자동 실행. 꺼도 "지금 정리"·CLI --now 는 된다',
    interval_hours: '자동 실행 주기(시간)',
    build_cache_keep_days: '이보다 오래 안 쓴 빌드캐시를 지운다. 0=끔',
    dangling_images: '<none>:<none> 이미지 중 어떤 컨테이너도 안 쓰는 것',
    anonymous_volumes: '어떤 컨테이너에도 안 붙은 익명 볼륨만(명명 볼륨은 절대 아님)',
    stale_test_artifacts_days: '라벨 marina.e2e=1 또는 이름 글롭에 맞는 컨테이너·이미지·네트워크 중 이보다 오래된 것. 0=끔',
    stale_test_artifact_names: 'e2e 산출물로 볼 이름 글롭(쉼표 구분). 라벨 marina.e2e=1 은 항상 포함. 예: marina-*-e2e-*,mdce2e*',
  };
  let state = null;   // 마지막 /api/docker-gc 응답
  let lastResult = null;   // 미리보기/실행 결과(팝오버 안 표)

  const gb = mb => `${((Number(mb) || 0) / 1024).toFixed(1)}GB`;
  const fmt = mb => (Number(mb) || 0) >= 1024 ? gb(mb) : `${Math.max(0, Math.round(Number(mb) || 0))}MB`;
  const ago = ts => {
    if (!ts) return '아직 실행 안 됨';
    const s = Math.max(0, Math.floor(Date.now() / 1000 - Number(ts)));
    if (s < 3600) return `${Math.floor(s / 60)}분 전`;
    if (s < 86400) return `${Math.floor(s / 3600)}시간 전`;
    return `${Math.floor(s / 86400)}일 전`;
  };
  const when = ts => ts ? new Date(Number(ts) * 1000).toLocaleString('ko-KR', {month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit'}) : '—';

  function statusLine(st) {
    const s = st?.state || {};
    if (!s.finishedAt) return '아직 정리한 적 없음';
    const base = `마지막 정리 <b>${ago(s.finishedAt)}</b> · 회수 <b>${fmt(s.reclaimedMb)}</b> <span class="dim">(${escapeHtml(s.source || '')})</span>`;
    return s.error ? `${base}<br>실패: ${escapeHtml(s.error)}` : base;
  }

  function renderDockerGc(st) {
    state = st;
    const d = st?.disk || {};
    const total = (Number(d.imagesMb) || 0) + (Number(d.buildCacheMb) || 0) + (Number(d.volumesMb) || 0);
    sizeEl.textContent = gb(total);
    const pol = st?.policy || {};
    const s = st?.state || {};
    box.classList.toggle('off', pol.enabled === false);
    box.classList.toggle('warn', !!s.error);
    const lines = [
      `Docker 디스크 ${gb(total)} — images ${gb(d.imagesMb)} · build cache ${gb(d.buildCacheMb)} · volumes ${gb(d.volumesMb)}`,
      s.finishedAt ? `마지막 정리 ${ago(s.finishedAt)} · 회수 ${fmt(s.reclaimedMb)}${s.error ? ' · 실패' : ''}` : '아직 정리한 적 없음',
      pol.enabled === false ? '자동 정리 꺼짐' : `자동 정리 ${pol.interval_hours}h 주기${st?.nextRunAt && !st?.due ? ` · 다음 ${when(st.nextRunAt)}` : ' · 다음 틱에 실행'}`,
      '클릭: 정책·미리보기·지금 정리',
    ];
    btn.title = lines.join('\n');
    if (!menu.hidden) renderMenu();
  }

  function renderMenu() {
    const pol = state?.policy || {};
    const rows = POLICY_ROWS.map(([key, label, kind, unit]) => {
      const ctl = kind === 'bool'
        ? `<input type="checkbox" data-dgc-key="${key}" ${pol[key] ? 'checked' : ''} />`
        : kind === 'text'
          ? `<input type="text" class="dgc-text" data-dgc-key="${key}" value="${escapeHtml(Array.isArray(pol[key]) ? pol[key].join(',') : (pol[key] ?? ''))}" spellcheck="false" />`
          : `<span><input type="number" min="0" step="1" data-dgc-key="${key}" value="${escapeHtml(pol[key] ?? '')}" /><span class="dgc-unit">${unit}</span></span>`;
      return `<label class="settings-row" title="${escapeHtml(TITLES[key] || '')}"><span>${label}</span>${ctl}</label>`;
    }).join('');
    const warn = (pol.warnings || []).length ? `<div class="dgc-status err">${(pol.warnings || []).map(escapeHtml).join('<br>')}</div>` : '';
    menu.innerHTML = `
      <div class="dgc-status${state?.state?.error ? ' err' : ''}">${statusLine(state)}</div>
      ${warn}
      <div class="dgc-sep"></div>
      ${rows}
      <div class="dgc-sep"></div>
      <div class="dgc-actions">
        <button type="button" id="dgcPreview" title="정책대로 지울 것과 예상 회수량만 — 아무것도 안 지움">미리보기</button>
        <button type="button" id="dgcRun" title="정책대로 지금 정리 (실행 중 컨테이너가 쓰는 것은 절대 안 건드림)">지금 정리</button>
      </div>
      ${lastResult ? `<div class="dgc-result" id="dgcResult">${resultHtml(lastResult)}</div>` : ''}`;
    for (const input of menu.querySelectorAll('[data-dgc-key]')) {
      input.addEventListener('change', () => setPolicy(input.dataset.dgcKey, input.type === 'checkbox' ? input.checked : input.value));
    }
    document.getElementById('dgcPreview').onclick = (e) => runGc(e.currentTarget, {dryRun: true});
    document.getElementById('dgcRun').onclick = (e) => runGc(e.currentTarget, {dryRun: false});
  }

  function resultHtml(r) {
    const head = `${r.dryRun ? '미리보기 — 예상 회수' : '정리 완료 — 회수'} <b>${fmt(r.reclaimedMb)}</b>`;
    const steps = (r.steps || []).map(s => {
      if (s.skipped) return `<span class="dim">${escapeHtml(s.name)}: 꺼짐</span>`;
      if (s.error) return `${escapeHtml(s.name)}: <span class="err">실패 — ${escapeHtml(s.error)}</span>`;
      const n = s.counts ? `${s.counts.containers}c·${s.counts.images}i·${s.counts.networks}n` : `${(s.items || []).length}개`;
      return `${escapeHtml(s.name)}: ${fmt(s.reclaimedMb)} <span class="dim">(${n})</span>`;
    });
    const items = (r.steps || []).flatMap(s => (s.items || []).slice(0, 8)).map(escapeHtml);
    return [head, ...steps, ...(items.length ? ['<span class="dim">' + items.join('<br>') + '</span>'] : [])].join('<br>');
  }

  async function setPolicy(key, value) {
    try {
      const r = await api('/api/docker-gc/policy', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({key, value})});
      state = {...(state || {}), policy: r.policy};
      renderDockerGc(state);
      await loadDockerGc();   // due/nextRunAt 재계산
    } catch (e) {
      alert('정책 저장 실패: ' + (e && e.message ? e.message : e));
      renderMenu();           // 입력값 되돌림
    }
  }

  function runGc(button, {dryRun}) {
    return withBusy(button, '…', async () => {
      const r = await api('/api/docker-gc/run', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({dryRun})});
      lastResult = r;
      if (!dryRun && typeof showToast === 'function') showToast(r.error ? `정리 일부 실패: ${r.error}` : `Docker 정리 — ${fmt(r.reclaimedMb)} 회수`, r.error ? 'error' : 'ok');
      await loadDockerGc({force: true});
      renderMenu();
    });
  }

  async function loadDockerGc(opts) {
    let st;
    try { st = await api('/api/docker-gc' + (opts && opts.force ? '?refresh=1' : '')); } catch { return; }
    renderDockerGc(st);
  }

  function closeMenu(e) {
    if (e && (menu.contains(e.target) || btn.contains(e.target))) return;
    menu.hidden = true;
    btn.setAttribute('aria-expanded', 'false');
    document.removeEventListener('click', closeMenu);
  }
  btn.onclick = (e) => {
    e.stopPropagation();
    const open = menu.hidden;
    if (open) { renderMenu(); menu.hidden = false; btn.setAttribute('aria-expanded', 'true'); setTimeout(() => document.addEventListener('click', closeMenu), 0); }
    else closeMenu();
  };
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !menu.hidden) closeMenu(); });

  // admin 만(정리는 호스트 도커를 건드린다). auth 가 꺼진 로컬은 admin 과 같다.
  window.marinaAuth.refresh().then(st => {
    const hide = st.enabled && st.user?.role !== 'admin';
    box.hidden = hide;
    if (!hide) loadDockerGc();
  }).catch(() => { box.hidden = true; });
  setInterval(() => { if (!document.hidden && !box.hidden) loadDockerGc(); }, 60000);
  window.loadDockerGc = loadDockerGc;
})();
