    // app-8b-git-commit.js — 깃 탭 '조작' 확장(P2): WIP 커밋/푸시 폼 · 머지된 워크트리 정리.
    // app-8-git.js(읽기 전용 그래프) 다음 로드. 전역 공유: api/enc/escapeHtml(app-3), worktreeData(app-1),
    // gitRenderDiffInto(app-8) — 이 파일은 app-8 이 호출하는 훅(gitRenderCommitPanel·gitCleanupWorktree)만 정의.
    // alert 금지(커밋 폼) — 에러는 폼 안 인라인(.git-commit-err), 성공은 변경 탭 헤드의 flash 줄(app-8c 가 슬롯 마련, D3).

    function gitCommitEligible(opts) {   // 등록된 root 면 커밋 가능 — main 포함(보호 해제, 형 확정 2026-07-13)
      return !!worktreeData.find(w => w.root === opts.root);
    }

    function gitCommitFlash(diffBodyEl, text) {   // 성공줄 — 가까운 flash 슬롯(우측 패널/오버레이 헤더) 우선, 없으면 pane 레벨
      const scope = diffBodyEl.closest('.git-detail, .git-diff-overlay, .ws-pane');
      const flash = scope && scope.querySelector('[data-diff-flash]');
      if (flash) flash.textContent = text;
    }

    async function gitDiffRefresh(diffBodyEl, opts) {   // WIP 커밋/푸시 후 diff-body 재조회(제목 등은 유지, 탭은 안 닫음)
      let d, untracked = [];
      try {
        d = await api(`/api/git-diff?root=${enc(opts.root)}&repo=${enc(opts.repo)}`);
        const wc = await api(`/api/worktree-changes?root=${enc(opts.root)}`);
        const entry = (wc.repos || []).find(r => opts.repo === '.' ? r.path === opts.root : r.name === opts.repo);
        untracked = (entry ? entry.changes || [] : []).filter(l => l.startsWith('??')).map(l => l.slice(3));
      } catch (e) { return; }
      gitRenderDiffInto(diffBodyEl, d, opts, untracked);
    }

    function gitRenderCommitPanel(diffBodyEl, opts, fileNames, untrackedNames, onDone) {
      const slot = diffBodyEl.querySelector('[data-git-commit-slot]');
      if (!slot) return;
      const allFiles = [...fileNames, ...untrackedNames];
      if (!gitCommitEligible(opts) || !allFiles.length) { slot.innerHTML = ''; return; }   // main/미해당/커밋할 것 없음 — 폼 숨김
      slot.innerHTML = `<div class="git-commit-form">
        <textarea class="git-commit-msg-input" data-commit-msg placeholder="커밋 메시지 — 첫 줄 요약, 빈 줄 후 본문" maxlength="2000" rows="4"></textarea>
        <div class="git-commit-actions">
          <button type="button" class="primary" data-git-commit>커밋</button>
          <button type="button" data-git-commit-push>커밋+푸시</button>
        </div>
        <div class="git-commit-err" data-git-commit-err></div>
      </div>`;
      const msgInput = slot.querySelector('[data-commit-msg]');
      const errEl = slot.querySelector('[data-git-commit-err]');
      const btns = () => [...slot.querySelectorAll('button')];
      const doCommit = async (alsoPush) => {
        errEl.textContent = '';
        const checked = [...diffBodyEl.querySelectorAll('[data-stage-file]:checked')].map(cb => cb.dataset.stageFile);
        const message = msgInput.value.trim();
        if (!checked.length) { errEl.textContent = '커밋할 파일을 하나 이상 선택하세요'; return; }
        if (!message) { errEl.textContent = '커밋 메시지를 입력하세요'; return; }
        btns().forEach(b => b.disabled = true);
        try {
          const r = await api('/api/git-commit', { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ root: opts.root, repo: opts.repo, files: checked, message }) });
          let flash = `✓ 커밋 ${(r.hash || '').slice(0, 7)} — ${r.summary || message}`;
          if (alsoPush) {
            try {
              await api('/api/git-push', { method: 'POST', headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ root: opts.root, repo: opts.repo }) });
              flash += ' · 푸시됨';
            } catch (pe) {
              flash += ` · 푸시 실패: ${(pe && pe.message) || pe}`;
            }
          }
          gitCommitFlash(diffBodyEl, flash);
          const refreshBtn = document.querySelector('[data-git-refresh]');
          if (refreshBtn) refreshBtn.click();   // 그래프 새로고침(캐시 무시) — loadGitGraphInto(..., true) 배선을 그대로 재사용
          if (onDone) await onDone();           // 우측 패널 모드 — 패널 재렌더(남은 변경·flash 유지)
          else await gitDiffRefresh(diffBodyEl, opts);
        } catch (e) {
          errEl.textContent = String((e && e.message) || e);
          btns().forEach(b => b.disabled = false);
        }
      };
      slot.querySelector('[data-git-commit]').onclick = () => doCommit(false);
      slot.querySelector('[data-git-commit-push]').onclick = () => doCommit(true);
    }

    // ✓ 머지됨 [정리] — 기존 /api/remove-worktree 흐름 재사용(app-5-sessions.js 의 removeWorktreeFlow 와 동일 API,
    // 여기선 그래프 칩의 root 하나로 충분해 별도 session/wt 객체 없이 바로 호출). 파괴적이라 confirm 1회는 유지.
    async function gitCleanupWorktree(root, alias, dirtyTotal) {
      let force = false;
      if (dirtyTotal > 0) {
        if (!confirm(`'${alias}' 에 미커밋 변경·untracked 파일이 있어요(${dirtyTotal}건).\n폐기하고 정리할까요? (브랜치는 이미 머지되어 보존 불필요)`)) return;
        force = true;
      } else if (!confirm(`'${alias}' 워크트리를 정리할까요? (머지된 브랜치 — 삭제 후 되돌릴 수 없음)\n${root}`)) {
        return;
      }
      try {
        await api('/api/remove-worktree', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, force }) });
      } catch (e) {
        alert(`정리 실패: ${(e && e.message) || e}`);
        return;
      }
      const refreshBtn = document.querySelector('[data-git-refresh]');
      if (refreshBtn) refreshBtn.click();
    }
