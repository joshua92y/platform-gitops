# platform/kafka-topics/ — 운영자 절차 (T056)

Strimzi **`KafkaTopic` 4**(`identity-admin.session.revoked` · `dev.identity-admin.session.revoked` · `identity-admin.dlq` · `dev.identity-admin.dlq` — partitions 3 · replicas 1 · retention 7d)
+ **`KafkaUser` 2**(`identity-admin` · `dev-identity-admin` — SCRAM-SHA-512 · ACL topic 접두 Read/Write/Describe + group 접두 Read) + 그 비밀번호 Secret을 Vault kv에서 만드는
**비밀번호 `ExternalSecret` 2**(ns `data` · store `vault-data`) + 원본 CA Secret의 `ca.crt`만 앱 ns로 복제하는 **CA 미러 `ExternalSecret` 5**(store `k8s-data-ca` — `pg-main-ca` → `identity`·`jt-dev`·`jt-prod` ·
`jt-kafka-cluster-ca-cert` → `jt-dev`·`jt-prod`)를 소유한다. 합계 **13장**. Argo CD Application **`platform-kafka-topics` 하나**가 이 디렉터리 하나를 적용한다(계약 `gitops-repo.md` §sync-wave 단일 표의 `kafka-topics` 행).
설치 방식은 `platform/cnpg-databases/`와 같은 **순수 매니페스트**다(`helmCharts` 없음).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources` 4파일(문서 13장). 전역 `namespace:` 변환기 없음(ns가 넷이라 쓸 수 없다). 만들지 않는 것과 되돌리기 요약은 머리 주석 |
| `externalsecrets-kafka-users.yaml` | ExternalSecret 2(리소스 wave `"0"` · ns `data`): `kafka-user-identity-admin` ← `vault-data` `prod/kafka/identity-admin` · `kafka-user-dev-identity-admin` ← `dev/kafka/identity-admin` — `data: [{secretKey: password, property: password}]` · **template 없음** · Owner · Periodic 5m |
| `kafkausers.yaml` | KafkaUser 2(리소스 wave `"1"` · 라벨 `strimzi.io/cluster: jt-kafka`): `authentication: scram-sha-512` + `password.valueFrom.secretKeyRef: {name: kafka-user-<이름>, key: password}` · `authorization: simple` + ACL ⓐ topic prefix(`identity-admin.` / `dev.identity-admin.`) Read·Write·Describe ⓑ group prefix(`identity-admin-` / `dev-identity-admin-`) Read |
| `kafkatopics.yaml` | KafkaTopic 4(리소스 wave `"1"` · 라벨 `strimzi.io/cluster: jt-kafka`): `metadata.name` = 토픽 이름(`spec.topicName` 없음) · partitions 3 · replicas 1 · config `retention.ms 604800000` · `cleanup.policy delete` · `min.insync.replicas 1` |
| `externalsecrets-ca-mirror.yaml` | ExternalSecret 5(리소스 wave `"1"`): 이름 = `target.name` = `remoteRef.key` = 원본 Secret 이름 · `data: [{secretKey: ca.crt, property: ca.crt}]` · `dataFrom` 없음 · template 없음 · Owner · Periodic 5m |

> **머지 → 폴링 주기 안에 자동 sync → wave 0(비밀번호 ES 2 SecretSynced) → wave 1(KafkaUser 2 · KafkaTopic 4 · CA 미러 ES 5 적용) → UO가 SCRAM 자격·ACL을, TO가 토픽을 만들고 각 CR이 `Ready`**
> (머지 → operation 시작 실측: T052 +4분 52초 · T053 +4분 47초 · T054 +2분 39초 · T055 +5분 23초 — 모노레포 런북 `bootstrap.md` §3). 파드를 만들지 않으므로 이미지 pull이 없고 조정은 초 단위로 본다(§1 · VD-2·VD-3).
> 머지 **전** §0의 선행 조건 표를 전부 확인한다 — 특히 **P1(Vault kv 2경로 시드)**: 시드 전에 머지하면 wave 0의 ES가 `SecretSyncedError`(Degraded)로 그 sync 시도가 Failed가 되고,
> 이 Application은 예외 없는 표준 syncPolicy라 기본 retry(대기 10·20·40·80·160 s ≈ 5분 — Argo CD v3.5.2 `controller/appcontroller.go` :1550이 증가된 RetryCount로 대기를 계산한다 · T055 실측 첫 대기 ≈ 10초 · 리뷰 r3 B1 정정)를 다 쓰면 같은 리비전으로 다시 시작하지 않는다(§1 증상표). **머지가 먼저 됐다면(늦은 시드)** kv 시드 뒤 모노레포 런북
> `docs/runbooks/bootstrap.md` §4 T056 「늦은 시드」(관리자 kubeconfig로 ES 2장에 `force-sync=<epoch>` 어노테이션 → agent-view로 2장 SecretSynced 확인 → retry를 다 썼으면 **전체** 수동 Sync).
> 머지 뒤 운영자가 §2의 확인과 §3의 VD를 기록한다(기록 위치는 §6).

- **이 저장소에 비밀은 없다.** 매니페스트에는 kv **경로·키 이름**과 사용자·토픽·Secret **이름**만 있다. 비밀번호 Secret 2장과 미러 Secret 5장은 ESO가, 자격 Secret 2장은 UO가 런타임에 만든다(희망 상태에 Secret 0장).
- **전역 `namespace:` 변환기가 없다.** 네 파일이 `metadata.namespace`를 직접 적는다(ns data 8 · identity 1 · jt-dev 2 · jt-prod 2).
- 로컬 재현(리뷰어용 · helm 불필요):
  ```bash
  kustomize build platform/kafka-topics   # 문서 13(ExternalSecret 7 · KafkaUser 2 · KafkaTopic 4)
  bash tests/validate.sh                  # FAIL 0 · 검사 3(ES ①②③④⑦) 그룹 PASS 줄의 ExternalSecret 수가 이 PR로 14 늘어난다(파일 7 + 렌더 7)
  ```
- **sync-wave 숫자는 여기 적지 않는다.** 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**, 코드 사본은 `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
  매니페스트의 `argocd.argoproj.io/sync-wave` `"0"`·`"1"`은 **그 표의 숫자가 아니라** 이 Application 안의 리소스 적용 순서다(§1).

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 **13장**):

| 객체 | ns | 리소스 wave | 역할 |
|---|---|---|---|
| ExternalSecret `kafka-user-identity-admin` | data | `"0"` | Secret `kafka-user-identity-admin`(키 `password`) ← `vault-data` `prod/kafka/identity-admin` — KafkaUser `identity-admin`의 secretKeyRef |
| ExternalSecret `kafka-user-dev-identity-admin` | data | `"0"` | Secret `kafka-user-dev-identity-admin`(키 `password`) ← `vault-data` `dev/kafka/identity-admin` — KafkaUser `dev-identity-admin`의 secretKeyRef |
| KafkaUser `identity-admin` | data | `"1"` | prod SCRAM 사용자 — topic prefix `identity-admin.` Read·Write·Describe · group prefix `identity-admin-` Read |
| KafkaUser `dev-identity-admin` | data | `"1"` | dev SCRAM 사용자 — topic prefix `dev.identity-admin.` Read·Write·Describe · group prefix `dev-identity-admin-` Read(검사 Job 그룹 `dev-identity-admin-assert` 포함) |
| KafkaTopic `identity-admin.session.revoked` · `identity-admin.dlq` | data | `"1"` | prod 토픽 · prod DLQ |
| KafkaTopic `dev.identity-admin.session.revoked` · `dev.identity-admin.dlq` | data | `"1"` | dev 토픽 · dev DLQ(검사 Job `kafka-assert`의 roundtrip 대상은 앞의 것) |
| ExternalSecret `pg-main-ca` × 3 | identity · jt-dev · jt-prod | `"1"` | Secret `pg-main-ca`(키 `ca.crt`만) ← `k8s-data-ca` 원본 `data/pg-main-ca` — pod `/etc/pg/ca.crt` · 검사 Job `data-assert` |
| ExternalSecret `jt-kafka-cluster-ca-cert` × 2 | jt-dev · jt-prod | `"1"` | Secret `jt-kafka-cluster-ca-cert`(키 `ca.crt`만) ← 원본 `data/jt-kafka-cluster-ca-cert` — Kafka 클라이언트 PEM truststore · 검사 Job `kafka-assert` |

**런타임 객체**(희망 상태에 없다 — 모양은 §2 · §3 VD에서 확인 · 이름은 업스트림 코드로 확인 · §4 「소스로 확인한 사실」):
- **ESO가 만드는 Secret 7**: ns data `kafka-user-identity-admin` · `kafka-user-dev-identity-admin`(키 `password` 하나) · 미러 5장(키 `ca.crt` 하나). ownerReference = 각 ES(Owner).
  template이 없어 ES의 라벨·어노테이션(Argo tracking-id · sync-wave)이 Secret에 복사된다 — Argo는 종류·이름이 다른 복사본을 관리 대상으로 세지 않는다(§4).
- **UO가 만드는 자격 Secret 2**(ns data · 이름 = KafkaUser 이름): `identity-admin` · `dev-identity-admin` — 키 `password` + `sasl.jaas.config`(SCRAM 로그인 모듈 문자열 — 비밀번호 포함) ·
  라벨 `strimzi.io/kind: KafkaUser` 등 · ownerReference = KafkaUser. 앱은 이 Secret을 쓰지 않는다(앱 ns는 같은 kv를 `<pod>-env`로 받는다 — T072). **agent-view는 Secret을 읽지 못한다**(§2 운영자 전용).
- **Kafka 쪽 객체**(K8s 객체가 아니다): 토픽 4(TO가 생성 · `status.topicId`) · SCRAM-SHA-512 자격 2 · ACL(operation마다 1행 — 사용자당 topic 3 + group 1 = 4행 · VD-6).
- CR 메타데이터: KafkaTopic에 TO finalizer `strimzi.io/topic-operator`(희망 상태에 없음) · KafkaUser/KafkaTopic `status`(conditions · `secret`·`username` / `topicName`·`topicId`).

