(() => {
  const openButton = document.getElementById('mobileAccessBtn');
  const dialog = document.getElementById('mobileAccessDialog');
  const mode = document.getElementById('mobileAccessMode');
  const address = document.getElementById('mobileAccessAddress');
  const message = document.getElementById('mobileAccessMessage');
  const checks = document.getElementById('mobileAccessChecks');
  const enableButton = document.getElementById('mobileAccessEnable');
  const disableButton = document.getElementById('mobileAccessDisable');
  const rotateButton = document.getElementById('mobileAccessRotate');
  const copyButton = document.getElementById('mobileAccessCopy');
  let current = null;

  function render(state) {
    current = state;
    mode.textContent = state.enabled ? '켜짐' : '꺼짐';
    address.hidden = !state.address;
    if (state.address) {
      address.href = state.address;
      address.textContent = state.address;
    }
    const warning = !state.reachable
      ? '현재 대시보드는 로컬에서만 열립니다. 원격 접근에서 Tailnet 연결을 먼저 설정하세요.'
      : '';
    message.hidden = !warning;
    message.textContent = warning;
    checks.innerHTML = [
      {ok: state.enabled, label: state.authEnabled ? '계정 로그인 보호' : '모바일 토큰'},
      {ok: state.tailscaleOnline, label: state.tailscaleInstalled ? 'Tailscale 연결' : 'Tailscale 미설치'},
      {ok: state.reachable, label: '휴대폰 접근 주소'},
    ].map(item => `<div class="remote-check ${item.ok ? 'ok' : 'blocked'}"><span>${item.ok ? '✓' : '×'}</span>${escapeHtml(item.label)}</div>`).join('');
    enableButton.hidden = state.enabled;
    copyButton.hidden = !state.enabled || !state.loginUrl;
    rotateButton.hidden = !state.tokenEnabled || state.authEnabled;
    disableButton.hidden = !state.tokenEnabled || state.authEnabled;
  }

  async function load() {
    try { render(await api('/api/mobile/access')); }
    catch (error) {
      message.hidden = false;
      message.textContent = String(error.message || error);
    }
  }

  async function mutate(action) {
    [enableButton, disableButton, rotateButton, copyButton].forEach(button => { button.disabled = true; });
    try {
      render(await api(`/api/mobile/${action}`, {
        method: 'POST', headers: {'content-type': 'application/json'}, body: '{}',
      }));
      showToast(action === 'disable' ? '모바일 연결을 껐습니다.' : '모바일 연결을 켰습니다.', 'ok');
    } catch (error) {
      message.hidden = false;
      message.textContent = String(error.message || error);
    } finally {
      [enableButton, disableButton, rotateButton, copyButton].forEach(button => { button.disabled = false; });
    }
  }

  openButton.onclick = () => {
    document.getElementById('settingsMenu').hidden = true;
    dialog.hidden = false;
    load();
  };
  document.getElementById('mobileAccessClose').onclick = () => { dialog.hidden = true; };
  dialog.onclick = event => { if (event.target === dialog) dialog.hidden = true; };
  enableButton.onclick = () => mutate('enable');
  disableButton.onclick = () => mutate('disable');
  rotateButton.onclick = () => mutate('rotate');
  copyButton.onclick = async () => {
    if (!current?.loginUrl) return;
    await navigator.clipboard.writeText(current.loginUrl);
    showToast('모바일 로그인 링크를 복사했습니다.', 'ok');
  };
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !dialog.hidden) dialog.hidden = true;
  });

  window.marinaAuth.refresh().then(state => {
    const local = ['localhost', '127.0.0.1', '::1', '0.0.0.0'].includes(location.hostname);
    openButton.hidden = state.enabled ? state.user?.role !== 'admin' : !local;
  }).catch(() => { openButton.hidden = true; });
})();
