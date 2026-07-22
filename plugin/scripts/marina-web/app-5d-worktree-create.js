    // app-5d-worktree-create.js — A4: 대시보드에서 워크트리 생성.
    // [+ 워크트리] 버튼(선택 프로젝트 컨텍스트) → 인라인 팝오버(브랜치명 입력) → POST /api/worktree-create(백엔드가 marina worktree create CLI 재사용).
    // 성공: 팝오버 닫고 목록 새로고침 + 새 카드 2s flash(app-5 pendingFlashRoot 소비) + 토스트. 실패: 팝오버 안 인라인 에러(alert 금지).

    let wtCreateOpen = false;

    function closeWtCreate() {
      wtCreateOpen = false;
      const pop = document.getElementById('wtCreatePop');
      if (pop) pop.remove();
    }

    function openWtCreate() {
      if (wtCreateOpen) { closeWtCreate(); return; }   // 토글 — 다시 누르면 닫힘
      const projectId = selectedProjectId;
      if (!projectId) { showToast('먼저 프로젝트를 선택하세요', 'err'); return; }
      wtCreateOpen = true;
      const bar = document.getElementById('worktreeCreateBtn').closest('.sessions-bar');
      const pop = document.createElement('div');
      pop.className = 'wt-create-pop';
      pop.id = 'wtCreatePop';
      pop.innerHTML = `
        <input type="text" id="wtCreateBranch" placeholder="브랜치명 (예: feature/foo)" autocomplete="off" />
        <div class="register-error" id="wtCreateError" hidden></div>
        <div class="wt-create-pop-actions"><button id="wtCreateSubmit">만들기</button></div>
      `;
      bar.appendChild(pop);
      const input = pop.querySelector('#wtCreateBranch');
      input.focus();

      const submit = async () => {
        const branch = input.value.trim();
        const err = pop.querySelector('#wtCreateError');
        err.hidden = true;
        if (!branch) { err.textContent = '브랜치명을 입력하세요'; err.hidden = false; return; }
        const btn = pop.querySelector('#wtCreateSubmit');
        const label = btn.textContent;
        btn.disabled = true; btn.innerHTML = BUSY_DOTS;
        let res;
        try {
          res = await api('/api/worktree-create', {
            method: 'POST', headers: {'content-type': 'application/json'},
            body: JSON.stringify({ projectId, branch }),
          });
        } catch (e) {
          err.textContent = String(e.message || e); err.hidden = false;
          btn.disabled = false; btn.textContent = label;
          return;   // 팝오버 유지 — 브랜치명 고쳐 재시도
        }
        closeWtCreate();
        await loadWorktrees(true);   // discover_all_roots 캐시 강제 재탐색(새 워크트리 즉시 반영)
        await load({ force: true });
        pendingFlashRoot = res.root; // app-5 render() 가 소비 — 새 카드 2s 하이라이트
        render();
        showToast('워크트리 생성됨 — attach 완료', 'ok');
      };
      pop.querySelector('#wtCreateSubmit').onclick = submit;
      input.onkeydown = (e) => {
        if (e.key === 'Enter') { e.preventDefault(); submit(); }
        else if (e.key === 'Escape') { e.preventDefault(); closeWtCreate(); }
      };
    }

    document.getElementById('worktreeCreateBtn').onclick = (e) => { e.stopPropagation(); openWtCreate(); };
    document.addEventListener('click', (e) => {
      if (wtCreateOpen && !e.target.closest('.wt-create-pop') && !e.target.closest('#worktreeCreateBtn')) closeWtCreate();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && wtCreateOpen) closeWtCreate();
    });