**이 디렉터리가 만들지 않는 것**:
- `Kafka jt-kafka` · `KafkaNodePool` · Strimzi operator · Entity Operator → `platform/kafka/`(T055). superUsers는 두지 않는다(T055 · 하네스 kafka-2).
- Namespace · PSA · NetworkPolicy → `platform/policies/`(정책 변경 **0** — 파드를 만들지 않는다 · 앱 → Kafka 9093은 매트릭스 `jt-dev`·`jt-prod` → `data` 행이 이미 연다).
- Vault kv 값(`kv/prod/kafka/identity-admin` · `kv/dev/kafka/identity-admin` 키 `password`) → 운영자 시드(P1). Vault 정책 → 모노레포 `infra/vault/policies.tf`(eso-data `kv/data/{dev,prod}/kafka/*` 이미 허용).
- 앱 ns의 `<pod>-env`(`KAFKA_PASSWORD` ← 같은 kv · store `vault-{env}`) → 앱 overlay(T072). 검사 Job Application(`platform/policies/tests` — kafka-assert 실행) → T059.
- 그룹·토픽 밖 ACL(cluster · transactionalId) · quotas · Create 권한 → 두지 않는다(§4).
- AppProject `platform` 변경 **없음**: 13장 전부 네임스페이스 범위이고 destinations에 `data` · `identity` · `jt-dev` · `jt-prod`가 이미 있다(`clusters/oci-k3s/projects/platform.yaml` — 14 ns)
  (계약 gitops-repo.md :49 「`platform`에 `jt-dev`를 넣지 않는다」 문장과의 모순은 converge 인계 1번 — 이 디렉터리가 project platform 리소스(CA 미러 ES — jt-dev·jt-prod 4장 · identity 1장)를 앱 ns에 더한다).

**선행 조건**(머지 전 전부 확인 — 하나라도 미충족이면 머지하지 않는다):

| # | 전제 | 확인 | 상태 2026-10-16 |
|---|---|---|---|
| P1 | **Vault kv 2경로 시드** — `kv/prod/kafka/identity-admin` · `kv/dev/kafka/identity-admin`, 키 **`password` 하나**(username 없음 — SCRAM 사용자 이름은 KafkaUser 이름) · 값 = 경로마다 따로 생성한 랜덤 base64url 43자(앞뒤 공백·개행 없음 — UO는 값을 다듬지 않는다 · §4) | **운영자 블록 모노레포 `specs/003-platform-foundation/design/t056-blocks/op1-seed-kafka.ps1`**(블록 하네스 `harness.ps1` 전부 PASS가 실행 조건) · 런북 `docs/runbooks/bootstrap.md` §4 T056 — 2경로 version ≥ 1 · 되읽기 해시 일치 | **머지 전** 운영자 실행 |
| P2 | `Kafka jt-kafka` `Ready=True` + Entity Operator(TO · UO) Ready · operator Deployment 1/1 | `kubectl -n data get kafka jt-kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` = `True` · `kubectl -n data get deploy jt-kafka-entity-operator strimzi-cluster-operator` READY `1/1` · 하네스 `kafka.tests.ps1` kafka-1 · pool-2 PASS | T055 라이브(2026-10-16 · 하네스 7/10/0) |
| P3 | ClusterSecretStore `vault-data`(conditions에 `data`) · **`k8s-data-ca`**(conditions = identity · jt-dev · jt-prod · `remoteNamespace: data`) Ready/Valid | `kubectl get clustersecretstore vault-data k8s-data-ca` → READY True · 하네스 `cluster.tests.ps1` eso-1 PASS(k8s-data-ca의 Ready는 SSRR 1회라 미러 동작의 증거가 아니다 — `platform/secret-stores/clustersecretstore-k8s-data-ca.yaml` 머리 주석) | T045 라이브 |
| P4 | 원본 CA Secret 2 존재 — `data/pg-main-ca`(CNPG operator 생성 · 키 `ca.crt`·`ca.key`) · `data/jt-kafka-cluster-ca-cert`(Strimzi CO 생성 · 키 `ca.crt`·`ca.p12`·`ca.password`) | agent-view는 Secret을 못 읽는다 → 존재 근거 = 모노레포 런북 §3 T053(VD-9 `pg-main-ca`) · §3 T055(운영자 키 목록 `ca.crt · ca.p12 · ca.password`) · 운영자 `kubectl -n data get secret pg-main-ca jt-kafka-cluster-ca-cert` | T053 · T055 라이브 |
| P5 | ns `identity` · `jt-dev` · `jt-prod` 존재(PSA restricted — 이 디렉터리는 파드를 만들지 않으므로 PSA와 무관) | `kubectl get ns identity jt-dev jt-prod` · 하네스 ns-1 PASS | T041 라이브 |
| P6 | agent-view RBAC — ClusterRole `agent-view-extra`: `kafka.strimzi.io` resources `*` · `external-secrets.io` resources `*` get/list/watch(Secret은 못 읽는다 — 의도) | `kubectl auth can-i list kafkausers.kafka.strimzi.io -n data` · `kafkatopics` · `kubectl auth can-i list externalsecrets.external-secrets.io -n jt-dev` → 셋 다 yes | T041 라이브(`platform/policies/rbac-agent-view.yaml` :83–88) |
| P7 | 관문 `bash tests/validate.sh` → `FAIL 0`(검사 1 = 저장소 렌더 CRD 파생 스키마로 KafkaUser·KafkaTopic·ES kubeconform — **한계**: CRD 종류의 미지·오타 필드는 잡지 못한다(계약 §validate.yml 1) → 빌더가 CRD storage 스키마와 잎 전수 대조로 보완 · 3.1–3.4 = ES 경로·store·CA 미러 규칙 · 7.1/7.2 WAVE 유지) | 로컬 `bash tests/validate.sh` · PR의 `validate` | 빌더 실측은 PR 본문(컨트롤러) |

**하네스 · 관문 대조**(값을 바꿀 때 같이 본다):

| 규칙 | 이 디렉터리의 값 |
|---|---|
| validate 3.1(키 정규식 `^(platform\|dev\|prod)/[a-z0-9_./-]+$` — 미러 제외) · 3.3(이 디렉터리 + store `vault-data` → 열거 접두 `{dev,prod}/{db,kafka,dragonfly,openfga}/…`) | `prod/kafka/identity-admin` · `dev/kafka/identity-admin` |
| validate 3.4(store `k8s-data-ca` → key ∈ {`pg-main-ca`, `jt-kafka-cluster-ca-cert`} · property `ca.crt`만 · `dataFrom` 금지) | 미러 5장 전부 `{key: <원본 이름>, property: ca.crt}` · `dataFrom` 0 |
| 하네스 eso-3(ns별 허용 store) | data → `vault-data` ✓ · identity → `k8s-data-ca` ✓(vault-data · vault-platform · k8s-data-ca 허용) · jt-dev → `k8s-data-ca` ✓(vault-dev · k8s-data-ca) · jt-prod → `k8s-data-ca` ✓(vault-prod · k8s-data-ca) · 키 접두 `prod/`·`dev/` ↔ `vault-data` 허용 · 미러 키 ∈ `$caMirrorKeys` |
| 하네스 ca-1(identity · jt-dev · jt-prod의 `pg-main-ca` — Secret get이 no면 **같은 이름의 ES spec**) | dataFrom 없음 · secretKey = property = `ca.crt` · key `pg-main-ca` · template 없음(template data 키 · templateFrom · mergePolicy 모두 없음) · store `k8s-data-ca` → 조건 전부 충족 |
| 하네스 topic-1(이름 = `spec.topicName` 없으면 `metadata.name` · Ready · partitions 3 · replicas 1 · retention.ms 604800000 · 같은 이름 중복 FAIL) | 4장 · 이름 = metadata.name · 숫자 표기 |
| 하네스 user-1(정확히 1개 · Ready · scram-sha-512 · simple · `status.secret` 있음) · user-2(Test-AclWritesPrefix — 자기 접두를 덮는 topic Write 있음 · 교차 접두를 덮는 topic Write 없음) | `identity-admin`: ACL prefix `identity-admin.`은 자기 접두와 같고 `dev.`와 서로 접두가 아니다 ✓ · `dev-identity-admin`: `dev.identity-admin.` ↔ 교차 `identity-admin.` 서로 접두가 아니다 ✓ · 다른 pod에서도 교차 env가 접두 형태로 막힌다(pod 이름 규칙 아래에서 — §6 · 하네스 user-2는 이 두 사용자만 본다) · group ACL은 topic이 아니라 판정 밖 · `type` 생략 = allow(자기 접두 후보) |

---

## 1. 첫 배포에서 일어나는 순서

root(app-of-apps)가 `platform-kafka-topics`를 이미 만들어 두었고(T041 — 지금은 렌더 0 · Synced/Healthy), 머지하면 자동 sync가 13장을 **리소스 wave 순서로** 적용한다.
Argo는 wave N의 리소스가 전부 Healthy가 된 뒤 N+1을 적용한다.

| 단계 | 리소스 wave | 무슨 일이 일어나는가 | 예상 시간(VD-1–VD-3로 실측) |
|---|---|---|---|
| ① | `0` 비밀번호 ES 2 | SSA 적용 → ESO가 `vault-data`로 kv를 읽어 Secret `kafka-user-<이름>`(키 `password`)을 만든다 → ES `Ready=True`(SecretSynced) → Argo health Healthy. kv가 비었으면 `SecretSyncedError` → Degraded → 이 시도는 Failed(아래 증상표 첫 행) | 초(T054 ES 6장: 적용 → SecretSynced 수 초) |
| ② | `1` KafkaUser 2 · KafkaTopic 4 · CA 미러 ES 5 | 11장 SSA 적용. **마지막 wave**라 적용 직후 operation이 **Succeeded**로 닫힌다(뒤에 기다릴 wave가 없다 — T055 README §1의 gitops-engine `sync_context.go` 경로 · T055 실측: Kafka Ready 전에 Succeeded). Application health는 아래 ③이 끝날 때까지 Progressing일 수 있다 | 초 |
| ③ | — | **UO**: KafkaUser 이벤트 → 같은 ns의 Secret `kafka-user-<이름>`에서 `password`를 읽는다 → Kafka Admin API로 SCRAM-SHA-512 자격 · ACL 4행(topic Read·Write·Describe + group Read) · 자격 Secret `<이름>`(`password` + `sasl.jaas.config`) → `status.secret` · `status.username` · `Ready=True`. **TO**: KafkaTopic 이벤트(배치) → finalizer 추가 → 토픽 생성(partitions 3 · RF 1 · config 3키) → `status.topicName` · `status.topicId` · `Ready=True`. **ESO**: `k8s-data-ca`로 원본 Secret의 `ca.crt`를 읽어 미러 Secret 5장 → `Ready=True` | 초 단위(VD-2 · VD-3) — 실패하면 UO/TO는 주기 조정(기본 2분 — UserOperatorConfig.java :87 · TopicOperatorConfig.java :48)으로 다시 시도한다 |
| ④ | — | 13장 전부 Healthy → Application `Synced/Healthy`. 하네스 topic-1 · user-1 · user-2 · ca-1 PASS 후보(§2) | — |

