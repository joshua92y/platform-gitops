# platform/cnpg-databases/ — 운영자 절차 (T054)

CloudNativePG **`DatabaseRole` 6**(PG role은 클러스터 전역이라 env마다 나눈다 — prod `identity_admin_{owner,app}` · dev `dev_identity_admin_{owner,app}` · 공유 `authentik_owner` · `openfga_owner`)
+ **`Database` 4**(`identity_admin` · `dev_identity_admin` · `authentik` · `openfga` — SP-1 범위 FR-016) + 그 비밀번호 Secret을 Vault kv에서 만드는 **`ExternalSecret` 6**
+ CRD로 표현할 수 없는 SQL을 전체 sync마다(§1) 멱등으로 내는 **PostSync hook Job 1**(`cnpg-databases-access` — ⓪ pod DB CONNECT 제한(컨트롤러 결정 C1 2026-10-14 · migrate Job T072 첫 단계와 이중 멱등) · ① 공유 DB CONNECT 제한 · ② app role 세션 기본값)을 소유한다.
Argo CD Application **`platform-cnpg-databases` 하나**가 이 디렉터리 하나를 적용한다(계약 `gitops-repo.md` §sync-wave 단일 표의 `cnpg-databases` 행). 설치 방식은
`platform/cnpg-cluster/`와 같은 **순수 매니페스트**다(`helmCharts` 없음).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources` 4파일(문서 17장). 전역 `namespace:` 변환기 없음. 이 디렉터리가 만들지 않는 것과 되돌리기 요약은 머리 주석 |
| `externalsecrets.yaml` | ExternalSecret 6(리소스 wave `"0"`): 이름 = Secret 이름 = DatabaseRole 이름 = `pg-main-<role 이름의 _를 ->` · pod role 4 = store `vault-data`(`prod/db/identity_admin/{owner,app}` · `dev/db/dev_identity_admin/{owner,app}`) · 공유 owner 2 = store `vault-platform`(`platform/db/{authentik,openfga}/owner`) · template `type: kubernetes.io/basic-auth` + 라벨 `cnpg.io/reload: "true"` + `username`·`password` · Owner · Periodic 5m |
| `databaseroles.yaml` | DatabaseRole 6(리소스 wave `"1"`): `login: true`(6장 전부 — CRD 기본값 false) · superuser/createdb/createrole/replication false · `bypassrls` pod owner 2 = true / 나머지 false · `passwordSecret` = 같은 이름 · `databaseRoleReclaimPolicy: retain` · `ensure: present` |
| `databases.yaml` | Database 4(리소스 wave `"2"`): owner `<db>_owner` · `databaseReclaimPolicy: retain` · `ensure: present` · `extensions: [vector]`는 `identity_admin`·`dev_identity_admin` 둘 다 |
| `job-postsync-db-access.yaml` | PostSync hook Job `cnpg-databases-access`: initContainer `pod-db-connect`(pod owner 자격 2장만 — ⓪ pod DB CONNECT 제한) → initContainer `shared-db-connect`(공유 owner 자격 2장만 — ①) → 본 컨테이너 `app-session-defaults`(app 자격 2장만 — ② + ⓪①의 판정 줄 중계 + SUMMARY) · 카탈로그 major 18 운영 이미지 · UID 26 · restricted securityContext |

> **머지 → 폴링 주기 안에 자동 sync → PG에 role 6 · database 4 · 확장 vector 2 생성 + PostSync Job 실행**(머지 → operation 시작 실측: T052 +4분 52초 · T053 +4분 47초 ·
> 길게는 약 8분 T046 — 모노레포 런북 `bootstrap.md` §3). 머지 **전** §0의 선행 조건 표를 전부 확인한다 — 특히 **P3(Vault kv 6경로 시드)**:
> 시드 전에 머지하면 ES가 `SecretSyncedError`(Degraded)로 첫 sync 시도가 Failed가 되고, 이 Application의 retry 창(≈12.5분)을 넘기면 같은 리비전으로는 다시 시작하지 않는다(§1 증상표).
> **머지가 먼저 됐다면(늦은 시드)** kv 시드 뒤 ES가 곧바로 다시 읽는다고 기대하지 않는다 — ESO 재조정 지수 백오프(실패가 길어질수록 다음 재조정이 늦어진다)가 retry 창을 넘길 수 있다 →
> 모노레포 런북 `docs/runbooks/bootstrap.md` §4 T054 「늦은 시드」(관리자 kubeconfig로 ES 6장에 `force-sync=<epoch>` 어노테이션 → agent-view로 6장 SecretSynced 확인 → retry를 다 썼으면
> **전체** 수동 Sync — §1).
> 머지 뒤 운영자가 §2의 확인과 §3의 VD를 기록한다(기록 위치는 §6).

- **이 저장소에 비밀은 없다.** 매니페스트에는 kv **경로·키 이름**과 role·DB **이름**만 있다. 비밀번호 Secret 6장은 ESO가 런타임에 만든다(희망 상태에 Secret 0장).
- **전역 `namespace:` 변환기가 없다.** 네 파일이 `metadata.namespace: data`를 직접 적는다.
- 로컬 재현(리뷰어용):
  ```bash
  kustomize build platform/cnpg-databases        # 문서 17(ES 6 · DatabaseRole 6 · Database 4 · Job 1) · 전부 namespace data
  bash tests/validate.sh                         # FAIL 0 · 출력 안에 `[PASS] 3.8 CNPG-retain — …`(관문 P6 — 기대 줄 전문은 §0 P6)
  ```
- **sync-wave 숫자는 여기 적지 않는다.** 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**, 코드 사본은 `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
  세 파일의 `argocd.argoproj.io/sync-wave` `"0"`·`"1"`·`"2"`는 **그 표의 숫자가 아니라** 이 Application 안의 리소스 적용 순서다(§1).

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 **17장** · 전부 ns `data`):

| 객체 | 리소스 wave | PG 이름 / kv 경로 | 역할 |
|---|---|---|---|
| ExternalSecret · DatabaseRole `pg-main-identity-admin-owner` | `"0"` · `"1"` | `identity_admin_owner` ← `vault-data` `prod/db/identity_admin/owner` | prod owner — 마이그레이션·시드 전용 · **BYPASSRLS** |
| ExternalSecret · DatabaseRole `pg-main-identity-admin-app` | `"0"` · `"1"` | `identity_admin_app` ← `vault-data` `prod/db/identity_admin/app` | prod app — 런타임 DML · NOBYPASSRLS · 세션 기본값(②) |
| ExternalSecret · DatabaseRole `pg-main-dev-identity-admin-owner` | `"0"` · `"1"` | `dev_identity_admin_owner` ← `vault-data` `dev/db/dev_identity_admin/owner` | dev owner · **BYPASSRLS** |
| ExternalSecret · DatabaseRole `pg-main-dev-identity-admin-app` | `"0"` · `"1"` | `dev_identity_admin_app` ← `vault-data` `dev/db/dev_identity_admin/app` | dev app · 세션 기본값(②) |
| ExternalSecret · DatabaseRole `pg-main-authentik-owner` | `"0"` · `"1"` | `authentik_owner` ← `vault-platform` `platform/db/authentik/owner` | Authentik DB owner(공유 — app role 없음) |
| ExternalSecret · DatabaseRole `pg-main-openfga-owner` | `"0"` · `"1"` | `openfga_owner` ← `vault-platform` `platform/db/openfga/owner` | OpenFGA DB owner(공유 — app role 없음) |
| Database `pg-main-identity-admin` | `"2"` | `identity_admin` · owner `identity_admin_owner` · 확장 `vector` | prod pod DB |
| Database `pg-main-dev-identity-admin` | `"2"` | `dev_identity_admin` · owner `dev_identity_admin_owner` · 확장 `vector` | dev pod DB(env 패리티) |
| Database `pg-main-authentik` · `pg-main-openfga` | `"2"` | `authentik` · `openfga` — owner `<db>_owner` | 공유 컴포넌트 DB |
| Job `cnpg-databases-access` | PostSync hook | — | ⓪ pod DB CONNECT 제한 ① 공유 DB CONNECT 제한 ② app role 세션 기본값(init 2 + 본 컨테이너 1 — 자격 격리) |

**런타임 객체**(희망 상태에 없다 — 정확한 모양은 §2에서 확인):
- **ESO가 만드는 Secret 6**(ns `data`, 이름 = ES 이름): type `kubernetes.io/basic-auth` · 키 `username`·`password` 둘 · 라벨 `cnpg.io/reload: "true"`(+ ESO 표식
  `reconcile.external-secrets.io/managed` · 어노테이션 `reconcile.external-secrets.io/data-hash` — T045 G3 실측) · ownerReference = ES. **agent-view는 Secret을 읽지 못한다**(§2 운영자 전용).
- **인스턴스 매니저(`pg-main-1`)가 만드는 PG 객체**: role 6 · database 4 · `vector` 확장 2(superuser가 `CREATE EXTENSION` — schema public). pod DB 2 · 공유 DB 2의 `datacl`(PostSync ⓪ ①) ·
  app role 2의 `rolconfig`(PostSync ②). CR에는 finalizer `cnpg.io/deleteRole` · `cnpg.io/deleteDatabase`가 붙고(희망 상태에 없음), 상태는 `status.applied` ·
  `status.observedGeneration` · `status.message`(+ DatabaseRole `status.secretResourceVersion` · 조건 `PasswordSecretChange` — operator가 Secret resourceVersion을 적는다).
- **PostSync Job의 Pod**(완료 뒤 7일 보존 — `ttlSecondsAfterFinished` · hook이 실행되는 다음 **전체** sync 직전에 `BeforeHookCreation`이 지운다).

**이 디렉터리가 만들지 않는 것**:
- app role의 테이블 GRANT(SELECT/INSERT/UPDATE/DELETE) → 각 pod 마이그레이션(T072 템플릿). pod DB(`identity_admin` · `dev_identity_admin`)의 `REVOKE CONNECT … FROM PUBLIC; GRANT CONNECT …
  TO <db>_app, <db>_owner;`는 여기 들지 **않는다** — 이 디렉터리의 PostSync Job ⓪이 먼저 낸다(컨트롤러 결정 C1 2026-10-14 · §1). 과제 문면의 migrate Job **첫 단계**(템플릿 T072 · 단언 T050
  `revoke-public`)는 그대로 두어 **이중 멱등**이다. Database 생성 ~ PostSync ⓪ 성공 사이에만 pod DB의 PUBLIC CONNECT가 열려 있다(§5).
- CA 미러(`pg-main-ca`의 `ca.crt`만 → `identity`·`jt-dev`·`jt-prod`) → `platform/kafka-topics/`(T056). 이 디렉터리의 Job은 ns `data` 원본에서 `ca.crt`만 마운트한다.
- Namespace · PSA · NetworkPolicy → `platform/policies/`(정책 변경 없음 — Job 파드 → `pg-main-rw:5432`는 ns `data`의 `allow-same-namespace`로 이미 열려 있다).
- Vault kv 값(시드) → 운영자(P3). Vault 정책 → 모노레포 `infra/vault/policies.tf`(이미 허용 — P2).
- 검사 Job `data-assert`(`platform/policies/tests/` — 이 PR이 검사 id `role-attrs` · `app-session-timeouts`를 더했다)의 **배포** → T057/T059.
- AppProject `platform`도 바꾸지 않는다: 17장 전부 **네임스페이스 범위**이고 `platform` 프로젝트에는 `namespaceResourceWhitelist`/`Blacklist`가 없다(destinations에 `data` 있음).

