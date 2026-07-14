    // ── 등록 워크벤치 M4 — 좌 하단 marina 옵션 폼 (x-marina 양방향 연동) ────────────
    // 스펙: docs/superpowers/specs/2026-07-11-register-workbench-design.md R2(좌 하단)·R4(옵션 사전).
    // 이 파일은 두 켜로 나뉜다:
    //   ① 순수 파서/직렬화기(xm*, wbParseXmarina/wbSerializeXmarina/wbReplaceXmarinaBlock) — DOM·의존성 0,
    //      node 에서 그대로 eval 해 왕복 테스트 가능(plugin/tests/test-xmarina-form-roundtrip.sh).
    //   ② 폼 UI/DOM 연동(wbForm*) — [data-wb-form](index.html)을 채우고 우측 compose 에디터(#composeYaml,
    //      app-2/app-2b 소유)와 양방향으로 잇는다. innerHTML 은 안 쓴다(전부 createElement/textContent).
    //
    // 양방향 규칙(R2): x-marina 서브트리만 바인딩 — services 는 읽기만(게이트웨이 체크박스 목록).
    // 폼이 모르는 키는 원문 보존(otherKeys) + "그 외 설정 n개" 표기. YAML 파싱 불가 시 폼 잠금(조용한 덮어쓰기 금지).

    // ── R4 사전 — 노출 지점 공용(재료 스니펫·해석 패널과 같은 문구를 여기서도 사용) ─────────────────
    const WB_XM_DICT = {
      startGroup: { label: '시작 그룹',                 mono: 'x-marina.startGroup', desc: '▶ 전체시작이 켜는 그룹 — 비우면 전부. 나머지는 필요할 때 개별 ▶ (쓸데없는 것 같이 안 뜸)' },
      links:    { label: '무거운 폴더 공유',            mono: 'x-marina.links',    desc: '워크트리를 새로 만들어도 node_modules·빌드 폴더를 재설치·재빌드 없이 재사용 — 🔗 링크(실시간 공유) 또는 ⧉ 복사(독립본) 중 선택' },
      forward:  { label: '내 컴퓨터의 DB/Redis 쓰기',    mono: 'x-marina.forward',  desc: '컨테이너 안 localhost 가 내 컴퓨터의 Redis/DB 로 연결됨' },
      gateway:  { label: '브라우저 주소 자동 발급',       mono: 'x-marina.gateway',  desc: '워크트리마다 이름.프로젝트.localhost 주소가 생겨요 — 포트 몰라도 됨' },
      prebuild: { label: '이미지 빌드 전에 미리 빌드',     mono: 'x-marina.prebuild', desc: 'jar 처럼 먼저 구워야 하는 산출물을 자동으로' },
      java:     { label: 'JDK 버전 지정',                mono: 'x-marina.java',     desc: '서브레포별 JDK 를 sdkman 에서 골라 씀' },
      build:    { label: '빌드 변수',                    mono: 'x-marina.build.args', desc: 'Dockerfile 의 ARG 값 채우기' },
    };
    const WB_XM_LOCK_MSG = 'x-marina 를 읽을 수 없어요 — YAML 을 고치면 다시 열려요';

    // ══════════════════════════════════════════════════════════════════════════
    // ① 순수 파서/직렬화기 — 아래부터 wbReplaceXmarinaBlock 까지 DOM 참조 없음(node 테스트 대상).
    // ══════════════════════════════════════════════════════════════════════════

    // 따옴표 밖의 첫 # (인라인 주석) 위치 — app-2 의 yamlCommentStart 와 같은 규칙이지만, 파서는
    // "의존성 0" 이라 별도 복제(공유 스코프에 기대지 않음 — node 단독 eval 에서도 그대로 동작).
    function xmStripComment(line) {
      let sq = false, dq = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "'" && !dq) sq = !sq;
        else if (c === '"' && !sq) dq = !dq;
        else if (c === '#' && !sq && !dq && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
      }
      return line;
    }
    function xmUnquoteScalar(s) {
      s = (s == null ? '' : String(s)).trim();
      if (s.length >= 2 && s[0] === "'" && s[s.length - 1] === "'") return s.slice(1, -1).replace(/''/g, "'");
      if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') return s.slice(1, -1).replace(/\\"/g, '"');
      return s;
    }
    function xmFindTopColon(s) {   // 따옴표 밖의 첫 ':' — flow map 항목 "key: value" 분리용
      let q = null;
      for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (q) { if (c === q) q = null; continue; }
        if (c === "'" || c === '"') { q = c; continue; }
        if (c === ':') return i;
      }
      return -1;
    }
    function xmSplitFlowTop(inner) {   // flow list/map 내부를 top-level 콤마로 split(중첩 []/{}·따옴표 보호)
      const parts = []; let depth = 0, q = null, cur = '';
      for (let i = 0; i < inner.length; i++) {
        const c = inner[i];
        if (q) { cur += c; if (c === q) q = null; continue; }
        if (c === "'" || c === '"') { q = c; cur += c; continue; }
        if (c === '[' || c === '{') { depth++; cur += c; continue; }
        if (c === ']' || c === '}') { depth--; cur += c; continue; }
        if (c === ',' && depth === 0) { parts.push(cur); cur = ''; continue; }
        cur += c;
      }
      if (cur.trim() !== '') parts.push(cur);
      return parts.map(p => p.trim()).filter(p => p !== '');
    }
    function xmParseFlowValue(s) {
      s = (s || '').trim();
      if (s.startsWith('[')) return xmParseFlowList(s);
      if (s.startsWith('{')) return xmParseFlowMap(s);
      return xmUnquoteScalar(s);
    }
    function xmParseFlowList(s) {
      const inner = s.trim().replace(/^\[/, '').replace(/\]\s*$/, '');
      return xmSplitFlowTop(inner).map(xmParseFlowValue);
    }
    function xmParseFlowMap(s) {
      const inner = s.trim().replace(/^\{/, '').replace(/\}\s*$/, '');
      const obj = {};
      for (const part of xmSplitFlowTop(inner)) {
        const ci = xmFindTopColon(part);
        if (ci < 0) throw new Error('flow map 항목에 콜론 없음: ' + part);
        const k = xmUnquoteScalar(part.slice(0, ci).trim());
        obj[k] = xmParseFlowValue(part.slice(ci + 1).trim());
      }
      return obj;
    }

    // 블록 매핑 파서 — child 라인(부모 key 줄 제외)을 top-level 항목별로 분리한다.
    // PyYAML 관례 반영: 중첩 매핑은 +들여쓰기, 중첩 리스트는 부모 key 와 "같은" 들여쓰기(대시 줄) —
    // 그래서 대시로 시작하는 same-indent 줄은 새 항목이 아니라 직전 key 의 값으로 흡수한다.
    // col-0 주석(#)은 백엔드(_edit_xmarina_block)처럼 블록을 안 끊는다 — 직전 항목에 붙여 보존.
    function xmParseBlockMap(lines) {
      const nonBlank = lines.filter(l => xmStripComment(l).trim() !== '');
      if (!nonBlank.length) return { order: [], entries: {}, indent: 0 };
      const indent = (nonBlank[0].match(/^(\s*)/) || ['', ''])[1].length;
      const order = []; const entries = {};
      let curKey = null;
      for (const raw of lines) {
        const stripped = xmStripComment(raw);
        if (stripped.trim() === '') { if (curKey) entries[curKey].child.push(raw); continue; }
        const sp = (raw.match(/^(\s*)/) || ['', ''])[1].length;
        const trimmedContent = stripped.slice(sp);
        const isDash = /^-(\s|$)/.test(trimmedContent);
        if (sp === indent && isDash && curKey && entries[curKey].inline === null) {
          entries[curKey].child.push(raw);   // PyYAML same-indent 리스트 연속
          continue;
        }
        if (sp === indent) {
          const m = trimmedContent.match(/^((?:'[^']*'|"[^"]*"|[^:\s][^:]*?)):\s?(.*)$/);
          if (!m) throw new Error('키:값 형태가 아님 — ' + raw);
          const key = xmUnquoteScalar(m[1].trim());
          const rest = m[2].trim();
          curKey = key;
          order.push(key);
          entries[key] = { inline: rest === '' ? null : rest, child: [], headLine: raw };
        } else if (sp > indent) {
          if (!curKey) throw new Error('예상 밖 들여쓰기 — ' + raw);
          entries[curKey].child.push(raw);
        } else {
          throw new Error('블록 안에서 들여쓰기가 얕아짐 — ' + raw);
        }
      }
      return { order, entries, indent };
    }
    function xmValueAsList(entry) {
      if (entry.inline !== null) {
        if (entry.inline.startsWith('[')) return xmParseFlowList(entry.inline);
        throw new Error('리스트가 필요한데 스칼라: ' + entry.inline);
      }
      const items = [];
      for (const l of entry.child) {
        const stripped = xmStripComment(l);
        if (stripped.trim() === '') continue;
        const m = stripped.trim().match(/^-\s?(.*)$/);
        if (!m) throw new Error('리스트 항목이 아님: ' + l);
        items.push(xmUnquoteScalar(m[1]));
      }
      return items;
    }
    function xmEntryValue(entry) {
      if (entry.inline !== null) return xmParseFlowValue(entry.inline);
      const meaningful = entry.child.filter(l => xmStripComment(l).trim() !== '');
      if (!meaningful.length) return null;
      const firstTrim = xmStripComment(meaningful[0]).trim();
      if (/^-(\s|$)/.test(firstTrim)) return xmValueAsList(entry);
      const sub = xmParseBlockMap(entry.child);
      const obj = {};
      for (const k of sub.order) obj[k] = xmEntryValue(sub.entries[k]);
      return obj;
    }
    // 미지원 항목 원문 보존 — 블록 전체가 2칸 기준(baseIndent=2)이 되도록 상수 shift 만 적용.
    // (하위 상대 들여쓰기 폭은 원본 그대로 — 그 서브트리 내부에서만 일관되면 유효 YAML.)
    function xmShiftLine(line, shift) {
      if (line.trim() === '') return '';
      const m = line.match(/^(\s*)([\s\S]*)$/);
      const newSp = Math.max(0, m[1].length + shift);
      return ' '.repeat(newSp) + m[2];
    }
    function xmReindentEntry(entry, blockIndent) {
      const shift = 2 - blockIndent;
      return [entry.headLine, ...entry.child].map(l => xmShiftLine(l, shift)).join('\n');
    }

    // ── 지원 키별 구조 검증/정규화 — 모양이 안 맞으면 던져서(호출측이) otherKeys 로 내린다 ──────────
    // x-marina.links 는 두 형태를 지원한다(백엔드 apply_glob_links _xm_sub 와 동일):
    //   · 전역   : links: { symlink: [...], copy: [...] }            → 모든 서비스/서브레포 공통
    //   · 서브레포별: links: { <svc>: { symlink, copy }, ... }         → 그 서브레포만 (실프로젝트 mdc-main 형태)
    // 둘을 {symlink, copy, subs:{<svc>:{symlink,copy}}} 하나로 정규화(전역=최상위 symlink/copy, 서브레포별=subs).
    // 예전엔 전역만 받고 서브레포별은 던져 otherKeys 로 내려갔다 — 카드에 안 보이고 편집 시 links: 블록 중복(손상).
    function xmCoerceLinks(val) {
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('links 는 매핑이어야 함');
      const out = { symlink: [], copy: [], subs: {} };
      const coerceList = (arr, where) => {
        if (!Array.isArray(arr)) throw new Error(where + ' 은 리스트여야 함');
        return arr.map(String);
      };
      for (const k of Object.keys(val)) {
        if (k === 'symlink' || k === 'copy') {
          out[k] = coerceList(val[k], 'links.' + k);
        } else {
          const node = val[k];
          if (!node || typeof node !== 'object' || Array.isArray(node)) throw new Error('links.' + k + ' 은 매핑이어야 함');
          const sub = { symlink: [], copy: [] };
          for (const kk of Object.keys(node)) {
            if (kk !== 'symlink' && kk !== 'copy') throw new Error('links.' + k + ' 의 미지원 하위키: ' + kk);
            sub[kk] = coerceList(node[kk], 'links.' + k + '.' + kk);
          }
          out.subs[k] = sub;
        }
      }
      return out;
    }
    function xmCoerceForward(val) {
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('forward 는 매핑이어야 함');
      const out = {};
      for (const [k, v] of Object.entries(val)) {
        if (!/^\d+$/.test(k)) continue;   // 포트 아닌 키 — 백엔드 _normalize_forward 와 동일하게 조용히 무시
        const tgt = (v && typeof v === 'object' && !Array.isArray(v)) ? v.target : v;
        const tgtStr = (tgt == null) ? '' : String(tgt).trim();
        if (tgtStr) out[k] = tgtStr;
      }
      return out;
    }
    function xmCoerceGateway(val) {
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('gateway 는 매핑이어야 함');
      const keys = Object.keys(val);
      if (keys.some(k => k !== 'routes')) throw new Error('gateway 에 폼 미지원 하위키 존재(expose/primary 등) — 전체 원문 보존');
      const routesVal = val.routes;
      const routes = {};
      if (routesVal != null) {
        if (typeof routesVal !== 'object' || Array.isArray(routesVal)) throw new Error('gateway.routes 는 매핑이어야 함');
        for (const [svc, paths] of Object.entries(routesVal)) {
          if (!Array.isArray(paths)) throw new Error('gateway.routes.' + svc + ' 는 리스트여야 함');
          routes[svc] = paths.map(String);
        }
      }
      return { routes };
    }
    function xmCoercePrebuild(val) {
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('prebuild 는 매핑이어야 함');
      const out = {};
      for (const [k, v] of Object.entries(val)) {
        if (typeof v === 'string') { out[k] = v; continue; }
        if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error('prebuild.' + k + ' 은 명령 문자열 또는 {cwd, command} 여야 함');
        if (Object.keys(v).some(n => n !== 'cwd' && n !== 'command') || !Object.prototype.hasOwnProperty.call(v, 'cwd') || !Object.prototype.hasOwnProperty.call(v, 'command')) {
          throw new Error('prebuild.' + k + ' 객체에는 cwd, command 만 필요함');
        }
        if (typeof v.cwd !== 'string' || typeof v.command !== 'string') throw new Error('prebuild.' + k + ' 의 cwd, command 는 문자열이어야 함');
        out[k] = { cwd: v.cwd, command: v.command };
      }
      return out;
    }
    function xmCoerceJava(val) {
      if (typeof val !== 'string' && typeof val !== 'number') throw new Error('java 는 스칼라여야 함');
      return String(val);
    }
    function xmCoerceBuild(val) {
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('build 는 매핑이어야 함');
      const keys = Object.keys(val);
      if (keys.some(k => k !== 'args')) throw new Error('build 에 폼 미지원 하위키 존재 — 전체 원문 보존');
      const args = {};
      if (val.args != null) {
        if (typeof val.args !== 'object' || Array.isArray(val.args)) throw new Error('build.args 는 매핑이어야 함');
        for (const [k, v] of Object.entries(val.args)) args[k] = String(v);
      }
      return { args };
    }
    function xmCoerceStartGroup(val) {
      if (!Array.isArray(val)) throw new Error('startGroup 은 서비스 이름 리스트여야 함');
      return val.map(v => {
        if (typeof v !== 'string' && typeof v !== 'number') throw new Error('startGroup 항목은 서비스 이름(문자열)이어야 함');
        return String(v);
      });
    }
    const XM_COERCERS = { startGroup: xmCoerceStartGroup, links: xmCoerceLinks, forward: xmCoerceForward, gateway: xmCoerceGateway, prebuild: xmCoercePrebuild, java: xmCoerceJava, build: xmCoerceBuild };

    // compose YAML 전문에서 top-level `x-marina:` 블록 경계를 찾는다(백엔드 _edit_xmarina_block 과 동일 규칙:
    // col-0·비주석·비공백 줄이 나오면 블록 끝). 없으면 {xi:-1}.
    function xmFindBlock(lines) {
      let xi = -1;
      for (let i = 0; i < lines.length; i++) { if (lines[i].startsWith('x-marina:')) { xi = i; break; } }
      if (xi === -1) return { xi: -1, xj: -1 };
      let xj = lines.length;
      for (let i = xi + 1; i < lines.length; i++) {
        const l = lines[i];
        if (l.trim() !== '' && !/^\s/.test(l) && !l.trimStart().startsWith('#')) { xj = i; break; }
      }
      return { xi, xj };
    }

    // 에디터 YAML 텍스트 → {ok, xm, otherKeys[]}. ok:false 는 진짜 구조가 깨졌을 때만(폼 잠금 트리거).
    function wbParseXmarina(text) {
      const lines = (text || '').replace(/\r\n/g, '\n').split('\n');
      const { xi, xj } = xmFindBlock(lines);
      if (xi === -1) return { ok: true, xm: {}, otherKeys: [] };   // x-marina 블록 자체가 없음 — 유효한 빈 상태
      const headRest = xmStripComment(lines[xi]).slice('x-marina:'.length).trim();
      if (headRest && headRest !== '{}') return { ok: false, error: 'x-marina: 한 줄 형식은 지원하지 않음' };
      const blockLines = lines.slice(xi + 1, xj);
      if (/^[ ]*\t/m.test(blockLines.join('\n'))) return { ok: false, error: '탭 들여쓰기는 YAML 에서 허용되지 않음' };
      let top;
      try { top = xmParseBlockMap(blockLines); }
      catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
      const xm = {}; const otherKeys = [];
      for (const key of top.order) {
        const entry = top.entries[key];
        try {
          const coercer = XM_COERCERS[key];
          if (!coercer) throw new Error('미지원 키: ' + key);
          xm[key] = coercer(xmEntryValue(entry));
        } catch (e) {
          otherKeys.push({ key, raw: xmReindentEntry(entry, top.indent) });
        }
      }
      return { ok: true, xm, otherKeys };
    }

    function xmQuoteIfNeeded(s) {
      s = String(s == null ? '' : s);
      if (s !== '' && /^[A-Za-z0-9_.\/-]+$/.test(s)) return s;
      return "'" + s.replace(/'/g, "''") + "'";
    }
    function xmQuoteKeyIfNeeded(k) {
      k = String(k);
      if (/^\d+$/.test(k)) return "'" + k + "'";   // 포트 키 — docker compose config 가 비-string 키 거부
      return xmQuoteIfNeeded(k);
    }
    function xmDumpMapOfScalars(key, obj) {
      const lines = ['  ' + key + ':'];
      for (const k of Object.keys(obj)) lines.push('    ' + xmQuoteKeyIfNeeded(k) + ': ' + xmQuoteIfNeeded(obj[k]));
      return lines;
    }
    function xmLinksNonEmpty(links) {   // 전역 심링크/복사 또는 서브레포별 노드 중 하나라도 항목이 있으면 true
      if (!links) return false;
      if ((links.symlink && links.symlink.length) || (links.copy && links.copy.length)) return true;
      const subs = links.subs || {};
      return Object.keys(subs).some(s => {
        const n = subs[s] || {};
        return (n.symlink && n.symlink.length) || (n.copy && n.copy.length);
      });
    }
    function xmDumpLinks(links) {
      const lines = ['  links:'];
      for (const k of ['symlink', 'copy']) {   // 전역 — 최상위 symlink/copy
        const arr = links[k];
        if (!arr || !arr.length) continue;
        lines.push('    ' + k + ':');
        for (const item of arr) lines.push('    - ' + xmQuoteIfNeeded(item));
      }
      const subs = links.subs || {};   // 서브레포별 — links.<svc>.{symlink,copy}
      for (const sub of Object.keys(subs)) {
        const node = subs[sub] || {};
        const hasAny = (node.symlink && node.symlink.length) || (node.copy && node.copy.length);
        if (!hasAny) continue;
        lines.push('    ' + xmQuoteKeyIfNeeded(sub) + ':');
        for (const k of ['symlink', 'copy']) {
          const arr = node[k];
          if (!arr || !arr.length) continue;
          lines.push('      ' + k + ':');
          for (const item of arr) lines.push('      - ' + xmQuoteIfNeeded(item));
        }
      }
      return lines;
    }
    function xmDumpGateway(gateway) {
      const lines = ['  gateway:', '    routes:'];
      for (const svc of Object.keys(gateway.routes)) {
        const paths = gateway.routes[svc] || [];
        if (!paths.length) { lines.push('      ' + xmQuoteKeyIfNeeded(svc) + ': []'); continue; }
        lines.push('      ' + xmQuoteKeyIfNeeded(svc) + ':');
        for (const p of paths) lines.push('      - ' + xmQuoteIfNeeded(p));
      }
      return lines;
    }
    function xmDumpBuildArgs(build) {
      const lines = ['  build:', '    args:'];
      for (const k of Object.keys(build.args)) lines.push('      ' + xmQuoteKeyIfNeeded(k) + ': ' + xmQuoteIfNeeded(build.args[k]));
      return lines;
    }

    function xmDumpPrebuild(prebuild) {
      const lines = ['  prebuild:'];
      for (const key of Object.keys(prebuild)) {
        const value = prebuild[key];
        if (typeof value === 'string') {
          lines.push('    ' + xmQuoteKeyIfNeeded(key) + ': ' + xmQuoteIfNeeded(value));
          continue;
        }
        lines.push('    ' + xmQuoteKeyIfNeeded(key) + ':');
        lines.push('      cwd: ' + xmQuoteIfNeeded(value.cwd));
        lines.push('      command: ' + xmQuoteIfNeeded(value.command));
      }
      return lines;
    }

    function xmDumpStartGroup(arr) {
      return ['  startGroup:', ...arr.map(v => '  - ' + xmQuoteIfNeeded(v))];
    }

    // {xm, otherKeys} → "x-marina:\n..." 블록 텍스트(끝 개행 포함) — 아무 내용도 없으면 ''(블록 자체 생략).
    // 순서는 R4 표 + startGroup(가장 기초 개념이라 맨 앞): startGroup, links, forward, gateway, prebuild, java, build.args.
    function wbSerializeXmarina(xm, otherKeys) {
      const out = ['x-marina:'];
      const has = (k) => xm && xm[k] != null;
      if (has('startGroup') && xm.startGroup.length) out.push(...xmDumpStartGroup(xm.startGroup));
      if (has('links') && xmLinksNonEmpty(xm.links)) out.push(...xmDumpLinks(xm.links));
      if (has('forward') && Object.keys(xm.forward).length) out.push(...xmDumpMapOfScalars('forward', xm.forward));
      if (has('gateway') && xm.gateway.routes && Object.keys(xm.gateway.routes).length) out.push(...xmDumpGateway(xm.gateway));
      if (has('prebuild') && Object.keys(xm.prebuild).length) out.push(...xmDumpPrebuild(xm.prebuild));
      if (has('java') && String(xm.java).trim() !== '') out.push('  java: ' + xmQuoteIfNeeded(String(xm.java)));
      if (has('build') && xm.build.args && Object.keys(xm.build.args).length) out.push(...xmDumpBuildArgs(xm.build));
      for (const o of (otherKeys || [])) out.push(o.raw);
      if (out.length === 1) return '';   // "x-marina:" 헤더뿐 — 지원/미지원 어느 키도 안 남음
      return out.join('\n') + '\n';
    }

    // compose YAML 전문 안의 x-marina 블록만 서지컬 교체(services 쪽 텍스트·주석 불변) — 백엔드
    // _edit_xmarina_block 과 동일한 head/tail 슬라이싱. newBlockText 가 ''이면 블록을 통째로 제거.
    function wbReplaceXmarinaBlock(fullText, newBlockText) {
      const src = fullText || '';
      const lines = src.split('\n');
      const { xi, xj } = xmFindBlock(lines);
      if (xi === -1) {
        if (!newBlockText) return src;
        const sep = (src && !src.endsWith('\n')) ? '\n' : '';
        return src + sep + newBlockText;
      }
      const head = lines.slice(0, xi).join('\n') + (xi > 0 ? '\n' : '');
      const tail = lines.slice(xj).join('\n');
      let mid = newBlockText || '';
      if (tail && mid && !mid.endsWith('\n')) mid += '\n';
      return head + mid + tail;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ② 폼 UI/DOM 연동 — 아래부터는 document 를 참조한다(브라우저 전용, 자동 실행부는 typeof 가드).
    // ══════════════════════════════════════════════════════════════════════════

    let wbFormXm = null;         // 현재 폼 작업 사본(항상 6개 지원 컨테이너를 채워둠 — 렌더 단순화용, wbFormNormalize 가 보장)
    let wbFormOtherKeys = [];    // 마지막 파싱에서 보존된 미지원 항목(raw 원문)
    let wbFormLocked = false;    // YAML 파싱 실패 — 폼 잠금 배너만 표시
    let wbXmSyncTimer = null;
    let wbXmSyncGuard = false;   // 폼발 편집기 갱신이 만든 input 이벤트를 한 번 무시(루프 방지)

    // 파싱 직후 xm 은 "실제로 있던 키만" 담는다(직렬화 최소화가 목적) — 폼이 항상 다루기 쉬우려면
    // 6개 컨테이너가 항상 존재해야 하므로, 편집용 사본에서만 빈 컨테이너로 채워 넣는다(직렬화는 여전히
    // 빈 컨테이너를 생략하므로 손대지 않은 필드는 왕복해도 문서에 흔적을 안 남긴다).
    function wbFormNormalize(xm) {
      const out = { startGroup: [], links: { symlink: [], copy: [], subs: {} }, forward: {}, gateway: { routes: {} }, prebuild: {}, java: '', build: { args: {} } };
      if (xm.startGroup) out.startGroup = xm.startGroup.map(String);
      if (xm.links) {
        out.links.symlink = (xm.links.symlink || []).slice();
        out.links.copy = (xm.links.copy || []).slice();
        const subs = xm.links.subs || {};
        for (const s of Object.keys(subs)) out.links.subs[s] = { symlink: (subs[s].symlink || []).slice(), copy: (subs[s].copy || []).slice() };
      }
      if (xm.forward) out.forward = { ...xm.forward };
      if (xm.gateway) out.gateway = { routes: { ...(xm.gateway.routes || {}) } };
      if (xm.prebuild) {
        for (const [key, value] of Object.entries(xm.prebuild)) {
          out.prebuild[key] = (typeof value === 'string') ? value : { cwd: value.cwd, command: value.command };
        }
      }
      if (xm.java != null) out.java = xm.java;
      if (xm.build) out.build = { args: { ...(xm.build.args || {}) } };
      return out;
    }

    function wbFormSyncFromEditor() {
      const ta = document.getElementById('composeYaml');
      const text = ta ? ta.value : '';
      const r = wbParseXmarina(text);
      if (!r.ok) {
        wbFormLocked = true;
        wbFormRender();
        return;
      }
      wbFormLocked = false;
      wbFormXm = wbFormNormalize(r.xm);
      wbFormOtherKeys = r.otherKeys;
      wbFormRender();
    }
    function wbScheduleFormSync() {
      if (wbXmSyncGuard) { wbXmSyncGuard = false; return; }   // 폼이 방금 쓴 값을 되읽어 다시 그릴 필요 없음
      clearTimeout(wbXmSyncTimer);
      wbXmSyncTimer = setTimeout(wbFormSyncFromEditor, 400);
    }

    // 폼 상태 → x-marina 블록 텍스트 생성 → 에디터에 서지컬 교체 → (기존 draft-save·하이라이트 리스너가
    // 같이 반응하도록) 진짜 input 이벤트를 한 번 디스패치. wbScheduleFormSync 는 가드로 그 한 번을 스킵.
    function wbFormApplyToEditor() {
      const ta = document.getElementById('composeYaml');
      if (!ta || !wbFormXm) return;
      const blockText = wbSerializeXmarina(wbFormXm, wbFormOtherKeys);
      const merged = wbReplaceXmarinaBlock(ta.value, blockText);
      wbXmSyncGuard = true;
      if (typeof setComposeYaml === 'function') setComposeYaml(merged); else ta.value = merged;
      ta.dispatchEvent(new Event('input', { bubbles: true }));
    }
    function wbFormMutate(mutator) {
      if (!wbFormXm) wbFormXm = wbFormNormalize({});
      mutator(wbFormXm);
      wbFormApplyToEditor();
      wbFormRender();
    }

    // ── DOM 빌더(innerHTML 금지 — createElement/textContent 만) ─────────────────
    function wbMk(tag, cls) { const el = document.createElement(tag); if (cls) el.className = cls; return el; }
    function wbMkText(tag, cls, text) { const el = wbMk(tag, cls); el.textContent = text; return el; }
    function wbMkBtn(label, cls, onclick) { const b = wbMk('button', cls); b.type = 'button'; b.textContent = label; b.onclick = onclick; return b; }

    // 카드 머리 = 라벨 + 모노표기 + (?) 툴팁. 장황한 설명(desc)은 항상 노출 대신 툴팁으로 접어 세로 밀도를 줄인다(코덱스 UX #3).
    function wbCardShell(key) {
      const dict = WB_XM_DICT[key];
      const card = wbMk('div', 'wb-opt-card');
      card.dataset.wbOptKey = key;
      const head = wbMk('div', 'wb-opt-card-head');
      head.appendChild(wbMkText('span', 'wb-opt-label', dict.label));
      head.appendChild(wbMkText('span', 'wb-opt-mono', dict.mono));
      if (dict.desc) {
        const q = wbMkText('span', 'help-q', '?');
        q.title = dict.desc;
        head.appendChild(q);
      }
      card.appendChild(head);
      const body = wbMk('div', 'wb-opt-body');
      card.appendChild(body);
      return { card, body };
    }

    // 서비스 선택을 세로 체크박스行 대신 가로 wrap 토글칩으로 — startGroup·gateway 공용(세로 낭비 제거, 코덱스 UX #3).
    function wbToggleChips(services, isOn, onToggle, groupLabel) {
      const list = wbMk('div', 'wb-chip-toggles');
      list.setAttribute('role', 'group');
      if (groupLabel) list.setAttribute('aria-label', groupLabel);
      services.forEach(svc => {
        const chip = wbMk('button', 'wb-chip-toggle' + (isOn(svc) ? ' on' : ''));
        chip.type = 'button';
        chip.textContent = svc;
        chip.setAttribute('aria-pressed', isOn(svc) ? 'true' : 'false');
        chip.onclick = () => onToggle(svc, !isOn(svc));
        list.appendChild(chip);
      });
      return list;
    }

    // links 카드는 x-marina.links 의 두 형태를 그대로 반영한다:
    //   · 🌐 모든 서비스(전역) = links.{symlink,copy}   · 📦 서비스별 = links.<svc>.{symlink,copy}
    // 각 스코프 안에서 🔗 링크(symlink) / ⧉ 복사(copy) 두 버킷 — YAML 키 병기로 카드↔YAML 연결. 실프로젝트(mdc-main)는 서비스별.
    // 예전엔 전역만 다뤄 서비스별이 카드에 안 보이고 편집 시 links 블록 중복(손상). 백엔드는 전역이 있으면 서비스별을 무시(전역 우선).
    function wbRenderLinksCard() {
      const { card, body } = wbCardShell('links');
      // links 가 폼이 못 읽는 형태(malformed)면 원문이 otherKeys 로 보존된다 — 이때 카드로 편집하면 지원블록+원문블록이 겹쳐
      // links: 가 중복될 수 있으므로 편집을 막고 YAML 로 안내(코덱스 리뷰 P3).
      if (wbFormOtherKeys.some(o => o.key === 'links')) {
        body.appendChild(wbMkText('div', 'wb-links-warn', '이 links 는 폼이 읽을 수 없는 형태예요 — 오른쪽 YAML 에서 직접 편집하세요'));
        return card;
      }
      const links = wbFormXm.links;
      const subHasEntries = (s) => links.subs[s] && ((links.subs[s].symlink || []).length || (links.subs[s].copy || []).length);
      const globalHas = (links.symlink || []).length || (links.copy || []).length;

      if (globalHas && Object.keys(links.subs).some(subHasEntries)) {
        body.appendChild(wbMkText('div', 'wb-links-warn', '⚠ 전역(모든 서비스)이 설정돼 있어 서비스별 규칙은 무시돼요 — 둘 중 하나만 쓰세요'));
      }

      // 한 버킷(symlink|copy) — svc=null 이면 전역(links 루트), svc 이름이면 links.subs[svc]
      const renderBucket = (svc, key, icon, label, suggests) => {
        const node = (svc == null) ? links : (links.subs[svc] || { symlink: [], copy: [] });
        const arr = node[key] || [];
        const inScope = (v) => (node.symlink || []).includes(v) || (node.copy || []).includes(v);
        const mut = (fn) => wbFormMutate(xm => {
          const n = (svc == null) ? xm.links : (xm.links.subs[svc] = xm.links.subs[svc] || { symlink: [], copy: [] });
          if (!Array.isArray(n[key])) n[key] = [];
          fn(n[key]);
          if (svc != null) {   // 빈 서브레포 노드는 제거(YAML 에 빈 svc: {} 안 남김)
            const sn = xm.links.subs[svc];
            if (!(sn.symlink && sn.symlink.length) && !(sn.copy && sn.copy.length)) delete xm.links.subs[svc];
          }
        });
        const sec = wbMk('div', 'wb-links-bucket');
        const head = wbMk('div', 'wb-links-sec-head');
        head.appendChild(wbMkText('span', 'wb-links-sec-ic', icon));
        head.appendChild(wbMkText('span', 'wb-links-sec-title', label));
        head.appendChild(wbMkText('span', 'wb-opt-mono', key));
        sec.appendChild(head);
        const row = wbMk('div', 'wb-tag-add');
        arr.forEach((g, idx) => {
          const chip = wbMk('span', 'wb-tag');
          chip.appendChild(document.createTextNode(g + ' '));
          chip.appendChild(wbMkBtn('✕', 'wb-tag-x', () => mut(a => a.splice(idx, 1))));
          row.appendChild(chip);
        });
        suggests.forEach(sug => { if (inScope(sug)) return; row.appendChild(wbMkBtn('+ ' + sug, 'wb-quick', () => mut(a => a.push(sug)))); });
        const input = wbMk('input', 'wb-tag-input');
        input.placeholder = '폴더/글롭';
        row.appendChild(input);
        const add = () => { const v = input.value.trim(); if (!v || inScope(v)) return; mut(a => a.push(v)); };
        row.appendChild(wbMkBtn('추가', 'wb-tag-go', add));
        input.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
        sec.appendChild(row);
        return sec;
      };
      const scopeBuckets = (svc) => {
        const frag = document.createDocumentFragment();
        frag.appendChild(renderBucket(svc, 'symlink', '🔗', '링크', ['node_modules', '.venv']));
        frag.appendChild(renderBucket(svc, 'copy', '⧉', '복사', ['dist', '.gradle', 'build']));
        return frag;
      };

      // 🌐 전역
      const gsec = wbMk('div', 'wb-links-scope');
      gsec.appendChild(wbMkText('div', 'wb-links-scope-head', '🌐 모든 서비스 (전역)'));
      gsec.appendChild(scopeBuckets(null));
      body.appendChild(gsec);

      // 📦 서비스별 — compose 서비스 ∪ 이미 정의된 서브레포 키
      const services = typeof wbUsedServiceNames === 'function' ? [...wbUsedServiceNames()] : [];
      const allSubs = [...new Set([...services, ...Object.keys(links.subs)])].sort();
      if (allSubs.length) {
        body.appendChild(wbMkText('div', 'wb-links-scope-head', '📦 서비스별 (그 서비스만)'));
        allSubs.forEach(svc => {
          const det = document.createElement('details');
          det.className = 'wb-links-svc';
          if (subHasEntries(svc)) det.open = true;
          const sm = document.createElement('summary');
          const cnt = links.subs[svc] ? ((links.subs[svc].symlink || []).length + (links.subs[svc].copy || []).length) : 0;
          sm.textContent = svc + (cnt ? ' · ' + cnt : '');
          det.appendChild(sm);
          det.appendChild(scopeBuckets(svc));
          body.appendChild(det);
        });
      }
      return card;
    }

    function wbRenderForwardCard() {
      const { card, body } = wbCardShell('forward');
      const fwd = wbFormXm.forward;
      const rows = wbMk('div', 'wb-row-list');
      Object.keys(fwd).sort().forEach(port => {
        const row = wbMk('div', 'wb-row');
        row.appendChild(wbMkText('span', 'mono-port', port));
        row.appendChild(wbMkText('span', 'wb-row-arrow', '→'));
        row.appendChild(wbMkText('span', 'wb-row-target', fwd[port]));
        row.appendChild(wbMkBtn('✕', 'wb-row-x', () => wbFormMutate(xm => { delete xm.forward[port]; })));
        rows.appendChild(row);
      });
      body.appendChild(rows);
      const addRow = wbMk('div', 'wb-tag-add');
      [['Redis', '6379'], ['MySQL', '3306'], ['PostgreSQL', '5432']].forEach(([name, port]) => {
        if (fwd[port]) return;
        addRow.appendChild(wbMkBtn('+ ' + name + '(' + port + ')', 'wb-quick', () => wbFormMutate(xm => { xm.forward[port] = 'host'; })));
      });
      const input = wbMk('input', 'wb-port-input');
      input.placeholder = '포트 번호'; input.inputMode = 'numeric';
      addRow.appendChild(input);
      const addPort = () => {
        const v = input.value.trim();
        if (!/^\d+$/.test(v)) return;
        wbFormMutate(xm => { xm.forward[v] = 'host'; });
      };
      addRow.appendChild(wbMkBtn('추가', 'wb-tag-go', addPort));
      input.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addPort(); } });
      body.appendChild(addRow);
      return card;
    }

    function wbRenderStartGroupCard() {
      const { card, body } = wbCardShell('startGroup');
      const services = typeof wbUsedServiceNames === 'function' ? [...wbUsedServiceNames()].sort() : [];
      if (!services.length) {
        body.appendChild(wbMkText('div', 'wb-opt-empty', '우측 YAML 에 services 를 먼저 추가하세요'));
        return card;
      }
      const auto = wbFormXm.startGroup;
      body.appendChild(wbMkText('div', 'wb-opt-note',
        auto.length ? '▶ 전체시작 = 켠 서비스만. 나머지는 개별 시작.' : '선언 없음 — 전체시작이 전부 켭니다. 고르면 그것만.'));
      body.appendChild(wbToggleChips(services, svc => auto.includes(svc), (svc, on) => wbFormMutate(xm => {
        if (on) { if (!xm.startGroup.includes(svc)) xm.startGroup.push(svc); }
        else xm.startGroup = xm.startGroup.filter(s => s !== svc);
      }), '전체시작에 포함할 서비스'));
      return card;
    }

    function wbRenderGatewayCard() {
      const { card, body } = wbCardShell('gateway');
      const services = typeof wbUsedServiceNames === 'function' ? [...wbUsedServiceNames()].sort() : [];
      if (!services.length) {
        body.appendChild(wbMkText('div', 'wb-opt-empty', '우측 YAML 에 services 를 먼저 추가하세요'));
        return card;
      }
      body.appendChild(wbToggleChips(services,
        svc => Object.prototype.hasOwnProperty.call(wbFormXm.gateway.routes, svc),
        (svc, on) => wbFormMutate(xm => {
          if (on) xm.gateway.routes[svc] = xm.gateway.routes[svc] || [];
          else delete xm.gateway.routes[svc];
        }), '브라우저 주소를 발급할 서비스'));
      return card;
    }

    function wbRenderPrebuildCard() {
      const { card, body } = wbCardShell('prebuild');
      const pb = wbFormXm.prebuild;
      const rows = wbMk('div', 'wb-row-list');
      Object.keys(pb).forEach(key => {
        const value = pb[key];
        const serviceMode = typeof value !== 'string';
        const row = wbMk('div', 'wb-prebuild-row');
        const modeInput = wbMk('select', 'wb-prebuild-mode');
        [['service', '서비스'], ['legacy', '레거시']].forEach(([optionValue, label]) => {
          const option = document.createElement('option'); option.value = optionValue; option.textContent = label; modeInput.appendChild(option);
        });
        modeInput.value = serviceMode ? 'service' : 'legacy';
        const keyInput = wbMk('input', 'wb-prebuild-key'); keyInput.value = key; keyInput.placeholder = serviceMode ? '서비스' : '서브레포';
        const cwdInput = wbMk('input', 'wb-prebuild-cwd'); cwdInput.value = serviceMode ? value.cwd : ''; cwdInput.placeholder = '작업 경로'; cwdInput.disabled = !serviceMode;
        const cmdInput = wbMk('input', 'wb-prebuild-cmd'); cmdInput.value = serviceMode ? value.command : value; cmdInput.placeholder = '명령';
        const commit = () => {
          const newKey = keyInput.value.trim(), cmd = cmdInput.value.trim();
          wbFormMutate(xm => {
            delete xm.prebuild[key];
            if (!newKey) return;
            xm.prebuild[newKey] = modeInput.value === 'service'
              ? { cwd: cwdInput.value.trim() || '.', command: cmd }
              : cmd;
          });
        };
        modeInput.addEventListener('change', commit);
        keyInput.addEventListener('change', commit);
        cwdInput.addEventListener('change', commit);
        cmdInput.addEventListener('change', commit);
        row.appendChild(modeInput);
        row.appendChild(keyInput);
        row.appendChild(cwdInput);
        row.appendChild(cmdInput);
        row.appendChild(wbMkBtn('✕', 'wb-row-x', () => wbFormMutate(xm => { delete xm.prebuild[key]; })));
        rows.appendChild(row);
      });
      body.appendChild(rows);
      body.appendChild(wbMkBtn('+ 추가', 'wb-add-row', () => wbFormMutate(xm => {
        let n = 1, key = 'service' + n;
        while (Object.prototype.hasOwnProperty.call(xm.prebuild, key)) key = 'service' + (++n);
        xm.prebuild[key] = { cwd: '.', command: '' };
      })));
      return card;
    }

    function wbRenderJavaCard() {
      const { card, body } = wbCardShell('java');
      const input = wbMk('input', 'wb-java-input');
      input.placeholder = '예: 21';
      input.value = wbFormXm.java || '';
      input.addEventListener('change', () => wbFormMutate(xm => { xm.java = input.value.trim(); }));
      body.appendChild(input);
      return card;
    }

    function wbRenderBuildCard() {
      const { card, body } = wbCardShell('build');
      const args = wbFormXm.build.args;
      const rows = wbMk('div', 'wb-row-list');
      Object.keys(args).forEach(k => {
        const row = wbMk('div', 'wb-row');
        const keyInput = wbMk('input', 'wb-build-key'); keyInput.value = k; keyInput.placeholder = 'ARG 이름';
        const valInput = wbMk('input', 'wb-build-val'); valInput.value = args[k]; valInput.placeholder = '값';
        const commit = () => {
          const newKey = keyInput.value.trim(), val = valInput.value;
          wbFormMutate(xm => {
            delete xm.build.args[k];
            if (newKey) xm.build.args[newKey] = val;
          });
        };
        keyInput.addEventListener('change', commit);
        valInput.addEventListener('change', commit);
        row.appendChild(keyInput);
        row.appendChild(wbMkText('span', 'wb-row-arrow', '='));
        row.appendChild(valInput);
        row.appendChild(wbMkBtn('✕', 'wb-row-x', () => wbFormMutate(xm => { delete xm.build.args[k]; })));
        rows.appendChild(row);
      });
      body.appendChild(rows);
      body.appendChild(wbMkBtn('+ 추가', 'wb-add-row', () => wbFormMutate(xm => {
        let n = 1, key = 'ARG' + n;
        while (Object.prototype.hasOwnProperty.call(xm.build.args, key)) key = 'ARG' + (++n);
        xm.build.args[key] = '';
      })));
      return card;
    }

    function wbFormRender() {
      const root = document.querySelector('[data-wb-form]');
      if (!root) return;
      while (root.firstChild) root.removeChild(root.firstChild);
      root.classList.remove('wb-placeholder');   // 초기 정적 플레이스홀더 박스 스타일 제거 — 카드형으로 대체
      root.classList.add('wb-opt-panel');
      if (wbFormLocked) {
        const lock = wbMk('div', 'wb-opt-lock');
        lock.appendChild(wbMkText('span', '', '⚠️ ' + WB_XM_LOCK_MSG));
        root.appendChild(lock);
        return;
      }
      if (!wbFormXm) wbFormXm = wbFormNormalize({});
      const head = wbMk('div', 'wb-opt-head');
      head.appendChild(wbMkText('span', 'wb-opt-title', '⚙️ marina 옵션'));
      root.appendChild(head);
      root.appendChild(wbRenderStartGroupCard());
      root.appendChild(wbRenderLinksCard());
      root.appendChild(wbRenderForwardCard());
      root.appendChild(wbRenderGatewayCard());
      root.appendChild(wbRenderPrebuildCard());
      const adv = document.createElement('details');
      adv.className = 'wb-opt-advanced';
      const summary = document.createElement('summary');
      summary.textContent = '고급';
      adv.appendChild(summary);
      adv.appendChild(wbRenderJavaCard());
      adv.appendChild(wbRenderBuildCard());
      root.appendChild(adv);
      if (wbFormOtherKeys.length) {
        root.appendChild(wbMkText('div', 'wb-opt-other', '그 외 설정 ' + wbFormOtherKeys.length + '개(YAML 참조)'));
      }
    }

    // 브라우저 전용 배선 — node 왕복 테스트가 이 파일을 그대로 eval 해도 안전하도록 typeof 가드.
    if (typeof document !== 'undefined') {
      const ta = document.getElementById('composeYaml');
      if (ta) ta.addEventListener('input', wbScheduleFormSync);
    }
