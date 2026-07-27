#!/usr/bin/env bash
# Task 3 (mobile queue/question plan) — robust AskUserQuestion surfacing.
# Part A: marina_question.py PreToolUse capture is best-effort (writes a record even when
#         tool_input.questions is odd-shaped; only skips when there's genuinely nothing).
# Part B: marina_mobile.py's renderQuestionCard never renders an empty .questionCard — it
#         falls back to plain text when header/question/options can't be built.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- Part A: marina_question.py capture hardening ----------
home_ok="$TMP/home-ok"; mkdir -p "$home_ok"
home_odd="$TMP/home-odd"; mkdir -p "$home_odd"
home_bare="$TMP/home-bare"; mkdir -p "$home_bare"
home_empty="$TMP/home-empty"; mkdir -p "$home_empty"

# well-formed: normal question with options.
MARINA_HOME="$home_ok" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-ok-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-1",
 "tool_input": {"questions": [{"header": "Pick one", "question": "Which color?", "options": [{"label": "Red"}, {"label": "Blue"}]}]}}
JSON

# odd-but-nonempty: list of bare strings (no header/options at all).
MARINA_HOME="$home_odd" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-odd-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-2",
 "tool_input": {"questions": ["What's your favorite color?"]}}
JSON

# odd-but-nonempty: a bare dict (not wrapped in a list) with an unrelated key + options only.
MARINA_HOME="$home_bare" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-bare-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-3",
 "tool_input": {"questions": {"options": [{"label": "Yes"}, {"label": "No"}]}}}
JSON

# genuinely empty: missing key, empty list, and empty-dict-only-list should all skip (no file).
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-1234", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-4",
 "tool_input": {}}
JSON
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-5678", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-5",
 "tool_input": {"questions": []}}
JSON
MARINA_HOME="$home_empty" python3 "$SCR/marina_question.py" <<'JSON'
{"session_id": "sess-empty-9012", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp",
 "tool_use_id": "tu-6",
 "tool_input": {"questions": [{}]}}
JSON

python3 - "$home_ok" "$home_odd" "$home_bare" "$home_empty" <<'PY'
import json
import sys
from pathlib import Path

home_ok, home_odd, home_bare, home_empty = (Path(p) for p in sys.argv[1:5])

ok = json.loads((home_ok / "agent-questions" / "claude-sess-ok-1234.json").read_text())
assert ok["questions"][0]["question"] == "Which color?", ok
assert ok["toolUseId"] == "tu-1", ok

odd = json.loads((home_odd / "agent-questions" / "claude-sess-odd-1234.json").read_text())
assert odd["questions"] and odd["questions"][0].get("question") == "What's your favorite color?", odd

bare = json.loads((home_bare / "agent-questions" / "claude-sess-bare-1234.json").read_text())
assert bare["questions"] and isinstance(bare["questions"][0].get("options"), list), bare
assert len(bare["questions"][0]["options"]) == 2, bare

for sid in ("sess-empty-1234", "sess-empty-5678", "sess-empty-9012"):
    assert not (home_empty / "agent-questions" / f"claude-{sid}.json").exists(), sid

print("PASS part A (marina_question.py capture hardening): well-formed + odd(list-of-strings) + odd(bare dict) written, genuinely-empty(3 shapes) skipped")
PY

# ---------- Part B: renderQuestionCard fallback (node vm) ----------
PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()

def extract(start_marker, end_marker):
    start = html.find(start_marker)
    end = html.find(end_marker)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit(f"boundaries missing for {start_marker}")
    return html[start:end]

esc_helpers = extract("// ESC_HELPERS_START", "// ESC_HELPERS_END")
question_card = extract("// QUESTION_CARD_START", "// QUESTION_CARD_END")
source = esc_helpers + "\n" + question_card
print("const helperSource = " + json.dumps(source) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

const context = {};
vm.createContext(context);
vm.runInContext(
  `${helperSource}\nthis.renderQuestionCard = renderQuestionCard; this.questionsFromActivity = questionsFromActivity;`,
  context, {filename: "marina_mobile.py::renderQuestionCard"});
const renderQuestionCard = context.renderQuestionCard;
if (typeof renderQuestionCard !== "function") throw new Error("renderQuestionCard not extracted");

function activityFor(questions) {
  return {name: "AskUserQuestion", status: "pending", detail: JSON.stringify({questions})};
}

// 1) well-formed question -> structured card with header/question text/option buttons.
{
  const item = activityFor([{header: "Pick one", question: "Which color?", options: [{label: "Red"}, {label: "Blue"}]}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes('class="questionCard"'), "expected questionCard wrapper");
  assert.ok(html.includes("Which color?"), `expected question text in structured card: ${html}`);
  assert.ok(html.includes("Red") && html.includes("Blue"), `expected option buttons: ${html}`);
}

// 2) malformed: no header/question/options at all (odd dict) -> text fallback, never empty.
{
  const item = activityFor([{foo: "bar"}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes('class="questionCard"'), "expected questionCard wrapper even for fallback");
  assert.ok(html.trim().length > 0, "fallback card must not be empty");
  assert.ok(!html.includes('<div class="questionOpts">'), `expected plain-text fallback (no opts div): ${html}`);
}

// 3) malformed: bare string (list-of-strings normalized shape from marina_question.py) -> shows question text.
{
  const item = activityFor([{question: "What's your favorite color?"}]);
  const html = renderQuestionCard(item, true);
  assert.ok(html.includes("What&#39;s your favorite color?") || html.includes("What's your favorite color?"),
    `expected question text rendered: ${html}`);
}

// 4) no questions at all -> "" (genuinely nothing to show, not a fallback case).
{
  const item = activityFor([]);
  const html = renderQuestionCard(item, true);
  assert.equal(html, "", `expected empty string when there are no questions: ${html}`);
}

console.log("PASS part B (renderQuestionCard): structured card + text fallback + no-question passthrough (4/4)");
''')
PY

echo "PASS test-agent-question-surfacing"
