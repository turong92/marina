# Gateway `expose` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `x-marina.gateway.expose` 로 프론트→백엔드 브라우저 배선을 앱 소스 무수정으로 잇는다 — 도메인 모드(`gateway:svc`)와 same-origin 모드(`origin:svc`), 도메인 모드는 caddy 가 CORS 전담.

**Architecture:** 도메인 스킴을 marina-gateway.py 단일 헬퍼(`service_domain`)로 통일해 build_caddyfile 과 expose resolve 가 공유(DRY). expose 토큰은 순수 파서로 파싱, cmd_up 에서 이 워크트리의 be 도메인/`''` 로 resolve 해 표준 compose `environment:` 로 주입. 도메인 모드 타겟 be 는 스냅샷에 `cors` 플래그가 붙고, build_caddyfile 이 그 서브도메인에 워크트리 대표 origin 을 허용하는 CORS(header_down replace + preflight 204 + credentialed + 헤더 echo)를 생성.

**Tech Stack:** Python 3 (표준 라이브러리만), bash 테스트(embedded python via importlib / `gen` CLI stdin→stdout), 실 docker/caddy e2e.

**Spec:** `docs/superpowers/specs/2026-07-01-gateway-expose-design.md`

**Test idiom (이 레포):** 순수 함수는 bash 테스트가 `python3 - "$GW" <<'PY' … PY`(importlib 로 모듈 로드 후 assert) 또는 `printf '<json>' | python3 "$GW" gen --port N`(stdout Caddyfile grep). 통합은 실 docker e2e(`command -v docker … || SKIP`). 새 테스트도 이 관례를 따른다. 데몬 띄우는 테스트는 caddy leak 방지로 `export MARINA_GATEWAY=off`.

---

## File Structure

- `plugin/scripts/marina-gateway.py` — `service_domain()` 헬퍼(도메인 스킴 SoT), build_caddyfile 의 CORS 생성, `gen` 은 그대로.
- `plugin/scripts/marina-compose.py` — `parse_expose_token()` 파서, build_overlay 에 `expose_env` 파라미터(→ `environment:` emit), cmd_up 에서 expose resolve + 주입.
- `plugin/scripts/marina_lifecycle.py` — `_gateway_snapshot` 이 도메인 모드 expose 타겟에 `cors: True` 표시.
- `plugin/scripts/marina-gateway-control.sh` / `marina_handler.py` — `marina gateway config` 관측(유효 라우팅+CORS 쌍 출력).
- `plugin/tests/test-gateway-expose-domain.sh`, `test-gateway-expose-origin.sh`, `test-expose-token.sh` — 신규.

---

## Task 1: `service_domain()` — 도메인 스킴 단일 헬퍼

기존 build_caddyfile 이 인라인으로 만드는 `<wt>[-<svc>].<proj>.localhost` 를 순수 헬퍼로 추출해 expose resolve 와 공유(DRY). 동작 불변(리팩터 + 신규 진입점).

**Files:**
- Modify: `plugin/scripts/marina-gateway.py` (build_caddyfile 근처, `_domain_label` 아래)
- Test: `plugin/tests/test-expose-token.sh` (신규 — 이 파일에 Task1·2 단위테스트)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-expose-token.sh`

```bash
#!/usr/bin/env bash
# expose: 도메인 스킴 헬퍼(service_domain) + 토큰 파서(parse_expose_token) 단위테스트.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"
MC="$HERE/../scripts/marina-compose.py"

python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
# 대표(primary)면 bare, 아니면 <wt>-<svc>. 라벨은 sanitize.
assert gw.service_domain("main","shop","web",True,3902)=="http://main.shop.localhost:3902", gw.service_domain("main","shop","web",True,3902)
assert gw.service_domain("main","shop","user-api",False,3902)=="http://main-user-api.shop.localhost:3902", gw.service_domain("main","shop","user-api",False,3902)
assert gw.service_domain("Feat_X","MDC","User_API",False,80)=="http://feat-x-user-api.mdc.localhost:80"
print("service_domain OK")
PY
echo "PASS test-expose-token (service_domain)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-gateway-... ` → `bash plugin/tests/test-expose-token.sh`
Expected: FAIL — `AttributeError: module 'gw' has no attribute 'service_domain'`

