#!/usr/bin/env bash
# Long Claude/Codex transcripts must be recoverable page-by-page without loading whole JSONL files.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCR" "$TMP" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

scr, tmp = sys.argv[1:3]
claude_projects = Path(tmp) / "claude-projects"
codex_home = Path(tmp) / "codex"
os.environ["CLAUDE_PROJECTS_DIR"] = str(claude_projects)
os.environ["CODEX_HOME"] = str(codex_home)
sys.path.insert(0, scr)
import marina_sessions as ms

root = Path(tmp) / "worktree"
root.mkdir()

def collect(source, sid):
    before = None
    pages = []
    while True:
        page = ms.agent_transcript(root, source, sid, before=before, limit=20)
        assert len(page["turns"]) <= 20, page
        pages.insert(0, page["turns"])
        if not page["hasMore"]:
            break
        assert page["cursor"] is not None and page["cursor"] != before, page
        before = page["cursor"]
    turns = [turn for page in pages for turn in page]
    ids = [turn["id"] for turn in turns]
    assert len(ids) == len(set(ids)), "turn IDs must be stable and unique"
    return turns

claude_sid = "claude-history-0001"
claude_dir = claude_projects / re.sub(r"[/.]", "-", str(root))
claude_dir.mkdir(parents=True)
claude_rows = [
    {"type": "user" if i % 2 == 0 else "assistant", "message": {
        "role": "user" if i % 2 == 0 else "assistant",
        "content": [{"type": "text", "text": f"claude-{i:03d}"}],
        **({"model": "claude-test", "effort": "high"} if i % 2 else {}),
    }} for i in range(95)
]
(claude_dir / f"{claude_sid}.jsonl").write_text(
    "{broken\n" + "\n".join(json.dumps(row) for row in claude_rows) + "\n", encoding="utf-8",
)
claude_turns = collect("claude", claude_sid)
assert [turn["text"] for turn in claude_turns] == [f"claude-{i:03d}" for i in range(95)]
assert ms.agent_runtime_settings(root, "claude", claude_sid) == {"model": "claude-test", "effort": "high"}

codex_sid = "codex-history-0001"
(codex_home / "sessions").mkdir(parents=True)
(codex_home / "session_index.jsonl").write_text(
    json.dumps({"id": codex_sid, "thread_name": "History"}) + "\n", encoding="utf-8",
)
codex_path = codex_home / "sessions" / f"rollout-{codex_sid}.jsonl"
codex_rows = [{"type": "session_meta", "payload": {"cwd": str(root), "id": codex_sid}}] + [
    {"type": "response_item", "payload": {
        "type": "message", "role": "user" if i % 2 == 0 else "assistant",
        "content": [{"type": "input_text" if i % 2 == 0 else "output_text", "text": f"codex-{i:03d}"}],
    }} for i in range(55)
] + [
    {"type": "turn_context", "payload": {"model": "gpt-test", "effort": "xhigh"}},
    {"type": "event_msg", "payload": {"type": "tool_output", "blob": "x" * 400_000}},
]
codex_path.write_text("\n".join(json.dumps(row) for row in codex_rows) + "\n", encoding="utf-8")
codex_turns = collect("codex", codex_sid)
assert [turn["text"] for turn in codex_turns] == [f"codex-{i:03d}" for i in range(55)]
assert ms.agent_runtime_settings(root, "codex", codex_sid) == {"model": "gpt-test", "effort": "xhigh"}
print("ok paginated Claude/Codex history")
PY

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = (Path(sys.argv[1]) / "mobile-state-root").resolve()
root.mkdir()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_info = lambda value, refresh=False: {
    "id": "mobile-state", "alias": "mobile-state", "projectId": "project",
    "projectLabel": "Project", "source": "registry",
}
mm.term_list = lambda: {"sessions": []}
mm.agents_payload = lambda value, refresh=False: [{
    "source": "codex", "sid": "codex-history-0001", "title": "History",
    "preview": "latest preview", "ts": 1,
}]
mm.activate_agent_payloads = lambda agents, active: agents
mm.agent_transcript = lambda *args, **kwargs: (_ for _ in ()).throw(
    AssertionError("mobile state eagerly loaded every transcript")
)
mm.agent_activity = lambda *args, **kwargs: (_ for _ in ()).throw(
    AssertionError("mobile state eagerly loaded subagent activity")
)
mm._native_catalog = lambda *args, **kwargs: (_ for _ in ()).throw(
    AssertionError("mobile state eagerly loaded native catalogs")
)
mm.agent_runtime_settings = lambda *args, **kwargs: {}
mm.mobile_pending_session_settings = lambda *args, **kwargs: {}
mm.mobile_agent_options = lambda: {}

state = mm.mobile_state()
session = state["sessions"][0]
assert session["preview"] == "latest preview", session
assert "turns" not in session, session
assert "historyCursor" not in session, session
assert "hasMoreHistory" not in session, session
assert "subagents" not in session, session
assert "catalog" not in session, session
print("ok mobile state defers transcript loading")
PY

MOBILE="$SCR/marina_mobile.py"
HANDLER="$SCR/marina_handler.py"
MODALS="$SCR/marina-web/app-6-modals.js"
grep -q 'id="olderMessagesBtn"' "$MOBILE" || { echo "FAIL mobile older-message control missing"; exit 1; }
grep -q 'function loadOlderMessages' "$MOBILE" || { echo "FAIL mobile older-message loader missing"; exit 1; }
grep -q 'historyCursor' "$MOBILE" || { echo "FAIL mobile history cursor missing"; exit 1; }
grep -q 'async function loadSessionMessages' "$MOBILE" || { echo "FAIL mobile latest-history loader missing"; exit 1; }
grep -q 'await loadSessionMessages(selectedSession()' "$MOBILE" || { echo "FAIL mobile selected history is not loaded after state"; exit 1; }
grep -q 'async function loadSessionActivity' "$MOBILE" || { echo "FAIL mobile subagent activity is not lazy"; exit 1; }
grep -q 'async function loadNativeCatalog' "$MOBILE" || { echo "FAIL mobile native catalog is not lazy"; exit 1; }
grep -q '"/mobile/api/transcript"' "$HANDLER" || { echo "FAIL token-protected mobile transcript route missing"; exit 1; }
grep -q '"/mobile/api/activity"' "$HANDLER" || { echo "FAIL token-protected mobile activity route missing"; exit 1; }
grep -q 'data-agent-older' "$MODALS" || { echo "FAIL desktop transcript older-message control missing"; exit 1; }
grep -q 'loadOlderAgentTurns' "$MODALS" || { echo "FAIL desktop transcript pagination missing"; exit 1; }

echo "PASS test-agent-history-pagination"
