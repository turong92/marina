# 테스트 공통 격리 — 모든 test-*.sh 가 맨 위에서 source 한다.
#
# **왜.** marina 터미널에서 테스트를 돌리면 셸이 데몬의 자식이라 데몬 환경을 통째로 물려받는다
# (MARINA_HOME=~/.marina, MARINA_CONTROL_HOST=localhost, MARINA_CONTROL_PORT=3900 ...).
# 그래서 테스트가 형의 실제 상태를 읽고 쓰게 되고, 실패가 "형 머신에서만" 나는 것처럼 보였다:
#   - marina_term 이 실 데몬의 terms/*.json 을 레지스트리로 복원 → 살아있는 세션이 _by_key 에
#     섞여 "reap 이 청소했나" 단언이 깨짐(test-term)
#   - 실 auth.db 를 읽어 auth 켜진 머신에서만 401(test-host-guard)
#   - 상속된 MARINA_CONTROL_HOST/PORT 가 저장된 bind 값을 가려 "재시작에 bind 가 리셋됐다"
#     로 보임(test-dashboard-launch) — 실제 코드는 멀쩡했다
#   - 테스트가 띄운 데몬이 실 MARINA_HOME 을 쥔 채 유출(포트 3910 점유 상태로 발견)
# 즉 "테스트가 실패한다"가 아니라 **테스트가 형의 실제 환경을 물려받는다**가 진짜 문제다.
#
# **어떻게.** MARINA_* 를 통째로 지우고 MARINA_HOME 만 테스트 전용 경로로 다시 세운다.
# 필요한 변수는 각 테스트가 이 뒤에서 스스로 세운다 — 상속은 없다.
# 경로는 테스트 파일 이름으로 고정하고 시작할 때 비운다. trap 을 걸지 않으므로 테스트가 나중에
# 자기 trap 을 덮어써도 격리가 풀리지 않고, 경로가 고정이라 반복 실행에 임시 디렉터리가 쌓이지 않는다.
while IFS='=' read -r _marina_var _; do
  [ -n "$_marina_var" ] && unset "$_marina_var"
done <<EOF
$(env | grep '^MARINA_' || true)
EOF
unset _marina_var

_marina_test_home_root="${TMPDIR:-/tmp}"
_marina_test_home_root="${_marina_test_home_root%/}/marina-test-home"   # macOS TMPDIR 은 / 로 끝난다
MARINA_HOME="${_marina_test_home_root}/$(basename -- "${0}" .sh)"
rm -rf "$MARINA_HOME"
mkdir -p "$MARINA_HOME"
export MARINA_HOME
unset _marina_test_home_root

# e2e 산출물 표식 — marina-compose.py up 이 이 값을 보고 오버레이에 라벨 marina.e2e=1 을 붙인다(컨테이너·이미지·네트워크).
# 테스트가 정리를 빠뜨려도(compose down 은 빌드 이미지를 안 지운다, 실측 383개 누수) 도커 GC 정책의
# stale_test_artifacts_days 규칙이 라벨로 찾아 회수한다. 테스트가 직접 치는 `docker run` 은 --label marina.e2e=1 을 붙일 것.
export MARINA_E2E=1

# YAML 읽기는 진짜 docker 로. marina 는 compose YAML 을 `docker compose config --format json` 으로 읽는다(PyYAML 없음).
# 테스트가 라이프사이클 흉내용 가짜 docker 를 PATH 앞에 올려도(up/ps/config 픽스처) YAML 파싱은 그 가짜가 아니라
# 진짜 CLI 를 타야 한다 — 가짜의 `config --format json` 픽스처가 x-marina 로 둔갑하거나(prebuild-runtime), 가짜가
# 모르는 호출이라 exit 99 로 죽어(entrypoint-lifecycle-env) x-marina 가 {} 로 사라진다. 위의 MARINA_* 초기화 뒤에 세운다.
MARINA_YAML_DOCKER="$(command -v docker 2>/dev/null || true)"
export MARINA_YAML_DOCKER