- [ ] **Step 3: 구현** — `marina-gateway.py`, `_domain_label` 함수 바로 아래에 추가

```python
def service_domain(wt: str, proj: str, svc: str, is_primary: bool, port: int) -> str:
    """이 워크트리 서비스의 게이트웨이 URL. 대표(primary)=<wt>.<proj>.localhost, 그 외=<wt>-<svc>.<proj>.localhost.
    도메인 스킴 SoT — build_caddyfile 과 expose resolve 가 공유(라벨 규칙 한 곳)."""
    w, p, s = _domain_label(wt), _domain_label(proj), _domain_label(svc)
    sub = f"{w}.{p}" if is_primary else f"{w}-{s}.{p}"
    return f"http://{sub}.localhost:{port}"
```

그리고 build_caddyfile 내부의 `sub = f"{wid}.{pid}" if is_primary else f"{wid}-{name}.{pid}"` (현재 [:62]) 는 그대로 두되(그 로직은 site 블록 host 라 URL 아님), 신규 헬퍼는 expose 전용 진입점으로 둔다(동작 불변).

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-expose-token.sh`
Expected: `PASS test-expose-token (service_domain)`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-gateway.py plugin/tests/test-expose-token.sh
git commit -m "feat(marina): service_domain 헬퍼 — 게이트웨이 도메인 스킴 SoT(expose 공유)"
```

---

## Task 2: `parse_expose_token()` — `gateway:svc` / `origin:svc` 파서

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (x-marina 계열 함수 근처, `parse_xmarina` 아래)
- Test: `plugin/tests/test-expose-token.sh` (Task1 파일에 append)

- [ ] **Step 1: 실패 테스트 append** — `test-expose-token.sh` 끝에 추가

```bash
python3 - "$MC" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
assert mc.parse_expose_token("gateway:user-api")==("gateway","user-api")
assert mc.parse_expose_token("origin:user-api")==("origin","user-api")
assert mc.parse_expose_token("  gateway:svc-a  ")==("gateway","svc-a")   # 공백 허용
assert mc.parse_expose_token("http://localhost:8081") is None               # 토큰 아님 → None
assert mc.parse_expose_token("${bogus:x}") is None                          # 미지원 모드 → None
assert mc.parse_expose_token("") is None
print("parse_expose_token OK")
PY
echo "PASS test-expose-token (parser)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-expose-token.sh`
Expected: FAIL — `AttributeError: ... 'parse_expose_token'`

- [ ] **Step 3: 구현** — `marina-compose.py`, `parse_xmarina` 아래

```python
import re as _re_expose

def parse_expose_token(val: str):
    """expose 값 파싱. 'gateway:svc'→('gateway',svc), 'origin:svc'→('origin',svc). 그 외/토큰아님→None."""
    m = _re_expose.fullmatch(r"\$\{(gateway|origin):([^}]+)\}", (val or "").strip())
    return (m.group(1), m.group(2).strip()) if m else None
```

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-expose-token.sh`
Expected: `PASS test-expose-token (parser)`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-expose-token.sh
git commit -m "feat(marina): parse_expose_token — \gateway:svc/\origin:svc 파서"
```

---

## Task 3: build_caddyfile — 도메인 모드 be 서브도메인에 CORS 생성

스냅샷 서비스에 `cors: True` 가 있으면 그 be 서브도메인 블록에 CORS 를 넣는다. ACAO = 그 워크트리의 대표 origin(build_caddyfile 이 이미 아는 `http://<wt>.<proj>.localhost:<port>`).

