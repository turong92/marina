    // app-9-connections.js — 워크스페이스 '연결' 탭: 워크트리별 연결을 "내 컴퓨터 안의 중첩 박스"로 표현.
    // 전역 공유(classic script): api/enc/escapeHtml/shortPath(app-3), sessions/selectedProjectId(app-1),
    //   gatewayState/gatewayUrlFor/loadGatewayState(app-3), STATE_META(app-5), selectLog(app-4), setWsTab/WS_VIEWS(app-6), gitMainRoot(app-8).
    //
    // 설계(2026-07-14):
    //  · 헤더에 워크트리 선택기 — 연결 탭 자체에서 워크트리를 고른다(예전엔 로그에서 클릭한 서비스에 묶여 워크트리별 보기가 힘들었다).
    //  · 흐름도(SVG 엣지)는 헤어볼·라벨겹침으로 폐기. 다 내 컴퓨터(호스트) 안에 있으므로 중첩(containment)으로:
    //    💻 내 컴퓨터 ⊃ { 🌐 브라우저(게이트웨이 주소) · 📦 컨테이너(서비스 카드) · 🖥 호스트 인프라(:포트 별 이름) }.
    //  · 상태는 좌측 카드와 같은 상태색 닷. 서비스 클릭=로그.
    const CONN_DOT_VAR = { run: '--st-run', stop: '--st-stop', boot: '--st-boot', bad: '--st-err', ext: '--st-ext' };

    function connStVar(svc) {
      const st = svc.state || (svc.running ? 'running' : 'stopped');
      const dot = (STATE_META[st] || STATE_META.stopped).dot;
      return CONN_DOT_VAR[dot] || '--st-stop';
    }

    let connSelectedRoot = null;   // 연결 탭이 현재 보고 있는 워크트리(선택기 상태)
    let connForwardDirty = false;  // 엮기(forward) 편집 후 — 재시작해야 실제 적용 배너 표시

    // 현재 프로젝트의 워크트리(세션) 목록 — 선택기 옵션. 서비스 없는 것도 포함(사용자가 골라 확인 가능).
    function connWorktrees() {
      const list = (typeof sessions !== 'undefined' ? sessions : []);
      const pid = (typeof selectedProjectId !== 'undefined') ? selectedProjectId : null;
      return list.filter(s => !pid || s.projectId === pid);
    }
    function connWtLabel(s) {
      const base = s.alias || s.id || (typeof shortPath === 'function' ? shortPath(s.root) : (s.root || '').split('/').pop());
      const isMain = s.isMain || s.source === 'main' || !/\/worktrees\//.test(s.root || '');   // .claude/·.codex/ worktrees 모두 워크트리로 취급
      return isMain ? `${base} (main)` : base;
    }

    // 워크스페이스 '연결' 탭 진입 — 선택 워크트리(또는 폴백) 컨텍스트로 렌더.
    // 좌측 프로젝트 전환 시 연결 탭이 그 프로젝트를 따라가게(app-1 setSelectedProject 가 호출) — 선택 워크트리는 새 프로젝트 기본으로 리셋.
    function connFollowProject() {
      connSelectedRoot = null;
      if (typeof wsActive !== 'undefined' && wsActive === 'conn') {
        const pane = document.getElementById('tab-conn');
        if (pane) renderConnPanel(pane, null);
      }
    }
    function connProjectLabel() {
      if (typeof projectSummaries !== 'function') return '';
      const p = projectSummaries().find(s => s.id === selectedProjectId);
      return p ? p.label : '';
    }
    function renderConnPanel(container, root) {
      const wts = connWorktrees();
      const inProject = (r) => wts.some(s => s.root === r);
      if (root && !inProject(root)) root = null;   // 다른 프로젝트 소속 root(전환 잔재) 버림
      if (!root) root = (connSelectedRoot && inProject(connSelectedRoot)) ? connSelectedRoot
                       : (typeof gitMainRoot === 'function' && inProject(gitMainRoot())) ? gitMainRoot()
                       : (wts[0] && wts[0].root);
      if (!root) { container.innerHTML = '<div class="git-err" style="padding:14px">프로젝트가 아직 없어요 — 먼저 프로젝트를 등록하세요</div>'; return; }
      connSelectedRoot = root;
      const proj = connProjectLabel();
      const opts = wts.map(s => `<option value="${escapeHtml(s.root)}"${s.root === root ? ' selected' : ''}>${escapeHtml(connWtLabel(s))}</option>`).join('');
      container.innerHTML = `<div class="git-head git-panel-head conn-head">
          ${proj ? `<span class="conn-proj" title="좌측 프로젝트를 따라갑니다">${escapeHtml(proj)}</span>` : ''}
          <select data-conn-wt title="연결을 볼 워크트리 — 워크트리마다 실행상태·게이트웨이 주소가 다릅니다">${opts}</select>
          <span class="git-legend">💻 내 컴퓨터(🌐 브라우저·인프라) ↔ 📦 Docker(격리) · 파랑=게이트웨이 진입 · 주황=엮기(localhost) · 실행=초록·정지=회색 · 서비스 클릭=로그</span>
          <span class="git-head-fill"></span>
          <button data-conn-refresh title="새로고침 — 엮기·게이트웨이 상태 다시 조회">↻</button></div>
        <div class="git-body conn-panel" data-conn-body>불러오는 중…</div>`;
      const sel = container.querySelector('[data-conn-wt]');
      if (sel) sel.onchange = (e) => { connSelectedRoot = e.target.value; loadConnInto(container, e.target.value); };
      container.querySelector('[data-conn-refresh]').onclick = () => loadConnInto(container, connSelectedRoot);
      loadConnInto(container, root);
    }

    async function loadConnInto(container, root) {
      const body = container.querySelector('[data-conn-body]'); if (!body) return;
      await loadGatewayState();
      const session = (sessions || []).find(s => s.root === root);
      if (!session || !(session.services || []).length) {
        body.innerHTML = `<div class="conn-empty">
            <div class="conn-empty-title">이 워크트리엔 아직 실행할 서비스가 없어요</div>
            <div class="conn-empty-sub">세션 카드에서 <b>▶ 전체 시작</b>을 누르면 서비스가 뜨고, 연결이 여기에 그려져요.</div>
          </div>`;
        return;
      }
      let wm = { ok: false };
      try { wm = await api(`/api/weave-map?root=${enc(root)}`); }
      catch (e) { wm = { ok: false, error: e.message }; }
      if (connSelectedRoot && connSelectedRoot !== root) return;   // 응답 대기 중 워크트리 전환됨 — 옛 응답이 새 화면을 덮지 않게(stale 가드)
      renderConnFlow(body, root, session, wm);
    }
    WS_VIEWS.conn = { activate(pane, ctx) { renderConnPanel(pane, (ctx && ctx.root) || connSelectedRoot); } };

    // 두 구역(존) 노드-엣지: 좌=💻 내 컴퓨터(호스트 — 🌐 브라우저 + redis/kafka/milvus 인프라 노드) · 우=📦 Docker(격리 — 서비스 노드).
    // 도커 서비스는 호스트와 격리된 별개(형 지적). forward 는 전역 공유 맵이라 서비스별이 아니라 "컨테이너(도커망) 전체 → 인프라"로 엣지를 묶는다(A안, 깔끔·정확).
    const CONN_PORT_NAMES = { '6379': 'redis', '5432': 'postgres', '3306': 'mysql', '9092': 'kafka', '27017': 'mongo', '19530': 'milvus', '9200': 'elastic', '5672': 'rabbitmq', '8123': 'clickhouse' };
    function renderConnFlow(body, root, session, wm) {
      const appServiceNames = wm.ok && Array.isArray(wm.appServices) ? new Set(wm.appServices) : null;
      const services = (session.services || []).filter(s => !appServiceNames || appServiceNames.has(s.service));
      if (!services.length) { body.innerHTML = '<div class="conn-warn">등록된 compose 서비스가 없어요</div>'; return; }
      const forward = (wm.ok && wm.forward) || {};
      const gwOn = gatewayState.enabled;
      const svcFwdPort = (name) => Object.keys(forward).filter(p => forward[p] === name).sort((a, b) => Number(a) - Number(b));
      const hostPorts = Object.keys(forward).filter(p => forward[p] === 'host').sort((a, b) => Number(a) - Number(b));
      // x-marina.gateway.expose = {consumer:{ENV:'gateway:target'|'origin:target'}} → [{consumer, var, mode, target}]
      const gwCfg = (wm.ok && wm.gateway) || {};
      const exposeList = [];
      for (const [consumer, envmap] of Object.entries(gwCfg.expose || {})) {
        for (const [v, val] of Object.entries(envmap || {})) {
          const m = /^(gateway|origin):(.+)$/.exec(String(val).trim());
          if (m) exposeList.push({ consumer, var: v, mode: m[1], target: m[2].trim() });
        }
      }

      // 서비스 노드는 접근 경로 3개(내부·호스트·도메인)를 담아 더 높고 넓다 — 호스트 존 노드와 치수 분리.
      const NODE_H = 48, ROW_H = 74, ZHEAD = 46;          // 좌(호스트 존) 노드
      const SVC_H = 70, SVC_ROW = 88;                      // 우(Docker 존) 서비스 노드
      const LZ_X = 16, ZW_L = 270, RZ_X = 440, ZW_R = 304, ZTOP = 18;   // 폭 합 760 — 연결 패널(≈744~)에 맞춤. 좁으면 SVG 가 비율 유지 축소.
      const nodeXL = LZ_X + 20, nodeW_L = ZW_L - 40;
      const nodeXR = RZ_X + 16, nodeW_R = ZW_R - 62;   // 우측 여백 = expose(서비스↔서비스) 엣지가 지나는 레인
      const hostRows = 1 + hostPorts.length + 1;        // 브라우저 + 인프라 + [+ 인프라 추가] 행
      const dockerRows = services.length + 1;           // 서비스 + [+ 서비스 연결(expose)] 행
      const contentTop = ZTOP + ZHEAD;
      const contentH = Math.max(hostRows * ROW_H, dockerRows * SVC_ROW);
      const zoneH = ZHEAD + contentH + 18;
      const h = ZTOP + zoneH + 18;
      const w = RZ_X + ZW_R + 20;
      const rowY = i => contentTop + i * ROW_H + NODE_H / 2;        // 좌 존
      const svcRowY = i => contentTop + i * SVC_ROW + SVC_H / 2;    // 우 존
      const curve = (x0, y0, x1, y1) => { const dir = x1 >= x0 ? 1 : -1; const dx = Math.max(46, Math.abs(x1 - x0) * 0.42) * dir; return `M${x0},${y0} C${x0 + dx},${y0} ${x1 - dx},${y1} ${x1},${y1}`; };
      const esc = escapeHtml;

      let edges = '', nodes = '';

      // ── 존 박스 ──
      nodes += `<rect x="${LZ_X}" y="${ZTOP}" width="${ZW_L}" height="${zoneH}" rx="14" class="conn-zone-box conn-zone-host"/>
          <text x="${LZ_X + 14}" y="${ZTOP + 22}" class="conn-zone-label">💻 내 컴퓨터 (호스트)</text>`;
      nodes += `<rect x="${RZ_X}" y="${ZTOP}" width="${ZW_R}" height="${zoneH}" rx="14" class="conn-zone-box conn-zone-docker"/>
          <text x="${RZ_X + 14}" y="${ZTOP + 22}" class="conn-zone-label">📦 Docker (격리)</text>`;

      // ── 좌: 🌐 브라우저(row0) — 게이트웨이 주소를 노드 안에. + redis/kafka/milvus 인프라 노드 ──
      const gwList = services.map(svc => { const d = gwOn && gatewayUrlFor(session, svc); return d ? { svc, url: d, label: d.replace(/^https?:\/\//, '').replace(/\/$/, '') } : null; }).filter(Boolean);
      const brY = rowY(0);
      const brSub = gwList.length === 0 ? (gwOn ? '게이트웨이 주소 없음' : '게이트웨이 꺼짐')
                    : gwList.length === 1 ? gwList[0].label
                    : `주소 ${gwList.length}개 (hover)`;
      const brOpen = gwList.length ? ` data-conn-open="${esc(gwList[0].url)}"` : '';
      const brTitle = gwList.map(g => g.label + ' → ' + g.svc.service).join('\n');
      nodes += `<g class="conn-node-g${gwList.length ? ' conn-open' : ''}"${brOpen}><title>${esc(brTitle)}</title>
          <rect x="${nodeXL}" y="${brY - NODE_H / 2}" width="${nodeW_L}" height="${NODE_H}" rx="10" class="conn-node conn-node-browser"/>
          <text x="${nodeXL + 14}" y="${brY - 3}" class="conn-node-title">🌐 브라우저</text>
          <text x="${nodeXL + 14}" y="${brY + 15}" class="conn-node-sub">${esc(brSub)}</text></g>`;
      hostPorts.forEach((p, i) => {
        const y = rowY(1 + i);
        const nm = CONN_PORT_NAMES[p] || '호스트 서비스';
        nodes += `<g data-conn-node="host">
            <rect x="${nodeXL}" y="${y - NODE_H / 2}" width="${nodeW_L}" height="${NODE_H}" rx="10" class="conn-node conn-node-infra"/>
            <text x="${nodeXL + 14}" y="${y - 3}" class="conn-node-title">${esc(nm)}</text>
            <text x="${nodeXL + 14}" y="${y + 15}" class="conn-node-sub">:${esc(p)}</text>
            <text x="${nodeXL + nodeW_L - 15}" y="${y + 5}" class="conn-fwd-x" data-conn-fwd-remove="${esc(p)}"><title>이 엮기 삭제(재시작 후 적용)</title>✕</text></g>`;
      });
      // [+ 인프라] — 호스트 forward(localhost→호스트 포트) 추가. 클릭 → 포트 입력 → x-marina.forward 편집.
      const addY = rowY(1 + hostPorts.length);
      nodes += `<g class="conn-fwd-add" data-conn-fwd-add><title>내 컴퓨터의 DB/Redis 등을 컨테이너가 쓰게 — localhost:포트 → 호스트</title>
          <rect x="${nodeXL}" y="${addY - NODE_H / 2}" width="${nodeW_L}" height="${NODE_H}" rx="10" class="conn-node conn-node-add"/>
          <text x="${nodeXL + nodeW_L / 2}" y="${addY + 5}" text-anchor="middle" class="conn-add-label">＋ 인프라 추가</text></g>`;

      // ── 우: 📦 서비스 노드 — 접근 경로 3개를 분리해 보여준다(예전엔 실행중=호스트포트/정지=내부포트를 한 자리에 섞어 혼동).
      //   ① 내부  :8081        — 컨테이너끼리(고정, forward 맵 키)
      //   ② 호스트 127.0.0.1:N — 나(Postman·브라우저). Docker 자동할당이라 **런마다 바뀜**. 클릭=복사
      //   ③ 도메인 <wt>[-<svc>].<proj>.localhost — 고정. 클릭=열기
      const svcY = {};
      services.forEach((svc, i) => {
        const y = svcRowY(i); svcY[svc.service] = y;
        const inner = svcFwdPort(svc.service).map(p => ':' + p).join(' ');
        const hostP = svc.running && svc.port ? String(svc.port) : '';
        const dom = gwOn && gatewayUrlFor(session, svc);
        const domLabel = dom ? dom.replace(/^https?:\/\//, '').replace(/\/$/, '') : '';
        const domShort = domLabel.length > 36 ? domLabel.slice(0, 33) + '…' : domLabel;
        const line2 = [inner ? '내부 ' + inner : '', hostP ? '호스트 :' + hostP : (svc.running ? '' : '정지')].filter(Boolean).join('  ·  ') || '포트 없음';
        nodes += `<g data-conn-node="${esc(svc.service)}" class="conn-svc-node">
            <rect x="${nodeXR}" y="${y - SVC_H / 2}" width="${nodeW_R}" height="${SVC_H}" rx="10" class="conn-node"/>
            <circle cx="${nodeXR + 16}" cy="${y - 20}" r="5" style="fill:var(${connStVar(svc)})"/>
            <text x="${nodeXR + 30}" y="${y - 16}" class="conn-node-title" data-conn-svc="${esc(svc.service)}"><title>클릭 = 로그</title>${esc(svc.service)}</text>
            <text x="${nodeXR + 14}" y="${y + 3}" class="conn-node-sub${hostP ? ' conn-copy' : ''}"${hostP ? ` data-conn-copy="127.0.0.1:${esc(hostP)}"` : ''}>${hostP ? '<title>클릭 = 127.0.0.1:' + esc(hostP) + ' 복사 · 런마다 바뀜</title>' : ''}${esc(line2)}</text>
            ${dom ? `<text x="${nodeXR + 14}" y="${y + 22}" class="conn-node-dom conn-open" data-conn-open="${esc(dom)}"><title>${esc(domLabel)} — 고정 주소(클릭=열기)</title>${esc(domShort)}</text>`
                  : `<text x="${nodeXR + 14}" y="${y + 22}" class="conn-node-hint">${esc(svc.running ? '게이트웨이 꺼짐' : '시작하면 주소 생겨요')}</text>`}
          </g>`;
      });
      // [+ 서비스 연결] — expose(타겟 URL → consumer env) 추가.
      const exAddY = svcRowY(services.length);
      nodes += `<g class="conn-fwd-add" data-conn-expose-add><title>서비스끼리 잇기 — 타겟 서비스의 주소를 다른 서비스의 env 로 주입(재시작 후 적용)</title>
          <rect x="${nodeXR}" y="${exAddY - NODE_H / 2}" width="${nodeW_R}" height="${NODE_H}" rx="10" class="conn-node conn-node-add"/>
          <text x="${nodeXR + nodeW_R / 2}" y="${exAddY + 5}" text-anchor="middle" class="conn-add-label">＋ 서비스 연결</text></g>`;

      // ── 엣지 ── in: 브라우저(좌) → 게이트웨이 서비스(우). out(A안): 도커망(우 존 좌변) → 인프라 노드(좌).
      gwList.forEach(g => {
        edges += `<path d="${curve(nodeXL + nodeW_L, brY, nodeXR, svcY[g.svc.service])}" class="conn-edge conn-edge-in" data-conn-edge="${esc(g.svc.service)}"><title>${esc(g.label)}</title></path>`;
      });
      const dockerAnchorY = ZTOP + zoneH / 2;
      hostPorts.forEach((p, i) => {
        edges += `<path d="${curve(RZ_X, dockerAnchorY, nodeXL + nodeW_L, rowY(1 + i))}" class="conn-edge conn-edge-out" data-conn-edge="host"/>`;
      });

      // ── expose: 타겟 서비스 URL → consumer 의 env. 서비스끼리라 우측 레인에 루프로 그린다(진짜 per-pair 관계). ──
      const laneX = nodeXR + nodeW_R;
      const loopRight = (y0, y1) => { const b = laneX + 30; return `M${laneX},${y0} C${b},${y0} ${b},${y1} ${laneX},${y1}`; };
      exposeList.forEach(x => {
        if (svcY[x.target] == null || svcY[x.consumer] == null) return;   // 이 워크트리에 없는 서비스 참조 — 엣지 생략
        const ty = svcY[x.target], cy = svcY[x.consumer];
        edges += `<path d="${loopRight(ty, cy)}" class="conn-edge conn-edge-expose" data-conn-edge="${esc(x.consumer)}" data-conn-edge2="${esc(x.target)}"><title>${esc(x.var)} = ${esc(x.target)} 주소 → ${esc(x.consumer)} (재시작 후 적용)</title></path>`;
        // 루프 최외곽에 ✕ (hover 로 노출) — 이 배선 삭제
        edges += `<g class="conn-ex-x-g"><text x="${laneX + 22}" y="${(ty + cy) / 2 + 4}" class="conn-fwd-x conn-ex-x" data-conn-expose-remove="${esc(x.consumer)}|${esc(x.var)}"><title>이 연결 삭제(${esc(x.var)}) — 재시작 후 적용</title>✕</text></g>`;
      });

      const warn = !wm.ok ? `<div class="conn-warn">⚠ 엮기 정보를 불러오지 못했어요 — ${esc(wm.error || '')}</div>` : '';
      // forward(엮기)·expose(서비스 연결) 둘 다 컨테이너 기동 때 세팅 → 공통 재시작 안내.
      const restartNote = connForwardDirty ? `<div class="conn-restart-note">연결 설정을 바꿨어요 — <b>서비스를 재시작해야 실제 적용</b>돼요(다이어그램은 미리 반영). <button type="button" data-conn-restart>전체 재시작</button></div>` : '';
      // 반응형 — 패널이 좁으면 비율 유지 축소(가로 스크롤 금지), 넓으면 원본 크기에서 멈춤(max-width).
      body.innerHTML = `${warn}${restartNote}<div class="conn-graph-wrap"><svg viewBox="0 0 ${w} ${h}" width="100%" style="max-width:${w}px;height:auto" role="img" aria-label="연결 다이어그램 — 내 컴퓨터(브라우저·인프라)와 Docker 격리 서비스">${edges}${nodes}</svg></div>`;

      body.querySelectorAll('[data-conn-svc]').forEach(el => { el.onclick = (e) => { e.stopPropagation(); selectLog(root, el.dataset.connSvc); }; });
      body.querySelectorAll('[data-conn-open]').forEach(el => { el.onclick = (e) => { e.preventDefault(); e.stopPropagation(); window.open(el.dataset.connOpen, '_blank', 'noopener'); }; });
      // 호스트 포트 클릭 = 복사(런마다 바뀌니 그때그때 집어가게)
      body.querySelectorAll('[data-conn-copy]').forEach(el => {
        el.onclick = async (e) => {
          e.stopPropagation();
          const v = el.dataset.connCopy;
          try { await navigator.clipboard.writeText(v); showToastSafe(v + ' 복사됨'); }
          catch { showToastSafe('복사 실패 — ' + v); }
        };
      });
      // 엮기 편집 — 인프라 ✕ 삭제 · ＋ 인프라 추가 · 재시작
      body.querySelectorAll('[data-conn-fwd-remove]').forEach(el => { el.onclick = (e) => { e.stopPropagation(); connForwardEdit(root, el.dataset.connFwdRemove, 'remove'); }; });
      const addBtn = body.querySelector('[data-conn-fwd-add]');
      if (addBtn) addBtn.onclick = () => {
        const port = (prompt('컨테이너가 내 컴퓨터로 쓸 포트 (예: 5432=postgres, 6379=redis)') || '').trim();
        if (/^\d+$/.test(port)) connForwardEdit(root, port, 'set');
        else if (port) showToastSafe('숫자 포트만 넣어주세요');
      };
      // expose 편집 — ✕ 삭제 · ＋ 서비스 연결
      body.querySelectorAll('[data-conn-expose-remove]').forEach(el => {
        el.onclick = (e) => { e.stopPropagation(); const [c, v] = el.dataset.connExposeRemove.split('|'); connExposeEdit(root, { consumer: c, var: v, op: 'remove' }); };
      });
      const exAdd = body.querySelector('[data-conn-expose-add]');
      if (exAdd) exAdd.onclick = () => {
        const names = services.map(s => s.service);
        const target = (prompt(`주소를 넘겨줄 서비스 (${names.join(', ')})`) || '').trim();
        if (!target) return;
        if (!names.includes(target)) return showToastSafe(`'${target}' 서비스가 없어요`);
        const consumer = (prompt(`그 주소를 받을 서비스 (${names.filter(n => n !== target).join(', ')})`) || '').trim();
        if (!consumer) return;
        if (!names.includes(consumer)) return showToastSafe(`'${consumer}' 서비스가 없어요`);
        if (consumer === target) return showToastSafe('같은 서비스끼리는 안 돼요');
        const v = (prompt(`${consumer} 에 넣을 env 변수명 (예: NEXT_PUBLIC_API_URL)`) || '').trim();
        if (!v) return;
        connExposeEdit(root, { consumer, var: v, target, mode: 'gateway', op: 'set' });
      };
      const rb = body.querySelector('[data-conn-restart]');
      if (rb) rb.onclick = async () => { rb.disabled = true; rb.textContent = '재시작 중…'; try { await api('/api/start-all', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root }) }); connForwardDirty = false; showToastSafe('재시작 요청됨 — 기동되면 반영돼요'); } catch (e) { showToastSafe('재시작 실패: ' + e.message); } loadConnInto(document.getElementById('tab-conn'), connSelectedRoot); };
      // 서비스 hover → 그 서비스의 게이트웨이 엣지 강조
      const svg = body.querySelector('svg');
      body.querySelectorAll('[data-conn-node]').forEach(node => {
        const key = node.dataset.connNode;
        node.addEventListener('mouseenter', () => {
          svg.classList.add('conn-hovering');
          const k = CSS.escape(key);   // expose 엣지는 양끝(consumer=edge, target=edge2) 어느 쪽에 hover 해도 강조
          svg.querySelectorAll(`[data-conn-edge="${k}"], [data-conn-edge2="${k}"]`).forEach(e => e.classList.add('conn-hi'));
        });
        node.addEventListener('mouseleave', () => { svg.classList.remove('conn-hovering'); svg.querySelectorAll('.conn-hi').forEach(e => e.classList.remove('conn-hi')); });
      });
    }

    function showToastSafe(msg) { if (typeof showToast === 'function') showToast(msg); else console.log('[conn]', msg); }
    // 엮기(x-marina.forward 호스트 항목) 편집 → 백엔드 → 다이어그램 즉시 갱신(선언 반영) + 재시작 배너.
    async function connForwardEdit(root, port, op) {
      try {
        await api('/api/forward-set', { method: 'POST', headers: { 'content-type': 'application/json' },   // POST 는 root 를 body 에서 읽음(쿼리 붙이면 path 매칭 깨짐)
          body: JSON.stringify({ root, port, op, target: 'host' }) });
      } catch (e) { showToastSafe('엮기 편집 실패: ' + e.message); return; }
      connForwardDirty = true;
      loadConnInto(document.getElementById('tab-conn'), connSelectedRoot);
    }
    // expose(서비스↔서비스 URL env 주입) 편집 → 백엔드 → 다이어그램 갱신 + 재시작 배너(env 는 기동 때 주입).
    async function connExposeEdit(root, payload) {
      try {
        await api('/api/expose-set', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, ...payload }) });
      } catch (e) { showToastSafe('연결 편집 실패: ' + e.message); return; }
      connForwardDirty = true;
      loadConnInto(document.getElementById('tab-conn'), connSelectedRoot);
    }
