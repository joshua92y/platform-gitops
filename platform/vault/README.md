# platform/vault/ — 운영자 절차 (T044 G1)

HashiCorp Vault 2.0.4(차트 0.34.1)의 **서버 배포만** 소유한다 — Raft 스토리지 1 replica · OCI KMS auto-unseal ·
리스너 평문 8200(TLS 종단은 Traefik websecure + Cloudflare AOP). 설치 방식은 `platform/cert-manager/`와 같은
kustomize `helmCharts` 인플레이트다(§1). 이 디렉터리는 **G1 PR 시점의 모양**이며 Ingress는 G2에서 붙는다(§0).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(HTTPS helm repo 인플레이트) + `valuesInline` 전량 + raft/seal HCL. seal 3값은 `<OPERATOR-FILL: …>` 자리표시자이고 운영자가 머지 전에 채운다(§3). 이 디렉터리가 만들지 않는 것의 경계는 머리 주석에 있다 |
| `serviceaccount-vault-backup.yaml` | SA `vault-backup`(K8s RBAC 0). 노드 A `platform-backup.sh`가 Raft 스냅샷을 뜰 때 Vault Kubernetes auth에 내미는 신원 |
| `ingress.yaml` | **아직 없다.** `vault.joshuatech.dev` → Service `vault` 포트 **이름** `http`. init 완료 뒤 G2 PR에서 이 파일과 `resources:` 한 줄, 이 README의 해당 절을 함께 추가한다 |

> **머지 순서: G0 → G1 → G2**(설계 D7). G0(AppProject `platform`의 `sourceRepos`에서 hashicorp helm repo 줄 삭제)이 먼저
> 머지되고 20 Application이 Synced/Healthy를 유지하는 것을 확인한 뒤에 이 PR(G1)을 연다. 순서를 강제하는 기계 장치는 없으므로
> cert-manager T042와 같이 draft PR + 본문 체크박스로 지킨다.
> **G1 머지 = 즉시 자동 sync = `vault-0` 기동 = SUC prepare 게이트 시작(§4)이다.** `vault operator init`을 곧바로 칠 수 있는
> 운영자 세션에서만 머지한다 — 초기화되지 않은 Vault가 떠 있는 시간을 최소로 한다.

- **이 저장소에 비밀은 없다.** seal 스탠자의 세 값은 자격증명이 아니라 식별자다(§0의 근거). 그 밖의 비밀(recovery key · root 토큰 ·
  kv 값)은 어느 파일에도 들어가지 않는다.
- 이 디렉터리에는 **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — 이유는 §0 마지막 불릿.
- 로컬 재현(리뷰어용, helm 필요):
  ```bash
  kustomize build --enable-helm platform/vault | kubeconform -strict -ignore-missing-schemas -summary
  # G1: 문서 10개 = 적용 대상 9개 + helm test hook Pod 1개(Argo CD가 무시한다 — kind/name 목록과 근거는 §6) · G2 뒤 Ingress 1개 추가
  ```
  렌더하면 `platform/vault/charts/`(차트 사본)가 생긴다. `.gitignore`의 `charts/`(T042 PR-0)가 잡으므로 `git add`에 끌려오지 않는다.

---

## 0. 소유 / 비소유 + 절대 규칙

**UI로 `vault operator init`을 하지 않는다 — 운영자 워크스테이션 `vault` CLI만(정본: 모노레포 `docs/runbooks/vault-unseal.md`).**
브라우저 초기화 화면은 recovery key와 root 토큰을 화면과 다운로드 파일로 남긴다. 실행 기록은 모노레포
`docs/runbooks/bootstrap.md` §4 T044 절에 남긴다.

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 결과, G1 기준 9장 — `helmCharts[].skipTests: true`로 helm test hook Pod를 렌더에서 제외한다. 대조 명령은 §6):

