# platform/external-secrets/ — 운영자 절차 (T045 G1)

External Secrets Operator 2.10.0(차트 2.10.0 · appVersion v2.10.0)의 **오퍼레이터 본체만** 소유한다 —
CRD 25장 + Deployment 3개(controller · webhook · cert-controller) + 그에 딸린 RBAC · Service · webhook 설정,
그리고 ClusterSecretStore가 인증 주체로 쓸 `eso-*` ServiceAccount 5개와 `eso-ca-reader` RBAC.
설치 방식은 `platform/vault/`·`platform/cert-manager/`와 같은 kustomize `helmCharts` 인플레이트다(§1).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(HTTPS helm repo 인플레이트) + `valuesInline` 전량. 이 디렉터리가 만들지 않는 것의 경계는 머리 주석에 있다 |
| `serviceaccounts.yaml` | SA 5개(`eso-platform`·`eso-dev`·`eso-prod`·`eso-data`·`eso-ca-reader`, ns `external-secrets`). 이 SA로 도는 파드는 없다 → `automountServiceAccountToken: false` |
| `rbac-eso-ca-reader.yaml` | ns `data`의 Role/RoleBinding — store `k8s-data-ca`가 CA Secret 2장만 읽는 범위(§5) |

> **머지 순서: G0 → G1.** G0(AppProject `platform`의 `sourceRepos`에서 external-secrets helm repo 줄 삭제)은
> 2026-09-17에 머지됐다(gitops main `d562bd9`, PR #23). G1은 그 뒤에 연다 — 순서를 강제하는 기계 장치는 없으므로
> cert-manager T042 · vault T044와 같이 draft PR + 본문 체크박스로 지킨다.
> **G1 머지 = 즉시 자동 sync = CRD 25장 + 파드 3개 기동 = 이 시점부터 ESO CR의 admission이 `Fail`로 동작한다**(§4).

- **이 저장소에 비밀은 없다.** 이 디렉터리의 4개 파일에는 토큰·키·OCID가 한 건도 없다.
- 이 디렉터리에는 **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — 이유는 §0 마지막 불릿.
- 로컬 재현(리뷰어용, helm 필요):
  ```bash
  kustomize build --enable-helm platform/external-secrets | kubeconform -strict -ignore-missing-schemas -summary
  # 2026-09-17 실측(kustomize v5.8.1 · helm v4.3.0): 문서 50장 · Valid 25 · Invalid 0 · Skipped 25(= CRD 25장)
  ```
  렌더하면 `platform/external-secrets/charts/`(차트 사본)가 생긴다. `.gitignore`의 `charts/`(T042 PR-0)가 잡으므로
  `git add`에 끌려오지 않는다.

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 결과. 2026-09-17 실측 **50장** — kind별 대조 명령은 §2):

| 객체 | 수 | 출처 | 역할 |
|---|---|---|---|
| CustomResourceDefinition | 25 | 차트 `templates/crds/` | `external-secrets.io` 6종 + `generators.external-secrets.io` 19종. 전부 `Delete=false,Prune=false`(§6) |
| Deployment `external-secrets` · `-webhook` · `-cert-controller` | 3 | 차트 | 컨트롤러 · admission webhook · webhook 인증서 관리자. 모두 replicas 1 · `role: platform`(노드 A) |
| ServiceAccount `external-secrets` · `-webhook` · `-cert-controller` | 3 | 차트 | 위 세 파드의 신원 |
| ServiceAccount `eso-platform` · `eso-dev` · `eso-prod` · `eso-data` · `eso-ca-reader` | 5 | `serviceaccounts.yaml` | ClusterSecretStore(G2)의 인증 주체. Vault role 이름 = SA 이름(T044) |
| ClusterRole `external-secrets-controller` · `-cert-controller` | 2 | 차트 | 컨트롤러·cert-controller 권한(폭발 반경은 §5) |
| ClusterRole `external-secrets-view` · `-edit` | 2 | 차트 | `aggregate-to-view/edit/admin` 라벨 — 기본 view/edit 롤에 ESO CR 읽기·쓰기가 합쳐진다 |
| ClusterRoleBinding `external-secrets-controller` · `-cert-controller` | 2 | 차트 | 위 두 ClusterRole ↔ 차트 SA |
| Role / RoleBinding `external-secrets-leaderelection` | 2 | 차트 | ns `external-secrets` 안 리더 선출(ConfigMap·Lease) |
| Role / RoleBinding `eso-ca-reader` | 2 | `rbac-eso-ca-reader.yaml` | **ns `data`** — CA Secret 2장 get(§5) |
| Service `external-secrets-webhook` | 1 | 차트 | 443 → targetPort 이름 `webhook`(= 10250). API 서버가 여기로 dial 한다 |
| Secret `external-secrets-webhook` | 1 | 차트 | **빈 Secret**(data 없음). cert-controller가 런타임에 서빙 인증서를 채운다(§4) |
| ValidatingWebhookConfiguration `secretstore-validate` · `externalsecret-validate` | 2 | 차트 | `failurePolicy: Fail`. caBundle 필드는 희망 상태에 **없다**(§4) |

**이 디렉터리가 만들지 않는 것**:

- ClusterSecretStore 5개(`vault-platform`·`vault-dev`·`vault-prod`·`vault-data`·`k8s-data-ca`) → **`platform/secret-stores/`**(G2).
  같은 Application에 두지 않는 이유: Argo 내장 health Lua가 store `Ready=False`를 Degraded로 보고, `argocd-cm`의 Application
  health Lua가 그것을 root로 전파한다. store는 Vault가 살아 있어야 Ready인데 Vault는 이 컴포넌트보다 뒤 wave다 →
  한 Application에 묶으면 Vault가 불가한 동안 이 Application이 Degraded가 되어 **root sync가 여기서 멈춘다**.