**Argo health 매핑**(v3.5.2 내장 — 원문 확인 2026-10-16 · 각 21줄/20줄):
- `kafka.strimzi.io/KafkaUser`·`KafkaTopic` health.lua: 조건 순회 중 `NotReady`=True → **Degraded**(message = 조건 message) · `Ready`=True → Healthy · 그 밖(status 없음 · `Ready`=False 포함) → **Progressing** "Waiting for Kafka User/Topic". Kafka health.lua와 달리 `Creating` 예외가 없다.
- **UO는 실패를 `NotReady`=True로 쓴다**(reason은 래퍼 `ExecutionException`(조정 시간 초과면 `TimeoutException`) — 원인은 message의 `InvalidResourceException` 문구(예: `Secret kafka-user-… in namespace data not found`) 같은 원래 예외 · UserControllerLoop.java :122–131 · StatusUtils.java :104–110 · :172–173 · KafkaUserOperator.java :258–261) → KafkaUser 실패는 **Degraded**. 원인은 reason이 아니라 message로 가른다(T098 알림도 같다 — §6).
- **TO는 실패를 `Ready`=False로 쓴다**(reason · message — BatchingTopicController.java :902–919 · 성공은 :867–880 `Ready`=True) → KafkaTopic 실패는 Argo에서 **Degraded가 아니라 Progressing으로 남는다**. KafkaTopic이 오래 Progressing이면 조건의 reason/message를 본다(아래 증상표).
- `external-secrets.io/ExternalSecret` health.lua: `Ready`=False → Degraded · `Ready`=True → Healthy · 그 밖 Progressing.
- 그래서 이 Application에는 계약 §Application 규약 예외(`ApplyOutOfSyncOnly` · `retry`)가 **없다**(컨트롤러 결정 D6): hook이 없고, Degraded를 낼 수 있는 wave 1의 셋은 마지막 wave라 operation을 실패시키지 않는다.
  앞 wave를 막는 유일한 경로는 wave 0 비밀번호 ES의 `SecretSyncedError`(kv 미시드)이고, 그것은 **머지 전 시드(P1)**로 막는다. CA 미러 ES를 wave 0에 두지 않는 이유도 같다(결정 D7 — 미러의 Degraded가 KafkaUser·KafkaTopic 적용을 막지 않게).

**어디서 멈추면 무엇을 보는가**(agent-view로 되는 명령만 — 관리자 kubeconfig가 필요한 조치는 그렇게 적었다):

| 증상 | 가장 먼저 볼 것 | 원인 후보 | 조치 |
|---|---|---|---|
| **wave 0 비밀번호 ES 실패** — operation이 두 상태로 보인다(리뷰 r2 O8): ⓐ **재시도 대기**(머지 뒤 ≈ 5분 동안 폴러 · 운영자가 보는 상태 — 메시지의 `at <시각>`은 증가 전 값(:1622)이라 실제 재시도보다 이르다) = `operationState.phase` **`Running`**(`finishedAt` 있음) · message `one or more synchronization tasks completed unsuccessfully. Retrying attempt #<n> at <시각>.`(Argo CD v3.5.2 `controller/appcontroller.go` :1619–1632 — 실패한 시도를 Running으로 되돌리고 FinishedAt을 찍는다 · 문구 앞부분은 gitops-engine `sync_context.go` :638) ⓑ **재시도 5회 소진** = phase **`Failed`** · message `… completed unsuccessfully (retried 5 times).`(:1633–1639) + Application 조건 `SyncError` `Failed last sync attempt to <rev>: …`(:2392 — 자동 sync가 같은 리비전을 다시 시도하지 않는다). 두 상태 모두 `.status.operationState.syncResult.resources[?(@.kind=="ExternalSecret")].message` = `could not get secret data from provider`(ES health 문구가 여기에만 남는다 — `sync_context.go` :562–567) · ES 조건 reason `SecretSyncedError` · 실제 원인 문구는 ES Event(`UpdateFailed` — ESO v2.10.0 `externalsecret_controller.go` :86 · :417–420 · :802–810) · wave 1(KafkaUser · KafkaTopic · 미러)이 **없다**. **둘째 행(operation `Running`이 오래 계속)과 가르는 법**: 비밀번호 ES에 status가 있으면(`Ready=False` · `SecretSyncedError`) 이 행이다 | `kubectl -n argocd get app platform-kafka-topics -o jsonpath='{.status.operationState.phase} finishedAt={.status.operationState.finishedAt} retry={.status.operationState.retryCount} {.status.operationState.message}{"\n"}{.status.conditions[?(@.type=="SyncError")].message}'` · `kubectl -n data get externalsecret kafka-user-identity-admin kafka-user-dev-identity-admin`(STATUS `SecretSyncedError` · READY `False` — 둘째 행은 빈 칸) · `kubectl -n argocd get app platform-kafka-topics -o jsonpath='{range .status.operationState.syncResult.resources[?(@.kind=="ExternalSecret")]}{.namespace}/{.name} {.message}{"\n"}{end}'` · `kubectl -n data describe externalsecret kafka-user-identity-admin` Events | **kv 미시드**(Events `Secret does not exist` — vault provider 문면 · `platform/secrets/README.md` §1 표) · kv 필드 이름 불일치(`cannot find secret data for key: "password"`) · `permission denied`/403(Vault 정책 — eso-data는 `{dev,prod}/kafka/*` 열거) · store 없음 | 고칠 곳은 **kv**(P1). 시드 뒤 런북 §4 T056 「늦은 시드」: 관리자 kubeconfig로 ES 2장에 `force-sync=<epoch>` 어노테이션 → agent-view로 2장 `SecretSynced` 확인(ESO 지수 백오프를 기다리지 않는다) → 기본 retry(limit 5 · 5s ×2 · 최대 3m — 대기 10·20·40·80·160 s ≈ 5분)를 다 썼으면(ⓑ — "Skipping auto-sync: failed previous sync attempt … will not retry" — 계약 §Application 규약) **운영자 전체 수동 Sync**(리소스 선택 없음) |
| operation **`Running`이 오래 계속**(Failed도 Succeeded도 아니다) · 비밀번호 ES 2(wave 0)에 **status가 없다**(READY 빈 칸) · Application Progressing | `kubectl -n data get externalsecret kafka-user-identity-admin kafka-user-dev-identity-admin`(READY 빈 칸) · `kubectl -n external-secrets get deploy external-secrets`(READY) · `kubectl -n external-secrets logs deploy/external-secrets --since=10m` | ESO 컨트롤러 정지·재시작 반복(Deployment `external-secrets` READY 0/1 · CrashLoop) — ES를 조정하지 않아 health가 Progressing에 머문다. sync 타임아웃 기본값이 0이라(Argo v3.5.2 `argocd_application_controller.go` :280 — 이 저장소는 설정하지 않았다) Argo는 wave 0이 Healthy가 될 때까지 **기다리기만 한다**(`sync_context.go` :573–597) | ESO를 먼저 살린다(`platform/external-secrets/` · Application `platform-external-secrets`) → ES가 `SecretSynced`가 되면 같은 operation이 이어 간다(wave 1 적용 → Succeeded) |
| KafkaUser `NotReady`=True · Application **Degraded** | `kubectl -n data get kafkauser identity-admin -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'` | message에 `Secret kafka-user-<이름> in namespace data not found`(ES 미동기 · 이름 오기 — KafkaUserOperator.java :353–368) · `does not contain the key password`(키 이름) · `The requested user password is empty.`(KafkaUserModel.java :347–364) · `Simple authorization ACL rules are configured but not supported`(Kafka CR 인가가 simple이 아님 — :133–139) · Kafka 연결·Admin API 오류(브로커 미준비) | Secret 문제 → 위 ES 행 · 이름 오기 → 파일 PR · 브로커/EO 미준비 → P2 확인 뒤 UO 주기 조정(≤ 2분)을 기다린다 · UO 로그 `kubectl -n data logs deploy/jt-kafka-entity-operator -c user-operator --since=10m` |
| KafkaUser에 **status가 아예 없다**(READY 빈 칸) · Application Progressing "Waiting for Kafka User" | `kubectl -n data get kafkauser -o wide`(CLUSTER 열) · UO 로그 | 라벨 `strimzi.io/cluster: jt-kafka` 누락·오기(UO 선택자 밖 — EntityUserOperator.java :104 · :199 · UserController.java :94–95 · :112) · UO 파드 미기동 | 라벨을 파일에서 고쳐 PR · EO 파드 상태(T055 README §1 EO 행) |
| KafkaTopic이 오래 **Progressing**(Degraded가 아니다) · `Ready`=False | `kubectl -n data get kafkatopic -o 'custom-columns=N:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason,MSG:.status.conditions[?(@.type=="Ready")].message'` · TO 로그 `kubectl -n data logs deploy/jt-kafka-entity-operator -c topic-operator --since=10m` | reason `KafkaError`(브로커·인가) · `NotSupported`(파티션 감소 · 복제 수 변경(Cruise Control 없음) · `spec.topicName` 변경 — BatchingTopicController.java :690–692 · :780–786 · :699–706) · `ResourceConflict`(같은 토픽을 두 CR이 선언 — :382–406) · 같은 이름의 토픽이 **다른 설정으로 이미** 있으면 TO가 CR 쪽으로 맞추려 한다(파티션이 더 많으면 NotSupported) | 선언 오류 → 파일 PR(되돌릴 수 없는 변경은 새 토픽 = 새 CR) · 브로커 문제 → T055 README §1 |
| KafkaTopic에 **status가 아예 없다** · Progressing "Waiting for Kafka Topic" | `kubectl -n data get kafkatopic -o wide`(CLUSTER 열) | 라벨 `strimzi.io/cluster` 누락·오기 → TO가 **무시**한다(BatchingTopicController.java :262–268 · EntityTopicOperator.java :117 · :190) · TO 미기동 | 라벨을 파일에서 고쳐 PR |
| KafkaTopic 삭제가 **Terminating에 멈춤**(Application cascade · 수동 삭제 · ns 삭제) | `kubectl -n data get kafkatopic <이름> -o jsonpath='{.metadata.deletionTimestamp} {.metadata.finalizers}'` | TO finalizer `strimzi.io/topic-operator`를 TO가 떼지 못한다 — TO가 멈춰 있다(KubernetesHandler.java :24 · 업스트림 `con-deleting-managed-topics.adoc`) | 먼저 TO를 살린다(삭제가 끝나면 **토픽도 지워진다**). TO를 살릴 수 없을 때만 finalizer 제거(업스트림 `con-removing-topic-finalizers.adoc` · research STRIMZI-D11 — 관리자) — 그러면 **Kafka 토픽은 남는다**(Strimzi 1.2.0 `BatchingTopicController.java` :119–131 · :187–207 · :272–274 — 토픽 삭제는 TO가 KafkaTopic 삭제 경로를 처리할 때만 일어나고, CR 없는 토픽을 정리하는 경로가 없다 · 업스트림 WARNING과 일치) · §5 |
| CA 미러 ES **Degraded**(`SecretSyncedError`) · Application Degraded(operation은 Succeeded) | `kubectl -n jt-dev describe externalsecret jt-kafka-cluster-ca-cert` Events | `secrets "<이름>" is forbidden`(Role `eso-ca-reader`의 resourceNames 밖 — 이름 오기) · `not found`(원본 Secret 없음 — P4) · `property ca.crt does not exist in data of secret`(ESO client.go :448–468) · store `k8s-data-ca` NotReady · ns가 store `conditions.namespaces` 밖 | 이름 → 파일 PR · 원본 없음 → T053/T055 산출물 확인(Kafka CR 재생성이면 새 CA — T055 README §5) · RBAC/store → `platform/external-secrets/rbac-eso-ca-reader.yaml` · `platform/secret-stores/` |
| 미러 Secret에 **`ca.key`가 있다**(하네스 T031 ca-1 FAIL · 운영자 키 목록) | 운영자 `kubectl -n <ns> get secret pg-main-ca -o 'go-template={{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'` | `property`가 빠졌거나(빈 property = 원본 전체를 JSON 한 덩어리로 — ESO client.go :55–77) `dataFrom`을 썼다 — validate 3.4가 막아야 했던 것 | **보안 사고**로 다룬다: 선언 정정 PR(property `ca.crt`) → ESO가 Secret을 키 하나로 다시 쓴다(creationPolicy Owner) → CA 개인키가 노출됐으므로 CNPG CA 재발급 여부를 컨트롤러·사용자가 결정(서버·`streaming_replica` 인증서 위조 가능 — 계약 §공통 규칙 CA 미러 문장) |
| Application `Synced` 대신 **영구 `OutOfSync`** | `kubectl -n argocd get app platform-kafka-topics -o jsonpath='{.status.resources[?(@.status=="OutOfSync")]}'` | TO가 단 finalizer · UO/TO의 status · ESO/CRD 기본값이 SSA diff로 남는 경우(VD-8 — 소스 판독상 status·다른 매니저 필드는 diff 밖) | VD-8 기록 → 영구면 1차 조치 `ServerSideDiff=true`(계약 예외 문단 개정 뒤 — 컨트롤러 · T053 VD-11 · T054 VD-7과 같은 질문) |

