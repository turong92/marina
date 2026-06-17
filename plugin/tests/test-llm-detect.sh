#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
python3 - "$CTRL" <<'PY' || { echo "FAIL: test-llm-detect"; exit 1; }
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# argv: claude is read-only (Read/Glob/Grep), never Write/Edit/Bash
a = mc._llm_argv("claude", "PROMPT")
assert "-p" in a and "PROMPT" in a and "--allowedTools" in a, a
tools = a[a.index("--allowedTools") + 1]
assert tools == "Read,Glob,Grep", tools
assert "Write" not in tools and "Bash" not in tools and "Edit" not in tools, tools

# argv: codex exec under read-only sandbox, non-interactive (skip git check), final msg to file
c = mc._llm_argv("codex", "PROMPT")
assert "exec" in c and "PROMPT" in c and "read-only" in c, c
assert "--skip-git-repo-check" in c, c
c2 = mc._llm_argv("codex", "PROMPT", "/tmp/last.txt")
assert "--output-last-message" in c2 and "/tmp/last.txt" in c2, c2

# pinned override via env
os.environ["MARINA_LLM"] = "codex"
assert mc._llm_pinned() == "codex"
del os.environ["MARINA_LLM"]

# pinned override via ~/.marina/config.json
import json, pathlib
pathlib.Path(os.environ["MARINA_HOME"], "config.json").write_text(json.dumps({"llmProvider": "claude"}))
assert mc._llm_pinned() == "claude"

# FAKE seam forces provider "fake"
os.environ["MARINA_LLM_FAKE"] = "/bin/true"
assert mc._llm_provider() == "fake"
del os.environ["MARINA_LLM_FAKE"]
PY
echo "PASS test-llm-detect"
