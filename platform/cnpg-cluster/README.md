# platform/cnpg-cluster/ — 운영자 절차 (T053)

CloudNativePG **`Cluster pg-main`**(PostgreSQL 18 · 인스턴스 1 · 노드 B · local-path 40Gi) + **`ObjectStore oci-backups`**(OCI Object Storage S3 호환 · 버킷 `joshuatech-backup`)
+ **`ScheduledBackup pg-main-daily`**(매일 02:00 KST · immediate)를 소유한다. Argo CD Application **`platform-cnpg-cluster` 하나**가 이 디렉터리 하나를 적용한다
(계약 `gitops-repo.md` §sync-wave 단일 표의 `cnpg-cluster` 행 = "pg-main"). 설치 방식은 `platform/cert-manager-issuers/`·`platform/secret-stores/`와 같은 **순수 매니페스트**다
(`helmCharts` 없음 · 로컬 재현에 helm이 필요 없다).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources` 3장. 전역 `namespace:` 변환기 없음. 이 디렉터리가 만들지 않는 것의 경계와 되돌리기 요약은 머리 주석 |
| `objectstore-oci-backups.yaml` | ObjectStore(리소스 wave `"0"`): `destinationPath s3://joshuatech-backup/pg-main/` · OCI S3 호환 `endpointURL` · `s3Credentials` = Secret `oci-s3-backup` 키 참조 3(region도 참조) · wal zstd/maxParallel 2 · data lz4/jobs 1 · `retentionPolicy 30d` · 사이드카 env(체크섬 우회)·resources · `Delete=false,Prune=false` |
| `cluster-pg-main.yaml` | Cluster(리소스 wave `"1"`): `imageCatalogRef` major 18 · instances 1 · local-path 40Gi · 1 CPU/2Gi(requests = limits) · `nodeSelector role=data` · `enableSuperuserAccess false` · parameters 8 · initdb `platform`/`platform_owner`/dataChecksums · plugins barman-cloud `isWALArchiver` · `Delete=false,Prune=false` |
| `scheduledbackup-pg-main-daily.yaml` | ScheduledBackup(리소스 wave `"2"`): `0 0 17 * * *`(6필드) · `immediate true` · `backupOwnerReference self` · `method plugin` |

> **머지 = 즉시 자동 sync = 노드 B에 PostgreSQL 인스턴스 기동 + 첫 베이스 백업이 OCI 버킷에 올라간다.** 이 PR부터 `Cluster pg-main`은 **상태를 가진 객체**다 —
> 삭제 = 데이터 삭제(§5). 머지 전 §0의 선행 조건 표를 전부 확인한 뒤 머지한다. 머지 뒤 운영자가 §2의 확인과 §3의 VD를 기록한다(정본 위치는 §6).

- **이 저장소에 비밀은 없다.** 세 매니페스트에 토큰·키·OCID가 한 건도 없다(OCI Object Storage 네임스페이스 `axvjykgvo2m1`은 모노레포 `infra/*/backend.tf`에 이미 공개된 값).
  자격은 Secret `oci-s3-backup`의 **이름**으로만 참조하고, 그 Secret은 선행 PR #46의 ExternalSecret(`secrets/data/`)이 Vault kv에서 만든다. 런타임 Secret 4장
  (`pg-main-ca` · `pg-main-server` · `pg-main-replication` · `pg-main-app`)은 operator 산출물이다 — 희망 상태에 Secret 0장.
- **전역 `namespace:` 변환기가 없다.** 세 매니페스트가 `metadata.namespace: data`를 직접 적는다(선례와 통일 · `platform/cloudflared`·`platform/system-upgrade`에서 복사하지 않는다).
- 로컬 재현(리뷰어용):
  ```bash
  kustomize build platform/cnpg-cluster        # 문서 3 · 전부 namespace data
  ```
- **sync-wave 숫자는 여기 적지 않는다.** 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**, 코드 사본은 `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
  세 파일의 `argocd.argoproj.io/sync-wave` `"0"`·`"1"`·`"2"`는 **그 표의 숫자가 아니라** 이 Application 안의 리소스 적용 순서다(§1).

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 결과 **3장** · 전부 ns `data`):

| 객체 | 리소스 wave | 역할 |
|---|---|---|
| ObjectStore `oci-backups`(`barmancloud.cnpg.io/v1`) | `"0"` | 백업·WAL 아카이브 대상. `s3://joshuatech-backup/pg-main/` · OCI S3 호환 엔드포인트 · 자격 = Secret `oci-s3-backup` 키 참조 3 · retention 30d · 사이드카 env·resources. `Delete=false,Prune=false`(§5) |
| Cluster `pg-main`(`postgresql.cnpg.io/v1`) | `"1"` | PostgreSQL 18(카탈로그 major 18 digest) · 인스턴스 1 · 노드 B · local-path 40Gi · 1 CPU/2Gi(컨테이너 requests = limits — 파드 QoS는 플러그인 사이드카 때문에 **Burstable** · §4 · VD-14) · superuser 비활성 · 플러그인 barman-cloud WAL 아카이버. `Delete=false,Prune=false`(하네스 argo-4-pg-main) |
| ScheduledBackup `pg-main-daily`(`postgresql.cnpg.io/v1`) | `"2"` | 매일 17:00 UTC(02:00 KST) 베이스 백업 · immediate 첫 백업 · Backup 객체 owner = self |

**operator·플러그인이 그 위에 만드는 런타임 객체**(희망 상태에 없다 — Argo 추적도 삭제 보호도 없다 · 정확한 수·이름은 §2에서 확인): Pod `pg-main-1`(`spec.containers` 1 = `postgres` ·
`spec.initContainers` 2 = `bootstrap-controller`(instance manager 바이너리 복사 · 기동 때만) + **`plugin-barman-cloud`**(restartPolicy `Always` = native sidecar — plugin v0.14.0 `internal/cnpgi/operator/lifecycle.go` `sidecarTemplate.Name = "plugin-barman-cloud"`(:417) · `RestartPolicy = Always`(:433) · `spec.InitContainers = append(...)`(:568); 로그는 `kubectl -n data logs pg-main-1 -c plugin-barman-cloud`)) · PVC `pg-main-1`(40Gi local-path · 노드 B) · Service `pg-main-rw`·`pg-main-ro`·`pg-main-r` · Secret `pg-main-ca`·`pg-main-server`·
`pg-main-replication`·`pg-main-app`(`pg-main-superuser`는 **없다** — `enableSuperuserAccess: false`) · ServiceAccount·Role·RoleBinding `pg-main` · initdb Job `pg-main-1-initdb`(완료 뒤 정리) ·
Backup `pg-main-daily-<YYYYMMDDHHMMSS>`(ScheduledBackup이 만든다 — 보존 만료 뒤에는 사이드카가 카탈로그에 없는 것을 지워 ≈ 30개로 수렴 · §5) · 사이드카가 ObjectStore·Secret을 읽는 RBAC =
플러그인 `rbac/ensure.go`가 Cluster를 owner로 ns `data`에 ensure/patch하는 Role·RoleBinding(Pre hook — 이름·규칙은 VD-10).

**이 디렉터리가 만들지 않는 것**:

