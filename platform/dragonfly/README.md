# platform/dragonfly/ — 운영자 절차 (T057)

세션 거부 목록 캐시 Dragonfly를 env마다 하나씩 둔다 — **`Deployment` 2**(`dragonfly-dev` · `dragonfly-prod` — v1.40.1 · replica 1 · 노드 B) + 그 aclfile을 Vault kv에서 만드는
**ACL `ExternalSecret` 2**(ns `data` · store `vault-data`) + 스냅샷 **`PersistentVolumeClaim` 2**(local-path 2Gi · 삭제 보호) + **`Service` 2**(ClusterIP 6379). 합계 **8장**(전부 ns `data`).
Argo CD Application **`platform-dragonfly` 하나**가 이 디렉터리 하나를 적용한다(계약 `gitops-repo.md` §sync-wave 단일 표의 `dragonfly` 행). 설치 방식은 `platform/kafka-topics/`와 같은
**순수 매니페스트**다(`helmCharts` 없음). 키 스키마 · ACL 표 · 유실 창의 정본은 모노레포 `specs/003-platform-foundation/contracts/denylist.md`, 값의 정본은 `tasks.md` T057 문면,
형상의 근거는 컨트롤러 결정 D1–D14(모노레포 `design/build-notes.md` 「T057」)다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources` 5파일(문서 8장). 전역 `namespace:` 변환기 · `commonLabels` 없음. 만들지 않는 것과 되돌리기 요약은 머리 주석 |
| `externalsecrets-acl.yaml` | ExternalSecret 2(리소스 wave `"0"`): `dragonfly-<env>-acl` ← `vault-data` `<env>/dragonfly/acl` — `data: [{secretKey: users.acl, property: users.acl}]` · **template 없음** · Owner · Periodic 5m |
| `services.yaml` | Service 2(리소스 wave `"0"`): `dragonfly-<env>` · ClusterIP · `6379 → redis` · selector `app.kubernetes.io/name` + `app.kubernetes.io/instance` |
| `pvcs.yaml` | PVC 2(리소스 wave `"1"`): `dragonfly-<env>-data` · RWO · `local-path` · 2Gi · `argocd.argoproj.io/sync-options: Delete=false,Prune=false` |
| `deployment-dev.yaml` · `deployment-prod.yaml` | Deployment 2(리소스 wave `"1"`): 이미지 태그 + digest · `command` 없음(tini → entrypoint) · args 9토큰 · env/envFrom 0 · tcpSocket 프로브 3 · Recreate · grace 60 · `role=data` · uid 999 · 읽기 전용 루트 + `/tmp` |

> **머지 → 폴링 주기 안에 자동 sync → wave 0(ACL ES 2 SecretSynced · Service 2) → wave 1(PVC 2 → Deployment 2 적용 — 마지막 wave라 operation은 여기서 Succeeded) → 스케줄러가 pod를 노드 B에 두고
> local-path가 PV를 만든다(PVC Bound) → Dragonfly 기동 · aclfile 적재 · 스냅샷 적재(첫 기동은 "No snapshot found") → Deployment Available → Application Healthy.**
> 머지 **전** §0의 선행 조건 표를 전부 확인한다 — 특히 **P1(Vault kv 7경로 시드)**: 시드 전에 머지하면 wave 0의 ES가 `SecretSyncedError`(Degraded)로 그 sync 시도가 Failed가 되고, 이 Application은
> 예외 없는 표준 syncPolicy라 기본 retry(대기 10·20·40·80·160 s ≈ 5분)를 다 쓰면 같은 리비전으로 다시 시작하지 않는다(§1 증상표 첫 행). **머지가 먼저 됐다면(늦은 시드)** kv 시드 뒤 모노레포 런북
> `docs/runbooks/bootstrap.md` §4 T057 — 절차는 `platform/kafka-topics/README.md` §1 증상표 첫 행과 같다(관리자 kubeconfig로 ES 2장에 `force-sync=<epoch>` → agent-view로 SecretSynced 확인 → retry를 다 썼으면 전체 수동 Sync:
> UI → CLI `argocd app sync platform-dragonfly`(플래그 없이) → JSON patch 순 · `.operation`만 넣는 merge patch 금지).
> 머지 뒤 운영자가 §2의 확인과 §3의 VD(특히 **VD-4 — 사용자 동석**)를 기록한다(기록 위치는 §6).

- **이 저장소에 비밀은 없다.** 매니페스트에는 kv **경로·키 이름**과 Secret · 사용자 **이름**만 있다. aclfile의 실제 내용(해시 포함)과 사용자 비밀번호 · URL은 kv에만 있다(희망 상태에 Secret 0장 — ESO가 런타임에 만든다).
- **전역 `namespace:` 변환기 · `commonLabels`가 없다.** 다섯 파일이 `metadata.namespace: data`와 라벨 세 개를 직접 적는다(selector가 변환기에 흔들리지 않게).
- 로컬 재현(리뷰어용 · helm 불필요):
  ```bash
  kustomize build platform/dragonfly   # 문서 8(ExternalSecret 2 · Service 2 · PersistentVolumeClaim 2 · Deployment 2)
  bash tests/validate.sh               # FAIL 0 · 새 WARN 0(기존 4b WARN 4 = system-upgrade 그대로) · 검사 3 PASS 줄의 ExternalSecret 수 +4(파일 2 + 렌더 2) · 3.5 워크로드 수 +4 · 4b image 줄 +2(digest 병기)
  ```
- **sync-wave 숫자는 여기 적지 않는다.** 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**, 코드 사본은 `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
  매니페스트의 `argocd.argoproj.io/sync-wave` `"0"`·`"1"`은 **그 표의 숫자가 아니라** 이 Application 안의 리소스 적용 순서다(§1).

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 **8장** · 전부 ns `data`):

| 객체 | 리소스 wave | 역할 |
|---|---|---|
| ExternalSecret `dragonfly-dev-acl` | `"0"` | Secret `dragonfly-dev-acl`(키 `users.acl`) ← `vault-data` `dev/dragonfly/acl` — Deployment `dragonfly-dev`의 `/etc/dragonfly/users.acl` |
| ExternalSecret `dragonfly-prod-acl` | `"0"` | Secret `dragonfly-prod-acl`(키 `users.acl`) ← `vault-data` `prod/dragonfly/acl` — Deployment `dragonfly-prod`의 aclfile |
| Service `dragonfly-dev` · `dragonfly-prod` | `"0"` | ClusterIP `6379`(`redis`) — 소비자 주소 `dragonfly-<env>.data.svc:6379`(계약 §ACL `DRAGONFLY_URL` 행) |
| PersistentVolumeClaim `dragonfly-dev-data` · `dragonfly-prod-data` | `"1"` | `--dir /data` 스냅샷(`dump-summary.dfs` + 샤드 파일) · local-path 2Gi · `Delete=false,Prune=false` |
| Deployment `dragonfly-dev` · `dragonfly-prod` | `"1"` | Dragonfly v1.40.1 · aclfile 인증 · 5분 스냅샷 + 종료 스냅샷 · replica 1 · 노드 B |

**런타임 객체**(희망 상태에 없다):
- **ESO가 만드는 Secret 2**: `dragonfly-dev-acl` · `dragonfly-prod-acl`(키 `users.acl` 하나) · ownerReference = 각 ES(Owner). template이 없어 ES의 라벨·어노테이션(Argo tracking-id · sync-wave)이
  Secret에 복사된다 — Argo는 종류·이름이 다른 복사본을 관리 대상으로 세지 않는다(`platform/kafka-topics/README.md` §4 template 행과 같다). **agent-view는 Secret을 읽지 못한다**(§2 운영자 전용).
- **PV 2**(local-path 프로비저너 — 노드 B `/var/lib/rancher/k3s/storage/` 아래 디렉터리 · reclaim **Delete** · 노드 B에 묶인다) · **pod 2**(ReplicaSet 경유) · 스냅샷 파일(`/data/dump*`).
- **Dragonfly 안의 ACL 레지스트리**(K8s 객체가 아니다): aclfile을 기동 때와 `ACL LOAD` 때 읽어 만든다. `ACL LIST`는 해시를 15자로 줄여 보여 준다(§4).

**이 디렉터리가 만들지 않는 것**:
- Namespace · PSA · NetworkPolicy → `platform/policies/`(정책 변경 **0** — 앱 → Dragonfly 6379는 매트릭스 `jt-dev`·`jt-prod` → `data` 행(`data/allow-from-apps` · podSelector `{}`)이 이미 연다).
  jt-dev pod는 `dragonfly-prod.data.svc:6379`에도 L4로 닿는다(jt-prod pod도 `dragonfly-dev`에 — `platform/policies/policies-matrix.yaml` :473–477 · :517–521(jt-dev · jt-prod `allow-egress-to-data` — podSelector `{}` · `to`는 namespaceSelector(data)만 · ports 5432·9093·6379) + 수신 :184–192(`data/allow-from-apps` podSelector `{}`) · pg-main과 같은 기존 설계 · 정책 변경 0) — env 격리는 **ACL만**이다:
  사용자 비밀번호 5개 전부 상이(시드 블록 B5) · prod aclfile에 `sample-pod` 없음 · 공유 이름 `identity-admin`은 env마다 다른 비밀번호.
- Vault kv 값(아래 P1 7경로) → 운영자 시드. Vault 정책 → 모노레포 `infra/vault/policies.tf`(eso-data `kv/data/{dev,prod}/dragonfly/*` — 이미 허용 · :41 · :46 · :51 · :56).
- 앱 ns의 `<pod>-env`(`DRAGONFLY_URL` ← `kv/{env}/dragonfly/<pod>` 키 `url` · store `vault-{env}`) → 앱 overlay(T072). 검사 Job `data-assert`의 **배포** → T059(Job 스크립트의 Dragonfly 검사 7개는 이 PR이
  `platform/policies/tests/job-data-assert.yaml`에 더했다 — 그 디렉터리 README 「검증 기록 (T057)」).
- Reloader 어노테이션 · `/metrics` 수집 경로 · 채널 ACL(`&<pod>:*`) → 두지 않는다(§4 · §5 · §6).
- AppProject `platform` 변경 **없음**: 8장 전부 네임스페이스 범위이고 destinations에 `data`가 있다(`clusters/oci-k3s/projects/platform.yaml` — namespaceResource 제한 없음).

