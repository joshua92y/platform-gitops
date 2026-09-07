# platform/system-upgrade/ — K3s 자동 업그레이드 (T037, FR-048)

system-upgrade-controller(SUC) v0.20.1과 Plan 2개(`k3s-server` = 노드 A, `k3s-agent` = 노드 B)로 K3s **패치**를 매주 일요일 03:00–05:00 KST 창에서
자동 승격한다(채널 `v1.36`). `k3s-server` Plan은 업그레이드 전에 `platform-backup.sh --pre-upgrade`를 호스트에서 실행하고 **성공했을 때만** 진행한다.
이 디렉터리는 **SUC + Plan만** 소유한다. T037은 코드만 작성했고 **라이브 실행은 없다** — 클러스터 적용은 T041 Argo CD sync 또는 그 전 운영자 수동 apply(②).
운영자의 창 뒤 확인 절차는 모노레포 `docs/runbooks/bootstrap.md` §6이 정본이다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `namespace: system-upgrade` + 아래 4개 + Deployment 패치 + CRD 삭제 보호 어노테이션. 레이아웃(복사 vs 원격 참조)·digest 조회·Plan 이미지 예외·이 디렉터리가 만들지 않는 것의 근거가 머리 주석에 있다 |
| `crd.yaml` | SUC v0.20.1 릴리스 `crd.yaml` **원본 그대로**(sha256 `68a2e6b7…c656`) — `Plan` CRD |
| `controller.yaml` | 릴리스 `system-upgrade-controller.yaml`에서 첫 문서(Namespace)를 빼고 이미지 2줄에 digest를 병기한 사본(SA·Role·ClusterRole 2·바인딩 3·ConfigMap `default-controller-env`·Deployment) |
| `controller-patch.yaml` | Deployment 패치: requests 30Mi/10m · limit 128Mi · `nodeSelector role=platform` · pod securityContext · `readOnlyRootFilesystem`(이미지가 `FROM scratch` 단일 바이너리) · tolerations(업스트림 5개 + `node.kubernetes.io/unschedulable` — 노드 A가 cordon된 동안 컨트롤러 pod가 다시 만들어져도 Pending이 되지 않게) |
| `plan-k3s-server.yaml` | 노드 A: prepare(백업 게이트, privileged chroot) → cordon → upgrade. `jobActiveDeadlineSecs 1800` |
| `plan-k3s-agent.yaml` | 노드 B: prepare(`prepare k3s-server` = 서버 완료 대기) → cordon → upgrade. `jobActiveDeadlineSecs 3600` |

## 경계 — 이 디렉터리가 만들지 않는 것

- **Namespace `system-upgrade` + PSA 라벨(`privileged`)**: T041 `platform/policies/`. 사유(계약 network-policy.md 네임스페이스 표): Plan Job의 hostPID·hostIPC·hostNetwork·`chroot /host`가
  SUC에 하드코딩돼 있다(kustomization 머리 주석에 소스 행). T041 전에는 ①로 수동 생성한다.
- **Application `platform-system-upgrade`**: T041 app-of-apps(project `platform`, path `platform/system-upgrade`, ns `system-upgrade`, sync-wave = 계약 단일 표, 표준 syncOptions +
  `SkipDryRunOnMissingResource=true` — CRD와 Plan이 같은 Application이라 필요).
- **NetworkPolicy**(`allow-kube-api`, 외부 443 `update.k3s.io` — 컨트롤러 pod만): T041 `platform/policies/`. Plan Job은 hostNetwork라 정책 밖(계약 §hostNetwork 예외표; IMDS 보호는 인스턴스 측).
- **비밀**: 없다. 백업 스크립트의 자격은 노드 A instance principal뿐이고 이 저장소는 그 호출만 선언한다.

## 업그레이드 창에서 일어나는 일(순서)

1. **채널 해석**: 컨트롤러가 `https://update.k3s.io/v1-release/channels/v1.36`을 15분마다 조회(302 → `v1.36.N+k3s1`). SUC는 `+`를 `-`로 바꿔 저장하므로 Plan `status.latestVersion`과
   이미지 태그는 `v1.36.N-k3s1`이고 `kubectl get nodes`의 VERSION은 `v1.36.N+k3s1`이다 — **같은 버전이며 불일치가 아니다**. `status.latestVersion`이 바뀌면 해시가 바뀌고,
   라벨 `plan.upgrade.cattle.io/<plan>=<해시>`가 없는 노드가 대상이 된다.
   **수용 위험(창 안 채널 갱신)**: Job이 도는 중에 채널이 새 패치를 해석하면 SUC는 version 라벨 ≠ `status.latestVersion`인 **진행 중 Job도** 지우고(`handle_batch.go` 62–66행,
   Background 전파 — upgrade 컨테이너가 바이너리를 복사 중이면 `/usr/local/bin/k3s`가 깨질 수 있다) 새 Job을 즉시 만든다. 일요일 2시간 창 안에 릴리스가 겹칠 확률이 낮아
   수용한다(깨졌는지 확인은 §비상 정지 5). 피해야 하면 `version:` 고정(§수동 트리거 — 채널 조회 자체가 멈춘다).
