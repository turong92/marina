(() => {
  const nativeFetch = window.fetch.bind(window);

  function cookieValue(name) {
    const prefix = `${encodeURIComponent(name)}=`;
    const entry = String(document.cookie || '').split(';').map(value => value.trim()).find(value => value.startsWith(prefix));
    return entry ? decodeURIComponent(entry.slice(prefix.length)) : '';
  }

  window.fetch = async (input, init = {}) => {
    const rawUrl = typeof input === 'string' ? input : input.url;
    const url = new URL(rawUrl, location.href);
    const method = String(init.method || (typeof input !== 'string' && input.method) || 'GET').toUpperCase();
    const options = Object.assign({}, init);
    if (url.origin === location.origin && !['GET', 'HEAD', 'OPTIONS'].includes(method)) {
      const headers = new Headers(init.headers || (typeof input !== 'string' ? input.headers : undefined));
      const csrf = cookieValue('marina_csrf');
      if (csrf) headers.set('X-Marina-CSRF', csrf);
      options.headers = headers;
    }
    const response = await nativeFetch(input, options);
    if (response.status === 401) {
      const next = location.pathname + location.search;
      location.assign(`/login?next=${encodeURIComponent(next)}`);
    }
    return response;
  };

  async function refresh() {
    const response = await nativeFetch('/api/auth/status', {cache: 'no-store'});
    const state = await response.json();
    window.marinaAuth.enabled = !!state.enabled;
    window.marinaAuth.user = state.user || null;
    return state;
  }

  async function logout() {
    await window.fetch('/api/auth/logout', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
    location.replace('/login');
  }

  window.marinaAuth = {enabled: false, user: null, refresh, logout};
})();
