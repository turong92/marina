---
description: Analyze a project and register its dev services with marina (marina-services.json)
allowed-tools: Bash, Read, Glob, Grep
---
Analyze the target project and register its runnable dev services with marina.

Target: `$ARGUMENTS` (a project path; if empty, use the current git project's main checkout via `git rev-parse --path-format=absolute --git-common-dir` → its dirname).

1. Resolve the project **id**: `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project ls` and match the path, or register first with `project add` if missing.
2. Inspect the repo to find runnable services — read `package.json` (scripts.dev/start), `build.gradle*`/`settings.gradle*` (Spring bootRun modules), `Dockerfile`/`docker-compose.yml`, `pyproject.toml`/`requirements.txt` (uvicorn/flask). For each, derive `name` (a valid identifier), `portBase` (the app's default port; avoid collisions across services), `cwd` (relative to the project root / its subrepo), and `run` — a shell command using marina tokens `{port}` (and `{profile}` if the framework has profiles). Native example: `exec npm run dev -- --port {port}`. Docker example: `exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=svc-{session} docker compose up`.
3. **Show the user the proposed services (name/port/cwd/run) and ask for confirmation.** Adjust per feedback.
4. Register each (central by default; pass `--root` only if the user wants it committed to the repo for team sharing):
   `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" service add <id> '<service-json>'`
5. Confirm with `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project ls` and tell the user to refresh the dashboard.

Keep `run` a single shell command; complex startup should call a project-side helper script. Default to central storage so the project repo stays untouched unless the user asks for team sharing.