2. **창 판정**: 일요일 03:00–05:00 KST 안에서만 Job을 만든다. 두 Plan의 Job은 **동시에** 생긴다(순서는 아래 prepare가 맡는다). 창 밖에서는 Job을 만들지 않는다(이벤트 `Waiting`) —
   **단, `status.applying`이 비어 있을 때만 창을 본다**(§실패 시의 "창 우회"). 창 안에서 시작한 Job은 05:00을 넘겨도 끝까지 간다.
3. **노드 A `apply-k3s-server-on-joshtech-api-with-<해시>`** (hostPID·hostIPC·hostNetwork, `/host` = 호스트 루트):
   - init `prepare` — `chroot /host /usr/local/bin/platform-backup.sh --pre-upgrade`: K3s SQLite 번들(+token·cred·tls) → age → OCI 버킷 `joshuatech-backup-platform` `k3s/`,
     Vault Raft 스냅샷 → `vault/`. **exit≠0이면 여기서 멈춘다**(cordon도 upgrade도 실행되지 않음). Job은 backoff로 pod를 다시 만들어 백업부터 재시도하고,
     1800초 안에 성공하지 못하면 Job Failed.
   - init `cordon` — `kubectl cordon joshtech-api`(이미지 `rancher/kubectl:v1.36.2`).
   - `upgrade` — `rancher/k3s-upgrade:v1.36.N-k3s1`이 `/host`의 k3s 바이너리를 sha256 비교 → 다르면 교체하고 k3s 프로세스에 SIGTERM → systemd가 새 버전으로 재시작.
     **같으면 "Binary already been replaced"로 exit 0(재시작 없음)**. 재시작 동안 API 서버가 수십 초~수 분 끊기고 파드는 계속 돈다.
   - Job 완료 → 컨트롤러가 노드에 해시 라벨을 붙이고 **uncordon**.
4. **노드 B `apply-k3s-agent-on-joshtech-cache-with-<해시>`**: init `prepare`(`prepare k3s-server`)가 Plan `k3s-server`의 `status.applying`이 비고 control-plane kubelet 버전이
   목표와 같아질 때까지 5초 간격 대기 → cordon → upgrade(백업 없음) → uncordon.
5. 두 Plan `Complete=True`. 끝난 Job은 **15분 뒤 삭제**된다(컨트롤러 기본 TTL) — 로그는 그 안에 보거나 Loki(T098)에서 본다.

**첫 창은 리허설이다**: T041 적용 시점의 클러스터(v1.36.4+k3s1)가 채널 최신과 같아도 라벨이 없으므로 Job은 만들어진다 — 백업 게이트·cordon·바이너리 비교·uncordon까지
실제로 돌고 재시작만 없다. 그 결과가 "게이트가 실제로 동작한다"는 첫 증거다(런북 §6 사후 확인 5 — 백업 timestamp가 창 시각인지).

## 백업 게이트(`platform-backup.sh --pre-upgrade`)의 범위 — T044 전후

정본은 모노레포 `infra/bootstrap/platform-backup.sh` 머리 주석 "--pre-upgrade 게이트 범위".

- k3s 번들: **항상 필수**.
- Vault 스냅샷: **배포돼 있을 때만 필수**(`kubectl -n vault get svc vault`로 탐지). **T044 전에는 vault ns/Service가 없으므로 `WARN: vault 미배포 … 이번 pre-upgrade 에서 건너뜀`을
  남기고 k3s만 백업한다** — 정상이며 업그레이드는 진행된다. T044 뒤에는 Vault 스냅샷 실패도 exit 1 = 업그레이드 차단.
- 게이트를 인자로 좁힐 수 없다(`--pre-upgrade`는 `--components`와 병용 거부). timer(02:30 KST)와 겹치면 flock으로 하나만 돈다(다른 쪽은 실패 → Job이 재시도).
- 성공 지표: 노드 A `/var/lib/node_exporter/textfile_collector/platform_backup_<k3s|vault>.prom`의 `platform_backup_last_success_timestamp`가 창 시각으로 갱신된다.