**선행 조건**(머지 전 전부 확인 — 하나라도 미충족이면 머지하지 않는다):

| # | 전제 | 확인 | 상태 2026-10-14 |
|---|---|---|---|
| P1 | `Cluster pg-main` Healthy(인스턴스 매니저가 DatabaseRole·Database를 조정한다) | `kubectl -n data get cluster pg-main -o jsonpath='{.status.phase}'` = `Cluster in healthy state` · 하네스 `data.tests.ps1` pg-1 PASS | T053 라이브(모노레포 `89d3456` — 하네스 data 9/6/1 · pg-1 PASS) |
| P2 | ClusterSecretStore `vault-data` · `vault-platform` Valid(둘 다 `conditions.namespaces`에 `data`) · Vault 정책 eso-data `kv/data/{dev,prod}/db/*` · eso-platform `kv/data/platform/*` | `kubectl get clustersecretstore vault-data vault-platform` → READY True · 정책은 모노레포 `infra/vault/policies.tf` | T045 라이브(store 5) · 정책 T044 |
| P3 | **Vault kv 6경로 시드**(키 `username` · `password` · `url`) — `kv/prod/db/identity_admin/{owner,app}` · `kv/dev/db/dev_identity_admin/{owner,app}` · `kv/platform/db/{authentik,openfga}/owner`. **`username` = role 이름**(CNPG가 대조 — §4) · `password` = 랜덤 base64url 43자(A–Z a–z 0–9 - _ — 시드 블록 S2 · 모두 URL 비예약 문자라 `url`에 인코딩 없이 들어간다 · 앞뒤 공백·개행 없음 — CNPG가 앞뒤 공백을 지운 값을 적용한다) · `url` = `postgresql://<role>:<password>@pg-main-rw.data.svc:5432/<db>?sslmode=verify-full&sslrootcert=/etc/pg/ca.crt`(pod-template §DB 연결 — 이 디렉터리는 `url`을 읽지 않는다. pod `-env`·`-migrate`가 읽는다) | **운영자 블록 모노레포 `specs/003-platform-foundation/design/t054-blocks/op1-seed-db.ps1`** · 런북 `docs/runbooks/bootstrap.md` §4(값 생성 절차) — 6경로 version ≥ 1 · 되읽기 해시 일치 | **머지 전** 운영자 실행(이 PR과 동시에 모노레포에서 작성 중) |
| P4 | agent-view가 `databaseroles` · `databases`(postgresql.cnpg.io) · ExternalSecret · Job · Pod 로그를 읽는다 | gitops `platform/policies/rbac-agent-view.yaml`(agent-view-extra: postgresql.cnpg.io `databases`·`databaseroles` get/list/watch · external-secrets.io `*`) + 내장 `view`(jobs · pods/log) | 라이브(T041/T052) — Secret은 읽지 못한다(의도) |
| P5 | Secret `pg-main-ca`(ns `data`, operator 생성 · 키 `ca.crt`·`ca.key`) — PostSync Job이 `ca.crt`만 마운트(`sslmode=verify-full`) | 운영자: `kubectl -n data get secret pg-main-ca -o 'go-template={{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'` → `ca.crt` · `ca.key`(이름만) | T053 VD-9(Cluster 생성 시 operator가 만든다) |
| P6 | 관문: `bash tests/validate.sh` → `FAIL 0`(검사 1 = 저장소 렌더 CRD 파생 스키마로 ES·DatabaseRole·Database kubeconform — **한계**: CRD 종류의 미지·오타 필드는 파생 스키마에 `additionalProperties: false`가 없어 validate가 잡지 못하고 Argo apply(strict field validation)에서 sync 실패로 드러난다(계약 §validate.yml 1 · 2026-10-14) · 3.3 = 이 디렉터리 ES의 store·접두 · **3.8 `CNPG-retain`**(계약 §validate.yml 3 하위 항목 「CNPG 데이터 보존」 — 검사 코드·PASS 줄은 `tests/validate.sh`의 것) = Database `ensure ≠ absent` + reclaim `retain` 명시 · DatabaseRole reclaim `retain` 명시. 기대 PASS 줄(개수 = 이 트리의 원본 4+6 · 렌더 4+6 — 2026-10-15 실측 · pod가 늘면 바뀐다): `[PASS] 3.8 CNPG-retain — postgresql.cnpg.io Database 8개(원본 4 · 렌더 4): ensure ≠ absent · databaseReclaimPolicy: retain 명시 · DatabaseRole 12개(원본 6 · 렌더 6): databaseRoleReclaimPolicy: retain 명시 — Git 변경만으로 DB·role이 지워지지 않는다`) | 로컬 `bash tests/validate.sh` · PR의 `validate` | 빌더 실측은 PR 본문(컨트롤러) |

---

## 1. 첫 배포에서 일어나는 순서

root(app-of-apps)가 `platform-cnpg-databases`를 이미 만들어 두었고(T041 — 지금은 렌더 0 · Synced/Healthy), 머지하면 자동 sync가 폴링 주기 안에 17장을 **리소스 wave 순서로**
적용한 뒤 PostSync Job을 띄운다. Argo는 wave N의 리소스가 전부 Healthy가 된 뒤 N+1을 적용한다.

> **이 순서 보장은 첫 시도에만 성립한다.** 재시도(같은 operation의 `retry`)에서는 `ApplyOutOfSyncOnly`가 이미 적용돼 in-sync인 리소스를 **health와 무관하게** task에서
> 뺀다(gitops-engine `sync_context.go:646–648` · `:761–773` — `modified=false`면 제외, hook만 남긴다). 그래서 첫 시도가 Degraded ES(kv 미시드)에서 Failed로 닫혔다면, 재시도는
> 그 ES를 **다시 기다리지 않고** DatabaseRole·Database를 Secret 없이 먼저 적용하고 PostSync Job을 띄운다 — CNPG 쪽은 무해하고(Secret이 없으면 `applied=false` · 30초 재시도),
> Job은 "Secret … 파일이 없다"로 바로 FAIL해 다음 재시도로 넘어간다(아래 증상표). kv가 시드되고 ES가 **SecretSynced**가 된 다음의 재시도에서 Job이 통과한다 — kv 시드 뒤 ESO가
> 곧바로 다시 읽는다고 기대하지 않는다(provider 오류는 `markAsFailed` 뒤 `return ctrl.Result{}, err`로 rate-limited requeue = 지수 백오프 · ESO v2.10.0
> `externalsecret_controller.go:419–420`; ES의 어노테이션·라벨·generation 변경은 즉시 enqueue `:1448–1465` — `force-sync` 어노테이션이 듣는 이유). 늦은 시드 절차 = 머리 문단 · 증상표 ES 행.

| 단계 | 리소스 wave | 무슨 일이 일어나는가 | 예상 시간(VD-6으로 실측) |
|---|---|---|---|
| ① | `"0"` ExternalSecret 6 | ESO가 store로 kv를 읽어 Secret 6을 만든다 → `Ready=True`(SecretSynced) → Argo health Healthy(ES 내장 health lua) | 초 |
| ② | `"1"` DatabaseRole 6 | 객체 생성 — Argo 내장 health가 없어 **즉시 Healthy**. 그 뒤 비동기로: operator가 Secret resourceVersion을 조건 `PasswordSecretChange`에 적고, 인스턴스 매니저가 `CREATE ROLE … LOGIN … PASSWORD …`(SCRAM)을 낸다 → `status.applied=true`. **실측(2026-10-15 첫 배포)**: 생성 직후 인스턴스 매니저가 finalizer `cnpg.io/deleteRole`을 **전체 객체 `Update`**로 넣는데, `RoleConfiguration`의 `omitempty` bool 6종(superuser · createdb · createrole · replication · bypassrls · login)은 CRD `default`가 없어 선언한 `false`가 본문에서 떨어진다(generation 2) → Argo가 6장을 "선언 필드 누락" OutOfSync로 보고 **selfHeal 부분 sync 1회**(`skipHooks` · DatabaseRole 6만 · `autoHealAttemptsCount 1`)로 되살린다(generation 3) → 그 뒤 안정. 새 DatabaseRole마다 한 번은 정상이다(소스+라이브 정합 추론 — 직접 관측은 다음 생성 때 1초 안 `-o yaml`로 · VD-7) | ≈25–30초(인스턴스 매니저 30초 requeue — 실측 CR 07:38:27Z → PG role ≈07:38:53–07:39:00Z) |
| ③ | `"2"` Database 4 | 객체 생성 — 즉시 Healthy. 비동기로 `CREATE DATABASE … OWNER <db>_owner` → pod DB 2에 `CREATE EXTENSION vector`. owner role이 아직 없으면 첫 시도가 실패하고 30초 뒤 다시 한다(실측 2026-10-15: CR 07:38:30Z → `CREATE DATABASE` 11회 `role "<owner>" does not exist` → **07:39:00Z 성공** + `created extension` ×2 · pgvector **0.8.6** — 인스턴스 매니저 `level=error` 11행은 이 정상 경로) | 수 초 ~ 30초+(실측 30초) |
| ④ | PostSync | Job `cnpg-databases-access`: init ⓪ `pod-db-connect`가 `identity_admin`·`dev_identity_admin`에 각 pod owner로 접속될 때까지 **그리고** GRANT 대상 `<db>_app` role이 `pg_roles`에 보일 때까지 기다린 뒤 REVOKE/GRANT(app·owner — 한 트랜잭션) + datacl 되읽기 → init ① `shared-db-connect`가 `authentik`·`openfga`에 각 owner로 REVOKE/GRANT(owner) + datacl 되읽기 → 본 컨테이너 ②가 app role 2로 자기 DB에 접속(⓪ 뒤라 PUBLIC이 아니라 GRANT로 붙는다 — 접속 성공 자체가 GRANT의 실증) + `ALTER ROLE CURRENT_USER SET …` + rolconfig 되읽기 → ⓪①의 판정 줄을 중계하고 `SUMMARY: pass=6 fail=0` · exit 0 → hook Healthy → operation Succeeded | 이미지 pull 없음(노드 B에 이미 있다) · 대기 ≤ 480초(Job 공유 · 보통 수십 초) — **실측 2026-10-15**: Job 36초(07:38:32→07:39:08Z) · ⓪ 접속 시도 1 `Connection refused`(PG 로그에 없음 — 새 파드 IP가 netpol ipset에 들어가기 전 첫 패킷 거절로 추정 · 미검증) · 시도 2·3 `password authentication failed`(role 미생성) · **4회째(07:39:03Z) 성공** — 대기 루프가 netpol 경합과 role 비동기를 모두 흡수했다. 즉시 접속하는 Job(T059 data-assert · T072 migrate)도 같은 재시도 루프가 필수 |

