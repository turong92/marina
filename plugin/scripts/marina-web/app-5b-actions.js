    // app-5b-actions.js — 세션 카드 액션(P4 분할 2/3): hover 액션 클러스터(fillSvcActs/fillCardActs)·⋯메뉴(openActMenu
    // /cardMenuItems)·수명주기 플로우(stopAllFlow/clearCacheFlow/removeWorktreeFlow)·원인줄 배선(wireWhyLinks)·서비스 행(makeSvcRow).
    // app-5-sessions.js 다음 로드. 상태 모델(STATE_META·svcState 등)은 app-5-sessions.js 참조(전역).


    // 에러/비활성 원인 줄 (콘솔 스펙 D3) — 접힘과 무관하게 카드에 상시. reason 은 백엔드 stateReason.
    function whyLines(session) {
      const svcWhy = visibleServices(session).map(svc => {
        const st = svcState(svc);
        if (st !== 'error' && st !== 'degraded') return '';
        const reason = escapeHtml((svc.stateReason || (st === 'error' ? '실패' : '비활성')).slice(0, 160));
        const logsTarget = svc.busyError ? 'build' : svc.service;   // 기동 실패 원인은 build 로그에 있다
        const acts = st === 'error'
          ? `<a data-why-logs="${escapeHtml(logsTarget)}">${svc.busyError ? '빌드 로그' : '로그'}</a> · <a data-why-retry="${escapeHtml(svc.service)}">재시도</a>`
          : `<a data-why-compose="${escapeHtml(svc.service)}">구성 보기</a>`;
        return `<div class="svc-why"><b>${escapeHtml(svc.service)}</b>: ${reason} → ${acts}</div>`;
      }).join('');
      return envWhyLine(session) + svcWhy;
    }
    // A2 — env 누락 경고줄(에러 빨강과 구분되는 주황). 시작을 막지 않는다 — '안내' 클릭 시 팝오버(hint+복사).
    function envWhyLine(session) {
      const missing = session.missingEnv || [];
      if (!missing.length) return '';
      const names = missing.map(e => escapeHtml(e.name)).join(', ');
      return `<div class="svc-why warn">⚠ 환경변수 ${missing.length}개 미설정: ${names} → <a data-why-env>.env 안내</a></div>`;
    }
    // hover 액션 클러스터 채움 — render()와 updateServiceStates() 양쪽에서 사용(이중 렌더 경로 계약)
    function fillSvcActs(el, session, svc) {
      el.innerHTML = '';
      for (const a of svcActions(svc)) {
        const btn = document.createElement('button');
        btn.textContent = a.icon; btn.title = a.title; btn.dataset.act = a.act;
        btn.setAttribute('aria-label', a.title.split(' — ')[0]);
        btn.onclick = (event) => {
          event.stopPropagation();
          if (a.act === 'stop-external') {
            if (!confirm(`:${svc.port} 를 점유한 외부 프로세스(IDE/터미널로 직접 띄운 dev로 보임)를 종료할까?\ndocker 컨테이너가 점유 중이면 안전을 위해 거부돼.`)) return;
            withBusy(btn, '…', async () => {
              const r = await api('/api/stop-external', {method: 'POST', headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root, service: svc.service, port: Number(svc.port)})});
              if (r && r.stopped === false && r.reason) alert(r.reason);
              await load({force: true});
            }, el.querySelectorAll('button'));
            return;
          }
          withBusy(btn, '…', () => action(a.act, session.root, svc.service), el.querySelectorAll('button'));
        };
        el.appendChild(btn);
      }
      const logBtn = document.createElement('button');
      logBtn.textContent = '☰'; logBtn.title = '로그 — 이 서비스 로그를 우측 로그 탭에';
      logBtn.onclick = (event) => { event.stopPropagation(); selectLog(session.root, svc.service, 'current', 'service'); };
      el.appendChild(logBtn);
      const menuBtn = document.createElement('button');
      menuBtn.textContent = '⋯'; menuBtn.title = '열기·복사·구성';
      menuBtn.onclick = (event) => { event.stopPropagation(); openActMenu(menuBtn, svcMenuItems(session, svc)); };
      el.appendChild(menuBtn);
    }
    function svcMenuItems(session, svc) {
      const items = [];
      const gwUrl = gatewayUrlFor(session, svc);
      if (gwUrl) {
        items.push({ label: `🌐 게이트웨이로 열기 — ${gwUrl.replace(/^https?:\/\//, '')}`, run: () => window.open(gwUrl, '_blank') });
        items.push({ label: '⧉ 게이트웨이 주소 복사', run: () => navigator.clipboard.writeText(gwUrl) });
      }
      if (svc.running && svc.port) items.push({ label: `↗ 호스트포트로 열기 — 127.0.0.1:${svc.port}`, run: () => window.open(`http://127.0.0.1:${svc.port}`, '_blank') });
      if (session.kind === 'compose') {
        items.push({ label: 'Rebuild — Docker image 빌드 후 재기동', run: () => action('rebuild', session.root, svc.service) });
        items.push({ label: 'ⓘ 구성 보기 — Dockerfile·포트·env·build args', run: () => openServiceConfig(session.root, svc.service) });
      }
      return items;
    }
    function fillCardActs(el, session, services, group) {
      el.innerHTML = '';
      for (const a of cardActions(services)) {
        const btn = document.createElement('button');
        btn.textContent = a.icon; btn.title = a.title; btn.dataset.act = a.act;
        btn.setAttribute('aria-label', a.act === 'stop-all' ? '전체 정지' : '전체 시작');
        btn.onclick = (event) => {
          event.stopPropagation();
          if (a.act === 'stop-all') stopAllFlow(session, btn, group ? group() : el.querySelectorAll('button'));
          else withBusy(btn, '…', () => sessionAction('start-all', session), group ? group() : el.querySelectorAll('button'));
        };
        el.appendChild(btn);
      }
      const menuBtn = document.createElement('button');
      menuBtn.textContent = '⋯'; menuBtn.title = '편집·캐시·삭제';
      menuBtn.dataset.act = 'menu';
      menuBtn.onclick = (event) => { event.stopPropagation(); openActMenu(menuBtn, cardMenuItems(session)); };
      el.appendChild(menuBtn);
    }
    // 공용 ⋯ 팝오버 — 싱글턴, 바깥 클릭·재클릭으로 닫힘
    let actMenuEl = null;
    function closeActMenu() { if (actMenuEl) { actMenuEl.remove(); actMenuEl = null; } }
    function openActMenu(anchor, items) {
      if (actMenuEl && actMenuEl.dataset.anchor === (anchor.dataset.menuId ||= String(Math.random()))) { closeActMenu(); return; }
      closeActMenu();
      if (!items.length) return;
      const menu = document.createElement('div');
      menu.className = 'act-menu';
      menu.dataset.anchor = anchor.dataset.menuId;
      for (const it of items) {
        if (it.divider) { const d = document.createElement('div'); d.className = 'act-menu-div'; menu.appendChild(d); continue; }
        const b = document.createElement('button');
        if (it.sub) {   // 2줄 항목(GitKraken D&D) — 명령 전문(label) + 부제(sub). 잘리지 않게 CSS 로 넓게
          b.className = 'two-line';
          b.innerHTML = `<span class="am-label"></span><span class="am-sub"></span>`;
          b.querySelector('.am-label').textContent = it.label;
          b.querySelector('.am-sub').textContent = it.sub;
        } else {
          b.textContent = it.label;
        }
        b.onclick = (e) => { e.stopPropagation(); closeActMenu(); Promise.resolve(it.run()).catch(err => alert(String((err && err.message) || err))); };
        menu.appendChild(b);
      }
      document.body.appendChild(menu);
      const r = anchor.getBoundingClientRect();
      menu.style.top = `${Math.min(r.bottom + 4, window.innerHeight - menu.offsetHeight - 8)}px`;
      menu.style.left = `${Math.max(8, Math.min(r.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 8))}px`;
      actMenuEl = menu;
      setTimeout(() => document.addEventListener('click', closeActMenu, { once: true }), 0);
    }
    // 카드 ⋯ 메뉴 항목 + 수명주기 플로우 — 구 상시 버튼(✎·♻·✕·전체시작/정지 스트립)을 흡수 (콘솔 스펙 D7)
    function cardMenuItems(session) {
      const wt = worktreeData.find(w => w.root === session.root);
      const items = [];
      items.push({ label: '🔨 빌드 로그 — start/restart 의 prebuild·docker build 출력', run: () => selectLog(session.root, 'build', 'current', 'service') });
      // 카드 다이어트(형 피드백 2026-07-13) — ✎/캐시 칩·↔ link 버튼을 카드 얼굴에서 여기로 흡수
      items.push({ label: '⎇ 깃 — 이 워크트리 브랜치·커밋 그래프 (깃 탭)', run: () => openGitTab(session.root, wt?.branches?.[wt?.projectLabel] || '') });   // 깃 탭 기본 레포탭=root — root 레포 브랜치로 필터
      items.push({ label: '↔ link — main 의 deps/config 를 이 worktree 로', run: () => openLinksModal(session) });
      if (session.kind === 'compose') items.push({ label: '✎ compose 편집 — 보관된 docker-compose.yml 수정', run: () => openComposeEdit(wt?.projectRoot || session.root) });   // 워크트리 카드여도 프로젝트 루트로 — 워크트리 신규등록 버그 방지
      if (wt && wt.cacheMb > 50) items.push({ label: `♻ 캐시 정리 (${(wt.cacheMb / 1024).toFixed(1)}GB) — 재생성 캐시 전체 회수`, run: () => clearCacheFlow(session, wt) });
      if (session.source !== 'main') items.push({ label: '✕ worktree 삭제 — 미머지 브랜치는 보존', run: () => removeWorktreeFlow(session, wt) });
      return items;
    }
    function stopAllFlow(session, btn, group) {
      return withBusy(btn, '…', async () => {
        // 외부(IDE/터미널 직접 실행)는 compose down 이 못 내림 — 확인 받아 stop-external 로 함께 종료
        const externals = session.services.filter(svc => svc.external && svc.running);
        const killExternals = externals.length > 0 &&
          confirm(`marina 컨테이너 밖(IDE/터미널)에서 직접 띄운 프로세스도 있어:\n  ${externals.map(svc => `${svc.service} (:${svc.port})`).join(', ')}\n같이 종료할까? (취소=컨테이너만 정지)`);
        await sessionAction('stop-all', session);
        if (killExternals) {
          for (const svc of externals) {
            try {
              const r = await api('/api/stop-external', {method: 'POST', headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root, service: svc.service, port: Number(svc.port)})});
              if (r && r.stopped === false && r.reason) alert(`${svc.service}: ${r.reason}`);
            } catch (e) { alert(`${svc.service} 외부 종료 실패: ${String((e && e.message) || e)}`); }
          }
          await load({force: true});
        }
      }, group);
    }
    async function clearCacheFlow(session, wt) {
      const cacheGb = ((wt?.cacheMb || 0) / 1024).toFixed(1);
      if (!confirm(`${session.alias || session.id} 의 재생성 캐시(${cacheGb}GB)를 비울까?\n다음 dev 시작 때 재생성돼. Docker volume 이 사용 중이면 거부돼.`)) return;
      const result = await api('/api/clear-cache', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root})
      });
      alert(`캐시 ${((result.freedMb || 0) / 1024).toFixed(1)}GB 회수`);
      await loadWorktrees(true);
      await load({force: true});
    }
    async function removeWorktreeFlow(session, wt) {
      if (wt?.aheadTotal > 0 && !confirm(`미머지 커밋 ${wt.aheadTotal}개가 있어. worktree 만 제거되고 브랜치는 보존돼 (미머지 브랜치는 -d 가 거부). 계속할까?`)) return;
      let force = false;
      if (session.worktreeStatus?.broken) {     // git 링크 깨진 고아 워크트리 — 폐기할 변경 없음
        force = true;
      } else if (!session.worktreeStatus?.clean) {
        if (!confirm(`${session.alias || session.id} 에 미커밋 변경분이 있어.\n삭제하면 미커밋 변경·untracked 파일이 영구 폐기돼. 폐기하고 삭제할까?`)) return;
        force = true;
      }
      const delMsg = session.worktreeStatus?.broken
        ? `${session.alias || session.id} — git 링크가 깨진 고아 워크트리야. 폐기될 변경 없음(이미 git 추적 끊김). 폴더 정리 삭제할까?\n\n${session.root}`
        : `${session.alias || session.id} worktree 를 삭제할까?\n\n${session.root}`;
      if (!confirm(delMsg)) return;
      await api('/api/remove-worktree', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, force})
      });
      if (selected?.root === session.root) {
        selected = null;
        if (source) source.close();
        resetLogView('서비스 행을 선택하세요');
        updateOlderBar();
      }
      await load({force: true});
      await loadWorktrees(true);
    }
    function wireWhyLinks(slot, session) {     // 원인 줄의 다음 액션 링크 — 로그/재시도/구성/env 안내
      for (const a of slot.querySelectorAll('[data-why-logs]')) a.onclick = (e) => { e.stopPropagation(); selectLog(session.root, a.dataset.whyLogs, 'current', 'service'); };
      for (const a of slot.querySelectorAll('[data-why-retry]')) a.onclick = (e) => { e.stopPropagation(); action('start', session.root, a.dataset.whyRetry).catch(err => alert(String((err && err.message) || err))); };
      for (const a of slot.querySelectorAll('[data-why-compose]')) a.onclick = (e) => { e.stopPropagation(); openServiceConfig(session.root, a.dataset.whyCompose); };
      for (const a of slot.querySelectorAll('[data-why-env]')) a.onclick = (e) => { e.stopPropagation(); openEnvHintPopover(a, session); };
    }
    // A2 — env 안내 팝오버(⋯ 메뉴와 같은 싱글턴 규약) — 누락 var 별 hint 문구 + `VAR=` 클립보드 복사 버튼
    let envHintEl = null;
    function closeEnvHint() { if (envHintEl) { envHintEl.remove(); envHintEl = null; } }
    function openEnvHintPopover(anchor, session) {
      if (envHintEl) { closeEnvHint(); return; }
      const missing = session.missingEnv || [];
      if (!missing.length) return;
      const pop = document.createElement('div');
      pop.className = 'act-menu env-hint-pop';
      pop.innerHTML = missing.map(e => `
        <div class="env-hint-row">
          <span class="env-hint-text">${escapeHtml(e.hint || `${e.name}= 추가`)}</span>
          <button class="env-hint-copy" data-copy="${escapeHtml(e.name)}=" title="클립보드 복사">⧉ ${escapeHtml(e.name)}=</button>
        </div>`).join('');
      document.body.appendChild(pop);
      const r = anchor.getBoundingClientRect();
      pop.style.top = `${Math.min(r.bottom + 4, window.innerHeight - pop.offsetHeight - 8)}px`;
      pop.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - pop.offsetWidth - 8))}px`;
      pop.querySelectorAll('[data-copy]').forEach(btn => {
        btn.onclick = (e) => {
          e.stopPropagation();
          navigator.clipboard.writeText(btn.dataset.copy);
          const t = btn.textContent;
          btn.textContent = '✓ 복사됨';
          setTimeout(() => { btn.textContent = t; }, 800);
        };
      });
      envHintEl = pop;
      setTimeout(() => document.addEventListener('click', closeEnvHint, { once: true }), 0);
    }

    function makeSvcRow(session, svc, disabled) {   // Orca 문법 서비스 행 (콘솔 스펙 D3·D6·D7) — 상태점·이름·우측 모노포트·hover 클러스터
      const row = document.createElement('div');
      const st = svcState(svc);
      const optional = svc.inStartGroup === false && st === 'stopped';   // 시작 그룹 밖 + 꺼짐 — 집계 제외분(딤)
      row.className = 'svc nested' + (disabled ? ' disabled' : '') + (optional ? ' svc-opt' : '');
      row.dataset.serviceKey = `${session.root}::${svc.service}`;
      row.title = disabled ? 'subrepo 미attach — attach 후 사용 가능'
                : optional ? '옵션 서비스 — 시작 그룹(x-marina.startGroup) 밖. 필요하면 ▶ 로 개별 시작'
                : '클릭하면 이 서비스의 로그를 우측에 표시';
      row.innerHTML = `
        <span class="wt-dot ${disabled ? 'stop' : STATE_META[st].dot}" title="${escapeHtml(disabled ? 'subrepo 미attach' : STATE_META[st].title)}"></span>
        <span class="svc-name"><span>${escapeHtml(svc.service)}</span></span>
        ${(svc.profile ?? '') !== '' ? `<span class="svc-chip-prof" title="profile (marina 주입)">${escapeHtml(String(svc.profile))}</span>` : ''}
        <span class="svc-right">
          <span class="mono-port" data-rss>${svc.running && svc.rssMb ? `${svc.rssMb}MB` : ''}</span>
          <span class="mono-port" data-port title="${escapeHtml(portTitle(svc))}">${escapeHtml(portText(svc))}</span>
          <span class="mono-port svc-uptime" data-uptime title="마지막 로그 시각 기준">${svc.running ? escapeHtml(relTime(svc.logTs)) : ''}</span>
          <span class="hov-acts" data-svc-acts></span>
        </span>
        <span class="svc-tail" data-tail title="최신 로그 1줄 — 클릭하면 로그 탭">${tailVisible(svc) ? escapeHtml(svc.logTail) : ''}</span>
      `;
      if (disabled) return row;
      row.onclick = () => selectLog(session.root, svc.service, 'current', 'service');
      const portEl = row.querySelector('[data-port]');
      portEl.onclick = async (event) => {           // 포트 클릭 = 복사 (콘솔 스펙 D6)
        event.stopPropagation();
        if (!svc.port) return;
        try { await navigator.clipboard.writeText(String(svc.port)); const t = portEl.textContent; portEl.textContent = '✓'; setTimeout(() => { portEl.textContent = t; }, 800); } catch {}
      };
      fillSvcActs(row.querySelector('[data-svc-acts]'), session, svc);
      return row;
    }
