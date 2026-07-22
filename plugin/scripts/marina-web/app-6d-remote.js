(() => {
  const openButton = document.getElementById('remoteAccessBtn');
  const dialog = document.getElementById('remoteAccessDialog');
  const publicBadge = document.getElementById('remotePublicStatus');
  const modeBox = document.getElementById('remoteMode');
  const address = document.getElementById('remoteAddress');
  const copyButton = document.getElementById('remoteCopy');
  const errorBox = document.getElementById('remoteError');
  const consent = document.getElementById('remoteConsent');
  const checks = document.getElementById('remoteChecks');
  const password = document.getElementById('remotePassword');
  const buttons = ['remoteOff', 'remoteServe', 'remoteFunnel'].map(id => document.getElementById(id));

  function modeLabel(mode) {
    return ({off: '로컬 전용', serve: 'Tailnet 전용', funnel: '인터넷 공개', conflict: '기존 Tailscale 설정 충돌', offline: 'Tailscale 연결 끊김', unavailable: 'Tailscale 없음'})[mode] || mode || '확인 불가';
  }

  function render(state) {
    const mode = state.mode || state.state || 'off';
    modeBox.textContent = modeLabel(mode);
    publicBadge.hidden = mode !== 'funnel';
    address.hidden = !state.url;
    copyButton.hidden = !state.url;
    if (state.url) { address.href = state.url; address.textContent = state.url; }
    const message = state.error?.message || state.message || '';
    errorBox.hidden = !message;
    errorBox.textContent = message;
    consent.hidden = !state.actionUrl;
    if (state.actionUrl) consent.href = state.actionUrl;
    checks.innerHTML = (state.readiness?.checks || []).map(item => `<div class="remote-check ${item.ok ? 'ok' : 'blocked'}"><span>${item.ok ? '✓' : '×'}</span>${escapeHtml(item.label)}</div>`).join('');
    document.getElementById('remoteOff').disabled = mode === 'off' || !state.owned;
    document.getElementById('remoteServe').disabled = !state.installed || !state.online || !!state.conflict;
    document.getElementById('remoteFunnel').disabled = !state.readiness?.ready;
  }

  async function loadRemote() {
    try { render(await api('/api/remote/status')); }
    catch (error) { render({state: 'error', message: String(error.message || error)}); }
  }

  async function mutate(mode) {
    buttons.forEach(button => { button.disabled = true; });
    let failure = '';
    try {
      const result = await api(`/api/remote/${mode}`, {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify(mode === 'funnel' ? {password: password.value} : {}),
      });
      password.value = '';
      render(result);
      if (result.restartRequired) {
        showToast('원격 주소를 적용하며 대시보드를 재시작합니다.', 'ok');
        setTimeout(() => location.reload(), 1800);
      }
    } catch (error) {
      failure = String(error.message || error);
    } finally {
      await loadRemote();
      if (failure) {
        errorBox.hidden = false;
        errorBox.textContent = failure;
      }
    }
  }

  openButton.onclick = () => {
    document.getElementById('settingsMenu').hidden = true;
    dialog.hidden = false;
    loadRemote();
  };
  document.getElementById('remoteAccessClose').onclick = () => { dialog.hidden = true; };
  dialog.onclick = event => { if (event.target === dialog) dialog.hidden = true; };
  document.getElementById('remoteServe').onclick = () => mutate('serve');
  document.getElementById('remoteFunnel').onclick = () => mutate('funnel');
  document.getElementById('remoteOff').onclick = () => mutate('off');
  copyButton.onclick = async () => { await navigator.clipboard.writeText(address.href); showToast('주소를 복사했습니다.', 'ok'); };
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && !dialog.hidden) dialog.hidden = true; });

  window.marinaAuth.refresh().then(state => {
    openButton.hidden = state.user?.role !== 'admin';
    if (state.user) loadRemote();
  }).catch(() => { openButton.hidden = true; });
  setInterval(() => { if (!document.hidden) loadRemote(); }, 15000);
})();
