# platform/cert-manager/ — 운영자 절차 (T042 PR-1)

cert-manager v1.21.1의 **컨트롤 플레인만** 소유한다 — CRD 6장 + Deployment 3개(controller · webhook · cainjector)
+ 그에 딸린 RBAC · Service · webhook 설정. ClusterIssuer(ACME/DNS-01)와 Certificate는 `platform/cert-manager-issuers/`
(T042 PR-2 · PR-3), Namespace·PSA 라벨·NetworkPolicy는 `platform/policies/`, Application은
`clusters/oci-k3s/apps/platform-cert-manager.yaml`(T041 PR-C)이 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(OCI 인플레이트) + `valuesInline` 전량 + CRD 삭제 보호 patch. 이 디렉터리가 만들지 않는 것(ns · Application · NetworkPolicy · Secret)의 경계는 머리 주석에 있다 |

> **머지 순서: PR-0 → PR-1.** 이 PR은 `bootstrap/argocd/argocd-cm.yaml`의 `kustomize.buildOptions: "--enable-helm"`(T042 PR-0)을
> 전제로 한다. 두 PR 모두 main을 대상으로 하고 GitHub은 순서를 모르므로 **순서를 강제하는 기계 장치가 없다** — PR-1은 draft로 열고
> 본문의 "PR-0 머지 확인" 체크박스를 채운 뒤에만 머지한다. 뒤집혔을 때 무엇이 깨지는지는 §2.

- **이 저장소에 비밀은 없다.** Cloudflare API 토큰과 ACME 계정 키는 운영자 수동 Secret(T042) → `secrets/cert-manager/` ExternalSecret(T045)으로 간다.
  저장소 비밀과 별개로, 이 PR이 **클러스터에 들이는 권한**의 폭발 반경은 §7에 따로 적었다 — 머지 전에 반드시 읽는다.
- 이 디렉터리에는 **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — 이유는 §4의 첫 불릿.
- 로컬 재현(리뷰어용):
  ```bash
  kustomize build --enable-helm platform/cert-manager | kubeconform -strict -ignore-missing-schemas -summary
  # 객체 46개: ClusterRole 13 · ClusterRoleBinding 10 · CRD 6 · SA/Service/Role/RoleBinding/Deployment 각 3 · Validating/Mutating 각 1
  ```
  ⚠ 렌더하면 이 디렉터리에 `charts/`(차트 사본)가 생긴다. T042 PR-0이 `.gitignore`에 `charts/`를 등재한다(**이 PR보다 먼저** 머지돼야 한다) —
  그전까지는 방어선이 규율뿐이므로 `git add -A`·`git commit -a`를 쓰지 말고, 커밋 전에 `git status`로 섞이지 않았는지 확인한다
  (gitleaks가 차트 사본을 훑어 오탐을 내기도 한다).

---

## 1. 왜 Argo 네이티브 helm source가 아니라 kustomize `helmCharts` 인플레이트인가

차트를 가져오는 방법은 둘이고, 이 저장소는 **A(kustomize 인플레이트)**를 쓴다.

1. **검사 7.1이 `source.path`를 강제한다.** `tests/validate.sh`의 검사 7.1은 `platform-<컴포넌트>` Application의 경로를
   `.spec.source.path`(없으면 `.spec.sources[0].path`)로 뽑아 `platform/<컴포넌트>`와 정확히 같은지 본다.
   Argo 네이티브 helm source(`source.chart`)에는 `path`가 없어 `-`가 되고 **즉시 FAIL**한다.
   통과시키려면 계약 §sync-wave 표와 `validate.sh`를 함께 고쳐야 하는데, 그것은 T033·T041 산출물 개정이다.
2. **`oci://`를 붙이면 Argo가 `chart` 필드를 무시한다.** Argo CD v3.5.2는 `source.IsOCI()`(repoURL이 `oci://`로 시작)를
   `source.IsHelm()`(chart ≠ "")보다 **먼저** 평가한다. 그래서 네이티브 helm source로 갈 때 `oci://`를 붙이면 OCI-artifact
   경로로 조용히 빠진다(Argo 문서도 "the oci:// syntax is not included"라고 못박는다). 표기 한 글자에 동작이 갈린다.
   **kustomize는 정반대로 `oci://` 접두가 필수**라, 두 방식의 표기 규칙이 서로 반대라는 점이 혼동의 원천이다.
