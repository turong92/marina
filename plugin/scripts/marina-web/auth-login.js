(() => {
  const modes = {
    login: document.getElementById('authLoginForm'),
    bootstrap: document.getElementById('authBootstrapForm'),
    claim: document.getElementById('authClaimForm'),
    pending: document.getElementById('authPending'),
    unavailable: document.getElementById('authUnavailable'),
  };
  const errorBox = document.getElementById('authError');
  const unavailableTitle = document.getElementById('authUnavailableTitle');
  const unavailableMessage = document.getElementById('authUnavailableMessage');
  const unavailableCommand = document.getElementById('authUnavailableCommand');

  function safeNext() {
    const value = new URL(location.href).searchParams.get('next') || '/';
    return value.startsWith('/') && !value.startsWith('//') ? value : '/';
  }

  function show(mode) {
    Object.entries(modes).forEach(([name, element]) => { element.hidden = name !== mode; });
    errorBox.hidden = true;
    const first = modes[mode]?.querySelector('input:not([readonly])');
    if (first) requestAnimationFrame(() => first.focus());
  }

  function showError(error) {
    const retry = Number(error?.retryAfter || 0);
    errorBox.textContent = retry ? `${error.message || '잠시 후 다시 시도하세요.'} (${retry}초)` : (error?.message || '요청을 완료하지 못했습니다.');
    errorBox.hidden = false;
  }

  function showUnavailable(error) {
    const recovery = error?.error === 'auth_unavailable';
    unavailableTitle.textContent = recovery ? '인증 저장소를 열 수 없습니다' : '로컬 설정 필요';
    unavailableMessage.textContent = recovery
      ? 'Marina가 설치된 컴퓨터에서 상태와 대시보드 로그를 확인하세요.'
      : 'Marina가 설치된 컴퓨터에서 관리자 설정을 먼저 완료하세요.';
    unavailableCommand.hidden = !recovery;
    show('unavailable');
  }

  async function call(path, body) {
    const response = await fetch(path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? {} : {'content-type': 'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(payload.message || `HTTP ${response.status}`), payload);
    return payload;
  }

  async function submit(form, action) {
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    errorBox.hidden = true;
    try { await action(new FormData(form)); }
    catch (error) { showError(error); }
    finally { button.disabled = false; }
  }

  modes.login.onsubmit = event => {
    event.preventDefault();
    submit(modes.login, async data => {
      const username = String(data.get('username') || '').trim();
      try {
        await call('/api/auth/login', {username, password: String(data.get('password') || '')});
        location.replace(safeNext());
      } catch (error) {
        if (error.error === 'unclaimed') {
          modes.claim.elements.username.value = username;
          modes.claim.elements.password.value = '';
          modes.claim.elements.confirmPassword.value = '';
          show('claim');
          return;
        }
        if (error.error === 'pending_approval') { show('pending'); return; }
        throw error;
      }
    });
  };

  modes.bootstrap.onsubmit = event => {
    event.preventDefault();
    submit(modes.bootstrap, async data => {
      const password = String(data.get('password') || '');
      if (password !== String(data.get('confirmPassword') || '')) throw {message: '비밀번호 확인이 일치하지 않습니다.'};
      await call('/api/auth/bootstrap', {
        displayName: String(data.get('displayName') || '').trim(),
        username: String(data.get('username') || '').trim(),
        password,
      });
      location.replace(safeNext());
    });
  };

  modes.claim.onsubmit = event => {
    event.preventDefault();
    submit(modes.claim, async data => {
      const password = String(data.get('password') || '');
      if (password !== String(data.get('confirmPassword') || '')) throw {message: '비밀번호 확인이 일치하지 않습니다.'};
      await call('/api/auth/claim', {username: String(data.get('username') || ''), password});
      // 초대받은 계정은 비밀번호를 정하는 순간 활성이다 — 바로 들여보낸다.
      // (예전엔 여기서 '승인 대기'를 띄웠다. 관리자가 만든 계정을 관리자가 또 승인하는
      //  중복이라 없앴다 — marina_auth.claim_user 주석 참조.)
      location.replace(safeNext());
    });
  };

  document.querySelectorAll('[data-auth-back]').forEach(button => {
    button.onclick = () => {
      modes.login.reset();
      show('login');
    };
  });

  // 초대 링크(`/login?claim=<이름>`)로 들어오면 **바로 비밀번호 설정**이다. 없는 비밀번호를
  // 아무거나 넣어 오류를 봐야 이 화면에 닿던 군더더기를 없앤다(형 실사용에서 그 단계에서 헤맸다).
  const 초대 = new URLSearchParams(location.search).get('claim') || '';
  call('/api/auth/status').then(state => {
    if (state.user) location.replace(safeNext());
    else if (!state.enabled && state.bootstrapAllowed) show('bootstrap');
    else if (!state.enabled) showUnavailable();
    else if (초대) {
      modes.claim.elements.username.value = 초대;
      show('claim');
    }
    else show('login');
  }).catch(error => {
    if (error.error === 'auth_unavailable') showUnavailable(error);
    else showError(error);
  });
})();