- Namespace `data` · PSA 라벨(**baseline**) · NetworkPolicy — `default-deny` · `allow-dns` · `allow-same-namespace` · `allow-kube-api` · `allow-from-apps`(jt-* 5432/9093/6379) ·
  `allow-from-identity`(5432) · `allow-scrape-from-monitoring`(9187/9404) · `allow-egress-external-443`(OCI Object Storage) · **`allow-from-cnpg-operator`(8000 · T053 선행 PR #46 — operator → instance manager `/pg/status` 상태 수집 · in-place update; 백업 **시작**은 `pods/exec` 스트림이라 정책 밖 — `method: plugin`도 같은 exec 경로: CNPG 1.30 `api/v1/backup_funcs.go` `IsManagedByInstance() = Plugin || BarmanObjectStore`, 원문 줄은 VD-5)**
  → `platform/policies/`. 이미 라이브 — 이 PR은 정책을 한 줄도 바꾸지 않는다. **열지 않는 경로**: 사이드카는 파드 안 unix 소켓(`/plugins` emptyDir — plugin v0.14.0
  `lifecycle.go` healthcheck `unix` · 마운트 `/plugins`)으로 instance manager와 통신하고 밖으로는 kube API 6443(`allow-kube-api`) · OCI 443(`allow-egress-external-443`)만 부른다
  → data → cnpg-system **9090은 열지 않는다**(9090은 operator ↔ 플러그인의 same-ns gRPC — 계약 §allow-same-namespace). 위 정책 집합으로 완결이다.
- ExternalSecret `oci-s3-backup`(→ Secret 키 `ACCESS_KEY_ID`·`ACCESS_SECRET_KEY`·`REGION`) → 원본 `secrets/data/externalsecret-oci-s3-backup.yaml` · 적용 주체 `platform/secrets/`
  (Application `platform-secrets`, 계약 §sync-wave 표의 `secrets` 행 — `cnpg-cluster` 행보다 앞). **이 디렉터리는 그 이름만 참조한다** — ES를 복사하면 validate 7.3(단일 소유)이 FAIL한다.
- `Database` · `DatabaseRole`(pod DB 4 · role 6) → `platform/cnpg-databases/`(T054). 부트스트랩 DB `platform`(owner `platform_owner`)은 initdb 산출물이라 Database CR이 아니다 —
  하네스 db-1은 Database CR만 센다.
- CA 미러 ExternalSecret(`pg-main-ca`의 `ca.crt`**만** 앱 ns로 — `dataFrom` 금지) → `platform/kafka-topics/`(T056).
- 검사 Job(`platform/policies/tests/`, T059) · 복구 런북과 복구 클러스터(T058) · 백업 지표·알림(T098).
- Application `platform-cnpg-cluster` → `clusters/oci-k3s/apps/platform-cnpg-cluster.yaml`(T041부터 라이브). 이 PR은 그 파일에 계약 §Application 규약 **예외**
  (`ApplyOutOfSyncOnly=true` + `retry` — 근거는 그 파일 머리 주석 · §5 · VD-11)만 더한다. 검사 7.1이 `source.path = platform/cnpg-cluster`를 대조한다.
- AppProject `platform`도 바꾸지 않는다: 세 객체는 전부 **네임스페이스 범위**이고 `platform` 프로젝트에는 `namespaceResourceWhitelist`/`Blacklist`가 없다(destinations에 `data`
  있음 — 2026-10-13 `clusters/oci-k3s/projects/platform.yaml` 확인). T052의 ClusterImageCatalog(클러스터 범위)와 달리 whitelist 추가가 필요 없다.

**선행 조건**(머지 전 전부 확인 — 하나라도 미충족이면 머지하지 않는다):

| # | 전제 | 확인(agent-view) | 상태 2026-10-13 |
|---|---|---|---|
| P1 | CNPG operator 1.30.0 Running(ns `cnpg-system`) · webhook `Fail` 동작 중 | `kubectl -n cnpg-system get deploy cnpg-cloudnative-pg` READY 1/1 | T052 라이브 |
| P2 | plugin-barman-cloud v0.14.0 Running + operator가 `barman-cloud.cloudnative-pg.io`를 발견 | `kubectl -n cnpg-system get deploy plugin-barman-cloud` 1/1 · operator 로그의 플러그인 줄 | T052 라이브 |
| P3 | ClusterImageCatalog `postgresql-standard-trixie`에 major 18 | `kubectl -n argocd get app platform-cnpg -o jsonpath='{.status.resources[?(@.kind=="ClusterImageCatalog")].status}'` → `Synced`(agent-view는 카탈로그를 직접 읽지 못한다) | T052 라이브 |
| P4 | Secret `data/oci-s3-backup` 존재 · ES Ready=True SecretSynced · 키 셋 `ACCESS_KEY_ID`·`ACCESS_SECRET_KEY`·`REGION` | `kubectl -n data get externalsecret oci-s3-backup`(READY True) · 키 집합은 **운영자**가 키 전용 go-template으로(값 출력 금지 — ES 머리 주석) | PR #46 라이브 · ES refreshTime 06:10:30Z(컨트롤러 전달 — `t053-verify.ps1 -Stage pre` 2026-10-13, 운영자 agent-view 세션 · 빌더는 라이브 접근 없음) |
| P5 | 정책 `data/allow-from-cnpg-operator`(8000) · `cnpg-system/allow-egress-to-data` | `kubectl -n data get networkpolicy allow-from-cnpg-operator` · `kubectl -n cnpg-system get networkpolicy allow-egress-to-data` | PR #46 라이브 |
| P6 | 버킷 `joshuatech-backup` 존재 · `svc-s3-backup`이 그 버킷만 접근 | 운영자(svc-verify): §2 마지막 블록의 `oci os object list` — 머지 전에는 `pg-main/` 접두 0개 | 버킷 존재 = T050 하네스(svc-verify 목록)가 `pg-main/` 0개로 읽음 · `svc-s3-backup` → 그룹 `joshuatech-s3-backup` 가입 = 2026-09-03 완료(모노레포 런북 `bootstrap.md` §T010 후속) · **실효 권한·키 쌍 = VD-1**(첫 completed)이 증명 |
| P7 | 노드 B 여유 — 인스턴스 2Gi + 사이드카 128Mi 요청 | `kubectl describe node -l role=data` Allocated resources | 지시문 확정(현재 요청 합 ≈ 0.46 GiB · 예산 8 GiB) |
| P8 | Vault kv `platform/oci/s3` 키 쌍 정합 | **미증명** — 첫 Backup completed가 증명한다(§1 ③ · VD-1) | 머지로 판정 |
| P9 | 관문: validate 검사 1(kubeconform)의 CRD 스키마 1순위 = **저장소 렌더 CRD 파생**(계약 §validate.yml 1 — 2026-10-13 개정 · 모노레포 `a1bf712`). datreeio 사본(2025-06-17)의 `data.compression lz4` 거부(거짓 음성 — 라이브 CRD는 받는다)는 이 개정으로 해소 | `bash tests/validate.sh` → `FAIL 0` · 검사 1 `platform/cnpg-cluster` 통과 | 관문 수정(`tests/**` 검사 1 두 패스 — **이 PR** 커밋 `63ee725` · 관문 빌더)이 들어왔다. **컨트롤러 단독 실측(2026-10-13 18:13–18:19 KST · 최종 트리 · 다른 하네스 0)**: `bash tests/validate.sh` → `PASS 38 · FAIL 0 · WARN 4(기존 SUC 이미지 digest) · SKIP 0` · 검사 1 `CRD 스키마 파생: CRD 47개 → 스키마 파일 51개(그룹 8개)` · `[PASS] 1 KUST`(`platform/cnpg-cluster` lz4 통과) · 378초. 2026-10-13 fix-r2 시점 `validate.sh` 1회(17:15–17:26 KST)가 실행됐으나 빌더 A 전체 자기검사와 **동시 실행이라 무효**(11.5 FAIL 3 = 외부 fixture `tests/.tmp/fmt-dirsource-link/…` · 자기검사 exit 137 — 두 실행 모두 증거로 쓰지 않는다) → 전체 `validate.sh`·자기검사의 **판정 실행은 다른 하네스가 없을 때**(`ps`로 `bash tests/validate` 프로세스 0 확인 · `tests/.tmp` 부재 확인 — SIGKILL/exit 137이면 EXIT trap이 돌지 않아 잔존하고 11.5가 거짓 FAIL한다) 컨트롤러 단독 1회. 매니페스트 단독 재현(2026-10-13): datreeio 단독 kubeconform `Valid 2 · Invalid 1`(lz4 거짓 음성) → 저장소 렌더 CRD 파생 스키마 1순위 `Valid 3 · Invalid 0 · Skipped 0`. 매니페스트는 바꾸지 않는다 |

---

## 1. 첫 배포에서 일어나는 순서

root(app-of-apps)가 `platform-cnpg-cluster`를 이미 만들어 두었고(T041 — 지금은 렌더 0 · Synced/Healthy), 머지하면 자동 sync(`automated` + `selfHeal`)가 폴링 주기 안에 세 객체를
**리소스 wave 순서로** 적용한다. Argo CD는 wave N의 리소스가 전부 Healthy가 된 뒤 N+1을 적용한다(T052 카탈로그 선례 — 이 저장소의 두 번째 사용 · 첫 **Cluster health 대기**).

| 단계 | 리소스 wave | 무슨 일이 일어나는가 | 예상 시간(VD-1 · VD-7로 실측) |
|---|---|---|---|
| ① | `"0"` ObjectStore | 객체 생성. 내장 health 없음 → 즉시 Healthy. 아직 어떤 파드도 버킷에 접속하지 않는다 | 초 |
| ② | `"1"` Cluster | admission webhook(`vcluster.cnpg.io`, `Fail`) 통과 → operator가 PVC `pg-main-1`(local-path · 노드 B) · initdb Job 생성 → 이미지 pull(카탈로그 major 18 — 노드 B 첫 pull) → initdb(DB `platform` · 체크섬) → Pod `pg-main-1` 기동(instance manager → postgres · 플러그인 **사이드카 주입**(`spec.initContainers`의 `plugin-barman-cloud` · restartPolicy Always = native sidecar) · WAL 아카이브 시작 — 첫 세그먼트는 체크포인트 또는 `archive_timeout` 300초 뒤) → `status.phase = Cluster in healthy state` → Argo health Healthy | 이미지 pull 1–3분 + initdb·기동 ≈ 1분 |
| ③ | `"2"` ScheduledBackup | 생성 즉시 `immediate` → Backup `pg-main-daily-<ts>` → 사이드카가 베이스 백업(빈 DB · lz4)을 `pg-main/pg-main/base/<backupId>/`에 쓰고 WAL 라벨 파일을 `wals/`에 → `status.phase = completed` · `status.backupId` · `status.endWal` | 1–2분 |

전체 ≈ 5분(추정 — VD-1). Application은 ②·③ 동안 `Progressing`, 끝나면 `Synced/Healthy` — 단 ②에서 Cluster가 Argo health **Degraded** phase를 지나면 그 sync 시도는 `Failed`로 끝나고
③이 그 시도에서는 만들어지지 않는다 → Application의 `retry`(limit 5 · 30s ×2 · 최대 5m — 계약 예외 · 자동 sync 기본 retry의 **대체**)가 같은 operation 안에서 다시 시도하고, 재시도에서는 이미 적용돼 in-sync인 ①·②가 task에서 빠져(`ApplyOutOfSyncOnly`) ③만 health 대기 없이 적용된다 — 그 `immediate` Backup은 파드가 Ready가 아니면 `pending`으로 대기한다(아래 표 · VD-7 · VD-11). **③의 completed가 kv 키 쌍 정합의 첫 증명이다**(P8).

**어디서 멈추면 무엇을 보는가**(agent-view로 되는 명령만 · 플러그인 사이드카는 `spec.containers`가 아니라 **`spec.initContainers`**의 고정 이름 **`plugin-barman-cloud`**(native sidecar · restartPolicy Always — plugin v0.14.0 `lifecycle.go`)다 → 로그는 `kubectl -n data logs pg-main-1 -c plugin-barman-cloud`, 필드는 `.spec.initContainers[?(@.name=="plugin-barman-cloud")]`로 본다; `.spec.containers[*]`에는 `postgres`만 나온다):

| 증상 | 가장 먼저 볼 것 | 원인 후보 |
|---|---|---|
| sync 오류 `admission webhook "vcluster.cnpg.io" denied …` / `connection refused` | `kubectl -n cnpg-system get deploy cnpg-cloudnative-pg` · `platform-cnpg` Healthy? | operator 미기동 · webhook 도달 불가(`allow-apiserver-webhook`) — Cluster CREATE가 거부된다(selfHeal 재시도가 operator 복구 뒤 통과) |
| Cluster `phase`가 "Setting up primary"에 머문다 · Pod `Pending` | `kubectl -n data describe pod -l cnpg.io/cluster=pg-main` Events | PVC 바인딩 대기(local-path는 WaitForFirstConsumer — 파드가 잡히면 풀린다) · `role=data` 노드 없음 · 자원 부족(2Gi) · `ImagePullBackOff`(ghcr.io 도달 · 카탈로그 digest) |
| Pod Running인데 `phase`가 Healthy로 안 간다 · `readyInstances 0` | operator 로그 `kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --since=10m \| Select-String 'pg-main'`의 `/pg/status` 연결 실패·timeout | **8000 차단**(`allow-from-cnpg-operator` 누락·오타) — operator가 instance manager API로 상태를 못 읽는다(VD-5) |
| 사이드카 CrashLoop · 로그 `secret "oci-s3-backup" not found` / 키 없음 | `kubectl -n data get externalsecret oci-s3-backup` · `platform-secrets` Healthy? | Secret 없음(ES `SecretSyncedError` — kv 경로 비었음) · 키 이름 불일치(`ACCESS_KEY_ID`·`ACCESS_SECRET_KEY`·`REGION`) |
| ContinuousArchiving `False` · Backup `failed` · 사이드카 로그 `SignatureDoesNotMatch` / `403` / `InvalidAccessKeyId` | `kubectl -n data logs pg-main-1 -c plugin-barman-cloud --since=10m` | **키 쌍 불일치**(kv 값 ≠ 콘솔 Customer Secret Key) → 운영자가 **kv를 정정**(Secret 수동 수정은 ≤5분에 되돌아간다) · `svc-s3-backup` IAM 정책이 버킷을 허용하지 않음 |
| 사이드카 로그에 `x-amz-content-sha256` / checksum 류 400 | 같은 로그 + `kubectl -n data get pod pg-main-1 -o jsonpath='{.spec.initContainers[?(@.name=="plugin-barman-cloud")].env}'`(사이드카는 initContainer — `.spec.containers`로 보면 항상 빈 값이라 "env 미전달"로 오판한다) | 체크섬 env(`AWS_*_CHECKSUM_*=when_required`)가 사이드카에 전달되지 않았다(VD-4) |
| Backup `pending`이 지속 · `kubectl -n data describe backup <name>` Events에 `BackupPending`/`FindingPod`가 30초 간격 | `kubectl -n data get cluster pg-main -o jsonpath='{.status.phase}'` · `kubectl -n data get pod -l cnpg.io/cluster=pg-main` · `kubectl -n argocd get app platform-cnpg-cluster -o jsonpath='{.status.operationState.syncResult.resources[*].message}'` | ScheduledBackup이 Cluster Ready 전에 만들어졌다(재시도 경로 — 위 문단 · VD-7). CNPG 1.30 `backup_controller.go`는 대상 파드 미준비면 Backup을 **`failed`가 아니라 `pending`**으로 두고 30초마다 다시 본다 → 파드 Ready 뒤 **자동 시작**(조치 불필요). 오래 지속되면 Cluster phase·파드를 본다(위 행들) |
| Application `operationState.phase` = `Failed`, 메시지가 Cluster health(`Applying configuration` · `Primary instance is being restarted in-place` 등 — Argo 내장 health lua의 **Degraded** phase) | `kubectl -n argocd get app platform-cnpg-cluster -o jsonpath='{.status.operationState.phase} {.status.operationState.message}'` · `kubectl -n data get cluster pg-main -o jsonpath='{.status.phase}'` | 다단계 sync(첫 배포 = 3장 모두 OutOfSync · 두 장 이상 함께 바뀐 PR)에서 wave 대기 중 Cluster가 Degraded면 gitops-engine이 그 task를 Failed로 닫는다(`sync_context.go` Degraded → OperationFailed · Argo v3.5.2 소스 판독 · 라이브 미실측). **변경 자체는 이미 적용돼 있고 Argo만 Failed**다. 자동 sync operation은 **기본 retry**(limit 5 · 5s ×2 · max 3m ≈ 2.6분 — Argo v3.5.2 `appcontroller.go:2377` `RetryStrategy{Limit: 5}` · `application_defaults.go` `DefaultSyncRetry*`)를 이미 가지며, 그것을 소진해 최종 `Failed`가 되면 **같은 리비전으로 다시 시작하지 않는다**(`appcontroller.go:2391` "failed previous sync attempt … will not retry" — selfHeal이어도). 이 PR의 계약 예외(D8)가 두 겹으로 막는다: Application의 `ApplyOutOfSyncOnly=true`로 **Cluster 한 장 변경은 단일 step**이 되어 health 대기 자체가 없고(reload = `Applying configuration` · 재시작 = in-place restart를 Argo가 기다리지 않는다), 다단계가 남는 경우는 `syncPolicy.retry`가 그 기본값을 **대체**해(`appcontroller.go:2379` `op.Retry = *app.Spec.SyncPolicy.Retry` — limit 5 · 30s ×2 · 최대 5m ≈ 12.5분) CNPG reload/in-place 재시작 창을 덮는다. 재시도에서는 in-sync인 Cluster가 task에서 빠져(gitops-engine `sync_context.go` `filterOutOfSyncTasks`) ScheduledBackup만 health 대기 없이 적용된다 — 그렇게 생긴 Backup은 CNPG가 `pending`으로 들고 있다(위 행). 그래도 `Failed`가 남으면(`retryCount` = 5 — 재시도마다 Cluster가 다시 OutOfSync로 task에 들어가며 Degraded를 만난 경우) Cluster가 `Cluster in healthy state`로 돌아온 뒤 **운영자 수동 Sync**(운영자 전용 명령 · 또는 다음 커밋) — 첫 배포에서 그 경로면 wave 2 ScheduledBackup이 그때까지 없어 하네스 backup-1 · argo-1 FAIL로 드러난다 — VD-11 · §5 |
| Application `operationState.phase` = `Running`이 오래 지속, Cluster phase가 `Cluster cannot proceed to reconciliation due to an error while interacting with plugins` 또는 `Invalid cluster definition` | 같은 두 명령 + `kubectl -n cnpg-system logs deploy/plugin-barman-cloud --since=10m` · operator 로그 | 두 phase는 health lua 표에 **없어** health `Unknown` → 다단계 sync가 끝나지 않고 대기한다(Failed도 아니다). ObjectStore 이름(`barmanObjectName`) · 플러그인 파드 · webhook을 본다 |
| Application `operationState.phase` = `Running`이 오래 지속, Cluster phase가 `Cluster has incomplete or invalid image catalog` · `Unable to create required cluster objects` · `Cluster cannot proceed to reconciliation due to an unknown plugin being required`(health lua **Suspended** — Argo v3.5.2 `health.lua:20–22`; 같은 표의 넷째 `Cluster is unrecoverable and needs manual intervention`은 운영자 개입 경로) | 같은 두 명령 + `kubectl -n argocd get app platform-cnpg -o jsonpath='{.status.sync.status} {.status.health.status}'`(Healthy?) · P3의 `{.status.resources[?(@.kind=="ClusterImageCatalog")].status}` · `kubectl -n cnpg-system get deploy plugin-barman-cloud` | Suspended도 Unknown처럼 sync는 **대기**한다(Failed 아님 — gitops-engine은 Healthy/Degraded만 판정). 원인 후보: 카탈로그 `postgresql-standard-trixie` 미배포 · major 18 항목 부재(P3 재확인 — agent-view는 ClusterImageCatalog를 직접 읽지 못한다) · 필수 객체 생성 실패(RBAC·quota — operator 로그) · 플러그인 `barman-cloud.cloudnative-pg.io` 미배포/미발견(P2 — 플러그인 파드 · operator 로그의 플러그인 줄) |
| Pod `pg-main-1`이 기동 직후 재시작을 반복 · postgres 로그 `invalid value for parameter "wal_compression": "zstd"` | `kubectl -n data logs pg-main-1 -c postgres --previous` | 이미지가 `--with-zstd` 없이 빌드됐다(카탈로그 표준 이미지는 켜져 있는 것으로 알지만 **미실측** — VD-12) → `wal_compression` 줄을 빼는 PR(`lz4`/`pglz`) |
| Backup `completed`인데 버킷에 오브젝트가 없다 | 운영자 `oci os object list`(§2) · `destinationPath` | 다른 버킷/접두에 썼다(`serverName`·`destinationPath` 오타) — 하네스 bucket-1은 `pg-main/pg-main/base/<backupId>/`를 본다 |

---

## 2. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다. **라이브 클러스터 접근 없이 작성했다**(KUBECONFIG 없음 — 기대값은 렌더·CRD에서 왔고 실측은 머지 뒤 VD).

```powershell
kubectl -n argocd get app platform-cnpg-cluster -o jsonpath='{.status.sync.status} {.status.health.status}'
#   Synced Healthy(§1 ②·③ 동안 Progressing이 정상)
(kubectl -n argocd get app platform-cnpg-cluster -o json | ConvertFrom-Json).status.resources | Select-Object kind,name,status,health
#   ObjectStore oci-backups Synced · Cluster pg-main Synced Healthy · ScheduledBackup pg-main-daily Synced = 3행
#   ⚠ agent-view는 objectstores.barmancloud.cnpg.io를 직접 읽지 못한다(agent-view-extra에 없다 — postgresql.cnpg.io만) → ObjectStore는 여기서 본다
kubectl -n data get cluster pg-main
#   INSTANCES 1 · READY 1 · STATUS "Cluster in healthy state" · PRIMARY pg-main-1
kubectl -n data get cluster pg-main -o jsonpath='{.status.phase}|{.status.readyInstances}|{.spec.instances}'
#   Cluster in healthy state|1|1   (하네스 pg-1)
kubectl -n data get cluster pg-main -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
#   ContinuousArchiving=True ContinuousArchivingSuccess · Ready=True   (VD-2 — 플러그인 경로에서 이 조건이 갱신되는지가 질문)
kubectl -n data get pod -l cnpg.io/cluster=pg-main,cnpg.io/podRole=instance -o wide
#   pg-main-1 Running · NODE = 노드 B(라벨 role=data — 하네스 pg-2). READY 열(`2/2` 등)은 kubectl 버전에 따라 native sidecar 표기가 달라 판정 기준으로 쓰지 않는다 — 아래 initContainerStatuses로 본다
kubectl -n data get pod pg-main-1 -o jsonpath='{range .spec.containers[*]}{.name} {.image}{"\n"}{end}'
#   postgres ghcr.io/cloudnative-pg/postgresql:18.6-202610050823-standard-trixie@sha256:79be0d10…(카탈로그 major 18) — containers는 postgres 하나(사이드카는 여기 나오지 않는다)
kubectl -n data get pod pg-main-1 -o jsonpath='{.spec.initContainers[*].name}'
#   bootstrap-controller plugin-barman-cloud   (initContainers 2 — 뒤의 것이 native sidecar · plugin v0.14.0 lifecycle.go가 spec.initContainers에 append)
kubectl -n data get pod pg-main-1 -o jsonpath='{.spec.initContainers[?(@.name=="plugin-barman-cloud")].image}'
#   ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.14.0@sha256:9880817c…(T052 SIDECAR_IMAGE)
kubectl -n data get pod pg-main-1 -o jsonpath='{.status.initContainerStatuses[?(@.name=="plugin-barman-cloud")].ready} {.spec.initContainers[?(@.name=="plugin-barman-cloud")].restartPolicy}'
#   true Always   (사이드카 준비 + native sidecar 확인)
kubectl -n data get pod pg-main-1 -o jsonpath='{.status.qosClass}'
#   Burstable   (VD-14 — 사이드카 requests ≠ limits · CPU limit 없음 → Guaranteed 아님 · PG_OOM_ADJUST_VALUE=0 미적용. §4)
kubectl -n data get scheduledbackup
#   pg-main-daily · 하네스 backup-1: cluster pg-main인 ScheduledBackup 정확히 1 · schedule '0 0 17 * * *' · suspend ≠ true
kubectl -n data get backup -o 'custom-columns=N:.metadata.name,P:.status.phase,ID:.status.backupId,BEGIN:.status.startedAt,END:.status.stoppedAt,ENDWAL:.status.endWal,M:.spec.method'
#   pg-main-daily-<ts> completed <backupId> … <endWal> plugin   (하네스 backup-2: completed ≥ 1 · 최신 ≤ 25h)
#   ⚠ `-o` 값 전체를 한 쌍의 작은따옴표로 감싼다(PowerShell — ESO README §7 각주)
kubectl -n data get pvc
#   pg-main-1 Bound 40Gi local-path   (VD-8 — 노드 B: `kubectl -n data get pvc pg-main-1 -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}'`)
kubectl -n data get svc
#   pg-main-rw · pg-main-ro · pg-main-r — 5432
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --since=15m | Select-String 'pg-main' | Select-String -Pattern 'error|timeout|refused'
#   0행   (VD-5 — operator → 인스턴스 8000 도달 · 5432 불필요 확인)
kubectl -n data logs pg-main-1 -c plugin-barman-cloud --since=15m | Select-String -Pattern 'SignatureDoesNotMatch|403|x-amz-content-sha256|checksum|error'
#   0행   (VD-4)
kubectl top pod -n data
#   pg-main-1 — requests 1 CPU/2Gi(+ 사이드카 50m/128Mi) 대비 실사용(VD-6 · T097 교정 — 사이드카를 requests = limits로 올려 Guaranteed로 갈지의 입력값 · VD-14)
kubectl get events -n data --field-selector reason=FailedCreate | Select-String -Pattern 'podsecurity'
#   0행   (PSA baseline 통과)
```

**운영자 전용**(admin kubeconfig 또는 svc-verify):

```powershell
kubectl -n data get secret -o name | Select-String 'pg-main'
#   pg-main-ca · pg-main-server · pg-main-replication · pg-main-app = 4(superuser 없음). agent-view는 secrets를 읽지 못한다 — 이름만 출력, 값 금지
kubectl -n data get secret oci-s3-backup -o 'go-template={{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
#   ACCESS_KEY_ID · ACCESS_SECRET_KEY · REGION 셋(ES template Replace의 증명 — ES 머리 주석 VD)
# OCI 버킷(svc-verify 세션 — 하네스 data.tests.ps1과 같은 호출. 세션 갱신: oci session authenticate --profile-name svc-verify)
oci --profile svc-verify --auth security_token os object list --bucket-name joshuatech-backup --prefix pg-main/ --all --fields name,size,timeCreated --output json
#   pg-main/pg-main/base/<backupId>/…(backup.info · data 아카이브 — 모양은 VD-3) ≥ 1 · 그 backupId = 최신 completed Backup의 status.backupId(하네스 bucket-1)
#   pg-main/pg-main/wals/<16hex>/<24hex>.zst(+ <24hex>.<off>.backup.zst 라벨) — 유휴 클러스터는 활동이 없으면 300초마다 늘지 않는다(하네스 bucket-2 유휴 가지 · VD-2)
```

**모노레포 하네스**(KUBECONFIG = agent-view · svc-verify 세션 · 한 번에 하나만 — Git Bash MSYS fork 거짓 FAIL):

```powershell
pwsh -NoProfile -File tests/platform/data.tests.ps1
#   기대 9 PASS(gate-1..3 · pg-1 · pg-2 · backup-1 · backup-2 · bucket-1 · bucket-2) / 6 FAIL(db-1 · db-2 · role-1 · role-2 · job-1 · job-2 = T054) / 1 SKIP(env-1 until T075)
#   bucket-1·bucket-2는 svc-verify 세션이 필요하다 — 세션 없으면 그 둘은 FAIL(사유 OCI · 거짓 FAIL)
pwsh -NoProfile -File tests/platform/cluster.tests.ps1
#   argo-4-pg-main PASS(Cluster data/pg-main에 정확히 Delete=false,Prune=false) — T052까지는 T049 허용 목록 SKIP이었다
```

---

## 3. VD(검증 후 결정 — 머지 뒤 실측해 기록)

| ID | 무엇을 | 판정 |
|---|---|---|
| VD-1 | 첫 Backup `completed`까지 소요 시간(머지 → ③ completed) · 재시도 횟수 · **kv 키 쌍 정합의 첫 증명** | completed면 P8 닫힘. `SignatureDoesNotMatch`·403이면 kv 정정 뒤 재시도(§1 표) |
| VD-2 | Cluster `status.conditions[type=ContinuousArchiving]`이 **플러그인 경로**에서 갱신되는가(T050 bucket-2 유휴 가지의 전제 — build-notes 「T050 · T051」) | True로 갱신되면 하네스 규칙 유지. 갱신되지 않으면 T059에서 규칙 재설계 |
| VD-3 | 오브젝트 배치 `pg-main/pg-main/{base/<backupId>/…, wals/<16hex>/<24hex>.zst}` — serverName 기본값 · zstd 확장자 | 접두가 다르면 하네스 bucket-1·2 전제가 틀린 것 → 매니페스트가 아니라 하네스 `$serverName`을 본다 |
| VD-4 | OCI S3 호환 + 체크섬 env로 오류 0(사이드카 로그 `kubectl -n data logs pg-main-1 -c plugin-barman-cloud`의 `SignatureDoesNotMatch` · `x-amz-content-sha256` · checksum 400) | 오류 0이면 env 유지. checksum 400이면 env 전달 경로 확인 — `kubectl -n data get pod pg-main-1 -o jsonpath='{.spec.initContainers[?(@.name=="plugin-barman-cloud")].env}'`(사이드카는 `spec.initContainers`의 native sidecar — `spec.containers`로 보면 빈 값) |
| VD-5 | operator → 인스턴스 **8000**(operator 로그에 `/pg/status` 수집 오류 0 · `status.instancesStatus` 갱신) · **5432 불필요** 확인. 판정은 이 둘로만 — 첫 백업 completed는 8000 도달의 증거가 **아니다**(백업 시작은 API 서버 경유 `pods/exec` 스트림 — `method: plugin`도 같은 exec 경로다: CNPG 1.30 `api/v1/backup_funcs.go:319–321` `IsManagedByInstance() = Plugin \|\| BarmanObjectStore` → `internal/controller/backup_controller.go:243` Reconcile `case backup.Spec.Method.IsManagedByInstance(): startBackupManagedByInstance` → `startInstanceManagerBackup`(:970) → `utils.ExecCommand`(:996) → 인스턴스 매니저 `pkg/management/postgres/webserver/plugin_backup.go:78–85` `repository.New()` + `pluginClient.NewClient`가 `/plugins` unix 소켓으로 사이드카를 부른다(plugin v0.14.0 `lifecycle.go:411` healthcheck `unix` · `:504` `/plugins` emptyDir · 컨테이너 포트 없음) — 네트워크 정책 밖 · data → cnpg-system 9090 불필요) | 통과면 계약 매트릭스 행 그대로(행의 "백업 요청" 문구는 컨트롤러가 "`/pg/status` 상태 수집 · in-place update"로 정정). 5432 오류가 보이면 계약 개정 뒤 정책 추가(열지 않고 시작한다) |
| VD-6 | `kubectl top` 실사용(postgres + 사이드카) vs requests 1 CPU/2Gi + 50m/128Mi | 기록만 — T097이 교정 |
| VD-7 | Argo health가 initdb 동안 Progressing → Healthy로 바뀌는 시간 = wave `"2"` 대기 시간 · ScheduledBackup이 Cluster Healthy **뒤에** 만들어졌는가(`creationTimestamp` 비교) | 뒤면 리소스 wave 설계 유지. 앞이어도(재시도 경로) Backup `pending` → 파드 Ready 뒤 자동 시작이 정상 경로다(§1 표) — `failed`가 나오면 그때 조사 |
| VD-8 | PVC `pg-main-1` 바인딩 노드 = 노드 B(`selected-node` 어노테이션) | 노드 A면 nodeSelector 또는 SC 문제 — 즉시 조사(데이터가 그 노드에 남는다) |
| VD-9 | Secret `pg-main-ca` 생성(`ca.crt`·`ca.key`) — T056 CA 미러 ES의 원본 전제 | 있으면 T056 진행. 없으면 `certificates` 기본 동작 확인 |
| VD-10 | 사이드카가 ObjectStore·Secret을 읽는 신원과 RBAC — 플러그인 `rbac/ensure.go`(`EnsureRole` · `EnsureRoleRules` · `patchRole` · `EnsureRoleBinding`, Cluster가 owner)가 ns `data`에 ensure/patch하는 Role·RoleBinding의 **이름·규칙(동사·리소스)** · 바인딩 주체 = Cluster SA `pg-main`인지 | 기록 → README §0 "런타임 객체" 문구 교정. 권한 부족 오류가 보이면 플러그인 이슈 확인 |
| VD-11 | Argo `operationState.phase` 전이 — 첫 배포(wave 1 대기 중 Cluster가 Degraded phase를 지났는가 · ScheduledBackup이 만들어졌는가)와 **첫 파라미터 변경**(`Applying configuration`/in-place 재시작 → sync `Failed`?)에서 `kubectl -n argocd get app platform-cnpg-cluster -o jsonpath='{.status.operationState.phase} {.status.operationState.message} retry={.status.operationState.retryCount}'` 기록 · Degraded 전이 발생 여부 · **retry 소모 수**(`retryCount`) · 수동 Sync가 필요했는가 · 첫 sync 뒤 Cluster 리소스가 `Synced`로 **안정**되는가(CNPG webhook 기본값 때문에 영구 `OutOfSync`면 `ApplyOutOfSyncOnly`의 "한 장 변경 = 단일 step" 전제가 깨진다 — 같은 질문이 모노레포 `research.md` R5 미확인 항목 "Argo CD에서 CNPG Cluster CR의 status/annotation 변경에 따른 OutOfSync 노이즈가 있는지(ignoreDifferences 필요 여부) 실측"(1860행)이다. 판정 보조: 라이브 `kubectl -n data get cluster pg-main -o yaml`의 `spec.postgresql.parameters` 개수가 8을 크게 넘으면 mutating webhook `Default()`가 CNPG 기본값을 합쳐 spec을 넓힌 것 — 그때는 컨트롤러에 보고 · 이 디렉터리 범위 밖) | 계약 §Application 규약 **예외(2026-10-13 T053)**가 이 Application에 `ApplyOutOfSyncOnly=true` + `retry`(limit 5 · backoff 30s ×2 · maxDuration 5m)를 정했다 — 이 PR이 `clusters/oci-k3s/apps/platform-cnpg-cluster.yaml`에 반영했다(근거는 그 파일 머리 주석). VD-11은 그 예외의 효과(Failed 0 · 수동 Sync 0 · `retryCount`)를 실측해 기록한다. `retryCount` 해석: ≤ 5인 채 `Succeeded` = retry가 흡수(기본 retry 진행 중을 '수동 Sync 필요'로 오판하지 않는다) / `retryCount` = 5 + `Failed` = 창(≈12.5분) 부족 → 수동 Sync + 창 재검토. **영구 `OutOfSync`면 1차 조치 = Application `syncOptions`에 `ServerSideDiff=true`**(Argo CD ≥ 2.10 — SSA dry-run 기반 diff가 webhook 기본값을 흡수) 추가 — 계약 §Application 규약 예외 문단 개정 뒤(컨트롤러 · 이 PR에는 없다 · research 1860행 미확인 항목을 그 실측으로 닫는다); 2차 = `ignoreDifferences`(실제 변경을 숨기므로 `spec.postgresql.parameters` 같은 넓은 경로는 피한다) |
| VD-12 | `wal_compression: zstd`가 실제 기동됐는가 — 운영자 `kubectl -n data exec pg-main-1 -c postgres -- psql -c 'SHOW wal_compression'` = `zstd`(PG가 `--with-zstd`로 빌드돼야 한다 — PGDG trixie 패키지는 그렇다고 알지만 이 저장소에서 미실측) | zstd면 유지. 기동 실패(§1 표 `invalid value for parameter`)면 파라미터를 빼는 PR |
| VD-13 | 보존 만료(머지 + 31일) 뒤 `(kubectl -n data get backup --no-headers \| Measure-Object).Count` ≈ 30 — 사이드카 `deleteBackupsNotInCatalog`(주기 1800초)가 카탈로그에 없는 Backup 객체를 지우는가 | 수렴하면 §5 문구 유지. 계속 늘면 플러그인 이슈 확인 — T059/T098 인계 |
| VD-14 | 파드 `pg-main-1`의 QoS 클래스 — `kubectl -n data get pod pg-main-1 -o jsonpath='{.status.qosClass}'`. 기대 **Burstable**: Cluster 컨테이너는 requests = limits지만 플러그인 사이드카(`spec.initContainers` `plugin-barman-cloud` · requests 50m/128Mi · limits memory 256Mi · CPU limit 없음 → requests ≠ limits)가 같은 파드에 있고 K8s QoS는 init 컨테이너 포함 전 컨테이너 조건이다 → CNPG의 `PG_OOM_ADJUST_VALUE=0`(Guaranteed 조건 — 1.30 `docs/src/resource_management.md:50–54`)은 적용되지 않는다. 운영자 보조(선택): postmaster 프로세스의 `/proc/<pid>/oom_score_adj` — Guaranteed면 postmaster -997 · 자식 0, Burstable이면 kubelet 산식(1000 − 1000 × requests/노드 메모리)의 양수 | Burstable이면 문서(§4 · `cluster-pg-main.yaml` 머리 주석)대로 — 기록만. Guaranteed로 갈지는 **T097**이 VD-6 실측 뒤 결정: ObjectStore `instanceSidecarConfiguration.resources`를 requests = limits(cpu 포함)로 올리면 사이드카 CPU 상한이 백업 압축(lz4·zstd는 사이드카 안에서 돈다)을 늦추고 requests 상향은 2 OCPU 노드 B 예산(T055 Kafka · T057 Dragonfly 동거)을 건드린다 — 이 PR은 바꾸지 않는다 |

---

## 4. 값 선택 근거

| 값 | 출처 | 비고 |
|---|---|---|
| `instances: 1` · `nodeSelector role=data` · `enablePodAntiAffinity false` | 과제 문면 · research CNPG-D4 | 노드 B 하나(plan A14). HA 아님 — 재시작 = 다운타임(§5) |
| `imageCatalogRef` major 18(`apiGroup postgresql.cnpg.io` · `ClusterImageCatalog postgresql-standard-trixie`) | 과제 문면 · T052 카탈로그 | 18.6 digest는 카탈로그가 고정. `imageName`은 적지 않는다(함께 쓰면 imageName 우선) |
| `storage local-path 40Gi` | 과제 문면 · research CNPG-D4 | 확장 불가·용량 미강제 — 명목값. 실제 한도 = 노드 B 부트 볼륨 100 GB. `walStorage` 미분리(추가 뒤 제거 불가) |
| `resources` requests = limits 1 CPU/2Gi | 과제 문면 · research CNPG-D4 | Cluster 컨테이너 requests = limits(문면 — CNPG는 `pkg/specs/pods.go:261`에서 bootstrap-controller init 컨테이너에도 같은 값을 복사)지만 플러그인 사이드카(requests ≠ limits · CPU limit 없음 — 아래 사이드카 행)가 파드에 함께 있어 **파드 QoS는 Burstable**이다 — CNPG의 `PG_OOM_ADJUST_VALUE=0`(Guaranteed 조건 · 1.30 `resource_management.md:50–54`) 적용은 기대하지 않는다(라이브 확인 = **VD-14**; research CNPG-D4의 "Guaranteed QoS" 서술은 사이드카를 빼고 본 것 — 정정은 build-notes · 컨트롤러). Cluster 컨테이너에 CPU limit을 **두는** 것은 문면이자 저장소 관례(CPU limit 없음)의 의도된 예외지만 그것만으로 Guaranteed가 되지는 않는다. Guaranteed로 만들려면 ObjectStore `instanceSidecarConfiguration.resources`를 requests = limits(cpu 포함)로 — 사이드카 CPU 상한이 백업 압축(lz4·zstd는 사이드카 안에서 돈다)을 늦추므로 **T097에서 VD-6 실측 뒤 결정**(이 PR은 바꾸지 않는다) |
| `shared_buffers 512MB` · `max_parallel_workers 2` · `max_connections 100` · `archive_timeout 300` | 과제 문면 | 300 = 초(기본 단위 s) = 5분 = PITR RPO ≤ 5분(CNPG 기본 `5min`의 재정의 — 고정 파라미터가 아니라 webhook 거부 없음). `"5min"`으로 쓰지 않는다(대조 단순화). `max_worker_processes`는 CNPG 기본 **32** 유지(문면 밖 · `max_parallel_workers 2 ≤ 32` 유효 · research 함정은 둘을 함께 낮추라 했다 — 의도된 선택 · T097 교정 대상) |
| `effective_cache_size 1536MB` · `work_mem 8MB` · `maintenance_work_mem 128MB` · `wal_compression zstd` | research CNPG-D4 스니펫(research.md 1654–1658행) | 2 OCPU · 2Gi 맞춤. 이론 최대 `work_mem 8MB × max_connections 100` ≈ 800MB + shared 512MB + maintenance 128MB ≈ 1.4GB < 2Gi(사이드카는 별도 128Mi/256Mi — 단 그 사이드카 때문에 파드 QoS가 Burstable이라 노드 B 메모리 압박 시 이 산술이 OOM-kill 순서·eviction 후순위를 보장하지는 않는다 · VD-14). 스니펫의 `pg_stat_statements.max`와 `postgresql.extensions`(pg_bigm)는 문면 밖 — 넣지 않는다(아래) |
| `enableSuperuserAccess false` | 과제 문면 · research CNPG-D4 | postgres 비밀번호 NULL · `pg-main-superuser` Secret 없음. 관리는 운영자 `kubectl cnpg psql pg-main` |
| `bootstrap.initdb database platform · owner platform_owner · dataChecksums true` | research CNPG-D4 스니펫(1666–1668행) | 부트스트랩 산출물 — pod DB 4개는 T054 Database CR. 체크섬은 initdb 때만 |
| `plugins[] barman-cloud.cloudnative-pg.io · isWALArchiver · barmanObjectName oci-backups` | 과제 문면 · plugin 문서 | in-tree `spec.backup` 없음(1.31 제거). `serverName` 파라미터 미기재(기본 pg-main) |
| ObjectStore `destinationPath s3://joshuatech-backup/pg-main/` | 과제 문면(`jt-backup` → 실명 예외) · 런북 §0 · build-notes 「T050 · T051」 | research CNPG-D6의 `joshuatech-cnpg-backups`가 아니다 — 버킷은 하나(`joshuatech-backup`), 접두로 나눈다 |
| `endpointURL https://axvjykgvo2m1.compat.objectstorage.ap-chuncheon-1.oraclecloud.com` | 모노레포 `infra/*/backend.tf`(tofu S3 백엔드와 같은 도메인) | research CNPG-D6의 `oci.customer-oci.com` 표기 대신 실측 도메인. 주소 방식: boto3는 커스텀 `endpoint_url`이면 path-style을 강제한다(botocore `args.py` `force_path_style = addressing_style != 'virtual'`) — OCI 호환 API가 요구하는 path-style(research 함정)과 맞아 따로 설정하지 않는다 |
| `s3Credentials` 키 참조 3(`region`도 참조) | CRD 원문(v0.14.0 — `region: {name, key}`) · research CNPG-D6(AWS_DEFAULT_REGION → SigV4) | Secret 이름 `oci-s3-backup` · 키 이름은 ES template과 글자 단위 일치 |
| `wal.compression zstd · maxParallel 2` / `data.compression lz4 · jobs 1` | 과제 문면 · research CNPG-D6 · CRD enum(data에 zstd 없음) | `.zst` = 하네스 bucket-2 허용 확장자. 작은 병렬도 = 1 CPU 인스턴스 |
| `retentionPolicy "30d"` | 과제 문면 | research CNPG-D6 초판 14d보다 문면 우선. 패턴 `^[1-9][0-9]*[dwm]$`. 비용은 §5 |
| 사이드카 `env AWS_REQUEST_CHECKSUM_CALCULATION · AWS_RESPONSE_CHECKSUM_VALIDATION = when_required` | 과제 문면 · plugin 문서(boto3 ≥ 1.36 CRC32 ↔ OCI S3 호환) · T052 README §8 인계 | VD-4 |
| 사이드카 `resources 50m/128Mi · limits memory 256Mi` · `retentionPolicyIntervalSeconds 1800` | 지시문(컨트롤러 결정 §3.2 — fix-r3에서 재확인 · 유지) · CRD 기본값 명시 | CPU limit 없음(저장소 관례). 이 requests ≠ limits가 파드 `pg-main-1`의 QoS를 **Burstable**로 만든다(위 `resources` 행 · VD-14). 이번 PR에서 바꾸지 않는 이유: 사이드카 CPU limit은 백업 압축(lz4·zstd는 사이드카 안에서 돈다)을 throttle하고, requests 상향은 2 OCPU 노드 B 예산(T055 Kafka · T057 Dragonfly 동거)을 건드린다 → T097이 VD-6 실측 뒤 결정 |
| ScheduledBackup `0 0 17 * * *` · `immediate true` · `backupOwnerReference self` · `method plugin` | 과제 문면 · CRD(6필드 · enum) · research CNPG-D6 | 02:00 KST = 업그레이드 창 03:00–05:00 앞(research 18:00 UTC 아님). `suspend` 미기재(하네스 backup-1) |
| 리소스 wave `"0"`·`"1"`·`"2"` | T052 카탈로그 선례 · Argo wave 의미(N 전부 Healthy → N+1) | Application 표의 숫자가 아니다. ScheduledBackup `immediate`가 Cluster Healthy 뒤여야 한다 |
| `Delete=false,Prune=false` — Cluster · ObjectStore | 계약 §삭제 보호(`Cluster pg-main` · `ObjectStore oci-backups` — 2026-10-13 T053 추가: 지우면 WAL 아카이브 즉시 중단 · 백업 카탈로그 접근 상실) | 하네스 argo-4-pg-main 정확 문자열. ScheduledBackup에는 붙이지 않는다(상태 없음) |

