#!/usr/bin/env bash
# mobile control: token-protected phone page + remote-safe state/send endpoints.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
# 트랜스크립트 마스킹은 이제 **기본 꺼짐**이다(원본 JSONL 이 평문이라 그릴 때만 가리는 건 어드민 혼자인
# 지금 얻는 게 없고 이메일 오탐만 남았다 — 형 지적). 이 테스트는 **켰을 때 동작하는지**를 잠근다.
# member 역할이 붙어 남의 대화를 보여줄 때 이 스위치를 켜므로, 기능 자체는 계속 검증해야 한다.
export MARINA_REDACT_TRANSCRIPT=1
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
unset MARINA_CONTROL_HOST MARINA_CONTROL_PORT
P="$TMP/proj"; mkdir -p "$P"; (cd "$P" && git init -q && git commit -q --allow-empty -m init)
cat > "$MARINA_HOME/projects.json" <<JSON
{"schemaVersion":1,"projects":[{"id":"proj","root":"$P","kind":"compose","composeFile":"docker-compose.yml","subrepos":[],"worktreeGlobs":[]}]}
JSON

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1])
s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-mobile-control (localhost bind unavailable)"; exit 0; }; exit "$code"; }
SRV=""; AUTH_SRV=""
cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; [[ -n "$AUTH_SRV" ]] && kill "$AUTH_SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

MARINA_MOBILE_TOKEN=secret MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"
ready=0
mobile_html=""
for _ in $(seq 1 100); do
  mobile_html="$(curl -sf "$b/mobile?token=secret" || true)"
  if grep -q 'mobileApp' <<<"$mobile_html"; then ready=1; break; fi
  sleep 0.1
done
[[ "$ready" == "1" ]] || { echo "FAIL: mobile test server did not become ready"; exit 1; }

# 타임라인 렌더러는 /web/chat-render.js 에 있다(웹 대시보드와 공유). 페이지가 참조하는 것만으로는
# 부족하고 **같은 서버에서 실제로 받아져야** 한다 — 모바일은 펀넬 호스트/토큰 경로로 들어오기 때문.
grep -q '/web/chat-render.js' <<<"$mobile_html" || { echo "FAIL: /mobile should load the shared chat renderer"; exit 1; }
chat_render="$(curl -sf "$b/web/chat-render.js" || true)"
grep -q 'window.MarinaChat' <<<"$chat_render" || { echo "FAIL: /web/chat-render.js should be served to mobile clients"; exit 1; }
# 아래 검사들은 '무엇이 서빙되는가'가 계약이다 — 두 파일 다 서빙되므로 합쳐서 본다.
mobile_html="$mobile_html
$chat_render"

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: devbox.example.test' "$b/mobile")"
[[ "$code" == "200" ]] || { echo "FAIL: /mobile without token should show login page, got $code"; exit 1; }
login_html="$(curl -sf -H 'Host: devbox.example.test' "$b/mobile")"
grep -q 'mobileLogin' <<<"$login_html" || { echo "FAIL: /mobile without token missing login form"; exit 1; }
! grep -q 'secret' <<<"$login_html" || { echo "FAIL: /mobile page leaked configured token"; exit 1; }

grep -q 'mobileApp' <<<"$mobile_html" || { echo "FAIL: /mobile token page missing app marker"; exit 1; }
grep -q 'mobileLogin' <<<"$mobile_html" || { echo "FAIL: /mobile token page missing login shell"; exit 1; }
! grep -q 'secret' <<<"$mobile_html" || { echo "FAIL: /mobile token page leaked configured token"; exit 1; }
grep -q 'logoutBtn' <<<"$mobile_html" || { echo "FAIL: /mobile page missing logout button"; exit 1; }
grep -q 'localStorage.removeItem("marinaMobileToken")' <<<"$mobile_html" || { echo "FAIL: /mobile page missing logout storage clear"; exit 1; }
grep -q 'autoPollMs' <<<"$mobile_html" || { echo "FAIL: /mobile page missing auto polling"; exit 1; }
! grep -q 'notifyBtn' <<<"$mobile_html" || { echo "FAIL: /mobile page should not promise unsupported background notifications"; exit 1; }
# 전체보기 때문에 템플릿 리터럴이 됐다(`?all=1`) — 여전히 모바일 전용 경로를 쓴다는 게 요점.
grep -q '/mobile/api/state' <<<"$mobile_html" || { echo "FAIL: /mobile page should fetch mobile-scoped state API"; exit 1; }
grep -q 'showAll ? "?all=1" : ""' <<<"$mobile_html" || { echo "FAIL: 전체보기가 서버에 전달되지 않는다"; exit 1; }
grep -q '"/mobile/api/send"' <<<"$mobile_html" || { echo "FAIL: /mobile page should post mobile-scoped send API"; exit 1; }
grep -q 'marinaMobileRoot' <<<"$mobile_html" || { echo "FAIL: /mobile page should remember selected root"; exit 1; }
grep -q 'marinaMobileTarget' <<<"$mobile_html" || { echo "FAIL: /mobile page should remember selected target"; exit 1; }
grep -q 'marinaMobileDraft' <<<"$mobile_html" || { echo "FAIL: /mobile page should remember draft prompt"; exit 1; }
grep -q 'sessionList' <<<"$mobile_html" || { echo "FAIL: /mobile page should render session cards"; exit 1; }
grep -q 'isEditing' <<<"$mobile_html" || { echo "FAIL: /mobile page should avoid refresh while user is editing"; exit 1; }
grep -q 'turns' <<<"$mobile_html" || { echo "FAIL: /mobile page should render agent transcript turns"; exit 1; }
grep -q 'chatView' <<<"$mobile_html" || { echo "FAIL: /mobile page should have chat view"; exit 1; }
grep -q 'backBtn' <<<"$mobile_html" || { echo "FAIL: /mobile page should have back button"; exit 1; }
grep -q 'chatComposer' <<<"$mobile_html" || { echo "FAIL: /mobile page should have a chat composer"; exit 1; }
! grep -q '\.chatComposer { position: fixed' <<<"$mobile_html" || { echo "FAIL: /mobile composer should participate in the viewport grid"; exit 1; }
grep -q 'visualViewport' <<<"$mobile_html" || { echo "FAIL: /mobile should track the virtual keyboard viewport"; exit 1; }
grep -q -- '--app-height' <<<"$mobile_html" || { echo "FAIL: /mobile should size its shell from the visual viewport"; exit 1; }
grep -q 'hiddenSelect' <<<"$mobile_html" || { echo "FAIL: /mobile page should hide technical selects"; exit 1; }
grep -q 'pendingTurns' <<<"$mobile_html" || { echo "FAIL: /mobile page should show sent messages immediately"; exit 1; }
grep -q 'pendingDeliveryLabel' <<<"$mobile_html" || { echo "FAIL: /mobile pending messages should identify steer/queue state"; exit 1; }

grep -q '전달 확인 안 됨' <<<"$mobile_html" || { echo "FAIL: /mobile pending messages should surface unconfirmed delivery"; exit 1; }
grep -q 'externalActive' <<<"$mobile_html" || { echo "FAIL: /mobile should distinguish external agent activity from controllability"; exit 1; }
grep -q 'd.delivery' <<<"$mobile_html" || { echo "FAIL: /mobile should render the server-confirmed delivery mode"; exit 1; }
grep -q 'selectAgentAfterSend' <<<"$mobile_html" || { echo "FAIL: /mobile page should keep agent sends in the agent chat"; exit 1; }
! grep -q 'menuPanel' <<<"$mobile_html" || { echo "FAIL: /mobile primary navigation should not hide behind a utility menu"; exit 1; }
grep -q 'projectTabs' <<<"$mobile_html" || { echo "FAIL: /mobile page should organize sessions by project"; exit 1; }
grep -q 'sourceTabs' <<<"$mobile_html" || { echo "FAIL: /mobile page should filter Codex, Claude, and terminal sessions"; exit 1; }
grep -q 'marinaMobileProject' <<<"$mobile_html" || { echo "FAIL: /mobile page should remember selected project"; exit 1; }
grep -q 'marinaMobileSource' <<<"$mobile_html" || { echo "FAIL: /mobile page should remember selected source"; exit 1; }
grep -q 'session-group' <<<"$mobile_html" || { echo "FAIL: /mobile page should group all sessions by source"; exit 1; }
grep -q 'source-badge' <<<"$mobile_html" || { echo "FAIL: /mobile session cards should identify their source"; exit 1; }
# 폴링이 카드 노드를 보존해야 한다. 예전엔 순서에 둔감한 구조키로 "아예 재정렬하지 않아서" 보존했는데,
# 그 대가로 최신순이 화면에 반영되지 않았다(형 지적). 이제 keyed reconciler 가 **순서를 반영하면서**
# 노드를 재사용한다 — 보존의 근거가 더 강해졌다. 자세한 계약은 test-session-panel.
grep -q 'function reconcileKeyed' <<<"$mobile_html" || { echo "FAIL: /mobile polling should preserve session card nodes (keyed reconciler)"; exit 1; }
! grep -q 'sessionStructureKey' <<<"$mobile_html" || { echo "FAIL: 순서에 둔감한 구조키가 되살아나면 정렬이 다시 얼어붙는다"; exit 1; }
grep -q 'sessionList.onclick' <<<"$mobile_html" || { echo "FAIL: /mobile session clicks should use stable delegated handling"; exit 1; }
! grep -q '<label>최근 작업' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not show a separate recent-work panel"; exit 1; }
! grep -q 'turn-role' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not label user/assistant roles"; exit 1; }
grep -q 'renderRichText' <<<"$mobile_html" || { echo "FAIL: /mobile chat should render safe clickable links"; exit 1; }
grep -q 'noopener noreferrer' <<<"$mobile_html" || { echo "FAIL: /mobile chat links should isolate new tabs"; exit 1; }
grep -q 'draftKey' <<<"$mobile_html" || { echo "FAIL: /mobile chat should keep drafts per session"; exit 1; }
grep -q 'queuePendingTurn' <<<"$mobile_html" || { echo "FAIL: /mobile chat should preserve repeated pending prompts independently"; exit 1; }
grep -q 'startsWith("marinaMobileDraft:")' <<<"$mobile_html" || { echo "FAIL: /mobile logout should clear per-session drafts"; exit 1; }
grep -q 'autoGrowComposer' <<<"$mobile_html" || { echo "FAIL: /mobile composer should grow with its contents"; exit 1; }
grep -q 'promptInput.onkeydown' <<<"$mobile_html" || { echo "FAIL: /mobile composer should support hardware keyboard send"; exit 1; }
grep -q 'retryBtn' <<<"$mobile_html" || { echo "FAIL: /mobile composer should expose failed-send retry"; exit 1; }
grep -q 'failedSend.sessionKey !== selectedSessionKey' <<<"$mobile_html" || { echo "FAIL: /mobile retry should stay bound to the failed session"; exit 1; }
# 전송 전에 세션 컨텍스트를 캡처한다(원래 의도). root 는 전역 selectedRoot() 가 아니라 **그 세션의**
# root 여야 한다 — 전역 값은 워크트리 피커/프로젝트 탭이 움직이면 어긋나 서버가 403 을 낸다.
# 자세한 계약은 test-mobile-session-root.
grep -q 'const requestContext = {root: sessionRoot(), sessionKey: selectedSessionKey' <<<"$mobile_html" || { echo "FAIL: /mobile send should capture its session before the request"; exit 1; }
grep -q 'failedSend = requestContext' <<<"$mobile_html" || { echo "FAIL: /mobile failed send should retry in its original session"; exit 1; }
grep -q 'async function responseError' <<<"$mobile_html" || { echo "FAIL: /mobile should show the server send failure reason"; exit 1; }
! grep -q 'class="usageRail"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not permanently expose agent context usage"; exit 1; }
# 데몬이 새 버전으로 뜨면 낡은 페이지는 **스스로** 새로고침한다(안전할 때만).
# 배너만 띄우면 형이 못 보고 옛 JS 로 계속 써서 "고쳤다는데 그대로"가 반복된다.
grep -q 'if (!busyTyping && !sending && !answering) { location.reload(); return; }' <<<"$mobile_html" || { echo "FAIL: 새 버전 자동 새로고침 없음"; exit 1; }
grep -q 'updateBanner.style.display = "block";   // 지금은 위험' <<<"$mobile_html" || { echo "FAIL: 위험할 땐 배너로 물러서야 함"; exit 1; }
grep -q 'id="usageBtn"' <<<"$mobile_html" || { echo "FAIL: /mobile compact header should expose a usage button"; exit 1; }
grep -q 'id="usagePanel"' <<<"$mobile_html" || { echo "FAIL: /mobile usage button should open a usage panel"; exit 1; }
grep -q 'id="chatNavTitle"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should use a compact navigation title"; exit 1; }
grep -q 'data-view="chat"' <<<"$mobile_html" || { echo "FAIL: /mobile shell should switch to compact chat mode"; exit 1; }
# 프로젝트/종류 탭은 채팅 헤더에선 빠지지만 **좌측 패널(#listView) 안**에 살아 있어야 한다.
# 예전엔 헤더에 두고 채팅 뷰에서 CSS 로 숨겼는데, 그러면 드로어를 열어도 현재 프로젝트 세션만 보여
# 다른 프로젝트를 고를 방법이 없었다(형 지적). 자세한 계약은 test-mobile-drawer.
! grep -q '#mobileApp\[data-view="chat"\] #projectTabs' <<<"$mobile_html" || { echo "FAIL: 채팅 뷰에서 프로젝트 탭을 숨기면 드로어에서 프로젝트를 못 바꾼다"; exit 1; }
mobile_panel="$(sed -n '/<section id="listView"/,/<\/section>/p' <<<"$mobile_html")"
mobile_header="$(sed -n '/<header>/,/<\/header>/p' <<<"$mobile_html")"
[[ -n "$mobile_panel" && -n "$mobile_header" ]] || { echo "FAIL: /mobile listView/header 구간을 못 찾음"; exit 1; }
for needle in 'id="projectTabs"' 'id="sourceTabs"'; do
  grep -q "$needle" <<<"$mobile_panel" || { echo "FAIL: $needle 가 좌측 패널 안에 없다"; exit 1; }
done
! grep -qE 'projectTabs|sourceTabs' <<<"$mobile_header" || { echo "FAIL: 탭이 헤더에 남아 있다"; exit 1; }
# 서버 버튼도 좌측 패널 안으로 옮겼다 — 드로어가 목록 화면을 대체한 뒤로 채팅 뷰에서 숨기면
# 볼 방법이 아예 사라진다(형: "모바일에서 서버 상태 보는거 어디갔지?").
grep -q 'data-wt-more' <<<"$mobile_html" || { echo "FAIL: 워크트리 작업 진입점(⋯)이 없다"; exit 1; }
grep -q 'body: JSON.stringify({root: servicesRoot || sessionRoot(), service, action})' <<<"$mobile_html" || { echo "FAIL: 서비스 실행이 시트가 보는 워크트리를 안 쓴다"; exit 1; }
# (프로젝트/종류 탭의 새 계약은 위 좌측 패널 검사에서 함께 못박는다 — 채팅 뷰에서 숨기지 않는다.)
! grep -q '#mobileApp\[data-view="chat"\] #sourceTabs' <<<"$mobile_html" || { echo "FAIL: 채팅 뷰에서 종류 탭을 숨기면 드로어에서 종류를 못 바꾼다"; exit 1; }
grep -q 'loadAgentUsage' <<<"$mobile_html" || { echo "FAIL: /mobile should load usage lazily for the selected agent"; exit 1; }
grep -q '"/mobile/api/usage"' <<<"$mobile_html" || { echo "FAIL: /mobile should use the scoped usage endpoint"; exit 1; }
grep -q 'accountUsage' <<<"$mobile_html" || { echo "FAIL: /mobile should render provider account usage"; exit 1; }
grep -q 'fableWeekly' <<<"$mobile_html" || { echo "FAIL: /mobile should render Claude Fable weekly usage"; exit 1; }
grep -q 'class="usageAccountTrack"' <<<"$mobile_html" || { echo "FAIL: account quota windows should render progress bars"; exit 1; }
grep -q '제공되지 않음' <<<"$mobile_html" || { echo "FAIL: missing five-hour quota should be explicit"; exit 1; }
grep -q 'formatTokens' <<<"$mobile_html" || { echo "FAIL: /mobile should compact large token values"; exit 1; }
grep -q 'suggestions' <<<"$mobile_html" || { echo "FAIL: /mobile composer should render native suggestions"; exit 1; }
grep -q 'renderSuggestions' <<<"$mobile_html" || { echo "FAIL: /mobile composer should adapt suggestions to Claude/Codex"; exit 1; }
grep -q '"/mobile/api/catalog"' <<<"$mobile_html" || { echo "FAIL: /mobile composer should query file references lazily"; exit 1; }
grep -q 'fileSuggestionKey === key' <<<"$mobile_html" || { echo "FAIL: /mobile composer should not refetch the same file query in a loop"; exit 1; }
grep -q 'selectedSessionKey !== sessionKey' <<<"$mobile_html" || { echo "FAIL: /mobile file suggestions should ignore stale session responses"; exit 1; }
grep -q 'fileSuggestionKey === key.*selectedSessionKey === sessionKey' <<<"$mobile_html" || { echo "FAIL: /mobile stale file errors should not clear the active session results"; exit 1; }
grep -q 'newMessagesBtn' <<<"$mobile_html" || { echo "FAIL: /mobile chat should preserve reading position on refresh"; exit 1; }
! grep -q 'subagentMenuBtn' <<<"$mobile_html" || { echo "FAIL: /mobile should not expose subagents as a global menu action"; exit 1; }
grep -q 'subagentSessionBtn' <<<"$mobile_html" || { echo "FAIL: /mobile should expose subagents inside their session"; exit 1; }
grep -q 'subagentSheet' <<<"$mobile_html" || { echo "FAIL: /mobile chat should render a subagent bottom sheet"; exit 1; }
grep -q '/mobile/api/activity' <<<"$mobile_html" || { echo "FAIL: /mobile should load subagent activity on demand"; exit 1; }
grep -q 'renderSubagents' <<<"$mobile_html" || { echo "FAIL: /mobile chat should render subagent activity"; exit 1; }
grep -q 'openSubagentIds' <<<"$mobile_html" || { echo "FAIL: /mobile polling should preserve opened subagent details"; exit 1; }
! grep -q '<label>워크트리' <<<"$mobile_html" || { echo "FAIL: /mobile page should not expose worktree select"; exit 1; }
! grep -q '<label>대상' <<<"$mobile_html" || { echo "FAIL: /mobile page should not expose target select"; exit 1; }
# 서비스 상태는 여전히 노출된다 — 다만 전역 버튼이 아니라 **워크트리 그룹 헤더**에서.
# 서비스 상태는 워크트리 ⋯ 시트에서 연다(헤더는 읽는 것만 남긴다).
grep -q 'data-wt-act="services"' <<<"$mobile_html" || { echo "FAIL: /mobile shell should expose service state"; exit 1; }
grep -q 'servicesSheet' <<<"$mobile_html" || { echo "FAIL: /mobile should render service controls in a sheet"; exit 1; }
grep -q 'settingsBtn' <<<"$mobile_html" || { echo "FAIL: /mobile chat should expose model and effort settings"; exit 1; }
grep -q 'stopBtn' <<<"$mobile_html" || { echo "FAIL: /mobile chat should expose current-turn interruption"; exit 1; }
grep -q '"/mobile/api/interrupt"' <<<"$mobile_html" || { echo "FAIL: /mobile stop should call the scoped interrupt API"; exit 1; }
grep -q '외부에서 실행 중' <<<"$mobile_html" || { echo "FAIL: external working sessions should be labeled"; exit 1; }
grep -q 'history.pushState({view: "chat"}' <<<"$mobile_html" || { echo "FAIL: /mobile chat should own a browser history entry"; exit 1; }
grep -q '한 번 더 누르면 Marina를 나갑니다' <<<"$mobile_html" || { echo "FAIL: /mobile main back should show a two-step exit guard"; exit 1; }
grep -q 'turnsEl.scrollHeight' <<<"$mobile_html" || { echo "FAIL: /mobile chat should scroll its transcript rather than the page"; exit 1; }
! grep -q 'data-turn-toggle' <<<"$mobile_html" || { echo "FAIL: /mobile chat messages should remain fully visible"; exit 1; }
! grep -q 'collapsedTurnIds' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not collapse question or answer bubbles"; exit 1; }
grep -q 'function conversationExchanges' <<<"$mobile_html" || { echo "FAIL: /mobile chat should partition loaded pages into Q&A exchanges"; exit 1; }
grep -q 'class="conversationSequence"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should render each Q&A as a visible sequence"; exit 1; }
! grep -q 'class="conversationExchange"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not collapse complete Q&A exchanges"; exit 1; }
! grep -q 'class="previousConversation"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not lump all history into one container"; exit 1; }
! grep -q 'id="olderMessagesBtn"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not expose the legacy history button"; exit 1; }
grep -q 'class="activityGroup"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should collapse native work events"; exit 1; }
grep -q 'data-activity-detail' <<<"$mobile_html" || { echo "FAIL: /mobile work details should expand independently"; exit 1; }
grep -q 'mergeTimelineItems' <<<"$mobile_html" || { echo "FAIL: /mobile history should merge paged timeline events"; exit 1; }
grep -q 'noteDetailToggle(' <<<"$mobile_html" || { echo "FAIL: /mobile polling should preserve opened timeline details"; exit 1; }
grep -q 'setDetailScope(' <<<"$mobile_html" || { echo "FAIL: /mobile should scope opened details per session"; exit 1; }
grep -q 'data-timeline-detail' <<<"$mobile_html" || { echo "FAIL: /mobile timeline details need stable identities"; exit 1; }
# 작업 묶음은 여전히 접힌다. 다만 **한 덩어리가 아니라 시간 순서대로 여러 구간**이다 —
# 어시스턴트 설명이 사이에 들어가야 결과만 덩그러니 남지 않는다(형: "맥락이 해석이 덜 되는 느낌").
grep -q 'renderActivityGroup(run.items, `exchange:${exchange.id}:${index}`)' <<<"$mobile_html" || { echo "FAIL: 작업 묶음이 순서대로 접히지 않는다"; exit 1; }
grep -q 'function exchangeRuns(exchange)' <<<"$mobile_html" || { echo "FAIL: exchange 를 시간 순서로 쪼개지 않는다"; exit 1; }
# 정렬 변형(.turnMeta.right)이 붙어 `class="turnMeta${...}"` 로 렌더된다 — 접두만 본다.
grep -q 'class="turnMeta' <<<"$mobile_html" || { echo "FAIL: each agent exchange should expose its actual model and effort"; exit 1; }
grep -q 'class="liveAction"' <<<"$mobile_html" || { echo "FAIL: the latest exchange should expose its current action inline"; exit 1; }
grep -q 'data-live-action' <<<"$mobile_html" || { echo "FAIL: the inline current action should open its full work history"; exit 1; }
grep -q 'flex: 0 0 auto' <<<"$mobile_html" || { echo "FAIL: visible conversation sequences should grow the transcript scroll surface"; exit 1; }
grep -q 'let followLatest = true' <<<"$mobile_html" || { echo "FAIL: /mobile chat should track explicit bottom-follow intent"; exit 1; }
grep -q 'function captureScrollAnchor' <<<"$mobile_html" || { echo "FAIL: /mobile polling should capture the visible exchange"; exit 1; }
grep -q 'function restoreScrollAnchor' <<<"$mobile_html" || { echo "FAIL: /mobile polling should restore the visible exchange"; exit 1; }
grep -q 'data-timeline-message-id' <<<"$mobile_html" || { echo "FAIL: page-boundary regrouping needs a stable message anchor"; exit 1; }
grep -q 'anchor.messageId' <<<"$mobile_html" || { echo "FAIL: scroll restoration should survive a changed exchange id"; exit 1; }
grep -q 'const followLatestBefore = followLatest' <<<"$mobile_html" || { echo "FAIL: polling should preserve follow-latest intent before rendering"; exit 1; }
! grep -q 'function nearPageBottom' <<<"$mobile_html" || { echo "FAIL: polling still uses the loose near-bottom jump heuristic"; exit 1; }
! grep -q 'olderMessagesBtn' <<<"$mobile_html" || { echo "FAIL: legacy previous-message state remains in mobile script"; exit 1; }
grep -q 'historyStatus' <<<"$mobile_html" || { echo "FAIL: cursor loading should use transient inline status"; exit 1; }

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

script = render_mobile_html().rsplit("<script>", 1)[1].split("</script>", 1)[0]
latest_loader = script.split("async function loadSessionMessages", 1)[1].split("async function loadOlderMessages", 1)[0]
# 구분자였던 activityTypeLabels 는 공유 렌더러로 옮겨갔다 — 모바일에 남는 다음 선언으로 자른다.
older_loader = script.split("async function loadOlderMessages", 1)[1].split("function conversationExchanges", 1)[0]
assert 'turnsStructureKey = ""' not in latest_loader, "polling invalidates the render key and jumps to the bottom"
assert 'turnsStructureKey = ""' not in older_loader, "history prepend invalidates the render key and loses the scroll anchor"
print("ok mobile loaders preserve scroll intent")
PY

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# esc/renderRichText 는 공유 렌더러(chat-render.js)에 산다 — 노출 표면 그대로 굴린다.
import sys
from pathlib import Path

print("var window = globalThis;")   # chat-render.js 는 window.MarinaChat 에 붙는다 (node 셤)
print((Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8"))
print("const {renderRichText} = window.MarinaChat;")
print(r'''
const raw = renderRichText('<img src=x onerror=alert(1)>');
if (raw.includes('<img') || !raw.includes('&lt;img')) throw new Error(`raw HTML was not escaped: ${raw}`);
const js = renderRichText('[bad](javascript:alert(1))');
if (js.includes('<a')) throw new Error(`javascript URL became a link: ${js}`);
const safe = renderRichText('[docs](https://example.test/a?q=1&x=2)');
if (!safe.includes('href="https://example.test/a?q=1&amp;x=2"')) throw new Error(`safe URL was not escaped: ${safe}`);
if (!safe.includes('rel="noopener noreferrer"')) throw new Error(`link isolation missing: ${safe}`);
const quoted = renderRichText('https://example.test/"onclick="alert(1)');
if (quoted.includes('onclick="')) throw new Error(`quote escaped from href: ${quoted}`);
const markdown = renderRichText('**모델**은 `gpt-test`');
if (!markdown.includes('<strong>모델</strong>') || !markdown.includes('<code>gpt-test</code>')) throw new Error(`basic markdown missing: ${markdown}`);
console.log('ok mobile rich text safety');
''')
PY

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
# conversationExchanges 는 모바일에, exchangeSections 는 공유 렌더러에 있다 — 둘 다 싣는다.
import sys
from pathlib import Path

from marina_mobile import render_mobile_html

print("var window = globalThis;")   # chat-render.js 는 window.MarinaChat 에 붙는다 (node 셤)
print((Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8"))
print("const {exchangeSections} = window.MarinaChat;")
script = render_mobile_html().rsplit("<script>", 1)[1].split("</script>", 1)[0]
print(script[script.index("function conversationExchanges"):script.index("function transcriptImageUrl")])
print(r'''
const current = [
  {id:'u1',kind:'message',role:'user',text:'question one'},
  {id:'a1',kind:'activity',activityType:'command',label:'run'},
  {id:'m1',kind:'message',role:'assistant',text:'answer one'},
  {id:'u2',kind:'message',role:'user',text:'question two'},
  {id:'m2',kind:'message',role:'assistant',text:'answer two'},
];
let exchanges = conversationExchanges(current);
if (exchanges.length !== 2 || exchanges[0].id !== 'u1' || exchanges[1].id !== 'u2') throw new Error(`bad exchange split: ${JSON.stringify(exchanges)}`);
let first = exchangeSections(exchanges[0]);
if (first.user.text !== 'question one' || first.activities.length !== 1 || first.assistant.text !== 'answer one') throw new Error(`bad exchange sections: ${JSON.stringify(first)}`);
const older = [
  {id:'u0',kind:'message',role:'user',text:'older question'},
  {id:'m0',kind:'message',role:'assistant',text:'older answer'},
];
exchanges = conversationExchanges(older.concat(current));
if (exchanges.map(item => item.id).join(',') !== 'u0,u1,u2') throw new Error(`prepend did not regroup pages: ${JSON.stringify(exchanges)}`);
console.log('ok paged Q&A exchange grouping');
''')
PY

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: devbox.example.test' "$b/api/mobile-state")"
[[ "$code" == "403" ]] || { echo "FAIL: mobile-state without token should be 403, got $code"; exit 1; }

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: devbox.example.test' "$b/mobile/api/state")"
[[ "$code" == "403" ]] || { echo "FAIL: mobile-scoped state without token should be 403, got $code"; exit 1; }

state_json="$(curl -sf -H 'Host: devbox.example.test' -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/state")"
python3 - "$P" "$state_json" <<'PY'
import json, os, sys
d = json.loads(sys.argv[2])
assert d["worktrees"] and os.path.realpath(d["worktrees"][0]["root"]) == os.path.realpath(sys.argv[1]), d
assert isinstance(d["terms"], list), d
assert "sessions" in d and isinstance(d["sessions"], list), d
print("ok mobile state")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import _input_payload
assert _input_payload("hello") == "hello\r"
assert _input_payload("hello\n") == "hello\r"
assert _input_payload("hello\r") == "hello\r"
assert _input_payload("line 1\nline 2") == "line 1\nline 2\r"
print("ok mobile enter payload")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
inputs = []
opens = []
mm.term_list = lambda: {"sessions": [{
    "tid": "live-agent-1", "root": str(root), "alive": True,
    "agent": {"source": "codex", "sid": "codex-session-0001"},
}, {
    "tid": "live-agent-2", "root": str(root), "alive": True,
    "agent": {"source": "claude", "sid": "claude-session-0001"},
}]}
mm.term_input = lambda tid, data: inputs.append((tid, data)) or {"ok": True}
pauses = []
mm._agent_input_pause = lambda: pauses.append(True)
assert mm.AGENT_INPUT_SETTLE_S > 0.12, mm.AGENT_INPUT_SETTLE_S
mm.term_open = lambda *args, **kwargs: opens.append((args, kwargs)) or {"tid": "new", "reused": False}

body = {
    "root": str(root),
    "target": {"type": "agent", "source": "codex", "sid": "codex-session-0001"},
    "text": "Please check the failing test",
}
sent = mm.mobile_send(body)
assert sent == {"ok": True, "tid": "live-agent-1", "opened": False, "delivery": "steer"}, sent
assert inputs == [
    ("live-agent-1", "Please check the failing test"),
    ("live-agent-1", "\r"),
], inputs
assert pauses == [True], pauses

original_pending_settings = mm.mobile_pending_session_settings
mm.mobile_pending_session_settings = lambda root_arg, source, sid: (
    {"model": "claude-fable-5", "effort": "high"}
    if source == "claude" else {"model": "", "effort": ""}
)
queued = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "claude", "sid": "claude-session-0001"},
    "text": "Run this after the current turn",
})
assert queued == {"ok": True, "tid": "live-agent-2", "opened": False, "delivery": "queue"}, queued
# 예약해 둔 모델·강도는 **전달 직전에 회수된다**. 예전엔 claude 만 이 자리에서 무시돼(codex 만 적용)
# 살아있는 세션에선 바꾼 모델이 영영 안 먹었다 — test-agent-settings-live 가 그 계약을 지킨다.
assert inputs[-6:] == [
    ("live-agent-2", "/model claude-fable-5"),
    ("live-agent-2", "\r"),
    ("live-agent-2", "/effort high"),
    ("live-agent-2", "\r"),
    ("live-agent-2", "Run this after the current turn"),
    ("live-agent-2", "\r"),
], inputs
assert pauses == [True] * 6, pauses      # 앞 전송 1 + 설정 4 + 이번 전달 1
mm.mobile_pending_session_settings = original_pending_settings

codex_queued = mm.mobile_send({**body, "delivery": "queue", "text": "Follow up next turn"})
assert codex_queued == {"ok": True, "tid": "live-agent-1", "opened": False, "delivery": "queue"}, codex_queued
assert inputs[-2:] == [
    ("live-agent-1", "Follow up next turn"),
    ("live-agent-1", "\t"),
], inputs
assert pauses == [True] * 7, pauses       # 예약이 비어 있어 이번엔 전달 1 만 는다
assert not opens, opens

original_native_active = mm._native_agent_active
original_clear_pending = mm._clear_pending_session_settings
mm.mobile_pending_session_settings = lambda *args: {"model": "gpt-5.6-sol", "effort": "high"}
mm._native_agent_active = lambda *args: True
cleared = []
mm._clear_pending_session_settings = lambda *args: cleared.append(args)
input_offset = len(inputs)
active_queued = mm.mobile_send({**body, "delivery": "queue", "text": "Keep this queued while busy"})
assert active_queued["delivery"] == "queue", active_queued
assert inputs[input_offset:] == [
    ("live-agent-1", "Keep this queued while busy"),
    ("live-agent-1", "\t"),
], inputs[input_offset:]
assert not cleared, cleared
mm.mobile_pending_session_settings = original_pending_settings
mm._native_agent_active = original_native_active
mm._clear_pending_session_settings = original_clear_pending

stopped = mm.mobile_interrupt({"root": str(root), "target": body["target"]})
assert stopped == {"ok": True, "tid": "live-agent-1", "interrupted": True}, stopped
assert inputs[-1] == ("live-agent-1", "\x03"), inputs

try:
    mm.mobile_interrupt({"root": str(root), "target": {"type": "agent", "source": "claude", "sid": "other-session"}})
    raise AssertionError("interrupt accepted an agent without a live Marina PTY")
except ValueError as exc:
    assert "실행 중" in str(exc), exc
print("ok mobile steering and interrupt")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
# 이중 실행 가드는 **세션(sid) 단위**다. 워크트리에 다른 에이전트가 살아 있다는 사실만으로는
# 막지 않는다 — 워크트리 하나에 세션이 여럿(터미널·데스크톱 앱·모바일)이기 때문.
# (02d3707 이 판정을 sid → root 로 넓히면서 데스크톱/코덱스 세션 이어받기까지 차단됐다.)
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
mm._root_has_live_agent = lambda root_arg, live_cwds: True    # 워크트리엔 '다른' 에이전트가 살아 있다
# 바쁨 판정은 이제 세션 겨냥(_native_agent_active) — 워크트리의 다른 세션이 작업 중이어도
# 이 세션(codex-session-0001)이 유휴면 resume 이 열려야 한다.
mm._native_agent_active = lambda r, s, i: (s, i) == ("claude", "other-session-0002")
opens = []
mm.term_open = lambda *args, **kwargs: opens.append(kwargs) or {"tid": "resumed", "reused": False}

out = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "codex", "sid": "codex-session-0001"},
    "text": "이어서 부탁해",
})
assert out == {"ok": True, "tid": "resumed", "opened": True}, out
assert opens and opens[0].get("agent_sid") == "codex-session-0001", opens
assert opens[0].get("agent_prompt") == "이어서 부탁해", opens
print("ok mobile resumes a dormant session even when the worktree has another live agent")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
mm._root_has_live_agent = lambda root_arg, live_cwds: False
mm._native_agent_active = lambda r, s, i: True   # 두 세션 다 작업 중
mm.term_open = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("native-active resume opened"))

# 작업 중인 세션에는 끼어들지 않는다 — 차단이 아니라 **보류**(끝나면 자동 전달).
# 진행 중이던 턴을 끊는 것은 어떤 경우에도 하지 않는다.
for source, sid in (("codex", "codex-session-0001"), ("claude", "claude-session-0001")):
    out = mm.mobile_send({
        "root": str(root),
        "target": {"type": "agent", "source": source, "sid": sid},
        "text": "do not overlap the desktop app",
    })
    assert out["delivery"] == "queue" and out["tid"] == "", out
    assert mm.mobile_outbox_pending(root, source, sid) == ["do not overlap the desktop app"]
print("ok mobile queues instead of interrupting a busy native-app session")
PY

PYTHONPATH="$SCR" python3 - "$TMP" "$P" <<'PY'
import json
from pathlib import Path
import sys
import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.PENDING_SETTINGS_FILE = tmp / "mobile-pending-agent-settings.json"
mm.safe_root = lambda value: root

saved = mm.mobile_update_session_settings({
    "root": str(root), "source": "codex", "sid": "codex-session-0001",
    "model": "gpt-5.6-sol", "effort": "high",
})
assert saved["model"] == "gpt-5.6-sol" and saved["effort"] == "high", saved
assert saved["applyMode"] == "pending", saved
assert mm.mobile_pending_session_settings(root, "codex", "codex-session-0001") == {
    "model": "gpt-5.6-sol", "effort": "high",
}
mode = mm.PENDING_SETTINGS_FILE.stat().st_mode & 0o777
assert mode == 0o600, oct(mode)
try:
    mm.mobile_update_session_settings({
        "root": str(root), "source": "codex", "sid": "codex-session-0001",
        "model": "--dangerous", "effort": "high",
    })
    raise AssertionError("invalid model persisted")
except ValueError:
    pass

original_mobile_agent_options = mm.mobile_agent_options
mm.mobile_agent_options = lambda: {"codex": {"models": [
    {"value": "gpt-5.6-sol", "label": "Sol", "efforts": ["low", "medium", "high"]},
    {"value": "gpt-5.6-terra", "label": "Terra", "efforts": ["low", "medium", "high"]},
    {"value": "gpt-5.6-luna", "label": "Luna", "efforts": ["low", "medium", "high", "xhigh", "max"]},
]}}
mm._live_agent_tid = lambda *args: "live-codex-1"
mm._native_agent_active = lambda *args: False
inputs = []
pauses = []
mm.term_input = lambda tid, data: inputs.append((tid, data)) or {"ok": True}
mm._agent_input_pause = lambda: pauses.append(True)

applied = mm.mobile_update_session_settings({
    "root": str(root), "source": "codex", "sid": "codex-session-0001",
    "model": "gpt-5.6-luna", "effort": "high",
})
assert applied == {"model": "gpt-5.6-luna", "effort": "high", "applyMode": "live"}, applied
assert inputs[:2] == [("live-codex-1", "/model"), ("live-codex-1", "\r")], inputs
assert inputs[2][0] == "live-codex-1" and inputs[2][1].endswith("\r") and inputs[2][1].count("\x1b[B") == 2, inputs[2]
assert inputs[3][0] == "live-codex-1" and inputs[3][1].endswith("\r") and inputs[3][1].count("\x1b[B") == 2, inputs[3]
assert len(pauses) >= 3, pauses
assert mm.mobile_pending_session_settings(root, "codex", "codex-session-0001") == {"model": "", "effort": ""}

mm._native_agent_active = lambda *args: True
pending = mm.mobile_update_session_settings({
    "root": str(root), "source": "codex", "sid": "codex-session-0001",
    "model": "gpt-5.6-sol", "effort": "medium",
})
# 미룬 이유까지 돌려준다 — 살아있는 세션에 "다음 Marina 연결에 적용"이라고만 하면 그 '다음'이
# 언제인지 알 수 없다(작업 중 = 이번 응답이 끝나면).
assert pending == {"model": "gpt-5.6-sol", "effort": "medium",
                   "applyMode": "pending", "pendingReason": "busy"}, pending
assert mm.mobile_pending_session_settings(root, "codex", "codex-session-0001") == {
    "model": "gpt-5.6-sol", "effort": "medium",
}
mm.mobile_agent_options = original_mobile_agent_options

mm.CODEX_MODELS_FILE = tmp / "models_cache.json"
mm.CODEX_MODELS_FILE.write_text(json.dumps({"models": [{
    "slug": "gpt-test", "display_name": "GPT Test",
    "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}],
}]}), encoding="utf-8")
catalog = mm.mobile_agent_options()
assert catalog["codex"]["models"] == [{"value": "gpt-test", "label": "GPT Test", "efforts": ["low", "high"]}], catalog
assert catalog["claude"]["efforts"] == ["low", "medium", "high", "xhigh", "max"], catalog

# claude 드롭다운 = 큐레이트 카탈로그 + CLI 가 캐시한 추가 모델(병합). 캐시가 비어도 목록은 유지된다.
import marina_sessions as ms
claude_values = [m["value"] for m in catalog["claude"]["models"]]
assert "claude-opus-5" in claude_values, claude_values

config = tmp / "claude.json"
config.write_text(json.dumps({"additionalModelOptionsCache": [
    {"value": "claude-brandnew-9[1m]", "label": "Brandnew"},   # 카탈로그에 없는 신모델
    {"value": "claude-opus-5[1m]", "label": "중복"},            # 이미 있는 건 한 번만
]}), encoding="utf-8")
ms.CLAUDE_CONFIG_FILE = config
merged = ms.claude_model_catalog()
values = [m["value"] for m in merged]
assert values.count("claude-opus-5") == 1, values
new = next(m for m in merged if m["value"] == "claude-brandnew-9")
assert new["window"] == 1_000_000, new         # [1m] 마커에서 컨텍스트 창을 읽는다
assert "[" not in new["value"], new            # CLI 인자로 넘길 값엔 마커가 없어야 한다

ms.CLAUDE_CONFIG_FILE = tmp / "nonexistent.json"
assert [m["value"] for m in ms.claude_model_catalog()] == [m["value"] for m in ms.CLAUDE_MODEL_CATALOG]
print("ok mobile session settings")
PY

PYTHONPATH="$SCR" python3 - "$TMP" "$P" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import marina_sessions as ms

tmp = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()

