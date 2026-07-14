# Why Rebuilt 설계

날짜: 2026-07-15  
상태: 구현 승인

## 목표

Build Timeline이 시간과 cache hit/miss뿐 아니라 이전 Marina build run 이후 어떤 선언된 이미지 입력이
바뀌었는지 설명한다. 언어별 manifest 이름을 추측하지 않고 Compose가 이미 선언한 build 경계만 사용한다.

## 노출 위치

대시보드 오른쪽 `로그` 탭에서 synthetic `build` 로그를 선택했을 때 기존 Build Timeline 헤더 바로 아래에
`재빌드 이유` 한 줄을 둔다. 여러 이유는 접어서 보고 기본 화면에는 최대 세 개의 요약만 표시한다.

서비스 카드에는 넣지 않는다. 실행 전 stale image 경고는 P0.3/M1의 별도 범위다.

## 입력 모델

대시보드가 `start`, `restart`, `rebuild` lifecycle을 실행할 때 external worktree attach와 link/prebuild 준비가
끝난 뒤, `marina-compose.py`가 `docker compose up`을 호출하기 직전에 선택 서비스의 입력 스냅샷을 만든다.
이미 해석한 Compose config와 실제 `--build-arg`를 재사용해 config를 중복 조회하지 않으며, 0600 임시 handoff
파일을 통해 build run `.meta.json`에 저장한다. 실행 중 meta에는 `pending`만 둔다. 수집은 별도 자식
프로세스에서 최대 500ms만 수행하며, 제한을 넘으면 `unknown`으로 기록하고 Compose 제출을 계속한다.
동시 lifecycle 요청의 build run과 handoff 경로는 프로세스 내부 mutex와 파일 락으로 원자 할당한다.

- Compose `services.<name>.build.dockerfile`
- Compose `services.<name>.develop.watch` 중 `action: rebuild`인 path
- 해석된 Compose build args, `~/.marina/<project>/build-args.json`, `x-marina.buildArgsFrom`의 유효 값

Dockerfile과 rebuild path는 파일 내용 SHA-256을 저장한다. 디렉터리는 하위 파일의 상대경로, 크기, mtime을
정렬해 SHA-256으로 축약한다. 이 digest는 설명용 비교에만 사용하며 Docker cache key나 Watch trigger가 아니다.

build arg 원문은 로그, meta, API 어디에도 저장하지 않는다. `~/.marina/build-input.key`의 로컬 256-bit key로
이름별 HMAC-SHA256만 저장한다. API는 digest와 HMAC을 반환하지 않고 변경된 arg 이름만 반환한다.

## 비교 규칙

현재 run과 같은 세션에서 각 선택 서비스별로 입력 스냅샷이 있는 가장 가까운 과거 run을 비교한다. 서비스별
실행이 번갈아 와도 관계없는 서비스 전체를 added/removed로 오판하지 않는다.

- Dockerfile/rebuild path 추가, 제거, 내용 변경을 이유로 반환한다.
- build arg 추가, 제거, 값 변경을 이유로 반환한다.
- 직전 스냅샷이 없으면 `first-run`으로 정직하게 표시한다.
- 입력 차이가 없고 명령이 `rebuild`면 `explicit-rebuild`로 표시한다.
- snapshot 수집 실패는 빌드를 막지 않고 `unknown`으로 표시한다.

비교 결과는 `reasons: [{kind, service, label, change}]` 형태다. raw 입력 스냅샷은 API 응답에서 제외한다.

## 경계와 실패 처리

- automatic Compose Watch rebuild 로그 통합은 이번 범위 밖이다. 이 기능은 Marina 대시보드 lifecycle run을
  비교한다.
- snapshot 수집은 best-effort다. Docker/Compose config 실패가 실제 lifecycle의 기존 오류 처리보다 먼저
  빌드를 중단해서는 안 되며, 디렉터리 순회가 500ms를 넘겨도 자식 수집 프로세스를 종료하고 오류 원문을
  meta에 저장하지 않는다.
- 선택 서비스와 `startGroup`, Compose dependency closure는 Marina lifecycle과 같은 해석 함수를 사용한다.
- 이전 버전 meta에는 inputs가 없으므로 first-run으로 자연스럽게 호환한다.

## 검증

- 순수 단위 테스트: Dockerfile, rebuild path, build arg의 added/changed/removed와 secret 비노출.
- build log 테스트: run meta에 입력이 기록되고 이전 run 이유가 summary에 합쳐짐.
- 동시성/시간 제한 테스트: 병렬 lifecycle run 경로는 고유하고 정체된 입력 순회는 Compose 제출을 막지 않음.
- API 테스트: 이유만 반환하고 digest, HMAC, secret은 반환하지 않음.
- UI 정적 테스트와 Aside: build 로그 선택 시 요약/접기, 좁은 viewport, light/dark 확인.
