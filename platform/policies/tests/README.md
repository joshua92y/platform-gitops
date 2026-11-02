# platform/policies/tests/ — 자격이 필요한 검사를 클러스터 안에서 도는 Job 3종

`psql`·`redis-cli`·Kafka 콘솔 도구·OpenFGA API처럼 **자격증명이 필요한 검사는 tester가 직접 실행하지 않는다**
(계약 `contracts/hostnames-and-access.md` §자격이 필요한 검사). 이 디렉터리의 Job이 네임스페이스 `jt-dev`
안에서 실행하고, tester는 **`kubectl -n jt-dev logs job/<이름>`으로 로그 텍스트만** 읽는다.

Job은 **dev scope 자격만** 받는다. prod 자격은 없다 — dev 자격은 `ClusterSecretStore vault-dev`에서만 나오고
그 store의 `conditions.namespaces`가 `jt-dev` 하나이므로, 세 Job의 네임스페이스도 `jt-dev` 하나다.

## 파일

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | **독립 kustomization**(`namespace: jt-dev`, resources 5 = ConfigMap 1 · ES 2 · Job 2). 상위 `platform/policies/kustomization.yaml`은 이 디렉터리를 참조하지 않는다 — **Application `platform-tests`가 읽는다**(`clusters/oci-k3s/apps/platform-tests.yaml` · T059 · 아래 §Application `platform-tests`). authz 두 파일은 resources 밖이다(주석 줄 — T085에서 포함 · 결정 D4) |
| `externalsecret-assert-data-env.yaml` | ExternalSecret `assert-data-env`(store `vault-dev`, `dev/` 키만) — data-assert의 5키(pg-main 자격 3 · Dragonfly URL 2) · 리소스 wave `"0"` |
| `externalsecret-assert-kafka-env.yaml` | ExternalSecret `assert-kafka-env`(같은 store · 접두) — kafka-assert의 1키(SCRAM 비밀번호) · 리소스 wave `"0"` |
| `externalsecret-assert-authz-env.yaml` | ExternalSecret `assert-authz-env`(같은 store · 접두) — authz-assert의 2키(OpenFGA) · **kustomization 밖**(T085까지 — 결정 D4) |
| `configmap-assert-config.yaml` | 비밀이 아닌 값(엔드포인트·DB/토픽/role 이름·합성 식별자) · 리소스 wave `"0"` |
| `job-data-assert.yaml` | pg-main 6검사(T054가 `role-attrs` · `app-session-timeouts`를 더했다) + initContainer가 Dragonfly 7검사(T057이 `noauth` · `writer-set` · `reader-get` · `reader-set-denied` · `reader-cross-denied`를 더했다) · 리소스 wave `"1"` |
| `job-kafka-assert.yaml` | Kafka 2검사 · 리소스 wave `"1"` |
| `job-authz-assert.yaml` | OpenFGA 2검사 · **kustomization 밖**(T085까지 — 결정 D4) |

