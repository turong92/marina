#!/usr/bin/env bash
# 바뀐 것만 돌린다.
#
# 형: "바뀐 부분만 하면되는데 왜 다하는지도 모르겠고." 맞는 지적이라 근거를 만들었다.
# 실측(2026-08-16): 세션 상태 캐시 하나 고치는데 192개를 다 돌려 10분 넘게 썼는데, 그 변경을
# 실제로 건드리는 테스트는 33개였다. 나머지는 도커 compose·게이트웨이라 상관이 없었다.
#
# 고르는 방법은 추측이 아니라 **import 그래프**다: 바뀐 모듈 → 그걸 (간접까지) import 하는
# 모듈들 → 그 모듈을 쓰는 테스트. 데몬(marina-control.py)을 띄우는 테스트는 그 데몬이 바뀐
# 모듈을 물고 있을 때만 고른다. 무엇을 왜 건너뛰었는지는 항상 출력한다 — 조용히 빠지면
# "다 통과"로 읽히니까.
#
#   ./run-affected.sh                 # 워킹트리 변경분(없으면 마지막 커밋) 기준
#   ./run-affected.sh HEAD~3          # 그 지점 이후 변경분 기준
#   ./run-affected.sh --list          # 고르기만 하고 실행 안 함
#   ./run-affected.sh --deep          # 데몬에만 간접으로 닿는 것까지(push 전 한 번)
#   ./run-affected.sh --all           # 전부(느린 docker e2e 포함)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"

LIST_ONLY=0
RUN_ALL=0
DEEP=0
BASE=""
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    --deep) DEEP=1 ;;
    --all) RUN_ALL=1 ;;
    *) BASE="$arg" ;;
  esac
done

PICKER="$(mktemp)"; trap 'rm -f "$PICKER"' EXIT
cat > "$PICKER" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

repo, here = Path(os.environ["REPO"]), Path(os.environ["HERE"])
base, run_all = os.environ.get("BASE", ""), os.environ.get("RUN_ALL") == "1"
scripts = repo / "plugin" / "scripts"
tests = sorted(p.name for p in here.glob("test-*.sh"))

def git(*args):
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return [line for line in out.stdout.splitlines() if line.strip()]

if run_all:
    print("\n".join(tests))
    print("::note::--all: 전부 실행", file=sys.stderr)
    sys.exit(0)

# ① 무엇이 바뀌었나 — 워킹트리에 변경이 있으면 그것, 없으면 마지막 커밋.
if base:
    changed, origin = git("diff", "--name-only", base), f"{base} 이후"
else:
    changed = git("diff", "--name-only") + git("diff", "--name-only", "--cached")
    origin = "워킹트리 변경분"
    if not changed:
        changed, origin = git("diff", "--name-only", "HEAD~1"), "마지막 커밋"
changed = sorted(set(changed))
if not changed:
    print("::note::바뀐 파일이 없다", file=sys.stderr)
    sys.exit(0)

# ② import 그래프(정방향) → 바뀐 모듈을 물고 있는 모듈들(역방향 폐포).
imports: dict[str, set[str]] = {}
for path in scripts.glob("*.py"):
    text = path.read_text(encoding="utf-8", errors="ignore")
    imports[path.stem] = set(re.findall(r"^\s*(?:from|import)\s+(marina_\w+)", text, re.M))

changed_modules = {Path(c).stem for c in changed if c.endswith(".py") and "/scripts/" in c}

# ②-1 **무엇이** 바뀌었나 — 모듈 이름만으로 고르면 그 모듈을 쓰는 테스트 전부가 걸린다.
# diff 에서 실제로 손댄 함수·상수 이름을 뽑아, 그걸 부르는 테스트를 정조준한다.
symbol = re.compile(r"^[+-]\s*(?:def|class)\s+(\w+)|^[+-]\s*(_?[A-Z][A-Z0-9_]{2,})\s*(?::[^=]+)?=")
scoped = ["--", "plugin/scripts"]      # 테스트 파일의 HERE=/TMP= 같은 것까지 심볼로 세면 전부 걸린다
diff_args = (["diff", "-U0", base] if base else ["diff", "-U0", "HEAD"]) + scoped
changed_symbols = set()
for line in git(*diff_args) or git("diff", "-U0", "HEAD~1"):
    found = symbol.match(line)
    name = (found.group(1) or found.group(2)) if found else ""
    # 흔한 낱말(services·render·user…)은 아무 데나 걸려 신호가 안 된다. 실측: `def services`
    # 하나 때문에 선택이 55개→117개로 부풀었다. 밑줄이 든 이름이나 아주 긴 이름만 신호로 쓴다.
    if name and ("_" in name or len(name) >= 12):
        changed_symbols.add(name)

