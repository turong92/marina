    async function api(path, options) {
      const res = await fetch(path, options);
      if (!res.ok) throw new Error(await res.text());
      return res.json();
    }

    function enc(value) { return encodeURIComponent(value); }
    function selectedServiceKey() { return selected ? `${selected.root}::${selected.service}` : ''; }
    function escapeHtml(value) {
      return String(value ?? '').replace(/[&<>"']/g, ch => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
      })[ch]);
    }

    function serviceMeta(root, service) {
      const session = sessions.find(item => item.root === root);
      if (!session) return {session: null, service: null};
      return {session, service: session.services.find(item => item.service === service)};
    }

    // 진행 중 표시 + 중복 클릭 방지: 누른 버튼은 라벨 교체, group 버튼들은 함께 비활성화.
    // 완료 후 보통 재렌더로 교체되지만, 에러·취소 경로를 위해 finally 에서 원복.
    // 모든 진행중 표시 공통 — 떠다니는 점 3개. withBusy 의 label 인자는 이제 표시에 안 쓰임(점으로 통일), 호환 위해 시그니처만 유지
    const BUSY_DOTS = '<span class="busy-dots" role="status" aria-label="처리 중"><i></i><i></i><i></i></span>';
    function withBusy(btn, label, fn, group) {
      if (btn.disabled) return;
      const targets = group ? Array.from(group) : [btn];
      const original = btn.innerHTML;   // innerHTML — 아이콘(SVG) 버튼도 보존 (textContent 면 복원 시 자식 노드 소실 → 빈 버튼)
      for (const b of targets) b.disabled = true;
      btn.innerHTML = BUSY_DOTS;
      fn().catch(alert).finally(() => {
        for (const b of targets) b.disabled = false;
        btn.innerHTML = original;
      });
    }

    function finiteMemoryMb(value) {
      if (value === null || value === undefined || typeof value === 'boolean') return null;
      if (typeof value === 'string' && value.trim() === '') return null;
      if (typeof value !== 'number' && typeof value !== 'string') return null;
      const mb = Number(value);
      return Number.isFinite(mb) ? mb : null;
    }

    function formatMemoryGb(value) {
      const mb = finiteMemoryMb(value);
      return mb === null ? '알 수 없음' : `${(mb / 1024).toFixed(1)} GB`;
    }

    function formatMemoryPair(usedMb, totalMb) {
      return `${(usedMb / 1024).toFixed(1)} / ${(totalMb / 1024).toFixed(1)} GB`;
    }

    function memoryBlockConfirmation(block, type = 'start') {
      const operation = ({start: '시작', 'start-all': '전체 시작', restart: '재시작', rebuild: '재빌드', 'clean-rebuild': '클린 재빌드'})[type] || '실행';
      const reason = {
        'host-critical': `Host available ${formatMemoryGb(block.hostFreeMb)}가 기준 ${formatMemoryGb(block.minFreeMb)}보다 낮아 ${operation}을 막았어.`,
        'docker-unknown': `Docker 메모리 측정이 불완전해 안전하게 판단할 수 없어 ${operation}을 막았어.`,
        'docker-current': `Docker 여유가 이미 예약 ${formatMemoryGb(block.reserveMb)}보다 낮아 ${operation}을 막았어.`,
        'docker-projected': `${operation}하면 Docker 여유가 예약치 아래로 내려가 막았어.`,
      }[block?.reason] || `메모리 여유가 부족해 ${operation}을 막았어.`;
      const estimates = (Array.isArray(block?.estimatedServices) ? block.estimatedServices : [])
        .map(item => ({service: String(item?.service || '').trim(), memoryMb: finiteMemoryMb(item?.memoryMb)}))
        .filter(item => item.service && item.memoryMb !== null)
        .sort((a, b) => b.memoryMb - a.memoryMb)
        .slice(0, 3);
      const unknown = (Array.isArray(block?.unknownServices) ? block.unknownServices : [])
        .map(service => String(service || '').trim())
        .filter(Boolean);
      const estimateLine = estimates.length
        ? `큰 추정: ${estimates.map(item => `${item.service} ${formatMemoryGb(item.memoryMb)}`).join(', ')}`
        : '큰 추정: 기록된 서비스 메모리 없음';
      const unknownLine = unknown.length ? `알 수 없는 서비스: ${unknown.join(', ')}` : '알 수 없는 서비스: 없음';
      return `${reason}\n예상 Docker 여유 ${formatMemoryGb(block?.projectedFreeMb)} / 예약 ${formatMemoryGb(block?.reserveMb)}\n${estimateLine}\n${unknownLine}\n그래도 강제로 ${operation}할까?`;
    }

    async function action(type, root, service, force = false) {
      const result = await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root, service, force})
      });
      if (result?.blocked === 'low-memory' && !force) {
        if (confirm(memoryBlockConfirmation(result, type))) {
          return action(type, root, service, true);
        }
        return;
      }
      if (result?.blocked === 'low-memory') return;
      await load({force: true});
      selectLog(root, service, 'current', selected?.mode ?? 'service');
    }

    // 런타임 타깃 배지 — 이 숫자들이 **어느 기계** 것인지. 로컬(기본)이면 아무것도 안 그린다.
    // 자리를 여기로 잡은 이유: 원격이면 옆의 Docker/Host 가 이미 박스 값이라, 안 밝히면 표시가 거짓말이 된다.
    let runtimeTargetState = null;
    function renderRuntimeTarget(rt) {
      runtimeTargetState = rt || null;
      const el = document.getElementById('memTarget');
      if (!el) return;
      const remote = rt && rt.kind === 'remote';
      el.hidden = !remote;
      if (!remote) return;
      const host = String(rt.host || '').replace(/^ssh:\/\//, '');
      el.textContent = `\u2601 ${host}`;
      el.classList.toggle('session', rt.scope === 'session');
      el.title = (rt.scope === 'session'
        ? '이 워크트리만 원격입니다(전역과 다름). '
        : '전역 기본이 원격입니다. ')
        + '위 Docker/Host 수치는 이 박스의 값입니다. 눌러서 로컬로 되돌립니다.';
      if (!el.dataset.wired) {
        el.dataset.wired = '1';
        el.addEventListener('click', onRuntimeTargetClick);
      }
    }

    async function onRuntimeTargetClick() {
      const rt = runtimeTargetState;
      if (!rt || rt.kind !== 'remote') return;
      // 이미 도는 컨테이너는 그 기계에 남는다 — 되돌려도 저절로 내려가지 않으므로 미리 알린다.
      const where = rt.scope === 'global' ? '전역 기본을' : '이 설정을';
      if (!confirm(`${where} 로컬로 되돌릴까요?\n\n이미 박스에서 도는 컨테이너는 그대로 남습니다 — 필요하면 먼저 정지하세요.`)) return;
      try {
        const scope = rt.scope === 'global' ? 'global' : 'session';
        // 세션 범위는 어느 워크트리인지 알려줘야 한다. 배지는 대시보드 상단(워크트리 무관)이라
        // 전역이 정한 경우가 대부분이고, 세션 override 는 그 워크트리가 선택돼 있을 때만 가능하다.
        const root = scope === 'session' ? (selected && selected.root) : undefined;
        if (scope === 'session' && !root) { alert('워크트리를 먼저 선택하세요.'); return; }
        await api('/api/runtime-target', {
          method: 'POST', headers: { 'content-type': 'application/json' },   // POST 는 root 를 body 에서 읽음
          body: JSON.stringify({ root, kind: 'local', scope }),
        });
      } catch (e) {
        alert('런타임 타깃 변경 실패: ' + (e && e.message ? e.message : e));
        return;
      }
      load({ force: true });
    }

    function renderMemory(memory) {
      const box = document.getElementById('mem');
      const docker = memory?.docker && typeof memory.docker === 'object' ? memory.docker : {};
      const host = memory?.host && typeof memory.host === 'object' ? memory.host : {};
      const dockerUsed = finiteMemoryMb(docker.usedMb);
      const dockerTotal = finiteMemoryMb(docker.totalMb);
      const hostAvailable = finiteMemoryMb(host.availableMb);
      const dockerText = dockerUsed !== null && dockerTotal !== null && dockerTotal > 0
        ? `Docker ${formatMemoryPair(dockerUsed, dockerTotal)}`
        : '';
      const hostText = hostAvailable !== null ? `Host available ${formatMemoryGb(hostAvailable)}` : '';
      const dockerEl = document.getElementById('memDocker');
      const hostEl = document.getElementById('memHost');
      const separator = document.getElementById('memSeparator');
      dockerEl.textContent = dockerText;
      hostEl.textContent = hostText;
      dockerEl.hidden = !dockerText;
      hostEl.hidden = !hostText;
      separator.hidden = !dockerText || !hostText;
      box.hidden = !dockerText && !hostText;
      const usedPercent = dockerUsed !== null && dockerTotal !== null && dockerTotal > 0
        ? Math.max(0, Math.min(100, (dockerUsed / dockerTotal) * 100))
        : (finiteMemoryMb(host.availablePercent) === null ? 0 : Math.max(0, Math.min(100, 100 - host.availablePercent)));
      document.getElementById('memBar').style.width = `${usedPercent}%`;
      box.classList.toggle('warn', hostAvailable !== null && hostAvailable < 4096);
    }

    let worktreeData = [];
    let projectData = [];
    // 게이트웨이 — enabled 면 서비스 카드에 <wt>[-<svc>].<proj>.localhost URL 표시. 1회만 조회(env 고정).
    let gatewayState = { enabled: false, port: 80, loaded: false };
    const GW_WEB_NAMES = ['web', 'fe', 'frontend', 'app', 'ui'];   // marina-gateway WEB_NAMES 와 동기
    function gwDomainLabel(s) { return (String(s).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').replace(/-{2,}/g, '-')) || 'x'; }
    function gwIsPrimary(services, name) {
      const have = (services || []).filter(s => String(s.port || '').trim() && s.running);
      for (const w of GW_WEB_NAMES) { if (have.some(s => s.service === w)) return name === w; }
      return have.length > 0 && have[0].service === name;
    }
    function gatewayUrlFor(session, svc) {
      if (!gatewayState.enabled || !svc.running || !String(svc.port || '').trim()) return null;
      const wid = gwDomainLabel(session.id || session.alias || '');
      const pid = gwDomainLabel(session.projectId || '');
      if (!wid || !pid) return null;
      const host = gwIsPrimary(session.services, svc.service) ? `${wid}.${pid}.localhost` : `${wid}-${gwDomainLabel(svc.service)}.${pid}.localhost`;
      const suffix = (gatewayState.port && gatewayState.port !== 80) ? `:${gatewayState.port}` : '';
      return `http://${host}${suffix}/`;
    }
    function hostPortUrlFor(svc) {
      return svc?.running && String(svc.port || '').trim() ? `http://localhost:${svc.port}/` : null;
    }
    function preferredServiceUrl(session, svc) {
      return gatewayUrlFor(session, svc) || hostPortUrlFor(svc);
    }
    function preferredServiceUrlKind(session, svc) {
      if (gatewayUrlFor(session, svc)) return 'gateway';
      return hostPortUrlFor(svc) ? 'host' : null;
    }
    function openServiceInBrowser(session, svc) {
      const url = preferredServiceUrl(session, svc);
      if (!url) return null;
      window.open(url, '_blank', 'noopener');
      return url;
    }
    async function loadGatewayState() {
      if (gatewayState.loaded) return;
      try { const r = await api('/api/gateway-status?light=1'); gatewayState = { enabled: !!r.enabled && !!r.caddy, port: r.port || 80, loaded: true }; }   // caddy 없으면 라우팅 불가 → URL 숨김(codex P3)
      catch { gatewayState.loaded = true; }
    }
    let worktreeSignature = '';
    let worktreesLoaded = false;  // 첫 /api/worktrees 응답 전엔 "빈 레지스트리" 판정 보류 (cold load 스퓨리어스 등록 모달 방지)
    // 구조 시그니처 — 에이전트의 "표시 상태" 필드는 전부 제외한다(구조가 아니라 라이브 값).
    //   에이전트 status/statusTs/preview/statusReason/ts 는 활성 세션이 working↔waiting↔completed 로
    //   수시로 바뀐다. 이를 시그니처에 포함하면 그때마다 전체 render() 가 돌아 → 열린 ⋯메뉴·입력·포커스·
    //   드롭다운이 통째로 리셋된다("전부 취소됨" — 형 피드백 2026-07-24). 이 값들의 화면 반영(dot·label·
    //   행 상태클래스·relTime·preview·접힘요약)은 부분 패치(updateServiceStates)가 5s 마다 신선하게
    //   유지하므로 full render 가 필요 없다. 시그니처는 "구조"만 잡는다: 어떤 카드/에이전트가 있고(sid),
    //   제목·순서·서비스 구성·깃 배지(verdict/ahead/clean)·디스크가 바뀔 때만 render — updateServiceStates
    //   가 패치하지 못하는 것들이다. (sid·title 은 남겨 add/remove/rename 시 행이 재구성되게.)
    function worktreeStructureSig(worktrees, projects) {
      const STRIP = new Set(['status', 'statusTs', 'ts', 'preview', 'statusReason']);
      const lean = worktrees.map(w => {
        if (!w.agents || !w.agents.length) return w;
        return { ...w, agents: w.agents.map(a => {
          const o = {}; for (const k in a) if (!STRIP.has(k)) o[k] = a[k]; return o;
        }) };
      });
      return JSON.stringify([lean, projects]);
    }
    async function loadWorktrees(refresh = false) {
      const data = await api(`/api/worktrees${refresh ? '?refresh=1' : ''}`);
      // 데이터는 항상 갱신 — 부분 패치 경로(updateServiceStates)가 신선한 worktreeData 를 읽어야 한다.
      worktreeData = data.worktrees ?? [];
      projectData = data.projects ?? [];
      worktreesLoaded = true;
      // 대화 탭 훅은 **조기 return 앞에** 둔다 — statusTs 는 아래 시그니처에서 빠져 있어서(휘발성)
      // 뒤에 두면 '새 턴' 점이 영영 안 뜬다. 비활성 탭을 따로 폴링하지 않는 대가로 이 신호를 쓴다.
      if (typeof pruneChatTabs === 'function') { pruneChatTabs(); markChatUnread(); }
      // 구조 시그니처(휘발성 에이전트 필드 제외)가 동일하면 전체 render 스킵 — 부분 패치가 라이브 값을 갱신한다.
      const nextSignature = worktreeStructureSig(worktreeData, projectData);
      if (!refresh && nextSignature === worktreeSignature) return;
      worktreeSignature = nextSignature;
      render(); // 카드의 디스크·캐시·배지 라인 갱신
    }

    async function saveAlias(session, input) {
      const alias = input.value.trim();
      await api('/api/meta', {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, meta: {alias}})
      });
      session.alias = alias;
      await load({force: true});
    }

    async function sessionAction(type, session, force = false) {
      const result = await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, force})
      });
      if (result?.blocked === 'low-memory' && !force) {
        if (confirm(memoryBlockConfirmation(result, type))) {
          return sessionAction(type, session, true);
        }
        return;
      }
      if (result?.blocked === 'low-memory') return;
      await load({force: true});
    }

    async function setDefaultAttach(session, wt, name, want) {
      const cur = new Set(wt?.defaultAttach ?? wt?.subrepos ?? []);
      if (want) cur.add(name); else cur.delete(name);
      const r = await api('/api/set-default-attach', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepos: [...cur]}),
      });
      if (r?.error) { alert(`기본 attach 변경 실패: ${r.error}`); }
      await loadWorktrees(true);
      render();
    }

    async function attachSubrepo(session, name) {
      const r = await api('/api/attach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepo: name}),
      });
      if (r?.error) { alert(`attach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }

    async function detachSubrepo(session, name) {
      const body = {root: session.root, subrepo: name};
      const send = () => api('/api/detach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body),
      });
      let r = await send();
      if (r?.needsStop) {
        if (!confirm(`${name} 에서 구동 중인 서비스(${r.needsStop.join('·')})를 정지하고 detach 할까?`)) return;
        body.stopServices = true;
        r = await send();
      }
      if (r?.needsConfirm) {
        if (!confirm(`${name} 에 미커밋 변경분이 있어. detach 하면 변경·untracked 가 폐기돼 (브랜치·커밋은 보존). 폐기하고 detach 할까?`)) return;
        body.force = true;
        r = await send();
      }
      if (r?.error) { alert(`detach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }
