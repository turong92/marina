#!/usr/bin/env bash
# mobile control: token-protected phone page + remote-safe state/send endpoints.
set -euo pipefail
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
grep -q '"/mobile/api/state"' <<<"$mobile_html" || { echo "FAIL: /mobile page should fetch mobile-scoped state API"; exit 1; }
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
grep -q 'sessionStructureKey' <<<"$mobile_html" || { echo "FAIL: /mobile polling should preserve session card nodes when structure is unchanged"; exit 1; }
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
grep -q 'const requestContext = {root: selectedRoot(), sessionKey: selectedSessionKey' <<<"$mobile_html" || { echo "FAIL: /mobile send should capture its session before the request"; exit 1; }
grep -q 'failedSend = requestContext' <<<"$mobile_html" || { echo "FAIL: /mobile failed send should retry in its original session"; exit 1; }
grep -q 'async function responseError' <<<"$mobile_html" || { echo "FAIL: /mobile should show the server send failure reason"; exit 1; }
! grep -q 'class="usageRail"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should not permanently expose agent context usage"; exit 1; }
grep -q 'id="usageBtn"' <<<"$mobile_html" || { echo "FAIL: /mobile compact header should expose a usage button"; exit 1; }
grep -q 'id="usagePanel"' <<<"$mobile_html" || { echo "FAIL: /mobile usage button should open a usage panel"; exit 1; }
grep -q 'id="chatNavTitle"' <<<"$mobile_html" || { echo "FAIL: /mobile chat should use a compact navigation title"; exit 1; }
grep -q 'data-view="chat"' <<<"$mobile_html" || { echo "FAIL: /mobile shell should switch to compact chat mode"; exit 1; }
grep -q '#mobileApp\[data-view="chat"\] #projectTabs' <<<"$mobile_html" || { echo "FAIL: project navigation should hide while chatting"; exit 1; }
grep -q '#mobileApp\[data-view="chat"\] #sourceTabs' <<<"$mobile_html" || { echo "FAIL: source navigation should hide while chatting"; exit 1; }
grep -q '#mobileApp\[data-view="chat"\] #servicesBtn' <<<"$mobile_html" || { echo "FAIL: service summary should hide while chatting"; exit 1; }
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
grep -q 'servicesBtn' <<<"$mobile_html" || { echo "FAIL: /mobile shell should expose service state"; exit 1; }
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
grep -q 'openTimelineDetailIds' <<<"$mobile_html" || { echo "FAIL: /mobile polling should preserve opened timeline details"; exit 1; }
grep -q 'data-timeline-detail' <<<"$mobile_html" || { echo "FAIL: /mobile timeline details need stable identities"; exit 1; }
grep -q 'renderActivityGroup(sections.activities, `exchange:${exchange.id}`)' <<<"$mobile_html" || { echo "FAIL: each answer process should keep a stable collapsible work group"; exit 1; }
grep -q 'class="turnMeta"' <<<"$mobile_html" || { echo "FAIL: each agent exchange should expose its actual model and effort"; exit 1; }
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
older_loader = script.split("async function loadOlderMessages", 1)[1].split("const activityTypeLabels", 1)[0]
assert 'turnsStructureKey = ""' not in latest_loader, "polling invalidates the render key and jumps to the bottom"
assert 'turnsStructureKey = ""' not in older_loader, "history prepend invalidates the render key and loses the scroll anchor"
print("ok mobile loaders preserve scroll intent")
PY

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
script = render_mobile_html().rsplit("<script>", 1)[1].split("</script>", 1)[0]
print(script[script.index("function esc"):script.index("function draftKey")])
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

PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
script = render_mobile_html().rsplit("<script>", 1)[1].split("</script>", 1)[0]
print(script[script.index("function conversationExchanges"):script.index("function renderTimelineMessage")])
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
assert inputs[-2:] == [
    ("live-agent-2", "Run this after the current turn"),
    ("live-agent-2", "\r"),
], inputs
assert pauses == [True, True], pauses
mm.mobile_pending_session_settings = original_pending_settings

codex_queued = mm.mobile_send({**body, "delivery": "queue", "text": "Follow up next turn"})
assert codex_queued == {"ok": True, "tid": "live-agent-1", "opened": False, "delivery": "queue"}, codex_queued
assert inputs[-2:] == [
    ("live-agent-1", "Follow up next turn"),
    ("live-agent-1", "\t"),
], inputs
assert pauses == [True, True, True], pauses
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
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
mm._agent_process_active = lambda source, sid: True
mm.term_open = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("duplicate resume opened"))

try:
    mm.mobile_send({
        "root": str(root),
        "target": {"type": "agent", "source": "codex", "sid": "codex-session-0001"},
        "text": "do not overlap",
    })
    raise AssertionError("mobile accepted a session already running outside Marina")
except ValueError as exc:
    assert "다른 앱" in str(exc), exc
print("ok mobile blocks external duplicate resume")
PY

PYTHONPATH="$SCR" python3 - "$P" <<'PY'
from pathlib import Path
import sys
import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: root
mm.term_list = lambda: {"sessions": []}
mm._agent_process_active = lambda source, sid: False
mm.agents_payload = lambda value, refresh=False: [{
    "source": "codex", "sid": "codex-session-0001", "status": "working",
}, {
    "source": "claude", "sid": "claude-session-0001", "status": "working",
}]
mm.term_open = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("native-active resume opened"))

try:
    mm.mobile_send({
        "root": str(root),
        "target": {"type": "agent", "source": "codex", "sid": "codex-session-0001"},
        "text": "do not overlap the desktop app",
    })
    raise AssertionError("mobile accepted a session active in a native app")
except ValueError as exc:
    assert "다른 앱" in str(exc), exc
try:
    mm.mobile_send({
        "root": str(root),
        "target": {"type": "agent", "source": "claude", "sid": "claude-session-0001"},
        "text": "do not overlap the Claude app",
    })
    raise AssertionError("mobile accepted a Claude session active in a native app")
except ValueError as exc:
    assert "다른 앱" in str(exc), exc
print("ok mobile blocks native-app duplicate resume")
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
assert pending == {"model": "gpt-5.6-sol", "effort": "medium", "applyMode": "pending"}, pending
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
ms.codex_agent_sessions = lambda refresh=False: {str(root): [
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
mm.agents_payload = lambda root_arg, refresh=False: [{
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
