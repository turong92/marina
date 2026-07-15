    // app-10-term.js — 터미널 탭 뷰: 사이드바(세션 목록) · 그리드(1~4칸 분할) · D&D 배치.
    // 개념 셋: 세션(백엔드 PTY, TermIO 가 소유) / 인스턴스(세션당 xterm, 칸에서 빠져도 살아있음)
    //          / 칸(그리드 슬롯, 어느 세션을 그릴지만 지정).
    // 이 파일은 HTTP 를 모른다 — 백엔드는 전부 TermIO(app-10b) 경유.
    // 전역 공유(classic script): escapeHtml/worktreeData(app-3-util), selectedProjectId(app-1-core),
    //   WS_VIEWS/setWsTab/wsActive(app-6-modals), gitMainRoot(app-8-git), TermIO(app-10b-term-io),
    //   Terminal/FitAddon(vendor-xterm*) — index.html 이 이 파일보다 먼저 싣는다.
    const TERM_LAYOUTS = { '1': [1, 1], 'lr': [2, 1], 'tb': [1, 2], '4': [2, 2] };
    const termLayoutKey = 'marinaTermLayout';
    let termLayout = '1';
    let termSlots = [null, null, null, null];   // 칸 index → tid | null
    let termFocus = 0;                          // 활성 칸 — 사이드바 클릭이 여기로 간다
    const termInsts = new Map();                // tid → {term, fit, ro, el, opened, head} — 세션 종료 때까지 유지
    const termDirty = new Set();                // 칸에 안 떠 있는데 출력이 온 tid → 활동 닷
    let termPending = null;                     // openAgentTerminal/openTerminalCmd 가 심는 1회성 컨텍스트
    let termPane = null;
    let termOpening = 0;                        // termNewShell 한복판인 셸 수 — 그 안에선 termPlace 가 어차피 그린다
                                                // (boolean 이면 먼저 끝난 open 의 finally 가 남의 probe 창을 열어둔 채 푼다)
    let termNewWtSig = null;                    // 마지막으로 그린 새 셸 드롭다운 내용 — 같으면 DOM 을 안 건드린다
    const termSideWKey = 'marinaTermSideW';     // 사이드바 폭(px) — 0/없음이면 CSS 기본(200px)
    let termSideW = Number(localStorage.getItem(termSideWKey)) || 0;

    function termTheme() {
      const cs = getComputedStyle(document.documentElement);
      const v = (name, fb) => (cs.getPropertyValue(name) || '').trim() || fb;
      return { background: v('--sys-bg-surface', '#101318'), foreground: v('--sys-cont-neutral-default', '#d8dee6'),
               cursor: v('--sys-cont-primary-default', '#7aa2f7'), selectionBackground: 'rgba(122,162,247,0.3)' };
    }
    // 다크/라이트 전환 실시간 반영 — 인스턴스 전부 순회(예전엔 termInst 하나만 갱신했다)
    new MutationObserver(() => { termInsts.forEach(i => { i.term.options.theme = termTheme(); }); })
      .observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });

    function termSaveLayout() {
      try { localStorage.setItem(termLayoutKey, JSON.stringify({ layout: termLayout, slots: termSlots, focus: termFocus })); } catch {}
    }
    function termLoadLayout() {
      try {
        const d = JSON.parse(localStorage.getItem(termLayoutKey) || 'null');
        if (!d) return;
        if (TERM_LAYOUTS[d.layout]) termLayout = d.layout;
        if (Array.isArray(d.slots)) termSlots = [0, 1, 2, 3].map(i => d.slots[i] || null);
        if (typeof d.focus === 'number' && d.focus >= 0 && d.focus < 4) termFocus = d.focus;
        // 저장값이 서로 안 맞아도(layout 만 깨져 기본 '1' 인데 focus=3) 없는 칸을 가리키면 안 된다 —
        // termNewShell 이 그 칸의 DOM 을 찾다가 null 을 만진다.
        if (termFocus >= termSlotCount()) termFocus = 0;
      } catch {}
    }
    const termSlotCount = () => TERM_LAYOUTS[termLayout][0] * TERM_LAYOUTS[termLayout][1];
    const termSlotOf = (tid) => termSlots.indexOf(tid);
    const termVisible = (tid) => { const i = termSlotOf(tid); return i >= 0 && i < termSlotCount(); };

    // ── 라벨 — 같은 root 안에서 created 오름차순 N번째 = "셸 N". 에이전트는 CC/CX 칩 + 세션 제목. ──
    function termWtLabel(root) {
      const w = (typeof worktreeData !== 'undefined' ? worktreeData : []).find(x => x.root === root);
      if (!w) return (root || '').split('/').pop();
      if (w.source === 'main' || w.isMain) return `${w.projectLabel || 'main'} (main)`;
      return w.alias || (w.root || '').split('/').pop();
    }
    // 에이전트 세션 제목은 백엔드 term-list 가 주지 않는다(백엔드는 UI 제목을 몰라도 된다) —
    // worktreeData 의 agents({source,title,ts,sid})에서 sid 로 찾는다. 거기 없으면(최근 3개·7일 캡을
    // 벗어난 오래된 세션) 36자 UUID 를 178px 칼럼에 흘리지 않게 앞 8자로 줄인다.
    // 이름은 "지금 뭐가 돌고 있나" — tmux 가 창 이름을 실행 중인 프로그램으로 짓는 것과 같은 이유다.
    // "셸 1" 은 셋을 늘어놨을 때 어느 게 어느 건지 하나도 안 알려준다(형). 유휴일 때만 셸 N 으로 떨어진다.
    function termLabel(s) {
      if (s.agent) {
        const w = (typeof worktreeData !== 'undefined' ? worktreeData : []).find(x => x.root === s.root);
        const a = ((w && w.agents) || []).find(x => x.sid === s.agent.sid);
        return (a && a.title) || s.agent.sid.slice(0, 8);
      }
      if (s.fg) return s.fg;                 // 실행 중인 명령 — `npm run dev` 처럼 바로 알아본다
      if (s.cmd) return s.cmd;               // 안 돌고 있으면 마지막으로 친 명령이 그 세션의 정체다
      // 아무것도 안 친 새 셸일 때만 여기까지 온다
      const peers = TermIO.list().filter(x => x.root === s.root && !x.agent).sort((a, b) => a.created - b.created);
      return `셸 ${peers.findIndex(x => x.tid === s.tid) + 1}`;
    }

    // ── 인스턴스 — 처음 칸에 배치될 때 생성(xterm 은 attach 된 요소에 open 해야 치수가 잡힌다) ──
    // 만들기와 tid 등록을 가른 이유: 새 셸은 tid 를 **알기 전에** 인스턴스를 만들어 fit 해야 한다
    // (term-open 에 실을 cols/rows 를 재려고). termNewShell 참조.
    function termMakeInst() {
      const el = document.createElement('div');
      el.className = 'term-wrap';
      const term = new Terminal({ fontSize: 12.5, fontFamily: 'ui-monospace, Menlo, monospace', cursorBlink: true,
                                  scrollback: 5000, theme: termTheme(), allowProposedApi: true });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);
      return { term, fit, el, ro: null, opened: false, head: '', sentCols: 0, sentRows: 0 };
    }
    function termAdoptInst(tid, inst) {   // tid 를 알았다 — 등록하고 io 에 붙인다
      termInsts.set(tid, inst);
      inst.term.onData(d => TermIO.send(tid, d));
      TermIO.attach(tid, (bytes, isSnap) => { if (isSnap) inst.term.reset(); inst.term.write(bytes); });
      return inst;
    }
    function termEnsureInst(tid) {        // 이미 있는 세션을 칸에 처음 올릴 때
      return termInsts.get(tid) || termAdoptInst(tid, termMakeInst());
    }
    function termDisposeInst(tid) {
      const inst = termInsts.get(tid);
      if (!inst) return;
      TermIO.detach(tid);
      try { inst.ro && inst.ro.disconnect(); } catch {}
      try { inst.term.dispose(); } catch {}
      termInsts.delete(tid);
    }
    // 인스턴스 수명 한 규칙(D6 + 에러처리): 살아있는 세션의 인스턴스는 칸에서 빠져도 유지한다 —
    // 재진입이 재생 없이 즉시여야 하니까. 반대로 **죽은** 세션의 인스턴스는 칸에 떠 있는 동안만 살려둔다:
    // 종료 문구·스크롤백을 읽으라고 남기는 것이고, 칸에서 빠지면 볼 사람이 없으니 정리한다
    // (안 그러면 exit 마다 xterm + 스크롤백 5000줄 + ResizeObserver 가 영원히 샌다).
    function termSweepDead() {
      for (const tid of [...termInsts.keys()]) {
        if (!TermIO.get(tid) && !termVisible(tid)) termDisposeInst(tid);
      }
      // 세션도 인스턴스도 없는 tid 의 닷은 그릴 자리가 없다 — kill 마다 Set 이 자라지 않게 버린다
      // (tid 는 재사용되지 않으니 정확성 문제는 아니고 순수 누적이다).
      for (const tid of [...termDirty]) {
        if (!TermIO.get(tid) && !termInsts.has(tid)) termDirty.delete(tid);
      }
    }

    // fit 은 크기가 같으면 스스로 no-op 이지만 term-resize 는 아니다 — TIOCSWINSZ 는 **크기가 같아도**
    // 셸에 SIGWINCH 를 쏘고, zsh 는 그때마다 프롬프트를 다시 그린다. 렌더가 3초 폴링으로 도니까
    // 무조건 보내면 3초마다 화면이 한 줄씩 먹혔다(형: "핑쪽 한줄씩 지워져 계속" — 실측 10초에 9번).
    // 그래서 **실제로 바뀐 값만** 보낸다.
    function termSyncSize(tid, inst) {
      inst.fit.fit();
      const { cols, rows } = inst.term;
      if (inst.sentCols === cols && inst.sentRows === rows) return;
      inst.sentCols = cols;
      inst.sentRows = rows;
      TermIO.resize(tid, cols, rows);
    }

    function termPlace(slot, tid) {
      if (slot < 0 || slot >= termSlotCount()) return;
      if (!tid || !TermIO.get(tid)) return;         // 사이드바 밖에서 끌어온 텍스트·이미 죽은 세션은 칸에 못 넣는다
      const dup = termSlots.indexOf(tid);           // 이미 다른 칸에 있으면 옮긴다(중복 배치 금지)
      if (dup >= 0 && dup !== slot) termSlots[dup] = null;
      termSlots[slot] = tid;
      termFocus = slot;
      termDirty.delete(tid);
      termSaveLayout();
      termRender();
    }
    // 사이드바 클릭의 배치 규칙 — 새 셸(termNewShell)과 **같은 규칙**이어야 한다.
    // 예전엔 클릭이 무조건 활성 칸에 꽂아서, 4분할에 빈 칸이 셋이나 있는데도 세션을 누를 때마다
    // 같은 칸을 덮어썼다(형: "셸 누를 때마다 터미널 위치가 이상하다").
    //   이미 떠 있으면 → 옮기지 말고 그 칸에 포커스만(자기 터미널을 자기가 옮기는 꼴이 된다)
    //   빈 칸 있으면 → 거기 (칸을 채워나가는 게 분할의 목적)
    //   꽉 찼으면 → 활성 칸 교체 (그때는 형이 어디를 바꿀지 이미 골라둔 것)
    function termOpenSlotFor(tid) {
      const shown = tid ? termSlotOf(tid) : -1;   // tid 없음(새 셸) — indexOf(null) 이 빈 칸을 집는 걸 우연에 안 맡긴다
      if (shown >= 0 && shown < termSlotCount()) return shown;
      const empty = termSlots.slice(0, termSlotCount()).indexOf(null);
      return empty >= 0 ? empty : termFocus;
    }
    function termSetLayout(name) {
      if (!TERM_LAYOUTS[name]) return;
      termLayout = name;
      for (let i = termSlotCount(); i < 4; i++) termSlots[i] = null;   // 줄어든 칸의 배치는 버린다(세션은 유지)
      if (termFocus >= termSlotCount()) termFocus = 0;
      termSaveLayout();
      termRender();
    }

    // 열기 전에 칸을 정하고 그 칸 크기로 xterm 을 먼저 만들어 fit 한다 — cols/rows 를 term-open 에 실어야
    // 하기 때문. 에이전트 attach 는 `claude --resume` 이 즉시 TUI 를 그리는데, 80x24 로 열면 그 하드랩이
    // 스크롤백에 **영구히 구워져** 이후 모든 snap 이 그걸 재생한다(SIGWINCH 는 라이브 화면만 고친다).
    async function termNewShell(root, agent) {
      const slot = termOpenSlotFor(null);   // 사이드바 클릭과 같은 규칙 — 규칙이 두 곳이면 또 갈라진다
      const probe = termMakeInst();                                    // tid 없이 먼저 — 치수만 재려고
      const body = termPane.querySelector(`[data-term-cell="${slot}"] .term-cell-body`);
      body.innerHTML = '';
      body.appendChild(probe.el);
      probe.term.open(probe.el);
      probe.opened = true;
      probe.fit.fit();
      let tid;
      // open 안의 refresh 가 'sessions' 훅으로 렌더를 끼워넣으면, probe 는 칸에 붙었는데 tid 는 아직 슬롯에
      // 없어 빈 칸 문구가 probe 를 잠깐 들어냈다 termPlace 가 도로 붙인다(깜빡임). 그 한 구간만 접어둔다.
      try { termOpening++; tid = await TermIO.open(root, agent, probe.term.cols, probe.term.rows); }
      catch (e) { try { probe.term.dispose(); } catch {} alert(e.message); termRender(); return null; }
      finally { termOpening--; }
      // 에이전트 attach 는 백엔드가 살아있는 세션을 재사용한다(resume 이중 실행 방지) — 그 tid 에 인스턴스가
      // 이미 있으면 probe 를 버리고 그걸 쓴다. 덮어쓰면 옛 xterm 이 dispose 없이 새고 스크롤백도 함께 사라진다.
      if (termInsts.has(tid)) { try { probe.term.dispose(); } catch {} }
      else {
        probe.sentCols = probe.term.cols;   // term_open 이 이 치수로 열었다 — 중복 SIGWINCH 방지
        probe.sentRows = probe.term.rows;
        termAdoptInst(tid, probe);                                     // 이제 tid 를 알았으니 그 이름으로 등록
      }
      termPlace(slot, tid);
      // 열자마자 죽은 세션(에이전트 CLI 즉사 → open 안의 refresh 가 이미 수거)은 배치가 거절된다 —
      // 그럼 probe 만 칸에 남아 아무도 안 치운다. 한 번 그려 칸을 정리하고 인스턴스도 sweep 에 태운다.
      if (!termVisible(tid)) termRender();
      return tid;
    }

    // ── 골격 — 1회만. 이후엔 사이드바 목록·그리드 내용만 갱신. ──
    // `＋ 새 셸` select 는 사이드바 **맨 위**에 둔다. 하단에 고정했더니 세션이 두어 개일 때 목록과 버튼
    // 사이가 텅 비어 손이 안 갔다(형: "새셸도 저 맨밑에 있으면 못쓰지 위에 있어야지").
    // 목록과 가른 이유는 그대로 — termRenderSide 가 목록 영역을 innerHTML 로 통째로 다시 그리므로
    // select 를 그 안에 두면 매 렌더마다 날아가고, 형이 열어둔 드롭다운이 발밑에서 닫힌다.
    function termEnsureShell(pane) {
      if (pane.querySelector('[data-term-side]')) return;
      termNewWtSig = null;   // 골격을 새로 만들면 select 도 빈 채로 새로 생긴다 — 캐시를 안 비우면 영영 안 채워진다
      pane.innerHTML = `<div class="term-root">
          <div class="term-side" data-term-side>
            <div class="term-side-head">
              <select data-term-new-wt title="새 셸을 열 워크트리"></select>
            </div>
            <div class="term-side-list" data-term-side-list></div>
          </div>
          <div class="term-rail" data-term-rail title="드래그 = 사이드바 폭 조절 · 더블클릭 = 기본 폭"></div>
          <div class="term-main">
            <div class="term-bar">
              <button data-term-lay="1" title="분할 없음">▭</button>
              <button data-term-lay="lr" title="좌우 2분할">▯▯</button>
              <button data-term-lay="tb" title="상하 2분할">⊟</button>
              <button data-term-lay="4" title="4분할">⊞</button>
              <span class="git-head-fill"></span>
            </div>
            <div class="term-grid" data-term-grid></div>
          </div></div>`;
      pane.querySelectorAll('[data-term-lay]').forEach(b => { b.onclick = () => termSetLayout(b.dataset.termLay); });
      // 사이드바 폭 드래그 — 깃 탭 gs-rail 과 같은 패턴(드래그·더블클릭 리셋·localStorage 기억).
      // 200px 는 이름+부제 기준의 기본값일 뿐이라 형 화면·명령 길이에 따라 조절이 필요하다.
      const sideEl = pane.querySelector('[data-term-side]');
      const rail = pane.querySelector('[data-term-rail]');
      rail.onmousedown = (e) => {
        e.preventDefault();                       // 드래그 중 텍스트 선택 방지
        const sx = e.clientX, sw = sideEl.getBoundingClientRect().width;
        const mv = (ev) => {
          termSideW = Math.max(140, Math.min(420, Math.round(sw + ev.clientX - sx)));
          sideEl.style.width = termSideW + 'px';
        };
        const up = () => {
          document.removeEventListener('mousemove', mv);
          document.removeEventListener('mouseup', up);
          localStorage.setItem(termSideWKey, String(termSideW));
        };
        document.addEventListener('mousemove', mv);
        document.addEventListener('mouseup', up);
      };
      rail.ondblclick = () => { termSideW = 0; localStorage.removeItem(termSideWKey); sideEl.style.width = ''; };
      if (termSideW) sideEl.style.width = termSideW + 'px';   // 복원
      pane.querySelector('[data-term-new-wt]').onchange = (e) => {
        const root = e.target.value;
        e.target.value = '';
        if (root) termNewShell(root, null);
      };
    }

    function termRenderSide() {
      const side = termPane.querySelector('[data-term-side-list]');
      const wts = [...new Set(TermIO.list().map(s => s.root))];
      side.innerHTML = wts.map(root => {
        const rows = TermIO.list().filter(s => s.root === root).sort((a, b) => a.created - b.created).map(s => {
          const slot = termSlotOf(s.tid);
          const badge = termVisible(s.tid) ? `<span class="term-slot-badge">${'①②③④'[slot]}</span>` : '';
          const dot = termDirty.has(s.tid) ? '<span class="term-dot"></span>' : '';
          const chip = s.agent ? `<span class="agent-src ${s.agent.source === 'codex' ? 'codex' : 'claude'}">${s.agent.source === 'codex' ? 'CX' : 'CC'}</span>` : '';
          const cls = `term-item${termVisible(s.tid) ? ' shown' : ''}${slot === termFocus && termVisible(s.tid) ? ' focus' : ''}`;
          // 부제 = 마지막으로 의미 있는 출력(백엔드가 빈 프롬프트를 걸러 준다). 없으면 줄 자체를 안 만든다 —
          // 빈 줄이 남으면 항목 높이만 들쭉날쭉해진다. 이름과 같으면(아직 출력이 없는 명령 — `sleep 90` 은
          // 마지막 줄이 방금 친 그 명령이다) 같은 말을 두 번 하지 않는다.
          const name = termLabel(s);
          const sub = s.preview && s.preview !== name
            ? `<div class="term-sub" title="${escapeHtml(s.preview)}">${escapeHtml(s.preview)}</div>` : '';
          return `<div class="${cls}" draggable="true" data-term-item="${escapeHtml(s.tid)}" title="${escapeHtml(s.root)}">
              <div class="term-item-top">${dot}${chip}${badge}<span class="nm">${escapeHtml(name)}</span>
                <span class="x" data-term-kill="${escapeHtml(s.tid)}" title="세션 종료 — 프로세스까지 내립니다">✕</span></div>
              ${sub}</div>`;
        }).join('');
        return `<div class="term-grp">${escapeHtml(termWtLabel(root))}</div>${rows}`;
      }).join('') || '<div class="term-hint">열린 셸이 없어요 — 아래에서 워크트리를 고르면 새 셸이 열려요.</div>';
      side.querySelectorAll('[data-term-item]').forEach(el => {
        el.onclick = (e) => {
          if (e.target.closest('[data-term-kill]')) return;
          const tid = el.dataset.termItem;
          termPlace(termOpenSlotFor(tid), tid);      // 새 셸과 같은 규칙 — 빈 칸부터 채운다
        };
        el.ondragstart = (e) => { e.dataTransfer.setData('text/plain', el.dataset.termItem); };
      });
      // 사이드바 ✕ = 세션 종료(프로세스까지). 칸 ✕(칸 비우기)와 의미가 다르다 — 헷갈리면 dev 서버가 죽는다.
      side.querySelectorAll('[data-term-kill]').forEach(el => {
        el.onclick = async (e) => {
          e.stopPropagation();
          const tid = el.dataset.termKill;
          termDisposeInst(tid);
          const i = termSlots.indexOf(tid);
          if (i >= 0) termSlots[i] = null;
          termSaveLayout();
          await TermIO.kill(tid);   // 목록에서 빠지는 건 kill 안의 refresh → 'sessions' 훅이 그린다
        };
      });
    }

    function termRenderGrid(grid) {
      const [cols, rows] = TERM_LAYOUTS[termLayout];
      grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
      grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;
      const n = termSlotCount();
      for (let i = grid.children.length; i < n; i++) {
        const cell = document.createElement('div');
        cell.className = 'term-cell';
        cell.dataset.termCell = String(i);
        cell.innerHTML = '<div class="term-cell-head"><span class="nm"></span><span class="x" title="칸 비우기 — 세션은 살아있어요">✕</span></div><div class="term-cell-body"></div>';
        cell.onmousedown = () => { if (termFocus !== Number(cell.dataset.termCell)) { termFocus = Number(cell.dataset.termCell); termSaveLayout(); termRender(); } };
        cell.ondragover = (e) => { e.preventDefault(); cell.classList.add('drop'); };
        cell.ondragleave = () => cell.classList.remove('drop');
        cell.ondrop = (e) => { e.preventDefault(); cell.classList.remove('drop'); termPlace(Number(cell.dataset.termCell), e.dataTransfer.getData('text/plain')); };
        cell.querySelector('.x').onclick = (e) => {
          e.stopPropagation();
          termSlots[Number(cell.dataset.termCell)] = null;   // 칸만 비움 — 세션·인스턴스는 유지
          termSaveLayout();
          termRender();
        };
        grid.appendChild(cell);
      }
      while (grid.children.length > n) grid.removeChild(grid.lastChild);

      [...grid.children].forEach((cell, i) => {
        cell.classList.toggle('focus', i === termFocus);
        const tid = termSlots[i];
        const s = tid ? TermIO.get(tid) : null;
        const head = cell.querySelector('.term-cell-head .nm');
        const body = cell.querySelector('.term-cell-body');
        // 세션도 인스턴스도 없으면 빈 칸. 세션은 죽었는데 인스턴스가 남아 있으면 그대로 그린다 —
        // 종료 문구·스크롤백을 읽으라고 남긴 것이다(칸 ✕ 로 빼면 termSweepDead 가 정리한다).
        if (!s && !termInsts.has(tid)) {
          head.textContent = '';
          body.innerHTML = '<div class="term-hint">사이드바에서 셸을 끌어다 놓거나 클릭하세요</div>';
          return;
        }
        const inst = termEnsureInst(tid);
        if (s) inst.head = `${termWtLabel(s.root)} · ${termLabel(s)}`;   // 죽은 뒤엔 라벨을 못 만든다 — 살아있을 때 캐시
        head.textContent = s ? inst.head : `${inst.head} · 종료됨`;
        if (inst.el.parentElement !== body) { body.innerHTML = ''; body.appendChild(inst.el); }
        if (!inst.opened) { inst.term.open(inst.el); inst.opened = true; }
        if (s) termSyncSize(tid, inst);
        if (!inst.ro) {
          inst.ro = new ResizeObserver(() => {
            if (!inst.el.isConnected || !TermIO.get(tid)) return;   // 죽은 세션에 WINSZ 를 보낼 이유가 없다
            termSyncSize(tid, inst);
          });
          inst.ro.observe(inst.el);
        }
        if (i === termFocus) inst.term.focus();
      });
    }

    // 매 렌더 불리지만 **내용이 실제로 바뀔 때만** DOM 을 다시 만든다. 양쪽 다 실패하는 길이라 멱등이 답이다:
    // 그냥 다시 그리면 형이 열어둔 드롭다운이 발밑에서 닫히고, 반대로 termRender 밖으로 빼면(탭 진입 때만)
    // 첫 진입이 worktreeData 폴링(웜 ~1s·콜드 >3s)을 앞질렀을 때 플레이스홀더만 남고 **영영 안 채워진다** —
    // 터미널 탭은 형이 앉아 있는 곳이라 "다시 들어오면 고쳐짐" 이 성립하지 않는다.
    // 서명은 만들어진 HTML 자체다 — 필드 목록을 손으로 꼽으면(root 만 등) selectedProjectId 전환에
    // "현재 프로젝트 우선"(D7)이 안 따라오는 걸 놓친다.
    function termRenderNewWt(sel) {
      const wts = (typeof worktreeData !== 'undefined' ? worktreeData : []);
      const cur = typeof selectedProjectId !== 'undefined' ? selectedProjectId : null;
      const mine = wts.filter(w => !cur || w.projectId === cur);
      const rest = wts.filter(w => cur && w.projectId !== cur);
      // 라벨 중복(예: ~/.codex/worktrees/<id>/mdc-main 들) — 부모 디렉토리를 붙여 구분
      const labels = wts.map(w => termWtLabel(w.root));
      const disp = (w) => {
        const l = termWtLabel(w.root);
        if (labels.filter(x => x === l).length < 2) return l;
        const seg = (w.root || '').split('/').filter(Boolean);
        return `${seg[seg.length - 2] || ''}/${l}`;
      };
      const opts = (arr) => arr.map(w => `<option value="${escapeHtml(w.root)}">${escapeHtml(disp(w))}</option>`).join('');
      const html = `<option value="">＋ 새 셸…</option>${opts(mine)}${rest.length ? `<optgroup label="다른 프로젝트">${opts(rest)}</optgroup>` : ''}`;
      if (termNewWtSig === html) return;
      termNewWtSig = html;
      sel.innerHTML = html;
      sel.value = '';
    }

    function termRender() {
      if (!termPane) return;
      termEnsureShell(termPane);
      // 지금 어느 분할인지 버튼에 표시 — 없으면 형이 4분할 버튼을 눌렀는지 알 방법이 없다
      termPane.querySelectorAll('[data-term-lay]').forEach(b => b.classList.toggle('on', b.dataset.termLay === termLayout));
      termSweepDead();
      termRenderSide();
      termRenderGrid(termPane.querySelector('[data-term-grid]'));
      termRenderNewWt(termPane.querySelector('[data-term-new-wt]'));   // 멱등 — 내용이 바뀔 때만 DOM 을 만진다
    }

    // 활동 닷 — 인스턴스 유무와 무관하게 한 규칙: 칸에 안 떠 있는 세션에 출력이 오면 켜고, 배치되면 끈다.
    // snap 은 재생된 과거지 새 출력이 아니라 무시한다(인스턴스를 붙이는 순간 자기 자신에 닷이 켜진다).
    TermIO.on('activity', (tid, isSnap) => {
      if (isSnap || termVisible(tid) || termDirty.has(tid)) return;
      termDirty.add(tid);
      if (termPane) termRenderSide();
    });
    // 세션 목록이 바뀌면 그린다 — refresh 를 부르는 자리가 전부 뷰인 건 아니다. SSE 가 끊긴 사이 PTY 가
    // 죽으면(노트북 sleep·marina-control 재시작·네트워크 blip) 재연결은 살아있는 tid 만 구독하므로 그 세션의
    // exit 은 **영영 안 온다**. io 의 백오프 재시도(scheduleRetry→refresh)가 목록을 바로잡아도 뷰가 안 그리면
    // 유령 행이 남고, 눌러도 termPlace 가 조용히 거절해 피드백이 0 이다. 그 경로를 이 훅이 닫는다.
    TermIO.on('sessions', () => { if (!termOpening) termRender(); });
    TermIO.on('exit', (tid) => {
      const inst = termInsts.get(tid);
      if (inst) inst.term.write('\r\n\x1b[2m[세션 종료됨]\x1b[0m\r\n');
      termDirty.delete(tid);
      // 목록에서 빠진다 — 칸에 떠 있으면 스크롤백을 읽게 남기고, 아니면 termSweepDead 가 인스턴스를 거둔다.
      // 그리는 건 refresh 안의 'sessions' 훅이다(.then 으로 또 그리면 exit 마다 렌더가 두 번).
      // catch 는 렌더용이 아니라 unhandled rejection 막이 — 목록 갱신 실패는 io 의 백오프가 다시 시도한다.
      TermIO.refresh().catch(() => {});
    });

    // 바깥(깃 탭·AGENTS 행)에서 터미널 탭으로 들어오는 유일한 문 — 컨텍스트를 심고 탭을 띄운다.
    // setWsTab 이 탭을 **실제로 바꾸면** 그 안에서 WS_VIEWS.term.activate(→termActivate)가 이미 불리고,
    // 이미 그 탭이면 no-op 이라 아무도 안 부른다(app-6-modals.js:548). 그래서 전환 여부를 **미리** 재야 한다 —
    // 뒤에서 wsActive 를 보면 항상 'term' 이라 termActivate 가 두 번 돌고, 둘 다 termPending 을 집어
    // 셸이 두 개 열린다. 사본이 하나뿐이어야 이 미묘한 순서를 한 곳에서만 지킨다.
    function termOpenPending(root, agent, cmd) {
      termPending = { root, agent, cmd };
      const alreadyOn = typeof wsActive !== 'undefined' && wsActive === 'term';
      if (typeof setWsTab === 'function') setWsTab('term');
      if (alreadyOn) termActivate(document.getElementById('tab-term'));
    }
    // 깃 D&D Interactive Rebase → 터미널에서 실행(웹 UI 로는 대화형 편집 불가, PTY 가 에디터를 띄운다).
    // 그 워크트리 셸을 열고 명령을 타이핑까지만(엔터는 사용자 — 안전).
    function openTerminalCmd(root, cmd) { termOpenPending(root, null, cmd); }
    // AGENTS 행 → 터미널 attach 진입점 (오르카 문법 — 좌측 패널과 연동)
    function openAgentTerminal(root, agent) { termOpenPending(root, agent, null); }

    async function termActivate(pane) {
      if (typeof Terminal === 'undefined') { pane.innerHTML = '<div class="git-err" style="padding:14px">xterm 로드 실패 — 새로고침 해보세요</div>'; return; }
      termPane = pane;
      termEnsureShell(pane);
      // 탭에 들어올 때마다 갱신 — 그 사이 워크트리가 생겼을 수 있다. termEnsureShell 은 1회뿐이라
      // 거기서만 그리면 첫 진입이 worktreeData 폴링보다 빨랐을 때 드롭다운이 영영 빈 채로 남는다.
      termRenderNewWt(pane.querySelector('[data-term-new-wt]'));
      // refresh 가 실패해도(marina-control 재시작 창) 렌더는 무조건 한다 — 안 그리면 칸이 0개라
      // 살아있는 `＋ 새 셸` 을 누르는 순간 termNewShell 이 없는 칸을 찾아 터지고, 빈 상태 힌트조차 안 뜬다.
      // io 가 스스로 재무장하므로 목록은 곧 따라온다(sessions 훅이 다시 그린다).
      try { await TermIO.refresh(); } catch {}
      // 복원: 죽은 tid 가 물린 칸은 비운다(localStorage 는 배치만, 세션 목록은 백엔드가 진실)
      termSlots = termSlots.map(t => (t && TermIO.get(t) ? t : null));
      termRender();
      const p = termPending; termPending = null;
      if (p) {
        const tid = await termNewShell(p.root, p.agent);
        if (tid && p.cmd) setTimeout(() => TermIO.send(tid, p.cmd), 1200);   // 셸 기동(-il rc 로드) 여유
      } else if (!termSlots.some(Boolean) && !TermIO.list().length) {
        const r = typeof gitMainRoot === 'function' ? gitMainRoot() : null;
        if (r) await termNewShell(r, null);                                  // 첫 진입 — 빈 화면 대신 셸 하나
      }
    }

    termLoadLayout();
    // 사이드바 이름(실행 중인 명령)·부제(마지막 출력)는 백엔드만 아는 값이라 목록을 다시 받아야 신선하다.
    // **탭이 보일 때만** 돈다 — fg 는 세션마다 ps 를 부르고, 다른 탭에 있는 동안 그걸 돌릴 이유가 없다.
    // (connect() 의 no-op 가드 덕에 이 폴링이 SSE 를 끊지 않는다 — 없으면 3초마다 재연결한다.)
    const TERM_POLL_MS = 3000;
    let termPollTimer = null;
    function termStopPoll() { clearInterval(termPollTimer); termPollTimer = null; }
    function termStartPoll() {
      termStopPoll();
      termPollTimer = setInterval(() => {
        if (document.hidden) return;             // 백그라운드 창 — 창이 안 보이면 이름도 안 보인다
        TermIO.refresh().catch(() => {});        // sessions 훅이 다시 그린다. 실패는 io 가 재무장.
      }, TERM_POLL_MS);
    }
    // 탭 이탈(deactivate)에도 구독은 유지 — 백그라운드 출력은 백엔드 링버퍼에 쌓이고 인스턴스가 받아쓴다.
    // 멈추는 건 라벨 폴링뿐이다.
    WS_VIEWS.term = {
      activate(pane) { termActivate(pane); termStartPoll(); },
      deactivate() { termStopPoll(); },
    };