**Files:**
- Modify: `plugin/scripts/marina-gateway.py` `build_caddyfile` (서브도메인 block 조립부, 현재 [:66-77])
- Test: `plugin/tests/test-gateway-expose-domain.sh` (신규 — CORS 생성 단위, gen CLI)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-gateway-expose-domain.sh`

```bash
#!/usr/bin/env bash
# expose 도메인 모드: cors:true be 서브도메인에 CORS(replace+preflight+credentialed+헤더 echo) 생성.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

out=$(printf '%s' '[{"id":"alpha","projectId":"mdc","services":[
  {"service":"web","port":"3100","running":true},
  {"service":"user-api","port":"3200","running":true,"cors":true}
]}]' | python3 "$GW" gen --port 8088)

# be 서브도메인 블록 추출
be=$(echo "$out" | awk '/alpha-user-api.mdc.localhost:8088 \{/{f=1} f{print} f&&/^}/{exit}')
echo "$be" | grep -q "header_down Access-Control-Allow-Origin http://alpha.mdc.localhost:8088" || { echo "FAIL: ACAO=대표origin replace 아님"; echo "$be"; exit 1; }
echo "$be" | grep -q "header_down Access-Control-Allow-Credentials true" || { echo "FAIL: credentials"; exit 1; }
echo "$be" | grep -q "method OPTIONS" || { echo "FAIL: preflight 매처 없음"; exit 1; }
echo "$be" | grep -q "respond 204" || { echo "FAIL: preflight 204 없음"; exit 1; }
echo "$be" | grep -q "Access-Control-Request-Headers" || { echo "FAIL: 헤더 echo 없음"; exit 1; }
echo "$be" | grep -q "reverse_proxy 127.0.0.1:3200" || { echo "FAIL: be 프록시 유지 안 됨"; exit 1; }

# 회귀: cors 없으면 CORS 0 (기존 서비스 영향 없음)
out2=$(printf '%s' '[{"id":"b","projectId":"mdc","services":[{"service":"user-api","port":"3200","running":true}]}]' | python3 "$GW" gen --port 8088)
echo "$out2" | grep -q "Access-Control-Allow-Origin" && { echo "FAIL: cors 없는데 CORS 생성"; exit 1; } || true

echo "PASS test-gateway-expose-domain"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-gateway-expose-domain.sh`
Expected: FAIL — `ACAO=대표origin replace 아님`

- [ ] **Step 3: 구현** — `build_caddyfile`. 대표 origin 을 워크트리 루프 진입 시 계산해두고, be 서브도메인 block 에서 `cors` 면 CORS 를 삽입. 현재 [:66-77] block 조립을 아래로 교체/보강:

```python
            block = [f"http://{sub}.localhost:{port} {{",
                     "    bind 127.0.0.1 ::1"]
            if is_primary:
                # (기존 형제 routes handle 부착 로직 그대로 유지)
                for sib in svcs:
                    sp = str((sib or {}).get("port") or "").strip()
                    if sib is s or not sp.isdigit() or not (sib or {}).get("running"):
                        continue
                    for rp in ((sib or {}).get("routes") or []):
                        rc = "/" + str(rp).strip().strip("/")
                        if rc != "/":
                            block += [f"    handle {rc}/* {{", f"        reverse_proxy 127.0.0.1:{sp}", "    }"]
            if (s or {}).get("cors"):
                fe_origin = f"http://{wid}.{pid}.localhost:{port}"     # 이 워크트리 대표 origin
                block += _cors_lines(fe_origin)
            block += [f"    reverse_proxy 127.0.0.1:{hostport}", "}", ""]
            lines += block
