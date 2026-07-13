    // app-6b-notify.js — 브라우저 알림(콘솔 스펙 A3, 옵트인). 헤더 🔔 토글 + 폴링 스냅샷 비교로 상태 전이 감지.
    // app-6-modals.js 의 load() 성공 경로에서 notifyScan(sessions) 훅 1줄만 호출 — 주 로직은 이 파일에 있음(결합 최소).
    // 기본 OFF — localStorage 'marinaNotify' === '1' 이고 Notification.permission === 'granted' 일 때만 OS 알림 발화.
    // 문서가 포커스 상태면(document.hasFocus()) OS 알림 대신 기존 showToast 로 — 창 보고 있는데 OS 알림은 소음.

    const NOTIFY_KEY = 'marinaNotify';
    const NOTIFY_DEDUPE_MS = 60000;   // 같은 (서비스,이벤트) 60s 내 재알림 금지
    let notifyPrevSnapshot = null;    // Map<root::service, {state, session, svc, alias}> — 첫 스캔은 기준선만(알림 금지)
    const notifyLastFired = new Map();   // `${root::service}::${event}` → epoch ms

    function notifySupported() {
      return typeof Notification !== 'undefined';
    }
    function notifyEnabled() {
      return typeof localStorage !== 'undefined' && localStorage.getItem(NOTIFY_KEY) === '1';
    }
    function notifyKey(root, service) { return `${root}::${service}`; }

    // 헤더 버튼 아이콘/title 갱신 — 미지원·거부·꺼짐·켜짐 네 가지 상태를 정직하게 표시.
    function updateNotifyButton() {
      if (typeof document === 'undefined') return;
      const btn = document.getElementById('notifyToggle');
      if (!btn) return;
      if (!notifySupported()) {
        btn.textContent = '🔕';
        btn.title = '이 브라우저는 알림을 지원하지 않아요';
        if (btn.classList) btn.classList.remove('active');
        return;
      }
      if (Notification.permission === 'denied') {
        btn.textContent = '🔕';
        btn.title = '알림 권한이 거부됐어요 — 브라우저 사이트 설정에서 허용해야 켤 수 있어요';
        if (btn.classList) btn.classList.remove('active');
        return;
      }
      const on = notifyEnabled() && Notification.permission === 'granted';
      btn.textContent = on ? '🔔' : '🔕';
      if (btn.classList) btn.classList.toggle('active', on);
      btn.title = on
        ? '기동 완료/실패 알림 켜짐 — 클릭하면 꺼요'
        : '알림 꺼짐(기본, 옵트인) — 클릭하면 서비스 기동 완료/실패를 브라우저 알림으로 받아요';
    }

    // 토글 클릭 — OFF→ON 은 매번 권한 요청(브라우저가 이미 grant/deny 기억이면 즉시 반환), ON→OFF 는 로컬만 끔.
    async function notifyToggleClick() {
      if (!notifySupported()) { updateNotifyButton(); return; }
      if (notifyEnabled()) {
        localStorage.setItem(NOTIFY_KEY, '0');
        updateNotifyButton();
        return;
      }
      let perm;
      try { perm = await Notification.requestPermission(); }
      catch (e) { perm = 'denied'; }
      localStorage.setItem(NOTIFY_KEY, perm === 'granted' ? '1' : '0');
      updateNotifyButton();
    }

    if (typeof document !== 'undefined') {
      const notifyBtn = document.getElementById('notifyToggle');
      if (notifyBtn) notifyBtn.onclick = () => notifyToggleClick().catch(() => {});
      updateNotifyButton();
    }

    // 실제 발화 — 60s 중복 억제 후, 포커스 상태면 토스트, 아니면 OS 알림(옵트인+권한 있을 때만).
    function notifyFire(key, event, session, svc, title, body) {
      const fk = `${key}::${event}`;
      const now = Date.now();
      const last = notifyLastFired.get(fk) || 0;
      if (now - last < NOTIFY_DEDUPE_MS) return;
      notifyLastFired.set(fk, now);
      if (typeof document !== 'undefined' && typeof document.hasFocus === 'function' && document.hasFocus()) {
        if (typeof showToast === 'function') showToast(body, event === 'ready' ? 'ok' : 'err');
        return;
      }
      if (!notifySupported() || !notifyEnabled() || Notification.permission !== 'granted') return;
      try {
        const n = new Notification(title, { body });
        n.onclick = () => {
          try { if (typeof window !== 'undefined' && window.focus) window.focus(); } catch (e) {}
          if (typeof selectLog === 'function') selectLog(session.root, svc.service, 'current', 'service');
          try { n.close(); } catch (e) {}
        };
      } catch (e) { /* 알림 생성 실패(권한/환경 문제) — 조용히 무시 */ }
    }

    // 폴링마다 이전 스냅샷과 비교 — svcState 기준 전이만 감지(콘솔 스펙 A3):
    //   starting → running = 기동 완료 / starting → error = 기동 실패 / running → error = 서비스 이상.
    function notifyScan(sessions) {
      const cur = new Map();
      for (const session of (sessions || [])) {
        const alias = session.alias || session.id || session.root;
        for (const svc of (session.services || [])) {
          if (typeof isInternalService === 'function' && isInternalService(svc)) continue;
          const key = notifyKey(session.root, svc.service);
          const state = typeof svcState === 'function' ? svcState(svc) : (svc.state || 'stopped');
          cur.set(key, { state, session, svc, alias });
        }
      }
      if (!notifyPrevSnapshot) {   // 첫 스냅샷(페이지 로드 직후) — 기준선만 설정, 알림 금지
        notifyPrevSnapshot = cur;
        return;
      }
      for (const [key, info] of cur) {
        const prev = notifyPrevSnapshot.get(key);
        if (!prev) continue;   // 이전 폴링에 없던 서비스(새 등록 등) — 비교 대상 없음, 다음 폴링부터 비교
        if (prev.state === 'starting' && info.state === 'running') {
          notifyFire(key, 'ready', info.session, info.svc,
            'Marina — 빌드/기동 완료', `${info.alias} · ${info.svc.service} 기동 완료`);
        } else if (prev.state === 'starting' && info.state === 'error') {
          notifyFire(key, 'failed', info.session, info.svc,
            'Marina — 기동 실패', `${info.alias} · ${info.svc.service} 기동 실패`);
        } else if (prev.state === 'running' && info.state === 'error') {
          notifyFire(key, 'issue', info.session, info.svc,
            'Marina — 서비스 이상', `${info.alias} · ${info.svc.service} 상태 이상`);
        }
      }
      notifyPrevSnapshot = cur;
    }
