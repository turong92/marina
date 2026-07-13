    // ── 등록 워크벤치 M5 — R3 서비스 해석 줄(compose 를 몰라도 읽게) ─────────────────
    // 스펙: docs/superpowers/specs/2026-07-11-register-workbench-design.md R3.
    // 이 파일도 app-2c 와 같은 방식으로 두 켜: ① 순수 파서(xp*) — DOM·의존성 0, node vm 으로 그대로 eval 해
    // 단위 테스트 가능(plugin/tests/test-explain-services.sh). ② DOM 배선(하단, typeof document 가드) —
    // [YAML|해석] 토글과 #wbExplainPanel 을 채운다. innerHTML 은 안 쓴다(createElement/textContent 만).
    //
    // services 는 결정적 최소 파서(정규식+들여쓰기)만 쓴다 — x-marina 파서(app-2c)처럼 LLM 없이 동작.
    // 지원 키만 번역(build/image/ports/expose/environment/env_file/depends_on) + top-level include.
    // 실패해도 예외를 던지지 않고 항상 {ok:false, error} 로 정직하게 반환 — 호출측(렌더)이 폴백 문구를 낸다.

    // ══════════════════════════════════════════════════════════════════════════
    // ① 순수 파서 — DOM 참조 없음.
    // ══════════════════════════════════════════════════════════════════════════

    // 따옴표 밖의 첫 # (인라인 주석) 위치 — app-2c 의 xmStripComment 와 동일 규칙, 파일 독립성 위해 복제.
    function xpStripComment(line) {
      let sq = false, dq = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "'" && !dq) sq = !sq;
        else if (c === '"' && !sq) dq = !dq;
        else if (c === '#' && !sq && !dq && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
      }
      return line;
    }
    function xpUnquote(s) {
      s = (s == null ? '' : String(s)).trim();
      if (s.length >= 2 && s[0] === "'" && s[s.length - 1] === "'") return s.slice(1, -1).replace(/''/g, "'");
      if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') return s.slice(1, -1).replace(/\\"/g, '"');
      return s;
    }

    // 최상위(col-0) `key:` 블록의 [시작, 끝) 줄 인덱스 — 없으면 null(app-2c 의 xmFindBlock 과 동일 규칙, key 일반화).
    function xpFindTopBlock(lines, key) {
      const headRe = new RegExp('^' + key + ':\\s*$');
      let start = -1;
      for (let i = 0; i < lines.length; i++) { if (headRe.test(xpStripComment(lines[i]))) { start = i; break; } }
      if (start === -1) return null;
      let end = lines.length;
      for (let i = start + 1; i < lines.length; i++) {
        const l = lines[i];
        if (l.trim() !== '' && !/^\s/.test(l) && !l.trimStart().startsWith('#')) { end = i; break; }
      }
      return { start, end };
    }

    // 슬라이스 끝에 붙은 빈 줄 제거 — 블록 경계 스캔이 "다음 형제를 못 찾으면 배열 끝까지"로 열려 있어서
    // 원본 끝(혹은 다음 top-level 키 직전)의 개행이 자식 블록 안으로 잘못 흡수되는 것을 막는다(실측 버그: 그
    // 흡수된 빈 줄 하나 때문에 child.body 가 "비어있지 않다"고 오판 → inline flow map(???) 분기를 못 탐).
    function xpDropTrailingBlanks(arr) {
      let end = arr.length;
      while (end > 0 && xpStripComment(arr[end - 1]).trim() === '') end--;
      return arr.slice(0, end);
    }

    // services 블록 본문(2-space 들여쓰기) → [{name, lines}] — 각 서비스의 자식 줄(원본 들여쓰기 그대로)만 모은다.
    function xpServiceEntries(bodyLines) {
      const entries = [];
      for (let i = 0; i < bodyLines.length; i++) {
        const stripped = xpStripComment(bodyLines[i]);
        const m = stripped.match(/^ {2}([^\s:][^:]*):\s*$/);
        if (!m) continue;
        let end = bodyLines.length;
        for (let j = i + 1; j < bodyLines.length; j++) {
          const l = bodyLines[j];
          if (l.trim() !== '' && /^ {0,2}\S/.test(l)) { end = j; break; }   // 다음 2-space(이하) 형제 = 이 서비스 끝
        }
        entries.push({ name: xpUnquote(m[1]), lines: xpDropTrailingBlanks(bodyLines.slice(i + 1, end)) });
      }
      return entries;
    }

    // bodyLines 안에서 `key:` 자식 하나를 찾아 { inline, body } 반환(없으면 null). inline=한 줄 스칼라 값(빈 값이면 null),
    // body=그보다 깊게 들여쓰기된 하위 줄. 서비스 본문 안 어디든(중첩 깊이 무관) 첫 매치를 쓴다 — 최소 파서(무리한 검증 금지).
    function xpChildBlock(bodyLines, key) {
      const re = new RegExp('^' + key + ':\\s?(.*)$');
      for (let i = 0; i < bodyLines.length; i++) {
        const stripped = xpStripComment(bodyLines[i]);
        if (stripped.trim() === '') continue;
        const sp = (stripped.match(/^(\s*)/) || ['', ''])[1].length;
        const m = stripped.slice(sp).match(re);
        if (!m) continue;
        const inline = m[1].trim();
        let end = bodyLines.length;
        for (let j = i + 1; j < bodyLines.length; j++) {
          const l = xpStripComment(bodyLines[j]);
          if (l.trim() === '') continue;
          const sp2 = (l.match(/^(\s*)/) || ['', ''])[1].length;
          if (sp2 <= sp) { end = j; break; }
        }
        return { inline: inline || null, body: xpDropTrailingBlanks(bodyLines.slice(i + 1, end)) };
      }
      return null;
    }

    // child({inline,body}) → 리스트(best-effort) — 블록 대시(- item) · 인라인 flow([a, b]) · 단일 스칼라 모두 흡수.
    function xpListItems(child) {
      if (!child) return [];
      if (child.inline) {
        if (child.inline.startsWith('[')) {
          return child.inline.replace(/^\[/, '').replace(/\]\s*$/, '')
            .split(',').map(s => xpUnquote(s.trim())).filter(Boolean);
        }
        return [xpUnquote(child.inline)];
      }
      const items = [];
      for (const l of (child.body || [])) {
        const s = xpStripComment(l).trim();
        if (!s) continue;
        const m = s.match(/^-\s?(.*)$/);
        if (!m) continue;
        const item = m[1].replace(/:\s*$/, '');   // "- svc:" (depends_on 신형 condition 매핑) → svc 이름만
        if (item.trim()) items.push(xpUnquote(item));
      }
      return items;
    }

    const XP_SUPPORTED_KEYS = new Set(['build', 'image', 'ports', 'expose', 'environment', 'env_file', 'depends_on']);
    // 서비스 본문의 최상위(그 서비스 기준 첫 단) 키 이름 목록 — "그 외 설정 n개" 집계용.
    function xpServiceTopKeys(bodyLines) {
      const nonBlank = bodyLines.filter(l => xpStripComment(l).trim() !== '');
      if (!nonBlank.length) return [];
      const indent = (nonBlank[0].match(/^(\s*)/) || ['', ''])[1].length;
      const keys = [];
      for (const l of bodyLines) {
        const stripped = xpStripComment(l);
        if (stripped.trim() === '') continue;
        const sp = (stripped.match(/^(\s*)/) || ['', ''])[1].length;
        if (sp !== indent) continue;
        const m = stripped.slice(sp).match(/^([^\s:][^:]*):/);
        if (m) keys.push(xpUnquote(m[1]));
      }
      return keys;
    }

    // 서비스 하나 → 사람 문장 조각들. { name, lines:[문장...], envWarnings:[KEY...](???), otherCount }
    function xpTranslateService(name, bodyLines) {
      const lines = [];

      const buildC = xpChildBlock(bodyLines, 'build');
      if (buildC) {
        if (buildC.inline) {
          lines.push(xpUnquote(buildC.inline) + ' 폴더의 Dockerfile 로 빌드');
        } else {
          const ctxC = xpChildBlock(buildC.body, 'context');
          const dfC = xpChildBlock(buildC.body, 'dockerfile');
          const ctx = ctxC && ctxC.inline ? xpUnquote(ctxC.inline) : '.';
          const df = dfC && dfC.inline ? xpUnquote(dfC.inline) : 'Dockerfile';
          lines.push(ctx + ' 폴더의 ' + df + ' 로 빌드');
        }
      }

      const imageC = xpChildBlock(bodyLines, 'image');
      if (imageC && imageC.inline) lines.push('이미지 ' + xpUnquote(imageC.inline) + ' 사용');

      const ports = [...xpListItems(xpChildBlock(bodyLines, 'ports')), ...xpListItems(xpChildBlock(bodyLines, 'expose'))]
        .map(p => String(p).split(':').pop())   // "8080:80" 같은 매핑도 컨테이너(앱) 포트만
        .filter(Boolean);
      if (ports.length) lines.push('포트 ' + [...new Set(ports)].join(', ') + ' 으로 서빙');

      const envWarnings = [];
      const envC = xpChildBlock(bodyLines, 'environment');
      if (envC) {
        if (envC.body && envC.body.length) {
          for (const l of envC.body) {
            const s = xpStripComment(l).trim();
            const m = s.match(/^([^\s:][^:]*):\s?(.*)$/);
            if (m && xpUnquote(m[2]) === '???') envWarnings.push(xpUnquote(m[1]));
          }
        } else if (envC.inline && envC.inline.startsWith('{')) {
          const inner = envC.inline.replace(/^\{/, '').replace(/\}\s*$/, '');
          for (const part of inner.split(',')) {
            const ci = part.indexOf(':');
            if (ci < 0) continue;
            const k = xpUnquote(part.slice(0, ci).trim());
            const v = xpUnquote(part.slice(ci + 1).trim());
            if (v === '???') envWarnings.push(k);
          }
        }
      }

      const envFiles = xpListItems(xpChildBlock(bodyLines, 'env_file'));
      if (envFiles.length) lines.push(envFiles.join(', ') + ' 파일의 환경변수를 불러옴');

      const deps = xpListItems(xpChildBlock(bodyLines, 'depends_on'));
      if (deps.length) lines.push(deps.join(', ') + ' 이(가) 먼저 준비된 뒤에 시작');

      const otherCount = xpServiceTopKeys(bodyLines).filter(k => !XP_SUPPORTED_KEYS.has(k)).length;
      return { name, lines, envWarnings, otherCount };
    }

    // compose YAML 전문 → { ok:true, services:[...], includes:[...] } | { ok:false, error }.
    // 절대 던지지 않는다(내부에서 예외가 나도 여기서 잡아 정직한 폴백을 낸다) — 호출측은 ok 만 보면 됨.
    function xpExplainCompose(fullYamlText) {
      try {
        // null/undefined 는 "아직 빈 편집기"로 관대하게(ok:true) — 문자열이 아닌 진짜 값(숫자·객체 등)만 깨진 입력으로 던진다.
        if (fullYamlText != null && typeof fullYamlText !== 'string') throw new Error('YAML 텍스트가 아님');
        const lines = String(fullYamlText || '').replace(/\r\n/g, '\n').split('\n');
        const svcBlock = xpFindTopBlock(lines, 'services');
        const services = [];
        if (svcBlock) {
          const body = lines.slice(svcBlock.start + 1, svcBlock.end);
          if (/^[ ]*\t/m.test(body.join('\n'))) throw new Error('탭 들여쓰기는 YAML 에서 허용되지 않음');
          for (const entry of xpServiceEntries(body)) services.push(xpTranslateService(entry.name, entry.lines));
        }
        const incBlock = xpFindTopBlock(lines, 'include');
        const includes = incBlock ? xpListItems({ inline: null, body: lines.slice(incBlock.start + 1, incBlock.end) }) : [];
        return { ok: true, services, includes };
      } catch (e) {
        return { ok: false, error: String((e && e.message) || e) };
      }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ② DOM 배선 — [YAML|해석] 토글 + #wbExplainPanel 렌더. innerHTML 금지(createElement/textContent 만).
    // ══════════════════════════════════════════════════════════════════════════

    function xpMk(tag, cls) { const el = document.createElement(tag); if (cls) el.className = cls; return el; }
    function xpMkText(tag, cls, text) { const el = xpMk(tag, cls); el.textContent = text; return el; }

    function xpRenderExplain(panel) {
      while (panel.firstChild) panel.removeChild(panel.firstChild);
      const ta = document.getElementById('composeYaml');
      const result = xpExplainCompose(ta ? ta.value : '');
      if (!result.ok) {
        panel.appendChild(xpMkText('div', 'wb-explain-error', '해석할 수 없어요 — YAML 을 확인하세요'));
        return;
      }
      if (!result.services.length && !result.includes.length) {
        panel.appendChild(xpMkText('div', 'wb-explain-empty', '아직 서비스가 없어요 — 왼쪽 재료에서 추가하거나 YAML 에 직접 작성하세요.'));
        return;
      }
      for (const svc of result.services) {
        const card = xpMk('div', 'wb-explain-svc');
        card.appendChild(xpMkText('div', 'wb-explain-svc-name', svc.name));
        for (const ln of svc.lines) card.appendChild(xpMkText('div', 'wb-explain-line', ln));
        for (const key of svc.envWarnings) card.appendChild(xpMkText('div', 'wb-explain-line wb-explain-warn', key + ' 값이 필요해요 (아직 비어 있음)'));
        if (!svc.lines.length && !svc.envWarnings.length) card.appendChild(xpMkText('div', 'wb-explain-line', '(해석 가능한 정보 없음)'));
        if (svc.otherCount) card.appendChild(xpMkText('div', 'wb-explain-other', '그 외 설정 ' + svc.otherCount + '개 (YAML 참조)'));
        panel.appendChild(card);
      }
      for (const inc of result.includes) {
        panel.appendChild(xpMkText('div', 'wb-explain-line', 'include: ' + inc + ' 의 자체 compose 를 통째로 가져옴'));
      }
    }

    // openWorkbench(app-2b)가 진입 때마다 호출 — 이전 세션에서 '해석' 탭에 머물러 있던 상태가 새 진입에 새지 않도록.
    function wbExplainReset() {
      const toggle = document.querySelector('[data-wb-explain-toggle]');
      const panel = document.getElementById('wbExplainPanel');
      if (!toggle || !panel) return;
      const btnYaml = toggle.querySelector('[data-wb-explain-tab="yaml"]');
      const btnExplain = toggle.querySelector('[data-wb-explain-tab="explain"]');
      if (btnYaml) btnYaml.classList.add('active');
      if (btnExplain) btnExplain.classList.remove('active');
      panel.hidden = true;
      const wrap = document.querySelector('.yaml-wrap');
      if (wrap) wrap.hidden = false;
    }

    if (typeof document !== 'undefined') {
      (function wireExplainToggle() {
        const toggle = document.querySelector('[data-wb-explain-toggle]');
        const panel = document.getElementById('wbExplainPanel');
        if (!toggle || !panel) return;
        const btnYaml = toggle.querySelector('[data-wb-explain-tab="yaml"]');
        const btnExplain = toggle.querySelector('[data-wb-explain-tab="explain"]');
        if (!btnYaml || !btnExplain) return;

        function yamlWrapEl() { return document.querySelector('.yaml-wrap'); }
        function showYaml() {
          btnYaml.classList.add('active'); btnExplain.classList.remove('active');
          panel.hidden = true;
          const wrap = yamlWrapEl(); if (wrap) wrap.hidden = false;
        }
        function showExplain() {
          btnExplain.classList.add('active'); btnYaml.classList.remove('active');
          xpRenderExplain(panel);
          panel.hidden = false;
          const wrap = yamlWrapEl(); if (wrap) wrap.hidden = true;   // YAML 은 숨김만 — DOM/상태(스크롤·커서)는 그대로 보존
        }
        btnYaml.onclick = showYaml;
        btnExplain.onclick = showExplain;

        // 해석 패널이 떠 있는 동안 편집이 들어오면(재료 삽입·폼 반영 등도 input 을 재발화) 같이 새로고침.
        const ta = document.getElementById('composeYaml');
        if (ta) ta.addEventListener('input', () => { if (!panel.hidden) xpRenderExplain(panel); });
      })();
    }