- ExternalSecret → 원본은 `secrets/<ns>/`, 적용 주체(배달자)는 `platform/secrets/`(G3·G4).
- Namespace `external-secrets` · PSA 라벨(restricted) · NetworkPolicy → `platform/policies/`. 정책 객체는 거기에만 있어야 한다
  (validate 5.0·5.1). 차트의 networkPolicy 3종(controller·webhook·cert-controller)은 기본 false라 값으로 끄지 않았다.
- Vault **내부** 설정(kv 마운트 · auth/kubernetes · 정책 6 · role 6) → 모노레포 `infra/vault/` OpenTofu(T044).
- Application `platform-external-secrets` → `clusters/oci-k3s/apps/platform-external-secrets.yaml`(T041부터 라이브).
  이 PR은 그 파일을 **건드리지 않는다** — 검사 7.1이 `source.path = platform/external-secrets`를 대조한다.
- 시크릿 값: 없다.

> sync-wave 숫자는 여기 적지 않는다. 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**이고, 코드 사본은
> `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.

- **전역 `namespace:` 변환기가 없다** — 차트 객체는 `helmCharts[].namespace: external-secrets`로 렌더되고, 수기 매니페스트는
  각자 `metadata.namespace`를 적는다(`serviceaccounts.yaml` = `external-secrets`, `rbac-eso-ca-reader.yaml` = **`data`**).
  변환기를 두면 ① ns `data`의 Role/RoleBinding이 `external-secrets`로 재작성되고 ② 클러스터 범위 CR(ClusterSecretStore 등)에도
  `metadata.namespace`가 찍힌다(2026-09-17 스크래치 실측). `platform/cloudflared`·`platform/system-upgrade`는 변환기를 쓰므로
  거기서 복사할 때 주의한다.

---

## 1. 왜 kustomize `helmCharts` 인플레이트인가

vault(T044 D1)·cert-manager(T042 D1)와 같은 이유이고, 같은 대가를 알고 골랐다.

1. **검사 7.1이 `source.path`를 강제한다.** `tests/validate.sh` 7.1은 `platform-external-secrets` Application의
   `.spec.source.path`가 `platform/external-secrets`와 정확히 같은지 본다. Argo 네이티브 helm source(`source.chart`)에는
   `path`가 없어 즉시 FAIL이고, 통과시키려면 계약 §sync-wave 표와 `validate.sh`를 함께 고쳐야 한다(T033·T041 산출물 개정).
2. **Application source가 gitops 저장소 하나뿐이다.** 차트는 repo-server의 kustomize가 `helmCharts[].repo`에서 직접 당긴다.
   AppProject `platform`의 `sourceRepos`는 Application `source.repoURL`만 검사하므로 거기 있던
   `https://charts.external-secrets.io` 줄은 아무것도 통제하지 않았다 — **G0 PR(#23)에서 지웠다**(jetstack T042 PR-5 ·
   hashicorp T044 G0에 이은 D7 규칙의 세 번째 실행). 그 공백을 메우는 자리는 `validate.sh`의 `helmCharts[].repo` 허용 목록
   정적 검사이고 T047 몫이다.
3. **HTTPS helm repo라 `oci://` 접두가 없다.** vault(hashicorp)와 같고 cert-manager(OCI 레지스트리)와 **반대**다.
   두 디렉터리의 `repo:` 표기 규칙이 서로 반대라는 점이 복사할 때 가장 먼저 틀리는 곳이다.
4. **helm 릴리스가 아니다.** 인플레이트는 kustomize가 렌더 시각에 템플릿을 펼치는 것이라 `helm list -n external-secrets`가
   비어 있는 것이 정상이고, `helm rollback`·`helm uninstall`은 쓸 수 없다. 되돌리기는 §6의 git 경로뿐이다.
5. 전제: `bootstrap/argocd/argocd-cm.yaml`의 `kustomize.buildOptions: "--enable-helm"`(T042 PR-0, 라이브). 없으면
   `platform-external-secrets`가 `ComparisonError`로 굳는다 — 리소스 손실은 없지만(`prune: false`) `argo-1`과 root 헬스
   신호를 잃는다.
6. 부수 효과로 **검사 5.4b가 살아 있다.** 5.4b는 `helmCharts[].valuesInline`의 `.webhook.port`·`.metrics.listen.port`를
   계약 §포트 각주(10250 · 8080)와 대조하는데, **키가 없으면 조용히 건너뛴다.** 두 키를 값 그대로 명시한 이유다.

⚠ 검사 1(KUST)은 helm이 없으면 이 디렉터리에서 fail-closed다 — cert-manager·vault와 같은 기존 상태이며 T047(CI runner에
helm 설치)이 푼다.

---

## 2. 차트 bump 절차

`kustomization.yaml`에서 함께 움직여야 하는 곳은 **다섯 군데**다(차트 버전 1 + 차트 tgz sha256 주석 1 + image 태그 3).

| 위치 | 값(2026-09-17 실측) | 누가 갱신하나 |
|---|---|---|
| `helmCharts[0].version` | `2.10.0`(appVersion `v2.10.0`) | Renovate가 올릴 수 있다 |
| `version:` 줄 주석의 차트 tgz sha256 | `b96e948f…7d1418`(index.yaml의 tgz digest) | **사람이** — 값 고정이 아니라 **대조용 기록** |
| `image.tag` | `v2.10.0@sha256:814117b0…221b1` | **사람이** — 멀티아치 **인덱스** digest |
| `webhook.image.tag` | 같은 값 | **사람이** |
| `certController.image.tag` | 같은 값 | **사람이** |

**⚠ 세 image 트리는 별개다.** `image`만 고치면 나머지 두 Deployment는 옛 digest로 남고 **자동 검사가 없다**
(validate 4b는 저장소 파일의 `image:` 스칼라 줄만 보는데 여기서는 `image.tag` 블록 표기라 매칭조차 하지 않는다).

