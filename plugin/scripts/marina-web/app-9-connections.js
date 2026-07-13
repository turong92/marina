    // app-9-connections.js — 워크스페이스 '연결' 탭(콘솔 스펙 P3): 게이트웨이 in + 엮기 out 흐름도(SVG, 깃 그래프와 같은 관례).
    // 전역 공유(classic script): api/enc/escapeHtml(app-3), sessions(app-1), gatewayState/gatewayUrlFor/loadGatewayState(app-3),
    // STATE_META(app-5), selectLog(app-4), setWsTab/WS_VIEWS(app-6).
    const CONN_ROW_H = 74, CONN_PAD_Y = 16;
    const CONN_LEFT_X = 16, CONN_LEFT_W = 132;
    const CONN_MID_X = 250, CONN_MID_W = 180;
    const CONN_RIGHT_X = 560, CONN_RIGHT_W = 160;
    // 상태 dot 클래스(STATE_META[...].dot) → --st-* 토큰. 카드와 같은 상태 언어(콘솔 스펙 D5).
    const CONN_DOT_VAR = { run: '--st-run', stop: '--st-stop', boot: '--st-boot', bad: '--st-err', ext: '--st-ext' };

    function connStVar(svc) {
      const st = svc.state || (svc.running ? 'running' : 'stopped');
      const dot = (STATE_META[st] || STATE_META.stopped).dot;
      return CONN_DOT_VAR[dot] || '--st-stop';
    }

    // 워크스페이스 '연결' 탭 진입 — 선택 워크트리 컨텍스트로 렌더. 모달 없이 pane 에 직접(D2 관례와 동일).
    function renderConnPanel(container, root) {
      if (!root) root = typeof gitMainRoot === 'function' ? gitMainRoot() : null;   // 선택 없음 → 프로젝트 main 폴백(빈 화면 금지)
      if (!root) { container.innerHTML = '<div class="git-err" style="padding:14px">프로젝트가 아직 없어요 — 먼저 프로젝트를 등록하세요</div>'; return; }
      container.innerHTML = `<div class="git-head git-panel-head conn-head">
          <span class="conn-ctx" data-conn-ctx></span>
          <span class="git-legend">● 실행 · ○ 정지 · → 게이트웨이 진입(in) · ⇢ 엮기(out) — 라벨은 포트</span>
          <button data-conn-refresh title="새로고침 — 엮기·게이트웨이 상태 다시 조회">↻</button></div>
        <div class="git-body conn-panel" data-conn-body>불러오는 중…</div>`;
      container.querySelector('[data-conn-refresh]').onclick = () => loadConnInto(container, root);
      loadConnInto(container, root);
    }

    async function loadConnInto(container, root) {
      const body = container.querySelector('[data-conn-body]'); if (!body) return;
      await loadGatewayState();   // 1회 lazy(env 고정) — app-3
      const session = (sessions || []).find(s => s.root === root);
      const ctxEl = container.querySelector('[data-conn-ctx]');
      if (ctxEl) ctxEl.textContent = session ? (session.alias || session.id || shortPath(root)) : shortPath(root);
      if (!session || !(session.services || []).length) {
        body.innerHTML = '<div class="git-err">등록된 compose 서비스가 없어요</div>';
        return;
      }
      let wm = { ok: false };
      try { wm = await api(`/api/weave-map?root=${enc(root)}`); }
      catch (e) { wm = { ok: false, error: e.message }; }
      renderConnFlow(body, root, session, wm);
    }
    // WS_VIEWS 는 app-6 에서 정의(로드 순서상 먼저) — 연결 탭 활성화 시 선택 워크트리 컨텍스트로 렌더
    WS_VIEWS.conn = { activate(pane, ctx) { renderConnPanel(pane, ctx && ctx.root); } };

    function connInternalPorts(forward, svcName) {
      return Object.keys(forward || {}).filter(p => forward[p] === svcName).sort((a, b) => Number(a) - Number(b));
    }
    // out 라벨 텍스트 — 포트 2개까지는 그대로 나열, 3개↑는 "첫포트 외 N" 축약(전체 목록은 title 로 hover)
    function connPortLabel(ports) {
      const sorted = ports.slice().sort((a, b) => Number(a) - Number(b));
      if (sorted.length <= 2) return { text: sorted.join(' · '), title: '' };
      return { text: `${sorted[0]} 외 ${sorted.length - 1}`, title: sorted.join(' · ') };
    }
    // 같은 타겟(host 또는 서비스)으로 여러 소스가 모이는 out 라벨을 엣지 중간(겹치기 쉬움) 대신
    // 타겟 노드 좌측에 세로로 쌓아 그린다 — 소스 행 순서(y) 유지.
    function connStackLabels(labels, anchorX, anchorY) {
      if (!labels.length) return '';
      const lineH = 11;
      const top = anchorY - (labels.length - 1) * lineH / 2;
      return labels.map((l, i) => {
        const y = top + i * lineH;
        const title = l.title ? `<title>${escapeHtml(l.title)}</title>` : '';
        return `<text x="${anchorX}" y="${y + 3}" text-anchor="end" class="conn-edge-label">${escapeHtml(l.text)}${title}</text>`;
      }).join('');
    }

    function renderConnFlow(body, root, session, wm) {
      // 엮기 사이드카(<svc>-bind, marina 런타임 주입 — docker compose ps 엔 보이지만 보관 compose 정의엔 없음)는
      // 노드로 안 그린다(플러밍, 앱 서비스 아님) — wm.appServices(보관 compose 서비스명, 사이드카 제외)로 필터.
      const appServiceNames = wm.ok && Array.isArray(wm.appServices) ? new Set(wm.appServices) : null;
      const services = (session.services || []).filter(s => !appServiceNames || appServiceNames.has(s.service));
      if (!services.length) { body.innerHTML = '<div class="git-err">등록된 compose 없음</div>'; return; }
      const forward = (wm.ok && wm.forward) || {};
      const applied = (wm.ok && wm.applied) || {};
      const rows = services.length;
      const h = rows * CONN_ROW_H + CONN_PAD_Y * 2;
      const rowY = i => CONN_PAD_Y + i * CONN_ROW_H + CONN_ROW_H / 2;
      const svcRowIdx = new Map(services.map((s, i) => [s.service, i]));

      const gwOn = gatewayState.enabled;
      let svg = '';
      // 좌측 브라우저 노드 — 세로 중앙 배치
      const browserCy = h / 2;
      svg += `<rect x="${CONN_LEFT_X}" y="${browserCy - 24}" width="${CONN_LEFT_W}" height="48" rx="10"
                class="conn-node conn-node-browser"/>
               <text x="${CONN_LEFT_X + CONN_LEFT_W / 2}" y="${browserCy + 5}" text-anchor="middle" class="conn-node-title">🌐 브라우저</text>`;
      if (!gwOn) {
        svg += `<text x="${CONN_LEFT_X}" y="${browserCy + 40}" class="conn-note">⚠ 게이트웨이 꺼짐 — caddy 미가동/미설치</text>`;
      }

      // 우측 host 노드 — 엮기 out 중 host 타겟이 하나라도 있을 때만
      const hostPairs = [];   // [{svc, port}]
      for (const svc of services) for (const [p, t] of (applied[svc.service] || [])) if (t === 'host') hostPairs.push({ svc: svc.service, port: p });
      const hasHost = hostPairs.length > 0;
      const hostCy = h / 2;
      if (hasHost) {
        svg += `<rect x="${CONN_RIGHT_X}" y="${hostCy - 24}" width="${CONN_RIGHT_W}" height="48" rx="10" class="conn-node conn-node-host"/>
                 <text x="${CONN_RIGHT_X + CONN_RIGHT_W / 2}" y="${hostCy - 4}" text-anchor="middle" class="conn-node-title">💻 내 컴퓨터</text>
                 <text x="${CONN_RIGHT_X + CONN_RIGHT_W / 2}" y="${hostCy + 14}" text-anchor="middle" class="conn-node-sub">host.docker.internal</text>`;
      }

      // out 라벨 스택 — target(host 또는 서비스 행 idx)별로 모아뒀다 서비스 행 루프가 끝난 뒤 한 번에 그린다.
      const hostLabels = [];              // [{y, text, title}] — 소스 행 순서
      const svcTargetLabels = new Map();  // targetIdx → [{y, text, title}]

      // 서비스 행
      services.forEach((svc, i) => {
        const y = rowY(i);
        const stVar = connStVar(svc);
        const running = !!svc.running;
        const midX0 = CONN_MID_X, midX1 = CONN_MID_X + CONN_MID_W;
        const ports = connInternalPorts(forward, svc.service);
        svg += `<g data-conn-svc="${escapeHtml(svc.service)}" class="conn-svc-node">
            <rect x="${midX0}" y="${y - 24}" width="${CONN_MID_W}" height="48" rx="10"
                  style="stroke:var(${stVar});fill:color-mix(in srgb, var(${stVar}) 14%, transparent)"/>
            <text x="${midX0 + 12}" y="${y - 3}" class="conn-node-title">${running ? '●' : '○'} ${escapeHtml(svc.service)}</text>
            <text x="${midX0 + 12}" y="${y + 15}" class="conn-node-sub">${ports.length ? ':' + escapeHtml(ports.join(', ')) : '(포트 없음)'}</text>
          </g>`;

        // in — 브라우저 → 서비스(게이트웨이 도메인)
        const domain = gwOn && gatewayUrlFor(session, svc);
        const inDashed = !domain;
        const x0 = CONN_LEFT_X + CONN_LEFT_W, y0 = browserCy;
        const midy = (y0 + y) / 2;
        svg += `<path d="M${x0},${y0} C${x0 + 40},${y0} ${midX0 - 40},${y} ${midX0},${y}"
                  class="conn-edge conn-edge-in${inDashed ? ' dashed' : ''}" ${domain ? `data-conn-domain="${escapeHtml(domain)}"` : ''}/>`;
        if (domain) {
          const label = domain.replace(/^https?:\/\//, '').replace(/\/$/, '');
          // 워크트리+서비스+프로젝트명이 길면 라벨이 캔버스 폭 대부분을 덮어 우측 out 라벨과 겹친다 — 말줄임(전체는 title/클릭)
          const shortLabel = label.length > 42 ? label.slice(0, 39) + '…' : label;
          svg += `<text x="${(x0 + midX0) / 2}" y="${midy - 6}" text-anchor="middle" class="conn-edge-label conn-domain-label"
                    data-conn-domain="${escapeHtml(domain)}">${escapeHtml(shortLabel)}<title>${escapeHtml(label)}</title></text>`;
        }

        // out — 서비스 → host / 서비스(엮기). 포트별로 엣지를 하나씩 그리면 실서비스(포트 여러 개)에서
        // 선·라벨이 겹쳐 못 읽는다 — 같은 (서비스,타겟) 쌍은 포트 목록을 하나의 라벨로 묶어 엣지 1개로(가독성).
        const byTarget = new Map();   // target → [ports...]
        for (const [port, target] of (applied[svc.service] || [])) {
          if (!byTarget.has(target)) byTarget.set(target, []);
          byTarget.get(target).push(port);
        }
        const outDashed = !running ? ' dashed' : '';   // 정지 서비스는 회색 노드+옅은 화살표(스펙) — out 엣지도 동일 적용
        for (const [target, ports2] of byTarget) {
          const { text: portLabel, title: portTitle } = connPortLabel(ports2);
          if (target === 'host' && hasHost) {
            const ty = hostCy, tx = CONN_RIGHT_X;
            svg += `<path d="M${midX1},${y} C${midX1 + 40},${y} ${tx - 40},${ty} ${tx},${ty}" class="conn-edge conn-edge-out-host${outDashed}"/>`;
            hostLabels.push({ y, text: portLabel, title: portTitle });
          } else if (target !== 'host' && svcRowIdx.has(target)) {
            const targetIdx = svcRowIdx.get(target);
            const ty = rowY(targetIdx);
            const bulge = midX1 + 50 + (targetIdx > i ? 14 : -14);
            svg += `<path d="M${midX1},${y} C${bulge},${y} ${bulge},${ty} ${midX1},${ty}" class="conn-edge conn-edge-out-svc${outDashed}"/>`;
            if (!svcTargetLabels.has(targetIdx)) svcTargetLabels.set(targetIdx, []);
            svcTargetLabels.get(targetIdx).push({ y, text: portLabel, title: portTitle });
          } else if (target !== 'host') {
            // 대상 서비스가 이 세션 목록에 없음(드묾) — host 노드 자리 근처에 안내만
            svg += `<text x="${midX1 + 10}" y="${y + 30}" class="conn-note">→ ${escapeHtml(target)}:${escapeHtml(portLabel)}(미탐색)</text>`;
          }
        }
      });

      // out 라벨 — host/서비스 타겟 좌측에 세로 스택(소스가 여럿이어도 안 겹치게)
      if (hasHost) svg += connStackLabels(hostLabels, CONN_RIGHT_X - 8, hostCy);
      for (const [targetIdx, labels] of svcTargetLabels) svg += connStackLabels(labels, CONN_MID_X - 8, rowY(targetIdx));

      const w = CONN_RIGHT_X + CONN_RIGHT_W + 16;
      const warn = !wm.ok ? `<div class="conn-warn">⚠ 엮기 정보를 불러오지 못했어요 — ${escapeHtml(wm.error || '')}</div>` : '';
      body.innerHTML = `${warn}<div class="conn-graph-wrap"><svg viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" aria-label="연결 흐름도">${svg}</svg></div>`;
      body.querySelectorAll('[data-conn-svc]').forEach(el => {
        el.onclick = () => selectLog(root, el.dataset.connSvc);
      });
      body.querySelectorAll('[data-conn-domain]').forEach(el => {
        el.onclick = (e) => { e.stopPropagation(); window.open(el.dataset.connDomain, '_blank'); };
      });
    }
