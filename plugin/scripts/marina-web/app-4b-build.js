    // Build run summary. The raw log remains the source of truth below this band.
    let buildSummaryRequest = 0;
    let buildSummaryTimer = null;

    function fmtBuildSeconds(value) {
      if (value == null || !Number.isFinite(Number(value))) return '-';
      const seconds = Number(value);
      return seconds >= 60
        ? `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`
        : `${seconds.toFixed(seconds < 10 ? 1 : 0)}s`;
    }

    function buildStepHtml(step, maxSeconds) {
      const seconds = Number(step.durationSec) || 0;
      const pct = step.cached
        ? 2
        : Math.max(2, Math.round((seconds / Math.max(maxSeconds, 0.1)) * 100));
      const state = step.failed ? 'failed' : (step.cached ? 'cache' : 'run');
      return `<div class="build-step" data-build-step data-state="${state}">
        <span class="build-step-name" title="${escapeHtml(step.label || '')}">${escapeHtml(step.label || '-')}</span>
        <span class="build-step-track" aria-hidden="true"><span style="width:${pct}%"></span></span>
        <span class="build-step-time">${step.failed ? 'failed' : (step.cached ? 'cache' : fmtBuildSeconds(seconds))}</span>
      </div>`;
    }

    function buildReasonText(reason) {
      const label = reason.label || '-';
      const change = {
        added: '추가',
        removed: '제거',
        changed: '변경',
        requested: '요청',
        unknown: '확인 불가',
      }[reason.change] || reason.change || '변경';
      const prefix = {
        dockerfile: 'Dockerfile',
        'rebuild-input': '이미지 입력',
        'build-arg': 'build arg',
        'first-run': '첫 실행',
        'explicit-rebuild': '명시적 Rebuild',
        unknown: '입력 상태',
      }[reason.kind] || '입력';
      return `${prefix} ${change} · ${label}`;
    }

    function buildReasonsHtml(reasons) {
      if (!reasons.length) return '';
      const preview = reasons.slice(0, 3).map(buildReasonText).join(' · ');
      const overflow = reasons.length > 3 ? ` 외 ${reasons.length - 3}개` : '';
      const rows = reasons.map(reason => {
        const service = reason.service ? `<span>${escapeHtml(reason.service)}</span>` : '';
        return `<div class="build-reason-row">${service}<strong>${escapeHtml(buildReasonText(reason))}</strong></div>`;
      }).join('');
      return `<details class="build-reasons" data-build-reasons>
        <summary><span>재빌드 이유</span><strong>${escapeHtml(preview)}${escapeHtml(overflow)}</strong></summary>
        <div class="build-reason-list">${rows}</div>
      </details>`;
    }

    function renderBuildSummary(data) {
      const el = document.getElementById('buildSummary');
      const steps = Array.isArray(data.steps) ? data.steps : [];
      const reasons = Array.isArray(data.reasons) ? data.reasons : [];
      const maxSeconds = Math.max(
        0.1,
        ...steps.filter(step => !step.cached).map(step => Number(step.durationSec) || 0),
      );
      const status = {
        running: '진행 중',
        success: '완료',
        failed: '실패',
        timeout: '시간 초과',
      }[data.status] || '기록 없음';
      const bottleneck = data.bottleneck
        ? `가장 오래 걸림 · ${escapeHtml(data.bottleneck.label)} ${fmtBuildSeconds(data.bottleneck.durationSec)}`
        : '측정 단계 없음';
      el.innerHTML = `<div class="build-summary-head">
          <span class="build-summary-status" data-state="${escapeHtml(data.status || 'unknown')}">${status}</span>
          <strong>${fmtBuildSeconds(data.durationSec)}</strong>
          <span>${bottleneck}</span>
          <span class="build-summary-cache">cache ${Number(data.cacheHits) || 0} · run ${Number(data.cacheMisses) || 0}</span>
        </div>
        ${buildReasonsHtml(reasons)}
        <div class="build-steps">${steps.map(step => buildStepHtml(step, maxSeconds)).join('')}</div>`;
      el.hidden = false;
    }

    async function loadBuildSummary(root, run) {
      const el = document.getElementById('buildSummary');
      if (buildSummaryTimer) {
        clearTimeout(buildSummaryTimer);
        buildSummaryTimer = null;
      }
      const request = ++buildSummaryRequest;
      if (!selected || selected.service !== 'build') {
        el.hidden = true;
        el.innerHTML = '';
        return;
      }
      el.hidden = false;
      el.innerHTML = '<div class="build-summary-head"><span>빌드 분석 중...</span></div>';
      try {
        const data = await api(`/api/build-summary?root=${enc(root)}&run=${enc(run)}`);
        if (
          request !== buildSummaryRequest
          || !selected
          || selected.root !== root
          || selected.run !== run
          || selected.service !== 'build'
        ) return;
        renderBuildSummary(data);
        if (data.status === 'running') {
          buildSummaryTimer = setTimeout(() => loadBuildSummary(root, run), 2000);
        }
      } catch (error) {
        if (request !== buildSummaryRequest) return;
        el.innerHTML = `<div class="build-summary-head"><span>빌드 요약을 읽지 못했어요 · ${escapeHtml(error.message || String(error))}</span></div>`;
      }
    }
