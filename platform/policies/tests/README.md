# platform/policies/tests/ — 자격이 필요한 검사를 클러스터 안에서 도는 Job 3종

`psql`·`redis-cli`·Kafka 콘솔 도구·OpenFGA API처럼 **자격증명이 필요한 검사는 tester가 직접 실행하지 않는다**
(계약 `contracts/hostnames-and-access.md` §자격이 필요한 검사). 이 디렉터리의 Job이 네임스페이스 `jt-dev`
안에서 실행하고, tester는 **`kubectl -n jt-dev logs job/<이름>`으로 로그 텍스트만** 읽는다.

Job은 **dev scope 자격만** 받는다. prod 자격은 없다 — dev 자격은 `ClusterSecretStore vault-dev`에서만 나오고
그 store의 `conditions.namespaces`가 `jt-dev` 하나이므로, 세 Job의 네임스페이스도 `jt-dev` 하나다.

## 파일

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | **독립 kustomization**(`namespace: jt-dev`, resources 5). 상위 `platform/policies/kustomization.yaml`은 이 디렉터리를 참조하지 않는다 |
| `externalsecret-assert-env.yaml` | dev scope 자격 하나 — ExternalSecret `assert-env`(store `vault-dev`, `dev/` 키만) |
| `configmap-assert-config.yaml` | 비밀이 아닌 값(엔드포인트·DB/토픽/role 이름·합성 식별자) |
| `job-data-assert.yaml` | pg-main 6검사(T054가 `role-attrs` · `app-session-timeouts`를 더했다) + initContainer가 Dragonfly 7검사(T057이 `noauth` · `writer-set` · `reader-get` · `reader-set-denied` · `reader-cross-denied`를 더했다) |
| `job-kafka-assert.yaml` | Kafka 2검사 |
| `job-authz-assert.yaml` | OpenFGA 2검사 |

## 로그 계약 (tester·T031 파서 고정)

세 Job 모두 **같은 형식**으로 출력한다. 이 형식이 계약이며, 바꾸려면 `tests/platform/cluster.tests.ps1`의
`np-2-*`와 함께 바꾼다.

```
RESULT: PASS <검사 id> <근거 요약>
RESULT: FAIL <검사 id> <실패 사유>
SUMMARY: pass=<n> fail=<n>
```

- 검사 하나가 **정확히 한 줄**의 `RESULT:`를 낸다. 순서는 아래 표의 순서다.
- 마지막 줄은 항상 `SUMMARY: pass=<n> fail=<n>`이다.
- **종료 코드**: `fail=0`이면 0, 하나라도 실패하면 1. 즉 `status.succeeded ≥ 1`은 "모든 검사 PASS"와 같다.
- 보조 줄은 `EVIDENCE:`(원문 증거)와 `NOTE:`(정리 작업 기록)뿐이다. 파서는 `^RESULT:`·`^SUMMARY:`만 본다.
- **출력은 짧게 유지한다.** `cluster.tests.ps1`의 `np-2-*`와 모노레포 `data.tests.ps1`의 `job-2`는 `kubectl logs job/<이름> --tail=50`을 읽으므로,
  모든 `RESULT:`와 `SUMMARY:`는 마지막 50줄 안에 들어와야 한다(현재 최대 **22줄** = data-assert: pg `RESULT` 6 + initContainer 줄 ≤ 15
  (`RESULT` 7 + `EVIDENCE:` 머리 1 + ACL LIST ≤ 6(`head -n 6`) + `NOTE:` 정리 1) + `SUMMARY` 1 · kafka-assert ≤ 5 · authz-assert ≤ 5 — **T057 재계산**(dev aclfile 4사용자면 ACL LIST 4행 → 20줄) ·
  kafka-assert는 T056 재계산. 이전 표기: T054 "16줄"(initContainer ≤ 9 = `RESULT` 2) · 그 전 "11줄"은 ACL LIST 6줄 상한을 덜 센 값이었다(T054 전 data-assert 최대 = 14줄)).
  **kafka-assert ≤ 5 — T056 재계산(리뷰 r1 O5 · r2 K5 · O11)**(컨슈머 선기동 · `latency=` 토큰 · 프로듀서 오류 증거 · 비밀번호 형식 검사): `RESULT` 2 + `SUMMARY` 1 + `EVIDENCE:` ≤ 2. `EVIDENCE:`를 내는 경로는 roundtrip의
  둘뿐이다 — "마커 미수신"(`EVIDENCE: consumer 수신 <n>줄 · stderr: …` 1줄 + `EVIDENCE: producer 마지막 오류: …` ≤ 1줄)과 "produce 실패"(`EVIDENCE: producer 마지막 오류: …` ≤ 1줄).
  **비밀번호 형식 검사(리뷰 r2 K5)**: 필수 값 확인 직후 · client.properties를 쓰기 **전**에 `KAFKA_PASSWORD`에 base64url(`A–Z a–z 0–9 _ -`) 밖의 문자가 하나라도 있으면 두 검사를
  `RESULT: FAIL <id> KAFKA_PASSWORD 형식이 base64url이 아니다(값 미출력 — 시드 블록 밖 kv 쓰기 의심 · JAAS 문자열을 안전하게 만들 수 없다)`로 닫고 `SUMMARY` 뒤 exit 1이다(3줄 · JVM 기동 0 ·
  값 · 길이 · 조각 출력 0). 따옴표가 든 값은 JAAS 문자열(`password="…"`)을 깨뜨려 Kafka가 파싱 오류 문구에 비밀번호 조각을 싣기 때문이다(Kafka 4.3.1 `JaasConfig.java` :113–116).
  **진단 줄 규칙 `safe_tail`(리뷰 r2 K5 · O11 — 진단 다섯 곳이 같다 · cross-env PASS 근거 줄도 같은 두 필터(들여쓴 줄 · `password`/`jaas` 줄 제외)를 거친다 — 리뷰 r3 A1)**: 컨슈머 stderr(`consumer_err`) · describe(`groups_note`) · 프로듀서 EVIDENCE · produce rc≠0 `RESULT` 줄 · cross-env 실패 꼬리는
  그 파일의 오류 · 상태 줄(대소문자 무시 error · exception · caused by · denied · not authorized · timeout · timed out + describe 상태 문구 active members · rebalancing · does not exist)
  가운데 들여쓴 줄(스택 프레임 `\tat …` · `\t... N more`)과 `password` · `jaas`가 든 줄(대소문자 무시)을 버린 뒤 마지막 줄의 뒤 140자다. 남는 줄이 없으면 프로듀서 EVIDENCE는 내지 않고,
  나머지 넷은 `(진단 줄 없음 — 오류 · 상태 줄이 없거나 password · jaas가 든 줄뿐)`을 싣는다(Kafka 4.3.1 콘솔 프로듀서는 기본 비동기 send라 인증 · ACL 실패에도 rc 0이다 — 프로듀서
  EVIDENCE가 없으면 원인이 "마커 미수신"에 가려진다). 레코드 값은 찍지 않는다.
  미할당 · 컨슈머 조기 종료 · 지연 측정 불가는 사유를 `RESULT: FAIL` 줄 안에 싣는다. 컨슈머 · describe · 프로듀서의 출력은 전부 `/tmp` 파일로 가고 Job stdout에 섞이지 않는다
  (검증 기록 T056 — 모의 11경로 3–5줄).
- **data-assert 결과 파일 부재 fallback(T057 수정 라운드 r1)** = Dragonfly 7 id 전부 FAIL(`RESULT: FAIL <id> initContainer 결과 파일(/work/dragonfly.result)이 없다` · id 수 불변 · 출력 순서 그대로 · 줄 수 pg 6 + 7 + `SUMMARY` 1 = **14** · exit 1 — 이전에는 `acl-list` · `noperm` 2줄뿐이었다).
- 값 자체(비밀번호·토큰·URL의 자격 부분)는 절대 출력하지 않는다. **data-assert initContainer(T057)**: 출력에 실리는 redis-cli 응답은 전부 같은 가림을 거친다 —
  `redis://…`(공백 전까지) → `redis://<redacted>` · `#` 뒤 hex **8자 이상** → `#<redacted>`(`sed -E` 한 번) — 응답 조각은 그 첫 줄 100자다. 옛 규칙 "`#` 뒤 hex 16자 이상"은
  Dragonfly `ACL LIST`가 해시를 **15자로 줄여** 보여 주므로(gitops `platform/dragonfly/README.md` §4) 한 번도 매치되지 않아 해시 앞 15자가 로그에 남았다(T057 정정 · 검증 기록 T057의 변이 m2).
  redis-cli는 `--no-auth-warning`으로 부른다 — 없으면 `-u` URL에 비밀번호가 있을 때 stderr 경고 줄이 응답 앞에 붙는다(정확 일치 판정 `OK` · `probe`가 깨지고 증거 첫 줄이 경고가 된다).