**선행 조건**(머지 전 전부 확인 — 하나라도 미충족이면 머지하지 않는다):

| # | 전제 | 확인 | 상태 2026-10-22 |
|---|---|---|---|
| P1 | **Vault kv 7경로 시드**(아래 표 · 값은 이 저장소에 없다) — aclfile은 그 env의 사용자 비밀번호로 렌더한다(아래 「aclfile 형식」) · 사용자 비밀번호 5개(dev 3 + prod 2 — 7은 kv 경로 수)는 서로 다르다(시드 블록 B5 — env 격리의 경계 · 위 NetworkPolicy 항목) | **운영자 블록 모노레포 `specs/003-platform-foundation/design/t057-blocks/op1-seed-dragonfly.ps1`**(블록 하네스 전부 PASS가 실행 조건 · 컨트롤러 결정 D11) · 런북 `docs/runbooks/bootstrap.md` §4 T057 — 7경로 version ≥ 1 · 되읽기 해시 일치 | **머지 전** 운영자 실행 |
| P2 | ClusterSecretStore `vault-data` Ready(conditions에 `data`) | `kubectl get clustersecretstore vault-data` → READY True · 하네스 `cluster.tests.ps1` eso-1 PASS | T045 라이브 |
| P3 | 노드 B(`role=data`) 여유 — 두 인스턴스 requests +512Mi(메모리) +200m(CPU) · limits +1800Mi · vCPU 2(`--maxmemory=768mb` 스레드 조건 — §4) | `kubectl get nodes -L role` · `kubectl describe node <노드 B>` Allocated resources | 2026-10-22 11:00 agent-view: allocatable 13241680Ki · requests 3250 MiB · limits 5922 MiB(수용) |
| P4 | StorageClass `local-path`(K3s 기본 · WaitForFirstConsumer) · ns data PVC가 쓰는 SC | `kubectl -n data get pvc -o custom-columns=N:.metadata.name,SC:.spec.storageClassName` | 2026-10-22: 기존 PVC 3장 전부 `local-path` |
| P5 | agent-view RBAC — `view`(deployments · pods · pods/log · services · persistentvolumeclaims · events) + `agent-view-extra`(`external-secrets.io` resources `*`) · Secret은 못 읽는다(의도) | `kubectl auth can-i list externalsecrets.external-secrets.io -n data` · `kubectl auth can-i get pods/log -n data` → yes · `kubectl auth can-i get secrets -n data` → no | T041 라이브(`platform/policies/rbac-agent-view.yaml` :86–87) |
| P6 | 관문 `bash tests/validate.sh` → `FAIL 0` · 이 PR로 새 WARN 0(기존 WARN 4 = `platform/system-upgrade` `rancher/k3s-upgrade` 이미지 4줄 — 그대로)(검사 1 kubeconform `-strict` · 3.1/3.3 ES 경로 · 3.6 automount · 4b digest · 7.1/7.2 WAVE 유지) | 로컬 `bash tests/validate.sh` · PR의 `validate` | 빌더 실측은 PR 본문(컨트롤러) |

**P1 kv 7경로**(키 이름만 — 값 0 · 계약 denylist.md §Vault 경로 · data-model §8):

| 경로 | 키 | 읽는 쪽 |
|---|---|---|
| `kv/dev/dragonfly/acl` · `kv/prod/dragonfly/acl` | `users.acl`(aclfile 전문) | 이 디렉터리의 ES 2(`vault-data`) |
| `kv/dev/dragonfly/admin` · `kv/prod/dragonfly/admin` | `password` | ESO 소비자 없음 — 운영자 런북 전용(`ACL LOAD` · 진단) |
| `kv/dev/dragonfly/identity-admin` · `kv/prod/dragonfly/identity-admin` | `password` · `url` | identity-admin `<pod>-env`(`vault-{env}` · T072) · dev는 검사 Job `data-assert`의 ES `assert-data-env`(`DRAGONFLY_URL`)도 |
| `kv/dev/dragonfly/sample-pod` | `password` · `url` | 검사 Job `data-assert`의 ES `assert-data-env`(`DRAGONFLY_SAMPLE_URL` · dev 전용 검사 계정 — **prod에는 없다**) |

`url` 값의 모양은 계약 §ACL `DRAGONFLY_URL` 행 그대로다(사용자 = pod 이름 · 호스트 `dragonfly-<env>.data.svc:6379` · db 0 — 비밀번호는 같은 경로의 `password`와 같다).

**aclfile 형식**(`users.acl` — 형식만 · 컨트롤러 결정 D6 · Dragonfly `ACL SAVE` 형식과 같다 — §4):

```text
USER default OFF +auth +hello
USER admin ON #<sha256hex> ~* &* +@all
USER identity-admin ON #<sha256hex> ~revoked:* ~identity-admin:* +@all
USER sample-pod ON #<sha256hex> %R~revoked:* ~sample-pod:* +@all
```

- dev = 위 4줄, prod = 앞 3줄(`sample-pod` 없음 — 계약 §ACL 표). `#<sha256hex>` = 그 사용자 kv `password`의 SHA-256 **소문자 hex 64자**(평문 비밀번호는 Secret에 싣지 않는다).
- **LF만** · CR · 탭 · 주석 · 앞뒤 공백 0 · 공백만 있는 줄 0(로더가 빈 토큰 목록의 첫 원소를 읽는다 — `acl_family.cc` :738–739) · 줄마다 토큰 ≥ 4 · 끝 줄바꿈 1개(빈 줄은 건너뛴다).
  대소문자: 첫 토큰 `USER`(대소문자 무시) · `ON`/`OFF`(대소문자 무시) · 나머지 토큰은 그대로.
- `USER default OFF +auth +hello`는 **필수**다(T057 수정 라운드 r2 · F12 — 처음 형식 `USER default OFF -@all`을 대체했다) — 파일에 `default` 줄이 없으면 Dragonfly가 default를 **nopass +@all ~* &*** 로 만든다(무인증).
  `USER default OFF`처럼 3토큰이면 줄 전체가 거부된다(→ 아래 첫 함정). **default에 `AUTH` · `HELLO` 권한이 있어야 한다**: Dragonfly는 NOAUTH 관문을 통과한 `AUTH`·`HELLO`를
  **연결의 현재 사용자(default)의 ACL**로 검사한다(`main_service.cc` :1403–1407 → `IsUserAllowedToInvokeCommand` · `kAuth`/`kHello` = FAST|CONNECTION — §4 인증) — default가 `-@all`이면
  아무도 인증할 수 없다(2026-10-22 1차 실측 · 로컬 v1.40.1 재현 — §1 증상표 「모든 사용자 AUTH 실패」 · §3 VD-4 실측 기록). `+auth +hello`가 최소 권한이다(비인증 연결의 다른 명령은
  NOAUTH 관문이 먼저 막는다 · `+@connection`은 등가 상위집합 — `CLIENT`(`server_family.cc` :4014 `kClient` = SLOW|CONNECTION) 같은 명령까지 더한다). default는 OFF라 이 두 권한으로 default **로**
  로그인할 수는 없다(인증 = `IsActive && HasPassword` — §4).
- **키 패턴과 명령 카테고리는 짝지어지지 않는다**(계약): `<pod>`의 읽기 전용은 `+@read`가 아니라 **`%R~revoked:*`** 로만 표현한다.
- 채널: admin만 `&*`. identity-admin · sample-pod는 채널 토큰이 없어 `resetchannels`(채널 0)다 — Celery/Kombu가 pub/sub 채널을 쓰면 `&<pod>:*`가 필요할 수 있다(§6 T062/T066/T072).
- ⚠ **한 줄이라도 파싱 오류면 파일 전체가 적재되지 않고 Dragonfly는 무인증(default nopass)으로 기동한다**(§1 증상표 둘째 행 · §4). 파일을 손으로 고치지 않는다 — 시드 블록이 렌더한다.

**하네스 · 관문 대조**(값을 바꿀 때 같이 본다):

| 규칙 | 이 디렉터리의 값 |
|---|---|
| validate 3.1(키 정규식 `^(platform\|dev\|prod)/[a-z0-9_./-]+$`) · 3.3(이 디렉터리 + store `vault-data` → 열거 접두 `{dev,prod}/{db,kafka,dragonfly,openfga}/…`) | `dev/dragonfly/acl` · `prod/dragonfly/acl` |
| validate 3.6(`automountServiceAccountToken: false` — 범위에 `platform/dragonfly`) | Deployment 2 모두 `false` |
| validate 4b(`platform/**` `image:` 줄 digest) · 계약 §이미지 | `ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c2…` 2줄 |
| 하네스 `kafka.tests.ps1` df-1 | Deployment 2 존재 · Available · replicas 1 · availableReplicas 1 · 컨테이너 1 · `--maxmemory=768mb` · `--aclfile /etc/dragonfly/users.acl`(분리 표기) · `--requirepass`/`-requirepass`/`--flagfile`/`--fromenv`/`--tryfromenv` 0 · env 이름 `DFLY_requirepass`·`DFLY_PASSWORD` 0 · envFrom 0 · grace `60` · `Recreate` · automount `false` |
| 하네스 df-2 | Service `dragonfly-dev` · `dragonfly-prod`의 `spec.ports[].port`에 `6379` |
| 하네스 `cluster.tests.ps1` argo-4-dragonfly | ns data에서 이름에 `dragonfly`가 들거나 라벨 `app.kubernetes.io/name=dragonfly`인 PVC **전부**의 `argocd.argoproj.io/sync-options` = **정확히** `Delete=false,Prune=false` — 2장 |
| 하네스 job-d-1/2 · `data.tests.ps1` job-1/2 · `cluster.tests.ps1` np-2-data-assert | 검사 Job `data-assert`(ns jt-dev)가 배포돼야 판정된다(T059 · 그 전에는 §3 VD-4의 임시 적용 동안만) — data job-2는 **추적 밖 id의 FAIL도 문제**로 보므로 Dragonfly 7개도 전부 PASS여야 한다 |

---

## 1. 첫 배포에서 일어나는 순서