3. 반대로 인플레이트에는 대가가 있다 — `--enable-helm`(§2)과 `.gitignore charts/`가 필요하고, Renovate의 helm-values
   매니저가 `valuesInline`을 보지 못한다(그래서 §3의 수동 규율이 필요하다). 그 대가를 알고 고른 것이다.
4. 부수 효과로 **검사 5.4b가 살아 있다.** 이 검사는 `helmCharts[].valuesInline`만 읽어 `.webhook.securePort`를 계약 §포트
   각주(10250)와 대조한다. 값을 `valuesFile`로 빼거나 네이티브 helm source로 옮기면 이 대조가 **조용히** 사라진다.

---

## 2. 선행 의존 — `kustomize.buildOptions: "--enable-helm"`

`bootstrap/argocd/argocd-cm.yaml`에 이 키가 있어야 repo-server가 `helmCharts`를 인플레이트한다(T042 PR-0이 단독으로 넣는다 —
**이 PR보다 먼저 머지돼야 한다**).

- **없으면**: `platform-cert-manager`가 렌더 실패로 `ComparisonError`에 굳는다. **리소스 손실은 없다** —
  Application이 `prune: false`이고, 렌더에 실패하면 Argo는 아무것도 지우지 않는다. 그러나 **조용한 실패는 아니다**:
  - 이 Application이 `Synced`를 잃으므로 `tests/platform/cluster.tests.ps1`의 **`argo-1`(제외 목록 밖 전 Application이 Synced/Healthy)이 FAIL** 한다.
  - `argocd-cm`의 `resource.customizations.health.argoproj.io_Application` Lua가 child의 `status.health.status`를 그대로 승계하므로,
    이 child가 Healthy를 잃는 순간 **root app-of-apps의 Healthy 신호까지 함께 사라진다**(설계 §8 R13).
  - 복구는 PR-0을 머지하고 hard refresh 하는 것뿐이다. 즉 "새 sync가 멈춤"은 증상의 일부일 뿐이다.
- **이 옵션은 저장소 전체에 걸린다.** 어떤 kustomization이든 렌더 시각에 원격 차트를 pull 할 수 있게 되므로(공급망 표면 확대),
  통제는 main 브랜치 ruleset(PR 필수 · required check `validate` · `bypass_actors: []`)뿐이다. 새 `helmCharts` 항목을 추가하는
  PR은 `repo`·`version`을 리뷰 포인트로 삼는다.
- ⚠ **그 통제에는 구멍이 하나 있다 — 차트 태그는 가변이다.** `helmCharts`에는 digest 필드가 없어 `version: v1.21.1`은 이름 참조일 뿐이다.
  태그가 재푸시되거나 레지스트리가 오염되면 repo-server의 **다음 캐시 미스**에서 다른 CRD·ClusterRole·webhook 설정이 인플레이트되고,
  `selfHeal: true`가 그것을 **PR 없이 자동 적용한다.** 이 저장소에서 PR 게이트를 거치지 않는 유일한 변경 경로다.
  방어는 `kustomization.yaml`의 차트 digest 주석(대조용 실측 기록)과 §3의 bump 절차뿐이며, 둘 다 사람이 지키는 규율이다.
- `argocd-cm` 변경 뒤에는 Application을 **hard refresh**해야 새 buildOptions가 반영된다.

**helm 릴리스가 아니다.** 인플레이트는 kustomize가 렌더 시각에 템플릿을 펼치는 것이라 `helm list -n cert-manager`에는
아무것도 보이지 않는다. `helm rollback`·`helm uninstall`도 쓸 수 없다 — 되돌리기는 §5의 git 경로뿐이다.

---

## 3. ⚠ 차트 버전 bump PR은 `valuesInline`의 digest 3개를 **함께** 갱신해야 한다

`kustomization.yaml`에는 버전이 **두 군데** 있다.

