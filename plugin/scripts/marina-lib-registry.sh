#!/usr/bin/env bash
# marina-lib-registry.sh — marina.sh 에서 분리된 registry 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

# ---- 프로젝트 레지스트리 CLI (~/.marina/projects.json) — 위치 무관 ----------
# 추론은 여기(registry_infer)가 단일 SoT — JSON 으로 출력만 하고 쓰지 않는다.
# registry_add 는 이걸 소비해서 ~/.marina/projects.json 에 upsert 하고, 대시보드 API(phase 3)도 이걸 shell.
registry_infer() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: marina project infer <project-path>"
  [[ -d "$path" ]] || die "디렉토리 없음: $path"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  local abs; abs="$(cd "$path" && pwd -P)" || die "경로 해석 실패: $path"
  python3 - "$abs" <<'PY'
import json, os, sys
root = sys.argv[1]
# 서브레포 추론 — .git 디렉토리(=독립 클론)를 가진 1단계 하위 디렉토리.
# (.git 파일은 worktree 링크 → main 체크아웃의 서브레포가 아니므로 제외)
subrepos = sorted(
    n for n in os.listdir(root)
    if not n.startswith(".")
    and os.path.isdir(os.path.join(root, n))
    and os.path.isdir(os.path.join(root, n, ".git"))
)
# worktreeGlobs 추론 — claude 는 항상, codex 는 ~/.codex 존재 시
globs = [".claude/worktrees/*"]
base = os.path.basename(root)
if os.path.isdir(os.path.expanduser("~/.codex/worktrees")):
    globs.append(f"~/.codex/worktrees/*/{base}")
print(json.dumps({"id": base, "root": root, "subrepos": subrepos, "worktreeGlobs": globs}, ensure_ascii=False))
PY
}

