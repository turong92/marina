(() => {
  const openButton = document.getElementById('userManagementBtn');
  const logoutButton = document.getElementById('accountLogoutBtn');
  const dialog = document.getElementById('userManagementDialog');
  const closeButton = document.getElementById('userManagementClose');
  const addForm = document.getElementById('authUserAddForm');
  const statusBox = document.getElementById('authUsersStatus');
  const tbody = dialog.querySelector('tbody');
  const actionPaths = {
    approve: '/api/auth/users/approve',
    reject: '/api/auth/users/reject',
    disable: '/api/auth/users/disable',
    'reset-password': '/api/auth/users/reset-password',
  };

  async function authMutation(path, body) {
    return api(path, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify(body || {}),
    });
  }

  function roleLabel(role) { return role === 'admin' ? '관리자' : '팀원'; }
  function statusLabel(status) {
    return ({unclaimed: '설정 전', pending_approval: '승인 대기', active: '활성', disabled: '비활성'})[status] || status;
  }

  function renderAuthUsers(users) {
    tbody.innerHTML = users.length ? users.map(user => `<tr>
      <td data-label="계정"><b>${escapeHtml(user.username)}</b><small>${escapeHtml(user.displayName)}</small></td>
      <td data-label="역할">${escapeHtml(roleLabel(user.role))}</td>
      <td data-label="상태"><span class="auth-user-state ${escapeHtml(user.status)}">${escapeHtml(statusLabel(user.status))}</span></td>
      <td class="auth-user-actions">
        ${user.status === 'pending_approval' ? `<button type="button" data-auth-action="approve" data-username="${escapeHtml(user.username)}">승인</button><button type="button" data-auth-action="reject" data-username="${escapeHtml(user.username)}">거절</button>` : ''}
        ${user.canDisable ? `<button type="button" data-auth-action="disable" data-username="${escapeHtml(user.username)}">비활성화</button>` : ''}
        ${user.canResetPassword ? `<button type="button" data-auth-action="reset-password" data-username="${escapeHtml(user.username)}">초기화</button>` : ''}
      </td>
    </tr>`).join('') : '<tr><td colspan="4" class="auth-users-empty">등록된 계정이 없습니다.</td></tr>';
  }

  async function loadAuthUsers() {
    statusBox.hidden = false;
    statusBox.textContent = '불러오는 중';
    try {
      const payload = await api('/api/auth/users');
      renderAuthUsers(payload.users || []);
      statusBox.hidden = true;
    } catch (error) {
      statusBox.textContent = String(error.message || error);
    }
  }

  function closeDialog() { dialog.hidden = true; }

  openButton.onclick = () => {
    const settings = document.getElementById('settingsMenu');
    if (settings) settings.hidden = true;
    dialog.hidden = false;
    loadAuthUsers();
  };
  closeButton.onclick = closeDialog;
  dialog.onclick = event => { if (event.target === dialog) closeDialog(); };
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !dialog.hidden) closeDialog();
  });

  addForm.onsubmit = async event => {
    event.preventDefault();
    const button = addForm.querySelector('button[type="submit"]');
    const data = new FormData(addForm);
    button.disabled = true;
    try {
      await authMutation('/api/auth/users/add', {
        username: String(data.get('username') || '').trim(),
        displayName: String(data.get('displayName') || '').trim(),
        role: String(data.get('role') || 'member'),
      });
      addForm.reset();
      showToast('계정을 등록했습니다.', 'ok');
      await loadAuthUsers();
    } catch (error) {
      showToast(String(error.message || error), 'err');
    } finally {
      button.disabled = false;
    }
  };

  tbody.onclick = async event => {
    const button = event.target.closest('[data-auth-action]');
    if (!button) return;
    const action = button.dataset.authAction;
    const path = actionPaths[action];
    if (!path) return;
    const username = button.dataset.username;
    const confirmations = {
      reject: `${username}의 승인 요청을 거절할까요?`,
      disable: `${username} 계정을 비활성화할까요?`,
      'reset-password': `${username}의 비밀번호와 로그인 세션을 초기화할까요?`,
    };
    if (confirmations[action] && !confirm(confirmations[action])) return;
    button.disabled = true;
    try {
      await authMutation(path, {username});
      await loadAuthUsers();
    } catch (error) {
      showToast(String(error.message || error), 'err');
      button.disabled = false;
    }
  };

  document.getElementById('revokeAllSessionsBtn').onclick = async () => {
    if (!confirm('모든 기기에서 로그아웃할까요?')) return;
    await authMutation('/api/auth/sessions/revoke-all');
    location.replace('/login');
  };
  logoutButton.onclick = () => window.marinaAuth.logout();

  window.marinaAuth.refresh().then(state => {
    logoutButton.hidden = !state.enabled;
    openButton.hidden = state.user?.role !== 'admin';
  }).catch(() => {
    logoutButton.hidden = true;
    openButton.hidden = true;
  });
})();