root(app-of-apps)가 `platform-dragonfly`를 이미 만들어 두었고(T041 — 지금은 렌더 0 · Synced/Healthy), 머지하면 자동 sync가 8장을 **리소스 wave 순서로** 적용한다.
Argo는 wave N의 리소스가 전부 Healthy가 된 뒤 N+1을 적용하고, 같은 wave 안에서는 kind 순서(PersistentVolumeClaim → Service → Deployment · 표에 없는 kind(ExternalSecret)는 그 뒤)로 적용한다
(gitops-engine `pkg/sync/sync_tasks.go` :24–66 · :102–104).

| 단계 | 리소스 wave | 무슨 일이 일어나는가 | 예상 시간(VD-1–VD-3로 실측) |
|---|---|---|---|
| ① | `0` ACL ES 2 · Service 2 | SSA 적용 → ESO가 `vault-data`로 kv `<env>/dragonfly/acl`을 읽어 Secret `dragonfly-<env>-acl`(키 `users.acl`)을 만든다 → ES `Ready=True`(SecretSynced) → Healthy. Service는 적용 즉시 Healthy. kv가 비었으면 `SecretSyncedError` → Degraded → 이 시도는 Failed(증상표 첫 행) | 초(T054 · T056 ES: 적용 → SecretSynced 수 초) |
| ② | `1` PVC 2 → Deployment 2 | 4장 SSA 적용. **마지막 wave**라 적용 직후 operation이 **Succeeded**로 닫힌다(PVC Pending · Deployment Progressing을 기다리지 않는다 — `platform/kafka-topics/README.md` §1 ②와 같은 gitops-engine 경로). Application health는 ③이 끝날 때까지 Progressing | 초 |
| ③ | — | 스케줄러가 pod를 `role=data` 노드(노드 B)에 둔다 → local-path 프로비저너가 그 노드에 PV를 만든다(WaitForFirstConsumer — 그 전까지 PVC는 Pending = Argo Progressing) → PVC Bound → 이미지 pull(첫 배포 — arm64 레이어 8개 압축 합 ≈ 48 MB) → tini → entrypoint(uid 999 — root 분기 없음) → `dragonfly --logtostderr <args>` → aclfile 적재 → 리스너 → 스냅샷 적재(첫 기동 `Load snapshot: No snapshot found` WARNING) → startup · readiness 프로브(tcpSocket) 통과 | 수십 초(pull 포함 — VD-2 · VD-3) |
| ④ | — | Deployment 2 Available(1/1) · PVC 2 Bound → Application `Synced/Healthy`. 하네스 df-1 · df-2 · argo-4-dragonfly PASS 후보(§2) | — |

**Argo health 매핑**(v3.5.2 — 원문 확인 2026-10-22): `external-secrets.io/ExternalSecret` health.lua(Ready=False → Degraded · True → Healthy · 그 밖 Progressing) ·
PVC(`gitops-engine/pkg/health/health_pvc.go` :28–41 — Pending → **Progressing** · Bound → Healthy · Lost → Degraded) · Service(ClusterIP → Healthy) · Deployment(롤아웃 완료 → Healthy · 진행 중 → Progressing ·
`progressDeadlineSeconds` 초과 → Degraded). 그래서 이 Application에는 계약 §Application 규약 예외(`ApplyOutOfSyncOnly` · `retry`)가 **없다**: hook이 없고, Degraded·Progressing이 오래 남을 수 있는
PVC·Deployment는 마지막 wave라 operation을 실패시키지 않는다. 앞 wave를 막는 유일한 경로는 wave 0 ES의 `SecretSyncedError`(kv 미시드)이고, 그것은 **머지 전 시드(P1)**로 막는다.
PVC를 Deployment보다 낮은 wave에 두지 않는 이유 = WaitForFirstConsumer라 pod가 없으면 Bound가 되지 않아 wave가 끝나지 않는다(pvcs.yaml 머리 주석).

**어디서 멈추면 무엇을 보는가**(agent-view로 되는 명령만 — 관리자 kubeconfig가 필요한 조치는 그렇게 적었다):

| 증상 | 가장 먼저 볼 것 | 원인 후보 | 조치 |
|---|---|---|---|
| **wave 0 ACL ES 실패** — operation이 재시도 대기(phase `Running` · message `… Retrying attempt #<n> …`) 또는 재시도 5회 소진(phase `Failed` · 조건 `SyncError` `Failed last sync attempt to [<rev>]: …`) · wave 1(PVC · Deployment)이 **없다** | `kubectl -n argocd get app platform-dragonfly -o jsonpath='{.status.operationState.phase} retry={.status.operationState.retryCount} {.status.operationState.message}'` · `kubectl -n data get externalsecret dragonfly-dev-acl dragonfly-prod-acl`(STATUS `SecretSyncedError`) · `kubectl -n data describe externalsecret dragonfly-dev-acl` Events | **kv 미시드**(Events `Secret does not exist`) · kv 키 이름 불일치(`cannot find secret data for key: "users.acl"`) · `permission denied`/403(Vault 정책 — eso-data는 `{dev,prod}/dragonfly/*`) · store 없음 | 고칠 곳은 **kv**(P1). 시드 뒤 런북 §4 T057 「늦은 시드」 — 두 상태 구분 · force-sync · 전체 수동 Sync 방법은 `platform/kafka-topics/README.md` §1 증상표 첫 행과 같다(Application 이름만 `platform-dragonfly`) · 재시도 대기 중이면 기다린다 |
| **aclfile 파싱 오류 = 무인증 기동**(⚠ 보안 사고) — pod는 Running · Ready다(프로브는 TCP라 통과) · 사용자 이름으로 AUTH하는 소비자는 전부 `-WRONGPASS invalid username-password pair or user is disabled.`(기본 레지스트리에는 default뿐 — `facade/error.h` :33–34 · `server_family.cc` :2055–2063) → 앱은 fail-closed 503 · 그런데 **자격 없는 연결은 전권**이다(검사 `noauth` FAIL — `미인증 PING이 통과(PONG)`) | `kubectl -n data logs deploy/dragonfly-dev --tail=500 \| Select-String -SimpleMatch -Pattern 'Error while parsing aclfile','Error materializing acl file','could not load ACL file','Invalid password hash'`(문구 4개) | 줄 하나라도 오류면 파일 전체가 적재되지 않고 기본 레지스트리(default **nopass** · `+@all ~* &*`)로 기동한다(`acl_family.cc` :642–656 — LOG(WARNING)만). 로그 문구 **4개**(왼쪽 grep · §6 T098 알림 후보와 같다): ① `Error while parsing aclfile: Unrecognized parameter …`(CR이 붙은 `+@all\r` · 탭 · 모르는 토큰) ② `Error materializing acl file`(첫 토큰이 `USER`가 아님 · 토큰 3개 이하 줄) ③ `Dragonfly could not load ACL file <경로> with error …`(파일 읽기 실패) ④ `Invalid password hash: <값>`(적재는 성공 — 그 사용자만 잠김 · 다음 행). `ACL SAVE`의 실패 로그는 적재 신호가 아니라 이 목록에 넣지 않는다(§4 받아들인 사실). **로그 문구 0은 적재 증거가 아니다** — 빈 aclfile은 로그 없이 무인증 기동한다(`Empty file` · `acl_family.cc` :307–308) · 증거는 VD-4 `noauth` PASS(`-NOAUTH`)뿐(§3 VD-3과 같은 사실) | kv `acl`을 시드 블록으로 다시 렌더 → ESO ≤ 5분 → kubelet 파일 갱신 → 관리자 `ACL LOAD`(§5 — 실행 중 적재 실패는 옛 규칙을 지킨다) 또는 rollout restart → `noauth` PASS 확인(§3 VD-4 Job). 무인증이었던 기간(로그 시각)을 기록하고 컨트롤러에 보고 — 도달 가능 범위는 ns data와 jt-dev · jt-prod(netpol) |
| 특정 사용자만 인증 실패(`WRONGPASS`) · 다른 사용자는 정상 · 로그 `Invalid password hash: <값>`(LOG(ERROR)) | 같은 로그 grep(`password hash`) | `#` 뒤 값이 hex가 아니다(`user.cc` :92–104 — 그 사용자는 비밀번호 없이 ON → 아무도 로그인 못 한다 · 파일 적재 자체는 성공). ⚠ **그 값이 로그에 그대로 찍힌다** — 평문 비밀번호를 `#` 뒤에 넣었다면 로그 = 유출 | kv `acl` 재렌더(시드 블록) → `ACL LOAD`. 값이 비밀번호였다면 그 사용자 비밀번호 회전(T084 · `secret-rotation.md`) |
| **모든 사용자 AUTH 실패**(서비스 불능 · fail-closed — 2026-10-22 VD-4 1차 실측) — pod Running · Ready · aclfile 오류 로그 0 · 소비자 로그/Job 로그 `AUTH failed: NOPERM default has no ACL permissions`(redis-cli 8.x — 2인자 `AUTH <user> <pw>`) 또는 `NOAUTH`(redis-cli 6.0 — AUTH 실패는 경고 `Warning: AUTH failed`뿐이고 다음 명령이 `NOAUTH`) · 검사 `noauth`는 PASS(비인증 PING은 그대로 `NOAUTH`) · `writer-set` · `reader-get` FAIL — 이때 `reader-set-denied` · `reader-cross-denied` · `noperm`도 **FAIL**이다(G9 — 근거 `… 인증 실패(AUTH failed) — NOPERM 판정 불가 …` · G9 전 Job(1차 실측 06:39Z)은 이 셋을 `AUTH failed: NOPERM default …`의 `NOPERM`을 보고 거짓 양성 PASS로 냈다) | agent-view: `kubectl -n jt-dev logs job/data-assert --tail=50`(§3 VD-4 Job · T059 — 근거에 `AUTH failed: NOPERM default …`) · 운영자(관리자 kubeconfig): `kubectl -n data exec -it deploy/dragonfly-dev -- redis-cli --user admin --askpass PING` → `Warning: AUTH failed` + `(error) NOAUTH Authentication required.`(정상이면 `PONG` · `-u` URL 형식은 쓰지 않는다 — §4 받아들인 사실) | aclfile `default` 줄에 AUTH 권한이 없다(`-@all` 등) — 파일은 적재됐으나 인증 경로가 닫혔다(fail-closed · 서비스 불능). Dragonfly는 `AUTH` · `HELLO`를 연결의 현재 사용자(default)의 ACL로 검사한다(§0 aclfile 형식 · §4 인증) | kv `acl` 재렌더(default 줄 `USER default OFF +auth +hello` — 시드 블록 · 모노레포 런북 bootstrap.md §4 T057 「ACL 파일 갱신(acl 2경로 재렌더)」) → ESO ≤ 5분(또는 `force-sync` — agent-view로 ES `status.refreshTime`이 재렌더 뒤인지 확인) → **pod 삭제** `kubectl -n data delete pod -l app.kubernetes.io/name=dragonfly`(관리자 kubeconfig · 한 env만이면 `-l app.kubernetes.io/instance=dragonfly-<env>` — ReplicaSet이 같은 템플릿으로 다시 만들고 새 pod가 갱신된 Secret을 마운트한다 · Deployment spec 불변이라 Argo Synced 유지) → §3 VD-4 Job으로 `noauth` · `writer-set` · `reader-get` PASS 확인. **`ACL LOAD`는 못 쓴다** — 아무도(admin 포함) AUTH하지 못해 `ACL LOAD`를 보낼 수 없다. **`rollout restart`는 쓰지 않는다** — 파드 템플릿에 `kubectl.kubernetes.io/restartedAt`을 남긴다(pod 삭제는 템플릿 불변). 그 어노테이션이 selfHeal을 부르는지는 이 Application에서 미실측이다(Server-Side Diff — T046 VD-9 실측은 다른 관리자가 넣은 템플릿 어노테이션을 드리프트로 보지 않았다) |
| pod `ContainerCreating` · Events `MountVolume.SetUp failed for volume "acl" : secret "dragonfly-<env>-acl" not found` 또는 `couldn't find key users.acl` | `kubectl -n data describe pod -l app.kubernetes.io/instance=dragonfly-dev` Events | ES가 지워졌거나(Secret GC) 키 이름이 다르다(ES `secretKey`) — wave 순서상 첫 배포에서는 나오지 않는다 | ES 재적용(selfHeal) · 키 이름 PR |
| PVC `Pending`이 **pod가 생긴 뒤에도** 계속 · pod `Pending`(`0/2 nodes are available: … didn't match Pod's node affinity/selector`) | `kubectl -n data describe pvc dragonfly-dev-data` Events · `kubectl get nodes -L role` · `kubectl -n data describe pod -l app.kubernetes.io/instance=dragonfly-dev` | pod가 붙기 전 Pending은 **정상**(WaitForFirstConsumer) · 노드 B 라벨 `role=data` 없음 · 노드 B 메모리 부족(requests 합 — P3) · local-path 프로비저너 실패(helper pod — 디스크) | 라벨 · 용량은 노드 쪽(운영자) · 프로비저너는 `kubectl -n kube-system logs deploy/local-path-provisioner`(agent-view `view`로 가능한지 VD-2에서 확인) |
| **CrashLoopBackOff** · 로그 `Failed to load snapshot with error …` 또는 적재 중 종료 | `kubectl -n data logs deploy/dragonfly-dev --previous --tail=50` | 스냅샷 파일 손상(적재 실패 = 프로세스 종료 — `server_family.cc` :1295–1314) · 디스크 가득 | **캐시이므로 `/data/dump*` 삭제가 안전하다**(거부 목록 정본은 DB — identity-admin 30 s 무조건 재적용이 다시 채운다). 운영자 · 관리자 kubeconfig: replica 0 대신 노드 B의 PV 디렉터리(`/var/lib/rancher/k3s/storage/<pv 이름>_data_dragonfly-<env>-data/`)에서 `dump*`를 지우거나, 같은 PVC를 붙인 일회용 디버그 pod로 지운 뒤 pod 재시작(§5) |
| CrashLoopBackOff · 로그 `There are <N> threads, so <M> are required. Exiting...` | 같은 `--previous` 로그 | `--maxmemory=768mb` < 스레드 수 × 256MiB(`dfly_main.cc` :318 — `<` 조건) — 노드 B vCPU가 **4개 이상**으로 늘었다(3개는 3 × 256 MiB = 768 MiB로 경계값 통과 · CPU limit이 없어 스레드 수 = 노드 vCPU) | 과제 문면 값 변경이라 컨트롤러 결정(`--proactor_threads` 고정 또는 maxmemory 상향 — limit 900Mi와 함께) |
| `OOMKilled`(재시작 수 증가 · `lastState.terminated.reason`) | `kubectl -n data get pod -l app.kubernetes.io/name=dragonfly -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'` · `kubectl top pod -n data -l app.kubernetes.io/name=dragonfly` | RSS가 limit 900Mi를 넘었다(maxmemory 768mb 위의 연결 · 스냅샷 직렬화 버퍼) | **비정상 종료 = 유실 창**(계약 — 최대 30 s · 30 s 재적용이 메운다). 값 조정(maxmemory · limit)은 과제 문면 값이라 컨트롤러 결정(T097 실측) |
| 기동 직후 소비자 오류 `-LOADING`(앱은 fail-closed 503) | 로그의 리스너 · 적재 완료 시각 | 스냅샷 적재 중(적재는 별도 fiber · 적재 중 명령은 `-LOADING` — `main_service.cc` :1385–1386) | 키 수십 건이면 수 ms 수준(VD-8로 실측) — 길면 스냅샷 크기 확인 |
| 기동 로그 WARNING `iouring API is not supported. Switching to epoll.` · `Check if io_uring is disabled …` · `Weird error … switching to epoll` | 같은 로그 | seccomp `RuntimeDefault`(containerd 기본 프로필)가 io_uring 시스템 호출을 막으면 epoll로 내려간다(`dfly_main.cc` :516–553) | **정보** — 실패가 아니다(VD-3에 어느 엔진인지 기록) |
| Application `Synced` 대신 **영구 `OutOfSync`** | `kubectl -n argocd get app platform-dragonfly -o jsonpath='{.status.resources[?(@.status=="OutOfSync")]}'` | Deployment · Service · PVC의 API 기본값 · 컨트롤러 필드가 SSA diff로 남는 경우(VD-6 — 소스 판독상 다른 매니저 필드는 diff 밖) | VD-6 기록 → 영구면 1차 조치 `ServerSideDiff=true`(계약 예외 문단 개정 뒤 — 컨트롤러) |

