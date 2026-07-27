#!/usr/bin/env bash
# LLM 이 만든 파일이 macOS 보호 폴더(~/Downloads·Desktop·Documents)에 떨어지면 그 뒤로 그 폴더를 읽을
# 때마다 시스템 권한 팝업이 뜬다(실측: '2.1.220'이(가) 다운로드 폴더의 파일에 접근하려고 합니다).
# CLI 는 버전마다 경로가 바뀌는 단일 실행파일이라 허용이 유지되지도 않는다. 그래서 애초에 안 쓰게 막는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-protected-write-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$HOME/work"

req() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$1" "$2"; }
deny()  { out="$(req "$1" "$2" | "$HOOK")"; echo "$out" | grep -q '"permissionDecision": *"deny"' \
            || { echo "FAIL(deny 기대): $1 $2 → [$out]"; exit 1; }; }
allow() { out="$(req "$1" "$2" | "$HOOK")"; [[ -z "$out" ]] || { echo "FAIL(allow 기대): $1 $2 → [$out]"; exit 1; }; }

# --- 보호 폴더 쓰기는 막는다(도구 3종) ---
for tool in Write Edit NotebookEdit; do
  deny "$tool" "$HOME/Downloads/report.md"
  deny "$tool" "$HOME/Desktop/note.txt"
  deny "$tool" "$HOME/Documents/a/b/deep.md"
done
deny apply_patch "$HOME/Downloads/codex.md"             # Codex 의 파일 쓰기도 같은 규칙
deny Write "$HOME/Downloads/sub/dir/nested.md"          # 하위 경로도
deny Write "$HOME/Downloads"                            # 폴더 자체
# 상대경로·물결표도 같은 곳을 가리키면 막는다 — 우회로가 되면 가드가 의미 없다
( cd "$HOME/Downloads" && deny Write "./slip.md" )
deny Write "~/Downloads/tilde.md"

# --- 그 외는 전부 통과 ---
allow Write "$HOME/work/report.md"
allow Write "$TMP/anywhere.md"
allow Write "$HOME/Downloadsnot/x.md"                   # 접두사만 같은 별개 폴더
allow Write "$HOME/mydocs/x.md"
allow Bash  "$HOME/Downloads/report.md"                 # 대상 도구가 아니면 관여 안 함
allow Read  "$HOME/Downloads/report.md"

# --- 탈출구: 형이 명시적으로 열어두면 통과 ---
MARINA_ALLOW_PROTECTED_WRITE=1 allow Write "$HOME/Downloads/report.md"

# --- fail-open: 어떤 입력이 와도 파일 쓰기를 통째로 막지 않는다 ---
for bad in '' 'not json' '{}' '{"tool_name":"Write"}' '{"tool_name":"Write","tool_input":{}}' '{"tool_input":null}'; do
  out="$(printf '%s' "$bad" | "$HOOK")"
  [[ -z "$out" ]] || { echo "FAIL(깨진 입력은 allow): [$bad] → [$out]"; exit 1; }
done

# --- 이유 문구는 어디에 쓰라는지 알려줘야 한다(막기만 하면 LLM 이 헤맨다) ---
msg="$(req Write "$HOME/Downloads/x.md" | "$HOOK")"
for needle in "워크트리" "MARINA_ALLOW_PROTECTED_WRITE"; do
  grep -q "$needle" <<<"$msg" || { echo "FAIL: 이유 문구에 '$needle' 없음 → $msg"; exit 1; }
done

# --- 배선: hooks.json 이 실제로 이 훅을 부르는지 ---
python3 - "$HERE/../hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
entries = [(m.get("matcher",""), h.get("command",""))
           for m in d.get("hooks",{}).get("PreToolUse",[]) for h in m.get("hooks",[])]
hit = [m for m,c in entries if "marina-protected-write-hook.sh" in c]
assert hit, f"hooks.json 에 보호폴더 가드 배선 없음: {entries}"
for tool in ("Write","Edit","NotebookEdit"):
    assert any(tool in m for m in hit), f"{tool} 이 matcher 에 없음: {hit}"

# Codex 도 같은 팀이 쓴다 — 배선만 하고 판정 목록에 빠뜨리면 조용히 통과한다(실제로 한 번 그랬다).
cx = json.load(open(sys.argv[1].replace("hooks.json", "codex-hooks.json"), encoding="utf-8"))
cx_hit = [m.get("matcher","") for m in cx.get("hooks",{}).get("PreToolUse",[])
          for h in m.get("hooks",[]) if "marina-protected-write-hook.sh" in h.get("command","")]
assert cx_hit, "codex-hooks.json 에 배선 없음"
assert any("apply_patch" in m for m in cx_hit), f"apply_patch 가 matcher 에 없음: {cx_hit}"
print("ok hooks.json · codex-hooks.json 배선")
PY

echo "PASS test-protected-write-guard"