리소스 wave(`argocd.argoproj.io/sync-wave` `"0"` · `"1"`)는 Application `platform-tests` **안의** 적용 순서다(ConfigMap · ES가 Healthy가 된 뒤 Job) — Application 표의 숫자가 아니다.
ES를 Job별로 나눈 이유는 §자격 매핑.

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
- **data-assert 기동 유예(T057 수정 라운드 r2)**: initContainer는 필수 값 확인 직후 비인증 `PING`으로 Dragonfly 연결을 최대 15회(1초 간격) 기다린다 — **줄을 내지 않고** `noauth` 근거 끝 ` wait=<n>s` 토큰 하나만 더한다
  (줄 수 · 최대 **22줄** 불변 · 지연 상한 = REJECT면 ≈ 15 s · 패킷이 버려져 `-t 2` 시간 초과가 나면 ≈ 15 × (2 + 1) = 45 s — Job `activeDeadlineSeconds` 300 안 · 검사 id 표 `noauth` 행).
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
kubectl -n jt-dev logs job/data-assert | grep 'NOPERM'          # 읽기 전용 ACL 증거 = RESULT: PASS 줄(근거 NOPERM sample-pod has no ACL permissions) — AUTH failed가 든 줄은 FAIL(G9)
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
| | `noauth` | 자격 없이 `PING`(ConfigMap `DRAGONFLY_HOST`·`DRAGONFLY_PORT` = Service `dragonfly-dev`) → `NOAUTH`(aclfile `USER default OFF +auth +hello` — default가 OFF라 비인증 명령은 AUTH · HELLO 밖 전부 `NOAUTH` · T057 수정 라운드 r2 F12). `PONG`이면 FAIL "aclfile 미적재(default nopass) 의심" — 파싱 오류 1건이면 Dragonfly가 무인증으로 기동한다(gitops `platform/dragonfly/README.md` §1). **기동 유예(T057 수정 라운드 r2 · F13)**: 필수 값 확인 직후 · 이 검사 전에 비인증 `PING`(`-t 2`)을 1초 간격 **최대 15회** 보내, 응답에 `Could not connect`가 없어지면(`NOAUTH`도 연결 성공) 바로 넘어간다 — 새 pod의 첫 1–2초 NetworkPolicy(kube-router) 반영 전 REJECT(`Connection refused`)를 흡수한다(VD-4 1차 실측 2026-10-22 06:39:50Z — 첫 세 호출만 거부 · Dragonfly 재시작 0). 근거 끝에 **` wait=<n>s`** 토큰 1개(PASS · FAIL 모두 · `n` = 거부된 시도 수 = `sleep 1` 횟수 — 보통 0–2). 15회 뒤에도 거부면 그대로 이 검사가 FAIL이다(`… -> Could not connect … wait=15s` — 조용한 통과 0). 유예는 줄을 내지 않는다(§로그 계약 줄 수 불변) · 필수 값 결손(fail-closed 7줄)이면 유예 전에 끝나 토큰이 없다 | T057(r2 F12 · F13) · denylist.md · 모노레포 build-notes 「T050 · T051」 T057 몫 · 같은 build-notes 「T057」 VD-4 1차 실측 |
| | `acl-list` | Dragonfly `ACL LIST`(identity-admin — `DRAGONFLY_URL`)에 dev 검사 계정(`sample-pod`) 행이 있고 읽기 전용 패턴 `%R~revoked:*`를 포함. 앞에 `EVIDENCE:` 머리 1줄 + 가린 행 ≤ 6줄 | quickstart §US3 VD-4 · T057 · denylist.md |
| | `writer-set` | identity-admin으로 `SET revoked:sub:assert-probe probe EX 120` → 정확히 `OK`(쓰는 쪽 `~revoked:*`) | T057 · denylist.md §ACL 표 · §검증 T051 |
| | `reader-get` | `sample-pod`로 같은 키 `GET` → 정확히 `probe`(`%R~` 읽기 허용 · nil = 빈 응답이면 FAIL) | T057 · denylist.md |
| | `reader-set-denied` | `sample-pod`로 같은 키 `SET … x` → `NOPERM`(`OK`면 FAIL "%R~ 패턴이 쓰기를 막지 않음"). **판정(G9)**: 응답에 정확히 `NOPERM <검사 계정> ` 접두(`DRAGONFLY_ACL_USER` + 공백 — 실제 응답 `NOPERM sample-pod has no ACL permissions` · Dragonfly v1.40.1의 NOPERM 문구는 `-NOPERM <authed_username> has no ACL permissions` 하나 — `main_service.cc` :1340 · :1462)가 있을 때만 PASS · 응답에 `AUTH failed`가 있으면 그 **앞** 갈래에서 FAIL `… 인증 실패(AUTH failed) — NOPERM 판정 불가 · aclfile default 줄 또는 비밀번호 확인 -> <응답>`(redis-cli 8.8.2는 인증 실패를 `AUTH failed: <서버 응답>`으로 찍는다 — `redis-cli.c` :1610 · 옛 판정 `*NOPERM*`은 `AUTH failed: NOPERM default has no ACL permissions`도 PASS로 셌다 — VD-4 1차 실측 거짓 양성) · 다른 사용자의 접두(`NOPERM default …`)는 그 밖 갈래 FAIL | T057 · denylist.md · G9(리뷰 r3 A-R3-1) |
| | `reader-cross-denied` | `sample-pod`로 `SET identity-admin:assert-probe 1 EX 120` → `NOPERM`(자기 접두 `sample-pod:*` 밖). `EX 120`: ACL이 깨져 SET이 성공하는 FAIL 경로에서도 키가 120 s 뒤 사라진다 — 정상 경로(NOPERM)에서는 키가 생기지 않는다(정리 DEL 대상 아님 · 수정 라운드 r1). **판정(G9)**: `reader-set-denied` 행과 같다 — 접두 `NOPERM <검사 계정> `일 때만 PASS · `AUTH failed`가 든 응답은 그 앞에서 FAIL(인증 실패 — NOPERM 판정 불가) | T057 · denylist.md · G9 |
| | `noperm` | 그 계정으로 `DEL revoked:sub:assert-probe` → `NOPERM`(키 패턴과 명령 카테고리는 짝지어지지 않는다 — `%R~`로만 막힌다). 뒤에 판정이 아닌 `NOTE: cleanup DEL revoked:sub:assert-probe -> <n>` 1줄(identity-admin DEL — 실패해도 `EX 120`). **판정(G9)**: `reader-set-denied` 행과 같다 — `grep -qF 'AUTH failed'`면 FAIL(인증 실패 — NOPERM 판정 불가) · 아니면 `grep -qF "NOPERM <검사 계정> "`일 때만 PASS(옛 `grep -q 'NOPERM'`) | quickstart §US3 · T057 · G9 |
| `kafka-assert` | `roundtrip` | dev 토픽에 produce → 같은 토픽에서 마커 consume 성공(경과 시간 함께 출력). **T056**: 컨슈머를 먼저 띄워 파티션 할당(describe의 CONSUMER-ID 행)을 확인한 뒤 produce하고, PASS 근거에 `latency=<n>ms`를 **정확히 1개** 찍는다 — **latency = 마커 수신 시각 − 레코드 CreateTime(ms · 둘 다 이 파드의 시계)** · spec US3 AC3의 **5 s 기준은 이 값**이다(모노레포 `kafka.tests.ps1` job-k-3 ≤ 5000). 같은 줄의 벽시계 `produce→consume <n>s`(produce 시작 ~ 마커 수신 · 프로듀서 JVM 기동 포함)는 Job 자체 상한 `KAFKA_ROUNDTRIP_DEADLINE_S` 판정용이다. 실패 줄에는 토큰이 없다. **리뷰 r1 O5**: 할당 확인은 **자기 멤버**(실행마다 고유 `client.id` = `kafka-assert-<pid>-<epoch>`)의 행만 본다(직전 실행의 옛 멤버 행을 준비로 오인하지 않는다) · 마커 미수신 · produce 실패 경로는 `EVIDENCE: producer 마지막 오류:`를 함께 낸다(§로그 계약). **리뷰 r2 K5 · O11**: `KAFKA_PASSWORD`가 base64url 형식이 아니면 JVM을 띄우기 전에 이 id와 `cross-env-denied`를 함께 FAIL로 닫는다(값 미출력) · 진단 줄은 전부 `safe_tail` 규칙(§로그 계약) — produce rc≠0의 RESULT 줄은 스택 꼬리(`\t... N more`)가 아니라 원인 줄을 싣는다 | quickstart §US3 · T051 인계(모노레포 build-notes 「T050 · T051」 토큰 형식) |
| | `cross-env-denied` | 같은 dev 자격으로 **prod 토픽** write 시도 → 인가 거부(`TopicAuthorizationException`). 비밀번호 형식이 base64url이 아니면 roundtrip과 같은 사유로 FAIL(리뷰 r2 K5) · 인가 거부가 아닌 실패의 꼬리는 `safe_tail`(리뷰 r2 K5) | quickstart §US3 · T056 ACL |
| `authz-assert` | `check-allowed` | 튜플이 있는 테넌트에 대한 `check` → `allowed=true` | quickstart §US4 5 |
| | `cross-tenant-false` | 튜플이 없는 다른 테넌트 object → `allowed=true`가 아님 | quickstart §US3·§US4 |

**판정은 fail-closed다.** 필요한 환경변수·CA 파일이 없거나 호출이 실패하면 해당 검사는 조용히 넘어가지 않고
`RESULT: FAIL`이 되고 종료 코드가 1이 된다.

## 자격 매핑 (Job별 ExternalSecret 3장, store `vault-dev`)

| ES 이름 | Vault 경로(`remoteRef.key`) | property | env 이름 | 쓰는 Job |
|---|---|---|---|---|
| `assert-data-env` | `dev/db/dev_identity_admin/app` | `url` | `DATABASE_URL` | data-assert |
| `assert-data-env` | `dev/db/dev_identity_admin/app` | `username` | `PGUSER` | data-assert |
| `assert-data-env` | `dev/db/dev_identity_admin/app` | `password` | `PGPASSWORD` | data-assert |
| `assert-kafka-env` | `dev/kafka/identity-admin` | `password` | `KAFKA_PASSWORD` | kafka-assert |
| `assert-data-env` | `dev/dragonfly/identity-admin` | `url` | `DRAGONFLY_URL` | data-assert(`acl-list` · `writer-set` · 정리 DEL) |
| `assert-data-env` | `dev/dragonfly/sample-pod` | `url` | `DRAGONFLY_SAMPLE_URL` | data-assert(`reader-get` · `reader-set-denied` · `reader-cross-denied` · `noperm`) |
| `assert-authz-env` | `dev/openfga/store_id` | `store_id` | `OPENFGA_STORE_ID` | authz-assert(T085까지 렌더 밖) |
| `assert-authz-env` | `dev/openfga/preshared` | `key` | `OPENFGA_TOKEN` | authz-assert(T085까지 렌더 밖) |

