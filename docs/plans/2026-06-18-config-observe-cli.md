# `marina config` — 워크트리 override(env·ports) + 관측 CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 워크트리별 `overrides.json`으로 서비스 env·port를 per-key override하고, `marina config <svc>`가 effective 값을 **출처(provenance) + 무엇을 덮었는지** 까지 보여준다.

**Architecture:** 스펙 `2026-06-18-worktree-env-override-observability-design.md`의 첫 수직 슬라이스. 관측이 실제와 일치하도록 override 적용(env·ports)과 관측 CLI를 함께 만든다. `links`와 대시보드는 후속 슬라이스. 전부 `marina.sh`(shell + 인라인 python), 테스트는 격리 mktemp fixture.

**Tech Stack:** bash, 인라인 python3, marina 기존 패턴(`service_env_raw`·`port_for`·`config_value`·`subst_tokens`·`redact_stream`).

---

## 핵심 모델 (이 슬라이스 한정)

- **overrides.json** (세션 폴더, 이 워크트리만), 서비스명으로 키잉:
  ```json
  {
    "version": 1,
    "env":   { "search": { "BE_API_URL": "http://host:9000", "LOG_LEVEL": null } },
    "ports": { "be": 8412 }
  }
  ```
  `null` = 그 key 해제(env unset / port는 무시).
- **precedence**:
  - env: `base def.env` ＜ `overrides.json.env[svc]` (per-key; null=unset).
  - port: `default(portBase+offset)` ＜ `overrides.env(SERVICE_PORT_*, auto-pin)` ＜ `overrides.json.ports[svc]`.
- **provenance**: key마다 이긴 출처 위치 + 덮인 직전값/출처.

## File Structure

- **Modify** `plugin/scripts/marina.sh`:
  - `overrides_json_file()` (신규 helper) — 세션 폴더 경로.
  - `service_env_raw()` (~L861) — base env ∪ `overrides.json.env[svc]` per-key 머지(null=drop) emit.
  - `port_for()` (~L587) — `overrides.json.ports[svc]`를 최우선으로.
  - `config)` 명령 (dispatch ~L1112 근처) — effective env·ports + provenance 출력.
  - `config_observe_raw()` (신규 helper) — provenance TSV emit.
- **Create** `plugin/tests/test-config-observe.sh` — 격리 fixture, override·provenance·null·공존·무회귀 검증.

---

### Task 1: env per-worktree override 적용 (`overrides.json.env`)

**Files:**
- Modify: `plugin/scripts/marina.sh` (`service_env_raw` ~L861, 신규 `overrides_json_file`)
- Test: `plugin/tests/test-config-observe.sh`

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-config-observe.sh` 생성

```bash
#!/usr/bin/env bash
# marina config / overrides.json: 워크트리 env·port override + 관측.
# 격리: mktemp 임시 프로젝트 + fake 서비스만 — 라이브 config 안 읽음.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[
  {"name":"be","portBase":8081,"cwd":".","run":"exec sleep 30"},
  {"name":"search","portBase":8002,"cwd":".","run":"exec sleep 30","env":{"BE_API_URL":"http://localhost:{be_port}","LOG_LEVEL":"info"}}
]}
JSON
bash "$SH" project add "$P" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }

# overrides.json: env override(BE_API_URL) + null 해제(LOG_LEVEL) + port override(be)
SDIR="$(mrun print-session-dir)"; mkdir -p "$SDIR"
cat > "$SDIR/overrides.json" <<'JSON'
{"version":1,"env":{"search":{"BE_API_URL":"http://host:9000","LOG_LEVEL":null}},"ports":{"be":8412}}
JSON

# 1) env override 적용 — print-env 가 override 값을 보여줌
out="$(mrun print-env search)"
case "$out" in *"BE_API_URL=http://host:9000"*) ;; *) echo "FAIL: env override not applied: [$out]"; exit 1;; esac
# 2) null 해제 — LOG_LEVEL 키 자체가 사라짐
case "$out" in *"LOG_LEVEL="*) echo "FAIL: nulled key still present: [$out]"; exit 1;; *) ;; esac