---

## 2. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다. **라이브 클러스터 접근 없이 작성했다**(빌더는 KUBECONFIG 없음 — 기대값은 렌더 · 업스트림 소스 · 이미지 config에서 왔다).

```powershell
kubectl -n argocd get app platform-dragonfly -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status} {.status.operationState.phase} retry={.status.operationState.retryCount}'
#   <머지 sha 40자> Synced Healthy Succeeded retry=   (빈 값 = 0 — 순수 매니페스트 · CRD 없음 · helm 없음이라 retryCount 0 기대 · VD-1)
(kubectl -n argocd get app platform-dragonfly -o json | ConvertFrom-Json).status.resources | Group-Object kind | Select-Object Name,Count
#   Deployment 2 · ExternalSecret 2 · PersistentVolumeClaim 2 · Service 2 = 8 · 전부 Synced
kubectl -n data get externalsecret dragonfly-dev-acl dragonfly-prod-acl
#   2행 · STORE vault-data · STATUS SecretSynced · READY True
kubectl -n data get pvc -l app.kubernetes.io/name=dragonfly -o 'custom-columns=N:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,CAP:.status.capacity.storage,PROTECT:.metadata.annotations.argocd\.argoproj\.io/sync-options'
#   dragonfly-dev-data · dragonfly-prod-data — Bound · local-path · 2Gi · Delete=false,Prune=false   (하네스 argo-4-dragonfly)
kubectl -n data get deploy dragonfly-dev dragonfly-prod -o 'custom-columns=N:.metadata.name,READY:.status.readyReplicas,AVAIL:.status.availableReplicas,STRATEGY:.spec.strategy.type,GRACE:.spec.template.spec.terminationGracePeriodSeconds,SA_TOKEN:.spec.template.spec.automountServiceAccountToken'
#   1 · 1 · Recreate · 60 · false (2행 — 하네스 df-1)
kubectl -n data get deploy dragonfly-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].env}{.spec.template.spec.containers[0].envFrom}{"\n"}'
#   ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c2… · args 9토큰(--maxmemory=768mb … --primary_port_http_enabled=false) · 셋째 줄 빈 값(env · envFrom 없음)
kubectl -n data get pod -l app.kubernetes.io/name=dragonfly -o wide
#   2 pods Running 1/1 · NODE = 노드 B(role=data) · 재시작 0
kubectl -n data get svc dragonfly-dev dragonfly-prod
#   ClusterIP · 6379/TCP (하네스 df-2)
kubectl -n data logs deploy/dragonfly-dev --tail=300 | Select-String -SimpleMatch -Pattern 'Error while parsing aclfile','Error materializing acl file','could not load ACL file','Invalid password hash','snapshot','epoll','threads'
#   aclfile 오류 문구(§1 둘째 행의 4개) 0 — 단 0은 적재 증거가 아니다(증거 = §3 VD-4 noauth PASS) · "Load snapshot: Searching for snapshot in directory: \"/data\"" + "Load snapshot: No snapshot found"(첫 기동) · epoll 전환 줄은 정보(VD-3) — dragonfly-prod도 같은 명령
kubectl top pod -n data -l app.kubernetes.io/name=dragonfly
#   RSS 기록(VD-7 — 유휴 수십 MiB 예상 · limit 900Mi)
kubectl auth can-i get secrets -n data
#   no   (P5 — aclfile 내용 · 해시는 agent-view로 볼 수 없다. 키 이름 확인은 운영자)
```

**운영자 전용**(admin kubeconfig — **키 이름만** 출력한다. 값은 화면·파일·argv에 두지 않는다 — `-o jsonpath='{.data}'`처럼 값을 찍는 형태는 금지):

```powershell
kubectl -n data get secret dragonfly-dev-acl dragonfly-prod-acl -o 'go-template={{range .items}}{{.metadata.name}}:{{range $k,$v := .data}} {{$k}}{{end}}{{"\n"}}{{end}}'
#   dragonfly-dev-acl: users.acl · dragonfly-prod-acl: users.acl
kubectl -n data exec -it deploy/dragonfly-dev -- redis-cli --user admin --askpass ACL LIST
#   비밀번호는 프롬프트로 입력(argv · 기록에 남지 않는다 — 이미지의 redis-cli 6.0.16에 --user · --askpass가 있다 · -u URL 형식은 6.0이 사용자 이름을 버려 실패한다 — §4) · 4행(default off -@all +auth +hello · admin · identity-admin · sample-pod) · 해시 15자 축약
```