| 위치 | 값 | 누가 갱신하나 |
|---|---|---|
| `helmCharts[0].version` | `v1.21.1` (차트 버전) | Renovate가 자동으로 올릴 수 있다 |
| `valuesInline`의 `image.tag`+`digest`, `webhook.image.*`, `cainjector.image.*` | `v1.21.1` + digest 3개 (바이너리 버전) | **사람이 수동으로** |
| `version:` 줄 주석의 **차트 아티팩트 digest** | `sha256:15c0b46d…`(2026-09-08 실측) | **사람이 수동으로** — 값 고정이 아니라 **대조용 기록**이다(§2 마지막 불릿) |

**네 번째 이미지 `cert-manager-acmesolver`는 digest를 고정하지 않는다.** 렌더된 컨트롤러 인자에
`--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.21.1`(태그만, digest 없음)이 남는데, 이는 HTTP-01 solver
전용이고 이 클러스터는 **DNS-01만** 쓰므로 solver 파드가 한 번도 생성되지 않기 때문이다 — 그래서 계약 §이미지의 digest 병기
대상에서 의도적으로 제외한다(태그는 차트 appVersion을 따라가므로 버전 드리프트도 없다). HTTP-01을 도입하는 PR은
`acmesolver.image.tag` + `acmesolver.image.digest`(둘 다 `values.schema.json`에 실재)를 **네 번째 항목으로 함께 고정하고**
아래 절차를 4행으로 늘린다.

**자동 검사가 없다.** 검사 4b는 렌더된 `image:` 줄이 아니라 저장소 파일의 `image:` 스칼라 줄만 보고, 여기서는 블록 스타일이라
매칭되지 않는다. Renovate가 차트 `version`만 올리면 **새 차트 템플릿이 옛 바이너리를 당기는** 상태가 조용히 성립한다
(차트 주석: 값이 없으면 chart appVersion을 쓴다 — 즉 digest를 지우면 자동 추종하지만, 그러면 계약 §이미지의 digest 병기가 깨진다).

**절차**: 차트 버전을 올리는 PR에서
1. `helmCharts[0].version`을 새 버전으로,
2. `image.tag` 3곳을 같은 값으로,
3. `crane digest quay.io/jetstack/cert-manager-{controller,webhook,cainjector}:<새 태그>`(또는 레지스트리 API의
   `Docker-Content-Digest`)로 얻은 **manifest list digest**를 `digest` 3곳에 —
   노드 2대가 arm64(Ampere A1)이므로 아키텍처별 digest가 아니라 인덱스 digest여야 한다,
4. 로컬 `kustomize build --enable-helm platform/cert-manager | grep 'image:'`로 3줄이 `<repo>:<새 태그>@sha256:<새 digest>`
   형태인지 확인한 뒤 PR 본문에 붙인다,
5. `helm pull oci://quay.io/jetstack/charts/cert-manager --version <새 태그>`의 **`Digest:` 출력**을 PR 본문에 붙이고
   `version:` 줄 주석의 차트 digest를 그 값으로 갱신한다(§2 마지막 불릿 — 태그가 가변이라 이 기록이 유일한 대조 수단이다).

T116에서 Renovate customManager로 자동화할 후보다(그때까지는 이 문단이 유일한 방어선이다).

---

## 4. values 선택 근거 (전문은 `kustomization.yaml` 주석)

- **전역 `namespace:` 변환기 없음** — 차트는 `global.leaderElection.namespace`(kube-system)에 Role/RoleBinding
  `cert-manager:leaderelection` · `cert-manager-cainjector:leaderelection` **4객체**를 렌더한다. 변환기가 이 넷을 `cert-manager` ns로
  재작성하면 컨트롤러 인자 `--leader-election-namespace=kube-system`과 어긋나 Lease 접근이 forbidden → **리더 선출 영구 실패**.
  그런데 파드는 Ready이고 Argo는 Synced/Healthy라 **인증서가 한 장도 발급되지 않는데 아무 신호가 없다**(무증상 실패).
  네임스페이스는 `helmCharts[].namespace`로만 준다. 확인 명령은 §6.