```

그리고 모듈 상단(함수 밖)에 CORS 렌더 헬퍼 추가:

```python
def _cors_lines(fe_origin: str) -> list:
    """be 서브도메인용 CORS(caddy 전담). be 응답의 ACAO 를 replace(header_down), preflight 는 204 자체응답,
    credentialed(특정 origin), Allow-Headers 는 요청 헤더 echo(커스텀 헤더 범용). caddy v2 문법."""
    return [
        "    @cors_pre method OPTIONS",
        "    handle @cors_pre {",
        f"        header Access-Control-Allow-Origin \"{fe_origin}\"",
        "        header Access-Control-Allow-Credentials true",
        "        header Access-Control-Allow-Methods \"GET, POST, PUT, PATCH, DELETE, OPTIONS\"",
        "        header Access-Control-Allow-Headers \"{http.request.header.Access-Control-Request-Headers}\"",
        "        header Access-Control-Max-Age 600",
        "        respond 204",
        "    }",
        f"    reverse_proxy 127.0.0.1:REPLACED {{",   # 실제 포트는 아래 라인이 대체 — 주: 이 블록은 참고용
    ][:9] + [
        # 응답 헤더 replace 는 아래 최종 reverse_proxy 에 header_down 으로 붙인다(Step 3b).
    ]
```

주의: preflight(@cors_pre)는 be 로 안 넘기고 caddy 가 204. 나머지(실제 요청)의 응답엔 be 가 낸 ACAO 를 replace 해야 하므로, **최종 `reverse_proxy` 를 header_down 블록으로** 바꾼다. block 마지막의 `reverse_proxy 127.0.0.1:{hostport}` 를 cors 일 때 아래로 교체:

```python
            if (s or {}).get("cors"):
                fe_origin = f"http://{wid}.{pid}.localhost:{port}"
                block += _cors_preflight_lines(fe_origin)
                block += [f"    reverse_proxy 127.0.0.1:{hostport} {{",
                          f"        header_down Access-Control-Allow-Origin \"{fe_origin}\"",
                          "        header_down Access-Control-Allow-Credentials true",
                          "    }", "}", ""]
            else:
                block += [f"    reverse_proxy 127.0.0.1:{hostport}", "}", ""]
            lines += block
```

`_cors_preflight_lines(fe_origin)` 는 위 `@cors_pre`/`handle @cors_pre { … respond 204 }` 9줄만 반환(reverse_proxy 라인 제외). 위 `_cors_lines` 초안은 버리고 이 형태로 확정.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-gateway-expose-domain.sh`
Expected: `PASS test-gateway-expose-domain`

- [ ] **Step 5: 기존 게이트웨이 테스트 회귀 확인**

Run: `bash plugin/tests/test-gateway-config.sh && bash plugin/tests/test-gateway-pathroute.sh`
Expected: 둘 다 무출력/PASS(assert 통과)

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-gateway.py plugin/tests/test-gateway-expose-domain.sh
git commit -m "feat(marina): build_caddyfile CORS 생성 — cors:true be 서브도메인(replace+preflight+credentialed)"
```

---

## Task 4: `_gateway_snapshot` — 도메인 모드 expose 타겟에 `cors: True`

x-marina.gateway.expose 를 읽어, `gateway:svc` 로 지목된 be 서비스의 스냅샷 항목에 `cors: True` 를 붙인다.

**Files:**
- Modify: `plugin/scripts/marina_lifecycle.py` `_gateway_snapshot` (현재 [:288-307], xm.gateway 읽는 블록 + services 조립)
- Test: `plugin/tests/test-gateway-expose-domain.sh` (스냅샷→cors 매핑 단위, importlib)

- [ ] **Step 1: 실패 테스트 append** — `test-gateway-expose-domain.sh` 끝에 추가. `_gateway_snapshot` 은 파일시스템 의존이라, 순수 매핑 로직을 별도 헬퍼 `_expose_cors_targets(xm_gateway)` 로 빼서 그걸 테스트:

```bash
python3 - "$HERE/../scripts/marina_lifecycle.py" <<'PY'
import importlib.util, sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec=importlib.util.spec_from_file_location("ml", sys.argv[1]); ml=importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(ml)
except Exception as e:
    print("skip import (env dep):", e); sys.exit(0)
gw={"expose":{"web":{"NEXT_PUBLIC_API_URL":"gateway:user-api","OTHER":"origin:svc2"}}}
assert ml._expose_cors_targets(gw)=={"user-api"}, ml._expose_cors_targets(gw)   # gateway 모드만 cors 대상
assert ml._expose_cors_targets({})==set()
print("_expose_cors_targets OK")
PY
echo "PASS test-gateway-expose-domain (cors targets)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-gateway-expose-domain.sh`
Expected: FAIL — `'ml' has no attribute '_expose_cors_targets'`