**모노레포 하네스**(KUBECONFIG = agent-view · 한 번에 하나만 · 기대값 = 모노레포 build-notes 「T057」 하네스 기대값):

```powershell
pwsh -NoProfile -File tests/platform/kafka.tests.ps1
#   10/7/0 → 기대 12/5/0: df-1 · df-2 PASS · 남는 FAIL = job-k-1..3 · job-d-1 · job-d-2(검사 Job 미배포 — T059)
pwsh -NoProfile -File tests/platform/cluster.tests.ps1
#   42/0/12 → 기대 43/0/11: argo-4-dragonfly SKIP → PASS(PVC 2장 정확 일치). 유지: eso-2(ES 전부 SecretSynced — 이 PR의 2장 포함 · kv 미시드면 FAIL) · eso-3 · argo-1(platform-dragonfly Synced/Healthy)
#   VD-4 임시 Job이 있는 동안(§3)만 kafka 14/3/0 · cluster 44/0/10(np-2-data-assert PASS) · data.tests job-1/2 PASS — 삭제 뒤 원래로
```

---

## 3. VD(검증 후 결정 — 머지 뒤 실측해 기록)

| ID | 무엇을 | 판정 |
|---|---|---|
| VD-1 | Argo operation 전이 — `operationState.phase`(Running → Succeeded) · `retryCount` · wave 0 → 1 간격(ES SecretSynced) · Application health 전이(Progressing → Healthy) · 머지 → Synced/Healthy 소요. 정본 = Application Events(**TTL 1h** — 머지 뒤 1시간 안에 `-o json` 저장) + 폴러의 `operationState.message` 매 틱 기록(재시도는 Events에 남지 않는다 — T055 교훈) | `retryCount` 0 · Degraded 전이 0 · history 1이면 예외 없음(결정 D1) 유효. Failed · 두 번째 operation이면 사유(§1)와 함께 컨트롤러에 |
| VD-2 | **PVC · 배치** — PVC Pending → Bound 시각(pod 스케줄 직후) · PV 노드 친화 = 노드 B · pod `spec.nodeName` = 노드 B · 이미지 pull 소요 · local-path 디렉터리 권한(uid 999 쓰기 — 스냅샷이 실제로 생기는가 = VD-5) | 기대와 같으면 그대로. 다르면 Events와 함께 기록 |
| VD-3 | **기동 로그** — aclfile 오류 문구(§1 둘째 행의 4개) 0 · `Load snapshot` 줄 · I/O 엔진(io_uring · epoll — seccomp RuntimeDefault의 영향) · 스레드 수(= 노드 vCPU — `--maxmemory` 조건) · HTTP 콘솔이 주 포트에서 꺼졌는가(로그 · 소비자 쪽 확인) | 오류 문구가 하나라도 있으면 §1 증상표 둘째 행(보안 사고 · `Invalid password hash`는 셋째 행 — 사용자 잠김). ⚠ **문구 0은 적재의 증거가 아니다** — 빈 파일은 로그 없이 무인증으로 기동한다(§4 :307–308) → 적재의 증거는 VD-4의 `noauth` PASS다(§1 증상표 둘째 행과 같은 사실) |
| **VD-4** | **aclfile이 키 패턴을 로드하는가(계약 denylist.md §VD-4 · 사용자 동석)** — 절차 뼈대(컨트롤러 결정 D13): ① §2 확인 ALL PASS 뒤 ② 운영자가 관리자 kubeconfig로 `platform/policies/tests` 렌더에서 자른 **임시** 파일(ConfigMap `assert-config` + ES `assert-env`를 data-assert 5키로 줄인 사본 + Job `data-assert` — 파일은 모노레포 `.superpowers/t057/vd4/`)을 ns jt-dev에 적용 ③ ES SecretSynced → Job 1회(pg 6 + Dragonfly 7) ④ 컨트롤러가 agent-view로 `kubectl -n jt-dev logs job/data-assert --tail=50` ⑤ 판정 뒤 운영자가 같은 파일로 삭제(T059 tests Application 전까지 Argo 관리 밖 임시 객체) | **옵션 A**(aclfile 유지 — 기본 가정) = 로그에 `RESULT: PASS noauth 미인증 PING -> NOAUTH(default 사용자 OFF) wait=<n>s`(n = 기동 유예 동안 거부된 PING 수 — `platform/policies/tests/README.md` 검증 기록 T057 r2) · `EVIDENCE:   user default off resetchannels -@all +auth +hello $all` · `EVIDENCE:   user sample-pod on #<redacted> %R~revoked:* ~sample-pod:* resetchannels +@all $all`(행 모양 = 로컬 v1.40.1 실측 — 라이브 재확인 · 아래 실측 기록) · `RESULT: PASS acl-list …` · `RESULT: PASS writer-set … -> OK` · `RESULT: PASS reader-get … -> probe(…)` · `RESULT: PASS reader-set-denied … -> NOPERM …` · `RESULT: PASS reader-cross-denied … -> NOPERM …` · `RESULT: PASS noperm … -> NOPERM …` · `NOTE: cleanup DEL revoked:sub:assert-probe -> 1` · `SUMMARY: pass=13 fail=0`(20줄 — `platform/policies/tests/README.md` §로그 계약). **옵션 B** = 로드 오류(§1 증상표 둘째 행의 로그 문구 · `noauth` FAIL)면 `--aclfile`을 빼고 entrypoint `ACL SETUSER` 래퍼(같은 규칙 · 같은 Vault 경로 — 새 설계 라운드). 결과 한 줄을 tasks.md T057 체크박스 옆과 report.md에(컨트롤러) |
| VD-5 | **종료 스냅샷 · 재적재** — `kubectl rollout restart`(Recreate) 때 옛 pod가 grace 60 s 안에 종료 스냅샷을 쓰고(로그) 새 pod가 `dump-summary.dfs`를 적재하는가 · `/data`에 `dump*` 외 누적 파일 0(결정 D4) | 키가 살아남으면 계약 §쓰기 규약 "정상 종료 = 유실 없음" 확인. SIGKILL 경로(≤ 30 s 복구)는 T085 |
| VD-6 | **Synced 안정** — 15분 간격 2회 `Synced` · Deployment/Service/PVC resourceVersion 변화 · Application 조건 `OrphanedResourceWarning` 수(새 Secret · PV · ReplicaSet · pod는 ownerReference/관리 밖이라 고아로 보지 않는다고 본다 — 판독) | 안정이면 그대로. 영구 OutOfSync면 필드 기록 → 1차 조치 `ServerSideDiff=true`(계약 예외 문단 개정 뒤) |
| VD-7 | **메모리** — `kubectl top` 유휴 RSS · 스냅샷 직후 RSS(limit 900Mi 대비) · 노드 B 할당 합계(P3) | T097(QoS · limits 재실측)에 넘긴다 |
| VD-8 | **`-LOADING` 창** — 재기동 로그의 리스너 시작 ~ 스냅샷 적재 완료 간격(키 수십 건) | 수 ms~수백 ms면 그대로(소비자 fail-closed 503). 초 단위면 컨트롤러에 |

**VD-4 실측 기록**:
- **1차(2026-10-22 06:39:50Z · Job `data-assert-8wzr2` · 로그 원문 모노레포 `.superpowers/t057/evidence/vd4-data-assert-log-2026-10-22.txt`)** — `SUMMARY: pass=9 fail=4` · Job failed · pg 6 PASS · **결함 2건**:
  ① default 줄 `USER default OFF -@all`(처음 설계 D6)이 모든 사용자의 AUTH를 막았다(`AUTH failed: NOPERM default has no ACL permissions` — `reader-get` FAIL · `reader-set-denied` · `reader-cross-denied` · `noperm` PASS는 거짓 양성 ·
  정리 DEL 실패 → §0 default 줄 정정 · §1 「모든 사용자 AUTH 실패」) ② 검사 Job 기동 경합 — 첫 세 호출(`noauth` · `acl-list` · `writer-set`)만 `Connection refused`(Dragonfly 재시작 0 · 엔드포인트 ready
  → 새 pod의 NetworkPolicy 반영 전 REJECT로 판단 → data-assert 기동 유예 `wait_ready` — `platform/policies/tests/README.md` 검증 기록 T057 r2). 판정 보류 — **재측정 예정**(acl 2경로 재렌더 → pod 삭제 →
  이 수정 PR 머지 → VD-4 Job 재적용).
- **로컬 Docker 실측(2026-10-22 · 같은 이미지 v1.40.1 amd64 · 모의 비밀번호 · 컨트롤러)**: default 줄 `-@all`은 1차와 같은 전 사용자 AUTH 실패를 재현했고, `+@connection` · `+auth +hello`는 둘 다 비인증 PING `NOAUTH` ·
  AUTH 성공 · `ACL LIST` 행 `user sample-pod on #<15hex> %R~revoked:* ~sample-pod:* resetchannels +@all $all`(`%R~` 적재) · identity-admin SET · sample-pod GET 성공 · revoked SET/DEL과 교차 SET `NOPERM` · 자기 접두 SET 성공 ·
  `HELLO 3 AUTH` 성공 · 틀린 비밀번호 거부 → **옵션 A 성립(로컬)** — 라이브 재측정이 확정한다(결과 한 줄은 tasks.md T057 체크박스 옆과 report.md — 컨트롤러).

---

## 4. 값 선택 근거