## 실패 시 상태와 복구

| 어디서 실패 | 노드 상태 | 보이는 것 | 복구 |
|---|---|---|---|
| `prepare`(백업) | cordon 전 — 스케줄 가능 그대로 | pod `Init:Error`, `kubectl -n system-upgrade logs <pod> -c prepare`에 `pre-upgrade gate: FAIL`; deadline 뒤 Job Failed, Plan `Complete=False` reason `JobFailed`, 이벤트 `JobFailed` | 아래 **복구 절차** 1(disabled 라벨) → 3(백업 원인: age 공개키·instance principal·버킷·Vault 접근) → 4 |
| `upgrade`(바이너리 교체·재시작) | **cordon 유지**(`SchedulingDisabled`) | `-c upgrade` 로그, 노드 A `journalctl -u k3s` | 복구 절차 1 → 2(uncordon) → 3 → 4 |
| 다운그레이드 시도 | cordon 유지 | `Error: Current … is higher than …` | k3s-upgrade는 다운그레이드를 거부한다 — 복구 절차 1·2 뒤 채널/버전을 현재 이상으로 바꾸는 PR; 되돌리기는 런북 `rollback`(T106)·bootstrap §7 번들 복원뿐 |
| agent prepare 대기 초과(서버 실패) | 노드 B는 cordon 전 | 3600초 뒤 Job Failed | 서버 Plan을 먼저 복구(1~4); 노드 B도 `k3s-agent`에 대해 같은 절차 |

**실패한 Plan은 창(window)을 우회한다 — SUC v0.20.1 소스로 확인한 사실**: 실패 처리(`pkg/upgrade/handle_batch.go` 86–101행)는 `status.applying`을 비우지 않고, 노드에
해시 라벨이 없어 같은 노드가 다시 선택되므로(`pkg/upgrade/plan.go` SelectConcurrentNodes 155–178행: applying 노드 우선) `applying=[노드]`가 남는다. 창 검사는
`len(applying)==0`일 때만 한다(`pkg/upgrade/handle_upgrade.go` 158–167행). 따라서 실패 뒤에는 **Plan의 resourceVersion이 바뀌는 순간 — retrigger PR 머지, 채널이 새 패치를 해석,
어떤 metadata 변경, 컨트롤러 pod 재시작 — 창 밖(Grafana mute 밖)에서 즉시** 백업→cordon→k3s 재시작 Job이 생긴다. 그 전까지(같은 resourceVersion)는 새 Job이 생기지 않는다
(wrangler `UniqueApplyForResourceVersion`).

**복구 절차 — (a) disabled 라벨로 확정**. 근거: 한 명령으로 즉시 실행 경로를 닫고, 노드 라벨은 gitops 관리 밖(`role=platform`처럼 설치 시 부여)이며 SUC README가 문서화한 수단이다.
대안 (b) Plan을 kustomization에서 빼는 PR(`Prune=confirm`) → 재추가 PR은 status를 초기화해 창을 지키지만 PR 2회·confirm으로 느리고 그동안 cordon이 남는다.
**라이브 미검증 — VD: T041 첫 창 뒤 실측**(런북 §6).

1. **즉시**: `kubectl label node <node> plan.upgrade.cattle.io/<plan>=disabled --overwrite` → 선택 노드 0 → `applying=nil`(`handle_upgrade.go` 179–186행; 노드 이벤트가 Plan을
   다시 평가한다 — `handle_core.go` 12행). 확인: `kubectl -n system-upgrade get plan <plan> -o jsonpath='{.status.applying}'`가 비어 있다.
2. cordon이 남았으면 `kubectl uncordon <node>`(disabled 상태에서는 성공 Job이 없어 자동 해제되지 않는다).
3. 원인 수정(로그는 15분 TTL 안에, 또는 Loki). 실패한 Job이 아직 있으면 `kubectl -n system-upgrade delete job <apply-…>`(같은 이름의 Job이 남아 있으면 재실행이 no-op이 된다).
4. 준비되면 `kubectl label node <node> plan.upgrade.cattle.io/<plan>-`(라벨 제거) → 노드가 해시 라벨 없이 다시 대상이 되고, 이때는 `applying`이 비어 있으므로 **창 검사를 거쳐
   다음 창에** 돈다. 같은 버전이면 `retrigger` PR은 필요 없다(해시 라벨이 없으므로).

## 비상 정지 · 즉시 uncordon(운영자, 라이브)