**적지 않은 것과 이유**: `spec.backup`(in-tree — 1.31 제거) · `walStorage`(비가역) · `managed.roles`(T054 DatabaseRole CRD) · `monitoring.enablePodMonitor`(PodMonitor CRD 없음 — T098) ·
`postgresql.pg_hba`(CNPG 기본 scram-sha-256 + TLS) · `certificates`(기본 자체 CA = `pg-main-ca`) · `primaryUpdateStrategy`(인스턴스 1) · `imageName`(카탈로그와 충돌) ·
`ObjectStore.spec.configuration.serverName`(기본 = 클러스터 이름 — 하네스 전제) · `ScheduledBackup.spec.suspend/target/online`(기본값 · 하네스) · `pluginConfiguration.parameters`(ObjectStore 선택은 Cluster 쪽) ·
`postgresql.extensions`(research CNPG-D4 스니펫의 `pg_bigm` — `image.reference: ghcr.io/<org>/pg_bigm:…` 자리표시자 · 문면 밖 · 이미지 미정 · 후속 과제 미지정).

---

## 5. 운영 위험 · 되돌리기

Application `platform-cnpg-cluster`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`이고, Cluster·ObjectStore에는 객체 수준 `Delete=false,Prune=false`가 있다. 그래서

> **Cluster 삭제 = 데이터 삭제.** local-path PVC의 reclaimPolicy는 Delete다 — Cluster가 지워지면 PVC `pg-main-1`과 노드 B의 데이터 디렉터리가 함께 사라진다.
> 남는 것은 **버킷의 베이스 백업 + WAL**뿐이다(T058 복구 런북). `Delete=false,Prune=false`는 **Argo 경로**(cascade · prune)만 막고 `kubectl delete`는 막지 않는다.
> **git revert 머지가 먼저, 수동 삭제가 그다음.** git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다(새 initdb = **빈 DB** — 데이터는 돌아오지 않는다).

**되돌리기 순서**(운영자 · admin kubeconfig):

1. revert PR 머지 → `kustomization.yaml`이 `resources: []` 뼈대로 복귀 → 렌더 0 → hard refresh. 객체는 그대로 남고 Application은 **`OutOfSync`가 정상**이다
   (`prune: false` + 객체의 `Prune=false` — 하네스 `argo-1`은 그동안 FAIL, `argo-4-pg-main`은 객체가 남아 있으면 PASS — operator·DB 생존 신호로 쓰지 않는다).
2. **삭제 전 확인**: `kubectl -n data get backup`에서 마지막 Backup `completed`와 `status.backupId` · 운영자 `oci os object list`로 그 `base/<backupId>/`와 `wals/` 최신 세그먼트가
   버킷에 있는지(§2). 필요하면 운영자 수동 `Backup`(`method: plugin`)을 하나 더 만들어 completed를 기다린다 — 그것이 마지막 복구 지점이다.
3. 수동 삭제, **이 순서로**:
   ```powershell
   kubectl -n data delete scheduledbackup pg-main-daily     # ① Backup 객체는 ownerReference(self)로 함께 GC — 버킷 데이터는 그대로
   kubectl -n data delete cluster pg-main                   # ② operator가 Pod · PVC(= 데이터) · Service · Secret 4장 · initdb Job을 정리한다. operator가 살아 있어야 한다(T052 README §6)
   kubectl -n data delete objectstore oci-backups           # ③ 마지막 — Cluster보다 먼저 지우면 WAL 아카이브가 즉시 멈추고 WAL이 PVC에 쌓인다
   ```
   Secret `oci-s3-backup`(ES)과 정책·ns는 이 디렉터리 소유가 아니라 **건드리지 않는다**(ES는 `platform/secrets/README.md` §5의 절차로만).

**그 밖의 위험**:

- **ObjectStore만 사라지거나 자격이 깨지면** WAL 아카이브가 실패하고 PostgreSQL은 아카이브되지 않은 WAL을 **지우지 않는다** → PVC가 찬다(local-path 40Gi 명목 · 노드 B 부트 볼륨
  100 GB가 실제 한도 — 디스크가 차면 노드 B 전체가 위험하다). ContinuousArchiving `False`가 첫 신호 — 알림은 T098(`CnpgBackupStale`류)까지 **없다**. 그 전에는 §2 명령을 운영자가 돈다.
- **카탈로그/이미지 갱신 · 재시작이 필요한 파라미터 변경**(`shared_buffers` · `max_connections`) = 인스턴스 1이라 PG 재시작 **수 초 다운타임** → 유지보수 창(03:00–05:00 KST)에
  머지한다. operator 업그레이드는 `ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES`로 재시작 없이 넘어간다(T052).
- **`retentionPolicy 30d`의 비용**: 매일 베이스 백업(lz4) 30개 + 30일치 WAL(zstd)이 버킷에 남는다 — 빈 DB에서는 작지만 데이터가 늘면 선형으로 는다. 버킷은 **versioning Enabled**이고 lifecycle은 `previous-versions-delete-60d`(이전 버전만 60일 뒤 DELETE — 모노레포 `infra/oci/storage.tf`; 현재 버전을 지우는 규칙은 없어 barman 보존과 충돌하지 않는다) → barman이 지운 베이스·WAL은 삭제 표식 뒤 **이전 버전으로 60일 더** 남는다 = 저장 비용은 보존 30d + 잔존 60d이고, 동시에 실수 삭제의 **60일 복구 창**(운영자가 콘솔/CLI로 이전 버전 복원)이다. **60일 창은 실수 삭제용이다 — 키 유출 방어가 아니다**: `svc-s3-backup`의 정책은 `allow group joshuatech-s3-backup to manage objects in tenancy where target.bucket.name = 'joshuatech-backup'`(모노레포 `infra/oci/iam.tf`)이고 `manage objects`는 OBJECT_VERSION_DELETE를 포함하므로, 사이드카가 쓰는 Secret `oci-s3-backup`의 키가 유출되면 S3 API로 현재 버전뿐 아니라 이전 버전까지 지울 수 있다. barman은 버전 삭제를 쓰지 않는다(보존 정리 = 현재 버전 DELETE만) → 권한 분리(`iam.tf`의 lifecycle 서비스 주체 정책이 이미 쓰는 `where all {target.bucket.name = '…', request.permission != 'OBJECT_VERSION_DELETE'}` 평면형으로 좁히기) · 버전 삭제 거부 정책은 **infra 후속 — T097/T116 인계**(§6 · 적용 뒤 백업·보존 정리 1주기가 정상인지 확인). PAYG 요금은 OCI 콘솔에서 본다(T097).
  K8s `Backup` 객체도 ≈ 30개에서 유지된다 — 사이드카가 보존 적용 뒤 카탈로그에 없는 Backup 객체를 지운다(plugin v0.14.0 `retention.go` `deleteBackupsNotInCatalog` · 주기 `retentionPolicyIntervalSeconds`
  1800초 · primary에서만 — VD-13). 반대 방향(Backup CR·ScheduledBackup 삭제 → 버킷 오브젝트 삭제)은 **없다**(CNPG-I `backup.proto`의 RPC는 GetCapabilities·Backup 둘뿐 · CNPG 1.30 `backup_controller.go`에 finalizer 없음 — 2026-10-13 원문 확인).
- **파라미터 변경 PR의 Argo sync가 `Failed`로 끝날 수 있는 경로와 그 방어**(§1 표): 예외 없이 표준 syncPolicy만 두면 세 객체의 리소스 wave 때문에 sync가 항상 다단계고, Cluster가 `Applying configuration`·in-place 재시작(health **Degraded**)을
  지나면 gitops-engine이 그 sync를 Failed로 닫는다. 변경은 이미 라이브이고 Argo만 Failed — 자동 sync operation의 **기본 retry**(limit 5 · 5s ×2 · max 3m ≈ 2.6분)를 소진해 최종 Failed가 되면 **같은 리비전으로 다시 시작하지 않는다**(`appcontroller.go:2377` · `:2391`). 그래서 계약 §Application 규약 **예외(2026-10-13 T053)**로 이 PR이 Application
  `platform-cnpg-cluster`(`clusters/oci-k3s/apps/platform-cnpg-cluster.yaml` — 머리 주석에 근거)에 `ApplyOutOfSyncOnly=true`(한 장 변경 = 단일 step → health 대기 없음 · 첫 배포는 전부 OutOfSync라 wave 순서 유지) +
  `retry`(limit 5 · backoff 30s ×2 · maxDuration 5m ≈ 12.5분 — 새 안전망이 아니라 기본 retry를 **대체**해 창을 넓힌 것 · 두 장 이상 변경이 남긴 다단계용)를 넣었다. 둘 다 소스 판독에 근거한 방어이고 라이브 미실측이다 — 효과는 VD-11로 기록하고, 그래도 `Failed`가 남으면 §1 표의 운영자 수동 Sync가 최후 수단이다.
- **노드 B 재부팅**(T048 측정 ≈ 6분 재조정): 인스턴스 1이라 그 동안 DB 불가 — 앱 재시도 정책(T075)의 전제. WAL 아카이브는 재기동 뒤 이어진다.
- **노드 B 재이미지 · 부트 볼륨 교체 · OCI 인스턴스 재생성 = PVC `pg-main-1` 데이터 소실**(local-path = 노드 B 디스크 — Argo `Delete=false`도 CNPG도 막지 못하는 경로). T015(두 노드 재이미지) · T048(재부팅 측정)처럼 일상 절차였지만 이 PR부터는 **pg-main 전체 소실 = 버킷에서 PITR 복원**이 된다. 전제(순서 고정): ① 직전 Backup `completed`와 `status.backupId` 확인 ② 운영자 `oci os object list`로 `base/<backupId>/`와 최신 `wals/` 세그먼트 확인 ③ 가능하면 수동 `Backup` 1회 → completed 대기 → 그 뒤 진행. 복원 절차는 T058 런북 — **그 전까지 노드 B 재이미지는 하지 않는다**(모노레포 런북 `bootstrap.md` 재이미지 절 머리에 같은 선행 조건 한 줄 = 컨트롤러 · §6).
- **`enableSuperuserAccess: false`**: 긴급 관리 SQL은 `kubectl cnpg psql pg-main`(운영자 · 파드 안 peer 인증)뿐이다 — `postgres` 원격 로그인 경로를 **열지 않는다**(값을 `true`로 바꾸면
  operator가 `pg-main-superuser` Secret을 만든다 — 하지 않는다).
- **삭제 보호 어노테이션의 글자**: `Delete=false,Prune=false`(공백 없음 · 이 순서)를 바꾸면 하네스 argo-4-pg-main이 FAIL하고, Argo는 알 수 없는 옵션을 **조용히 무시**해 보호가 사라진다.

---

## 6. 인계

- **T054(`platform/cnpg-databases/`)**: `Database` 4(identity_admin · dev_identity_admin · authentik · openfga — owner `<app>_owner`) · `DatabaseRole` 6(app 2 **`login: true` 명시** · pod owner 2
  `bypassrls: true` · 공유 owner 2). 전부 `cluster.name: pg-main`(1.30부터 immutable). 비밀번호 Secret은 Vault → ESO(`vault-data`). 하네스 db-1·db-2·role-1·role-2·job-1·job-2가 PASS로 바뀐다.
- **T056(`platform/kafka-topics/`)**: CA 미러 ES — `remoteRef.key: pg-main-ca` · `property: ca.crt`**만**(`dataFrom` 금지 — `ca.key` 복사 방지). 원본 Secret은 VD-9.
- **T058(복구 런북)**: PITR은 **클러스터 전체**(재해 복구 전용) — 새 Cluster(`pg-main-restored`류)를 `bootstrap.recovery.source` + `externalClusters[].plugin`(barmanObjectName `oci-backups` ·
  serverName `pg-main`)으로 만들고 자기 아카이브는 `plugins[].parameters.serverName`을 다른 이름으로(research CNPG-D8 — 같은 serverName으로 아카이브하면 WAL 덮어쓰기 위험). 단일 DB 복구 =
  side Cluster에서 dump/restore. 복구 드릴의 오브젝트(다른 serverName)는 하네스 bucket-*가 무시한다. **노드 B 재이미지 · 부트 볼륨 교체 전 선행 조건**(§5 — 직전 completed · 버킷 오브젝트 확인 ·
  수동 Backup)을 모노레포 런북 `bootstrap.md`의 재이미지 절 머리에 한 줄로(컨트롤러) — 복구 런북이 나오기 전까지 노드 B 재이미지 금지.
- **T097**: 배치 단언(Pod `pg-main-1` = 노드 B) · 자원 실측 교정(VD-6 · 사이드카 포함) · 버킷 비용 · **파드 QoS 결정**(VD-14 — ObjectStore `instanceSidecarConfiguration.resources`를 requests = limits(cpu 포함)로 올려 Guaranteed로 갈지: 사이드카 CPU 상한 = 백업 압축 속도 trade-off · 노드 B 예산(T055 Kafka · T057 Dragonfly 동거) — VD-6 실측이 입력) · **S3 키 권한 분리**(K18 — `infra/oci/iam.tf` `svc-s3-backup` 정책에 `request.permission != 'OBJECT_VERSION_DELETE'` · 적용 뒤 백업·보존 정리 1주기 정상 확인 · T116 보안 마무리의 버킷 접근 정책 재확인과 공유).
- **T098(`platform/monitoring`)**: 인스턴스 exporter 9187 스크레이프(정책 `allow-scrape-from-monitoring` 행 준비됨) · `CnpgBackupStale`(최신 completed > 25h) · ContinuousArchiving False 알림 ·
  PVC 사용량(WAL 적체) 알림.
- **T059**: VD-2 결과에 따라 하네스 bucket-2 유휴 가지 규칙 유지/재설계 · VD-13(Backup 객체 수 수렴 — T098과 공유).
- **컨트롤러(계약 · Application · 관문 — 이 디렉터리 밖, 같은 PR)**: ① Application `platform-cnpg-cluster`에 `ApplyOutOfSyncOnly=true` + `retry`(limit 5 · 30s ×2 · 5m) — 계약 §Application 규약 예외(2026-10-13 T053 · 모노레포 `a1bf712`)로 확정하고
  **이 PR에서 반영**(`clusters/oci-k3s/apps/platform-cnpg-cluster.yaml` 머리 주석 · 효과는 VD-11) ② 계약 §삭제 보호 행에 `ObjectStore oci-backups` 추가 — 같은 커밋으로 **완료**(이 디렉터리의 어노테이션과 계약 문면이 일치한다) ③ 검사 1의 CRD 스키마(계약 §validate.yml 1 — D7로 개정됨: 저장소 렌더에 나온 CRD에서 **실행 시 파생**한 스키마 1순위 ·
  datreeio 폴백) — datreeio의 ObjectStore 사본(2025-06-17)이 `data.compression lz4`를 거부해 이 디렉터리의 검사 1이 FAIL이던 것을 **이 PR의 `tests/**` 변경**(검사 1 두 패스 — 렌더 수집 → CRD 스키마 파생 → kubeconform)이 푼다(이 디렉터리는 바꾸지 않는다).
- **VD 결과 기록 위치**: 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T053 절(소요 시간 · 첫 completed · 오브젝트 모양 · 8000/5432 판정 · VD-10 RBAC 이름) + build-notes 「T053」.