**⚠ 이 차트의 `values.schema.json`에는 `additionalProperties`가 0곳이다**(cert-manager는 28곳이라 로컬 렌더가 즉시 실패했다).
키 오타는 조용히 무시되고 렌더는 성공한다 — 예컨대 `nodeSelctor`라고 쓰면 파드가 **노드 B에도 뜰 수 있다.**
**유일한 방어선은 렌더 결과 grep이다.** bump PR 본문에 아래 출력을 붙인다.

```bash
kustomize build --enable-helm platform/external-secrets > /tmp/es.yaml
yq -N '.kind' /tmp/es.yaml | wc -l                                                    # 50 (문서 장수)
yq -N '.kind' /tmp/es.yaml | sort | uniq -c | sort -rn                                # 아래 실측표와 일치
grep -c 'ghcr.io/external-secrets/external-secrets:v2.10.0@sha256:814117b0' /tmp/es.yaml   # 3
grep -c 'role: platform' /tmp/es.yaml                                                 # 3
grep -c 'kind: CustomResourceDefinition' /tmp/es.yaml                                 # 25
grep -c 'argocd.argoproj.io/sync-options: Delete=false,Prune=false' /tmp/es.yaml      # 25
grep -c 'helm.sh/hook' /tmp/es.yaml                                                   # 0 (이 차트에는 templates/tests가 없다)
kubeconform -strict -ignore-missing-schemas -summary -kubernetes-version 1.32.0 /tmp/es.yaml
#   Summary: 50 resources found in 1 file - Valid: 25, Invalid: 0, Errors: 0, Skipped: 25
#   Skipped 25 = CRD 25장(kubeconform에 apiextensions CRD 스키마가 없어 -ignore-missing-schemas로 건너뛴다 — 실측 확인)
```

**2026-09-17 실측 kind별 장수(합계 50 = 차트 43 + 이 디렉터리의 수기 7)**:

| kind | 장 | 내역 |
|---|---|---|
| CustomResourceDefinition | 25 | 전부 차트 |
| ServiceAccount | 8 | 차트 3 + `eso-*` 5 |
| ClusterRole | 4 | controller · cert-controller · view · edit (`rbac.servicebindings.create: false`라 servicebindings ClusterRole은 **없다**) |
| Deployment | 3 | controller · webhook · cert-controller |
| ValidatingWebhookConfiguration | 2 | `secretstore-validate` · `externalsecret-validate` |
| Role | 2 | 차트 `external-secrets-leaderelection`(ns `external-secrets`) + `eso-ca-reader`(**ns `data`**) |
| RoleBinding | 2 | 위와 같은 짝 |
| ClusterRoleBinding | 2 | controller · cert-controller |
| Service | 1 | `external-secrets-webhook` 443 → 10250 |
| Secret | 1 | `external-secrets-webhook`(빈 Secret — §4) |

**절차**: 차트 버전을 올리는 PR에서

1. `helmCharts[0].version`을 새 버전으로.
2. `https://charts.external-secrets.io/index.yaml`의 `entries.external-secrets[]`에서 그 버전 항목의 `digest`(tgz sha256)를
   `version:` 줄 주석에. 차트 태그는 가변이므로(같은 버전 문자열로 재푸시할 수 있다) 이 기록이 **같은 버전 재푸시의 유일한
   대조 수단**이다(단계 5의 캐시 서술과 짝).
3. 새 appVersion의 **인덱스 digest**를 `image.tag`·`webhook.image.tag`·`certController.image.tag` **세 곳 모두**에
   `<tag>@sha256:<digest>` 형태로. 아키텍처별 digest가 아니라 매니페스트 리스트 digest여야 한다(노드 2대가 arm64 Ampere A1).
   얻는 법: `docker buildx imagetools inspect ghcr.io/external-secrets/external-secrets:<tag>`의 첫 `Digest:` 줄, 또는
   레지스트리 API(`GET /v2/external-secrets/external-secrets/manifests/<tag>`에 Accept `application/vnd.oci.image.index.v1+json`).
4. 위 grep 묶음을 돌려 출력을 PR 본문에.
5. **머지 뒤 라이브 반영을 확인한다 — `charts/` 캐시의 범위를 정확히 알아 둔다.**
   캐시 키는 `charts/<name>-<version>/`이라 **버전이 이름에 들어간다**(2026-09-17 스크래치 실측: `version:`을 2.9.0 → 2.10.0으로
   바꾸면 `charts/external-secrets-2.10.0/`이 새로 생기고 렌더의 `helm.sh/chart` 라벨이 함께 바뀐다). 즉 **version bump는 캐시
   미스라 즉시 새로 pull된다** — 단계 6의 "머지 = 즉시 롤아웃"과 어긋나지 않는다.
   가려지는 것은 **같은 버전 문자열의 재푸시**뿐이다(같은 실측에서 `charts/external-secrets-2.10.0/`의 내용을 바꿔 두면 재렌더가
   그 사본을 그대로 쓴다). 그 경우에만 repo-server 재시작 또는 그 `charts/` 제거가 필요하고 **hard refresh로는 풀리지 않는다**
   (git 리비전만 다시 읽는다. Argo CD v3.5.2 repo-server가 최초 init에서만 작업 트리를 청소한다는 것은 소스 문면 확인이고
   라이브 미확인이다). 그 경우의 대조 수단이 단계 2의 tgz sha256이다.
   머지 뒤에는 §7의 `get deploy … image`와 `helm.sh/chart` 라벨로 실제 반영을 확인한다.
6. **이 컴포넌트는 Deployment라 머지 = 즉시 롤아웃이다**(vault의 `OnDelete`와 반대 — 운영자 파드 삭제 단계가 없다).
   CRD 25장이 함께 갱신되므로 새 필드·제거된 필드가 곧바로 적용된다.

---

## 3. values 선택 근거 (전문은 `kustomization.yaml` 주석)

