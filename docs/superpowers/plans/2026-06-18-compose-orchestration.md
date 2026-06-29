# Worktree Docker Compose Orchestration (compose-kind) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Rev 5** — owner chose **override + Docker-assigned ports + no recording** (rev 4); this rev fixes the codex round-4 blocker (override **every** `ports[]` entry incl. auto-host-port; truly-internal = `expose`). See "Design history" at the end.

**Goal:** Let a git worktree start/stop/inspect its project's full-stack Docker Compose, isolated per worktree, via the `marina` CLI — inter-service traffic over container DNS (zero injection), host ports auto-assigned by Docker, marina running the compose opaquely.

**Architecture:** compose-kind is a **project-level execution mode** running alongside the existing service-level native `run` path. A new module `plugin/scripts/marina-compose.py` owns all compose logic. `marina.sh` detects `kind: compose` from the registry and delegates the execution verbs (`start/stop/restart/status/logs/ports`) to it; every other path (native `run`, `config`, `override`, `project`, `service`, `status-all`) is untouched.

**marina does NOT pick or store host ports.** Isolation = `-p <id>-<session>` (per-worktree network/name namespacing). For each service that publishes a port, marina emits a tiny **static overlay** that `!override`s its `ports` to `127.0.0.1::<container-port>` — i.e. localhost-only, **host port left to Docker** (ephemeral). Docker assigns a free host port at `up`; marina reads it back live with `docker compose -p <name> ps` whenever it needs to display it. No host-port computation, no free-port probing, no persisted port file, no resolved-config file (so no secrets on disk). Inter-service comms never use host ports — they use the compose network's DNS (`http://search:8000`).

**Tech Stack:** bash (`marina.sh`), Python 3 stdlib only (`marina-compose.py`), Docker Compose **v2.24.4+** (`!override` merge tag), bash test harness (`plugin/tests/*.sh`, mktemp + `MARINA_HOME` isolation).

**Source of truth:** `docs/specs/2026-06-18-worktree-compose-orchestration-design.md` (spec) + `docs/specs/2026-06-18-compose-orchestration-HANDOFF.md` (handoff). This plan deliberately supersedes two spec sub-details — see "Deviations from spec".

---

## Scope

CLI-complete compose-kind — spec phases **②** (worktree compose execution) **+ ③** (lifecycle) **+ minimal ①** (registration). After it lands:

```
marina start --all          # docker compose -f stored -f overlay -p <name> up -d --remove-orphans
marina start --web          # one service (+ its compose deps)
marina stop --web           # docker compose -p <name> stop web   (one service)
marina stop --all           # docker compose -p <name> down --remove-orphans  (whole stack)
marina restart --web|--all
marina status | ports       # docker compose -p <name> ps  → live host ports
marina logs [service]       # docker compose -p <name> logs
```

…against a project registered with `marina project add <path> --compose <file>`.

**Deferred to follow-on plans** (outlined at end): spec **④** dashboard, rich **①** import/edit UI, spec **⑤** LLM starter.

**No-regression guarantee:** native-kind (env/links/overrides/`run`) is shipped on `origin/main` and stays the default. Compose paths run **only** when the resolved project has `kind: compose`. Docker is required **only** for compose-kind. Task 4.1 enforces this.

---

## Locked design decisions

1. compose-kind ∥ native-kind coexist; native stays default & shipped.
2. Project = its Dockerfiles + **one full-stack dev compose**, **stored by marina** at `~/.marina/<id>/<composeFile>` (default `docker-compose.yml`). App repo gets **zero** marina files/vars. Import = **copy** into marina.
3. Execution: `docker compose -f <stored> -f <overlay> --project-directory <worktree> -p <id>-<session> up -d`. The overlay `!override`s published ports to `127.0.0.1::<target>` (localhost + Docker-assigned host port). `--project-directory` resolves the stored compose's relative paths against the worktree.
4. inter-service = container DNS (`http://be:8081`), fixed, zero injection. Container (target) ports are never touched.
5. env = string passthrough; compose consumes its **own** var names. A project may declare one env var name + default (e.g. `APP_ENV=local`). The env is built **before** `config` (interpolation happens at `config`, not `up`) and passed to both.
6. gitignored config lives in the worktree (attach symlink / scratch); compose references it by relative path resolved via `--project-directory` at `config` time.
7. marina runs compose **opaquely** — it never interprets app config. The overlay it writes contains only port overrides (no app config, no secrets, no chosen port numbers). It never merges N subrepo composes.
8. Access v1 = per-worktree **localhost** host port + (later) dashboard `↗`. Reverse proxy out of scope.

## Engineering policies (the why behind the code)

- **P1 — env before config.** Compose interpolates `${VAR}` during `config`, not `up`. Build the env first; pass to both `config` and `up`. (`COMPOSE_PROFILES` inherited from `os.environ` so profiles work.)
- **P2 — `!override`, not append.** `docker compose -f a -f b` *appends* the `ports:` list by default → an overlay would publish both base and remapped ports. The `!override` tag (Compose ≥2.24.4) makes the overlay **replace** the list. This is the whole reason the overlay works.
- **P3 — Docker assigns host ports.** marina overrides published to `127.0.0.1::<target>` (empty host port = ephemeral). Docker picks a free host port atomically (no race, no `% 80` collisions, no bind-probe). marina reads the result back with `ps`.
- **P4 — localhost-only.** `127.0.0.1::<target>` binds loopback only (a bare `<target>` would bind 0.0.0.0 / the LAN).
- **P5 — reject isolation breakers.** `container_name` and `network_mode: host` defeat per-worktree isolation → error with an actionable message. `external` networks/volumes → warning.
- **P6 — port ranges unsupported in v1.** A `target` range is rejected with a clear error (single ports only).
- **P7 — lifecycle by project label.** `down/stop/restart/ps/logs` run as `docker compose -p <name> …` (operates by the `com.docker.compose.project` label); only `up` needs the `-f` files. No reliance on persisted state.
- **P8 — `--remove-orphans`** on whole-stack `down` so removed services don't leak containers.
- **P9 — no persisted port/resolved state.** Docker is the source of truth for host ports; marina queries live. The only file written is the static overlay (no secrets, no port numbers).

## Deviations from spec (intentional, owner-approved 2026-06-18)

- Spec ② said reuse `portBase + offset` for **stable, predictable** per-worktree host ports and **record the mapping to the session**. This plan instead lets **Docker assign** host ports (ephemeral) and **does not record** them (queries `ps` live). Trade-off: host ports change on `down`/`up`. Accepted because access is via the dashboard `↗` (which reads the live port), so stability is low-value, and this removes the port-collision/secret-on-disk complexity entirely.