- **`startupapicheck.enabled: false`** — 기본 `true`면 차트의 `helm.sh/hook: post-install` Job이 Argo의 **PostSync 훅**으로
  매핑돼 **매 sync마다** Job·SA·Role·RoleBinding·ClusterRole이 생겼다 사라지고, 실패하면 Application이 Degraded로 잠긴다.
  "CRD가 준비됐는지 확인하는 카나리아"라는 값어치는 GitOps에서 sync-wave와 Argo의 재시도가 이미 제공하고,
  더 정확한 형태(`kubectl --dry-run=server` 프로브)로 배포 게이트에서 따로 확인한다. `false`면 관련 객체가 **전부** 사라진다(렌더로 확인).
- **편차 ② `dns01RecursiveNameservers: "1.1.1.1:53"` 단독**(계약 문면은 8.8.8.8 병기) — DNS-01 self-check는
  `Only: true`에서 리졸버를 하나씩 단독 질의하고 **첫 오류에 즉시 실패한다(폴백 없음)**. 적용된 정책(`allow-egress-dns-1111`)은
  `1.1.1.1/32`:53만 열려 있으므로 8.8.8.8이 남아 있으면 Challenge가 오류 없이 `pending`에 머문다. 8.8.8.8을 열려면
  계약 수정 경로가 필요해 값 쪽을 단독으로 맞췄다(편차는 `/speckit-converge`에 인계).
  `Only: true`는 선택이 아니라 **필수값**이다 — `false`면 self-check가 권위 NS의 임의 IP:53으로 나가 전부 드롭된다.
- **편차 ④ `global.nodeSelector: {role: data}`**(계약 문면은 컴포넌트별 지정) — 차트가 이 값을 컴포넌트별 nodeSelector와
  **병합**해 3 워크로드 모두 `{kubernetes.io/os: linux, role: data}`가 된다(렌더로 실측). 키 3개(`nodeSelector` ·
  `webhook.nodeSelector` · `cainjector.nodeSelector`)를 각각 쓰는 것보다 드리프트 여지가 작다.
  결과적으로 3종이 노드 B 단독 배치이므로, 노드 B drain 중에는 `failurePolicy: Fail`인 webhook 때문에 cert-manager CR의
  CREATE/UPDATE가 클러스터 전역에서 거부된다(**서빙 영향 없음 — 발급만 큐잉**). SUC 업그레이드 창 동안 issuers를 sync 하지 않는다.
- **`webhook.securePort: 10250`은 변경 금지** — 계약 §포트 각주 · `platform/policies`의 `allow-apiserver-webhook` ·
  `validate.sh`의 `HELM_PORT_KEYS` 3중 일치다. 바꾸려면 셋을 같은 PR에서 함께 바꿔야 한다.
- **`crds.enabled: true` 하나만 쓴다** — 구 `installCRDs`(deprecated)와 동시에 쓰면 차트의 `crd-check` 헬퍼가 렌더를 실패시킨다.
- 키 오타는 조용히 무시되지 않는다 — 차트에 `values.schema.json`이 있고 28곳이 `additionalProperties: false`라
  로컬 `kustomize build --enable-helm`이 즉시 실패한다.

---

## 5. 되돌리기 — 2단 규율 (순서가 곧 안전장치)

> ⚠ **이 되돌리기가 '무해'한 것은 PR-4(TLSStore) 적용 전까지다.** TLSStore가 살아 있는 상태에서 이 PR을 revert하면 컨트롤러가
> 사라져 **갱신만 조용히 멈춘다** — CRD·Certificate·Secret은 남아 서빙이 계속되므로 그 순간에는 아무 신호가 없고, 최대 90일 뒤
> 만료 시점에 Cloudflare Full(strict)가 **전 호스트 526**을 낸다(설계 R5·R19). T098의 만료 알림
> (`certmanager_certificate_expiration_timestamp_seconds`) 전에는 자동 감지 수단이 **없으므로**, PR-4 이후에 revert한다면
> 만료일을 사람이 기록하고 감시한다:
>
> ```bash
> kubectl -n kube-system get secret wildcard-joshuatech-dev-tls -o jsonpath='{.data.tls\.crt}' \
>   | base64 -d | openssl x509 -noout -enddate
> ```

Application은 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서:

> **git revert 머지가 먼저, 수동 삭제가 그다음.**
> git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다. 반대로 revert만 하면
> `prune: false` 때문에 리소스는 남아 있다(그게 정상 동작이다).

1. revert PR 머지 → `platform/cert-manager/kustomization.yaml`이 `resources: []` 뼈대로 복귀 → hard refresh.
2. (필요할 때만) 운영자가 수동 삭제:
   ```bash
   kubectl -n cert-manager delete deploy --all
   kubectl delete validatingwebhookconfiguration cert-manager-webhook
   kubectl delete mutatingwebhookconfiguration  cert-manager-webhook
   ```
3. **CRD 6장은 의도적으로 남긴다.** `crds.keep: true`와 patch의 `argocd.argoproj.io/sync-options: Delete=false,Prune=false`가
   둘 다 그걸 위해 있다 — CRD를 지우면 클러스터의 **Certificate · Order · Challenge가 전부 같이 사라진다.**
   (`helm.sh/resource-policy: keep`은 helm 전용이라 Argo의 prune과 무관하다. Argo 쪽 대응물은 그 어노테이션뿐이다.)
   정말로 CRD까지 지워야 한다면 남은 CR을 먼저 백업하고 `kubectl delete crd …`를 수동으로 한다.

**렌더 실패는 안전하다** — `ComparisonError`로 끝나고 클러스터 변경이 0이다(다만 §2의 신호 손실 — `argo-1` FAIL과 root 헬스 —
은 그대로 발생한다).

---

## 6. 배포 뒤 확인

```bash
kubectl -n argocd get app platform-cert-manager -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n cert-manager get deploy -o wide                      # 3개 Ready · NODE 전부 노드 B(role=data)
kubectl get crd -o custom-columns=N:.metadata.name,S:'.metadata.annotations.argocd\.argoproj\.io/sync-options' \
  | grep cert-manager                                           # 6장 전부 Delete=false,Prune=false
kubectl -n kube-system get role,rolebinding | grep leaderelection   # kube-system에 있어야 한다(§4의 전역 변환기 금지)
kubectl get validatingwebhookconfiguration cert-manager-webhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c    # > 0 (cainjector가 주입)
kubectl -n cert-manager logs deploy/cert-manager --since=5m | grep -Ei 'error|denied|refused'   # 0줄
kubectl top pods -n cert-manager                                # 요청 합계 160Mi ≈ 0.16 GiB 대조(plan A14 · T097에서 교정)
```

`leaderelection` Role/RoleBinding이 `cert-manager` ns에 보이면 **즉시 되돌린다** — 누군가 전역 `namespace:` 변환기를
넣었다는 뜻이고, 그 상태에서는 파드가 Ready이고 Argo가 Synced/Healthy인데도 인증서가 한 장도 발급되지 않는다(§4 첫 불릿).
정상은 4객체 전부 `kube-system` 유지다(Role/RoleBinding `cert-manager:leaderelection` · `cert-manager-cainjector:leaderelection`).

**3개 중 하나라도 Ready가 안 되면 첫 가설은 차트가 아니라 default-deny다.** 렌더된 kubelet 프로브 포트는
webhook `6080`(readiness+liveness) · controller `9403`(liveness)인데, `cert-manager` ns의 ingress 허용 규칙은
`10.0.7.78/32`·`10.42.0.0/32`:10250(`allow-apiserver-webhook` — 후자는 T042 PR-A add-only, 노드 A flannel-wg 주소) ·
`monitoring:9402` · same-namespace **뿐**이고 6080·9403은 어디에도 없다.
통과 근거는 T041 VD-P(같은 노드 host→pod 통과) 하나이며 이 컴포넌트에서 재측정된 적이 없다. 검사 5.4b는 helm values의
`.webhook.securePort`만 보므로 이 두 포트는 **어떤 자동 검사에도 걸리지 않는다.**

```bash
kubectl -n cert-manager describe pod <webhook-pod> | grep -A3 Warning   # probe failed 여부
# 노드 B에서:
curl -s -o /dev/null -w '%{http_code}\n' http://<podIP>:6080/healthz
```