전체 **43초 실측**(2026-10-15 첫 배포 — operation 07:38:25Z → 07:39:08Z · `retryCount` 0 · Degraded 전이 없음 · 머지 → Argo 인지 2분 39초는 별도; 이전 추정 1–2분 — VD-6). Application은 ①–④ 동안 `Progressing`/Syncing, 끝나면 `Synced/Healthy`.

**hook이 도는 sync와 건너뛰는 sync**(Argo CD v3.5.2): PostSync Job은 **전체 sync**(새 리비전의 자동 sync · 그 operation의 재시도 · 리소스를 고르지 않은 수동 Sync)마다 돈다.
selfHeal 자동 sync(같은 리비전 — OutOfSync 리소스만 `op.Sync.Resources`에 넣는 부분 sync · `controller/appcontroller.go:2412–2420`) · UI에서 리소스를 골라 하는 Sync · Apply only는
hook을 **건너뛴다**(`controller/sync.go:311` — apply 전략 또는 `Resources ≥ 1`이면 skipHooks → gitops-engine `sync_context.go:980` `if !sc.skipHooks`). 그래서 수동 Sync로 Job을 돌릴 때는
리소스를 전부 선택하고 Apply only를 끈다(CLI: `argocd app sync platform-cnpg-databases` — `--resource` 없음) · 끝나면 §3 VD-4의 네 판정을 본다. hook 결과는 Application의 sync·health
집계에도 들어가지 않는다(`controller/health.go:27–32` · `controller/state.go:981–985`) — Job이 실패해도 앱은 Synced/Healthy일 수 있다(§2 · §5).

**PostSync Job 로그 계약**(검사 Job과 같다 — `platform/policies/tests/README.md` §로그 계약): `RESULT: PASS|FAIL <id> …` 정확히 한 줄씩 · 보조 줄 `NOTE:`(대기 사유 ·
접속 성공 · GRANT 대상 role 대기 · 서버 메시지) · `EVIDENCE:`(pod DB의 `vector` 버전 — 판정 아님) · 마지막 `SUMMARY: pass=<n> fail=<n>` · 실패 ≥ 1이면 exit 1. id 6개(출력 순서) =
`pod-connect-identity_admin` · `pod-connect-dev_identity_admin` · `shared-connect-authentik` · `shared-connect-openfga` · `app-session-defaults-prod` · `app-session-defaults-dev`.
최대 63줄(RESULT 6 + NOTE ≤ 54 + EVIDENCE 2 + SUMMARY 1 — 계산은 Job 머리 주석). 대기 예산 480초는 Job 전체(init 2 + 본 컨테이너)가 공유한다(첫 init `pod-db-connect`가 시한을
`/work/deadline`에 적는다 — 서버 불통의 최악 ≈ 시한 + 대상 6 × connect_timeout 10초 + 컨테이너 전환 ≈ 550초 < `activeDeadlineSeconds 600` · 계산은 Job 머리 주석).

**어디서 멈추면 무엇을 보는가**(agent-view로 되는 명령만):

| 증상 | 가장 먼저 볼 것 | 원인 후보 |
|---|---|---|
| ES `Ready=False` · `SecretSyncedError` · Application Degraded | `kubectl -n data get externalsecret` · `kubectl -n data describe externalsecret <이름>` Events | Events `Secret does not exist` = **kv 경로에 데이터가 없다**(시드 누락 · 경로 오기 — K8s Secret 얘기가 아니라 vault provider 문면) · `cannot find secret data for key: "username"`/`"password"` = kv **필드 이름** 불일치 · `could not get ClusterSecretStore` = store 없음 · `permission denied`/403 = Vault 정책(eso-data는 `{dev,prod}/db/*` 열거만) — 문면은 `platform/secrets/README.md` §1 표(ESO 2.10.0 실측). 고칠 곳은 **kv**(P3). **머지가 먼저 됐다면(늦은 시드)** kv 시드 뒤 모노레포 런북 `docs/runbooks/bootstrap.md` §4 T054 「늦은 시드」(관리자 kubeconfig — ES 6장에 `force-sync=<epoch>` 어노테이션 → agent-view로 6장 SecretSynced 확인 → retry를 다 썼으면 전체 수동 Sync): kv만 고치고 기다리면 ESO 지수 백오프(수 분 실패 뒤 5–16분)가 retry 창 ≈12.5분을 넘길 수 있다. force-sync는 git에 없는 다른 매니저 소유 필드라 SSA 구조 diff에서 드리프트로 보지 않는다고 판독 — VD-7과 함께 관찰 |
| DatabaseRole `status.applied=false` | `kubectl -n data get databaserole -o 'custom-columns=N:.metadata.name,ROLE:.spec.name,APPLIED:.status.applied,MSG:.status.message'` | `secrets "pg-main-…" not found` = Secret 없음(① 확인) · `the username in secret "…" does not match role "…"` = **kv `username` ≠ role 이름**(CNPG v1.30.0 `roles/runnable.go:366–369` — kv 정정) · `username key doesn't exist inside the secret`/`password key …` = Secret 키 없음(ES template) · `database role is already managed by the CNPG cluster` = Cluster `managed.roles`에 같은 이름(쓰지 않는다) |
| DatabaseRole `status.message` = `secrets "pg-main-…" is forbidden …`(첫 적용 직후) | 위 행의 명령 · `kubectl -n data get events --field-selector involvedObject.name=pg-main,reason=UpdatingRole` | **일시적**: 인스턴스 매니저가 읽을 수 있는 Secret은 operator가 그리는 instance Role `pg-main`의 `resourceNames`뿐이고, operator는 DatabaseRole 생성을 보고 그 목록을 다시 그린다(CNPG v1.30.0 `internal/controller/cluster_controller.go:1320–1326` → `cluster_create.go:748–800` createOrPatchRole → `pkg/specs/roles.go:77` · `:344` · `:539–556`). 인스턴스 매니저가 그보다 먼저 읽으면 거부되고 30초 뒤 다시 시도해 풀린다(이벤트 `UpdatingRole` = 목록 갱신). 몇 분 넘게 남으면 operator 로그(`kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --since=15m`)에서 Cluster `pg-main` 조정 오류를 본다 |
| Database `status.applied=false` | `kubectl -n data get database -o 'custom-columns=N:.metadata.name,DB:.spec.name,OWNER:.spec.owner,APPLIED:.status.applied,MSG:.status.message'` · `-o jsonpath='{.status.extensions}'` | `role "<db>_owner" does not exist` = owner role이 아직 없다(② 뒤 30초마다 재시도 — 오래 남으면 DatabaseRole 행) · 확장 오류(`status.extensions[].applied=false` — 이미지에 pgvector가 없을 때) |
| PostSync Job `RESULT: FAIL … 접속하지 못했다` (대기 시한 초과) | `kubectl -n data logs job/cnpg-databases-access`의 그 id 위 `NOTE:` 사유 | `password authentication failed` = role 미생성 · 비밀번호 미적용 · kv 비밀번호 ≠ Secret(→ DatabaseRole 행) · `database "…" does not exist` = Database 미적용(→ Database 행) · `permission denied for database` = 그 role에 CONNECT 없음 — ② app 접속에서 나오면 ⓪이 GRANT 없이 끝난 것(같은 로그의 `pod-connect-<db>` 줄 · ⓪은 REVOKE와 GRANT를 한 트랜잭션으로 내므로 정상 경로로는 PUBLIC을 닫고 app을 빠뜨리지 않는다 → 누가 밖에서 PUBLIC을 닫았거나 app GRANT를 지웠다) · `certificate verify failed`/`does not match host name` = CA·SAN · timeout/`could not connect` = pg-main 불가 · 정책 |
| Job `RESULT: FAIL pod-connect-<db>` · `shared-connect-<db> … PUBLIC CONNECT가 남아 있다` | 같은 로그의 `NOTE: … 서버 메시지: WARNING: no privileges could be revoked` | 접속한 role이 그 DB의 **owner가 아니다**(Database `spec.owner` 확인) — owner가 아니면 REVOKE는 오류가 아니라 경고로 끝나고 아무것도 바꾸지 않는다. **Job을 다시 돌릴 수 없을 때의 수동 대체** = 모노레포 런북 `docs/runbooks/bootstrap.md` §4 T054 「수동 대체 ② — pod DB CONNECT 제한」(운영자 · `kubectl -n data exec pg-main-1 -c postgres -- psql -X` 1순위 — 파드 안 superuser peer 인증이라 owner 자격 불필요) — 공유 DB(`authentik`·`openfga`)도 같은 방법, GRANT 대상은 `<db>_owner`만(기대 datacl은 §2) |
| Job `RESULT: FAIL pod-connect-<db> … GRANT 대상 role <db>_app 이 보이지 않았다`(시한 초과 · REVOKE도 하지 않았다) · `… GRANT 뒤에도 CONNECT가 없다(app-no-connect)` | DatabaseRole 행(`pg-main-<db>-app`의 `applied`) · 같은 줄의 datacl | app role이 아직 생성되지 않았다(인스턴스 매니저 비동기 · Secret·username 문제 → DatabaseRole 행). ⓪은 app role이 `pg_roles`에 보이기 전에는 REVOKE/GRANT를 내지 않는다(없는 role에 GRANT하면 한 트랜잭션이 통째로 취소되고, 따로 내면 PUBLIC을 닫은 채 app을 잠글 위험) → 그 동안 pod DB의 PUBLIC CONNECT는 그대로 열려 있다(§5). role이 `applied`가 된 뒤에도 Job을 다시 돌릴 수 없으면(전체 수동 Sync 불가 · hook 실패 반복) **수동 대체** = 모노레포 런북 `docs/runbooks/bootstrap.md` §4 T054 「수동 대체 ② — pod DB CONNECT 제한」(운영자 · `kubectl -n data exec pg-main-1 -c postgres -- psql -X` 1순위 · REVOKE+GRANT 네 문장 = 한 트랜잭션 · 확인 SQL = `datacl` · `has_database_privilege`) |
| Job `RESULT: FAIL app-session-defaults-<env> … rolconfig가 기대 … 와 다르다` | 같은 줄의 실제 값 | **정상 경로로는 나오지 않는다** — ②는 자기 `ALTER ROLE CURRENT_USER SET`(rc=0) 직후 별도 접속으로 되읽으므로 그 전의 수동 덮어쓰기는 원인이 될 수 없다. 나오면 예상 밖(PG가 값을 원문대로 저장한다는 전제 — `guc.c:6507–6513` — 가 깨졌거나 ALTER와 SELECT 사이의 동시 변경) → 같은 줄의 실제 값을 기록해 컨트롤러에 보고(VD-5). 수동 `ALTER ROLE … SET`로 덮인 상태를 잡는 것은 data-assert `app-session-timeouts`(T059 배포 뒤) · §2 운영자 `pg_roles` 질의이고, 다음 **전체** sync에서 이 Job이 다시 15s/30s로 맞춘다(§3 VD-5) |
| Job `RESULT: FAIL … Secret … username이 role … 과 다르다` · `… 파일이 없다` · `CA 파일 … 이 없다` | ES 상태 · P5 | kv `username` 오기(CNPG도 그 비밀번호를 적용하지 않는다) · ES 미동기 — 재시도 중이면 예상된 경로다(재시도는 Degraded ES를 다시 기다리지 않는다 — §1 「첫 시도에만」 문단 · kv 시드 뒤 ES가 **SecretSynced가 된 다음**의 재시도에서 통과 — ESO 백오프로 retry 창을 넘길 수 있다 → ES 행의 「늦은 시드」) · `pg-main-ca` 없음(볼륨이 `optional`이라 파드는 뜨고 FAIL 줄로 드러난다) |
| Job Pod `Pending`/`ContainerCreating`이 오래 | `kubectl -n data describe pod -l job-name=cnpg-databases-access` Events | `role=data` 노드 없음 · 이미지 pull(노드 B 밖으로 잡힌 경우 — nodeSelector 확인) · PSA(restricted 수준이라 baseline 통과가 정상) |
| Application `operationState.phase` = `Failed`, 메시지가 ES health(`SecretSyncedError` …) 또는 hook(`cnpg-databases-access` …) | `kubectl -n argocd get app platform-cnpg-databases -o jsonpath='{.status.operationState.phase} {.status.operationState.message} retry={.status.operationState.retryCount}'` | 다단계 sync에서 wave 대기 중 ES가 Degraded(kv 미시드)였거나 hook Job이 실패했다(gitops-engine `sync_context.go` · 소스 판독 · 라이브 미실측). 이 Application의 `retry`(limit 5 · 30s ×2 · 최대 5m ≈ 12.5분 — 계약 §Application 규약 예외 두 번째 사례 · 기본 retry의 **대체**)가 같은 operation 안에서 다시 시도한다(재시도마다 Job이 새로 뜬다 · 재시도는 in-sync 리소스를 health와 무관하게 건너뛰므로 ES를 다시 기다리지 않는다 — §1 「첫 시도에만」 문단). `retryCount` = 5 + `Failed`면 기본 동작상 **같은 리비전으로 다시 시작하지 않는다**(`appcontroller.go:2391` — selfHeal이어도) → 원인(kv · Secret · role)을 고친 뒤(늦은 시드면 ES 행의 force-sync → SecretSynced 확인이 먼저) **운영자 전체 수동 Sync**(리소스 선택 없음 · Apply only 끔 — §1 「hook이 도는 sync」; 또는 이 디렉터리의 hook 아닌 매니페스트를 바꾸는 다음 커밋 — 자동 sync는 OutOfSync일 때만 돈다: `appcontroller.go:2341`) → 끝나면 VD-4의 네 판정 — VD-6 |
| Job 스크립트만 고친 PR을 머지했는데 Job이 다시 돌지 않는다 | `kubectl -n argocd get app platform-cnpg-databases -o jsonpath='{.status.sync.status}'` = `Synced` | hook 매니페스트는 sync 상태에 들어가지 않는다(Argo CD v3.5.2 `controller/state.go:981–985`) → OutOfSync가 아니라 자동 sync가 없다. **운영자 전체 수동 Sync**(리소스 선택 없음 · Apply only 끔)로 새 Job을 돌린다 → VD-4의 네 판정 |

