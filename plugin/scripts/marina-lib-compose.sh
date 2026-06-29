#!/usr/bin/env bash
# marina-lib-compose.sh — marina.sh 에서 분리된 compose 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

# compose-kind 실행 동사 위임 (marina 는 compose 전용).
ensure_external_worktrees() {
  # 외부 레포를 $ROOT/.workspace/external/<name> 에 git worktree 로 체크아웃 — compose 빌드 컨텍스트.
  # main·worktree 공통(compose 는 prepare/attach 를 안 거침), 멱등(이미 있으면 그대로 둠).
  # 실패는 조용히 넘기지 않는다 — 외부 마운트가 없거나 깨지면 compose 빌드 컨텍스트가 틀어져 start 가
  # 엉뚱하게 실패하므로, 치명적 실패면 return 1 로 호출측이 중단하게 한다(코덱스 감사 #5).
  local externals _ln _nm _src _dst _br _rc=0
  externals="$(printf '%s' "$meta" | python3 -c 'import json,sys
for e in (json.load(sys.stdin).get("externalRepos") or []):
  if e.get("name") and e.get("source"): print(str(e["name"])+"="+str(e["source"]))' 2>/dev/null || true)"
  [[ -n "$externals" ]] || return 0
  _br="marina/$(session_id)"
  while IFS= read -r _ln; do
    [[ -n "$_ln" && "$_ln" == *=* ]] || continue
    _nm="${_ln%%=*}"; _src="${_ln#*=}"; _dst="$ROOT/.workspace/external/$_nm"
    git -C "$_src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "외부 레포가 git 작업트리 아님: $_nm ($_src)" >&2; _rc=1; continue; }
    if [[ -e "$_dst" ]]; then                       # 멱등 — 단, 유효한 worktree 일 때만 skip(깨진 디렉터리면 빌드컨텍스트 틀어짐)
      git -C "$_dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 && continue
      echo "외부 마운트 경로가 유효한 git worktree 가 아님: $_dst — 지우고 다시 시도하세요" >&2; _rc=1; continue
    fi
    git -C "$_src" worktree prune 2>/dev/null || true
    mkdir -p "$ROOT/.workspace/external"
    if git -C "$_src" worktree add --detach "$_dst" HEAD >&2; then
      # 브랜치 전환은 nicety — detached HEAD 로도 빌드는 됨. 실패해도 치명 아님(경고만).
      git -C "$_dst" switch -c "$_br" 2>/dev/null || git -C "$_dst" switch "$_br" 2>/dev/null \
        || echo "external [$_nm]: 브랜치 $_br 전환 실패(다른 worktree 가 점유?) — detached HEAD 로 진행(빌드엔 무방)" >&2
      echo "external attached: $_nm -> $_dst [$_br]" >&2
    else
      echo "external worktree 생성 실패: $_nm ($_src) — 빌드 컨텍스트가 없어 중단" >&2; _rc=1
    fi
  done <<< "$externals"
  return $_rc
}

run_prebuild_hooks() {
  # pre-build(B): 서브레포별 빌드 명령을 up 전에 실행(아티팩트 선빌드 — be-api gradle 등).
  # portable: 명령은 상대(예 ./gradlew build), 서브레포 dir(내부 ./<sub> 또는 외부 마운트)에서 실행 → 동료 머신서도 동작.
  # 소스: x-marina.prebuild(보관 compose, 새 SoT) 우선, 없으면 레거시 prebuild.json (전환기 backward-compat).
  local stored="${1:-}" cp="${2:-}"
  local pf="$MARINA_HOME/$pid/prebuild.json" _sub _cmd _dir _xm=""
  [[ -n "$stored" && -n "$cp" && -f "$stored" ]] && _xm="$(python3 "$cp" xmarina --stored "$stored" --key prebuild 2>/dev/null)"
  while IFS=$'\t' read -r _sub _cmd; do
    [[ -n "$_sub" && -n "$_cmd" ]] || continue
    if [[ -d "$ROOT/.workspace/external/$_sub" ]]; then _dir="$ROOT/.workspace/external/$_sub"
    elif [[ -d "$ROOT/$_sub" ]]; then _dir="$ROOT/$_sub"
    else echo "pre-build skip(서브레포 폴더 없음): $_sub" >&2; continue; fi
    echo "pre-build [$_sub]: $_cmd  (in ${_dir#$ROOT/})" >&2
    ( cd "$_dir" && bash -c "$_cmd" ) || { echo "pre-build 실패: $_sub ($_cmd)" >&2; return 1; }
  done < <(python3 - "$pf" "$_xm" <<'PY'
import json, sys
pf = sys.argv[1]; xm_raw = sys.argv[2] if len(sys.argv) > 2 else ""
d = {}
try:                                          # x-marina.prebuild (있으면 SoT)
    xm = json.loads(xm_raw) if xm_raw.strip() else {}
    if isinstance(xm, dict):
        d = xm
except Exception:
    d = {}
if not d:                                     # 레거시 prebuild.json fallback
    try:
        d = json.load(open(pf))
    except FileNotFoundError:                 # 없는 게 정상(대부분) — 조용히
        d = {}
    except Exception as e:                     # 손상 JSON 을 조용히 무시하지 않음 — pre-build 누락을 알림(코덱스 감사 #6)
        sys.stderr.write("warning: prebuild.json 읽기 실패 — pre-build 건너뜀: %s\n" % e)
        sys.exit(0)
for sub, cmd in (d or {}).items():
    if sub and isinstance(cmd, str) and cmd.strip():
        print(sub + "\t" + cmd.strip())
PY
)
}

