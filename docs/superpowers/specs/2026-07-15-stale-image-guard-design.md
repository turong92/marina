# Stale Image Guard 설계

**상태:** 방향 승인, 구현 전 설계 확정
**범위:** Marina core의 Compose-kind Start/Rebuild 실행 경계

## 배경

Fast Start에서 `docker compose up -d --build`를 `up -d`로 분리한 뒤 같은 이미지를 다시 쓰는 시작은
빨라졌다. 하지만 Compose Watch가 꺼진 동안 branch를 바꾸거나 pull하여 Dockerfile, dependency manifest,
build arg가 달라진 경우에도 Start는 로컬의 옛 이미지를 그대로 사용할 수 있다. 실제로 ai-api branch 전환
후 `marina start`가 실패하고 `marina rebuild search-api`로 복구한 사례가 있었다.

문서로 Rebuild를 안내하는 것만으로는 사용자가 stale image를 먼저 진단해야 한다. 반대로 Start마다
`--build`를 복원하면 BuildKit이 cache hit을 판단하더라도 context 전송과 Dockerfile 평가가 반복되고,
여러 서비스를 동시에 시작할 때 시간과 메모리 peak가 다시 커진다.

## 목표

- Start와 Restart는 현재 이미지가 선언된 build 입력과 일치하면 기존처럼 `up -d`만 실행한다.
- 선택한 build 서비스의 입력이 마지막 성공 build와 다르면 해당 시작에만 `--build`를 자동 적용한다.
- Rebuild는 입력이 같아도 사용자의 명시적 요청이므로 항상 `--build`를 적용한다.
- 판단 기준은 표준 Compose 설정에 선언된 Dockerfile, `develop.watch`의 `action: rebuild` 경로,
  최종 build args와 실제 Docker image ID로 제한한다. `dockerfile_inline`은 Dockerfile 입력으로 취급한다.
- build arg 원문과 파일 내용은 상태, 로그, API에 노출하지 않는다.
- 기존 Compose 파일은 수정 없이 동작하고 image-only 서비스는 판정에서 제외한다.

## 비목표

- build context 전체 또는 언어별 manifest를 Marina가 추론하지 않는다.
- Git commit, branch, 세션명, 시간은 이미지 최신성의 근거로 사용하지 않는다.
- Compose Watch나 사용자가 Marina 밖에서 실행한 build를 이번 범위에서 추적하지 않는다.
- Docker/BuildKit cache 정리인 Clean Rebuild와 메모리 resource guard는 별도 작업으로 남긴다.
- registry image digest나 remote cache 최신성을 판정하지 않는다.

## 검토한 대안

### 1. Start마다 `--build`

정확하고 구현이 가장 단순하지만 Fast Start의 이점을 없애고 동시 build의 메모리 peak를 되살린다.
기본 정책으로 채택하지 않는다.

### 2. 변경 감지 후 경고만 표시

속도는 유지하지만 사용자가 실패 원인을 찾아 Rebuild를 다시 눌러야 하므로 현재 피드백을 해결하지 못한다.
입력 수집에 실패하여 자동 판정을 할 수 없는 경우의 fallback으로만 사용한다.

### 3. 마지막 성공 build baseline과 비교하여 조건부 build

변경이 없을 때는 기존 Fast Start를 유지하고, stale이 확실할 때만 Compose의 표준 `--build`를 사용한다.
Marina 전용 프로젝트 설정이나 언어별 규칙을 추가하지 않으므로 이 안을 채택한다.

## 상태 모델

현재 Build Timeline의 run snapshot은 Start, Restart, Rebuild마다 기록되는 관찰 데이터다. 이를 baseline으로
사용하면 build하지 않은 Start가 stale 입력을 정상 상태로 덮어쓸 수 있다. 따라서 실제 build 성공만 나타내는
별도 파일을 session directory에 둔다.

```text
.workspace/marina/<session>/build-baseline.json
```