| 객체 | 출처 | 역할 |
|---|---|---|
| ServiceAccount `vault` | 차트 | 서버 파드 신원. auth/kubernetes의 TokenReview 호출자 |
| ClusterRoleBinding → `system:auth-delegator` | 차트 `server.authDelegator` | SA `vault`에 TokenReview·SubjectAccessReview 권한(폭발 반경은 §7) |
| Role / RoleBinding(pods get·watch·list·update·patch) | 차트 `serviceAccount.serviceDiscovery` | `service_registration "kubernetes"`가 파드 라벨 `vault-active`·`vault-sealed`를 갱신 |
| ConfigMap `vault-config` | 차트 | HCL 본문(§3). `includeConfigAnnotation`으로 체크섬이 파드 어노테이션에 붙는다 |
| Service `vault` | 차트 | 8200 · 포트 이름 `http`. `publishNotReadyAddresses: true`라 봉인·미초기화 중에도 엔드포인트가 남는다 |
| Service `vault-internal` | 차트 | headless. Raft·StatefulSet 내부용 |
| StatefulSet `vault` | 차트 | 1 replica · OnDelete · PVC 템플릿 `data` → PVC `data-vault-0` |
| ServiceAccount `vault-backup` | `serviceaccount-vault-backup.yaml` | 백업 스크립트의 Vault 로그인 신원. K8s RBAC 없음 |
| Ingress `vault` | `ingress.yaml` | **G2 이후** |
| (Pod `vault-server-test`) | 차트 `templates/tests/server-test.yaml` | **렌더도 적용도 되지 않는다.** helm test hook(`helm.sh/hook: test`)이며 끄는 value가 없어 kustomize `helmCharts[].skipTests: true`로 렌더에서 제외한다. Argo CD도 test hook을 적용하지 않지만, securityContext 없는 Pod를 정본 렌더에 남기지 않는다(§6) |

**이 디렉터리가 만들지 않는 것**:

- Namespace `vault` · PSA 라벨(restricted) · NetworkPolicy → `platform/policies/`. 정책 객체는 거기에만 있어야 한다(validate 5.0·5.1).
  차트의 `server.networkPolicy`가 `false`인 이유다.
- Application `platform-vault` → `clusters/oci-k3s/apps/platform-vault.yaml`(T041부터 라이브). 이 PR은 건드리지 않는다 —
  검사 7.1이 `source.path = platform/vault`를 대조한다.
- ClusterSecretStore · ExternalSecret → `secrets/`(T045).
- Vault **내부** 설정(kv v2 마운트 · auth/kubernetes · 정책 6 · role 6) → 모노레포 `infra/vault/` OpenTofu.
- 감사 장치(`sys/audit`) → 런북의 CLI 1회 `vault audit enable file file_path=stdout`(설계 D5). gitops도 tofu도 소유하지 않는다 —
  `sys/audit`는 list·enable·disable이 전부 sudo라 tofu가 소유하면 매 plan의 refresh가 sudo를 요구한다.
- kv **값** → 운영자 `vault kv put`. 상태 파일에도 저장소에도 들어가지 않는다.

**KMS 식별자를 public 저장소에 적는 근거**(설계 D7, 사용자 확정 2026-09-14). seal 스탠자의 key OCID · crypto 엔드포인트 ·
management 엔드포인트는 **자격증명이 아니라 식별자**다.

- OCI 호출은 노드 A의 **인스턴스 프린시펄 x509 서명**으로만 인가된다. 세 값을 아는 것만으로는 어떤 API도 부를 수 없다.
- 권한은 `target.key.id` 조건이 붙은 IAM 정책이 정한다(모노레포 `infra/oci/iam.tf` — 동적 그룹 `joshuatech-node-a`의
  matching_rule은 노드 A 인스턴스 하나뿐이고, 정책은 그 키 하나의 `use`뿐이다).
- env로 빼는 우회는 구조적으로 불가능하다. Vault는 HCL seal 스탠자가 있으면 `WithDisallowEnvVars(true)`로 `VAULT_OCIKMS_*`를 무시한다.
  HCL 전체를 Secret 볼륨으로 옮기는 대안은 GitOps 추적성·selfHeal·Argo 헬스를 모두 잃으므로 채택하지 않았다.
- 이 저장소에 OCID가 들어가는 **최초 사례**다. 허용되는 것은 `kustomization.yaml` 안의 key OCID(`ocid1`-`key` 접두) 1건뿐이고
  테넌시·컴파트먼트·사용자 OCID는 **0건**이어야 한다. PR마다 게이트 둘: `gitleaks dir . --no-banner --redact --exit-code 1` → exit 0,
  `grep -rn 'ocid1\.' .` → 히트가 `platform/vault/kustomization.yaml` 1건뿐(자리표시자 상태의 G1 파일에서는 0건).

- **전역 `namespace:` 변환기가 없다** — 차트 객체는 `helmCharts[].namespace: vault`로 렌더되고, 수기 매니페스트는 각자
  `metadata.namespace: vault`를 적는다. 변환기를 두면 `system:auth-delegator` ClusterRoleBinding의 subject ns까지 다시 쓰는
  두 번째 메커니즘이 생길 뿐이다. `platform/cloudflared`·`platform/system-upgrade`는 변환기를 쓰므로 거기서 복사할 때 주의한다.

---

## 1. 왜 kustomize `helmCharts` 인플레이트인가

cert-manager(T042 D1 = A)와 같은 이유이고, 같은 대가를 알고 골랐다.