| 키 | 값 | 이유 |
|---|---|---|
| `crds.annotations` | `argocd.argoproj.io/sync-options: Delete=false,Prune=false` | 계약 §삭제 보호. 한 줄이 CRD **25장 전부**에 붙는다(실측 25/25). CRD를 지우면 모든 CR이 cascade 삭제된다(§6) |
| `replicaCount` · `webhook.replicaCount` · `certController.replicaCount` | `1` · `1` · `1` | 노드 A 단독 배치. 차트 기본값이지만 명시한다 |
| `nodeSelector` · `webhook.nodeSelector` · `certController.nodeSelector` | `role: platform` | 3개 트리 각각에 둔다(이 차트에는 `global.nodeSelector`도 있지만 컴포넌트 키와의 병합 규칙에 기대지 않는다). 실측 렌더 3건 |
| `image.tag` · `webhook.image.tag` · `certController.image.tag` | `v2.10.0@sha256:814117b0…` | 이 차트에는 `image.digest` 키가 **없다** → 태그 문자열에 병기하는 것이 유일한 방법(vault 선례). `repo:tag@digest`는 유효한 OCI 참조 |
| `securityContext`(3개 트리) | 4항목 명시 | ns `external-secrets`가 PSA **restricted**라 계약 §워크로드 강화의 4항목(allowPrivilegeEscalation false · runAsNonRoot · capabilities drop ALL · seccompProfile RuntimeDefault)이 admission 통과 조건이다. 이 차트는 부분 지정 시 기본값과 **깊은 병합**이라(실측) `readOnlyRootFilesystem: true`·`runAsUser: 1000`이 유지된다 — vault 차트(대체)와 반대다 |
| `resources`(3개 트리) | requests 20m/96Mi · 10m/48Mi · 10m/48Mi, limits memory만 | 차트 기본 `{}`라 명시하지 않으면 plan A14 예산 대조가 성립하지 않는다. **초기 추정치**이며 T097 실측으로 교정한다(VD-18). CPU limit은 두지 않는다(저장소 관례 · validate 5.5와 같은 취지) |
| `rbac.servicebindings.create` | `false` | 이 클러스터는 servicebinding을 쓰지 않는다 → 미사용 ClusterRole 1장 제거(실측: ClusterRole 5 → 4) |
| `rbac.serviceAccountTokenCreate` | `true`(차트 기본값) | G1은 **차트 기본 RBAC를 그대로 둔다.** 전역 `serviceaccounts/token create`는 최소권한이 아니며(§5) **G2r 단독 PR**에서 `false` + `rbac-token-create.yaml`(resourceNames 5개)로 내린다. 권한 축소를 컴포넌트 머지와 한 PR에 묶지 않는 이유는 설계 D7 — store Ready 실패의 원인을 분리하기 위해서다 |
| `metrics.listen.port` | `8080` | 명시해야 validate 5.4b(`HELM_PORT_KEYS`)가 **실제로 대조한다**(키가 없으면 조용히 건너뛴다). 계약 §포트 각주 `external-secrets 8080 eso-metrics`와 일치 |
| `metrics.service.enabled` | `false` | 차트 기본. T098(Alloy)이 Service discovery를 쓰기로 하면 그때 켠다 |
| `webhook.port` | `10250` | 계약 §포트 각주 · `PORT_TABLE` · `platform/policies`의 `allow-apiserver-webhook` **3중 일치 — 변경 금지**(셋을 함께 바꿔야 한다). Service는 443 → targetPort 이름 `webhook`(= 10250) |
| `webhook.failurePolicy` | `Fail` | 차트 기본값 명시. 대가는 §4 |

**적지 않은 키와 이유**:

| 적지 않은 키 | 이유 |
|---|---|
| `skipTests` | 이 차트에는 `templates/tests`가 **없다**(렌더 `helm.sh/hook` 0건 실측). vault에서 복사하며 붙이지 않는다 |
| `installCRDs` · `crds.create*` | 기본값(전부 true)을 쓴다. 구 키(`installCRDs`)와 신 키(`crds.create*`)를 함께 썼을 때의 동작이 미검증이고, `crds.createSecretStore`는 템플릿 참조가 **0건인 죽은 키**라 699 KB짜리 `secretstores` CRD를 줄이지 못한다 |
| `crds.conversion.enabled` · `crds.unsafeServeV1Beta1` | 둘 다 기본 `false`. 전자는 CRD에 caBundle 주입 대상을 만들지 않아 Argo 드리프트가 없고(§4), 후자가 false라 `v1beta1`이 `served: false`가 되어 계약의 'v1beta1 금지'를 CRD가 직접 강제한다 |
| `scopedRBAC` | ClusterSecretStore와 충돌한다(네임스페이스 범위로 RBAC를 좁히면 클러스터 범위 store를 처리하지 못한다) |
| `processClusterExternalSecret` · `tls.minVersion` | task 문면 밖이고 라이브 검증을 하지 못했다. **후속 하드닝 후보**로 §8에 인계한다 |
| `networkPolicy`(3종) | 기본 `false`. 정책은 `platform/policies`만 소유한다(계약 · validate 5.0) |
| 전역 `namespace:` 변환기 | §0 마지막 불릿 |

---

## 4. webhook — `failurePolicy: Fail`의 대가

렌더 실측(2026-09-17):

| webhook 설정 | 대상 | operations | scope |
|---|---|---|---|
| `secretstore-validate` | `secretstores` | CREATE · UPDATE · **DELETE** | Namespaced |
| `secretstore-validate` | `clustersecretstores` | CREATE · UPDATE · **DELETE** | Cluster |
| `externalsecret-validate` | `externalsecrets` | CREATE · UPDATE · **DELETE** | Namespaced |

- 셋 다 `failurePolicy: Fail` · `sideEffects: None` · `timeoutSeconds: 5` · apiGroup `external-secrets.io` · apiVersion `v1`.
- **코어 `Secret`은 가로채지 않는다.** ESO가 죽어도 일반 Secret의 생성·수정·삭제는 영향이 없다.
- **웹훅이 죽으면 store·ES의 적용과 `삭제`가 막힌다.** DELETE까지 가로채므로, 되돌리기 중에 "먼저 CR을 지우자"는 판단이
  webhook이 이미 죽은 뒤라면 실행되지 않는다 — §6의 순서가 그래서 고정이다.