파일 형식은 기존 build input snapshot의 service map을 재사용한다.

```json
{
  "version": 1,
  "status": "ok",
  "services": {
    "search-api": {
      "dockerfile": {"search_api/Dockerfile.local": "file:<sha256>"},
      "rebuild": {"search_api/requirements.txt": "file:<sha256>"},
      "buildArgs": {"INSTALL_BROWSER": "<hmac>"},
      "image": {"ref": "project-search-api:latest", "id": "sha256:<image-id>"}
    }
  }
}
```

- 파일과 lock은 `0600`으로 생성한다.
- selective build가 다른 서비스 기록을 지우지 않도록 exclusive file lock 아래 service 단위로 merge한다.
- 임시 파일 작성 후 atomic replace한다.
- raw build arg 값은 기존 로컬 key를 이용한 HMAC만 저장한다.
- 이 파일은 Marina 내부 runtime state이며 project Compose나 `x-marina` 공유 설정에 추가하지 않는다.

## 실행 흐름

`marina-compose.py cmd_up`은 resolved Compose config, 선택 서비스, 최종 build args가 모두 준비된 현재의
submit boundary에서 다음 순서를 수행한다.

1. 기존 500ms 제한 snapshot 수집으로 현재 입력을 얻는다.
2. session의 마지막 성공 build baseline과 baseline image ref의 현재 Docker image ID를 읽는다.
3. 명시적 Rebuild인지, 입력 또는 실제 image ID가 stale인지에 따라 effective build mode를 결정한다.
4. effective build면 `docker compose up -d --build`, 아니면 `up -d`를 실행한다.
5. effective build가 성공한 경우에만 선택 서비스의 현재 snapshot과 Compose image ID를 baseline에 merge한다.
6. 실패, timeout, 입력 수집 실패에서는 baseline을 변경하지 않는다.

판정표는 다음과 같다.

| 요청 | 현재 입력 | baseline 비교 | 동작 |
|---|---|---|---|
| Rebuild | 임의 | 임의 | 항상 `--build` |
| Start/Restart | `ok` | 동일 | fast `up -d` |
| Start/Restart | `ok` | 변경 | 자동 `--build` |
| Start/Restart | `ok` | 서비스 기록 없음 | 최초 1회 자동 `--build` |
| Start/Restart | `unknown` | 임의 | fast `up -d` + 명시적 경고 |
| Start/Restart | build 서비스 없음 | 임의 | 판정 없이 `up -d` |

설치 후 기존 세션에는 baseline이 없으므로 build 서비스별 첫 Start에서 한 번 `--build`가 실행된다. 이는
baseline을 신뢰할 수 있게 만드는 호환 비용이며, 이후 입력이 같으면 다시 Fast Start로 돌아간다.

## 선언 계약

Marina는 큰 build context 전체를 매 Start마다 hash하지 않는다. `action: rebuild`가 디렉터리를 가리키면
그 디렉터리의 파일 내용·타입·권한과 빈 디렉터리를 hash한다. 이미지에 bake되어 변경 시 rebuild가 필요한
파일은 Compose 표준 `develop.watch`에 `action: rebuild`로 선언해야 한다. 실행 중 동기화할 일반 source는
`action: sync`로 선언한다. Dockerfile과 최종 build args는 별도 선언 없이 포함된다.

따라서 아무 Watch 선언 없이 `COPY . .`만 사용하는 프로젝트의 임의 source 변경까지 자동 판정하는 기능은
아니다. 해당 프로젝트는 Rebuild를 사용하거나 rebuild 경로를 Compose에 선언해야 한다. 이 제한은 Fast
Start에서 전체 context scan을 피하기 위한 명시적 선택이다.

## 사용자 노출

자동 build 시 build log의 Compose 명령 직전에 다음처럼 이유를 남긴다.

```text
stale image: search-api requirements.txt changed; Start에 --build 자동 적용
```