- [ ] **Step 3: 구현** — `marina_lifecycle.py`. `_gateway_snapshot` 위에 헬퍼 추가:

```python
def _expose_cors_targets(xm_gateway: dict) -> set:
    """x-marina.gateway.expose 에서 gateway:svc 로 지목된 be 서비스명 집합(=CORS 대상). ${origin:} 은 same-origin 이라 제외."""
    out = set()
    for _consumer, envmap in ((xm_gateway or {}).get("expose") or {}).items():
        for _var, val in (envmap or {}).items():
            tok = _mc().parse_expose_token(str(val))
            if tok and tok[0] == "gateway":
                out.add(tok[1])
    return out
```

그리고 `_gateway_snapshot` 의 services 조립부([:305-306])에서 각 서비스에 cors 표시:

```python
        cors_targets = _expose_cors_targets(xm_gw) if 'xm_gw' in dir() else set()
        out.append({"id": p.get("id"), "projectId": pid, "primary": gprimary,
                    "services": [{"service": s.get("service"), "port": s.get("port"), "running": s.get("running"),
                                  "routes": groutes.get(s.get("service")) or [],
                                  "cors": s.get("service") in cors_targets}
                                 for s in (p.get("services") or [])]})
```

주: `xm_gw` 는 현재 try 블록 지역변수 — 스코프 밖에서 참조 못 하므로, xm_gw 를 try 앞에서 `xm_gw = {}` 로 초기화하고 try 안에서 채운 뒤 `cors_targets = _expose_cors_targets(xm_gw)` 를 append 직전에 계산. (try 구조 정리)

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-gateway-expose-domain.sh`
Expected: `PASS test-gateway-expose-domain (cors targets)`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_lifecycle.py plugin/tests/test-gateway-expose-domain.sh
git commit -m "feat(marina): _gateway_snapshot 이 도메인모드 expose 타겟에 cors 표시"
```

---

## Task 5: build_overlay — `expose_env` 로 `environment:` 주입

**Files:**
- Modify: `plugin/scripts/marina-compose.py` `build_overlay` (현재 [:333-396], profile env emit 부 [:374-378] 참고)
- Test: `plugin/tests/test-gateway-expose-origin.sh` (신규 — build_overlay env 주입 단위, importlib)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-gateway-expose-origin.sh`

```bash
#!/usr/bin/env bash
# expose: build_overlay 가 expose_env 를 서비스 environment 로 주입(도메인=URL, origin=빈값).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MC="$HERE/../scripts/marina-compose.py"

python3 - "$MC" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
config={"services":{"web":{"build":{"context":"./web"},"ports":["3000"]}}}
ov=mc.build_overlay(config, expose_env={"web":{"NEXT_PUBLIC_API_URL":"http://alpha-user-api.mdc.localhost:8088"}})
assert "web:" in ov and "environment:" in ov, ov
assert 'NEXT_PUBLIC_API_URL: "http://alpha-user-api.mdc.localhost:8088"' in ov, ov
# same-origin 빈값도 명시 주입(하드코딩 폴백 덮기)
ov2=mc.build_overlay(config, expose_env={"web":{"NEXT_PUBLIC_API_URL":""}})
assert 'NEXT_PUBLIC_API_URL: ""' in ov2, ov2
# expose_env 없으면 environment 안 생김(회귀)
ov3=mc.build_overlay(config)
assert "NEXT_PUBLIC_API_URL" not in ov3, ov3
print("build_overlay expose_env OK")
PY
echo "PASS test-gateway-expose-origin (build_overlay)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-gateway-expose-origin.sh`
Expected: FAIL — `build_overlay() got an unexpected keyword argument 'expose_env'`

