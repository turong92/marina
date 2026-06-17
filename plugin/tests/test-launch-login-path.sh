#!/usr/bin/env bash
# 서비스는 사용자 LOGIN PATH 로 떠야 한다 (빈약한 bash -lc PATH 가 아니라) — npx·ffprobe 등
# homebrew/node 툴을 per-service 핀 없이 찾게. marina_login_path 우선순위:
#   MARINA_PATH override > $SHELL -ilc 캡처 > 현재 PATH 폴백.
# start_service 는 env PATH="$(marina_login_path)" 로 그 PATH 를 서비스 프로세스에 주입한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
# 스모크 서비스: 기동 즉시 자기 PATH 를 파일로 남기고 잠시 대기 (start_service 주입 검증용).
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"smoke","portBase":19987,"cwd":".","run":"exec sh -c 'printf %s \"$PATH\" > path.out; sleep 2'"}]}
JSON
bash "$SH" project add "$P" >/dev/null

# 1) 명시 MARINA_PATH override 가 최우선
out="$(cd "$P" && MARINA_HOME="$MARINA_HOME" MARINA_PATH="/marker-override:/usr/bin:/bin" bash "$SH" print-launch-path)"
case "$out" in *"/marker-override"*) ;; *) echo "FAIL: MARINA_PATH override not honored: [$out]"; exit 1;; esac

# 2) 사용자 로그인+인터랙티브 셸($SHELL -ilc)로 캡처
FAKE="$TMP/fake-login-shell"
cat > "$FAKE" <<'SHX'
#!/usr/bin/env bash
# rc 를 source 해 PATH 를 빌드하는 로그인+인터랙티브 셸 흉내. fix 핵심인 -i(인터랙티브)
# 플래그가 실제로 전달되는지 검증 — 없으면 실패(→ 빈 출력 → 폴백 → 케이스2 단언이 fail).
case "${1:-}" in *i*) ;; *) echo "fake-shell: missing -i flag (got: $*)" >&2; exit 7;; esac
printf %s "/fake/brew/bin:/fake/node22/bin:/usr/bin:/bin"
SHX
chmod +x "$FAKE"
out="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SHELL="$FAKE" bash "$SH" print-launch-path)"
case "$out" in *"/fake/brew/bin"*) ;; *) echo "FAIL: did not capture via \$SHELL -ilc: [$out]"; exit 1;; esac
case "$out" in *"/fake/node22/bin"*) ;; *) echo "FAIL: captured login PATH missing node dir: [$out]"; exit 1;; esac

# 3) 캡처 실패(빈 출력) 시 현재 PATH 폴백 (기존 동작 보존)
EMPTY="$TMP/empty-shell"; printf '#!/usr/bin/env bash\nprintf %%s ""\n' > "$EMPTY"; chmod +x "$EMPTY"
out="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SHELL="$EMPTY" PATH="/sentinel-cur:$PATH" bash "$SH" print-launch-path)"
case "$out" in *"/sentinel-cur"*) ;; *) echo "FAIL: did not fall back to current PATH: [$out]"; exit 1;; esac

# 4) E2E: start_service 가 해석된 로그인 PATH 를 서비스에 실제 주입하는가 (env PATH= 배선)
rm -f "$P/path.out"
(cd "$P" && MARINA_HOME="$MARINA_HOME" MARINA_PATH="/e2e-marker:$PATH" bash "$SH" start --all >/dev/null 2>&1) || true
for _ in $(seq 1 20); do [[ -s "$P/path.out" ]] && break; sleep 0.3; done
(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" stop --all >/dev/null 2>&1) || true
[[ -s "$P/path.out" ]] || { echo "FAIL: smoke service did not write PATH (start_service launch failed?)"; exit 1; }
got="$(cat "$P/path.out")"
case "$got" in *"/e2e-marker"*) ;; *) echo "FAIL: launched service PATH missing injected marker: [$got]"; exit 1;; esac

echo "PASS test-launch-login-path"
