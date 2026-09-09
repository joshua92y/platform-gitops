# platform/cert-manager/ — 운영자 절차 (T042 PR-1)

cert-manager v1.21.1의 **컨트롤 플레인만** 소유한다 — CRD 6장 + Deployment 3개(controller · webhook · cainjector)
+ 그에 딸린 RBAC · Service · webhook 설정. ClusterIssuer(ACME/DNS-01)와 Certificate는 `platform/cert-manager-issuers/`
(T042 PR-2 · PR-3), Namespace·PSA 라벨·NetworkPolicy는 `platform/policies/`, Application은
`clusters/oci-k3s/apps/platform-cert-manager.yaml`(T041 PR-C)이 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(OCI 인플레이트) + `valuesInline` 전량 + CRD 삭제 보호 patch. 이 디렉터리가 만들지 않는 것(ns · Application · NetworkPolicy · Secret)의 경계는 머리 주석에 있다 |

- **이 저장소에 비밀은 없다.** Cloudflare API 토큰과 ACME 계정 키는 운영자 수동 Secret(T042) → `secrets/cert-manager/` ExternalSecret(T045)으로 간다.
- 이 디렉터리에는 **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — 이유는 §4.
- 로컬 재현(리뷰어용):
  ```bash
  kustomize build --enable-helm platform/cert-manager | kubeconform -strict -ignore-missing-schemas -summary
  # 객체 46개: ClusterRole 13 · ClusterRoleBinding 10 · CRD 6 · SA/Service/Role/RoleBinding/Deployment 각 3 · Validating/Mutating 각 1
  ```
  ⚠ 렌더하면 이 디렉터리에 `charts/`(차트 사본)가 생긴다. T042 PR-0이 `.gitignore`에 `charts/`를 등재했다 —
  커밋 전에 `git status`로 섞이지 않았는지 확인한다(gitleaks가 차트 사본을 훑어 오탐을 내기도 한다).

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

`bootstrap/argocd/argocd-cm.yaml`에 이 키가 있어야 repo-server가 `helmCharts`를 인플레이트한다(T042 PR-0에서 단독으로 넣었다).

- **없으면**: `platform-cert-manager`가 렌더 실패로 `ComparisonError`에 굳는다. **리소스 손실은 없다** —
  Application이 `prune: false`이고, 렌더에 실패하면 Argo는 아무것도 지우지 않는다. 증상은 "새 sync가 더 이상 진행되지 않음"뿐이다.
- **이 옵션은 저장소 전체에 걸린다.** 어떤 kustomization이든 렌더 시각에 원격 차트를 pull 할 수 있게 되므로(공급망 표면 확대),
  통제는 main 브랜치 ruleset(PR 필수 · required check `validate` · `bypass_actors: []`)뿐이다. 새 `helmCharts` 항목을 추가하는
  PR은 `repo`·`version`을 리뷰 포인트로 삼는다.
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
   형태인지 확인한 뒤 PR 본문에 붙인다.

T116에서 Renovate customManager로 자동화할 후보다(그때까지는 이 문단이 유일한 방어선이다).

---

## 4. values 선택 근거 (전문은 `kustomization.yaml` 주석)

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

**렌더 실패는 안전하다** — `ComparisonError`로 끝나고 클러스터 변경이 0이다.

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
넣었다는 뜻이고, 그 상태에서는 파드가 Ready이고 Argo가 Synced/Healthy인데도 인증서가 한 장도 발급되지 않는다.