- [ ] **Step 3: 구현** — `build_overlay` 시그니처에 `expose_env=None` 추가, 서비스 body 조립부(profile env emit 근처)에서 주입. `environment:` 는 이미 profile env 로 쓰일 수 있으니 merge 되게:

```python
def build_overlay(config: dict, bind_host: str = "127.0.0.1", build_args: dict = None,
                  connectivity: dict = None, expose_env: dict = None) -> str:
    ...
    build_args, connectivity, expose_env = build_args or {}, connectivity or {}, expose_env or {}
    ...
    # (서비스 루프 안, prof_env emit 하는 자리에서 expose_env 병합)
        env_pairs = dict(prof_env)                          # profile 후보 env
        for k, v in (expose_env.get(name) or {}).items():   # expose 주입(우선)
            env_pairs[k] = v
        if env_pairs:
            body.append("    environment:")
            for k in sorted(env_pairs):
                body.append(f"      {k}: {json.dumps(str(env_pairs[k]))}")
```

기존 `prof_env` 만 emit 하던 블록([:375-378])을 위 `env_pairs` 병합 형태로 교체. `json.dumps` 로 빈 문자열은 `""` 로 나온다.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-gateway-expose-origin.sh`
Expected: `PASS test-gateway-expose-origin (build_overlay)`

- [ ] **Step 5: 회귀** — profile env 테스트

Run: `bash plugin/tests/test-profile-overlay.sh`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-gateway-expose-origin.sh
git commit -m "feat(marina): build_overlay expose_env — 서비스 environment 주입(도메인 URL/빈값)"
```

---

## Task 6: cmd_up — expose resolve + 주입 배선

x-marina.gateway.expose 를 읽어, 이 워크트리(`a.session`)·프로젝트(`a.project_id`)·게이트웨이 포트로 각 토큰을 resolve 해 `expose_env` 를 만들고 build_overlay 에 넘긴다.

> **wiring 확인(구현 전 1회):** `a.session` 이 `_gateway_snapshot` 의 워크트리 `id` 와 같은 라벨인지 확인 — 다르면 domain 이 caddy site 블록과 안 맞는다. `marina_lifecycle.session_payload`/`project_for` 가 만드는 `id` 와 `cmd_up` 의 `a.session` 을 대조(같은 basename 계열). 대표 서비스 판정은 `gw._is_primary(services, svc)` 재사용.

**Files:**
- Modify: `plugin/scripts/marina-compose.py` `cmd_up` (현재 [:536-542], overlay build 호출부)
- Test: `plugin/tests/test-gateway-expose-domain.sh` (실 docker e2e 로 검증 — 아래 Task 7 통합에 포함) + resolve 순수부 단위

- [ ] **Step 1: resolve 순수 헬퍼 실패 테스트 append** — `test-expose-token.sh` 에 추가

```bash
python3 - "$MC" "$GW" <<'PY'
import importlib.util, sys
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
mc=load("mc",sys.argv[1]); gw=load("gw",sys.argv[2])
# expose dict + (wt,proj,port,primary판정) → {consumer:{ENV:value}}
expose={"web":{"NEXT_PUBLIC_API_URL":"gateway:user-api","REL":"origin:user-api"}}
services=[{"service":"web","port":"1","running":True},{"service":"user-api","port":"2","running":True}]
res=mc.resolve_expose_env(expose, "alpha", "mdc", 8088, services, gw)
assert res["web"]["NEXT_PUBLIC_API_URL"]=="http://alpha-user-api.mdc.localhost:8088", res
assert res["web"]["REL"]=="", res     # origin 모드 → 빈값(상대)
print("resolve_expose_env OK")
PY
echo "PASS test-expose-token (resolve)"
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-expose-token.sh`
Expected: FAIL — `'mc' has no attribute 'resolve_expose_env'`

- [ ] **Step 3: 구현** — `marina-compose.py` 에 헬퍼 추가