---

## 2. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다. **라이브 클러스터 접근 없이 작성했다**(빌더는 KUBECONFIG 없음 — 기대값은 렌더·CRD·업스트림 소스에서 왔다).

```powershell
kubectl -n argocd get app platform-kafka-topics -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status} {.status.operationState.phase} retry={.status.operationState.retryCount}'
#   <머지 sha 40자> Synced Healthy Succeeded retry=   (빈 값 = 0 — `retryCount`는 omitempty(Argo v3.5.2 types.go :1465) · 1도 정상 — T055 VD-1: 첫 배포 재시도는 Events에 남지 않는다 · 컨트롤러 로그로 사유 확인 · VD-1)
#   리비전이 머지 sha가 아니면 아직 옛 상태(T041 뼈대도 Synced/Healthy다 — 모노레포 build-notes T045 G1 교훈)
(kubectl -n argocd get app platform-kafka-topics -o json | ConvertFrom-Json).status.resources | Group-Object kind,namespace | Select-Object Name,Count
#   ExternalSecret, data 2 · ExternalSecret, identity 1 · ExternalSecret, jt-dev 2 · ExternalSecret, jt-prod 2 · KafkaTopic, data 4 · KafkaUser, data 2 = 13 · 전부 Synced
kubectl get externalsecret -A -o 'custom-columns=NS:.metadata.namespace,N:.metadata.name,STORE:.spec.secretStoreRef.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason' | Select-String -Pattern 'kafka-user-|pg-main-ca|jt-kafka-cluster-ca-cert'
#   7행 · READY True · REASON SecretSynced — data/kafka-user-identity-admin · data/kafka-user-dev-identity-admin(vault-data) · {identity,jt-dev,jt-prod}/pg-main-ca · {jt-dev,jt-prod}/jt-kafka-cluster-ca-cert(k8s-data-ca)
kubectl -n data get kafkauser -o wide
#   identity-admin · dev-identity-admin — CLUSTER jt-kafka · AUTHENTICATION scram-sha-512 · AUTHORIZATION simple · READY True
kubectl -n data get kafkauser identity-admin dev-identity-admin -o jsonpath='{range .items[*]}{.metadata.name} secret={.status.secret} username={.status.username}{"\n"}{end}'
#   identity-admin secret=identity-admin username=identity-admin · dev-identity-admin secret=dev-identity-admin username=dev-identity-admin   (하네스 user-1 — status.secret)
kubectl -n data get kafkatopic -o 'custom-columns=N:.metadata.name,P:.spec.partitions,R:.spec.replicas,RET:.spec.config.retention\.ms,READY:.status.conditions[?(@.type=="Ready")].status,TOPIC:.status.topicName,ID:.status.topicId,FIN:.metadata.finalizers'
#   4행 · 3 · 1 · 604800000 · True · 토픽 이름 = CR 이름 · topicId 있음 · [strimzi.io/topic-operator]   (VD-3)
kubectl -n jt-dev get externalsecret pg-main-ca jt-kafka-cluster-ca-cert -o jsonpath='{range .items[*]}{.metadata.name} store={.spec.secretStoreRef.name} data={.spec.data[*].secretKey}/{.spec.data[*].remoteRef.property} dataFrom={.spec.dataFrom} template={.spec.target.template}{"\n"}{end}'
#   pg-main-ca store=k8s-data-ca data=ca.crt/ca.crt dataFrom= template= · jt-kafka-cluster-ca-cert store=k8s-data-ca data=ca.crt/ca.crt dataFrom= template=   (하네스 ca-1이 ES spec으로 판정하는 조건)
kubectl auth can-i list kafkausers.kafka.strimzi.io -n data; kubectl auth can-i list kafkatopics.kafka.strimzi.io -n data; kubectl auth can-i get secrets -n jt-dev
#   yes · yes · no   (P6 — 마지막 no 때문에 ca-1은 Secret이 아니라 ES spec으로 증명한다)
```

**운영자 전용**(admin kubeconfig — **키 이름만** 출력한다. 값은 화면·파일·argv에 두지 않는다 — `-o jsonpath='{.data}'`처럼 값을 찍는 형태는 금지):

```powershell
kubectl -n data get secret identity-admin dev-identity-admin kafka-user-identity-admin kafka-user-dev-identity-admin -o 'go-template={{range .items}}{{.metadata.name}}:{{range $k,$v := .data}} {{$k}}{{end}}{{"\n"}}{{end}}'
#   identity-admin: password sasl.jaas.config · dev-identity-admin: password sasl.jaas.config · kafka-user-identity-admin: password · kafka-user-dev-identity-admin: password   (VD-4)
foreach ($p in 'identity/pg-main-ca','jt-dev/pg-main-ca','jt-prod/pg-main-ca','jt-dev/jt-kafka-cluster-ca-cert','jt-prod/jt-kafka-cluster-ca-cert') { $ns, $n = $p -split '/'; "$p :" + (kubectl -n $ns get secret $n -o 'go-template={{range $k,$v := .data}} {{$k}}{{end}}') }
#   5행 모두 " ca.crt" 하나 — ca.key · ca.p12 · ca.password 없음(VD-5 · T031)
```

- ACL 실적용(VD-6): 브로커 파드 안 `kafka-acls.sh --list`(관리자 · 복제 리스너 9091의 TLS 자격 — T055 README §5 superUsers 행이 가리키는 경로 · 명령 형태는 런북 후속). 기대 = `User:identity-admin`에 `TOPIC` PREFIXED `identity-admin.` Read·Write·Describe + `GROUP` PREFIXED `identity-admin-` Read, `User:dev-identity-admin`에 `TOPIC` PREFIXED `dev.identity-admin.` Read·Write·Describe + `GROUP` PREFIXED `dev-identity-admin-` Read — 사용자당 4행 · 그 밖의 사용자 행 0.

**모노레포 하네스**(KUBECONFIG = agent-view · 한 번에 하나만 · 단언 id를 세어 확정한 기대값):

