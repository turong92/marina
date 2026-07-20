    const linksActiveSubrepo = new Map();

    function linkSubrepoLabel(sub) {
      return sub && sub !== '.' ? sub : '워크트리';
    }

    function linkSessionKey(session) {
      return session.root || session.id || '';
    }

    function linkRuleMode(rule) {
      return rule && (rule.mode === 'copy' || rule.op === 'copy') ? 'copy' : 'symlink';
    }

    function openLinksModal(session) {   // link 모달 — 해당 서브레포에 실제 있는 것만
      const ex = document.getElementById('linksModalBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'linksModalBack'; back.className = 'modal-backdrop'; back.style.zIndex = '200';
      const desc = session.source === 'main'
        ? '여긴 <b>원본(main)</b> — 이 목록이 이 머신의 새 worktree에 자동 적용되고, 그대로 <b>docker-compose.yml 공유 단위</b>입니다(목록에 있으면 적용·없으면 안 함). <b>+ 폴더 탐색</b>으로 추가, <b>✕로 빼기</b>. 카피/참조는 worktree가 받을 방식이고, main 자신엔 적용되지 않아요.'
        : 'main 의 deps/config 를 이 worktree 로 가져옵니다(목록 = 프로젝트 공유 링크, x-marina). 링크는 원본을 같이 쓰고, 카피는 현재 내용을 복제. <b>+ 폴더 탐색</b>으로 연결, <b>✕</b>로 해제.';
      back.innerHTML = `<div class="links-modal">
        <div class="links-modal-head"><strong>link — ${escapeHtml(session.alias || session.id)}</strong><button class="links-modal-x" title="닫기">✕</button></div>
        <div class="config-label" style="margin-bottom:8px">${desc}</div>
        <div data-links-body class="links-body">불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('.links-modal-x').onclick = close;
      // 바깥 클릭으로는 안 닫음 — ✕ 로만 (실수 방지)
      loadLinks(session, back.querySelector('[data-links-body]'));
    }
    function linkRow(l, sub, isMain) {   // 워크트리 레벨(서비스 무관) — 토글은 service="" override. main 은 토글 무효(원본이라 적용 skip)라 정적 표시.
      const r = l.rule || {};
      const mode = linkRuleMode(r);
      const ruleDisp = (mode === 'copy' ? 'copy' : 'link') + ' · glob ' + (r.glob || '') + (r.kind ? ' · ' + r.kind : '');
      const shownName = (r.subrepo && l.name.indexOf(r.subrepo + '/') === 0) ? l.name.slice(r.subrepo.length + 1) : l.name;
      const badge = l.baseOff ? '<span class="lk-badge lk-ovr">프로젝트 꺼짐</span>'
                  : l.source === 'project' ? '<span class="lk-badge lk-cus">프로젝트 공유</span>'
                  : l.source === 'override' ? ('<span class="lk-badge lk-ovr">' + (l.disabled ? '워크트리 꺼짐' : '워크트리 override') + '</span>')
                  : l.source === 'service' ? '<span class="lk-badge lk-def">service.links</span>'
                  : l.source === 'discovered' ? '<span class="lk-badge lk-def">발견</span>'
                  : '<span class="lk-badge lk-def">기본</span>';
      const modeBadge = l.source === 'discovered' ? '' : `<span class="lk-badge lk-mode ${mode === 'copy' ? 'copy' : 'link'}" title="${mode === 'copy' ? '카피 — main의 현재 내용을 이 worktree로 복제. 이후 서로 독립' : '참조 링크 — main 원본을 symlink로 공유. 한쪽을 고치면 양쪽 반영'}">${mode === 'copy' ? '📄 카피' : '🔗 참조'}</span>`;
      const cat = l.category ? `<span class="lk-badge lk-cat">${escapeHtml(l.category)}</span>` : '';
      const missing = l.present === false ? '<span class="lk-badge lk-missing" title="이 checkout 디스크엔 없음 — worktree에서 가져올 때 생성됨">원본 없음</span>' : '';
      const removable = l.base === 'project';
      if (l.dangling) {   // 공유 정의가 삭제됐는데 이 워크트리 "끄기" override 만 남은 잔재 — 토글 대상 아님, 제거만
        return `<div class="lk-row off dangling" data-lk-name="${escapeHtml(l.name)}">
          <span class="lk-dot" aria-hidden="true">⌀</span>
          <span class="lk-name" title="${escapeHtml(l.name)}">${escapeHtml(shownName)}</span><span class="lk-badge lk-dangling">끄기 잔재</span>
          <span class="lk-rule">공유 정의 삭제됨 — 이 끄기만 남음</span>
          <button class="lk-rm" data-lk-rm-ovr title="끄기 잔재 제거 — 이 워크트리 override 삭제">✕</button>
        </div>`;
      }
      // 발견(discovered): 소스에 있지만 아직 링크 설정 안 된 파생물(빌드출력·jar 등) — 기본 미선택(unchecked).
      //   체크는 "실제 적용된 링크"만 반영. 켜야 등록(빌드출력은 보통 워크트리별 독립이라 공유 비권장).
      // main: 기본 링크는 base 토글(프로젝트 전체 on/off). 공유 링크(project)는 ✕(빼기).
      const isDisc = l.source === 'discovered';
      // 리드 컨트롤 없음(메인·워크트리 동일): 목록에 있으면 적용. 연결 = + 폴더 탐색, 해제 = ✕. on/off 토글 없음.
      //   예외 — discovered(발견된 파생물, 아직 미등록): 켜면 x-marina 에 연결(opt-in).
      const lead = isDisc
        ? `<input type="checkbox" data-lk-disc data-glob="${escapeHtml(r.glob || l.name)}" data-kind="${escapeHtml(r.kind || 'dir')}" title="발견됨 — 아직 미연결(파생물). 켜면 이 패턴을 링크로 연결. 빌드출력·jar 는 워크트리별 독립이라 보통 안 함" />`
        : '<span class="lk-dot" aria-hidden="true"></span>';
      return `<div class="lk-row${l.present === false ? ' missing' : ''}" data-lk-name="${escapeHtml(l.name)}">
        ${lead}
        <span class="lk-name" title="${escapeHtml(l.name)}">${escapeHtml(shownName)}</span>${badge}${modeBadge}${cat}${missing}
        <span class="lk-rule">${escapeHtml(ruleDisp)}</span>
        ${removable ? '<button class="lk-rm" data-lk-rm title="이 링크 빼기 — x-marina 목록에서 제거(원본 파일은 안 지움)">✕</button>' : ''}
      </div>`;
    }
    function visibleLinks(links, session) {
      if (session && session.source === 'main')   // 원본 checkout — deps 미설치라 present=false 가 흔함. 설정된 링크는 다 보여줌(원본 없음 표시)
        return links.filter(l => l.source !== 'discovered' || l.present !== false);
      return links.filter(l => l.present !== false || l.source !== 'default');   // worktree — 해당 서브레포에 실제 있는 것만 + 형이 손댄 것
    }
    async function loadLinks(session, body, preferredSub) {
      body.innerHTML = '<span class="config-label">불러오는 중…</span>';
      const services = session.services || [];
      if (!services.length) { body.innerHTML = '<span class="config-label">서비스 없음</span>'; return; }
      const bySub = new Map();   // 서브레포로 묶음 — 같은 서브레포 서비스 여러 개여도 한 번만(중복 제거)
      for (const svc of services) {
        const s = svc.subrepo || '.';
        if (!bySub.has(s)) bySub.set(s, []);
        bySub.get(s).push(svc);
      }
      const groups = [...bySub.keys()];
      const records = new Map();
      await Promise.all(groups.map(async sub => {
        const rep = bySub.get(sub)[0];
        try {
          const res = await api(`/api/links?root=${enc(session.root)}&service=${enc(rep.service)}${sub !== '.' ? '&subrepo=' + enc(sub) : ''}`);
          const links = res.links || [];
          records.set(sub, {sub, rep, links, shown: visibleLinks(links, session), error: ''});
        } catch (e) {
          records.set(sub, {sub, rep, links: [], shown: [], error: e.message || String(e)});
        }
      }));
      const key = linkSessionKey(session);
      const saved = preferredSub || linksActiveSubrepo.get(key);
      const active = groups.includes(saved) ? saved : groups[0];
      linksActiveSubrepo.set(key, active);
      const tabs = groups.map(sub => {
        const rec = records.get(sub) || {shown: []};
        return `<button type="button" class="lk-tab${sub === active ? ' active' : ''}" data-lk-tab="${escapeHtml(sub)}" title="${escapeHtml(linkSubrepoLabel(sub))}">
          <span class="lk-tab-name">${escapeHtml(linkSubrepoLabel(sub))}</span><span class="lk-tab-count">${rec.shown.length}</span>
        </button>`;
      }).join('');
      const rec = records.get(active) || {shown: [], error: ''};
      const panelBody = rec.error
        ? `<span class="config-label">${escapeHtml(rec.error)}</span>`
        : (rec.shown.length ? rec.shown.map(l => linkRow(l, active, session.source === 'main')).join('') : '<span class="lk-empty">이 서브레포에 표시할 항목 없음</span>');
      body.innerHTML = `<div class="lk-tabs" role="tablist">${tabs}</div>
        <div class="lk-panel">
          <div class="lk-panel-head">
            <span><b>${escapeHtml(linkSubrepoLabel(active))}</b><em>${rec.shown.length}개 항목</em></span>
            <button class="lk-add" data-lk-add="${escapeHtml(active)}">+ 폴더 탐색</button>
          </div>
          <div class="lk-list">${panelBody}</div>
        </div>`;
      wireLinks(session, body);
    }
    async function linkSet(session, payload) {
      return api('/api/link-set', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({root: session.root, ...payload})});
    }
    function wireLinks(session, body) {
      body.querySelectorAll('[data-lk-tab]').forEach(btn => {
        btn.onclick = () => loadLinks(session, body, btn.dataset.lkTab);
      });
      body.querySelectorAll('[data-lk-rm]').forEach(btn => {   // ✕ 해제: x-marina 목록에서 제거(이 서브레포)
        btn.onclick = async () => {
          const row = btn.closest('.lk-row');
          const name = row.dataset.lkName;
          const sub = linksActiveSubrepo.get(linkSessionKey(session));
          btn.disabled = true;
          try {
            await linkSet(session, {service: '', name, scope: 'base', op: 'clear', subrepo: sub});
            await loadLinks(session, body, sub);
          } catch (e) { alert('실패: ' + (e.message || e)); btn.disabled = false; }
        };
      });
      body.querySelectorAll('[data-lk-disc]').forEach(cb => {   // 발견 항목: 켜면 링크로 등록(base set), 끄면 해제(base clear)
        cb.onchange = async () => {
          const row = cb.closest('.lk-row');
          const on = cb.checked;
          const sub = linksActiveSubrepo.get(linkSessionKey(session));
          cb.disabled = true;
          try {
            if (on) await linkSet(session, {service: '', name: row.dataset.lkName, scope: 'base', op: 'set', rule: {glob: cb.dataset.glob, kind: cb.dataset.kind || 'dir', subrepo: sub}});
            else await linkSet(session, {service: '', name: row.dataset.lkName, scope: 'base', op: 'clear', subrepo: sub});
            await loadLinks(session, body, sub);   // source 가 바뀌므로(discovered↔project) 재로드
          } catch (e) { alert('실패: ' + (e.message || e)); cb.checked = !on; cb.disabled = false; }
        };
      });
      body.querySelectorAll('[data-lk-rm-ovr]').forEach(btn => {   // 끄기 잔재(dangling override) 제거
        btn.onclick = async () => {
          const row = btn.closest('.lk-row');
          btn.disabled = true;
          try {
            await linkSet(session, {service: '', name: row.dataset.lkName, scope: 'override', op: 'clear'});
            await loadLinks(session, body, linksActiveSubrepo.get(linkSessionKey(session)));
          } catch (e) { alert('실패: ' + (e.message || e)); btn.disabled = false; }
        };
      });
      body.querySelectorAll('[data-lk-add]').forEach(btn => {
        btn.onclick = () => linksAddBrowse(session, btn.dataset.lkAdd, body);
      });
    }
    async function linksAddBrowse(session, sub, body) {   // main 트리 탐색 → 폴더 다중선택 → 링크(참조)/카피(복제)로 한 번에 등록(서브레포 스코프)
      const back = document.createElement('div');
      back.className = 'modal-backdrop'; back.style.zIndex = '300';
      const label = linkSubrepoLabel(sub);
      back.innerHTML = `<div class="lk-browse-modal">
        <div class="lk-browse-head"><b>폴더 선택 — ${escapeHtml(label)}</b><button class="lk-browse-x" title="닫기">✕</button></div>
        <div class="lk-browse-hint">폴더 이름을 누르면 안으로 들어가고, 오른쪽 <b>+</b> 를 누르면 선택돼. 여러 개 골라 한 번에 추가할 수 있어.</div>
        <div class="lk-browse-bar"><button class="lk-browse-up">⬆ 위로</button><span class="lk-browse-path"></span></div>
        <div class="lk-browse-list"></div>
        <div class="lk-browse-foot">
          <div class="lk-browse-moderow">
            <span class="lk-browse-modelabel">가져오는 방식</span>
            <div class="lk-browse-mode" role="group" aria-label="가져오는 방식">
              <button type="button" data-lk-mode="symlink" class="active">🔗 참조 링크</button>
              <button type="button" data-lk-mode="copy">📄 카피</button>
            </div>
            <span class="lk-browse-modehint"></span>
          </div>
          <div class="lk-browse-actionrow">
            <div class="lk-browse-picks" aria-label="선택한 폴더"></div>
            <button class="lk-browse-go primary" disabled>추가</button>
          </div>
        </div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('.lk-browse-x').onclick = close;
      // 바깥 클릭으로는 안 닫음 — ✕ 로만 (실수 방지)
      const pathEl = back.querySelector('.lk-browse-path'), listEl = back.querySelector('.lk-browse-list'),
            picksEl = back.querySelector('.lk-browse-picks'), modeHintEl = back.querySelector('.lk-browse-modehint'),
            goEl = back.querySelector('.lk-browse-go'), upEl = back.querySelector('.lk-browse-up');
      const modeBtns = [...back.querySelectorAll('[data-lk-mode]')];
      const addedPaths = new Set();              // 등록 완료(다시 못 고름)
      const picked = new Map();                  // childPath → rel(표시이름) — 체크 상태 유지(여러 폴더 옮겨다녀도)
      let browseBase = '', mode = 'symlink', lastPath = '';
      const start = sub && sub !== '.' ? session.root.replace(/\/+$/, '') + '/' + sub.replace(/^\/+|\/+$/g, '') : session.root;
      const samePath = (a, b) => String(a || '').replace(/\/+$/, '') === String(b || '').replace(/\/+$/, '');
      function syncFooter() {
        modeBtns.forEach(btn => btn.classList.toggle('active', btn.dataset.lkMode === mode));
        modeHintEl.textContent = mode === 'copy'
          ? '지금 내용을 복제 — 이후 main과 따로 갑니다.'
          : '원본을 그대로 가리킴 — 한쪽을 고치면 양쪽 다 바뀝니다.';
        const items = [...picked.entries()];
        picksEl.innerHTML = items.length
          ? items.map(([child, rel]) => `<span class="lk-pick-chip" data-pick="${escapeHtml(child)}">${escapeHtml(rel)}<button class="lk-pick-x" type="button" title="선택 해제">✕</button></span>`).join('')
          : '<span class="lk-browse-empty">선택한 폴더 없음</span>';
        picksEl.querySelectorAll('.lk-pick-chip').forEach(chip => {
          chip.querySelector('.lk-pick-x').onclick = () => { picked.delete(chip.dataset.pick); syncFooter(); renderList(); };
        });
        goEl.disabled = !items.length;
        goEl.textContent = items.length ? `${mode === 'copy' ? '카피' : '링크'} ${items.length}개 추가` : '추가';
      }
      modeBtns.forEach(btn => {
        btn.onclick = () => { mode = btn.dataset.lkMode === 'copy' ? 'copy' : 'symlink'; syncFooter(); };
      });
      function renderList(d) {
        renderBrowseEntries(listEl, d || renderList._d, {
          onEnter: browse,
          multiPick: true, pickedPaths: picked, addedPaths,
          onPick: (name, childPath) => {
            if (picked.has(childPath)) picked.delete(childPath);
            else picked.set(childPath, relPath(browseBase, childPath));
            syncFooter(); renderList();
          },
          emptyText: '하위 폴더 없음',
        });
      }
      async function browse(p) {
        try {
          const d = await api(`/api/browse?path=${enc(p)}`);
          if (!browseBase) browseBase = d.path;
          renderList._d = d; lastPath = d.path;
          pathEl.textContent = d.path;
          const atBase = samePath(d.path, browseBase);
          upEl.onclick = (!atBase && d.parent) ? () => browse(d.parent) : null;
          upEl.disabled = atBase || !d.parent;
          renderList(d);
        } catch (e) { listEl.innerHTML = '<span class="config-label">' + escapeHtml(e.message || e) + '</span>'; }
      }
      goEl.onclick = async () => {
        const items = [...picked.entries()];
        if (!items.length) return;
        const selectedMode = mode;
        goEl.disabled = true; goEl.textContent = selectedMode === 'copy' ? '카피 중…' : '링크 중…';
        const failed = [];
        for (const [child, rel] of items) {
          const name = sub && sub !== '.' ? `${sub}/${rel}` : rel;
          try {
            await linkSet(session, {service: '', name, scope: 'base', op: 'set', rule: {glob: rel, kind: 'dir', mode: selectedMode, ...(sub && sub !== '.' ? {subrepo: sub} : {})}});
            addedPaths.add(child); picked.delete(child);
          } catch (e) { failed.push(`${rel}: ${e.message || e}`); }
        }
        if (failed.length) alert('일부 실패:\n' + failed.join('\n'));
        await loadLinks(session, body, sub);
        await browse(lastPath || start);
        syncFooter();
      };
      syncFooter();
      browse(start);
    }

    async function load({force = false, passive = false} = {}) {
      await loadGatewayState();   // 기본 열기 URL을 정하기 전에 Caddy 가용성을 확정한다.
      const data = await api('/api/sessions');
      renderMemory(data.memory, data.sessions);
      const nextSessions = data.sessions;
      const nextSignature = buildSessionSignature(nextSessions);
      const sessionListChanged = nextSignature !== sessionSignature;
      sessions = nextSessions;
      sessionSignature = nextSignature;
      if (typeof notifyScan === 'function') notifyScan(sessions);   // A3 브라우저 알림 — 전이 감지는 app-6b-notify.js
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
    let updateBannerSig = '';
    async function loadUpdateStatus() {
      let s;
      try { s = await api('/api/update-status'); } catch { return; }
      renderUpdateBanner(s);
    }

    function renderUpdateBanner(s) {
      if (updateBusy) return;   // 진행 중(버튼이 busy 표시) — 폴링이 DOM 을 갈아엎지 않게
      const el = document.getElementById('updateBanner');
      const sig = JSON.stringify(s ? [s.state, s.serving, s.installed, s.origin, s.harnessStatus] : null);
      if (sig === updateBannerSig) return;   // 변화 없으면 재생성 스킵
      updateBannerSig = sig;
      if (!s || s.state === 'current' || s.state === 'unknown') { el.hidden = true; el.innerHTML = ''; return; }
      el.hidden = false;
      el.classList.toggle('stale', s.state === 'stale');
      if (s.state === 'stale') {
        el.innerHTML = `<span class="ub-dot"></span><span class="ub-msg">업데이트 설치됨</span>
          <span class="ub-note">재시작하면 적용돼요</span>
          <span class="ub-sha">${escapeHtml(s.serving || '?')} → ${escapeHtml(s.installed || '?')}</span>
          <span class="ub-actions"><button data-restart class="ub-btn">재시작</button></span>`;
      } else { // new — 하네스별 상태 칩(점=최신/뒤처짐) + 단일 [지금 받기] 버튼
        const hs = s.harnessStatus || {};
        const chips = [];
        for (const h of (s.harnesses || [])) {
          const st = hs[h];
          if (!st) continue;
          const cur = !st.behind;
          chips.push(`<span class="ub-hchip ${cur ? 'cur' : 'old'}" title="${escapeHtml(h)} ${cur ? '최신' : '뒤처짐 — 받으면 갱신돼요'}"><i></i>${escapeHtml(h)} <span class="sha">${escapeHtml(st.installed || '?')}</span></span>`);
        }
        const anyBehind = (s.harnesses || []).some(h => hs[h]?.behind);
        const updateBtn = anyBehind ? '<button data-update-now class="ub-btn">지금 받기</button>' : '';
        el.innerHTML = `<span class="ub-dot"></span><span class="ub-msg">새 버전</span>
          <span class="ub-sha">${escapeHtml(s.origin || '?')}</span>
          <span class="ub-actions">${chips.join('')}${updateBtn}</span>`;
      }
      const restartBtn = el.querySelector('[data-restart]');
      if (restartBtn) restartBtn.onclick = () => doRestartDashboard(restartBtn);
      const updateNowBtn = el.querySelector('[data-update-now]');
      if (updateNowBtn) updateNowBtn.onclick = () => doUpdateNow(updateNowBtn);
    }

    // 서버만 재시작하면 브라우저는 옛 INDEX_HTML(HTML/JS/CSS) 그대로라 UI 변경이 안 보임 →
    // 데몬이 죽었다 다시 살아나는 걸 감지하면 페이지를 새로고침해 새 코드 전체 반영
    async function watchRestartThenReload() {
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

    async function doRestartDashboard(btn) {
      if (updateBusy) return;
      if (!confirm('대시보드를 재시작해 새 코드로 띄울까요?\n(dev 서버는 유지 · 브라우저 자동 새로고침 · 수 초)')) return;
      updateBusy = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      await watchRestartThenReload();
    }

    async function doUpdateNow(btn) {
      if (updateBusy) return;
      if (!confirm('새 버전을 받아 대시보드만 재시작합니다.\n실행 중인 dev 서버(be/web 등)는 그대로 유지됩니다.\n(받기 수 초~수십 초 · 완료되면 화면 자동 새로고침)')) return;
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
        showToast('업데이트 실패 — ' + errs.join(' · '), 'err');
        updateBusy = false; btn.disabled = false; btn.innerHTML = '지금 받기';
        return;
      }
      // 업데이트 성공 → 재시작. 재시작 완료를 감지해 새로고침해야 새 프론트 코드가 실린다
      // (재시작만 하고 두면 브라우저는 옛 JS 로 새 백엔드를 치는 반쪽 상태).
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      await watchRestartThenReload();
    }

    // 설정(⚙) 팝오버 토글 — 안쪽 클릭(테마 select·알림 버튼)엔 안 닫히고, 바깥 클릭·Esc 로만 닫힘
    const settingsBtn = document.getElementById('settingsBtn');
    const settingsMenu = document.getElementById('settingsMenu');
    if (settingsBtn && settingsMenu) {
      const closeSettings = (e) => {
        if (e && (settingsMenu.contains(e.target) || settingsBtn.contains(e.target))) return;
        settingsMenu.hidden = true;
        document.removeEventListener('click', closeSettings);
        document.removeEventListener('keydown', onSettingsKey);
      };
      const onSettingsKey = (e) => { if (e.key === 'Escape') closeSettings(); };
      settingsBtn.onclick = (e) => {
        e.stopPropagation();
        settingsMenu.hidden = !settingsMenu.hidden;
        if (!settingsMenu.hidden) setTimeout(() => { document.addEventListener('click', closeSettings); document.addEventListener('keydown', onSettingsKey); }, 0);
      };
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
      persistExpandedRoots();
      render();
    };
    // 레일 = IDE 식 분할 핸들 — 드래그(4px+)로 좌측 패널 폭 조절(--aside-w, localStorage 기억),
    // 그냥 클릭은 기존 접기/펼치기 그대로 (버튼은 pointer-events 없음 — 이중 토글 방지)
    (() => {
      const rail = document.querySelector('.rail');
      const mainEl = document.querySelector('main');
      const clampW = w => Math.min(Math.max(w, 320), Math.round(innerWidth * 0.7));
      const saved = parseInt(localStorage.getItem('marinaAsideW'), 10);
      if (saved) mainEl.style.setProperty('--aside-w', clampW(saved) + 'px');
      let dragged = false;
      rail.addEventListener('pointerdown', (e) => {
        if (mainEl.classList.contains('aside-collapsed')) return;   // 접힘 상태에선 클릭 토글만
        e.preventDefault();   // 드래그 중 텍스트 선택 방지
        const downX = e.clientX;
        const startW = document.querySelector('aside').getBoundingClientRect().width;
        let w = startW;
        rail.setPointerCapture(e.pointerId);
        const move = (ev) => {
          const dx = ev.clientX - downX;
          if (!dragged && Math.abs(dx) < 4) return;   // 4px 미만은 클릭
          dragged = true;
          w = clampW(Math.round(startW + dx));
          mainEl.style.setProperty('--aside-w', w + 'px');
        };
        const up = (ev) => {
          rail.removeEventListener('pointermove', move);
          rail.removeEventListener('pointerup', up);
          rail.removeEventListener('pointercancel', up);
          if (dragged) localStorage.setItem('marinaAsideW', String(w));
          if (ev.type === 'pointercancel') dragged = false;   // click 이 안 따라오는 종료 — 스왈로 플래그 해제
        };
        rail.addEventListener('pointermove', move);
        rail.addEventListener('pointerup', up);
        rail.addEventListener('pointercancel', up);
      });
      rail.addEventListener('click', () => {
        if (dragged) { dragged = false; return; }   // 방금 드래그였음 — 접기 오발 방지
        const collapsed = mainEl.classList.toggle('aside-collapsed');
        document.getElementById('asideToggle').textContent = collapsed ? '▶' : '◀';
      });
    })();
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
    // ── 워크스페이스 뷰 탭 (콘솔 스펙 D2) — 새 뷰 = WS_VIEWS 등록 + pane div 하나. 컨텍스트는 좌측 선택 추종. ──
    const WS_VIEWS = { logs: {}, git: {}, conn: {}, term: {} };   // {activate(pane, ctx)?, deactivate()?} — diff 는 깃 탭 오버레이로 흡수(탭 철거)
    let wsActive = 'logs';
    function wsContext() { return selected ? { root: selected.root, service: selected.service } : null; }
    function setWsTab(name) {
      if (!WS_VIEWS[name] || name === wsActive) return;
      const prev = WS_VIEWS[wsActive];
      if (prev.deactivate) prev.deactivate();
      wsActive = name;
      document.querySelectorAll('[data-ws-tab]').forEach(b => b.classList.toggle('on', b.dataset.wsTab === name));
      document.querySelectorAll('.ws-pane').forEach(p => { p.hidden = p.id !== 'tab-' + name; });
      const v = WS_VIEWS[name];
      if (v.activate) v.activate(document.getElementById('tab-' + name), wsContext());
      updateWsCtx();
    }
    function updateWsCtx() {
      const el = document.getElementById('wsCtx');
      if (el) el.textContent = selected ? `${shortPath(selected.root)} · ${selected.service}` : '';
    }
    document.querySelectorAll('[data-ws-tab]').forEach(b => { if (!b.disabled) b.onclick = () => setWsTab(b.dataset.wsTab); });
    document.getElementById('openWeb').onclick = () => {
      if (!selected) return;
      const {session, service: svc} = serviceMeta(selected.root, selected.service);
      if (session && svc) openServiceInBrowser(session, svc);
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

    // 공통 툴팁 — 네이티브 title 의 ~1초 지연 제거 + 구조화. mouseover 위임이 title 을 data-tip 으로 흡수해
    // 동적 생성 노드(render 마다 새 카드)도 자동 적용. 대시보드 전체 title 이 이 하나를 거친다(재활용).
    const tipEl = document.createElement('div');
    tipEl.id = 'tip';
    tipEl.innerHTML = '<span class="tip-arrow"></span><div class="tip-inner"></div>';
    document.body.appendChild(tipEl);
    const tipInner = tipEl.querySelector('.tip-inner');
    let tipTimer = 0;
    function hideTip() {
      clearTimeout(tipTimer);
      tipEl.classList.remove('on');
    }
    // 관용 문법( '제목 — 본문 · 부가' )을 구조로: 첫 ' — ' 앞=강조 제목, 뒤=본문(‘ · ’·개행은 줄로).
    // 이모지/기호로 시작하는 짧은 라벨은 통째 제목 취급(설명 없는 아이콘 버튼).
    function renderTip(text) {
      const t = text.replace(/\s+$/, '');
      const dash = t.indexOf(' — ');
      let head = t, body = '';
      if (dash >= 0) { head = t.slice(0, dash); body = t.slice(dash + 3); }
      let html = `<div class="tip-head">${escapeHtml(head)}</div>`;
      if (body) {
        const lines = body.split(/\n|\s·\s/).map(s => s.trim()).filter(Boolean);
        html += '<div class="tip-body">' + lines.map(l => `<div class="tip-line">${escapeHtml(l)}</div>`).join('') + '</div>';
      }
      tipInner.innerHTML = html;
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
        renderTip(text);
        const rect = target.getBoundingClientRect();
        const cx = rect.left + rect.width / 2;
        tipEl.classList.remove('above');
        tipEl.style.top = `${rect.bottom + 9}px`;
        tipEl.style.left = `${cx}px`;
        tipEl.style.setProperty('--tip-arrow-x', '50%');
        tipEl.classList.add('on');
        requestAnimationFrame(() => {
          const r = tipEl.getBoundingClientRect();
          let shift = 0;
          if (r.left < 6) shift = 6 - r.left;
          else if (r.right > innerWidth - 6) shift = (innerWidth - 6) - r.right;
          if (shift) { tipEl.style.left = `${cx + shift}px`; tipEl.style.setProperty('--tip-arrow-x', `calc(50% - ${shift}px)`); }
          if (r.bottom > innerHeight - 6) {   // 아래로 넘치면 위로 뒤집고 화살표도 아래로
            tipEl.classList.add('above');
            tipEl.style.top = `${rect.top - 9 - r.height}px`;
          }
        });
      }, 90);
    });
    document.addEventListener('mouseout', (event) => {
      if (event.target.closest?.('[data-tip]')) hideTip();
    });
    document.addEventListener('scroll', hideTip, {capture: true, passive: true});
    document.addEventListener('click', hideTip, true);

    // ── AGENTS 행 클릭 뷰어 — 최신부터 열고 이전 메시지는 byte cursor 로 계속 prepend. ──
    async function openAgentTranscript(session, agent) {
      const ex = document.getElementById('agentModalBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'agentModalBack'; back.className = 'modal-backdrop'; back.style.zIndex = '250';
      const isCodex = agent.source === 'codex';
      back.innerHTML = `<div class="links-modal agent-modal">
        <div class="links-modal-head"><strong><span class="agent-src ${isCodex ? 'codex' : 'claude'}">${isCodex ? 'Codex' : 'Claude'}</span> ${escapeHtml(agent.title)}</strong>
          <button class="links-modal-x" title="닫기 (Esc)">✕</button></div>
        <div class="config-label" style="margin-bottom:8px">대화 기록 — 도구 호출/결과는 생략, 민감정보는 로그처럼 마스킹</div>
        <button class="agent-older-btn" data-agent-older hidden>이전 메시지</button>
        <div class="agent-turns" data-agent-turns>불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      const close = () => { back.remove(); document.removeEventListener('keydown', onKey); };
      const onKey = (e) => { if (e.key === 'Escape') close(); };
      document.addEventListener('keydown', onKey);
      back.querySelector('.links-modal-x').onclick = close;
      back.onclick = (e) => { if (e.target === back) close(); };   // 읽기 전용 뷰어 — 바깥 클릭 닫기 허용
      const body = back.querySelector('[data-agent-turns]');
      const older = back.querySelector('[data-agent-older]');
      let cursor = null;
      let loading = false;
      const turnsHtml = (turns) => turns.map(t => `
          <div class="agent-turn ${t.role === 'user' ? 'user' : 'ai'}">
            <span class="turn-role">${t.role === 'user' ? '나' : (isCodex ? 'Codex' : 'Claude')}</span>
            <div class="turn-text">${escapeHtml(t.text)}</div>
          </div>`).join('');
      async function loadOlderAgentTurns(initial = false) {
        if (loading) return;
        loading = true;
        older.disabled = true;
        older.textContent = '불러오는 중';
        try {
          const before = !initial && cursor != null ? `&before=${enc(cursor)}` : '';
          const d = await api(`/api/agent-transcript?root=${enc(session.root)}&source=${enc(agent.source)}&sid=${enc(agent.sid)}${before}`);
          const turns = d.turns || [];
          if (initial) {
            body.innerHTML = turns.length ? turnsHtml(turns) : '<div class="config-label">표시할 대화가 없어요 (도구 호출만 있었거나 빈 세션)</div>';
            body.scrollTop = body.scrollHeight;
          } else if (turns.length) {
            const oldHeight = body.scrollHeight;
            const oldTop = body.scrollTop;
            body.insertAdjacentHTML('afterbegin', turnsHtml(turns));
            body.scrollTop = oldTop + body.scrollHeight - oldHeight;
          }
          cursor = d.cursor ?? null;
          older.hidden = !d.hasMore;
        } catch (e) {
          if (initial) body.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`;
          else showToast(`이전 메시지 실패 · ${e.message}`, 'err');
        } finally {
          loading = false;
          older.disabled = false;
          older.textContent = '이전 메시지';
        }
      }
      older.onclick = () => loadOlderAgentTurns(false);
      await loadOlderAgentTurns(true);
    }

    let pollTimer = null;
    let pollTick = 0;
    function startPolling() {
      if (pollTimer) return;
      pollTimer = setInterval(() => {
        pollTick += 1;
        load({passive: true}).catch(console.error);
        // 60초마다 — 업데이트 상태는 분 단위로만 변함(서버도 UPDATE_TTL 캐시). 렌더는 signature 스킵.
        if (pollTick % 12 === 6) loadUpdateStatus().catch(console.error);
        // 15초마다 — 깃 배지(dirty/ahead)·AGENTS 는 서버 15s 캐시(값싼 부분만), du 는 서버가 장수 캐시로 분리
        if (pollTick % 3 === 0) loadWorktrees().catch(console.error);
      }, 5000);
    }
    function stopPolling() {
      clearInterval(pollTimer);
      pollTimer = null;
    }