```python
def resolve_expose_env(expose: dict, wt: str, proj: str, gwport: int, services: list, gw_mod) -> dict:
    """expose 선언 → {consumer:{ENV:value}}. gateway 모드=be 게이트웨이 URL, origin 모드=''(상대).
    services 는 대표 판정용([{service,port,running}]). gw_mod=marina-gateway 모듈(service_domain/_is_primary 재사용)."""
    out = {}
    for consumer, envmap in (expose or {}).items():
        for var, val in (envmap or {}).items():
            tok = parse_expose_token(str(val))
            if not tok:
                continue
            mode, target = tok
            if mode == "origin":
                out.setdefault(consumer, {})[var] = ""
            else:
                is_prim = gw_mod._is_primary(services, target)
                out.setdefault(consumer, {})[var] = gw_mod.service_domain(wt, proj, target, is_prim, gwport)
    return out
```

`cmd_up` 의 overlay build 호출부([:538-540])를 교체 — gateway 모듈 로드 + expose resolve + 전달:

```python
        gw_mod = _gw_module()                                        # marina-gateway.py 로드(아래 헬퍼)
        gwport = _gateway_port_for_up()                              # 게이트웨이 포트(아래 헬퍼)
        snap_services = [{"service": k, "port": (v or {}).get("ports_hostport",""), "running": True}
                         for k, v in (config.get("services") or {}).items()]   # 대표판정용(포트값 불필요, 존재만)
        exp = resolve_expose_env((xm.get("gateway") or {}).get("expose") or {}, a.session, a.project_id, gwport, snap_services, gw_mod)
        overlay_text = build_overlay(config, build_args=_parse_build_args(getattr(a, "build_arg", [])),
                                     connectivity=overlay_conn, expose_env=exp)
```

그리고 모듈 상단에 로더/포트 헬퍼:

```python
def _gw_module():
    import importlib.util
    p = os.path.join(os.path.dirname(__file__), "marina-gateway.py")
    s = importlib.util.spec_from_file_location("marina_gateway", p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
    return m

def _gateway_port_for_up() -> int:
    """게이트웨이 포트: MARINA_GATEWAY_PORT env 우선, 없으면 $MARINA_HOME/gateway/port, 기본 3902."""
    v = os.environ.get("MARINA_GATEWAY_PORT")
    if v and v.isdigit():
        return int(v)
    try:
        return int((Path(os.environ.get("MARINA_HOME", os.path.expanduser("~/.marina"))) / "gateway" / "port").read_text().strip())
    except Exception:
        return 3902
```

> 주: `_is_primary(services, target)` 은 gw 의 `WEB_NAMES` 자동판정을 쓴다 — x-marina.gateway.primary 명시가 있으면 그걸 우선해야 하므로, `gprimary` 를 넘길 수 있게 `resolve_expose_env` 에 `primary=""` 인자를 추가하고 `is_prim = (target==primary) if primary else gw_mod._is_primary(services, target)` 로. cmd_up 에서 `primary=(xm.get("gateway") or {}).get("primary","")` 전달.

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-expose-token.sh`
Expected: `PASS test-expose-token (resolve)`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-expose-token.sh
git commit -m "feat(marina): cmd_up expose resolve+주입 — 토큰→게이트웨이URL/빈값 environment"
```

---

## Task 7: `marina gateway config` — 관측성 + 실 docker e2e

**Files:**
- Modify: `plugin/scripts/marina_handler.py` (gateway status 핸들러 근처 [:71]) 또는 `marina-gateway-control.sh` — `config` 서브커맨드로 유효 라우팅+CORS 쌍 출력.
- Test: `plugin/tests/test-gateway-expose-domain.sh` 에 실 docker/caddy e2e append(있으면).

- [ ] **Step 1: 관측 출력 테스트 작성** — build_caddyfile 결과에서 CORS 쌍을 파싱해 요약하는 순수 함수 `summarize_gateway(snapshot)` 를 gateway.py 에 두고 테스트

