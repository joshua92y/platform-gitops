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
| `job-data-assert.yaml` | pg-main 6검사(T054가 `role-attrs` · `app-session-timeouts`를 더했다) + initContainer가 Dragonfly 2검사 |
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
  모든 `RESULT:`와 `SUMMARY:`는 마지막 50줄 안에 들어와야 한다(현재 최대 **16줄** = data-assert: pg `RESULT` 6 + initContainer 줄 ≤ 9
  (`EVIDENCE:` 머리 1 + ACL LIST ≤ 6(`head -n 6`) + `RESULT` 2) + `SUMMARY` 1 · kafka-assert ≤ 4 · authz-assert ≤ 5 — T054 재계산. 이전 표기 "11줄"은
  ACL LIST 6줄 상한을 덜 센 값이었다(T054 전 data-assert 최대 = 14줄)).
- 값 자체(비밀번호·토큰·URL의 자격 부분)는 절대 출력하지 않는다. `ACL LIST` 증거의 비밀번호 해시(`#<hex>`)는
  `#<redacted>`로 치환한 뒤 찍는다.

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
| | `acl-list` | Dragonfly `ACL LIST`에 dev 검사 계정(`sample-pod`) 행이 있고 읽기 전용 패턴 `%R~revoked:*`를 포함 | quickstart §US3 VD-4 · T057 · denylist.md |
| | `noperm` | 그 계정으로 `DEL revoked:sub:assert-probe` → `NOPERM` | quickstart §US3 · T057 |
| `kafka-assert` | `roundtrip` | dev 토픽에 produce → 같은 토픽에서 마커 consume 성공(경과 시간 함께 출력) | quickstart §US3 |
| | `cross-env-denied` | 같은 dev 자격으로 **prod 토픽** write 시도 → 인가 거부(`TopicAuthorizationException`) | quickstart §US3 · T056 ACL |
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
| `dev/dragonfly/identity-admin` | `url` | `DRAGONFLY_URL` | data-assert(ACL 조회) |
| `dev/dragonfly/sample-pod` | `url` | `DRAGONFLY_SAMPLE_URL` | data-assert(NOPERM 프로브) |
| `dev/openfga/store_id` | `store_id` | `OPENFGA_STORE_ID` | authz-assert |
| `dev/openfga/preshared` | `key` | `OPENFGA_TOKEN` | authz-assert |

- 전부 `dev/` 접두다(`platform/`·`prod/` 경로 0개). `dataFrom`·항목별 `sourceRef`는 쓰지 않는다.
- 세 Job이 **같은 Secret 하나**를 `envFrom`한다(설계 §6.3). Job마다 ES를 쪼개면 Job 사이 자격 격리가 한 겹
  늘어난다(예: kafka-assert가 DB 비밀번호를 갖지 않음) — 채택 여부는 아래 §후속 결정.
- 비밀이 아닌 값(호스트·DB/토픽 이름·합성 식별자)은 ConfigMap `assert-config`에 있다.

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
| Kafka 컨슈머 그룹 이름 | `dev-identity-admin-assert` — KafkaUser ACL의 "그룹 접두"가 계약에 없다 | T056 |
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