echo "PASS test-config-observe (task1)"
```

- [ ] **Step 2: 실패 확인** — `print-session-dir`/override 미구현으로 FAIL

Run: `bash plugin/tests/test-config-observe.sh`
Expected: FAIL (print-session-dir 없거나 override 미적용)

- [ ] **Step 3: 구현** — `marina.sh`에 helper + 디버그 명령 + env 머지

`session_dir`를 노출하는 디버그 명령(`print-session-dir`)을 dispatch에 추가(`print-env` 옆):
```bash
    print-session-dir)
      session_dir
      ;;
```
신규 helper (config_file 정의 근처):
```bash
overrides_json_file() {
  echo "$(session_dir)/overrides.json"
}
```
`service_env_raw`를 base ∪ overrides.json 머지로 교체:
```bash
service_env_raw() {
  local service="$1" _merged _ovr
  _merged="$(merged_services_json)"
  _ovr="$(overrides_json_file)"
  python3 - "$_merged" "$service" "$_ovr" <<'PY'
import json, sys, os
data = json.loads(sys.argv[1]); service = sys.argv[2]; ovr_path = sys.argv[3]
svc = next((s for s in data.get("services", []) if s.get("name") == service), None)
env = dict(((svc or {}).get("env") or {}))
try:
    ov = json.load(open(ovr_path, encoding="utf-8"))
    oenv = (ov.get("env") or {}).get(service) or {}
except Exception:
    oenv = {}
if isinstance(oenv, dict):
    for k, v in oenv.items():
        if not isinstance(k, str):
            continue
        if v is None:
            env.pop(k, None)          # null = 해제
        elif isinstance(v, str):
            env[k] = v                # per-key override
for k, v in env.items():
    if isinstance(k, str) and isinstance(v, str):
        sys.stdout.write(k + "\t" + v + "\n")
PY
}
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-config-observe.sh`
Expected: `PASS test-config-observe (task1)`

- [ ] **Step 5: 회귀 — 기존 env 테스트**

Run: `bash plugin/tests/test-service-env.sh`
Expected: `PASS test-service-env`

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina.sh plugin/tests/test-config-observe.sh
git commit -m "feat(plugin): overrides.json env per-worktree override (per-key, null=해제)"
```

---

### Task 2: port per-worktree override 적용 (`overrides.json.ports`)

**Files:**
- Modify: `plugin/scripts/marina.sh` (`port_for` ~L587)
- Test: `plugin/tests/test-config-observe.sh`

- [ ] **Step 1: 실패 테스트 추가** — test 파일의 `echo "PASS...(task1)"` 앞에 삽입

```bash
# 3) port override 적용 — be 가 overrides.json 값(8412)을 씀 (offset 0, default 8081)
case "$(mrun ports)" in *"be=8412"*) ;; *) echo "FAIL: port override not applied: [$(mrun ports)]"; exit 1;; esac
# 4) override 없는 포트는 default 유지
case "$(mrun ports)" in *"search=8002"*) ;; *) echo "FAIL: non-overridden port changed"; exit 1;; esac
# 5) env 토큰이 override된 형제 포트를 반영 ({be_port}→8412)
case "$(mrun print-env search)" in *"BE_API_URL=http://host:9000"*) ;; *) echo "FAIL: env override regressed"; exit 1;; esac
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-config-observe.sh`
Expected: FAIL (`be=8081` — override 미적용)

- [ ] **Step 3: 구현** — `port_for`가 overrides.json을 최우선으로

```bash
port_for() {
  local service="$1" offset="$2"
  if [[ "${MARINA_IGNORE_PORT_OVERRIDES:-0}" == "1" ]]; then
    default_port_for "$service" "$offset"
    return 0
  fi
  local ovr; ovr="$(overrides_json_port "$service")"
  if [[ -n "$ovr" ]]; then echo "$ovr"; return 0; fi
  config_value "SERVICE_PORT_$(upper_service "$service")" "$(default_port_for "$service" "$offset")"
}

# overrides.json 의 ports[service] (정수) — 없으면 빈 문자열
overrides_json_port() {
  local service="$1" _ovr; _ovr="$(overrides_json_file)"
  [[ -f "$_ovr" ]] || return 0
  python3 - "$_ovr" "$service" <<'PY'
import json, sys
try:
    ov = json.load(open(sys.argv[1], encoding="utf-8"))
    p = (ov.get("ports") or {}).get(sys.argv[2])
    if isinstance(p, int) and not isinstance(p, bool):
        print(p, end="")
except Exception:
    pass
PY
}
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-config-observe.sh`
Expected: `PASS test-config-observe (task1)` (task2 assertion 포함 통과)