```powershell
pwsh -NoProfile -File tests/platform/kafka.tests.ps1
#   7/10/0 → 기대 10 PASS(gate-1..3 · kafka-1 · kafka-2 · pool-1 · pool-2 · topic-1 · user-1 · user-2) / 7 FAIL(df-1 · df-2 = T057 · job-k-1 · job-k-2 · job-k-3 · job-d-1 · job-d-2 = T059) / 0 SKIP
#   = 단언 17 중 T056 몫 3(topic-1 · user-1 · user-2)이 PASS로 바뀐다. UO/TO 조정 전이면 topic-1 · user-1(Ready · status.secret)이 FAIL — Ready 뒤 재실행
#   user-2 대조(선언만으로 정해진다): identity-admin = topic prefix `identity-admin.`(자기 접두와 같음 · `dev.`와 서로 접두 아님) · dev-identity-admin = `dev.identity-admin.`(자기 접두와 같음 · `identity-admin.`과 서로 접두 아님) → 둘 다 "topic Write on <자기 접두>* only (1 of 2 ACLs)"
pwsh -NoProfile -File tests/platform/cluster.tests.ps1
#   41/0/13 → 기대 42/0/12: ca-1 SKIP → PASS(identity·jt-dev·jt-prod의 pg-main-ca 미러 ES spec). 유지돼야 하는 것: eso-2(ExternalSecret 전부 SecretSynced — 이 PR의 7장 포함 · kv 미시드면 FAIL) ·
#   eso-3(ns별 store · 키 접두) · argo-1(Application 전부 Synced/Healthy — platform-kafka-topics 포함). 남는 SKIP 12 = 운영자 수동 5 · np-2-* 3(T059 · T085) · limits-* 2(T075) · mon-1(T098) · argo-4-dragonfly(T057)
```

---

## 3. VD(검증 후 결정 — 머지 뒤 실측해 기록)

| ID | 무엇을 | 판정 |
|---|---|---|
| VD-1 | Argo operation 전이 — `operationState.phase`(Running → Succeeded) · `retryCount` · wave 0 → 1 간격(ES SecretSynced) · Application health 전이(Progressing → Healthy) · 머지 → Synced/Healthy 소요. 정본 = `kubectl -n argocd get events --field-selector involvedObject.name=platform-kafka-topics`(**Events TTL 1h** — 머지 뒤 1시간 안에 `-o json` 저장) + 폴러의 `operationState.message` 매 틱 기록(**재시도는 Events에 남지 않는다** — T055 교훈) | `retryCount` 0 또는 1 · Degraded 전이 0 · history 1이면 결정 D6(예외 없음) 유효. Failed · `retryCount` ≥ 2 · 두 번째 operation이면 사유(§1 표)와 함께 컨트롤러에 — 예외가 필요한지 재검토 |
| VD-2 | **KafkaUser Ready 소요** — CR 생성 → `Ready=True`(UO 로그 `reconciled` 시각) · `status.secret` · `status.username` | 초 단위면 그대로. 2분 이상이면(주기 조정을 탔다) 첫 조정의 실패 사유를 UO 로그에서 기록 |
| VD-3 | **KafkaTopic Ready · topicId** — `Ready=True` · `status.topicId` 있음 · finalizer `strimzi.io/topic-operator` · Argo health 경로(Progressing → Healthy · Degraded 없음 — TO는 실패를 Ready=False로 쓴다 · §1) | 4장 전부면 그대로. Ready=False면 reason/message 기록(§1 증상표) |
| VD-4 | **UO 자격 Secret 키**(운영자 — 이름만) = `password` · `sasl.jaas.config` · 비밀번호 Secret 키 = `password` 하나(template 없음의 효과) | 기대와 같으면 그대로. 비밀번호 Secret에 다른 키가 보이면 ESO 동작이 소스 판독과 다르다는 기록 |
| VD-5 | **미러 Secret 키 = `ca.crt`만**(운영자 직접 — 또는 agent-view로는 ES spec · 하네스 ca-1) · 5장 | `ca.key`가 하나라도 보이면 §1 증상표의 보안 사고 행 |
| VD-6 | **ACL 실적용**(운영자 `kafka-acls.sh --list` — §2) — 사용자당 4행(topic prefix Read·Write·Describe + group prefix Read) · 교차 env 행 0 | 기대와 같으면 그대로. 다르면 UO 로그(`SimpleAclOperator`)와 함께 기록 |
| VD-7 | **IdempotentWrite 불필요**(KIP-679) — T059 검사 Job `kafka-assert`의 roundtrip produce 성공 + cross-env-denied가 `TopicAuthorizationException`(**`ClusterAuthorizationException`이 아님**) | 성공이면 cluster ACL 0 확정. `ClusterAuthorizationException`(InitProducerId 거부)이면 `cluster` `IdempotentWrite` 행 추가 PR(컨트롤러 결정) |
| VD-8 | **Synced 안정** — TO finalizer 추가 · UO/TO status 쓰기 · ESO/CRD 기본값 주입 뒤 15분 간격 2회 `Synced` · KafkaUser/KafkaTopic resourceVersion 변화 기록 · Application 조건 `OrphanedResourceWarning` 수가 머지 전과 같은가(새 런타임 Secret은 ownerReference가 있어 고아가 아니라고 본다 — 판독) | 안정이면 그대로. 영구 OutOfSync면 필드 기록 → 1차 조치 `ServerSideDiff=true`(계약 예외 문단 개정 뒤) |
| VD-9 | **회전 경로**(후속 — T084): kv 교체 → ES ≤ 5분 Secret 갱신 → UO 다음 주기 조정(≤ 2분 — 이 Secret은 UO 감시 라벨 밖이라 이벤트로 깨지 않는다) → Kafka SCRAM 자격 갱신 · 앱 `<pod>-env`도 ≤ 5분(Reloader 롤아웃) — 그 사이 옛 비밀번호 클라이언트의 인증 실패 창 | 이번 PR에서는 실측하지 않는다(값 회전 없음). T084가 순서·창을 실측해 `secret-rotation.md`에 기록 |

---

## 4. 값 선택 근거