| 값 | 출처 | 비고 |
|---|---|---|
| 이미지 `ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c213e82fb51b4521660cca13f06f3421dc5b1ed14f2f474c50b5e29986` | tasks.md T057 문면(v1.40.1) · 계약 §이미지(태그 + digest 병기) · 2026-10-22 ghcr.io registry v2 API 조회(익명 토큰 → `GET /v2/dragonflydb/dragonfly/manifests/v1.40.1` · Accept OCI index · 헤더 `docker-content-digest` = 본문 sha256 일치) | OCI image index — linux/amd64 `sha256:26893a7d1f8697e343b462dee82ef5cb836c58f123c0e1dfc0fe9bae33081d49` · linux/arm64 `sha256:58070cae9b5e0b5b8ec6fb4ff055e3e96be6b86a58dc8ed3906d3be560463c57`(노드 2대 = arm64). 태그 목록의 v1.40.2는 Renovate PR로(§6) |
| `command` 없음 · uid/gid/fsGroup 999 · `runAsNonRoot` | 이미지 config(arm64 config `sha256:bd30867b…`: `User` 없음 · Entrypoint tini → entrypoint.sh · Cmd `dragonfly --logtostderr` · WorkingDir `/data` · history `groupadd -r -g 999 dfly && useradd -r -g dfly -u 999 dfly`) · entrypoint.sh(아래) · 결정 D2 | tini가 SIGTERM을 전달해 종료 스냅샷이 돈다. uid 999는 entrypoint의 root 분기(chown · setpriv)를 건너뛴다. 숫자 UID = kubelet의 비루트 판정(이미지 `User`가 비었다) |
| args 4개(문면) `--maxmemory=768mb` · `--aclfile /etc/dragonfly/users.acl` · `--dir /data` · `--snapshot_cron "*/5 * * * *"` | tasks.md T057 · 계약 §ACL · 하네스 df-1(토큰 모양 — `=`와 분리 표기 둘 다 받는다) | 768mb ≥ 스레드 수(노드 B vCPU 2) × 256MiB(아래 소스). `requirepass`는 쓰지 않는다(문면) |
| `--dbfilename=dump` | 결정 D4 · `server_family.cc` :112(기본 `dump-{timestamp}`) · `snapshot_storage.cc` :311–354(적재 글롭) | 기본값 + 5분 cron = 파일 무한 누적(보존 플래그 없음). 고정 이름 = 덮어쓰기. 대가: 스냅샷 이력 없음(캐시 — 30 s 재적용) |
| `--primary_port_http_enabled=false` | 결정 D5 · `main_service.cc` :2956–2968 | requirepass가 비면 주 포트 HTTP 무인증(ACL 사용자는 세지 않는다). 대가: `/metrics` 없음(T098) |
| env 0 · envFrom 0 · 금지 토큰 0 | 계약 §ACL(인증은 ACL 사용자만) · 하네스 df-1 · `user_registry.cc` :158–168(`DFLY_PASSWORD` · `DFLY_requirepass`) | 비밀번호의 길은 aclfile 하나 |
| 프로브 tcpSocket 3종(startup 2 s × 60 · readiness 10 s × 3 · liveness 10 s × 6 · timeout 5) | 결정 D2(**근거 정정 2026-10-22** — 아래 「이미지에 redis-cli는 있다」) | default OFF → 비인증 명령 `-NOAUTH` · 자격 없는 exec 프로브 = TCP 확인 · HTTP `/healthz`는 D5로 닫힘 · `-LOADING` 창은 짧고 소비자 fail-closed |
| requests cpu 100m / memory 256Mi · limits memory 900Mi(CPU limit 없음) | tasks.md T057(256Mi/900Mi) · 저장소 관례(CPU limit 없음 — cloudflared · 검사 Job과 같다) | 메모리 requests ≠ limits → QoS Burstable(T097) |
| `strategy: Recreate` · `replicas: 1` · `terminationGracePeriodSeconds: 60` · `nodeSelector role=data` | tasks.md T057 · 계약 §쓰기 규약(grace 60 명시) · plan A14(노드 B) | RWO PVC를 두 pod가 동시에 잡지 않는다 · 기본 30 s에 기대지 않는다 |
| PVC local-path 2Gi · RWO · `Delete=false,Prune=false` · 리소스 wave `"1"` | tasks.md T057 · 계약 §삭제 보호 · 하네스 argo-4-dragonfly · 결정 D3 | WaitForFirstConsumer라 Deployment와 같은 wave(pvcs.yaml 머리 주석) |
| ACL ES template 없음 · Owner · Periodic 5m · 삭제 보호 없음 · 리소스 wave `"0"` | 결정 D7 · T056 결정 D2 선례 · 계약 §공통 규칙 | Secret 키 = `users.acl` 하나 · ES 메타데이터가 Secret에 복사된다(Argo는 관리 대상으로 세지 않는다) |
| Service ClusterIP 6379 · selector name + instance | 결정 D8 · 계약 §ACL `DRAGONFLY_URL` 호스트 | dev/prod가 서로의 pod를 고르지 않는다 |
| Reloader 어노테이션 없음 | 결정 D9 · 계약 §Reloader(감시 ns = identity · jt-dev · jt-prod) | ns data를 감시에 더하면 data의 **모든** Secret(pg 자격 · Kafka CA 키 등) 읽기 권한이 생긴다 → 회전은 `ACL LOAD`(§5) |

**받아들인 사실**(이 PR에서 바꾸지 않는다):
- 검사 Job의 redis-cli `-u "$URL"`은 프로세스 argv에 자격을 싣는다(같은 pod 안의 프로세스만 본다 · Job 로그에는 나오지 않는다 — `platform/policies/tests/README.md` §로그 계약).
- 주 포트 HTTP를 닫아 `/metrics`가 없다 — 관측은 T098에서 `--admin_port` + 계약 매트릭스 행 추가(monitoring → data) 또는 exporter로 다시 연다(§6).
- `ACL SAVE`는 실패한다(aclfile은 읽기 전용 Secret 마운트 — 정본은 kv). 그 로그 `Failed to open the aclfile: …`(LOG(ERROR))는 `ACL SAVE` 경로(`acl_family.cc` :256–270) 문구다 — 읽기 전용 마운트라
  누가 `ACL SAVE`를 실행하면 정상 실패 · 적재 실패 신호가 아니다(§1 둘째 행의 문구 4개에 넣지 않는다). 런타임 `ACL SETUSER`는 다음 기동 · `ACL LOAD`에서 사라진다.
- **운영자 함정 — 이미지 안 redis-cli 6.0.16은 `-u` URL(`redis://` + `<user>:<pw>@` + 호스트)의 사용자 이름을 보내지 않는다**(redis 6.0.16 `src/redis-cli.c` `parseRedisUri` :412–419 "If provided, username is ignored." ·
  `cliAuth` :763–766 — 사용자가 없으면 인자 1개 `AUTH <pw>`) → Dragonfly는 인자 1개 AUTH를 사용자 `default`로 처리하고(`server_family.cc` :2053–2056) default는 비밀번호 없는 OFF라 인증이 실패한다
  (6.0은 `Warning: AUTH failed`만 찍고 다음 명령을 보내 `NOAUTH`가 된다 — :767–771 · :920). 그래서 운영자 명령은 `redis-cli --user <u> --askpass`(또는 `--user … --pass` — :1479–1486)로 적는다(§1 · §2 · §5).
  검사 Job의 redis-cli **8.8.2**는 URL의 사용자 이름을 보내므로(redis 8.8.2 `src/cli_common.c` :325–333 `connInfo->user` → 2인자 AUTH) `-u` 형식이 정상이다.
- identity-admin · sample-pod(· 앱 `<pod>`)의 `+@all`에는 `@admin`(`ACL SETUSER` · `CONFIG` · `SHUTDOWN` 등 — `acl_family.cc` :1263 · `server_family.cc` :4015 · :4026)과 키 인자가 없는
  `FLUSHALL`(`@keyspace` · `@write` · `@dangerous` — `server_family.cc` :4019 · 키 패턴 검사는 키 인자가 있는 명령에만 — `validator.cc` :155)이 든다(계약 denylist.md §ACL 표 — 키 패턴과
  명령 카테고리는 짝지어지지 않는다) — 자격이 노출된 소비자는 런타임 ACL을 바꾸거나 캐시를 비울 수 있고, 런타임 ACL 변경은 `ACL LOAD`·재기동에서(`CONFIG SET`은 재기동에서) 사라진다
  (복구 = `ACL LOAD` 또는 재기동 · 비운 캐시는 30 s 재적용이 채운다 · 탐지 = VD-4 시점 `noauth`·`ACL LIST` — 주기 탐지는 §6 T098).

**소스로 확인한 사실**(2026-10-22 · 원문 판독 — **라이브 미실측**). 줄 번호 기준 = Dragonfly 태그 `v1.40.1` · Argo CD `v3.5.2` · K3s `v1.36.5+k3s1` · redis `8.8.2`(검사 Job 이미지의 redis-cli).

- **aclfile 로더**(`src/server/acl/acl_family.cc`): `Init` :642–656 — `--aclfile`이 있고 `Load()`가 성공하면 끝, **실패하면 `registry_->Init()`으로 기본 레지스트리(default nopass · `+@all` · `~*` · `&*`)로 기동한다**(로그는 LOG(WARNING)뿐 — 파일 오류 = 무인증 인스턴스) ·
  `LoadToRegistryFromFile` :293–358 — 파일 읽기 실패(:296–302 `Dragonfly could not load ACL file … with error …`) · 빈 파일(:307–308 — `Empty file` · **로그 없음**) · materialize 실패(:314–318 `Error materializing acl file`) · 한 줄이라도 토큰 오류(:322–328 `Error while parsing aclfile: …`) → 전체 로드 실패 ·
  사용자마다 `-@all`을 먼저 적용한 뒤 줄의 토큰을 적용(:342–350) · **파일에 `default`가 없으면 `DefaultUserUpdateRequest()`(nopass · `+@all` · `~*` · `&*`)로 default를 만든다**(:353–357 · `user_registry.cc` :136–145) ·
  `MaterializeFileContents` :727–748 — `\n`으로 나눔(:731) · 빈 줄은 건너뜀(:736–737 — 끝 줄바꿈 뒤의 빈 조각도) · 공백 하나로 나눔 + 빈 토큰 무시(:738) · 첫 토큰 `USER`(대소문자 무시) **그리고 토큰 ≥ 4가 아니면 실패**(:739–741) · 사용자 이름 = 둘째 토큰(:743) ·
  나머지는 `ParseAclSetUser(args, hashed=true)`(:323) — `#<hex>` 해시 허용(:1087–1092 · `MaybeParsePassword` :838–857) · 키 `~p` · `%R~p` · `%W~p` · `%RW~p` · `allkeys` · `resetkeys`(:757–787) · 채널 `&p` · `allchannels` · `resetchannels`(:796–812) ·
  `ON`/`OFF`는 대문자로 바꾼 뒤 비교(:1148 → `MaybeParseStatus` :859–867 — 대소문자 무시) · 그 밖의 토큰 → `Unrecognized parameter <토큰>`(:1175 — CR이 붙은 `+@all\r`도 여기) ·
  **실행 중 `ACL LOAD`**(:368–380)는 같은 함수로 다시 읽되, 읽기 · 파싱이 레지스트리를 건드리기 **전에** 끝나므로(:296–330 → 쓰기 잠금 :332) 실패해도 **옛 규칙이 남는다** · 성공하면 기존 연결을 모두 끊는다(:334–340 `EvictOpenConnectionsOnAllProactorsWithRegistry`).