---

## 2. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다. **라이브 클러스터 접근 없이 작성했다**(빌더는 KUBECONFIG 없음 — 기대값은 렌더·CRD·소스에서 왔고 실측은 머지 뒤 VD).

```powershell
kubectl -n argocd get app platform-cnpg-databases -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase} retry={.status.operationState.retryCount}'
#   Synced Healthy Succeeded retry=…   (VD-6 — ①–④ 동안 Progressing/Running이 정상. ⚠ Synced/Healthy는 PostSync 결과를 포함하지 않는다 — operationState.phase가 판정 ①)
kubectl -n argocd get app platform-cnpg-databases -o jsonpath='{range .status.operationState.syncResult.resources[?(@.hookType=="PostSync")]}{.kind}/{.name} hookPhase={.hookPhase} {.message}{"\n"}{end}'
#   Job/cnpg-databases-access hookPhase=Succeeded …   (판정 ② — Job TTL과 무관하게 다음 operation 전까지 남는다 · VD-4)
(kubectl -n argocd get app platform-cnpg-databases -o json | ConvertFrom-Json).status.resources | Select-Object kind,name,status,health,hook
#   ExternalSecret 6 · DatabaseRole 6 · Database 4 = 16행 Synced(+ 살아 있는 hook Job이 hook=True로 함께 보일 수 있다 — sync 상태에 들어가지 않는다)
kubectl -n data get externalsecret,databaserole,database
#   ES 6(+ 기존 oci-s3-backup) READY True · STATUS SecretSynced / DatabaseRole 6 APPLIED true / Database 4 APPLIED true
kubectl -n data get databaserole -o 'custom-columns=N:.metadata.name,ROLE:.spec.name,APPLIED:.status.applied,GEN:.metadata.generation,OBS:.status.observedGeneration,SRV:.status.secretResourceVersion,MSG:.status.message'
#   6행 APPLIED true · GEN = OBS(하네스 role-1) · SRV 비어 있지 않음(비밀번호 적용된 Secret resourceVersion) · MSG 비어 있음
kubectl -n data get database -o 'custom-columns=N:.metadata.name,DB:.spec.name,OWNER:.spec.owner,APPLIED:.status.applied,GEN:.metadata.generation,OBS:.status.observedGeneration,EXT:.status.extensions[*].name,EXTOK:.status.extensions[*].applied'
#   4행 APPLIED true · GEN = OBS(하네스 db-1) · identity_admin·dev_identity_admin만 EXT vector / EXTOK true
kubectl -n data get job cnpg-databases-access
#   COMPLETIONS 1/1(실패면 0/1 — 로그를 본다)
kubectl -n data logs job/cnpg-databases-access
#   RESULT: PASS pod-connect-identity_admin identity_admin: PUBLIC CONNECT 회수 · identity_admin_app · identity_admin_owner CONNECT — datacl {=T/identity_admin_owner,identity_admin_owner=CTc/identity_admin_owner,identity_admin_app=c/identity_admin_owner}(형태 — VD-4)
#   RESULT: PASS pod-connect-dev_identity_admin …
#   RESULT: PASS shared-connect-authentik … datacl {=T/authentik_owner,authentik_owner=CTc/authentik_owner}
#   RESULT: PASS shared-connect-openfga …
#   RESULT: PASS app-session-defaults-prod identity_admin_app: statement_timeout=15s idle_in_transaction_session_timeout=30s (pg_roles.rolconfig)
#   EVIDENCE: identity_admin pg_extension vector=<버전> schema=public …(VD-3)
#   RESULT: PASS app-session-defaults-dev …
#   EVIDENCE: dev_identity_admin pg_extension vector=<버전> schema=public …
#   SUMMARY: pass=6 fail=0   (판정 ④ · 판정 ③ = 위 get job COMPLETIONS 1/1)
kubectl -n data logs job/cnpg-databases-access -c pod-db-connect
#   init ⓪ 자신의 줄(PASS/FAIL·NOTE 접두 그대로 — GRANT 대상 role 대기 NOTE 포함) — 본 컨테이너가 같은 줄을 RESULT:로 다시 낸다
kubectl -n data logs job/cnpg-databases-access -c shared-db-connect
#   init ① 자신의 줄
kubectl get events -n data --field-selector reason=FailedCreate | Select-String -Pattern 'podsecurity'
#   0행(PSA baseline 통과)
```

**운영자 전용**(admin kubeconfig — 값은 출력하지 않는다):

```powershell
kubectl -n data get secret -o name | Select-String 'pg-main-(identity|dev-identity|authentik|openfga)'
#   secret/pg-main-{identity-admin-owner,identity-admin-app,dev-identity-admin-owner,dev-identity-admin-app,authentik-owner,openfga-owner} = 6(이름만)
kubectl -n data get secret pg-main-identity-admin-app -o 'go-template={{.type}}{{"\n"}}{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}{{range $k,$v := .metadata.labels}}{{$k}}={{$v}}{{"\n"}}{{end}}'
#   kubernetes.io/basic-auth · 키 password · username 둘(그 밖 0 — template Replace) · 라벨 cnpg.io/reload=true + reconcile.external-secrets.io/managed=true(Argo tracking 라벨 없음)
kubectl -n data exec pg-main-1 -c postgres -- psql -X -tAc "SELECT rolname, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolcanlogin, rolconfig FROM pg_roles WHERE rolname IN ('identity_admin_owner','identity_admin_app','dev_identity_admin_owner','dev_identity_admin_app','authentik_owner','openfga_owner') ORDER BY 1"
#   owner 2 rolbypassrls t · 나머지 f · 전부 rolsuper/rolcreatedb/rolcreaterole f · rolcanlogin t · app 2 rolconfig {statement_timeout=15s,idle_in_transaction_session_timeout=30s}(VD-2 · VD-5)
kubectl -n data exec pg-main-1 -c postgres -- psql -X -tAc "SELECT datname, pg_get_userbyid(datdba), datacl FROM pg_database WHERE datname IN ('identity_admin','dev_identity_admin','authentik','openfga') ORDER BY 1"
#   authentik·openfga datacl = {=T/<owner>,<owner>=CTc/<owner>}(PUBLIC에 c 없음) · identity_admin·dev_identity_admin datacl = {=T/<owner>,<owner>=CTc/<owner>,<db>_app=c/<owner>}(PUBLIC에 c 없음 · app에 c — PostSync ⓪ · VD-4)
#   다르면(PUBLIC에 c가 남았거나 app에 c가 없으면) 다음 전체 sync의 Job ⓪①이 다시 맞춘다 — Job을 돌릴 수 없을 때는 런북 §4 T054 「수동 대체 ② — pod DB CONNECT 제한」(§1 증상표)
kubectl -n data exec pg-main-1 -c postgres -- psql -X -tAc "SELECT d, has_database_privilege('dev_identity_admin_app', d, 'CONNECT') FROM unnest(ARRAY['platform','postgres','template1']) AS d"
#   접근 경계 공백 기록(VD-9) — 지금은 true가 예상값이다(세 DB의 datacl은 기본값 · 회수는 이 Job의 자격으로 할 수 없다 · §5)
kubectl -n data exec pg-main-1 -c postgres -- psql -X -d identity_admin -tAc "SELECT extname, extversion, extnamespace::regnamespace FROM pg_extension WHERE extname = 'vector'"
#   vector | <버전> | public   (VD-3 — dev_identity_admin도 같은 명령)
```

**모노레포 하네스**(KUBECONFIG = agent-view · svc-verify 세션 · 한 번에 하나만):

