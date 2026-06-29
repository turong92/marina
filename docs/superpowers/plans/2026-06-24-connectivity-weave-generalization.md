# Connectivity 엮기 일반화 (Stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 워크트리별 compose 격리에서 앱의 모든 서버측 `localhost:<port>` 호출을 앱 무수정으로 올바른 대상(같은 compose 의 다른 서비스 = 컨테이너 DNS, 또는 호스트의 redis/db)으로 자동 라우팅한다.

**Architecture:** 이번 세션의 host-forward(socat 사이드카, 프로젝트 단위·호스트 전용)를 **포트별 타겟을 갖는 범용 엮기**로 확장한다. 진실의 원천은 `backing.json` 의 선언 `forward: {port: {target: service|host}}`. `marina-compose.py` 의 `_apply_connectivity` 가 이를 `{port: target}` 맵으로 정규화하고, `build_overlay` 가 **앱(build) 서비스마다 사이드카 1개**를 만들어 그 컨테이너가 부르는 모든 `localhost:port` 를 각 타겟으로 중계한다(`target=host`→`host.docker.internal`, `target=<svc>`→그 서비스 DNS). 자기 자신이 서빙하는 포트는 건너뛴다(socat ↔ 앱 포트 충돌 방지). 레거시 `hostForward: [port]`(전부 host)는 그대로 받아 마이그레이션한다.

**Tech Stack:** Python 3 stdlib only (`plugin/scripts/marina-compose.py`), Docker Compose v2.24.4+ (`!override` merge tag, `network_mode: service:<svc>`), `alpine/socat` 사이드카, bash 테스트 하니스(`plugin/tests/*.sh`, `importlib` 로 모듈 직접 호출 + stdin `overlay` 훅). 테스트 실행: `bash plugin/tests/<name>.sh` → `PASS <name>`. 전체: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done`.

---

## 배경 — 지금 코드 (1단계의 씨앗, commit `42ebdbf`)

`backing.json` top-level `hostForward: ["6379"]` → `_apply_connectivity` 가 `{"extraHosts":[...], "hostForward":["6379"], "env":{...}}` 반환 → `build_overlay` 가 **앱 서비스 × 포트마다** 사이드카 `<svc>-hostbind-<port>`(socat `localhost:<port>` → `host.docker.internal:<port>`) 생성. 전부 호스트로만 간다.

**이번 작업이 바꾸는 것:**
1. 캐리어 `hostForward: [port]`(list, 전부 host) → `forward: {port: target}`(dict, 포트별 host|서비스명).
2. 사이드카: 포트마다 1개(`<svc>-hostbind-<port>`) → **앱 서비스마다 1개**(`<svc>-bind`, 그 컨테이너 모든 포트를 한 사이드카가).
3. 타겟: 호스트 전용 → **호스트 또는 같은 compose 서비스(DNS)**.
4. 자기 서빙 포트 self-skip.
5. 레거시 `hostForward` 입력은 계속 동작(전부 host 로 정규화).

**범위 밖(다음 단계):** 대시보드/`/api` 에서 service-target 을 선언하는 UI 는 **3단계(선언 자동 + 검출)**. 이번엔 `backing.json` 의 `forward` 를 손으로(또는 기존 호스트 전용 대시보드 경로로) 채운다. 호스트 브라우저 게이트웨이(Caddy)는 **2단계**. `marina-control.py` 는 손대지 않는다(기존 `hostForward` 쓰기 경로가 레거시로 그대로 호환).

## File Structure

| 파일 | 책임 | 변경 |
|---|---|---|
| `plugin/scripts/marina-compose.py` | compose overlay 생성 엔진 | `_forward_for_service`/`_bind_script`/`_normalize_forward` 추가; `build_overlay`·`_apply_connectivity`·`cmd_up` 수정 |
| `plugin/tests/test-compose-overlay.sh` | 기존 overlay/연결 단위 테스트 | 캐리어 rename(`hostForward`→`forward`)·사이드카 rename(`-hostbind-<port>`→`-bind`) 어서션 갱신 |
| `plugin/tests/test-compose-forward.sh` | **신규** — 엮기 일반화 단위 테스트 | 생성(서비스 타겟·혼합·self-skip·헬퍼) |
| `README.md` | 사용자 문서 | `forward` 스키마 + 엮기 사이드카 동작 문단 추가 |

데이터 흐름: `backing.json` → `cmd_up(--connectivity)` → `_apply_connectivity(conn)` →(`_normalize_forward`)→ `{forward: {port: target}}` → `build_overlay(connectivity=...)` →(`_forward_for_service`+`_bind_script`)→ overlay YAML 의 `<svc>-bind` 사이드카. `cmd_up` 은 같은 `_forward_for_service` 로 `up` 대상 사이드카 이름을 계산.

---

## Task 1: 엮기 엔진 — 포트별 타겟 + 앱 서비스당 사이드카 1개

`build_overlay` 가 `forward: {port: target}` 를 읽어 앱 서비스마다 사이드카 1개를 만든다(host + service 타겟, self-skip). 캐리어를 `hostForward`(list)에서 `forward`(dict)로 바꾸고 `_apply_connectivity`/`cmd_up` 을 맞춘다. 이 태스크가 끝나면 엔진은 service-target 까지 지원하지만, `backing.json` 에서 그걸 **선언**하는 경로(top-level `forward` 파싱)는 Task 2 에서 붙는다 — Task 1 의 `_normalize_forward` 는 레거시 `hostForward`(전부 host)만 정규화한다.

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (helpers 추가 + `build_overlay` 148-223 + `_apply_connectivity` 273-319 + `cmd_up` 452-457)
- Modify: `plugin/tests/test-compose-overlay.sh` (어서션 갱신)
- Create: `plugin/tests/test-compose-forward.sh`

- [ ] **Step 1: 신규 테스트 파일 작성 (실패하는 테스트)**

`plugin/tests/test-compose-forward.sh` 생성:

```bash
#!/usr/bin/env bash
# 엮기 일반화: build_overlay 가 forward={port:target} 로 앱(build) 서비스마다 사이드카 1개(<svc>-bind)를 만든다.
# target=host → host.docker.internal(리눅스 게이트웨이 폴백), target=서비스명 → 컨테이너 DNS. target==자기 서비스는 skip.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"