읽는 법(quickstart §US3 그대로):

```bash
kubectl -n jt-dev logs job/data-assert
kubectl -n jt-dev logs job/kafka-assert
kubectl -n jt-dev logs job/authz-assert
kubectl -n jt-dev logs job/data-assert | grep -A5 'ACL LIST'   # VD-4 증거
kubectl -n jt-dev logs job/data-assert | grep 'NOPERM'          # 읽기 전용 ACL 증거
```

### 검사 id

| Job | 검사 id | 무엇을 단언하나 | 근거 |
|---|---|---|---|
| `data-assert` | `pg-cross-db-denied` | dev app role로 prod DB·공유 DB(`authentik`·`openfga`)에 **실접속** → 전부 `permission denied for database` | quickstart §US3 ①② · data-model §7 |
| | `catalog-connect-false` | 로그인 없이 카탈로그로 `has_database_privilege(<prod app role>, {dev DB, 공유 DB}, 'CONNECT')` = 전부 false | quickstart §US3 ③ |
| | `revoke-public` | 4개 DB 모두 PUBLIC의 CONNECT가 회수됨(`datacl`이 NULL이면 기본 권한이 살아 있다는 뜻이라 FAIL) | quickstart §US3 ④ · data-model :113 |
| | `ssl-verify-full` | `sslmode=verify-full` URL로 붙은 세션의 `pg_stat_ssl`(자기 backend)이 `ssl=t` | quickstart §US3 ④ · pod-template §DB 연결 |
| | `role-attrs` | 로그인 없이 카탈로그(`pg_roles`)로 app 2(`identity_admin_app`·`dev_identity_admin_app`) `rolbypassrls=f`·`rolsuper=f`, pod owner 2(`identity_admin_owner`·`dev_identity_admin_owner`) `rolbypassrls=t`·`rolsuper=f` — 넷 다 `rolcreatedb=f`·`rolcreaterole=f`·`rolcanlogin=t`(DatabaseRole 선언이 PG에 실제로 적용됐는지). role 이름은 ConfigMap `PROD_APP_ROLE`·`DEV_APP_ROLE`·`PROD_OWNER_ROLE`·`DEV_OWNER_ROLE` | tasks.md T054 문면 · data-model §7 · 모노레포 build-notes 「T050 · T051」(T054 몫) |
| | `app-session-timeouts` | `pg_roles.rolconfig`(DB 무관 role 설정)에 app 2 모두 `statement_timeout=15s` **그리고** `idle_in_transaction_session_timeout=30s` — 적용 주체는 gitops `platform/cnpg-databases`의 PostSync Job(app role 자신의 `ALTER ROLE CURRENT_USER SET`). **role 수준 기본값만 본다** — DB별 덮어쓰기(`ALTER ROLE … IN DATABASE … SET` = `pg_db_role_setting.setdatabase ≠ 0`, app role 자신도 낼 수 있다)는 보지 않는다(실효 값이 달라도 PASS — security r2 K13 · 확장은 후속) | data-model §7 app role 행(2026-10-14) · 같은 build-notes |
| | `noauth` | 자격 없이 `PING`(ConfigMap `DRAGONFLY_HOST`·`DRAGONFLY_PORT` = Service `dragonfly-dev`) → `NOAUTH`(aclfile `USER default OFF -@all`). `PONG`이면 FAIL "aclfile 미적재(default nopass) 의심" — 파싱 오류 1건이면 Dragonfly가 무인증으로 기동한다(gitops `platform/dragonfly/README.md` §1) | T057 · denylist.md · 모노레포 build-notes 「T050 · T051」 T057 몫 |
| | `acl-list` | Dragonfly `ACL LIST`(identity-admin — `DRAGONFLY_URL`)에 dev 검사 계정(`sample-pod`) 행이 있고 읽기 전용 패턴 `%R~revoked:*`를 포함. 앞에 `EVIDENCE:` 머리 1줄 + 가린 행 ≤ 6줄 | quickstart §US3 VD-4 · T057 · denylist.md |
| | `writer-set` | identity-admin으로 `SET revoked:sub:assert-probe probe EX 120` → 정확히 `OK`(쓰는 쪽 `~revoked:*`) | T057 · denylist.md §ACL 표 · §검증 T051 |
| | `reader-get` | `sample-pod`로 같은 키 `GET` → 정확히 `probe`(`%R~` 읽기 허용 · nil = 빈 응답이면 FAIL) | T057 · denylist.md |
| | `reader-set-denied` | `sample-pod`로 같은 키 `SET … x` → `NOPERM`(`OK`면 FAIL "%R~ 패턴이 쓰기를 막지 않음") | T057 · denylist.md |
| | `reader-cross-denied` | `sample-pod`로 `SET identity-admin:assert-probe 1 EX 120` → `NOPERM`(자기 접두 `sample-pod:*` 밖). `EX 120`: ACL이 깨져 SET이 성공하는 FAIL 경로에서도 키가 120 s 뒤 사라진다 — 정상 경로(NOPERM)에서는 키가 생기지 않는다(정리 DEL 대상 아님 · 수정 라운드 r1) | T057 · denylist.md |
| | `noperm` | 그 계정으로 `DEL revoked:sub:assert-probe` → `NOPERM`(키 패턴과 명령 카테고리는 짝지어지지 않는다 — `%R~`로만 막힌다). 뒤에 판정이 아닌 `NOTE: cleanup DEL revoked:sub:assert-probe -> <n>` 1줄(identity-admin DEL — 실패해도 `EX 120`) | quickstart §US3 · T057 |
| `kafka-assert` | `roundtrip` | dev 토픽에 produce → 같은 토픽에서 마커 consume 성공(경과 시간 함께 출력). **T056**: 컨슈머를 먼저 띄워 파티션 할당(describe의 CONSUMER-ID 행)을 확인한 뒤 produce하고, PASS 근거에 `latency=<n>ms`를 **정확히 1개** 찍는다 — **latency = 마커 수신 시각 − 레코드 CreateTime(ms · 둘 다 이 파드의 시계)** · spec US3 AC3의 **5 s 기준은 이 값**이다(모노레포 `kafka.tests.ps1` job-k-3 ≤ 5000). 같은 줄의 벽시계 `produce→consume <n>s`(produce 시작 ~ 마커 수신 · 프로듀서 JVM 기동 포함)는 Job 자체 상한 `KAFKA_ROUNDTRIP_DEADLINE_S` 판정용이다. 실패 줄에는 토큰이 없다. **리뷰 r1 O5**: 할당 확인은 **자기 멤버**(실행마다 고유 `client.id` = `kafka-assert-<pid>-<epoch>`)의 행만 본다(직전 실행의 옛 멤버 행을 준비로 오인하지 않는다) · 마커 미수신 · produce 실패 경로는 `EVIDENCE: producer 마지막 오류:`를 함께 낸다(§로그 계약). **리뷰 r2 K5 · O11**: `KAFKA_PASSWORD`가 base64url 형식이 아니면 JVM을 띄우기 전에 이 id와 `cross-env-denied`를 함께 FAIL로 닫는다(값 미출력) · 진단 줄은 전부 `safe_tail` 규칙(§로그 계약) — produce rc≠0의 RESULT 줄은 스택 꼬리(`\t... N more`)가 아니라 원인 줄을 싣는다 | quickstart §US3 · T051 인계(모노레포 build-notes 「T050 · T051」 토큰 형식) |
| | `cross-env-denied` | 같은 dev 자격으로 **prod 토픽** write 시도 → 인가 거부(`TopicAuthorizationException`). 비밀번호 형식이 base64url이 아니면 roundtrip과 같은 사유로 FAIL(리뷰 r2 K5) · 인가 거부가 아닌 실패의 꼬리는 `safe_tail`(리뷰 r2 K5) | quickstart §US3 · T056 ACL |
| `authz-assert` | `check-allowed` | 튜플이 있는 테넌트에 대한 `check` → `allowed=true` | quickstart §US4 5 |
| | `cross-tenant-false` | 튜플이 없는 다른 테넌트 object → `allowed=true`가 아님 | quickstart §US3·§US4 |

**판정은 fail-closed다.** 필요한 환경변수·CA 파일이 없거나 호출이 실패하면 해당 검사는 조용히 넘어가지 않고
`RESULT: FAIL`이 되고 종료 코드가 1이 된다.

## 자격 매핑 (ExternalSecret `assert-env`, store `vault-dev`)