**인증서 흐름**: 차트는 **빈 Secret** `external-secrets-webhook`과 **caBundle 필드가 없는** webhook 설정 2장을 렌더하고,
cert-controller가 런타임에 둘을 채운다. 희망 상태에 그 필드 자체가 없으므로 `ignoreDifferences`를 넣지 않았다
(설계 D8 — 드리프트로 잡히는지는 VD-5로 배포 뒤 15분 간격 2회 확인한다). cert-controller의 `enablePartialCache`(기본 true)는
`external-secrets.io/component` 라벨에 의존하므로 **라벨을 깎는 kustomize 변환을 넣지 않는다.**

**API 서버 → webhook 경로**는 `platform/policies`의 `allow-apiserver-webhook`(ns `external-secrets`, 10250)이 연다.
**G1p**(T045)로 노드 A의 flannel-wg `/32`(cert-manager T042 PR-A가 `cert-manager` ns에 넣은 것과 같은 성격)가
기존 `10.0.7.78/32` 옆에 **add-only**로 들어갔다. 다만 **동일 노드 경로는 그 전에도 통과했다** — G1 머지 후·G1p 머지 전,
즉 이 ns에 flannel `/32`가 없는 상태에서 아래 프로브가 통과했다(2026-09-17 실측). 노드 간 webhook 경로는 여전히
미실측이다(아래 ⚠). 정책 파일은 이 디렉터리가 만들지 않는다(계약 `network-policy.md`).

**admission이 실제로 동작하는지의 판정 기준**: 유효한 ESO CR을 `kubectl apply --dry-run=server`로 던져
**종료 코드 0 + `… created (server dry run)`** 이 나오는 것(운영자 전용 — §7). 오류 메시지 없음만으로는 판정하지 않는다.
음성 대조도 함께 본다: **webhook 검증 규칙을 어긴**(예: `data`·`dataFrom` 둘 다 없음 — CRD 스키마는 통과한다)
ExternalSecret을 같은 방식으로 던져 `admission webhook "validate.externalsecret.external-secrets.io" denied the request`가
돌아오면 **webhook에 도달했다는 증거**다(도달하지 못하면 거절이 아니라 연결 오류·타임아웃이 난다).
⚠ 진짜 **스키마** 위반(타입 오류 등)은 API 서버가 webhook에 넘기기 전에 거절하므로 이 문구가 나오지 않는다 —
그런 객체를 고르면 "webhook 미도달"로 오판한다. 스키마는 통과하고 webhook 규칙만 어기는 객체를 쓴다.

**⚠ 한계 — 노드 간 webhook 경로는 이 배포로 실측되지 않는다.** ESO Deployment 3개는 `role: platform`(노드 A)이고
API 서버도 노드 A다. 그래서 위 프로브가 통과해도 그것은 **동일 노드 host→pod 경로**의 증거일 뿐이다.
노드 B에서 출발하는 경로는 이 태스크에서 측정되지 않았다.

---

## 5. RBAC — 지금 들이는 권한의 폭발 반경

아래는 전부 **이 PR의 렌더 결과**에서 직접 뽑았다(ClusterRole 4장).

| ClusterRole | 규칙 (전 네임스페이스) | 비고 |
|---|---|---|
| `external-secrets-controller` | `"" secrets: get,list,watch,create,update,delete,patch` | ESO의 존재 이유다. 클러스터 **전 Secret** 읽기·쓰기·삭제. ⚠ `create`+`get`의 조합은 `kubernetes.io/service-account-token` 타입 Secret을 통한 **임의 SA의 레거시 토큰(aud 없음) 획득과 등가**다 — ESO 고유의 잔여 위험이고 **G2r로 줄지 않는다** |
| `external-secrets-controller` | `"" serviceaccounts/token: create` | **⚠ 임의 ns의 임의 SA 토큰을 발급할 수 있다 = 클러스터 admin 등가** — 아래 |
| `external-secrets-controller` | `"" serviceaccounts,namespaces: get,list,watch` · `namespaces: update,patch` · `configmaps: get,list,watch` · `events: create,patch` | ClusterExternalSecret의 ns 라벨링 등 |
| `external-secrets-controller` | `external-secrets.io` CR 6종 **본체** get,list,watch · 같은 6종의 **본체 + `/status` + `/finalizers`** get,update,**patch** · `externalsecrets`·`pushsecrets` create,update,delete · `generators.external-secrets.io` generator 18종 get,list,watch · `generatorstates` get,list,watch,create,update,patch,delete,deletecollection | 자기 CR 군의 조정. ⚠ **본체에 `patch`가 있다** — 컨트롤러 SA를 쥔 쪽은 `clustersecretstores` 본체(= `provider`·`auth`·`conditions`)를 고쳐 쓸 수 있다. 그래서 store `conditions.namespaces`는 ES 작성자에 대한 통제일 뿐, **컨트롤러 침해 시에는 통제가 아니다**(§5의 `eso-ca-reader` 절과 함께 읽는다) |
| `external-secrets-cert-controller` | `"" secrets: get,list,watch`(전역) + `resourceNames: [external-secrets-webhook]`에만 `update,patch` | 자기 webhook 인증서를 넣기 위한 것인데 **읽기는 전역**이다 |
| `external-secrets-cert-controller` | `apiextensions CRD get,list,watch` + 3개 이름에만 `update,patch` · `admissionregistration validatingwebhookconfigurations get,list,watch` + 2개 이름에만 `update,patch` | caBundle 주입. 이 두 줄의 쓰기는 이름으로 좁혀져 있다 |
| `external-secrets-cert-controller` | `coordination.k8s.io leases: get,create,update,patch`(**전역, 이름 제한 없음**) · `"" endpoints` · `discovery.k8s.io endpointslices`: get,list,watch(전역) · `"" events: create,patch` | 리더 선출용 규칙인데 ClusterRole에 있어 **전 ns의 Lease(타 컨트롤러 리더 선출 · `kube-node-lease`)에 update/patch가 가능**하다. 다만 차트 `leaderElect` 기본 `false`라 이 렌더의 cert-controller는 리더 선출을 켜지 않는다(렌더 args에 `--enable-leader-election` 없음) = **미사용 권한**. 규칙 하나만 values로 뺄 수는 없다(`cert-controller-rbac.yaml` 안에 조건 없이 들어 있다). ClusterRole을 통째로 없애는 길은 §8의 `webhook.certManager` 전환, 또는 `certController.rbac.create: false` + 수기 RBAC(**미검증**)다 — 템플릿 가드가 `certController.create` ∧ `certController.rbac.create` ∧ ¬`webhook.certManager.enabled`이기 때문이다(셋 다 기본값은 이 ClusterRole을 렌더하는 쪽) |
| `external-secrets-view` · `-edit` | ESO CR의 read / write. `-view`는 `aggregate-to-view`·`-edit`·`-admin`, `-edit`은 `aggregate-to-edit`·`-admin` 라벨 | 기본 view 롤을 가진 주체는 ESO CR을 **보게 되고**, 기본 edit/admin 롤을 가진 주체는 `externalsecrets`·`secretstores`·`clustersecretstores`·`pushsecrets`·`clusterpushsecrets`의 **create·update·delete·deletecollection·patch까지 받는다**(= gitops validate를 거치지 않고 ES를 직접 만들 수 있다). 2026-09-17 현재 이 저장소에 edit/admin 바인딩은 0건이다 |