| 값 | 출처 | 비고 |
|---|---|---|
| 토픽 4 이름 · `metadata.name` = 토픽 이름 · `spec.topicName` 없음 | tasks.md T056 문면 · data-model §6 토픽 이름 행 · CRD 043 `topicName` 설명("It is recommended to not set this unless the topic name is not a valid Kubernetes resource name") · 컨트롤러 결정 D4 | 넷 다 DNS 서브도메인으로 유효. 생성 뒤 이름 변경은 TO가 거부(`NotSupported`) — 새 이름 = 새 CR |
| partitions 3 · replicas 1 · `retention.ms 604800000` · `cleanup.policy delete` · `min.insync.replicas 1` | data-model §6 파티션·보존·복제 행 · research STRIMZI-D6 · 과제 문면 | 숫자 표기(CRD `config`는 preserve-unknown 자유 객체 · 하네스는 문자열/숫자 둘 다 받는다). 파티션은 늘릴 수만 있다 · 복제 수 변경은 Cruise Control 필요(이 클러스터에 없다) |
| KafkaUser 이름 `identity-admin` · `dev-identity-admin` | data-model §6 사용자 행(`<pod>` · `dev-<pod>`) · 하네스 user-1/2 · Kafka CR `superUsers` 없음(T055) | SCRAM 사용자 이름 = CR 이름(UO `getScramUserName` — 접두 없음) |
| ACL ⓐ topic **prefix** `identity-admin.` / `dev.identity-admin.` · Read · Write · Describe | data-model §6 ACL 행(2026-10-16 정정 — 모노레포 `9442b14`: 자기 접두 Read·Write·Describe · dev/prod 대칭) · research STRIMZI-D6(prefix `<env>.<pod>.`) · 컨트롤러 결정 D3 | 접두 하나가 자기 토픽과 DLQ를 함께 덮는다. 자기 접두의 Read는 계약이 dev·prod 대칭으로 둔다(검사 Job 왕복 · DLQ 점검 — 자기가 낸 이벤트를 읽는 권한이라 새 데이터 노출이 아니다 · 정정 전 문구 「자기 토픽 Write·Describe · 구독 Read·Describe · DLQ Write」). literal이 아닌 prefix인 이유 = 같은 pod의 다음 이벤트 토픽(SP-2)이 ACL 변경 없이 덮인다 · 교차 env는 접두 형태로 막힌다(pod 이름 규칙 아래에서 — §6) — prod `identity-admin.` ↔ dev `dev.…` 서로 접두가 아니다 |
| ACL ⓑ group **prefix** `identity-admin-` / `dev-identity-admin-` · Read | data-model §6 ACL 행(2026-10-16 정정 — 모노레포 `9442b14`: 그룹 접두 prod `<pod>-` · dev `dev-<pod>-`) · 컨트롤러 결정 D3 · 검사 Job ConfigMap `KAFKA_GROUP` `dev-identity-admin-assert` | Kafka ACL은 `*` 와일드카드 접미를 prefix 패턴으로 표현한다. Read는 그룹 Describe를 함의한다(컨슈머 · `kafka-consumer-groups --describe`). prod·dev 그룹 접두가 서로 겹치지 않는다(`dev-`로 시작하는 이름은 `identity-admin-`으로 시작하지 않는다) · 구분자 `-`가 pod 이름에도 쓰이는 문제와 env 접두(`dev` · `dev-`)와 겹치는 pod 이름 문제는 §6 SP-2 |
| Create · IdempotentWrite · cluster · transactionalId · deny · quotas 없음 | research D6("토픽을 CR로 선언하므로 Create ACL 불필요") · Kafka `auto.create.topics.enable: "false"`(T055) · KIP-679(Kafka 4.3.1 `KafkaApis.scala` :1616–1620) | 기본 idempotent 프로듀서의 `InitProducerId`는 cluster `IdempotentWrite` **또는** 아무 topic의 `Write`면 허용 → cluster ACL 불필요(VD-7로 라이브 확정) · 트랜잭션은 SP-1에 없다 |
| `type` 생략(기본 allow) · `host: "*"` 명시 | 1.2.0 `api/…/user/acl/AclRule.java` :37(type 기본 ALLOW) · :39(host 기본 `*`) · CRD 044 설명 | 하네스 user-2는 type이 없거나 `allow`일 때만 자기 접두 후보로 센다 |
| 비밀번호 ES 이름 `kafka-user-<KafkaUser 이름>` | 컨트롤러 결정 D2 · Strimzi KafkaUserModel.java :497–499 · :517–519(UO 자격 Secret 이름 = KafkaUser 이름 · 접두 "") | 같은 이름이면 ESO와 UO가 한 Secret을 번갈아 덮어쓴다. 이 Secret에 `strimzi.io/kind: KafkaUser` 라벨을 붙이면 UO가 "그 이름의 KafkaUser가 없는 사용자"로 보고 지운다(UserController.java :97–100 · :145–155 · KafkaUserOperator.java :190–199 · :209–218 — §5) |
| **KafkaUser(ns data) 쓰기 = UO를 통한 ns data Secret 권한**(받아들인 경계 · 리뷰 r1 K1) — `secretKeyRef.name` = `kafka-user-<metadata.name>` 고정 · KafkaUser 이름은 ns data의 기존 Secret 이름과 겹치지 않게 | CRD 044 `secretKeyRef` 설명 "Selects a key of a Secret in the resource's namespace" · 차트 `031-ClusterRole-strimzi-entity-operator.yaml`(secrets get·list·watch·create·delete·patch·update · resourceNames 없음) → ns data RoleBinding `strimzi-cluster-operator-entity-operator-delegation` → operator가 Role `jt-kafka-entity-operator`로 EO SA에 위임(T055 README §4 RBAC 행) · `platform/kafka/kafka-jt-kafka.yaml` userOperator에 `secretPrefix` 없음(UserOperatorConfig.java :95 기본 "") | ① `password.valueFrom.secretKeyRef`는 ns data의 **임의 Secret**을 가리킬 수 있고 UO는 그 값을 SCRAM 비밀번호로 써 자격 Secret에 복사한다(KafkaUserOperator.java :296–316 · KafkaUserModel.java :207–211) ② 자격 Secret 이름 = KafkaUser 이름(접두 "") → ns data의 기존 Secret 이름(`pg-main-*` · `jt-kafka-*` · `kafka-user-*` · `oci-s3-backup`)과 같은 이름의 KafkaUser는 그 Secret을 UO 조정 대상으로 만든다 ③ 그래서 ①②를 위 두 규칙으로 막는다 — T055 README §4 K5 「ns data Secret 읽기 = Kafka super user」와 같은 등급 · 이 디렉터리의 PR은 approval-review `k8s-security` 경계 대상 · **막는 관문 없음**(validate에 KafkaUser 규칙 없음 — 후속 후보: `secretKeyRef.name` · 이름 접두 고정 규칙, 컨트롤러 판단) · §5 |
| 비밀번호 ES·미러 ES **template 없음** | 컨트롤러 결정 D2 · D5 · ESO v2.10.0 `externalsecret_controller_template.go` :60–64(template 없음 → Secret 키 = `data[].secretKey`) · :71–75(template.data/templateFrom이 있으면 기본 Replace — Secret 키 = template의 것만) | 키 집합의 단순성을 택했다. 대가: ES 라벨·어노테이션(Argo tracking-id 포함)이 Secret에 복사된다(:147–152) — Argo v3.5.2는 종류·이름이 다른 복사본을 관리 대상으로 세지 않는다(`controller/state.go` :981–985 · :1282–1337). `template.metadata: {}`만 두는 대안(키 유지 + 복사 차단 — :71–75 · :154–156)은 T053 `secrets/data/oci-s3-backup`과 T045 인수형 ES가 쓰는 모양이다 · 하네스 ca-1은 그 대안도 통과시킨다 |
| CA 미러 범위 `pg-main-ca` → identity·jt-dev·jt-prod · `jt-kafka-cluster-ca-cert` → jt-dev·jt-prod · 이름 = 원본 이름 | tasks.md T056 문면 · 계약 §공통 규칙 CA 미러 문장(2026-10-16 정정) · 컨트롤러 결정 D5 | identity에는 Kafka 소비자가 없다. 소비자(검사 Job 2 · 앱 pod)와 하네스 ca-1이 원본 이름으로 찾는다 |
| 미러 `remoteRef.property: ca.crt`만 · `dataFrom` 없음 | 과제 문면 · 계약 · validate 3.4 · ESO v2.10.0 `providers/v1/kubernetes/client.go` :55–77(property가 비면 원본 전체 키를 JSON으로) | CNPG `pg-main-ca`에는 `ca.key`가 있다 — RBAC(`eso-ca-reader` resourceNames)는 객체 단위라 키를 막지 못한다 |
| refreshPolicy Periodic + refreshInterval 5m · creationPolicy Owner | 계약 §공통 규칙 · T054 선례 | 원본 CA 갱신(Strimzi 갱신 · CNPG 재발급)을 ≤ 5분에 따라간다. Strimzi 기본 갱신(`renew-certificate`)은 같은 키로 `ca.crt`만 교체해 끊김이 없고, 키 교체(`strimzi.io/force-replace` · `replace-key`) 때는 구 CA(`ca-<notAfter>.crt`)가 원본 Secret에만 병존해 미러(`ca.crt`만)로 오지 않는다(§5 CA 갱신 추종) |
| 리소스 wave ES `"0"` → KafkaUser · KafkaTopic · 미러 ES `"1"` | 컨트롤러 결정 D7 · T055 README §6 T056 인계(ES → KafkaUser → KafkaTopic 권장) | 비밀번호 Secret이 있어야 KafkaUser가 Ready다. 나머지를 한 wave에 모아 그 wave의 Degraded가 다른 것의 적용을 막지 않게 했다(마지막 wave) |
| 삭제 보호 어노테이션 없음(KafkaTopic · KafkaUser · ES 전부) | 계약 §Application 규약 삭제 보호 목록(KafkaTopic·KafkaUser·ES는 없다) · 컨트롤러 결정 D2–D5 · T054 ES 선례 | Application `prune: false` + `Delete=confirm`이 Argo 경로를 막는다. 수동 삭제의 결과는 §5 |
| Application `platform-kafka-topics` syncPolicy **예외 없음** | 컨트롤러 결정 D6 · §1 health 매핑 | hook 없음 · wave 1이 마지막 wave · wave 0 실패 경로는 P1로 막는다. `clusters/oci-k3s/apps/platform-kafka-topics.yaml`은 머리 주석만 바꿨다 |

**받아들인 사실**(이 PR에서 바꾸지 않는다 · 리뷰 r1 K3):
- store `vault-data`의 `conditions.namespaces`가 [data, identity]라(`platform/secret-stores/clustersecretstore-vault-data.yaml` · Vault 정책 eso-data `kv/data/{dev,prod}/kafka/*` — 모노레포 `infra/vault/policies.tf`) ns identity도 kv `{dev,prod}/kafka/identity-admin`을 ES로 읽을 수 있다(T045 설계 · identity에 vault-data ES 0장 → 노출 0 · 노출하려면 Git PR) —
  후속 T080: validate 3.3 · 하네스 eso-3에 「identity + vault-data → `{dev,prod}/authentik/webhooks/*`만」(모노레포 build-notes 「T056」 K3).

**소스로 확인한 사실**(2026-10-16 · 원문 판독 — **라이브 미실측**). 줄 번호 기준 = Strimzi 태그 `1.2.0` · Argo CD `v3.5.2` · ESO `v2.10.0` · Apache Kafka `4.3.1`.

- **Strimzi UO**(`user-operator/src/main/java/io/strimzi/operator/user/`): 외부 비밀번호 — `KafkaUserOperator.java` :296–316(`password.valueFrom.secretKeyRef`가 있으면 **KafkaUser와 같은 ns**의 그 Secret을 필수로 읽는다 · 없으면 :353–368 `Secret <name> in namespace <ns> not found`) ·
  `model/KafkaUserModel.java` :347–364(키 없음 · 빈 값 → `InvalidResourceException` · 값은 base64 디코드 그대로 — `operator-common/…/Util.java` :301–315 · 다듬지 않는다) · :173–184(secretKeyRef의 name·key 둘 다 필수).
  자격 Secret — :207–211(SCRAM이면 키 `password` · `sasl.jaas.config`) · :385–397(이름 = 접두 + 사용자 이름 · 라벨 · annotation은 template에서만) · :404–413(ownerReference = KafkaUser · `blockOwnerDeletion: true`) · :497–499 · :517–519 ·
  `UserOperatorConfig.java` :95(`STRIMZI_SECRET_PREFIX` 기본 "") · :87(주기 조정 `STRIMZI_FULL_RECONCILIATION_INTERVAL_MS` 기본 120000) · CO `cluster-operator/…/model/EntityUserOperator.java` :104 · :199(`STRIMZI_LABELS` = 클러스터 라벨) · :200–201(주기는 CR에 값이 있을 때만 env로 준다) · :139 · :211(접두).
  감시 — `UserController.java` :94–95 · :112(KafkaUser 선택자) · :97–100 · :109(Secret 선택자 = 그 선택자 + `strimzi.io/kind: KafkaUser`) · :145–155(Secret 이벤트 → Secret 이름과 같은 사용자 조정) · `UserControllerLoop.java` :104–115(KafkaUser가 없으면 삭제 경로) ·
  `KafkaUserOperator.java` :209–226(삭제 = 자격 Secret · ACL · SCRAM 자격 · quotas) · :239–268(조정 실패는 Kafka 반영 전에 끝난다 — 비밀번호 Secret이 사라져도 Kafka 쪽 자격·ACL은 남는다) · :262–263 · :436–445(`status.username` · `status.secret`).
  상태 — `UserControllerLoop.java` :122–131 + `operator-common/…/model/StatusUtils.java` :104–110 · :172–173(실패 = `NotReady`=True · reason = `get()`이 던진 래퍼 예외의 클래스 이름 — 실패는 `ExecutionException` · 시간 초과는 `TimeoutException`(:125) · 원래 예외는 message 안(`KafkaUserOperator.java` :258–261이 `CompletionException`으로 감싼다) · 성공 = `Ready`=True).
  ACL — `api/…/user/acl/AclRule.java` :37 · :39(기본 allow · host `*`) · `user-operator/…/model/acl/SimpleAclRule.java` :144–148(operation마다 1규칙) · CRD 044 enum(authentication.type tls|tls-external|scram-sha-512 · authorization.type simple · resource.type topic|group|cluster|transactionalId · patternType literal|prefix · operations 11 · `operations` 필수 · 단수 `operation` 없음).
  예제 `examples/user/kafka-user.yaml`(producer 예제는 Create·Describe·Write — 이 디렉터리는 Create를 뺀다).