1. **검사 7.1이 `source.path`를 강제한다.** `tests/validate.sh` 7.1은 `platform-vault` Application의 `.spec.source.path`가
   `platform/vault`와 정확히 같은지 본다. Argo 네이티브 helm source(`source.chart`)에는 `path`가 없어 즉시 FAIL이고,
   통과시키려면 계약 §sync-wave 표와 validate.sh를 함께 고쳐야 한다(T033·T041 산출물 개정).
2. **Application source가 gitops 저장소 하나뿐이다.** 차트는 repo-server의 kustomize가 `helmCharts[].repo`에서 직접 당긴다.
   AppProject `platform`의 `sourceRepos`는 Application `source.repoURL`만 검사하므로 거기 있던
   `https://helm.releases.hashicorp.com` 줄은 아무것도 통제하지 않았다 — **G0 PR에서 지웠다**(T042 PR-5의 jetstack 선례, D7 규칙의
   두 번째 실행). 그 공백을 메우는 자리는 validate.sh의 `helmCharts[].repo` 허용 목록 정적 검사이고 T047 몫이다.
3. **HTTPS helm repo라 `oci://` 접두가 없다.** cert-manager는 OCI 레지스트리(`oci://quay.io/jetstack/charts`)라 접두가 필수였고,
   hashicorp는 전통 HTTPS 인덱스라 붙이면 안 된다 — 두 디렉터리의 `repo:` 표기 규칙이 **서로 반대**다. 복사할 때 가장 먼저 틀리는 곳.
4. **helm 릴리스가 아니다.** 인플레이트는 kustomize가 렌더 시각에 템플릿을 펼치는 것이라 `helm list -n vault`가 비어 있는 것이
   정상이고, `helm rollback`·`helm uninstall`은 쓸 수 없다. 되돌리기는 §5의 git 경로뿐이다.
5. 전제: `bootstrap/argocd/argocd-cm.yaml`의 `kustomize.buildOptions: "--enable-helm"`(T042 PR-0, 라이브). 없으면
   `platform-vault`가 `ComparisonError`로 굳는다 — 리소스 손실은 없지만(`prune: false`) argo-1과 root 헬스 신호를 잃는다.
6. 부수 효과로 **검사 5.4b가 살아 있다.** 5.4b는 `helmCharts[].valuesInline`의 `.server.service.port`·`.server.service.targetPort`를
   계약 §포트 각주 8200과 대조하는데, **키가 없으면 조용히 건너뛴다**. 두 키를 값 그대로 명시한 이유다.

로컬 재현은 `kustomize build --enable-helm platform/vault`(helm 필요). ⚠ 검사 1(KUST)은 helm이 없으면 이 디렉터리에서
fail-closed다 — cert-manager와 같은 기존 상태이며 T047(CI runner에 helm 설치)이 푼다.

---

## 2. 차트 bump 절차

`kustomization.yaml`에서 함께 움직여야 하는 곳은 **세 군데**다.

| 위치 | 값(2026-09-14 실측) | 누가 갱신하나 |
|---|---|---|
| `helmCharts[0].version` | `0.34.1`(appVersion 2.0.4) | Renovate가 올릴 수 있다 |
| `version:` 줄 주석의 차트 아티팩트 sha256 | `df4c37fa…64c4`(index.yaml의 tgz digest) | **사람이** — 값 고정이 아니라 **대조용 기록** |
| `server.image.tag`의 `@sha256:` | `5be49781…e1a2`(멀티아치 **인덱스** digest) | **사람이** — 계약 §이미지의 digest 병기 |

**⚠ 이 차트의 `values.schema.json`에는 `additionalProperties: false`가 0곳이다**(cert-manager는 28곳이라 로컬 렌더가 즉시 실패했다).
키 오타는 조용히 무시되고 렌더는 성공한다 — 예컨대 `injector.enabld: false`라고 쓰면 injector가 **배포된다.** 유일한 방어는
렌더 결과 대조(§6의 kind/name 9장 + `image:`·`Delete=false`·`namespaceSelector` grep)이고, bump PR 본문에 그 출력을 붙인다.

**자동 검사가 없다.** validate 4b는 저장소 파일의 `image:` 스칼라 줄만 보는데 여기서는 `repository`/`tag` 블록 표기라 매칭조차
하지 않는다. 차트 `version`만 올라가면 새 템플릿이 옛 바이너리를 당기는 상태가 조용히 성립한다.

**절차**: 차트 버전을 올리는 PR에서

