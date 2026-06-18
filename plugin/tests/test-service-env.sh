#!/usr/bin/env bash
# 서비스 `env` 주입: 정의의 env(토큰 포함)가 run 과 동일한 per-worktree 치환으로 서비스에 주입된다.
# 격리: mktemp 임시 프로젝트 + fake 서비스만 — 기존 서브레포/라이브 config 는 읽지 않는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
# search 는 형제 be 포트({be_port})와 자기 포트({port})를 env 로 받는다. (temp dir = 비-worktree → offset 0)
cat > "$P/marina-services.json" <<'JSON'
{"services":[
  {"name":"be","portBase":8081,"cwd":".","run":"exec sleep 30"},
  {"name":"search","portBase":8002,"cwd":".","run":"exec sh -c 'printf %s \"$BE_API_URL\" > env.out; sleep 30'","env":{"BE_API_URL":"http://localhost:{be_port}","SELF":"http://localhost:{port}"}}
]}
JSON
bash "$SH" project add "$P" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }

# 1) print-env: {be_port}→형제 be 실제 포트, {port}→자기 포트
out="$(mrun print-env search)"
case "$out" in *"BE_API_URL=http://localhost:8081"*) ;; *) echo "FAIL: BE_API_URL not resolved to be port: [$out]"; exit 1;; esac
case "$out" in *"SELF=http://localhost:8002"*) ;; *) echo "FAIL: SELF not resolved to own port: [$out]"; exit 1;; esac

# 2) env 없는 서비스(be)는 빈 출력
[[ -z "$(mrun print-env be)" ]] || { echo "FAIL: be should have no env"; exit 1; }

# 3) 스키마 보존: env 가 머지(service ls) 후에도 남음 (Codex: 미지필드 drop 방지)
case "$(mrun service ls proj 2>/dev/null || true)" in *"BE_API_URL"*) ;; *) echo "FAIL: env dropped from merge/service ls"; exit 1;; esac

# 4) E2E: 기동된 search 가 BE_API_URL 을 실제로 주입받음
rm -f "$P/env.out"
mrun start --all >/dev/null 2>&1 || true
for _ in $(seq 1 20); do [[ -s "$P/env.out" ]] && break; sleep 0.3; done
# exp 는 start 후 resolve — 포트 점유 시 자동이동(shift) 박제를 반영 (shift 전 계산하던 race 교정)
exp="$(mrun print-env search | sed -n 's/^BE_API_URL=//p')"
mrun stop --all >/dev/null 2>&1 || true
[[ -s "$P/env.out" ]] || { echo "FAIL: search didn't write env.out (injection?)"; exit 1; }
got="$(cat "$P/env.out")"
[[ "$got" == "$exp" && -n "$exp" ]] || { echo "FAIL: injected BE_API_URL [$got] != resolved [$exp]"; exit 1; }

# 5) 잘못된 env 키 거부 (공백·= → wrong-key 주입 방지, Codex)
for bad in \
  '{"name":"b1","portBase":9990,"run":"exec true","env":{"A B":"x"}}' \
  '{"name":"b2","portBase":9991,"run":"exec true","env":{"A=B":"x"}}'; do
  if mrun service add proj "$bad" >/dev/null 2>&1; then echo "FAIL: bad env key accepted: $bad"; exit 1; fi
done

echo "PASS test-service-env"