- 전부 `dev/` 접두다(`platform/`·`prod/` 경로 0개). `dataFrom`·항목별 `sourceRef`는 쓰지 않는다.
- **Job마다 자기 ES 하나만 `envFrom`한다**(T059 결정 D5 — 아래 §후속 결정 1 채택 · 2026-10-29). 그 전에는 세 Job이 ES `assert-env` 하나(위 8키)를
  공유했다(설계 §6.3). 나눈 이유 둘: ① **자격 격리** — kafka-assert는 DB 비밀번호 · Dragonfly URL을, data-assert는 SCRAM 비밀번호를 갖지 않는다
  ② **부분 실패 격리** — 한 ES의 kv 경로 하나가 비어도(`SecretSyncedError` → Secret 미생성) 그 ES를 쓰는 Job만 뜨지 못하고 다른 Job은 돈다. 공유 ES로는
  지금 미시드인 `dev/openfga/*` 두 경로 때문에 세 Job이 모두 막혔다. 환경변수 이름 · ConfigMap은 그대로라 로그 계약은 바뀌지 않는다(`envFrom`의 Secret 이름만 바뀌었다).
  단 data-assert initContainer의 fail-closed 문구 `필수 값 없음(ExternalSecret assert-env · ConfigMap assert-config)`는 옛 이름을 그대로 싣는다 — 스크립트 변경 0
  (결정 D7)이라 다음 스크립트 변경 때 함께 고친다(판정 · 줄 수에는 영향 없음).
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

## Application `platform-tests` (T059 · 2026-10-29)

이 디렉터리는 Application **`platform-tests`**(`clusters/oci-k3s/apps/platform-tests.yaml`)가 적용한다. T041은 매니페스트와 로그 계약까지만 만들고
Application을 두지 않았다(설계 D3-A — 검사 대상이 US3/US4 산출물이라 배포하면 즉시 실패했고, 이름 · 표 행이 계약에 없었다). T059가 아래 체크리스트를
해소하고 붙였다(US3 E2E의 선행 산출물 — 모노레포 build-notes 「T059」 결정 D1–D14). 로그 계약 · `np-2-*` 파서 · tester 절차는 그대로다.

- **이름 ↔ 경로**: `platform-tests` ↔ source.path `platform/policies/tests` — `platform/<component>` 대응의 예외다. 계약(모노레포 `contracts/gitops-repo.md`)
  §Application 규약 이름 행: `platform-<component>` · `<pod>-<env>`. **예외 1개(2026-10-29 T059)**: 검증 Job Application은 `platform-tests`이며 source.path는 `platform/policies/tests`다(`platform/<component>` 대응의 유일한 예외 — 디렉터리는 T041이 `platform/policies/` 아래에 두었고 하네스·계약·과제 문면이 그 경로를 가리킨다 · validate 7.1 분기).
  `tests/validate.sh` 검사 7.1의 `tests` 분기가 이 경로만 받는다(그 밖의 경로 → `7.1 WAVE-path` FAIL — 자기검사 `wave-and-app`). 7.2는 `platform/*/` 한 단계만
  세므로 `platform/tests/` 디렉터리는 없다 — 만들면 7.2가 FAIL한다(표의 `tests` 키가 그 디렉터리를 통과시키는 사각 · 리뷰 r1 A3 · C6). (`platform-argocd`가 `bootstrap/argocd`를 쓰는 것은 계약 §디렉터리의 자기 관리 배치 — 7.1의 별도 분기다.)