```bash
# test-gateway-expose-domain.sh 에 append
python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
snap=[{"id":"alpha","projectId":"mdc","services":[
  {"service":"web","port":"3100","running":True},
  {"service":"user-api","port":"3200","running":True,"cors":True,"routes":[]}]}]
s=gw.summarize_gateway(snap, 8088)
assert any(r["domain"]=="alpha-user-api.mdc.localhost:8088" and r["cors_origin"]=="http://alpha.mdc.localhost:8088" for r in s), s
print("summarize_gateway OK")
PY
echo "PASS test-gateway-expose-domain (summarize)"
```

- [ ] **Step 2: 실패 확인** → `AttributeError: summarize_gateway`

- [ ] **Step 3: 구현** — `marina-gateway.py` 에 `summarize_gateway(snapshot, port)` (build_caddyfile 과 같은 순회로 `[{domain, service, hostport, cors_origin|None, routes}]` 반환) + `gen` 옆에 `config` 서브커맨드(`sub.add_parser("config")` → stdin snapshot → JSON 요약 print). `marina gateway config` 는 marina-gateway-control.sh 가 snapshot 을 만들어 이 CLI 로 넘기거나, marina_handler 가 `_gateway_snapshot()` 로 요약해 출력.

- [ ] **Step 4: 통과 확인** → `PASS ... (summarize)`

- [ ] **Step 5: 실 docker e2e (docker 있을 때만)** — mdc 또는 픽스처 compose 에 `x-marina.gateway.expose.web.NEXT_PUBLIC_API_URL: "gateway:user-api"` 를 넣고, `MARINA_GATEWAY=on` 으로 up → 게이트웨이 caddy 가 be 서브도메인에 CORS 를 내는지 `curl -H "Origin: http://<wt>.<proj>.localhost:<port>" -X OPTIONS` 로 204 + ACAO 확인. docker 없으면 `SKIP`. (테스트 상단 `command -v docker … || SKIP`, 데몬 leak 방지는 이 테스트는 게이트웨이 대상이라 그대로 ON.)

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-gateway.py plugin/scripts/marina_handler.py plugin/scripts/marina-gateway-control.sh plugin/tests/test-gateway-expose-domain.sh
git commit -m "feat(marina): gateway config 관측(라우팅+CORS 쌍) + expose 도메인 e2e"
```

---

## Task 8: 전체 스위트 + 문서

- [ ] **Step 1: 전체 테스트 + leak 0 확인**

Run: `for f in plugin/tests/test-*.sh; do bash "$f" >/dev/null 2>&1 && echo "ok $f" || echo "FAIL $f"; done` + 스위트 전후 `pgrep -f 'caddy run' | wc -l` 동일 확인.
Expected: 전부 ok, caddy leak 0.

- [ ] **Step 2: README/docs — expose 사용법 한 문단** (`gateway:svc` vs `origin:svc`, 토큰-인증 vs 쿠키-세션, CORS 는 게이트웨이가 처리, 쿠키앱은 same-origin 권고). 스펙 파일 링크.

- [ ] **Step 3: 커밋**

```bash
git add README.md docs/
git commit -m "docs(marina): gateway.expose 사용법 — 2모드·CORS·쿠키앱 권고"
```

---

## Self-Review (작성자 체크 완료)

- **스펙 커버리지:** 스키마(T2 파서, T6 resolve)·2모드(T5 주입, T3 CORS/기존 routes)·CORS caddy전담(T3)·내부평면 불변(사이드카 미변경)·관측성(T7)·데이터흐름(T6 cmd_up)·테스트(각 T)·한계(T8 문서) — 매핑됨.
- **플레이스홀더:** T3 의 `_cors_lines` 초안은 폐기 명시하고 `_cors_preflight_lines`+header_down 최종형으로 확정.
- **타입 일관성:** `service_domain`·`parse_expose_token`·`resolve_expose_env`·`_expose_cors_targets`·`summarize_gateway`·`build_overlay(expose_env=)`·스냅샷 `cors` 키 — 태스크 간 시그니처 일치.
- **미해결 1건(구현 중 확인):** T6 의 `a.session` ↔ 스냅샷 워크트리 `id` 라벨 동일성 — wiring 확인 스텝으로 명시.