| Vault 경로(`remoteRef.key`) | property | env 이름 | 쓰는 Job |
|---|---|---|---|
| `dev/db/dev_identity_admin/app` | `url` | `DATABASE_URL` | data-assert |
| `dev/db/dev_identity_admin/app` | `username` | `PGUSER` | data-assert |
| `dev/db/dev_identity_admin/app` | `password` | `PGPASSWORD` | data-assert |
| `dev/kafka/identity-admin` | `password` | `KAFKA_PASSWORD` | kafka-assert |
| `dev/dragonfly/identity-admin` | `url` | `DRAGONFLY_URL` | data-assert(`acl-list` · `writer-set` · 정리 DEL) |
| `dev/dragonfly/sample-pod` | `url` | `DRAGONFLY_SAMPLE_URL` | data-assert(`reader-get` · `reader-set-denied` · `reader-cross-denied` · `noperm`) |
| `dev/openfga/store_id` | `store_id` | `OPENFGA_STORE_ID` | authz-assert |
| `dev/openfga/preshared` | `key` | `OPENFGA_TOKEN` | authz-assert |

- 전부 `dev/` 접두다(`platform/`·`prod/` 경로 0개). `dataFrom`·항목별 `sourceRef`는 쓰지 않는다.
- 세 Job이 **같은 Secret 하나**를 `envFrom`한다(설계 §6.3). Job마다 ES를 쪼개면 Job 사이 자격 격리가 한 겹
  늘어난다(예: kafka-assert가 DB 비밀번호를 갖지 않음) — 채택 여부는 아래 §후속 결정.
- 비밀이 아닌 값(호스트·DB/토픽 이름·합성 식별자)은 ConfigMap `assert-config`에 있다. **T057**: 비인증 `PING`(`noauth`)은 자격 없이 붙어야 하므로 ConfigMap `DRAGONFLY_HOST`
  (`dragonfly-dev.data.svc` — gitops `platform/dragonfly/services.yaml`) · `DRAGONFLY_PORT`(`6379`)를 쓴다(자격이 든 `DRAGONFLY_URL`을 셸에서 파싱하지 않는다). Dragonfly 7검사는 이 둘과
  `DRAGONFLY_URL` · `DRAGONFLY_SAMPLE_URL` · `REVOKED_PROBE_KEY` · `DRAGONFLY_ACL_USER` · `DRAGONFLY_ACL_PATTERN` 중 하나라도 비면(또는 없으면) **7개 id 전부** `RESULT: FAIL <id> 필수 값 없음(…): <변수 이름>`
  (값 미출력 · id 수 불변 · redis-cli 호출 0)이다.

## 이미지

| Job | 이미지(태그 + digest 병기) | 고른 이유 |
|---|---|---|
| data-assert(init) | `redis:8.8.2-alpine` | `redis-cli`(Dragonfly는 Redis 프로토콜 호환) |
| data-assert | `postgres:18.6-alpine` | `psql`(서버는 CNPG major 18) |
| kafka-assert | `apache/kafka:4.3.1` | 브로커와 같은 버전의 콘솔 도구. `edenhill/kcat:1.7.1`은 Docker Hub 매니페스트가 **amd64 단일**이라 arm64 노드에서 못 쓴다(registry v2 API 실측 2026-09-08) |
| authz-assert | `curlimages/curl:8.22.0` | OpenFGA HTTP API 호출 2건뿐 |

- digest는 2026-09-08에 Docker Hub registry v2 API로 조회한 **manifest index** sha256이며 네 개 모두
  `linux/arm64` 항목을 포함한다(노드 2대 = Ampere A1).
- 세 Job 모두 restricted PSA에 맞춘 securityContext(`runAsNonRoot`·`allowPrivilegeEscalation: false`·
  `capabilities.drop [ALL]`·`seccompProfile RuntimeDefault`·`readOnlyRootFilesystem: true` + `/tmp` emptyDir),
  `automountServiceAccountToken: false`, requests 명시(LimitRange `default.memory` 승계 방지), memory limit만(CPU limit 없음).
- **UID를 숫자(65534)로 못박는 이유**: 네 이미지의 config `User`가 비었거나(root) 이름 형식(`appuser`·`curl_user`)이라
  `runAsNonRoot: true`만 두면 kubelet이 비루트 여부를 판정하지 못해 파드가 기동하지 않는다.

## 왜 지금 Argo CD Application이 없나 (설계 D3-A)

이 디렉터리는 **매니페스트와 로그 계약까지만** T041에서 만든다. `platform/policies/kustomization.yaml`도
이 디렉터리를 참조하지 않는다(별도 kustomization). 이유는 셋이다.

1. **검사 대상이 아직 없다.** pg-main·Kafka·Dragonfly·OpenFGA와 CA 미러 Secret은 US3/US4 산출물이다. 지금
   배포하면 Job이 즉시 실패하고, `cluster.tests.ps1`의 `argo-1`(모든 Application Synced/Healthy)이 US3/US4 내내 FAIL한다.
2. **이름·표가 계약에 없다.** `tests/validate.sh` 7.1의 Application 이름 규약은 `root`·`platform-<component>`·
   `<pod>-<env>`뿐이고, 계약 `contracts/gitops-repo.md` §sync-wave 표에도 이 Application 행이 없다.
   validate를 계약보다 먼저 고치는 것은 우선순위 역전이다(`validate.sh` 머리 주석: "계약을 먼저 고친다").
3. 그래서 지금 고정해 두는 것은 **로그 계약**이다. 대상이 생기는 태스크가 Application만 붙이면 되고,
   `np-2-*` 파서와 tester 절차는 바뀌지 않는다.

그때까지 `cluster.tests.ps1`의 `np-2-data-assert`·`np-2-kafka-assert`·`np-2-authz-assert`는
클러스터에 Job이 없으므로 계속 `SKIP np-2-<job>: until T041 (assert Job jt-dev/<job> … not present)`을 낸다.
그 SKIP은 **매니페스트가 없어서가 아니라 배포되지 않아서**이며, Application이 붙는 순간 PASS 후보가 된다.

### 나중에 Application을 붙일 때의 선행 조건 체크리스트

- [ ] 계약 `contracts/gitops-repo.md` §Application 규약과 **§sync-wave 단일 표에 이 검사 Application 행 추가**
      (이름·destination ns·wave). 값은 계약 표에만 적고 다른 곳에 중복 기재하지 않는다.
- [ ] 그 다음 `tests/validate.sh`의 `WAVE_TABLE`·7.1 이름 규약 갱신(계약 → validate 순서).
- [ ] AppProject **`tests`** 소속으로 만든다(source = gitops 저장소만, destination = `jt-dev`만, cluster 리소스 금지).
- [ ] 선행 산출물 존재 확인: `Cluster pg-main`·`Database`/`DatabaseRole`(dev role 포함) · CA 미러 Secret
      `pg-main-ca`·`jt-kafka-cluster-ca-cert`(ns `jt-dev`) · `KafkaTopic`/`KafkaUser`(dev) · Dragonfly `dragonfly-dev`와
      aclfile 사용자(`identity-admin`·`sample-pod`) · OpenFGA store + authorization model · Vault `dev/*` 경로 값 ·
      `ClusterSecretStore vault-dev`.
- [ ] 재실행 모델 확정(아래 §후속 결정) — Job은 immutable이라 "매니페스트 수정 → sync"만으로는 재실행되지 않는다.
- [ ] 첫 실행 뒤 `cluster.tests.ps1` `np-2-*` 3건이 PASS로 바뀌는지 확인.

## 재실행 모델 (미확정 — 후보만 기록)

Job의 `spec`은 immutable이므로 Argo CD가 같은 이름의 Job을 갱신할 수 없다. 후보는 둘이다.

- **A. Argo Sync hook** — Application의 전체 sync마다 실행(selfHeal 부분 sync · 리소스 선택 Sync · Apply only는 hook을 건너뛴다 — Argo CD v3.5.2 `controller/sync.go:311`). `argocd.argoproj.io/hook: Sync` +
  `hook-delete-policy: BeforeHookCreation`. 장점: sync 1회 = 검사 1회. 단점: 실패가 sync 실패로 이어져
  `argo-1` 판정과 얽힌다.
- **B. 일반 리소스 + 수동 재실행** — `kubectl -n jt-dev delete job <이름>` 후 sync(또는 `Replace=true`).
  장점: Application 헬스와 검사 결과가 분리된다. 단점: 재실행이 수동이다.

현재 매니페스트는 **B에 가깝다**(hook 어노테이션 없음, `ttlSecondsAfterFinished` 7일). 확정은 Application을
만드는 태스크에서 한다.

## 확인이 필요한 값 (계약에 없어 추정한 것)

여기 값들은 **추정이며, 해당 태스크에서 실측·확정**해야 한다. T041은 규칙을 새로 만들지 않는다.

