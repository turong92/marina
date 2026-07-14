    // app-5c-config.js — 서비스/프로젝트 구성 읽기전용 모달(P4 분할 3/3): openServiceConfig/openProjectConfig
    // /renderServiceConfig/highlightVars + build args·profile 저장 배선(wireBuildArgsSave).
    // app-5b-actions.js 다음 로드.


    async function openServiceConfig(root, service) {   // 읽기전용 구성 모달(동적 생성)
      const ex = document.getElementById('svcConfigBack'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'svcConfigBack'; back.className = 'modal-backdrop';
      back.innerHTML = `<div class="svc-config-modal narrow">
        <div class="svc-config-head">
          <span class="svc-config-title">구성 — ${escapeHtml(service)}</span>
          <button id="svcCfgClose" class="links-modal-x">✕</button>
        </div>
        <div id="svcCfgBody" class="svc-config-body">불러오는 중…</div>
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
      back.innerHTML = `<div class="svc-config-modal wide">
        <div class="svc-config-head">
          <span class="svc-config-title">구성 — 전체 서비스 <span class="sub">(profile·build args 편집 가능)</span></span>
          <button id="svcCfgClose" class="links-modal-x">✕</button>
        </div>
        <div id="svcCfgBody" class="svc-config-body scroll">불러오는 중…</div>
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
        const tabBtn = (s, i) => `<button class="cfg-tab" data-i="${i}">📦 ${escapeHtml(s.subrepo || '-')}/${escapeHtml(s.service)}</button>`;
        body.innerHTML = `<div class="cfg-tab-row">${svcs.map(tabBtn).join('')}</div><div id="cfgTabBody" class="cfg-tab-body"></div>`;
        const tabs = [...body.querySelectorAll('.cfg-tab')];
        const showTab = (i) => {
          tabs.forEach((t, j) => t.classList.toggle('active', j === i));
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
      if (s.prebuild) {
        const pb = s.prebuild;
        const mode = pb.mode === 'service' ? '서비스 단위' : '레거시 서브레포';
        html += `<div style="margin:0 0 12px"><div style="color:${muted};margin-bottom:4px">pre-build <span title="Compose Workbench의 x-marina.prebuild에서 편집합니다.">(읽기 전용 · ${escapeHtml(mode)})</span></div>
          <div style="border:1px solid var(--sys-style-neutral-light);border-radius:6px;padding:7px 9px;font-family:ui-monospace,monospace;font-size:12px;line-height:1.6">
            <div><span style="color:${muted}">cwd</span> ${escapeHtml(pb.cwd || '.')}</div>
            <div><span style="color:${muted}">command</span> ${escapeHtml(pb.command || '')}</div>
          </div></div>`;
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
    function wireBuildArgsSave(container, root) {   // ⓘ 모달 저장 — build args. 변경 없으면 저장 버튼 비활성
      const wireDirty = (btn) => {   // 초기 비활성(저장할 변경 없음) — 대상 편집하면 활성
        const ta = document.getElementById(btn.dataset.target);
        if (ta) { btn.disabled = true; ta.addEventListener('input', () => { btn.disabled = false; }); }
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
