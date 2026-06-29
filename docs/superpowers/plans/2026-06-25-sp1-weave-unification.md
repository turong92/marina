# SP1 — 엮기 일원화 + 실검증 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 엮기(socat 사이드카)를 서버측 모든 localhost 라우팅의 *유일* 메커니즘으로 굳히고(서비스타겟 자동도출), 옛 service-redirect(파일패치·via=env·localhost 감지)를 엔진·API·UI 에서 전부 들어내고, 실 docker 로 PONG/200 검증한다.

**Architecture:** `cmd_up` 이 compose config 에서 `_auto_service_forward`(포트→서빙 서비스)를 도출하고 backing.json 의 명시 선언(`_normalize_forward`, host 타겟)을 그 위에 덮어 통합 `forward:{port:target}` 를 만든다. `build_overlay` 는 그 forward 로 앱 서비스마다 `<svc>-bind` socat 사이드카 1개만 렌더(extra_hosts/environment 주입 제거). 파일패치 경로(`_patch_config`·`_apply_connectivity`)와 그 저장/감지/UI 는 삭제.

**Tech Stack:** Python 3 stdlib only (`plugin/scripts/marina-compose.py`, `marina-control.py`), `alpine/socat`·`hashicorp/http-echo`·`redis:7-alpine`(e2e), Docker Compose v2, vanilla JS 프론트(`marina-web/`), bash 테스트(`importlib` 직접호출 + 실 docker). 실행: `bash plugin/tests/<name>.sh` → `PASS`. 전체: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done`. **codex 활용**: Task 3·4(기계적 cull)는 `codex exec` 위임 + `codex review`, 통합·검증은 내가.

**입력 SPEC:** `docs/superpowers/specs/2026-06-25-connectivity-finalization-design.md` (SP1 절).

---

## File Structure

| 파일 | 변경 | 태스크 |
|---|---|---|
| `plugin/scripts/marina-compose.py` | `_auto_service_forward` 추가; `cmd_up` 통합 forward; `build_overlay` extra_hosts/env 주입 제거; `_patch_config`·`_apply_connectivity` 삭제 | T1 |
| `plugin/tests/test-compose-overlay.sh` | service-redirect 어서션 삭제, `_normalize_forward`/`_auto_service_forward`/일원화 어서션으로 교체 | T1 |
| `plugin/tests/test-compose-weave-e2e.sh` | **신규** 실 docker e2e(PONG/200) | T2 |
| `plugin/scripts/marina-control.py` | `_scan_config_endpoints`·`_clean_compose_connectivity_endpoints`·`/api/compose-connectivity` 삭제, detect 흐름의 conn_eps 제거(hostForward·mounts 유지) | T3 |
| `plugin/tests/test-compose-connectivity-api.sh` | 삭제(API 없어짐) | T3 |
| `plugin/scripts/marina-web/app.js`·`index.html` | 연결 모달(cn-mode·cn-save·endpoint)·`/api/compose-connectivity` 호출 삭제; host-backing-port·mounts 유지 | T4 |

---

## Task 1: 엮기 엔진 일원화 (auto-derive + 파일패치 삭제)

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (add `_auto_service_forward`; `cmd_up` 466-479 + 500; `build_overlay` 184-189/225-231; delete `_patch_config` 279-296, `_apply_connectivity` 325-367)
- Modify: `plugin/tests/test-compose-overlay.sh` (68-125)

- [ ] **Step 1: 테스트 교체 (실패 유도)** — `test-compose-overlay.sh` 의 68-125행 전체를 아래로 교체:

```python
# 엮기 — _normalize_forward: backing.json forward 선언 → {port: target} (legacy hostForward 흡수)
assert mc._normalize_forward({"forward":{"8081":{"target":"be"},"6379":{"target":"host"}}})=={"8081":"be","6379":"host"}
assert mc._normalize_forward({"forward":{"8081":"be"}})=={"8081":"be"}                          # 축약형
assert mc._normalize_forward({"hostForward":["6379","3306"]})=={"6379":"host","3306":"host"}    # legacy top-level → host
assert mc._normalize_forward({"services":{"api":{"hostForward":["6379"]},"web":{"hostForward":["3306"]}}})=={"6379":"host","3306":"host"}  # legacy 서비스별
# 엮기 — _auto_service_forward: compose 가 서빙하는 포트 → 그 서비스 (자동 서비스타겟)
assert mc._auto_service_forward({"services":{"be":{"ports":[{"target":8081,"published":"8081"}]},"fe":{"ports":[{"target":3000}]},"redis":{"image":"r"}}})=={"8081":"be","3000":"fe"}
assert mc._auto_service_forward({"services":{}})=={}, "포트 서빙 서비스 없으면 빈"
# 엮기 사이드카 — forward(={port:target}) → 앱(build) 서비스마다 사이드카 1개. host=host.docker.internal. image-only 제외.
_ovf=mc.build_overlay({"services":{"api":{"build":{"context":"."}}, "cache":{"image":"redis"}}}, connectivity={"forward":{"6379":"host"}})
assert "api-bind:" in _ovf and "alpine/socat" in _ovf and 'network_mode: "service:api"' in _ovf, _ovf
assert "TCP-LISTEN:6379" in _ovf and "host.docker.internal" in _ovf, _ovf
assert "cache-bind" not in _ovf, "image-only 서비스는 사이드카 없음"
# service 타겟 — localhost:8081 → be:8081 (컨테이너 DNS)
_ovs=mc.build_overlay({"services":{"fe":{"build":{"context":"."}}, "be":{"build":{"context":"."},"ports":[{"target":8081,"published":"8081"}]}}}, connectivity={"forward":{"8081":"be"}})
assert "fe-bind:" in _ovs and "TCP:be:8081" in _ovs and "be-bind:" not in _ovs, _ovs   # be 는 8081 self-skip
# 일원화 — build_overlay 는 forward 만 본다(옛 service-redirect extraHosts/env 주입 제거)
_ovx=mc.build_overlay({"services":{"api":{"build":{"context":"."}}}}, connectivity={"forward":{"6379":"host"},"extraHosts":["api"],"env":{"api":{"X":"y"}}})
assert "extra_hosts" not in _ovx and "environment:" not in _ovx, _ovx
print("ok funcs")
```

- [ ] **Step 2: 실행 → 실패** — Run: `bash plugin/tests/test-compose-overlay.sh`. Expected: FAIL — `AttributeError: module 'mc' has no attribute '_auto_service_forward'`.

- [ ] **Step 3: `_auto_service_forward` 추가** — `marina-compose.py` 의 `_bind_script` 함수 끝(현재 173행, `return "\n".join(lines)` 다음 빈 줄)과 `def build_overlay(` 사이에 추가:

```python
def _auto_service_forward(config: dict) -> dict:
    """resolved compose config → {port(str): service}. 각 서비스가 퍼블리시하는 포트(_port_targets)를 그 서비스 DNS 타겟으로
    자동 매핑(localhost:8081 → be). 같은 포트 두 서비스면 경고 후 먼저(정렬) 것 사용(SPEC 동일포트 한계). 사람은 host 타겟만 선언."""
    out: dict = {}
    services = (config or {}).get("services") or {}
    for name in sorted(services):
        for port, _proto in _port_targets(services[name] or {}):
            p = str(port)
            if p in out and out[p] != name:
                sys.stderr.write(f"warning: 포트 {p} 를 여러 서비스({out[p]}·{name})가 서빙 — 엮기 자동타겟 모호, '{out[p]}' 사용. compose 에서 포트 분리 권장.\n")
                continue
            out[p] = name
    return out
```

- [ ] **Step 4: `build_overlay` 에서 extra_hosts/env 주입 제거** — 두 군데 수정.

(4a) docstring ⑥ (184-185행):
```python
    ⑥ 연결 주입(connectivity): 같은 compose 안 service redirect 의 via=env 호스트 변수 주입만 overlay 에 반영.
       (localhost→서비스명 치환은 patch-on-mount 가 patched 복사본을 mounts 로 넘김)
```
→
```python
    ⑥ 엮기(connectivity={forward:{port:target}}): 앱(build) 서비스마다 socat 사이드카 1개로 그 컨테이너의
       localhost:<port> 를 타겟(host=host.docker.internal / 서비스명=컨테이너 DNS)으로 중계. 자기 서빙 포트 제외.
```

(4b) `extra_hosts_svcs` 줄(189행) 삭제:
```python
    extra_hosts_svcs = set(connectivity.get("extraHosts") or [])   # ⑥ host 모드 — 컨테이너가 호스트(host.docker.internal)에 닿게
```
→ (삭제)

(4c) 서비스 body 루프 안 extra_hosts + conn_env 주입(225-231행) 삭제:
```python
        if name in extra_hosts_svcs:                       # ⑥ host 모드 — localhost→host.docker.internal 과 짝. 리눅스서도 호스트 닿게 host-gateway
            body.append('    extra_hosts: ["host.docker.internal:host-gateway"]')
        conn_env_svc = (connectivity.get("env") or {}).get(name) or {}   # ⑥ via=env redirect(host: ${REDIS.HOST} → REDIS.HOST=target). map 병합(키별 override)
        if conn_env_svc:
            body.append("    environment:")
            for k in sorted(conn_env_svc):
                body.append(f"      {json.dumps(str(k))}: {json.dumps(str(conn_env_svc[k]))}")
```
→ (삭제). 바로 다음 `if body:` 블록은 유지.

- [ ] **Step 5: `_patch_config`·`_apply_connectivity` 삭제** — `marina-compose.py` 279-296행(`def _patch_config(...)` 전체)과 325-367행(`def _apply_connectivity(...)` 전체) 삭제. `_normalize_forward`(299-322)는 **유지**.

- [ ] **Step 6: `cmd_up` 통합 forward 로 재배선** — 466-479행:
```python
    mounts = _parse_mounts(getattr(a, "mount", []))
    overlay_conn: dict = {}
    conn_path = getattr(a, "connectivity", None)                    # ⑥ service redirect 설정 — patched 복사본 생성 + overlay env
    if conn_path and os.path.exists(conn_path):
        try:
            conn = json.load(open(conn_path, encoding="utf-8"))
        except (ValueError, OSError) as e:
            sys.stderr.write(f"warning: connectivity({conn_path}) 읽기 실패 — 연결 주입 건너뜀: {e}\n")
            conn = {}
        extra_mounts, overlay_conn = _apply_connectivity(conn, a.project_dir, a.session_dir)
        for svc, ms in extra_mounts.items():
            mounts.setdefault(svc, []).extend(ms)                   # patched 복사본을 마운트로(기존 마운트 유지)
    try:
        overlay_text = build_overlay(config, build_args=_parse_build_args(getattr(a, "build_arg", [])),
                                     mounts=mounts, connectivity=overlay_conn)  # P2/P3/P4/P6 + build args + 마운트 + 연결주입
```
→
```python
    mounts = _parse_mounts(getattr(a, "mount", []))
    conn: dict = {}                                                 # 엮기 선언(backing.json): host 타겟 등 명시 forward
    conn_path = getattr(a, "connectivity", None)
    if conn_path and os.path.exists(conn_path):
        try:
            conn = json.load(open(conn_path, encoding="utf-8"))
        except (ValueError, OSError) as e:
            sys.stderr.write(f"warning: connectivity({conn_path}) 읽기 실패 — 엮기 선언 건너뜀: {e}\n")
            conn = {}
    forward = {**_auto_service_forward(config), **_normalize_forward(conn)}   # 자동 서비스타겟 + 명시 선언(명시 우선)
    overlay_conn = {"forward": forward}
    try:
        overlay_text = build_overlay(config, build_args=_parse_build_args(getattr(a, "build_arg", [])),
                                     mounts=mounts, connectivity=overlay_conn)  # P2/P3/P4 + build args + 마운트 + 엮기
```
(500행 `forward = overlay_conn.get("forward") or {}` 은 그대로 유지 — overlay_conn 에 forward 있음.)

- [ ] **Step 7: 실행 → 통과** — Run: `bash plugin/tests/test-compose-overlay.sh` → `PASS test-compose-overlay`. 그리고 전체: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done` → 모두 PASS/SKIP(이 시점엔 test-compose-connectivity-api.sh 도 아직 PASS).

- [ ] **Step 8: 커밋**
```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-overlay.sh
git commit -m "feat(conn): 엮기 일원화 — 서비스타겟 자동도출 + 파일패치 service-redirect 삭제

cmd_up 이 compose config 에서 _auto_service_forward(포트→서빙서비스) 도출, backing.json 명시
forward(_normalize_forward)를 위에 덮어 통합. build_overlay 는 forward 만(extra_hosts/env 주입 제거).
_patch_config·_apply_connectivity 삭제. 사람은 host 타겟만 선언, 서비스↔서비스는 자동."
```

---

## Task 2: 실 docker e2e — 엮기 워킹 검증 (PONG/200)

stage1+일원화 엮기가 실제 컨테이너에서 동작함을 증명: 앱의 `localhost:<be>` → be(서비스DNS, 자동도출), `localhost:<redis>` → host redis(host 타겟, 선언). 형 "환경변수 넣고 워킹" → `--env-var` 주입 + 실 트래픽.

**Files:** Create `plugin/tests/test-compose-weave-e2e.sh`

- [ ] **Step 1: e2e 작성** — `test-compose-weave-e2e.sh`:

```bash
#!/usr/bin/env bash
# 실 docker E2E: 엮기 일원화 — app(build) 가 localhost:8081→be(서비스DNS·자동도출), localhost:6399→host redis(host 타겟·선언).
# --env-var 주입까지. docker 없으면 SKIP. 자체 redis 를 호스트 6399 에 띄워(점유 6379 회피) 격리.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP test-compose-weave-e2e (docker 데몬 미가용)"; exit 0; }

export MARINA_HOME="$(mktemp -d)"; P="$(mktemp -d)"
RED=marina-weave-e2e-redis
cleanup(){ bash "$SH" --project-dir "$P" stop --all >/dev/null 2>&1 || true; docker rm -f "$RED" >/dev/null 2>&1 || true; rm -rf "$MARINA_HOME" "$P"; }
trap cleanup EXIT

docker run -d --rm --name "$RED" -p 127.0.0.1:6399:6379 redis:7-alpine >/dev/null   # host 공유 redis (6399)

cat > "$P/Dockerfile.app" <<'DOCK'
FROM alpine:3.20
RUN apk add --no-cache curl redis
CMD ["sleep","infinity"]
DOCK
cat > "$P/docker-compose.yml" <<'YML'
services:
  be:
    image: hashicorp/http-echo
    command: ["-text=BE-OK","-listen=:8081"]
    ports: ["8081:8081"]
  app:
    build: { context: ., dockerfile: Dockerfile.app }
    ports: ["7000:7000"]
YML

# 등록(--env-var APP_ENV 주입) + host 타겟 6399 선언(backing.json hostForward) + up
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" --env-var APP_ENV --env-default e2elocal >/dev/null
PID="$(bash "$SH" project ls 2>/dev/null | awk 'END{print $1}')"   # 방금 등록한 프로젝트 id
mkdir -p "$MARINA_HOME/$PID"; printf '{"version":1,"hostForward":["6399"]}' > "$MARINA_HOME/$PID/backing.json"
bash "$SH" --project-dir "$P" start --all >/dev/null 2>&1 || bash "$SH" --project-dir "$P" up --all >/dev/null 2>&1

# app 컨테이너 찾기
APPC="$(docker ps --format '{{.Names}}' | grep -E '(^|[-_])app([-_]|$)' | head -1)"
[ -n "$APPC" ] || { echo "FAIL: app 컨테이너 못 찾음"; docker ps; exit 1; }
sleep 2   # 사이드카·be 기동 대기

# 1) service 타겟 — app 의 localhost:8081 → be:8081 (socat→DNS) → BE-OK
out_be="$(docker exec "$APPC" sh -c 'curl -s --max-time 5 localhost:8081' 2>&1 || true)"
echo "$out_be" | grep -q "BE-OK" || { echo "FAIL: localhost:8081→be 안 됨: [$out_be]"; docker logs "${APPC%-app-*}-app-bind-1" 2>&1 | tail; exit 1; }

# 2) host 타겟 — app 의 localhost:6399 → host redis (socat→host.docker.internal) → PONG
out_rd="$(docker exec "$APPC" sh -c 'redis-cli -h localhost -p 6399 ping' 2>&1 || true)"
echo "$out_rd" | grep -qi "PONG" || { echo "FAIL: localhost:6399→host redis 안 됨: [$out_rd]"; exit 1; }

echo "PASS test-compose-weave-e2e (service=BE-OK, host=PONG)"
```

> 참고: marina CLI 서브커맨드(`project add`/`project ls`/`start`/`up`/`stop`)·옵션(`--project-dir`)·프로젝트 id 컬럼은 실행 시 `bash plugin/scripts/marina.sh --help` 와 `test-compose-e2e.sh` 로 정확 확인해 맞춘다(이 스크립트의 CLI 형태가 다르면 그에 맞게 1줄 보정).

- [ ] **Step 2: 실행 → 통과(또는 SKIP)** — Run: `bash plugin/tests/test-compose-weave-e2e.sh`. Expected: `PASS test-compose-weave-e2e (service=BE-OK, host=PONG)` (docker 가용 시). 실패하면 사이드카 로그로 디버그(`systematic-debugging`).

- [ ] **Step 3: 커밋**
```bash
git add plugin/tests/test-compose-weave-e2e.sh
git commit -m "test(conn): 엮기 일원화 실 docker e2e — service타겟 BE-OK + host타겟 PONG

app(build) 컨테이너에서 localhost:8081→be(자동 서비스타겟·socat DNS) BE-OK,
localhost:6399→host redis(선언 host타겟·socat host.docker.internal) PONG. --env-var 주입. docker 없으면 SKIP."
```

---

## Task 3: 컨트롤 API cull (codex 위임 가능)

옛 service-redirect 의 감지·정리·저장 API 삭제. **hostForward(host-backing-port)·mounts·build-args·prebuild·compose env 는 유지.**

**Files:** Modify `plugin/scripts/marina-control.py`; delete `plugin/tests/test-compose-connectivity-api.sh`

- [ ] **Step 1: 삭제 대상 (codex exec 지시 그대로 사용 가능)**
  - `_scan_config_endpoints(p)` (1569~1606행) — 설정파일 localhost/env 감지. **삭제.**
  - `_clean_compose_connectivity_endpoints(eps)` (1635-1664행). **삭제.**
  - `/api/compose-connectivity` POST 핸들러 (2971-2997행). **삭제.**
  - compose-detect 흐름의 service-redirect 후보: `port_to_svcs`(1726행)와 `conn_eps`(1770·1782행 등 `_scan_config_endpoints` 사용부)·응답에 실리는 `endpoints`/conn 후보. **삭제.** `cfg_cands`(마운트 후보)·`hostForward` 로드(2745-2756)·`_save_project_hostforward`(1608-1632)·그 호출(3104)은 **유지.**
  - backing.json 에서 `services[svc].endpoints` 읽기/쓰기 잔재 제거(있다면). `hostForward`/`forward` top-level 만.

  **codex 위임 예:** `codex exec "marina-control.py 에서 옛 service-redirect(파일 localhost 감지·endpoints) 메커니즘을 전부 삭제하라: _scan_config_endpoints, _clean_compose_connectivity_endpoints, /api/compose-connectivity 핸들러, compose-detect 응답의 conn_eps/endpoints/port_to_svcs. 단 hostForward(_save_project_hostforward 및 그 로드/호출), mounts, build-args, prebuild, compose env, CORS localhost 체크는 절대 건드리지 마라. 문법·들여쓰기 유지."` → 그 후 `codex review` → 내가 diff 검토.

- [ ] **Step 2: 테스트 삭제** — `git rm plugin/tests/test-compose-connectivity-api.sh` (테스트하던 API 가 없어짐). detect/mounts 테스트가 endpoints 를 검증하면 그 부분만 제거.

- [ ] **Step 3: import/구문 검증** — Run: `python3 -c "import ast; ast.parse(open('plugin/scripts/marina-control.py').read()); print('ok')"` → `ok`. 그리고 데몬 기동 스모크: `bash plugin/tests/test-compose-only-control-api.sh`(또는 control-api 계열) → PASS. 전체 스위트 → FAILED 없음(연결 의존 테스트는 이미 제거/갱신).

- [ ] **Step 4: 커밋**
```bash
git add -A plugin/scripts/marina-control.py plugin/tests/
git commit -m "refactor(conn): 컨트롤 API 에서 옛 service-redirect 제거 — 엮기 선언으로 일원화

_scan_config_endpoints·_clean_compose_connectivity_endpoints·/api/compose-connectivity·
compose-detect conn_eps 삭제. hostForward(host 타겟 선언)·mounts·build-args·prebuild·compose env 유지.
test-compose-connectivity-api.sh 삭제. (codex exec + review)"
```

---

## Task 4: 프론트 cull (codex 위임 가능)

연결(service-redirect) 모달만 제거. **host-backing-port 입력·mounts·build-args·prebuild 는 유지.**

**Files:** Modify `plugin/scripts/marina-web/app.js`, `plugin/scripts/marina-web/index.html`

- [ ] **Step 1: 삭제/수정 대상**
  - `app.js`: 엔드포인트 service-redirect 모달 렌더(1911-1945행의 `eps.length` 블록·`cn-mode` 버튼·"↪ 다른 서비스/호스트" HTML), `.cn-mode` 토글 핸들러(2020-2032행), `.cn-save` 결합저장(2035-2061행)에서 `/api/compose-connectivity` fetch(2059행) 제거. **마운트 저장은 유지** — `.cn-save` 가 마운트만 저장하도록(또는 마운트 저장 버튼으로 정리). `composeHostForward`(113·148·701행)·mount(`mt-add` 등) **유지.**
  - `index.html`: "호스트 백킹 포트" 입력(131-132행) **유지.** 연결 관련 별도 마크업 있으면 제거.

  **codex 위임 예:** `codex exec "marina-web/app.js·index.html 에서 옛 service-redirect(연결) UI 만 제거하라: 엔드포인트별 ↪서비스/↪호스트 토글(cn-mode), 그 모달 HTML, /api/compose-connectivity fetch. 마운트 저장(mt-add/고급 텍스트영역), composeHostForward(호스트 백킹 포트) 입력, build-args, prebuild, compose env 는 절대 건드리지 마라. cn-save 가 마운트 저장만 하도록 정리."` → `codex review` → 내가 검토.

- [ ] **Step 2: 검증(프리뷰)** — marina 대시보드 기동(`marina restart` 또는 데몬) → preview_start → preview_console_logs(에러 0) → preview_snapshot(연결 모달 사라짐, host-backing-port·mounts 남음) → preview_screenshot. 그리고 `bash plugin/tests/test-dashboard-launch.sh` → PASS.

- [ ] **Step 3: 커밋**
```bash
git add plugin/scripts/marina-web/app.js plugin/scripts/marina-web/index.html
git commit -m "refactor(conn): 대시보드에서 옛 service-redirect 연결 모달 제거 — 엮기 선언으로 일원화

엔드포인트별 ↪서비스/↪호스트 토글·모달·/api/compose-connectivity 호출 삭제.
host-backing-port(host 타겟)·mounts·build-args·prebuild·compose env 유지. (codex exec + review)"
```

---

## Self-Review

**1. Spec coverage (SP1 절):**
- SP1-(a) service-redirect 삭제 → T1(엔진: `_patch_config`/`_apply_connectivity`/extra_hosts/env) + T3(API) + T4(UI). ✅
- SP1-(b) 서비스타겟 자동도출 → T1 `_auto_service_forward` + cmd_up 병합(명시 우선). ✅
- SP1-(c) UI 걷어내기(host-backing·mounts 유지) → T3·T4 keep-list 명시. ✅
- SP1-(d) 실 docker e2e(환경변수+PONG/200) → T2(`--env-var`·BE-OK·PONG). ✅

**2. Placeholder scan:** T1·T2 전 단계 실제 코드/명령/기대출력. T3·T4 는 "삭제 대상"을 함수명·핸들러·행번호·keep-list 로 정확 명시(삭제 태스크의 '정확한 코드'='정확한 삭제 대상') + codex 지시문 포함. e2e 의 CLI 형태 1줄 보정 안내는 의도된 검증지점(실 CLI 확인). ✅

**3. Type/이름 일관성:**
- `_auto_service_forward(config)->{port:service}` — T1 정의, cmd_up·테스트 동일. ✅
- `_normalize_forward(conn)->{port:target}` — 기존 유지, 테스트가 `_apply_connectivity` 대신 직접 호출로 교체. ✅
- `forward = {**auto, **explicit}` — 명시 선언이 자동 override(dict 병합 순서). cmd_up·spec 일치. ✅
- self-skip: `_auto_service_forward` 가 타겟=서빙서비스 → `_forward_for_service` 의 `target==svc` 가 자기 포트 자동 제외(stage1 로직 그대로 합성). ✅
- keep-list 일관: hostForward·mounts·build-args·prebuild·compose env — T3·T4 동일. ✅

**4. 위험/주의:**
- T1 후~T3 전: `/api/compose-connectivity` 가 남아 endpoints 저장하나 엔진이 무시(죽은 데이터, 무해). T3 가 제거. 각 태스크 단위테스트 green.
- e2e: host:6399 자체 redis 로 격리(점유 6379 회피). host.docker.internal 은 Mac/Docker Desktop 기본; Linux 는 사이드카 ip-route 폴백(stage1).
- 미사용 리스너(자동도출 전 서비스 포트를 모든 앱에): 무해, stage3 정밀화. 동일포트 두 서비스 → 경고.

---

## Execution Handoff

**codex 활용(형 지시):** T1·T2(엔진+실검증, 고위험 코어)는 내가 TDD 로 직접 + 실 docker 증거. T3·T4(기계적 cull)는 `codex exec` 위임 → `codex review` → 내가 diff 검토·통합·스모크. 매 태스크 커밋 green, SC 누적, 형 마지막 검토.

실행: `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`. SP1 완료·검증 후 SP2(Caddy 게이트웨이) plan.