1. `helmCharts[0].version`을 새 버전으로.
2. `https://helm.releases.hashicorp.com/index.yaml`의 `entries.vault[]`에서 그 버전 항목의 `digest`(tgz sha256)를 `version:` 줄 주석에.
3. 새 appVersion의 **인덱스 digest**를 `server.image.tag`에 `<tag>@sha256:<digest>` 형태로. 아키텍처별 digest가 아니라
   매니페스트 리스트 digest여야 한다(노드 2대가 arm64 Ampere A1). 얻는 법: `docker buildx imagetools inspect hashicorp/vault:<tag>`의
   첫 `Digest:` 줄, 또는 registry API(`GET /v2/hashicorp/vault/manifests/<tag>`에 Accept `application/vnd.oci.image.index.v1+json` ·
   `application/vnd.docker.distribution.manifest.list.v2+json`, 응답 헤더 `Docker-Content-Digest`).
4. 로컬 렌더로 `image: hashicorp/vault:<tag>@sha256:<digest>` 줄(STS + test Pod, 2줄)과 문서 수(§6의 기대값)를 확인해 PR 본문에.
5. **머지 뒤 라이브 반영을 확인한다 — `charts/` 캐시 함정.** kustomize는 `charts/vault`가 이미 있으면 **버전을 보지 않고** pull을
   건너뛰고, Argo repo-server는 최초 init 1회만 작업 트리를 청소한다(cert-manager README §3, 2026-09-10 사후 감사). 그래서 살아 있는
   repo-server는 옛 차트를 계속 쓴다. hard refresh로는 풀리지 않는다(git 리비전만 다시 읽는다). §6의 `get sts … image`가 옛 값이면
   repo-server를 재시작하거나 그 `charts/`를 지운다. 같은 캐시가 태그 재푸시 공격도 같은 만큼 늦춘다.

`server.image.tag`의 digest 병기가 containerd에서 거부되면(ImagePullBackOff · InvalidImageName) `"2.0.4"`로 되돌리고 digest는
주석 기록으로만 남긴다(설계 D6 폴백 — 수용 여부는 첫 배포 VD-12에서 실측).

---

## 3. values 선택 근거 (전문은 `kustomization.yaml` 주석)