---

## File structure

**New files:**

| File | Responsibility |
|------|----------------|
| `plugin/scripts/marina-compose.py` | Pure: `compose_project_name`, `isolation_breakers`, `build_overlay` (config → `!override` overlay text), `parse_ps_ports` (`ps --format json` → `{service:[hostports]}`), `up_argv`/`label_argv`. Impure: `docker_config_json` (env-aware). Subcommands: `name`, `overlay`/`psports` (stdin test hooks), `up`, `down`, `stop`, `restart`, `status`, `logs`. |
| `plugin/tests/test-compose-name.sh` | `compose_project_name` sanitization (pure). |
| `plugin/tests/test-compose-overlay.sh` | `build_overlay` (every `ports[]` entry — fixed & auto — → `!override ["127.0.0.1::<target>"]`; `expose`/image-only untouched; range rejected) + `isolation_breakers` + `parse_ps_ports` (pure, no docker). |
| `plugin/tests/test-compose-registry.sh` | `project add --compose` sets `kind`, copies compose; `project ls` shows kind. |
| `plugin/tests/test-compose-dispatch.sh` | `marina.sh` routes verbs via a **fake `docker`** shim; asserts no-arg guard, bare-arg rejection, env-at-config, `-f overlay`, `-p`, per-service vs whole-stack stop, live `ps` port readout. |
| `plugin/tests/test-compose-config.sh` | **Real `docker compose config`** (gated on the binary, no daemon): JSON shape + `${VAR}` interpolation + abspath, then feeds `build_overlay`. Proves P1/P2 assumptions. |
| `plugin/tests/test-compose-native-fallback.sh` | Native project unaffected: docker never invoked, native pid created (no-regression). |
| `plugin/tests/test-compose-e2e.sh` | Real-docker smoke (gated on `docker info`): `${APP_ENV}` interpolation, Docker-assigned port read via `marina ports`, reachable on 127.0.0.1, down. |

**Modified files:**

| File | Change |
|------|--------|
| `plugin/scripts/marina.sh` | `registry_add` (`--compose`), `registry_infer` (default `kind`), `registry_ls` (show kind), new `project_meta`/`project_kind`, new `compose_main` (guard, docker+version check, label lifecycle), `main()` delegation branch, `usage()`. |
| `README.md` | compose-kind section. |

**Session-dir artifact** (under `<worktree>/.workspace/marina/<session_id>/`): only `marina-overlay.yml` — static (same content each `up` for a given compose), contains only `ports: !override` lines. No secrets, no chosen port numbers. Regenerated each `up`.

---

## Phase 1 — Minimal registration (spec ①)

### Task 1.1: `project add --compose <file>` stores kind + copies compose

**Files:** Modify `plugin/scripts/marina.sh` (`registry_infer` :64-88, `registry_add` :90-129, `registry_ls` :259-274, `usage` :512); Test `plugin/tests/test-compose-registry.sh` (create).

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-compose-registry.sh`:

```bash
#!/usr/bin/env bash
# project add --compose <file> 가 kind:compose 를 박고 compose 를 ~/.marina/<id>/ 로 복사한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web: { image: "nginx", ports: ["3000:80"] }
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default local >/dev/null
python3 - "$MARINA_HOME/projects.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))["projects"][0]
assert p.get("kind")=="compose", p
assert p.get("composeFile")=="docker-compose.yml", p
assert p.get("composeEnvVar")=="APP_ENV" and p.get("composeEnvDefault")=="local", p
print("ok registry")
PY
id="$(basename "$P")"
[[ -f "$MARINA_HOME/$id/docker-compose.yml" ]] || { echo "FAIL: compose not copied"; exit 1; }
grep -q "nginx" "$MARINA_HOME/$id/docker-compose.yml" || { echo "FAIL: copy content"; exit 1; }
bash "$SH" project ls | grep -q "compose" || { echo "FAIL: ls no kind"; exit 1; }
echo "PASS test-compose-registry"
```

- [ ] **Step 2: Run → fails** (`--compose` is an unknown arg today): `bash plugin/tests/test-compose-registry.sh`

- [ ] **Step 3: `registry_infer` default kind** — change marina.sh:86 `print(...)` to:

```python
print(json.dumps({"id": base, "root": root, "subrepos": subrepos, "worktreeGlobs": globs, "kind": "native"}, ensure_ascii=False))
```

- [ ] **Step 4: `registry_add` parses `--compose`/`--env-var`/`--env-default`, copies compose** — replace `registry_add` (marina.sh:90-129) with:

```bash
registry_add() {
  local path="" subrepos_csv="" have_subrepos=0 compose_file="" env_var="" env_default="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subrepos)   have_subrepos=1; if [[ $# -ge 2 ]]; then subrepos_csv="$2"; shift 2; else subrepos_csv=""; shift; fi ;;
      --subrepos=*) have_subrepos=1; subrepos_csv="${1#--subrepos=}"; shift ;;
      --compose)    compose_file="${2:-}"; shift 2 ;;
      --compose=*)  compose_file="${1#--compose=}"; shift ;;
      --env-var)    env_var="${2:-}"; shift 2 ;;
      --env-var=*)  env_var="${1#--env-var=}"; shift ;;
      --env-default)   env_default="${2:-}"; shift 2 ;;
      --env-default=*) env_default="${1#--env-default=}"; shift ;;
      *) [[ -z "$path" ]] || die "add: 인자 과다 ('$1')"; path="$1"; shift ;;
    esac
  done
  [[ -z "$compose_file" || -f "$compose_file" ]] || die "compose 파일 없음: $compose_file"
  local entry; entry="$(registry_infer "$path")" || exit $?
  mkdir -p "$MARINA_HOME"
  local abs_compose=""
  [[ -n "$compose_file" ]] && abs_compose="$(cd "$(dirname "$compose_file")" && pwd -P)/$(basename "$compose_file")"
  entry="$(python3 - "$entry" "$have_subrepos" "$subrepos_csv" "$abs_compose" "$env_var" "$env_default" <<'PY'
import json, os, sys
entry = json.loads(sys.argv[1])
have_subrepos, subrepos_csv = sys.argv[2] == "1", sys.argv[3]
compose, env_var, env_default = sys.argv[4], sys.argv[5], sys.argv[6]
if have_subrepos:
    entry["subrepos"] = [s for s in (x.strip() for x in subrepos_csv.split(",")) if s]
if compose:
    entry["kind"] = "compose"
    entry["composeFile"] = os.path.basename(compose)
    if env_var:
        entry["composeEnvVar"] = env_var
        entry["composeEnvDefault"] = env_default
