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
| `controller-patch.yaml` | Deployment 패치: requests 30Mi/10m · limit 128Mi · `nodeSelector role=platform` · pod securityContext · `readOnlyRootFilesystem`(이미지가 `FROM scratch` 단일 바이너리) |
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

1. **채널 해석**: 컨트롤러가 `https://update.k3s.io/v1-release/channels/v1.36`을 15분마다 조회(302 → `v1.36.N+k3s1`, 이미지 태그는 `v1.36.N-k3s1`). Plan `status.latestVersion`이 바뀌면
   해시가 바뀌고, 라벨 `plan.upgrade.cattle.io/<plan>=<해시>`가 없는 노드가 대상이 된다.
2. **창 판정**: 일요일 03:00–05:00 KST 안에서만 Job을 만든다. 두 Plan의 Job은 **동시에** 생긴다(순서는 아래 prepare가 맡는다). 창 밖에서는 아무 일도 없다(이벤트 `Waiting`);
   창 안에서 시작한 Job은 05:00을 넘겨도 끝까지 간다.
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
| `prepare`(백업) | cordon 전 — 스케줄 가능 그대로 | pod `Init:Error`, `kubectl -n system-upgrade logs <pod> -c prepare`에 `pre-upgrade gate: FAIL`; deadline 뒤 Job Failed, Plan `Complete=False` reason `JobFailed`, 이벤트 `JobFailed` | 백업 원인(age 공개키·instance principal·버킷·Vault 접근) 수정 → §수동 트리거로 재실행 |
| `upgrade`(바이너리 교체·재시작) | **cordon 유지**(`SchedulingDisabled`) | `-c upgrade` 로그, 노드 A `journalctl -u k3s` | 원인 수정 → 재트리거(성공 Job이 uncordon). Plan을 지웠다면 `kubectl uncordon <node>` 직접 |
| 다운그레이드 시도 | cordon 유지 | `Error: Current … is higher than …` | k3s-upgrade는 다운그레이드를 거부한다 — 되돌리기는 런북 `rollback`(T106)·bootstrap §7 번들 복원뿐 |
| agent prepare 대기 초과(서버 실패) | 노드 B는 cordon 전 | 3600초 뒤 Job Failed | 서버 Plan을 먼저 고친다; 서버 Job 성공 뒤 agent Plan 재트리거 |

Job이 Failed로 끝난 Plan은 **갱신될 때까지 새 Job을 만들지 않는다**(SUC `jobActiveDeadlineSecs` 문서·K3s 문서 §Downgrade Prevention의 복구 방법). 갱신 = 아래 §수동 트리거.

## 수동 트리거 · 버전 고정 · 일시 정지

전부 **PR로만**(main = 클러스터 정본). 라이브 `kubectl edit plan`은 Argo selfHeal이 되돌린다. Plan 해시는 spec 전체가 아니라
`latestVersion + serviceAccountName + upgrade.cattle.io/digest 어노테이션이 가리키는 경로 + secrets`이므로(plan-k3s-server.yaml 주석), spec의 다른 필드를 고쳐도 재실행되지 않는다.

- **재트리거(같은 버전)**: 해당 Plan의 어노테이션 `retrigger` 값을 바꾸는 PR(`"0"` → `"1"` …) → 해시가 바뀌어 다음 창에 Job이 생긴다. **VD**: T041 첫 창 뒤 한 번 실측.
  대체(라이브, 운영자만): `kubectl label node <node> plan.upgrade.cattle.io/<plan>-` — 라벨을 지우면 노드가 다시 대상이 된다.
- **즉시 실행(창 밖)**: `window` 블록을 임시로 제거하는 PR → 머지 즉시 Job 생성. 끝나면 되돌리는 PR. Grafana mute 창 밖이므로 알림이 난다.
- **버전 고정**: `channel`을 지우고 `version: v1.36.N+k3s1`을 두면 채널 조회가 멈추고 그 버전만 대상(Plan 이미지 digest 고정의 대안 — kustomization 머리 주석).
  마이너 승격은 `channel`을 `v1.37`로 바꾸는 PR(마이너 건너뛰기 금지).
- **노드 하나 제외**: 노드 라벨 `plan.upgrade.cattle.io/<plan>=disabled`(라이브, 운영자) — 컨트롤러가 그 노드를 건너뛴다(SUC README).
- **일시 정지**: 두 Plan 파일을 kustomization `resources`에서 빼는 PR(Application `Prune=confirm`이라 Argo가 자동 삭제하지 않는다 — Plan 삭제는 운영자 confirm).

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
kubectl -n system-upgrade get plans -o wide      # 15분 안에 VERSION 열이 채널 버전으로 채워진다(LatestResolved)
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
kubectl -n system-upgrade get plans -o wide                 # COMPLETE True, MESSAGE 비어 있음
kubectl -n system-upgrade get jobs,pods                     # Failed 0(완료 15분 뒤에는 없어진다)
kubectl -n system-upgrade get events --sort-by=.lastTimestamp | tail -n 20   # JobFailed 없음
```

## 업스트림 대조 · 이미지 (2026-09-07 조회)

| 항목 | 값 | 확인 방법 |
|---|---|---|
| SUC 릴리스 | v0.20.1 (2026-07-22) | `sha256sum crd.yaml` = `68a2e6b7…c656`; `diff <(curl -sL …/system-upgrade-controller.yaml \| sed '1,7d') <(grep -v '^#' controller.yaml)` → 이미지 2줄만 |
| `rancher/system-upgrade-controller:v0.20.1` | `@sha256:aaf4dbf6…153a` | Docker Hub registry v2 manifest list(OCI index) — 본문 sha256 = Docker-Content-Digest; amd64·arm64·arm/v7 |
| `rancher/kubectl:v1.36.2` | `@sha256:06c7a7a9…5fbe` | 같은 방법 — amd64·arm64. 업스트림 기본 v1.30.3은 클러스터 1.36과 kubectl skew 밖이라 교체 |
| `rancher/k3s-upgrade`(Plan) | 태그·digest 없음(채널이 정한다) | validate 4b WARN 4줄이 예상값. 참고: `v1.36.4-k3s1` = `@sha256:7c079385…2ef9`(amd64·arm64·arm/v7) |
