#!/usr/bin/env bash
# marina-lib-links.sh — marina.sh 에서 분리된 links 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

# heavy/gitignored 디렉토리·설정을 main(SOURCE_ROOT)→worktree 로 symlink 하는 기본 링크 룰.
# attach 의 숨은 sync(node_modules 빠짐) 를 대체 — 보임(marina config)·override(null)로 끔·node_modules 포함.
# 무거운 것은 종류 불문 main 에서 공유(재생성/재빌드 안 함) — deps + 빌드출력. 빌드출력은 stale 가능하나 "갖다 쓰는" 게 이득(형).
# 주의: 빌드출력 심링크는 워크트리에서 다시 빌드하면 main 으로 써질 수 있음(증분 빌드) — clean 빌드는 링크를 실폴더로 교체, marina 는 실폴더면 안 건드림. 워크트리별 override(null)로 끔.
# mental model: links 우선순위는 기본(default) < 프로젝트 공유(central links.json) < service.links < 워크트리 override.
# 빌드출력(build·dist·out·target·.next·*.jar)은 기본 자동링크에서 제외 — 워크트리별 독립 빌드(spec §2,
# docker 빌드컨텍스트 심링크 깨짐=user-api JAR 버그 근본원인). 가져오려면 x-marina.links 에 명시(opt-in).
_DEFAULT_LINKS_JSON='{"node_modules":{"glob":"node_modules","kind":"dir"},".venv":{"glob":".venv","kind":"dir"},"local-yml":{"glob":"*local.yml","kind":"file"},"local-env":{"glob":".env*.local","kind":"file"}}'

# 프로젝트 단위 커스텀 base 링크(~/.marina/<id>/links.json = {name: rule}) — 모든 워크트리 공유, 앱 레포 불변.
# 대시보드 탐색기 등록이 여기 저장. rule 은 {glob,kind[,mode,subrepo]} — mode=copy 면 복제, 비면 symlink.
central_links_json() {
  python3 - "$ROOT" "$SOURCE_ROOT" "$PROJECTS_FILE" "$MARINA_HOME" <<'PY'
import json, os, sys
root, source_root, projects_file, home = sys.argv[1:5]
def norm(p): return os.path.realpath(os.path.expanduser(p))
pid = ""
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    tgt = {norm(source_root), norm(root)}
    for p in data.get("projects", []):
        pr = norm(p.get("root", ""))
        if pr in tgt or any(t == pr or t.startswith(pr + os.sep) for t in tgt):
            pid = p.get("id", ""); break
except Exception:
    pass
out = {}
if pid:
    try:
        d = json.load(open(os.path.join(home, pid, "links.json"), encoding="utf-8"))
        out = d.get("links", d) if isinstance(d, dict) else {}
        if not isinstance(out, dict):
            out = {}
    except Exception:
        out = {}
print(json.dumps(out, ensure_ascii=False))
PY
}

