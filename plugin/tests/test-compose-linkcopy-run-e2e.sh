#!/usr/bin/env bash
# 실 docker E2E: deps(vendor)를 한 워크트리는 '링크(symlink)', 다른 워크트리는 '카피(copy)' 로 적용한 뒤
# 둘 다 marina 로 실제 기동(start) → nginx 컨테이너 떠서 응답 + 마운트된 vendor 내용까지 서빙되는지 확인.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP (docker 미가용)"; exit 0; }

TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"
SRC="$TMP/src"; mkdir -p "$SRC/vendor"
echo "DEP-CONTENT" > "$SRC/vendor/marker.txt"     # deps 내용(host) — 링크/카피로 워크트리에 적용됨
cleanup() {
  for d in "$TMP"/wt-link "$TMP"/wt-copy; do [ -d "$d" ] && (cd "$d" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" stop --all >/dev/null 2>&1 || true); done
  rm -rf "$TMP"
}
trap cleanup EXIT

make_wt() {  # $1=name  $2=mode(symlink|copy)  → 워크트리 dir 생성·등록·central 링크 설정
  local name="$1" mode="$2"; local wt="$TMP/$name"
  mkdir -p "$wt/html/vendor"   # vendor 마운트 지점 미리 생성(:ro 부모 밑 child 마운트 OK)
  echo "RUN-OK-$name" > "$wt/html/index.html"
  cat > "$wt/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx:alpine
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./vendor:/usr/share/nginx/html/vendor:ro
    ports: ["80"]
YML
  bash "$SH" project add "$wt" --compose "$wt/docker-compose.yml" >/dev/null
  local pid; pid="$(python3 -c "import json; ps=json.load(open('$MARINA_HOME/projects.json'))['projects']; print([p['id'] for p in ps if p['root'].rstrip('/').endswith('/$name')][0])")"
  mkdir -p "$MARINA_HOME/$pid"
  if [ "$mode" = copy ]; then
    printf '{"version":1,"links":{"vendor":{"glob":"vendor","kind":"dir","mode":"copy"}}}' > "$MARINA_HOME/$pid/links.json"
  else
    printf '{"version":1,"links":{"vendor":{"glob":"vendor","kind":"dir"}}}' > "$MARINA_HOME/$pid/links.json"
  fi
  echo "$pid"
}

pname() { python3 -c "import re,sys; print(re.sub(r'[^a-z0-9_-]+','-', (sys.argv[1]+'-main').lower()).strip('-_') or 'marina')" "$1"; }

start_and_check() {  # $1=name $2=pid $3=expect-symlink(yes/no)
  local name="$1" pid="$2" wantlink="$3"; local wt="$TMP/$name"
  (cd "$wt" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" start --all >/dev/null 2>&1) \
    || { echo "FAIL[$name]: marina start"; (cd "$wt" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" start --all 2>&1 | tail -15); return 1; }
  # host: 링크 vs 카피
  if [ "$wantlink" = yes ]; then
    [ -L "$wt/vendor" ] || { echo "FAIL[$name]: vendor 가 symlink 아님(링크 기대)"; return 1; }
    echo "  [$name] host vendor = symlink ✓"
  else
    [ -d "$wt/vendor" ] && [ ! -L "$wt/vendor" ] || { echo "FAIL[$name]: vendor 가 실제 복제 dir 아님(카피 기대)"; return 1; }
    echo "  [$name] host vendor = real copy ✓"
  fi
  # container 기동 + 포트
  local cname port
  cname=""
  for _ in $(seq 1 30); do
    cname="$(docker ps --filter "label=com.docker.compose.service=web" --filter "name=$pid-" --format '{{.Names}}' | head -1)"
    [ -n "$cname" ] && break; sleep 1
  done
  [ -n "$cname" ] || { echo "FAIL[$name]: web 컨테이너 못 찾음(pid=$pid)"; docker ps | head; return 1; }
  port="$(docker port "$cname" 80/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  [ -n "$port" ] || { echo "FAIL[$name]: 호스트 포트 못 읽음"; return 1; }
  # 응답 확인: index + vendor 마운트
  local idx ven ok=false
  for _ in $(seq 1 20); do
    idx="$(curl -s --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null || true)"
    case "$idx" in *RUN-OK-$name*) ok=true; break;; esac; sleep 1
  done
  $ok || { echo "FAIL[$name]: 서비스 응답 없음 (got: ${idx:-})"; docker logs "$cname" 2>&1 | tail; return 1; }
  ven="$(curl -s --max-time 3 "http://127.0.0.1:$port/vendor/marker.txt" 2>/dev/null || true)"
  echo "  [$name] 컨테이너 RUNNING(port $port) · GET / = ${idx} · GET /vendor/marker.txt = ${ven}"
  case "$ven" in *DEP-CONTENT*) : ;; *) echo "FAIL[$name]: 컨테이너가 vendor(deps) 못 읽음"; return 1;; esac
  return 0
}

echo "================ 워크트리 2개: 링크 / 카피 로 deps 적용 후 실제 marina start ================"
PL="$(make_wt wt-link symlink)"
PC="$(make_wt wt-copy copy)"
echo "[setup] wt-link pid=$PL (vendor=symlink) · wt-copy pid=$PC (vendor=copy)"
echo
echo "---- wt-link (deps 를 symlink 로) ----"
start_and_check wt-link "$PL" yes || exit 1
echo
echo "---- wt-copy (deps 를 copy 로) ----"
start_and_check wt-copy "$PC" no || exit 1
echo
echo "================ 판정: 링크/카피 워크트리 둘 다 marina 로 기동·응답·deps 서빙 OK ✓ ================"
echo "PASS test-compose-linkcopy-run-e2e"