claude_home = tmp / "claude-projects"
ms.CLAUDE_PROJECTS_DIR = claude_home
session_dir = claude_home / ms._claude_project_slug(root)
session_dir.mkdir(parents=True)
claude_sid = "claude-session-0001"
tool_id = "toolu_agent_1"
running_tool_id = "toolu_agent_2"
(session_dir / f"{claude_sid}.jsonl").write_text("\n".join([
    json.dumps({"type": "assistant", "message": {"content": [{
        "type": "tool_use", "id": tool_id, "name": "Agent",
        "input": {"description": "Review auth flow", "prompt": "Check auth"},
    }]}}),
    json.dumps({"type": "user", "message": {"content": [{
        "type": "tool_result", "tool_use_id": tool_id,
        "content": [{"type": "text", "text": "agentId: childclaude0001 working in the background"}],
    }]}}),
    json.dumps({"type": "assistant", "message": {"content": [{
        "type": "tool_use", "id": running_tool_id, "name": "Agent",
        "input": {"description": "Still reviewing", "prompt": "Keep checking"},
    }]}}),
    json.dumps({"type": "user", "message": {"content": [{
        "type": "tool_result", "tool_use_id": running_tool_id,
        "content": [{"type": "text", "text": "agentId: childclaude0002 working in the background"}],
    }]}}),
    json.dumps({"type": "queue-operation", "content": (
        "<task-notification><task-id>childclaude0001</task-id>"
        f"<tool-use-id>{tool_id}</tool-use-id><status>completed</status></task-notification>"
    )}),
    json.dumps({"type": "queue-operation", "content": (
        "<task-notification><task-id>childclaude0002</task-id>"
        "<status>stopped</status></task-notification>"
    )}),
]) + "\n", encoding="utf-8")
child_dir = session_dir / claude_sid / "subagents"
child_dir.mkdir(parents=True)
(child_dir / "agent-childclaude0001.jsonl").write_text("\n".join([
    json.dumps({"type": "user", "message": {"content": "Check auth"}}),
    json.dumps({"type": "assistant", "message": {"content": [{
        "type": "text", "text": "Found sk-abcdefghijklmnopqrstuvwxyz secret",
    }]}}),
]) + "\n", encoding="utf-8")
(child_dir / "agent-childclaude0002.jsonl").write_text("\n".join([
    json.dumps({"type": "user", "message": {"content": "Keep checking"}}),
    json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "Interim finding"}]}}),
]) + "\n", encoding="utf-8")

claude = ms.agent_activity(root, "claude", claude_sid)
assert len(claude) == 2, claude
claude_by_id = {item["id"]: item for item in claude}
assert claude_by_id["childclaude0001"]["title"] == "Review auth flow", claude
assert claude_by_id["childclaude0001"]["status"] == "completed", claude
assert claude_by_id["childclaude0001"]["turns"][-1]["text"] == "Found [redacted] secret", claude
assert claude_by_id["childclaude0002"]["status"] == "stopped", claude

parent = tmp / "parent-codex.jsonl"
codex_dir = tmp / "codex-rollouts"
codex_dir.mkdir()
codex_sid = "codex-session-0001"
child_sid = "019f-child-agent-0001"
child = codex_dir / f"rollout-2026-07-20T00-00-00-{child_sid}.jsonl"
parent.write_text("\n".join([
    json.dumps({"payload": {"type": "function_call", "name": "spawn_agent", "call_id": "spawn-1",
        "arguments": json.dumps({"agent_type": "reviewer", "message": "Review auth"})}}),
    json.dumps({"payload": {"type": "function_call_output", "call_id": "spawn-1",
        "output": json.dumps({"agent_id": child_sid, "nickname": "Nash"})}}),
    json.dumps({"payload": {"type": "function_call", "name": "wait_agent", "call_id": "wait-1",
        "arguments": json.dumps({"targets": [child_sid]})}}),
    json.dumps({"payload": {"type": "function_call_output", "call_id": "wait-1",
        "output": json.dumps({"status": {child_sid: {"completed": "Review complete"}}})}}),
]) + "\n", encoding="utf-8")
child.write_text("\n".join([
    json.dumps({"type": "session_meta", "payload": {"id": child_sid, "cwd": str(root)}}),
    json.dumps({"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Review auth"}]}}),
    json.dumps({"payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Looks good"}]}}),
]) + "\n", encoding="utf-8")
ms.codex_agent_sessions = lambda refresh=False, include_all=False: {str(root): [
    {"sid": codex_sid, "path": str(parent)},
]}
ms.CODEX_ROLLOUT_DIRS = (codex_dir,)

codex = ms.agent_activity(root, "codex", codex_sid)
assert len(codex) == 1, codex
assert codex[0]["id"] == child_sid, codex
assert codex[0]["title"] == "Nash · reviewer", codex
assert codex[0]["status"] == "completed", codex
assert codex[0]["turns"][-1]["text"] == "Looks good", codex
print("ok mobile subagent activity")
PY

# 서브에이전트 연결 — 대화가 안 보이던 두 뿌리를 고정한다.
#  (1) 긴 세션: Agent 호출이 끝 256KB 밖에 있으면 목록 자체가 비었다.
#  (2) agentId 없는 호출: 동기 실행·이름 붙은 팀메이트는 결과 텍스트에 agentId 가 없어
#      파일이 있는데도 못 붙었다 — .meta.json 의 toolUseId·name 이 진짜 연결고리다.
PYTHONPATH="$SCR" python3 - "$TMP" "$P" <<'PY'
import json
from pathlib import Path
import sys

import marina_sessions as ms

tmp = Path(sys.argv[1]) / "link"
root = Path(sys.argv[2]).resolve()
claude_home = tmp / "claude-projects"
ms.CLAUDE_PROJECTS_DIR = claude_home
session_dir = claude_home / ms._claude_project_slug(root)
session_dir.mkdir(parents=True)
sid = "claude-session-link"
sync_id = "toolu_sync_1"
mate_id = "toolu_mate_1"
lines = [
    json.dumps({"type": "assistant", "message": {"content": [{
        "type": "tool_use", "id": sync_id, "name": "Task",
        "input": {"description": "Trace the bug", "prompt": "Where does it break?"},
    }]}}),
    json.dumps({"type": "user", "message": {"content": [{
        "type": "tool_result", "tool_use_id": sync_id,
        "content": [{"type": "text", "text": "Findings below. It breaks in the parser."}],
    }]}}),
    json.dumps({"type": "assistant", "message": {"content": [{
        "type": "tool_use", "id": mate_id, "name": "Agent",
        "input": {"description": "Review the branch", "name": "pre-main-review", "prompt": "Review"},
    }]}}),
]
# 끝 256KB 를 채우는 잡음 — 위 호출들을 tail 창 밖으로 밀어낸다(실제 긴 세션과 같은 모양).
filler = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "x" * 2000}]}})
lines += [filler] * 200
(session_dir / f"{sid}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
assert (session_dir / f"{sid}.jsonl").stat().st_size > ms.AGENT_TRANSCRIPT_TAIL_BYTES

child_dir = session_dir / sid / "subagents"
child_dir.mkdir(parents=True)
(child_dir / "agent-a11b22c33.jsonl").write_text("\n".join([
    json.dumps({"type": "user", "message": {"content": "Where does it break?"}}),
    json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "It breaks in the parser"}]}}),
]) + "\n", encoding="utf-8")
(child_dir / "agent-a11b22c33.meta.json").write_text(json.dumps({
    "agentType": "Explore", "description": "Trace the bug", "toolUseId": sync_id, "spawnDepth": 1,
}), encoding="utf-8")
(child_dir / "agent-apre-main-review-99f0.jsonl").write_text("\n".join([
    json.dumps({"type": "user", "message": {"content": "Review"}}),
    json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "Branch looks clean"}]}}),
]) + "\n", encoding="utf-8")
(child_dir / "agent-apre-main-review-99f0.meta.json").write_text(json.dumps({
    "agentType": "pre-main-review", "description": "Review the branch", "name": "pre-main-review",
    "spawnDepth": 0, "taskKind": "in_process_teammate",
}), encoding="utf-8")

items = ms.agent_activity(root, "claude", sid)
assert len(items) == 2, items
by_title = {item["title"]: item for item in items}
assert by_title["Trace the bug"]["turns"][-1]["text"] == "It breaks in the parser", items
assert by_title["Review the branch"]["turns"][-1]["text"] == "Branch looks clean", items
assert "name" not in by_title["Review the branch"], items
print("ok subagent linking (tail window · meta sidecar)")
PY

PYTHONPATH="$SCR" python3 - "$TMP" "$P" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import marina_mobile as mm

tmp = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")

