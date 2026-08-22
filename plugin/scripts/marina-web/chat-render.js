// chat-render.js — 에이전트 대화 타임라인 렌더러. **웹 대시보드와 모바일이 공유한다.**
//
// 왜 공유하나. 예전엔 모바일에만 타임라인이 있었고 웹은 읽기전용 텍스트 모달이었다. 웹에 채팅을
// 붙이면서 렌더러를 새로 짜면 두 벌이 되고, 그러면 지금 고치고 있는 "둘이 벌어짐"이 그대로
// 재생산된다. 그래서 마크업 계약(클래스명·구조)을 여기 한 곳에 두고 CSS 스킨만 각자 입힌다.
//
// 규칙. 이 파일은 **호스트 앱 상태를 모른다.** 필요한 것은 configure() 로 받은 어댑터 세 개뿐이다.
// 함수마다 opts 를 넘기지 않는 이유: 30개 시그니처를 다 고치면 순수 이동이 아니게 되고 회귀
// 위험만 커진다. 모바일 전역(selectedSession·liveAnswer·turnsEl 등)을 직접 참조하면
// test-chat-render-shared.sh 가 막는다.
(function () {
  'use strict';

  // ── 호스트 어댑터 ──
  // imageUrl(ref)            대화 안 이미지의 URL. 인증 방식이 웹/모바일에서 다르다.
  // fileUrl(path)            세션이 만든 파일의 URL.
  // ensureAnswerState(qs, t) 질문 카드의 선택 상태. 라이브 카드와 공유해야 해서 호스트가 소유한다.
  // displayModel(model)      모델 표시 이름. 호스트의 모델 카탈로그를 봐야 한다.
  // uploadUrl(nameOrPath)    업로드 파일 URL. 인증 방식이 웹/모바일에서 다르다.
  const host = {
    imageUrl: () => "",
    fileUrl: () => "",
    ensureAnswerState: () => null,
    displayModel: (model) => String(model || ""),
    uploadUrl: () => "",
  };
  function configure(adapter) { Object.assign(host, adapter || {}); }

  // ── 렌더러 소유 상태 ──
  // 펼쳐 둔 <details> 는 렌더 상태다(누가 무엇을 보고 있나) — 호스트가 아니라 여기가 기억한다.
  // 세션이 바뀌면 스코프만 갈아 끼운다. 그래야 A 세션에서 편 것이 B 세션에 새어 들지 않는다.
  const openDetailIds = new Set();
  let detailScope = "";
  function setDetailScope(key) { detailScope = String(key || ""); }
  // ── 렌더 상수 (호스트 무관) ── 옮긴 렌더 함수들이 쓴다.
  // RENDER_CONSTS_START  (테스트가 함수와 함께 이 블록을 vm 에 싣는다)
    const activityTypeLabels = {skill: "Skill", command: "명령", diff: "Diff", file: "파일", agent: "에이전트", progress: "진행", tool: "도구"};
    const UPLOAD_PATH_RE = /(?:^|\s)(\/[^\s]*\/mobile-uploads\/[^\s]+)/g;
    const ACTIVITY_SUMMARY_ORDER = ["skill", "command", "diff", "file", "agent", "progress", "tool"];
    const IMAGE_EXT_RE = /\.(png|jpe?g|gif|webp|bmp|heic|svg)$/i;
  // RENDER_CONSTS_END
  function noteDetailToggle(id, open) {
    const key = `${detailScope}:${id || "detail"}`;
    if (open) openDetailIds.add(key);
    else openDetailIds.delete(key);
  }

    // ESC_HELPERS_START
    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[ch]));
    }
    function renderInlineMarkdown(value) {
      return esc(value)
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    }
    function renderRichText(value) {
      const text = String(value ?? "");
      const pattern = /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>]+)/g;
      let html = "";
      let cursor = 0;
      for (const match of text.matchAll(pattern)) {
        html += renderInlineMarkdown(text.slice(cursor, match.index));
        const label = match[1] || match[3];
        let url = match[2] || match[3];
        let suffix = "";
        if (!match[2]) {
          const trailing = url.match(/[.,!?;:)]+$/);
          if (trailing) {
            suffix = trailing[0];
            url = url.slice(0, -suffix.length);
          }
        }
        html += `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${renderInlineMarkdown(label.slice(0, label.length - suffix.length))}</a>${esc(suffix)}`;
        cursor = match.index + match[0].length;
      }
      html += renderInlineMarkdown(text.slice(cursor));
      return html.replace(/\n/g, "<br>");
    }
    // ESC_HELPERS_END
    // MARKDOWN_BLOCKS_START
    // 말풍선 본문은 인라인 렌더만으론 부족하다. 형 기록을 세보면 assistant 텍스트의 24% 가 코드펜스 안
    // 박스 다이어그램, 23% 가 목록, 13% 가 제목, 9% 가 표다. 인라인만 돌리면 파이프(|)·백틱·#가 날것으로
    // 나오고, 다이어그램은 비례폰트 + 공백 접힘 + <br> 조합으로 뭉개져 아예 못 읽는다(형: "시각화 위젯을
    // 볼 수가 없어"). 블록으로 먼저 자른 뒤 각 블록 안에서 기존 인라인 렌더를 쓴다.
    function mdTableCells(line) {
      let body = line.trim();
      if (body.startsWith("|")) body = body.slice(1);
      if (body.endsWith("|") && !body.endsWith("\\|")) body = body.slice(0, -1);
      return body.split(/(?<!\\)\|/).map(cell => cell.replace(/\\\|/g, "|").trim());
    }
    function mdIsTableRow(line) { return /\|/.test(line || "") && /\S/.test(line || ""); }
    function mdIsTableDivider(line) { return /^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/.test(line || "") && /\|/.test(line || "") && /-/.test(line || ""); }
    function mdListMarker(line) {
      const bullet = (line || "").match(/^(\s*)([-*+])\s+(.*)$/);
      if (bullet) return {indent: bullet[1].length, ordered: false, text: bullet[3]};
      const ordered = (line || "").match(/^(\s*)(\d{1,9})[.)]\s+(.*)$/);
      if (ordered) return {indent: ordered[1].length, ordered: true, text: ordered[3]};
      return null;
    }
    function renderMarkdownBlocks(value) {
      const lines = String(value ?? "").split("\n");
      const out = [];
      let i = 0;
      while (i < lines.length) {
        const line = lines[i];
        // ① 코드펜스 — 공백과 정렬을 글자 그대로 보존해야 다이어그램이 산다(가로 스크롤로 잘림 방지).
        const fence = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
        if (fence) {
          const marker = fence[1][0], width = fence[1].length;
          const lang = (fence[2] || "").trim().split(/\s+/)[0];
          const body = [];
          i += 1;
          while (i < lines.length) {
            const close = lines[i].match(/^\s{0,3}(`{3,}|~{3,})\s*$/);
            if (close && close[1][0] === marker && close[1].length >= width) { i += 1; break; }
            body.push(lines[i]); i += 1;
          }
          const label = lang ? `<span class="mdCodeLang">${esc(lang)}</span>` : "";
          out.push(`<div class="mdCode">${label}<pre><code>${esc(body.join("\n"))}</code></pre></div>`);
          continue;
        }
        // ② 표 — 헤더 다음 줄이 구분선일 때만. 좁은 화면이라 가로 스크롤 컨테이너에 넣는다.
        if (mdIsTableRow(line) && mdIsTableDivider(lines[i + 1])) {
          const header = mdTableCells(line);
          const aligns = mdTableCells(lines[i + 1]).map(spec => {
            const left = spec.startsWith(":"), right = spec.endsWith(":");
            return right && left ? "center" : right ? "right" : left ? "left" : "";
          });
          i += 2;
          const rows = [];
          while (i < lines.length && mdIsTableRow(lines[i]) && !mdIsTableDivider(lines[i])) {
            rows.push(mdTableCells(lines[i])); i += 1;
          }
          const cell = (text, tag, index) => {
            const align = aligns[index] ? ` style="text-align:${aligns[index]}"` : "";
            return `<${tag}${align}>${renderRichText(text)}</${tag}>`;
          };
          const head = `<tr>${header.map((text, index) => cell(text, "th", index)).join("")}</tr>`;
          const body = rows.map(row => `<tr>${header.map((_, index) => cell(row[index] ?? "", "td", index)).join("")}</tr>`).join("");
          out.push(`<div class="mdTableWrap"><table class="mdTable"><thead>${head}</thead><tbody>${body}</tbody></table></div>`);
          continue;
        }
        // ③ 제목
        const heading = line.match(/^\s{0,3}(#{1,6})\s+(.*)$/);
        if (heading) {
          out.push(`<div class="mdH mdH${heading[1].length}">${renderRichText(heading[2].replace(/\s+#+\s*$/, ""))}</div>`);
          i += 1; continue;
        }
        // ④ 구분선
        if (/^\s{0,3}([-*_])\s*(\1\s*){2,}$/.test(line)) { out.push('<hr class="mdHr">'); i += 1; continue; }
        // ⑤ 인용
        if (/^\s{0,3}>\s?/.test(line)) {
          const body = [];
          while (i < lines.length && /^\s{0,3}>\s?/.test(lines[i])) { body.push(lines[i].replace(/^\s{0,3}>\s?/, "")); i += 1; }
          out.push(`<blockquote class="mdQuote">${renderMarkdownBlocks(body.join("\n"))}</blockquote>`);
          continue;
        }
        // ⑥ 목록 — 들여쓰기 2칸마다 한 단계. 항목 하나가 여러 줄이면 이어 붙인다.
        if (mdListMarker(line)) {
          const items = [];
          while (i < lines.length) {
            const marker = mdListMarker(lines[i]);
            if (marker) { items.push({...marker, lines: [marker.text]}); i += 1; continue; }
            if (!lines[i].trim()) break;
            if (!items.length || mdIsTableRow(lines[i]) || /^\s{0,3}(#{1,6}\s|`{3,}|~{3,}|>)/.test(lines[i])) break;
            items[items.length - 1].lines.push(lines[i].trim()); i += 1;   // 계속 줄
          }
          out.push(mdRenderList(items, 0));
          continue;
        }
        // ⑦ 빈 줄
        if (!line.trim()) { i += 1; continue; }
        // ⑧ 문단 — 다음 블록 시작 전까지 모은다.
        const paragraph = [];
        while (i < lines.length && lines[i].trim()
               && !mdListMarker(lines[i])
               && !/^\s{0,3}(#{1,6}\s|`{3,}|~{3,}|>)/.test(lines[i])
               && !/^\s{0,3}([-*_])\s*(\1\s*){2,}$/.test(lines[i])
               && !(mdIsTableRow(lines[i]) && mdIsTableDivider(lines[i + 1]))) {
          paragraph.push(lines[i]); i += 1;
        }
        if (paragraph.length) out.push(`<p class="mdP">${renderRichText(paragraph.join("\n"))}</p>`);
        else i += 1;   // 어떤 규칙에도 안 걸린 줄 — 무한루프 방지
      }
      return out.join("");
    }
    function mdRenderList(items, depth) {
      let html = "";
      let index = 0;
      while (index < items.length) {
        const item = items[index];
        const tag = item.ordered ? "ol" : "ul";
        const group = [];
        while (index < items.length && items[index].indent <= item.indent && items[index].ordered === item.ordered) {
          const current = items[index];
          index += 1;
          const nested = [];
          while (index < items.length && items[index].indent > current.indent) { nested.push(items[index]); index += 1; }
          group.push(`<li>${renderRichText(current.lines.join("\n"))}${nested.length ? mdRenderList(nested, depth + 1) : ""}</li>`);
        }
        html += `<${tag} class="mdList">${group.join("")}</${tag}>`;
      }
      return html;
    }
    // MARKDOWN_BLOCKS_END
    function renderActivityCode(value, type) {
      const escaped = esc(String(value ?? ""));
      if (type !== "diff") return escaped;   // diff 활동만 unified-diff 색칠(다른 출력의 +/- 오탐 방지)
      return escaped.split("\n").map(line => {
        if (line.startsWith("@@")) return `<span class="diffHunk">${line}</span>`;
        if (line.startsWith("+") && !line.startsWith("+++")) return `<span class="diffAdd">${line}</span>`;
        if (line.startsWith("-") && !line.startsWith("---")) return `<span class="diffDel">${line}</span>`;
        return line;
      }).join("\n");
    }
    function sessionSource(session) {
      const raw = String((session && (session.source || (session.target && session.target.source))) || "").toLowerCase();
      if (raw === "codex") return "codex";
      if (raw === "claude") return "claude";
      return "terminal";
    }
    function pendingDeliveryLabel(delivery, createdAt=0) {
      // queue/steer/started 는 서버가 이미 전달을 확정한 상태 — 에이전트가 현재 턴을 끝내야 트랜스크립트에
      // 나타나므로(긴 턴이면 수 분) 나이와 무관하게 제 라벨을 유지한다. 예전엔 10초 지나면 무조건
      // "전달 확인 안 됨" 으로 뒤집혀 큐 메시지가 오탐으로 실패처럼 보였다(형 피드백).
      // accepted = 한가한 세션에 넣고 **도착까지 확인**했다. 예전엔 이것도 "대기열"로 떠서
      // 놀고 있던 세션에 보내도 줄 선 것처럼 보였다(형: "바로바로 접수된거로 표현").
      if (delivery === "accepted") return "접수됨";
      if (delivery === "steer") return "현재 작업에 전달됨";
      if (delivery === "queue") return "작업 끝나면 전달돼요 · 대기열";
      if (delivery === "started") return "새 작업 시작 중";
      if (delivery === "failed") return "전송 안 됨 · 탭해서 다시 보내기";
      // held = 세션이 입력을 안 받아(트랜스크립트 확인 실패) 보류함에 보존됨 — 회복되면 자동 전달.
      if (delivery === "held") return "세션이 입력을 안 받아 보류 중 · 회복되면 자동 전달";
      if (delivery === "held-compacting") return "컨텍스트가 가득 차 압축 중 · 끝나면 자동 전달";
      // delivery 미확정(서버 응답 전 pending)만 오래되면 실패로 표기.
      if (createdAt && Date.now() - Number(createdAt) > 15000) return "전달 확인 안 됨";
      return "보내는 중…";   // 서버 응답 전. "확인 중"은 안 간 것처럼 읽혀 불안하다
    }
    function runtimeLabel(runtime, includeSource="") {
      const parts = [includeSource, host.displayModel(runtime && runtime.model), runtime && runtime.effort].filter(Boolean);
      return parts.join(" · ");
    }
    function mergeHistoryTurns(existing, incoming) {
      const out = existing.slice();
      const ids = new Set(out.filter(turn => turn.id).map(turn => turn.id));
      const legacy = new Set(out.filter(turn => !turn.id).map(turn => `${turn.role}\n${turn.text}`));
      for (const turn of incoming || []) {
        if (turn.id) {
          if (ids.has(turn.id)) continue;
          ids.add(turn.id);
        } else {
          const key = `${turn.role}\n${turn.text}`;
          if (legacy.has(key)) continue;
          legacy.add(key);
        }
        out.push(turn);
      }
      if (out.every(turn => /^\d+:\d+$/.test(String(turn.id || "")))) {
        out.sort((a, b) => Number(a.id.split(":", 1)[0]) - Number(b.id.split(":", 1)[0]));
      }
      return out;
    }
    function timelineFromTurns(turns) {
      return (turns || []).map((turn, index) => ({
        ...turn, kind: "message", id: turn.id || `legacy:message:${index}:${turn.role || "assistant"}`,
      }));
    }
    function mergeTimelineItems(existing, incoming, prepend=false) {
      const ordered = prepend ? (incoming || []).concat(existing || []) : (existing || []).concat(incoming || []);
      const seen = new Set();
      return ordered.filter((item, index) => {
        const id = String(item.id || `legacy:${item.kind || "message"}:${item.role || ""}:${index}:${item.text || item.label || ""}`);
        if (seen.has(id)) return false;
        seen.add(id);
        return true;
      });
    }
    function exchangeSections(exchange) {
      const items = (exchange && exchange.items) || [];
      const user = exchange && exchange.user;
      let assistantIndex = -1;
      for (let index = items.length - 1; index >= 0; index -= 1) {
        if (items[index].kind === "message" && items[index].role === "assistant") { assistantIndex = index; break; }
      }
      const isQueuedMsg = it => it.kind === "message" && it.role === "user" && it.queued;
      const queued = items.filter(it => it !== user && isQueuedMsg(it));   // 진행 중 끼어든 큐 메시지 → 인라인 말풍선
      // 활동은 **진짜 도구 호출만**. 예전엔 마지막 것 말고 모든 어시스턴트 텍스트를 "진행 메모" 활동으로
      // 바꿔 접힌 목록에 묻었는데, 그러면 결과만 덩그러니 남고 왜 그랬는지가 사라진다(형 지적).
      const activities = items.filter(item => item.kind === "activity");
      // 질문은 활동이 아니라 대화다 — 접힌 목록엔 안 들어가되, 골격 비교에는 잡혀야 한다
      // (안 그러면 질문 카드가 붙어도 exchange 를 다시 안 그려 화면에 안 나타난다).
      const questions = items.filter(item => item.kind === "question");
      return {user, queued, activities, questions,
              assistant: assistantIndex >= 0 ? items[assistantIndex] : null};
    }
    // EXCHANGE_RUNS_START
    // exchange 를 **시간 순서대로** 조각낸다: 말풍선(어시스턴트 설명 · 끼어든 메시지)과 연속 활동 묶음.
    // 예전엔 활동을 전부 앞에 몰고 마지막 텍스트만 말풍선으로 그려서, 실제 흐름과 순서가 달랐다.
    function exchangeRuns(exchange) {
      const items = (exchange && exchange.items) || [];
      const user = exchange && exchange.user;
      const runs = [];
      let current = null;
      for (const item of items) {
        if (item === user) continue;
        if (item.kind === "activity") {
          if (!current) { current = {type: "activities", items: []}; runs.push(current); }
          current.items.push(item);
          continue;
        }
        current = null;                       // 말풍선이 끼면 활동 묶음을 끊는다(순서 보존)
        runs.push({type: "message", item});
      }
      return runs;
    }
    // EXCHANGE_RUNS_END
    function exchangeRuntime(exchange, session=null, allowFallback=false) {
      const items = ((exchange && exchange.items) || []).slice().reverse();
      const item = items.find(value => value && (value.model || value.effort));
      if (item) return {model: item.model || "", effort: item.effort || ""};
      if (allowFallback && session && session.settings) return session.settings.current || {model: "", effort: ""};
      return {model: "", effort: ""};
    }
    function renderTurnMeta(exchange, session, allowFallback=false, alignRight=false) {
      const runtime = exchangeRuntime(exchange, session, allowFallback);
      const label = runtimeLabel(runtime);   // 소스접두 없이 브랜드 포함 모델명(+effort) — "Claude Opus 4.8 · high"
      // 응답 전(내 메시지 밑)=우측(내 말풍선 쪽), 응답 후(Claude 응답 밑)=좌측(응답 말풍선 쪽).
      return label ? `<div class="turnMeta${alignRight ? " right" : ""}">${esc(label)}</div>` : "";
    }
    function renderLiveAction(exchange, sections, session, isLatest) {
      if (!isLatest || !session || session.status !== "working") return "";
      const running = sections.activities.filter(item => item.status === "running");
      // 실제 '실행 중'인 활동이 있을 때만 스피너. 활동 없이 대기/응답만 남은 상태를 실행 중처럼 보이게 하지 않기(형 지적).
      const current = running[running.length - 1];
      if (!current) return "";
      const label = current.label || current.name || activityTypeLabels[current.activityType] || "작업 중";
      const runtime = exchangeRuntime(exchange, session, true);
      const meta = runtimeLabel(runtime);
      const target = sections.activities.length ? `group:exchange:${exchange.id}` : "";
      return `<button class="liveAction" type="button" data-live-action="${esc(target)}"><span class="liveActionDot"></span><span class="liveActionLabel">${esc(label)}</span><span class="liveActionMeta">${esc(meta)}</span></button>`;
    }
    function extractAttachments(text) {
      const items = [];
      let stripped = text;
      for (const match of text.matchAll(UPLOAD_PATH_RE)) {
        const path = match[1];
        const name = path.split("/").pop().replace(/^[0-9a-f]{16}-/, "");
        items.push({path, name, url: host.uploadUrl(path), isImage: IMAGE_EXT_RE.test(path)});
        stripped = stripped.replace(path, "");
      }
      return {items, stripped: stripped.replace(/\n{3,}/g, "\n\n").trim()};
    }
    function renderTurnAttachments(items) {
      if (!items.length) return "";
      const cells = items.map(a => a.isImage
        ? `<a href="${esc(a.url)}" target="_blank" rel="noopener noreferrer"><img src="${esc(a.url)}" alt="${esc(a.name)}" loading="lazy" /></a>`
        : `<a href="${esc(a.url)}" target="_blank" rel="noopener noreferrer">${esc(a.name)}</a>`).join("");
      return `<div class="turnAttachments">${cells}</div>`;
    }
    function renderTimelineImages(item, className) {
      const images = Array.isArray(item && item.images) ? item.images : [];
      if (!images.length) return "";
      const cells = images.map(img => {
        const url = host.imageUrl(img && img.ref);
        if (!url) return "";
        return `<button class="turnImageBtn" type="button" data-image-ref="${esc(img.ref)}"><img src="${esc(url)}" alt="대화 이미지" loading="lazy" /></button>`;
      }).join("");
      return cells ? `<div class="${className || "turnAttachments"}">${cells}</div>` : "";
    }
    function renderTimelineMessage(item) {
      if (item && item.kind === "question") return renderAnsweredQuestion(item);
      const text = String(item.text || "");
      const role = item.role === "user" ? "user" : item.role === "output" ? "output" : "assistant";
      const {items: attachments, stripped} = extractAttachments(text);
      const pendingActions = item.pending && item.id
        ? `<span class="pendingActions"><button class="pendingActionBtn" type="button" data-pending-retry="${esc(item.id)}">&#8635; 재시도</button><button class="pendingActionBtn" type="button" data-pending-cancel="${esc(item.id)}">&#10005; 취소</button></span>`
        : "";
      const pendingState = item.pending ? `<div class="turnState${item.failed ? " failed" : ""}"${item.failed ? ` data-resend-text="${esc(item.text || "")}"` : ""}><span>${esc(pendingDeliveryLabel(item.delivery, item.createdAt))}</span>${pendingActions}</div>` : "";
      // 전달된 큐는 서버에서 아예 말풍선을 안 만든다(진짜 user 행이 대신한다) — 여기 남는 건
      // 아직 기다리는 것과 사용자가 취소한 것뿐이다.
      // steered = 작업 중에 끼어들어 그 턴이 이미 삼킨 말. 대기도 취소도 아니라서 별도 표시를 쓴다
      // (예전엔 remove 만 보고 "취소됨"을 붙여, 실제로 소화한 말이 취소된 것처럼 보였다).
      const queuedBadge = item.steered
        ? `<span class="queuedTag steered">⤳ 전달됨</span>`
        : item.queued
        ? `<span class="queuedTag${item.queuedCancelled ? " consumed" : ""}">⏱ ${item.queuedCancelled ? "대기열에서 취소됨" : "대기열 · 대기 중"}</span>`
        : "";
      return `<div class="turn ${role}${item.pending ? " pending" : ""}${item.queued ? " queued" : ""}" data-timeline-message-id="${esc(item.id || "")}">${queuedBadge}<div class="turnBody">${renderMarkdownBlocks(stripped)}</div>${renderTurnAttachments(attachments)}${renderTimelineImages(item)}${pendingState}</div>`;
    }
    function timelineDetailAttrs(id) {
      const value = String(id || "detail");
      return `data-timeline-detail="${esc(value)}"${openDetailIds.has(`${detailScope}:${value}`) ? " open" : ""}`;
    }
    // ACTIVITY_IDENTITY_START
    // 활동 항목의 **정체성**(누구인가)과 **지문**(내용이 바뀌었나)을 분리한다. 정체성이 같고 지문도
    // 같으면 그 DOM 을 손대지 않는다 — 읽는 중에 노드가 갈리면 스크롤이 튀기 때문.
    function activityItemKey(item, index) { return String(item.id || item.label || `activity-${index}`); }
    function activityItemFingerprint(item) {
      return JSON.stringify([item.activityType, item.status, item.label, item.name, item.detail, item.result,
                             (item.images || []).map(img => img.ref)]);
    }
    function activityGroupSummary(items) {
      // 스킬은 **이름까지** 보여준다 — 접힌 상태에서 "Skill 2"만 보면 뭘 읽었는지 알 수가 없다(형 요청).
      const skills = items.filter(item => (item.activityType || "") === "skill")
                          .map(item => String(item.label || item.name || "").trim()).filter(Boolean);
      const counts = {};
      items.forEach(item => { const key = item.activityType || "tool"; counts[key] = (counts[key] || 0) + 1; });
      const rank = key => { const i = ACTIVITY_SUMMARY_ORDER.indexOf(key); return i < 0 ? ACTIVITY_SUMMARY_ORDER.length : i; };
      const categories = Object.keys(counts)
        .sort((a, b) => rank(a) - rank(b) || a.localeCompare(b))
        .map(key => `${activityTypeLabels[key] || key} ${counts[key]}`);
      const skillNames = skills.length && skills.length <= 3 ? [`Skill: ${[...new Set(skills)].join(", ")}`] : [];
      return [`작업 ${items.length}`, ...categories, ...skillNames].join(" · ");
    }
    // ACTIVITY_IDENTITY_END

    // PROGRESS_LINE_START
    // 지금 뭘 하고 있는지 **한 줄, 사람말로**(스펙 §3). 도구 이름·명령어·경로는 한 글자도
    // 내보내지 않는다 — 그게 이 화면을 비개발자용으로 만드는 선이다.
    //
    // 왜 필요한가: 예전엔 무슨 일이 돌든 "생각 중" 하나뿐이라 뭘 하는지도, 멈춘 건지도
    // 알 수 없었다. 반대로 활동 항목을 그대로 보여주면 Edit(marina_mobile.py) 가 튀어나온다.
    const PROGRESS_WORDS = {
      command: "실행하는 중",
      agent: "다른 일꾼에게 맡기는 중",
      skill: "방법을 찾아보는 중",
      progress: "정리하는 중",
      tool: "이것저것 해보는 중",
    };

    function progressLine(items) {
      const running = (items || []).filter(item => item && item.status === "running");
      if (!running.length) return "";
      // 파일 고치기가 섞여 있으면 그걸 말한다 — 형이 제일 궁금해하는 게 "뭘 건드리고 있나" 다.
      const 파일 = running.filter(item => ["file", "diff"].includes(item.activityType || ""));
      if (파일.length) {
        // 같은 파일을 여러 번 건드려도 하나로 센다 — 숫자가 부풀면 못 믿는다.
        const 수 = new Set(파일.map((item, index) => String(item.path || `#${index}`))).size;
        return `파일 ${수}개 고치는 중`;
      }
      // 나머지는 **가장 뚜렷한 것 하나**만. 한 줄이 계약이라 붙여 쓰지 않는다.
      for (const key of ["command", "agent", "skill", "progress", "tool"]) {
        if (running.some(item => (item.activityType || "tool") === key)) return PROGRESS_WORDS[key];
      }
      return PROGRESS_WORDS.tool;
    }
    // PROGRESS_LINE_END
    function renderActivityItem(item, index) {
      const type = item.activityType || "tool";
      const status = ["running", "failed"].includes(item.status) ? item.status : "completed";
      const detail = String(item.detail || "");
      const result = String(item.result || "");
      // 이미지는 여기 담지 않는다 — 활동 항목도 그룹도 <details> 라 두 겹 안에 묻혀 안 보였다
      // (형: "이미지 같은거 있으면 접어놓지말고 보여주고"). renderActivityGroup 이 접힘 **밖으로**
      // 끌어올려 스트립으로 그린다. 여기 또 그리면 펼쳤을 때 같은 그림이 두 번 나온다.
      const body = [
        detail ? `<span class="activityBodyLabel">입력</span><pre class="activityCode">${renderActivityCode(detail, type)}</pre>` : "",
        result ? `<span class="activityBodyLabel">결과</span><pre class="activityCode">${renderActivityCode(result, type)}</pre>` : "",
      ].join("");
      // 파일/디프 활동은 그 파일을 대화에서 바로 열 수 있어야 한다. 경로는 백엔드가 item.path 로
      // 실어 준다(label 은 표시용이라 계약이 아니다). 호스트가 data-file-path 를 보고 뷰어를 연다.
      const fileAttrs = item.path
        ? ` data-file-path="${esc(item.path)}" data-file-name="${esc(String(item.path).split("/").pop())}"` : "";
      return `<details class="activityItem ${status}" data-activity-detail data-activity-key="${esc(activityItemKey(item, index))}" data-activity-fp="${esc(activityItemFingerprint(item))}" ${timelineDetailAttrs(`item:${item.id || item.label || "activity"}`)}><summary><span class="activityDot"></span><span class="activityLabel">${esc(item.label || item.name || activityTypeLabels[type] || "작업")}</span>${item.path ? `<button class="activityOpen" type="button"${fileAttrs}>열기</button>` : ""}<span class="activityType">${esc(activityTypeLabels[type] || "도구")}</span></summary>${body ? `<div class="activityBody">${body}</div>` : ""}</details>`;
    }
    function renderActivityGroup(items, stableId="") {
      if (!items.length) return "";
      const rows = items.map((item, index) => renderActivityItem(item, index)).join("");
      const groupId = stableId ? `group:${stableId}` : `group:${items[0].id || "first"}`;
      // 그림은 접지 않는다. 스크린샷·이미지 Read 결과가 <details> 두 겹(그룹→항목) 안에 있으면
      // 대화를 그냥 읽어서는 절대 안 보인다 — 도구 작업 요약은 접되 결과 그림은 항상 내놓는다.
      const shots = renderTimelineImages(
        {images: items.flatMap(item => (item && item.images) || [])}, "activityImages hoisted");
      const fold = `<details class="activityGroup" ${timelineDetailAttrs(groupId)}><summary>${esc(activityGroupSummary(items))}</summary><div class="activityList" data-activity-list>${rows}</div></details>`;
      return shots ? `${fold}${shots}` : fold;
    }
    // 활동 목록 제자리 갱신 — 새 작업은 **덧붙이고**, 안 바뀐 항목은 건드리지 않는다.
    // (exchange 통째 교체를 피하는 이유: 자율 진행 중인 턴은 exchange 가 하나라, 도구 하나 늘 때마다
    //  읽고 있던 펼친 상세가 파괴되고 스크롤이 튄다.)
    function reconcileActivityList(listEl, items) {
      const existing = new Map();
      [...listEl.children].forEach(node => {
        const key = node.dataset && node.dataset.activityKey;
        if (key) existing.set(key, node);
      });
      const kept = new Set();
      let cursor = null;
      items.forEach((item, index) => {
        const key = activityItemKey(item, index);
        const fingerprint = activityItemFingerprint(item);
        let node = existing.get(key);
        if (!node || node.dataset.activityFp !== fingerprint) {
          const holder = document.createElement("div");
          holder.innerHTML = renderActivityItem(item, index);
          const fresh = holder.firstElementChild;
          if (node && node.parentNode === listEl) listEl.replaceChild(fresh, node);
          node = fresh;
        }
        kept.add(node);
        const expected = cursor ? cursor.nextSibling : listEl.firstChild;
        if (node !== expected) listEl.insertBefore(node, expected);
        cursor = node;
      });
      [...listEl.children].forEach(node => { if (!kept.has(node)) listEl.removeChild(node); });
    }
    // VIEWABLES_START
    // 뷰어가 좌우로 넘길 목록. **A안** — 채팅에서 연 것은 그 대화에 나온 것만 대화 순서대로 흐른다
    // (형 결정: "해당 채팅에서는 해당 채팅 내용만"). 모아보기에서 연 것은 갤러리가 자기 배열을 준다.
    //
    // 같은 파일을 여러 번 고치면 타임라인에 여러 번 나온다 → 경로로 접되 **마지막 등장 자리**를
    // 남긴다. 최신 내용을 보는 게 맞고, 위치도 "가장 최근에 만진 곳"이 직관적이다.
    function collectViewables(items) {
      const out = [];
      const fileAt = new Map();          // path → out 안 위치
      for (const item of (items || [])) {
        if (!item) continue;
        for (const img of (item.images || [])) {
          if (img && img.ref) out.push({type: "image", ref: img.ref, name: img.name || "대화 이미지"});
        }
        if (item.kind === "activity" && item.path) {
          const path = String(item.path);
          const entry = {type: "file", path, name: path.split("/").pop() || path};
          const prev = fileAt.get(path);
          if (prev !== undefined) out[prev] = null;   // 앞선 등장은 비우고
          fileAt.set(path, out.length);               // 마지막 자리에 남긴다
          out.push(entry);
        }
      }
      return out.filter(Boolean);
    }
    // VIEWABLES_END

    function renderTimelineSequence(items) {
      const html = [];
      let activities = [];
      const flush = () => { if (activities.length) html.push(renderActivityGroup(activities)); activities = []; };
      (items || []).forEach(item => {
        if (item.kind === "activity") activities.push(item);
        else { flush(); html.push(renderTimelineMessage(item)); }
      });
      flush();
      return html.join("");
    }
    // QUESTION_CARD_START
    function questionsFromActivity(item) {
      if (!item) return null;
      // 서버가 질문을 1급 항목으로 내려주면(kind:"question") 파싱할 게 없다 — 그대로 쓴다.
      if (Array.isArray(item.questions) && item.questions.length) return item.questions;
      if (item.name !== "AskUserQuestion") return null;
      try {
        const parsed = JSON.parse(item.detail || "{}");
        const questions = parsed.questions || (parsed.input && parsed.input.questions);
        return Array.isArray(questions) && questions.length ? questions : null;
      } catch (e) { return null; }
    }
    function pendingQuestionActivity(sections) {
      const pool = [...(sections.questions || []), ...(sections.activities || [])];
      return pool.find(item =>
        item.name === "AskUserQuestion" && item.status !== "completed" && questionsFromActivity(item));
    }
    // 구조화된 카드(헤더/질문문/옵션 버튼)를 만들 재료가 하나도 없을 때, 원문에서 뽑아낼 수 있는
    // 텍스트(질문/옵션 라벨 등)를 최대한 찾아 평문으로라도 보여주기 위한 헬퍼.
    function questionFallbackText(raw) {
      if (raw == null) return "";
      if (typeof raw === "string") return raw.trim();
      if (typeof raw === "object") {
        for (const key of ["question", "text", "prompt", "header", "label", "title"]) {
          const val = raw[key];
          if (typeof val === "string" && val.trim()) return val.trim();
        }
        if (Array.isArray(raw.options) && raw.options.length) {
          const labels = raw.options.map(opt => String((opt && (opt.label || opt.value)) || "").trim()).filter(Boolean);
          if (labels.length) return `선택지: ${labels.join(", ")}`;
        }
        try {
          const text = JSON.stringify(raw);
          return text && text !== "{}" ? text : "";
        } catch (e) { return ""; }
      }
      return String(raw);
    }
    // 질문을 **전부** 그린다. 예전엔 첫 질문만 그리고 "외 N개 — 첫 질문에 응답합니다" 라고 적었는데,
    // 실제로는 나머지 질문에서 폼이 계속 대기해 아무 일도 안 일어났다(형: "선택하는데 안 가는데").
    // state = {choices, sending, failed} — 여러 질문일 땐 다 고른 뒤 한 번에 보낸다.
    function renderQuestionCard(item, interactive, state) {
      const questions = questionsFromActivity(item);
      if (!questions) return "";
      // choices[qi] 는 **배열**이다 — multiSelect 질문은 여러 개를 담아야 한다.
      // (예전엔 정수 하나라 다중선택이 구조적으로 불가능했다 — 형: "ask 여러개 선택하는거 선택이 안되는데")
      const choices = (state && state.choices) || [];
      const picks = qi => Array.isArray(choices[qi]) ? choices[qi] : (Number.isInteger(choices[qi]) ? [choices[qi]] : []);
      const sending = Boolean(state && state.sending);
      // 보내고 **나서도** 잠가둔다. 카드는 서버의 pendingQuestion 으로 그려지는데, 서버가 그 질문을
      // 내리는 건 다음 폴 뒤라 그 사이 카드가 멀쩡하게 되살아난다 — 형이 같은 질문에 두 번 답할
      // 뻔한 자리다. 잠금은 서버가 질문을 내리거나(토큰 소멸) 반영이 없다고 판정될 때 풀린다.
      const submitted = Boolean(state && state.submitted);
      const locked = sending || submitted;
      const multi = questions.length > 1;
      const blocks = questions.map((rawQ, qi) => {
        const q = (rawQ && typeof rawQ === "object") ? rawQ : {};
        const questionText = typeof q.question === "string" && q.question.trim() ? q.question : "";
        const options = Array.isArray(q.options) ? q.options.filter(opt => opt != null) : [];
        const header = q.header ? `<div class="questionHeader">${esc(String(q.header))}</div>` : "";
        const text = questionText ? `<div class="questionText">${renderRichText(String(questionText))}</div>` : "";
        if (!header && !text && !options.length) {
          // 구조(헤더/질문문/옵션)를 하나도 못 뽑아낸 경우 — 평문 폴백. 빈 카드는 절대 만들지 않는다.
          const fallback = questionFallbackText(rawQ) || "질문을 표시할 수 없습니다(형식 확인 필요)";
          return `<div class="questionBlock"><div class="questionText">${esc(fallback)}</div></div>`;
        }
        const stepBits = [];
        if (multi) stepBits.push(`질문 ${qi + 1} / ${questions.length}`);
        if (q.multiSelect) stepBits.push("여러 개 고를 수 있어요");
        const step = stepBits.length ? `<div class="questionStep">${esc(stepBits.join(" · "))}</div>` : "";
        const buttons = options.map((opt, index) => {
          const label = esc(String((opt && (opt.label || opt.value)) || `옵션 ${index + 1}`));
          const desc = opt && opt.description ? `<span class="questionOptDesc">${esc(String(opt.description))}</span>` : "";
          const chosen = picks(qi).includes(index) ? " chosen" : "";
          const attrs = interactive && !locked ? `data-answer-q="${qi}" data-answer-option="${index}"` : "disabled";
          return `<button class="questionOpt${chosen}" type="button" ${attrs}><span class="questionOptLabel">${label}</span>${desc}</button>`;
        }).join("");
        // 기타(직접 입력) — 질문이 하나일 때만. 여러 질문은 셀렉터를 순서대로 확정해야 해서 자유입력을 못 섞는다.
        // 열림 상태와 입력값은 **state 에** 둔다. 예전엔 버튼 아래에 숨은 행을 두고 클릭 때 JS 로
        // style.display 를 바꿨는데, 그러면 직렬화된 DOM 이 템플릿과 영구히 달라져 폴링마다 innerHTML
        // 이 재할당되고 입력창이 매번 파괴됐다(형: "깜빡거리면서 자꾸 초기화 → 직접 입력 자체가 불가능").
        // 그리고 아래에 줄을 더 만들지 않고 **그 줄 자체**를 입력칸으로 바꾼다.
        // 기타(직접 입력)는 **모든 질문**에 있다. AskUserQuestion 은 내가 준 선택지 뒤에 Other 행을
        // 항상 붙이므로(그래서 tool_input 의 options 에는 안 들어있다), 여기서 감추면 터미널·앱에선
        // 되는 선택지가 마리나에서만 사라진다 — 형: "모든 질문에 기타입력 있어야 하는거 아니니?".
        // 상태는 **질문별(qi)** 로 갖는다. 폼 전체에 하나면 질문이 여러 개일 때 어느 질문의 기타인지
        // 표현할 수가 없어서, 예전엔 그 김에 다중선택·복수질문을 통째로 막아뒀었다.
        // **여러 개 고르는 질문에서는 직접 입력을 못 준다.** 실증(2026-08-22): 자유 입력 줄에
        // 글자를 넣는 것까지는 되는데, 그 뒤 입력칸을 빠져나와 Submit 으로 가는 키가 없다.
        // 네 가지 순서를 실제 CLI 로 다 돌려봤다 — 제출이 안 되거나(→/Tab/Enter), 아예
        // "답 안 함"으로 닫힌다(↑). 될 것처럼 칸만 띄워두면 형은 썼는데 안 가는 걸 또 겪는다.
        const 다중 = Boolean(q && q.multiSelect);
        const otherOpen = Boolean(state && state.otherOpen && state.otherOpen[qi]);
        const otherText = (state && state.otherText && state.otherText[qi]) || "";
        const other = 다중 ? `<span class="questionOtherOff">직접 입력은 이 질문에선 안 돼요 — 골라서 답해주세요</span>`
          : !(interactive && !locked) ? ""
          : otherOpen
          ? `<div class="questionOtherRow" data-question-other-row><input class="questionOtherInput" type="text" data-answer-other-input data-answer-q="${qi}" placeholder="직접 입력..." value="${esc(otherText)}" enterkeyhint="send" autocomplete="off" /><button class="primary questionOtherSend" type="button" data-answer-other-send data-answer-q="${qi}">보내기</button></div>`
          : `<button class="questionOpt questionOther" type="button" data-answer-other data-answer-q="${qi}">&#9998; 기타 (직접 입력)</button>`;
        return `<div class="questionBlock">${step}${header}${text}<div class="questionOpts">${buttons}${other}</div></div>`;
      }).join("");
      const answered = questions.reduce((n, _, qi) => n + (picks(qi).length ? 1 : 0), 0);
      const anyMultiSelect = questions.some(q => q && q.multiSelect);
      const needsSubmit = multi || anyMultiSelect;   // 다중선택은 탭 즉시 전송하면 안 된다(더 고를 수 있으니)
      // 카운터는 **형이 방금 한 행동**을 비춰야 한다. 질문이 하나인 다중선택에서 '답한 질문 수'를 세면
      // 몇 개를 고르든 늘 1/1 이고 안 고르면 0/1 이라 아무 정보가 없다(형: "0/1 나오는것도 문제고").
      // 질문이 여러 개일 때만 질문 진행도가 뜻이 있고, 하나일 땐 고른 개수가 뜻이 있다.
      const submitLabel = sending ? "보내는 중..." : submitted ? "보냈어요"
        : multi ? `보내기 (${answered}/${questions.length})`
        : `보내기 (${picks(0).length}개 선택)`;
      const submit = interactive && needsSubmit
        ? `<div class="questionSubmitRow"><button class="primary questionSubmit" type="button" data-answer-submit${answered === questions.length && !locked ? "" : " disabled"}>${submitLabel}</button></div>`
        : "";
      const busy = sending && !needsSubmit ? `<div class="questionMore">보내는 중...</div>`
        : submitted && !needsSubmit ? `<div class="questionMore">보냈어요 · 반영을 기다리는 중</div>` : "";
      const failed = state && state.failed
        ? `<div class="questionFailed">응답이 안 먹었어요 — 다시 눌러보세요. 계속 이러면 터미널에서 직접 답해야 해요.</div>`
        : "";
      const note = interactive
        ? ((state && state.viaResume)
            ? `<div class="questionBlocked">이 세션 터미널을 marina 가 쥐고 있지 않아, 고르면 세션을 이어받아 답을 전달해요${"\u0020"}(작업 중이면 끝난 뒤에)</div>`
            : "")
        : `<div class="questionBlocked">${esc((state && state.reason) || "여기서는 답할 수 없어요")}</div>`;
      return `<div class="questionCard${submitted ? " submitted" : ""}">${blocks}${submit}${busy}${failed}${note}</div>`;
    }
    // THINKING_BUBBLE_START
    // 답이 나올 자리에서 도는 표시. 헤더의 "작업 중…" 은 대화와 떨어져 있어 와닿지 않는다
    // (형: "채팅창 너 대답 부분에 작업중 돌리는 것 처럼 생각 중 같은거 넣자").
    function renderThinking(label) {
      const text = String(label || "생각 중");
      return `<div class="thinkingBubble" role="status" aria-live="polite">`
        + `<span class="thinkingDots"><i></i><i></i><i></i></span>`
        + `<span class="thinkingLabel">${esc(text)}</span></div>`;
    }
    // THINKING_BUBBLE_END
    // ANSWERED_QUESTION_START
    // 이미 답한 질문 — 대화에 남는 기록이다. 선택지를 다시 다 늘어놓지 않고 **물은 것과 고른 것**만
    // 보여준다(그게 형이 못 보고 있던 두 가지다). 아직 답 전이면 기다리는 중이라고 말한다.
    function renderAnsweredQuestion(item) {
      const questions = questionsFromActivity(item);
      if (!questions) return "";
      const answers = Array.isArray(item.answers) ? item.answers : [];
      const blocks = questions.map((rawQ, qi) => {
        const q = (rawQ && typeof rawQ === "object") ? rawQ : {};
        const header = q.header ? `<div class="questionHeader">${esc(String(q.header))}</div>` : "";
        const questionText = typeof q.question === "string" && q.question.trim() ? q.question : "";
        const text = questionText ? `<div class="questionText">${renderRichText(String(questionText))}</div>` : "";
        if (!header && !text) {
          const fallback = questionFallbackText(rawQ) || "질문을 표시할 수 없습니다(형식 확인 필요)";
          return `<div class="questionBlock"><div class="questionText">${esc(fallback)}</div></div>`;
        }
        const answer = answers[qi] || {};
        const picked = (Array.isArray(answer.picked) && answer.picked.length)
          ? answer.picked
          : (answer.text ? [answer.text] : []);
        const rows = picked.map(label =>
          `<div class="questionOpt chosen answered"><span class="questionOptLabel">${esc(String(label))}</span></div>`).join("");
        const waiting = item.status !== "completed" && item.status !== "failed";
        const none = rows ? "" : `<div class="questionMore">${waiting ? "답을 기다리는 중" : "고른 답을 찾지 못했어요"}</div>`;
        return `<div class="questionBlock">${header}${text}<div class="questionOpts">${rows}${none}</div></div>`;
      }).join("");
      return `<div class="questionCard answered">${blocks}</div>`;
    }
    // ANSWERED_QUESTION_END
    // QUESTION_CARD_END
    function renderConversationSequence(exchange, session, isLatest=false) {
      const sections = exchangeSections(exchange);
      const question = pendingQuestionActivity(sections);
      // 대화 안 카드는 폴백이다 — 훅이 잡은 라이브 카드가 입력창 위에 뜨면 그쪽이 주인이고 여긴 읽기 전용.
      // 라이브 카드가 없을 땐(상태파일 만료 등) **여기서 답할 수 있어야 한다** — 안 그러면 형이 보는
      // 유일한 카드가 죽은 카드가 된다. 상태는 라이브 카드와 공유해 규칙이 갈라지지 않게 한다.
      const fallbackQuestions = questionsFromActivity(question) || [];
      const canAnswer = Boolean(isLatest && session && session.kind === "agent"
        && sessionSource(session) === "claude"
        && fallbackQuestions.length && !session.pendingQuestion);
      const fallbackState = canAnswer
        ? host.ensureAnswerState(fallbackQuestions, `activity:${(question && question.id) || "q"}`)
        : null;
      const runs = exchangeRuns(exchange);
      const flow = runs.map((run, index) => run.type === "message"
        ? renderTimelineMessage(run.item)
        : renderActivityGroup(run.items, `exchange:${exchange.id}:${index}`)).join("");
      const body = [
        sections.user ? renderTimelineMessage(sections.user) : "",
        flow,
        question ? renderQuestionCard(question, canAnswer, fallbackState) : "",
        renderTurnMeta(exchange, session, isLatest, !sections.assistant),
        renderLiveAction(exchange, sections, session, isLatest),
      ].join("");
      return `<section class="conversationSequence" data-exchange-id="${esc(exchange.id)}">${body}</section>`;
    }
    function pendingKeyPart(it) {
      // pending(대기열/전송중) 항목은 delivery 라벨·시간기반 실패표기가 갱신돼야 하므로 렌더키에 상태+시간버킷을 싣는다.
      if (!it || !it.pending) return 0;
      return [it.delivery || "", Math.floor((Date.now() - (it.createdAt || 0)) / 4000)];
    }
    // TIMELINE_KEY_START
    // 렌더 키에 실을 항목 필드를 **한 곳에서** 정의한다. 두 군데(전체 키/exchange 키)에 따로 적어두면
    // 어긋나고, 여기서 빠진 필드는 값이 바뀌어도 DOM 이 안 갈려 화면에 문신처럼 남는다.
    // 실제로 queued/queuedCancelled/steered 가 빠져 있어서 큐 배지가 새로고침 전까지 "대기 중"으로
    // 굳어 있었고, exchange 키에는 images 도 빠져 있었다.
    function timelineItemKeyParts(it) {
      return [it.id || "", it.kind, it.role, it.text, it.activityType, it.label, it.status,
              it.detail, it.result, it.model, it.effort,
              (it.images || []).map(img => img.ref),
              it.queued ? 1 : 0, it.queuedCancelled ? 1 : 0, it.steered ? 1 : 0,
              pendingKeyPart(it)];
    }
    // TIMELINE_KEY_END
    function exchangeRenderKey(exchange, session, isLatest) {
      // 이 exchange 하나의 렌더에 영향을 주는 것만: 항목들 + (최신일 때만) 세션 라이브 상태.
      return JSON.stringify([
        isLatest,
        isLatest ? [session.status, session.controllable] : 0,
        (exchange.items || []).map(timelineItemKeyParts),
      ]);
    }

  window.MarinaChat = {
    configure, setDetailScope, noteDetailToggle, IMAGE_EXT_RE, collectViewables,
    esc, renderInlineMarkdown, renderRichText, mdTableCells, mdIsTableRow, mdIsTableDivider,
    mdListMarker, renderMarkdownBlocks, mdRenderList, renderActivityCode, sessionSource,
    pendingDeliveryLabel, renderThinking, runtimeLabel, mergeHistoryTurns, timelineFromTurns,
    mergeTimelineItems, exchangeSections, exchangeRuns, exchangeRuntime, renderTurnMeta,
    renderLiveAction, extractAttachments, renderTurnAttachments, renderTimelineImages,
    renderTimelineMessage, timelineDetailAttrs, activityItemKey, activityItemFingerprint,
    activityGroupSummary, progressLine, renderActivityItem, renderActivityGroup, reconcileActivityList,
    renderTimelineSequence, questionsFromActivity, pendingQuestionActivity,
    questionFallbackText, renderQuestionCard, renderAnsweredQuestion, renderConversationSequence, pendingKeyPart,
    timelineItemKeyParts, exchangeRenderKey,
  };
})();