**⚠ `serviceaccounts/token create`가 전역인 것이 이 PR의 가장 큰 권한이다.** ESO가 임의 네임스페이스의 임의 SA 토큰을
발급할 수 있다는 뜻이다. 컨트롤러 파드 하나가 뚫리면 (a) 전 Secret 읽기 → (b) 임의 SA 토큰 발급 →
(c) 그 SA에 걸린 Vault role로 로그인(**Vault Kubernetes auth 우회**) → (d) `argocd/argocd-application-controller`(`*/*/*`) 같은
고권한 SA의 토큰 발급 = **클러스터 admin 등가**가 성립한다.
(c)에 대해: Vault role은 SA 이름·ns에 더해 audience `vault`를 바인드하지만(`infra/vault/roles.tf`), **TokenRequest 호출자가
audience를 지정할 수 있으므로** 그 바인드가 이 경로를 막지 못한다.

- **G2r이 닫는 것은 TokenRequest 경로다** — (c) audience 지정이 필요한 Vault 우회 체인과, (b)·(d)의 TokenRequest 판. G2r 단독 PR이
  `rbac.serviceAccountTokenCreate: false` + `rbac-token-create.yaml`
  (ns `external-secrets`의 Role, `resourceNames: [eso-platform, eso-dev, eso-prod, eso-data, eso-ca-reader]`)로 내린다.
  G1에서 함께 내리지 않는 이유는 설계 D7 — 권한 축소가 섞이면 store Ready 실패의 원인을 분리할 수 없다.
- **G2r 뒤에도 남는 것**: 전역 `secrets` create+get은 `kubernetes.io/service-account-token` 타입 Secret을 통해
  임의 SA의 **레거시 토큰**(aud 없음)을 얻는 경로와 등가다. 이 잔여 위험은 ESO가 전 Secret CRUD를 갖는 한 남고 G2r로 줄지 않는다.
  다만 레거시 토큰에는 `aud`가 없으므로 Vault role의 audience 바인드에는 걸린다 — 즉 남는 것은 K8s API 쪽 위험이다.
  **따라서 (d)의 클러스터 admin 등가는 G2r 뒤에도 이 경로로 남는다.**
- 이 창 동안의 완화는 없다. **G1 머지부터 G2r 머지까지의 시간을 짧게 가져가는 것**이 유일한 통제이고, 그 사실을
  report에 기록한다.

**`eso-ca-reader`(ns `data`)** — 이 디렉터리가 만드는 유일한 수기 RBAC다.

- 범위: Secret `pg-main-ca` · `jt-kafka-cluster-ca-cert`의 `get`(+문면상 `list`·`watch`).
- **⚠ RBAC는 Secret 객체 단위다 — 키 단위 인가는 없다.** 그래서 이 Role만으로도 `pg-main-ca` **전체(`ca.key` 포함)** 가
  SA `eso-ca-reader` 신원으로 **이미 읽힌다.** `ca.key`가 앱 ns로 복제되지 않게 막는 통제는 이 파일이 아니라
  ExternalSecret 쪽(validate 3.4의 `property: ca.crt`만 · `dataFrom` 금지 · 하네스 T031)과 store `k8s-data-ca`의
  `conditions.namespaces`, 그리고 그 ns에서 ES를 만들 수 있는 주체다(바로 위 표의 `-edit` 집계 행과 함께 읽는다).
  `ca.key`가 새면 서버·`streaming_replica` 인증서 위조가 가능해져 `sslmode=verify-full`이 무력화된다.
- **이 파일의 리뷰가 막는 것**은 `resourceNames` **밖으로 범위가 넓어지는 것**이다 — `resourceNames`를 빼거나 이름을 늘리면
  ns `data`의 다른 Secret(DB·Kafka 자격, `pg-main-server`/`-replication`의 `tls.key` 등)까지 열린다.
  RBAC 범위에는 자동 검사가 없다(validate 3.4는 ES 쪽만 본다).