write(root / ".claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Deploy this project\n---\n")
write(root / ".claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Review changes\n---\n")
write(root / ".agents/skills/audit/SKILL.md", "---\nname: audit\ndescription: Audit the project\n---\n")
write(root / ".codex/agents/reviewer.toml", 'name = "reviewer"\ndescription = "Review changes"\n')
write(root / "mobile-note.md", "mobile catalog fixture\n")
subprocess.run(["git", "add", "mobile-note.md"], cwd=root, check=True)

claude_home = tmp / "claude-home"
claude_plugin = tmp / "claude-plugin"
project_plugin = tmp / "project-plugin"
write(claude_plugin / "skills/plugin-skill/SKILL.md", "---\nname: plugin-skill\ndescription: Plugin skill\n---\n")
write(claude_plugin / "commands/plugin-command.md", "---\nname: plugin-command\ndescription: Plugin command\n---\n")
write(claude_plugin / "agents/plugin-reviewer.md", "---\nname: plugin-reviewer\ndescription: Plugin reviewer\n---\n")
write(project_plugin / "skills/project-skill/SKILL.md", "---\nname: project-skill\ndescription: Project plugin skill\n---\n")
write(claude_home / "settings.json", json.dumps({"enabledPlugins": {"demo@market": True, "off@market": False}}))
write(root / ".claude/settings.local.json", json.dumps({"enabledPlugins": {"project@market": True}}))
write(claude_home / "plugins/installed_plugins.json", json.dumps({"plugins": {
    "demo@market": [{"installPath": str(claude_plugin)}],
    "project@market": [{"installPath": str(project_plugin)}],
    "off@market": [{"installPath": str(tmp / "off-plugin")}],
}}))

codex_home = tmp / "codex-home"
write(codex_home / "config.toml", '[plugins."demo@market"]\nenabled = true\n[plugins."off@market"]\nenabled = false\n')
write(codex_home / "plugins/cache/market/demo/1.0/skills/plugin-skill/SKILL.md", "---\nname: plugin-skill\ndescription: Plugin skill\n---\n")
write(codex_home / "plugins/cache/market/off/1.0/skills/hidden/SKILL.md", "---\nname: hidden\ndescription: Hidden\n---\n")

mm.CLAUDE_HOME = claude_home
mm.CODEX_USER_HOME = codex_home
mm.AGENTS_HOME = tmp / "agents-home"

claude = mm._native_catalog(root, "claude")
assert {item["insert"] for item in claude["skills"]} >= {
    "/deploy", "/demo:plugin-skill", "/demo:plugin-command", "/project:project-skill"
}, claude
assert {item["insert"] for item in claude["agents"]} >= {"@agent-reviewer", "@agent-demo:plugin-reviewer"}, claude
assert all("off" not in item["insert"] for item in claude["skills"] + claude["agents"]), claude

codex = mm._native_catalog(root, "codex")
assert {item["insert"] for item in codex["skills"]} >= {"$audit", "$demo:plugin-skill"}, codex
assert {item["name"] for item in codex["agents"]} >= {"reviewer"}, codex
assert all("hidden" not in item["insert"] for item in codex["skills"]), codex

files = mm.mobile_catalog(root, "claude", "mobile")
assert files["files"] == [{"name": "mobile-note.md", "insert": "@mobile-note.md", "description": "file"}], files
print("ok mobile native catalog")
PY

catalog_url="$(python3 -c 'import sys,urllib.parse; print(sys.argv[1] + "/mobile/api/catalog?" + urllib.parse.urlencode({"root":sys.argv[2],"source":"claude","q":"mobile"}))' "$b" "$P")"
catalog_json="$(curl -sf -H 'Host: devbox.example.test' -H 'X-Marina-Mobile-Token: secret' "$catalog_url")"
python3 - "$catalog_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert any(item["name"] == "mobile-note.md" for item in d["files"]), d
print("ok mobile catalog endpoint")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
opened = []
inputs = []
mm.safe_root = lambda value: root
mm.term_open = lambda root_arg, cols, rows, agent_source="", agent_sid="", agent_prompt="": (
    opened.append({
        "root": root_arg,
        "cols": cols,
        "rows": rows,
        "agent_source": agent_source,
        "agent_sid": agent_sid,
        "agent_prompt": agent_prompt,
    }) or {"tid": "agent-term", "reused": False}
)
mm.term_input = lambda tid, data: inputs.append((tid, data)) or {"ok": True}
out = mm.mobile_send({
    "root": str(root),
    "target": {"type": "agent", "source": "codex", "sid": "sid0001"},
    "text": "hello agent",
})
assert out == {"ok": True, "tid": "agent-term", "opened": True}, out
assert opened and opened[0]["agent_source"] == "codex" and opened[0]["agent_sid"] == "sid0001", opened
assert opened[0]["agent_prompt"] == "hello agent", opened
assert inputs == [], inputs
print("ok mobile agent prompt")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_info = lambda root_arg, refresh=False: {"id": "proj", "projectLabel": "proj", "sessionTitle": "title"}
mm.agents_payload = lambda root_arg, refresh=False, include_all=False: [{
    "source": "codex",
    "sid": "sid0001",
    "title": "Agent",
    "preview": "agent preview",
    "ts": 10,
}]
mm.agent_transcript = lambda root_arg, source, sid: {"turns": [{"role": "assistant", "text": "agent preview"}]}
mm.agent_activity = lambda root_arg, source, sid: [{
    "id": "child1", "title": "Review", "status": "completed", "preview": "done", "turns": []
}]
mm._native_catalog = lambda root_arg, source: {"skills": [{"name": "audit", "insert": "$audit", "description": "Audit"}], "agents": []}
mm.term_list = lambda: {"sessions": [
    {"tid": "agent-term", "root": str(root), "agent": {"source": "codex", "sid": "sid0001"}, "preview": "sent text", "created": 20},
    {"tid": "shell-term", "root": str(root), "agent": None, "preview": "shell preview", "created": 5},
]}
state = mm.mobile_state()
keys = [s["key"] for s in state["sessions"]]
assert "agent:codex:sid0001:%s" % root in keys, keys
agent = next(s for s in state["sessions"] if s["key"].startswith("agent:codex:"))
assert agent["tid"] == "agent-term" and agent["controllable"] is True, agent
assert agent["externalActive"] is False, agent
assert "subagents" not in agent, agent
assert "catalog" not in agent, agent
assert "term:shell-term" in keys, keys
assert "term:agent-term" not in keys, keys
print("ok mobile hides agent runner terms")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
# detached(재시작 후 디스크에서 복원된) PTY 는 tid 는 있어도 fd 가 없어 term_input 이 400 —
# controllable 이 True 로 보이면 안 된다(Plan 2 잔여 지적).
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_info = lambda root_arg, refresh=False: {"id": "proj", "projectLabel": "proj", "sessionTitle": "title"}
mm.agents_payload = lambda root_arg, refresh=False, include_all=False: [{
    "source": "codex",
    "sid": "sid0001",
    "title": "Agent",
    "preview": "agent preview",
    "ts": 10,
}]
mm.agent_transcript = lambda root_arg, source, sid: {"turns": [{"role": "assistant", "text": "agent preview"}]}
mm.agent_activity = lambda root_arg, source, sid: []
mm._native_catalog = lambda root_arg, source: {"skills": [], "agents": []}
mm.term_list = lambda: {"sessions": [
    {"tid": "adopted-term", "root": str(root), "agent": {"source": "codex", "sid": "sid0001"},
     "preview": "sent text", "created": 20, "alive": True, "detached": True},
]}
state = mm.mobile_state()
agent = next(s for s in state["sessions"] if s["key"].startswith("agent:codex:"))
assert agent["tid"] == "adopted-term", agent
assert agent["controllable"] is False, agent
print("ok mobile detached term is not controllable")
PY

activity_url="$(python3 -c 'import sys,urllib.parse; print(sys.argv[1] + "/mobile/api/activity?" + urllib.parse.urlencode({"root":sys.argv[2],"source":"codex","sid":"sid0001"}))' "$b" "$P")"
activity_json="$(curl -sf -H 'Host: devbox.example.test' -H 'X-Marina-Mobile-Token: secret' "$activity_url")"
python3 - "$activity_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload == {"subagents": []}, payload
print("ok mobile activity endpoint")
PY

send_body="$(python3 -c 'import json,sys; print(json.dumps({"root":sys.argv[1],"target":{"type":"shell"},"text":"echo MOBILE_OK"}))' "$P")"
tid="$(curl -sf -H 'Host: devbox.example.test' -H 'X-Marina-Mobile-Token: secret' -H 'content-type: application/json' \
  -d "$send_body" "$b/mobile/api/send" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and d["tid"], d; print(d["tid"])')"