| 값 | 현재 값 | 확인 시점 |
|---|---|---|
| Kafka bootstrap Service DNS | `jt-kafka-kafka-bootstrap.data.svc:9093` (Strimzi 관례 `<cluster>-kafka-bootstrap`) | T055 |
| Kafka 컨슈머 그룹 이름 | `dev-identity-admin-assert` — **해소(T056)**: KafkaUser `dev-identity-admin`의 ACL ⓑ group **prefix** `dev-identity-admin-` · `Read`(data-model §6 ACL 행(2026-10-16 정정 — 모노레포 `9442b14`) — gitops `platform/kafka-topics/kafkausers.yaml`) 안에 든다. ConfigMap 값은 그대로다(prod 그룹 접두 `identity-admin-`과 교차하지 않는다) · ConfigMap 머리 주석의 「T056에서 확인」 문구도 확정 문구로 바꿨다(리뷰 r2 S9 — 주석은 렌더에서 빠진다) | T056 확정 |
| kafka-assert 동시 JVM 메모리(T056) | roundtrip이 컨슈머(`-Xmx256m`)를 띄운 채 describe(`-Xmx128m` — 이 호출만 낮춘다) · 프로듀서(`-Xmx256m`)를 띄워 **JVM 2개가 동시에** 돈다(힙 상한 합 ≤ 512Mi) — limit 640Mi 안이라고 보지만 실측 전이다(`resources` 주석도 이 내용으로 정정 — 리뷰 r1 S6 · O4a) | T059 첫 실행(OOMKilled 0 · `kubectl top`) |
| roundtrip 준비 확인 · 지연 실측(T056) | 할당 확인 상한 60 s(2 s 간격 describe · 자기 멤버 = CLIENT-ID가 이 실행의 `client.id`인 행만) · 선기동 컨슈머 유휴 상한 = `(60 + KAFKA_ROUNDTRIP_DEADLINE_S) × 1000 + KAFKA_CONSUME_TIMEOUT_MS` ms(= 110000 — `KAFKA_CONSUME_TIMEOUT_MS`의 뜻이 "소비 대기"에서 "유휴 여유분"으로 바뀌었다 · ConfigMap의 그 키 위에 같은 뜻의 주석을 달았다 — 리뷰 r2 S9) · `latency=<n>ms`는 모의로만 확인(모의 185–440 ms — r1 · r2 실행 · 가짜 컨슈머의 폴링 잡음 · 고정 시계 123 ms — 검증 기록 T056) | T059 첫 실행(할당 소요 · latency 값 · job-k-3) |
| OpenFGA Service DNS | `openfga.identity.svc:8080` — helm 릴리스 이름에 따라 달라진다 | T082 |
| `roundtrip` 상한 | `KAFKA_ROUNDTRIP_DEADLINE_S=30`(JVM 기동 포함 벽시계). quickstart의 "≤ 5초"는 메시지 경로 기준이라 값이 다르다 | 첫 실행 시 실측 후 조정 |
| authz 검사 데이터 | 합성 식별자(`ASSERT_*`)를 Job이 직접 쓰고 지운다 | 아래 §후속 결정 |

## 후속 결정 (Application을 만드는 태스크에서)

1. **ES 분할**: `assert-env` 하나 → Job별 3개(`assert-data-env`·`assert-kafka-env`·`assert-authz-env`)로 나누면
   Job 사이 자격 격리가 한 겹 늘어난다. 현재는 설계 §6.3대로 하나다.
2. **authz 검사 데이터**: 지금은 합성 튜플을 Job이 쓰고 지운다(dev store만). `seed_tenant`가 만든 고정 테넌트
   UUID를 단언 대상으로 삼는 안이 더 강한 검증이지만, 그 UUID는 US4 산출물이라 지금 매니페스트에 넣지 않았다.
3. **`ttlSecondsAfterFinished`**: 현재 7일. 설계 §6.3은 "미지정(로그 보존)", T041 슬라이스 문면은 "명시"였다 —
   재실행 모델과 함께 확정한다.

## 네트워크

이 Job이 쓰는 경로는 **이미 계약 매트릭스에 있는 행**뿐이다: `jt-dev → data 5432·9093·6379`(:82),
`jt-dev → identity 8080`(:83), `allow-dns`. **새 허용 규칙을 추가하지 않았다.** 새 목적지가 필요해지면
`contracts/network-policy.md`를 먼저 고친다.

ESO가 `assert-env` Secret을 만드는 경로는 `external-secrets → vault 8200`(:91)이며 `jt-dev` 정책과 무관하다.

## 검증 기록 (T041, 저장소 로컬)

- `kustomize build platform/policies/tests` exit 0 — 객체 5개(ConfigMap 1 · ExternalSecret 1 · Job 3).
- `kustomize build platform/policies` 여전히 **123객체**, 렌더에 `assert` 문자열 0건(정책과 섞이지 않음).
- `kubeconform -strict -ignore-missing-schemas`: Valid 4 · Invalid 0 · Skipped 1(ExternalSecret = CRD 스키마).
- `bash tests/validate.sh`: **PASS 18 · FAIL 0 · WARN 4**(WARN 4는 기존 `platform/system-upgrade` k3s-upgrade 이미지
  4줄 그대로 — 이 디렉터리의 image 4줄은 전부 digest 병기라 새 WARN 없음). 검사 3(ExternalSecret ①②③④⑦)·
  3.5(⑤⑥)·4b·8(gitleaks) 통과.
- 셸 스크립트 4개(init/main/kafka/authz): `sh -n`·`bash -n` 통과, `shellcheck -S warning` 지적 0건,
  스텁으로 정상 경로(6·2·2 PASS)와 음성 대조(교차 DB 접속 성공 / `verify-full` 없음 / PUBLIC CONNECT 잔존 /
  다른 테넌트 allowed=true / 환경변수 결손)에서 FAIL·종료 코드 1을 확인했다.
- **클러스터에서는 아직 한 번도 실행되지 않았다**(Application 없음). 첫 실행은 대상이 생기는 태스크에서 한다.

## 검증 기록 (T054 — data-assert에 `role-attrs` · `app-session-timeouts` 추가, 저장소 로컬)

- `kustomize build platform/policies/tests` exit 0 — 객체 5개 그대로(ConfigMap 1 · ExternalSecret 1 · Job 3). ConfigMap에 `DEV_APP_ROLE` ·
  `PROD_OWNER_ROLE` · `DEV_OWNER_ROLE` 3키 추가(비밀 아님 — role 이름).
- 렌더에서 뽑은 pg-assert 스크립트: `sh -n` · `dash -n` · `bash --posix -n` 통과. dash + 모의 psql로 6경우 — 전부 PASS(8/0 · exit 0 · 16줄) /
  owner bypassrls=f · app role 없음 · rolconfig에 30s 없음 · pg_roles 조회 실패(각 해당 id FAIL · 7/1 · exit 1) / ConfigMap 키 결손(pg 6 id 전부
  FAIL "필수 값 없음" · 2/6 · exit 1). 출력에 비밀번호 0건.
- 모노레포 하네스 `tests/platform/data.tests.ps1`의 **판정 함수 `Test-JobLog` 자체**(AST로 읽어 실행 — 파일 수정 없음)를 위 로그의 `--tail=50`에 적용:
  전부 PASS 경우만 ok, 나머지 5경우 not ok(해당 id FAIL · SUMMARY fail≠0). 같은 모의로 T054 **전**(main `a769359`) 스크립트는
  "missing RESULT line for role-attrs … app-session-timeouts"로 not ok — 빨강 → 초록 확인.
- 이 Job은 여전히 **배포되지 않는다**(Application 없음 — T057/T059). 하네스 `job-1`·`job-2`는 그때까지 FAIL이 정상이다.
- **배포한 뒤**: pod DB(`identity_admin` · `dev_identity_admin`)의 PUBLIC CONNECT는 gitops `platform/cnpg-databases/`의 PostSync Job ⓪(`pod-db-connect` — 컨트롤러 결정 C1
  2026-10-14)이 `REVOKE CONNECT … FROM PUBLIC; GRANT CONNECT … TO <db>_app, <db>_owner;`로 **먼저 닫아 두므로**, `pg-cross-db-denied` · `catalog-connect-false` · `revoke-public`은
  T072/T075(migrate Job 첫 단계 — 같은 SQL을 다시 내는 이중 멱등)를 기다리지 않고 **PASS 후보**다(이전 서술 "pod DB REVOKE 전까지 FAIL"은 철회). 공유 DB 2의 CONNECT 제한은
  같은 Job ①. 남는 선행 산출물은 CA 미러 T056(`DATABASE_URL`의 `verify-full` · 접속 자체) · Dragonfly T057(`acl-list` · `noperm`)이다(gitops `platform/cnpg-databases/README.md` §6 T059).
  ⚠ 그 PostSync Job이 FAIL이면(Argo operation Failed — Application은 Synced/Healthy로 남는다) pod DB가 열린 채라 세 id가 FAIL하고 Job이 exit 1이라 `job-1` · `job-2`도 FAIL한다
  → 먼저 gitops README §3 VD-4의 네 판정(operationState.phase · hookPhase · Job succeeded · 로그 SUMMARY)으로 PostSync 결과를 확인한다.