- [ ] **Step 5: 회귀**

Run: `bash plugin/tests/test-service-env.sh && bash plugin/tests/test-resolve.sh`
Expected: 둘 다 PASS

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina.sh plugin/tests/test-config-observe.sh
git commit -m "feat(plugin): overrides.json port per-worktree override (over auto-pin/default)"
```

---

### Task 3: `marina config <svc>` — provenance 관측

**Files:**
- Modify: `plugin/scripts/marina.sh` (신규 `config_observe_raw`, `config)` 명령)
- Test: `plugin/tests/test-config-observe.sh`

- [ ] **Step 1: 실패 테스트 추가** — `echo "PASS..."` 앞에 삽입

```bash
# 6) marina config: env override 출처 + 덮인 값 노출
cfg="$(mrun config search)"
case "$cfg" in *"BE_API_URL"*"override"*"overrides.json"*) ;; *) echo "FAIL: env override provenance missing: [$cfg]"; exit 1;; esac
case "$cfg" in *"덮음"*"http://localhost:8412"*) ;; *) echo "FAIL: shadowed base value missing"; exit 1;; esac
# 7) port override 출처
case "$cfg" in *"be"*"8412"*"override"*) ;; *) echo "FAIL: port override provenance missing"; exit 1;; esac
# 8) 시크릿 redaction — TOKEN 값 마스킹
cat > "$SDIR/overrides.json" <<'JSON'
{"version":1,"env":{"search":{"API_TOKEN":"supersecretvalue"}}}
JSON
case "$(mrun config search)" in *"supersecretvalue"*) echo "FAIL: secret not redacted"; exit 1;; *) ;; esac
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-config-observe.sh`
Expected: FAIL (`unknown command: config`)

- [ ] **Step 3: 구현** — provenance accessor + 명령

`config_observe_raw` helper (provenance TSV: `kind`\t`key`\t`winSrc`\t`winRaw`\t`shadowSrc`\t`shadowRaw`):
```bash
# kind(env|port) TSV provenance emit. env winRaw 는 치환 전(호출부가 subst_tokens). port 는 최종 정수.
config_observe_raw() {
  local service="$1" offset="$2" _merged _ovr default_be
  _merged="$(merged_services_json)"
  _ovr="$(overrides_json_file)"
  python3 - "$_merged" "$service" "$_ovr" <<'PY'
import json, sys
data = json.loads(sys.argv[1]); service = sys.argv[2]; ovr_path = sys.argv[3]
svc = next((s for s in data.get("services", []) if s.get("name") == service), None) or {}
base_src = "서비스 def(%s)" % (svc.get("source") or "root")
try:
    ov = json.load(open(ovr_path, encoding="utf-8"))
except Exception:
    ov = {}
def emit(kind, key, ws, wv, ss="", sv=""):
    sys.stdout.write("\t".join([kind, key, ws, str(wv), ss, str(sv)]) + "\n")
# env
base_env = dict((svc.get("env") or {}))
oenv = (ov.get("env") or {}).get(service) or {}
for k in list(base_env.keys()) + [k for k in oenv if k not in base_env]:
    if k in oenv:
        v = oenv[k]
        if v is None:
            emit("env", k, "해제 · overrides.json", "(unset)", base_src, base_env.get(k, ""))
        else:
            emit("env", k, "override · overrides.json", v, base_src, base_env.get(k, ""))
    else:
        emit("env", k, "base · " + base_src, base_env[k])
PY
}
```
`config)` 명령 (dispatch에 `print-env` 옆 추가) — env 토큰 치환 + 포트 레이어 + 포맷, 전체 redact:
```bash
    config)
      local svc="${1:-${SERVICES[0]:-}}"
      [[ -n "$svc" ]] || die "config: service name required"
      offset="$(port_offset)"
      {
        echo "service: $svc   worktree: $(session_id)"
        echo "env"
        local kind key ws wv ss sv
        while IFS=$'\t' read -r kind key ws wv ss sv; do
          [[ "$kind" == "env" ]] || continue
          if [[ "$wv" != "(unset)" ]]; then wv="$(subst_tokens "$wv" "$svc" "$offset")"; fi
          [[ -n "$sv" ]] && sv="$(subst_tokens "$sv" "$svc" "$offset")"
          printf '  %s = %s   [%s]\n' "$key" "$wv" "$ws"
          [[ -n "$sv" ]] && printf '      ↑ 덮음  %s  ·  %s\n' "$sv" "$ss"
        done < <(config_observe_raw "$svc" "$offset")
        echo "ports"
        local p_default p_auto p_ovr p_win p_src p_sh_v p_sh_s
        for s in ${SERVICES[@]+"${SERVICES[@]}"}; do
          p_default="$(default_port_for "$s" "$offset")"
          p_auto="$(config_value "SERVICE_PORT_$(upper_service "$s")" "")"
          p_ovr="$(overrides_json_port "$s")"
          if [[ -n "$p_ovr" ]]; then
            p_win="$p_ovr"; p_src="override · overrides.json"
            if [[ -n "$p_auto" ]]; then p_sh_v="$p_auto"; p_sh_s="auto-pin · overrides.env"; else p_sh_v="$p_default"; p_sh_s="portBase"; fi
          elif [[ -n "$p_auto" ]]; then
            p_win="$p_auto"; p_src="auto-pin · overrides.env"; p_sh_v="$p_default"; p_sh_s="portBase"
          else
            p_win="$p_default"; p_src="base · portBase"; p_sh_v=""; p_sh_s=""
          fi
          printf '  %s = %s   [%s]\n' "$s" "$p_win" "$p_src"
          [[ -n "$p_sh_v" ]] && printf '      ↑ 덮음  %s  ·  %s\n' "$p_sh_v" "$p_sh_s"
        done
      } | redact_stream
      ;;
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-config-observe.sh`
Expected: `PASS test-config-observe (task1)` (모든 assertion 통과)

- [ ] **Step 5: 회귀 (전체 스위트 일부)**

Run: `bash plugin/tests/test-service-env.sh && bash plugin/tests/test-resolve.sh && bash plugin/tests/test-standard-cli.sh`
Expected: 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina.sh plugin/tests/test-config-observe.sh
git commit -m "feat(plugin): marina config <svc> — effective env·ports + 출처 체인 관측"
```

---

## Self-Review

**Spec coverage (이 슬라이스):** overrides.json(env·ports) per-key override ✓(T1·T2), null 해제 ✓(T1), provenance 이긴출처+덮인체인 ✓(T3), redaction ✓(T3), 무회귀 ✓(회귀 step). **이 슬라이스 밖(후속):** `links` 선언화·preserve(`_read_services_file`)·validate, 대시보드 뷰, `marina override set/unset` authoring CLI, app yaml 출처 추적.

**Placeholder scan:** 모든 step에 실제 코드/명령/기대출력 있음. TODO 없음.

**Type consistency:** `overrides_json_file`/`overrides_json_port`/`config_observe_raw` 명칭 T1–T3 일관. overrides.json 스키마(`env[svc][k]`, `ports[svc]`) T1·T2·T3 동일. `print-session-dir`(T1) 테스트가 T2·T3에서도 `$SDIR` 재사용.

**주의(실행 중 확인):** `config_observe_raw`의 env winRaw에 탭 포함 가능성 낮음(검증됨: 값 개행거부). port 섹션은 `SERVICES` 전체 순회(서비스 컨텍스트라 채워짐). redact_stream이 `↑ 덮음` 라인 시크릿도 마스킹.
