#!/usr/bin/env bash
# marina config / overrides.json: 워크트리 env·port override + 관측.
# 격리: mktemp 임시 프로젝트 + fake 서비스만 — 라이브 config 안 읽음.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
cat > "$P/marina-services.json" <<'JSON'
{"services":[
  {"name":"be","portBase":8081,"cwd":".","run":"exec sleep 30"},
  {"name":"search","portBase":8002,"cwd":".","run":"exec sleep 30","env":{"BE_API_URL":"http://localhost:{be_port}","LOG_LEVEL":"info"},"links":{"venv":{"to":".venv","from":"{source}/.venv"},"localEnv":{"glob":".env*.local"}}}
]}
JSON
bash "$SH" project add "$P" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }

# overrides.json: env override(BE_API_URL) + null 해제(LOG_LEVEL) + port override(be)
SDIR="$(mrun print-session-dir)"; mkdir -p "$SDIR"
cat > "$SDIR/overrides.json" <<'JSON'
{"version":1,"env":{"search":{"BE_API_URL":"http://host:9000","LOG_LEVEL":null}},"ports":{"be":8412}}
JSON

# 1) env override 적용 — print-env 가 override 값을 보여줌
out="$(mrun print-env search)"
case "$out" in *"BE_API_URL=http://host:9000"*) ;; *) echo "FAIL: env override not applied: [$out]"; exit 1;; esac
# 2) null 해제 — LOG_LEVEL 키 자체가 사라짐
case "$out" in *"LOG_LEVEL="*) echo "FAIL: nulled key still present: [$out]"; exit 1;; *) ;; esac

# 3) port override 적용 — be 가 overrides.json 값(8412)을 씀 (offset 0, default 8081)
case "$(mrun ports)" in *"be=8412"*) ;; *) echo "FAIL: port override not applied: [$(mrun ports)]"; exit 1;; esac
# 4) override 없는 포트는 default 유지
case "$(mrun ports)" in *"search=8002"*) ;; *) echo "FAIL: non-overridden port changed: [$(mrun ports)]"; exit 1;; esac
# 5) port 로직 변경 후에도 env override 유지 (회귀)
case "$(mrun print-env search)" in *"BE_API_URL=http://host:9000"*) ;; *) echo "FAIL: env override regressed after port change"; exit 1;; esac

# 6) marina config: env override 출처 + 덮인 값(base 토큰이 override된 be 포트 8412로 resolve) 노출
cfg="$(mrun config search)"
case "$cfg" in *"BE_API_URL"*"override"*"overrides.json"*) ;; *) echo "FAIL: env override provenance missing: [$cfg]"; exit 1;; esac
case "$cfg" in *"덮음"*"http://localhost:8412"*) ;; *) echo "FAIL: shadowed base value missing: [$cfg]"; exit 1;; esac
# 7) port override 출처
case "$cfg" in *"be"*"8412"*"override"*) ;; *) echo "FAIL: port override provenance missing: [$cfg]"; exit 1;; esac
# 8) 시크릿 redaction — TOKEN 값 마스킹
cat > "$SDIR/overrides.json" <<'JSON'
{"version":1,"env":{"search":{"API_TOKEN":"supersecretvalue"}}}
JSON
case "$(mrun config search)" in *"supersecretvalue"*) echo "FAIL: secret not redacted"; exit 1;; *) ;; esac

# --- links: 선언 표시 + control.py 보존 + override/해제 ---
rm -f "$SDIR/overrides.json"
# 9) base links 가 config 에 표시
case "$(mrun config search)" in *"links"*"venv"*) ;; *) echo "FAIL: links not shown in config: [$(mrun config search)]"; exit 1;; esac
# 10) control.py 가 links 보존 (service ls — 미지필드 drop 방지)
case "$(mrun service ls proj 2>/dev/null || true)" in *"venv"*) ;; *) echo "FAIL: links dropped from service ls"; exit 1;; esac
# 11) link override + null 해제 (overrides.json 손편집)
cat > "$SDIR/overrides.json" <<'JSON'
{"version":1,"links":{"search":{"venv":{"to":".venv","from":"/custom/venv"},"localEnv":null}}}
JSON
lc="$(mrun config search)"
case "$lc" in *"venv"*"/custom/venv"*"override"*) ;; *) echo "FAIL: link override provenance missing: [$lc]"; exit 1;; esac
case "$lc" in *"localEnv"*"해제"*) ;; *) echo "FAIL: link disable missing: [$lc]"; exit 1;; esac

# --- authoring: marina override set/unset/disable (overrides.json 편집) ---
rm -f "$SDIR/overrides.json"
# set env → print-env 반영
mrun override set search env NEW_KEY hello >/dev/null
case "$(mrun print-env search)" in *"NEW_KEY=hello"*) ;; *) echo "FAIL: override set env not applied"; exit 1;; esac
# set port → ports 반영
mrun override set be port 9999 >/dev/null
case "$(mrun ports)" in *"be=9999"*) ;; *) echo "FAIL: override set port not applied: [$(mrun ports)]"; exit 1;; esac
# disable → base 키(LOG_LEVEL=info) 해제
mrun override disable search env LOG_LEVEL >/dev/null
case "$(mrun print-env search)" in *"LOG_LEVEL="*) echo "FAIL: disable didn't null base key"; exit 1;; *) ;; esac
# unset env → override 제거 (base 에 NEW_KEY 없음 → 사라짐)
mrun override unset search env NEW_KEY >/dev/null
case "$(mrun print-env search)" in *"NEW_KEY="*) echo "FAIL: unset env didn't remove override"; exit 1;; *) ;; esac
# unset port → default(8081) 복원
mrun override unset be port >/dev/null
case "$(mrun ports)" in *"be=8081"*) ;; *) echo "FAIL: unset port didn't restore default: [$(mrun ports)]"; exit 1;; esac
# 잘못된 env 키 / 비정수 port 거부
if mrun override set search env "BAD KEY" x >/dev/null 2>&1; then echo "FAIL: bad env key accepted"; exit 1; fi
if mrun override set be port abc   >/dev/null 2>&1; then echo "FAIL: non-int port accepted"; exit 1; fi

echo "PASS test-config-observe"