| 키 | 값 | 이유 |
|---|---|---|
| `global.tlsDisable` | `true` | 리스너 평문 8200. TLS 종단은 Traefik websecure + Cloudflare AOP. cluster.tests·reboot.tests·platform-backup.sh가 http로 하드코딩돼 있어 선택이 아니라 통과 조건. Service 포트 이름이 이 값으로 `http`가 된다 |
| `injector.enabled` | `false` | 기본값 `"-"`는 `global.enabled` 상속 = true. 명시하지 않으면 injector Deployment·Service·RBAC·certs Secret과 **클러스터 범위 MutatingWebhookConfiguration**(failurePolicy Ignore — 조용히 성공해 더 위험)이 함께 온다. 주입은 ESO만(ADR 0010) |
| `csi.enabled` | `false` | 기본값과 같지만 계약 의도를 코드에 남긴다 |
| `ui.enabled` | `false` | 이 키는 Service `vault-ui`를 하나 더 만들 뿐이다. UI는 HCL `ui = true`로 8200 `/ui`에서 서빙되고 Ingress(G2)는 Service `vault`를 쓴다(research VAULT-D2 편차 — converge 인계) |
| `server.image.tag` | `2.0.4@sha256:…` | 차트에 digest 키가 없고 STS가 `{repo}:{tag}` 한 줄만 렌더하므로 태그에 이어 붙이는 것이 유일한 병기 방법(§2). `repo:tag@digest`는 유효한 OCI 참조 |
| `updateStrategyType` · `includeConfigAnnotation` | `OnDelete` · `true` | HCL(ConfigMap) 변경이 파드를 자동 재시작하지 않아야 "KMS 장애 중 pod 재시작 금지"와 맞는다. 대가인 조용한 드리프트는 config 체크섬 어노테이션으로 눈에 보인다. **설정 변경 = PR 머지 + 운영자 `kubectl -n vault delete pod vault-0` 두 단계**(런북 §10) |
| `server.networkPolicy.enabled` | `false` | 켜면 `namespaceSelector: {}`(전 ns)로 8200·8201 ingress가 렌더돼 계약과 cluster.tests np-4를 동시에 깬다. validate 5.0은 원본 파일만 보므로 helm 렌더 결과의 이 위반은 라이브 np-4만 잡는다 |
| `server.nodeSelector` | `role: platform` | **가용성 조건**이지 편의가 아니다. KMS 정책의 동적 그룹은 노드 A 인스턴스 하나뿐이라, 노드 B에 뜨면 인스턴스 프린시펄 federation은 돼도 어떤 KMS 정책에도 속하지 않아 Encrypt가 NotAuthorizedOrNotFound → seal 설정 실패 = 프로세스 즉사 |
| `server.service.port` · `targetPort` | `8200` · `8200` | 명시해야 validate 5.4b가 **실제로 대조한다**(§1). 계약 §포트 표·정책 매트릭스와 3중 일치 — 변경 금지 |
| `server.service.publishNotReadyAddresses` | `true` | 봉인·미초기화(NotReady)에서도 엔드포인트가 남아야 port-forward와 UI 도달이 된다. 기본값이지만 명시 |
| `server.service.active` · `standby` `.enabled` | `false` | replicas=1에 무의미. `vault-active`의 selector `vault-active: "true"`는 unseal 뒤에야 붙어 봉인 중 엔드포인트 0(Ingress 백엔드로 쓰면 바로 그때 503). 객체 2장 감소 |
| `server.ingress.enabled` | `false` | Ingress는 순수 매니페스트(G2, `bootstrap/argocd/ingress.yaml` 선례, 백엔드 포트 **이름** `http`). 차트 Ingress는 ha 모드에서 `vault-active`를 백엔드로 잡고 포트를 번호로 렌더한다(설계 D1) |
| `server.authDelegator.enabled` | `true` | ClusterRoleBinding → `system:auth-delegator`. auth/kubernetes의 TokenReview에 필수 — Vault가 자기 파드 SA 토큰을 리뷰어로 쓰므로 `token_reviewer_jwt`가 tofu 상태에 들어가지 않는다 |
| `server.serviceAccount.serviceDiscovery.enabled` | `true` | Role/RoleBinding(pods get·watch·list·update·patch). `service_registration "kubernetes"`가 요구 |
| `server.statefulSet.securityContext.pod` · `.container` | 4항목 명시 | ns `vault`는 PSA **restricted**라 계약 §워크로드 강화의 4항목이 admission 통과 조건이다. 차트 헬퍼는 값이 주어지면 기본값을 **병합이 아니라 대체**하므로 pod 쪽 기본(runAsUser 100 · runAsGroup 1000 · fsGroup 1000)을 다시 적는다 — 빠뜨리면 SKIP_CHOWN과 겹쳐 `/vault/data` 쓰기 실패. `readOnlyRootFilesystem`은 넣지 않는다(args가 `/tmp/storageconfig.hcl`에 쓴다). `IPC_LOCK` 불필요(`disable_mlock = true` + 이미지 SKIP_SETCAP) |
| `server.resources` | requests 100m·256Mi / limits memory 512Mi | 차트 기본 `{}`라 명시하지 않으면 plan A14 예산 대조가 성립하지 않는다. A14 노드 A "Vault·ESO 0.5 GiB"의 Vault 몫. CPU limit 없음(저장소 관례, validate 5.5와 같은 취지). T097 실측으로 교정 |
| `server.dataStorage` | 5Gi · `local-path` · 어노테이션 | 기본 SC에 기대지 않는다(WaitForFirstConsumer → nodeSelector와 함께 PV도 노드 A). 어노테이션 `argocd.argoproj.io/sync-options: Delete=false,Prune=false`는 volumeClaimTemplates → STS 컨트롤러 DeepCopy → PVC `data-vault-0`으로 전파돼 cluster.tests argo-4(ns vault의 모든 PVC)를 만족한다. ⚠ volumeClaimTemplates는 STS 생성 뒤 **불변** — 첫 apply에 있어야 하고, 이 어노테이션은 Argo 관리 밖 PVC의 **표식일 뿐 보호가 아니다**(§5) |
| `server.auditStorage.enabled` | `false` | 감사는 stdout(§4). 켜면 어노테이션 없는 PVC `audit-vault-0`이 생겨 argo-4가 FAIL |
| `server.ha.disruptionBudget.enabled` | `false` | replicas=1이면 차트가 `maxUnavailable: 0`으로 고정(override 불가) → 앞으로 노드 A `kubectl drain`이 영구 대기. SUC Plan은 cordon만 쓰므로 업그레이드는 무해하지만 지뢰를 남기지 않는다 |
| `server.ha.config` | 차트 기본(건드리지 않음) | ConfigMap과 `/vault/config` 마운트의 렌더 조건이 `standalone.config or ha.config`다. 빈 문자열로 바꾸면 ConfigMap이 사라지고 볼륨만 남아 ContainerCreating(`configmap "vault-config" not found`)에 갇힌다. raft가 켜지면 실제 HCL은 `ha.raft.config`다 |
| `persistentVolumeClaimRetentionPolicy` | 적지 않음 | 차트가 `semverCompare ">= 1.23-0"` 뒤에 두는데 helm 기본 KubeVersion이 v1.20이라 `helmCharts[].kubeVersion` 없이는 조용히 사라진다. K8s 기본이 이미 Retain/Retain이라 동작은 같고 거짓 안전감만 없앤다(설계 D2) |