python3 - "$CP" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

SV={"services":{
  "fe":{"build":{"context":"."}},
  "be":{"build":{"context":"."},"ports":[{"target":8081,"published":"8081"}]},
  "cache":{"image":"redis"},
}}

# --- 헬퍼: _forward_for_service — self(타겟==자기) 제외, 포트 오름차순, [(port,target)] ---
assert mc._forward_for_service({"8081":"be","6379":"host"}, "fe")==[("6379","host"),("8081","be")], mc._forward_for_service({"8081":"be","6379":"host"},"fe")
assert mc._forward_for_service({"8081":"be","6379":"host"}, "be")==[("6379","host")], "be 는 8081 self 제외"
assert mc._forward_for_service({}, "fe")==[], "빈 forward → 빈"

# --- 헬퍼: _bind_script — host 면 $H 셋업, 포트별 백그라운드 socat, 끝에 wait ---
s=mc._bind_script([("6379","host"),("8081","be")])
assert "H=host.docker.internal" in s and "ip route" in s, s          # host → 런타임 host.docker.internal 또는 default gateway
assert 'TCP-LISTEN:6379,fork,reuseaddr TCP:"$$H":6379 &' in s, s     # $$ = compose 변수확장 회피(런타임 리터럴 $)
assert "TCP-LISTEN:8081,fork,reuseaddr TCP:be:8081 &" in s, s        # service → DNS, 따옴표 없음
assert s.rstrip().endswith("wait"), s
s2=mc._bind_script([("8081","be")])                                  # 전부 service → $H 셋업 없음
assert "host.docker.internal" not in s2 and "TCP:be:8081" in s2, s2

# --- build_overlay: service target — fe 가 localhost:8081 → be:8081. 사이드카는 fe-bind 하나 ---
ov=mc.build_overlay(SV, connectivity={"forward":{"8081":"be"}})
assert "fe-bind:" in ov and "alpine/socat" in ov, ov
assert 'network_mode: "service:fe"' in ov, ov
assert "TCP-LISTEN:8081" in ov and "TCP:be:8081" in ov, ov           # 따옴표 없는 부분문자열(json.dumps 안전)
assert "be-bind:" not in ov, ("be 는 8081 자기서빙 → 사이드카 없어야", ov)   # self-skip
assert "cache-bind" not in ov, "image-only 서비스는 사이드카 없음"

# --- build_overlay: 혼합 — 한 사이드카가 host(redis)+service(be) 둘 다 ---
ov2=mc.build_overlay(SV, connectivity={"forward":{"6379":"host","8081":"be"}})
assert ov2.count("fe-bind:")==1, ("fe 사이드카는 하나(모든 포트)", ov2)
assert "TCP-LISTEN:6379" in ov2 and "host.docker.internal" in ov2, ov2   # host target
assert "TCP:be:8081" in ov2, ov2                                         # service target
assert "be-bind:" in ov2, ("be 도 6379(host) 는 받음", ov2)              # be 는 6379 만(8081 self)

