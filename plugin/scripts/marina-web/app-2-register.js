    document.getElementById('registerPath').addEventListener('change', () => {
      if (!document.getElementById('composeSection').hidden)
        renderComposeSubrepos(document.getElementById('registerPath').value.trim());
    });

    function setComposeProgress(kind, text) {
      const prog = document.getElementById('composeProgress');
      prog.hidden = false;
      prog.className = 'svc-llm-progress ' + kind;
      prog.innerHTML = '<span>' + escapeHtml(text) + '</span>';
    }

    // ── compose YAML 하이라이트 오버레이 (dep0 — 라이브러리 없음) ───────────────
    function yamlCommentStart(line) {   // 따옴표 밖의 첫 # (인라인 주석) 위치, 없으면 -1
      let s = false, d = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "'" && !d) s = !s;
        else if (c === '"' && !s) d = !d;
        else if (c === '#' && !s && !d && (i === 0 || /\s/.test(line[i - 1]))) return i;
      }
      return -1;
    }
    function highlightYaml(text) {
      return text.split('\n').map(line => {
        let code = line, comment = '';
        const ci = yamlCommentStart(line);
        if (ci >= 0) { code = line.slice(0, ci); comment = line.slice(ci); }
        let html = escapeHtml(code).replace(/^(\s*)([A-Za-z0-9_.\-]+)(\s*:)/, (m, sp, key, colon) => {
          const depth = Math.floor(sp.length / 2) % 5;   // 들여쓰기 깊이별 키 색 — 계층 가독성(top-level=d0 …)
          return sp + `<span class="y-d${depth}">${key}</span>` + colon;
        });
        html = html.replace(/\$\{[^}]+\}/g, m => `<span class="y-var">${m}</span>`);   // escapeHtml 후라 ${} 보존
        if (comment) html += `<span class="y-com">${escapeHtml(comment)}</span>`;
        return html;
      }).join('\n');
    }
    function refreshComposeHighlight() {
      const ta = document.getElementById('composeYaml'), hl = document.getElementById('composeHl'), gut = document.getElementById('composeGutter');
      if (!ta || !hl || !gut) return;
      const n = (ta.value.match(/\n/g) || []).length + 1;
      hl.innerHTML = highlightYaml(ta.value);
      gut.textContent = Array.from({ length: n }, (_, i) => i + 1).join('\n');
      hl.style.transform = `translate(${-ta.scrollLeft}px, ${-ta.scrollTop}px)`;   // transform 동기화 — scrollbar-clamp 어긋남 없음
      gut.style.transform = `translateY(${-ta.scrollTop}px)`;
    }
    function setComposeYaml(v) {   // 프로그램적 세팅 — 하이라이트·line# 도 같이 갱신(input 이벤트 안 뜨므로)
      const ta = document.getElementById('composeYaml');
      if (ta) ta.value = v == null ? '' : v;
      refreshComposeHighlight();
    }
    (function wireComposeHighlight() {
      const ta = document.getElementById('composeYaml');
      if (!ta) return;
      ta.addEventListener('input', refreshComposeHighlight);
      ta.addEventListener('scroll', () => {
        const hl = document.getElementById('composeHl'), gut = document.getElementById('composeGutter');
        if (hl) hl.style.transform = `translate(${-ta.scrollLeft}px, ${-ta.scrollTop}px)`;
        if (gut) gut.style.transform = `translateY(${-ta.scrollTop}px)`;
      });
      // 초기 페인트는 다음 tick 으로 — highlightYaml→escapeHtml(app-3-util)이 이 스크립트보다 늦게 로드되므로
      // eval 시점 호출은 ReferenceError 로 이후 핸들러 등록을 막는다(codex P1).
      setTimeout(refreshComposeHighlight, 0);
    })();

    document.getElementById('composeViewConfig').onclick = () => {   // 편집 모달에서 해석된 구성 보기
      const path = document.getElementById('registerPath').value.trim();
      if (!path) { setComposeProgress('err', '프로젝트 경로 먼저 입력'); return; }
      openProjectConfig(path);
    };
    function okToReplaceYaml() {   // 편집기에 내용이 있으면 덮어쓰기 전 확인 — 직접 작성분 유실 방지(코덱스 UX #2)
      const ta = document.getElementById('composeYaml');
      const v = ((ta && ta.value) || '').trim();
      if (!v || v === '불러오는 중…') return true;
      return confirm('편집기에 작성한 compose 내용이 있어요. 새로 불러온 내용으로 덮어쓸까요?');
    }
    document.getElementById('composeImport').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const list = document.getElementById('composeDetectList');
      if (!path) { setComposeProgress('err', '프로젝트 경로 먼저 입력'); return; }
      try {
        const r = await api('/api/compose-detect?path=' + enc(path));
        const files = (r && r.files) || [];
        list.innerHTML = '';
        if (r && r.stored && r.stored.yaml) {
          const row = document.createElement('div');
          row.className = 'browse-row';
          row.innerHTML = '<span>💾 marina 저장본 (' + escapeHtml(r.stored.composeFile || 'docker-compose.yml') + ')</span>';
          row.onclick = () => {
            if (!okToReplaceYaml()) return;
            setComposeYaml(r.stored.yaml);
            composeStoredEnv = { envVar: r.stored.envVar || '', envDefault: r.stored.envDefault || '' };   // 저장된 env 보간값 보존
            list.hidden = true; setComposeProgress('ok', 'marina 저장본을 불러왔어요 — 수정 후 등록하면 교체됩니다');
          };
          list.appendChild(row);
        }
        if (!files.length && !(r && r.stored)) {
          list.innerHTML = '<div class="register-empty">레포에서 compose 파일을 못 찾음 — 직접 작성</div>';
        }
        for (const f of files) {
          const row = document.createElement('div');
          row.className = 'browse-row';
          row.innerHTML = '<span>📄 ' + escapeHtml(f.rel) + '</span>';
          row.onclick = () => {
            if (!okToReplaceYaml()) return;
            setComposeYaml(f.content || '');
            list.hidden = true; setComposeProgress('ok', f.rel + ' 불러옴 — 검토·검증 후 등록');
          };
          list.appendChild(row);
        }
        list.hidden = false;
      } catch (e) { setComposeProgress('err', String((e && e.message) || e)); }
    };

    document.getElementById('composeConfirm').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const yaml = document.getElementById('composeYaml').value;
      const isEdit = document.getElementById('registerTitle').textContent === 'compose 편집';
      const err = document.getElementById('registerError');
      err.hidden = true;
      if (!path) { err.textContent = '프로젝트 경로를 입력하세요'; err.hidden = false; return; }
      if (!yaml.trim()) { err.textContent = 'compose 내용을 입력하세요 (📁 import / 직접 작성)'; err.hidden = false; return; }
      const btn = document.getElementById('composeConfirm'); const label = btn.textContent;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/compose-register', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({path, yaml,
            envVar: composeStoredEnv.envVar,
            envDefault: composeStoredEnv.envDefault,
            externalRepos: [...document.querySelectorAll('#composeSubrepos [data-mount]')].map(r => ({name: r.dataset.mount.split('/').pop(), sub: r.dataset.subrepo}))}),   // 저장만(자동 실행 X) + env var/default + 외부 서브레포 기록
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      if (res && res.ok === false) {
        err.textContent = '검증 실패: ' + ((res.errors && res.errors.join(' / ')) || ''); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      if (res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id)) setSelectedProject(res.id);
      else render();
      if (res && res.ok !== false) {
        alert((isEdit ? 'compose 저장 완료' : 'compose 등록 완료')
          + ' — 자동 실행은 안 했어요. 카드에서 ▶로 시작하세요 (이미 실행 중이면 ■ 정지 후 ▶ 시작해야 변경분이 반영됩니다).');
      }
    };

    // ── 팀원 설정 붙여넣기(import) ─────────────────────────────────────────────
    document.getElementById('pasteBrowse').onclick = () => {
      browseMode = 'paste';
      document.getElementById('registerPaste').appendChild(document.getElementById('browsePanel'));
      openBrowse(document.getElementById('pastePath').value.trim() || '');
    };
    document.getElementById('pasteImport').onclick = async () => {
      const root = document.getElementById('pastePath').value.trim();
      const blob = document.getElementById('pasteBlob').value;
      const apply = document.getElementById('pasteApply').checked;
      const err = document.getElementById('pasteError');
      err.hidden = true;
      if (!root) { err.textContent = '프로젝트 경로를 입력하세요'; err.hidden = false; return; }
      if (!blob.trim()) { err.textContent = '공유 블록(compose+x-marina)을 붙여넣으세요'; err.hidden = false; return; }
      const btn = document.getElementById('pasteImport'); const label = btn.textContent;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/compose-import', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ root, blob, apply }),
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      if (res && res.ok === false) {
        err.textContent = '가져오기 실패: ' + ((res.errors && res.errors.join(' / ')) || res.error || ''); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      if (res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id)) setSelectedProject(res.id);
      else render();
      const warn = (res && res.warnings && res.warnings.length) ? ('\n경고: ' + res.warnings.join(' / ')) : '';
      alert('가져오기 완료 — 등록 + 설정 적용됨.' + (apply ? ' 시작도 시도했어요.' : ' 카드에서 ▶로 시작하세요.')
        + ' 시크릿(.env 값)은 본인 것을 채우세요.' + warn);
    };

    // ── 새 프로젝트 위저드 (스캔→파일→연결→검토) — 하나의 config 객체(고급뷰와 공유) ──────────
    const WIZ_STEPS = ['스캔', '파일', '연결', '검토'];
    let wiz = null;
    function openWizard() {
      document.getElementById('registerTitle').textContent = '새 프로젝트 설정';
      document.getElementById('registerPath').value = '';
      document.getElementById('registerPath').disabled = false;
      document.getElementById('registerBrowse').hidden = false;
      document.getElementById('registerInfer').hidden = true;
      wiz = { step: 0, scan: null, servicesYaml: '', includes: [], buildArgs: {},
              links: { symlink: ['node_modules', '.venv'], copy: [] },
              configMode: 'symlink', forward: {}, gateway: { routes: {} }, mergedYaml: '' };
      setRegisterView('wizard');
      renderWiz();
      showRegisterPanel(true);
      renderSwitcher();
    }
    function wizErr(msg) { const e = document.getElementById('wizError'); if (!msg) { e.hidden = true; return; } e.textContent = msg; e.hidden = false; }
    function renderWiz() {
      const bar = document.getElementById('wizSteps'); bar.innerHTML = '';
      WIZ_STEPS.forEach((label, i) => {
        const s = document.createElement('span');
        s.textContent = (i + 1) + '. ' + label;
        s.style = 'padding:3px 8px;border-radius:10px;' + (i === wiz.step
          ? 'background:var(--accent,#2563eb);color:#fff' : (i < wiz.step ? 'color:var(--accent,#2563eb)' : 'color:var(--muted)'));
        bar.appendChild(s);
      });
      document.getElementById('wizPrev').disabled = wiz.step === 0;
      document.getElementById('wizNext').textContent = wiz.step === WIZ_STEPS.length - 1 ? '등록' : '다음 →';
      wizErr('');
      [renderWizScan, renderWizFiles, renderWizConnect, renderWizReview][wiz.step]();
    }
    function wizServiceNames() {   // servicesYaml 에서 서비스명 추출 (연결/게이트웨이용)
      return [...wiz.servicesYaml.matchAll(/^ {2}([A-Za-z0-9_-]+):/gm)].map(m => m[1]);
    }
    // 스텝1: 스캔 — Dockerfile·ARG·EXPOSE + build-args 입력 + 포함 선택
    async function renderWizScan() {
      const body = document.getElementById('wizBody'); body.innerHTML = '';
      const hint = document.createElement('div'); hint.style = 'font-size:12px;color:var(--muted);margin-bottom:8px';
      hint.textContent = '프로젝트 경로를 입력하고 스캔하세요 — 서브레포의 Dockerfile 을 찾아 서비스 후보로 보여줍니다.';
      body.appendChild(hint);
      const scanBtn = document.createElement('button'); scanBtn.type = 'button'; scanBtn.className = 'svc-llm-go'; scanBtn.textContent = '🔍 스캔';
      scanBtn.onclick = async () => {
        const root = document.getElementById('registerPath').value.trim();
        if (!root) { wizErr('프로젝트 경로를 먼저 입력하세요'); return; }
        scanBtn.disabled = true; scanBtn.textContent = '스캔 중…';
        try {
          const r = await api('/api/compose-scan', { method: 'POST', headers: {'content-type':'application/json'}, body: JSON.stringify({ root }) });
          wiz.scan = r; renderWiz();
        } catch (e) { wizErr(String(e.message || e)); scanBtn.disabled = false; scanBtn.textContent = '🔍 스캔'; }
      };
      body.appendChild(scanBtn);
      if (!wiz.scan) return;
      const cards = document.createElement('div'); cards.id = 'wizScanCards'; cards.style = 'display:flex;flex-direction:column;gap:8px;margin-top:10px';
      let any = false;
      for (const sub of (wiz.scan.subrepos || [])) {
        if (!(sub.dockerfiles || []).length) {   // Dockerfile 없는 서브레포 — 자체 compose 가 있으면 include 로 (codex P2: 기존 compose 프로젝트도 위저드 등록 가능)
          if (sub.subrepo === '.' || sub.subrepo === '') continue;   // 루트 자체는 include 후보 아님(서브레포만)
          any = true;
          const card = document.createElement('div');
          card.className = 'wiz-svc-card'; card.dataset.subrepo = sub.subrepo; card.dataset.dockerfile = '';
          card.style = 'border:1px solid var(--border,#333);border-radius:8px;padding:8px;font-size:12px';
          card.innerHTML = `<label class="register-check" style="font-weight:600"><input type="checkbox" class="wiz-inc" /> ${escapeHtml(sub.subrepo)} · 🧩 자체 compose (include)</label>
            <div style="color:var(--muted);margin-top:4px">Dockerfile 없음 — 이 서브레포의 docker-compose.yml 을 통째로 가져옵니다(있을 때).</div>`;
          cards.appendChild(card);
          continue;
        }
        for (const df of (sub.dockerfiles || [])) {
          any = true;
          const card = document.createElement('div');
          card.className = 'wiz-svc-card'; card.dataset.subrepo = sub.subrepo; card.dataset.dockerfile = df.dockerfile;
          card.style = 'border:1px solid var(--border,#333);border-radius:8px;padding:8px;font-size:12px';
          const argstr = (df.args || []).map(a => (df.requiredArgs || []).includes(a) ? a + '*' : a).join(', ') || '없음';
          card.innerHTML = `<label class="register-check" style="font-weight:600"><input type="checkbox" class="wiz-inc" checked /> ${escapeHtml(sub.subrepo)} · 🐳 ${escapeHtml(df.dockerfile)}</label>
            <div style="color:var(--muted);margin:4px 0">EXPOSE: ${df.expose ? escapeHtml(df.expose) : '—'} · ARG: ${escapeHtml(argstr)}${(df.artifacts||[]).length ? ' · 아티팩트(선빌드 필요)' : ''}</div>`;
          const ba = document.createElement('textarea');
          ba.className = 'wiz-buildargs'; ba.placeholder = 'build-args (KEY=VALUE, 줄마다) — 선택';
          ba.style = 'width:100%;min-height:38px;font-family:ui-monospace,monospace;font-size:11px';
          if ((df.requiredArgs || []).length) ba.value = df.requiredArgs.map(a => a + '=').join('\n');
          card.appendChild(ba);
          cards.appendChild(card);
        }
      }
      if (!any) { const e = document.createElement('div'); e.className = 'register-empty'; e.textContent = 'Dockerfile 을 못 찾았습니다 — [고급]에서 직접 작성하세요.'; cards.appendChild(e); }
      body.appendChild(cards);
    }
    async function wizCommitScan() {   // 선택된 Dockerfile → scaffold → servicesYaml + buildArgs
      const root = document.getElementById('registerPath').value.trim();
      const cards = [...document.querySelectorAll('#wizScanCards .wiz-svc-card')].filter(c => c.querySelector('.wiz-inc').checked);
      if (!cards.length) { wizErr('서비스를 하나 이상 선택하세요 (또는 [고급]에서 직접 작성)'); return false; }
      let services = '', includes = [], buildArgs = {};
      for (const c of cards) {
        try {
          const rr = await api('/api/compose-scaffold?path=' + enc(root) + '&subrepo=' + enc(c.dataset.subrepo) + '&dockerfile=' + enc(c.dataset.dockerfile));
          if (rr && rr.include) { if (!includes.includes(rr.include)) includes.push(rr.include); }
          else if (rr && rr.yaml) {
            services += rr.yaml.replace(/\s+$/, '') + '\n';
            const nm = (rr.yaml.match(/^ {2}([A-Za-z0-9_-]+):/m) || [])[1];
            const ba = parseKv(c.querySelector('.wiz-buildargs').value);
            if (nm && Object.keys(ba).length) buildArgs[nm] = ba;
          }
        } catch (e) { wizErr(String(e.message || e)); return false; }
      }
      wiz.servicesYaml = (services ? 'services:\n' + services : '');
      wiz.includes = includes; wiz.buildArgs = buildArgs;
      return true;
    }
    function parseKv(text) { const o = {}; (text || '').split('\n').forEach(ln => { const i = ln.indexOf('='); if (i > 0) { const k = ln.slice(0, i).trim(), v = ln.slice(i + 1).trim(); if (k) o[k] = v; } }); return o; }
    // 스텝2: 파일(opt-in links) — deps/config/build 3분류
    function renderWizFiles() {
      const body = document.getElementById('wizBody'); body.innerHTML = '';
      const mk = (title, desc) => { const h = document.createElement('div'); h.style='font-weight:600;font-size:13px;margin:8px 0 2px'; h.textContent=title; body.appendChild(h); const d=document.createElement('div'); d.style='font-size:11px;color:var(--muted);margin-bottom:4px'; d.textContent=desc; body.appendChild(d); };
      mk('의존성 (심링크 공유)', 'node_modules·.venv — 워크트리 간 공유해 재설치 회피');
      for (const dep of ['node_modules', '.venv']) {
        const l = document.createElement('label'); l.className='register-check';
        l.innerHTML = `<input type="checkbox" class="wiz-dep" value="${dep}" ${wiz.links.symlink.includes(dep)?'checked':''}/> ${dep}`;
        body.appendChild(l);
      }
      mk('Config (gitignore)', '*local.yml·.env*.local — 공유(심링크) 또는 독립 편집(복제)');
      const modeRow = document.createElement('div'); modeRow.style='display:flex;gap:12px;font-size:12px';
      for (const [val, lab] of [['symlink','심링크(공유)'],['copy','복제(독립)'],['none','안 가져옴']]) {
        const l=document.createElement('label'); l.className='register-check';
        l.innerHTML = `<input type="radio" name="wizCfgMode" value="${val}" ${wiz.configMode===val?'checked':''}/> ${lab}`;
        modeRow.appendChild(l);
      }
      body.appendChild(modeRow);
      mk('빌드 출력 (제외)', 'build·dist·out·target·.next·*.jar — 워크트리별 독립 빌드 (가져오지 않음)');
      const note=document.createElement('div'); note.style='font-size:11px;color:var(--muted);opacity:.7'; note.textContent='✗ 자동 제외 — docker 빌드는 워크트리에서 독립 수행';
      body.appendChild(note);
      const custom=document.createElement('div'); custom.style='margin-top:10px';
      custom.innerHTML='<div style="font-size:12px;color:var(--muted)">추가 심링크 (선택, 쉼표 구분)</div>';
      const inp=document.createElement('input'); inp.id='wizCustomLinks'; inp.placeholder='예: .gradle, packages/shared/dist';
      inp.style='width:100%;font-size:12px;height:30px'; inp.value=(wiz.links.symlink.filter(s=>!['node_modules','.venv'].includes(s)).join(', '));
      custom.appendChild(inp); body.appendChild(custom);
    }
    function wizCommitFiles() {
      const deps = [...document.querySelectorAll('.wiz-dep:checked')].map(c => c.value);
      const extra = (document.getElementById('wizCustomLinks').value || '').split(',').map(s=>s.trim()).filter(Boolean);
      const mode = (document.querySelector('input[name=wizCfgMode]:checked') || {}).value || 'symlink';
      wiz.configMode = mode;
      const sym = [...deps, ...extra], copy = [];
      if (mode === 'symlink') sym.push('**/*local.yml', '.env*.local');
      else if (mode === 'copy') copy.push('**/*local.yml', '.env*.local');
      wiz.links = { symlink: sym, copy };
      return true;
    }
    // 스텝3: 연결 — host 백킹 forward + 게이트웨이
    function renderWizConnect() {
      const body = document.getElementById('wizBody'); body.innerHTML = '';
      const h=document.createElement('div'); h.style='font-weight:600;font-size:13px;margin-bottom:2px'; h.textContent='호스트 백킹 연결 (엮기)'; body.appendChild(h);
      const d=document.createElement('div'); d.style='font-size:11px;color:var(--muted);margin-bottom:6px'; d.textContent='컨테이너의 localhost:포트 → 호스트의 redis/db 로 중계 (앱 수정 0)'; body.appendChild(d);
      for (const [port, name] of [['6379','Redis (6379)'],['3306','MySQL (3306)'],['5432','PostgreSQL (5432)']]) {
        const l=document.createElement('label'); l.className='register-check';
        l.innerHTML=`<input type="checkbox" class="wiz-fwd" value="${port}" ${wiz.forward[port]?'checked':''}/> ${name}`;
        body.appendChild(l);
      }
      const gh=document.createElement('div'); gh.style='font-weight:600;font-size:13px;margin:10px 0 2px'; gh.textContent='게이트웨이 (호스트 브라우저 진입)'; body.appendChild(gh);
      const gd=document.createElement('div'); gd.style='font-size:11px;color:var(--muted);margin-bottom:6px'; gd.textContent='체크한 서비스를 <wt>.<proj>.localhost 대표 도메인에 노출 (경로 / )'; body.appendChild(gd);
      const names = wizServiceNames();
      if (!names.length) { const e=document.createElement('div'); e.className='register-empty'; e.textContent='서비스 없음 (스텝1에서 추가)'; body.appendChild(e); }
      for (const nm of names) {
        const l=document.createElement('label'); l.className='register-check';
        l.innerHTML=`<input type="checkbox" class="wiz-gw" value="${escapeHtml(nm)}" ${wiz.gateway.routes[nm]?'checked':''}/> ${escapeHtml(nm)}`;
        body.appendChild(l);
      }
    }
    function wizCommitConnect() {
      const fwd = {}; [...document.querySelectorAll('.wiz-fwd:checked')].forEach(c => { fwd[c.value] = { target: 'host' }; });
      wiz.forward = fwd;
      const routes = {}; [...document.querySelectorAll('.wiz-gw:checked')].forEach(c => { routes[c.value] = ['/']; });
      wiz.gateway = { routes };
      return true;
    }
    function wizXmarina() {
      const xm = {};
      if (wiz.links.symlink.length || wiz.links.copy.length) xm.links = { symlink: wiz.links.symlink, copy: wiz.links.copy };
      if (Object.keys(wiz.forward).length) xm.forward = wiz.forward;
      if (Object.keys(wiz.gateway.routes).length) xm.gateway = wiz.gateway;
      return xm;
    }
    function wizServicesText() {
      const inc = wiz.includes.length ? ('include:\n' + wiz.includes.map(p => '  - ' + p).join('\n') + '\n') : '';
      return inc + (wiz.servicesYaml || '');
    }
    // 스텝4: 검토 — config → compose YAML(serialize) 미리보기(편집 가능) → 등록
    async function renderWizReview() {
      const body = document.getElementById('wizBody'); body.innerHTML = '';
      const info=document.createElement('div'); info.style='font-size:12px;color:var(--muted);margin-bottom:6px'; info.textContent='최종 compose 미리보기 — 수정 후 등록할 수 있어요.'; body.appendChild(info);
      const ta=document.createElement('textarea'); ta.id='wizReviewYaml'; ta.spellcheck=false;
      ta.style='width:100%;min-height:240px;font-family:ui-monospace,Menlo,monospace;white-space:pre;font-size:12px';
      ta.value='직렬화 중…'; body.appendChild(ta);
      try {
        const r = await api('/api/compose-serialize', { method:'POST', headers:{'content-type':'application/json'},
          body: JSON.stringify({ yaml: wizServicesText(), xmarina: wizXmarina(), buildArgs: wiz.buildArgs }) });
        wiz.mergedYaml = (r && r.yaml) || ''; ta.value = wiz.mergedYaml;
      } catch (e) { ta.value=''; wizErr(String(e.message || e)); }
    }
    async function wizRegister() {
      const root = document.getElementById('registerPath').value.trim();
      const yaml = document.getElementById('wizReviewYaml').value;
      if (!root) { wizErr('프로젝트 경로가 필요합니다'); return; }
      if (!yaml.trim()) { wizErr('compose 내용이 비어있습니다'); return; }
      const btn=document.getElementById('wizNext'); const label=btn.textContent; btn.disabled=true; btn.innerHTML=BUSY_DOTS;
      let res;
      try {
        res = await api('/api/compose-register', { method:'POST', headers:{'content-type':'application/json'},
          body: JSON.stringify({ path: root, yaml, apply: false }) });
      } catch (e) { wizErr(String(e.message || e)); btn.disabled=false; btn.textContent=label; return; }
      if (res && res.ok === false) { wizErr('검증 실패: ' + ((res.errors && res.errors.join(' / ')) || '')); btn.disabled=false; btn.textContent=label; return; }
      showRegisterPanel(false); await loadWorktrees(true); await load({ force: true });
      btn.disabled=false; btn.textContent=label;
      if (res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id)) setSelectedProject(res.id); else render();
      alert('등록 완료 — 카드에서 ▶로 시작하세요.' + ((res && res.warnings && res.warnings.length) ? ('\n경고: ' + res.warnings.join(' / ')) : ''));
    }
    document.getElementById('wizPrev').onclick = () => { if (wiz.step > 0) { wiz.step--; renderWiz(); } };
    document.getElementById('wizNext').onclick = async () => {
      const commit = [wizCommitScan, wizCommitFiles, wizCommitConnect, null][wiz.step];
      if (commit) { const ok = await commit(); if (!ok) return; }
      if (wiz.step === WIZ_STEPS.length - 1) { await wizRegister(); return; }
      wiz.step++; renderWiz();
    };
    document.getElementById('wizAdvanced').onclick = async () => {   // 고급: 같은 config → raw compose YAML 폼으로(파워유저)
      // 현재까지 입력 커밋(가능한 스텝만) 후 직렬화
      const root = document.getElementById('registerPath').value.trim();
      try { if (wiz.step === 0) await wizCommitScan(); else if (wiz.step === 1) wizCommitFiles(); else if (wiz.step === 2) wizCommitConnect(); } catch {}
      let yaml = wiz.mergedYaml;
      try {
        const r = await api('/api/compose-serialize', { method:'POST', headers:{'content-type':'application/json'},
          body: JSON.stringify({ yaml: wizServicesText(), xmarina: wizXmarina(), buildArgs: wiz.buildArgs }) });
        yaml = (r && r.yaml) || yaml;
      } catch {}
      openComposeRegister();
      document.getElementById('registerPath').value = root;  // 경로 유지
      setComposeYaml(yaml || '');
      if (root) renderComposeSubrepos(root);
    };

    async function openSubrepoEdit(sum) {
      switcherOpen = false;
      setRegisterView('new');   // 진입 선택/붙여넣기 뷰 숨기고 경로행 노출
      document.getElementById('registerTitle').textContent = `subrepos 편집 — ${sum.label}`;
      document.getElementById('registerPath').value = sum.root;
      document.getElementById('registerPath').disabled = true;
      document.getElementById('registerBrowse').hidden = true;   // 편집: 경로 고정이라 탐색·분석 숨김(분석은 누르면 리셋 위험)
      document.getElementById('composeSection').hidden = true;
      syncRegisterWorkspace();   // subrepos 편집은 compose 작업공간 아님 — 좁은 패널로
      document.getElementById('registerInfer').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      showRegisterPanel(true);
      renderSwitcher();
      // universe = infer(현재 nested-git 전수), checked = 레지스트리에 등록된 큐레이션 집합(main 엔트리 payload).
      const mainEntry = worktreeData.find(w => w.projectId === sum.id && w.isMain);
      const current = mainEntry ? (mainEntry.subrepos || []) : [];
      await inferAndPreview(sum.root, current);
    }

    async function shareProject(sum) {   // 공유용 복사 — '하나의 정규 설정'(compose+x-marina) 클립보드로
      try {
        const r = await api('/api/compose-export?root=' + enc(sum.root));
        if (!r || r.ok === false || !r.yaml) { alert('공유 블록 생성 실패: ' + ((r && r.error) || '알 수 없음')); return; }
        let copied = false;
        try { await navigator.clipboard.writeText(r.yaml); copied = true; } catch {}
        if (!copied) {   // clipboard API 불가(비보안 컨텍스트 등) → 폴백 textarea
          const ta = document.createElement('textarea'); ta.value = r.yaml; ta.style.position = 'fixed'; ta.style.opacity = '0';
          document.body.appendChild(ta); ta.select();
          try { copied = document.execCommand('copy'); } catch {}
          document.body.removeChild(ta);
        }
        alert(copied ? ('공유 블록을 클립보드에 복사했어요 — 팀원이 [📋 팀원 설정 붙여넣기]로 재현합니다.\n(시크릿 .env 값은 포함 안 됨)')
                     : ('복사 실패 — 아래 블록을 직접 복사하세요:\n\n' + r.yaml));
      } catch (e) { alert('공유 실패: ' + String(e.message || e)); }
    }

    async function removeProject(sum) {
      if (!confirm(`'${sum.label}' 등록을 해제할까요? (코드·worktree 는 그대로, 레지스트리에서만 제거)`)) return;
      try {
        await api('/api/remove-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ id: sum.id }),
        });
      } catch (e) {
        alert(`등록 해제 실패: ${e.message || e}`);
        return;
      }
      if (selectedProjectId === sum.id) setSelectedProject(null);
      await loadWorktrees(true);
      await load({ force: true });
      render();
    }