## 검증 기록 (T056 — kafka-assert roundtrip에 `latency=<n>ms` 토큰, 저장소 로컬 · 2026-10-16)

바꾼 것은 `job-kafka-assert.yaml`의 **roundtrip 절**과 `resources` **주석**이다(필수 값 확인 · client.properties · cross-env-denied 절 · `resources` 값 불변 — 주석은 렌더에서 빠진다 ·
수정 라운드 r2가 필수 값 확인 뒤의 형식 검사와 진단 줄 규칙을 더했다 — 아래).
순서 = 컨슈머 선기동(수신 줄마다 수신 시각 ms 태깅 · 실행마다 고유 `client.id`) → describe로 **자기 멤버**의 파티션 할당 확인(2 s 간격 · 상한 60 s) → produce(옵션 그대로) →
마커 줄 폴링(1 s · 상한 `KAFKA_ROUNDTRIP_DEADLINE_S`) → 컨슈머 kill + wait → (마커 미수신 · produce 실패면 `EVIDENCE:` ≤ 2줄) → RESULT 1줄.
PASS 줄 = `RESULT: PASS roundtrip <토픽> produce→consume <n>s latency=<n>ms (상한 <d>s, JVM 기동 포함)` — 토큰 정확히 1개(앞뒤 공백) · 실패 줄에는 토큰이 없다.
**수정 라운드 r1(리뷰 r1 O5 · S6/O4a — 2026-10-16)**: ⓐ 프로듀서 오류 `EVIDENCE: producer 마지막 오류: …`(마커 미수신 · produce 실패 경로) ⓑ 컨슈머 `--command-property client.id=…` + awk의
CLIENT-ID 대조(자기 멤버의 할당 행만 준비로 본다) ⓒ `resources` 주석 정정. 그 밖의 로직 · RESULT 형식 · `latency=` 토큰 규칙은 그대로다.
**수정 라운드 r2(리뷰 r2 K5 · O11 · S9 — 2026-10-16)**: ⓐ 필수 값 확인 직후 · client.properties를 쓰기 전에 `KAFKA_PASSWORD` 형식 검사(base64url 밖의 문자 → 두 검사 FAIL + `SUMMARY` +
exit 1 · 값 · 길이 · 조각 출력 0 · JVM 기동 0) ⓑ 진단 줄 헬퍼 `safe_tail`(consumer_err · groups_note · 프로듀서 EVIDENCE · produce rc≠0 RESULT 줄 · cross-env 실패 꼬리가 같은 규칙 —
§로그 계약) ⓒ ConfigMap 주석 2곳(값 · 키 불변). RESULT 형식 · `latency=` 토큰 규칙 · 그 밖의 로직은 그대로다.

- `kustomize build platform/policies/tests` exit 0 — 객체 5개 그대로(ConfigMap 1 · ExternalSecret 1 · Job 3) · ConfigMap 값 불변(`KAFKA_GROUP` `dev-identity-admin-assert`는 KafkaUser
  `dev-identity-admin`의 group prefix `dev-identity-admin-` 안 — gitops `platform/kafka-topics/kafkausers.yaml`) · 렌더의 ConfigMap 문서는 r2 전 렌더와 바이트 동일(주석만 바뀌었다).
  렌더에서 뽑은 kafka-assert 스크립트(**225줄** — 측정
  `kustomize build platform/policies/tests | yq 'select(.kind=="Job" and .metadata.name=="kafka-assert") | .spec.template.spec.containers[0].args[0]' | wc -l` · yq는 끝에 빈 줄 1개를
  더하므로 YAML 블록 :64–287의 224줄보다 1 많다 · 수정 라운드 r1 205줄 · 그 전 188줄): `bash -n` 통과 (shellcheck는 이 작업 환경에 없어 돌리지 않았다).
- **이미지 사실(실행 없이 — Docker Hub registry v2 API + 레이어 tar 목록)**: `apache/kafka:4.3.1@sha256:77e3df90…`(manifest index) → arm64 매니페스트 `sha256:c2b5172a…` → config `sha256:33241f6e…`
  history 첫 줄 `ADD alpine-minirootfs-3.23.4-aarch64.tar.gz` — **Debian이 아니라 Alpine 3.23.4**(Kafka 4.3.1 `docker/jvm/Dockerfile` `FROM eclipse-temurin:21-jre-alpine`)다.
  그 위 eclipse-temurin 레이어(`sha256:bf450a43…` — `apk add … coreutils …`)가 `bin/date -> coreutils`를 놓아 첫 레이어(`sha256:d17f077a…`)의 `bin/date -> /bin/busybox`를 가린다 →
  **`date +%s%3N`은 GNU coreutils**(밀리초 지원)이고 폴백(`date +%s%N | cut -c1-13`)은 필요 없다. 같은 레이어가 `cut` · `tail` · `wc` · `sleep` · `mkfifo`도 coreutils로 덮는다 · `awk` · `grep`은 BusyBox
  (`usr/bin/awk -> /bin/busybox` — 스크립트의 awk는 머리 행 열 찾기 · 문자열 비교만 쓴다) · bash는 Kafka 레이어의 `apk add bash`. 런타임 실측은 T059 첫 실행.
- **도구 사실(Apache Kafka 4.3.1 소스 `tools/src/main/java/org/apache/kafka/tools/…`)**: 옛 옵션 `--consumer.config` · `--property`(컨슈머)와 `--producer.config` · `--producer-property`(프로듀서)는
  4.2부터 폐기 예고이고 안내를 **stdout**에 찍는다(`consumer/ConsoleConsumerOptions.java` :216–223 · :379–382 · `ConsoleProducer.java` :330 · :335) — 그래서 선기동 컨슈머는 새 이름
  `--command-config` · `--formatter-property` · `--command-property`(:99–102 — `--command-config` 파일 값보다 우선 :109 · :281–282)를 쓴다(수신 기록에 안내 줄이 섞이지 않게). produce 두 곳은 지시대로 옛 옵션 그대로다(출력은 `/tmp/*.log`로만 간다 · cross-env의 판정 grep에 걸리지 않는다).
  `client.id`를 주지 않으면 실행마다 같은 `console-consumer`다(:285–287) → describe 멤버 행의 CLIENT-ID = 그 멤버의 client.id(`group/ConsumerGroupCommand.java` :841–855) · 할당 없는 커밋 행은
  CONSUMER-ID · HOST · CLIENT-ID가 `-`(:859–868) — 그래서 고유 `client.id`로 자기 멤버의 행만 고른다. 콘솔 프로듀서는 기본이 비동기 send(`ConsoleProducer.java` :107–111 — 실패는
  ErrorLoggingCallback 로그뿐)이고 끝에 `Exit.exit(0)`(:79)이라 인증 · ACL · 타임아웃 실패에도 rc 0이다 — 그래서 `/tmp/produce.log`의 오류 줄을 EVIDENCE로 싣는다.
  `print.timestamp=true` 줄 = `CreateTime:<ms>` + 탭 + 값(`consumer/DefaultMessageFormatter.java` :131–138 · :186–188) · 그룹이 있으면 `auto.offset.reset` 기본 latest(`ConsoleConsumerOptions.java` :328–331) ·
  유휴 타이머는 첫 `receive()`(그룹 가입 포함)부터 흐른다(`ConsoleConsumer.java` :211–217 — 그래서 선기동 컨슈머의 `--timeout-ms`를 `(60 + 상한) × 1000 + KAFKA_CONSUME_TIMEOUT_MS`로 둔다) ·
  SIGTERM은 종료 훅이 컨슈머를 닫고 끝낸다(:91–103) · describe 머리 행 9열(`--verbose`면 LEADER-EPOCH가 끼어 10열 — `group/ConsumerGroupCommand.java` :340–342) · 상태 문구는 stderr(:306 · :312).