print(json.dumps(entry, ensure_ascii=False))
PY
)"
  python3 - "$PROJECTS_FILE" "$entry" <<'PY'
import json, os, sys
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
norm = lambda p: os.path.realpath(os.path.expanduser(p))
projects = [p for p in data.get("projects", []) if norm(p.get("root","")) != norm(entry["root"])]
projects.append(entry)
data["projects"] = projects
data.setdefault("schemaVersion", 1)
json.dump(data, open(projects_file, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"added: {entry['id']}  root={entry['root']}  kind={entry.get('kind','native')}")
print(f"  subrepos: {', '.join(entry['subrepos']) or '(none)'}")
print(f"  worktreeGlobs: {', '.join(entry['worktreeGlobs'])}")
PY
  if [[ -n "$abs_compose" ]]; then
    local id; id="$(basename "$(cd "$path" && pwd -P)")"
    mkdir -p "$MARINA_HOME/$id"
    cp "$abs_compose" "$MARINA_HOME/$id/$(basename "$abs_compose")"
    echo "  compose: stored at $MARINA_HOME/$id/$(basename "$abs_compose")"
  fi
}
```

- [ ] **Step 5: `registry_ls` shows kind** — in marina.sh:266-273, after `print(f"{p.get('id')}\t{p.get('root')}")`:

```python
    kind = p.get("kind", "native")
    if kind != "native":
        print(f"  kind: {kind}  compose: {p.get('composeFile','docker-compose.yml')}")
```

- [ ] **Step 6: `usage()`** — extend the `project add` line (marina.sh:512):

```
    marina.sh project add <project-path> [--subrepos a,b,c] [--compose <file> [--env-var NAME --env-default VAL]]
```

- [ ] **Step 7: Run → passes**: `bash plugin/tests/test-compose-registry.sh` → `PASS test-compose-registry`

- [ ] **Step 8: Commit**

```bash
git add plugin/scripts/marina.sh plugin/tests/test-compose-registry.sh
git commit -m "feat(compose): project add --compose stores kind:compose + copies compose into marina"
```

---

## Phase 2 — Pure compose logic (`marina-compose.py`)

### Task 2.1: module — name + overlay + ps-parse + isolation + argv

**Files:** Create `plugin/scripts/marina-compose.py`; Test `plugin/tests/test-compose-name.sh` (create).

- [ ] **Step 1: Write the failing test**

Create `plugin/tests/test-compose-name.sh`:

```bash
#!/usr/bin/env bash
# compose_project_name: <id>-<session> 를 docker 허용 문자(소문자/숫자/_/-)로 정규화.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
[[ "$(python3 "$CP" name --project-id MyProj --session abc-123)" == "myproj-abc-123" ]] || { echo "FAIL: lower/keep"; exit 1; }
[[ "$(python3 "$CP" name --project-id ai.api --session 'feat/foo bar')" == "ai-api-feat-foo-bar" ]] || { echo "FAIL: sanitize"; exit 1; }
[[ "$(python3 "$CP" name --project-id --- --session '')" == "marina" ]] || { echo "FAIL: empty fallback"; exit 1; }
echo "PASS test-compose-name"
```

- [ ] **Step 2: Run → fails** (file missing): `bash plugin/tests/test-compose-name.sh`

- [ ] **Step 3: Create `marina-compose.py`**

```python
#!/usr/bin/env python3
"""marina-compose.py — compose-kind 실행 헬퍼 (의존성 0, stdlib only).

워크트리별 격리 docker compose. 포트는 marina 가 정하지도 기록하지도 않는다:
정적 overlay 로 published 를 ephemeral(127.0.0.1::<target>)로 덮어 → Docker 가 빈 호스트포트 자동할당,
marina 는 `docker compose ps` 로 실제 포트를 *그때그때* 읽는다(기록 파일 없음 = stale·secret 잔류 없음).
inter-service 는 컨테이너 DNS(주입 0), marina 는 compose 불투명 실행.
"""
import argparse
import json
import os
import re
import subprocess
import sys


def compose_project_name(project_id: str, session: str) -> str:
    """docker compose -p 값. 소문자 + [a-z0-9_-] 만, 양끝 -/_ 정리. 빈 값이면 'marina'."""
    name = re.sub(r"[^a-z0-9_-]+", "-", f"{project_id}-{session}".lower()).strip("-_")
    return name or "marina"


def isolation_breakers(config: dict):
    """워크트리 격리를 깨는 설정 → (errors, warnings). errors 는 reject 대상."""
    errors, warnings = [], []
    services = (config or {}).get("services") or {}
    for n in sorted(services):
        s = services[n] or {}
        if s.get("container_name"):
            errors.append(f"service '{n}': container_name 고정 — 워크트리 다중 인스턴스 충돌. 제거.")
        nm = s.get("network_mode")
        if isinstance(nm, str) and nm.startswith("host"):
            errors.append(f"service '{n}': network_mode: host — 포트 forward·격리 무력화. 제거.")
    for kind in ("networks", "volumes"):
        for nm, spec in ((config or {}).get(kind) or {}).items():
            if isinstance(spec, dict) and spec.get("external"):
                warnings.append(f"{kind}.{nm}: external — 워크트리 간 상태 공유 가능(의도면 무시).")
    return errors, warnings


def _port_targets(svc: dict):
    """서비스의 모든 호스트-publish 포트 → [(target, protocol)].
    `docker compose config` 의 services[*].ports[] 엔트리는 전부 호스트로 publish 되는 포트다 —
    고정(3000:80, published 있음)이든 auto(8000, published 없음)든. 내부 전용은 `expose` 로 표현돼
    ports[] 에 없으니 여기서 안 잡힌다(컨테이너 DNS 로만 도달). 범위 target 은 거부(P6)."""
    out = []
    for p in (svc.get("ports") or []):
        if not isinstance(p, dict):
            continue
        tgt = p.get("target")
        if tgt is None:
            continue
        if "-" in str(tgt):
            raise ValueError(f"포트 범위 target={tgt} 는 compose-kind v1 미지원 (단일 포트만).")
        out.append((int(tgt), str(p.get("protocol") or "tcp")))
    return out


def build_overlay(config: dict, bind_host: str = "127.0.0.1") -> str:
    """resolved config → overlay YAML 텍스트. ports[] 가 있는 각 서비스의 ports 를 !override 로
    127.0.0.1::<target> (호스트포트는 Docker 자동할당)로 덮는다. 포트값·비밀번호 안 들어감.
    overlay 대상(=ports[] 보유 서비스) 없으면 빈 문자열."""
    services = (config or {}).get("services") or {}
    lines, any_ = ["services:"], False
    for name in sorted(services):
        specs = _port_targets(services[name] or {})
        if not specs:
            continue
        any_ = True
        entries = ", ".join(
            f'"{bind_host}::{t}"' if proto == "tcp" else f'"{bind_host}::{t}/{proto}"'
            for t, proto in specs
        )
        lines += [f"  {name}:", f"    ports: !override [{entries}]"]
    return ("\n".join(lines) + "\n") if any_ else ""