이유는 기존 `compare_build_inputs`의 안전한 projection을 재사용하며 digest와 HMAC은 출력하지 않는다.
여러 이유는 서비스와 label 기준으로 결정적으로 정렬한다. 입력 수집 실패 시에는 Start를 막거나 반복 build하지
않고 다음 경고를 남긴다.

```text
warning: build 입력을 확인하지 못해 기존 이미지로 시작합니다; 문제가 있으면 Rebuild를 실행하세요.
```

Build Timeline의 run-to-run Why Rebuilt는 관찰 기능으로 그대로 유지한다. baseline은 자동 build 여부를
결정하는 내부 상태로 사용하며 API에 raw payload를 새로 공개하지 않는다.

## 외부 build와 Watch

Compose Watch가 자동 rebuild하거나 사용자가 직접 `docker compose build`하면 baseline의 선언 입력은 즉시
바뀌지 않는다. 대신 baseline에 저장한 image ref의 현재 Docker image ID가 달라지므로 다음 Marina Start가
이를 감지해 build한다. 입력이 A→B→A로 돌아온 경우에도 실제 image ID가 다르면 fast path를 허용하지 않는다.

## 실패 및 동시성

- snapshot 수집은 기존 500ms 상한을 유지하여 Start 자체를 지연시키지 않는다.
- `unknown`은 baseline에 저장하지 않고 자동 build 조건으로도 사용하지 않아 무한 rebuild를 피한다.
- Compose up/build가 실패하면 baseline은 이전 성공 상태를 유지한다.
- 동시에 서로 다른 서비스를 시작해도 baseline lock 안에서 service map을 merge하여 갱신 유실을 막는다.
- 같은 build 서비스를 포함하는 Start/Rebuild는 service lock을 정렬 순서로 획득하고 overlay 작성부터 build,
  image ID 확인, baseline 갱신까지 직렬화한다. 서로 다른 build 서비스는 병렬 실행할 수 있다.
- baseline JSON이 손상되면 기록 없음으로 취급하고 다음 정상 snapshot에서 1회 자동 build로 복구한다.
- snapshot이 디렉터리를 hash할 때 Marina의 session directory는 제외한다. capture 임시 파일, baseline,
  lock이 자신의 digest를 바꿔 영구 rebuild를 만드는 자기관찰을 방지한다.

## 테스트

1. 동일 snapshot과 baseline은 Start/Restart에 `--build`를 추가하지 않는다.
2. Dockerfile, rebuild path, build arg의 added/changed/removed는 선택 서비스 Start에 `--build`를 추가한다.
3. baseline이 없는 build 서비스의 첫 Start만 `--build`하고 성공 후 두 번째 Start는 fast path를 탄다.
4. 명시적 Rebuild는 입력이 같아도 항상 `--build`한다.
5. build 실패와 snapshot `unknown`은 baseline을 갱신하지 않는다.
6. image-only 서비스는 baseline과 자동 build 판정에 포함하지 않는다.
7. service별 selective build와 동시 merge가 다른 서비스 baseline을 보존한다.
8. build arg 원문, digest, HMAC이 build log와 공개 API에 노출되지 않는다.
9. Watch/direct build의 image ABA와 같은 서비스의 동시 Start가 fast path를 잘못 허용하지 않는다.
10. inline Dockerfile과 preserved-mtime 디렉터리 내용 변경을 감지한다.
11. 기존 Compose dispatch, Build Timeline, Why Rebuilt, Watch 테스트를 함께 실행한다.

## 완료 기준

- branch 전환으로 선언된 build 입력이 달라진 뒤 Start만 실행해도 필요한 서비스가 자동 rebuild된다.
- 입력이 같은 연속 Start는 Docker build 단계 없이 기존 속도를 유지한다.
- Rebuild와 자동 stale build 모두 성공한 경우에만 baseline이 갱신된다.
- 수집 실패와 외부 build의 한계를 로그와 문서에서 숨기지 않는다.
- 전체 Marina 테스트가 통과한다.