**raft HCL(`server.ha.raft.config`)** — 차트 헬퍼가 `tpl`로 한 번 렌더하므로 `{{ }}`를 쓰지 않는다.

- `service_registration "kubernetes" {}`를 **직접 다시 넣는다.** 이 문자열은 차트의 기본 raft config를 통째로 대체하므로,
  빠지면 파드 라벨 `vault-active`·`vault-sealed`가 영영 붙지 않는데 증상이 조용하다.
- `disable_mlock = true`를 명시한다. 헬퍼가 없으면 자동으로 붙이지만 task 문면대로 적고, Vault 2.x는 integrated storage에서 명시가
  필수다. 전제는 노드 A 스왑 0(VD-06 실측).
- `api_addr` · `cluster_addr`는 적지 않는다 — 차트가 env `VAULT_API_ADDR` · `VAULT_CLUSTER_ADDR`로 주입한다.
- **`x_forwarded_for_*`는 의도적으로 넣지 않는다**(research VAULT-D3 편차, 설계 D9). `x_forwarded_for_authorized_addrs`가 비어 있지
  않으면 Vault가 XFF 래퍼를 설치하고, 그 래퍼는 remote 주소를 보기 **전에** 헤더 부재를 검사해 `reject_not_present`이면 400을 돌려준다.
  헤더 없는 경로가 readinessProbe(127.0.0.1) · port-forward seal-status · platform-backup.sh · ESO · metrics 스크레이프 **전부**라
  한 줄로 모든 내부 경로가 동시에 깨진다. 실제 클라이언트 IP는 Cloudflare Access 로그와 Traefik 액세스 로그(`CF-Connecting-IP`)에 남는다.
- **seal 3값**(`key_id` · `crypto_endpoint` · `management_endpoint`)은 운영자가 `tofu -chdir=infra/oci output -raw kms_key_id` ·
  `kms_crypto_endpoint` · `kms_management_endpoint`로 읽어 `<OPERATOR-FILL: …>` 자리에 채운다 — 에이전트는 읽을 수 없다.
  머지 전 게이트: `Select-String -Path platform/vault/kustomization.yaml -Pattern 'OPERATOR-FILL'` → 0행.
  ⚠ 값이 틀리면 sealed 대기가 **아니라 프로세스 즉사(CrashLoopBackOff)** 다 — Vault는 seal 설정 실패 시 시작 자체를 중단하고
  seal-status는 연결 거부가 된다. 반대로 이미 unseal된 파드는 KMS 장애 중에도 계속 서비스한다 — "KMS 장애 중 pod 재시작 금지"의 진짜 근거.
- `auth_type_api_key = "false"` = 인스턴스 프린시펄. `true`면 `~/.oci/config`를 찾다 실패한다.
- `telemetry { prometheus_retention_time = "1m"  disable_hostname = true }` + 리스너 `unauthenticated_metrics_access = true`.
  `disable_hostname`이 없으면 게이지에 호스트명 접두가 붙어 알림 `VaultSealed`(`vault_core_unsealed == 0`)가 성립하지 않는다.
  보존 1m이라 스크레이프 주기는 30s 이하여야 한다(T098).

---

## 4. init · seal · 감사 · 백업 — 절차는 모노레포 런북

이 README는 절차를 반복하지 않는다.

- **정본**: 모노레포 `docs/runbooks/vault-unseal.md` — init(워크스테이션 CLI · admin kubeconfig port-forward · 3단 전사) ·
  KMS 장애 시 대기 규율 · break-glass(2.0에서는 recovery key만으로 성립하지 않는다 — 유효한 토큰이 함께 필요) ·
  Raft 스냅샷 복원(**같은 KMS 키** 필수) · 감사 장치 CLI 1회 · 되돌리기.
- **실행 기록**: 모노레포 `docs/runbooks/bootstrap.md` §4 T044.

**시간 제약 하나는 여기서도 적는다.** helm이 Service `vault`를 만드는 순간부터 노드 A의 `platform-backup.sh --pre-upgrade`
(SUC k3s-server Plan의 prepare)는 vault 스냅샷 성공을 **필수**로 승격한다(`kubectl -n vault get svc vault`로 탐지). 스냅샷은
SA `vault-backup` 토큰으로 Vault role `vault-backup`에 로그인해야 뜨는데, 그 role은 모노레포 `infra/vault` apply가 만든다.
즉 G1 머지 ~ `infra/vault` apply 사이에는 prepare가 실패하고, 그 실패는 일요일 03:00–05:00 KST 창 밖에서도 재트리거된다.
**배포(G1 머지) · init · 감사 장치 · `infra/vault` apply · 백업 1회 성공은 같은 운영자 세션에서 끝낸다.**