def parse_ps_ports(ps_text: str):
    """`docker compose ps --format json` (JSON 배열 or 줄별 JSON) → {service: [hostports]}.
    Publishers[].PublishedPort 중 0 아닌 것만, 정렬·중복제거."""
    s = (ps_text or "").strip()
    if not s:
        return {}
    rows = []
    try:
        v = json.loads(s)
        rows = v if isinstance(v, list) else [v]
    except json.JSONDecodeError:
        rows = [json.loads(ln) for ln in s.splitlines() if ln.strip()]
    out = {}
    for r in rows:
        svc = r.get("Service") or r.get("Name") or "?"
        for p in (r.get("Publishers") or []):
            if not isinstance(p, dict) or not p.get("PublishedPort"):
                continue
            try:
                hp = int(p["PublishedPort"])           # 버전에 따라 int/str → 정규화
            except (TypeError, ValueError):
                continue
            out.setdefault(svc, set()).add(hp)          # 컨테이너 여러 개여도 dedup
    return {svc: sorted(ports) for svc, ports in out.items()}


def up_argv(stored, overlay, project_dir, project_name, services):
    a = ["docker", "compose", "-f", stored]
    if overlay and os.path.exists(overlay):
        a += ["-f", overlay]
    a += ["--project-directory", project_dir, "-p", project_name, "up", "-d", "--remove-orphans"]
    return a + list(services)


def label_argv(project_name, verb_args):
    """파일 없이 -p 라벨로 동작하는 lifecycle 명령 (down/stop/restart/ps/logs)."""
    return ["docker", "compose", "-p", project_name] + list(verb_args)


def docker_config_json(stored, project_dir, project_name, env) -> dict:
    """stored compose 완전 해석(상대→절대, ${VAR} 보간). env 가 보간에 쓰임(P1). 출력은 저장 안 함."""
    out = subprocess.check_output(
        ["docker", "compose", "-f", stored, "--project-directory", project_dir,
         "-p", project_name, "config", "--format", "json"],
        text=True, env=env)
    return json.loads(out)


# ---- subcommands ----

def cmd_name(a):
    print(compose_project_name(a.project_id, a.session)); return 0


def cmd_overlay(a):  # test hook: stdin = config json → overlay text
    try:
        print(build_overlay(json.load(sys.stdin)), end="")
    except ValueError as e:
        sys.stderr.write(f"error: {e}\n"); return 2
    return 0


def cmd_psports(a):  # test hook: stdin = ps json → {service:[ports]}
    print(json.dumps(parse_ps_ports(sys.stdin.read()))); return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="marina-compose")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("name"); p.add_argument("--project-id", required=True); p.add_argument("--session", required=True); p.set_defaults(fn=cmd_name)
    p = sub.add_parser("overlay"); p.set_defaults(fn=cmd_overlay)
    p = sub.add_parser("psports"); p.set_defaults(fn=cmd_psports)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run → passes**: `bash plugin/tests/test-compose-name.sh` → `PASS test-compose-name`

- [ ] **Step 5: Commit**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-name.sh
git commit -m "feat(compose): marina-compose.py — name, overlay, ps-parse, isolation, argv (pure core)"
```

### Task 2.2: lock overlay / isolation / ps-parse with tests

**Files:** Test `plugin/tests/test-compose-overlay.sh` (create).

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# build_overlay: ports[] 보유 서비스(고정+auto) 전부 !override 127.0.0.1::<target>, expose/image-only 제외, 범위 거부.
# + isolation_breakers + parse_ps_ports.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/c.json" <<'JSON'
{"services":{
  "web":{"ports":[{"target":80,"published":"3000","protocol":"tcp"}]},
  "be":{"ports":[{"target":8081,"published":"8081","protocol":"tcp"}]},
  "auto":{"ports":[{"target":9000,"protocol":"tcp"}]},
  "index":{"image":"py"},
  "dbonly":{"image":"pg","expose":["5432"]}
}}
JSON
ov="$(python3 "$CP" overlay < "$TMP/c.json")"
echo "$ov" | grep -q '!override' || { echo "FAIL: no !override"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::80"' || { echo "FAIL: web fixed→localhost"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::8081"' || { echo "FAIL: be"; exit 1; }
echo "$ov" | grep -q '"127.0.0.1::9000"' || { echo "FAIL: auto-publish(published 없음)도 override 돼야 함"; exit 1; }
echo "$ov" | grep -qE '^  index:' && { echo "FAIL: image-only service in overlay"; exit 1; } || true
echo "$ov" | grep -qE '^  dbonly:' && { echo "FAIL: expose-only service in overlay"; exit 1; } || true

# 범위 거부
echo '{"services":{"a":{"ports":[{"target":"8080-8090","published":"8080"}]}}}' \
  | python3 "$CP" overlay >/dev/null 2>&1 && { echo "FAIL: range not rejected"; exit 1; } || true

# isolation breakers + ps parse — 함수 직접
python3 - "$CP" <<'PY'
import importlib.util, sys, json
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
err,warn=mc.isolation_breakers({"services":{"x":{"container_name":"fixed"},"y":{"network_mode":"host"}},"volumes":{"v":{"external":True}}})
assert any("container_name" in e for e in err) and any("network_mode" in e for e in err), err
assert any("external" in w for w in warn), warn
ps='[{"Service":"web","Publishers":[{"URL":"127.0.0.1","TargetPort":80,"PublishedPort":55001,"Protocol":"tcp"},{"PublishedPort":0}]},{"Service":"be","Publishers":[{"PublishedPort":55002}]}]'
assert mc.parse_ps_ports(ps)=={"web":[55001],"be":[55002]}, mc.parse_ps_ports(ps)
print("ok funcs")
PY
echo "PASS test-compose-overlay"
```

- [ ] **Step 2: Run** → `PASS test-compose-overlay` (fix logic until green).
- [ ] **Step 3: Commit** — `git add plugin/tests/test-compose-overlay.sh && git commit -m "test(compose): overlay (!override/localhost/range), isolation breakers, ps-port parse"`

---

## Phase 3 — `marina.sh` dispatch to compose

### Task 3.1: `up`/`down`/`stop`/`restart`/`status`/`logs` subcommands

**Files:** Modify `plugin/scripts/marina-compose.py`.

- [ ] **Step 1: Add subcommand functions** (before `def main`)