```powershell
pwsh -NoProfile -File tests/platform/data.tests.ps1
#   기대 13 PASS(gate-1..3 · pg-1 · pg-2 · db-1 · db-2 · role-1 · role-2 · backup-1 · backup-2 · bucket-1 · bucket-2) / 2 FAIL(job-1 · job-2 = 검사 Job data-assert가
#   아직 배포되지 않았다 — T057/T059. 이 PR은 그 Job에 검사 id role-attrs · app-session-timeouts를 더했을 뿐이다) / 1 SKIP(env-1 until T075)
#   T059가 data-assert를 배포하면 job-1 · job-2는 PASS 후보다 — pod DB 교차 거부 세 id(pg-cross-db-denied · catalog-connect-false · revoke-public)는 이 Job ⓪이 먼저 닫아 두므로
#   T072/T075를 기다리지 않는다(C1 · 2026-10-14). 남는 선행 산출물은 T056 CA 미러 · T057 Dragonfly(acl-list · noperm)다(§6 T059)
#   ⚠ db-1·db-2·role-1·role-2는 CR status(applied)만 본다 — PostSync Job의 성패와 무관하게 PASS다. 13/2/1은 PostSync 성공의 증명이 아니다
pwsh -NoProfile -File tests/platform/cluster.tests.ps1
#   argo-1(모든 Application Synced/Healthy)에 platform-cnpg-databases 포함
#   ⚠ argo-1 PASS는 PostSync 결과를 포함하지 않는다 — hook은 Argo health·sync 집계에서 제외된다(Argo CD v3.5.2 controller/health.go:30 · controller/state.go:981).
#   PostSync 판정 = operationState.phase=Succeeded + hook hookPhase=Succeeded + Job succeeded=1 + 로그 `SUMMARY: … fail=0`(위 네 명령 · §3 VD-4). 장기 감시는 T059 인계(§6)
```

---

## 3. VD(검증 후 결정 — 머지 뒤 실측해 기록)

| ID | 무엇을 | 판정 |
|---|---|---|
| VD-1 | ES 6 `Ready=True`(SecretSynced) — **kv 6경로 실재의 첫 증명**(P3 시드의 결과). `refreshTime` 기록 | 6 전부 True면 P3 닫힘. `Secret does not exist`/`cannot find secret data for key`면 kv 정정(§1 표) — Secret 수동 수정 금지(≤5분에 kv 값으로 되돌아간다) |
| VD-2 | DatabaseRole 6 `applied=true` + **PG 실제 속성**(§2 운영자 `pg_roles` 질의 — bypassrls · super · createdb · createrole · login) | 선언과 같으면 통과. 다르면 `status.message`와 인스턴스 매니저 로그(`kubectl -n data logs pg-main-1 -c postgres --since=15m \| Select-String 'role'`) |
| VD-3 | Database 4 `applied=true` + **`vector` 설치·버전·schema**(Job `EVIDENCE:` 줄 또는 §2 운영자 `pg_extension` 질의 — research 미확인 항목: pgvector 버전) | 버전을 런북에 기록. `status.extensions[].applied=false`면 카탈로그 이미지의 확장 목록 확인(이미지 빌드 인자 `EXTENSIONS`에 postgresql-18-pgvector — 2026-10-14 이미지 config history) |
| VD-4 | PostSync Job 성공 — **판정 4가지**: ① `operationState.phase=Succeeded` ② hook `hookPhase=Succeeded`(`syncResult.resources` — Job TTL과 무관하게 다음 operation 전까지 남는다 · `types.go:1789–1792`) ③ Job `succeeded=1` ④ 로그 `RESULT: PASS` 6줄 · `SUMMARY: pass=6 fail=0`. `NOTE:` 대기 줄 수(= 인스턴스 매니저 비동기 지연 · ⓪의 GRANT 대상 role 대기 포함)도 기록 | 넷 다 통과면 pod DB·공유 DB CONNECT 제한 · app 세션 기본값 적용 완료. **하네스 argo-1 PASS · db/role PASS는 이 증명이 아니다**(hook은 sync·health 집계 밖 — §1 「hook이 도는 sync」 · §2). 대기 NOTE가 많거나 시한 초과면 §1 표 |
| VD-5 | **CNPG 조정이 rolconfig를 되돌리지 않는가** — 소스 판독으로는 되돌리지 않는다(§4 · 인스턴스 매니저의 ALTER ROLE 문장에 SET/RESET 없음 · 이미 적용된 객체는 다시 ALTER하지 않음). 실측 = 하루 뒤(또는 비밀번호 회전 VD-8 뒤 — 그때 인스턴스 매니저가 `ALTER ROLE … PASSWORD`를 다시 낸다) §2 운영자 `pg_roles` 질의 또는 검사 Job `app-session-timeouts`(T059) | 값이 남아 있으면 소스 판독 확인. 사라졌다면 컨트롤러에 보고(Job이 전체 sync마다 다시 맞추지만 sync 사이의 공백이 생긴다 — 설계 재검토). 수동 `ALTER ROLE … SET` 덮어쓰기도 여기서 드러난다(Job ② FAIL로는 나오지 않는다 — §1 표) |
| VD-6 | Argo operation 전이 — 첫 배포의 `operationState.phase`(Running → Succeeded) · `retryCount` · ES Degraded 전이 여부 · **PostSync 시점**(Job `creationTimestamp` vs Database 생성 시각) · Job의 접속 대기 NOTE · 머지 → Synced/Healthy 소요 시간 · **첫 operation이 어느 syncPolicy로 돌았는가**: `kubectl -n argocd get app platform-cnpg-databases -o jsonpath='{.status.operationState.operation.retry} {.status.operationState.operation.sync.syncOptions}'` — 이 PR이 Application CR(syncPolicy)과 매니페스트를 함께 바꾸므로, child가 root보다 먼저 새 리비전을 보면(둘 다 180초 폴링) 첫 operation이 옛 정책(기본 retry 5s ×2 · 3m ≈ 2.6분 · `ApplyOutOfSyncOnly` 없음)으로 돈다(operation은 만들어지는 시점의 spec을 담는다 — `appcontroller.go:2372–2380`). 영향은 실패 경로뿐(P3 머지 전 시드가 지켜지면 첫 시도는 성공). **실측 2026-10-15**: 예고한 경합이 실제로 일어났다 — child 첫 operation 07:38:25Z(옛 정책 · `ApplyOutOfSyncOnly` 없음 · retry 기본) · root가 새 Application CR을 적용 07:38:35Z(+10초) · 첫 시도 성공으로 영향 0 · 두 번째(selfHeal) operation만 새 정책. 위 jsonpath는 **마지막 operation**의 정책만 보인다(같은 초의 selfHeal op가 `operationState`를 덮었다) → 첫 op 정책의 정본 = `kubectl -n argocd get events --field-selector involvedObject.name=platform-cnpg-databases`(`OperationStarted`/`OperationCompleted` · "Partial sync" 문구로 selfHeal 구분 · **Events TTL 1h**) + 컨트롤러 로그 `Initialized new operation`(SyncOptions 전문) — 머지 뒤 1시간 안에 `-o json`으로 저장한다 | `retryCount` 0 + Succeeded = 예외(retry·ApplyOutOfSyncOnly)가 필요 없었다는 기록. ≤ 5인 채 Succeeded = retry가 흡수. `retryCount` 5 + Failed = 창 부족 → 전체 수동 Sync + 창 재검토(계약 §Application 규약 예외 · 컨트롤러). 기록된 retry/syncOptions가 옛 정책이면 "첫 operation은 기본 retry로 돌았다"를 적는다 — 다음 예외 컴포넌트(T055 등)는 Application CR을 먼저 머지하는 2단 PR 검토(컨트롤러 인계) |
| VD-7 | **webhook·CRD 기본값 주입 뒤 Synced 유지** — DatabaseRole(`inherit` · `connectionLimit` 기본값 · finalizer)·Database(finalizer)·ES(`deletionPolicy` · `conversionStrategy` 등 기본값)가 첫 sync 뒤 `Synced`로 안정되는가 | 안정이면 그대로. **실측 2026-10-15**: 안정(07:39:09Z Synced → 07:48Z까지 operation 0) — 단 DatabaseRole 6장만 **selfHeal 부분 sync 1회**를 거쳤다(generation 3). 원인은 CRD 기본값(`inherit` · `connectionLimit` — 어느 매니저 소유도 아니라 diff에서 무시)이나 finalizer 자체가 아니라, 인스턴스 매니저의 finalizer **전체 `Update`**가 `omitempty` bool 6종의 선언 `false`를 떨어뜨린 것("선언 필드 누락" OutOfSync → selfHeal이 되살림 · Database 4장은 같은 Update를 겪고도 generation 1 — 대조군 · 소스+라이브 정합 추론, 직접 관측은 다음 DatabaseRole 생성 때 1초 안 `-o yaml`). selfHeal이 꺼져 있었다면 영구 OutOfSync였을 것(§1 ②). 영구 `OutOfSync`면 1차 조치 = `ServerSideDiff=true`(계약 예외 문단 개정 뒤 — 컨트롤러 · T053 VD-11과 같은 질문). 늦은 시드로 ES에 `force-sync` 어노테이션을 걸었다면 그 뒤에도 Synced가 유지되는지 함께 본다(git에 없는 다른 매니저 소유 필드 — SSA 구조 diff에서 드리프트로 보지 않는다고 판독) |
| VD-8 | **`cnpg.io/reload`로 비밀번호 회전 반영** — dev app role 하나만: kv 교체 → ≤ 5분 ES `refreshTime` · Secret resourceVersion 변경 → DatabaseRole 조건 `PasswordSecretChange` 메시지 · `status.secretResourceVersion` 갱신 → 새 비밀번호로 접속 · 옛 비밀번호 거부(운영자) · 그 뒤 VD-5 재확인 | **후속 런북(`secret-rotation.md`)으로 이월 가능** — 첫 회전 때 실측. 반영이 안 되면 Secret 라벨 `cnpg.io/reload`(operator는 라벨 **키**만 본다)와 operator 로그 확인 |
| VD-9 | **새 LOGIN role 6개가 `postgres` · `platform`(initdb 부트스트랩 DB · owner `platform_owner`) · `template1`에 PUBLIC CONNECT로 붙을 수 있는가**(접근 경계 공백 — security r2 K12 · 결정 C9): CNPG Database 경로에는 GRANT/REVOKE가 없어 세 DB의 `datacl`은 기본값(PUBLIC CONNECT·TEMP)이다. 운영자(agent-view로는 안 된다): §2의 `has_database_privilege('dev_identity_admin_app', d, 'CONNECT')` 질의 | true가 예상값 — 기록만 한다(지금은 데이터·소비자 없음 · PG15+ public 스키마에 PUBLIC CREATE 없음 → TEMP 객체만 가능). 회수(`REVOKE CONNECT ON DATABASE platform, postgres FROM PUBLIC`)는 이 Job의 자격(비superuser owner)으로는 할 수 없다(세 DB의 owner는 superuser·`platform_owner`) → 결정 T097/T116(data-model §7 접근 경계 행) — 회수하면 data-assert `pg-cross-db-denied` 대상에 두 DB를 더한다 |

---

## 4. 값 선택 근거

