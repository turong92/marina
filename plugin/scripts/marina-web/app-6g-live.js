// 상시 운영(live) 영역 — 워크트리 카드 목록과 **분리해서** 그린다.
//
// 왜 분리인가: 워크트리는 "버리는 것" 이고 live 는 "지우면 안 되는 것" 이다. 같은 목록에
// 섞으면 유휴 정리 대상처럼 보인다. 그래서 #liveArea 는 #sessions 밖에 따로 있다.
//
// 왜 초록불이 없나: 앱이 모든 경로를 인증 뒤에 두면 헬스체크가 401 을 받고, 그걸 "살아 있음"
// 으로 처리하면 DB 가 죽어도 healthy 로 남는다(홈서버 구현에서 실측). 그래서 **세 신호를
// 따로** 보여준다 — 컨테이너 상태 / 재시작 횟수 / HTTP 상태코드 그 자체.
(() => {
  const area = document.getElementById('liveArea');
  if (!area) return;

  const esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function healthLine(h) {
    if (!h || !h.declared) return '<span class="live-sig live-sig-none">헬스: 선언 없음</span>';
    if (h.code == null) return `<span class="live-sig live-sig-bad">헬스: 닿지 않음</span>`;
    const cls = (h.code >= 200 && h.code < 300) ? 'live-sig-ok' : 'live-sig-warn';
    // 코드를 그대로 쓴다. 2xx 가 아니면 "모른다" 고 말한다 — 거짓 초록불을 만들지 않는다.
    const note = (h.code >= 200 && h.code < 300) ? '' : ' (안쪽이 살아 있는지는 모른다)';
    return `<span class="live-sig ${cls}">헬스: HTTP ${esc(h.code)}${note}</span>`;   // note 는 코드 안 리터럴
  }

  function card(p) {
    const states = (p.containers || []).map((c) => {
      const cls = c.state === 'running' ? 'live-sig-ok'
        : (c.state === 'restarting' ? 'live-sig-warn' : 'live-sig-bad');
      return `<span class="live-sig ${cls}">${esc(c.service || c.name)}: ${esc(c.state)}</span>`;
    }).join('') || '<span class="live-sig live-sig-bad">컨테이너 없음</span>';
    const restarts = (p.restartsTotal || 0) > 0
      ? `<span class="live-sig live-sig-warn">재시작 ${esc(p.restartsTotal)}회 — 늘고 있으면 크래시 루프다</span>`
      : '<span class="live-sig">재시작 0회</span>';
    // 유닛 설치가 실패해도 기동은 유지되므로, 이 줄이 "재부팅하면 살아나나" 의 유일한 신호다.
    const auto = p.autostart && p.autostart.registered
      ? '<span class="live-sig live-sig-ok">재부팅 후 자동 기동: 등록됨</span>'
      : '<span class="live-sig live-sig-bad">재부팅 후 자동 기동: 안 됨</span>';
    const pub = [];
    if (p.expose && p.expose.funnel) {
      pub.push(`Funnel :${esc(p.expose.funnel.httpsPort)}${esc(p.expose.funnel.path)}`);
    }
    if (p.expose && p.expose.cloudflare) {
      pub.push(`Cloudflare ${esc(p.expose.cloudflare.domain)}`);
    }
    const deploy = p.lastDeploy
      ? `${esc(p.lastDeploy.ref)} · ${esc(p.lastDeploy.at)}`
      : `${esc(p.ref)} · 이력 없음`;
    const data = p.data && p.data.exists
      ? esc(p.data.human)
      : '없음 (아직 기동하지 않았거나 디렉터리가 사라졌다)';
    return `<div class="live-card" data-live-project="${esc(p.project)}">
      <div class="live-head"><b>${esc(p.project)}</b> <span class="live-ref">${esc(p.ref)}</span></div>
      <div class="live-sigs">${states}${restarts}${healthLine(p.health)}${auto}</div>
      <div class="live-meta">배포: ${deploy}</div>
      <div class="live-meta">공개: ${pub.length ? pub.join(' · ') : '안 함 — 로컬·테일넷에서만'}</div>
      <div class="live-meta">데이터: ${esc((p.data || {}).path || '')} ${data}</div>
    </div>`;
  }

  function showError(msg) {
    // **영역을 숨기지 않는다.** 숨기면 "재부팅 후 자동 기동: 안 됨" 신호까지 같이
    // 사라지는데, 설계는 그 줄이 유일한 신호라고 못 박았다 — 실패가 '아무 말 없이
    // 없어지는' 방향이면 안 된다.
    area.hidden = false;
    area.innerHTML = '<div class="live-title">상시 운영 (live)</div>'
      + `<div class="live-error">상태를 읽지 못했다 — ${esc(msg)}</div>`;
  }

  async function refresh() {
    let data;
    try {
      const res = await fetch('/api/live');
      if (!res.ok) { showError(`/api/live → HTTP ${res.status}`); return; }
      data = await res.json();
    } catch (err) { showError(String(err && err.message || err)); return; }
    if (data && data.error) { showError(data.error); return; }
    const list = (data && data.projects) || [];
    if (!list.length) { area.hidden = true; area.innerHTML = ''; return; }
    area.hidden = false;
    area.innerHTML = '<div class="live-title">상시 운영 (live) — 워크트리와 별개, 지우지 않는다</div>'
      + list.map(card).join('');
  }

  refresh();
  setInterval(refresh, 15000);
  window.marinaLiveRefresh = refresh;
})();
