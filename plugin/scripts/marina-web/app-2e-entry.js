    // ── 등록 진입 — 레포 후보 화면 (R1) ─────────────────────────────────────────
    // 스펙: docs/superpowers/specs/2026-07-11-register-workbench-design.md R1
    // '처음 설정해요' 카드가 여는 화면. 관례 루트(존재하는 것만) 2단계 스캔 결과(GET /api/repo-candidates,
    // 버튼 트리거 — 자동 아님)를 근거 뱃지와 함께 나열, 항목 클릭 = openWorkbench({root, mode:'new'}).
    // 경로 직접 입력 + 찾아보기(기존 browsePanel, app-1-core.js) 를 항상 같이 노출.
    let candScanResult = null;   // 마지막 /api/repo-candidates 응답 { candidates, scanned }

    function openCandidates() {
      document.getElementById('registerTitle').textContent = '처음 설정해요 — 레포 고르기';
      document.getElementById('candPath').value = '';
      document.getElementById('candStatus').hidden = true;
      document.getElementById('candList').innerHTML = '';
      candScanResult = null;
      setRegisterView('candidates');
    }

    function candStatus(kind, text) {   // 인라인 상태 — alert 금지(형 규칙)
      const el = document.getElementById('candStatus');
      if (!el) return;
      if (!text) { el.hidden = true; return; }
      el.hidden = false;
      el.className = 'cand-status svc-llm-progress ' + kind;
      el.innerHTML = '<span>' + escapeHtml(text) + '</span>';
    }

    function candRow(c) {
      const row = document.createElement('div');
      row.className = 'cand-row' + (c.registered ? ' registered' : '');
      const badges = [
        '<span class="cand-badge git">git</span>',
        c.hasCompose ? '<span class="cand-badge compose">compose</span>' : '',
        c.registered ? '<span class="cand-badge reg">등록됨</span>' : '',
      ].filter(Boolean).join('');
      row.innerHTML = `
        <span class="cand-name">${escapeHtml(c.name)}</span>
        <span class="cand-path" title="${escapeHtml(c.path)}">${escapeHtml(c.path)}</span>
        <span class="cand-badges">${badges}</span>`;
      if (c.registered) {
        row.title = '이미 등록된 프로젝트예요 — 프로젝트 전환에서 선택하세요';
      } else {
        row.classList.add('clickable');
        row.title = '클릭하면 이 경로로 워크벤치가 열려요';
        row.onclick = () => openWorkbench({ root: c.path, mode: 'new' });
      }
      return row;
    }

    function renderCandidates() {
      const list = document.getElementById('candList');
      const scope = document.getElementById('candScanScope');
      list.innerHTML = '';
      const r = candScanResult;
      if (!r) return;
      scope.textContent = r.scanned.length
        ? ('스캔 범위 — ' + r.scanned.join(' · ') + ' (2단계까지)')
        : '스캔 범위 — 관례 루트(~/IdeaProjects 등)를 찾지 못했어요. 아래 경로 직접 입력을 쓰세요.';
      if (!r.candidates.length) {
        const empty = document.createElement('div');
        empty.className = 'cand-empty';
        empty.textContent = 'git 레포 후보를 못 찾았어요 — 위에서 경로를 직접 입력하세요.';
        list.appendChild(empty);
        return;
      }
      for (const c of r.candidates) list.appendChild(candRow(c));
    }

    async function candScan() {
      const btn = document.getElementById('candScanBtn');
      if (btn) { btn.disabled = true; btn.textContent = '찾는 중…'; }
      candStatus('run', '후보 찾는 중…');
      try {
        candScanResult = await api('/api/repo-candidates');
        renderCandidates();
        candStatus('', '');
      } catch (e) {
        candStatus('err', String((e && e.message) || e));
      }
      if (btn) { btn.disabled = false; btn.textContent = '🔍 후보 찾기'; }
    }

    (function wireCandidates() {
      const scanBtn = document.getElementById('candScanBtn');
      if (scanBtn) scanBtn.onclick = candScan;
      const browseBtn = document.getElementById('candBrowse');
      if (browseBtn) browseBtn.onclick = () => {
        browseMode = 'candidates';
        document.getElementById('registerCandidates').appendChild(document.getElementById('browsePanel'));
        openBrowse(document.getElementById('candPath').value.trim() || '');
      };
      const goBtn = document.getElementById('candGo');
      if (goBtn) goBtn.onclick = () => {
        const root = document.getElementById('candPath').value.trim();
        if (!root) { candStatus('err', '프로젝트 경로를 입력하세요'); return; }
        openWorkbench({ root, mode: 'new' });
      };
    })();