registry_add() {
  local path="" subrepos_csv="" have_subrepos=0 compose_file="" env_var="" env_default="local" external_specs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subrepos)
        have_subrepos=1
        if [[ $# -ge 2 ]]; then subrepos_csv="$2"; shift 2; else subrepos_csv=""; shift; fi
        ;;
      --subrepos=*)
        have_subrepos=1; subrepos_csv="${1#--subrepos=}"; shift ;;
      --compose)    compose_file="${2:-}"; shift 2 ;;
      --compose=*)  compose_file="${1#--compose=}"; shift ;;
      --env-var)    env_var="${2:-}"; shift 2 ;;
      --env-var=*)  env_var="${1#--env-var=}"; shift ;;
      --env-default)   env_default="${2:-}"; shift 2 ;;
      --env-default=*) env_default="${1#--env-default=}"; shift ;;
      --external)   external_specs+=("${2:-}"); shift 2 ;;
      --external=*) external_specs+=("${1#--external=}"); shift ;;
      *)
        [[ -z "$path" ]] || die "add: 인자 과다 ('$1')"
        path="$1"; shift ;;
    esac
  done
  [[ -z "$compose_file" || -f "$compose_file" ]] || die "compose 파일 없음: $compose_file"
  # --external name=path: 절대경로 resolve + git 작업트리 검증(외부 격리엔 git 필요). name=abspath 줄로 join.
  local ext_joined=""
  if [[ ${#external_specs[@]} -gt 0 ]]; then
    local _spec _nm _src _abs
    for _spec in "${external_specs[@]}"; do
      _nm="${_spec%%=*}"; _src="${_spec#*=}"
      [[ -n "$_nm" && "$_nm" != "$_spec" && -n "$_src" ]] || die "외부 레포 형식: --external name=path (받음 '$_spec')"
      _abs="$(cd "$_src" 2>/dev/null && pwd -P)" || die "외부 레포 경로 없음: $_src"
      git -C "$_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "외부 레포가 git 작업트리 아님: $_abs (격리엔 git 필요)"
      ext_joined+="$_nm=$_abs"$'\n'
    done
  fi
  local entry; entry="$(registry_infer "$path")" || exit $?
  mkdir -p "$MARINA_HOME"
  local abs_compose=""
  [[ -n "$compose_file" ]] && abs_compose="$(cd "$(dirname "$compose_file")" && pwd -P)/$(basename "$compose_file")"
  entry="$(python3 - "$entry" "$have_subrepos" "$subrepos_csv" "$abs_compose" "$env_var" "$env_default" "$ext_joined" <<'PY'
import json, os, sys
entry = json.loads(sys.argv[1])
have_subrepos, subrepos_csv = sys.argv[2] == "1", sys.argv[3]
compose, env_var, env_default = sys.argv[4], sys.argv[5], sys.argv[6]
external_joined = sys.argv[7] if len(sys.argv) > 7 else ""
# 플래그 존재 시 추론 대신 명시 집합(빈 값이면 []=모노레포). 부재 시 추론 그대로.
if have_subrepos:
    entry["subrepos"] = [s for s in (x.strip() for x in subrepos_csv.split(",")) if s]
if compose:
    entry["kind"] = "compose"
    entry["composeFile"] = os.path.basename(compose)
    if env_var:
        entry["composeEnvVar"] = env_var
        entry["composeEnvDefault"] = env_default
ext = [{"name": n.strip(), "source": s.strip()}
       for n, _, s in (ln.partition("=") for ln in external_joined.splitlines()) if n.strip() and s.strip()]
if ext:
    entry["externalRepos"] = ext
print(json.dumps(entry, ensure_ascii=False))
PY
)"
  python3 - "$PROJECTS_FILE" "$entry" <<'PY'
import json, os, sys, hashlib
projects_file, entry = sys.argv[1], json.loads(sys.argv[2])
try:
    data = json.load(open(projects_file, encoding="utf-8"))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
norm = lambda p: os.path.realpath(os.path.expanduser(p))
my_root = norm(entry["root"])
# 충돌 안전 id: 다른 root 가 이미 같은 basename id 를 점유하면 -<root해시6> 붙여 분리.
# (폴더명만 같은 별개 프로젝트의 main 끼리 -p 이름·~/.marina/<id> 가 겹치는 것 방지. 같은 root 재등록은 id 유지.)
taken = {p.get("id") for p in data.get("projects", []) if norm(p.get("root", "")) != my_root}
if entry["id"] in taken:
    entry["id"] = f"{entry['id']}-{hashlib.sha1(my_root.encode()).hexdigest()[:6]}"
prev = next((p for p in data.get("projects", []) if norm(p.get("root", "")) == my_root), None)
if prev:                                    # 재등록(subrepo 편집 등 --compose 없는 경로) — compose 메타는 기존 보존
    for _k in ("kind", "composeFile", "composeEnvVar", "composeEnvDefault", "externalRepos"):
        if _k not in entry and _k in prev:
            entry[_k] = prev[_k]
projects = [p for p in data.get("projects", []) if norm(p.get("root","")) != my_root]
projects.append(entry)
data["projects"] = projects
data.setdefault("schemaVersion", 1)
json.dump(data, open(projects_file, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"added: {entry['id']}  root={entry['root']}  kind={entry.get('kind','compose')}")
print(f"  subrepos: {', '.join(entry['subrepos']) or '(none)'}")
print(f"  worktreeGlobs: {', '.join(entry['worktreeGlobs'])}")
PY
  if [[ -n "$abs_compose" ]]; then
    # 업서트가 정한 최종 id(충돌 시 해시 포함)를 projects.json 에서 root 로 역참조 — basename 재계산 금지
    local id; id="$(python3 -c 'import json, os, sys
norm = lambda p: os.path.realpath(os.path.expanduser(p))
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(p["id"] for p in d["projects"] if norm(p.get("root","")) == norm(sys.argv[2])))' "$PROJECTS_FILE" "$(cd "$path" && pwd -P)")"
    mkdir -p "$MARINA_HOME/$id"
    cp "$abs_compose" "$MARINA_HOME/$id/$(basename "$abs_compose")"
    echo "  compose: stored at $MARINA_HOME/$id/$(basename "$abs_compose")"
  fi
}

registry_rm() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: marina project rm <id>"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  [[ -f "$PROJECTS_FILE" ]] || die "레지스트리 없음: $PROJECTS_FILE"
  python3 - "$PROJECTS_FILE" "$id" <<'PY'
import json, sys
projects_file, target = sys.argv[1], sys.argv[2]
data = json.load(open(projects_file, encoding="utf-8"))
projects = data.get("projects", [])
kept = [p for p in projects if p.get("id") != target]
if len(kept) == len(projects):
    print(f"not found: {target}", file=sys.stderr)
    sys.exit(1)
data["projects"] = kept
with open(projects_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
print(f"removed: {target}")
PY
}

registry_default() {
  local id="${1:-}" csv="${2-}"
  [[ -n "$id" ]] || die "usage: marina project default <id> <a,b,c>  (빈 값=전부 비움)"
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  [[ -f "$PROJECTS_FILE" ]] || die "레지스트리 없음: $PROJECTS_FILE"
  python3 - "$PROJECTS_FILE" "$id" "$csv" <<'PY'
import json, sys
projects_file, target, csv = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(projects_file, encoding="utf-8"))
projects = data.get("projects", [])
match = next((p for p in projects if p.get("id") == target), None)
if match is None:
    print(f"not found: {target}", file=sys.stderr); sys.exit(1)
universe = [str(s) for s in match.get("subrepos", [])]
want = [s for s in (x.strip() for x in csv.split(",")) if s]
bad = [s for s in want if s not in universe]
if bad:
    print(f"not in subrepos ({', '.join(universe) or 'none'}): {', '.join(bad)}", file=sys.stderr)
    sys.exit(1)
match["defaultAttach"] = want
with open(projects_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
print(f"defaultAttach[{target}]: {', '.join(want) or '(none — 새 worktree 자동 attach 없음)'}")
PY
}

registry_ls() {
  command -v python3 >/dev/null 2>&1 || die "python3 필요"
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "(레지스트리 비어 있음: $PROJECTS_FILE — marina project add <path> 로 등록)"
    return 0
  fi
  python3 - "$PROJECTS_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
projects = data.get("projects", [])
if not projects:
    print("(등록된 프로젝트 없음)")
    sys.exit(0)
for p in projects:
    print(f"{p.get('id')}\t{p.get('root')}")
    print(f"  compose: {p.get('composeFile','docker-compose.yml')}")
    subs = p.get("subrepos", [])
    if subs:
        print(f"  subrepos: {', '.join(subs)}")
    globs = p.get("worktreeGlobs", [])
    if globs:
        print(f"  worktrees: {', '.join(globs)}")
PY
}

# subrepos = MARINA_SUBREPOS env(대시보드 주입) → 레지스트리(직접 CLI) → 없음(미등록 프로젝트)
registry_subrepos_for() {
  command -v python3 >/dev/null 2>&1 || return 3
  [[ -f "$PROJECTS_FILE" ]] || return 3
  python3 - "$PROJECTS_FILE" "$1" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(3)
root = os.path.realpath(os.path.expanduser(sys.argv[2]))
codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
projects = data.get("projects", [])
norm = lambda p: os.path.realpath(os.path.expanduser(p.get("root", "")))
match = None
best_len = -1
for p in projects:
    pr = norm(p)
    if root == pr or root.startswith(pr + os.sep):
        if len(pr) > best_len:
            match = p; best_len = len(pr)
# basename 패스는 codex 레이아웃(<worktrees>/<id>/<basename>) 한정 — 동일 basename 다중 프로젝트 오매핑 방지
if match is None and os.path.dirname(os.path.dirname(root)) == codex_wt:
    base = os.path.basename(root)
    for p in projects:
        if os.path.basename(norm(p)) == base:
            match = p; break
if match is None and len(projects) == 1:
    match = projects[0]
if match is None:
    sys.exit(3)
print(" ".join(str(s) for s in match.get("subrepos", [])))
PY
}