```python
def _overlay_path(session_dir):
    return os.path.join(session_dir, "marina-overlay.yml")


def _env_with(overrides):
    env = dict(os.environ)
    for kv in overrides:
        k, _, v = kv.partition("=")
        if k:
            env[k] = v
    return env


def _show_ports(project_name):
    try:
        out = subprocess.check_output(label_argv(project_name, ["ps", "--format", "json"]), text=True)
    except subprocess.CalledProcessError:
        return
    ports = parse_ps_ports(out)
    if ports:
        print("ports (docker 자동할당):")
        for svc in sorted(ports):
            print("  " + svc + "=" + ",".join(str(p) for p in ports[svc]))


def cmd_up(a):
    env = _env_with(a.env)                                          # P1: env first
    name = compose_project_name(a.project_id, a.session)
    config = docker_config_json(a.stored, a.project_dir, name, env)  # 비밀번호 in-memory only, 저장 안 함
    errors, warnings = isolation_breakers(config)                   # P5
    for w in warnings:
        sys.stderr.write(f"warning: {w}\n")
    if errors:
        for e in errors:
            sys.stderr.write(f"error: {e}\n")
        return 2
    try:
        overlay_text = build_overlay(config)                       # P2/P3/P4/P6
    except ValueError as e:
        sys.stderr.write(f"error: {e}\n")
        return 2
    os.makedirs(a.session_dir, exist_ok=True)
    op = _overlay_path(a.session_dir)
    with open(op, "w", encoding="utf-8") as f:
        f.write(overlay_text)
    argv = up_argv(a.stored, op, a.project_dir, name, a.service)
    print("compose: " + " ".join(argv))
    rc = subprocess.call(argv, env=env)                            # P1: same env to up
    if rc == 0:
        _show_ports(name)
    return rc


def cmd_down(a):
    name = compose_project_name(a.project_id, a.session)
    return subprocess.call(label_argv(name, ["down", "--remove-orphans"]))  # P7/P8


def cmd_stop(a):
    name = compose_project_name(a.project_id, a.session)
    return subprocess.call(label_argv(name, ["stop", *a.service]))          # P7


def cmd_restart(a):
    name = compose_project_name(a.project_id, a.session)
    return subprocess.call(label_argv(name, ["restart", *a.service]))       # P7


def cmd_status(a):
    name = compose_project_name(a.project_id, a.session)
    try:
        out = subprocess.check_output(label_argv(name, ["ps", "--format", "json"]), text=True)
    except subprocess.CalledProcessError:
        print("(not running)")
        return 0
    for svc, ports in sorted(parse_ps_ports(out).items()):
        print(svc + "=" + ",".join(str(p) for p in ports))
    if a.ports_only:
        return 0
    return subprocess.call(label_argv(name, ["ps"]))               # 사람용 표


def cmd_logs(a):
    name = compose_project_name(a.project_id, a.session)
    verb = ["logs"] + ([] if a.no_follow else ["-f"]) + list(a.service)
    return subprocess.call(label_argv(name, verb))                 # P7
```

- [ ] **Step 2: Register subcommands in `main()`** (after the `psports` parser line)

```python
    def name_args(p):
        p.add_argument("--project-id", required=True)
        p.add_argument("--session", required=True)
    p = sub.add_parser("up"); name_args(p); p.add_argument("--stored", required=True); p.add_argument("--project-dir", required=True); p.add_argument("--session-dir", required=True); p.add_argument("--service", action="append", default=[]); p.add_argument("--env", action="append", default=[]); p.set_defaults(fn=cmd_up)
    p = sub.add_parser("down"); name_args(p); p.set_defaults(fn=cmd_down)
    p = sub.add_parser("stop"); name_args(p); p.add_argument("--service", action="append", default=[]); p.set_defaults(fn=cmd_stop)
    p = sub.add_parser("restart"); name_args(p); p.add_argument("--service", action="append", default=[]); p.set_defaults(fn=cmd_restart)
    p = sub.add_parser("status"); name_args(p); p.add_argument("--ports-only", action="store_true"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("logs"); name_args(p); p.add_argument("--service", action="append", default=[]); p.add_argument("--no-follow", action="store_true"); p.set_defaults(fn=cmd_logs)
```

- [ ] **Step 3: Commit**

```bash
git add plugin/scripts/marina-compose.py
git commit -m "feat(compose): up (overlay+env-before-config) + label-based down/stop/restart/status/logs"
```

### Task 3.2: `project_meta` + `compose_main` + `main()` branch in `marina.sh`

**Files:** Modify `plugin/scripts/marina.sh` (add `project_meta`/`project_kind` after `merged_services_json` ~:312; `compose_main` before `main` ~:1273; branch inside `main()` ~:1277); Test `plugin/tests/test-compose-dispatch.sh` (create).

- [ ] **Step 1: Write the failing test (fake docker)**