python3 - "$b" "$tid" <<'PY'
import json, subprocess, sys, time
base, tid = sys.argv[1:3]
for _ in range(50):
    raw = subprocess.check_output([
        "curl", "-sf", "-H", "Host: devbox.example.test",
        "-H", "X-Marina-Mobile-Token: secret", f"{base}/mobile/api/state"
    ], text=True)
    state = json.loads(raw)
    terms = {t["tid"]: t for t in state["terms"]}
    if tid in terms and "MOBILE_OK" in (terms[tid].get("preview") or ""):
        print("ok mobile send")
        break
    time.sleep(0.2)
else:
    raise SystemExit("FAIL: MOBILE_OK did not appear in terminal preview")
PY

AUTH_HOME="$TMP/auth-home"; mkdir -p "$AUTH_HOME"
cp "$MARINA_HOME/projects.json" "$AUTH_HOME/projects.json"
AUTH_PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
MARINA_HOME="$AUTH_HOME" MARINA_AUTH_DB="$AUTH_HOME/auth.db" MARINA_AUTH_PBKDF2_ITERATIONS=1000 PYTHONPATH="$SCR" python3 - <<'PY'
import os
from pathlib import Path
from marina_auth import AuthStore
store = AuthStore(Path(os.environ["MARINA_AUTH_DB"]), pbkdf2_iterations=1000)
store.initialize()
store.bootstrap_admin("owner", "Owner", "owner-password")
PY
MARINA_MOBILE_TOKEN=secret MARINA_CONTROL_PORT=$AUTH_PORT MARINA_CONTROL_HOST=127.0.0.1 \
  MARINA_HOME="$AUTH_HOME" MARINA_AUTH_DB="$AUTH_HOME/auth.db" MARINA_AUTH_PBKDF2_ITERATIONS=1000 \
  python3 "$CTRL" >/dev/null 2>&1 & AUTH_SRV=$!
auth_base="http://127.0.0.1:$AUTH_PORT"
for _ in $(seq 1 100); do curl -sf "$auth_base/api/health" >/dev/null && break; sleep 0.1; done
old_token_code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Marina-Mobile-Token: secret' "$auth_base/mobile/api/state")"
[[ "$old_token_code" == "401" ]] || { echo "FAIL: auth-enabled mobile token should be rejected, got $old_token_code"; exit 1; }
cookie_jar="$TMP/auth-cookies"
curl -sf -c "$cookie_jar" -H 'content-type: application/json' \
  -d '{"username":"owner","password":"owner-password"}' "$auth_base/api/auth/login" >/dev/null
cookie_state_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$cookie_jar" "$auth_base/mobile/api/state")"
[[ "$cookie_state_code" == "200" ]] || { echo "FAIL: auth-enabled mobile cookie should work, got $cookie_state_code"; exit 1; }

grep -q 'mobile)' "$SCR/marina-entrypoint.sh" || {
  echo "FAIL: marina mobile CLI missing"; exit 1;
}

CLI_HOME="$TMP/cli-home"
out="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile enable devbox.example.test)"
[[ -s "$CLI_HOME/mobile-token" ]] || { echo "FAIL: mobile enable did not create token"; exit 1; }
grep -q 'http://devbox.example.test:' <<<"$out" || { echo "FAIL: mobile enable URL missing host: $out"; exit 1; }
grep -q '/mobile?token=' <<<"$out" || { echo "FAIL: mobile enable URL missing token: $out"; exit 1; }
grep -q 'phone access: local-only' <<<"$out" || { echo "FAIL: mobile enable should explain local-only dashboard bind: $out"; exit 1; }

old_token="$(cat "$CLI_HOME/mobile-token")"
token_out="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile token)"
[[ "$token_out" == "$old_token" ]] || { echo "FAIL: mobile token should print raw token"; exit 1; }

rotate_out="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile rotate devbox.example.test)"
new_token="$(cat "$CLI_HOME/mobile-token")"
[[ -n "$new_token" && "$new_token" != "$old_token" ]] || { echo "FAIL: mobile rotate should replace token"; exit 1; }
grep -q 'mobile token rotated' <<<"$rotate_out" || { echo "FAIL: mobile rotate missing status: $rotate_out"; exit 1; }
grep -q "token=$new_token" <<<"$rotate_out" || { echo "FAIL: mobile rotate should print new raw token: $rotate_out"; exit 1; }
grep -q "/mobile?token=$new_token" <<<"$rotate_out" || { echo "FAIL: mobile rotate should print new login URL: $rotate_out"; exit 1; }

address_out="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile address devbox.example.test)"
[[ "$address_out" == "http://devbox.example.test:3900/mobile" ]] || { echo "FAIL: mobile address should print stable tokenless URL: $address_out"; exit 1; }

address_with_path="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile address https://devbox.example.test/mobile)"
[[ "$address_with_path" == "https://devbox.example.test/mobile" ]] || { echo "FAIL: mobile address should not duplicate /mobile path: $address_with_path"; exit 1; }

env_host_url="$(MARINA_HOME="$CLI_HOME" MARINA_MOBILE_HOST=phonebox.test "$SCR/marina-entrypoint.sh" mobile address)"
[[ "$env_host_url" == "http://phonebox.test:3900/mobile" ]] || { echo "FAIL: mobile address should prefer MARINA_MOBILE_HOST: $env_host_url"; exit 1; }

FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/open" <<'SH'
#!/usr/bin/env bash
echo "$1" > "$MARINA_OPEN_CAPTURE"
SH
chmod +x "$FAKEBIN/open"
MARINA_OPEN_CAPTURE="$TMP/open-url" MARINA_HOME="$CLI_HOME" PATH="$FAKEBIN:$PATH" "$SCR/marina-entrypoint.sh" mobile open devbox.example.test >/dev/null
[[ "$(cat "$TMP/open-url")" == "http://devbox.example.test:3900/mobile" ]] || { echo "FAIL: mobile open should open stable address"; exit 1; }

status_out="$(MARINA_HOME="$CLI_HOME" MARINA_CONTROL_HOST=0.0.0.0 "$SCR/marina-entrypoint.sh" mobile status devbox.example.test)"
grep -q 'mobile enabled token=' <<<"$status_out" || { echo "FAIL: mobile status should show enabled token: $status_out"; exit 1; }
grep -q 'address=http://devbox.example.test:3900/mobile' <<<"$status_out" || { echo "FAIL: mobile status should show stable address: $status_out"; exit 1; }
grep -q "login-url=http://devbox.example.test:3900/mobile?token=$new_token" <<<"$status_out" || { echo "FAIL: mobile status should show login URL: $status_out"; exit 1; }
grep -q 'phone access: network-bind' <<<"$status_out" || { echo "FAIL: mobile status should explain network bind: $status_out"; exit 1; }

cat > "$CLI_HOME/dashboard-bind.env" <<'EOF'
MARINA_CONTROL_HOST=0.0.0.0
MARINA_CONTROL_PORT=43900
EOF
persisted_status="$(MARINA_HOME="$CLI_HOME" "$SCR/marina-entrypoint.sh" mobile status devbox.example.test)"
grep -q 'address=http://devbox.example.test:43900/mobile' <<<"$persisted_status" || { echo "FAIL: mobile status should use persisted dashboard port: $persisted_status"; exit 1; }
grep -q 'phone access: network-bind' <<<"$persisted_status" || { echo "FAIL: mobile status should use persisted dashboard bind: $persisted_status"; exit 1; }

doctor_out="$(MARINA_HOME="$CLI_HOME" MARINA_CONTROL_HOST=127.0.0.1 MARINA_CONTROL_PORT=$PORT "$SCR/marina-entrypoint.sh" mobile doctor devbox.example.test)"
grep -q 'mobile doctor' <<<"$doctor_out" || { echo "FAIL: mobile doctor missing heading: $doctor_out"; exit 1; }
grep -q 'dashboard-http=ok' <<<"$doctor_out" || { echo "FAIL: mobile doctor should confirm dashboard HTTP: $doctor_out"; exit 1; }
grep -q 'address=http://devbox.example.test:' <<<"$doctor_out" || { echo "FAIL: mobile doctor should show stable address: $doctor_out"; exit 1; }
grep -q 'login-url=http://devbox.example.test:' <<<"$doctor_out" || { echo "FAIL: mobile doctor should show login URL: $doctor_out"; exit 1; }
grep -q 'phone access: local-only' <<<"$doctor_out" || { echo "FAIL: mobile doctor should show bind hint: $doctor_out"; exit 1; }

echo "PASS test-mobile-control"
