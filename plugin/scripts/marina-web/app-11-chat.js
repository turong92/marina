    // ── 대화 워크스페이스 — 에이전트 세션 멀티탭 ──
    //
    // 멘탈 모델: **에이전트 세션은 여기서, 셸은 터미널 탭에서.** 예전엔 터미널 탭이 둘을 겸했다
    // (AGENTS 행 클릭 = claude --resume PTY attach). 그래서 한 세션을 여는 길이 둘이었고, 무엇보다
    // detach 된 세션·과거 세션의 **이미지를 볼 방법이 없었다** — 터미널은 살아있는 PTY 만 보여준다.
    // 여기 [대화] 는 트랜스크립트 파일이 진실이라 PTY 가 없어도 보인다. [원본] 은 같은 세션의 PTY 를
    // 그대로 띄운다(권한 프롬프트·/명령·TUI 조작은 정리된 뷰로 못 한다). 같은 세션의 두 렌즈다.
    //
    // 탭은 **브라우저 탭처럼 워크트리를 넘나든다.** 다른 워크트리 세션을 열면 교체가 아니라 추가다.
    // 탭마다 상태가 독립이다(커서·아이템·스크롤·view·초안) — 탭을 바꿔도 치던 글이 날아가지 않는다.
    //
    // 타임라인 렌더는 chat-render.js(모바일과 공유)가 한다. 이 파일은 탭 셸·폴링·전송만 맡는다.
    const CHAT_TABS_KEY = 'marina.chat.tabs';
    let chatTabs = [];
    let chatActive = -1;
    let chatTimer = null;
    let chatSending = false;     // 전송 중 — 폴링 재렌더 금지
    let chatAnswering = false;   // 질문 카드 응답 중 — 폴링 재렌더 금지

    function activeChatTab() {
      return chatActive >= 0 && chatActive < chatTabs.length ? chatTabs[chatActive] : null;
    }
    function chatTabKey(tab) { return `${tab.root} ${tab.source} ${tab.sid}`; }
    function chatAgentsFor(root) {
      const wt = worktreeData.find(w => w.root === root);
      return ((wt && wt.agents) || []).filter(a => a.sid);
    }
    function chatPane() { return document.getElementById('tab-chat'); }

    function saveChatTabs() {
      // 영속화는 '어느 세션이 열려 있었나'만 — 트랜스크립트 본문은 다시 받으면 된다.
      const slim = chatTabs.map(t => ({root: t.root, source: t.source, sid: t.sid,
                                       title: t.title, view: t.view, draft: t.draft || ''}));
      try { localStorage.setItem(CHAT_TABS_KEY, JSON.stringify({tabs: slim, active: chatActive})); }
      catch {}
    }
    function loadChatTabs() {
      let saved = null;
      try { saved = JSON.parse(localStorage.getItem(CHAT_TABS_KEY) || 'null'); } catch {}
      if (!saved || !Array.isArray(saved.tabs) || !saved.tabs.length) return;
      chatTabs = saved.tabs.map(t => ({...t, cursor: null, items: [], hasMore: false, paged: false,
                                       attachments: [], scrollTop: 0, seenTs: 0, unread: false}));
      chatActive = Math.min(Math.max(0, saved.active | 0), chatTabs.length - 1);
    }
    // 세션이 사라졌으면(7일 지남·삭제) 조용히 걷어낸다. worktreeData 가 아직 안 왔으면 건드리지 않는다 —
    // 첫 폴링 전에 정리하면 복원한 탭을 전부 날린다.
    function pruneChatTabs() {
      if (!worktreeData.length || !chatTabs.length) return;
      const alive = new Set();
      for (const wt of worktreeData) {
        for (const a of (wt.agents || [])) if (a.sid) alive.add(`${wt.root} ${a.source} ${a.sid}`);
      }
      const before = chatTabs.length;
      const activeKey = activeChatTab() && chatTabKey(activeChatTab());
      chatTabs = chatTabs.filter(t => alive.has(chatTabKey(t)));
      if (chatTabs.length === before) return;
      const at = chatTabs.findIndex(t => chatTabKey(t) === activeKey);
      chatActive = chatTabs.length ? (at >= 0 ? at : 0) : -1;
      saveChatTabs();
      if (!chatPane().hidden) renderChatPane();
    }
    // 비활성 탭의 '새 턴' 점 — 트랜스크립트를 받지 않고 statusTs 변화만으로 판정한다.
    // 탭 N개를 각각 폴링하면 N배 부하다. loadWorktrees 는 어차피 5초마다 돈다.
    function markChatUnread() {
      let changed = false;
      chatTabs.forEach((t, i) => {
        const wt = worktreeData.find(w => w.root === t.root);
        const a = ((wt && wt.agents) || []).find(x => x.sid === t.sid && x.source === t.source);
        if (!a) return;
        if (a.title && a.title !== t.title) { t.title = a.title; changed = true; }
        const ts = a.statusTs || a.ts || 0;
        if (i === chatActive) { t.seenTs = ts; if (t.unread) { t.unread = false; changed = true; } return; }
        if (ts > (t.seenTs || 0) && !t.unread) { t.unread = true; changed = true; }
      });
      if (changed && !chatPane().hidden) renderChatPane();
    }

    // AGENTS 행 진입점 — 이미 열린 세션이면 새 탭이 아니라 그 탭으로 간다(브라우저와 같은 감각).
    function openAgentChat(root, agent) {
      const key = `${root} ${agent.source} ${agent.sid}`;
      const at = chatTabs.findIndex(t => chatTabKey(t) === key);
      if (at >= 0) chatActive = at;
      else {
        chatTabs.push({root, source: agent.source, sid: agent.sid,
                       title: agent.title || String(agent.sid).slice(0, 8),
                       view: 'chat', cursor: null, items: [], hasMore: false, paged: false, draft: '',
                       attachments: [], scrollTop: 0, seenTs: agent.statusTs || agent.ts || 0,
                       unread: false});
        chatActive = chatTabs.length - 1;
      }
      saveChatTabs();
      const wasOn = typeof wsActive !== 'undefined' && wsActive === 'chat';
      if (typeof setWsTab === 'function') setWsTab('chat');
      if (wasOn) { renderChatPane(); loadChatTranscript(true).catch(console.error); }
    }

    function closeChatTab(i) {
      if (i < 0 || i >= chatTabs.length) return;
      chatTabs.splice(i, 1);
      if (!chatTabs.length) chatActive = -1;
      else if (i < chatActive) chatActive -= 1;
      else if (chatActive >= chatTabs.length) chatActive = chatTabs.length - 1;
      saveChatTabs();
      renderChatPane();
      if (activeChatTab()) loadChatTranscript(true).catch(console.error);
    }

    function chatTabLabel(tab, showRoot) {
      const head = tab.source === 'codex' ? 'Codex' : 'Claude';
      const wt = showRoot ? `${escapeHtml(tab.root.split('/').filter(Boolean).pop() || '')} · ` : '';
      return `${wt}${head} · ${escapeHtml(tab.title)}`;
    }

    function renderChatPane() {
      const pane = chatPane();
      if (!pane) return;
      if (!chatTabs.length) {
        if (typeof unmountAgentTerms === 'function') unmountAgentTerms();
        pane.innerHTML = `<div class="chat-empty">
          <div class="chat-empty-title">열린 대화가 없어요</div>
          <div class="chat-empty-hint">왼쪽 AGENTS 행을 누르거나 아래에서 세션을 고르세요</div>
          <button class="chat-open-btn" data-chat-open>세션 열기</button></div>`;
        pane.querySelector('[data-chat-open]').onclick = (e) => openChatPicker(e.currentTarget);
        return;
      }
      const tab = activeChatTab();
      // 워크트리가 둘 이상 열려 있을 때만 워크트리명을 붙인다 — 같은 워크트리끼리는 군더더기.
      const showRoot = new Set(chatTabs.map(t => t.root)).size > 1;
      pane.innerHTML = `
        <div class="chat-tabstrip" data-chat-tabstrip>
          ${chatTabs.map((t, i) => `
            <span class="chat-tab${i === chatActive ? ' active' : ''}${t.unread ? ' unread' : ''}"
                  data-chat-tab="${i}" role="button" tabindex="0" title="${escapeHtml(t.root)}">
              <i class="chat-tab-dot" aria-hidden="true"></i>
              <span class="chat-tab-label">${chatTabLabel(t, showRoot)}</span>
              <b class="chat-tab-x" data-chat-tab-close="${i}" title="닫기 (가운데 클릭도 가능)">✕</b>
            </span>`).join('')}
          <button class="chat-tab-add" data-chat-add title="세션 탭 추가">＋</button>
        </div>
        <div class="chat-head">
          <div class="segments chat-view-tabs">
            <button data-chat-view="chat" class="${tab.view === 'chat' ? 'active' : ''}"
              title="정리된 타임라인 — 이미지·도구활동·질문 카드">대화</button>
            <button data-chat-view="raw" class="${tab.view === 'raw' ? 'active' : ''}"
              title="이 세션의 터미널 원본 — 권한 프롬프트·/명령·TUI 조작">원본</button>
          </div>
          <button class="chat-gal-btn" data-chat-gallery title="모아보기 — 이 세션의 이미지·만든 파일 전부">모아보기</button>
          <span class="chat-head-root">${escapeHtml(tab.root)}</span>
        </div>
        <div class="chat-body" data-chat-body></div>`;

      pane.querySelectorAll('[data-chat-tab]').forEach(el => {
        const i = Number(el.dataset.chatTab);
        el.onclick = (e) => {
          if (e.target.closest('[data-chat-tab-close]')) return;
          if (i === chatActive) return;
          chatActive = i;
          chatTabs[i].unread = false;
          saveChatTabs();
          renderChatPane();
          loadChatTranscript(true).catch(console.error);
        };
        el.onauxclick = (e) => { if (e.button === 1) { e.preventDefault(); closeChatTab(i); } };
      });
      pane.querySelectorAll('[data-chat-tab-close]').forEach(x => {
        x.onclick = (e) => { e.stopPropagation(); closeChatTab(Number(x.dataset.chatTabClose)); };
      });
      pane.querySelector('[data-chat-add]').onclick = (e) => openChatPicker(e.currentTarget);
      pane.querySelector('[data-chat-gallery]').onclick = () => openChatGallery(tab);
      pane.querySelectorAll('[data-chat-view]').forEach(btn => {
        btn.onclick = () => { tab.view = btn.dataset.chatView; saveChatTabs(); renderChatPane(); };
      });

      const body = pane.querySelector('[data-chat-body]');
      // pane 을 갈아엎었으므로 직전 raw xterm 의 등록을 먼저 푼다 — 안 그러면 chatTermInsts 가
      // 세션을 열 때마다 자라고, 죽은 세션이 영영 dispose 되지 않는다.
      if (typeof unmountAgentTerms === 'function') unmountAgentTerms();
      if (tab.view === 'raw') mountAgentTerm(body, tab.root, tab);
      else renderChatConversation(body);
    }

    // ＋ — 지금 선택된 워크트리에서 아직 안 열린 세션을 고르게 한다.
    function openChatPicker(anchor) {
      const root = (selected && selected.root) || (sessions[0] && sessions[0].root);
      if (!root) { showToast('워크트리를 먼저 고르세요', 'err'); return; }
      const open = new Set(chatTabs.map(chatTabKey));
      const rest = chatAgentsFor(root).filter(a => !open.has(`${root} ${a.source} ${a.sid}`));
      const ex = document.getElementById('chatPicker'); if (ex) ex.remove();
      const menu = document.createElement('div');
      menu.id = 'chatPicker';
      menu.className = 'chat-picker';
      menu.innerHTML = rest.length
        ? rest.map(a => `<button data-pick-sid="${escapeHtml(a.sid)}">${a.source === 'codex' ? 'Codex' : 'Claude'} · ${escapeHtml(a.title || a.sid.slice(0, 8))}</button>`).join('')
        : `<div class="chat-picker-empty">${chatAgentsFor(root).length ? '이 워크트리 세션은 모두 열려 있어요' : '이 워크트리에 에이전트 세션이 없어요'}</div>
           <button data-pick-launch>세션 시작</button>`;
      document.body.appendChild(menu);
      const r = anchor.getBoundingClientRect();
      // 뷰포트 밖으로 나가지 않게 — 좁은 창에서 오른쪽으로 새는 걸 막는다
      menu.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - menu.offsetWidth - 8))}px`;
      menu.style.top = `${Math.min(r.bottom + 4, window.innerHeight - menu.offsetHeight - 8)}px`;
      const close = () => { menu.remove(); document.removeEventListener('click', onDoc, true); };
      const onDoc = (e) => { if (!menu.contains(e.target) && e.target !== anchor) close(); };
      setTimeout(() => document.addEventListener('click', onDoc, true), 0);
      menu.querySelectorAll('[data-pick-sid]').forEach(btn => {
        btn.onclick = () => {
          const a = rest.find(x => x.sid === btn.dataset.pickSid);
          close();
          if (a) openAgentChat(root, a);
        };
      });
      const launch = menu.querySelector('[data-pick-launch]');
      if (launch) launch.onclick = () => { close(); launchChatSession(root); };
    }

    async function launchChatSession(root) {
      try {
        const r = await api('/api/agent/launch', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({root, source: 'claude'}),
        });
        showToast('세션을 시작했어요 — 곧 목록에 떠요', 'ok');
        if (typeof loadWorktrees === 'function') await loadWorktrees();
        const fresh = chatAgentsFor(root)[0];
        if (fresh) openAgentChat(root, fresh);
        else if (r && r.tid) renderChatPane();
      } catch (e) {
        showToast(`세션 시작 실패 · ${e.message}`, 'err');
      }
    }

    // ── 트랜스크립트 ──
    function chatAdapter(tab) {
      const q = `root=${enc(tab.root)}&source=${enc(tab.source)}&sid=${enc(tab.sid)}`;
      return {
        imageUrl: (ref) => `/api/agent/transcript-image?${q}&ref=${enc(ref || '')}`,
        fileUrl: (path) => `/api/agent/session-file?root=${enc(tab.root)}&path=${enc(path || '')}`,
        uploadUrl: (nameOrPath) => `/api/agent/file?name=${enc(String(nameOrPath || '').split('/').pop())}`,
        displayModel: (model) => String(model || ''),
        ensureAnswerState: () => null,   // 웹 대화 탭은 아직 질문 카드를 읽기 전용으로만 그린다
      };
    }

    // 요청 세대 번호 — 같은 탭에서 R1 을 보낸 뒤 R2 를 보내면 R1 이 늦게 도착해 최신을 과거로
    // 덮을 수 있다. 탭 키 비교만으론 그 역전을 못 막는다(둘 다 같은 탭이니까).
    let chatReqSeq = 0;

    async function loadChatTranscript(initial) {
      const tab = activeChatTab();
      if (!tab) return;
      const key = chatTabKey(tab);
      const seq = ++chatReqSeq;
      const before = !initial && tab.cursor != null ? `&before=${enc(tab.cursor)}` : '';
      const d = await api(`/api/agent/transcript?root=${enc(tab.root)}&source=${enc(tab.source)}&sid=${enc(tab.sid)}${before}`);
      // 응답이 오는 사이 탭을 바꿨거나(남의 응답) 더 새 요청이 떠났으면(역전) 버린다.
      const now = activeChatTab();
      if (!now || chatTabKey(now) !== key || seq !== chatReqSeq) return;
      // **서버의 timeline 이 진실이다.** turns 는 평문 메시지만이라 도구 활동·diff·이미지 ref·
      // 질문 활동이 전부 빠진다 — timelineFromTurns 는 timeline 이 없을 때의 폴백일 뿐이다.
      const fresh = (d.timeline && d.timeline.length)
        ? d.timeline : MarinaChat.timelineFromTurns(d.turns || []);
      // 이전 메시지를 펼쳐 본 뒤에는 폴링이 최근 페이지로 갈아엎으면 안 된다 — 읽던 과거가 사라진다.
      tab.items = (initial && !tab.paged) ? fresh : MarinaChat.mergeTimelineItems(fresh, tab.items);
      if (!initial) {
        tab.paged = true;                       // 과거를 한 번이라도 붙였다 → 이후 폴링은 병합
        tab.cursor = d.cursor != null ? d.cursor : null;
        tab.hasMore = Boolean(d.hasMore);
      } else if (!tab.paged) {
        tab.cursor = d.cursor != null ? d.cursor : null;
        tab.hasMore = Boolean(d.hasMore);
      }
      tab.unread = false;
      const body = chatPane().querySelector('[data-chat-body]');
      if (body && tab.view === 'chat') renderChatConversation(body);
    }

    function renderChatConversation(body) {
      const tab = activeChatTab();
      if (!tab) return;
      MarinaChat.configure(chatAdapter(tab));
      MarinaChat.setDetailScope(chatTabKey(tab));
      if (!body.querySelector('[data-chat-turns]')) {
        body.innerHTML = `
          <button class="chat-older-btn" data-chat-older hidden>이전 메시지</button>
          <div class="chat-turns" data-chat-turns></div>
          <div class="chat-composer" data-chat-composer></div>`;
        body.querySelector('[data-chat-older]').onclick = () => loadChatTranscript(false).catch(console.error);
        renderChatComposer(body.querySelector('[data-chat-composer]'), tab);
        // 펼침 상태는 렌더러가 세션 스코프로 기억한다 — 모바일과 같은 규칙.
        body.querySelector('[data-chat-turns]').addEventListener('toggle', (e) => {
          const d = e.target.closest && e.target.closest('details[data-timeline-detail]');
          if (d) MarinaChat.noteDetailToggle(d.getAttribute('data-timeline-detail') || 'detail', d.open);
        }, true);
      }
      body.querySelector('[data-chat-older]').hidden = !tab.hasMore;
      const list = body.querySelector('[data-chat-turns]');
      const first = !list.childElementCount;
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
      // 대기 중인 질문이 있으면 카드를 **읽기 전용**으로 얹는다. 웹에서 응답까지 하려면 모바일의
      // 선택 상태 로직(pickAnswerOption·ensureAnswerState)이 필요한데, 여기 베끼면 또 두 벌이 된다.
      // 그 로직을 공유 렌더러로 올리는 게 정석이고, 그건 다음 사이클이다.
      const pending = MarinaChat.pendingQuestionActivity(
        {activities: (tab.items || []).filter(i => i.kind === 'activity')});
      const card = pending ? MarinaChat.renderQuestionCard(pending, false, null)
        + '<div class="chat-answer-hint">이 질문은 모바일이나 [원본] 터미널에서 골라주세요</div>' : '';
      list.innerHTML = MarinaChat.renderTimelineSequence(tab.items) + card;
      if (first) list.scrollTop = tab.scrollTop || list.scrollHeight;
      else if (atBottom) list.scrollTop = list.scrollHeight;
      list.onscroll = () => { tab.scrollTop = list.scrollTop; };
      wireChatViewables(list, tab);
    }

    // 이미지·파일 클릭 = 앱 안 뷰어. **A안** — 넘기면 그 대화에 나온 것만 순서대로 흐른다
    // (형: "해당 채팅에서는 해당 채팅 내용만"). 새 탭으로 던지면 대화 맥락이 끊긴다.
    function wireChatViewables(list, tab) {
      const viewables = MarinaChat.collectViewables(tab.items || []);
      list.querySelectorAll('[data-image-ref]').forEach(el => {
        el.onclick = (e) => {
          e.preventDefault();
          const ref = el.getAttribute('data-image-ref');
          openChatViewer(tab, viewables, viewables.findIndex(v => v.ref === ref));
        };
      });
      list.querySelectorAll('[data-file-path]').forEach(el => {
        el.onclick = (e) => {
          e.preventDefault();
          e.stopPropagation();   // <summary> 안이라 안 막으면 접힘이 같이 토글된다
          const path = el.getAttribute('data-file-path');
          openChatViewer(tab, viewables, viewables.findIndex(v => v.path === path));
        };
      });
    }

    function renderChatComposer(el, tab) {
      el.innerHTML = `
        <div class="chat-attach-strip" data-chat-attach hidden></div>
        <div class="chat-input-row">
          <button class="chat-attach-btn" data-chat-attach-btn title="이미지·파일 첨부">＋</button>
          <textarea class="chat-prompt" data-chat-prompt rows="1"
            placeholder="메시지 — Enter 전송 · Shift+Enter 줄바꿈"></textarea>
          <button class="chat-stop-btn" data-chat-stop title="현재 턴 정지">정지</button>
          <button class="chat-send-btn" data-chat-send>전송</button>
        </div>
        <input type="file" data-chat-file hidden multiple />`;
      const prompt = el.querySelector('[data-chat-prompt]');
      prompt.value = tab.draft || '';                 // 탭마다 초안이 독립 — 바꿔도 안 날아간다
      prompt.oninput = () => { tab.draft = prompt.value; };
      const file = el.querySelector('[data-chat-file]');
      el.querySelector('[data-chat-attach-btn]').onclick = () => file.click();
      file.onchange = () => uploadChatFiles(tab, [...file.files])
        .catch(e => showToast(`첨부 실패 · ${e.message}`, 'err'))
        .finally(() => { file.value = ''; });
      el.querySelector('[data-chat-send]').onclick = () => submitChat(prompt, tab);
      el.querySelector('[data-chat-stop]').onclick = () => interruptChat(tab);
      prompt.onkeydown = (e) => {
        // isComposing — 한글 조립 중 엔터를 가로채면 마지막 음절이 깨진다(모바일에서 겪은 버그).
        if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submitChat(prompt, tab); }
      };
      renderChatAttachStrip(el, tab);
    }

    function renderChatAttachStrip(el, tab) {
      const strip = el.querySelector('[data-chat-attach]');
      const items = tab.attachments || [];
      strip.hidden = !items.length;
      strip.innerHTML = items.map((a, i) =>
        `<span class="chat-attach-chip">${escapeHtml(a.name)}<b data-chat-attach-del="${i}" title="빼기">✕</b></span>`).join('');
      strip.querySelectorAll('[data-chat-attach-del]').forEach(b => {
        b.onclick = () => { tab.attachments.splice(Number(b.dataset.chatAttachDel), 1); renderChatAttachStrip(el, tab); };
      });
    }

    async function uploadChatFiles(tab, files) {
      for (const f of files) {
        const res = await fetch(`/api/agent/upload?root=${enc(tab.root)}`, {
          method: 'POST',
          headers: {'x-marina-filename': encodeURIComponent(f.name), 'content-type': 'application/octet-stream'},
          body: f,
        });
        if (!res.ok) throw new Error(await res.text());
        const d = await res.json();
        (tab.attachments = tab.attachments || []).push({name: d.path || d.stored || f.name});
      }
      const el = chatPane().querySelector('[data-chat-composer]');
      if (el) renderChatAttachStrip(el, tab);
    }

    async function submitChat(prompt, tab) {
      const text = prompt.value.trim();
      const attachments = (tab.attachments || []).map(a => a.name);
      if (!text && !attachments.length) return;
      prompt.value = '';
      tab.draft = '';
      chatSending = true;
      try {
        await api('/api/agent/send', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({
            root: tab.root, text,
            target: {type: 'agent', source: tab.source, sid: tab.sid},
            attachments,
          }),
        });
        tab.attachments = [];
        saveChatTabs();
        await loadChatTranscript(true);
      } catch (e) {
        prompt.value = text;   // 실패하면 입력을 돌려준다 — 날리면 다시 못 친다
        tab.draft = text;
        showToast(`전송 실패 · ${e.message}`, 'err');
      } finally {
        chatSending = false;
      }
    }

    async function interruptChat(tab) {
      try {
        await api('/api/agent/interrupt', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({root: tab.root, target: {type: 'agent', source: tab.source, sid: tab.sid}}),
        });
        showToast('정지를 보냈어요', 'ok');
      } catch (e) {
        showToast(`정지 실패 · ${e.message}`, 'err');
      }
    }

    // ── 뷰어 — 모바일과 같은 계약: (목록, 위치). 마크업 클래스명도 모바일과 맞춰 스킨만 다르다. ──
    let viewerState = null;   // {tab, list, idx, seq}

    function openChatViewer(tab, list, index) {
      if (!list.length || index < 0) return;
      viewerState = {tab, list, idx: index, seq: 0};
      let back = document.getElementById('chatViewer');
      if (!back) {
        back = document.createElement('div');
        back.id = 'chatViewer';
        back.className = 'chat-viewer';
        back.innerHTML = `
          <div class="cv-bar">
            <span class="cv-name" data-cv-name></span>
            <span class="cv-count" data-cv-count></span>
            <button class="cv-x" data-cv-close title="닫기 (Esc)">✕</button>
          </div>
          <div class="cv-body" data-cv-body></div>
          <button class="cv-nav prev" data-cv-step="-1" title="이전 (←)">‹</button>
          <button class="cv-nav next" data-cv-step="1" title="다음 (→)">›</button>`;
        document.body.appendChild(back);
        back.onclick = (e) => { if (e.target === back) closeChatViewer(); };
        back.querySelector('[data-cv-close]').onclick = closeChatViewer;
        back.querySelectorAll('[data-cv-step]').forEach(b => {
          b.onclick = () => stepChatViewer(Number(b.dataset.cvStep));
        });
        document.addEventListener('keydown', chatViewerKeys);
      }
      back.hidden = false;
      renderChatViewer();
    }
    function chatViewerKeys(e) {
      if (!viewerState) return;
      if (e.key === 'Escape') closeChatViewer();
      else if (e.key === 'ArrowLeft') { e.preventDefault(); stepChatViewer(-1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); stepChatViewer(1); }
    }
    function closeChatViewer() {
      const back = document.getElementById('chatViewer');
      if (back) back.hidden = true;
      viewerState = null;
    }
    function stepChatViewer(delta) {
      if (!viewerState) return;
      const at = viewerState.idx + delta;
      if (at < 0 || at >= viewerState.list.length) return;
      viewerState.idx = at;
      renderChatViewer();
    }
    async function renderChatViewer() {
      const st = viewerState;
      if (!st) return;
      const back = document.getElementById('chatViewer');
      const item = st.list[st.idx];
      const ad = chatAdapter(st.tab);
      const seq = ++st.seq;
      back.querySelector('[data-cv-name]').textContent = item.name || '';
      back.querySelector('[data-cv-count]').textContent =
        st.list.length > 1 ? `${st.idx + 1} / ${st.list.length}` : '';
      back.querySelectorAll('[data-cv-step]').forEach(b => {
        const d = Number(b.dataset.cvStep);
        b.disabled = d < 0 ? st.idx === 0 : st.idx === st.list.length - 1;
        b.style.display = st.list.length > 1 ? '' : 'none';
      });
      const body = back.querySelector('[data-cv-body]');
      const url = item.type === 'image' ? ad.imageUrl(item.ref) : ad.fileUrl(item.path);
      const isImage = item.type === 'image' || MarinaChat.IMAGE_EXT_RE.test(item.path || '');
      if (isImage) { body.innerHTML = `<img class="cv-img" src="${escapeHtml(url)}" alt="${escapeHtml(item.name || '')}" />`; return; }
      body.innerHTML = '<pre class="cv-text">불러오는 중…</pre>';
      try {
        const res = await fetch(url);
        const text = res.ok ? await res.text() : `열기 실패 · ${res.status}`;
        if (seq !== st.seq) return;   // 그 사이 넘어갔다 — 남의 화면을 덮지 않는다
        const CAP = 200000;
        body.innerHTML = `<pre class="cv-text">${escapeHtml(
          text.length > CAP ? `${text.slice(0, CAP)}\n\n… 이하 생략` : (text || '(빈 파일)'))}</pre>`;
      } catch (e) {
        if (seq === st.seq) body.innerHTML = `<pre class="cv-text">열기 실패 · ${escapeHtml(e.message)}</pre>`;
      }
    }

    // 모아보기 — 이 세션의 이미지·파일 전부. 채팅 목록(A안)과 달리 **세션 전체**가 대상이다.
    async function openChatGallery(tab) {
      const ex = document.getElementById('chatGallery'); if (ex) ex.remove();
      const back = document.createElement('div');
      back.id = 'chatGallery';
      back.className = 'modal-backdrop';
      back.style.zIndex = '255';
      back.innerHTML = `<div class="links-modal chat-gallery">
        <div class="links-modal-head"><strong>모아보기 · ${escapeHtml(tab.title)}</strong>
          <button class="links-modal-x" title="닫기 (Esc)">✕</button></div>
        <div class="chat-gal-status" data-gal-status>불러오는 중…</div>
        <div class="chat-gal-grid" data-gal-grid></div>
        <div class="chat-gal-files" data-gal-files></div>
      </div>`;
      document.body.appendChild(back);
      const close = () => { back.remove(); document.removeEventListener('keydown', onKey); };
      const onKey = (e) => { if (e.key === 'Escape' && !viewerState) close(); };
      document.addEventListener('keydown', onKey);
      back.querySelector('.links-modal-x').onclick = close;
      back.onclick = (e) => { if (e.target === back) close(); };
      const q = `root=${enc(tab.root)}&source=${enc(tab.source)}&sid=${enc(tab.sid)}`;
      const ad = chatAdapter(tab);
      try {
        const [imgs, files] = await Promise.all([
          api(`/api/agent/images?${q}`).catch(() => ({images: []})),
          api(`/api/agent/session-files?${q}`).catch(() => ({files: []})),
        ]);
        const imageList = (imgs.images || []).map(i => ({type: 'image', ref: i.ref, name: i.name || '대화 이미지'}));
        const fileList = (files.files || []).map(f => ({type: 'file', path: f.path, name: f.relPath,
                                                        isImage: Boolean(f.isImage), servable: f.servable !== false}));
        back.querySelector('[data-gal-status]').textContent =
          `대화 이미지 ${imageList.length}장 · 만든 파일 ${fileList.length}개`;
        back.querySelector('[data-gal-grid]').innerHTML = imageList.map((v, i) =>
          `<button class="chat-gal-cell" data-gal-img="${i}"><img src="${escapeHtml(ad.imageUrl(v.ref))}" alt="" loading="lazy" /></button>`).join('');
        back.querySelector('[data-gal-files]').innerHTML = fileList.map((v, i) =>
          `<button class="chat-gal-row" data-gal-file="${i}"${v.servable ? '' : ' disabled'}>
             <span class="nm">${escapeHtml(v.name)}</span>
             <span class="st">${v.servable ? '열기 ›' : '열 수 없음'}</span></button>`).join('');
        back.querySelectorAll('[data-gal-img]').forEach(b => {
          b.onclick = () => openChatViewer(tab, imageList, Number(b.dataset.galImg));
        });
        back.querySelectorAll('[data-gal-file]').forEach(b => {
          b.onclick = () => openChatViewer(tab, fileList, Number(b.dataset.galFile));
        });
      } catch (e) {
        back.querySelector('[data-gal-status]').textContent = `모아보기 실패 · ${e.message}`;
      }
    }

    // ── 폴링 — **활성 탭 하나만**. 탭 N개를 각각 돌리면 N배 부하고, 비활성 탭의 '새 턴' 점은
    // markChatUnread 가 이미 도는 loadWorktrees 의 statusTs 로 찍는다.
    // 입력 중·전송 중·응답 중엔 재렌더를 미룬다 — 폴링 재렌더가 포커스와 입력값을 날리는 사고가 있었다.
    function chatStartPoll() {
      if (chatTimer) return;
      chatTimer = setInterval(() => {
        const pane = chatPane();
        const tab = activeChatTab();
        if (!pane || pane.hidden || !tab || tab.view !== 'chat') return;
        const prompt = pane.querySelector('[data-chat-prompt]');
        const typing = prompt && (prompt.value.trim() || document.activeElement === prompt);
        if (typing || chatSending || chatAnswering) return;
        loadChatTranscript(true).catch(console.error);
      }, 3000);
    }
    function chatStopPoll() { clearInterval(chatTimer); chatTimer = null; }

    WS_VIEWS.chat = {
      activate() { renderChatPane(); chatStartPoll(); if (activeChatTab()) loadChatTranscript(true).catch(console.error); },
      deactivate() { chatStopPoll(); if (typeof unmountAgentTerms === 'function') unmountAgentTerms(); },
    };

    loadChatTabs();