| 값 | 출처 | 비고 |
|---|---|---|
| role 6 · database 4 · 이름(env 접두 · 공유는 접두 없음) | 과제 문면 · 모노레포 data-model §7 | 하네스 db-1/db-2/role-1/role-2가 이 집합을 **정확히** 본다(더 있으면 FAIL) |
| 객체 이름 `pg-main-<role·db 이름의 _를 ->` (ES = Secret = DatabaseRole) | 컨트롤러 결정 D2 | K8s 이름에 `_` 불가. 셋을 같은 이름으로 두어 1:1 추적 |
| store·경로(pod role `vault-data` `{prod,dev}/db/<role 접두>/{owner,app}` · 공유 `vault-platform` `platform/db/<db>/owner`) | D3 · data-model §7 비밀 행 · §8 · 계약 §공유 컴포넌트 비밀 | `kv/` 접두 금지(validate 3.1) · 3.3 = 열거 접두. Vault 정책은 이미 허용(P2) |
| ES template `type basic-auth` · 라벨 `cnpg.io/reload` · data `username`·`password`(`url` 미매핑) · 그 밖 라벨·어노테이션 없음 | D2 · CNPG CRD passwordSecret 설명 · ESO 2.10.0 소스 | §아래 「소스로 확인한 사실」 |
| `refreshPolicy Periodic` · `refreshInterval 5m` · `creationPolicy Owner` | 계약 §공통 규칙 | CRD 기본 refreshInterval은 1h — 쓰지 않는다 |
| `login: true` 6장 전부 | D4 · CRD(기본 false) | owner도 migrate Job · Authentik · OpenFGA가 로그인한다 |
| `bypassrls` pod owner 2 = true · 나머지 false · superuser/createdb/createrole/replication false 명시 | 과제 문면 · D4 · data-model §7 | 인스턴스 매니저가 매 적용에서 모든 속성을 명시적으로 낸다(`[NO]…`) |
| `databaseRoleReclaimPolicy` · `databaseReclaimPolicy` `retain` · `ensure present` | 과제 문면(retain) · D4/D5 · CRD 기본값 명시 | CR 삭제가 DROP을 부르지 않는다. **단 Database `ensure: absent`는 reclaim과 무관하게 `DROP DATABASE`**를 낸다 — 이 두 값(`ensure` · `databaseReclaimPolicy`)을 바꾸는 PR은 데이터 삭제 PR이다(§5) |
| 적지 않은 것: `connectionLimit`(기본 -1) · `validUntil` · `inRoles` · `inherit` · `clientCertificate` · encoding/locale | D4 · D5 | 연결 상한은 T097. encoding·locale은 생성 뒤 불변(CEL) — 기본값(클러스터 initdb) |
| `vector`를 `identity_admin`과 `dev_identity_admin` 둘 다 | D5 · data-model §7 확장 행(2026-10-14) | 과제 문면은 identity_admin만 — env 패리티(dev 마이그레이션이 먼저 돈다) |
| 리소스 wave `"0"`·`"1"`·`"2"` | D6 · research CNPG-D10 · T052/T053 선례 | Application 표의 숫자가 아니다. Secret → role → database owner 순서 |
| 객체 삭제 보호 어노테이션 **없음** | D6 · 계약 §삭제 보호 목록에 없음 | 데이터 보호는 reclaim `retain`(CR 삭제 경로만 막는다 — `ensure: absent` · reclaim `delete` 변경은 막지 못한다 §5), Application은 `prune: false` |
| PostSync Job(⓪ pod DB CONNECT · ① 공유 DB CONNECT · ② app 세션 기본값) | 과제 문면 · D7 · 컨트롤러 결정 C1(2026-10-14) · data-model §7 접근 경계 행 · app role 행 | ⓪은 과제 문면의 migrate Job 첫 단계(T072)와 **이중 멱등** — T059(US3 E2E)의 교차 DB 거부 증거를 T072 전에 만들기 위해 이 Job이 먼저 낸다. 자격 격리 = pod owner Secret 2장만 보는 별도 initContainer. 순서 ⓪ → ① → ②: app은 GRANT 뒤에만 자기 DB에 붙는다 |
| Job 이미지 = 카탈로그 major 18 운영 이미지 · `runAsUser/Group/fsGroup 26` · `/usr/lib/postgresql/18/bin/psql` | 지시문 기본 선택 · 이미지 config 조회(아래) | 노드 B에 이미 있다(새 pull · 새 레지스트리 없음) · 클라이언트 = 서버 버전 |
| Job 대기 예산 480초(Job 공유) · 재시도 10초 · `activeDeadlineSeconds 600` · `backoffLimit 0` · `ttlSecondsAfterFinished` 7일 | D7 지시문 · C1 | 예산을 Job 전체가 공유해야 세 컨테이너가 600초 안에 끝난다(컨테이너마다 480초면 최악 1440초) — 서버 불통의 최악 ≈ 시한 + 대상 6 × connect_timeout 10초 + 컨테이너 전환 ≈ 550초(Job 머리 주석 · 모의 실행 `timeout` 경우로 시한 안 종료 확인) |
| Secret 볼륨 `optional: true` · `defaultMode 0440` + `fsGroup 26` | 빌더 선택(근거 = Job 머리 주석) | Secret이 없을 때 ContainerCreating으로 말없이 멈추는 대신 FAIL 줄로 드러난다 |
| Application `ApplyOutOfSyncOnly=true` + `retry`(5 · 30s ×2 · 5m) | D8 · 계약 §Application 규약 예외 두 번째 사례(2026-10-14) | 근거는 `clusters/oci-k3s/apps/platform-cnpg-databases.yaml` 머리 주석. 재시도에서는 in-sync 리소스를 health와 무관하게 건너뛴다 — wave 순서 보장은 첫 시도만(§1) |

**소스로 확인한 사실**(2026-10-14 · 원문 판독 — 라이브 미실측). 줄 번호 기준 = **배포본 태그**: CNPG `v1.30.0` · Argo CD `v3.5.2`(gitops-engine은 그 저장소 안
`gitops-engine/` — `go.mod` replace) · PostgreSQL `REL_18_STABLE`. CNPG `release-1.30` 브랜치는 1.30.0 이후 수정이 들어가 줄 번호가 다르다(이 PR이 기대는 동작은 같다).

- **CRD**: 저장소 렌더(`platform/cnpg` 차트 cloudnative-pg 0.29.0)의 `databaseroles`·`databases` CRD는 CNPG 태그 `v1.30.0` `config/crd/bases/` 원문과 `spec`(openAPIV3Schema 포함)
  **JSON 동일 — CRD 어노테이션 제외**(차트가 `helm.sh/resource-policy: keep`, 이 저장소가 삭제 보호 `argocd.argoproj.io/sync-options`를 더한다 · controller-gen `v0.21.0`은 같다.
  `release-1.30` 브랜치와도 `spec`은 같고 controller-gen만 `v0.22.0`).
  DatabaseRole: required `cluster`·`name` · `ensure` enum present|absent(기본 present, absent는 CEL로 거부) · `databaseRoleReclaimPolicy` enum delete|retain(기본 retain) ·
  `login` 기본 false · `inherit` 기본 true · `connectionLimit` 기본 -1 · `cluster`·`name` 불변(CEL) · **role 수준 GUC 필드 없음**. Database: required `cluster`·`name`·`owner` ·
  `databaseReclaimPolicy` 기본 retain · `extensions[]`(name 필수 · ensure 기본 present) · encoding/locale 계열 불변 · database 수준 권한(CONNECT) 필드 없음.
  `v1.30.0`에는 DatabaseRole webhook이 없고(`internal/webhook/v1/`에 DatabaseRole 파일 없음), Database 기본값 webhook은 아무것도 바꾸지 않는다(`internal/webhook/v1/database_webhook.go:67–72`).
  DatabaseRole의 `ensure: absent`는 CEL(CRD)과 인스턴스 매니저(`internal/management/controller/databaserole_controller.go:121–128`) 둘 다 거부한다 — Database의 `absent`는 거부하지 않는다(아래 DROP 문단).
- **username 대조**: 인스턴스 매니저는 Secret의 `username`(앞뒤 공백 제거)이 role 이름과 다르면 `the username in secret %q does not match role %q`로 그 role을 적용하지 않는다
  (`internal/management/controller/roles/runnable.go:366–369` → DatabaseRole `applied=false`). **비밀번호도 앞뒤 공백을 지운 값이 적용된다**(같은 함수 `:372`). Secret type은 검사하지 않고
  키 `username`·`password`의 존재만 본다(`internal/management/utils/secrets.go:32–44`). → 시드 블록은 `username` = role 이름, 비밀번호에 앞뒤 공백·개행 없음.
- **rolconfig 보존**: 인스턴스 매니저의 role 적용 문장은 `ALTER ROLE <name> [NO]BYPASSRLS [NO]CREATEDB [NO]CREATEROLE [NO]INHERIT [NO]LOGIN [NO]REPLICATION [NO]SUPERUSER CONNECTION LIMIT n
  PASSWORD '<SCRAM>'`뿐이다(`roles/postgres.go:114–140` · `:338–382` · `:393–423`) — `SET`/`RESET`이 없다. 비교용 `roles.List`(`:44–55`)는 `pg_authid`의 rolconfig를 읽지 않고,
  이미 적용된 객체는 generation과 Secret resourceVersion이 그대로면 다시 ALTER하지 않는다(`internal/management/controller/databaserole_controller.go:271–289`). → PostSync ②의
  `ALTER ROLE CURRENT_USER SET …`은 CNPG가 되돌리지 않는다(라이브 확인 = VD-5). 이 판독이 틀렸다면 D7 ②가 무의미해진다 — 그래서 VD-5를 둔다.
- **`cnpg.io/reload`**: operator가 이 라벨(**키 존재만** — `internal/controller/cluster_predicates.go:134–137`)이 붙은 Secret의 생성·변경·삭제를 감시해 참조 DatabaseRole의 조건
  `PasswordSecretChange`에 resourceVersion을 적고(`internal/controller/databaserole_controller.go:108–170` · `:174–187` · `:206–210`), 그 상태 변화로 인스턴스 매니저가 다시 적용한다
  (인스턴스 매니저는 Secret을 watch하지 않는다 — 같은 파일 `:144–155`). 라벨이 **없으면** Secret 변경이 operator를 깨우지 않을 뿐, operator는 그 DatabaseRole의 다른 이벤트
  (DatabaseRole 변경 · Cluster spec 변경 — `:204` · `:224–228`) 때도 현재 Secret resourceVersion으로 조건을 다시 쓴다(`:78` → `:108–170`) → 회전 반영이 **다음 이벤트까지 지연**된다.
- **ESO template**(v2.10.0 `pkg/controllers/externalsecret/externalsecret_controller_template.go`): template이 있으면 ES의 라벨·어노테이션을 복사하지 않고 template.metadata만 붙인다
  (`setMetadata :148–156`) · `template.type`이 있으면 Secret type = 그 값(`:67–69`) · template.data가 있으면(mergePolicy 기본 Replace) Secret 키 = template 키뿐(`:72–76`). CRD 기본값:
  `engineVersion v2` · `mergePolicy Replace` · `refreshInterval 1h0m0s` · `target.creationPolicy Owner`/`deletionPolicy Retain`.
- **CREATE DATABASE / 확장**: owner role이 없으면 실패 → 30초 뒤 재시도(`internal/management/controller/database_controller.go:93` · `:195–206`). 확장은 superuser가
  search_path `"$user", public`에서 `CREATE EXTENSION`(`database_controller_sql.go:267–312`). `retain`이면 CR 삭제가 DROP을 부르지 않는다(`database_controller.go:215–218` ·
  DatabaseRole은 `databaserole_controller.go:189–198`).