```bash
#!/usr/bin/env bash
# compose-kind 라우팅: no-arg 가드, bare 인자 거부, config 단계 env 주입, -f overlay, 서비스별 stop, live ps 포트.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$*" in
  "compose version --short") echo "2.40.3" ;;
  info) exit 0 ;;
  *"config --format json"*) echo "APP_ENV_AT_CONFIG=${APP_ENV:-MISSING}" >> "$DOCKER_LOG"; cat "$DOCKER_CONFIG_FIXTURE" ;;
  *"ps --format json"*) cat "$DOCKER_PS_FIXTURE" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log" DOCKER_CONFIG_FIXTURE="$TMP/cfg.json" DOCKER_PS_FIXTURE="$TMP/ps.json"; : > "$DOCKER_LOG"
cat > "$TMP/cfg.json" <<'JSON'
{"services":{
  "web":{"image":"nginx","ports":[{"target":80,"published":"3000","protocol":"tcp"}]},
  "be":{"image":"temurin","ports":[{"target":8081,"published":"8081","protocol":"tcp"}]}
}}
JSON
cat > "$TMP/ps.json" <<'JSON'
[{"Service":"web","Publishers":[{"URL":"127.0.0.1","TargetPort":80,"PublishedPort":55001,"Protocol":"tcp"}]}]
JSON

P="$TMP/proj"; mkdir -p "$P"; cp "$TMP/cfg.json" "$P/docker-compose.yml"
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default local >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" \
  DOCKER_LOG="$DOCKER_LOG" DOCKER_CONFIG_FIXTURE="$DOCKER_CONFIG_FIXTURE" DOCKER_PS_FIXTURE="$DOCKER_PS_FIXTURE" bash "$SH" "$@"); }

# no-arg 가드
if mrun start >/dev/null 2>&1; then echo "FAIL: no-arg start should guard"; exit 1; fi
# bare positional 거부 (전체 안 띄움)
: > "$DOCKER_LOG"
if mrun start web >/dev/null 2>&1; then echo "FAIL: bare positional should error"; exit 1; fi
grep -q "up -d" "$DOCKER_LOG" && { echo "FAIL: bad arg leaked to up"; exit 1; } || true

# start --all → overlay 생성 + up + env at config
: > "$DOCKER_LOG"; mrun start --all >/dev/null
grep -q "compose .*up -d --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: up not routed"; cat "$DOCKER_LOG"; exit 1; }
grep -q -- "-p proj-main" "$DOCKER_LOG" || { echo "FAIL: project name"; exit 1; }
grep -q "APP_ENV_AT_CONFIG=local" "$DOCKER_LOG" || { echo "FAIL: env not at config (P1)"; cat "$DOCKER_LOG"; exit 1; }
SD="$P/.workspace/marina/main"
grep -q '!override' "$SD/marina-overlay.yml" || { echo "FAIL: overlay missing !override"; cat "$SD/marina-overlay.yml"; exit 1; }
grep -q '127.0.0.1::80' "$SD/marina-overlay.yml" || { echo "FAIL: overlay localhost target"; exit 1; }
grep -q -- "-f $SD/marina-overlay.yml" "$DOCKER_LOG" || { echo "FAIL: overlay not passed to up"; exit 1; }

# ports → live ps 파싱
mrun ports 2>/dev/null | grep -q "web=55001" || { echo "FAIL: live ps ports"; exit 1; }

# stop --web → stop web (down 아님)
: > "$DOCKER_LOG"; mrun stop --web >/dev/null
grep -q "compose -p proj-main stop web" "$DOCKER_LOG" || { echo "FAIL: per-svc stop"; cat "$DOCKER_LOG"; exit 1; }
grep -q "down --remove-orphans" "$DOCKER_LOG" && { echo "FAIL: per-svc stop did down"; exit 1; } || true
# stop --all → down
: > "$DOCKER_LOG"; mrun stop --all >/dev/null
grep -q "compose -p proj-main down --remove-orphans" "$DOCKER_LOG" || { echo "FAIL: stop --all not down"; exit 1; }
echo "PASS test-compose-dispatch"
```

- [ ] **Step 2: Run → fails** (native path; no compose routing): `bash plugin/tests/test-compose-dispatch.sh`

- [ ] **Step 3: Add `project_meta`/`project_kind`** (after `merged_services_json`, ~marina.sh:312) — matching mirrors `merged_services_json` so kind classification == service-resolution project:

```bash
# 해석된 프로젝트의 메타: id·kind·composeFile·composeEnvVar·composeEnvDefault (JSON). 매칭은 merged_services_json 과 동일.
project_meta() {
  command -v python3 >/dev/null 2>&1 || { echo '{}'; return 0; }
  [[ -f "$PROJECTS_FILE" ]] || { echo '{}'; return 0; }
  python3 - "$PROJECTS_FILE" "$ROOT" "$SOURCE_ROOT" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("{}"); sys.exit(0)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
source = os.path.realpath(os.path.expanduser(sys.argv[3]))
norm = lambda p: os.path.realpath(os.path.expanduser(p.get("root", "")))
tgt = {root, source}
match = None
for p in data.get("projects", []):
    pr = norm(p)
    if pr in tgt or any(t == pr or t.startswith(pr + os.sep) for t in tgt):
        match = p; break
if match is None:
    print("{}"); sys.exit(0)
print(json.dumps({
    "id": match.get("id", ""),
    "kind": match.get("kind", "native"),
    "composeFile": match.get("composeFile", "docker-compose.yml"),
    "composeEnvVar": match.get("composeEnvVar", ""),
    "composeEnvDefault": match.get("composeEnvDefault", "local"),
}, ensure_ascii=False))
PY
}

project_kind() {
  project_meta | python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("kind","native"))' 2>/dev/null || echo native
}
```

- [ ] **Step 4: Add `compose_main`** (just before `main()`, ~marina.sh:1273)

```bash
# compose-kind 실행 동사 위임. native 경로는 건드리지 않는다.
compose_main() {
  local command="$1"; shift || true

  # no-arg 가드(네이티브와 동일 취지) — docker 유무 전에 인자 실수부터.
  case "$command" in
    start|stop|restart)
      [[ $# -gt 0 ]] || { echo "usage: marina $command <--service..|--all>   (전체 스택은 --all)" >&2; exit 2; } ;;
  esac

  command -v docker >/dev/null 2>&1 || die "compose-kind 엔 docker 필요 — 설치·기동 후 다시. (native 무영향)"
  if [[ "$command" == "start" || "$command" == "restart" ]]; then
    docker info >/dev/null 2>&1 || die "docker 데몬 미가동 (docker info 실패) — 기동 후 다시."
    local ver; ver="$(docker compose version --short 2>/dev/null || true)"
    if [[ -n "$ver" && "$(printf '2.24.4\n%s\n' "$ver" | sort -V | head -n1)" != "2.24.4" ]]; then
      die "compose-kind 는 docker compose 2.24.4+ 필요(!override) — 현재 $ver. 업그레이드 후 다시."
    fi
  fi

  local meta pid cfile envvar envdef
  meta="$(project_meta)"
  pid="$(printf '%s' "$meta"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')"
  cfile="$(printf '%s' "$meta"  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composeFile") or "docker-compose.yml")')"
  envvar="$(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composeEnvVar") or "")')"
  envdef="$(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("composeEnvDefault") or "local")')"
  [[ -n "$pid" ]] || die "compose: 프로젝트 id 해석 실패"
  local stored="$MARINA_HOME/$pid/$cfile" sd sid cp
  sd="$(session_dir)"; sid="$(session_id)"; cp="$SCRIPT_DIR/marina-compose.py"
  local -a nameargs=(--project-id "$pid" --session "$sid")

  case "$command" in
    start|stop|restart)
      [[ -f "$stored" ]] || die "compose 파일 없음: $stored  (marina project add --compose <file> 로 등록)"
      local -a svcs=() envargs=() a
      for a in "$@"; do
        case "$a" in
          --all) ;;
          --*)   svcs+=("--service=${a#--}") ;;
          *)     die "compose: 알 수 없는 인자 '$a' (서비스는 --<name>, 전체는 --all)" ;;
        esac
      done
      [[ -n "$envvar" ]] && envargs+=("--env=$envvar=${MARINA_COMPOSE_ENV:-$envdef}")
      mkdir -p "$sd"
      case "$command" in
        start)
          python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" \
            ${svcs[@]+"${svcs[@]}"} ${envargs[@]+"${envargs[@]}"} ;;
        stop)
          if [[ ${#svcs[@]} -gt 0 ]]; then python3 "$cp" stop "${nameargs[@]}" "${svcs[@]}"
          else python3 "$cp" down "${nameargs[@]}"; fi ;;        # --all → 전체 teardown
        restart)
          if [[ ${#svcs[@]} -gt 0 ]]; then python3 "$cp" restart "${nameargs[@]}" "${svcs[@]}"
          else
            python3 "$cp" down "${nameargs[@]}"
            python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" ${envargs[@]+"${envargs[@]}"}
          fi ;;
      esac ;;
    status)  python3 "$cp" status "${nameargs[@]}" ;;
    ports)   python3 "$cp" status "${nameargs[@]}" --ports-only ;;
    logs)
      local -a lsvc=(); [[ -n "${1:-}" ]] && lsvc+=("--service=$1")
      python3 "$cp" logs "${nameargs[@]}" ${lsvc[@]+"${lsvc[@]}"} ;;
    *) die "compose: 미지원 명령 $command" ;;
  esac
}
```

