#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
f="$MARINA_HOME/services/$id.json"

# fake LLM emits out-<callcount> (fallback out-1)
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
c="$MARINA_HOME/calls"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
g="$MARINA_HOME/out-$n"; [[ -f "$g" ]] || g="$MARINA_HOME/out-1"; cat "$g"
EOF
chmod +x "$TMP/fake.sh"; export MARINA_LLM_FAKE="$TMP/fake.sh"
mkdir -p "$MARINA_HOME/services"

# run_loop [edit_name]
run_loop() { python3 - "$CTRL" "$P" "${1:-}" <<'PY'
import importlib.util, sys, json
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
edit = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
print(json.dumps(mc.llm_register_loop(Path(sys.argv[2]), edit_name=edit)))
PY
}

# 1) success on first verify -> committed + ok
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec x {port}"}' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="ok" run_loop | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] and r['name']=='web', r"
python3 -c "import json;s=json.load(open('$f'))['services'];assert any(x['name']=='web' for x in s), s" || { echo "FAIL: success not committed"; exit 1; }
bash "$SH" service rm "$id" web >/dev/null

# 2) fix-then-success: attempt1 verify fails, analyze#2 yields good def, attempt2 ok -> committed
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec bad {port}"}' > "$MARINA_HOME/out-1"
printf '%s' '{"name":"web","portBase":3001,"cwd":".","run":"exec good {port}"}' > "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,ok" run_loop | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] and r['attempts']==2, r"
python3 -c "import json;s={x['name']:x for x in json.load(open('$f'))['services']};assert s['web']['portBase']==3001, s" || { echo "FAIL: fix not committed"; exit 1; }
bash "$SH" service rm "$id" web >/dev/null

# 3) exhausted on ADD -> rolled back (web absent)
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec bad {port}"}' > "$MARINA_HOME/out-1"; rm -f "$MARINA_HOME/out-2"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,fail" run_loop | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] is False, r"
python3 -c "import json,os;p='$f';s=json.load(open(p))['services'] if os.path.exists(p) else [];assert not any(x['name']=='web' for x in s), s" || { echo "FAIL: add not rolled back"; exit 1; }

# 4) exhausted on EDIT -> prior def restored
bash "$SH" service add "$id" '{"name":"api","portBase":8080,"cwd":".","run":"exec orig {port}"}' >/dev/null
printf '%s' '{"name":"api","portBase":9090,"cwd":".","run":"exec broken {port}"}' > "$MARINA_HOME/out-1"
rm -f "$MARINA_HOME/calls"; MARINA_FAKE_VERIFY="fail,fail" run_loop api | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['ok'] is False, r"
python3 -c "import json;s={x['name']:x for x in json.load(open('$f'))['services']};assert s['api']['portBase']==8080 and 'orig' in s['api']['run'], s" || { echo "FAIL: edit not restored"; exit 1; }
echo "PASS test-llm-register-loop"