- **해시**: `user.cc` :92–104 `SetPasswordHash` — `#` 뒤 hex를 바이트로 바꿔 저장 · `absl::HexStringToBytes` 실패면 `LOG(ERROR) << "Invalid password hash: " << <값>`(:99 — **값을 그대로 로그에 찍는다**) · 그 사용자는 비밀번호 없이 ON.
  인증 = 입력 비밀번호 바이트의 SHA-256이 저장된 바이트 집합에 있는가(`StringSHA256` :18–24 · `HasPassword` :128–133) → aclfile의 `#<hex>` = kv `password` 값(UTF-8 바이트)의 SHA-256 hex. `ACL LIST`(`acl_family.cc` :85–112)는 소문자 `user` + `#` + 해시 **15자 축약**(`PasswordsToString` :869–880 · `PrettyPrintSha` :831–836) + 키(`AclKeysToString` :882–900 — `%R~p` 표기 유지) + 채널(`AclPubSubToString` :902–915 — 패턴이 없으면 `resetchannels`) + 카테고리 + `$<db>` · `ACL SAVE` 형식(`RegistryToString` :227–251) = `USER <이름> ON|OFF #<전체 sha> <키> <채널> <카테고리> $<db>` — 로더는 이 형식을 그대로 읽는다.
- **인증**(`src/server/main_service.cc`): `CreateContext` :1869–1890 — 새 TCP 연결은 default 자격으로 시작하고 `req_auth = !AuthUser("default", "")` · `AuthUser` = `IsActive && HasPassword`(`user_registry.cc` :111–119) → **default가 OFF면 비인증 명령은 전부 `-NOAUTH Authentication required.`**(:1403–1407 — AUTH · HELLO · QUIT · RESET만 예외) · NOPERM 문구 `-NOPERM <사용자> <사유>`(:1340) · 적재 중 명령 `-LOADING`(:1385–1386 — 상태 검사가 인증 검사보다 앞).
  **NOAUTH 관문을 통과한 `AUTH` · `HELLO`도 ACL 검사를 받는다**(T057 수정 라운드 r2 · F12): 관문(:1403–1407)과 같은 함수 `VerifyCommandState`(:1345)의 끝에서 `VerifyConnectionAclStatus`(:1462 → :1335–1343)가
  `acl::IsUserAllowedToInvokeCommand`(`src/server/acl/validator.cc` :85–113 · :115–135 — 연결의 `acl_commands` = **현재 사용자 default의 ACL**)로 검사하고, 실패면 `-NOPERM default has no ACL permissions`(:1340)다.
  `AUTH` · `HELLO`의 카테고리는 `FAST | CONNECTION`(`server_family.cc` :4012 `kAuth` · :4021 `kHello` · 등록 :4045 · :4056) → default가 `-@all`이면 AUTH가 거부돼 **아무도 인증할 수 없다**(2026-10-22 VD-4 1차 실측 ·
  로컬 v1.40.1 재현) → default 줄 `USER default OFF +auth +hello`(§0). 인자 1개 `AUTH <pw>`는 사용자 `default`로 인증을 시도한다(`server_family.cc` :2053–2063 — default가 OFF라 실패).
  `ACL LIST`의 default 행 모양 = `user default off resetchannels -@all +auth +hello $all`(로더가 사용자마다 `-@all`을 먼저 적용한 뒤 `+auth +hello`를 더한다 — 위 aclfile 로더 :342–350 · 2026-10-22 로컬 v1.40.1 실측).
- **HTTP 콘솔**: `ConfigureHttpHandlers` :2956–2968 — `should_skip_auth = (privileged && !RequirePrivilegedAuth()) || GetPassword().empty()` · requirepass가 있어도 `/metrics` · `/healthz`는 항상 무인증(:2964–2965) · `GetPassword()` = `--requirepass` 또는 `DFLY_PASSWORD`(`server_family.cc` :1967–1979 — ACL 사용자는 세지 않는다) ·
  `--primary_port_http_enabled`(기본 true — `src/facade/dragonfly_connection.cc` :58 · 판정 :1323–1331 · `dragonfly_listener.cc` :162–167) · `--expose_http_api` 기본 false(`main_service.cc` :103–104).
- **메모리 · 스레드**: `--maxmemory` 플래그 설명 "Must be *at least* 256MiB per proactor thread"(`main_service.cc` :106–112) · 미달이면 `There are N threads, so … are required. Exiting...` 후 exit 1(`dfly_main.cc` :316–322) · cgroup `cpu.max`가 `max`(CPU limit 없음)면 스레드 수 = 풀 기본값 = 노드 vCPU(`dfly_main.cc` :685–691 · :1205–1216) ·
  io_uring을 쓸 수 없으면 epoll로 내려간다(`ShouldUseEpollAPI` :516–553 — ENOSYS · EPERM · ENOMEM마다 WARNING 문구).
- **스냅샷**(`src/server/server_family.cc`): 플래그 `dir`(:111) · `dbfilename` 기본 `dump-{timestamp}`(:112) · `snapshot_cron`(:121) · 기동 `LoadFromSnapshot` :1283–1316(적재는 별도 fiber · 실패 = **exit 1** :1298–1301 · :1312–1313 · 파일 없음 = `Load snapshot: No snapshot found` WARNING :1307) ·
  종료 `Shutdown` :1324–1345(`save_on_shutdown_` && dbfilename이 비어 있지 않으면 `DoSave()` · 실패 = `Failed to perform snapshot` WARNING) · `snapshot_storage.cc` `LoadPath` :311–355(정확 일치 → 없으면 `{timestamp}`를 `*`로 · 확장자 없으면 `*`를 붙인 글롭 → mtime 정렬 → 가장 최근 `*-summary.dfs`/`.rdb`) ·
  `save_stages_controller.cc` `ValidateFilename` :64–80(`"`로 시작 금지 · 디렉터리 구분자 금지 — 기동 때 `ValidateSnapshotFilenameFlags`(`server_family.cc` :1017–1024 · `dfly_main.cc` :1133–1136)).
- **이미지 진입점**(`tools/docker/entrypoint.sh` v1.40.1): :7 `ulimit -l 65000`(비특권이면 조용히 실패) · :11–15 첫 인자가 `-`로 시작하면 `dragonfly --logtostderr`를 앞에 붙인다 · :18–24 root면 `chown` + `setpriv --reuid=dfly` · :26–29 `umask 0077`(현재 0022일 때) · :31 `exec "$@"`.
  `tools/docker/healthcheck.sh` :32–36 = `echo PING | nc -q1 localhost <포트>`(응답을 판정하지 않는다).
- **이미지에 redis-cli는 있다**(2026-10-22 레이어 판독 — 실행 없음): arm64 레이어 `sha256:334c08486e6ac2db1ad88da971526a36eea91d120b85b7a3f383378de0f9ca4c`(history `apt install … netcat-openbsd ca-certificates redis-tools net-tools tini`) 목록에 `usr/bin/redis-cli` · dpkg `redis-tools 5:6.0.16-1ubuntu1.1` · 기반 Ubuntu 22.04.5 LTS ·
  redis-cli 6.0.16에 `--user` · `--askpass` · `--no-auth-warning`가 있다(redis 6.0.16 `src/redis-cli.c` :1477–1485). 모노레포 build-notes 「T057」 1차 자료의 "redis-cli 없음"은 이 판독으로 정정한다(프로브 결정은 그대로 — 위 표).
- **Argo CD v3.5.2**: PVC health `gitops-engine/pkg/health/health_pvc.go` :28–41 · 적용 순서 `gitops-engine/pkg/sync/sync_tasks.go` :24–66(PersistentVolumeClaim :40 · Service :50 · Deployment :55) · cascade 삭제 판정 `controller/appcontroller.go` :1251–1260 `shouldBeDeleted`(객체 어노테이션 `Delete=false`가 Application syncOptions보다 먼저 · CRD 제외) · tracking 방식 = annotation(`bootstrap/argocd/argocd-cm.yaml` :39 — `app.kubernetes.io/instance` 라벨은 tracking에 쓰이지 않는다).
- **K3s v1.36.5+k3s1** `manifests/local-storage.yaml`: StorageClass `local-path` :92 · `volumeBindingMode: WaitForFirstConsumer` :97 · `reclaimPolicy: Delete` :98 · setup `mkdir -m 0777 -p "${VOL_DIR}"` :118.
- **문서 vs 소스**: dragonflydb.io ACL 문서 Persistence 절의 "aclfile은 키·pub/sub DSL을 지원하지 않는다"는 v1.40.1 로더와 맞지 않는다(위 :757–812 — 계약 §VD-4 기본 가정과 같다). 외부 서비스는 실측으로 확정한다 → VD-4.

---

## 5. 운영 위험 · 되돌리기

