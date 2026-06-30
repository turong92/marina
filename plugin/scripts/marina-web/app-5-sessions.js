    function isInternalService(svc) {   // 엮기 forward 사이드카(<svc>-bind)·내부 표식 — 사용자 대상 서비스가 아니므로 카드에서 숨김
      return svc.internal === true || /-bind$/.test(svc.service || '');
    }
    function visibleServices(session) { return (session.services || []).filter(svc => !isInternalService(svc)); }

    // 서비스 1개 = 상태점 + 이름 + 포트 칩. 카드 요약 줄(접힘에서도)에서 한눈에 — 모달과 같은 칩 언어.
    function serviceChip(session, svc) {
      const st = pillState(svc);
      const port = svc.running && (svc.port ?? '') !== '' ? String(svc.port) : '';
      const key = `${session.root}::${svc.service}`;
      return `<span class="svc-chip" data-chip-key="${escapeHtml(key)}" data-name="${escapeHtml(svc.service)}" title="${escapeHtml(svc.service)} — ${escapeHtml(st.title)}">`
        + `<span class="dot ${st.cls}" data-chip-dot></span>`
        + `<span class="nm">${escapeHtml(svc.service)}</span>`
        + ((svc.profile ?? '') !== '' ? `<span class="svc-chip-prof" title="profile (marina 주입)">${escapeHtml(String(svc.profile))}</span>` : '')
        + `<span class="pt" data-chip-port${port ? '' : ' hidden'}>${escapeHtml(port)}</span>`
        + `</span>`;
    }
    function renderServiceChips(session) {
      const svcs = visibleServices(session);
      if (!svcs.length) return '';
      return `<div class="svc-chip-row" data-svc-chips>${svcs.map(svc => serviceChip(session, svc)).join('')}</div>`;
    }
    function trimChipRow(row) {   // 2줄까지만 노출, 초과분은 +N 칩(호버=이름들). 레이아웃 측정이라 DOM 부착 후 호출.
      if (!row) return;
      const old = row.querySelector('.svc-chip-more'); if (old) old.remove();
      const chips = [...row.children].filter(c => c.classList.contains('svc-chip'));
      if (chips.length < 2) return;
      for (const c of chips) c.style.display = '';
      const gap = 6, lineH = chips[0].offsetHeight || 22, firstTop = chips[0].offsetTop;
      const rowOf = (el) => Math.round((el.offsetTop - firstTop) / (lineH + gap));
      let cut = chips.findIndex(c => rowOf(c) >= 2);
      if (cut === -1) return;   // 2줄 안에 다 들어감
      for (let i = cut; i < chips.length; i++) chips[i].style.display = 'none';
      const more = document.createElement('span');
      more.className = 'svc-chip svc-chip-more';
      more.textContent = `+${chips.length - cut}`;
      row.appendChild(more);
      let guard = 0;
      while (rowOf(more) >= 2 && cut > 1 && guard++ < 40) {   // +N 이 3줄째로 밀리면 한 칸씩 더 접어 2줄 유지
        cut--; chips[cut].style.display = 'none';
        more.textContent = `+${chips.length - cut}`;
      }
      more.title = chips.slice(cut).map(c => c.dataset.name).join(' · ');   // 루프로 추가로 숨긴 칩까지 호버 목록에 반영
    }

    function shortPath(path) {
      return path.replace(/^\/(?:Users|home)\/[^/]+/, '~');  // macOS·Linux 홈 단축
    }

    const CACHE_CAT_LABEL = {};  // 라벨은 서비스명 — 아래 ?? cat 폴백
    function renderCacheDetails(area, session, wt) {
      const cats = Object.entries(wt?.cacheCats ?? {}).filter(([, mb]) => mb > 0);
      area.innerHTML = cats.length ? cats.map(([cat, mb]) =>
        `<div>${escapeHtml(CACHE_CAT_LABEL[cat] ?? cat)} — ${(mb / 1024).toFixed(1)}GB <button data-clear-cat="${escapeHtml(cat)}">Clear</button></div>`
      ).join('') : '회수할 캐시 없음';
      for (const btn of area.querySelectorAll('[data-clear-cat]')) {
        btn.onclick = () => {
          const cat = btn.dataset.clearCat;
          const mb = wt?.cacheCats?.[cat] ?? 0;
          if (!confirm(`${session.alias || session.id} 의 ${cat} 캐시(${(mb / 1024).toFixed(1)}GB)를 비울까?\n다음 dev 시작 때 재생성돼. Docker volume 이 사용 중이면 거부돼.`)) return;
          withBusy(btn, 'Clearing…', async () => {
            const result = await api('/api/clear-cache', {
              method: 'POST',
              headers: {'content-type': 'application/json'},
              body: JSON.stringify({root: session.root, category: cat})
            });
            alert(`캐시 ${((result.freedMb || 0) / 1024).toFixed(1)}GB 회수`);
            await loadWorktrees(true);
            await load({force: true});
          });
        };
      }
    }

    // 헬스 3단계 pill — 첫 HTTP 응답 전은 시간 제한 없이 BOOT, 응답 이력(everOk) 있는 서비스가 멎으면 ERR
    const HEALTH_PILLS = {   // 한글 UI — 짧게(스타일 cls 유지). 자세한 뜻은 title.
      ok: {text: '실행', cls: 'run', title: 'HTTP 응답 확인됨 — 사용 가능'},
      starting: {text: '시작', cls: 'boot', title: '프로세스는 떴고 첫 HTTP 응답 대기 중 — 빌드·컴파일이 길어도 시간 제한 없이 유지'},
      bad: {text: '오류', cls: 'bad', title: '응답하던 서비스가 응답을 멈춤 — 로그 확인 필요'},
    };
    // 상태 적응형 액션 가시성 — external(marina 컨테이너 아닌 외부 dev 가 포트 점유)은 marina 가 관리 안 함:
    //   ▶ 시작은 보임(외부 끄고 marina 로 띄울 수 있게), ■ 정지·↻ 재시작은 숨김(외부 프로세스엔 무효).
    function serviceActHidden(svc, type) {
      if (type === 'start') return (svc.running && !svc.external) || svc.degraded;
      if (type === 'restart') return !svc.running || svc.degraded || svc.external;
      return !svc.running || svc.external;   // stop
    }
    function pillState(svc) {
      if (svc.degraded) return {text: '비활성', cls: 'bad', title: 'Dockerfile 없음 — 이 서비스만 기동에서 건너뜁니다(나머지는 정상). compose 편집에서 Dockerfile 을 추가하거나 이 서비스를 빼세요.'};
      if (svc.external) return {text: `외부 :${svc.port}`, cls: 'run', title: `marina 컨테이너가 아닌 외부 프로세스가 포트 ${svc.port} 를 사용 중 — 직접(node·gradlew 등)으로 띄운 dev 서버로 보입니다. marina 로 관리하려면 그 프로세스를 끄고 ▶ 로 시작하세요.`};
      if (!svc.running) return {text: '꺼짐', cls: 'stop', title: '정지됨'};
      return HEALTH_PILLS[svc.health] ?? HEALTH_PILLS.ok;
    }

    function updateServiceStates() {
      for (const session of sessions) {
        const card = document.querySelector(`[data-root="${CSS.escape(session.root)}"]`);
        // 요약 서비스 칩(상태점·포트) 라이브 갱신 — 내부서비스(-bind)는 칩이 없어 자동 스킵
        for (const svc of session.services) {
          const chip = card?.querySelector(`[data-chip-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!chip) continue;
          const st = pillState(svc);
          const dot = chip.querySelector('[data-chip-dot]'); if (dot) dot.className = `dot ${st.cls}`;
          const cp = chip.querySelector('[data-chip-port]');
          if (cp) { const p = svc.running && (svc.port ?? '') !== '' ? String(svc.port) : ''; cp.textContent = p; cp.hidden = !p; }
          chip.title = `${svc.service} — ${st.title}`;
        }
        const stopAllBtn = card?.querySelector('[data-stop-all]');   // 시작/정지에 맞춰 정지(■) 표시 동기화 (busy 중엔 건드리지 않음)
        if (stopAllBtn && !stopAllBtn.disabled) stopAllBtn.hidden = !session.services.some(svc => svc.running);
        for (const svc of session.services) {
          const row = document.querySelector(`[data-service-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!row) continue;
          if (row.classList.contains('disabled')) continue;   // 미attach subrepo 의 서비스 — 라이브 상태로 덮지 않음
          const port = row.querySelector('[data-port]');
          const rss = row.querySelector('[data-rss]');
          const pill = row.querySelector('[data-state]');
          if (port) port.textContent = svc.port ?? '-';
          if (rss) rss.textContent = svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : '';
          if (pill) {
            const state = pillState(svc);
            pill.textContent = state.text;
            pill.className = `pill ${state.cls}`;
            pill.title = state.title;
          }
          // 상태 적응형 액션 — 정지: ▶ / 구동: ■·↻ (busy 중엔 건드리지 않음)
          for (const btn of row.querySelectorAll('[data-act]')) {
            if (btn.disabled) continue;
            btn.hidden = serviceActHidden(svc, btn.dataset.act);
          }
        }
      }
      renderSelection();
    }

    function render() {
      const sessionsEl = document.getElementById('sessions');
      sessionsEl.innerHTML = '';

      const wtByRoot = new Map(worktreeData.map(w => [w.root, w]));
      // 등록 프로젝트 목록 — 선택 보정(선택이 사라졌으면 첫 프로젝트로 폴백)
      const projectIds = [...new Set(worktreeData.map(w => w.projectId))];
      if (selectedProjectId && !projectIds.includes(selectedProjectId)) selectedProjectId = null;
      if (!selectedProjectId && projectIds.length) selectedProjectId = projectIds[0];
      renderSwitcher();
      // 빈 레지스트리 → 등록 패널이 기본 뷰 (spec C). 단 첫 worktree 로드 완료 후에만 — 로딩 중 스퓨리어스 방지
      if (worktreesLoaded && !projectIds.length) { showRegisterPanel(true); setRegisterKind('compose'); return; }
      // 선택 프로젝트로 스코프 — project-group 스태킹 대체 (세로 카드 목록 그대로)
      const scopedSessions = sessions.filter(s => wtByRoot.get(s.root)?.projectId === selectedProjectId);
      for (const session of scopedSessions) {
        const card = document.createElement('div');
        const isExpanded = expandedRoots.has(session.root);
        const wt = wtByRoot.get(session.root);
        // 상태를 원자적 칩으로 — 칩 내부는 개행 금지, 칩 사이에서만 줄바꿈.
        // 계층 분리: riskPills=위험(포트충돌·브랜치불일치·삭제권장) 별도 줄 / metaPills=정보(수정·캐시·미머지) 별도 줄
        const riskPills = [];
        const metaPills = [];
        // 카드 제목 = alias → Claude 세션 타이틀 → 최신 커밋 제목 → 해시. 해시는 제목과 다를 때만 보조줄로.
        // main 체크아웃은 "작업 세션"이 아니라 통합본 → 커밋제목 폴백 없이 'main'(id) 유지.
        const isMainCard = session.source === 'main' || wt?.isMain;
        const displayTitle = session.alias || (isMainCard ? '' : (wt?.sessionTitle || wt?.headSubject)) || session.id;
        const showSub = displayTitle !== session.id;
        const stRepos = session.worktreeStatus?.repos ?? [];
        const trackedCount = stRepos.reduce((sum, r) => sum + (r.trackedCount || 0), 0);
        const untrackedCount = stRepos.reduce((sum, r) => sum + (r.untrackedCount || 0), 0);
        // ✎ = 실제 수정(tracked) — 진짜 신호. 클릭하면 레포별 분해(합산 출처)
        if (trackedCount > 0) {
          metaPills.push(`<button class="pill-stat edit" data-changes-toggle title="미커밋 수정 — 클릭해 레포별 보기">✎ ${trackedCount} ▾</button>`);
        }
        // untracked = 주로 .venv·빌드산출물 노이즈 — 약하게, 0이면 사라짐. 같은 패널로 펼침
        if (untrackedCount > 0) {
          metaPills.push(`<button class="pill-stat ghost" data-changes-toggle title="untracked ${untrackedCount}개 (.venv·빌드산출물 등 — gitignore 권장). 클릭해 보기">+${untrackedCount}</button>`);
        }
        if (wt && wt.cacheMb > 50) {
          metaPills.push(`<button class="pill-stat" data-cache-toggle title="재생성 가능한 빌드 캐시 — 클릭해 카테고리별 보기·개별 회수">캐시 ${(wt.cacheMb / 1024).toFixed(1)}GB ▾</button>`);
        }
        if (wt && !wt.isMain) {
          // 디스크·미활동은 정보성 — 칩이 아니라 root 메타 줄에 합산 (칩은 액션·경고만)
          if (wt.verdict === 'stale') riskPills.push('<span class="pill-stat danger" title="clean · 미머지 0 · 7일↑ 미활동 — 지워도 안전">삭제 권장</span>');
          if (wt.aheadTotal > 0) {
            // ↑ = 이 세션이 생성 이후 쌓은 미머지 커밋(fork-point 기준). 출처 레포가 하나면 칩에 표기, 여럿이면 호버.
            const aheadRepos = Object.entries(wt.ahead || {}).filter(([, n]) => n > 0).map(([r]) => r);
            const src = aheadRepos.length === 1 ? ` ${aheadRepos[0]}` : '';
            const srcTitle = aheadRepos.length ? ` (${aheadRepos.map(r => `${r} ${wt.ahead[r]}`).join(' · ')})` : '';
            metaPills.push(`<span class="pill-stat ahead" title="main 에 없는 이 세션 커밋${srcTitle} — Remove 해도 브랜치는 보존">↑ ${wt.aheadTotal}${escapeHtml(src)}</span>`);
          }
        }
        let branchRow = '';
        if (wt?.branches && Object.keys(wt.branches).length) {
          // 브랜치는 항상 보이는 전용 줄로 — 어느 브랜치를 체크아웃 중인지 한눈에. 길면 줄바꿈(안 잘림).
          // 레포마다 다르거나(mixed), main 세션에 비-main 이 섞이면(offMain) 경고색 — 커밋이 엉뚱한 곳으로 갈 함정.
          const entries = Object.entries(wt.branches);
          const fullMap = entries.map(([repo, branch]) => `${repo}=${branch}`).join(' · ');
          const uniqueBranches = [...new Set(Object.values(wt.branches))];
          const offMain = session.source === 'main' && uniqueBranches.some(branch => branch !== 'main');
          const mixed = uniqueBranches.length > 1;
          const grouped = {};
          for (const [repo, branch] of entries) (grouped[branch] ??= []).push(repo);
          const parts = Object.entries(grouped).map(([branch, repos]) =>
            repos.length === entries.length ? escapeHtml(branch) : `${escapeHtml(branch)} <span class="br-repos">${escapeHtml(repos.join('·'))}</span>`);
          const warnTitle = mixed ? ' · 레포마다 브랜치가 달라 커밋이 의도와 다른 곳으로 갈 수 있음'
                          : offMain ? ' · main 세션인데 비-main 브랜치가 섞임' : '';
          branchRow = `<div class="branch-row${(offMain || mixed) ? ' warn' : ''}" title="체크아웃 브랜치 — ${escapeHtml(fullMap)}${warnTitle}"><span class="br-ic" aria-hidden="true">⎇</span><span class="br-text">${parts.join('<span class="br-sep"> · </span>')}</span></div>`;
        }
        if (session.webPortConflictWith?.length) {
          const conflictText = `⚠ 포트 충돌: ${session.webPortConflictWith.map(escapeHtml).join(', ')}`;
          riskPills.push(`<span class="pill-stat danger" title="다른 세션과 포트가 겹칩니다">${conflictText}</span>`);
        }
        // 전체 시작/정지 = 별도 action strip (제목 우측 툴바는 작은 아이콘만 남김)
        const hasStartAll = session.kind === 'compose';
        const actionStrip = (hasStartAll || session.services.some(svc => svc.running)) ? `
            <div class="session-actions">
              ${hasStartAll ? '<button data-start-all aria-label="전체 시작" title="전체 시작 — 이 세션의 compose 서비스 전부 시작(필요 시 외부 attach·pre-build·재빌드)">▶ 전체 시작</button>' : ''}
              <button data-stop-all aria-label="전체 정지" title="전체 정지 — 이 세션의 서비스 전부 정지">■ 전체 정지</button>
            </div>` : '';
        card.className = `session ${isExpanded ? '' : 'collapsed'}`;
        card.dataset.root = session.root;
        card.innerHTML = `
          <div class="session-head">
            <div class="session-title">
              <div class="session-main">
                <div class="alias-row">
                  <span class="chev">${isExpanded ? '▾' : '▸'}</span>
                  <span class="alias-display" data-alias-display title="클릭해서 별칭 수정 (세션 타이틀 위에 덮어씀)">${escapeHtml(displayTitle)}</span>
                  <input class="alias-input" data-alias value="${escapeHtml(session.alias || '')}" placeholder="별칭" aria-label="session alias" title="별칭 — Enter 로 저장" hidden />
                </div>
                ${showSub ? `<div class="sid-sub">${escapeHtml(session.id)}</div>` : ''}
              </div>
              <div class="session-tools">
                ${session.kind === 'compose' ? '<button data-edit-compose title="compose 편집 — 보관된 docker-compose.yml 수정 후 저장">✎</button>' : ''}
                ${wt && wt.cacheMb > 50 ? '<button data-clear-cache title="Clear cache — compose에서 찾은 재생성 캐시 전체 회수. 카테고리별 회수는 캐시 칩 클릭">♻</button>' : ''}
                ${session.source === 'main' ? '' : '<button data-remove class="danger" title="Remove — worktree 삭제. 미머지 브랜치는 보존, 변경분은 confirm 후 폐기">✕</button>'}
              </div>
            </div>
            ${branchRow}
            ${renderServiceChips(session)}
            ${actionStrip}
            ${riskPills.length ? `<div class="risk-row">${riskPills.join('')}</div>` : ''}
            ${metaPills.length ? `<div class="stat-row">${metaPills.join('')}</div>` : ''}
            <div class="wt-changes" data-session-changes hidden></div>
            <div class="wt-changes" data-cache-details hidden></div>
            <div class="root" title="${escapeHtml(session.root)}">${escapeHtml(shortPath(session.root))}${wt && !wt.isMain ? ` <span class="root-meta">·${wt.diskMb != null ? ` ${(wt.diskMb / 1024).toFixed(1)}GB` : ''}${wt.idleDays != null ? ` · ${Math.round(wt.idleDays)}일 미활동` : ''}</span>` : ''}</div>
            ${renderLinksRows(session)}
          </div>
          <div class="svc-list"></div>
        `;
        card.querySelector('.session-head').onclick = (event) => {
          if (event.target.closest('button,input,select,summary,details,[data-changes-toggle],[data-alias-display],.wt-changes')) return;
          if (expandedRoots.has(session.root)) expandedRoots.delete(session.root);
          else expandedRoots.add(session.root);
          render();
        };
        const aliasInput = card.querySelector('[data-alias]');
        aliasInput.onkeydown = (event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            aliasInput.blur();
          }
        };
        const aliasDisplay = card.querySelector('[data-alias-display]');
        aliasDisplay.onclick = () => {
          aliasDisplay.hidden = true;
          aliasInput.hidden = false;
          aliasInput.focus();
          aliasInput.select();
        };
        aliasInput.onblur = () => {
          if ((session.alias || '') !== aliasInput.value.trim()) {
            saveAlias(session, aliasInput).catch(alert);
          } else {
            aliasInput.hidden = true;
            aliasDisplay.hidden = false;
          }
        };
        const linksOpenBtn = card.querySelector('[data-links-open]');   // 🔗 링크 — 누르면 모달
        if (linksOpenBtn) linksOpenBtn.onclick = (e) => { e.stopPropagation(); openLinksModal(session); };
        const toolButtons = card.querySelectorAll('.session-tools button, .session-actions button');
        const stopAllBtn = card.querySelector('[data-stop-all]');
        stopAllBtn.hidden = !session.services.some(svc => svc.running);   // 정지할 게 없으면 숨김 — 개별 서비스 버튼과 동일한 상태적응
        stopAllBtn.onclick = () => withBusy(stopAllBtn, '…', () => sessionAction('stop-all', session), toolButtons);
        const startAllBtn = card.querySelector('[data-start-all]');       // compose: 항상 표시(미실행·include 미해석 시에도 전체 시작 가능)
        if (startAllBtn) startAllBtn.onclick = () => withBusy(startAllBtn, '…', () => sessionAction('start-all', session), toolButtons);
        const editComposeBtn = card.querySelector('[data-edit-compose]');
        if (editComposeBtn) editComposeBtn.onclick = (e) => { e.stopPropagation(); openComposeEdit(session.root); };
        const changesToggles = card.querySelectorAll('[data-changes-toggle]');
        const editToggle = card.querySelector('.pill-stat.edit[data-changes-toggle]');
        if (changesToggles.length) {
          const onToggle = () => {
            (async () => {
              const area = card.querySelector('[data-session-changes]');
              if (!area.hidden) {
                area.hidden = true;
                if (editToggle) editToggle.textContent = `✎ ${trackedCount} ▾`;
                return;
              }
              const data = await api(`/api/worktree-changes?root=${enc(session.root)}`);
              // 레포별로 tracked(✎)/untracked(+) 분해 — "합산이 어디서 왔는지" 출처를 드러냄
              area.textContent = (data.repos ?? []).filter(r => (r.changeCount || 0) > 0).map(r => {
                const head = `■ ${r.name}  ✎${r.trackedCount || 0}${(r.untrackedCount || 0) ? ` · +${r.untrackedCount} untracked` : ''}`;
                const lines = (r.changes ?? []).join('\n');
                const more = r.changeCount > (r.changes ?? []).length ? `\n... +${r.changeCount - r.changes.length} more` : '';
                return `${head}\n${lines}${more}`;
              }).join('\n\n') || '(변경 없음 — Refresh 해봐)';
              area.hidden = false;
              if (editToggle) editToggle.textContent = `✎ ${trackedCount} ▴`;
            })().catch(alert);
          };
          changesToggles.forEach(btn => { btn.onclick = onToggle; });
        }
        const cacheToggle = card.querySelector('[data-cache-toggle]');
        if (cacheToggle) {
          cacheToggle.onclick = () => {
            const area = card.querySelector('[data-cache-details]');
            if (!area.hidden) {
              area.hidden = true;
              return;
            }
            renderCacheDetails(area, session, wtByRoot.get(session.root));
            area.hidden = false;
          };
        }
        const clearCacheBtn = card.querySelector('[data-clear-cache]');
        if (clearCacheBtn) {
          clearCacheBtn.onclick = () => {
            const cacheGb = ((wtByRoot.get(session.root)?.cacheMb || 0) / 1024).toFixed(1);
            if (!confirm(`${session.alias || session.id} 의 재생성 캐시(${cacheGb}GB)를 비울까?\n다음 dev 시작 때 재생성돼. Docker volume 이 사용 중이면 거부돼.`)) return;
            withBusy(clearCacheBtn, '…', async () => {
              const result = await api('/api/clear-cache', {
                method: 'POST',
                headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root})
              });
              alert(`캐시 ${((result.freedMb || 0) / 1024).toFixed(1)}GB 회수`);
              await loadWorktrees(true);
              await load({force: true});
            }, toolButtons);
          };
        }
        const removeBtn = card.querySelector('[data-remove]');
        if (removeBtn) {
          removeBtn.onclick = () => {
            const wtInfo = wtByRoot.get(session.root);
            if (wtInfo?.aheadTotal > 0 && !confirm(`미머지 커밋 ${wtInfo.aheadTotal}개가 있어. worktree 만 제거되고 브랜치는 보존돼 (미머지 브랜치는 -d 가 거부). 계속할까?`)) return;
            let force = false;
            if (session.worktreeStatus?.broken) {     // git 링크 깨진 고아 워크트리 — 폐기할 변경 없음. 무섭게 안 띄우고 force 로 폴더 정리.
              force = true;
            } else if (!session.worktreeStatus?.clean) {
              if (!confirm(`${session.alias || session.id} 에 미커밋 변경분이 있어 (has local changes 클릭으로 확인).\n삭제하면 미커밋 변경·untracked 파일이 영구 폐기돼. 폐기하고 삭제할까?`)) return;
              force = true;
            }
            const delMsg = session.worktreeStatus?.broken
              ? `${session.alias || session.id} — git 링크가 깨진 고아 워크트리야. 폐기될 변경 없음(이미 git 추적 끊김). 폴더 정리 삭제할까?\n\n${session.root}`
              : `${session.alias || session.id} worktree 를 삭제할까?\n\n${session.root}`;
            if (!confirm(delMsg)) return;
            withBusy(removeBtn, '…', async () => {
              await api('/api/remove-worktree', {
                method: 'POST',
                headers: {'content-type': 'application/json'},
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
            }, toolButtons);
          };
        }
        renderServiceTree(card.querySelector('.svc-list'), session, wt);
        sessionsEl.appendChild(card);
      }
      // 칩 줄 overflow(+N)는 DOM 부착 후 측정 — 카드 모두 추가한 뒤 한 번에
      for (const row of sessionsEl.querySelectorAll('[data-svc-chips]')) trimChipRow(row);
      const collapseBtn = document.getElementById('collapseAll');
      collapseBtn.textContent = expandedRoots.size ? '⇈' : '⇊';
      collapseBtn.dataset.tip = expandedRoots.size ? '세션 카드 모두 접기' : '세션 카드 모두 펼치기';
      renderSelection();
    }

    async function openServiceConfig(root, service) {   // 읽기전용 구성 모달(동적 생성)
      const ex = document.getElementById('svcConfigBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'svcConfigBack'; back.className = 'modal-backdrop';
      back.innerHTML = `<div style="background:var(--sys-bg-surface);border:1px solid var(--sys-style-neutral-light);border-radius:12px;max-width:680px;width:92%;max-height:84vh;overflow:auto;padding:16px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px">
          <strong>구성 — ${escapeHtml(service)}</strong>
          <button id="svcCfgClose" style="background:none;border:none;color:var(--sys-cont-neutral-light);cursor:pointer;font-size:16px">✕</button>
        </div>
        <div id="svcCfgBody" style="font-size:13px;color:var(--sys-cont-neutral-light)">불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('#svcCfgClose').onclick = close;
      // 바깥(배경) 클릭으로는 안 닫음 — ✕ 로만(실수로 닫힘 방지)
      try {
        const r = await api('/api/compose-config?root=' + enc(root));
        const body = back.querySelector('#svcCfgBody');
        if (!body) return;
        if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--sys-cont-negative-default)">구성 읽기 실패: ' + escapeHtml((r && r.error) || '?') + '</span>'; return; }
        const svc = (r.services || []).find(s => s.service === service);
        body.innerHTML = svc ? renderServiceConfig(svc) : '서비스 구성 없음';
        if (svc) wireBuildArgsSave(body, root);
      } catch (e) {
        const body = back.querySelector('#svcCfgBody');
        if (body) body.innerHTML = '<span style="color:var(--sys-cont-negative-default)">' + escapeHtml(String((e && e.message) || e)) + '</span>';
      }
    }
    async function openProjectConfig(root) {   // 프로젝트 전체 서비스 구성(읽기전용) — compose 편집 모달에서
      const ex = document.getElementById('svcConfigBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'svcConfigBack'; back.className = 'modal-backdrop'; back.style.zIndex = '200';
      back.innerHTML = `<div style="background:var(--sys-bg-surface);border:1px solid var(--sys-style-neutral-light);border-radius:12px;max-width:720px;width:92%;height:86vh;display:flex;flex-direction:column;overflow:hidden;padding:16px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px;flex-shrink:0">
          <strong>구성 — 전체 서비스 <span style="font-weight:400;color:var(--sys-cont-neutral-lightest);font-size:12px">(profile·build args·pre-build 편집 가능)</span></strong>
          <button id="svcCfgClose" style="background:none;border:none;color:var(--sys-cont-neutral-light);cursor:pointer;font-size:16px">✕</button>
        </div>
        <div id="svcCfgBody" style="font-size:13px;color:var(--sys-cont-neutral-light);flex:1;min-height:0;display:flex;flex-direction:column">불러오는 중…</div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('#svcCfgClose').onclick = close;
      // 바깥(배경) 클릭으로는 안 닫음 — ✕ 로만(실수로 닫힘 방지)
      try {
        const r = await api('/api/compose-config?root=' + enc(root));
        const body = back.querySelector('#svcCfgBody');
        if (!body) return;
        if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--sys-cont-negative-default)">구성 읽기 실패: ' + escapeHtml((r && r.error) || '?') + '</span><div style="margin-top:6px;color:var(--sys-cont-neutral-lightest)">아직 미등록이거나 외부 레포 attach 전일 수 있어요(저장된 compose 기준).</div>'; return; }
        const svcs = r.services || [];
        if (!svcs.length) { body.innerHTML = '서비스 없음'; return; }
        const tabBtn = (s, i) => `<button class="cfg-tab" data-i="${i}" style="border:1px solid var(--sys-style-neutral-light);background:var(--sys-bg-base);color:var(--sys-cont-neutral-light);border-radius:8px;padding:4px 10px;font-size:12px;cursor:pointer;white-space:nowrap">📦 ${escapeHtml(s.subrepo || '-')}/${escapeHtml(s.service)}</button>`;
        body.innerHTML = `<div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px;flex-shrink:0">${svcs.map(tabBtn).join('')}</div><div id="cfgTabBody" style="flex:1;overflow:auto;min-height:0"></div>`;
        const tabs = [...body.querySelectorAll('.cfg-tab')];
        const showTab = (i) => {
          tabs.forEach((t, j) => {
            const on = j === i;
            t.style.background = on ? 'var(--sys-cont-primary-default)' : 'var(--sys-bg-base)';
            t.style.color = on ? '#fff' : 'var(--sys-cont-neutral-light)';
            t.style.fontWeight = on ? '700' : '400';
          });
          const cb = body.querySelector('#cfgTabBody');
          cb.innerHTML = renderServiceConfig(svcs[i]);
          wireBuildArgsSave(cb, root);
        };
        tabs.forEach(t => t.onclick = () => showTab(+t.dataset.i));
        showTab(0);
      } catch (e) {
        const body = back.querySelector('#svcCfgBody');
        if (body) body.innerHTML = '<span style="color:var(--sys-cont-negative-default)">' + escapeHtml(String((e && e.message) || e)) + '</span>';
      }
    }
    function renderServiceConfig(s) {
      const muted = 'var(--sys-cont-neutral-lightest)';
      const row = (k, v) => v ? `<div style="margin:5px 0"><span style="color:${muted}">${k}</span> &nbsp;${v}</div>` : '';
      const build = s.build
        ? `📁 ${escapeHtml(s.build.context)} &nbsp;·&nbsp; 🐳 ${escapeHtml(s.build.dockerfile)}`
        : (s.image ? '이미지 ' + escapeHtml(s.image) : '(빌드/이미지 없음)');
      const ports = (s.ports || []).length
        ? s.ports.map(p => '<code>' + escapeHtml(p) + '</code>').join(' ') + ` <span style="color:${muted}">→ marina 가 127.0.0.1:자동포트로 격리</span>`
        : `<span style="color:${muted}">(publish 없음 — 컨테이너 DNS만)</span>`;
      const env = (s.envKeys || []).length
        ? s.envKeys.map(k => '<code>' + escapeHtml(k) + '</code>').join(' ') + ` <span style="color:${muted}">(값 숨김)</span>`
        : `<span style="color:${muted}">(없음)</span>`;
      const cmd = s.command ? '<code>' + escapeHtml(Array.isArray(s.command) ? s.command.join(' ') : String(s.command)) + '</code>' : '';
      let html = `<div style="background:var(--sys-bg-base);border-radius:8px;padding:10px;margin-bottom:12px">
        ${row('서브레포', '📦 ' + escapeHtml(s.subrepo || '(없음)'))}
        ${row('출처', escapeHtml(s.source))}
        ${row('빌드', build)}
        ${row('포트', ports)}
        ${row('env', env)}
        ${row('command', cmd)}
      </div>`;
      const inj = s.injections || {};
      const reqSet = new Set(inj.requiredArgs || []);
      const injItems = [];
      (inj.requiredArgs || []).filter(a => a !== s.profileVar).forEach(a => injItems.push(`<li><b style="color:var(--sys-cont-negative-default)">ARG ${escapeHtml(a)} (필수)</b> — 아래 build args 에 설정</li>`));
      (inj.args || []).filter(a => !reqSet.has(a) && a !== s.profileVar).forEach(a => injItems.push(`<li>ARG <code>${escapeHtml(a)}</code> <span style="color:${muted}">(선택 · build args)</span></li>`));   // profileVar 는 아래 profile 컨트롤에서 다룸 — 중복 제외
      (inj.artifacts || []).forEach(a => injItems.push(`<li>📦 선빌드 필요 <code>${escapeHtml(a)}</code> <span style="color:${muted}">(gradle/pnpm — pre-build 훅)</span></li>`));
      (inj.runtime || []).forEach(r => injItems.push(`<li>⏱️ 런타임 <code>${escapeHtml(r)}</code></li>`));
      if (injItems.length) {
        html += `<div style="margin:0 0 12px;border:1px solid var(--sys-cont-negative-default);border-radius:8px;padding:8px 10px">
          <div style="color:var(--sys-cont-negative-default);font-weight:700;margin-bottom:4px">⚠️ 외부 주입 필요 (marina 가 감지)</div>
          <ul style="margin:0;padding-left:18px;line-height:1.6;color:var(--sys-cont-neutral-default)">${injItems.join('')}</ul></div>`;
      }
      if (s.profileVar) {   // ⚙️ profile — 그 서비스가 받는 환경선택 변수(감지). build arg + 런타임 env 로 주입.
        const pvId = 'pv-' + s.service.replace(/[^a-z0-9_-]/gi, '_');
        html += `<div style="margin:0 0 12px"><div style="color:${muted};margin-bottom:4px">⚙️ profile <span title="이 서비스가 받는 환경 선택 변수(${escapeHtml(s.profileVar)}) — marina 가 build arg + 런타임 env 로 주입(compose 안 건드림). 변경 시 다음 시작에 재빌드.">(${escapeHtml(s.profileVar)})</span></div>
          <input id="${pvId}" list="profileSuggest" value="${escapeHtml(s.profileValue || '')}" placeholder="local" style="width:160px;box-sizing:border-box;font-family:ui-monospace,monospace;font-size:12px;background:var(--sys-bg-base);color:var(--sys-cont-neutral-default);border:1px solid var(--sys-style-neutral-light);border-radius:6px;padding:6px">
          <button class="svc-llm-go pv-save" data-service="${escapeHtml(s.service)}" data-var="${escapeHtml(s.profileVar)}" data-target="${pvId}" style="margin-left:6px">💾 저장</button></div>`;
      } else {
        html += `<div style="margin:0 0 12px;color:${muted};font-size:11px">profile 변수 없음 — 환경은 compose 의 command/env_file 로 자기완결(주입 대상 아님).</div>`;
      }
      const baId = 'ba-' + s.service.replace(/[^a-z0-9_-]/gi, '_');
      // profileVar 는 위 profile 컨트롤이 관리 — build args 목록에선 제외(중복·혼동 방지)
      const baLines = Object.entries(s.marinaBuildArgs || {}).filter(([k]) => k !== s.profileVar).map(([k, v]) => k + '=' + v).join('\n');
      html += `<div style="margin:0 0 12px"><div style="color:${muted};margin-bottom:4px">⚙️ build args <span title="marina 가 overlay 로 주입 — app 레포·compose 안 건드림. profile 은 위 전용 칸에서. 다음 시작/재시작 때 적용.">(편집 가능 · 한 줄당 KEY=VALUE · profile 제외)</span></div>
        <textarea id="${baId}" spellcheck="false" placeholder="BUILD_VERSION=1.2.3" style="width:100%;min-height:52px;box-sizing:border-box;font-family:ui-monospace,monospace;font-size:12px;background:var(--sys-bg-base);color:var(--sys-cont-neutral-default);border:1px solid var(--sys-style-neutral-light);border-radius:6px;padding:6px">${escapeHtml(baLines)}</textarea>
        <button class="svc-llm-go ba-save" data-service="${escapeHtml(s.service)}" data-target="${baId}" style="margin-top:6px">💾 저장</button></div>`;
      if (s.subrepo && (s.build || s.prebuild)) {   // pre-build(B): 서브레포 공통, up 전 실행
        const pbId = 'pb-' + s.service.replace(/[^a-z0-9_-]/gi, '_');
        const sug = s.prebuildSuggest || '';
        const sugBtn = (sug && !s.prebuild) ? `<button class="svc-llm-go pb-suggest" data-target="${pbId}" data-cmd="${escapeHtml(sug)}" style="margin-left:6px">제안: ${escapeHtml(sug)}</button>` : '';
        html += `<div style="margin:0 0 12px"><div style="color:${muted};margin-bottom:4px">🔨 pre-build (서브레포 <b>${escapeHtml(s.subrepo)}</b> 공통 · up 전 실행)</div>
          <input id="${pbId}" value="${escapeHtml(s.prebuild || '')}" placeholder="${escapeHtml(sug ? ('예: ' + sug) : '예: ./gradlew build')}" style="width:100%;box-sizing:border-box;font-family:ui-monospace,monospace;font-size:12px;background:var(--sys-bg-base);color:var(--sys-cont-neutral-default);border:1px solid var(--sys-style-neutral-light);border-radius:6px;padding:6px">
          <div style="margin-top:6px"><button class="svc-llm-go pb-save" data-subrepo="${escapeHtml(s.subrepo)}" data-target="${pbId}">💾 pre-build 저장</button>${sugBtn}</div></div>`;
      }
      const dfPath = (s.build && s.build.dockerfile) ? String(s.build.dockerfile) : '';
      const dfPathHtml = dfPath ? ` <code style="color:var(--sys-cont-neutral-default)">${escapeHtml(dfPath)}</code>` : '';
      if (s.dockerfile) {
        html += `<div style="margin-bottom:4px;color:${muted}">🐳 Dockerfile${dfPathHtml} <span title="경로는 compose 의 build.dockerfile — 바꾸려면 compose 편집(✎)에서 수정 후 다시 보세요.">(읽기전용 · <span style="color:var(--sys-cont-primary-default)">변수</span> 하이라이트 · 경로=compose)</span></div>
          <pre style="background:var(--sys-code-bg);color:var(--sys-code-fg);border:1px solid var(--sys-style-neutral-light);border-radius:8px;padding:10px;overflow:auto;max-height:42vh;font-size:12px;white-space:pre-wrap;margin:0">${highlightVars(s.dockerfile)}</pre>`;
      } else if (s.build) {   // 빌드는 있는데 Dockerfile 을 못 읽음(파일 부재 등) — 왜 빈지 안내
        html += `<div style="margin:0 0 12px;border:1px dashed var(--sys-style-neutral-default);border-radius:8px;padding:8px 10px;color:${muted};font-size:12px;line-height:1.6">🐳 Dockerfile${dfPathHtml} 을 못 읽었습니다 — 현재 체크아웃에 이 파일이 없을 수 있어요(예: <code>Dockerfile.local</code> 이 다른 브랜치에만 있는 경우, 서브레포 브랜치를 맞추세요). 경로 자체는 compose 의 build.dockerfile 에서 바꿉니다(✎).</div>`;
      }
      return html;
    }
    function highlightVars(text) {   // Dockerfile 변수 하이라이트 — escape 후 ${VAR}/$VAR 참조 + ARG/ENV 선언 이름
      let h = escapeHtml(text);
      h = h.replace(/(\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*)/g, '<span style="color:var(--sys-cont-primary-default);font-weight:600">$1</span>');
      h = h.replace(/^(\s*(?:ARG|ENV)\s+)([A-Za-z_][A-Za-z0-9_]*)/gm, '$1<span style="color:var(--sys-cont-primary-default);font-weight:600">$2</span>');
      return h;
    }
    function wireBuildArgsSave(container, root) {   // ⓘ 모달 저장 — build args/pre-build. 변경 없으면 저장 버튼 비활성(형 제안)
      const wireDirty = (btn) => {   // 초기 비활성(저장할 변경 없음) — 대상 편집하면 활성
        const ta = document.getElementById(btn.dataset.target);
        if (ta) { btn.disabled = true; ta.addEventListener('input', () => { btn.disabled = false; }); }
      };
      const enableSave = (sel, targetId) => {   // 제안/후보 클릭 등 프로그램적 변경 후 해당 저장 버튼 활성화
        const sb = container.querySelector(sel + '[data-target="' + targetId + '"]');
        if (sb) sb.disabled = false;
      };
      container.querySelectorAll('.ba-save').forEach(btn => {
        wireDirty(btn);
        btn.onclick = async () => {
          const service = btn.dataset.service;
          const ta = document.getElementById(btn.dataset.target);
          const args = {};
          ((ta && ta.value) || '').split('\n').forEach(ln => {
            const i = ln.indexOf('='); if (i <= 0) return;
            const k = ln.slice(0, i).trim(); if (k) args[k] = ln.slice(i + 1).trim();
          });
          const orig = btn.textContent; btn.disabled = true; btn.textContent = '저장 중…';
          let ok = false;
          try {
            const resp = await fetch('/api/compose-service-args', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({root, service, args})});
            const r = await resp.json(); ok = !!(r && r.ok);
            btn.textContent = ok ? '✓ 저장됨 (다음 시작/재시작 적용)' : ('실패: ' + ((r && r.error) || '?'));
          } catch (e) { btn.textContent = '실패: ' + String((e && e.message) || e); }
          setTimeout(() => { btn.textContent = orig; btn.disabled = ok; }, 2600);   // 성공=깨끗(비활성)·실패=재시도(활성)
        };
      });
      container.querySelectorAll('.pb-suggest').forEach(btn => {
        btn.onclick = () => { const inp = document.getElementById(btn.dataset.target); if (inp) { inp.value = btn.dataset.cmd; enableSave('.pb-save', btn.dataset.target); } };
      });
      container.querySelectorAll('.pb-save').forEach(btn => {
        wireDirty(btn);
        btn.onclick = async () => {
          const subrepo = btn.dataset.subrepo;
          const inp = document.getElementById(btn.dataset.target);
          const command = ((inp && inp.value) || '').trim();
          const orig = btn.textContent; btn.disabled = true; btn.textContent = '저장 중…';
          let ok = false;
          try {
            const resp = await fetch('/api/compose-prebuild', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({root, subrepo, command})});
            const r = await resp.json(); ok = !!(r && r.ok);
            btn.textContent = ok ? '✓ 저장됨 (다음 시작 시 up 전 실행)' : ('실패: ' + ((r && r.error) || '?'));
          } catch (e) { btn.textContent = '실패: ' + String((e && e.message) || e); }
          setTimeout(() => { btn.textContent = orig; btn.disabled = ok; }, 2600);
        };
      });
      container.querySelectorAll('.pv-save').forEach(btn => {   // ⚙️ profile 저장 → /api/compose-service-profile
        wireDirty(btn);
        btn.onclick = async () => {
          const service = btn.dataset.service, value = ((document.getElementById(btn.dataset.target) || {}).value || '').trim();
          const orig = btn.textContent; btn.disabled = true; btn.textContent = '저장 중…';
          let ok = false;
          try {   // var 동봉 — UI 가 감지한 profile 변수 전달(백엔드 docker 재감지 불필요, 오프라인/미attach 에서도 저장)
            const resp = await fetch('/api/compose-service-profile', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({root, service, value, var: btn.dataset.var})});
            const r = await resp.json(); ok = !!(r && r.ok);
            btn.textContent = ok ? '✓ 저장됨 (다음 시작/재시작 적용 · 재빌드)' : ('실패: ' + ((r && r.error) || '?'));
          } catch (e) { btn.textContent = '실패: ' + String((e && e.message) || e); }
          setTimeout(() => { btn.textContent = orig; btn.disabled = ok; }, 2600);
        };
      });
    }
    function makeSvcRow(session, svc, disabled) {
      const row = document.createElement('div');
      row.className = 'svc nested' + (disabled ? ' disabled' : '');
      row.dataset.serviceKey = `${session.root}::${svc.service}`;
      const state = pillState(svc);
      row.title = disabled ? 'subrepo 미attach — attach 후 사용 가능' : '클릭하면 이 서비스의 로그를 우측에 표시';
      const src = '';
      row.innerHTML = `
        <div><div class="svc-name"><span>${svc.service}</span>${src}</div><div class="svc-port"><span data-port>${svc.port ?? '-'}</span><span data-rss>${svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : ''}</span></div></div>
        <div class="pill ${disabled ? 'stop' : state.cls}" data-state title="${escapeHtml(disabled ? 'subrepo 미attach' : state.title)}">${disabled ? '—' : state.text}</div>
        <div class="actions"></div>
      `;
      if (disabled) return row;
      row.onclick = () => selectLog(session.root, svc.service, 'current', 'service');
      const actions = row.querySelector('.actions');
      const busyLabels = {start: '…', stop: '…', restart: '…'};
      const actionTitles = {
        start: '시작 — 이 서비스 기동 (compose=up, 호스트 포트는 자동 격리)',
        stop: '정지 — 이 서비스 정지',
        restart: '재시작 — 변경분(빌드/설정) 반영해 재기동',
      };
      const actionAria = {start: '시작', stop: '정지', restart: '재시작'};
      for (const [label, type, cls] of [['▶', 'start', 'primary'], ['■', 'stop', 'danger'], ['↻', 'restart', '']]) {
        const btn = document.createElement('button');
        btn.textContent = label;
        btn.title = actionTitles[type];
        btn.setAttribute('aria-label', actionAria[type]);   // 아이콘만이라 스크린리더·hover 전 의미 보강(코덱스 UX #11)
        btn.dataset.act = type;
        if (cls) btn.className = cls;
        btn.hidden = serviceActHidden(svc, type);   // degraded·external 반영(헬퍼 단일화)
        btn.onclick = (event) => {
          event.stopPropagation();
          withBusy(btn, busyLabels[type], () => action(type, session.root, svc.service), actions.querySelectorAll('button'));
        };
        actions.appendChild(btn);
      }
      if (session.kind === 'compose') {   // 구성 보기(읽기전용) — 어떤 Dockerfile/compose 로 구성됐나
        const cfgBtn = document.createElement('button');
        cfgBtn.className = 'svc-edit-btn';
        cfgBtn.textContent = 'ⓘ';
        cfgBtn.title = '구성 보기 — 빌드 컨텍스트·Dockerfile·포트·env + build args·pre-build 설정';
        cfgBtn.setAttribute('aria-label', '구성 보기');
        cfgBtn.onclick = (event) => { event.stopPropagation(); openServiceConfig(session.root, svc.service); };
        actions.appendChild(cfgBtn);
      }
      const gwUrl = gatewayUrlFor(session, svc);   // 게이트웨이 켜졌고 running 이면 대표 도메인 URL + 복사
      if (gwUrl) {
        const gw = document.createElement('div');
        gw.className = 'svc-gw';
        gw.style = 'display:flex;align-items:center;gap:4px;font-size:11px;color:var(--muted);margin-top:2px;width:100%';
        const a = document.createElement('a');
        a.href = gwUrl; a.target = '_blank'; a.textContent = '🌐 ' + gwUrl.replace(/^https?:\/\//, '').replace(/\/$/, '');
        a.title = '게이트웨이 — 호스트 브라우저로 열기'; a.style = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--accent,#2563eb);text-decoration:none';
        a.onclick = (e) => e.stopPropagation();
        const cp = document.createElement('button');
        cp.className = 'svc-edit-btn'; cp.textContent = '⧉'; cp.title = 'URL 복사';
        cp.onclick = async (e) => { e.stopPropagation(); try { await navigator.clipboard.writeText(gwUrl); cp.textContent = '✓'; setTimeout(() => cp.textContent = '⧉', 1200); } catch {} };
        gw.appendChild(a); gw.appendChild(cp);
        row.appendChild(gw);
      }
      return row;
    }

    function renderSubrepoHead(name, o) {
      const chev = o.count ? `<span class="chev">${o.open ? '▾' : '▸'}</span>` : '<span class="chev"></span>';
      // 아이콘 토글 — attached→unlink(=detach 동작), detached→link(=attach 동작). Tabler link/unlink (MIT). 상태는 행 흐림(.detached)+아이콘으로 구분, 별도 칩 없음
      const UNLINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a3.5 3.5 0 0 0 5 0l4 -4a3.5 3.5 0 0 0 -5 -5l-.5 .5"/><path d="M14 10a3.5 3.5 0 0 0 -5 0l-4 4a3.5 3.5 0 0 0 5 5l.5 -.5"/><path d="M16 21v-2"/><path d="M19 16h2"/><path d="M3 8h2"/><path d="M8 3v2"/></svg>';
      const LINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 15l6 -6"/><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464"/><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463"/></svg>';
      // 핀 토글 — main 카드의 "기본"(새 worktree 자동 attach 대상) 체크박스 대체. on 이면 채워진 파란 핀
      const PIN_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4v6l-2 4v2h10v-2l-2 -4v-6"/><path d="M12 16l0 5"/><path d="M8 4l8 0"/></svg>';
      let control = '';
      if (!o.inUniverse) {
        control = '<span class="subrepo-chip warn" title="서비스 cwd 가 가리키는 subrepo 가 레지스트리에 없음 — ⚙ 에서 등록하면 attach 가능">미등록</span>';
      } else if (o.isMain) {
        control = `<button class="subrepo-act icon default-toggle ${o.isDefault ? 'on' : ''}" data-default-toggle aria-label="기본 attach 대상" title="기본 — 새 worktree 자동 attach 대상(전체 기본). 끄면 새 worktree 부터 제외 (main 의 클론은 보존)">${PIN_ICON}</button>`;
      } else if (o.isAttached) {
        control = `<button class="subrepo-act icon" data-detach aria-label="detach" title="이 worktree 에서 detach (git worktree remove) — 브랜치·미머지 커밋은 보존">${UNLINK_ICON}</button>`;
      } else {
        control = `<button class="subrepo-act icon primary" data-attach aria-label="attach" title="이 worktree 에 attach (git worktree add) — 같은 이름 브랜치 있으면 재사용">${LINK_ICON}</button>`;
      }
      return `
        <div class="subrepo-main">
          ${chev}
          <span class="subrepo-name">${escapeHtml(name)}</span>
          ${o.count ? `<span class="subrepo-count">${o.count} svc</span>` : '<span class="subrepo-count muted">no svc</span>'}
        </div>
        <div class="subrepo-ctl">${control}</div>
      `;
    }

    function renderServiceTree(list, session, wt) {
      list.innerHTML = '';
      const universe = wt?.subrepos ?? [];
      const isMain = !!wt?.isMain;
      const attached = new Set(wt?.attachedSubrepos ?? universe);
      const defaults = new Set(wt?.defaultAttach ?? universe);

      // 서비스 → subrepo 그룹핑 (svc.subrepo 태그). 빈 태그 = root cwd → ungrouped.
      const byGroup = new Map();
      const rootSvcs = [];
      for (const svc of session.services) {
        if (isInternalService(svc)) continue;   // 엮기 사이드카(-bind) 등 내부서비스는 트리에서 숨김
        const g = (svc.subrepo && svc.subrepo !== '.') ? svc.subrepo : '';   // '.'(루트/단일레포)는 그룹 없이 상단
        if (!g) { rootSvcs.push(svc); continue; }
        if (!byGroup.has(g)) byGroup.set(g, []);
        byGroup.get(g).push(svc);
      }
      // 그룹 순서: universe 순서 + 서비스만 참조하는 미등록 그룹은 뒤에.
      const groups = [...universe];
      for (const g of byGroup.keys()) if (!groups.includes(g)) groups.push(g);

      // 1) 루트(cwd '.') 서비스 — 카드 상단 ungrouped.
      for (const svc of rootSvcs) list.appendChild(makeSvcRow(session, svc, false));

      // 2) subrepo ⊃ service.
      if (session.kind === 'compose') {   // compose: 읽기전용 서브레포 그룹(빌드 컨텍스트 출처 — attach/추가 컨트롤 없음)
        for (const name of groups) {
          const svcs = byGroup.get(name) ?? [];
          if (!svcs.length) continue;
          const key = `${session.root}::${name}`;
          const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : true;
          const head = document.createElement('div');
          head.className = 'subrepo-row';
          head.innerHTML = `<div class="subrepo-main"><span class="subrepo-toggle">${open ? '▾' : '▸'}</span><span class="subrepo-name" title="서브레포 — 빌드 컨텍스트 출처">📦 ${escapeHtml(name)}</span></div><span class="subrepo-count">${svcs.length} svc</span>`;
          list.appendChild(head);
          const body = document.createElement('div');
          body.className = 'subrepo-body';
          body.hidden = !open;
          for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, false));
          list.appendChild(body);
          head.querySelector('.subrepo-main').onclick = () => { subrepoOpen.set(key, !open); render(); };
        }
      } else for (const name of groups) {
        const inUniverse = universe.includes(name);
        const isAttached = isMain || attached.has(name);
        const isDefault = defaults.has(name);
        const svcs = byGroup.get(name) ?? [];
        const key = `${session.root}::${name}`;
        const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : isAttached;

        const head = document.createElement('div');
        head.className = 'subrepo-row' + (isAttached ? '' : ' detached');
        head.innerHTML = renderSubrepoHead(name, {isMain, isAttached, isDefault, inUniverse, open, count: svcs.length});
        list.appendChild(head);

        const body = document.createElement('div');
        body.className = 'subrepo-body';
        body.hidden = !open;
        for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, !isAttached));
        list.appendChild(body);

        head.querySelector('.subrepo-main').onclick = () => {
          subrepoOpen.set(key, !open);
          render();
        };
        wireSubrepoToggle(head, session, wt, name, {isMain, isAttached, isDefault, inUniverse});
      }
      if (!list.children.length) {   // 빈 서비스 영역 — 빈칸 대신 '뭘 해야 하나' 안내(코덱스 UX #10)
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.style.cssText = 'padding:8px 10px;font-size:12px;color:var(--sys-cont-neutral-light);line-height:1.5';
        empty.innerHTML = session.kind === 'compose'
          ? '서비스가 아직 없습니다 — <b>▶ 전체</b>로 시작하면 compose·include 가 해석돼 나타납니다. (Docker 가 꺼져 있으면 켜고, 정의를 바꾸려면 카드의 <b>✎ compose 편집</b>)'
          : '서비스가 없습니다.';
        list.appendChild(empty);
      }
    }

    function wireSubrepoToggle(head, session, wt, name, o) {
      if (o.isMain && o.inUniverse) {
        const cb = head.querySelector('[data-default-toggle]');
        if (cb) cb.onclick = (e) => { e.stopPropagation(); withBusy(cb, '…', () => setDefaultAttach(session, wt, name, !o.isDefault)); };
      }
      const attachBtn = head.querySelector('[data-attach]');
      if (attachBtn) attachBtn.onclick = (e) => { e.stopPropagation(); withBusy(attachBtn, '…', () => attachSubrepo(session, name)); };
      const detachBtn = head.querySelector('[data-detach]');
      if (detachBtn) detachBtn.onclick = (e) => { e.stopPropagation(); withBusy(detachBtn, '…', () => detachSubrepo(session, name)); };
    }
