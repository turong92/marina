#!/usr/bin/env bash
# marina-lib-services.sh — marina.sh 에서 분리된 services 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

# root ∪ 중앙 서비스 머지 JSON 을 stdout 으로 (name 중앙 우선). 서비스 조회가 이걸 파싱한다.
# early dispatch(service ls)에서도 호출되므로 워크스페이스 컨텍스트 해석 위에 정의한다 —
# ROOT/SOURCE_ROOT/PROJECTS_FILE/MARINA_HOME 을 positional 로만 받아 그 시점 의존이 없다.
merged_services_json() {
  python3 - "$ROOT" "$SOURCE_ROOT" "$PROJECTS_FILE" "$MARINA_HOME" <<'PY'
import json, os, sys
root, source_root, projects_file, home = sys.argv[1:5]
def read(p):
    try:
        d = json.load(open(p, encoding="utf-8"))
        return d.get("services", []) if isinstance(d, dict) else []
    except Exception:
        return []
def norm(p): return os.path.realpath(os.path.expanduser(p))
pid = ""; proot = source_root
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    tgt = {norm(source_root), norm(root)}
    for p in data.get("projects", []):
        pr = norm(p.get("root", ""))
        if pr in tgt or any(t == pr or t.startswith(pr + os.sep) for t in tgt):
            pid = p.get("id", ""); proot = p.get("root", ""); break
except Exception:
    pass
merged = {}
root_file = os.path.join(norm(proot), "marina-services.json")
for s in read(root_file):
    n = s.get("name")
    if n: merged[n] = {**s, "source": "root"}
if pid:
    for s in read(os.path.join(norm(home), "services", pid + ".json")):
        n = s.get("name")
        if n: merged[n] = {**s, "source": "central"}
print(json.dumps({"services": list(merged.values())}, ensure_ascii=False))
PY
}

extra_services() {
  command -v python3 >/dev/null 2>&1 || return 0
  local _merged; _merged="$(merged_services_json)"
  python3 - "$_merged" <<'PY'
import json, sys
try:
    for s in json.loads(sys.argv[1]).get("services", []):
        name = str(s.get("name", "")).strip()
        if name and name.isidentifier() and isinstance(s.get("portBase"), int):
            print(name)
except Exception:
    pass
PY
}

service_json_field() {
  local name="$1" field="$2"
  local _merged; _merged="$(merged_services_json)"
  python3 - "$_merged" "$name" "$field" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
service, field = sys.argv[2], sys.argv[3]
svc = next((s for s in data.get("services", []) if s.get("name") == service), None)
if svc:
    value = svc.get(field, "")
    if isinstance(value, (str, int)):
        print(value, end="")
PY
}

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
    "kind": match.get("kind", "compose"),
    "composeFile": match.get("composeFile", "docker-compose.yml"),
    "composeEnvVar": match.get("composeEnvVar", ""),
    "composeEnvDefault": match.get("composeEnvDefault", "local"),
    "externalRepos": match.get("externalRepos", []),
}, ensure_ascii=False))
PY
}

project_kind() {
  project_meta | python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("kind","compose"))' 2>/dev/null || echo compose
}
