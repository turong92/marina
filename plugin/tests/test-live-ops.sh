#!/usr/bin/env bash
# L3 운영 — 백업 대상 목록, 배포 이력, 세 갈래 헬스 신호, 데이터 용량.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - "$SCRIPTS" <<'PY'
import json, os, pathlib, sys, time
sys.path.insert(0, sys.argv[1])
import marina_live as L
import marina_live_ops as O

HOME = pathlib.Path(os.environ["MARINA_HOME"])
(HOME / "projects.json").write_text(json.dumps({"projects": [
    {"id": "ovation", "root": "/x", "composeFile": "docker-compose.yml",
     "live": {"ref": "v1", "services": ["server"], "envFile": ".env.prod"}}]}), encoding="utf-8")

# ── 1) 백업 대상 ─────────────────────────────────────────────────────────────
paths = O.backup_paths("ovation")
flat = [p["path"] for p in paths]

# projects.json 이 빠지면 데이터를 복원해도 **무엇을 어떻게 띄웠는지 모른다**
assert str(HOME / "projects.json") in flat, flat
# 서비스 데이터
assert str(L.live_data("ovation")) in flat, flat
# 비밀 파일 — 홈서버에서 시드가 백업에서 빠져 데이터가 잠기는 사고를 실측했다
secret_entries = [p for p in paths if p["secret"]]
assert secret_entries, paths
assert any("secrets.env" in p["path"] for p in secret_entries), secret_entries
assert any(".env.prod" in p["path"] for p in secret_entries), secret_entries
# 모든 항목이 '왜' 를 함께 낸다 — 목록만 주면 사용자가 하나씩 빼먹는다
assert all(p["why"] for p in paths), paths
# 비밀이 포함됐다는 경고가 있다
assert any("비밀" in w for w in O.backup_warnings("ovation")), O.backup_warnings("ovation")

# ── 2) 배포 이력 ─────────────────────────────────────────────────────────────
assert O.read_history("ovation") == []
O.append_history("ovation", "v1", note="첫 배포")
time.sleep(0.01)
O.append_history("ovation", "v2")
rows = O.read_history("ovation")
assert [r["ref"] for r in rows] == ["v1", "v2"], rows
assert rows[0]["note"] == "첫 배포", rows
assert all(r["at"] for r in rows), rows
# 롤백해도 코드만 돌아간다 — 마이그레이션은 안 돌아간다. 숨기면 사고가 된다.
assert "마이그레이션" in O.MIGRATION_WARNING, O.MIGRATION_WARNING
assert "되돌아가지 않는다" in O.MIGRATION_WARNING, O.MIGRATION_WARNING
# 깨진 줄이 있어도 나머지를 읽는다 (append-only 파일이 중간에 끊길 수 있다)
with O.history_file("ovation").open("a", encoding="utf-8") as fh:
    fh.write("{not json\n")
O.append_history("ovation", "v3")
assert [r["ref"] for r in O.read_history("ovation")] == ["v1", "v2", "v3"]

# ── 3) 데이터 용량 — '없음' 과 0 바이트를 구분한다 ───────────────────────────
u = O.data_usage("ovation")
assert u["exists"] is False, u
assert u["human"] == "없음", u          # 첫 기동 전과 데이터 유실을 구분한다
L.ensure_data_dir("ovation")
u = O.data_usage("ovation")
assert u["exists"] is True and u["bytes"] == 0, u
assert u["human"] == "0 B", u
(L.live_data("ovation") / "f").write_bytes(b"x" * 2048)
u = O.data_usage("ovation")
assert u["bytes"] >= 2048, u
assert "KB" in u["human"] or "MB" in u["human"], u

# ── 4) 헬스 신호는 코드를 그대로 보여준다 ───────────────────────────────────
# 홈서버 실측: 앱이 모든 경로를 인증 뒤에 두면 헬스체크가 401 을 받는다. 그걸 '살아 있음'
# 으로 처리하면 **DB 가 죽어도 healthy** 로 남는다. 단일 초록불을 만들지 않는다.
import http.server, threading

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.end_headers()
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
probe = O.health_probe(f"http://127.0.0.1:{srv.server_port}/actuator/health")
assert probe["code"] == 401, probe
assert "healthy" not in json.dumps(probe), probe
assert probe["error"] is None, probe
srv.shutdown()

# 닫힌 포트는 코드가 아니라 오류로 — 0 이나 500 으로 뭉개지 않는다
probe = O.health_probe("http://127.0.0.1:1/health")
assert probe["code"] is None and probe["error"], probe

# 헬스 경로 선언이 없으면 '선언 없음' 을 말한다 (조용히 통과시키지 않는다)
assert O.health_url({"live": {}}, {}) is None
print("ok")
PY

echo "--- CLI"
MARINA="bash $SCRIPTS/marina.sh"
mkdir -p "$MARINA_HOME"
cat > "$MARINA_HOME/projects.json" <<'JSON'
{"projects":[{"id":"opsproj","root":"/tmp","composeFile":"docker-compose.yml",
 "live":{"ref":"v1","services":["a"]}}],"schemaVersion":1}
JSON

# 1) backup-paths 출력에 projects.json 과 비밀 경고가 있다
out="$($MARINA live backup-paths opsproj 2>&1)"
case "$out" in *projects.json*) ;; *) echo "FAIL: projects.json 이 없다: $out"; exit 1 ;; esac
case "$out" in *비밀*) ;; *) echo "FAIL: 비밀 경고가 없다: $out"; exit 1 ;; esac

# 2) pin 두 번 → history 두 줄 + 마이그레이션 경고
$MARINA live pin opsproj v2 >/dev/null
$MARINA live pin opsproj v3 >/dev/null
out="$($MARINA live history opsproj 2>&1)"
case "$out" in *v2*) ;; *) echo "FAIL: 이력에 v2 가 없다: $out"; exit 1 ;; esac
case "$out" in *v3*) ;; *) echo "FAIL: 이력에 v3 가 없다: $out"; exit 1 ;; esac
case "$out" in *마이그레이션*) ;; *) echo "FAIL: 마이그레이션 경고가 없다: $out"; exit 1 ;; esac

# 3) status 가 데이터 용량과 '없음' 을 구분해 보여준다
out="$($MARINA live status opsproj 2>&1)"
case "$out" in *없음*) ;; *) echo "FAIL: 데이터 '없음' 을 안 보여준다: $out"; exit 1 ;; esac
echo "PASS test-live-ops"