Application `platform-dragonfly`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`이고, PVC 2장에만 객체 어노테이션 `Delete=false,Prune=false`가 있다(계약 §삭제 보호 목록). 그래서

> **Git revert는 객체를 지우지 않는다**(렌더 0 → 객체는 남고 Application은 `OutOfSync`가 정상). PVC 어노테이션은 이 PVC가 **Argo가 직접 관리하는 객체**라 Argo 경로에서 실효다 — prune에서 빠지고
> Application cascade 삭제에서도 빠진다(Argo CD v3.5.2 `appcontroller.go` :1251–1260 — StatefulSet이 만드는 Vault PVC의 '표식'과 다르다). **`kubectl delete`는 막지 못한다** — 두 번째 겹은 Application의
> `Prune=confirm`·`Delete=confirm`(나머지 6장의 삭제 승인)과 아래 절차다.

| 무엇을 지우면 | 무슨 일이 일어나는가 | 되돌리기 |
|---|---|---|
| **ACL ES** | Secret GC(Owner) → **이미 뜬 Dragonfly는 적재한 규칙으로 계속 돈다**(파일은 기동 · `ACL LOAD` 때만 읽는다) → 다음 재시작은 Secret 볼륨이 없어 ContainerCreating | selfHeal이 ES를 다시 만든다 → ≤ 수 초에 Secret 재생성 |
| **Deployment**(또는 pod) | 그 env의 거부 목록 조회가 실패 → 앱은 **fail-closed 503**(계약 §조회 규약 3) · 정상 종료면 종료 스냅샷이 남는다 | selfHeal 재생성 → 스냅샷 적재 → 30 s 재적용이 나머지를 채운다 |
| **Service** | 소비자 DNS 실패 → 503 | selfHeal 재생성 |
| **PVC**(kubectl) | pod가 쓰는 동안은 `kubernetes.io/pvc-protection` finalizer로 Terminating에 머문다 → pod가 사라지면 PVC · PV · **스냅샷 삭제**(reclaim Delete) | selfHeal이 빈 PVC를 다시 만든다 → 새 PV(노드 B) → 빈 캐시로 기동 → 30 s 재적용이 채운다(데이터 정본은 DB) |
| **Application**(cascade · finalizer `resources-finalizer.argocd.argoproj.io` · `Delete=confirm` 승인 필요) | ES 2 · Service 2 · Deployment 2 삭제 → 두 env 모두 503 · **PVC 2는 남는다**(어노테이션) | Application 재생성(root) → PVC는 그대로 다시 관리된다. 이 Application을 지우는 일은 하지 않는다(필요하면 컨트롤러 · 사용자 결정) |

**되돌리기 순서**(이 PR을 무르고 객체까지 치워야 할 때 — 운영자 · admin kubeconfig):
1. revert PR 머지 → 렌더 0 → 객체는 남고 `OutOfSync`. **여기서 멈추는 것이 기본이다**(소비자가 아직 없다 — T072 전).
2. 지워야 한다면 소비자 0을 먼저 확인한다(앱 `<pod>-env`의 `DRAGONFLY_URL` · 검사 Job).
3. Deployment → Service → ES 순서로 수동 삭제. PVC는 마지막 · 필요할 때만(스냅샷 삭제 = 캐시 삭제라 데이터 손실은 아니다).
4. Vault kv 7경로는 지우지 않는다(값 교체는 회전 절차 — 런북 §4 T057 「정리 판단」은 **머지 전**에만).

**회전**(결정 D9 · 실행은 T084 `secret-rotation.md` — 이 PR은 값을 회전하지 않는다):
1. kv의 사용자 경로(`<user>` 키 `password` · `url`)와 그 env의 `acl`을 **함께** 갱신한다(시드 블록 — aclfile은 새 비밀번호로 재렌더).
2. ESO가 ≤ 5분에 Secret `dragonfly-<env>-acl`을 갱신 → kubelet이 마운트 파일을 갱신(원자적 심볼릭 링크 교체 · 수십 초~수 분).
3. 운영자가 `kubectl -n data exec -it deploy/dragonfly-<env> -- redis-cli --user admin --askpass ACL LOAD`(관리자 kubeconfig · 비밀번호는 프롬프트 입력).
   **`ACL LOAD`를 rollout restart보다 먼저 쓴다**: 실행 중 적재가 실패하면 옛 규칙이 남고(오류 응답 — 안전한 실패) 성공하면 모든 연결을 끊어 소비자가 새 비밀번호로 다시 붙는다.
   rollout restart(Recreate)는 다운타임이 있고, 그때 파일이 잘못돼 있으면 **무인증으로 기동한다**(위험한 실패 — §1 증상표 둘째 행).
4. 앱 `<pod>-env`는 같은 kv를 ≤ 5분에 받고 Reloader가 앱 Deployment를 롤아웃한다(감시 ns jt-dev · jt-prod) — 그 사이 옛/새 비밀번호가 엇갈리는 창은 T084가 실측한다.
5. 끝나면 `noauth` · `ACL LIST`를 다시 본다(§3 VD-4 Job 재실행 또는 위 운영자 명령).

**그 밖의 위험**:
- **`requirepass` · `DFLY_PASSWORD` · `--flagfile` · `--fromenv`를 더하지 않는다** — 하네스 df-1이 FAIL하고, requirepass가 생기면 HTTP 콘솔 판정(§4)과 default 사용자 비밀번호가 바뀐다.
- **aclfile에 평문 비밀번호(`>pw`)를 쓰지 않는다** — 로더는 받아들이지만(:848–849) ns data Secret에 평문이 실린다. **`#` 뒤에 hex가 아닌 값을 쓰지 않는다** — 그 값이 pod 로그에 찍힌다(§4 해시).
- **replica를 늘리지 않는다**(RWO PVC · Recreate · 인스턴스끼리 데이터를 나누지 않는다 — 계약은 env마다 인스턴스 하나).
- **Reloader 어노테이션을 붙이지 않는다**(감시 밖 ns라 무시되고, 감시에 data를 더하면 data의 모든 Secret 읽기 권한이 생긴다 — 결정 D9).
- **노드 B vCPU를 늘리면** `--maxmemory=768mb`의 스레드 조건을 다시 계산한다(§1 · §4).
- **스냅샷 삭제 절차**(손상 · 디스크 — 운영자 · admin kubeconfig): CrashLoop 중인 pod는 적재 단계에서 끝나므로 파일을 쓰지 않는다.
  ① 노드 B의 PV 디렉터리(`/var/lib/rancher/k3s/storage/<pv 이름>_data_dragonfly-<env>-data/`)에서 `dump*`를 지우거나, 같은 PVC를 마운트한 일회용 pod(노드 B · uid 999 · 같은 securityContext)로
  `/data/dump*`를 지운다 — RWO는 노드 단위라 같은 노드의 두 pod가 함께 마운트할 수 있다(replica를 0으로 줄이면 selfHeal이 곧 1로 되돌린다) ② 일회용 pod 삭제 ③ Dragonfly pod 삭제(또는 다음
  CrashLoop 재시작) → `Load snapshot: No snapshot found` → 빈 캐시 → 30 s 재적용이 채운다. 데이터 손실은 없다(정본 = DB).

---

## 6. 인계

- **T059(US3 E2E · 검사 Job Application)**: `platform/policies/tests` Application(AppProject `tests`)이 `data-assert`를 돌린다 — Dragonfly 7검사(noauth · acl-list · writer-set · reader-get · reader-set-denied · reader-cross-denied · noperm) +
  `NOTE: cleanup` 1줄 · 최대 22줄(`platform/policies/tests/README.md` §로그 계약 · 검증 기록 T057). VD-4 임시 적용(§3)을 Application 배포로 대체 · `ttlSecondsAfterFinished` 7d · 하네스 job-d-1/2 · np-2-data-assert · data job-1/2.
  병합 절의 결과 파일 부재 fallback(Dragonfly 7 id 각 1줄 FAIL · 14줄)은 이 PR 수정 라운드 r1이 끝냈다 — 인계 없음.
  **kafka-assert · authz-assert도 기동 경합 후보다** — 새 pod의 첫 1–2초 NetworkPolicy(kube-router) 반영 전 REJECT(§3 VD-4 1차 실측 ②) → 같은 `wait_ready` 패턴(첫 호출 전 연결 확인 · 1초 간격 최대 15회 · 걸린 초를 첫 검사 근거에 — data-assert initContainer T057 수정 라운드 r2 · `platform/policies/tests/README.md` 검증 기록 T057 r2).
- **T062 · T066 · T072(앱 템플릿 · identity-admin)**: `DRAGONFLY_URL` ← `kv/{env}/dragonfly/<pod>` 키 `url`(`<pod>-env` · store `vault-{env}`) · 키 접두 `<pod>:`(Celery `global_keyprefix` · Django `KEY_PREFIX`) ·
  **채널 ACL 실측** — Celery/Kombu(pidbox · events · result backend pub/sub)가 채널을 쓰면 `<pod>` 줄에 `&<pod>:*`가 필요할 수 있다(지금은 `resetchannels` — `ACL LIST`에 보인다). 새 pod = aclfile 한 줄 + kv 경로 1개 추가(시드 블록 · 그 env의 `acl` 재렌더) — 이 디렉터리의 매니페스트는 바뀌지 않는다.
- **T084(회전)**: §5 회전 순서 실측 · `secret-rotation.md`에 Dragonfly 행(kv `<user>` + `acl` 동시 · `ACL LOAD` 우선 · 앱 `<pod>-env` Reloader) · 새 값도 P1 형식 · `ACL LOAD` 성공 = 기존 연결 전부 끊김(`acl_family.cc` :334–340 — §4) → 소비자 재접속 창 실측.
- **T085(US4 E2E)**: SIGKILL 뒤 ≤ 30 s 안에 폐기된 세션이 다시 401(계약 §검증) — `--dbfilename=dump`라 스냅샷 이력이 없으므로 "스냅샷 없음/손상 → 빈 캐시 → 30 s 재적용" 경로도 같은 기준으로 본다(결정 D4).
- **T097**: 메모리 실측(VD-7) · QoS Burstable(requests 256Mi ≠ limits 900Mi) · OOM 여유.
- **T098(관측)**: `/metrics` 경로 — 주 포트 HTTP를 닫았으므로 `--admin_port`(별도 포트 · 계약 매트릭스 monitoring → data 행 추가 + `platform/policies` 정책) 또는 exporter 중 컨트롤러 결정 · 알림 후보: pod 로그 `Error while parsing aclfile` · `Error materializing acl file` · `could not load ACL file` · `Invalid password hash`(무인증 기동 · 사용자 잠김 — §1 둘째 · 셋째 행의 문구 4개) · OOMKilled · `Failed to perform snapshot` ·
  주기적 비인증 PING(기대 `-NOAUTH` · `PONG`이면 무인증) + `ACL LIST` 행 수 · `default off` 대조 — 빈 aclfile 경로는 로그 문구로 잡히지 않는다(§1 둘째 행).
- **Renovate**: v1.40.2 이상으로 올리는 PR은 태그와 **인덱스** digest를 함께 바꾼다(arm64 포함 확인) · 이 README §4의 소스 줄 번호를 새 태그로 다시 판독한다(특히 aclfile 로더 · HTTP 콘솔 판정).
- **VD 결과 기록 위치**: 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T057 절(머지 → operation → Ready 시각 · retryCount · 하네스 결과 · VD-4 판정) + build-notes 「T057」 + report.md(VD-4 결과 한 줄).