# glob 링크 룰(기본 < 프로젝트 공유 < service.links < 워크트리 override) 을 service 의 서브레포(cwd 첫 segment) 기준으로 적용.
# mode=copy 는 복제, 그 외는 symlink. idempotent·best-effort. source==dest(main)면 skip.
apply_glob_links() {
  local service="$1" stored="${2:-}" cp="${3:-}" cwd _xml=""
  cwd="$(service_json_field "$service" cwd)"
  # x-marina.links {symlink:[],copy:[]} (보관 compose, opt-in SoT) — 있으면 그것만 적용(레거시 글롭 무시).
  [[ -n "$stored" && -n "$cp" && -f "$stored" ]] && _xml="$(python3 "$cp" xmarina --stored "$stored" --key links 2>/dev/null)"
  python3 - "$(merged_services_json)" "$service" "$(overrides_json_file)" "$_DEFAULT_LINKS_JSON" "$SOURCE_ROOT" "$ROOT" "${cwd:-.}" "$(central_links_json)" "$_xml" <<'PY'
import json, sys, os, fnmatch, shutil
data = json.loads(sys.argv[1]); service = sys.argv[2]; ovr_path = sys.argv[3]
defaults = json.loads(sys.argv[4]); source_root = sys.argv[5]; root = sys.argv[6]; cwd = sys.argv[7]
central = json.loads(sys.argv[8]) if len(sys.argv) > 8 and sys.argv[8].strip() else {}
xmlinks = json.loads(sys.argv[9]) if len(sys.argv) > 9 and sys.argv[9].strip() else {}   # x-marina.links
sub = cwd.split("/")[0] if cwd and cwd != "." else "."
# ops: [(glob, op)] — op in {symlink, copy}. x-marina.links 있으면 그 명시 리스트만(빌드출력은 목록 외=자동 제외).
ops = []
if isinstance(xmlinks, dict) and ("symlink" in xmlinks or "copy" in xmlinks):   # 키 존재로 판정 — 빈 리스트는 '아무것도 안 함' opt-out(legacy 폴백 아님)
    for g in (xmlinks.get("symlink") or []):
        if isinstance(g, str) and g.strip():
            ops.append((g.strip(), "symlink"))
    for g in (xmlinks.get("copy") or []):
        if isinstance(g, str) and g.strip():
            ops.append((g.strip(), "copy"))
else:                                  # 레거시 fallback: 기본<central<service<override 레이어(빌드출력은 defaults 에서 제거됨), 전부 symlink
    rules = dict(defaults)
    for k, v in central.items():       # 프로젝트 커스텀 base — subrepo 필드 있으면 그 서브레포만(구조 열어둠)
        if isinstance(v, dict) and v.get("subrepo") and v.get("subrepo") != sub:
            continue
        rules[k] = v
    svc = next((s for s in data.get("services", []) if s.get("name") == service), None) or {}
    for k, v in (svc.get("links") or {}).items():
        rules[k] = v
    try:
        ov = json.load(open(ovr_path, encoding="utf-8"))
        ol = {**((ov.get("links") or {}).get("") or {}), **((ov.get("links") or {}).get(service) or {})}   # 워크트리레벨("") + 서비스별(우선)
    except Exception:
        ol = {}
    for k, v in ol.items():
        if v is None:
            rules.pop(k, None)
        else:
            rules[k] = v
    for k, r in rules.items():
        if isinstance(r, dict) and r.get("glob"):
            op = "copy" if r.get("mode") == "copy" or r.get("op") == "copy" else "symlink"
            ops.append((r["glob"], op))
if not ops:
    sys.exit(0)
src_base = os.path.join(source_root, sub) if sub != "." else source_root
dst_base = os.path.join(root, sub) if sub != "." else root
if not os.path.isdir(src_base) or os.path.realpath(src_base) == os.path.realpath(dst_base):
    sys.exit(0)
NEVER = {".git", ".claude"}             # 절대 링크/순회 안 함
BUILDDIRS = {"build", "dist", "out", "target", ".next"}   # 빌드트리 — 명시 글롭이 내려갈 때만 descend(안의 config 딸려오는 것 방지)
DEPDIRS = {"node_modules", ".venv"}     # 거대 의존성 — 통째 매치(opt-in)는 prune 전, 안으로는 명시 글롭 있을 때만
dst_base_real = os.path.realpath(dst_base)
def under_dst(dp, d):
    rp = os.path.realpath(os.path.join(dp, d))
    return rp == dst_base_real or rp.startswith(dst_base_real + os.sep)
def fmatch(name, abs_path, g):          # basename·소스상대경로 매치 + globstar(**/) 지원
    rel = os.path.relpath(abs_path, src_base)
    if fnmatch.fnmatch(name, g):
        return True
    if "/" in g and fnmatch.fnmatch(rel, g):
        return True
    if "**/" in g:                      # **/ = 0+ 세그먼트 → globstar 제거한 tail 을 basename/relpath 에 매치(루트 직속 포함)
        tail = g.rsplit("**/", 1)[-1]
        return fnmatch.fnmatch(name, tail) or fnmatch.fnmatch(rel, tail)
    return False
def apply_op(src_abs, op):
    rel = os.path.relpath(src_abs, src_base); dst = os.path.join(dst_base, rel)
    if os.path.realpath(src_abs) == os.path.realpath(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if op == "copy":                   # 독립 복제 — 기존 심링크는 교체, 실파일은 보존(사용자 편집)
        if os.path.islink(dst):
            os.unlink(dst)
        elif os.path.exists(dst):
            print("copy skip(존재·실파일):", rel); return
        if os.path.isdir(src_abs):
            shutil.copytree(src_abs, dst)
        else:
            shutil.copy2(src_abs, dst)
        print("copy:", rel)
    else:                              # symlink — 공유
        if os.path.islink(dst):
            os.unlink(dst); os.symlink(src_abs, dst); print("link:", rel)
        elif os.path.exists(dst):
            print("link skip(존재·실파일):", rel)
        else:
            os.symlink(src_abs, dst); print("link:", rel)
for g, op in ops:
    g_eff = g.rsplit("**/", 1)[-1] if "**/" in g else g     # globstar 제거한 유효 경로 — descend 판정용
    g_first = g_eff.split("/", 1)[0] if "/" in g_eff else g_eff
    descends = "/" in g_eff                                  # 유효 경로가 디렉터리로 내려가나(build/libs/app.jar 등)
    for dp, dns, fns in os.walk(src_base, followlinks=False):
        matched = [d for d in dns if fmatch(d, os.path.join(dp, d), g) and not under_dst(dp, d)]   # dir 매치 → 통째 적용 후 안 내려감
        for d in matched:
            apply_op(os.path.join(dp, d), op)
        def keep(d):
            if d in matched or d in NEVER or under_dst(dp, d):
                return False
            if d in DEPDIRS or d in BUILDDIRS:              # dep·빌드트리: 명시 글롭이 이 디렉터리로 내려갈 때만 descend(아니면 안 들어감)
                return descends and fnmatch.fnmatch(d, g_first)
            return True
        dns[:] = [d for d in dns if keep(d)]
        for f in fns:
            if fmatch(f, os.path.join(dp, f), g):
                apply_op(os.path.join(dp, f), op)
PY
}

# 서비스의 effective links 를 JSON 으로 출력 (대시보드용).
# 우선순위: 기본(default) < 프로젝트 공유(central) < service.links < 워크트리 override(null=끄기).
# [{name, source: default|service|override, disabled: bool, rule: {...}}]
links_json() {
  local service="$1" subrepo="${2:-}" cwd
  cwd="$(service_json_field "$service" cwd)"
  python3 - "$(merged_services_json)" "$service" "$(overrides_json_file)" "$_DEFAULT_LINKS_JSON" "$(central_links_json)" "$SOURCE_ROOT" "$ROOT" "${cwd:-.}" "$subrepo" <<'PY'
import json, sys, os, fnmatch
data = json.loads(sys.argv[1]); service = sys.argv[2]; ovr_path = sys.argv[3]
defaults = json.loads(sys.argv[4])
central_raw = json.loads(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].strip() else {}
source_root = sys.argv[6] if len(sys.argv) > 6 else ""
root = sys.argv[7] if len(sys.argv) > 7 else ""
cwd = sys.argv[8] if len(sys.argv) > 8 else "."
subrepo = sys.argv[9] if len(sys.argv) > 9 else ""   # 명시 서브레포(compose 정밀 present) — 있으면 cwd 대신
svc = next((s for s in data.get("services", []) if s.get("name") == service), None) or {}
svc_links = svc.get("links") or {}
sub = subrepo if subrepo else (cwd.split("/")[0] if cwd and cwd != "." else ".")
central = {}
for k, v in central_raw.items():                        # 프로젝트 공유 링크가 특정 subrepo 용이면 해당 탭에서만 표시
    if isinstance(v, dict) and v.get("subrepo") and v.get("subrepo") != sub:
        continue
    central[k] = v
base = dict(defaults); base.update(central); base.update(svc_links)   # 기본 < 프로젝트 커스텀(central) < 앱레포 service
try:
    ov = json.load(open(ovr_path, encoding="utf-8"))
    olinks_raw = {**((ov.get("links") or {}).get("") or {}), **((ov.get("links") or {}).get(service) or {})}   # 워크트리레벨("")+서비스별(우선)
except Exception:
    olinks_raw = {}
olinks = {}
for k, v in olinks_raw.items():
    if isinstance(v, dict) and v.get("subrepo") and v.get("subrepo") != sub:
        continue
    if v is None and sub != "." and isinstance(k, str) and "/" in k and not k.startswith(sub + "/"):
        continue
    olinks[k] = v
# 존재 검사용 — 소스 서브레포(명시 subrepo > cwd 첫 segment) 의 dir 이름·파일 이름 수집(heavy prune·cap)
src_base = os.path.join(source_root, sub) if sub != "." else source_root
dst_base = os.path.join(root, sub) if sub != "." else root
dst_base_real = os.path.realpath(dst_base) if dst_base else ""
dir_names = set(); file_names = []
if source_root and os.path.isdir(src_base):
    HEAVY = {".git", ".claude", "node_modules", ".venv", "build", "dist", "out", "target", ".next"}
    def under_dst(dp, d):
        if not dst_base_real:
            return False
        rp = os.path.realpath(os.path.join(dp, d))
        return rp == dst_base_real or rp.startswith(dst_base_real + os.sep)
    cnt = 0
    for dp, dns, fns in os.walk(src_base, followlinks=False):
        if dp[len(src_base):].count(os.sep) > 5:
            dns[:] = []; continue
        for d in dns:
            if not under_dst(dp, d):
                dir_names.add(d)
        dns[:] = [d for d in dns if d not in HEAVY and not under_dst(dp, d)]   # 이름은 모았으니 안 내려감
        for f in fns:
            file_names.append(f); cnt += 1
        if cnt > 3000:
            break
def present(rule):
    if not isinstance(rule, dict):
        return True
    g = rule.get("glob")
    if not g or not source_root:
        return True                                    # glob 아니거나 소스 모르면 일단 표시
    if rule.get("kind") == "dir":
        return any(fnmatch.fnmatch(d, g) for d in dir_names)
    return any(fnmatch.fnmatch(f, g) for f in file_names)
DEPS = {"node_modules", ".venv"}                        # 분류 — UI 가 기본 동작 제안에 사용
BUILD = {"build", "dist", "out", "target", ".next"}     # 빌드출력 = 제외 제안(워크트리별 독립 빌드)
def categorize(name, rule):
    g = (rule.get("glob") if isinstance(rule, dict) else None) or name or ""
    b = os.path.basename(str(g))
    if name in DEPS or b in DEPS or "gradle" in (name or "").lower():
        return "deps"                                  # 심링크 제안(공유·재설치 회피)
    if name in BUILD or b in BUILD or str(g).endswith(".jar"):
        return "build"                                 # 제외 제안
    return "config"                                    # 심링크/복제 택(*local.yml·.env*)
out = []
for name in list(base.keys()) + [k for k in olinks if k not in base]:
    if not isinstance(name, str):
        continue
    overridden = name in olinks
    base_off = name in central and central[name] is None   # 프로젝트 전체 끄기(main 에서 base disable) — 모든 워크트리 제외
    if base_off:
        src = "default" if name in defaults else "project"
        out.append({"name": name, "source": src, "disabled": True, "baseOff": True,
                    "rule": defaults.get(name) or {}, "base": src,
                    "present": present(defaults.get(name) or {}),
                    "category": categorize(name, defaults.get(name) or {}), "dangling": False})
        continue
    disabled = overridden and olinks[name] is None
    rule = (olinks[name] if (overridden and not disabled) else base.get(name)) or {}
    if name in svc_links:
        src = "service"
    elif name in central:
        src = "project"        # 대시보드 탐색기로 등록한 프로젝트 커스텀(모든 워크트리 공유)
    else:
        src = "default"
    source = "override" if overridden else src
    dangling = overridden and name not in base   # 가리킬 기본/공유 정의가 없는 override = 끄기 잔재(공유 링크 삭제 후 override 만 남음)
    out.append({"name": name, "source": source, "disabled": disabled, "baseOff": False, "rule": rule,
                "base": src, "present": present(rule), "category": categorize(name, rule), "dangling": dangling})
# 소스에 존재하는 빌드출력은 설정엔 없어도 노출(source=discovered) — 위저드가 "제외(독립 빌드)" 로 안내
configured = set(base) | set(olinks)
for bd in sorted(BUILD):
    if bd in dir_names and bd not in configured:
        out.append({"name": bd, "source": "discovered", "disabled": False, "rule": {"glob": bd, "kind": "dir"},
                    "base": "discovered", "present": True, "category": "build"})
if any(f.endswith(".jar") for f in file_names) and "*.jar" not in configured:
    out.append({"name": "*.jar", "source": "discovered", "disabled": False, "rule": {"glob": "*.jar", "kind": "file"},
                "base": "discovered", "present": True, "category": "build"})
print(json.dumps(out, ensure_ascii=False))
PY
}