- **문면 유지 + 실효 없음 2건**(설계 D12 · 계약 각주와 같은 취지):
  `list`·`watch`는 `resourceNames`가 붙은 규칙이라 이름 없는 요청을 인가하지 못하고(ESO kubernetes provider는 Get만 쓴다),
  `selfsubjectrulesreviews create`는 클러스터 스코프 리소스라 Role로는 부여되지 않는다 — 기본 ClusterRole `system:basic-user`가
  `system:authenticated` 전원에게 이미 준다(VD-7로 실측). 둘 다 동작에는 지장이 없고, 문면을 그대로 두되 근거를 파일 주석에 남겼다.

---

## 6. 되돌리기 — 순서가 곧 안전장치

Application `platform-external-secrets`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.**
> git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다. 반대로 revert만 하면
> `prune: false` 때문에 객체는 남아 있다(그게 정상 동작이다).

1. revert PR 머지 → `kustomization.yaml`이 `resources: []` 뼈대로 복귀 → 렌더 0 → hard refresh. 객체는 그대로 남는다.
2. **store·ExternalSecret을 지워야 한다면 지금, webhook이 아직 Ready인 동안에 한다.** `failurePolicy: Fail`이 DELETE도
   가로채므로 webhook Deployment를 먼저 지우면 CR을 지울 수 없게 된다(§4).
3. 운영자가 수동 삭제, **이 순서로**(admin kubeconfig):
   ```powershell
   # ① Deployment 3
   kubectl -n external-secrets delete deploy external-secrets external-secrets-webhook external-secrets-cert-controller
   # ② webhook 설정 2 — 이걸 지워야 ESO CR의 admission이 풀린다
   kubectl delete validatingwebhookconfiguration secretstore-validate externalsecret-validate
   # ③ Service · Secret · SA · RBAC (이름은 §0 표 또는 get 출력에서)
   kubectl -n external-secrets delete svc external-secrets-webhook
   kubectl -n external-secrets delete secret external-secrets-webhook
   kubectl -n external-secrets delete sa external-secrets external-secrets-webhook external-secrets-cert-controller
   kubectl -n external-secrets delete role,rolebinding external-secrets-leaderelection
   kubectl delete clusterrole external-secrets-controller external-secrets-cert-controller external-secrets-view external-secrets-edit
   kubectl delete clusterrolebinding external-secrets-controller external-secrets-cert-controller
   # eso-* SA와 ns data의 eso-ca-reader RBAC는 store(G2)를 되돌린 뒤에 지운다
   ```
4. **④ CRD 25장은 남긴다.** 지우면 클러스터의 **모든 ClusterSecretStore · ExternalSecret · PushSecret · generator CR이
   cascade 삭제된다.** `Delete=false,Prune=false` 어노테이션이 그것을 위해 붙어 있지만, 그 어노테이션은 Argo에게 주는
   표식일 뿐 `kubectl delete crd`를 막지 않는다. 정말로 지워야 한다면 남은 CR을 먼저 백업한다.

**되돌린 뒤 Application `platform-external-secrets`는 OutOfSync로 남는 것이 정상이다.** 남긴 CRD 25장, 그리고 G2를 되돌릴
때까지 남는 `eso-*` SA · `eso-ca-reader` RBAC에 Argo 추적 어노테이션이 있어, 렌더 0인 상태에서는 이 객체들이 'prune 대상'으로
보이기 때문이다(`prune: false`라 실제로 지워지지는 않는다). 그동안 하네스 `argo-1`은 FAIL한다.
`eso-1`..`eso-3`은 store·ES가 없으면 FAIL하고, CR을 남긴 경우에는 status가 갱신되지 않을 뿐이라 통과할 수 있다(미실측)
— **ESO 생존 신호로 쓰지 않는다.**
**이 OutOfSync를 없애려고 CRD를 지우지 않는다.** 컴포넌트를 다시 머지하면 Synced로 돌아온다.

렌더 실패는 안전하다(`ComparisonError`, 클러스터 변경 0 — 단 `argo-1`과 root 헬스 신호는 잃는다).
G0(AppProject의 external-secrets 줄)은 별개 PR로 되돌린다.

---

## 7. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다.

```powershell
kubectl -n argocd get app platform-external-secrets -o jsonpath='{.status.sync.status} {.status.health.status}'
#   Synced Healthy. webhook의 readinessProbe initialDelay가 20s라 그 전에는 Progressing이 정상이다.
kubectl -n external-secrets get deploy -o 'custom-columns=N:.metadata.name,R:.status.readyReplicas,IMG:.spec.template.spec.containers[0].image'
#   3행 모두 R=1 · IMG는 v2.10.0@sha256:814117b0…
#   bump 뒤 옛 값이면 **`image.tag` 3곳 중 빠뜨린 곳을 먼저 의심한다**(§2) — 이미지는 차트가 아니라 valuesInline에서 온다.
#   차트 자체가 옛 버전인지는 아래 `helm.sh/chart` 라벨로 따로 본다.
kubectl -n external-secrets get deploy external-secrets -o jsonpath='{.metadata.labels.helm\.sh/chart}'
#   external-secrets-2.10.0
#   그쪽이 옛 값이면 sync 미완료·실패를 먼저 본다. `charts/` 캐시는 **같은 버전 재푸시**만 가리는데 그때 이 라벨은
#   `<name>-<version>`이라 바뀌지 않으므로 라벨로는 드러나지 않는다 — 그 경우의 대조 수단은 §2 단계 2의 tgz sha256이다.
kubectl -n external-secrets get pod -o wide
#   3개 모두 노드 A(role=platform). 노드 B에 하나라도 있으면 nodeSelector 오타를 의심한다(§2)
kubectl get crd | Select-String 'external-secrets.io' | Measure-Object
#   25
kubectl get crd -o 'custom-columns=N:.metadata.name,S:.metadata.annotations.argocd\.argoproj\.io/sync-options' `
  | Select-String 'external-secrets.io'
