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

    async function action(type, root, service, force = false) {
      const result = await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root, service, force})
      });
      if (result?.blocked === 'low-memory') {
        const freeGb = (result.freeMb / 1024).toFixed(1);
        const minGb = (result.minFreeMb / 1024).toFixed(1);
        if (confirm(`메모리 여유가 ${freeGb}GB뿐이라 시작을 막았어 (기준 ${minGb}GB).\n다른 세션을 먼저 정리하는 걸 추천. 그래도 시작할까?`)) {
          return action(type, root, service, true);
        }
        return;
      }
      await load({force: true});
      selectLog(root, service, 'current', selected?.mode ?? 'service');
    }

    function renderMemory(memory, sessionList) {
      const box = document.getElementById('mem');
      if (!memory || memory.freePercent == null) { box.hidden = true; return; }
      box.hidden = false;
      // "시스템"은 OS 전체(브라우저·IDE 등 모든 앱 포함) — dev 서비스 합과 단위가 다르다는
      // 혼동이 있어 둘을 분리 표기. dev = marina 가 추적 중인 서비스 RSS 합.
      const usedPercent = 100 - memory.freePercent;
      const usedGb = ((memory.totalMb - memory.freeMb) / 1024).toFixed(1);
      const totalGb = Math.round(memory.totalMb / 1024);
      const devMb = (sessionList ?? []).reduce((sum, s) => sum + s.services.reduce((a, svc) => a + (svc.running && svc.rssMb ? svc.rssMb : 0), 0), 0);
      const devPart = devMb ? `dev ${(devMb / 1024).toFixed(1)}GB · ` : '';
      document.getElementById('memText').textContent = `${devPart}시스템 ${usedGb}/${totalGb}GB (${usedPercent}%)`;
      document.getElementById('memBar').style.width = `${usedPercent}%`;
      box.classList.toggle('warn', memory.freeMb < 4096);
    }

    let worktreeData = [];
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
    async function loadGatewayState() {
      if (gatewayState.loaded) return;
      try { const r = await api('/api/gateway-status?light=1'); gatewayState = { enabled: !!r.enabled && !!r.caddy, port: r.port || 80, loaded: true }; }   // caddy 없으면 라우팅 불가 → URL 숨김(codex P3)
      catch { gatewayState.loaded = true; }
    }
    let worktreeSignature = '';
    let worktreesLoaded = false;  // 첫 /api/worktrees 응답 전엔 "빈 레지스트리" 판정 보류 (cold load 스퓨리어스 등록 모달 방지)
    async function loadWorktrees(refresh = false) {
      const data = await api(`/api/worktrees${refresh ? '?refresh=1' : ''}`);
      const nextSignature = JSON.stringify(data.worktrees ?? []);
      // 변화 없으면 재렌더 스킵 — 60초 폴링이 입력·진행 중 버튼을 흔들지 않게
      if (!refresh && nextSignature === worktreeSignature) return;
      worktreeSignature = nextSignature;
      worktreeData = data.worktrees ?? [];
      worktreesLoaded = true;
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

    async function sessionAction(type, session) {
      if (type === 'cleanup' && !confirm(`${session.alias || session.id} 세션을 리셋할까?\n(로그·pid·포트 설정·alias 삭제 — 코드/worktree 는 무관)`)) return;
      await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root})
      });
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