- **형식 검사 · `safe_tail` 이식성(r2 — 로컬 실행)**: 형식 검사 패턴은 범위(`A-Z`) 대신 문자를 나열한다. bash는 두 문자가 모두 ASCII일 때만 범위를 코드값으로 비교하고(`globasciiranges` — 이 작업 환경
  bash 5.2.21과 아래 컨테이너 bash 5.3.9 모두 기본 on) 비ASCII 문자는 로캘 정렬(wcscoll)로 비교한다 — 로컬 msys bash에서 범위 패턴 `*[!A-Za-z0-9_-]*`는 UTF-8 로캘(en_US · ko_KR)일 때 전각 A(U+FF21) ·
  Kelvin 기호(U+212A)를 통과시켰고, 나열 패턴은 C · en_US.UTF-8 · ko_KR.UTF-8 세 로캘 모두 입력 28종(따옴표 · 역슬래시 · 공백 · 탭 · 끝 개행 · `=` · `+` · `/` · 비ASCII 문자 등) 중 base64url 값 3개만 통과시켰다.
  musl(로컬에 캐시된 `postgres:17-alpine` = Alpine 3.24.1 · bash 5.3.9 · BusyBox grep — `--network none` 일회용 컨테이너)에서는 두 패턴 모두 전각 A · Kelvin 기호 · `é`를 거부했다(Kafka 이미지의
  musl에서는 두 패턴의 결과가 같다). `safe_tail`(렌더 스크립트에서 그대로 뗀 정의)은 입력 12종(jaasfrag stderr · pe-jaas · produce-exit · describe 4종 · 대문자 미끼 + 240자 오류 줄 · 미끼뿐 ·
  오류 없음 · 빈 파일 · 없는 파일)에서 GNU grep(로컬)과 BusyBox grep(컨테이너)의 출력이 바이트 동일했다 — 조각 · 비밀번호 · 미끼 0 · 스택 프레임 0 · 240자 줄은 `…` + 뒤 139자(= 140자).
- **모의 실행**(가짜 `kafka-console-consumer.sh` · `kafka-console-producer.sh` · `kafka-consumer-groups.sh` + `date` 래퍼 — 렌더에서 뽑은 스크립트의 `/opt/kafka/bin/` · `/tmp/` 경로만 바꿔 bash로 그대로 실행 ·
  ConfigMap 값 그대로(`KAFKA_CONSUME_TIMEOUT_MS=20000` · `KAFKA_ROUNDTRIP_DEADLINE_S=30`) · stdout+stderr 합침 = `kubectl logs` 모양 · r2는 r1 가짜 도구 사본에 jaasfrag · pe-jaas를 더해 열한 경로를 다시 돌렸다):

  | 경로 | 출력 줄 | roundtrip RESULT(+ EVIDENCE) | `latency=` 토큰 | SUMMARY · exit | 소요 |
  |---|---|---|---|---|---|
  | 마커 수신 | 3 | PASS `… produce→consume 1s latency=251ms (상한 30s, JVM 기동 포함)`(값은 가짜 컨슈머의 0.1 s 폴링 잡음) | 1 | pass=2 fail=0 · 0 | 7 s |
  | 마커 수신(고정 시계 — `date +%s%3N` = T, CreateTime = T − 123) | 3 | PASS `… produce→consume 0s latency=123ms …` — 산술 정확 | 1 | pass=2 fail=0 · 0 | 7 s |
  | 미할당(describe = 커밋만 있는 `-` 행 + "has no active members") | 3 | FAIL `consumer not assigned within 60s: Consumer group 'dev-identity-admin-assert' has no active members.` | 0 | pass=1 fail=1 · 1 | 61 s(describe 23회) |
  | 마커 미수신(컨슈머가 레코드를 내지 않음 · 프로듀서 오류 없음) | 4 | `EVIDENCE: consumer 수신 0줄 · stderr: (진단 줄 없음 — 오류 · 상태 줄이 없거나 password · jaas가 든 줄뿐)`(r2 — 오류 · 상태 줄이 없는 stderr의 마지막 줄은 더 싣지 않는다) + FAIL `…에서 마커를 30s 안에 받지 못함(31s 경과)` — 프로듀서 오류 줄이 없어 producer EVIDENCE는 나오지 않는다 | 0 | pass=1 fail=1 · 1 | 36 s |
  | 컨슈머 조기 종료(SCRAM 인증 실패) | 3 | FAIL `consumer exited before assignment: …invalid credentials with SASL mechanism SCRAM-SHA-512 (…NetworkClient)` — 60 s를 기다리지 않는다 | 0 | pass=1 fail=1 · 1 | 5 s |
  | **produce 인가 실패 · rc 0**(r1 — 가짜 프로듀서가 `TopicAuthorizationException`을 로그에만 남기고 rc 0 · 그 뒤 마지막 ERROR 2줄은 비밀번호 · `jaas` 문자열이 든 미끼) | 5 | `EVIDENCE: consumer 수신 0줄 · stderr: (진단 줄 없음 …)` + `EVIDENCE: producer 마지막 오류: org.apache.kafka.common.errors.TopicAuthorizationException: Not authorized to access topics: [dev.identity-admin.session.revoked]` + FAIL `…마커를 30s 안에 받지 못함(30s 경과)` — 미끼 줄 0 · 비밀번호 0 | 0 | pass=1 fail=1 · 1 | 35 s |
  | **produce 실패 rc 1**(r1 — 프로듀서 생성 예외 · 출력이 스택 꼬리로 끝난다) | 4 | `EVIDENCE: producer 마지막 오류: Caused by: org.apache.kafka.common.config.ConfigException: …` + FAIL `produce 실패(rc=1): Caused by: org.apache.kafka.common.config.ConfigException: Invalid value MOCK for configuration ssl.truststore.type`(**r2** — r1의 RESULT 줄은 스택 꼬리 `\t... 5 more`였다) | 0 | pass=1 fail=1 · 1 | 7 s |
  | **옛 멤버 → 자기 멤버**(r1 stale-member — describe 3회는 CLIENT-ID가 다른 옛 멤버 `kafka-assert-1-1760600000`의 할당 행 + "is rebalancing" · 6 s 뒤 자기 멤버 할당 · 할당 전 레코드는 latest라 받지 않는다) | 3 | PASS `… produce→consume 1s latency=347ms …` — 옛 행 3회를 준비로 보지 않고 자기 행이 보인 뒤 produce(가짜 프로듀서 기록 `assigned=yes`) | 1 | pass=2 fail=0 · 0 | 13 s(describe 4회) |
  | 옛 멤버만(r1 — 끝까지 옛 행) | 3 | FAIL `consumer not assigned within 60s: Warning: Consumer group 'dev-identity-admin-assert' is rebalancing.` | 0 | pass=1 fail=1 · 1 | 61 s(describe 23회) |
  | **비밀번호에 따옴표**(**r2 신규 jaasfrag** — 값 = 가운데에 `"`가 든 가짜 비밀번호(보안 리뷰 r2 재현 값) · 가짜 컨슈머 · describe · 프로듀서는 실행되면 JAAS 파싱 오류 문구에 따옴표 뒤 조각을 싣는다 — 보안 리뷰 r2 K5 모양) | 3 | FAIL `KAFKA_PASSWORD 형식이 base64url이 아니다(값 미출력 — 시드 블록 밖 kv 쓰기 의심 · JAAS 문자열을 안전하게 만들 수 없다)` · cross-env-denied도 같은 FAIL — 비밀번호 전체 · 따옴표 앞 · 뒤 조각 0 · JVM 기동 0(컨슈머 · describe · 프로듀서 호출 0) · `/tmp`에는 `logs/`만(client.properties를 만들지 않았다) | 0 | pass=0 fail=2 · 1 | 0 s |
  | **produce 실패 rc 1 · JAAS 미끼**(**r2 신규 pe-jaas** — 운영 리뷰 r2 O11 모양: Caused-by 줄에 `JAAS`와 비밀번호가 든 미끼 · 마지막 줄 TAB 스택 꼬리) | 4 | `EVIDENCE: producer 마지막 오류: org.apache.kafka.common.KafkaException: Failed to construct kafka producer` + FAIL `produce 실패(rc=1): org.apache.kafka.common.KafkaException: Failed to construct kafka producer` — 미끼 0 · 비밀번호 0 · TAB 0 | 0 | pass=1 fail=1 · 1 | 6 s |

  열한 경로 모두 Job stdout에 계약 밖 줄 0(셸의 "Terminated" 류 없음) · TAB 0 · 비밀번호 문자열 0건 · 미끼 줄 0건 · client.properties 없음 · 남은 컨슈머 프로세스 0. jaasfrag 밖의 열 경로는
  cross-env-denied PASS(가짜 프로듀서의 `TopicAuthorizationException`) · 할당된 경로의 컨슈머는 SIGTERM으로 끝났다 · 선기동 컨슈머 인자 `--timeout-ms 110000` · `client.id=kafka-assert-<pid>-<epoch>` ·
  describe 호출 전부 `KAFKA_HEAP_OPTS=-Xms32m -Xmx128m`.
  **빨강 → 초록 · 음성 대조(r1)**: 같은 stale-member 모의에 수정 라운드 전 스크립트(CLIENT-ID를 보지 않는다)는 첫 describe의 옛 행을 준비로 오인해 할당 전에 produce(`assigned=no`)하고, 할당 뒤 latest라
  마커를 받지 못해 **거짓 FAIL**(`…마커를 30s 안에 받지 못함(30s 경과)`)이다 — 수정본은 위 표대로 PASS. 변이 2종도 잡힌다: awk의 CLIENT-ID 조건(`$li == c`)을 빼면 stale-member 거짓 FAIL이 재발하고,
  `grep -viE 'password|jaas'` 필터를 빼면 produce 인가 실패 경로에서 미끼 줄이 EVIDENCE로 나가 비밀번호가 1회 보인다.
  **빨강 → 초록 · 음성 대조(r2)**: 수정 라운드 r1 스크립트(리뷰 r2 대상)는 jaasfrag에서 `RESULT: FAIL roundtrip consumer exited before assignment: Caused by: java.lang.IllegalArgumentException: Value not
  specified for key '<따옴표 뒤 조각>' in JAAS config`로 **조각 1회**(보안 리뷰 r2 K5 재현 — cross-env 꼬리는 `\t... 5 more`)이고, pe-jaas · produce-exit의 RESULT 줄은 `produce 실패(rc=1): \t... 5 more`
  (운영 리뷰 r2 O11 재현)다 — 수정본은 위 표대로. 변이 4종: 형식 검사만 빼면(jaasfrag) JVM이 뜨지만 `safe_tail`이 JAAS 줄을 걸러 조각 0(두 방어가 각각 막는다) · 형식 검사와 필터를 둘 다 빼면
  조각 2회 · 필터만 빼면 pe-jaas에서 미끼(비밀번호 포함) 2회 · produce 인가 실패에서 비밀번호 1회.
