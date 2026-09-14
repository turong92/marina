    // app-5e-worktree-gc.js — 유휴 워크트리 일괄 정리(선택 삭제).
    //
    // 배경(2026-09-14 실측): 워크트리 28개 중 22개가 세션·프로세스 0, 마지막 커밋 2~9주 전. 워크트리당
    // 1.5~8GB + 이미지 3~6GB × 서비스 수가 남고, 감시 파일 폭증으로 fseventsd 가 4.5GB·CPU 100% 로 39일.
    // 판정·가드는 백엔드(marina_worktree_gc)가 한다 — 여기선 계획(GET /api/worktree-gc)을 표로 보여 주고
    // 골라서 POST 한다. 자동 삭제 없음: 사람이 체크하고 누른 것만 지운다.

    function gcGb(mb) { return `${((Number(mb) || 0) / 1024).toFixed(1)}GB`; }

    function gcRowHtml(item, preselectRoot) {
      const eligible = !!item.eligible;
      const checked = eligible && !!preselectRoot && item.root === preselectRoot;   // 칩에서 열면 그것만 미리 체크. 🧹 에서 열면 아무것도 — 대량 삭제의 기본값이 '전부'면 실수 한 번의 파급이 크다(리뷰 지적)
      const label = escapeHtml(item.alias || item.id);
      const reasons = (item.reasons || []).map(r => `<span class="gc-reason">✗ ${escapeHtml(r)}</span>`).join('');
      const backups = (item.backups || []).map(b =>
        `<span class="gc-backup">↳ 보존 ${escapeHtml(b.subrepo || 'root')} → ${escapeHtml(b.branch)} (${escapeHtml(b.why || '')})</span>`).join('');
      const ahead = Number(item.aheadTotal) > 0 ? `<span class="gc-backup">↑ 미머지 커밋 ${item.aheadTotal} — 브랜치는 보존됨(-d 거부)</span>` : '';
      return `<tr class="${eligible ? '' : 'ineligible'}" data-gc-root="${escapeHtml(item.root)}">
        <td><input type="checkbox" data-gc-pick ${eligible ? '' : 'disabled'} ${checked ? 'checked' : ''}></td>
        <td><b>${label}</b> <span class="sid-sub">${escapeHtml(item.projectId || '')}</span>
          <div class="sid-sub" title="${escapeHtml(item.root)}">${escapeHtml(item.root)}</div>${ahead}${backups}${reasons}</td>
        <td class="num">${Math.round(item.gcIdleDays || 0)}일</td>
        <td class="num">${gcGb(item.diskMb)}</td>
        <td class="num">${gcGb(item.imageMb)}</td>
      </tr>`;
    }

    async function openWorktreeGc(preselectRoot) {
      const ex = document.getElementById('gcModalBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'gcModalBack'; back.className = 'modal-backdrop'; back.style.zIndex = '200';
      back.innerHTML = `<div class="links-modal">
        <div class="links-modal-head"><strong>🧹 유휴 워크트리 정리</strong><button class="links-modal-x" title="닫기">✕</button></div>
        <div class="config-label">유휴 = <b>붙은 세션 0</b> · <b>cwd 프로세스 0</b> · <b>마지막 커밋과 파일 변경 모두 <span data-gc-days-label>14</span>일 초과</b>.
          삭제 전에 detached HEAD·원격에 없는 서브레포 커밋은 메인 클론에 <code>backup/worktree-…</code> 브랜치로 보존하고,
          서브레포 밖 untracked/미커밋이 있으면 대상에서 뺀다(사유 표시). 삭제 시 그 워크트리의 compose 이미지·볼륨도 회수.</div>
        <div data-gc-body>불러오는 중…</div>
        <div class="gc-foot">
          <label class="gc-sum">기준 <input type="number" min="1" data-gc-days value="14"> 일 <button data-gc-reload title="다시 계산">↻</button></label>
          <span class="gc-sum" data-gc-sum></span>
          <button class="gc-run" data-gc-run disabled>선택 삭제</button>
        </div>
        <div class="gc-result" data-gc-result hidden></div>
      </div>`;
      document.body.appendChild(back);
      const close = () => back.remove();
      back.querySelector('.links-modal-x').onclick = close;
      const body = back.querySelector('[data-gc-body]');
      const runBtn = back.querySelector('[data-gc-run]');
      const sumEl = back.querySelector('[data-gc-sum]');
      const daysInput = back.querySelector('[data-gc-days]');
      let items = [];

      const picked = () => Array.from(body.querySelectorAll('tr[data-gc-root]'))
        .filter(tr => tr.querySelector('[data-gc-pick]')?.checked)
        .map(tr => items.find(i => i.root === tr.dataset.gcRoot)).filter(Boolean);
      const updateSum = () => {
        const sel = picked();
        const mb = sel.reduce((a, i) => a + (Number(i.diskMb) || 0) + (Number(i.imageMb) || 0), 0);
        sumEl.textContent = sel.length ? `${sel.length}개 선택 · 회수 예상 ${gcGb(mb)}` : '선택 없음';
        runBtn.disabled = sel.length === 0;
        runBtn.textContent = sel.length ? `선택 삭제 (${sel.length})` : '선택 삭제';
      };

      const loadPlan = async () => {
        body.textContent = '불러오는 중…'; runBtn.disabled = true;
        const days = Math.max(1, Number(daysInput.value) || 14);
        let data;
        try { data = await api(`/api/worktree-gc?days=${days}&refresh=1`); }
        catch (e) { body.innerHTML = `<div class="register-error">${escapeHtml(String((e && e.message) || e))}</div>`; return; }
        items = data.items || [];
        back.querySelector('[data-gc-days-label]').textContent = String(data.days || days);
        if (!items.length) { body.innerHTML = `<div class="config-label">유휴 워크트리 없음 (기준 ${data.days || days}일)</div>`; updateSum(); return; }
        body.innerHTML = `<table class="gc-table"><thead><tr>
            <th><input type="checkbox" data-gc-all title="가능한 것 전체 선택/해제 — 직접 눌러야 전체 선택"></th><th>워크트리</th><th>유휴</th><th>디스크</th><th>이미지</th>
          </tr></thead><tbody>${items.map(i => gcRowHtml(i, preselectRoot)).join('')}</tbody></table>`;
        body.querySelector('[data-gc-all]').onchange = (e) => {
          for (const cb of body.querySelectorAll('[data-gc-pick]:not(:disabled)')) cb.checked = e.target.checked;
          updateSum();
        };
        for (const cb of body.querySelectorAll('[data-gc-pick]')) cb.onchange = updateSum;
        updateSum();
      };
      back.querySelector('[data-gc-reload]').onclick = loadPlan;
      daysInput.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); loadPlan(); } };

      runBtn.onclick = async () => {
        const sel = picked();
        if (!sel.length) return;
        const names = sel.map(i => i.alias || i.id).join(', ');
        if (!confirm(`유휴 워크트리 ${sel.length}개를 삭제할까?\n${names}\n\n삭제 전 백업 브랜치를 만들고, compose 이미지·볼륨도 회수해. 미머지 브랜치는 보존돼.`)) return;
        runBtn.disabled = true; runBtn.textContent = '삭제 중…';
        const resultEl = back.querySelector('[data-gc-result]');
        let res;
        try {
          res = await api('/api/worktree-gc', {method: 'POST', headers: {'content-type': 'application/json'},
            body: JSON.stringify({roots: sel.map(i => i.root), days: Math.max(1, Number(daysInput.value) || 14)})});
        } catch (e) {
          resultEl.hidden = false; resultEl.textContent = `실패: ${String((e && e.message) || e)}`;
          runBtn.disabled = false; runBtn.textContent = '선택 삭제';
          return;
        }
        const lines = (res.results || []).map(r => {
          const name = sel.find(i => i.root === r.root)?.alias || r.id || r.root;
          if (r.removed) {
            const extra = (r.reclaimErrors || []).length ? ` (회수 일부 실패: ${r.reclaimErrors.join('; ')})` : '';
            return `✓ ${name} — ${gcGb(r.freedMb)} 회수${extra}`;
          }
          return `✗ ${name} — ${r.reason || '실패'}`;
        });
        resultEl.hidden = false;
        resultEl.textContent = `${lines.join('\n')}\n합계 ${gcGb(res.freedMb)} 회수`;
        const removedRoots = new Set((res.results || []).filter(r => r.removed).map(r => r.root));
        if (selected && removedRoots.has(selected.root)) {   // 로그 패널이 지워진 워크트리를 보고 있었으면 비운다(removeWorktreeFlow 와 동일)
          selected = null;
          if (source) source.close();
          resetLogView('서비스 행을 선택하세요');
          updateOlderBar();
        }
        await loadWorktrees(true);
        await load({force: true});
        showToast(`유휴 워크트리 ${removedRoots.size}개 삭제 · ${gcGb(res.freedMb)} 회수`, removedRoots.size ? 'ok' : 'err');
        await loadPlan();
      };

      await loadPlan();
    }

    document.getElementById('worktreeGcBtn').onclick = (e) => { e.stopPropagation(); openWorktreeGc(''); };