- **Strimzi TO**(`topic-operator/src/main/java/io/strimzi/operator/topic/`): finalizer `KubernetesHandler.java` :24(`strimzi.io/topic-operator`) · :49–60(추가) · `TopicOperatorConfig.java` :72(`STRIMZI_USE_FINALIZERS` 기본 true) · :48(주기 120000) ·
  `BatchingTopicController.java` :262–268(라벨 선택자 밖 = 무시 · CO가 `STRIMZI_RESOURCE_LABELS`를 준다 — `EntityTopicOperator.java` :117 · :190) · :867–880(성공 `Ready`=True) · :902–919(실패 `Ready`=False + reason/message) · :690–692 · :699–706 · :780–786(NotSupported 3종) · :382–406(ResourceConflict) · :812–834(RF < min ISR 경고 — 이 선언은 해당 없음) · :86–93(auto.create가 true면 경고 — T055는 false).
  문서 `documentation/modules/operators/con-deleting-managed-topics.adoc` · `con-removing-topic-finalizers.adoc`(TO가 멈춘 동안 finalizer 제거 뒤 CR을 지우면 Kafka 토픽은 **남는다** — WARNING :34–35) ·
  코드 근거 `BatchingTopicController.java` :119–131 · :187–207 · :272–274(토픽 삭제는 TO가 KafkaTopic 삭제 경로를 처리할 때만 일어나고, CR 없는 토픽을 정리하는 경로가 없다 · 업스트림 WARNING과 일치).
- **Argo CD v3.5.2**: `resource_customizations/kafka.strimzi.io/KafkaUser/health.lua` · `KafkaTopic/health.lua`(각 21줄 — `NotReady`=True → Degraded · `Ready`=True → Healthy · 그 밖 Progressing) · `external-secrets.io/ExternalSecret/health.lua`(20줄 — Ready=False → Degraded · True → Healthy) ·
  `controller/state.go` :941 · :950 · :981–985 · :1282–1337(`isSelfReferencedObj` — tracking-id가 객체 자신과 다르면 sync 상태·prune에서 뺀다) · 이 저장소의 tracking 방식 = annotation(`bootstrap/argocd/argocd-cm.yaml` :39).
- **ESO v2.10.0**: `pkg/controllers/externalsecret/externalsecret_controller_template.go` :60–64 · :71–75 · :147–156(위 표) · kubernetes provider `providers/v1/kubernetes/client.go` :49–80(`remoteRef.key` = 원본 Secret 이름으로 Get · `property` = 그 Secret의 data 키 · 비면 전체 JSON) · :448–468(property 없음 오류 문면) ·
  문서 `docs/provider/kubernetes.md` :9("With it you point to the key of the remote secret. If you leave it empty it will json encode all key/value pairs") · :26(key = Secret 이름 예).
- **Apache Kafka 4.3.1**: `core/src/main/scala/kafka/server/KafkaApis.scala` :1603–1620 `handleInitProducerIdRequest` — 트랜잭션 id가 없으면 cluster `IDEMPOTENT_WRITE` **또는** `authorizeByResourceType(WRITE, TOPIC)`(KIP-679) · 검사 Job 관련 도구 사실은 `platform/policies/tests/README.md` 「검증 기록 (T056)」.
- **렌더 · 관문**(빌더 실측 2026-10-16): `kustomize build` 13장 · CRD storage 스키마(차트 캐시 `strimzi-kafka-operator-1.2.0/crds/043·044` · ESO 렌더의 ExternalSecret v1) 잎 전수 대조 — KafkaUser 2장 잎 32 · KafkaTopic 4장 잎 20(그중 `config` 자유 객체 12) · ES 7장 잎 63 · 불일치 0 · enum 전부 일치 · required 41개 충족 · 음성 대조 5종(미지 필드 `operation` · `partition` · enum `Prefix` · required `type` 누락 · 타입 `"1"`) 전부 검출 · `bash tests/validate.sh` FAIL 0(수치는 PR 본문).
  모노레포 하네스 `kafka.tests.ps1`의 **판정 본문 자체**(`ClusterAssert 'topic-1'` · `'user-1'` · `'user-2'` — AST로 읽어 실행 · 파일 수정 0 · 조회만 렌더로 바꿔 끼움)를 렌더 13장에 적용:
  렌더 그대로 = user-2 **PASS**("identity-admin: topic Write on identity-admin.* only (1 of 2 ACLs); dev-identity-admin: topic Write on dev.identity-admin.* only (1 of 2 ACLs) -- no cross-env Write") ·
  topic-1 · user-1은 status가 없어 FAIL("no Ready condition" · "status.secret empty" — 그 밖의 문제 0) / UO·TO 조정 성공을 흉내 낸 status(Ready=True · `status.secret`)를 주입한 사본 = 셋 다 **PASS**
  (partitions 3 · replicas 1 · retention.ms 604800000 · scram-sha-512 · simple — 하네스의 정확 일치 비교를 선언 표기가 통과한다) · 음성 대조(prod 사용자에 literal `*` Write 추가) = user-2 FAIL "also covers dev.* (cross-env)".

---

## 5. 운영 위험 · 되돌리기