- 모노레포(`d91de0c` 작업 트리 — `Get-LatencyTokens` :452 정규식은 HEAD와 같다) 하네스 `tests/platform/kafka.tests.ps1`의 **판정 코드 자체**(함수 정의 + `ClusterAssert 'job-k-2'` · `'job-k-3'` 본문을 AST로
  읽어 실행 — 파일 수정 0 · `Get-ParsedJobLog`만 모의 로그로 바꿔 끼움 · `--tail=50` 적용): 마커 수신 세 경로(마커 수신 · 고정 시계 · 옛 멤버 → 자기 멤버) = job-k-2 PASS · **job-k-3 PASS**
  (`roundtrip latency 251ms` / `123ms` / `347ms <= 5000ms`) · 실패 여덟 경로(jaasfrag · pe-jaas 포함) = job-k-2 FAIL · job-k-3 FAIL("no PASS evidence to read the latency from"). 줄마다 `Get-LatencyTokens`를 세면
  roundtrip PASS 줄 = 1 · 그 밖의 줄(EVIDENCE 2종 · FAIL · cross-env · SUMMARY) = 0이다(열한 경로 + r2 대조 7종 전부).
  T056 **전**(main `3e03021`) 스크립트는 같은 모의(r1 기록)로 job-k-2 PASS · **job-k-3 FAIL**("roundtrip evidence has no latency=<n>ms token … wall-clock 24s") — 빨강 → 초록 확인
  (옛 흐름의 벽시계 24 s = 프로듀서 기동 + 컨슈머 유휴 대기 20 s — T051 리뷰 F1의 "항상 ≥ 20 s"와 같다).
- 이 Job은 여전히 **배포되지 않는다**(Application 없음 — T059). 하네스 job-k-1 · job-k-2 · job-k-3은 그때까지 FAIL이 정상이고, T059 첫 실행이 할당 소요 · 실제 latency · 동시 JVM 메모리를 처음 잰다
  (위 「확인이 필요한 값」 T056 두 행).

## 검증 기록 (T057 — data-assert Dragonfly 절에 `noauth` · `writer-set` · `reader-get` · `reader-set-denied` · `reader-cross-denied`, 저장소 로컬 · 2026-10-22)

바꾼 것은 `job-data-assert.yaml`의 **dragonfly-assert initContainer 스크립트**와 머리 주석(검사 id 목록 · "8개 판정" → "13개 판정"), `configmap-assert-config.yaml`의 **키 2개**(`DRAGONFLY_HOST` ·
`DRAGONFLY_PORT` + 주석)다. pg-assert 컨테이너 · 병합 절 · Job spec · 두 이미지는 1라운드에서 그대로였다(렌더에서 뽑은 pg-assert 스크립트가 main `3fa4440`과 바이트 동일 — `cmp`) —
**수정 라운드 r1**이 ⑥ `reader-cross-denied` 명령(`EX 120`)과 병합 절(결과 파일 부재 fallback · 주석)을 바꿨다(아래 「수정 라운드 r1」 — pg 검사 절 ①–⑥ · Job spec · 이미지는 여전히 그대로).
순서 = 필수 값 7개 확인(하나라도 비거나 없으면 7개 id 전부 FAIL · `exit 0`) → `noauth`(`-h`/`-p` · 자격 없음) → `acl-list`(`EVIDENCE:` 머리 1 + 가린 행 ≤ 6) → `writer-set` → `reader-get` →
`reader-set-denied` → `reader-cross-denied` → `noperm` → `NOTE: cleanup DEL …` 1줄. redis-cli 호출은 전부 `redis-cli --no-auth-warning -t 5 … 2>&1`이고 판정은 **응답 문자열**로 한다(종료 코드 아님).
출력되는 응답 조각은 전부 가림(§로그 계약) 뒤 첫 줄 100자다. initContainer는 늘 `exit 0`(판정은 FAIL 줄로 남는다 — 기존과 같다).

- `kustomize build platform/policies/tests` exit 0 — 객체 5개 그대로(ConfigMap 1 · ExternalSecret 1 · Job 3) · ConfigMap 키 +2(비밀 아님 — Service 이름 · 포트).
  렌더에서 뽑은 initContainer 스크립트 **92줄**(측정 `kustomize build platform/policies/tests | yq 'select(.kind=="Job" and .metadata.name=="data-assert") | .spec.template.spec.initContainers[0].args[0]' | wc -l` —
  yq가 끝에 빈 줄 1개를 더하므로 YAML 블록 :82–172의 91줄보다 1 많다 · 수정 라운드 r1 전 91줄 · 이전 32줄): `sh -n` · `dash -n` · `bash --posix -n` 통과(shellcheck는 이 작업 환경에 없어 돌리지 않았다).
- **도구 사실**(redis 태그 `8.8.2` `src/redis-cli.c` 판독 — 검사 Job 이미지의 redis-cli): stdout이 터미널이 아니면 raw 출력(:10982–10983) · raw 오류 응답 = 오류 문자열 + 줄바꿈을 **stdout**에(:2032–2035) ·
  nil = 출력 없음(:2029–2031 — `$(…)`에서 빈 문자열) · `-e` 없이는 오류 응답에도 종료 코드 0(:2355–2361) · 연결 실패는 stderr `Could not connect to Redis at <호스트>:<포트>: …` + 종료 1
  (:1724–1735 · :3320–3326 · :3691) · `-u` URL에 비밀번호가 있으면 `--no-auth-warning`이 없을 때
  stderr에 `Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.`(:2731–2732 · :3085–3088) · URI 파싱 오류 문구는 URI를 찍지 않는다(`cli_common.c` — `Invalid URI scheme`).