- [ ] **Step 5: Branch `main()`** — after `shift || true` (marina.sh:1276), before `case "$command"`:

```bash
  # compose-kind: 실행 동사만 compose 핸들러로 위임. status-all/foreground/print-*/config/override/project/service 는 native.
  case "$command" in
    start|stop|restart|status|logs|ports)
      if [[ "$(project_kind)" == "compose" ]]; then
        compose_main "$command" "$@"
        return $?
      fi
      ;;
  esac
```

(`status-all` deliberately not delegated — cross-worktree native scan; compose-aware variant is future work.)

- [ ] **Step 6: Run → passes**: `bash plugin/tests/test-compose-dispatch.sh` → `PASS test-compose-dispatch`

- [ ] **Step 7: Commit**

```bash
git add plugin/scripts/marina.sh plugin/tests/test-compose-dispatch.sh
git commit -m "feat(compose): marina.sh routes execution verbs to compose handler (overlay up, label lifecycle)"
```

---

## Phase 4 — No-regression + real-docker validation

### Task 4.1: Native-kind unaffected (no-regression)

**Files:** Test `plugin/tests/test-compose-native-fallback.sh` (create).

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# native-kind 프로젝트는 compose 코드 영향 0: docker 미호출 + 네이티브 start 동작.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "DOCKER-CALLED $*" >> "$DOCKER_LOG"; exit 0
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"echo","portBase":4555,"cwd":".","run":"exec sleep 30"}]}
JSON
bash "$SH" project add "$P" >/dev/null    # --compose 없음 → native
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" PATH="$TMP/bin:$PATH" DOCKER_LOG="$DOCKER_LOG" bash "$SH" "$@"); }
mrun start --echo >/dev/null
[[ -f "$P/.workspace/marina/main/echo.pid" ]] || { echo "FAIL: native pid missing"; exit 1; }
[[ ! -s "$DOCKER_LOG" ]] || { echo "FAIL: native path touched docker"; cat "$DOCKER_LOG"; exit 1; }
mrun stop --echo >/dev/null
echo "PASS test-compose-native-fallback"
```

- [ ] **Step 2: Run** → `PASS`. **Step 3: Commit** — `git commit -am "test(compose): native-kind unaffected (no-regression)"`

### Task 4.2: Real `docker compose config` → overlay (gated on binary, no daemon)

Proves P1/P2 against the real CLI without a daemon.

**Files:** Test `plugin/tests/test-compose-config.sh` (create).

- [ ] **Step 1: Write the gated test**

```bash
#!/usr/bin/env bash
# 실 `docker compose config` (데몬 불요): services=map, ports 객체(published 문자열), ${VAR} 보간, bind 절대경로.
# 그 결과로 build_overlay 가 !override 127.0.0.1::<target> 를 뽑는지까지.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || { echo "SKIP test-compose-config (docker compose 미설치)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"; : > "$TMP/src/marker"
cat > "$TMP/docker-compose.yml" <<'YML'
services:
  web:
    image: "img-${APP_ENV:?APP_ENV required}"
    ports: ["3000:80"]
    volumes: ["./src:/app"]
YML
python3 - "$CP" "$TMP/docker-compose.yml" "$TMP" <<'PY'
import importlib.util, json, os, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
env=dict(os.environ); env["APP_ENV"]="local"
cfg=mc.docker_config_json(sys.argv[2], sys.argv[3], "proj-test", env)   # raise 시 = P1 위반
w=cfg["services"]["web"]
assert isinstance(cfg["services"], dict)                                # map
p=w["ports"][0]; assert isinstance(p, dict) and isinstance(p["published"], str)  # 객체, published 문자열
assert w["image"]=="img-local", w["image"]                             # ${APP_ENV} 보간
vols=w.get("volumes",[])
src=lambda v: v.get("source","") if isinstance(v,dict) else str(v)
assert any(src(v).startswith(sys.argv[3]) for v in vols), vols          # bind 절대경로
ov=mc.build_overlay(cfg)
assert "!override" in ov and "127.0.0.1::80" in ov, ov                  # overlay 정확
print("ok config shape + interpolation + abspath + overlay")
PY
echo "PASS test-compose-config"
```

- [ ] **Step 2: Run** → `PASS` (or `SKIP`). If only the volumes-abspath assertion trips on a different Compose volume form, relax that one line; the load-bearing checks are map/ports-object/`published`-string/interpolation/overlay.
- [ ] **Step 3: Commit** — `git commit -am "test(compose): real docker compose config + overlay (gated, no daemon)"`

### Task 4.3: Real-docker E2E smoke (gated on daemon)

**Files:** Test `plugin/tests/test-compose-e2e.sh` (create).

- [ ] **Step 1: Write the gated E2E test**

```bash
#!/usr/bin/env bash
# 실 docker E2E: up → Docker 할당 포트를 marina ports 로 읽음 → 127.0.0.1 도달 → down. 데몬 없으면 SKIP.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-e2e (docker 데몬 미가용)"; exit 0; }
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YML'
services:
  web:
    image: "python:3-alpine"
    command: ["sh","-c","echo $APP_ENV && python -m http.server 8000"]
    ports: ["8000:8000"]
    environment: ["APP_ENV"]