- **DROP 경로**(데이터 손실 — §5): ① Database `spec.ensure: absent`는 reclaim policy를 **보지 않는다** — 인스턴스 매니저가 조정마다 `DROP DATABASE IF EXISTS <db>`를 낸다
  (`database_controller.go:299–300` → `database_controller_sql.go:227–243`, FORCE 없음 — 연결이 남아 있으면 실패하지만 30초마다 다시 시도하므로 연결이 끊기는 순간 실행된다).
  ② `databaseReclaimPolicy: delete` + CR 삭제(수동 · Prune · Application cascade) → `evaluateDropDatabase`가 `dropDatabase`(`database_controller.go:215–244` — 한 번이라도 조정된 객체만).
  ③ DatabaseRole `databaseRoleReclaimPolicy: delete` + CR 삭제 → `DROP ROLE`(`databaserole_controller.go:152–198` — 데이터는 아니지만 자격 소실 · 그 role이 소유한 객체가 남아 있으면 PG가 거부).
  확장의 `ensure: absent`는 `DROP EXTENSION IF EXISTS`(CASCADE 없음 — 의존 객체가 있으면 실패 · `database_controller_sql.go:314–326`).
- **이미지**(2026-10-14 ghcr 익명 토큰 — index `sha256:79be0d10…` → linux/arm64 manifest `sha256:1609f983…` → config `sha256:5be9805f…`): `User "26"`(숫자) · Env PATH에
  `/usr/lib/postgresql/18/bin` · `/etc/passwd` `postgres:x:26:102` · `/usr/lib/postgresql/18/bin/psql` 있음(`/usr/bin/psql`은 pg_wrapper 링크) · `/usr/bin/sh -> dash` ·
  빌드 인자 `EXTENSIONS=postgresql-18-pgaudit postgresql-18-pgvector postgresql-18-pg-failover-slots`. CNPG Cluster `postgresUID`/`postgresGID` 기본값 26/26(렌더 CRD) — Job도 26/26.
- **Argo**(v3.5.2): ES 내장 health(`Ready=False` → Degraded) · DatabaseRole/Database 내장 health 없음(즉시 Healthy — gitops-engine `sync_context.go:559`) · hook health Degraded →
  operation Failed(`:349–361`) · `ApplyOutOfSyncOnly`는 in-sync 리소스를 health와 무관하게 빼고 hook만 남긴다(`:646–648` · `:761–773`) · hook은 sync 상태에 들어가지 않는다
  (`controller/state.go:981–985`) · 자동 sync는 OutOfSync일 때만 돈다(`controller/appcontroller.go:2341`) · hook은 앱 health 집계에도 들어가지 않는다(`controller/health.go:27–32`
  `hookutil.IsHook(res.Live)` → continue) · selfHeal 자동 sync는 OutOfSync 리소스만 `op.Sync.Resources`에 넣는 부분 sync(`appcontroller.go:2412–2420`)이고 apply 전략 또는
  `Resources ≥ 1`이면 skipHooks(`controller/sync.go:311` → gitops-engine `WithOperationSettings` · `sync_context.go:980`) → selfHeal·리소스 선택 Sync·Apply only는 hook을 건너뛴다 ·
  자동 sync operation은 만들어지는 시점의 syncPolicy를 담는다(`appcontroller.go:2372–2380` `SyncOptions: app.Spec.SyncPolicy.SyncOptions` · 기본 `RetryStrategy{Limit: 5}` ·
  `op.Retry = *app.Spec.SyncPolicy.Retry` — VD-6) · hook 결과는 `operationState.syncResult.resources[].hookType/hookPhase`에 남는다(`pkg/apis/application/v1alpha1/types.go:1789–1792`).
- **PostgreSQL**(REL_18_STABLE · 문서): DB owner는 자기 DB의 `GRANT/REVOKE … ON DATABASE`를 낼 수 있다(⓪ ①이 owner 자격으로 충분한 이유 — superuser 불필요) · `psql -c`에 여러 문장을
  한 문자열로 주면 **한 트랜잭션**이다(psql 문서 — ⓪의 REVOKE+GRANT가 통째로 성공·취소되는 근거 · 모의 실행 `grant-error-atomic`) · 일반 role은 자기 세션 기본값만 바꿀 수 있고
  (`ALTER ROLE` 문서 "Ordinary roles can only set defaults for themselves" · `user.c:1039–1040` `roleid != GetUserId()`일 때만 권한 검사) `ALTER ROLE CURRENT_USER IN DATABASE <db> SET …`도
  자기 자신에 대해 낼 수 있다 → DB별 덮어쓰기(`pg_db_role_setting.setdatabase ≠ 0`)는 role 수준보다 우선하는데 ② · data-assert `app-session-timeouts`는 role 수준(`pg_roles.rolconfig`)만
  본다(security r2 K13 — 한계로 기록 · 확장은 후속).

---

## 5. 운영 위험 · 되돌리기