- **sync-wave**: 계약 §sync-wave 단일 표의 `policies/tests` 행. 모든 플랫폼 컴포넌트 뒤라 검사 실패(Job Failed → Application Degraded)가
  root 재구축에서 앞 wave를 막지 않는다. 숫자는 계약 표 · `tests/validate.sh` `WAVE_TABLE`(`tests` 행) · Application 어노테이션에만 있다(여기 옮겨 적지 않는다).
  표의 마지막 **플랫폼** 행이지 전체의 마지막은 아니다 — `<pod>-<env>`(앱 · 뒤 행)가 생기면 root 콜드 재구축의 첫 operation은 이 Application의 health가 Healthy로
  읽힐 때까지 기다린 뒤 앱 행으로 간다. 단, Argo CD v3.5.2는 live가 없는 리소스를 Application health 집계에서 뺀다(`controller/health.go` "Missing resources should
  not affect parent app health")라, ES 2가 SecretSynced가 되고 Job이 아직 만들어지기 전의 짧은 창에서 이 Application은 Healthy로 읽힌다 — root가 그 창을 읽으면 Job
  실행(2–3분)을 기다리지 않고 앱 행으로 간다. 즉 뒤 행(앱) 게이트는 검사 Job의 결과를 **보장하지 않는다**(경합 · 실측 VD-6 · 리뷰 r2 A-r2-1). 창을 지나 Job이
  Progressing이면 기다리고, Degraded면 그 시도는 Failed이되 retry(root `ApplyOutOfSyncOnly=true` · limit 5)가 이미 만들어진 CR을 건너뛰어 앱 행을 적용하므로 최종
  phase는 Succeeded다(흔적은 `operationState.retryCount ≥ 1`뿐 — 하네스 `argo-5`는 retry 5회 소진 때만 잡고 Degraded 자체는 `argo-1`이 잡는다 · 계약 §sync-wave 표의
  `secret-stores` 행과 같은 성질 · 소스 판독). 검사 결과로 앱 행을 막아야 한다면 별도 설계가 필요하다(후속 — 이 과제 밖). 역방향: 이 Application은 앞 행(플랫폼 컴포넌트)
  child 전부가 Healthy가 된 뒤 적용된다.
- **project `tests`**(`clusters/oci-k3s/projects/tests.yaml`): sourceRepos = 이 저장소만 · destinations = `jt-dev`만 · cluster 리소스 금지 → dev scope 자격만.
- **syncPolicy**: 플랫폼 표준(automated `prune: false` · `selfHeal: true` · SSA · `CreateNamespace`(실질 no-op — jt-dev가 없으면 project `tests`의
  `clusterResourceWhitelist: []`라 Namespace 생성이 `resource :Namespace is not permitted in project tests`로 거부돼 operation Failed · fail closed · argo-5 · 소스 판독 ·
  라이브 미실측 · ns 소유는 `platform-policies` — tests whitelist에 Namespace를 넣지 않는다) · `Prune=confirm` · `Delete=confirm` · `SkipDryRunOnMissingResource`) ·
  finalizer 있음 · 예외(`ApplyOutOfSyncOnly` · `retry`) 없음 · `ignoreDifferences` 없음. Job은 마지막 리소스 wave라 Job의 진행 · 실패가 sync operation을 실패시키지
  않고 Application **health**로 드러난다(Argo CD v3.5.2 내장 Job health — Complete → Healthy · Failed → Degraded · 그 밖 Progressing).

### 선행 조건 체크리스트 — 해소 (T059)

| # | T041 체크리스트 항목 | 해소 |
|---|---|---|
| 1 | 계약 §Application 규약 · **§sync-wave 단일 표에 행 추가**(값은 계약 표에만) | 모노레포 계약 이름 행 예외 1 + §sync-wave 표 `policies/tests` 행(T059 — 같은 날 모노레포 커밋) |
| 2 | 그 다음 `tests/validate.sh` `WAVE_TABLE` · 7.1 이름 규약(계약 → validate 순서) | `WAVE_TABLE` `tests` 행 + 7.1 `tests` 분기 + 머리 주석 7.1 줄 · 자기검사 `wave-and-app` 음성 1건(경로 `platform/tests` → `7.1 WAVE-path`) · `positive` 양성 1문서(이 PR) |
| 3 | AppProject **`tests`** 소속 | `project: tests` — AppProject spec은 그대로(머리 주석만 정정 — 이 PR) |
| 4 | 선행 산출물 존재 확인 | 2026-10-29 agent-view 읽기(모노레포 build-notes 「T059」 사실 1–7): `ClusterSecretStore` 5 Valid(`vault-dev` 포함) · ns jt-dev CA 미러 ES 2(`pg-main-ca` · `jt-kafka-cluster-ca-cert`) SecretSynced · ns data 파드 6 Running(`pg-main-1` · `jt-kafka-combined-0` · entity-operator · strimzi-operator · `dragonfly-dev` · `dragonfly-prod`) · Argo Application 22 Synced/Healthy(Database/DatabaseRole · KafkaTopic/KafkaUser · Dragonfly 포함) · kv `dev/` 4경로 시드(db · dragonfly 3경로 = 2026-10-22 VD-4 실증 · kafka 1경로 = ns data ES `kafka-user-dev-identity-admin` Ready). **OpenFGA store · kv `dev/openfga/*`는 없다** → authz-assert 보류(결정 D4) |
| 5 | 재실행 모델 확정 | **B 확정**(아래 §재실행 모델 · 결정 D6) |
| 6 | 첫 실행 뒤 `cluster.tests.ps1` `np-2-*` PASS 확인 | 머지 뒤 컨트롤러(관찰 D11): `np-2-data-assert` · `np-2-kafka-assert` SKIP → PASS 기대 · `np-2-authz-assert`는 T085까지 SKIP |

머지 · 첫 실행 전까지 `cluster.tests.ps1`의 `np-2-*`는 클러스터에 Job이 없어 SKIP이다 — 매니페스트가 없어서가 아니라 배포되지 않아서다.

## 첫 배포 순서(머지 뒤)

리뷰 r1 C1(2026-10-29). 머지하면 root가 Application `platform-tests`를 만들고, 그 Application이 렌더 5장을 **리소스 wave 순서로** 적용한다(리소스 wave `"0"`이
전부 Healthy가 된 뒤 `"1"`). 확인 명령은 전부 agent-view로 된다(get · describe · logs) — 「운영자(admin kubeconfig)」 표시가 붙은 명령만 운영자 전용이다.

| 단계 | 무슨 일 | 기대 상태 | 예상 시간 |
|---|---|---|---|
| 0 머지 선행 | kv `dev/` 4경로 시드(`dev/db/dev_identity_admin/app` · `dev/dragonfly/identity-admin` · `dev/dragonfly/sample-pod` · `dev/kafka/identity-admin` — 새 시드 0) · ns jt-dev CA 미러 ES 2(`pg-main-ca` · `jt-kafka-cluster-ca-cert`) Ready · ClusterSecretStore `vault-dev` Valid · ns data 대상 파드 Running(`kubectl -n data get pods` — `pg-main-1` · `jt-kafka-combined-0` · `dragonfly-dev`) · CI(validate) PASS + 렌더 diff = 추가분만 · 운영자 kubectl 사전 동작 0 — 출력을 확인한 **뒤에만** 머지한다(모노레포 build-notes 「T059」 D10 ①–⑥) | 여섯 조건 전부 출력으로 확인 | — |
| 1 root 폴링 → child 생성 | root가 폴링 주기(`bootstrap/argocd/argocd-cm.yaml` `timeout.reconciliation` 180 s) 안에 새 커밋을 보고 자동 sync로 Application `platform-tests`를 만든다. 즉시 당기려면 운영자(admin kubeconfig) `kubectl -n argocd annotate app root argocd.argoproj.io/refresh=normal --overwrite` | root operation **즉시 Succeeded** — 지금은 이 Application이 root의 마지막 wave라 health를 기다리지 않는다(앱 행이 생긴 뒤의 콜드 재구축은 §Application `platform-tests` sync-wave) | ≤ 180 s |
| 2 리소스 wave `"0"` | ConfigMap `assert-config` · ES 2(`assert-data-env` · `assert-kafka-env`) SSA → ESO가 `vault-dev`로 kv를 읽어 Secret 2를 만든다 | ES 2 `Ready=True`(SecretSynced) → Healthy | 수 초 |
| 3 리소스 wave `"1"` | Job 2(`data-assert` · `kafka-assert`) SSA — 마지막 리소스 wave라 적용 직후 operation이 닫힌다 | operation **Succeeded** · Application(그리고 root) health Progressing — Job이 끝날 때까지(이때 하네스 `argo-1`은 일시 FAIL) | 초 |
| 4 파드 기동 · 검사 | data-assert: initContainer `dragonfly-assert`(Dragonfly 7검사) → `pg-assert`(pg 6검사 + init 결과 중계) · kafka-assert: 컨슈머 선기동 → 할당 확인 → produce → 마커 수신 → cross-env | pod Completed · 로그 마지막 줄 data-assert `SUMMARY: pass=13 fail=0` · kafka-assert `SUMMARY: pass=2 fail=0` | data-assert ≤ 2분 · kafka-assert ≤ 3분 |
| 5 완료 | Job 2 Complete → 내장 Job health Healthy | Application `Synced/Healthy`(완료된 Job이 Synced로 남는지 = VD-1) | — |
| 6 하네스(관찰 D11) | 모노레포 하네스(agent-view) | cluster **46/0/9** · data **15/0/1** · kafka **17/0/0** | — |

단계 2–5의 확인 명령(agent-view): `kubectl -n argocd get app platform-tests`(SYNC STATUS · HEALTH STATUS 열) · `kubectl -n jt-dev get externalsecret assert-data-env assert-kafka-env`(READY · STATUS 열) ·
`kubectl -n jt-dev get job`(COMPLETIONS 열) · §로그 계약의 `kubectl -n jt-dev logs job/<이름>`.

## 증상표 — 어디서 멈추면 무엇을 보는가

리뷰 r1 C1(2026-10-29). 「가장 먼저 볼 것」은 전부 agent-view 명령이다(get · describe · logs — `platform/policies/rbac-agent-view.yaml`). 「조치」의 쓰기 명령은
**운영자 전용(admin kubeconfig)**이다 — 운영자 명령은 `--kubeconfig <관리자 kubeconfig 경로>`를 명령에 직접 적는다(관리자 kubeconfig가 없는 창에서 치면 `NotFound`로
실패한다 — 모노레포 런북 `bootstrap.md` §3 T056 교훈 ②; 아래 표의 `kubectl … annotate` · `delete job`과 단계 1의 refresh 모두 같은 규칙). `<job>` = `data-assert` · `kafka-assert`.

| 증상 | 가장 먼저 볼 것(agent-view 명령) | 원인 | 조치(운영자 전용 표시) |
|---|---|---|---|
| (a) ES `SecretSyncedError` — operation `Running`(message `… Retrying attempt #<n> …`) → 재시도 5회 뒤 `Failed` · 리소스 wave `"1"`의 Job이 **없다** | `kubectl -n jt-dev get externalsecret assert-data-env assert-kafka-env` · `kubectl -n argocd get app platform-tests -o jsonpath='{.status.operationState.phase} retry={.status.operationState.retryCount} {.status.operationState.message}'` | kv 경로 없음(미시드) · `vault-dev` 정책 거부 | kv 시드 → ESO 재조회 → 재시도 창(≈ 5분) 안이면 다음 재시도가 Job까지 간다 · 창 밖(`Failed`)이면 운영자(admin kubeconfig) 전체 수동 Sync(§재실행 모델 ⑤의 방법). ESO 재조회는 실패가 이어질수록 지수 백오프로 벌어진다(수 분 실패 뒤에는 다음 시도가 5–16분 뒤일 수 있다 — 모노레포 런북 `bootstrap.md` §4 T054 「언제」) — 기다리지 않으려면 운영자(admin kubeconfig) `kubectl --kubeconfig <관리자 kubeconfig> -n jt-dev annotate externalsecret assert-data-env assert-kafka-env "force-sync=<epoch>" --overwrite`(런북 §4 T056 「늦은 시드」 2단계와 같은 방법) |
| (b) ES에 status가 없다(READY 빈 칸) · operation `Running`이 무기한 | `kubectl -n external-secrets get deploy external-secrets`(READY) · `kubectl -n jt-dev get externalsecret assert-data-env assert-kafka-env` | ESO 정지 — ES를 조정하지 않는다(sync 타임아웃이 0이라 Argo는 기다리기만 한다) | ESO 복구(`platform/external-secrets/` · Application `platform-external-secrets`) → 같은 operation이 이어 간다 |
| (c) pod `CreateContainerConfigError` | `kubectl -n jt-dev describe pod -l job-name=<job>` → Events `secret "assert-<x>-env" not found` | Secret 삭제 · 순서 우회(리소스 선택 Sync로 Job만 적용) | ES 재조회로 Secret이 다시 생기면 pod가 이어 간다 · `activeDeadlineSeconds` 300 s 뒤 `DeadlineExceeded`면 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <job>` → selfHeal |
| (d) pod가 생기지 않는다 → 300 s 뒤 Job `Failed` reason `DeadlineExceeded` | `kubectl -n jt-dev describe job <job>` Events `exceeded quota` · `violates PodSecurity`(하네스 `np-7` — 이벤트 TTL 1h 안에서만 보인다) | ResourceQuota · PSA restricted 위반 | 원인 PR 뒤 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <job>` → selfHeal |
| (e) Job `Failed` reason `BackoffLimitExceeded` · Application Degraded · 로그에 `RESULT: FAIL <id>` | `kubectl -n jt-dev logs job/<job>` | 대상 시스템(id별 — pg = `platform/cnpg-databases`(DatabaseRole · PostSync Job ⓪–②) · Dragonfly = ACL 파일 · Kafka = ACL · CA · JAAS · 할당) | 수정 PR → 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <job>` → selfHeal |
| (f) Job `Failed` reason `DeadlineExceeded`(pod는 있었다) | **활성 pod가 삭제돼 로그가 없다**(`logs job/…` 실패 — 로그를 읽는 하네스 검사가 FAIL) → `kubectl -n jt-dev describe job <job>` Events · 대상 쪽 로그(`kubectl -n data logs deploy/dragonfly-dev --since=10m` · `kubectl -n data logs jt-kafka-combined-0 --since=10m`) | 할당 60 s + 마커 30 s 초과 · 네트워크 | 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <job>`으로 재실행 → 같은 모양이면 kafka-assert에 기동 유예(data-assert `wait_ready` 모양)를 더할지 재검토(스크립트 변경 — 이 PR은 결정 D7로 스크립트 불변 · 다음 Job 스펙 변경 PR) |
| (g) Application `OutOfSync`/`Healthy`가 영구 | `kubectl -n argocd get app platform-tests -o jsonpath='{.status.resources[?(@.status=="OutOfSync")]}'` | 완료된 Job의 live-only 필드(VD-1) | `ignoreDifferences`(Job `/spec/selector` · template 라벨) 후속 PR — §재실행 모델 |
| (h) 주간 재실행 FAIL | (e)와 같다 | — | **Degraded가 7일 남는다**(`backoffLimit: 0` · 자동 재시도 없음 — 다음 재실행은 TTL 삭제 뒤) → 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <job>`으로 즉시 재실행 |

## 재실행 모델 — **B 확정** (T059 결정 D6 · 2026-10-29)

Job의 `spec.template`은 immutable이라 Argo CD가 같은 이름의 Job을 갱신할 수 없다. T041이 남긴 후보 둘(A = Argo Sync hook · B = 일반 리소스) 중 **B**를 채택했다.

- **모양**: hook 어노테이션 없음 · 리소스 wave ConfigMap · ES `"0"` → Job `"1"` · `ttlSecondsAfterFinished: 604800`(7일) 유지 · `backoffLimit: 0` 그대로.
- **주간 재검사**: Job이 끝나고 7일 뒤 TTL 컨트롤러가 Job을 지우면 Application이 OutOfSync(리소스 없음)가 되고 selfHeal이 같은 스펙으로 다시 만든다
  → 검사가 다시 돈다(첫 관찰 = VD-2 · 2026-11-05 무렵).
- **수동 재실행(운영자 전용 — admin kubeconfig)**: `kubectl -n jt-dev delete job <이름>` → selfHeal이 다시 만든다(≤ 3분 — 조정 주기 상한) 또는 Argo Sync.
  agent-view에는 `delete` 동사가 없다(`platform/policies/rbac-agent-view.yaml` — ClusterRole `view` + get/list/watch + `pods/portforward` create뿐) · tester · agent-view는 로그만 읽는다.
- **Job 스펙을 바꾸는 PR**: 완료된 Job이 남아 있으면 머지 뒤 sync가 그 Job 적용에서 거부된다(`spec.template` immutable). 순서:
  - ① 머지한다.
  - ② `kubectl -n argocd get app platform-tests -o jsonpath='{.status.operationState.phase} {.status.operationState.message}'`에서 `field is immutable`을 확인한다(agent-view로 된다).
    자동 sync operation은 기본 retry(대기 10·20·40·80·160 s — 재시도 창 ≈ 5분) 동안 phase `Running`이다(message `… Retrying attempt #<n> …`).
  - ③ 운영자(admin kubeconfig) `kubectl -n jt-dev delete job <이름>`.
  - ④ 창 안이면 → 다음 재시도가 새 스펙으로 Job을 만든다.
  - ⑤ 창 밖이면(operation `Failed` — 같은 리비전으로는 자동 sync가 다시 시작하지 않는다 · 모노레포 하네스 `argo-5`(operationState `Failed` · `Error` — T059 D9)가 잡는다)
    ③ 뒤 **운영자 전체 수동 Sync**(리소스 선택 없음): Argo CD UI `platform-tests` → SYNC(리소스 전부 · PRUNE 끔 · Apply Out of Sync Only 끔 · Retry 끔 · Sync options는
    미리 채워진 값 그대로) → 안 되면 CLI `argocd app sync platform-tests`(**옵션 플래그 없이** — syncOptions를 하나라도 주면 spec 목록이 대체된다 · `--resource` ·
    `--prune`도 주지 않는다) → admin kubeconfig만 있을 때 JSON patch(옛 `status.operationState` 제거 + `.operation` 추가 · `test` phase Failed) 순. **`.operation`만 넣는
    `--type merge` patch 금지** — 정상 경로(`SetAppOperation`)가 하는 operationState 비우기가 빠져 옛 실패 기록이 새 기록에 섞인다(2026-10-19 T056 실측 · 출처:
    `platform/kafka-topics/README.md` §1 증상표 첫 행 · 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T056 교훈 ③ · §4 T056 「늦은 시드」 4단계). agent-view로는 할 수 없다
    (K8s 동사 get · list · watch뿐 — Application에 쓸 수 없다 · 운영자 전용).
  - ⑥ 머지 **전에**(또는 Argo가 새 리비전을 당기기 전에) Job을 지우지 않는다 — selfHeal이 옛 리비전의 옛 스펙 Job을 수 초 안에 다시 만들어(옛 스펙 검사가 한 번 더 돈다)
    머지 뒤 같은 거부가 난다. 첫 사례에서 실측한다(VD-3).
- **A(Sync hook)를 채택하지 않은 이유**: hook 결과는 sync · health 집계 밖이라 Job 실패가 Application의 Synced/Healthy에 가려져 하네스 `argo-1`이 보지 못한다
  (`platform/cnpg-databases/README.md` §6 T059 — C5) · selfHeal 부분 sync · 리소스 선택 Sync · Apply only는 hook을 건너뛴다(Argo CD v3.5.2 `controller/sync.go:311`) —
  주간 재검사가 일어나지 않는다. B는 Job 실패가 Application health(Degraded)로 드러나 `argo-1`이 본다.
- **`Replace=true,Force=true`는 두지 않는다** — OutOfSync가 날 때마다 Job을 지우고 다시 만든다. 완료된 Job에 거짓 차이(live-only 필드)가 있으면 무한 재실행이 된다.
  완료된 Job이 Synced로 남는지는 머지 직후 관찰한다(VD-1 — 아니면 `ignoreDifferences`(Job `/spec/selector` · template 라벨) 후속 PR · 그 뒤 재검토).

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

## 후속 결정 — 결과 (T059 · 2026-10-29)

1. **ES 분할 — 채택(결정 D5 · 이 PR)**: `assert-env` 하나 → Job별 3개(`assert-data-env` · `assert-kafka-env` · `assert-authz-env`). 근거는 §자격 매핑
   (자격 격리 + 부분 실패 격리).
2. **authz 검사 데이터 — T085**: 지금은 합성 튜플을 Job이 쓰고 지운다(dev store만). `seed_tenant`가 만든 고정 테넌트 UUID를 단언 대상으로 삼는 안이
   더 강한 검증이지만, 그 UUID는 US4 산출물이라 T085가 정한다. authz-assert 자체도 T085까지 kustomization 밖이다(결정 D4).
3. **`ttlSecondsAfterFinished` — 7일 확정(결정 D6)**: 재실행 모델 B의 주간 재검사 주기다(§재실행 모델 · VD-2). 설계 §6.3 "미지정(로그 보존)"과
   T041 슬라이스 문면 "명시"를 함께 만족한다.

## 네트워크

이 Job이 쓰는 경로는 **이미 계약 매트릭스에 있는 행**뿐이다: `jt-dev → data 5432·9093·6379`(:82),
`jt-dev → identity 8080`(:83), `allow-dns`. **새 허용 규칙을 추가하지 않았다.** 새 목적지가 필요해지면
`contracts/network-policy.md`를 먼저 고친다.

ESO가 Job별 Secret(`assert-data-env` · `assert-kafka-env` — T085부터 `assert-authz-env`)을 만드는 경로는 `external-secrets → vault 8200`(:91)이며 `jt-dev` 정책과 무관하다.

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

## 검증 기록 (T057 r2 — data-assert 기동 유예 `wait_ready` · `noauth` 근거 ` wait=<n>s`, 저장소 로컬 · 2026-10-22)

바꾼 것은 `job-data-assert.yaml`의 **dragonfly-assert initContainer 스크립트**뿐이다: 필수 값 확인(fail-closed) 직후 · ① `noauth` 전에 기동 유예 루프(:108–119 — 비인증
`redis-cli -h "$DRAGONFLY_HOST" -p "$DRAGONFLY_PORT" -t 2 PING` 응답에 `Could not connect`가 있으면 `n=$((n + 1)); sleep 1`, 없으면 끝 · 최대 15회) + `noauth` 세 갈래 근거 끝 ` wait=${n}s`(:124–126) +
① 주석의 default 줄 표기(`+auth +hello` — :121). 머리 주석 · pg-assert 컨테이너 · 병합 절 · Job spec · 이미지 · ConfigMap · ES는 그대로다.
이유 = VD-4 1차 실측(2026-10-22 06:39:50Z · Job `data-assert-8wzr2`): 첫 세 호출(`noauth` · `acl-list` · `writer-set`)만 `Connection refused`였고 Dragonfly 재시작 0 · 엔드포인트 ready였다 —
새 pod의 첫 1–2초 NetworkPolicy(kube-router) 반영 전 REJECT로 판단했다(모노레포 build-notes 「T057」 결정 F13). 같은 실측의 다른 결함(default 줄 `-@all`이 모든 AUTH를 막았다 — F12)은 aclfile(kv) 쪽이라
이 디렉터리에서는 `noauth` 행 · 주석의 default 줄 표기만 바뀌었다(gitops `platform/dragonfly/README.md` §0 · §1 · §3).

- `kustomize build platform/policies/tests` exit 0 — 객체 5개 그대로 · sha256 `552a7214…`(main `e2f0d2b`) → `994ff98d…`. data-assert 밖 4객체 JSON 동일 · data-assert에서 initContainer `args` 밖 JSON 동일 ·
  pg-assert 스크립트는 main과 바이트 동일(`cmp` · 158줄). `kustomize build platform/dragonfly` sha256 `9335067…` 그대로 · 문서 8.
- 렌더에서 뽑은 initContainer 스크립트 **105줄**(같은 측정 — YAML 블록 :82–185의 104줄 + yq 끝 빈 줄 1 · 이전 92): `sh -n` · `dash -n` · `bash --posix -n` 통과. `wait=` 토큰은 `noauth` emit 3줄에만 있다(주석 1줄 제외).
- **모의 실행**(1라운드 가짜 redis-cli의 수정 라운드 r1 사본(새 명령 모양) 앞에 r2 래퍼를 둔다 — 처음 N회 호출을 실제 redis-cli 8.8.2처럼 stderr `Could not connect to Redis at dragonfly-dev.data.svc:6379: Connection refused` +
  exit 1로 거부하고 그 뒤는 r1 모의에 넘긴다 · `ACL LIST`만 F12 모양(default 행 `-@all +auth +hello`)으로 답한다 · `sleep`은 실제 · 렌더에서 뽑은 스크립트의 `/work/`만 바꿔 dash로 실행 · URL은 가짜 비밀번호):

  | 경로 | 거부(처음 N회) | 결과 파일 줄 | RESULT · `wait=` | redis-cli 호출 | 경과 | 누출(`redis://` 비가림 · 가짜 비밀번호 · `#` + hex 8자 이상) |
  |---|---|---|---|---|---|---|
  | ⓐ 즉시 연결 | 0 | **13** | PASS 7 · `PASS noauth 미인증 PING -> NOAUTH(default 사용자 OFF) wait=0s` | 9(유예 PING 1 + 기존 8) | 2 s | 0 · 0 · 0 |
  | ⓑ 처음 2회 거부 | 2 | 13 | PASS 7 · `wait=2s`(3번째 유예 PING에서 끝) | 11 | 4 s | 0 · 0 · 0 |
  | ⓒ 유예 15회 + `noauth` PING까지 거부 | 16 | 13 | `FAIL noauth 미인증 PING이 NOAUTH로 거부되지 않음 -> Could not connect to Redis at dragonfly-dev.data.svc:6379: Connection refused wait=15s` + PASS 6(이후 호출은 그대로 진행) | 23(유예 15 + 8) | 18 s | 0 · 0 · 0 |
  | ⓒ′ 정확히 15회 거부(유예 소진 직후 연결) | 15 | 13 | PASS 7 · `wait=15s` | 23 | 19 s | 0 · 0 · 0 |
  | ⓓ `DRAGONFLY_HOST=''`(1라운드 ⓓ) | 0 | **7** | FAIL 7(`… 필수 값 없음(…): DRAGONFLY_HOST`) · `wait=` 0개(유예 전에 끝난다) | 0 | 0 s | 0 · 0 · 0 |
  | ⓔ 끝까지 거부(1라운드 ⓕ) | 전부 | 10 | FAIL 7(`noauth`만 `wait=15s`) · `EVIDENCE:` 머리 1 + 오류 1행 · NOTE 1 | 23 | 18 s | 0 · 0 · 0 |

  경과에서 `sleep` 초를 뺀 나머지(2–4 s)는 이 작업 환경(Windows)에서 가짜 redis-cli 프로세스를 띄우는 시간이다 — 실제 Job에서 REJECT는 즉시 돌아오므로 유예 시간 ≈ `n` s다.
- **빨강 → 초록**(라이브 1차 모양 — 처음 3회 거부): main `e2f0d2b`의 스크립트 = 10줄 · FAIL 3(`noauth` · `acl-list` · `writer-set` — `Connection refused` · 06:39:50Z 로그와 같은 세 id) / 이 수정본 = 13줄 · PASS 7 · `wait=3s`.
- 모노레포(`bd0fdce` — 하네스 파일 작업 트리 변경 0) 하네스의 **판정 코드 자체**(1라운드와 같은 AST 방식 · 파일 수정 0 · `--tail=50`)를 전체 Job 로그(가짜 psql로 pg 6 PASS + 병합 절)에 적용했다:
  ⓐ · ⓑ 20줄 `SUMMARY: pass=13 fail=0` = `kafka.tests.ps1` job-d-2 **PASS**("… SUMMARY pass=13 fail=0 matches 13 RESULT line(s)") · `data.tests.ps1` `Test-JobLog` ok /
  ⓒ 20줄 `SUMMARY: pass=12 fail=1` = job-d-2 FAIL(`noauth: RESULT FAIL -- … wait=15s`) · `Test-JobLog` not ok("RESULT FAIL for noauth (outside the tracked set)" · `SUMMARY fail=1`).
  파서 정규식(`\ARESULT: (PASS|FAIL) (\S+)(?: (.*))?\z`)은 id 뒤 전부를 근거로 받으므로 ` wait=<n>s`는 판정에 영향이 없다.
- 이 Job은 여전히 **Application 배포 전**이다(T059). 라이브 확인은 F12(acl 2경로 재렌더 + pod 삭제)와 이 수정 PR 머지 뒤의 VD-4 재측정에서 한다(`wait=<n>s` 실측값 · 15회 안에 연결되는가).
- **G9 — NOPERM 판정 좁히기(리뷰 r3 A-R3-1 · A-R3-5 · 2026-10-22)**: 바꾼 것은 initContainer의 ⑤ `reader-set-denied` · ⑥ `reader-cross-denied` · ⑦ `noperm` **판정**과 이유 주석 1줄이다(명령 · redis-cli 호출 수 · 결과 줄 수 · id 순서 · `wait=` 토큰 불변).
  PASS = 응답에 정확히 `NOPERM ${DRAGONFLY_ACL_USER} `(뒤 공백 포함) 접두 — ⑤ ⑥ `case` 패턴 `*"NOPERM ${DRAGONFLY_ACL_USER} "*` · ⑦ `grep -qF "NOPERM ${DRAGONFLY_ACL_USER} "`. 그 **앞** 갈래 = 응답에 `AUTH failed`(⑤ ⑥ `*'AUTH failed'*` · ⑦ `grep -qF 'AUTH failed'`)면
  FAIL `… 인증 실패(AUTH failed) — NOPERM 판정 불가 · aclfile default 줄 또는 비밀번호 확인 -> <응답 첫 줄>`. `OK` 갈래 · 그 밖 갈래는 그대로 · `writer-set`(`OK` 정확 일치) · `reader-get`(`probe` 정확 일치)은 이미 엄격해 그대로다.
  근거: Dragonfly v1.40.1의 NOPERM 문구는 `-NOPERM <authed_username> has no ACL permissions` 하나다(`main_service.cc` :1340 · :1462 — 로컬 실바이너리 응답 `NOPERM sample-pod has no ACL permissions`). redis-cli 8.8.2는 인증 실패를
  stderr `AUTH failed: <서버 응답>`으로 찍고(`redis-cli.c` :1610) 비대화 실행은 그 연결 실패를 무시한 채(:11141) 명령을 비인증 연결로 보낸다(응답 `NOAUTH …`) — 그래서 VD-4 1차 실측(06:39:50Z) 로그 14–16행의
  `RESULT: PASS reader-set-denied` · `reader-cross-denied` · `noperm … -> AUTH failed: NOPERM default has no ACL permissions`는 옛 판정(`*NOPERM*` · `grep -q 'NOPERM'`)의 **거짓 양성**이었다.
  - 렌더: `kustomize build platform/policies/tests` 객체 5 · sha256 `994ff98d…` → `9213a0fe…` · data-assert initContainer `args` 밖 JSON 동일 · pg-assert 스크립트 바이트 동일(158줄) · initContainer 스크립트 **110줄**(같은 측정 —
    YAML 블록 :82–190의 109줄 + yq 끝 빈 줄 1 · 이전 105) `sh -n` · `dash -n` · `bash --posix -n` 통과. `kustomize build platform/dragonfly` `9335067…` 그대로 · 문서 8(`externalsecrets-acl.yaml` 머리 주석만 바뀜 — 리뷰 r3 A-R3-4).
  - **모의 문구 정정(A-R3-5)**: 1라운드 · 수정 라운드 r1 · r2 모의의 가짜 redis-cli는 거부 응답을 `NOPERM sample-pod No permissions to access a key`(서버가 내지 않는 문구)로 냈다 — 위 표들의 수치는 옛 판정 `*NOPERM*`에서 문구와
    무관했다. G9 모의(수정 라운드 r3 — r2 거부 래퍼와 r1 모의를 한 스크립트로 합친 사본 · `ACL LIST`는 F12 모양)는 실제 문구 `NOPERM <사용자> has no ACL permissions`로 답하고, 인증 실패 경로는 실제 redis-cli처럼
    stderr `AUTH failed: NOPERM default has no ACL permissions` + stdout `NOAUTH Authentication required.`를 낸다(렌더에서 뽑은 스크립트의 `/work/`만 바꿔 dash로 실행 · URL은 가짜 비밀번호):

  | 경로 | 거부 3검사(⑤ ⑥ ⑦)의 응답 | 결과 파일 줄 | 이 수정본 | 빨강 대조(r2 스크립트 · 같은 모의) |
  |---|---|---|---|---|
  | ⓐ 전부 정상 | `NOPERM sample-pod has no ACL permissions` | 13 | PASS 7 | PASS 7 |
  | ⓕ 1차 사고 재현 — `ACL LIST` 밖의 인증 호출(`writer-set` · `reader-get` · 거부 3검사 · 정리 DEL) 전부 인증 실패 | `AUTH failed: NOPERM default has no ACL permissions` + `NOAUTH …` | 13 | PASS 2(`noauth` · `acl-list`) · FAIL 5 — 거부 3검사 = `… 인증 실패(AUTH failed) — NOPERM 판정 불가 …` | PASS 5 · FAIL 2(`writer-set` · `reader-get`) — 거부 3검사 **거짓 PASS** |
  | ⓕ′ 처음 3회 거부 + `ACL LIST`까지 인증 실패(1차 사고의 서버 상태 그대로) | ⓕ와 같다 | 11 | `noauth` PASS `wait=3s` · FAIL 6 | PASS 4(거부 3검사 거짓 PASS) · FAIL 3 |
  | ⓖ 다른 사용자의 접두(`AUTH failed` 없음) | `NOPERM default has no ACL permissions` | 13 | PASS 4 · FAIL 3(그 밖 갈래 `… 가 NOPERM으로 거부되지 않음 -> NOPERM default …`) | **PASS 7** — Job 전체 `SUMMARY: pass=13 fail=0` |
  | ⓗ 변이 — 뒤 공백 없는 접두 충돌 | `NOPERM sample-pod2 has no ACL permissions` | 13 | PASS 4 · FAIL 3 | PASS 7 |

  모든 경로 누출 0(`redis://` 비가림 · 가짜 비밀번호 · `#` + hex 8자 이상) · id 순서 그대로 · `wait=` 토큰은 `noauth` 줄에만 1개.
  - 모노레포(`bd0fdce` — 하네스 파일 작업 트리 변경 0) 하네스의 **판정 코드 자체**(같은 AST 방식 · 파일 수정 0 · `--tail=50`)를 전체 Job 로그(가짜 psql로 pg 6 PASS · 20줄)에 적용했다: ⓐ `SUMMARY: pass=13 fail=0` =
    `kafka.tests.ps1` job-d-2 PASS · `data.tests.ps1` `Test-JobLog` ok / ⓕ `pass=8 fail=5` = job-d-2 FAIL(5 problem — 거부 3검사 포함) · not ok / ⓖ `pass=10 fail=3` = job-d-2 FAIL(3) · not ok.
    빨강(r2 스크립트): ⓕ `pass=11 fail=2` = job-d-2 FAIL이지만 problem은 `writer-set` · `reader-get` 2개뿐(거부 3검사가 PASS로 가려진다) · ⓖ `pass=13 fail=0` = job-d-2 **PASS** · `Test-JobLog` ok(다른 사용자의 NOPERM이 전체 판정을 통과했다).

## 검증 기록 (T059 — Application `platform-tests` · ES Job별 분할 · 리소스 wave, 저장소 로컬 · 2026-10-29)

바꾼 것: Application `clusters/oci-k3s/apps/platform-tests.yaml`(신규) · `kustomization.yaml` resources(ES 1 + Job 3 → ES 2 + Job 2 · authz 두 파일은 주석 줄) · ES `assert-env`
삭제 → `externalsecret-assert-{data,kafka,authz}-env.yaml` · Job 3파일의 `envFrom` Secret 이름 · 리소스 wave 어노테이션(`"1"`) · 머리 주석 「실행 시점」(kafka-assert는 머리의
ES 이름도) · ConfigMap 어노테이션(`"0"` — 값 불변) · `tests/validate.sh` 7.1 · 자기검사 · 문서. Job 스크립트 · 이미지 · securityContext · 자원 · 볼륨은 그대로다.

- `kustomize build platform/policies/tests` exit 0 — 객체 **5개**(kustomize 출력 순서: ConfigMap/assert-config · Job/data-assert · Job/kafka-assert · ExternalSecret/assert-data-env ·
  ExternalSecret/assert-kafka-env) · sha256 `9213a0fe…`(main `ac0340a`) → `f3f0cca4…`. 리소스 wave = ConfigMap · ES `"0"` · Job `"1"` · ns 전부 `jt-dev` · 렌더의 envFrom · metadata에 옛 ES 이름 0건 · authz 0건(스크립트 FAIL 문구의 `assert-env` 1건은 D7로 유지 — §자격 매핑).
- `envFrom` Secret 이름(렌더): data-assert initContainer `dragonfly-assert` · 본 컨테이너 `pg-assert` = `assert-data-env` · kafka-assert = `assert-kafka-env`(파일: authz-assert =
  `assert-authz-env`). ES 키 집합: 옛 `assert-env` 8키 = 새 3장의 합 8키(`secretKey` · `remoteRef.key` · `property` — `diff` 0).
- **변경 0 확인**: 렌더의 data-assert · kafka-assert와 파일 authz-assert에서 `envFrom[0].secretRef.name` · `metadata.annotations`만 지운(정규화한) JSON이 main과 동일 ·
  ConfigMap은 `metadata.annotations` 밖 JSON 동일 · 스크립트 바이트 동일(앞 기록과 같은 측정 — initContainer **110줄** · pg-assert **158줄** · kafka-assert **225줄**).
- `kubeconform -strict -ignore-missing-schemas -summary`(렌더): Valid 3 · Invalid 0 · Errors 0 · Skipped 2(ExternalSecret = CRD 스키마) · 같은 명령(파일 3 — Application ·
  authz Job · authz ES): Valid 1 · Invalid 0 · Skipped 2.
- `VALIDATE_SKIP_TOOLS=1 bash tests/validate.sh`(도구 전부 있음 — helm 포함): **PASS 39 · FAIL 0 · WARN 4 · SKIP 0 · 결과: PASS**(WARN 4는 기존 `platform/system-upgrade`
  k3s-upgrade 이미지 4줄 그대로) — `[PASS] 2 APP-SSA — Application 23개 모두 ServerSideApply=true` · `[PASS] 3 ES — ExternalSecret 44개(파일+렌더링) ①②③④⑦ 통과` ·
  `[PASS] 7.1 WAVE — Application 23개 sync-wave·이름·경로 = 단일 표` · `[PASS] 7.2 WAVE-dir — platform/ 디렉터리 21개 모두 단일 표에 있음`.
  `--root platform/policies/tests` 부분 실행의 `[PASS] 3 ES — ExternalSecret 5개(파일+렌더링)` = 파일 3 + 렌더 2 — 렌더 밖 `assert-authz-env`도 파일 단위로 검사된다.
- 자기검사 부분 실행(`VALIDATE_TESTS_ONLY='^(positive|wave-and-app)$'` — 전체 실행은 CI): validate.sh를 고치기 **전** = `2 케이스, 실패 2`(positive: `7.1 WAVE-unknown … platform-tests:
  컴포넌트 'tests'는 §sync-wave 단일 표에 없음` · wave-and-app: 기대 줄 `7.1 WAVE-path … platform-tests: source.path 'platform/tests' ≠ platform/policies/tests` 없음) → 고친 뒤 =
  `2 케이스, 실패 0`. 변이: 표 행만 두고 7.1 `tests` 분기를 뺀 사본은 positive에서 `7.1 WAVE-path … 'platform/policies/tests' ≠ platform/tests` FAIL · wave-and-app에서 기대 줄 없음
  — 표 행과 분기가 각각 필요하다.
- gitleaks(`gitleaks detect --no-git -s platform/policies/tests`): no leaks found.
- **클러스터에서는 아직 실행되지 않았다** — 머지 뒤 컨트롤러가 관찰한다(모노레포 build-notes 「T059」 D11 · VD-1–VD-10).