---

## 5. 되돌리기 — 순서가 곧 안전장치

Application `platform-vault`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.**
> git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다. 반대로 revert만 하면
> `prune: false` 때문에 객체는 남아 있다(그게 정상 동작이다).

1. revert PR 머지 → `kustomization.yaml`이 `resources: []` 뼈대로 복귀 → 렌더 0 → hard refresh. 객체는 그대로 남는다.
2. 운영자가 수동 삭제, **이 순서로**(admin kubeconfig):
   ```powershell
   # ① 공개 진입점 먼저 — G2 이후에만 존재한다
   kubectl -n vault delete ingress vault
   # ② StatefulSet만 지우고 파드는 남긴다
   kubectl -n vault delete sts vault --cascade=orphan
   # ③ 남은 파드
   kubectl -n vault delete pod vault-0
   # ④ Service · ConfigMap · SA · RBAC — 이름은 §6의 렌더 대조 목록(또는 get 출력)에서 가져온다
   kubectl -n vault delete svc vault vault-internal
   kubectl -n vault delete cm vault-config
   kubectl -n vault delete sa vault vault-backup
   kubectl -n vault get role,rolebinding                      # discovery Role/RoleBinding 이름 확인 뒤 delete
   kubectl get clusterrolebinding | Select-String vault       # auth-delegator ClusterRoleBinding 이름 확인 뒤 delete
   ```
3. **⑤ PVC `data-vault-0`과 그 PV는 지우지 않는다.** `local-path`의 reclaimPolicy는 Delete라 PVC 삭제 = 노드 A 디스크의 Raft
   데이터 소멸이다. 복구 수단은 Raft 스냅샷 + **같은 KMS 키**뿐이다(스냅샷은 seal로 래핑돼 있어 다른 키로는 열리지 않는다).
   `Delete=false,Prune=false` 어노테이션은 Argo에게 주는 표식일 뿐 `kubectl delete`를 막지 않는다(런북 §11).

G0(AppProject의 hashicorp 줄)은 별개 PR로 되돌린다 — 이 되돌리기와 무관하다. 렌더 실패는 안전하다(`ComparisonError`,
클러스터 변경 0 — 단 argo-1과 root 헬스 신호는 잃는다).

---

## 6. 배포 뒤 확인

agent-view kubeconfig(읽기 전용 + ns `vault`의 `pods/portforward`)로 가능한 명령만 적는다.

```powershell
kubectl -n argocd get app platform-vault -o jsonpath='{.status.sync.status} {.status.health.status}'
#   init 전에는 `Synced Progressing`이 정상(readinessProbe `vault status`가 exit 2 → NotReady). init·unseal 뒤 Healthy.
#   이 창 동안 cluster.tests argo-1이 FAIL하고 root app-of-apps도 Healthy를 잃는다 — 이 창에서는 clusters/oci-k3s/apps/ PR을 머지하지 않는다.
kubectl -n vault get sts,svc,cm,sa,pvc,pod -o wide
#   sts vault · svc vault + vault-internal(vault-ui · vault-active · vault-standby 없음) · cm vault-config · sa vault + vault-backup
#   · pvc data-vault-0 Bound · pod vault-0 NODE = 노드 A(role=platform)
kubectl -n vault get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}'
#   hashicorp/vault:2.0.4@sha256:5be49781…e1a2 — digest 병기(§2)
kubectl -n vault get pvc data-vault-0 -o jsonpath='{.metadata.annotations}'
#   argocd.argoproj.io/sync-options: Delete=false,Prune=false 포함
kubectl get mutatingwebhookconfigurations | Select-String vault     # 0행 — injector 없음
kubectl -n vault get pdb,networkpolicy
#   PDB 0 · NetworkPolicy는 platform/policies 소유분만(2026-09-14 기준 9장 — default-deny · allow-dns · allow-kube-api ·
#   allow-apiserver-webhook · allow-imds · allow-egress-external-443 · allow-from-traefik · allow-from-external-secrets ·
#   allow-scrape-from-monitoring). 차트가 만든 정책이 하나라도 보이면 `server.networkPolicy.enabled`를 확인한다
kubectl -n vault logs vault-0 --tail=200 | Select-String 'Seal Type|ocikms|error'
#   `Seal Type: ocikms` 1회 · error 0행. CrashLoopBackOff면 seal 3값 → nodeSelector(노드 A인가) → IMDS 80/KMS 443 egress 순으로 본다(런북)
```

seal 상태(agent-view에 `pods/portforward` create가 있다 — 별도 창):

