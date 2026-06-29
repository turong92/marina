    function renderLinksRows(session) {   // 🔗 링크(symlink) — 버튼, 누르면 모달
      return `<button data-links-open class="links-open-btn" title="host/worktree 편의 symlink — 기본 &lt; 프로젝트 공유 &lt; service.links &lt; 워크트리 override.">🔗 <span class="summary-sub">링크 (symlink)</span></button>`;
    }
    function openLinksModal(session) {   // 🔗 링크 모달 — 해당 워크트리에 실제 있는 것만
      const ex = document.getElementById('linksModalBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'linksModalBack'; back.className = 'modal-backdrop'; back.style.zIndex = '200';
      back.innerHTML = `<div class="links-modal">
        <div class="links-modal-head"><strong>🔗 링크 (host/worktree symlink) — ${escapeHtml(session.alias || session.id)}</strong><button class="links-modal-x" title="닫기">✕</button></div>
        <div class="config-label" style="margin-bottom:8px">main checkout 것을 이 worktree 로 심링크해 재설치·재빌드를 줄입니다. 우선순위: 기본 &lt; 프로젝트 공유 &lt; service.links &lt; 워크트리 override. 토글=이 워크트리만 끄기 · 탐색기 추가=프로젝트 공유.</div>
        <div data-links-body class="links-body">불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('.links-modal-x').onclick = close;
      // 바깥 클릭으로는 안 닫음 — ✕ 로만 (실수 방지)
      loadLinks(session, back.querySelector('[data-links-body]'));
    }
    function linkRow(l) {   // 워크트리 레벨(서비스 무관) — 토글은 service="" override
      const r = l.rule || {};
      const ruleDisp = 'glob ' + (r.glob || '') + (r.kind ? ' · ' + r.kind : '');
      const badge = l.source === 'project' ? '<span class="lk-badge lk-cus">프로젝트 공유</span>'
                  : l.source === 'override' ? ('<span class="lk-badge lk-ovr">' + (l.disabled ? '워크트리 꺼짐' : '워크트리 override') + '</span>')
                  : l.source === 'service' ? '<span class="lk-badge lk-def">service.links</span>'
                  : '<span class="lk-badge lk-def">기본</span>';
      const removable = l.base === 'project';
      return `<div class="lk-row${l.disabled ? ' off' : ''}" data-lk-name="${escapeHtml(l.name)}">
        <input type="checkbox" data-lk-toggle ${l.disabled ? '' : 'checked'} title="이 워크트리에서 켜기/끄기" />
        <span class="lk-name">${escapeHtml(l.name)}</span>${badge}
        <span class="lk-rule">${escapeHtml(ruleDisp)}</span>
        ${removable ? '<button class="lk-rm" data-lk-rm title="공유 링크 삭제(모든 워크트리)">🗑</button>' : ''}
      </div>`;
    }
    async function loadLinks(session, body) {
      body.innerHTML = '<span class="config-label">불러오는 중…</span>';
      const services = session.services || [];
      if (!services.length) { body.innerHTML = '<span class="config-label">서비스 없음</span>'; return; }
      const bySub = {};   // 서브레포로 묶음 — 같은 서브레포 서비스 여러 개여도 한 번만(중복 제거)
      for (const svc of services) { const s = svc.subrepo || '.'; (bySub[s] = bySub[s] || []).push(svc); }
      let html = '';
      for (const sub of Object.keys(bySub)) {
        const rep = bySub[sub][0];
        let links = [];
        try { const res = await api(`/api/links?root=${enc(session.root)}&service=${enc(rep.service)}${sub !== '.' ? '&subrepo=' + enc(sub) : ''}`); links = res.links || []; } catch (e) {}
        const shown = links.filter(l => l.present !== false || l.source !== 'default');   // 해당 서브레포에 실제 있는 것만 + 형이 손댄 것
        html += `<div class="lk-svc"><div class="lk-svc-head"><span>📁 ${escapeHtml(sub === '.' ? '워크트리' : sub)}</span><button class="lk-add" data-lk-add="${escapeHtml(sub)}">+ 탐색기로 추가</button></div>`;
        html += shown.length ? shown.map(l => linkRow(l)).join('') : '<span class="config-label">해당 링크 없음</span>';
        html += '</div>';
      }
      body.innerHTML = html;
      wireLinks(session, body);
    }
    async function linkSet(session, payload) {
      return api('/api/link-set', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({root: session.root, ...payload})});
    }
    function wireLinks(session, body) {
      body.querySelectorAll('[data-lk-toggle]').forEach(cb => {
        cb.onchange = async () => {
          const row = cb.closest('.lk-row');
          try {
            await linkSet(session, {service: '', name: row.dataset.lkName, scope: 'override', op: cb.checked ? 'clear' : 'disable'});   // 워크트리 레벨
            row.classList.toggle('off', !cb.checked);
          } catch (e) { alert('실패: ' + (e.message || e)); cb.checked = !cb.checked; }
        };
      });
      body.querySelectorAll('[data-lk-rm]').forEach(btn => {
        btn.onclick = async () => {
          const row = btn.closest('.lk-row');
          if (!confirm(`공유 링크 '${row.dataset.lkName}' 삭제 — 이 프로젝트의 모든 워크트리에서 사라집니다. 계속?`)) return;
          try { await linkSet(session, {service: '', name: row.dataset.lkName, scope: 'base', op: 'clear'}); loadLinks(session, body); }
          catch (e) { alert('실패: ' + (e.message || e)); }
        };
      });
      body.querySelectorAll('[data-lk-add]').forEach(btn => {
        btn.onclick = () => linksAddBrowse(session, btn.dataset.lkAdd, body);
      });
    }
    async function linksAddBrowse(session, sub, body) {   // main 트리 탐색 → 폴더 골라 공유 base 링크로 등록(서브레포 스코프)
      const back = document.createElement('div');
      back.className = 'modal-backdrop'; back.style.zIndex = '300';
      back.innerHTML = `<div class="lk-browse-modal">
        <div class="lk-browse-head"><b>🔗 링크할 폴더 ${sub && sub !== '.' ? '(' + escapeHtml(sub) + ')' : ''}</b><button class="lk-browse-x" title="닫기">✕</button></div>
        <div class="lk-browse-bar"><button class="lk-browse-up">⬆ 위로</button><span class="lk-browse-path"></span></div>
        <div class="lk-browse-list"></div>
        <div class="lk-browse-foot"><span class="config-label">선택 <b class="lk-browse-sel">—</b></span>
          <input class="lk-browse-name" placeholder="이름" /><button class="lk-browse-go primary" disabled>등록(공유)</button></div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('.lk-browse-x').onclick = close;
      // 바깥 클릭으로는 안 닫음 — ✕ 로만 (실수 방지)
      const pathEl = back.querySelector('.lk-browse-path'), listEl = back.querySelector('.lk-browse-list'),
            selEl = back.querySelector('.lk-browse-sel'), nameEl = back.querySelector('.lk-browse-name'),
            goEl = back.querySelector('.lk-browse-go'), upEl = back.querySelector('.lk-browse-up');
      let pick = '';
      async function browse(p) {
        try {
          const d = await api(`/api/browse?path=${enc(p)}`);
          pathEl.textContent = d.path;
          upEl.onclick = d.parent ? () => browse(d.parent) : null;
          upEl.disabled = !d.parent;
          renderBrowseEntries(listEl, d, {
            onEnter: browse,
            onPick: (name) => { pick = name; selEl.textContent = pick + ' (glob · dir)'; nameEl.value = pick; goEl.disabled = false; },
            pickLabel: '이거 링크', emptyText: '하위 폴더 없음',
          });
        } catch (e) { listEl.innerHTML = '<span class="config-label">' + escapeHtml(e.message || e) + '</span>'; }
      }
      goEl.onclick = async () => {
        const name = (nameEl.value || pick).trim();
        if (!name || !pick) return;
        goEl.disabled = true; goEl.textContent = '등록 중…';
        try { await linkSet(session, {service: '', name, scope: 'base', op: 'set', rule: {glob: pick, kind: 'dir', ...(sub && sub !== '.' ? {subrepo: sub} : {})}}); close(); loadLinks(session, body); }
        catch (e) { alert('실패: ' + (e.message || e)); goEl.disabled = false; goEl.textContent = '등록(공유)'; }
      };
      browse(session.root);
    }

    async function load({force = false, passive = false} = {}) {
      loadGatewayState();   // 1회 lazy(env 고정) — 카드 게이트웨이 URL 표시용
      const data = await api('/api/sessions');
      renderMemory(data.memory, data.sessions);
      const nextSessions = data.sessions;
      const nextSignature = buildSessionSignature(nextSessions);
      const sessionListChanged = nextSignature !== sessionSignature;
      sessions = nextSessions;
      sessionSignature = nextSignature;
      if (passive && !sessionListChanged) {
        updateServiceStates();
        return;
      }
      render();
      if (!selected) {
        const firstSession = sessions[0];
        const firstWeb = firstSession?.services.find(item => item.service === 'web') ?? firstSession?.services[0];
        if (firstSession && firstWeb) selectLog(firstSession.root, firstWeb.service, 'current', 'service');
      }
    }

    let updateBusy = false;
    async function loadUpdateStatus() {
      let s;
      try { s = await api('/api/update-status'); } catch { return; }
      renderUpdateBanner(s);
    }

    function renderUpdateBanner(s) {
      const el = document.getElementById('updateBanner');
      if (!s || s.state === 'current' || s.state === 'unknown') { el.hidden = true; el.innerHTML = ''; return; }
      el.hidden = false;
      el.classList.toggle('stale', s.state === 'stale');
      if (s.state === 'stale') {
        el.innerHTML = `<span class="ub-msg">업데이트 설치됨 — 재시작하면 적용</span>
          <span class="ub-sha">${escapeHtml(s.serving || '?')} → ${escapeHtml(s.installed || '?')}</span>
          <span class="ub-actions"><button data-restart class="primary">재시작</button></span>`;
      } else { // new — 하네스별 뒤처짐 칩 (정보) + 단일 [지금 받기] 버튼
        const hs = s.harnessStatus || {};
        const chips = [];
        for (const h of (s.harnesses || [])) {
          const st = hs[h];
          if (!st) continue;
          const cur = !st.behind;
          chips.push(`<span class="ub-hchip ${cur ? 'cur' : 'old'}">${escapeHtml(h)} <span class="sha">${escapeHtml(st.installed || '?')}</span> ${cur ? '최신' : '뒤처짐'}</span>`);
        }
        const anyBehind = (s.harnesses || []).some(h => hs[h]?.behind);
        const updateBtn = anyBehind ? '<button data-update-now class="primary">지금 받기</button>' : '';
        el.innerHTML = `<span class="ub-msg">새 버전 ${escapeHtml(s.origin || '?')}</span>
          <span class="ub-actions">${chips.join('')}${updateBtn}</span>`;
      }
      const restartBtn = el.querySelector('[data-restart]');
      if (restartBtn) restartBtn.onclick = () => doRestartDashboard(restartBtn);
      const updateNowBtn = el.querySelector('[data-update-now]');
      if (updateNowBtn) updateNowBtn.onclick = () => doUpdateNow(updateNowBtn);
    }

    async function doRestartDashboard(btn) {
      if (updateBusy) return;
      if (!confirm('대시보드를 재시작해 새 코드로 띄울까요?\n(dev 서버는 유지 · 브라우저 자동 새로고침 · 수 초)')) return;
      updateBusy = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      // 서버만 재시작하면 브라우저는 옛 INDEX_HTML(HTML/JS/CSS) 그대로라 UI 변경이 안 보임 →
      // 데몬이 죽었다 다시 살아나는 걸 감지하면 페이지를 새로고침해 새 코드 전체 반영
      let down = false;
      for (let i = 0; i < 20; i++) {                 // 최대 ~8초
        await new Promise(r => setTimeout(r, 400));
        try {
          const ok = (await fetch('/api/update-status', {cache: 'no-store'})).ok;
          if (!ok) { down = true; continue; }        // 데몬 내려감 감지
          if (down) { location.reload(); return; }   // 죽었다 다시 살아남 → 새로고침
        } catch { down = true; }
      }
      location.reload();                             // fallback — transition 못 봐도 새로고침
    }

    async function doUpdateNow(btn) {
      if (updateBusy) return;
      if (!confirm('새 버전을 받아 대시보드만 재시작합니다.\n실행 중인 dev 서버(be/web 등)는 그대로 유지됩니다 · 약 1초.\n진행할까요?')) return;
      updateBusy = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      const errs = [];
      // 뒤처진 하네스만 업데이트
      let s;
      try { s = await api('/api/update-status'); } catch { s = null; }
      const hs = s?.harnessStatus || {};
      if (hs.claude?.behind) {
        try {
          const r = await api('/api/update-claude', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
          if (r?.error) errs.push('claude: ' + r.error);
        } catch (e) { errs.push('claude: ' + e); }
      }
      if (hs.codex?.behind) {
        try {
          const r = await api('/api/update-codex', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
          if (r?.error) errs.push('codex: ' + r.error);
        } catch (e) { errs.push('codex: ' + e); }
      }
      if (errs.length) {
        alert('업데이트 실패:\n' + errs.join('\n'));
        updateBusy = false; btn.disabled = false; btn.innerHTML = '지금 받기';
        return;
      }
      // 업데이트 성공 → 재시작 (confirm 이미 했으므로 바로 진행)
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      setTimeout(() => { updateBusy = false; loadUpdateStatus().catch(() => {}); }, 3000);
    }

    const themeSelect = document.getElementById('themeSelect');
    const themeMedia = window.matchMedia('(prefers-color-scheme: dark)');
    function applyTheme() {
      const pref = localStorage.getItem('devSessionTheme') || 'system';
      themeSelect.value = pref;
      const dark = pref === 'dark' || (pref === 'system' && themeMedia.matches);
      document.documentElement.classList.toggle('dark', dark);
    }
    themeSelect.onchange = () => {
      localStorage.setItem('devSessionTheme', themeSelect.value);
      applyTheme();
    };
    themeMedia.addEventListener('change', applyTheme);
    applyTheme();

    document.getElementById('collapseAll').onclick = () => {
      if (expandedRoots.size) expandedRoots.clear();
      else for (const session of sessions) expandedRoots.add(session.root);
      render();
    };
    // 레일 띠 전체가 클릭 영역 (버튼은 pointer-events 없음 — 이중 토글 방지)
    document.querySelector('.rail').onclick = () => {
      const collapsed = document.querySelector('main').classList.toggle('aside-collapsed');
      document.getElementById('asideToggle').textContent = collapsed ? '▶' : '◀';
    };
    document.getElementById('logFilter').oninput = (event) => {
      logFilterText = event.target.value.trim().toLowerCase();
      applyLogFilter();
      scheduleMatchScan();  // 로드된 창은 즉시 거르고, 파일 전체 매치는 디바운스 스캔
    };
    document.getElementById('logErrOnly').onclick = () => {
      logErrorsOnly = !logErrorsOnly;
      document.getElementById('logErrOnly').classList.toggle('active', logErrorsOnly);
      applyLogFilter();
      fetchMatches().catch(console.error);
    };
    document.getElementById('logClear').onclick = () => resetLogView();
    // 무한 스크롤 — 상단 근접 시 과거 로드, (tail 분리 상태에서) 하단 근접 시 이후 로드
    let lastLogScrollTop = 0;
    document.getElementById('log').addEventListener('scroll', () => {
      if (!selected) return;
      const logEl = document.getElementById('log');
      // 방향 가드 — 아래로 내리는 중에 위 청크가 로드되는 오발 방지
      const goingUp = logEl.scrollTop < lastLogScrollTop;
      lastLogScrollTop = logEl.scrollTop;
      if (goingUp && logEl.scrollTop < 400) loadOlder();
      if (!goingUp && !logWindow.live && logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 400) loadNewer();
    }, {passive: true});
    // 게이지 클릭 — 그 위치로 시크, 근처(±2%)에 매치 틱이 있으면 거기로 스냅
    document.getElementById('gaugeTrack').onclick = (event) => {
      if (!selected) return;
      const rect = event.currentTarget.getBoundingClientRect();
      const ratio = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
      const size = Math.max(logFileSize, logWindow.bottom, 1);
      let target = Math.round(ratio * size);
      let best = null;
      for (const offset of logMatches.offsets) {
        if (best == null || Math.abs(offset - target) < Math.abs(best - target)) best = offset;
      }
      if (matchView) {
        // 매치 뷰 — 게이지 클릭은 목록 안에서 그 위치의 매치로 스크롤 (필터 유지, 모드 이탈 없음)
        const entry = best != null ? logEntries.find(e => e.matchOffset === best) : null;
        if (entry) {
          followLog = false;
          document.getElementById('followLog').classList.remove('active');
          entry.el.scrollIntoView({block: 'center'});
          lastLogScrollTop = document.getElementById('log').scrollTop;
          entry.el.classList.add('jump-hit');
          setTimeout(() => entry.el.classList.remove('jump-hit'), 1500);
        }
        return;
      }
      if (best != null && Math.abs(best - target) / size < 0.02) target = best;
      jumpToOffset(target).catch(console.error);
    };
    document.getElementById('logDownload').onclick = () => {
      if (!selected) return;
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      window.open(`/api/logs/download?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}`, '_blank');
    };

    document.getElementById('refresh').onclick = () => {
      load({force: true}).catch(alert);
      loadWorktrees(true).catch(console.error); // du·ahead 강제 재계산 포함
    };
    document.getElementById('runSelect').onchange = (event) => {
      if (!selected) return;
      selectLog(selected.root, selected.service, event.target.value, selected.mode);
    };
    document.getElementById('logModeTabs').onclick = (event) => {
      const mode = event.target?.dataset?.logMode;
      if (!mode || !selected) return;
      selectLog(selected.root, selected.service, 'current', mode);
    };
    document.getElementById('openWeb').onclick = () => {
      if (!selected) return;
      const {session} = serviceMeta(selected.root, selected.service);
      const web = session?.services.find(item => item.service === 'web');
      if (web?.port) window.open(`http://localhost:${web.port}/`, '_blank');
    };
    document.getElementById('followLog').onclick = () => {
      followLog = !followLog;
      document.getElementById('followLog').classList.toggle('active', followLog);
      if (followLog) {
        if (selected && !logWindow.live) {
          // 과거 탐색으로 tail 이 분리된 상태 — 최신부터 다시 연다
          selectLog(selected.root, selected.service, selected.run, selected.mode);
          return;
        }
        const log = document.getElementById('log');
        log.scrollTop = log.scrollHeight;
      }
    };
    document.getElementById('log').addEventListener('wheel', (event) => {
      // scrollTop 0 에선 위로 휠을 돌려도 scroll 이벤트가 없다 — 휠 방향으로 직접 과거 로드
      if (event.deltaY < 0 && document.getElementById('log').scrollTop < 400) loadOlder();
      if (!followLog) return;
      followLog = false;
      document.getElementById('followLog').classList.remove('active');
    }, {passive: true});

    // 즉시 툴팁 — 네이티브 title 의 ~1초 지연 제거. mouseover 위임이 title 을 data-tip 으로 흡수해
    // 동적 생성 노드(render 마다 새 카드)도 자동 적용. 80ms 만 기다려 스쳐 갈 때 번쩍임 방지.
    const tipEl = document.createElement('div');
    tipEl.id = 'tip';
    document.body.appendChild(tipEl);
    let tipTimer = 0;
    function hideTip() {
      clearTimeout(tipTimer);
      tipEl.classList.remove('on');
    }
    document.addEventListener('mouseover', (event) => {
      const target = event.target.closest?.('[title], [data-tip]');
      if (!target) return;
      if (target.title) {
        target.dataset.tip = target.title;
        target.removeAttribute('title');
      }
      const text = target.dataset.tip;
      if (!text) return;
      clearTimeout(tipTimer);
      tipTimer = setTimeout(() => {
        tipEl.textContent = text;
        const rect = target.getBoundingClientRect();
        tipEl.style.top = `${rect.bottom + 8}px`;
        tipEl.style.left = `${rect.left + rect.width / 2}px`;
        tipEl.classList.add('on');
        requestAnimationFrame(() => {
          const tipRect = tipEl.getBoundingClientRect();
          let shift = 0;
          if (tipRect.left < 4) shift = 4 - tipRect.left;
          else if (tipRect.right > innerWidth - 4) shift = (innerWidth - 4) - tipRect.right;
          if (shift) tipEl.style.left = `${rect.left + rect.width / 2 + shift}px`;
          if (tipRect.bottom > innerHeight - 4) tipEl.style.top = `${Math.max(4, rect.top - 8 - tipRect.height)}px`;
        });
      }, 80);
    });
    document.addEventListener('mouseout', (event) => {
      if (event.target.closest?.('[data-tip]')) hideTip();
    });
    document.addEventListener('scroll', hideTip, {capture: true, passive: true});
    document.addEventListener('click', hideTip, true);

    let pollTimer = null;
    let pollTick = 0;
    function startPolling() {
      if (pollTimer) return;
      pollTimer = setInterval(() => {
        pollTick += 1;
        load({passive: true}).catch(console.error);
        if (pollTick % 2 === 0) loadUpdateStatus().catch(console.error);
        // 60초마다 — 서버 10분 캐시를 타서 비용 ~0, 배지(삭제 권장)·디스크 표시 신선도 유지
        if (pollTick % 12 === 0) loadWorktrees().catch(console.error);
      }, 5000);
    }
    function stopPolling() {
      clearInterval(pollTimer);
      pollTimer = null;
    }