#   25행 전부 Delete=false,Prune=false
#   ⚠ `-o` 값 **전체**를 한 쌍의 작은따옴표로 감싼다. 쉼표로 이어진 토큰 중간에 따옴표를 열면 PowerShell이 그것을 벗기지
#   않고 kubectl에 그대로 넘겨(실측: argv가 `…,S:'.metadata…'`) JSONPath가 깨지고 S 열이 25행 모두 `<none>`으로 나온다
#   — "어노테이션 누락"으로 오판하기 쉽다.
kubectl -n external-secrets get svc external-secrets-webhook -o jsonpath='{.spec.ports[0].port} {.spec.ports[0].targetPort}'
#   443 webhook (targetPort는 이름 — 컨테이너 포트 10250)
kubectl -n external-secrets get sa
#   차트 3 + eso-platform·eso-dev·eso-prod·eso-data·eso-ca-reader
(kubectl -n argocd get app platform-external-secrets -o json | ConvertFrom-Json).status.resources |
  Where-Object { $_.name -eq 'eso-ca-reader' } | Select-Object kind,namespace,name,status
#   기대 3행: ServiceAccount = external-secrets · Role = data · RoleBinding = data.
#   Role·RoleBinding의 namespace가 external-secrets로 보이면 전역 namespace 변환기가 들어간 것이다(§0) — 즉시 되돌린다.
#   ⚠ 이 확인을 `kubectl -n data get role,rolebinding`으로 하지 않는 이유: agent-view에는 RBAC 읽기 권한이 없다
#   (`platform/policies/rbac-agent-view.yaml` — 기본 `view`에도 roles/rolebindings가 없다) → Forbidden이다. 그 명령은 운영자 전용 블록에 있다.
kubectl -n external-secrets logs deploy/external-secrets --since=5m | Select-String -Pattern 'error|denied|forbidden'
#   0행. `forbidden`이 보이면 RBAC(§5)나 default-deny 정책을 본다
```

**운영자 전용**(admin kubeconfig가 필요하거나 쓰기 성격):

```powershell
# caBundle 주입 확인 — agent-view에는 admissionregistration 읽기 권한이 없다
(kubectl get validatingwebhookconfiguration secretstore-validate `
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}').Length     # > 0
# eso-ca-reader RBAC를 객체로 직접 확인(agent-view는 RBAC를 읽지 못한다 — 위 Application 기반 확인이 에이전트용 대체)
kubectl -n data get role,rolebinding eso-ca-reader
#   두 객체 모두 ns data. subjects는 external-secrets/eso-ca-reader
# VD-1: admission 프로브 — 판정은 "종료 코드 0 + created (server dry run)"
kubectl apply --dry-run=server -f <유효한 ClusterSecretStore 또는 ExternalSecret>.yaml
# VD-7: selfsubjectrulesreviews가 system:basic-user로 이미 되는지
kubectl auth can-i create selfsubjectrulesreviews --as=system:serviceaccount:external-secrets:eso-ca-reader
# VD-9: webhook/cert-controller의 readinessProbe(8081)가 default-deny 아래에서 통과하는지 — describe의 Warning 유무
kubectl -n external-secrets describe pod <webhook-pod> | Select-String -Context 0,3 Warning
# VD-5: 15분 간격 2회 — caBundle 주입이 Argo 드리프트(OutOfSync)로 잡히는지
kubectl -n argocd get app platform-external-secrets -o jsonpath='{.status.sync.status}'
```

---

## 8. 인계

- ~~**G1p**~~ **완료** — `platform/policies/policies-common.yaml`의 `allow-apiserver-webhook`(ns `external-secrets`)에
  노드 A flannel-wg 출발 주소 `10.42.0.0/32`를 add-only로 더했다(값은 머지 전 노드 A 실측으로 확정 — `flannel-wg`
  장치 주소와 **다른 노드(B)의 파드 IP**로의 `ip route get` `src`). 동일 노드 경로는 그 전에도 통과했고
  (2026-09-17 실측: dry-run `created (server dry run)` · 음성 대조 webhook denied) 노드 간 경로는 미실측이다 — §4.
  이 디렉터리는 정책을 만들지 않는다(§0).
- **G2** — ClusterSecretStore 5개 → `platform/secret-stores/`. `auth.kubernetes.serviceAccountRef.audiences: [vault]`가
  **필수**이고(Vault 1.21+ · 2.x — ESO 문서 기준), Vault role 이름 = SA 이름이다. 다섯 번째 `k8s-data-ca`는 Vault role이 없고
  이 디렉터리의 `eso-ca-reader` RBAC로 동작한다(store의 `conditions.namespaces`가 `ca.crt` 소비 ns를 좁히는 통제다 — §5).
- **G2r** — `rbac.serviceAccountTokenCreate: false` + `rbac-token-create.yaml`(resourceNames 5개).
  **TokenRequest 경로(= §5의 Vault 우회 체인)를 닫는 단독 PR이다.** 전역 `secrets` CRUD에서 오는 K8s API 쪽 잔여 위험
  (레거시 SA 토큰 Secret)은 G2r로 줄지 않는다 — §5. `kustomization.yaml`의 `resources:`에 주석으로 남겨 둔 줄을 그때 살린다.
- **T046(Reloader)** — ESO가 갱신한 Secret을 소비 파드에 반영하는 주체. 이 컴포넌트는 파드를 재시작시키지 않는다.
- **T098(monitoring)** — `metrics.service.enabled: false`를 켤지, Alloy가 파드 discovery로 8080을 직접 긁을지 결정한다.
- **후속 하드닝 후보**(지금 넣지 않은 이유는 §3):
  `processClusterExternalSecret`(ClusterExternalSecret을 안 쓴다면 끄는 쪽이 권한·부하 모두 줄인다) ·
  `tls.minVersion`(webhook·cert-controller의 TLS 하한) ·
  `webhook.certManager`(cert-controller 대신 cert-manager가 webhook 인증서를 발급 — cert-controller ClusterRole의 전역
  `secrets get,list,watch`가 사라진다. 계약 변경이라 범위 밖).
- **resources 값은 추정치다** — T097이 `kubectl top`으로 교정한다(VD-18).
