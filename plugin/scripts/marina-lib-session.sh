#!/usr/bin/env bash
# marina-lib-session.sh — marina.sh 에서 분리된 session 함수군 (source 전용, 함수 정의만).
# 동작 변경 0 — marina.sh 에서 이동만. 전역(ROOT/SOURCE_ROOT/MARINA_HOME/SERVICES 등)은 marina.sh 가 설정.

session_id() {
  # codex 레이아웃은 <id>/<projectBasename>, claude 는 .claude/worktrees/<name> 그 자체가 루트.
  # 무조건 dirname 을 쓰면 claude worktree 가 전부 "worktrees" 로 뭉개진다.
  # codex worktree 의 basename 은 원본(SOURCE_ROOT) basename 과 같다 → 부모(<id>)명을 세션 id 로.
  if [[ "$ROOT" == "$SOURCE_ROOT" ]]; then
    echo "main"
  elif [[ "$(basename "$ROOT")" == "$(basename "$SOURCE_ROOT")" ]]; then
    basename "$(dirname "$ROOT")"
  else
    basename "$ROOT"
  fi
}

session_dir() {
  echo "$SESSION_ROOT/$(session_id)"
}

log_file() {
  echo "$(session_dir)/$1.log"
}

config_file() {
  echo "$(session_dir)/overrides.env"
}

# 워크트리별 구조적 override (env·ports). 이 워크트리만. base ＜ overrides.json (per-key).
overrides_json_file() {
  echo "$(session_dir)/overrides.json"
}

# overrides.json 의 ports[service] (정수) — 없으면 빈 문자열 (port_for 최우선 레이어).
# 파일 없으면 python 안 띄움(핫패스 — port_for 가 매우 자주 호출됨).
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

log_dir() {
  echo "$(session_dir)/logs/$1"
}

# run 로그 누적 방지: 최신 keep 개만 유지 (기본 10, MARINA_LOG_KEEP)
prune_old_runs() {
  local service="$1" current_log="$2" keep="${MARINA_LOG_KEEP:-10}" dir total old_log
  dir="$(log_dir "$service")"
  total="$(ls -1 "$dir"/run-*.log 2>/dev/null | wc -l | tr -d ' ')"
  if ((keep > 0 && total > keep)); then
    # 사전순은 run-1000 < run-999 로 역전 → 시퀀스 숫자 기준 정렬
    while IFS= read -r old_log; do
      [[ "$old_log" == "$current_log" ]] && continue
      rm -f "$old_log"
    done < <(ls -1 "$dir"/run-*.log | sort -t- -k2 -n | sed -n "1,$((total - keep))p")
  fi
}

next_run_log() {
  local service="$1" seq_path seq log_path
  mkdir -p "$(log_dir "$service")"
  seq_path="$(session_dir)/$service.seq"
  if [[ -f "$seq_path" ]]; then
    seq="$(cat "$seq_path")"
  else
    seq=0
  fi
  seq=$((10#$seq + 1))
  printf '%03d\n' "$seq" > "$seq_path"
  log_path="$(log_dir "$service")/run-$(printf '%03d' "$seq").log"
  : > "$log_path"
  ln -sfn "$log_path" "$(log_file "$service")"
  prune_old_runs "$service" "$log_path"
  echo "$log_path"
}

ensure_current_log() {
  local service="$1" current
  current="$(log_file "$service")"
  if [[ -e "$current" ]]; then
    echo "$current"
  else
    next_run_log "$service"
  fi
}

backup_path() {
  echo "$(session_dir)/backup-$1-$(date +%Y%m%d%H%M%S)"
}