- **모의 실행**(가짜 `redis-cli` — PATH 앞 디렉터리의 sh 스크립트가 인자 모양(`-u` 사용자 · `-h` · 명령)으로 응답을 고르고 `--no-auth-warning`이 없으면 실제처럼 stderr 경고를 낸다 · 렌더에서 뽑은 스크립트의 `/work/`만
  바꿔 dash로 그대로 실행 · ConfigMap 값은 렌더에서 읽음 · URL은 가짜 비밀번호를 넣은 dev 모양):

  | 경로 | 결과 파일 줄 | RESULT · 보조 줄 | 누출(`redis://` 비가림 · 가짜 비밀번호 · `#` + hex 8자 이상) |
  |---|---|---|---|
  | ⓐ 전부 정상 | **13** | PASS 7(noauth → acl-list → writer-set → reader-get → reader-set-denied → reader-cross-denied → noperm) · `EVIDENCE:` 머리 1 + ACL 행 4(해시 `#<redacted>`) · `NOTE: cleanup DEL revoked:sub:assert-probe -> 1` | 0 · 0 · 0 |
  | ⓑ `noauth`가 `PONG` | 13 | `FAIL noauth 미인증 PING이 통과(PONG) — aclfile 미적재(default nopass) 의심` + PASS 6 | 0 · 0 · 0 |
  | ⓒ `reader-set-denied`가 `OK` | 13 | `FAIL reader-set-denied sample-pod로 SET revoked:sub:assert-probe 가 성공(OK) — %R~ 패턴이 쓰기를 막지 않음` + PASS 6 | 0 · 0 · 0 |
  | ⓓ `DRAGONFLY_HOST=''` | **7** | FAIL 7(`… 필수 값 없음(ExternalSecret assert-env · ConfigMap assert-config): DRAGONFLY_HOST`) · redis-cli 호출 0 | 0 · 0 · 0 |
  | ⓔ `DRAGONFLY_ACL_USER` · `DRAGONFLY_ACL_PATTERN` **unset**(`set -u` 아래) | 7 | FAIL 7(두 이름) · 호출 0 · 셸 중단 없음 | 0 · 0 · 0 |
  | ⓕ Dragonfly 연결 거부 | 10 | FAIL 7(근거 `Could not connect to Redis at dragonfly-dev.data.svc:6379: Connection refused`) · `EVIDENCE:` 머리 1 + 오류 1행 · NOTE 1 | 0 · 0 · 0 |
  | ⓖ 응답에 자격 URL과 64자 해시가 섞임(가림 시험) | 13 | `FAIL noauth … -> ERR mock echo redis://<redacted> #<redacted>` + PASS 6 | 0 · 0 · 0 |

- **실제 셸**: 같은 스크립트 · 같은 가짜 redis-cli를 로컬에 캐시된 `redis:8-alpine`(BusyBox v1.37.0 ash · Alpine 3.23.5 — 검사 Job 이미지 `redis:8.8.2-alpine`과 같은 계열) 일회용 컨테이너(`--network none` ·
  읽기 전용 루트 · uid 65534)에서 ⓐ로 돌려 결과 파일이 dash 결과와 **바이트 동일**(13줄)했다.
- **실제 redis-cli ↔ 실제 RESP 서버**(같은 일회용 컨테이너 안 `redis-server` 8.10.1 — **Redis ACL이지 Dragonfly가 아니다** · 사용자 3(default off · identity-admin · sample-pod)을 `ACL SETUSER`로 만든 뒤 가짜 redis-cli 없이 실행):
  7개 전부 PASS · 12줄(ACL 행 3) · Redis `ACL LIST`의 64자 해시도 `#<redacted>` · 정리 뒤 프로브 키 `EXISTS` 0 · `identity-admin:assert-probe` 0. 같은 서버로 확인: `--no-auth-warning` 없이 `-u` → 첫 줄이 경고 ·
  붙이면 `PONG`만 · 오류 응답(`NOAUTH`) 종료 코드 0 · nil 출력 1바이트(줄바꿈). Dragonfly 쪽 동작(aclfile 적재 · `%R~` · NOPERM 문구 · 15자 축약)은 소스 판독뿐이다 — 라이브 판정은 VD-4(gitops `platform/dragonfly/README.md` §3).
- **변이**(같은 모의 ⓐ): m1 = `rc()`에서 `--no-auth-warning`을 빼면 `writer-set` · `reader-get`이 **거짓 FAIL**(응답 첫 줄이 경고)이고 NOPERM 근거 · ACL 첫 행이 경고 줄이 된다(14줄) ·
  m2 = 가림을 옛 `{16,}`로 되돌리면 ACL 행 3개에 해시 앞 15자가 그대로 남는다(누출 hash 3).
- **빨강 → 초록**: main `3fa4440`의 스크립트를 같은 모의(가짜 psql로 pg 6 PASS)로 돌린 Job 로그(15줄)는 `EVIDENCE:` 첫 행이 경고 줄 · ACL 행 3개에 해시 15자 노출 · `noperm` 근거가 경고 줄이고,
  모노레포(`c20674b` — `6049fb5`와 하네스 파일 동일) 하네스 `tests/platform/kafka.tests.ps1`의 **판정 코드 자체**(최상위 함수 + 상수를 AST로 읽어 실행 · `ClusterAssert 'job-d-2'` 본문 · 파일 수정 0 · `Get-ParsedJobLog`만 모의 로그로 바꿔 끼움 ·
  `--tail=50`)로 job-d-2 **FAIL** "no RESULT line for noauth, writer-set, reader-get, reader-set-denied, reader-cross-denied (the Job does not emit these check ids yet; T057 adds them)"였다.
  이 PR의 Job 로그(**20줄** = pg `RESULT` 6 + Dragonfly 13 + `SUMMARY: pass=13 fail=0` · pg-assert exit 0) = job-d-2 **PASS**("… PASS; pattern %R~revoked:* present on the sample-pod row (VD-4); SUMMARY pass=13 fail=0 matches 13 RESULT line(s)") ·
  ⓑ · ⓒ 로그(`SUMMARY: pass=12 fail=1` · exit 1) = job-d-2 FAIL(해당 id). `tests/platform/data.tests.ps1`의 `Test-JobLog`(같은 방식): 이 PR ⓐ = ok · ⓑ · ⓒ = not ok("RESULT FAIL for <id> (outside the tracked set)" + `SUMMARY fail=1`) ·
  main = ok(그 판정은 Dragonfly id를 요구하지 않는다 — 추적 밖 id의 FAIL만 문제로 본다).
- **수정 라운드 r1(리뷰 r1 S3 · K3 · O1 → ⑥ · S4 · O4 → 병합 절 — 2026-10-22)**: ⓐ ⑥ `reader-cross-denied`를 `SET identity-admin:assert-probe 1 EX 120`으로(호출 수 · 줄 수 · 판정 문자열 `NOPERM`/`OK` 불변 —
  PASS/FAIL 문구에 `1 EX 120`) ⓑ 병합 절 fallback(결과 파일 부재)을 `acl-list` · `noperm` 2줄에서 **7 id 루프**로(출력 순서 그대로 · 주석 `⑦⑧` → `⑦–⑬`). 렌더 객체 5 그대로 · data-assert 밖 4객체와
  data-assert의 두 스크립트 밖은 JSON 동일 · 두 스크립트(initContainer 92줄 · pg-assert 158줄 — 같은 측정 · 이전 91 · 156) `sh -n` · `dash -n` · `bash --posix -n` 통과.
  모의(1라운드 가짜 redis-cli의 사본이 **새 명령 모양만** 받는다 — 옛 모양 `SET identity-admin:assert-probe 1`은 `ERR mock: unexpected call`): ⓐ 13줄 PASS 7 · 호출 8회 중 6번째 =
  `sample-pod|SET identity-admin:assert-probe 1 EX 120`(`--no-auth-warning` 붙음) · ⓒ FAIL 1 · 교차 SET 성공(`OK`) 경로 = `FAIL reader-cross-denied sample-pod로 SET identity-admin:assert-probe 1 EX 120 이 성공(OK) — 자기 접두 밖 쓰기가 허용됨` ·
  옛 스크립트 = reader-cross-denied FAIL(`… -> ERR mock: unexpected call user=sample-pod cmd=SET identity-admin:assert-probe 1`) — 빨강 → 초록.
  **fallback**(가짜 psql로 pg 6 PASS · 렌더에서 뽑은 pg-assert 스크립트를 바이트 그대로 · `/work`가 없는 환경): **14줄** = pg `RESULT: PASS` 6 + `RESULT: FAIL <id> initContainer 결과 파일(/work/dragonfly.result)이 없다` 7
  (noauth → acl-list → writer-set → reader-get → reader-set-denied → reader-cross-denied → noperm) + `SUMMARY: pass=6 fail=7` · exit 1 — 옛 병합 절은 9줄(FAIL 2 · `SUMMARY: pass=6 fail=2`).
  하네스 판정 코드(AST — 위와 같은 방식 · 파일 수정 0): job-d-2 = 새 fallback FAIL(8 problem — `acl-list: RESULT FAIL` · 나머지 6 id `RESULT FAIL -- initContainer 결과 파일(/work/dragonfly.result)이 없다` ·
  VD-4 패턴 없음 — 7 id 전부 이름) · 옛 fallback FAIL "no RESULT line for noauth, writer-set, reader-get, reader-set-denied, reader-cross-denied (the Job does not emit these check ids yet; T057 adds them)"(사유가 오도된다) ·
  ⓐ 전체 로그 20줄 = PASS(불변) / `data.tests.ps1` `Test-JobLog` = 새 fallback not ok(추적 밖 FAIL 7 + `SUMMARY fail=7`) · ⓐ ok.
- 이 Job은 여전히 **배포되지 않는다**(Application 없음 — T059). T057 머지 뒤 VD-4 동안만 운영자가 임시로 적용한다(gitops `platform/dragonfly/README.md` §3 — 기대 로그 줄).
