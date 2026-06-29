    // ── 로그 뷰어 엔진: 라인 단위 렌더 + ANSI 컬러 + 레벨 하이라이트 + 필터 + 5천줄 링버퍼 ──
    const LOG_MAX_LINES = 5000;
    const LOG_MATCH_CAP = 2000;  // 서버 LOG_MATCH_CAP 과 동기
    let logEntries = [];
    let logFilterText = '';
    let logErrorsOnly = false;

    const ANSI_FG = {
      30: 'hsl(220, 8%, 50%)', 31: 'hsl(358, 75%, 62%)', 32: 'hsl(148, 55%, 48%)',
      33: 'hsl(40, 85%, 52%)', 34: 'hsl(215, 90%, 62%)', 35: 'hsl(280, 70%, 68%)',
      36: 'hsl(190, 80%, 52%)', 37: 'hsl(220, 14%, 80%)',
      90: 'hsl(220, 8%, 55%)', 91: 'hsl(358, 80%, 68%)', 92: 'hsl(148, 60%, 55%)',
      93: 'hsl(45, 90%, 58%)', 94: 'hsl(215, 95%, 68%)', 95: 'hsl(280, 75%, 74%)',
      96: 'hsl(190, 85%, 60%)', 97: 'hsl(0, 0%, 95%)'
    };

    function ansiToHtml(raw) {
      const parts = raw.split(/\x1b\[([0-9;]*)m/);
      let html = '';
      let color = null;
      let bold = false;
      for (let i = 0; i < parts.length; i++) {
        if (i % 2 === 0) {
          if (!parts[i]) continue;
          const style = [color ? `color:${color}` : '', bold ? 'font-weight:700' : ''].filter(Boolean).join(';');
          html += style ? `<span style="${style}">${escapeHtml(parts[i])}</span>` : escapeHtml(parts[i]);
        } else {
          for (const code of (parts[i] || '0').split(';')) {
            const n = Number(code || 0);
            if (n === 0) { color = null; bold = false; }
            else if (n === 1) bold = true;
            else if (n === 22) bold = false;
            else if (n === 39) color = null;
            else if (ANSI_FG[n]) color = ANSI_FG[n];
          }
        }
      }
      return html;
    }

    function stripAnsi(raw) { return raw.replace(/\x1b\[[0-9;]*m/g, ''); }

    // 파이썬 트레이스백은 여러 줄 한 덩어리 — 시작 줄 이후 들여쓴 연속 줄과
    // 마지막 예외 줄(XxxError: ...)까지 err 로 묶는다 (Err 필터에서 통째로 보이게)
    let logTracebackSticky = false;
    function detectLogLevel(plain) {
      if (/Traceback \(most recent call last\)/.test(plain)) { logTracebackSticky = true; return 'err'; }
      if (logTracebackSticky) {
        if (/^[ \t]/.test(plain) || plain === '') return 'err';
        logTracebackSticky = false;
        if (/^[\w.]+(Error|Exception|Exit|Interrupt|Warning)\b/.test(plain)) return 'err';
      }
      if (/^\s*(Caused by\b|at [\w.$<>/]+\()/.test(plain)) return 'err';
      if (/\[(error|window\.error|unhandledrejection)\]/i.test(plain) || /\b(ERROR|FATAL|SEVERE)\b/.test(plain) || /\b[\w.]*(Exception|Error):/.test(plain) || /Exception|Traceback/.test(plain)) return 'err';
      if (/\[warn\]/i.test(plain) || /\bWARN(ING)?\b/.test(plain)) return 'warn';
      return '';
    }

    function logEntryVisible(entry) {
      if (logErrorsOnly && !entry.level) return false;
      if (logFilterText && !entry.plainLower.includes(logFilterText)) return false;
      return true;
    }

    function updateLogCount() {
      const posEl = document.getElementById('gaugePos');
      if (!selected) { posEl.textContent = ''; renderMatchCount(); return; }
      if (matchView) {
        posEl.textContent = `매치 ${logEntries.length}건 표시`;
      } else {
        const size = Math.max(logFileSize, logWindow.bottom);
        const pct = size ? Math.min(100, Math.round((logWindow.bottom / size) * 100)) : 100;
        posEl.textContent = `${pct}% 지점 · 창 ${logEntries.length}줄`;
      }
      renderMatchCount();
    }

    function renderMatchCount() {
      const el = document.getElementById('matchCount');
      if (!logMatches.active) { el.textContent = ''; return; }
      if (matchView) {
        const cap = logMatches.truncated ? ` (파일 앞쪽 ${logMatches.items?.length ?? 0}건만 표시)` : '';
        el.textContent = `파일 전체 ${logMatches.total}건${cap}`;
        return;
      }
      const visible = logEntries.reduce((sum, entry) => sum + (logEntryVisible(entry) ? 1 : 0), 0);
      const cap = logMatches.truncated ? ` (파일 앞쪽 ${logMatches.offsets.length}건만 틱 표시)` : '';
      el.textContent = `파일 전체 ${logMatches.total}건 · 화면 ${visible}건${cap}`;
    }

    let gaugeRaf = 0;
    function renderGauge() {
      if (gaugeRaf) return;
      gaugeRaf = requestAnimationFrame(() => {
        gaugeRaf = 0;
        const track = document.getElementById('gaugeTrack');
        const win = document.getElementById('gaugeWindow');
        const size = Math.max(logFileSize, logWindow.bottom, 1);
        if (matchView) {
          // 매치 뷰는 파일 전체를 커버 — 창 띠도 전체
          win.style.left = '0%';
          win.style.width = '100%';
        } else {
          win.style.left = `${(logWindow.top / size) * 100}%`;
          win.style.width = `${Math.max(((logWindow.bottom - logWindow.top) / size) * 100, 0.5)}%`;
        }
        for (const tick of track.querySelectorAll('.gauge-tick')) tick.remove();
        if (!logMatches.offsets.length) return;
        // 0.5% 버킷으로 병합 — 매치 수천 개여도 DOM 틱은 최대 200개
        const buckets = new Set();
        for (const offset of logMatches.offsets) buckets.add(Math.round((offset / size) * 200));
        for (const bucket of buckets) {
          const tick = document.createElement('div');
          tick.className = 'gauge-tick';
          tick.style.left = `${bucket / 2}%`;
          track.appendChild(tick);
        }
      });
    }

    function scheduleMatchScan() {
      clearTimeout(matchScanTimer);
      matchScanTimer = setTimeout(() => fetchMatches().catch(console.error), 350);
    }

    async function fetchMatches() {
      logMatches = {offsets: [], total: 0, truncated: false, active: false};
      if (!selected || (!logFilterText && !logErrorsOnly)) {
        renderMatchCount();
        renderGauge();
        if (matchView) {
          // 필터 해제 — 일반 tail 뷰로 복귀 (선택이 사라졌으면 상태만 내린다)
          matchView = false;
          if (selected) selectLog(selected.root, selected.service, selected.run, selected.mode);
        }
        return;
      }
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const reqKey = `${selected.root}|${actualService}|${selected.run}|${logFilterText}|${logErrorsOnly}`;
      const data = await api(`/api/logs/matches?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&q=${enc(logFilterText)}&errOnly=${logErrorsOnly ? 1 : 0}`);
      const nowService = selected && (selected.mode === 'console' ? 'console' : selected.service);
      const nowKey = selected && `${selected.root}|${nowService}|${selected.run}|${logFilterText}|${logErrorsOnly}`;
      if (nowKey !== reqKey) return;  // 응답 대기 중 선택/필터가 바뀜 — 구식 응답 폐기
      logMatches = {offsets: data.matches.map(item => item.o), items: data.matches, total: data.total, truncated: data.truncated, active: true};
      logFileSize = Math.max(logFileSize, data.size);
      enterMatchView();
      renderMatchCount();
      renderGauge();
    }

    // 매치 전용 뷰 — 파일 전체의 매치를 한 번에 목록으로 (cap 2000 ≤ LOG_MAX_LINES 라 안전)
    function enterMatchView() {
      matchView = true;
      resetLogView();
      logTracebackSticky = false;
      const logEl = document.getElementById('log');
      const fragment = document.createDocumentFragment();
      for (const item of logMatches.items ?? []) {
        logTracebackSticky = false;  // 매치는 비연속 발췌 — sticky 가 다음 매치 색상을 오염시키지 않게
        const entry = makeLogEntry(item.t, null);
        entry.matchOffset = item.o;  // 게이지 클릭 → 목록 내 위치 탐색용
        entry.el.hidden = false;  // 서버가 이미 매치 판정 — 클라 재판정으로 숨기지 않는다
        entry.el.classList.add('match-row');
        entry.el.title = '클릭하면 필터를 풀고 이 위치 맥락으로 이동';
        entry.el.onclick = () => exitMatchViewTo(item.o);
        logEntries.push(entry);
        fragment.appendChild(entry.el);
      }
      if (!logEntries.length) {
        logEl.innerHTML = '<div class="empty">매치 없음</div>';
      } else {
        logEl.appendChild(fragment);
        logEl.scrollTop = logEl.scrollHeight;  // 최신 매치부터 — tail 멘탈 유지
      }
      lastLogScrollTop = logEl.scrollTop;
      updateOlderBar();
      updateLogCount();
    }

    // 매치 행 클릭 — 필터를 풀고 그 위치의 전후 맥락으로 점프
    function exitMatchViewTo(offset) {
      matchView = false;
      logFilterText = '';
      document.getElementById('logFilter').value = '';
      logErrorsOnly = false;
      document.getElementById('logErrOnly').classList.remove('active');
      logMatches = {offsets: [], total: 0, truncated: false, active: false};
      renderMatchCount();
      jumpToOffset(offset).catch(console.error);
    }

    // 매치 뷰 중 라이브 신규 라인 — 매치만 목록 끝에 합류 (비매치는 버림)
    function appendLiveMatchLine(raw, end) {
      const lineStart = logWindow.bottom;
      if (end != null) {
        logWindow.bottom = Math.max(logWindow.bottom, end);
        logFileSize = Math.max(logFileSize, end);
      }
      const entry = makeLogEntry(raw, end);
      if (!logEntryVisible(entry)) return;
      entry.matchOffset = lineStart;
      entry.el.hidden = false;
      entry.el.classList.add('match-row');
      entry.el.title = '클릭하면 필터를 풀고 이 위치 맥락으로 이동';
      entry.el.onclick = () => exitMatchViewTo(lineStart);
      logEntries.push(entry);
      logMatches.total += 1;
      if (logMatches.offsets.length < LOG_MATCH_CAP) logMatches.offsets.push(lineStart);
      // 매치 뷰에서 dropOldestLines 의 logWindow.top 갱신은 무의미하지만 무해 — 복귀 시 jumpToOffset 이 덮어씀
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      const logEl = document.getElementById('log');
      const placeholder = logEl.querySelector('.empty');
      if (placeholder) placeholder.remove();
      logEl.appendChild(entry.el);
      if (followLog) {
        logEl.scrollTop = logEl.scrollHeight;
        lastLogScrollTop = logEl.scrollTop;
      }
      updateLogCount();
      renderGauge();
    }

    // 게이지 클릭/매치 탐색 — 그 파일 위치로 점프 (근처 매치 틱이 있으면 스냅)
    let jumpInFlight = false;
    async function jumpToOffset(offset) {
      if (!selected || jumpInFlight) return;
      jumpInFlight = true;
      if (source) source.close();
      resetLogView();
      followLog = false;
      document.getElementById('followLog').classList.remove('active');
      logWindow = {top: offset, bottom: offset, live: false};
      logPaging = {loadingUp: false, loadingDown: false, atStart: offset === 0};
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const base = `/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}`;
      const jumpKey = `${selected.root}|${actualService}|${selected.run}`;
      const stale = () => !selected || matchView || `${selected.root}|${selected.mode === 'console' ? 'console' : selected.service}|${selected.run}` !== jumpKey;
      try {
        const down = await api(`${base}&after=${offset}`);
        if (stale()) return;  // 응답 대기 중 다른 서비스/run 으로 전환 — 구식 응답 폐기
        // 서버가 라인 경계로 정렬한 실제 시작점 — before 도 같은 경계에서 만나 누락·중복 0
        const aligned = down.start;
        logWindow = {top: aligned, bottom: aligned, live: false};
        appendChunkLines(down.lines);
        logWindow.bottom = Math.max(logWindow.bottom, down.end);
        logFileSize = Math.max(logFileSize, down.size);
        const up = await api(`${base}&before=${aligned}`);
        if (stale()) return;
        prependLogLines(up.lines);
        logWindow.top = up.start;
        logFileSize = Math.max(logFileSize, up.size);
        logPaging.atStart = up.atStart;
        const target = logEntries.find(entry => entry.end != null && entry.end > aligned);
        if (target) {
          target.el.scrollIntoView({block: 'center'});
          target.el.classList.add('jump-hit');
          setTimeout(() => target.el.classList.remove('jump-hit'), 1500);
        }
      } catch (err) {
        console.error(err);
      } finally {
        jumpInFlight = false;
        lastLogScrollTop = document.getElementById('log').scrollTop;
        updateOlderBar();
        updateLogCount();
      }
    }

    function appendLogLine(raw, end) {
      const logEl = document.getElementById('log');
      const lineStart = logWindow.bottom;
      const entry = makeLogEntry(raw, end);
      logEntries.push(entry);
      if (entry.end != null) {
        logWindow.bottom = Math.max(logWindow.bottom, entry.end);
        logFileSize = Math.max(logFileSize, entry.end);
        // 라이브 신규 라인도 매치면 게이지 틱·카운트에 합류 (스캔 결과의 연장)
        if (logMatches.active && logEntryVisible(entry)) {
          logMatches.total += 1;
          if (logMatches.offsets.length < LOG_MATCH_CAP) logMatches.offsets.push(lineStart);
        }
      }
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      logEl.appendChild(entry.el);
      if (followLog) {
        logEl.scrollTop = logEl.scrollHeight;
        lastLogScrollTop = logEl.scrollTop;  // follow 점프를 '위로 스크롤' 로 오판하지 않게
      }
      updateLogCount();
      renderGauge();
    }

    function applyLogFilter() {
      if (matchView) { updateLogCount(); return; }  // 매치 뷰는 재스캔(fetchMatches)이 뷰를 재구성
      for (const entry of logEntries) entry.el.hidden = !logEntryVisible(entry);
      updateLogCount();
      if (followLog) {
        const logEl = document.getElementById('log');
        logEl.scrollTop = logEl.scrollHeight;
      }
    }

    function resetLogView(placeholder = '') {
      logEntries = [];
      logTracebackSticky = false;
      const logEl = document.getElementById('log');
      logEl.innerHTML = placeholder ? `<div class="empty">${escapeHtml(placeholder)}</div>` : '';
      logEl.scrollTop = 0;
      lastLogScrollTop = 0;
      updateLogCount();
    }

    function selectLog(root, service, run = 'current', mode = 'service') {
      const {session, service: svc} = serviceMeta(root, service);
      const actualService = mode === 'console' ? 'console' : service;
      selected = {root, service, run, mode};
      expandedRoots.add(root);
      document.getElementById('selectedRoot').textContent = root;
      document.getElementById('selectedLabel').textContent = `${session?.alias || session?.id || '-'} / ${service} / ${mode === 'console' ? 'browser console' : 'server log'}`;
      const isWeb = service === 'web';
      document.getElementById('logModeTabs').classList.toggle('visible', isWeb);
      document.getElementById('openWeb').hidden = !isWeb;
      for (const btn of document.querySelectorAll('[data-log-mode]')) btn.classList.toggle('active', btn.dataset.logMode === mode);
      renderRunSelect(session, service, mode, run);
      render();
      renderSelection();

      if (source) source.close();
      matchView = false;  // 필터가 살아 있으면 fetchMatches 가 새 대상 스캔 후 다시 진입
      resetLogView();
      logWindow = {top: 0, bottom: 0, live: false};
      logPaging = {loadingUp: false, loadingDown: false, atStart: true};
      logFileSize = 0;
      // 새 선택 = 최신 tail 부터 — follow 가 꺼진 채 재진입하면 화면이 창 맨 위에 고정되는 버그 방지
      followLog = true;
      document.getElementById('followLog').classList.add('active');
      updateOlderBar();
      openStream(null);
      fetchMatches().catch(console.error);  // 필터 활성 시 새 대상 재스캔, 아니면 클리어
    }

    // SSE tail 연결 — from 이 있으면 그 오프셋부터 이어받아 forward 페이징과 갭 없이 연결
    function openStream(from) {
      if (source) source.close();
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const fromParam = from != null ? `&from=${from}` : '';
      source = new EventSource(`/api/logs?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}${fromParam}`);
      logWindow.live = true;
      source.addEventListener('meta', (event) => {
        // 서버가 보낸 표시 시작 오프셋 — 그 이전 구간은 위로 스크롤해 페이징
        const meta = JSON.parse(event.data);
        if (!logEntries.length) logWindow.top = meta.start;  // 재연결이면 기존 창 유지
        logWindow.bottom = Math.max(logWindow.bottom, meta.start);
        logFileSize = Math.max(logFileSize, meta.size || 0);
        logPaging.atStart = logWindow.top === 0;
        updateOlderBar();
        updateLogCount();
      });
      source.onmessage = (event) => {
        const item = JSON.parse(event.data);
        if (matchView) appendLiveMatchLine(item.line, item.end);
        else appendLogLine(item.line, item.end);
      };
      source.onerror = () => {
        appendLogLine('[log stream disconnected]');
        source.close();
        logWindow.live = false;
      };
    }

    function fmtKb(bytes) {
      const kb = Math.max(1, Math.round(bytes / 1024));
      return kb >= 1024 ? `${(kb / 1024).toFixed(1)}MB` : `${kb}KB`;
    }

    function updateOlderBar() {
      document.getElementById('olderBar').hidden = !selected;
      if (!selected) return;
      const downNote = logWindow.live ? '' : ' · ↓ 아래로';
      document.getElementById('olderInfo').textContent =
        matchView ? '● 매치 목록 — 파일 전체'
        : logPaging.loadingUp ? '불러오는 중…'
        : logPaging.atStart ? `● 파일 시작${downNote}`
        : `↑ 위에 ${fmtKb(logWindow.top)} 더${downNote}`;
      renderGauge();
    }

    function makeLogEntry(raw, end) {
      const plain = stripAnsi(raw);
      const el = document.createElement('div');
      const level = detectLogLevel(plain);
      el.className = `log-line${level ? ' ' + level : ''}`;
      el.innerHTML = ansiToHtml(raw) || '&nbsp;';
      const entry = {level, plainLower: plain.toLowerCase(), el, end: end ?? null};
      el.hidden = !logEntryVisible(entry);
      return entry;
    }

    // 창 상단(과거쪽) 라인 제거 — 제거된 라인의 끝 오프셋으로 top 경계 전진
    function dropOldestLines(excess) {
      let dropped = false;
      while (excess-- > 0 && logEntries.length) {
        const removed = logEntries.shift();
        removed.el.remove();
        if (removed.end != null) logWindow.top = removed.end;
        dropped = true;
      }
      if (dropped) {
        logPaging.atStart = logWindow.top === 0;
        updateOlderBar();
      }
    }

    // 창 하단(최신쪽) 라인 제거 — 최신 구간을 버렸으니 SSE tail 도 분리 (아래로 스크롤해 복귀)
    function dropNewestLines(excess) {
      let dropped = false;
      while (excess-- > 0 && logEntries.length) {
        logEntries.pop().el.remove();
        dropped = true;
      }
      if (dropped) {
        const last = logEntries[logEntries.length - 1];
        if (last?.end != null) logWindow.bottom = last.end;
        if (logWindow.live) {
          if (source) source.close();
          logWindow.live = false;
        }
        followLog = false;
        document.getElementById('followLog').classList.remove('active');
      }
    }

    // 과거 청크를 위에 끼워 넣는다 — 화면 위치 보존, cap 초과분은 최신(아래쪽)부터 제거
    function prependLogLines(lines) {
      if (!lines.length) return;
      const logEl = document.getElementById('log');
      const entries = lines.map(item => makeLogEntry(item.t, item.e));
      const fragment = document.createDocumentFragment();
      for (const entry of entries) fragment.appendChild(entry.el);
      const prevHeight = logEl.scrollHeight;
      const prevTop = logEl.scrollTop;
      logEl.insertBefore(fragment, logEl.firstChild);
      logEntries = entries.concat(logEntries);
      dropNewestLines(logEntries.length - LOG_MAX_LINES);
      logEl.scrollTop = prevTop + (logEl.scrollHeight - prevHeight);
      lastLogScrollTop = logEl.scrollTop;  // 보정 점프를 '아래로 스크롤' 로 오판하지 않게 동기화
      updateLogCount();
    }

    // 이후(최신쪽) 청크를 아래에 붙인다 — cap 초과분은 과거(위쪽)부터 제거
    function appendChunkLines(lines) {
      if (!lines.length) return;
      const logEl = document.getElementById('log');
      const entries = lines.map(item => makeLogEntry(item.t, item.e));
      const fragment = document.createDocumentFragment();
      for (const entry of entries) fragment.appendChild(entry.el);
      logEl.appendChild(fragment);
      logEntries = logEntries.concat(entries);
      const last = entries[entries.length - 1];
      if (last.end != null) logWindow.bottom = Math.max(logWindow.bottom, last.end);
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      updateLogCount();
    }

    async function loadOlder() {
      // 매치 뷰는 파일 전체 매치가 이미 다 떠 있다 — 스크롤 페이징 불필요
      if (!selected || matchView || logPaging.atStart || logPaging.loadingUp || jumpInFlight) return;
      logPaging.loadingUp = true;
      updateOlderBar();
      try {
        const actualService = selected.mode === 'console' ? 'console' : selected.service;
        const reqTop = logWindow.top;
        const data = await api(`/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&before=${reqTop}`);
        // 대기 중 창이 움직였거나 매치 뷰로 전환됐으면 구식 응답 — 폐기
        // (필터 토글 직후 hidden 으로 인한 scrollHeight 급감 → scroll 이벤트 → 여기 진입하는 race 가 실재)
        if (matchView || logWindow.top !== reqTop) return;
        prependLogLines(data.lines);
        logWindow.top = data.start;
        logFileSize = Math.max(logFileSize, data.size);
        logPaging.atStart = data.atStart;
      } catch (err) {
        console.error(err);
      } finally {
        logPaging.loadingUp = false;
        updateOlderBar();
      }
    }

    async function loadNewer() {
      if (!selected || matchView || logWindow.live || logPaging.loadingDown || jumpInFlight) return;
      logPaging.loadingDown = true;
      try {
        const actualService = selected.mode === 'console' ? 'console' : selected.service;
        const data = await api(`/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&after=${logWindow.bottom}`);
        if (matchView) return;  // 대기 중 매치 뷰로 전환 — 구식 응답 폐기
        appendChunkLines(data.lines);
        logWindow.bottom = Math.max(logWindow.bottom, data.end);
        logFileSize = Math.max(logFileSize, data.size);
        // 파일 끝에 닿았고 current 면 끊긴 지점부터 SSE 재연결 — 갭·중복 없는 라이브 복귀
        if (data.atEnd && selected.run === 'current') openStream(logWindow.bottom);
      } catch (err) {
        console.error(err);
      } finally {
        logPaging.loadingDown = false;
        updateOlderBar();
      }
    }

    function renderRunSelect(session, service, mode, selectedRun) {
      const select = document.getElementById('runSelect');
      select.innerHTML = '';
      const runs = mode === 'console'
        ? session?.consoleLogRuns
        : session?.services.find(item => item.service === service)?.logRuns;
      const current = document.createElement('option');
      current.value = 'current';
      current.textContent = 'current';
      select.appendChild(current);
      for (const run of runs ?? []) {
        const option = document.createElement('option');
        option.value = run.id;
        option.textContent = run.label;
        select.appendChild(option);
      }
      select.value = selectedRun;
    }

    function renderSelection() {
      const key = selectedServiceKey();
      for (const row of document.querySelectorAll('[data-service-key]')) {
        row.classList.toggle('selected', row.dataset.serviceKey === key);
      }
    }

    function buildSessionSignature(items) {
      return items.map(item => item.root).join('|');
    }