closure, frontier = set(changed_modules), set(changed_modules)
while frontier:
    dependents = {mod for mod, deps in imports.items() if deps & frontier} - closure
    closure |= dependents
    frontier = dependents

# 데몬이 바뀐 모듈을 물고 있으면, 데몬을 띄우는 테스트도 영향권이다(HTTP 표면으로 새어나온다).
control = scripts / "marina-control.py"
control_deps = set(re.findall(r"^\s*(?:from|import)\s+(marina_\w+)", control.read_text(encoding="utf-8"), re.M))
seen, frontier = set(control_deps), set(control_deps)
while frontier:
    nxt = set().union(*(imports.get(m, set()) for m in frontier)) - seen
    seen |= nxt
    frontier = nxt
daemon_affected = bool(seen & closure) or any(c.endswith("marina-control.py") for c in changed)

# 스크립트가 아닌 자산(웹 JS/CSS, 훅, 셸)은 파일명으로 직접 찾는다.
asset_names = {Path(c).name for c in changed if not c.endswith(".py") and "/plugin/" in c}
changed_tests = {Path(c).name for c in changed if "/tests/" in c and c.endswith(".sh")}

deep = os.environ.get("DEEP") == "1"
direct, indirect, heavy, skipped = [], [], [], []
for name in tests:
    text = (here / name).read_text(encoding="utf-8", errors="ignore")
    # 도커·caddy 를 실제로 띄우는 e2e 는 한 건에 수 분이다. 컨테이너 오케스트레이션을 건드리지
    # 않았으면 기본 실행에서 뺀다(--all 로 돌린다). 무엇을 뺐는지는 아래에서 반드시 말한다.
    container_e2e = ("docker compose" in text or "caddy" in text)
    touches_containers = any(mod in ("marina_compose", "marina_gateway", "marina_weave", "marina_links")
                             for mod in changed_modules)
    hits = lambda names: any(re.search(rf"\b{re.escape(n)}\b", text) for n in names)
    if (name in changed_tests or hits(changed_modules) or hits(changed_symbols)
            or any(asset in text for asset in asset_names)):
        direct.append(name)                                   # 바뀐 모듈·심볼을 직접 부른다
    elif hits(closure - changed_modules) or (daemon_affected and "marina-control.py" in text):
        indirect.append(name)                                 # 의존 모듈·데몬을 통해서만 닿는다
    else:
        skipped.append(name)
    if container_e2e and not touches_containers and name in direct:
        direct.remove(name)
        heavy.append(name)

selected = direct + (indirect if deep else [])
print("\n".join(selected))
note = (f"{origin} {len(changed)}개 파일 · 영향 모듈 {len(closure)}개 → "
        f"바뀐 심볼 {len(changed_symbols)}개 → 직접 {len(direct)}개" + (f" + 데몬 간접 {len(indirect)}개" if deep else "") +
        f" 실행, 무관 {len(skipped)}개 제외")
if heavy:
    note += f"\n::note::도커/caddy e2e {len(heavy)}개는 건너뜀(컨테이너 코드 안 바뀜) — 필요하면 --all"
if indirect and not deep:
    # 조용히 빠지면 "다 통과"로 읽힌다 — 무엇을 안 돌렸는지 항상 말한다.
    note += f"\n::note::데몬 간접 {len(indirect)}개는 건너뜀 — push 전엔 --deep 으로 한 번 돌릴 것"
print(f"::note::{note}", file=sys.stderr)
PY

SELECTED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SELECTED+=("$line")
done < <(REPO="$REPO" HERE="$HERE" BASE="$BASE" RUN_ALL="$RUN_ALL" DEEP="$DEEP" python3 "$PICKER")

[[ ${#SELECTED[@]} -eq 0 ]] && { echo "돌릴 테스트가 없다"; exit 0; }
if [[ "$LIST_ONLY" == "1" ]]; then printf '%s\n' "${SELECTED[@]}"; exit 0; fi

pass=0; fail=0; failed=()
for t in "${SELECTED[@]}"; do
  out="$(bash "$HERE/$t" 2>&1)"
  if grep -qE "^PASS|^ok$|^SKIP" <<<"$out" && ! grep -qE "AssertionError|^FAIL|Traceback" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$t")
    printf '\n=== FAIL %s\n%s\n' "$t" "$(tail -n 15 <<<"$out")"
  fi
done
echo
echo "PASS=$pass FAIL=$fail (선택 ${#SELECTED[@]}개)"
[[ $fail -gt 0 ]] && { printf '실패: %s\n' "${failed[@]}"; exit 1; }
exit 0
