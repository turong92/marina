#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; CTRL="$HERE/../scripts/marina-control.py"; SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""; cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null||true; rm -rf "$TMP"; }; trap cleanup EXIT
export MARINA_HOME="$TMP/home"; P="$TMP/proj"; mkdir -p "$P"; bash "$SH" project add "$P" >/dev/null
id="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$MARINA_HOME/projects.json')))['projects'][0]['id'])")"
cat > "$TMP/fake.sh" <<'EOF'
#!/usr/bin/env bash
cat "$MARINA_HOME/out"
EOF
chmod +x "$TMP/fake.sh"; mkdir -p "$MARINA_HOME/services"
printf '%s' '{"name":"web","portBase":3000,"cwd":".","run":"exec x {port}"}' > "$MARINA_HOME/out"

PORT=39730; b="http://127.0.0.1:$PORT"; H=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")
MARINA_LLM_FAKE="$TMP/fake.sh" MARINA_FAKE_VERIFY="ok" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -sf "${H[@]}" "$b/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done

# analyze -> candidates
curl -s "${H[@]}" -d "{\"root\":\"$P\"}" "$b/api/llm-analyze" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and r['candidates'][0]['name']=='web', r" || { echo "FAIL: llm-analyze"; exit 1; }

# register (verify ok) -> committed
curl -s "${H[@]}" -d "{\"root\":\"$P\"}" "$b/api/llm-register" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['ok'] and r['name']=='web', r" || { echo "FAIL: llm-register"; exit 1; }
python3 -c "import json;s=json.load(open('$MARINA_HOME/services/$id.json'))['services'];assert any(x['name']=='web' for x in s), s" || { echo "FAIL: register not committed"; exit 1; }

# cross-origin POST rejected
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Origin: http://evil.test" -H "content-type: application/json" -d "{\"root\":\"$P\"}" "$b/api/llm-analyze")
[[ "$code" == "403" ]] || { echo "FAIL: origin not enforced ($code)"; exit 1; }
echo "PASS test-llm-api"
