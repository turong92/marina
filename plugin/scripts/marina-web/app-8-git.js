    // app-8-git.js — 깃 탭: GitKraken 스타일 레인 그래프 + 우측 커밋 상세 + diff 오버레이(✕/Esc).
    // 변경 탭은 철거(2026-07-13) — diff·커밋 폼(wipMode, app-8b) 전부 이 탭 안에서 해결.
    // 전역 공유(classic script): api/enc/escapeHtml(app-3), worktreeData/selectedProjectId(app-1), openActMenu(app-5b)
    const GIT_LANES = ['#8a7ef0', '#2fae87', '#e0854f', '#d4537e', '#4f8fdd', '#b08a2e', '#7aa53c'];
    const GIT_ROW_H = 40, GIT_LANE_W = 22, GIT_PAD_X = 16;
    let gitRepoTab = '.';
    let gitWtFilter = '';   // P2 워크트리 필터 — '' = 전체, 아니면 branch 라벨(main 은 항상 표시). 리렌더에도 유지.
    const gitSideOpen = { local: true, remote: true, worktrees: true };   // 좌측 트리 섹션 접힘 상태(크라켄 LOCAL/REMOTE/WORKTREES)
    let gitAllRemotes = localStorage.getItem('gitAllRemotes') === '1';    // REMOTE '전체' — origin/* 전부 vs 내 카운터파트만(기본)
    let gitSideW = parseInt(localStorage.getItem('gitSideW'), 10) || 0;   // 좌측 트리 폭(드래그 리사이즈, 0=기본)
    // 원격 아이콘 — 유니코드 ☁ 는 폰트에 따라 화살표처럼 보임(형) → 인라인 SVG 구름으로 통일
    const GIT_CLOUD = '<svg class="gi-cloud" viewBox="0 0 16 16" width="11" height="11" aria-hidden="true"><path d="M4.5 12.5a3 3 0 0 1-.4-5.97 4.25 4.25 0 0 1 8.3-.83 3.15 3.15 0 0 1-.5 6.8z" fill="currentColor"/></svg>';

    function gitMainRoot() {
      const main = worktreeData.find(w => w.projectId === selectedProjectId && w.source === 'main');
      return main ? main.root : (worktreeData.find(w => w.source === 'main') || {}).root;
    }

    // 크라켄 문법 — 원격 ref 도 브랜치 이름은 그대로 두고 ☁ 아이콘으로만 원격임을 표시(origin/ 접두 제거)
    const gitShortRef = (name) => name.replace(/^origin\//, '');

    // 워크스페이스 '깃' 탭 진입 (콘솔 스펙 D2) — 모달 없이 pane 에 직접. 컨텍스트 root(선택 워크트리)를
    // 받지만 그래프 자체는 백엔드가 main 으로 승격(source_root_for)하므로 어느 root 든 동일 지형도.
    function renderGitPanel(container, root) {
      const r = root || gitMainRoot();
      if (!r) { container.innerHTML = '<div class="git-err" style="padding:14px">프로젝트가 아직 없어요 — 먼저 프로젝트를 등록하세요</div>'; return; }
      container.innerHTML = `<div class="git-head git-panel-head"><div class="git-tabs" data-git-tabs></div>
          <span class="git-head-fill"></span>
          <span class="git-legend" title="● 미커밋 · ✓ 머지됨 · ⚠ 브랜치 불일치 — 행 클릭 = 우측 상세, 파일 클릭 = diff 오버레이(Esc 닫기), 브랜치 필 hover = 전체 이름 · 클릭 = 그 브랜치만">ⓘ</span>
          <button data-git-refresh title="새로고침 — 캐시 무시하고 다시 스캔">↻</button></div>
        <div class="git-body git-panel" data-git-body>불러오는 중…</div>`;
      container.querySelector('[data-git-refresh]').onclick = () => loadGitGraphInto(container, r, gitRepoTab, true);
      loadGitGraphInto(container, r, gitRepoTab, false);
    }

    async function loadGitGraphInto(container, root, repo, refresh) {
      const body = container.querySelector('[data-git-body]'); if (!body) return;
      let g;
      try { g = await api(`/api/git-graph?root=${enc(root)}&repo=${enc(repo)}${refresh ? '&refresh=1' : ''}${gitAllRemotes ? '&all=1' : ''}&avatars=1`); }
      catch (e) {
        if (repo !== '.') { gitRepoTab = '.'; return loadGitGraphInto(container, root, '.', refresh); }  // 탭 잔상(다른 프로젝트의 repo명) 복구
        body.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; return;
      }
      gitRepoTab = g.repo;
      const rootName = (g.mainRoot || '').split('/').pop() || 'root';   // 루트도 실제 레포명으로(형 피드백)
      const tabs = container.querySelector('[data-git-tabs]');
      tabs.innerHTML = g.repos.map(r =>
        `<button data-git-repo="${escapeHtml(r)}" class="${r === g.repo ? 'active' : ''}">${escapeHtml(r === '.' ? rootName : r)}</button>`).join('');
      tabs.querySelectorAll('[data-git-repo]').forEach(b => b.onclick = () => loadGitGraphInto(container, root, b.dataset.gitRepo, false));
      if (gitWtFilter && !g.branches.some(b => b.branch === gitWtFilter)) gitWtFilter = '';   // 다른 레포 탭엔 없는 브랜치 — 리셋
      renderGitGraph(body, g);
    }
    // WS_VIEWS 는 app-6 에서 정의(로드 순서상 먼저) — 깃 탭 활성화 시 선택 워크트리 컨텍스트로 렌더
    let gitPendingRoot = null;   // openGitTab 이 심는 1회성 컨텍스트(카드 → 깃 탭 라우팅)
    WS_VIEWS.git = { activate(pane, ctx) {
      const r = gitPendingRoot || (ctx && ctx.root);
      if (!gitPendingRoot && ctx && ctx.root) {   // 컨텍스트 추종 — 선택 워크트리의 깃만(그 브랜치 필터), main 선택이면 전체
        const wt = worktreeData.find(w => w.root === ctx.root);
        gitWtFilter = (wt && !wt.isMain && wt.branches && wt.branches[wt.projectLabel]) || '';
      }
      gitPendingRoot = null;
      renderGitPanel(pane, r);
    } };
    // 카드/칩 → 깃 탭 진입점 — branch 를 주면 그 워크트리 레인으로 필터 프리셀렉트(다른 레포 탭엔 없으면 자동 해제)
    function openGitTab(root, branch) {
      if (branch) gitWtFilter = branch;
      gitPendingRoot = root || null;
      const alreadyOn = typeof wsActive !== 'undefined' && wsActive === 'git';
      if (typeof setWsTab === 'function') setWsTab('git');
      if (alreadyOn) { const pane = document.getElementById('tab-git'); gitPendingRoot = null; renderGitPanel(pane, root || undefined); }
    }

    function gitReachableHashes(byHash, tips) {   // P2 필터 — tips 의 전체 조상(모든 parent, first-parent 한정 아님) 집합
      const seen = new Set(), stack = [...tips];
      while (stack.length) {
        const h = stack.pop();
        if (!h || seen.has(h) || !byHash.has(h)) continue;
        seen.add(h);
        for (const p of byHash.get(h).parents || []) stack.push(p);
      }
      return seen;
    }

    function renderGitGraph(body, g) {
      // P2 워크트리 필터 — main + 선택 브랜치만 레인/칩 대상. 레인 좌표는 안정적으로 유지하려 전체
      // 레인은 그대로 계산하고(색·위치 유지), 표시되는 "행"만 gitWtFilter 로 줄인다.
      const branches = gitWtFilter
        ? g.branches.filter(b => b.branch === g.mainBranch || b.branch === gitWtFilter
            || (b.remote && (b.branch === 'origin/' + gitWtFilter || b.branch === 'origin/' + g.mainBranch)))
        : g.branches;
      // 레인 배치: main = lane 0. 각 브랜치 tip 에서 first-parent 체인을 따라 내려가며
      // "아직 레인 없는 커밋" 에 자기 레인 배정 — main 이 먼저 걸어 공유 히스토리를 차지.
      // 레인 정체성은 항상 전체 브랜치(g.branches) 기준 — 필터로 목록이 줄어도 레인/색 배정이 안 흔들린다(codex P3).
      const byHash = new Map(g.commits.map(c => [c.hash, c]));
      const ordered = [...g.branches].sort((a, b) => (b.branch === g.mainBranch) - (a.branch === g.mainBranch));
      const lane = new Map();
      ordered.forEach(b => { if (!lane.has(b.branch)) lane.set(b.branch, lane.size); });
      const laneOf = new Map();
      for (const b of ordered) {
        let h = b.head;
        while (h && byHash.has(h) && !laneOf.has(h)) {
          laneOf.set(h, lane.get(b.branch));
          h = (byHash.get(h).parents || [])[0];
        }
      }
      // 살아있는 tip 이 없는 머지된 side history(워크트리 정리 후) — merge 2nd parent 부터 익명 레인 배정
      for (const c of g.commits) {
        for (const p of (c.parents || []).slice(1)) {
          if (!byHash.has(p) || laneOf.has(p)) continue;
          const anon = lane.size; lane.set(`anon:${p.slice(0, 7)}`, anon);
          let h = p;
          while (h && byHash.has(h) && !laneOf.has(h)) { laneOf.set(h, anon); h = (byHash.get(h).parents || [])[0]; }
        }
      }
      // 필터 활성 시 — main+선택 브랜치 tip 의 전체 조상만 커밋 행으로 노출(공유 히스토리는 유지, 다른 브랜치 전용 커밋은 숨김)
      const visible = gitWtFilter ? gitReachableHashes(byHash, branches.map(b => b.head)) : null;
      const rows = [];
      for (const b of branches) if (b.dirtyCount) rows.push({ wip: true, b, lane: lane.get(b.branch) || 0 });
      for (const c of g.commits) {
        if (visible && !visible.has(c.hash)) continue;
        rows.push({ c, lane: laneOf.get(c.hash) ?? 0 });
      }
      const rowIdx = new Map();
      rows.forEach((r, i) => rowIdx.set(r.c ? r.c.hash : `wip:${r.b.branch}`, i));

      // ── 레인 X좌표 재사용(GitKraken) — 브랜치마다 영원히 한 칸씩 차지하면 그래프가 부채꼴로 벌어진다.
      // 각 레인(브랜치 정체성)의 행 구간 [start,end] 을 계산해, 구간이 안 겹치는 레인끼리 같은 X 를 공유.
      // 색은 계속 "브랜치 정체성"(원 레인)을 따른다 — 같은 X 라도 브랜치가 다르면 색이 다름.
      const iv = new Map();   // 원레인 → {start, end} (커밋 행 + 커넥터가 스치는 행까지)
      const touch = (l, i) => { const v = iv.get(l) || { start: i, end: i }; v.start = Math.min(v.start, i); v.end = Math.max(v.end, i); iv.set(l, v); };
      rows.forEach((r, i) => {
        touch(r.lane, i);
        if (r.wip) { const tip = rowIdx.get(r.b.head); if (tip !== undefined) touch(r.lane, tip); }
        else for (const p of r.c.parents) {
          const pi = rowIdx.get(p);
          if (pi !== undefined) { touch(r.lane, pi); touch(rows[pi].lane, i); }
        }
      });
      const mainLane = lane.get(g.mainBranch) ?? 0;
      const laneX = new Map([[mainLane, 0]]);   // main = X0 고정(전체 구간 점유)
      const laneEnd = [Infinity];               // newX → 마지막 점유 행
      for (const [old, v] of [...iv.entries()].sort((a, b) => a[1].start - b[1].start)) {
        if (laneX.has(old)) continue;
        let nx = 1;
        while (laneEnd[nx] !== undefined && laneEnd[nx] >= v.start) nx++;   // 겹치면 다음 칸
        laneX.set(old, nx);
        laneEnd[nx] = v.end;
      }
      const laneCount = Math.max(1, Math.max(...[...laneX.values()]) + 1);
      const gw = GIT_PAD_X * 2 + (laneCount - 1) * GIT_LANE_W;
      const X = l => GIT_PAD_X + (laneX.get(l) ?? 0) * GIT_LANE_W, Y = i => i * GIT_ROW_H + GIT_ROW_H / 2;
      // 색 = 브랜치 정체성 — 전체 목록 기준 인덱스라 필터로 레인이 줄어도 색이 안 변하고,
      // 원격(origin/X)은 로컬 X 와 같은 색(크라켄 — 같은 브랜치는 로컬/원격이 한 색)
      const colorIdx = new Map();
      [...g.branches].sort((a, b) => (b.branch === g.mainBranch) - (a.branch === g.mainBranch))
        .forEach(b => { const k = gitShortRef(b.branch); if (!colorIdx.has(k)) colorIdx.set(k, colorIdx.size); });
      const colorOf = (name) => GIT_LANES[(colorIdx.get(gitShortRef(name)) ?? 0) % GIT_LANES.length];
      const laneName = new Map([...lane.entries()].map(([n, i]) => [i, n]));
      const C = l => {
        const n = laneName.get(l);
        const i = n != null && colorIdx.has(gitShortRef(n)) ? colorIdx.get(gitShortRef(n)) : l;
        return GIT_LANES[i % GIT_LANES.length];
      };
      // D&D(크라켄) — 필·행이 드래그 소스이자 드롭 타깃. 방향이 동작을 정한다(드롭하면 메뉴로 확정):
      //   로컬 → ☁ 카운터파트/REMOTE 섹션 = 푸시(일반/첫 -u/강제) · ☁ → 같은 로컬 = 당겨오기(ff-only) · 그 외 → 로컬 = 병합
      const dndAttrs = (b) => {
        if (b.detached) return '';
        if (b.remote) return ` draggable="true" data-drag-kind="remote" data-drag-branch="${escapeHtml(b.branch)}" data-drop-remote="${escapeHtml(gitShortRef(b.branch))}"`;
        return ` draggable="true" data-drag-kind="local" data-drag-branch="${escapeHtml(b.branch)}" data-drag-root="${escapeHtml(b.root)}"`
          + ` data-drag-ahead="${b.aheadRemote || 0}" data-drag-behind="${b.behindRemote || 0}" data-drag-up="${b.upstream === false ? '0' : '1'}"`
          + ` data-drop-local="${escapeHtml(b.branch)}" data-drop-root="${escapeHtml(b.root)}"`;
      };
      let svg = '';
      rows.forEach((r, i) => {
        if (r.wip) {
          const tip = rowIdx.get(r.b.head);
          if (tip !== undefined) svg += `<path d="M${X(r.lane)},${Y(i)} L${X(r.lane)},${Y(tip)}" stroke="${C(r.lane)}" stroke-width="2" stroke-dasharray="3 3" fill="none"/>`;
          svg += `<circle cx="${X(r.lane)}" cy="${Y(i)}" r="8" fill="none" stroke="${C(r.lane)}" stroke-width="2" stroke-dasharray="3 2.5"/>`;
          return;
        }
        for (const p of r.c.parents) {
          const pi = rowIdx.get(p);
          if (pi === undefined) {   // 200개 창 밖 부모 — 아래로 사라지는 스텁
            svg += `<path d="M${X(r.lane)},${Y(i)} L${X(r.lane)},${Y(i) + GIT_ROW_H * 0.8}" stroke="${C(r.lane)}" stroke-width="2" opacity=".35" fill="none"/>`;
            continue;
          }
          // 커넥터 — 크라켄식 각진 라우팅(형: 곡선이 보기 힘듦). 자식 레인에서 수직으로 내려오다
          // 부모 행 직전에 둥근 코너 하나로 부모 레인에 합류. 부드러운 S-베지어 대신 orthogonal+radius.
          const pl = rows[pi].lane, x1 = X(r.lane), y1 = Y(i), x2 = X(pl), y2 = Y(pi);
          if (x1 === x2) {
            svg += `<path d="M${x1},${y1} L${x2},${y2}" stroke="${C(r.lane)}" stroke-width="2" fill="none"/>`;
          } else {
            const dir = x2 > x1 ? 1 : -1, R = Math.min(9, Math.abs(y2 - y1) / 2, Math.abs(x2 - x1));
            svg += `<path d="M${x1},${y1} L${x1},${y2 - R} Q${x1},${y2} ${x1 + dir * R},${y2} L${x2},${y2}" stroke="${C(r.lane)}" stroke-width="2" fill="none"/>`;
          }
        }
        // 아바타 노드(크라켄) — 이니셜 디스크가 기본(fallback). 아바타 URL(GitHub 프로필)이 해석됐으면
        // 그 위에 원형 클립으로 덮는다. 로드 실패(오프라인 등)면 이미지가 안 그려져 밑의 이니셜이 그대로 보임.
        // 노드 = 아바타(20px) + 테두리 링(형). surface 헤일로로 뒤 레인선과 분리(크라켄 감) → 레인색 링.
        const cx = X(r.lane), cy = Y(i), ini = ((r.c.author || '?').trim()[0] || '?').toUpperCase();
        svg += `<circle cx="${cx}" cy="${cy}" r="12.5" fill="none" stroke="var(--sys-bg-surface)" stroke-width="3"/>`
          + `<circle cx="${cx}" cy="${cy}" r="10" fill="${C(r.lane)}"/>`
          + `<text x="${cx}" y="${cy}" text-anchor="middle" dominant-baseline="central" font-size="11" font-weight="700" fill="#fff">${escapeHtml(ini)}</text>`;
        if (r.c.avatar) {
          const url = r.c.avatar + (r.c.avatar.includes('?') ? '&' : '?') + 's=64';
          svg += `<image x="${cx - 10}" y="${cy - 10}" width="20" height="20" clip-path="url(#gav-clip)" preserveAspectRatio="xMidYMid slice" href="${escapeHtml(url)}"/>`;
        }
        svg += `<circle cx="${cx}" cy="${cy}" r="11" fill="none" stroke="${C(r.lane)}" stroke-width="1.75"/>`;
      });

      const tipOf = new Map();
      branches.forEach(b => { if (!tipOf.has(b.head)) tipOf.set(b.head, []); tipOf.get(b.head).push(b); });
      // 로컬과 origin 카운터파트가 같은 커밋 = 필 하나로 합쳐 ⎇☁ 두 아이콘(크라켄). 갈라졌을 때만 ☁ 필이 따로 선다.
      for (const [h, list] of tipOf) {
        const locals = new Set(list.filter(b => !b.remote).map(b => b.branch));
        list.forEach(b => { if (!b.remote) b.remoteHere = list.some(r => r.remote && gitShortRef(r.branch) === b.branch); });
        tipOf.set(h, list.filter(b => !(b.remote && locals.has(gitShortRef(b.branch)))));
      }
      const html = rows.map((r, i) => {
        if (r.wip) {
          const b = r.b;
          return `<div class="git-row wip" data-wip-root="${escapeHtml(b.root)}" title="미커밋 변경 — 클릭해 diff">
            <span class="git-reflabel"><span class="grl-in"><span class="git-badge dirty" title="아직 커밋 안 된 변경 ${b.dirtyCount}개">● ${b.dirtyCount}</span></span></span>
            <span class="git-graph-gap"></span>
            <span class="git-subject git-sub">${escapeHtml(b.alias || '')} — 작업 중인 변경</span>
            <span class="git-sha"></span></div>`;
        }
        const c = r.c;
        // 칩 문법(정돈): 첫 브랜치만 인라인 필(+배지+hover 정리), 나머지는 +N 팝오버 — 같은 커밋에 팁이
        // 몰려도(맨 윗줄 흔함) subject·해시가 밀려나지 않는다.
        const tips = tipOf.get(c.hash) || [];
        const pill = (b) => {
          const col = C(lane.get(b.branch) || 0);
          const who = (!b.isMain && b.alias && b.alias !== b.branch) ? ` <span class="br-who">${escapeHtml(b.alias)}</span>` : '';
          // 원격 = 아웃라인 필(채움 없는 구름 톤) — 로컬(채움)과 한눈에 구분. 이름은 origin/ 없이, ☁ 아이콘이 원격 표시.
          // 로컬·원격이 같은 커밋이면 로컬 필 하나에 ⎇☁ 두 아이콘(크라켄 문법).
          const pillStyle = b.remote ? `border:1.5px solid ${col};color:${col};background:transparent` : `background:${col}`;
          const icon = b.remote ? GIT_CLOUD : (b.remoteHere ? '⎇' + GIT_CLOUD : '⎇');
          const tip = b.remote ? `origin/${gitShortRef(b.branch)} — 원격(origin)` : `${b.branch}${b.alias ? ' — ' + b.alias : ''}${b.remoteHere ? ' · 원격(origin)도 같은 위치' : ''}`;
          let s = `<span class="git-chip br${b.remote ? ' remote' : ''}" data-pill-branch="${escapeHtml(gitShortRef(b.branch))}"${dndAttrs(b)} style="${pillStyle}" title="${escapeHtml(tip)} — 클릭하면 이 브랜치만 보기">${icon} ${escapeHtml(gitShortRef(b.branch))}${who}</span>`;
          if (!b.detached && !b.remote) {
            if (!b.upstream) s += `<span class="git-badge local" title="원격 추적 브랜치 없음 — 로컬 전용(아직 한 번도 push 안 됨)">L</span>`;
            else if (b.aheadRemote) s += `<span class="git-badge push" title="원격보다 ${b.aheadRemote}커밋 앞섬 — 미푸시">↑${b.aheadRemote}</span>`;
            if (b.upstream && b.behindRemote) s += `<span class="git-badge pull" title="원격이 ${b.behindRemote}커밋 앞섬 — pull 필요">↓${b.behindRemote}</span>`;
          }
          if (b.merged) s += `<span class="git-badge ok" title="HEAD 가 ${escapeHtml(g.mainBranch)} 에 포함 — 워크트리 정리 가능">✓</span>`;
          if (b.mismatch && b.mismatch.length) s += `<span class="git-badge warn" title="같은 워크트리의 다른 레포가 다른 브랜치를 체크아웃 — ${escapeHtml(b.mismatch.join(' · '))}">⚠</span>`;
          if (b.merged) {
            // P2 — 정리(remove-worktree) 실제 동작은 app-8b(gitCleanupWorktree) 가 담당. hover 에서만 노출(중구난방 방지).
            s += `<button class="git-chip-btn hov" data-cleanup-root="${escapeHtml(b.root)}" data-cleanup-alias="${escapeHtml(b.alias || b.branch)}" data-cleanup-dirty="${(b.dirtyCount || 0) + (b.untrackedCount || 0)}" title="워크트리 정리 — 삭제(브랜치는 이미 머지되어 보존 불필요)">정리</button>`;
          }
          return s;
        };
        let chips = tips.length ? pill(tips[0]) : '';
        if (tips.length > 1) chips += `<button class="git-chip more" data-tips="${c.hash}" title="이 커밋을 가리키는 브랜치 ${tips.length}개 — 클릭해 목록">+${tips.length - 1}</button>`;
        return `<div class="git-row" data-commit="${c.hash}" title="${escapeHtml(c.author || '')} · ${new Date(c.ts * 1000).toLocaleString('ko-KR')} — 클릭해 커밋 상세">
          <span class="git-reflabel"><span class="grl-in">${chips}</span></span>
          <span class="git-graph-gap"></span>
          <span class="git-subject" title="${escapeHtml(c.subject)}">${escapeHtml(c.subject)}</span>
          <span class="git-sha">${c.hash.slice(0, 7)}</span></div>`;
      }).join('');
      // 시간은 컬럼이 아니라 그룹 경계 마커(크라켄 "N hours ago") — 버킷 라벨이 바뀌는 행 사이에 필로 띄움.
      // 분 단위는 마커가 난립해서 시간/일 버킷만 쓴다(정확한 시각은 행 tooltip·상세 패널).
      const timeBucket = (r) => {
        if (r.wip) return '지금';
        const s = Math.max(0, Date.now() / 1000 - r.c.ts);
        if (s < 3600) return '1시간 내';
        if (s < 86400) return `${Math.round(s / 3600)}시간 전`;
        return `${Math.round(s / 86400)}일 전`;
      };
      const timeLab = rows.map(timeBucket);
      let timeMarks = '';
      timeLab.forEach((l, i) => {
        if (i && l !== timeLab[i - 1]) timeMarks += `<span class="git-time-mark" style="top:${i * GIT_ROW_H - 9}px">${l}</span>`;
      });

      // ── 좌측 브랜치 트리(크라켄 LOCAL/REMOTE 패널) — 클릭=그 브랜치만 보기(재클릭 해제), 섹션 접힘 가능 ──
      const sideName = (name) => {
        const cut = name.lastIndexOf('/');
        return cut < 0 ? `<span class="gs-leaf">${escapeHtml(name)}</span>`
          : `<span class="gs-pre">${escapeHtml(name.slice(0, cut + 1))}</span><span class="gs-leaf">${escapeHtml(name.slice(cut + 1))}</span>`;
      };
      const sideBadges = (b) => {
        let s = '';
        if (b.dirtyCount) s += `<span class="git-badge dirty" title="미커밋 변경 ${b.dirtyCount}개">●${b.dirtyCount}</span>`;
        if (!b.detached && !b.remote) {
          if (!b.upstream) s += `<span class="git-badge local" title="원격 추적 브랜치 없음 — 로컬 전용">L</span>`;
          else {
            if (b.aheadRemote) s += `<span class="git-badge push" title="미푸시 ${b.aheadRemote}커밋">↑${b.aheadRemote}</span>`;
            if (b.behindRemote) s += `<span class="git-badge pull" title="원격이 ${b.behindRemote}커밋 앞섬">↓${b.behindRemote}</span>`;
          }
        }
        if (b.merged) s += `<span class="git-badge ok" title="${escapeHtml(g.mainBranch)} 에 머지됨">✓</span>`;
        return s;
      };
      // 행 3종 — LOCAL=브랜치명(prefix 딤/폴더), REMOTE=구름 아이콘+짧은 이름, WORKTREES=워크트리 별칭 위주(브랜치 딤).
      const sideOpen = (k) => gitSideOpen[k] !== false;   // 미기록 키(폴더)는 기본 펼침
      // 행 아이콘 문법(섹션 구분, 형 재설계) — ⎇ 로컬 브랜치(레인색) · ☁ 원격 · ⌂ 워크트리(별칭=산세리프) · ⧉ 스태시
      const sideRow = (b, wt, indent) => {
        const key = b.remote ? gitShortRef(b.branch) : b.branch;
        const col = colorOf(b.branch);
        const marker = b.remote
          ? `<span class="gs-ic gs-cloud" style="color:${col}">${GIT_CLOUD}</span>`
          : wt ? `<span class="gs-ic" style="color:${col}">⌂</span>`
               : `<span class="gs-ic" style="color:${col}">⎇</span>`;
        const nm = b.remote ? gitShortRef(b.branch) : b.branch;
        const name = wt ? `<span class="gs-wtname">${escapeHtml(b.alias || b.branch)}</span>`
          : sideName(indent ? nm.slice(nm.indexOf('/') + 1) : nm);   // 폴더 안에선 접두 생략(폴더가 접두)
        const sub = wt ? `<span class="gs-alias">${escapeHtml(b.branch)}</span>` : '';
        return `<div class="gs-row${gitWtFilter === key ? ' active' : ''}${indent ? ' gs-in' : ''}" data-side-branch="${escapeHtml(key)}"${dndAttrs(b)}
            title="${escapeHtml(b.branch)}${b.alias ? ' — ' + escapeHtml(b.alias) : ''}${b.remote ? ' — 원격(origin)' : ''} — 클릭=이 브랜치만 보기(재클릭 해제)">
          ${marker}<span class="gs-name">${name}</span>${sub}${sideBadges(b)}</div>`;
      };
      // prefix 폴더 트리(크라켄) — 첫 세그먼트가 같은 브랜치 2개 이상이면 접힘 폴더로 묶는다
      const sideTree = (id, list, wt) => {
        const flat = [], groups = new Map();
        for (const b of list) {
          const nm = b.remote ? gitShortRef(b.branch) : b.branch;
          const cut = nm.indexOf('/');
          if (cut > 0) { if (!groups.has(nm.slice(0, cut))) groups.set(nm.slice(0, cut), []); groups.get(nm.slice(0, cut)).push(b); }
          else flat.push(b);
        }
        let out = flat.map(b => sideRow(b, wt)).join('');
        for (const [seg, items] of groups) {
          if (items.length < 2) { out += items.map(b => sideRow(b, wt)).join(''); continue; }
          const k = `${id}:${seg}`;
          out += `<div class="gs-folder" data-gs-toggle="${k}" title="${escapeHtml(seg)}/ 브랜치 ${items.length}개 — 접기/펼치기"><span class="gs-tw">${sideOpen(k) ? '▾' : '▸'}</span>${escapeHtml(seg)}/ <span class="gs-n">${items.length}</span></div>`;
          if (sideOpen(k)) out += items.map(b => sideRow(b, wt, true)).join('');
        }
        return out;
      };
      // 스태시 행(크라켄 STASHES) — refs/stash 는 레포 공유. 적용 타깃 = 그 브랜치가 체크아웃된 워크트리.
      const sideStash = (s) => {
        const b = g.branches.find(x => !x.remote && x.branch === s.branch);
        const col = s.branch && colorIdx.has(s.branch) ? colorOf(s.branch) : 'var(--sys-cont-neutral-lightest)';
        const short = s.msg.replace(/^(?:WIP on|On) [^:]+:\s*/, '');
        return `<div class="gs-row gs-stash" title="${escapeHtml(s.ref)} — ${escapeHtml(s.msg)}${b ? '' : ' · 브랜치 워크트리 없음(적용 불가, 삭제만)'}">
          <span class="gs-ic" style="color:${col}">⧉</span>
          <span class="gs-name">${s.branch ? `<span class="gs-pre">${escapeHtml(s.branch)}: </span>` : ''}<span class="gs-leaf">${escapeHtml(short)}</span></span>
          <span class="hov-acts gs-stash-acts">
            ${b ? `<button data-stash-apply data-ref="${escapeHtml(s.ref)}" data-root="${escapeHtml(b.root)}" title="${escapeHtml(b.branch)} 워크트리에 적용 — 스태시는 유지(충돌해도 안 사라짐)">적용</button>` : ''}
            <button data-stash-drop data-ref="${escapeHtml(s.ref)}" title="스태시 삭제 — 되돌릴 수 없음">✕</button></span></div>`;
      };
      const sideLocals = g.branches.filter(b => !b.remote && !b.detached);   // 브랜치 목록 — detached 는 워크트리 섹션에서만
      const sideRemotes = g.branches.filter(b => b.remote);
      const sideWts = g.branches.filter(b => !b.remote);                      // 워크트리 = 로컬 체크아웃 전부(detached 포함)
      const sideSect = (id, label, rowsHtml, n, extra) =>
        `<div class="gs-sect" data-gs-toggle="${id}"${extra || ''} title="접기/펼치기"><span class="gs-tw">${sideOpen(id) ? '▾' : '▸'}</span> ${label} <span class="gs-n">${n}</span></div>
         ${sideOpen(id) ? rowsHtml : ''}`;
      const sideHtml = `${gitWtFilter ? `<div class="gs-filterbar" title="브랜치 필터 작동 중"><span class="gs-fname">⎇ ${escapeHtml(gitWtFilter)}</span><button data-gs-clear title="필터 해제 — 전체 보기">✕</button></div>` : ''}
        ${sideSect('local', 'LOCAL', sideTree('local', sideLocals, false), sideLocals.length)}
        ${sideSect('remote', `<span title="origin 원격">REMOTE</span> <button class="gs-fetch" data-gs-fetch title="git fetch origin --prune — 원격 상태 갱신(로컬 브랜치는 안 건드림)">⇣</button><button class="gs-fetch gs-all${gitAllRemotes ? ' on' : ''}" data-gs-allremotes title="origin 브랜치 전체 보기 — 기본은 내 브랜치의 카운터파트(+main)만. 팀원 브랜치 구경용">전체</button>`, sideTree('remote', sideRemotes, false), sideRemotes.length, ' data-drop-remote=""')}
        ${sideSect('worktrees', 'WORKTREES', sideWts.map(b => sideRow(b, true)).join(''), sideWts.length)}
        ${(g.stashes || []).length ? sideSect('stashes', 'STASHES', g.stashes.map(sideStash).join(''), g.stashes.length) : ''}`;

      body.innerHTML = `<div class="git-split">
        <div class="git-side"${gitSideW ? ` style="width:${gitSideW}px"` : ''}>${sideHtml}</div>
        <div class="gs-rail" data-gs-rail title="드래그 = 좌측 트리 폭 조절 · 더블클릭 = 기본 폭"></div>
        <div class="git-rows-pane">
          <div class="git-graph-wrap" style="--git-graph-w:${gw}px">
            <div class="git-cols-head">
              <span class="gch-branch">BRANCH</span>
              <span class="git-graph-gap gch-graph">GRAPH</span><span class="gch-msg">COMMIT MESSAGE</span><span class="gch-sha">SHA</span></div>
            <svg class="git-graph-svg" width="${gw}" height="${rows.length * GIT_ROW_H}" aria-hidden="true"><defs><clipPath id="gav-clip" clipPathUnits="objectBoundingBox"><circle cx="0.5" cy="0.5" r="0.5"/></clipPath></defs>${svg}</svg>
            <div class="git-rows">${html}${timeMarks}</div>
          </div>
        </div>
        <div class="git-detail" data-git-detail hidden></div></div>`;
      body.querySelectorAll('[data-gs-toggle]').forEach(el => el.onclick = () => {
        const k = el.dataset.gsToggle;
        gitSideOpen[k] = !(gitSideOpen[k] ?? true);   // 미기록 키(폴더) 기본 펼침 → 첫 클릭에 접힘
        renderGitGraph(body, g);
      });
      body.querySelectorAll('[data-side-branch]').forEach(el => el.onclick = () => {
        const v = el.dataset.sideBranch;
        gitWtFilter = gitWtFilter === v ? '' : v;
        renderGitGraph(body, g);
      });
      const gsClear = body.querySelector('[data-gs-clear]');
      if (gsClear) gsClear.onclick = () => { gitWtFilter = ''; renderGitGraph(body, g); };
      // 스태시 적용/삭제 — 적용은 스태시를 보존(pop 아님)하므로 충돌해도 잃는 것 없음
      const stashAct = async (payload, what) => {
        try {
          await api('/api/git-stash', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ repo: g.repo, ...payload }) });
          document.querySelector('[data-git-refresh]')?.click();
        } catch (err) { alert(`${what} 실패: ${(err && err.message) || err}`); }
      };
      body.querySelectorAll('[data-stash-apply]').forEach(el => el.onclick = (e) => {
        e.stopPropagation();
        stashAct({ op: 'apply', root: el.dataset.root, ref: el.dataset.ref }, '스태시 적용');
      });
      body.querySelectorAll('[data-stash-drop]').forEach(el => el.onclick = (e) => {
        e.stopPropagation();
        if (confirm(`${el.dataset.ref} 스태시를 삭제할까요? 되돌릴 수 없어요.`)) stashAct({ op: 'drop', root: g.mainRoot, ref: el.dataset.ref }, '스태시 삭제');
      });
      // 좌측 트리 폭 드래그(형: 쫍다) — 레일 드래그로 조절, 더블클릭 리셋, localStorage 기억
      const sideEl = body.querySelector('.git-side');
      const rail = body.querySelector('[data-gs-rail]');
      if (rail) {
        rail.onmousedown = (e) => {
          e.preventDefault();
          const sx = e.clientX, sw = sideEl.getBoundingClientRect().width;
          const mv = (ev) => { gitSideW = Math.max(150, Math.min(520, Math.round(sw + ev.clientX - sx))); sideEl.style.width = gitSideW + 'px'; };
          const up = () => { document.removeEventListener('mousemove', mv); document.removeEventListener('mouseup', up); localStorage.setItem('gitSideW', String(gitSideW)); };
          document.addEventListener('mousemove', mv);
          document.addEventListener('mouseup', up);
        };
        rail.ondblclick = () => { gitSideW = 0; localStorage.removeItem('gitSideW'); sideEl.style.width = ''; };
      }
      const gsAll = body.querySelector('[data-gs-allremotes]');
      if (gsAll) gsAll.onclick = (e) => {
        e.stopPropagation();   // 섹션 접힘 토글로 안 번지게
        gitAllRemotes = !gitAllRemotes;
        localStorage.setItem('gitAllRemotes', gitAllRemotes ? '1' : '0');
        document.querySelector('[data-git-refresh]')?.click();   // all 은 캐시 키가 달라 새로 로드
      };
      const gsFetch = body.querySelector('[data-gs-fetch]');
      if (gsFetch) gsFetch.onclick = async (e) => {
        e.stopPropagation();   // 섹션 접힘 토글로 안 번지게
        gsFetch.disabled = true; gsFetch.textContent = '…';
        try {
          await api('/api/git-fetch', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root: g.mainRoot, repo: g.repo }) });
          document.querySelector('[data-git-refresh]')?.click();
        } catch (err) { alert(`fetch 실패: ${(err && err.message) || err}`); gsFetch.disabled = false; gsFetch.textContent = '⇣'; }
      };
      // ── D&D(크라켄) — 소스를 타깃에 드롭 → GitKraken 문법 메뉴(영어 전문 명령, 형). 실행 아닌 확정 메뉴 ──
      let dragSrc = null;
      const dTargets = () => [...body.querySelectorAll('[data-drop-remote],[data-drop-local]')];
      // 드롭 유효성 — 소스 로컬: 원격 타깃(rebase/push/pr)·다른 로컬(merge/rebase). 소스 원격: 로컬 타깃(pull/merge).
      const dropMode = (t) => {
        if (!dragSrc) return null;
        if (t.dataset.dropRemote !== undefined) return dragSrc.kind === 'local' ? 'onto-remote' : null;
        const y = t.dataset.dropLocal;
        if (dragSrc.kind === 'remote') return 'onto-local';
        return dragSrc.branch !== y ? 'onto-local' : null;
      };
      const dropAct = async (path, payload, what) => {
        try {
          await api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) });
          document.querySelector('[data-git-refresh]')?.click();
        } catch (err) { alert(`${what} failed: ${(err && err.message) || err}`); }
      };
      // 터미널로 타이핑되는 ref 는 셸 인용 필수 — git refname 에 ;·$·백틱 이 들어갈 수 있어(codex P2)
      const shq = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";
      const openPR = (base, head) => {
        if (!g.originSlug) { alert('GitHub 원격이 아니라 PR 을 열 수 없어요'); return; }
        window.open(`https://github.com/${g.originSlug}/compare/${encodeURIComponent(base)}...${encodeURIComponent(head)}?expand=1`, '_blank');
      };
      // GitKraken 문법 — 명령 전문(잘리지 않게 act-menu 폭 넓힘). 부제(한 줄)로 실제 동작 보강.
      const dropMenu = (t, mode, src) => {
        const items = [];
        const S = src.branch, Sshort = gitShortRef(S);
        if (mode === 'onto-remote') {
          const rref = t.dataset.dropRemote;                 // '' = REMOTE 섹션(=소스의 카운터파트로 취급)
          const target = `origin/${rref || Sshort}`;         // 항상 원격 추적 ref (로컬 main 과 구분 — 버그 방지)
          const isCounterpart = !rref || rref === Sshort;    // 소스 자신의 원격이냐
          if (!isCounterpart) {                              // 다른 원격(예: origin/main) 위로 rebase / PR
            items.push({ label: `Rebase ${S} onto ${target}`, sub: `git rebase ${target} — ${Sshort} 을 ${target} 뒤에 재적용(히스토리 재작성)`,
              run: () => dropAct('/api/git-rebase', { root: src.root, repo: g.repo, onto: target }, 'Rebase') });
            items.push({ label: `Interactive Rebase ${S} onto ${target}`, sub: `터미널에서 git rebase -i ${target} (squash·reorder)`,
              run: () => { if (typeof openTerminalCmd === 'function') openTerminalCmd(src.root, `git rebase -i ${shq(target)} `); } });
          }
          const canPush = isCounterpart && (!src.hasUp || src.ahead);
          if (canPush) {
            if (items.length) items.push({ divider: true });
            items.push({ label: `Push ${S} to ${target}`, sub: src.hasUp ? `git push — 미푸시 ${src.ahead}커밋` : `git push -u origin ${Sshort} — 첫 푸시`,
              run: () => dropAct('/api/git-push', { root: src.root, repo: g.repo }, 'Push') });
          }
          if (isCounterpart && src.hasUp && src.ahead && src.behind) {
            items.push({ label: `Force Push ${S} to ${target}`, sub: `git push --force-with-lease — 원격 ${src.behind}커밋 대체`,
              run: () => { if (confirm(`Force push: origin ${src.behind}커밋이 대체됩니다. 계속?`)) dropAct('/api/git-push', { root: src.root, repo: g.repo, force: true }, 'Force push'); } });
          }
          if (items.length) items.push({ divider: true });
          items.push({ label: `Start a pull request to ${target} from ${S}`, sub: 'GitHub compare 페이지 열기',
            run: () => openPR(rref || g.mainBranch, Sshort) });
        } else {                                             // onto-local
          const T = t.dataset.dropLocal, Troot = t.dataset.dropRoot;
          items.push({ label: `Merge ${S} into ${T}`, sub: `git merge ${S} — ${T} 워크트리에서(충돌 시 자동 abort)`,
            run: () => dropAct('/api/git-merge', { root: Troot, repo: g.repo, branch: S }, 'Merge') });
          if (src.kind === 'remote' && gitShortRef(S) === T) {   // 원격→카운터파트 로컬 = pull
            items.push({ label: `Pull ${S} into ${T}`, sub: `git pull --ff-only`, run: () => dropAct('/api/git-pull', { root: Troot, repo: g.repo }, 'Pull') });
            items.push({ label: `Pull (rebase) ${S} into ${T}`, sub: `git pull --rebase — 내 커밋을 위로 재적용`, run: () => dropAct('/api/git-pull', { root: Troot, repo: g.repo, rebase: true }, 'Pull rebase') });
          }
          if (src.kind === 'local') {                        // 로컬→로컬 = rebase 도(소스 워크트리에서)
            items.push({ label: `Rebase ${S} onto ${T}`, sub: `git rebase ${T} — ${S} 워크트리에서(히스토리 재작성)`,
              run: () => dropAct('/api/git-rebase', { root: src.root, repo: g.repo, onto: T }, 'Rebase') });
            items.push({ label: `Interactive Rebase ${S} onto ${T}`, sub: `터미널에서 git rebase -i ${T}`,
              run: () => { if (typeof openTerminalCmd === 'function') openTerminalCmd(src.root, `git rebase -i ${shq(T)} `); } });
          }
        }
        if (items.length && typeof openActMenu === 'function') openActMenu(t, items);
      };
      body.querySelectorAll('[data-drag-branch]').forEach(el => {
        el.addEventListener('dragstart', (e) => {
          dragSrc = { kind: el.dataset.dragKind, branch: el.dataset.dragBranch, root: el.dataset.dragRoot,
                      ahead: Number(el.dataset.dragAhead) || 0, behind: Number(el.dataset.dragBehind) || 0, hasUp: el.dataset.dragUp === '1' };
          e.dataTransfer.setData('text/plain', dragSrc.branch);
          e.dataTransfer.effectAllowed = 'copy';
          dTargets().forEach(t => { if (el !== t && dropMode(t)) t.classList.add('gd-droppable'); });
        });
        el.addEventListener('dragend', () => { dragSrc = null; dTargets().forEach(t => t.classList.remove('gd-droppable', 'gd-dropover')); });
      });
      dTargets().forEach(t => {
        t.addEventListener('dragover', (e) => { if (dropMode(t)) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; t.classList.add('gd-dropover'); } });
        t.addEventListener('dragleave', () => t.classList.remove('gd-dropover'));
        t.addEventListener('drop', (e) => {
          const mode = dropMode(t);
          if (!mode) return;
          e.preventDefault(); e.stopPropagation();
          const src = dragSrc; dragSrc = null;
          dTargets().forEach(x => x.classList.remove('gd-droppable', 'gd-dropover'));
          dropMenu(t, mode, src);
        });
      });
      // 브랜치 필 클릭 = 그 브랜치 레인만 필터 (hover 확장된 상태에서 누르는 자연스러운 다음 동작)
      body.querySelectorAll('[data-pill-branch]').forEach(el => el.onclick = (e) => {
        e.stopPropagation();
        gitWtFilter = gitWtFilter === el.dataset.pillBranch ? '' : el.dataset.pillBranch;   // 재클릭=해제
        renderGitGraph(body, g);
      });
      const selectRow = (el) => { body.querySelectorAll('.git-row.selected').forEach(x => x.classList.remove('selected')); el.classList.add('selected'); };
      body.querySelectorAll('[data-commit]').forEach(el =>
        el.onclick = () => { selectRow(el); gitShowCommitDetail(body.querySelector('[data-git-detail]'), g, el.dataset.commit, el.querySelector('.git-subject').textContent); });
      body.querySelectorAll('[data-wip-root]').forEach(el =>
        el.onclick = () => { selectRow(el); gitShowWipDetail(body.querySelector('[data-git-detail]'), g, el.dataset.wipRoot); });
      body.querySelectorAll('[data-tips]').forEach(el => el.onclick = (e) => {
        e.stopPropagation();   // 행 diff-open 으로 안 번지게
        const tips = tipOf.get(el.dataset.tips) || [];
        const items = [];
        for (const b of tips) {
          const remote = b.remote ? ' · 원격(origin)' : b.detached ? '' : !b.upstream ? ' · 로컬 전용' : (b.aheadRemote ? ` · ↑${b.aheadRemote} 미푸시` : '') + (b.behindRemote ? ` · ↓${b.behindRemote}` : '');
          const mark = `${remote}${b.merged ? ' · ✓ 머지됨' : ''}${b.mismatch && b.mismatch.length ? ' · ⚠ 불일치' : ''}`;
          const short = gitShortRef(b.branch);
          items.push({ label: `⎇ ${short}${b.alias && b.alias !== b.branch ? ' — ' + b.alias : ''}${mark}`,
                       run: () => { gitWtFilter = short; renderGitGraph(body, g); } });
          if (b.merged) items.push({ label: `　♻ 정리 — ${b.alias || b.branch} (워크트리 삭제)`,
                                     run: () => { if (typeof gitCleanupWorktree === 'function') gitCleanupWorktree(b.root, b.alias || b.branch, (b.dirtyCount || 0) + (b.untrackedCount || 0)); } });
        }
        if (typeof openActMenu === 'function') openActMenu(el, items);
      });
      body.querySelectorAll('[data-cleanup-root]').forEach(el => el.onclick = (e) => {
        e.stopPropagation();   // 부모 .git-row 의 diff-open 클릭으로 안 번지게
        if (typeof gitCleanupWorktree === 'function') gitCleanupWorktree(el.dataset.cleanupRoot, el.dataset.cleanupAlias, Number(el.dataset.cleanupDirty) || 0);
      });
    }

    // ── 우측 상세 패널 (GitKraken 우측 커밋 패널) — 행 클릭 = 메타+파일 목록, 파일 클릭 = 변경 탭 드릴인 ──
    async function gitShowCommitDetail(panel, g, hash, subjectHint) {
      if (!panel) return;
      panel.hidden = false;
      panel.innerHTML = '<div class="gd-empty">불러오는 중…</div>';
      let d;
      try { d = await api(`/api/git-commit-info?root=${enc(g.mainRoot)}&repo=${enc(g.repo)}&commit=${enc(hash)}`); }
      catch (e) { panel.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; return; }
      const [subject, ...rest] = (d.body || subjectHint || '').split('\n');
      const when = new Date(d.ts * 1000);
      const files = (d.files || []).map(f =>
        `<div class="gd-file" data-gd-file="${escapeHtml(f.name)}" title="클릭하면 변경 탭에서 이 파일 diff">
          <span class="gd-name">${escapeHtml(f.name)}</span>
          <span class="gd-stat"><i class="a">+${escapeHtml(f.add)}</i><i class="d">−${escapeHtml(f.del)}</i></span></div>`).join('');
      panel.innerHTML = `
        <button class="gd-x" data-gd-x title="상세 닫기">✕</button>
        <div class="gd-subject">${escapeHtml(subject)}</div>
        ${rest.join('\n').trim() ? `<div class="gd-body">${escapeHtml(rest.join('\n').trim())}</div>` : ''}
        <div class="gd-meta">${escapeHtml(d.author)} · ${when.toLocaleString('ko-KR', { month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit' })}
          · <button class="gd-hash" data-gd-copy title="클릭=전체 해시 복사">${d.hash.slice(0, 7)}</button></div>
        <div class="gd-files-head">파일 ${(d.files || []).length}개 — 클릭하면 diff</div>
        <div class="gd-files">${files || '<div class="gd-empty">변경 파일 없음</div>'}</div>`;
      panel.querySelector('[data-gd-x]').onclick = () => { panel.hidden = true; };
      panel.querySelector('[data-gd-copy]').onclick = async (e) => {
        try { await navigator.clipboard.writeText(d.hash); e.target.textContent = '복사됨'; setTimeout(() => { e.target.textContent = d.hash.slice(0, 7); }, 900); } catch {}
      };
      // 파일 클릭 = 전체 커밋 diff 오버레이를 "그 파일 눌린 상태"(포커스+스크롤)로 — 별도 전체 버튼 불필요(형)
      panel.querySelectorAll('[data-gd-file]').forEach(b => b.onclick = () =>
        gitShowDiffOverlay(panel.closest('.git-split'), { root: g.mainRoot, repo: g.repo, commit: d.hash, title: subject, focusFile: b.dataset.gdFile }));
    }
    async function gitShowWipDetail(panel, g, wipRoot) {
      if (!panel) return;
      panel.hidden = false;
      panel.innerHTML = '<div class="gd-empty">불러오는 중…</div>';
      let data;
      try { data = await api(`/api/git-wip-stat?root=${enc(wipRoot)}&repo=${enc(g.repo)}`); }
      catch (e) { panel.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; return; }
      const list = data.files || [];
      const b = (g.branches || []).find(x => x.root === wipRoot) || {};
      const canCommit = typeof gitCommitEligible === 'function' && gitCommitEligible({ root: wipRoot });
      // 크라켄 문법(형 확정): 선택(체크박스)·커밋 메시지·버튼 전부 이 우측 패널 소유. 오버레이는 읽기 전용 diff.
      const files = list.map(f => `<div class="gd-file" data-gd-file="${escapeHtml(f.name)}" title="${escapeHtml(f.name)} — 이름 클릭=diff, 체크=커밋 포함">
          ${canCommit ? `<input type="checkbox" class="git-stage-cb" data-stage-file="${escapeHtml(f.name)}" checked>` : ''}
          <span class="gd-name">${escapeHtml(f.name)}</span>
          <span class="gd-stat">${f.untracked ? '<i class="n">new</i>' : `<i class="a">+${escapeHtml(f.add)}</i><i class="d">−${escapeHtml(f.del)}</i>`}</span></div>`).join('');
      const repoName = g.repo === '.' ? ((g.mainRoot || '').split('/').pop() || 'root') : g.repo;
      const needPush = !b.detached && (b.upstream === false || (b.aheadRemote || 0) > 0);
      panel.innerHTML = `
        <button class="gd-x" data-gd-x title="상세 닫기">✕</button>
        <div class="gd-subject">● 미커밋 변경</div>
        <div class="gd-meta">커밋 대상: ${escapeHtml(repoName)} ⎇ ${escapeHtml(b.branch || '?')}${b.mismatch && b.mismatch.length ? ' <span class="git-badge warn" title="같은 워크트리의 다른 레포가 다른 브랜치 — 레포 탭별로 그 레포 브랜치에 커밋됩니다">⚠</span>' : ''}
          ${needPush ? `<button class="gd-push" data-gd-push title="${b.upstream === false ? '원격에 브랜치 없음 — 첫 푸시(-u origin)' : `미푸시 ${b.aheadRemote}커밋 푸시`}">↑ 푸시${b.aheadRemote ? ' ' + b.aheadRemote : ''}</button>` : ''}
          ${list.length ? `<button class="gd-push gd-stash" data-gd-stash title="변경 전부(untracked 포함)를 스태시로 치워두기 — 좌측 STASHES 에서 적용/삭제">⧉ 스태시</button>` : ''}
          <span class="git-commit-flash" data-diff-flash></span></div>
        <div class="gd-files-head">파일 ${list.length}개 — 이름 클릭=diff, 체크=커밋 포함</div>
        <div class="gd-files">${files || '<div class="gd-empty">변경 없음</div>'}</div>
        <div class="git-commit-slot" data-git-commit-slot></div>`;
      panel.querySelector('[data-gd-x]').onclick = () => { panel.hidden = true; };
      panel.querySelectorAll('.git-stage-cb').forEach(cb => cb.onclick = (e) => e.stopPropagation());   // 체크는 diff 안 엶
      panel.querySelectorAll('[data-gd-file]').forEach(b2 => b2.onclick = () =>
        gitShowDiffOverlay(panel.closest('.git-split'), { root: wipRoot, repo: g.repo, title: '미커밋 변경', focusFile: b2.dataset.gdFile }));
      const stashBtn = panel.querySelector('[data-gd-stash]');
      if (stashBtn) stashBtn.onclick = async () => {
        const memo = prompt('스태시 메모 (선택 — 비워도 됩니다)', '');
        if (memo === null) return;   // 취소
        stashBtn.disabled = true; stashBtn.textContent = '스태시 중…';
        try {
          await api('/api/git-stash', { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ op: 'save', root: wipRoot, repo: g.repo, message: memo }) });
          document.querySelector('[data-git-refresh]')?.click();
        } catch (e2) {
          stashBtn.disabled = false; stashBtn.textContent = '⧉ 스태시';
          const f = panel.querySelector('[data-diff-flash]'); if (f) f.textContent = `스태시 실패: ${(e2 && e2.message) || e2}`;
        }
      };
      const pushBtn = panel.querySelector('[data-gd-push]');
      if (pushBtn) pushBtn.onclick = async () => {
        pushBtn.disabled = true; pushBtn.textContent = '푸시 중…';
        try {
          await api('/api/git-push', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root: wipRoot, repo: g.repo }) });
          document.querySelector('[data-git-refresh]')?.click();
          gitShowWipDetail(panel, g, wipRoot);
        } catch (e) { pushBtn.disabled = false; pushBtn.textContent = '↑ 푸시'; const f = panel.querySelector('[data-diff-flash]'); if (f) f.textContent = `푸시 실패: ${(e && e.message) || e}`; }
      };
      if (canCommit && typeof gitRenderCommitPanel === 'function') {
        gitRenderCommitPanel(panel, { root: wipRoot, repo: g.repo }, list.filter(f => !f.untracked).map(f => f.name),
          list.filter(f => f.untracked).map(f => f.name), () => gitShowWipDetail(panel, g, wipRoot));
      }
    }

    // ── diff 오버레이 — 깃 탭 안에서 그래프 자리를 덮고 ✕/Esc 로 복귀(탭 점프·뒤로가기 문제 해소, 형 확정) ──
    async function gitShowDiffOverlay(splitEl, opts) {
      const pane = splitEl && splitEl.querySelector('.git-rows-pane');
      if (!pane) return;
      let ov = pane.querySelector('.git-diff-overlay');
      if (!ov) { ov = document.createElement('div'); ov.className = 'git-diff-overlay'; pane.appendChild(ov); }
      ov.innerHTML = `<div class="gdo-head"><button class="gdo-x" title="닫기(Esc) — 그래프로">✕</button>
          <span class="gdo-title">${escapeHtml(opts.title || 'diff')}${opts.file ? ' · ' + escapeHtml(opts.file) : ''}</span>
          <span class="git-commit-flash" data-diff-flash></span>
          ${opts.commit ? `<span class="git-when">${escapeHtml(opts.commit.slice(0, 7))}</span>` : ''}</div>
        <div class="gdo-body">불러오는 중…</div>`;
      const close = () => { ov.remove(); document.removeEventListener('keydown', onKey); };
      const onKey = (e) => { if (e.key === 'Escape') close(); };
      ov.querySelector('.gdo-x').onclick = close;
      document.addEventListener('keydown', onKey);
      const q = `root=${enc(opts.root)}&repo=${enc(opts.repo)}` + (opts.commit ? `&commit=${enc(opts.commit)}` : '') + (opts.file ? `&file=${enc(opts.file)}` : '');
      const wip = !opts.commit && !opts.file;   // WIP 전체 = 스테이징+커밋 폼(wipMode)
      try {
        // 라인 수(파일 목록용)는 diff 와 병렬로 — wip=git-wip-stat(untracked 포함), commit=git-commit-info. 실패해도 목록은 뜸
        const statP = wip ? api(`/api/git-wip-stat?root=${enc(opts.root)}&repo=${enc(opts.repo)}`).catch(() => null)
          : opts.commit ? api(`/api/git-commit-info?root=${enc(opts.root)}&repo=${enc(opts.repo)}&commit=${enc(opts.commit)}`).catch(() => null)
          : Promise.resolve(null);
        const [d, statData] = await Promise.all([api(`/api/git-diff?${q}`), statP]);
        const stats = {};
        let untracked = [];
        for (const f of (statData && statData.files) || []) {
          stats[f.name] = f;
          if (f.untracked) untracked.push(f.name);
        }
        const ovBody = ov.querySelector('.gdo-body');
        gitRenderDiffInto(ovBody, d, { root: opts.root, repo: opts.repo, commit: opts.commit || undefined, file: opts.file || undefined, title: opts.title }, untracked, stats);
        if (opts.focusFile) {   // 상세에서 누른 파일 — 목록에서 하이라이트 + 그 섹션으로 스크롤("눌린 상태로 띄움")
          const fbtn = [...ovBody.querySelectorAll('.git-file')].find(b => b.title === opts.focusFile || b.dataset.untracked === opts.focusFile);
          if (fbtn) { fbtn.classList.add('focus'); if (fbtn.dataset.goto !== undefined) fbtn.click(); }
        }
      } catch (e) { ov.querySelector('.gdo-body').innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; }
    }

    // 패치 렌더 — 에디터식 거터(구/신 라인 넘버 + ± 마커)와 본문 분리(형: 라인수·유격).
    // hunk 헤더(@@ -a,b +c,d @@)에서 카운터를 세팅, add=신번호·del=구번호·context=둘 다.
    function gitRenderPatchLines(lines) {
      let oldN = 0, newN = 0, inHunk = false;
      return lines.map(ln => {
        let cls = '', o = '', n = '', mark = '', body = ln;
        if (ln.startsWith('diff --git') || ln.startsWith('commit ')) { cls = 'file'; inHunk = false; }
        else if (ln.startsWith('+++') || ln.startsWith('---')) cls = 'meta';
        else if (ln.startsWith('@@')) {
          cls = 'hunk'; inHunk = true;
          const m = ln.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
          if (m) { oldN = +m[1]; newN = +m[2]; }
        } else if (inHunk && ln.startsWith('+')) { cls = 'add'; n = newN++; mark = '+'; body = ln.slice(1); }
        else if (inHunk && ln.startsWith('-')) { cls = 'del'; o = oldN++; mark = '−'; body = ln.slice(1); }
        else if (inHunk && ln.startsWith('\\')) cls = 'meta';
        else if (inHunk) { o = oldN++; n = newN++; body = ln.slice(1); }
        else cls = 'meta';
        const gutter = (cls === '' || cls === 'add' || cls === 'del')
          ? `<span class="ln">${o}</span><span class="ln">${n}</span><span class="lm">${mark}</span>` : '';
        return `<div class="dl ${cls}${gutter ? ' code' : ''}" data-ln>${gutter}<span class="lc">${escapeHtml(body) || '&nbsp;'}</span></div>`;
      }).join('');
    }

    // gitRenderDiffInto — diff 본문(파일목록+patch, wipMode 면 커밋 폼 슬롯까지)을 컨테이너에 렌더.
    // gitShowDiffOverlay 가 fetch 한 뒤 호출(순수 렌더). 모달(D2)→변경 탭(D3)→오버레이로 수렴.
    function gitRenderDiffInto(el, d, opts, untracked, stats) {
      // 파일 단위 섹션 분해 → 좌측 파일 목록(2개 이상일 때) + 우측 본문 — 한 요청으로 전부
      // wipMode(P2) = 커밋 없는 워킹트리 전체 보기(진입점) — 여기서만 stage 체크박스 + 커밋 폼(app-8b) 노출.
      const wipMode = !opts.commit && !opts.file;   // WIP 전체 보기(untracked 목록 동반) — 읽기 전용. 커밋은 우측 패널(크라켄 문법, 형 확정)
      const body = d.text.replace(/\n$/, '');
      const lines = body ? body.split('\n') : [];   // 빈 diff → [''] 가 되면 '변경 없음' 대신 빈 줄이 그려짐
      const files = [];
      lines.forEach((ln, i) => { const m = ln.match(/^diff --git a\/.* b\/(.*)$/); if (m) files.push({ name: m[1], start: i }); });
      const colored = gitRenderPatchLines(lines);
      const fileRow = (inner) => inner;
      // 파일 행 = 이름 + 라인 수(+n −n / new 배지) — '+ ' 접두는 diff 기호와 헷갈려 폐지(형)
      const statHtml = (name, isNew) => {
        if (isNew) return '<span class="gd-stat"><i class="n">new</i></span>';
        const s = stats && stats[name];
        return s ? `<span class="gd-stat"><i class="a">+${escapeHtml(s.add)}</i><i class="d">−${escapeHtml(s.del)}</i></span>` : '';
      };
      const list = files.map(f => fileRow(`<div class="git-file" data-goto="${f.start}" title="${escapeHtml(f.name)}"><span class="gf-name">${escapeHtml(f.name)}</span>${statHtml(f.name, false)}</div>`)).join('')
        + (untracked || []).map(f => fileRow(`<div class="git-file" data-untracked="${escapeHtml(f)}" title="${escapeHtml(f)} — untracked, 클릭해 내용 보기"><span class="gf-name">${escapeHtml(f)}</span>${statHtml(f, true)}</div>`)).join('');
      el.innerHTML = `<div class="git-diff-main">${(wipMode || (files.length + (untracked || []).length) > 1 || (untracked || []).length > 0) ? `<div class="git-files">${list}</div>` : ''}
        <div class="git-patch">${d.truncated ? '<div class="git-err">⚠ 200KB 초과 — 절단됨</div>' : ''}${colored || '<div class="git-sub" style="padding:12px">변경 없음</div>'}</div></div>`;
      // 파일 클릭 문법 통일 — 좌측 목록·커밋 폼은 항상 유지, 우측 패치 영역만 반응:
      // tracked = (untracked 로 바꿔치기됐었다면 원복 후) 해당 섹션 스크롤 / untracked = 패치 영역만 그 파일 내용으로 교체
      const focusMark = (b) => { el.querySelectorAll('.git-file.focus').forEach(x => x.classList.remove('focus')); b.classList.add('focus'); };
      el.querySelectorAll('[data-goto]').forEach(b => b.onclick = () => {
        focusMark(b);
        const patch = el.querySelector('.git-patch');
        if (el.__origPatch != null) { patch.innerHTML = el.__origPatch; el.__origPatch = null; }
        const t = el.querySelectorAll('[data-ln]')[Number(b.dataset.goto)];
        if (t) t.scrollIntoView({ block: 'start' });
      });
      el.querySelectorAll('[data-untracked]').forEach(b => b.onclick = async () => {
        focusMark(b);
        const patch = el.querySelector('.git-patch');
        if (!patch) return;
        if (el.__origPatch == null) el.__origPatch = patch.innerHTML;   // 첫 교체 전 원본 보관 — tracked 클릭 시 원복
        patch.innerHTML = '불러오는 중…';
        try {
          const fd = await api(`/api/git-diff?root=${enc(opts.root)}&repo=${enc(opts.repo)}&file=${enc(b.dataset.untracked)}`);
          const fl = fd.text.replace(/\n$/, '');
          patch.innerHTML = (fd.truncated ? '<div class="git-err">⚠ 200KB 초과 — 절단됨</div>' : '')
            + (fl ? gitRenderPatchLines(fl.split('\n')) : '<div class="git-sub" style="padding:12px">변경 없음</div>');
        } catch (e) { patch.innerHTML = `<div class="git-err">${escapeHtml(e.message)}</div>`; }
      });
    }
