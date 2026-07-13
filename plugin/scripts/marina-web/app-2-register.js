    // 경로가 바뀌면 재료 서랍의 "기존 compose" 가벼운 목록을 재조회(스캔은 버튼 전용 — 자동 아님). app-2b-workbench.js.
    document.getElementById('registerPath').addEventListener('change', () => {
      if (!document.getElementById('composeSection').hidden && typeof wbOnPathChanged === 'function') wbOnPathChanged();
    });

    // ── compose YAML 하이라이트 오버레이 (dep0 — 라이브러리 없음) ───────────────
    function yamlCommentStart(line) {   // 따옴표 밖의 첫 # (인라인 주석) 위치, 없으면 -1
      let s = false, d = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "'" && !d) s = !s;
        else if (c === '"' && !s) d = !d;
        else if (c === '#' && !s && !d && (i === 0 || /\s/.test(line[i - 1]))) return i;
      }
      return -1;
    }
    function highlightYaml(text) {
      return text.split('\n').map(line => {
        let code = line, comment = '';
        const ci = yamlCommentStart(line);
        if (ci >= 0) { code = line.slice(0, ci); comment = line.slice(ci); }
        let html = escapeHtml(code).replace(/^(\s*)([A-Za-z0-9_.\-]+)(\s*:)/, (m, sp, key, colon) => {
          const depth = Math.floor(sp.length / 2) % 5;   // 들여쓰기 깊이별 키 색 — 계층 가독성(top-level=d0 …)
          return sp + `<span class="y-d${depth}">${key}</span>` + colon;
        });
        html = html.replace(/\$\{[^}]+\}/g, m => `<span class="y-var">${m}</span>`);   // escapeHtml 후라 ${} 보존
        if (comment) html += `<span class="y-com">${escapeHtml(comment)}</span>`;
        return html;
      }).join('\n');
    }
    function refreshComposeHighlight() {
      const ta = document.getElementById('composeYaml'), hl = document.getElementById('composeHl'), gut = document.getElementById('composeGutter');
      if (!ta || !hl || !gut) return;
      const n = (ta.value.match(/\n/g) || []).length + 1;
      hl.innerHTML = highlightYaml(ta.value) + '\n';   // 끝 개행 sentinel — <pre>는 trailing newline 을 안 그려 마지막 빈 줄이 밀린다
      gut.textContent = Array.from({ length: n }, (_, i) => i + 1).join('\n');
      hl.style.transform = `translate(${-ta.scrollLeft}px, ${-ta.scrollTop}px)`;   // transform 동기화 — scrollbar-clamp 어긋남 없음
      gut.style.transform = `translateY(${-ta.scrollTop}px)`;
    }
    function setComposeYaml(v) {   // 프로그램적 세팅 — 하이라이트·line# 도 같이 갱신(input 이벤트 안 뜨므로)
      const ta = document.getElementById('composeYaml');
      if (ta) ta.value = v == null ? '' : v;
      refreshComposeHighlight();
    }
    // ── YAML 편집 기본기 (형 요청) — 탭=들여쓰기 삽입, 엔터=YAML 문맥 맞는 들여쓰기 유지 ──
    const YAML_INDENT = '  ';   // compose/YAML 표준 2칸 — 템플릿·스캐폴드 출력과 일치
    function yamlInsertText(ta, text) {   // execCommand 우선 — 브라우저 undo 스택 보존. 폴백은 setRangeText+input
      if (!document.execCommand || !document.execCommand('insertText', false, text)) {
        ta.setRangeText(text, ta.selectionStart, ta.selectionEnd, 'end');
        ta.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    function yamlShiftLines(ta, outdent) {   // 선택 블록(또는 현재 줄) 들여쓰기/내어쓰기
      const v = ta.value;
      const selS = ta.selectionStart, selE = ta.selectionEnd;
      const ls = v.lastIndexOf('\n', selS - 1) + 1;
      let le = v.indexOf('\n', Math.max(selE - 1, selS));
      if (le === -1) le = v.length;
      const block = v.slice(ls, le);
      const re = new RegExp(`^ {1,${YAML_INDENT.length}}`);
      const shifted = block.split('\n').map(l => outdent ? l.replace(re, '') : (l.length ? YAML_INDENT + l : l)).join('\n');
      if (shifted === block) return;
      ta.setSelectionRange(ls, le);
      yamlInsertText(ta, shifted);
      ta.setSelectionRange(ls, ls + shifted.length);
    }
    function yamlEnterIndent(line) {
      // 엔터 후 들여쓰기 결정 — 핵심: `key: value` 줄에서의 개행은 "값의 연속"이라 키보다 깊어야
      // YAML fold 로 한 값이 된다(얕으면 형제 키로 파싱돼 '깨진 걸로 인식' — 보고된 버그).
      const sp = (line.match(/^ */) || [''])[0];
      if (/^\s*[A-Za-z0-9_."'\-]+:\s*$/.test(line)) return sp + YAML_INDENT;        // key: (빈 값) → 중첩 시작
      if (/^\s*[A-Za-z0-9_."'\-]+:\s+\S/.test(line)) return sp + YAML_INDENT;       // key: value → 값 연속(fold)
      if (/^\s*-\s/.test(line)) return sp;                                          // 리스트 항목 → 같은 깊이(다음 - 항목)
      return sp;                                                                    // 그 외 → 현재 들여쓰기 유지
    }
    function yamlTabInsert(ta) {
      const ls = ta.value.lastIndexOf('\n', ta.selectionStart - 1) + 1;
      const col = ta.selectionStart - ls;
      yamlInsertText(ta, ' '.repeat(YAML_INDENT.length - (col % YAML_INDENT.length)));   // 다음 들여쓰기 칸으로
    }
    let _yamlTabTs = 0;   // keydown 에서 처리한 Tab 을 beforeinput('\t')이 중복 처리하지 않게 (합성 입력은 둘 다 발생)
    function yamlEditorKeydown(e) {
      const ta = e.target;
      if (e.key === 'Tab') {
        e.preventDefault();   // 포커스 이동 대신 들여쓰기
        _yamlTabTs = Date.now();
        if (e.shiftKey || ta.selectionStart !== ta.selectionEnd) yamlShiftLines(ta, e.shiftKey);
        else yamlTabInsert(ta);
      }
    }
    let _yamlPendIndent = null;
    function yamlEditorBeforeInput(e) {
      const ta = e.target;
      // Enter: 기본 개행을 막지 않는다 — 합성 입력(자동화)은 preventDefault 를 무시하고 개행을 강행해
      // '내 삽입+기본 개행' 이중이 됐다(실측). 대신 개행 직전에 들여쓰기만 계산해 두고 input 에서 삽입(fix-up).
      if (e.inputType === 'insertLineBreak' || (e.inputType === 'insertText' && e.data === '\n')) {
        if (ta.selectionStart !== ta.selectionEnd) { _yamlPendIndent = null; return; }
        const s = ta.selectionStart;
        const ls = ta.value.lastIndexOf('\n', s - 1) + 1;
        _yamlPendIndent = yamlEnterIndent(ta.value.slice(ls, s)) || null;
        return;
      }
      if (e.inputType === 'insertText' && e.data === '\t') {   // 탭 문자는 어느 경로로 와도 스페이스로
        e.preventDefault();
        if (Date.now() - _yamlTabTs > 80) yamlTabInsert(ta);   // keydown 이 이미 처리한 직후면 스킵
        return;
      }
      if (e.inputType === 'insertText' && (e.data === '\r' || e.data === '\r\n')) {
        e.preventDefault();   // 합성 입력(CDP)의 중복 CR — insertLineBreak 뒤에 "\r" 이 한 번 더 온다(실측). 실키보드엔 없음
      }
    }
    function yamlEditorInput(e) {
      if (_yamlPendIndent && (e.inputType === 'insertLineBreak' || (e.inputType === 'insertText' && e.data === '\n'))) {
        const ind = _yamlPendIndent;
        _yamlPendIndent = null;
        yamlInsertText(e.target, ind);   // 개행은 이미 적용됨 — 들여쓰기만 캐럿 위치에
        return;   // yamlInsertText 가 input 을 다시 발화 → refresh 는 그 경로에서
      }
      refreshComposeHighlight();
    }
    (function wireComposeHighlight() {
      const ta = document.getElementById('composeYaml');
      if (!ta) return;
      ta.setAttribute('wrap', 'off');   // 줄바꿈 어긋남 — textarea 는 CSS white-space 가 아니라 wrap 속성이 지배. soft-wrap 이 오버레이(no-wrap)와 줄을 어긋나게 한다
      ta.addEventListener('keydown', yamlEditorKeydown);
      ta.addEventListener('beforeinput', yamlEditorBeforeInput);
      ta.addEventListener('input', yamlEditorInput);
      ta.addEventListener('scroll', () => {
        const hl = document.getElementById('composeHl'), gut = document.getElementById('composeGutter');
        if (hl) hl.style.transform = `translate(${-ta.scrollLeft}px, ${-ta.scrollTop}px)`;
        if (gut) gut.style.transform = `translateY(${-ta.scrollTop}px)`;
      });
      // 초기 페인트는 다음 tick 으로 — highlightYaml→escapeHtml(app-3-util)이 이 스크립트보다 늦게 로드되므로
      // eval 시점 호출은 ReferenceError 로 이후 핸들러 등록을 막는다(codex P1).
      setTimeout(refreshComposeHighlight, 0);
    })();

    document.getElementById('composeViewConfig').onclick = () => {   // 편집 모달에서 해석된 구성 보기
      const path = document.getElementById('registerPath').value.trim();
      const err = document.getElementById('registerError');
      if (!path) { err.textContent = '프로젝트 경로 먼저 입력'; err.hidden = false; return; }
      openProjectConfig(path);
    };
    function okToReplaceYaml() {   // 편집기에 내용이 있으면 덮어쓰기 전 확인 — 직접 작성분 유실 방지(코덱스 UX #2). 재료 서랍(app-2b)도 재사용.
      const ta = document.getElementById('composeYaml');
      const v = ((ta && ta.value) || '').trim();
      if (!v || v === '불러오는 중…') return true;
      return confirm('편집기에 작성한 compose 내용이 있어요. 새로 불러온 내용으로 덮어쓸까요?');
    }
    // 구 "📁 레포에서 찾기"(composeImport) 버튼·목록은 제거 — 같은 compose-detect 호출로 재료 서랍의
    // "기존 compose" 카드(app-2b-workbench.js, wbMatExisting)가 대체(스펙 R2 M3, okToReplaceYaml 재사용).

    document.getElementById('composeConfirm').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const yaml = document.getElementById('composeYaml').value;
      const isEdit = wbMode === 'edit';   // 제목 문자열 비교 대신 openWorkbench 가 보관한 모드(app-2b)
      const err = document.getElementById('registerError');
      err.hidden = true;
      if (wbMarkerLines.length) {   // M5 — ??? 값이 남아있으면 인라인 배너로 차단(alert 금지, app-2b 가 매 입력마다 갱신)
        err.textContent = '⚠ 채워야 할 값 ' + wbMarkerLines.length + '개(' + wbMarkerLines.join(', ') + '행) — ??? 를 채우고 다시 시도하세요';
        err.hidden = false;
        return;
      }
      if (!path) { err.textContent = '프로젝트 경로를 입력하세요'; err.hidden = false; return; }
      if (!yaml.trim()) { err.textContent = 'compose 내용을 입력하세요 (📁 import / 직접 작성)'; err.hidden = false; return; }
      const btn = document.getElementById('composeConfirm'); const label = btn.textContent;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/compose-register', {
          method: 'POST', headers: {'content-type': 'application/json'},
          // 저장만(자동 실행 X) + env var/default. externalRepos 는 안 보냄 — 서버가 기존 등록분을 보존(prev-merge, marina-lib-registry.sh)하고,
          // 새로 추가하려면 CLI(marina project add --external)를 쓴다(구 composeSubrepos UI 는 재료 서랍으로 흡수되며 정리됨 — 스펙 R2 M3).
          body: JSON.stringify({path, yaml, envVar: composeStoredEnv.envVar, envDefault: composeStoredEnv.envDefault}),
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      if (res && res.ok === false) {
        err.textContent = '검증 실패: ' + ((res.errors && res.errors.join(' / ')) || ''); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      wbClearDraft();   // 등록/저장 성공 — 워크벤치 초안 정리(app-2b)
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      // R5 — 등록 성공 후 새 프로젝트 자동 선택 + 해당 main 카드 하이라이트(app-5 render() 가 pendingFlashProjectId 소비)
      const known = res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id);
      if (known) { pendingFlashProjectId = res.id; setSelectedProject(res.id); }
      else render();
      if (res && res.ok !== false) {
        showToast(isEdit ? 'compose 저장 완료 — 변경분은 카드에서 ▶(재시작)로 반영돼요'
                          : '등록 완료 — ▶ 로 시작하면 빌드 로그 탭에서 진행이 보여요', 'ok');
      }
    };

    // ── 팀원 설정 붙여넣기(import) ─────────────────────────────────────────────
    document.getElementById('pasteBrowse').onclick = () => {
      browseMode = 'paste';
      document.getElementById('registerPaste').appendChild(document.getElementById('browsePanel'));
      openBrowse(document.getElementById('pastePath').value.trim() || '');
    };
    document.getElementById('pasteImport').onclick = async () => {
      const root = document.getElementById('pastePath').value.trim();
      const blob = document.getElementById('pasteBlob').value;
      const apply = document.getElementById('pasteApply').checked;
      const err = document.getElementById('pasteError');
      err.hidden = true;
      if (!root) { err.textContent = '프로젝트 경로를 입력하세요'; err.hidden = false; return; }
      if (!blob.trim()) { err.textContent = '공유 블록(compose+x-marina)을 붙여넣으세요'; err.hidden = false; return; }
      const btn = document.getElementById('pasteImport'); const label = btn.textContent;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/compose-import', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ root, blob, apply }),
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      if (res && res.ok === false) {
        err.textContent = '가져오기 실패: ' + ((res.errors && res.errors.join(' / ')) || res.error || ''); err.hidden = false;
        btn.disabled = false; btn.textContent = label; return;
      }
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      const known = res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id);
      if (known) { pendingFlashProjectId = res.id; setSelectedProject(res.id); }   // R5 — 하이라이트(app-5)
      else render();
      const warn = (res && res.warnings && res.warnings.length) ? (' 경고: ' + res.warnings.join(' / ')) : '';
      showToast('가져오기 완료 — 등록 + 설정 적용됨.' + (apply ? ' 시작도 시도했어요.' : ' ▶ 로 시작하면 빌드 로그 탭에서 진행이 보여요.')
        + ' 시크릿(.env 값)은 본인 것을 채우세요.' + warn, 'ok');
    };

    // (구 위저드 코드 제거됨 — R6. 신규 등록 진입은 레포 후보 → 워크벤치(app-2e-entry.js openCandidates/openWorkbench).
    // 위저드가 쓰던 /api/compose-scan·scaffold 는 재료 서랍(app-2b-workbench.js)이 그대로 재사용한다.)

    async function openSubrepoEdit(sum) {
      switcherOpen = false;
      setRegisterView('new');   // 진입 선택/붙여넣기 뷰 숨기고 경로행 노출
      document.getElementById('registerTitle').textContent = `subrepos 편집 — ${sum.label}`;
      document.getElementById('registerPath').value = sum.root;
      document.getElementById('registerPath').disabled = true;
      document.getElementById('registerBrowse').hidden = true;   // 편집: 경로 고정이라 탐색·분석 숨김(분석은 누르면 리셋 위험)
      document.getElementById('composeSection').hidden = true;
      syncRegisterWorkspace();   // subrepos 편집은 compose 작업공간 아님 — 좁은 패널로
      document.getElementById('registerInfer').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      showRegisterPanel(true);
      renderSwitcher();
      // universe = infer(현재 nested-git 전수), checked = 레지스트리에 등록된 큐레이션 집합(main 엔트리 payload).
      const mainEntry = worktreeData.find(w => w.projectId === sum.id && w.isMain);
      const current = mainEntry ? (mainEntry.subrepos || []) : [];
      await inferAndPreview(sum.root, current);
    }

    async function shareProject(sum) {   // 공유용 복사 — '하나의 정규 설정'(compose+x-marina) 클립보드로
      try {
        const r = await api('/api/compose-export?root=' + enc(sum.root));
        if (!r || r.ok === false || !r.yaml) { showToast('공유 블록 생성 실패: ' + ((r && r.error) || '알 수 없음'), 'err'); return; }
        let copied = false;
        try { await navigator.clipboard.writeText(r.yaml); copied = true; } catch {}
        if (!copied) {   // clipboard API 불가(비보안 컨텍스트 등) → 폴백 textarea
          const ta = document.createElement('textarea'); ta.value = r.yaml; ta.style.position = 'fixed'; ta.style.opacity = '0';
          document.body.appendChild(ta); ta.select();
          try { copied = document.execCommand('copy'); } catch {}
          document.body.removeChild(ta);
        }
        showToast(copied ? '공유 블록을 클립보드에 복사했어요 — 팀원이 [팀원 설정 받았어요]로 재현합니다(시크릿 .env 값은 포함 안 됨)'
                          : '복사 실패 — 브라우저 클립보드 권한을 확인하세요', copied ? 'ok' : 'err');
      } catch (e) { showToast('공유 실패: ' + String(e.message || e), 'err'); }
    }

    async function removeProject(sum) {
      if (!confirm(`'${sum.label}' 등록을 해제할까요? (코드·worktree 는 그대로, 레지스트리에서만 제거)`)) return;
      try {
        await api('/api/remove-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ id: sum.id }),
        });
      } catch (e) {
        showToast(`등록 해제 실패: ${e.message || e}`, 'err');
        return;
      }
      if (selectedProjectId === sum.id) setSelectedProject(null);
      await loadWorktrees(true);
      await load({ force: true });
      render();
    }
