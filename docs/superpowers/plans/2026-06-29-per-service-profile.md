# marina per-service profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 구현=Claude(Edit/Write), 리뷰=codex([[marina-claude-implements-codex-reviews]]). 백엔드(Python TDD) 먼저 → UI.

**Goal:** 서비스마다 profile(`local`/`dev`…)을 marina 가 1급으로 관리 — 그 서비스가 실제 받는 build arg(감지)를 build-args overlay 로 주입하고, 런타임 env 로도 미러링해 하드코딩을 비파괴로 덮는다.

**Architecture:** 저장=기존 `build-args.json`(profile 변수 키) 재사용, 주입=기존 `build_overlay`(marina-overlay.yml)에 profile 후보 build arg 를 `environment` 로도 emit. stored compose 불변(주석 보존)·마이그레이션 없음. UI=ⓘ 패널 profile 컨트롤 + 카드 profile 칩(P0 칩 재사용).

**Tech Stack:** Python stdlib · bash · vanilla JS · 테스트 `plugin/tests/*.sh`(importlib 로 모듈 로드해 assert).

**Spec:** `docs/superpowers/specs/2026-06-29-per-service-profile-design.md`

---

## Task 0 — 사전 확인 (코드 안 고침)

- [ ] `grep -n "from marina_dockerfile import" plugin/scripts/marina-compose.py plugin/scripts/marina_compose_svc.py` — marina-compose.py 가 `marina_dockerfile` 를 import 가능한지 확인. 안 되면 Task 2 에서 후보집합/`is_profile_var` 를 marina-compose.py 에 inline(아래 코드의 주석 분기).
- [ ] `sed -n '435,475p' plugin/scripts/marina-compose.py` — `cmd_up` 이 `build_overlay(config, build_args=_parse_build_args(getattr(a,"build_arg",[])), connectivity=...)` 로 호출하는지 재확인(line 471 근처). build_args 가 이미 build_overlay 로 들어옴 = 추가 배선 불필요.
- [ ] `bash plugin/tests/test-compose-overlay.sh` 가 green 인지 확인(기존 overlay 테스트 — Task 2 가 확장).

---

## Phase 1 — 백엔드 (Python TDD)

### Task 1: profile 변수 감지 헬퍼

**Files:**
- Modify: `plugin/scripts/marina_dockerfile.py` (`_detect_injections` 아래, line 40 근처)
- Test: `plugin/tests/test-profile-detect.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-profile-detect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]
spec = importlib.util.spec_from_file_location("marina_dockerfile", os.path.join(sd, "marina_dockerfile.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# 후보 우선순위 첫 매칭
assert m.detect_profile_var(["JAVA_TOOL_OPTIONS", "PROFILE"]) == "PROFILE", "ARG PROFILE 매칭"
assert m.detect_profile_var(["SPRING_PROFILES_ACTIVE"]) == "SPRING_PROFILES_ACTIVE", "spring 직접"
assert m.detect_profile_var(["PROFILE", "APP_ENV"]) == "PROFILE", "우선순위(PROFILE>APP_ENV)"
assert m.detect_profile_var(["FOO", "BAR"]) is None, "후보 없음(web 류)→None"
assert m.detect_profile_var([]) is None
assert m.is_profile_var("profile") is True and m.is_profile_var("PROFILE") is True, "대소문자 무시"
assert m.is_profile_var("JAVA_TOOL_OPTIONS") is False
print("ok profile-detect")
PY
echo "PASS test-profile-detect"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-profile-detect.sh` → FAIL (`AttributeError: module ... has no attribute 'detect_profile_var'`).

- [ ] **Step 3: 구현** — `marina_dockerfile.py` 의 `_detect_injections` 정의 바로 아래에 추가:

```python
# profile(환경 선택) 변수 후보 — 우선순위 순. 프레임워크 표준 + mdc 관용(PROFILE).
# marina 는 이 중 그 서비스 Dockerfile 이 실제 선언한 ARG 를 profile 변수로 본다(추측 아님).
PROFILE_VAR_CANDIDATES = [
    "PROFILE", "SPRING_PROFILES_ACTIVE", "APP_ENV", "ASPNETCORE_ENVIRONMENT",
    "RAILS_ENV", "ENVIRONMENT", "STAGE", "ENV", "NODE_ENV",
]
_PROFILE_SET = {c.upper() for c in PROFILE_VAR_CANDIDATES}

def is_profile_var(name: str) -> bool:
    return bool(name) and str(name).upper() in _PROFILE_SET

def detect_profile_var(args) -> "str|None":
    """ARG 이름 목록 → profile 변수(후보 우선순위 첫 매칭) 또는 None."""
    up = {str(a).upper(): a for a in (args or [])}
    for c in PROFILE_VAR_CANDIDATES:
        if c.upper() in up:
            return up[c.upper()]
    return None
```

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-profile-detect.sh` → `PASS test-profile-detect`.

- [ ] **Step 5: 커밋**

```bash
chmod +x plugin/tests/test-profile-detect.sh
git add plugin/scripts/marina_dockerfile.py plugin/tests/test-profile-detect.sh
git commit -m "feat(profile): detect_profile_var/is_profile_var — ARG 에서 profile 변수 감지"
```

### Task 2: build_overlay 가 profile build arg 를 런타임 env 로 미러링

**Files:**
- Modify: `plugin/scripts/marina-compose.py` (`build_overlay`, line 272~330; import 부)
- Test: `plugin/tests/test-profile-overlay.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-profile-overlay.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]
spec = importlib.util.spec_from_file_location("marina_compose", os.path.join(sd, "marina-compose.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
config = {"services": {
    "ai-index": {"build": {"context": "./ai-api", "dockerfile": "index_api/Dockerfile.local"}},
    "user-api": {"build": {"context": "./be-api/user-api", "dockerfile": "DockerFile"}},
}}
ba = {"ai-index": {"PROFILE": "dev", "EXTRA": "x"}, "user-api": {"PROFILE": "local"}}
out = m.build_overlay(config, build_args=ba)
# profile 후보(PROFILE)는 environment 로도 미러링
assert "ai-index" in out and "environment:" in out, out
assert "PROFILE: \"dev\"" in out, ("env 미러 dev 누락", out)
assert "PROFILE: \"local\"" in out, ("user-api env 미러 누락", out)
# profile 후보 아닌 build arg(EXTRA)는 env 미러링 안 함 — args 로만
assert "EXTRA:" in out, "build args 자체는 유지"
# EXTRA 가 environment 블록엔 안 들어감: ai-index environment 에 PROFILE 만
seg = out.split("ai-index:",1)[1].split("user-api:",1)[0]
assert "EXTRA" in seg and seg.count("environment:") == 1
env_part = seg.split("environment:",1)[1]
assert "PROFILE" in env_part and "EXTRA" not in env_part, ("EXTRA 가 env 로 새면 안 됨", env_part)
print("ok profile-overlay")
PY
echo "PASS test-profile-overlay"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-profile-overlay.sh` → FAIL (env 미러링 없음 → `PROFILE: "dev"` 미발견).

- [ ] **Step 3: 구현** — `marina-compose.py` 상단 import 에 추가(Task 0 에서 import 가능 확인 시):

```python
from marina_dockerfile import is_profile_var
```
(import 불가 판명 시 inline: `def is_profile_var(n): return bool(n) and str(n).upper() in {"PROFILE","SPRING_PROFILES_ACTIVE","APP_ENV","ASPNETCORE_ENVIRONMENT","RAILS_ENV","ENVIRONMENT","STAGE","ENV","NODE_ENV"}`)

그리고 `build_overlay` 의 build 블록 처리 직후(`if build_block: body += ["    build:", *build_block]` 다음 줄)에 추가:

```python
        # profile 후보 build arg 는 런타임 environment 로도 미러링 — stored 의 하드코딩 env 를
        # overlay 머지에서 덮어 profile 이 런타임에도 적용되게(ai-api 케이스). stored compose 불변.
        prof_env = {k: margs[k] for k in margs if is_profile_var(k)}
        if prof_env:
            body.append("    environment:")
            for k in sorted(prof_env):
                body.append(f"      {k}: {json.dumps(str(prof_env[k]))}")
```

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-profile-overlay.sh` → `PASS`. 또한 `bash plugin/tests/test-compose-overlay.sh` → 기존 green 유지.

- [ ] **Step 5: 커밋**

```bash
chmod +x plugin/tests/test-profile-overlay.sh
git add plugin/scripts/marina-compose.py plugin/tests/test-profile-overlay.sh
git commit -m "feat(profile): build_overlay 가 profile build arg 를 런타임 env 로 미러링(비파괴 override)"
```

### Task 3: compose_resolved_view 에 profileVar/profileValue 노출

**Files:**
- Modify: `plugin/scripts/marina_compose_svc.py` (`compose_resolved_view`, 서비스 dict append, line 330~344; import 부 line 20)
- Test: `plugin/tests/test-profile-config.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-profile-config.sh`(순수 함수 단위 — `_detect_injections` 결과 + build-args 로 profileVar/Value 산출 로직만 검증하도록, `_service_profile(injections_args, marina_build_args, stored_build_args)` 헬퍼를 둔다):

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]
spec = importlib.util.spec_from_file_location("marina_compose_svc", os.path.join(sd, "marina_compose_svc.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# var 감지 + 값 우선순위(marina overlay > stored)
assert m._service_profile(["PROFILE"], {"PROFILE": "dev"}, {"PROFILE": "local"}) == {"profileVar": "PROFILE", "profileValue": "dev"}
assert m._service_profile(["PROFILE"], {}, {"PROFILE": "local"}) == {"profileVar": "PROFILE", "profileValue": "local"}
assert m._service_profile(["FOO"], {}, {}) == {"profileVar": None, "profileValue": ""}
print("ok profile-config")
PY
echo "PASS test-profile-config"
```

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-profile-config.sh` → FAIL (`_service_profile` 없음).

- [ ] **Step 3: 구현** — `marina_compose_svc.py` import(line 20) 를 `from marina_dockerfile import _detect_injections, _prebuild_suggest, detect_profile_var` 로 확장하고, `compose_resolved_view` 위에 헬퍼 추가:

```python
def _service_profile(arg_names, marina_build_args, stored_build_args) -> dict:
    """ARG 목록 + (marina overlay build args, stored build args) → {profileVar, profileValue}.
    값은 marina overlay 우선, 없으면 stored, 둘 다 없으면 ''."""
    var = detect_profile_var(arg_names)
    if not var:
        return {"profileVar": None, "profileValue": ""}
    val = (marina_build_args or {}).get(var)
    if val is None:
        val = (stored_build_args or {}).get(var)
    return {"profileVar": var, "profileValue": "" if val is None else str(val)}
```

그리고 서비스 dict append(line 330~344)에서 `injections` 산출 결과와 build args 로 profile 추가. append 직전에:

```python
            _inj = _detect_injections(df_text or "")
            _stored_ba = (b.get("args") if isinstance(b, dict) and isinstance(b.get("args"), dict) else {})
            _mba = (ba_all.get(name) if isinstance(ba_all.get(name), dict) else {})
```
그리고 dict 의 `"injections": _detect_injections(df_text or ""),` 를 `"injections": _inj,` 로 바꾸고, `"marinaBuildArgs": _mba,` 로 바꾼 뒤 dict 에 `**_service_profile(_inj["args"], _mba, _stored_ba),` 추가.

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-profile-config.sh` → `PASS`. `bash plugin/tests/test-compose-config.sh` → 기존 green.

- [ ] **Step 5: 커밋**

```bash
chmod +x plugin/tests/test-profile-config.sh
git add plugin/scripts/marina_compose_svc.py plugin/tests/test-profile-config.sh
git commit -m "feat(profile): compose_resolved_view 에 profileVar/profileValue 노출"
```

### Task 4: /api/compose-service-profile 저장 엔드포인트

**Files:**
- Modify: `plugin/scripts/marina_handler.py` (`/api/compose-service-args` 핸들러 옆, line 352~370)
- Test: `plugin/tests/test-profile-api.sh` (신규)

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-profile-api.sh`: 임시 MARINA_HOME 에 mdc 형 프로젝트 등록 후 `POST /api/compose-service-profile {root, service, value}` → `build-args.json[service]` 에 감지된 var=value 저장 확인, 잘못된 입력(service 없음) → 4xx. (`test-compose-register-api.sh` 의 서버 기동 하네스 복제 — `MARINA_CONTROL_PORT`/`MARINA_HOME` 로 marina-control.py 띄우고 curl.) value 저장 후 `GET /api/compose-config` 에 `profileValue` 반영 확인.

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# (test-compose-register-api.sh 의 setup 패턴 복제: 임시 repo+Dockerfile[ARG PROFILE], compose 등록, 서버 기동)
# … 서버 기동 후 …
code=$(curl -s -o /tmp/pp.json -w "%{http_code}" -X POST "$BASE/api/compose-service-profile" \
  -H 'content-type: application/json' -d '{"root":"'"$P"'","service":"web","value":"dev"}')
[ "$code" = "200" ] || { echo "expected 200 got $code"; cat /tmp/pp.json; exit 1; }
python3 -c "import json;d=json.load(open('$MARINA_HOME/'+open('/tmp/pid').read().strip()+'/build-args.json'));assert d.get('web',{}).get('PROFILE')=='dev',d"
# 잘못된 입력
bad=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/compose-service-profile" -H 'content-type: application/json' -d '{"root":"'"$P"'"}')
[ "$bad" = "400" ] || { echo "expected 400 got $bad"; exit 1; }
echo "PASS test-profile-api"
```
(setup 세부는 `test-compose-register-api.sh` 를 읽어 동일 변수[$BASE/$P/$MARINA_HOME/pid]로 채운다.)

- [ ] **Step 2: 실패 확인** — Run: `bash plugin/tests/test-profile-api.sh` → FAIL (404/405 — 엔드포인트 없음).

- [ ] **Step 3: 구현** — `marina_handler.py` 의 `/api/compose-service-args` 핸들러(line 352) 바로 뒤에 추가. var 는 요청 `var` 있으면 그것, 없으면 그 서비스 Dockerfile ARG 에서 감지(`compose_resolved_view` 의 해당 서비스 `profileVar`). 저장은 build-args.json 의 그 키:

```python
            if self.path == "/api/compose-service-profile":   # profile = build-args.json 의 profile 변수 키
                root = _norm(body.get("root", "")); service = str(body.get("service", "")).strip()
                value = str(body.get("value", "")).strip()
                if not root or not service:
                    return self.send_json({"ok": False, "error": "root·service 필수"}, status=400)
                proj = _project_for_root(root)            # 기존 헬퍼(다른 핸들러와 동일 해석)
                if not proj:
                    return self.send_json({"ok": False, "error": "프로젝트 미해석"}, status=400)
                var = str(body.get("var", "")).strip()
                if not var:                                # 감지: 그 서비스 resolved view 의 profileVar
                    view = compose_resolved_view(Path(root), proj)
                    svc = next((s for s in (view.get("services") or []) if s.get("service") == service), None)
                    var = (svc or {}).get("profileVar") or ""
                if not var:
                    return self.send_json({"ok": False, "error": "이 서비스에서 profile 변수를 찾지 못했습니다"}, status=400)
                d = MARINA_HOME / str(proj["id"]); d.mkdir(parents=True, exist_ok=True)
                bf = d / "build-args.json"
                try:
                    ba = json.loads(bf.read_text(encoding="utf-8"))
                except Exception:
                    ba = {}
                ba.setdefault(service, {})
                if value:
                    ba[service][var] = value
                else:
                    ba[service].pop(var, None)             # 빈 값 = 해제(stored 기본값으로)
                bf.write_text(json.dumps(ba, ensure_ascii=False, indent=2), encoding="utf-8")
                return self.send_json({"ok": True, "var": var, "value": value})
```
(`_project_for_root`/`_norm`/`compose_resolved_view`/`MARINA_HOME`/`Path` 는 `/api/compose-service-args` 핸들러와 동일 출처 — 그 핸들러를 읽어 정확한 이름으로 맞춘다. 다르면 거기 쓰는 방식 그대로.)

- [ ] **Step 4: 통과 확인** — Run: `bash plugin/tests/test-profile-api.sh` → `PASS`.

- [ ] **Step 5: 커밋**

```bash
chmod +x plugin/tests/test-profile-api.sh
git add plugin/scripts/marina_handler.py plugin/tests/test-profile-api.sh
git commit -m "feat(profile): /api/compose-service-profile — build-args.json 에 profile 저장(감지 var)"
```

### Task 5 (Phase 1 끝): codex 리뷰

- [ ] `codex review --commit <Task4 커밋>` (또는 `--base <Phase1 시작 전>`). 지적 반영, 재검증. 기존 54 + 신규 4 테스트 green 확인: `for t in profile-detect profile-overlay profile-config profile-api; do bash plugin/tests/test-$t.sh; done`.

---

## Phase 2 — UI (marina-web)

### Task 6: ⓘ 서비스 구성 패널에 profile 컨트롤

**Files:**
- Modify: `plugin/scripts/marina-web/app-5-sessions.js` (`renderServiceConfig` line 393~444, `wireBuildArgsSave` line 451~499)
- Modify: `plugin/scripts/marina-web/index.html` (datalist 추가) · `styles.css`(필요 시)

- [ ] **Step 1: profile 컨트롤 마크업** — `renderServiceConfig(s)` 의 build args 블록(line 426~430) **위**에, `s.profileVar` 있을 때만 profile 행 추가:

```javascript
      if (s.profileVar) {
        const pvId = 'pv-' + s.service.replace(/[^a-z0-9_-]/gi, '_');
        html += `<div style="margin:0 0 12px"><div style="color:${muted};margin-bottom:4px">⚙️ profile <span title="이 서비스가 받는 환경 선택 변수(${escapeHtml(s.profileVar)}) — build arg + 런타임 env 로 주입. 변경 시 다음 시작에 재빌드.">(${escapeHtml(s.profileVar)})</span></div>
          <input id="${pvId}" list="profileSuggest" value="${escapeHtml(s.profileValue || '')}" placeholder="local" style="width:160px;box-sizing:border-box;font-family:ui-monospace,monospace;font-size:12px;background:var(--sys-bg-base);color:var(--sys-cont-neutral-default);border:1px solid var(--sys-style-neutral-light);border-radius:6px;padding:6px">
          <button class="svc-llm-go pv-save" data-service="${escapeHtml(s.service)}" data-var="${escapeHtml(s.profileVar)}" data-target="${pvId}" style="margin-left:6px">💾 저장</button></div>`;
      } else {
        html += `<div style="margin:0 0 12px;color:${muted};font-size:11px">이 서비스는 profile 변수가 없습니다(환경은 compose 의 command/env_file 로 자기완결).</div>`;
      }
```
그리고 `index.html` 의 `</body>` 앞에 datalist 추가(없으면): `<datalist id="profileSuggest"><option value="local"><option value="dev"><option value="prod"><option value="staging"></datalist>`.

- [ ] **Step 2: 저장 와이어링** — `wireBuildArgsSave(container, root)` 안(line 499 닫기 전)에 추가:

```javascript
      container.querySelectorAll('.pv-save').forEach(btn => {
        wireDirty(btn);
        btn.onclick = async () => {
          const service = btn.dataset.service, value = (document.getElementById(btn.dataset.target)?.value || '').trim();
          const orig = btn.textContent; btn.disabled = true; btn.textContent = '저장 중…';
          let ok = false;
          try {
            const resp = await fetch('/api/compose-service-profile', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({root, service, value})});
            const r = await resp.json(); ok = !!(r && r.ok);
            btn.textContent = ok ? '✓ 저장됨 (다음 시작/재시작 적용 · 재빌드)' : ('실패: ' + ((r && r.error) || '?'));
          } catch (e) { btn.textContent = '실패: ' + String((e && e.message) || e); }
          setTimeout(() => { btn.textContent = orig; btn.disabled = ok; }, 2600);
        };
      });
```

- [ ] **Step 3: 검증(Aside)** — 격리 인스턴스(`MARINA_CONTROL_PORT/MARINA_HOME` + mdc 형 더미)로 ⓘ 열어 profile 행 표시·저장→build-args.json 반영·profile 변수 없는 서비스는 안내문구. `node --check app-5-sessions.js`. 콘솔에러0.

- [ ] **Step 4: 커밋** — `git commit -am "feat(profile): ⓘ 패널 profile 컨트롤(감지 var 표시·저장)"`

### Task 7: 카드 service-chip 에 profile 칩

**Files:**
- Modify: `plugin/scripts/marina-web/app-5-sessions.js` (`serviceChip` line ~9, 또는 별도 profile 칩) · `styles.css`

- [ ] **Step 1: 데이터 전달** — 카드 렌더는 `session.services`(dash 응답) 기반이라 profile 값을 알아야 한다. dash 서비스 dict 에 `profile`(현재 값) 이 없으면, `serviceChip` 은 일단 표시 생략하고, **profile 칩은 ⓘ 가 아닌 dash 응답에 profile 추가가 필요**한지 Task 0 처럼 확인: `grep -n "build_compose_services\|def .*dash\|services.append" plugin/scripts/marina_*.py` 로 dash 서비스 산출부 찾기. 거기 `profile` 값(build-args.json 의 profile 변수 값 또는 stored)을 추가.

- [ ] **Step 2: 칩 렌더** — `serviceChip(session, svc)` 에서 `svc.profile` 있으면 P0 칩 옆에 작은 profile 칩:

```javascript
      const prof = (svc.profile ?? '') !== '' ? `<span class="svc-chip-prof" title="profile">${escapeHtml(String(svc.profile))}</span>` : '';
```
그리고 chip 템플릿 `nm` 다음, `pt` 앞에 `${prof}` 삽입. CSS `styles.css`:

```css
    .svc-chip .svc-chip-prof { flex-shrink: 0; padding: 0 5px; border-radius: 4px; background: var(--sys-style-neutral-light); color: var(--sys-cont-neutral-light); font-size: 10px; font-weight: 700; }
```
(profile 변수 없는 서비스는 `svc.profile` 빈값 → 칩 없음.)

- [ ] **Step 3: 검증(Aside)** — 합성 세션 주입(P0 검증 방식)으로 profile 있는 서비스는 칩, 없는(web) 서비스는 칩 없음. `node --check`. 콘솔에러0.

- [ ] **Step 4: 커밋** — `git commit -am "feat(profile): 카드 service-chip 에 profile 칩"`

### Task 8 (Phase 2 끝): codex 리뷰 + 실 docker 검증

- [ ] `codex review --commit <Task7 커밋>` 지적 반영.
- [ ] 실 docker 1케이스(가능 시): mdc 형 더미 프로젝트에서 service profile=dev 저장 → `marina start` → `docker compose -p <name> config` 또는 컨테이너 env 로 `PROFILE=dev` 확인(overlay env 미러링 실동작). stored compose 불변 확인(`git -C ~/.marina ... ` 아니라 파일 mtime/내용 그대로).

---

## Self-Review (작성자 체크 — 완료)
- **Spec 커버**: §1 저장(build-args.json)→T4 · §2 감지→T1 · §3 마이그레이션 없음→(코드 없음, T3 가 stored 기본값 읽음) · §4 주입(build_overlay env 미러)→T2 · §5 API→T4 · §6 UI(컨트롤·칩)→T6·T7 · §경계(web)→T6 안내문구·T7 칩없음. 갭 없음.
- **타입 일관**: `detect_profile_var`/`is_profile_var`(T1) ↔ `_service_profile`(T3) ↔ `profileVar`/`profileValue`(T3·T6) ↔ `/api/compose-service-profile`(T4·T6) ↔ `svc.profile`(T7) 명칭 통일.
- **Placeholder**: 각 백엔드 task 에 실제 테스트·코드. UI 는 컴포넌트 코드 명시. T7 Step1 은 dash 산출부 위치 확인(코드는 그때 정확히) — 의도된 탐색 단계.

## 다음 세션 핸드오프
1. Task 0 → Phase 1(T1~5) 백엔드 TDD → Phase 2(T6~8) UI. 백엔드 먼저=안전.
2. 각 task 끝 commit, Phase 끝 codex 리뷰.
3. 기존 54 테스트 + 신규 4 회귀 유지. 전부 로컬 main(미push) — 형 검토 후 push.