순서가 중요하다. (i) Job을 먼저 지우면 Plan이 같은 Job을 다시 만들 수 있다. (ii) disabled 라벨을 붙이면 `applying=nil`이 되고(`handle_upgrade.go` 179–186행), SUC는 applying에
없는 노드의 **진행 중 Job을 다음 Job 이벤트에 스스로 지운다**(`handle_batch.go` 145–149행) — 라벨 뒤에는 운영자가 삭제 시점을 잡을 수 없으므로 **바이너리 교체 구간은
라벨을 붙이기 전에** 넘긴다. **라이브 미검증 — VD: T041 첫 창 뒤 실측.**

1. **먼저 로그**: `kubectl -n system-upgrade logs <apply-…> -c upgrade`. `Deploying new k3s binary`가 보이면 `K3s binary has been replaced successfully`(수 초)까지 기다린다 —
   복사 중에 끊기면 `/usr/local/bin/k3s`가 깨질 수 있다. prepare/cordon 단계이거나 upgrade 컨테이너가 아직 시작 전이면 바로 2로.
2. `kubectl label node <node> plan.upgrade.cattle.io/<plan>=disabled --overwrite` — 그 노드에 대한 Plan을 멈춘다(두 노드 모두 = Plan 전체 정지). 이 시점부터 SUC가 진행 중 Job을
   스스로 지울 수 있다.
3. Job이 남아 있으면 `kubectl -n system-upgrade delete job <apply-…>` — pod가 종료된다(SUC가 이미 지웠으면 NotFound — 정상).
4. `kubectl uncordon <node>`.
5. **사후 확인**(노드에서, cloudflared SSH): `/usr/local/bin/k3s -v`가 실행되고 버전이 기대값(교체 전 또는 교체 후)인지, `sha256sum /usr/local/bin/k3s`가 그 버전 릴리스의
   `sha256sum-arm64.txt`(github.com/k3s-io/k3s/releases) 값과 같은지 대조한다. 다르면 bootstrap §7 번들 복원.
6. 다시 켤 때는 §실패 시 복구 절차 4(라벨 제거). Plan 자체를 없애려면 kustomization `resources`에서 빼는 PR(Argo `Prune=confirm` — 운영자 confirm 필요).

## 수동 트리거 · 버전 고정 · 일시 정지

전부 **PR로만**(main = 클러스터 정본). 라이브 `kubectl edit plan`은 Argo selfHeal이 되돌린다. Plan 해시는 spec 전체가 아니라
`latestVersion + serviceAccountName + upgrade.cattle.io/digest 어노테이션이 가리키는 경로 + secrets`이므로(plan-k3s-server.yaml 주석), spec의 다른 필드를 고쳐도 재실행되지 않는다.
**어느 방법이든 실패한 Plan(applying 잔존)에 쓰면 창 밖에서 즉시 실행된다 — 먼저 §실패 시 복구 절차 1.**

- **재실행(성공한 같은 버전을 다시)**: 해당 Plan의 어노테이션 `retrigger` 값을 바꾸는 PR(`"0"` → `"1"` …) → 해시가 바뀌어 **다음 창에** Job이 생긴다(applying이 비어 있을 때).
  **VD**: T041 첫 창 뒤 한 번 실측. 실패한 노드는 해시 라벨이 없으므로 retrigger 없이 disabled 라벨 제거만으로 다시 대상이 된다(§실패 시 4).
- **즉시 실행(창 밖)**: `window` 블록을 임시로 제거하는 PR → 머지 즉시 Job 생성. 끝나면 되돌리는 PR. Grafana mute 창 밖이므로 알림이 난다.
- **버전 고정**: `channel`을 지우고 `version: v1.36.N+k3s1`을 두면 채널 조회가 멈추고 그 버전만 대상(Plan 이미지 digest 고정의 대안 — kustomization 머리 주석).
  마이너 승격은 `channel`을 `v1.37`로 바꾸는 PR(마이너 건너뛰기 금지).
- **노드 하나 제외 / 일시 정지**: 노드 라벨 `plan.upgrade.cattle.io/<plan>=disabled`(라이브, 운영자 — §비상 정지) — 컨트롤러가 그 노드를 건너뛴다(SUC README). 두 노드 모두 붙이면 Plan 전체 정지.
- **Plan 제거**: 두 Plan 파일을 kustomization `resources`에서 빼는 PR(Application `Prune=confirm`이라 Argo가 자동 삭제하지 않는다 — Plan 삭제는 운영자 confirm). 재추가 PR로
  돌아오면 status가 초기화돼 창을 지킨다.

## ① 네임스페이스 수동 생성 + PSA 라벨 (T041 전)