YML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default e2elocal >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
cleanup() { mrun stop --all >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
mrun start --all
port="$(mrun ports 2>/dev/null | awk -F= '/^web=/{print $2}')"   # docker 가 할당한 호스트포트
[[ -n "$port" ]] || { echo "FAIL: no web port from marina ports"; exit 1; }
ok=false
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1 && { ok=true; break; }; sleep 0.5; done
[[ "$ok" == true ]] || { echo "FAIL: not reachable on 127.0.0.1:$port"; mrun logs web 2>/dev/null | tail -20 || true; exit 1; }
mrun stop --all
echo "PASS test-compose-e2e"
```

- [ ] **Step 2: Run** → `PASS` (docker) / `SKIP`. **Step 3: Commit** — `git commit -am "test(compose): real-docker E2E (docker-assigned port via marina ports, localhost; gated)"`

### Task 4.4: Full suite + README

- [ ] **Step 1: Run the whole suite**: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done` — all `PASS`/`SKIP`, no `FAIL`.
- [ ] **Step 2: README** — append compose-kind section: registration (`marina project add <path> --compose <file> [--env-var NAME --env-default VAL]`); compose copied into `~/.marina/<id>/` (app repo clean); `start/stop/status/logs` on the worktree's isolated stack; inter-service via container DNS; **host ports auto-assigned by Docker — see them with `marina ports`** (they change on restart); access via dashboard `↗`; docker (≥2.24.4) required only for compose-kind; v1 limits (single ports only; no `container_name`/`network_mode: host`; profiles via `COMPOSE_PROFILES`).
- [ ] **Step 3: Commit** — `git commit -am "docs(readme): compose-kind registration + execution"`

---

## Self-review

| Item | Covered by |
|------|-----------|
| ② isolated execution (`-p`, `--project-directory`, `-f overlay`) | `up_argv` (2.1); 3.2 asserts `-p proj-main`, `-f overlay` |
| ② host ports — Docker-assigned, localhost, read live | `build_overlay` `127.0.0.1::<target>` (2.2); `_show_ports`/`cmd_status` via `parse_ps_ports` (3.1); E2E reads via `marina ports` (4.3) |
| ② env before config (P1) | `cmd_up` (3.1); 3.2 asserts `APP_ENV_AT_CONFIG=local`; 4.2 real interpolation |
| ② `!override` replaces (not appends) ports (P2) | `build_overlay` (2.1/2.2); 4.2 real overlay |
| ③ start/stop/restart/status/logs/ports; per-service vs whole-stack; label lifecycle (P7); `--remove-orphans` (P8) | `compose_main` + subcommands; 3.2 asserts per-svc stop vs `down` |
| ① store/register, import=copy | 1.1 |
| inter-service DNS, zero injection | container target untouched (2.2) |
| localhost-only (P4) | `127.0.0.1::` (2.2); E2E hits 127.0.0.1 (4.3) |
| docker missing/old/daemon-down → clear msg; native unaffected | `compose_main` checks (3.2); 4.1 |
| reject `container_name`/`network_mode:host` (P5); ranges (P6) | `isolation_breakers`/`_port_targets` (2.1), asserted (2.2) |
| no persisted port/resolved state (P9) | only `marina-overlay.yml` written; ports via live `ps` |
| isolated mktemp fixtures; docker tests gated | all tests; 4.2 binary-gated, 4.3 daemon-gated |

**Placeholders:** none. **Names consistent:** `compose_project_name`, `isolation_breakers`, `build_overlay`, `parse_ps_ports`, `up_argv`, `label_argv`, artifact `marina-overlay.yml`, registry keys `kind`/`composeFile`/`composeEnvVar`/`composeEnvDefault`, CLI flags (`--stored --project-dir --project-id --session --session-dir --service --env --ports-only --no-follow`) — used identically across module, `compose_main`, and tests.

---

## Resolved decisions (were open questions)

- **Port injection = `!override` overlay** (not resolve-and-rewrite). No full resolved config persisted → **no secrets on disk**. Requires Compose ≥2.24.4 (checked in `compose_main`).
- **Host ports = Docker-assigned (ephemeral), not computed/recorded.** Removes free-port probing + cross-worktree collision handling. Read live via `docker compose ps`. Trade-off: ports change on `down`/`up` (fine — access via dashboard `↗`).
- **Localhost-only** binding (`127.0.0.1::`).
- **`restart --<svc>` = `docker compose restart <svc>`** (quick bounce of the existing container, **does not** re-read the stored compose). To apply a changed compose to one service use `start --<svc>` (`up` recreates if changed); `restart --all` does `down`+`up` (full recreate). Documented in README.

## Follow-on plans (outline)

- **Plan B — Dashboard (④):** in `marina-control.py` `session_payload`, when kind==compose, derive services + host ports from `docker compose -p <name> ps --format json` (reuse `parse_ps_ports` logic), health from container state. `INDEX_HTML`: reuse `makeSvcRow` + `HEALTH_PILLS`; `#openWeb ↗` → live web host port. Verify on `marina-preview` (:3901).
- **Plan C — Rich registration (rest of ①):** import-existing vs author-new; edit/replace; re-import on change; dashboard UI.
- **Plan D — LLM starter (⑤):** extend `/api/llm-analyze` to draft a dev compose → human review → store via Plan C.
- **Parking (spec):** reverse proxy, prod orchestration, subrepo-compose auto-merge.

## Design history

- **rev 1:** initial — port remap (`published+offset`) via resolve-and-rewrite.
- **rev 2 (codex round 1):** env-before-config; free-host-port probe; range reject; no-arg guard; label fallback; `host_ip:127.0.0.1`; drop `status-all`; `--remove-orphans`; reject isolation breakers.
- **rev 3 (codex round 2):** strict arg handling; per-service stop/restart; allocate cap; host-aware probe; `project_meta` mirrors `merged_services_json`.
- **rev 4 (owner direction):** dropped offset/remap/free-probe/resolved-file entirely → **`!override` overlay + Docker-assigned ports + live `ps` (no recording)**. Simpler, no secrets on disk, removes the whole port-collision bug class. Two questions from 형 drove this: "override가 나아 보인다" + "포트포워딩만 하면 되는 거 아냐 / marina가 기록할 필요 있나?".
- **rev 5 (codex round 4):** blocker fix — `build_overlay` now overrides **every** `ports[]` entry (Compose emits auto-host-port publishes *without* a `published` field; only `expose` is truly internal). Without this, a `ports: ["8000"]` would leak on `0.0.0.0` or be dropped in a mixed service. Nits: `parse_ps_ports` casts `PublishedPort` to int + dedups across replicas; documented `restart --<svc>` = quick bounce (no config refresh).

## Workflow reminders

- TDD, isolated mktemp fixtures; real-docker tests gated (`docker compose version` for config, `docker info` for E2E).
- Conventional Commits; **no** `Co-Authored-By` / `Task` trailers.
- All push/deploy require the owner's (형) approval.
- Preview (:3901) only for dashboard UI (Plan B, not this plan).