```powershell
kubectl -n vault port-forward svc/vault 18200:8200
curl.exe -s http://127.0.0.1:18200/v1/sys/seal-status
#   init 전: "initialized":false · "sealed":true · "type":"ocikms" — 인증 불요. init·unseal 뒤: "sealed":false
#   400이면 XFF 스탠자가 들어간 것이다(§3) — 즉시 되돌린다
```

렌더 대조(helm 필요 — 리뷰어 로컬 또는 T047 이후 CI):

```bash
kustomize build --enable-helm platform/vault | yq -N '.kind + " " + .metadata.name'
# G1 실측(2026-09-14, helm v4.3.0 · kustomize v5.8.1, `skipTests: true`) = 문서 **9장**:
#   ServiceAccount vault · ServiceAccount vault-backup · Role vault-discovery-role · RoleBinding vault-discovery-rolebinding ·
#   ClusterRoleBinding vault-server-binding · ConfigMap vault-config · Service vault · Service vault-internal · StatefulSet vault
#   ⚠ `skipTests` 없이는 Pod vault-server-test(`helm.sh/hook: test`)가 10번째로 렌더된다 — 차트 `templates/tests/server-test.yaml`은
#   mode≠external이면 무조건 렌더하고 끄는 value가 없다(values.yaml에 `tests:` 키 없음). Argo CD는 test hook을 적용하지 않지만
#   그 Pod는 securityContext가 없어 PSA restricted에 걸리는 객체라 정본 렌더에서 제외한다. G2 뒤에는 Ingress vault가 더해져 10장.
kustomize build --enable-helm platform/vault | grep -E 'image:|Delete=false|namespaceSelector'
# image: 1줄(StatefulSet, digest 병기) · Delete=false 1줄(volumeClaimTemplates) · namespaceSelector 0줄(차트 NetworkPolicy 없음)
```

---

## 7. 수용된 위험

- **고아 경고 1건은 정상이다.** PVC `data-vault-0`은 StatefulSet 컨트롤러가 만들지 Argo 트리에 없다. AppProject `platform`이
  `orphanedResources.warn: true`라 Argo UI에 경고로 뜬다 — 드리프트가 아니고 **지우지 않는다**(§5 ⑤).
- **`system:auth-delegator` ClusterRoleBinding의 폭발 반경.** SA `vault`가 클러스터 전체 범위의 TokenReview·SubjectAccessReview를
  부를 수 있다 = 어떤 ns의 SA 토큰이든 검증할 수 있는 권한이다. auth/kubernetes에 필수라 끄는 value가 없고, 차트도 대안을 주지 않는다.
  Vault 파드가 뚫리면 이 권한으로 토큰 유효성을 조회할 수 있다(발급은 불가). 수용한다.
- **단일 stdout 감사 = fail-closed.** Vault는 모든 감사 장치에 쓰기가 실패하면 **전 요청을 거부**한다. 장치가 stdout 하나라
  노드 A 디스크 포화(컨테이너 로그 로테이션 실패)가 곧 Vault 전면 정지다. 두 번째 장치를 임시 FS에 두는 '보험'은 감사 유실 경로라
  넣지 않고, `NodeDiskLow`(FR-040)를 조기 경보로 쓴다(런북 §9).
- **Raft 1 replica = 노드 A 단일 장애 도메인.** 노드 A가 죽으면 Vault도 죽고, 노드 B로 옮길 수도 없다(KMS 동적 그룹이 노드 A뿐 —
  §3 nodeSelector). 복구는 노드 A 복귀 또는 Raft 스냅샷 + 같은 KMS 키. SP-1 범위의 수용 위험이다.

---

## 8. 인계(T045)

- ESO ClusterSecretStore 4개(`vault-platform` · `vault-dev` · `vault-prod` · `vault-data`)는
  `auth.kubernetes.serviceAccountRef.audiences: [vault]`가 **필수**다(ESO 1.21+ / Vault 2.x는 audience 없으면 인증 실패).
- role 이름 = SA 이름(`eso-platform` · `eso-dev` · `eso-prod` · `eso-data`). Vault role은 SA 존재를 검사하지 않으므로 ns
  `external-secrets`의 동명 SA는 **T045가 만든다**. ESO 컨트롤러 RBAC에 그 SA들의 `serviceaccounts/token` create가 필요하다.
- 다섯 번째 store `k8s-data-ca`는 Vault role이 없다(SA `eso-ca-reader`의 K8s RBAC).
- 초기 kv 시드는 **root 토큰**으로 한다(T044에서 오프라인 보관, revoke하지 않음). root revoke는 break-glass 대체 경로가
  결정·실증된 뒤에만(설계 D4 — converge 인계).
- eso-* 정책은 metadata `read`만이다 — `dataFrom.find` ExternalSecret이 생기면 계약을 먼저 고친 뒤 list를 더한다.