정책 추가가 필요하다고 판명되면 **계약 수정 경로**(D6와 같은 k8s-security 경계)이며 임의로 고치지 않는다.

**머지 뒤 Argo UI에 새 고아(orphaned) 경고가 하나 뜬다 — 정상이다.** webhook이 자기 서빙 CA를 런타임에 만들기 때문이다
(`--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)` · `--dynamic-serving-ca-secret-name=cert-manager-webhook-ca`, 짝이 되는
Role `cert-manager-webhook:dynamic-serving`). AppProject `platform`이 `orphanedResources.warn: true`라 선언에 없는 이 Secret을
경고로 알린다. **지우지 않는다** — 지우면 webhook이 재생성하고 그 사이 caBundle 재주입까지 잠시 흔들린다.
(PR-2의 운영자 수동 Secret 2~3장도 같은 경고를 늘린다. 드리프트가 아니다.)

---

## 7. RBAC 폭발 반경 (수용된 위험 — 머지 전에 읽는다)

이 PR은 **클러스터 admin 등가에 가까운 권한 경로를 하나 새로 만든다.** 이 저장소는 AppProject 머리 주석("argocd ns 배포 가능 =
클러스터 admin 등가")과 agent-view("Secret get 없음 · pods/exec 없음")처럼 권한 사실을 명문화하는 관례가 있으므로, 그보다 큰 이 권한도
그대로 적는다. 아래는 전부 **이 PR의 렌더 결과**(ClusterRole 13장)에서 직접 뽑았다.

| ClusterRole | 규칙 (전 네임스페이스) | 이 클러스터에서 실제로 쓰나 |
|---|---|---|
| `cert-manager-controller-certificates` | `"" secrets: get,list,watch,create,update,delete,patch` | **쓴다** — 발급 결과가 Secret이다 |
| `cert-manager-controller-issuers` · `-clusterissuers` | `"" secrets: get,list,watch,create,update,delete` | **쓴다** — ACME 계정 키 Secret |
| `cert-manager-cainjector` | `"" secrets: get,list,watch` + `validatingwebhookconfigurations`·`mutatingwebhookconfigurations`·`apiservices`·`customresourcedefinitions: update,patch` | **쓴다** — 자기 webhook의 caBundle 주입. 다만 대상이 **임의의** webhook/CRD로 열려 있다 |
| `cert-manager-controller-challenges` | `"" pods,services: get,list,watch,create,delete` + `networking.k8s.io ingresses: get,list,watch,create,delete,update` + `gateway.networking.k8s.io httproutes` 동일 | **한 번도 쓰지 않는다** — 이 설계는 DNS-01 전용이라 HTTP-01 solver 파드가 생성되지 않는다 |

**연결고리**: `platform/policies/namespaces.yaml`의 `kube-system` PSA는 **privileged**다. 그래서 노드 B의 cert-manager 파드 하나가
뚫리면 (a) 클러스터 **전 Secret 읽기·삭제**(vault · argocd · cloudflared 터널 토큰 포함) → (b) `kube-system`에 privileged 파드 생성 →
**노드 root** 가 성립한다. cainjector의 webhook/CRD `patch`는 여기에 임의 admission 경로 조작을 더한다.

**차트에는 이 RBAC를 끄는 value가 없다.** `values.schema.json`의 `global.rbac` 하위는 `create` · `aggregateClusterRoles` 둘뿐이고,
HTTP-01 전용 규칙만 떼어내는 키는 존재하지 않는다(스키마 직접 확인). 그래서 T042는 이 상태를 **수용한다.**

**완화 후보(후속 태스크 T097/T114로 인계)**: DNS-01 전용이므로 `cert-manager-controller-challenges`에서
`pods` · `services` · `ingresses` · `httproutes` 규칙을 지우는 SMP 패치를 이 디렉터리에 추가할 수 있다. 지금 넣지 않는 이유는
차트 업그레이드마다 규칙 배열이 흔들려 조용한 드리프트를 만들고, HTTP-01로 전환하는 순간 즉시 되돌려야 하기 때문이다.
넣을 때는 §4의 편차와 같은 방식으로 근거를 남기고 `/speckit-converge`에 인계한다.