compose_main() {
  local command="$1"; shift || true

  # no-arg 가드(네이티브와 동일 취지) — docker 유무 전에 인자 실수부터.
  case "$command" in
    start|stop|restart)
      [[ $# -gt 0 ]] || { echo "usage: marina $command <--service..|--all>   (전체 스택은 --all)" >&2; exit 2; } ;;
  esac

  command -v docker >/dev/null 2>&1 || die "compose 실행엔 docker 필요 — 설치·기동 후 다시."
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
      local -a svcs=() envargs=() a; local x cname
      for a in "$@"; do
        case "$a" in
          --all) ;;
          --*)   svcs+=("--service=${a#--}") ;;
          *)     die "compose: 알 수 없는 인자 '$a' (서비스는 --<name>, 전체는 --all)" ;;
        esac
      done
      [[ -n "$envvar" ]] && envargs+=("--env=$envvar=${MARINA_COMPOSE_ENV:-$envdef}")
      mkdir -p "$sd"
      [[ "$command" == "stop" ]] || ensure_external_worktrees || return 1   # 외부 레포 마운트 보장(up 전) — 실패 시 중단(빌드컨텍스트 없음)
      [[ "$command" == "stop" ]] || run_prebuild_hooks "$stored" "$cp" || return 1   # pre-build(B): 아티팩트 선빌드(up 전)
	      [[ "$command" == "stop" ]] || apply_glob_links "" "$stored" "$cp"   # opt-in 링크(x-marina.links 우선) — 호스트 deps/config, 빌드출력 제외.
      local -a bargs=(); local _ba                              # 서비스별 build args(build-args.json) → overlay 주입
      while IFS= read -r _ba; do [[ -n "$_ba" ]] && bargs+=("--build-arg=$_ba"); done < <(
        python3 - "$MARINA_HOME/$pid/build-args.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except FileNotFoundError:                    # 없는 게 정상(대부분 프로젝트) — 조용히
    sys.exit(0)
except Exception as e:                        # 있는데 손상이면 알림(build args 누락, 코덱스 감사 #6)
    sys.stderr.write("warning: build-args.json 읽기 실패 — build args 건너뜀: %s\n" % e)
    sys.exit(0)
for svc, args in (d or {}).items():
    if isinstance(args, dict):
        for k, v in args.items():
            if k:
                print(f"{svc}={k}={v}")
PY
)
      # buildArgsFrom (x-marina): 서비스별 env 파일을 호스트에서 읽어 build-arg 로 주입.
      # 값은 공유 blob(x-marina)에 안 들어가고(경로만), 파일은 워크트리(links copy)/원본에 로컬 존재 →
      # codex/claude 로 워크트리 바로 열어도 자동. multi-stage 라 최종 이미지엔 안 남음(CI 와 동일).
      local _xbaf=""
      [[ -f "$stored" ]] && _xbaf="$(python3 "$cp" xmarina --stored "$stored" --key buildArgsFrom 2>/dev/null)"
      if [[ -n "$_xbaf" && "$_xbaf" != "{}" ]]; then
        while IFS= read -r _ba; do [[ -n "$_ba" ]] && bargs+=("--build-arg=$_ba"); done < <(
          python3 - "$_xbaf" "$ROOT" "$SOURCE_ROOT" <<'PY'
import json, os, sys
try:
    m = json.loads(sys.argv[1] or "{}")
except Exception:
    m = {}
root = sys.argv[2]; src = sys.argv[3] if len(sys.argv) > 3 else ""
for svc, rel in (m or {}).items():
    if not (svc and isinstance(rel, str) and rel.strip()):
        continue
    path = None
    for base in (root, src):                     # 워크트리 우선, 없으면 원본(creds 는 user-global)
        if base and os.path.isfile(os.path.join(base, rel)):
            path = os.path.join(base, rel); break
    if not path:
        sys.stderr.write(f"warning: buildArgsFrom 파일 없음({rel}) — {svc} 건너뜀\n"); continue
    try:
        for ln in open(path, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            if ln.startswith("export "):
                ln = ln[7:].strip()
            k, sep, v = ln.partition("=")
            k = k.strip(); v = v.strip().strip('"').strip("'")
            if not (sep and k):
                continue
            if v.startswith("$"):                # 미해석 SSM/env 플레이스홀더(예: dollar-brace 참조)는 실값 아님 → 스킵(compose 보간 깨짐 방지)
                continue
            print(f"{svc}={k}={v}")
    except OSError as e:
        sys.stderr.write(f"warning: buildArgsFrom 읽기 실패({path}): {e}\n")
PY
)
      fi
	      local -a connarg=()   # ⑥ 연결 주입 설정 → marina-compose 가 weave forward 를 적용
	      [[ -f "$MARINA_HOME/$pid/backing.json" ]] && connarg=(--connectivity "$MARINA_HOME/$pid/backing.json")
	      case "$command" in
	        start)
	          python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" \
	            ${svcs[@]+"${svcs[@]}"} ${envargs[@]+"${envargs[@]}"} ${bargs[@]+"${bargs[@]}"} ${connarg[@]+"${connarg[@]}"} || return $?
          cname="$(python3 "$cp" name "${nameargs[@]}")"
          local -a tail_svcs=()
          if [[ ${#svcs[@]} -gt 0 ]]; then
            for x in "${svcs[@]}"; do tail_svcs+=("${x#--service=}"); done
          else
            while IFS= read -r x; do [[ -n "$x" ]] && tail_svcs+=("$x"); done \
              < <(docker compose -p "$cname" ps --all --services 2>/dev/null)
          fi
          for x in ${tail_svcs[@]+"${tail_svcs[@]}"}; do _compose_logtail_start "$cname" "$x"; done ;;
        stop)
          if [[ ${#svcs[@]} -gt 0 ]]; then
            for x in "${svcs[@]}"; do _compose_logtail_stop "${x#--service=}"; done
            python3 "$cp" stop "${nameargs[@]}" "${svcs[@]}"
          else
            _compose_logtail_stop
            python3 "$cp" down "${nameargs[@]}"
          fi ;;
        restart)
          if [[ ${#svcs[@]} -gt 0 ]]; then
            # bounce 가 아니라 up 재적용 — build args/Dockerfile 보정/overlay 변경이 반영되게(--build). config 바뀌면 recreate.
            python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" \
              "${svcs[@]}" ${envargs[@]+"${envargs[@]}"} ${bargs[@]+"${bargs[@]}"} ${connarg[@]+"${connarg[@]}"} || return $?
            cname="$(python3 "$cp" name "${nameargs[@]}")"
            for x in "${svcs[@]}"; do _compose_logtail_start "$cname" "${x#--service=}"; done
          else
            _compose_logtail_stop
            python3 "$cp" down "${nameargs[@]}"
            python3 "$cp" up --stored "$stored" --project-dir "$ROOT" --session-dir "$sd" "${nameargs[@]}" ${envargs[@]+"${envargs[@]}"} ${bargs[@]+"${bargs[@]}"} ${connarg[@]+"${connarg[@]}"} || return $?
            cname="$(python3 "$cp" name "${nameargs[@]}")"
            while IFS= read -r x; do [[ -n "$x" ]] && _compose_logtail_start "$cname" "$x"; done \
              < <(docker compose -p "$cname" ps --all --services 2>/dev/null)
          fi ;;
      esac ;;
    status)  python3 "$cp" status "${nameargs[@]}" ;;
    ports)   python3 "$cp" status "${nameargs[@]}" --ports-only ;;
    logs)
      local -a lsvc=(); [[ -n "${1:-}" ]] && lsvc+=("--service=$1")
      python3 "$cp" logs "${nameargs[@]}" ${lsvc[@]+"${lsvc[@]}"} ;;
    *) die "compose: 미지원 명령 $command" ;;
  esac
  # start/restart 성공 직후(여기 도달=up 성공): 게이트웨이 자동 기동 + 라우트 반영(CLI 경로도 대시보드와 동일 UX)
  case "$command" in start|restart) python3 "$SCRIPT_DIR/marina-control.py" gateway-ensure >/dev/null 2>&1 || true ;; esac
}