Application `platform-kafka-topics`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`이고, 13장 어디에도 `Delete=false,Prune=false`가 없다(계약 §삭제 보호 목록 밖). 그래서

> **Git revert는 객체를 지우지 않는다**(렌더 0 → 객체는 남고 Application은 `OutOfSync`가 정상). **삭제는 사람(또는 Application cascade)만 한다 — 그리고 KafkaTopic · KafkaUser의 삭제는 되돌릴 수 없는 Kafka 쪽 삭제를 부른다.**

| 무엇을 지우면 | 무슨 일이 일어나는가 | 되돌리기 |
|---|---|---|
| **KafkaTopic CR** | TO가 **Kafka 토픽을 지운다**(finalizer `strimzi.io/topic-operator` — 그 토픽의 메시지 전부 손실 · retention 7d 안의 이벤트 · 원본은 PG outbox) · TO가 멈춰 있으면 Terminating에 멈춘다(§1 증상표) | CR 재적용(selfHeal 또는 revert의 revert) = **빈 새 토픽**(새 topicId). 소비자 오프셋은 무효 — outbox 재전송(앱 설계 · research D6) |
| **KafkaUser CR** | UO가 SCRAM 자격 · ACL 4행 · 자격 Secret `<이름>`을 지운다(KafkaUserOperator.java :209–226) → 그 사용자로 붙은 앱·검사 Job이 **즉시 인증 실패** | CR 재적용 → UO가 같은 kv 비밀번호(비밀번호 Secret이 남아 있으면)로 자격을 다시 만든다 — 클라이언트는 재접속 |
| **비밀번호 ES** | Secret `kafka-user-<이름>`이 GC된다(Owner) → UO 다음 조정(≤ 2분)에서 KafkaUser `NotReady`(Degraded) — **Kafka 쪽 자격·ACL은 남는다**(조정이 Kafka 반영 전에 실패 — §4 소스) · 앱은 계속 붙는다 | ES 재적용 → Secret 재생성 → UO 다음 조정에서 Ready |
| **CA 미러 ES** | 미러 Secret GC → 그 Secret을 마운트하는 파드는 **다음 기동에 실패**(ContainerCreating — Secret 없음) · 이미 뜬 파드는 영향 없음 | ES 재적용 → ≤ 수 초에 Secret 재생성 |
| **Application**(cascade · finalizer `resources-finalizer.argocd.argoproj.io`) | 위 전부 — 토픽 4 · 사용자 2 · Secret 7 삭제. `Delete=confirm`이라 승인 어노테이션(`argocd.argoproj.io/deletion-approved`)이 한 겹 더 필요하다 | 이 Application을 지우는 일은 하지 않는다(필요하면 컨트롤러 · 사용자 결정 — 데이터 손실 PR로 다룬다) |

**되돌리기 순서**(이 PR을 무르고 객체까지 치워야 할 때 — 운영자 · admin kubeconfig):
1. revert PR 머지 → 렌더 0 → 객체는 남고 `OutOfSync`. **여기서 멈추는 것이 기본이다** — 객체가 남아 있어도 해가 없다(토픽·사용자는 쓰는 곳이 생길 때까지 비어 있다).
2. 지워야 한다면 소비자 0을 먼저 확인한다(T059 검사 Job · 앱 pod가 이 사용자·토픽을 쓰지 않는다).
3. KafkaUser → KafkaTopic → ES 순서로 수동 삭제(토픽 삭제는 데이터 삭제 — 되돌릴 수 없다). TO가 살아 있어야 KafkaTopic 삭제가 끝난다.
4. Vault kv 2경로는 지우지 않는다(값 교체는 회전 절차 — 런북 §4 T056 「정리 판단」은 **머지 전**에만).

**그 밖의 위험**:
- **비밀번호 Secret 이름을 KafkaUser 이름으로 바꾸지 않는다 · `strimzi.io/kind: KafkaUser` 라벨을 붙이지 않는다**: 앞은 ESO와 UO가 한 Secret을 번갈아 덮어쓰고, 뒤는 UO가 그 Secret을 "없는 사용자의 자격"으로 보고 지운다(§4 비밀번호 ES 이름 행).
- **KafkaUser(ns data) 쓰기 = UO를 통한 ns data Secret 권한**(§4 행 · 리뷰 r1 K1): ① `password.valueFrom.secretKeyRef`는 ns data의 **임의 Secret**(`pg-main-*` 자격 · `oci-s3-backup` · Strimzi CA 키 등)을 가리킬 수 있고 UO는 그 값을 SCRAM 비밀번호로 써 자격 Secret에 복사한다
  ② 자격 Secret 이름 = KafkaUser 이름(접두 "")이라 기존 Secret 이름(`pg-main-*` · `jt-kafka-*` · `kafka-user-*` · `oci-s3-backup`)과 같은 이름의 KafkaUser는 그 Secret을 UO 조정 대상으로 만든다 ③ 그래서 `secretKeyRef.name`은 `kafka-user-<metadata.name>`으로 고정하고
  KafkaUser 이름은 기존 Secret 이름과 겹치지 않게 한다. T055 README §4 K5 「ns data Secret 읽기 = Kafka super user」와 같은 등급이다 — 이 디렉터리의 PR은 approval-review `k8s-security` 경계 대상이고, **막는 관문은 없다**(validate에 KafkaUser 규칙 없음 — 후속 후보: `secretKeyRef.name` · 이름 접두 고정 규칙, 컨트롤러 판단).
- **시드 값에 앞뒤 공백·개행을 넣지 않는다**: UO는 Secret 값을 다듬지 않고 그대로 SCRAM 비밀번호로 쓴다(Util.java :301–315). 앱 `<pod>-env`가 같은 kv를 읽으므로 둘은 어긋나지 않지만, 사람이 값을 손으로 옮기면 어긋난다.
- **`superUsers`를 더하지 않는다**(T055 README §5 · 하네스 kafka-2) — ACL을 통째로 우회한다. 관리 작업은 브로커 파드 안 도구로.
- **파티션 감소 · 복제 수 변경 · 토픽 이름 변경은 되지 않는다**(TO `NotSupported` — §1 증상표). 이름을 바꾸려면 새 CR을 더하고 옛 CR 삭제(= 옛 토픽 데이터 삭제)를 별도로 결정한다.
- **CA 갱신 추종**: Strimzi 클러스터 CA는 기본 365일 · 만료 30일 전 자동 갱신(T055 README §5) · CNPG CA 재발급(Cluster 재생성 등)도 원본 Secret이 바뀐다 → 미러는 ESO 5분 주기로 `ca.crt`를 따라간다. Strimzi 갱신은 두 갈래다:
  ⓐ **기본 갱신**(`renew-certificate` — T055 Kafka CR은 `clusterCa`를 두지 않아 이것) = 키를 유지한 채 `ca.crt`만 교체 — 같은 키라 구 서버 인증서도 새 `ca.crt`로 검증된다 → 미러가 5분 안에 따라가고 끊김 없음.
  ⓑ **키 교체**(`strimzi.io/force-replace` 어노테이션 또는 `spec.clusterCa.certificateExpirationPolicy: replace-key`) = 원본 Secret에만 구 CA가 `ca-<notAfter>.crt`로 병존 → 미러는 `ca.crt`뿐이라 구 CA가 오지 않는다 → 브로커 롤링이 끝나기 전에 재접속·truststore 재로드한 소비자는 **TLS 실패 창**.
  ⓒ 키 교체는 T084 · `secret-rotation.md`(후속) 절차로 다룬다(예: 롤링 완료 뒤 소비자 재시작 · 또는 그 기간만 원본의 구 CA 항목도 미러 — validate 3.4가 `property: ca.crt`만 허용하므로 계약 개정이 먼저).
  근거 Strimzi 1.2.0 `operator-common/…/ca/InternalCa.java` :442–462(REPLACE_KEY만 구 `ca.crt`를 `ca-<notAfter>.crt`로 옮긴다 · RENEW_CERT는 새 인증서 맵) · :729–739(renew = 기존 `ca.key`로 재서명) · `Ca.java` :159–162 · :621–630(구 인증서 패턴 — "mostly used when a CA certificate is renewed by replacing the key") ·
  `documentation/modules/security/con-certificate-renewal.adoc` :87–91("retaining the existing private key" · "replaces `ca.crt`") · `proc-replacing-private-keys.adoc` :45–53("Client applications must reload").
  **파드는 마운트된 Secret 갱신을 kubelet 주기(약 1분)로 받지만 클라이언트가 truststore를 다시 읽는지는 앱 몫**(T072 · Reloader는 Secret 변경 시 롤아웃 — 감시 ns identity·jt-dev·jt-prod).
- **비밀번호 회전 절차는 이 PR의 범위가 아니다**(VD-9 · T084 · `secret-rotation.md` 후속). 회전 중에는 ESO(≤ 5분) → UO(≤ 2분)와 앱 `<pod>-env`(≤ 5분 + 롤아웃)의 갱신 시점이 달라 옛/새 비밀번호가 엇갈리는 창이 있다.

---

## 6. 인계

- **T059(US3 E2E · 검사 Job Application)**: `platform/policies/tests` Application(AppProject `tests`)이 `kafka-assert`를 돌린다 — 이 PR이 Job의 roundtrip에 `latency=<n>ms` 토큰을 더했다(컨슈머 선기동 · 자기 멤버(실행마다 고유 `client.id`)의 할당 확인 · 지연 = 수신 시각 − CreateTime · 마커 미수신 · produce 실패 경로의 `EVIDENCE: producer 마지막 오류:` · 비밀번호 형식 검사(base64url 밖이면 JVM 기동 전에 두 검사 FAIL — 리뷰 r2 K5) ·
  진단 줄 필터 `safe_tail`(진단 다섯 곳이 `password` · `jaas` 줄을 거른다 — 리뷰 r2 K5 · O11) — `platform/policies/tests/README.md` §로그 계약 · 검증 기록 T056).
  첫 실측: 할당 소요 · latency 값(하네스 job-k-3 ≤ 5000) · VD-7(cross-env가 `TopicAuthorizationException`) · 동시 JVM 2개의 메모리(limit 640Mi — OOMKilled 0). 하네스 job-k-1..3 · `np-2-kafka-assert`.
- **T072(앱 템플릿 `<pod>-env`)**: `KAFKA_PASSWORD` ← `kv/{env}/kafka/<pod>` 키 `password`(store `vault-{env}` — 같은 비밀, store 둘 · data-model §8) · 사용자 이름(`<pod>` / `dev-<pod>`) · bootstrap `jt-kafka-kafka-bootstrap.data.svc:9093` · 토픽 이름은 ConfigMap(비밀 아님) ·
  CA = Secret `jt-kafka-cluster-ca-cert`의 `ca.crt`(PEM truststore — 이 PR의 미러) · 컨슈머 그룹은 KafkaUser 이름 접두 안에서 짓는다 — prod `<pod>-` · dev `dev-<pod>-`(ACL ⓑ · 결정 D3 · data-model §6). 새 pod는 이 디렉터리에 KafkaUser 2 · KafkaTopic · 비밀번호 ES 2를 같은 모양으로 더하는 PR + kv 시드가 선행한다.
  DLQ도 env 접두 — prod `<pod>.dlq` · dev `dev.<pod>.dlq`(events.md :5 · 2026-10-16 정정 — dev 자격은 `<pod>.dlq`에 쓸 수 없다).
- **T084(회전)**: VD-9 — kv 교체 → ES ≤ 5분 → UO ≤ 2분 → 앱 롤아웃의 순서·창 실측 · `secret-rotation.md`에 Kafka 행(이 디렉터리의 ES 2 · 앱 `<pod>-env` 2). **새 값도 P1 형식**(경로마다 따로 만든 base64url 43자 · 앞뒤 공백·개행 없음 · prod/dev 서로 다른 값 — 모노레포 시드 블록 B3 · C1) — 다른 형식이면 kafka-assert가 JVM 전에 두 검사를 FAIL로 닫고(리뷰 r2 K5) 시드 블록 재실행이 live-mismatch로 멈춘다(리뷰 r3 A2 · B4).
- **T097**: 이 디렉터리는 파드를 만들지 않는다 — UO/TO 메모리(T055 VD-3 · EO 256Mi 가정값)에 사용자·토픽 수가 더해진 뒤 재실측.
- **T098(관측)**: KafkaUser `NotReady` · KafkaTopic `Ready=False` 알림 후보(Argo health로는 KafkaTopic 실패가 Progressing으로만 보인다 — §1) · UO/TO 로그의 `reconciliation failed` 줄 ·
  KafkaUser 알림은 reason(늘 래퍼 `ExecutionException` — 시간 초과면 `TimeoutException`)이 아니라 message로 원인을 가른다(§1).
- **SP-2(구독 토픽 · 그룹 확장)**: 다른 pod의 토픽을 구독하면 KafkaUser에 literal topic `Read`·`Describe` 행을 더하는 PR(data-model §6 "구독 토픽 Read·Describe") · 새 이벤트 토픽은 KafkaTopic CR 추가(자기 접두라 ACL 변경 없음) · DLQ 정책 변경은 data-model 먼저.
  그룹 ACL 접두 `<pod>-`의 `-`는 pod 이름에도 쓰인다 — 어떤 두 pod 이름도 한쪽이 다른 쪽 + `-`로 시작하지 않는다(예: `identity-admin`이 있으면 `identity-admin-x`도 `identity`도 금지 — 접두 일치는 양방향으로 덮는다 · data-model §6 2026-10-16 · 리뷰 K2 · r3 B2).
  pod 이름은 `dev`가 아니고 `dev-`로 시작하지 않는다 — env 접두와 겹치면 prod ACL 접두(`<pod>.` · `<pod>-`)가 dev 토픽·그룹을 덮는다(data-model §6 · 리뷰 r2 K6) ·
  이 두 규칙 아래에서만 토픽 접두가 교차를 막는다 · 막는 장치는 후속 후보(copier `pod_name` 검증기 · validate KafkaUser 규칙).
- **후속(컨트롤러 판단)**: 비밀번호 ES · 미러 ES에 `template.metadata: {}`를 둘지(§4 template 행 — ES 메타데이터가 Secret에 복사되는 것을 막는 T053/T045 모양 · 하네스 ca-1과 양립) · validate에 KafkaUser 규칙(`secretKeyRef.name` · 이름 접두 고정 — §4 K1 행).
  (`job-kafka-assert.yaml` `resources` 주석은 리뷰 r1 S6/O4a로 정정했다 — JVM 동시 최대 2개 · 힙 상한 합 ≤ 512Mi.)
- **VD 결과 기록 위치**: 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T056 절(머지 → operation → Ready 시각 · retryCount · 하네스 결과) + build-notes 「T056」.