print("ok forward")
PY
echo "PASS test-compose-forward"
```

- [ ] **Step 2: 실행 → 실패 확인**

Run: `bash plugin/tests/test-compose-forward.sh`
Expected: FAIL — `AttributeError: module 'mc' has no attribute '_forward_for_service'` (헬퍼 미존재).

- [ ] **Step 3: 헬퍼 추가 (`_forward_for_service`, `_bind_script`)**

`plugin/scripts/marina-compose.py` 의 `_dockerfile_case_fix` 함수 끝(현재 145행, `return None` 다음 빈 줄)과 `def build_overlay(` 사이에 추가:

```python
def _forward_for_service(forward: dict, svc: str):
    """그 서비스의 엮기 사이드카가 받을 [(port, target)]. target==svc(자기 자신이 서빙) 는 제외 —
    이미 localhost:port 가 자기 컨테이너에 닿고, socat TCP-LISTEN 이 그 포트를 두면 앱과 충돌하기 때문. 포트 오름차순."""
    out = []
    for port in sorted((p for p in forward if str(p).isdigit()), key=int):
        target = forward[port]
        if target == svc:
            continue
        out.append((port, target))
    return out


def _bind_script(pairs):
    """[(port, target)] → 엮기 사이드카의 `sh -c` 스크립트. target=host → host.docker.internal(없으면 리눅스
    default gateway 폴백 — network_mode:service 라 extra_hosts 무시), 그 외 → 같은 compose 서비스명(컨테이너 DNS).
    포트별 socat 1개를 백그라운드로 띄우고 wait. $$ = compose 가 리터럴 $ 로(변수확장 회피)."""
    lines = []
    if any(t == "host" for _, t in pairs):
        lines.append('H=host.docker.internal; nslookup "$$H" >/dev/null 2>&1 || '
                     "H=$$(ip route 2>/dev/null | awk '/default/{print $$3; exit}')")
    for port, target in pairs:
        dst = '"$$H"' if target == "host" else target
        lines.append(f'socat TCP-LISTEN:{port},fork,reuseaddr TCP:{dst}:{port} &')
    lines.append("wait")
    return "\n".join(lines)
```

- [ ] **Step 4: `build_overlay` 사이드카 블록 교체 (포트별 → 앱 서비스당 1개)**

`plugin/scripts/marina-compose.py` 현재 208-222행 블록:

```python
    hf_ports = sorted({str(p) for p in (connectivity.get("hostForward") or []) if str(p).isdigit()})   # ⑥ 프로젝트 단위 host-forward 포트(redis/db 등 — 앱 서비스마다 socat 사이드카)
    for fname in sorted(services):
        if not hf_ports or not (services[fname] or {}).get("build"):   # build(앱) 서비스에만 — image-only(redis 자체 등)는 사이드카 불요
            continue
        for fport in hf_ports:                                   # 앱이 localhost:port 그대로 쓰고 socat 이 호스트로 중계(앱 0수정·언어무관)
            script = ('H=host.docker.internal; nslookup "$$H" >/dev/null 2>&1 || '   # $$ = compose 가 literal $ 로(변수확장 회피). Mac/Docker Desktop=host.docker.internal, Linux(network_mode:service 라 extra_hosts 무시)=default gateway fallback(코덱스 #4)
                      "H=$$(ip route 2>/dev/null | awk '/default/{print $$3; exit}'); "
                      f'exec socat TCP-LISTEN:{fport},fork,reuseaddr TCP:"$$H":{fport}')
            out += [f"  {fname}-hostbind-{fport}:",
                    "    image: alpine/socat",
                    f'    network_mode: "service:{fname}"',
                    '    entrypoint: ["sh", "-c"]',
                    f"    command: [{json.dumps(script)}]",
                    "    restart: unless-stopped"]
            any_ = True
    return ("\n".join(out) + "\n") if any_ else ""
```

을 아래로 교체(끝의 `return` 은 유지):

```python
    forward = connectivity.get("forward") or {}                  # ⑥ 엮기 — {port: target}. target=host(호스트 redis/db) 또는 같은 compose 서비스명(DNS).
    for fname in sorted(services):                               # 앱(build) 서비스마다 사이드카 1개가 그 컨테이너의 모든 localhost 의존성 포트를 한 번에 받음
        if not (services[fname] or {}).get("build"):             # image-only(redis 자체 등)는 사이드카 불요 — DNS 로 바로 닿음
            continue
        pairs = _forward_for_service(forward, fname)             # self(자기서빙 포트) 제외
        if not pairs:
            continue
        out += [f"  {fname}-bind:",                              # 앱 0수정·언어무관: 앱이 localhost:port 그대로 쓰고 socat 이 타겟으로 중계
                "    image: alpine/socat",
                f'    network_mode: "service:{fname}"',          # 그 컨테이너의 localhost 를 가로챔
                '    entrypoint: ["sh", "-c"]',
                f"    command: [{json.dumps(_bind_script(pairs))}]",
                "    restart: unless-stopped"]
        any_ = True
    return ("\n".join(out) + "\n") if any_ else ""
```

또한 함수 상단 docstring 의 `⑥` 줄과 12행 위 주석(208행 직전까지)은 그대로 둔다. (`build_overlay` 의 `connectivity` 파라미터 설명은 Task 3 문서화 때 함께 손볼 수 있으나 동작엔 무관.)

- [ ] **Step 5: `_normalize_forward` 추가 + `_apply_connectivity` 반환 캐리어 교체**

`plugin/scripts/marina-compose.py` 의 `def _apply_connectivity(` (현재 273행) **바로 앞**에 추가:

```python
def _normalize_forward(conn: dict) -> dict:
    """backing.json 의 host-forward 선언 → {port(str): target(str)}. target="host"(host.docker.internal).
    소스: top-level hostForward(legacy) → host, 없으면 서비스별 hostForward(legacy) union → host.
    (신규 top-level `forward` 스키마 — service 타겟 포함 — 파싱은 Task 2 에서 이 함수 앞부분에 추가한다.)"""
    fwd: dict = {}
    for port in (conn.get("hostForward") or []):                 # legacy top-level → host
        p = str(port).strip()
        if p.isdigit():
            fwd[p] = "host"
    if not fwd:                                                  # legacy 서비스별 union → host (top-level 전무할 때만, 코덱스 #major)
        for _sc in (conn.get("services") or {}).values():
            for port in ((_sc or {}).get("hostForward") or []):
                p = str(port).strip()
                if p.isdigit():
                    fwd.setdefault(p, "host")
    return fwd
```

그리고 `_apply_connectivity` 안에서 현재 280-284행:

```python
    proj_hf = [str(p).strip() for p in (conn.get("hostForward") or []) if str(p).strip().isdigit()]   # 프로젝트 단위(top-level) host-forward 포트 — build_overlay 가 앱 서비스마다 사이드카(redis/db 는 프로젝트 인프라)
    if not proj_hf:                 # legacy 마이그레이션 — top-level 없으면 옛 서비스별 hostForward union(코덱스 #major)
        for _sc in (conn.get("services") or {}).values():
            proj_hf += [str(p).strip() for p in ((_sc or {}).get("hostForward") or []) if str(p).strip().isdigit()]
        proj_hf = sorted(set(proj_hf), key=int)
```

을 한 줄로 교체:

```python
    forward = _normalize_forward(conn)   # {port: target} — 엮기. 레거시 hostForward(전부 host) 흡수, 신규 forward 스키마는 Task 2
```

그리고 현재 319행 반환:

```python
    return extra_mounts, {"extraHosts": extra_hosts, "hostForward": proj_hf, "env": conn_env}
```

을:

```python
    return extra_mounts, {"extraHosts": extra_hosts, "forward": forward, "env": conn_env}
```

- [ ] **Step 6: `cmd_up` 사이드카 이름 계산 교체 (앱 서비스당 1개)**

`plugin/scripts/marina-compose.py` 현재 452-456행:

```python
    hf_ports = sorted({str(p) for p in (overlay_conn.get("hostForward") or []) if str(p).isdigit()})   # 프로젝트 단위 포트
    svc_cfg = config.get("services") or {}
    sidecars = [f"{svc}-hostbind-{port}"                           # host-forward 사이드카는 overlay 에만 있어 startable 엔 없음 → up 대상에 명시 추가(코덱스 #1). 앱(build) 서비스만.
                for svc in startable if (svc_cfg.get(svc) or {}).get("build")
                for port in hf_ports]
```

을:

```python
    forward = overlay_conn.get("forward") or {}                   # {port: target} — 엮기
    svc_cfg = config.get("services") or {}
    sidecars = [f"{svc}-bind"                                      # 엮기 사이드카는 overlay 에만 있어 startable 엔 없음 → up 대상에 명시 추가(코덱스 #1). 앱(build) 서비스마다 1개(받을 포트가 있을 때만).
                for svc in startable
                if (svc_cfg.get(svc) or {}).get("build") and _forward_for_service(forward, svc)]
```

- [ ] **Step 7: 기존 `test-compose-overlay.sh` 어서션 갱신 (캐리어/이름 rename)**

`plugin/tests/test-compose-overlay.sh` 에서 아래 4개의 반환-shape 어서션의 `"hostForward":[]` 를 `"forward":{}` 로 바꾼다:

- 90행 `assert _oc=={"extraHosts":[], "hostForward":[], "env":{}}, _oc` → `assert _oc=={"extraHosts":[], "forward":{}, "env":{}}, _oc`
- 98행 `assert _oc3=={"extraHosts":[], "hostForward":[], "env":{}}, _oc3` → `assert _oc3=={"extraHosts":[], "forward":{}, "env":{}}, _oc3`
- 110행 `assert _oc5=={"extraHosts":["be"], "hostForward":[], "env":{"be":{"REDIS.HOST":"host.docker.internal"}}}, _oc5` → `assert _oc5=={"extraHosts":["be"], "forward":{}, "env":{"be":{"REDIS.HOST":"host.docker.internal"}}}, _oc5`
- 114행 `assert _oc6=={"extraHosts":[], "hostForward":[], "env":{}}, _oc6` → `assert _oc6=={"extraHosts":[], "forward":{}, "env":{}}, _oc6`

그리고 현재 115-124행(host-forward 사이드카 + 레거시 union 블록):

```python
# host-forward — 프로젝트 단위(top-level) hostForward → 앱(build) 서비스마다 socat 사이드카. image-only 는 제외(앱 무수정·언어무관 범용)
_ovf=mc.build_overlay({"services":{"api":{"build":{"context":"."}}, "cache":{"image":"redis"}}}, connectivity={"hostForward":["6379"]})
assert "api-hostbind-6379:" in _ovf and "alpine/socat" in _ovf and 'network_mode: "service:api"' in _ovf, _ovf
assert "TCP-LISTEN:6379" in _ovf and "host.docker.internal" in _ovf, _ovf   # Linux fallback sh wrapper (host.docker.internal or default gateway)
assert "cache-hostbind" not in _ovf, "image-only 서비스는 사이드카 없음"
_,_ocf=mc._apply_connectivity({"hostForward":["6379","3306"],"services":{}},_d,_sess)
assert _ocf["hostForward"]==["6379","3306"], _ocf["hostForward"]
# legacy 마이그레이션 — top-level 없으면 옛 서비스별 hostForward 를 union(코덱스 #major)
_,_ocm=mc._apply_connectivity({"services":{"api":{"hostForward":["6379"]},"web":{"hostForward":["3306"]}}},_d,_sess)
assert _ocm["hostForward"]==["3306","6379"], _ocm["hostForward"]
```

을 (캐리어 `forward` dict + 사이드카 이름 `api-bind`로) 교체:

```python
# 엮기 사이드카 — forward(={port:target}) → 앱(build) 서비스마다 사이드카 1개. host=host.docker.internal. image-only 제외.
_ovf=mc.build_overlay({"services":{"api":{"build":{"context":"."}}, "cache":{"image":"redis"}}}, connectivity={"forward":{"6379":"host"}})
assert "api-bind:" in _ovf and "alpine/socat" in _ovf and 'network_mode: "service:api"' in _ovf, _ovf
assert "TCP-LISTEN:6379" in _ovf and "host.docker.internal" in _ovf, _ovf   # Linux fallback sh wrapper (host.docker.internal or default gateway)
assert "cache-bind" not in _ovf, "image-only 서비스는 사이드카 없음"
# 레거시 hostForward(전부 host) → forward dict 로 정규화
_,_ocf=mc._apply_connectivity({"hostForward":["6379","3306"],"services":{}},_d,_sess)
assert _ocf["forward"]=={"6379":"host","3306":"host"}, _ocf["forward"]
# legacy 마이그레이션 — top-level 없으면 옛 서비스별 hostForward → host (코덱스 #major)
_,_ocm=mc._apply_connectivity({"services":{"api":{"hostForward":["6379"]},"web":{"hostForward":["3306"]}}},_d,_sess)
assert _ocm["forward"]=={"6379":"host","3306":"host"}, _ocm["forward"]
```

- [ ] **Step 8: 두 테스트 + 전체 스위트 실행 → 통과 확인**

Run: `bash plugin/tests/test-compose-forward.sh` → Expected: `PASS test-compose-forward`
Run: `bash plugin/tests/test-compose-overlay.sh` → Expected: `PASS test-compose-overlay`
Run 전체: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done`
Expected: 모두 `PASS`/`SKIP`, `FAILED:` 없음.

- [ ] **Step 9: 커밋**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-overlay.sh plugin/tests/test-compose-forward.sh
git commit -m "feat(conn): 엮기 일반화 — forward{port:target} 로 앱 서비스당 사이드카 1개(host+service DNS, self-skip)

캐리어 hostForward[list]→forward{port:target} 으로 일반화. build_overlay 가 앱(build)
서비스마다 <svc>-bind 사이드카 1개를 만들어 그 컨테이너 모든 localhost 의존성을 각 타겟으로
중계(host=host.docker.internal, 서비스명=컨테이너 DNS). 자기 서빙 포트는 self-skip. 레거시
hostForward(전부 host)는 _normalize_forward 가 흡수."
```

---

## Task 2: `backing.json` 의 `forward` 선언 파싱 (service 타겟 wiring)

엔진(Task 1)은 service 타겟을 만들 수 있지만, 아직 `backing.json` 에서 그걸 선언하면 무시된다(`_normalize_forward` 가 레거시 `hostForward` 만 읽음). 이 태스크가 top-level `forward: {port: {target: service|host}}` 선언을 파싱해 service-target 을 **end-to-end** 동작시킨다.

**스키마(이번에 확정):** `~/.marina/<id>/backing.json` top-level
```json
{ "forward": { "8081": {"target": "be"}, "6379": {"target": "host"} } }
```
축약형 `{ "forward": { "8081": "be", "6379": "host" } }` 도 허용(값이 문자열이면 곧 target). 우선순위: top-level `forward` > top-level `hostForward`(레거시, host) > 서비스별 `hostForward`(레거시, host). `forward` 에 없는 레거시 포트는 host 로 병합.

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (`_normalize_forward` 앞부분에 `forward` 파싱 추가)
- Modify: `plugin/tests/test-compose-forward.sh` (`_apply_connectivity` forward-스키마 테스트 추가)

- [ ] **Step 1: 실패하는 테스트 추가**

`plugin/tests/test-compose-forward.sh` 에서 `print("ok forward")` **바로 앞**에 추가:

```python
# --- Task 2: _apply_connectivity 가 backing.json top-level forward 선언을 정규화 ---
import tempfile as _tf
_d=_tf.mkdtemp(); _sess=_tf.mkdtemp()
# 객체형 {target: ...}
_,oc=mc._apply_connectivity({"forward":{"8081":{"target":"be"},"6379":{"target":"host"}},"services":{}}, _d,_sess)
assert oc["forward"]=={"8081":"be","6379":"host"}, oc["forward"]
# 축약형 {port: "svc"|"host"}
_,oc2=mc._apply_connectivity({"forward":{"8081":"be"},"services":{}}, _d,_sess)
assert oc2["forward"]=={"8081":"be"}, oc2["forward"]
# 신규 forward 가 우선, 겹치지 않는 레거시 hostForward 는 host 로 병합
_,oc3=mc._apply_connectivity({"forward":{"8081":"be"},"hostForward":["6379"],"services":{}}, _d,_sess)
assert oc3["forward"]=={"8081":"be","6379":"host"}, oc3["forward"]
# 숫자 아닌 포트·빈 target 은 무시
_,oc4=mc._apply_connectivity({"forward":{"abc":"be","8081":{"target":""},"6379":"host"},"services":{}}, _d,_sess)
assert oc4["forward"]=={"6379":"host"}, oc4["forward"]
```

- [ ] **Step 2: 실행 → 실패 확인**

Run: `bash plugin/tests/test-compose-forward.sh`
Expected: FAIL — `AssertionError` (현재 `_normalize_forward` 는 top-level `forward` 를 안 읽어 `oc["forward"]=={}`).

- [ ] **Step 3: `_normalize_forward` 에 `forward` 파싱 추가**

`plugin/scripts/marina-compose.py` 의 `_normalize_forward` 를 (docstring 갱신 + 함수 본문 맨 앞에 `forward` 루프 추가):

```python
def _normalize_forward(conn: dict) -> dict:
    """backing.json 의 forward 선언 → {port(str): target(str)}. target="host"(host.docker.internal) 또는 같은 compose 서비스명(DNS).
    소스 우선순위: top-level forward(신규: {port:{target:svc|host}} 또는 {port:"svc"|"host"})
    > top-level hostForward(legacy, host) > 서비스별 hostForward(legacy, host)."""
    fwd: dict = {}
    for port, spec in (conn.get("forward") or {}).items():       # 신규 스키마
        p = str(port).strip()
        if not p.isdigit():
            continue
        tgt = spec.get("target") if isinstance(spec, dict) else spec
        tgt = str(tgt or "").strip()
        if tgt:
            fwd[p] = tgt
    for port in (conn.get("hostForward") or []):                 # legacy top-level → host (forward 에 없는 포트만)
        p = str(port).strip()
        if p.isdigit():
            fwd.setdefault(p, "host")
    if not fwd:                                                  # legacy 서비스별 union → host (top-level 전무할 때만, 코덱스 #major)
        for _sc in (conn.get("services") or {}).values():
            for port in ((_sc or {}).get("hostForward") or []):
                p = str(port).strip()
                if p.isdigit():
                    fwd.setdefault(p, "host")
    return fwd
```

(주의: `if not fwd:` 가드는 top-level `forward`·`hostForward` 둘 다 비었을 때만 서비스별 레거시로 폴백 — 의도된 동작.)

- [ ] **Step 4: 실행 → 통과 확인**

Run: `bash plugin/tests/test-compose-forward.sh` → Expected: `PASS test-compose-forward`
Run 전체: `for f in plugin/tests/test-*.sh; do echo "== $f"; bash "$f" || { echo "FAILED: $f"; break; }; done` → 모두 `PASS`/`SKIP`.

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-compose.py plugin/tests/test-compose-forward.sh
git commit -m "feat(conn): backing.json top-level forward{port:{target}} 선언 파싱 — service 타겟 end-to-end

_normalize_forward 가 신규 forward 스키마(객체형/축약형)를 우선 파싱하고 레거시 hostForward 를
host 로 병합. 이제 backing.json 에 forward:{8081:{target:be}} 선언하면 fe→be 엮기가 동작."
```

---

## Task 3: `forward` 스키마 + 엮기 동작 문서화

**Files:**
- Modify: `README.md` (compose 구성 — 자동 주입 표 아래에 엮기 문단 추가)

- [ ] **Step 1: README 에 엮기 문단 추가**

`README.md` 의 `## compose 구성 — 자동 주입 (ⓘ 구성뷰)` 섹션 끝 — 현재 197-199행의 `ⓘ 모달의 **📁 설정 파일** ...` 문단과 그 아래 `---`(201행) 사이 — 에 아래를 삽입:

```markdown

### 엮기 (서버측 localhost 자동 라우팅)

워크트리마다 compose 로 격리하면 앱이 코드에 박은 `localhost:<port>` 가 컨테이너 자기 자신을 가리켜 깨진다(fe(SSR)→be, be→redis 등). marina 는 `~/.marina/<id>/backing.json` 의 **`forward` 선언**을 진실로 삼아, 앱(build) 서비스마다 `alpine/socat` 사이드카 1개(`<svc>-bind`)를 붙여 그 컨테이너의 모든 `localhost:<port>` 를 대상으로 중계한다. **앱 0수정·언어무관**(JAR 내장 설정도 무관).

```json
{ "forward": {
    "8081": { "target": "be" },     // localhost:8081 → be:8081 (같은 compose 서비스, 컨테이너 DNS)
    "6379": { "target": "host" }    // localhost:6379 → host.docker.internal (호스트의 redis/db)
} }
```

- `target: "<서비스명>"` — 같은 compose 안 다른 서비스로(컨테이너 DNS). `target: "host"` — 개발자 PC 에 떠있는 인프라로(`host.docker.internal`, 리눅스는 default gateway 폴백).
- 사이드카는 `network_mode: service:<svc>` 로 그 컨테이너의 localhost 를 가로챈다. 자기 자신이 서빙하는 포트(예: be 의 8081)는 건너뛴다 — 이미 닿고, socat 이 그 포트를 두면 앱과 충돌하니까.
- 헤드리스 브라우저(E2E·에이전트)→be 도 컨테이너 안이라 엮기로 해결(동시 무제한). **호스트 브라우저**→be 만 별도(게이트웨이, 다음 단계).
- 레거시: top-level `hostForward: ["6379"]`(전부 host)도 그대로 받는다.
```

(`<svc>-bind` 사이드카는 `marina status`/`docker compose ps` 에 `<프로젝트>-<svc>-bind-1` 로 보인다.)

- [ ] **Step 2: 마크다운 렌더 확인 + 커밋**

Run: `git diff --stat README.md` — README.md 만 변경.
육안: 코드펜스/표 깨짐 없는지 확인(`forward` JSON 블록 닫힘, 인접 `---` 유지).

```bash
git add README.md
git commit -m "docs(readme): 엮기(forward{port:target}) 스키마·동작 문서화 — host/service 타겟·self-skip·사이드카"
```

---

## Self-Review

**1. Spec coverage (SPEC 1단계 항목 → 태스크 매핑):**
- "compose 선언 포트→서비스 매핑을 읽어 `localhost:8081→be:8081`(DNS)" → Task 1(엔진: service 타겟 `TCP:be:8081`) + Task 2(선언 파싱). ✅
- "`localhost:6379→호스트`" → Task 1(host 타겟, `host.docker.internal` + 리눅스 폴백 유지). ✅
- "한 사이드카가 그 컨테이너 모든 포트" → Task 1(`build_overlay` 가 앱 서비스당 `<svc>-bind` 1개, `_bind_script` 가 포트별 socat 다중). ✅
- "build(앱) 서비스마다 사이드카 1개" → Task 1(`if not build: continue` + `_forward_for_service`). ✅
- "backing.json 스키마(`port → {target: service|host}`)" → Task 2(`_normalize_forward` 객체형/축약형). ✅
- "건드릴 파일: `marina-compose.py`(`build_overlay`/`cmd_up`/`_apply_connectivity`)" → Task 1 의 Step 4/5/6 이 정확히 세 함수. ✅
- self-skip(자기 서빙 포트) → SPEC 명시는 아니나 consolidation 의 필수 안전장치(socat↔앱 포트 충돌). Task 1 에서 처리 + 테스트. ✅

**2. Placeholder scan:** 모든 Step 에 실제 코드/명령/기대출력 포함. "TBD/적절히 처리" 없음. ✅

**3. Type/이름 일관성:**
- `_forward_for_service(forward, svc) -> [(port, target)]` — Task 1 정의, `build_overlay`·`cmd_up`·테스트에서 동일 시그니처. ✅
- `_bind_script(pairs) -> str` — Task 1 정의, `build_overlay`·테스트 동일. ✅
- `_normalize_forward(conn) -> dict` — Task 1 정의(legacy), Task 2 확장(forward 파싱). 같은 이름·시그니처. ✅
- 캐리어 키 `forward`(dict) — `_apply_connectivity` 반환, `build_overlay`/`cmd_up` 읽기, 테스트 어서션 전부 `forward`. 잔존 `hostForward` 반환키 0(grep 확인: 영향 파일은 `marina-compose.py`·`test-compose-overlay.sh` 둘뿐). ✅
- 사이드카 이름 `<svc>-bind` — `build_overlay` 생성 / `cmd_up` up 대상 / 테스트 어서션 일치. ✅

**4. 알려진 트레이드오프 (형 검토용):**
- **사이드카 장애 격리:** 한 컨테이너에 socat 다중(`& … wait`). socat 하나가 죽어도 컨테이너는 안 죽어(다른 socat live) 그 포트만 조용히 끊긴다 — 포트별 컨테이너(이전)보다 격리 약함. socat 은 매우 안정적이라 실무 영향 작지만, 원하면 "자식 하나라도 죽으면 컨테이너 종료→restart"(ash 에선 `wait -n` 불안정 → PID 폴링 필요)로 강화 가능. SPEC 의 "한 사이드카" 지시를 우선해 단순 `wait` 채택.
- **미사용 리스너:** 1단계는 forward 포트를 모든 앱 서비스(self 제외)에 단다 — 그 앱이 실제로 그 의존성을 안 불러도 idle 리스너. 무해하나, 그 앱이 같은 포트를 자기 용도로 바인드하면 충돌 가능. 서비스별 정밀 스코핑은 3단계(검출). 기존 host-forward 도 동일 동작이라 회귀 아님.
- **타겟 오타:** `target` 이 없는 서비스명이면 런타임에 socat DNS 해석 실패(조용한 죽은 forward). 선언 검증은 3단계.

---

## Execution Handoff

계획 저장 완료. 두 실행 옵션:

1. **Subagent-Driven (추천)** — 태스크마다 fresh 서브에이전트 + 2단계 리뷰, 사이 검토. (`superpowers:subagent-driven-development`)
2. **Inline Execution** — 이 세션에서 체크포인트로 일괄 실행. (`superpowers:executing-plans`)

형 작업 스타일(자율 진행, 마지막에만 검토; 연계 기능은 SC 한 브랜치 누적)에 맞춰, 승인 시 **이 SC 워크트리에서 그대로 실행**하고 형은 끝에 브랜치 전체를 검토.