`platform/policies/`(T041)가 없는 동안 운영자가 만든다. 라벨 값은 계약 네임스페이스 표와 같아야 T041에서 Argo CD가 SSA로 충돌 없이 인수한다.

```bash
kubectl create namespace system-upgrade
kubectl label namespace system-upgrade --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
kubectl get namespace system-upgrade -o jsonpath='{.metadata.labels}'; echo
```

## ② 수동 apply (T041 전에 적용할 때만)

main에 머지된 뒤, main을 최신화한 클론에서. CRD가 established 되기 전에는 Plan apply가 `no matches for kind "Plan"`으로 실패하므로 CRD를 먼저 넣는다.

```bash
REPO=<platform-gitops 로컬 클론 절대 경로>
git -C "$REPO" checkout main && git -C "$REPO" pull --ff-only
kubectl apply --server-side --field-manager=operator-bootstrap -f "$REPO/platform/system-upgrade/crd.yaml"
kubectl wait --for=condition=Established crd/plans.upgrade.cattle.io --timeout=60s
kubectl apply --server-side --field-manager=operator-bootstrap -k "$REPO/platform/system-upgrade"
kubectl -n system-upgrade rollout status deploy/system-upgrade-controller --timeout=120s
# 15분 안에 LATEST가 채널 버전, RESOLVED가 True. (-o wide의 VERSION 열은 .spec.version이라 `version:` 고정 모드에서만 채워지고 채널 Plan에서는 늘 비어 있다 — 해석 버전은 .status.latestVersion)
# LATEST는 v1.36.N-k3s1 표기(SUC가 `+`를 `-`로 바꿔 저장) — `kubectl get nodes`의 v1.36.N+k3s1과 같은 버전이다(불일치 아님, §업그레이드 창 1).
kubectl -n system-upgrade get plans -o custom-columns=NAME:.metadata.name,LATEST:.status.latestVersion,RESOLVED:'.status.conditions[?(@.type=="LatestResolved")].status'
kubectl -n system-upgrade logs deploy/system-upgrade-controller --tail=50   # 'read-only file system' 없음(controller-patch.yaml)
```

## ③ T041 인수 확인

```bash
kubectl -n argocd get app platform-system-upgrade -o jsonpath='{.status.sync.status} {.status.health.status}'; echo   # Synced Healthy
kubectl -n system-upgrade get deploy,plans
```

## 확인 명령 모음(창 다음 날 — 런북 bootstrap.md §6이 정본)

```bash
kubectl get nodes -o wide                                   # 2 Ready · VERSION 같음 · SchedulingDisabled 없음
kubectl -n system-upgrade get plans -o wide                 # COMPLETE True, MESSAGE 비어 있음, APPLYING 비어 있음(남아 있으면 §실패 시 — 창 우회 상태). VERSION 열은 .spec.version이라 늘 비어 있다
kubectl -n system-upgrade get plans -o custom-columns=NAME:.metadata.name,LATEST:.status.latestVersion,RESOLVED:'.status.conditions[?(@.type=="LatestResolved")].status'   # LATEST = 노드 VERSION의 -k3s1 표기(②)
kubectl -n system-upgrade get jobs,pods                     # Failed 0(완료 15분 뒤에는 없어진다)
kubectl -n system-upgrade get events --sort-by=.lastTimestamp | tail -n 20   # JobFailed 없음
```

## 업스트림 대조 · 이미지 (2026-09-07 조회)

| 항목 | 값 | 확인 방법 |
|---|---|---|
| SUC 릴리스 | v0.20.1 (2026-07-22) | `sha256sum crd.yaml` = `68a2e6b7…c656`; `diff <(curl -sL …/system-upgrade-controller.yaml \| sed '1,7d') <(grep -v '^#' controller.yaml)` → 이미지 2줄만 |
| `rancher/system-upgrade-controller:v0.20.1` | `@sha256:aaf4dbf6…153a` | Docker Hub registry v2 manifest list(OCI index) — 본문 sha256 = Docker-Content-Digest; amd64·arm64·arm/v7 |
| `rancher/kubectl:v1.36.2` | `@sha256:06c7a7a9…5fbe` | 같은 방법 — amd64·arm64. 업스트림 기본 v1.30.3은 클러스터 1.36과 kubectl skew 밖이라 교체 |
| `rancher/k3s-upgrade`(Plan) | 태그·digest 없음(채널이 정한다) | validate 4b WARN 4줄이 예상값 · Renovate digest 핀 PR 제외(renovate.json packageRule, VD T116). 참고: `v1.36.4-k3s1` = `@sha256:7c079385…2ef9`(amd64·arm64·arm/v7) |