Application `platform-cnpg-databases`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`이고, DatabaseRole·Database는 reclaim policy **`retain`**이다. 그래서

> **CR 삭제 ≠ PG 객체 삭제(reclaim `retain`).** DatabaseRole·Database를 지워도 PG의 role·database(와 데이터)는 **남는다**(인스턴스 매니저는 `retain`이면 DROP하지 않고
> finalizer만 푼다). ExternalSecret을 지우면 Secret이 GC되지만 **PG의 비밀번호는 그대로**다 — DatabaseRole status도 곧바로 바뀌지 않는다(operator는 Secret NotFound면 조건을 바꾸지 않고
> `internal/controller/databaserole_controller.go:125–134` `return nil`, 인스턴스 매니저는 Secret을 watch하지 않아 다음 재조정 이벤트(spec 변경 · Cluster spec 변경 · Secret 재생성)까지
> `applied=true`가 남는다 — 그때 `detectMissingPasswordSecret`(`internal/management/controller/databaserole_controller.go:200–219`)이 `applied=false`로 표시한다 · Secret 존재는 ES 상태(VD-1)로 본다).
>
> **그러나 Git만으로 데이터가 지워지는 경로가 둘 있다**(§4 「DROP 경로」):
> ① **Database `spec.ensure: absent`** — reclaim과 **무관하게** 인스턴스 매니저가 `DROP DATABASE IF EXISTS`를 낸다. 이 Application은 automated + selfHeal이라
> **머지가 곧 drop**이다(연결이 남아 있으면 실패하지만 30초마다 다시 시도해 연결이 끊기는 순간 실행된다).
> ② **`databaseReclaimPolicy: delete` + CR 삭제** — 수동 삭제 · Prune · Application cascade(`Prune=confirm`/`Delete=confirm` 승인 뒤) 어느 쪽이든 `DROP DATABASE`.
> (DatabaseRole `databaseRoleReclaimPolicy: delete` + CR 삭제 = `DROP ROLE` — 데이터는 아니지만 자격 소실.)
> **이 값들(`ensure` · `databaseReclaimPolicy` · `databaseRoleReclaimPolicy`)을 바꾸는 PR은 데이터 삭제 PR로 다룬다**: 리뷰에서 그 DB의 소비자 0 · 최근 Backup
> `completed`(T053 §2)를 확인하고, 되돌릴 수 없음을 PR 본문에 적는다. `tests/validate.sh`가 이 값들을 고정한다(계약 §validate.yml 3 하위 항목 「CNPG 데이터 보존」 2026-10-14 — 모든 원본·렌더의
> Database `ensure ≠ absent` + `databaseReclaimPolicy: retain` 명시 · DatabaseRole `databaseRoleReclaimPolicy: retain` 명시 — 검사 코드 **`3.8 CNPG-retain`** · 기대 PASS 줄 `[PASS] 3.8 CNPG-retain — postgresql.cnpg.io Database 8개(원본 4 · 렌더 4): … · DatabaseRole 12개(원본 6 · 렌더 6): … — Git 변경만으로 DB·role이 지워지지 않는다`(전문은 §0 P6 · 보는 것/보지 않는 것은 `tests/README.md` 「한계」)): 의도된 삭제는 계약 행과
> 그 검사를 **같은 PR**에서 고치는 것으로만 열고, 사람 리뷰는 그 위의 두 번째 관문이다.

**되돌리기 순서**(운영자 · admin kubeconfig):

1. revert PR 머지 → `kustomization.yaml`이 `resources: []`로 복귀 → 렌더 0. 객체는 남고 Application은 **`OutOfSync`가 정상**이다(`prune: false`). PostSync Job도 더는 돌지 않는다.
2. 객체를 치워야 한다면 CR 수동 삭제(`kubectl -n data delete database <이름>` → `kubectl -n data delete databaserole <이름>` → `kubectl -n data delete externalsecret <이름>`).
   **PG 객체는 남는다**(retain).
3. PG 객체까지 지워야 할 때만(데이터 삭제 — 되돌릴 수 없다): **먼저** 그 DB를 쓰는 소비자(pod · Authentik · OpenFGA)가 없는지 · 최근 Backup `completed`(T053 §2)를 확인한 뒤
   `kubectl -n data exec pg-main-1 -c postgres -- psql -X -c "DROP DATABASE <db>"` → `… -c "DROP ROLE <role>"`(owner인 DB가 남아 있으면 DROP ROLE은 실패한다 — DB 먼저).
   kv 경로는 운영자가 따로 정리한다(`kv metadata delete` — 런북).
4. PostSync Job이 바꾼 것은 revert로 되돌아가지 않는다: pod DB·공유 DB의 PUBLIC CONNECT를 되살리려면 `GRANT CONNECT ON DATABASE <db> TO PUBLIC`(pod DB의 app GRANT를 지우려면
   `REVOKE CONNECT ON DATABASE <db> FROM <db>_app`), app 세션 기본값을 지우려면
   `ALTER ROLE <role> RESET statement_timeout` · `ALTER ROLE <role> RESET idle_in_transaction_session_timeout`(운영자 SQL — 보통 필요 없다).

**그 밖의 위험**:

- **pod DB의 PUBLIC CONNECT는 이 Job ⓪이 첫 성공 sync에서 닫는다**(컨트롤러 결정 C1 2026-10-14): CNPG가 만든 DB는 `datacl` NULL(PUBLIC CONNECT 허용)이라 Database 생성 ~ PostSync ⓪
  성공 사이(보통 수십 초 · 첫 시도가 실패하면 retry 창 ≤ 12.5분 · Failed로 닫히면 수동 Sync까지)에는 `dev_identity_admin_app`이 prod `identity_admin`에 **접속할 수 있다**(과제 문면이
  경고한 경로). 그 창에 데이터·소비자는 없다(identity-admin pod는 T075 이후). ⓪이 FAIL이면(§1 표) 창이 닫히지 않은 것이다 — VD-4 ④가 그 증거이고, 검사 Job data-assert(T059 배포 뒤)의
  `pg-cross-db-denied` · `catalog-connect-false` · `revoke-public`이 그 상태를 FAIL로 드러낸다. T072 템플릿의 migrate Job 첫 단계는 같은 SQL을 다시 낸다(이중 멱등 — 둘 중 하나가 빠져도 닫힌다).
- **`postgres` · `platform`(initdb 부트스트랩 DB · owner `platform_owner`) · `template1`의 PUBLIC CONNECT는 열려 있다**(접근 경계 공백 — security r2 K12 · 결정 C9): CNPG Database 경로에는
  GRANT/REVOKE가 없어 세 DB의 `datacl`은 기본값(PUBLIC CONNECT·TEMP)이고, 새 LOGIN role 6개가 거기 붙을 수 있다. 이 Job의 자격(비superuser owner)으로는 회수할 수 없다(세 DB의 owner는
  superuser·`platform_owner`) → **회수하지 않고 기록** · VD-9로 실측 · 결정은 T097/T116(data-model §7 접근 경계 행). 지금은 데이터·소비자가 없고 PG15+ public 스키마에 PUBLIC CREATE가 없어
  TEMP 객체만 만들 수 있다(template1 오염 불가). 회수한다면 data-assert `pg-cross-db-denied` 대상에 두 DB를 더한다.
- **PostSync Job 실패 = sync operation Failed, 그러나 Application은 Synced/Healthy로 남는다**(hook은 sync·health 집계 밖 — §1 「hook이 도는 sync」 · §2): Application `retry`(≈12.5분 창)가
  operation을 다시 돌며 Job도 새로 뜬다. 창을 넘기면 같은 리비전으로 자동 재시작하지 않는다 → 원인 해결 뒤 운영자 전체 수동 Sync(§1 표). 하네스 argo-1·db/role 검사는 이 실패를 보지 못한다
  → 머지 시점은 컨트롤러 `t054-verify.ps1`(Job succeeded · RESULT/SUMMARY) · 그 뒤는 VD-4 네 판정 · 장기 감시는 T059 인계(§6).
- **hook만 바꾼 커밋은 자동 sync를 부르지 않는다**(§1 표) — Job 스크립트를 고친 PR은 머지 뒤 전체 수동 Sync(리소스 선택 없음 · Apply only 끔)로 확인한다.
- **비밀번호 회전** = kv 교체 → ESO ≤ 5분 → Secret 변경 → `cnpg.io/reload` → 인스턴스 매니저 `ALTER ROLE … PASSWORD`. Secret만 손으로 바꾸면 ≤ 5분에 kv 값으로 되돌아간다
  (회전의 정본은 kv). 같은 kv의 `url`도 함께 바꿔야 pod(`-env`)가 새 비밀번호를 쓴다 — 회전 매트릭스는 런북 `secret-rotation.md`(후속 · VD-8).
- **`username` 오기 = 그 role만 조용히 미적용**: CNPG가 거부하고 DatabaseRole `applied=false`(하네스 role-1 FAIL)로만 드러난다. PostSync Job도 같은 Secret을 대조해 FAIL을 남긴다.
- **속성 드리프트는 재적용 전까지 남는다**: 수동 `ALTER ROLE … BYPASSRLS` 같은 변경은 그 DatabaseRole이 다시 적용될 때(spec 변경 · Secret resourceVersion 변경)에야 선언으로
  되돌아간다 — 이미 적용된 객체는 다시 ALTER하지 않는다(`databaserole_controller.go:271–289`). 재적용 때는 반대로 spec `inRoles`에 없는 부모 멤버십(이 role이 **멤버**인 쪽)이 전부 REVOKE된다(§6 T072).
  → 감시는 검사 Job data-assert `role-attrs`(T059 배포 뒤).
- **이름 변경은 새 객체다**: `spec.name`·`cluster`는 불변(CEL) — `spec.name`만 바꾼 PR은 API가 거부해 sync Failed. `metadata.name`만 바꾸면 같은 PG 객체를 가리키는 CR이
  둘이 되고(`prune: false`라 옛 CR이 남는다) 새 CR은 충돌로 조정되지 않는다(`internal/management/controller/common.go:249–286` detectConflictingManagers — 데이터 손실 없음).
  둘 다 바꾸면 새 role/DB가 생기고 옛 것은 `retain`으로 남는다(수동 정리 — 위 3).
- **연결 수**: role마다 `connectionLimit` 기본 -1(무제한) · 클러스터 `max_connections 100` — 상한 교정은 T097.

---

## 6. 인계

- **T059(검사 Job · 하네스) — 2026-10-15 라이브 실측에서**: ① 새 DatabaseRole마다 selfHeal 부분 sync 1회가 정상(§1 ② · VD-7) — 하네스가 `operationState.operation.sync.autoHealAttemptsCount` 또는 Argo Events "Partial sync"를 단언할지 검토 ② PostSync Job의 첫 접속이 `Connection refused`로 거절됐다(netpol ipset 경합 추정 · 미검증) → data-assert Job도 재시도 루프 필수 ③ hook의 `hookPhase`는 다음 operation이 덮으면 사라진다(VD-4 ②) → Job 자체 상태 + Events가 정본 ④ 교차 거부의 첫 반(pod DB PUBLIC CONNECT 회수)은 Job ⓪ datacl로 확인됨 — 검사 Job `pg-cross-db-denied`가 나머지 반.
- **T056(`platform/kafka-topics/` CA 미러)**: `pg-main-ca`의 `ca.crt`**만**(`dataFrom` 금지) → `identity` · `jt-dev` · `jt-prod`. 검사 Job `data-assert`(ns `jt-dev`)와 Authentik·OpenFGA의
  `verify-full`이 그 미러를 쓴다(이 디렉터리의 Job은 ns `data` 원본을 직접 마운트).
- **T072(django-pod 템플릿)**: migrate Job **첫 단계** = `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC; GRANT CONNECT ON DATABASE <db> TO <db>_app, <db>_owner;`(owner 자격 — owner는
  자기 DB의 권한을 바꿀 수 있다 · 한 `-c` 문자열 = 한 트랜잭션) + app role 테이블 GRANT. 이 디렉터리의 PostSync Job ⓪이 같은 SQL을 **먼저** 내지만(C1) 첫 단계는 그대로 둔다 — **이중 멱등**
  (둘 중 하나가 빠져도 pod DB가 닫힌다). 세션 기본값은 이미 이 디렉터리의 PostSync Job ②가 맡는다(템플릿에서 다시 하지 않아도 된다).
  - **세션 기본값을 다시 낸다면**(app 자격으로만 된다 — migrate Job의 owner 자격으로는 다른 role의 기본값을 바꿀 수 없다: 일반 role은 자기 것만 · PostgreSQL ALTER ROLE 문서)
    **정확히 `'15s'` · `'30s'` 리터럴로 쓴다** — 검사(이 디렉터리 Job ② · data-assert `app-session-timeouts`)가 rolconfig **문자열**을 대조하고, PG는 값을
    정규화하지 않고 받은 그대로 저장한다(PostgreSQL `REL_18_STABLE` `guc.c:6507–6513` — 이름만 정규화 · `guc_funcs.c:251–258` — `= 15000`이면 `statement_timeout=15000`).
    의미가 같아도 FAIL이다(다음 전체 sync에서 이 Job이 `'15s'`로 되돌리지만 그 사이 검사가 FAIL한다).
  - **role 멤버십이 필요하면 DatabaseRole `inRoles`로 선언한다** — 밖에서 `GRANT <부모 role> TO <이 role>`(이 DatabaseRole의 role이 **멤버**인 쪽)한 멤버십은 이 role이 다시
    적용될 때(비밀번호 회전 · spec 변경) 인스턴스 매니저가 조용히 REVOKE한다(`inRoles`에 없는 부모 전부 — CNPG v1.30.0 `roles/postgres.go:300–324` GetParentRoles
    (`pg_auth_members.member` = 이 role) → `roles/runnable.go:422–436` getRolesToRevoke → `roles/postgres.go:271–275` `REVOKE <부모> FROM <이 role>`). **방향에 주의**: 이 role을
    남에게 준 `GRANT <이 role> TO <다른 role>`은 이 role의 재적용과 무관하고, 받는 쪽이 DatabaseRole이면 **그쪽** 재적용 때 회수된다(6개 모두 DatabaseRole이라 서로 간 멤버십은
    멤버 쪽 `inRoles`에 부모 이름을 적는다).
- **T075(pod Deployment·`-env`/`-migrate` ES)**: `kv/{env}/db/<role 접두>/{app,owner}`의 `url`을 `vault-{env}`로 읽는다(P3에서 시드). `url`의 비밀번호 = kv `password`(앞뒤 공백 없음 — §4).
- **T080(Authentik)**: DB `authentik` · role `authentik_owner` · 자격 `kv/platform/db/authentik/owner`(`vault-platform` · ns `identity`) · `AUTHENTIK_POSTGRESQL__SSLMODE=verify-full` ·
  `…__SSLROOTCERT`(T056 미러). `authentik` DB에는 이 디렉터리의 Job이 **owner에게만 CONNECT**를 남긴다 — 다른 role로 붙이지 않는다.
  role 멤버십이 필요하면 `inRoles`로 선언한다(이 role이 멤버인 멤버십은 재적용 때 회수된다 — 위 T072).
- **T082(OpenFGA)**: DB `openfga` · role `openfga_owner` · 자격 `kv/platform/db/openfga/owner` — 위와 같은 규칙(CONNECT는 owner만 · 멤버십은 `inRoles`).
- **T097**: role별 `connectionLimit` · Job 자원 실측 교정(requests 10m/32Mi · limit 64Mi).
- **T059**: 검사 Job `data-assert` 배포(tests Application) · VD 결과 수합. pod DB 교차 거부 세 id(`pg-cross-db-denied` · `catalog-connect-false` · `revoke-public`)는 이 디렉터리의
  PostSync Job ⓪이 pod DB의 PUBLIC CONNECT를 먼저 닫아 두므로 **T072/T075를 기다리지 않고 PASS 후보**다(컨트롤러 결정 C1 2026-10-14 — 이전 서술 "pod DB REVOKE 전까지 FAIL"은 철회).
  남는 선행 산출물 = CA 미러 T056(`ssl-verify-full` · 접속 자체) · Dragonfly T057(`acl-list` · `noperm`). 그 뒤 하네스 data `job-1`(`status.failed` ≥ 1이면 FAIL) · `job-2`(id 6개 전부
  PASS 요구) · cluster `np-2-data-assert`(`status.succeeded ≥ 1`) · kafka `job-d-1`(spec r3 S3가 같은 원인으로 지목)이 PASS 후보다. T059 AC "다른 pod app role로 교차 DB 접속 시
  permission denied 증거"는 pod DB 방향(dev app → prod `identity_admin`)과 공유 DB 방향 둘 다 이 Job 뒤에 만들 수 있다. **장기 감시 인계(C5)**: 하네스 argo-1은 hook 실패를 보지 못한다
  (§2) → `operationState.phase ∈ {Failed, Error}`인 Application(제외 목록 밖)을 FAIL로 내는 단언 추가를 T059에서 검토(컨트롤러). ⚠ PostSync Job이 FAIL인 채 data-assert를 돌리면 세 id가
  FAIL한다 — 먼저 VD-4 네 판정.
- **VD 결과 기록 위치**: 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T054 절(시드 시각 · ES refreshTime · applied · Job 로그 요약 · vector 버전 · operation 전이) + build-notes 「T054」.
