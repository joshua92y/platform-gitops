# platform/secret-stores/ — 운영자 절차 (T045 G2)

`ClusterSecretStore` **5장만** 소유한다 — ExternalSecret이 "어느 저장소에서, 어떤 신원으로" 비밀을 읽는지를 선언하는
클러스터 범위 객체다. 오퍼레이터 본체(CRD·Deployment·`eso-*` SA·`eso-ca-reader` RBAC)는 `platform/external-secrets/`가,
ExternalSecret은 `secrets/<ns>/`(원본)와 `platform/secrets/`(적용)가 소유한다. 이 디렉터리에는 helm 차트가 없다 —
순수 매니페스트 5장 + `kustomization.yaml`이다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources` 5줄만. helm 없음, 전역 `namespace:` 변환기 없음(아래 불릿) |
| `clustersecretstore-vault-platform.yaml` | vault provider · 플랫폼 ns 12개 · SA/role `eso-platform`. **함정 주석의 정본**(나머지 vault store 3장은 이 파일을 가리킨다) |
| `clustersecretstore-vault-dev.yaml` | vault provider · `jt-dev` · SA/role `eso-dev` |
| `clustersecretstore-vault-prod.yaml` | vault provider · `jt-prod` · SA/role `eso-prod` |
| `clustersecretstore-vault-data.yaml` | vault provider · `data`·`identity` · SA/role `eso-data`(열거 접두 20개) |
| `clustersecretstore-k8s-data-ca.yaml` | **유일한 kubernetes provider** · `identity`·`jt-dev`·`jt-prod` · SA `eso-ca-reader`(Vault role 없음) |

> **머지 순서: G0 → G1 → G1p → admission PASS → G2**(설계 D6-⑤). G1p(`platform/policies`의 `allow-apiserver-webhook`에
> 노드 A flannel 출발 주소 추가)가 반영되고, 유효한 ESO CR의 `kubectl apply --dry-run=server`가
> **종료 코드 0 + `created (server dry run)`** 으로 통과한 것을 확인한 **뒤에** 이 PR을 연다.
> 이 확인 없이 머지하면 ESO webhook(`failurePolicy: Fail`)이 store 5장을 모두 거부해 Application이 실패한다.
> 거부는 **dry-run 단계**에서 나고 문면은 `one or more objects failed to apply (dry run)`이다. 이 Application spec에
> `retry`가 없어도 Argo auto-sync 기본 retry(limit 5 · 5s×2 · 최대 3m ≈ **2.5분**)가 자동 재시도하며, 그 뒤에는 같은
> revision을 다시 시도하지 않는다(`Skipping auto-sync: failed previous sync attempt`). 원인(정책·webhook Ready) 해소가
> 2.5분을 넘기면 `argocd app sync platform-secret-stores`(또는 빈 커밋)로 재개한다.
> **G2 머지 = 즉시 자동 sync = ESO가 Vault에 로그인하기 시작한다**(감사 로그가 늘어난다 — §1 마지막 불릿).

- **이 저장소에 비밀은 없다.** 이 디렉터리의 6개 파일에는 토큰·키·OCID가 한 건도 없다. store는 *어디서 어떤 신원으로
  읽는지*만 적고, 값은 Vault와 ns `data`의 Secret에 있다.
- 이 디렉터리에는 **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — `ClusterSecretStore`는 클러스터 범위
  객체라 `metadata.namespace`가 찍히면 Argo가 영구 OutOfSync로 본다(`kustomization.yaml` 머리 주석).
- 로컬 재현(리뷰어용, helm **불필요**):
  ```bash
  kustomize build platform/secret-stores | kubeconform -strict -ignore-missing-schemas -summary
  # 2026-09-18 실측: 5 resources found - Valid: 0, Invalid: 0, Skipped: 5
  # ⚠ 기본 카탈로그에 ESO CRD 스키마가 없어 **5장 전부 Skipped**다 — 이 명령만으로는 아무것도 검증되지 않는다.
  #   CRD에서 뽑은 스키마를 -schema-location으로 넘기면 Valid 5 / Skipped 0이 되고 필수 필드(`role` 등) 누락은 잡힌다.
  #   다만 그때도 **키 오타는 잡히지 않는다**(CRD의 openAPIV3Schema에 additionalProperties가 없어 -strict가 작동하지
  #   않는다 — 2026-09-18 실측: `mountPathh: typo`가 Valid 1). 실질 방어선은 `tests/validate.sh`의 **검사 9**다(§2).
  ```

---

## 0. 역할과 하지 않는 일

**이 디렉터리가 만드는 것**(= 로컬 렌더 결과 5장. 정본은 계약 `gitops-repo.md` §ClusterSecretStore 5개 표):

| store | provider | 참조 허용 ns(`conditions.namespaces`) | 인증 주체(SA, ns `external-secrets`) | Vault role |
|---|---|---|---|---|
| `vault-platform` | vault(kv v2, mount `kv`) | 플랫폼 12개 — `kube-system` `argocd` `vault` `external-secrets` `cert-manager` `cnpg-system` `data` `identity` `monitoring` `system-upgrade` `cloudflared` `reloader` | `eso-platform` | `eso-platform` — `kv/{data,metadata}/platform/*` read |
| `vault-dev` | vault | `jt-dev` | `eso-dev` | `eso-dev` — `kv/{data,metadata}/dev/*` read |
| `vault-prod` | vault | `jt-prod` | `eso-prod` | `eso-prod` — `kv/{data,metadata}/prod/*` read |
| `vault-data` | vault | `data` · `identity` | `eso-data` | `eso-data` — **열거 경로 20개만**(env 와일드카드 금지) |
| `k8s-data-ca` | **kubernetes**(`remoteNamespace: data`) | `identity` · `jt-dev` · `jt-prod` | `eso-ca-reader` | **없음** — ns `data`의 Role/RoleBinding으로 동작 |

- 플랫폼 ns 12개 = `network-policy.md` §네임스페이스 표 14개 − `jt-dev` − `jt-prod`.
- `data`·`identity`에는 `vault-platform`과 `vault-data`가 **둘 다** 걸린다: 환경 무관 공유 비밀은 `vault-platform`
  (`platform/` 접두), env 스코프 비밀은 `vault-data`(열거 접두)로 읽는다. 어느 쪽도 `kv/{env}/*` 전체를 열지 않는다.
- Vault role 이름 = 인증에 쓰는 **SA 이름과 같다**. 정본은 모노레포 `infra/vault/roles.tf`·`policies.tf`(T044 적용분)다.

**이 디렉터리가 만들지 "않는" 것**

1. ESO 오퍼레이터 본체·CRD·`eso-*` SA 5개·`eso-ca-reader` RBAC → `platform/external-secrets/`.
   SA와 Role을 저쪽에 남긴 이유는 store 검증이 SA TokenRequest를 필요로 하고, ns `data`는 policies가 먼저 만들기 때문이다.
2. ExternalSecret → 원본 `secrets/<ns>/`, 적용 `platform/secrets/`(G3). 이 디렉터리에는 ES가 한 장도 없다.
3. NetworkPolicy·Namespace → `platform/policies/`. store가 쓰는 경로(egress → `vault` 8200, kube-api 6443)는
   그쪽에 이미 선언돼 있다.
4. RBAC 축소(`rbac.serviceAccountTokenCreate: false` + `rbac-token-create.yaml`) → **G2r 단독 PR**(§4).

**왜 `platform-external-secrets`와 다른 Application인가 = health 격리**(설계 D2 + §3.5). Argo CD 3.5.2에는
`ClusterSecretStore`의 내장 health Lua가 있어 `Ready=False`를 **Degraded**로 판정하고, `argocd-cm`의 Application health
Lua가 child의 health를 root(app-of-apps)로 전파한다. store는 Vault가 살아 있어야 Ready인데 Vault는 ESO보다 뒤 wave다.
한 Application에 두면 Vault가 불가한 동안 **ESO Application 자체가** Degraded가 된다(그러면 ESO의 생존 신호를 잃는다).
분리하면

1. `platform-external-secrets`는 store 상태와 무관하게 Healthy로 남고,
2. store 5장만 단독으로 revert할 수 있으며(§3),
3. ESO webhook이 Ready가 된 뒤에 CR이 적용되므로 첫 sync의 admission 순환이 사라진다.

**⚠ "root가 이 wave에서 기다린다"는 틀리다.** 전파되는 것은 health이고, root **health**는 Degraded가 된다(하네스
`argo-1` FAIL). 그러나 root **sync**는 이 Application CR을 처음 만드는 operation에서 그 wave task가 Degraded로 실패할 뿐,
10초 뒤 첫 retry부터는 `ApplyOutOfSyncOnly=true`가 이미 만들어진 in-sync CR을 걸러내 **다음 wave로 진행한다**. 뒤 wave까지
연속 실패로 retry 5회(10s×2, 최대 3m ≈ 310초)가 소진돼도 실패한 wave의 CR은 이미 생성돼 있어 보통 root는
`Synced/Degraded`로 끝나고 수동 조치가 필요 없다 — CR이 미생성으로 남은 경우에만 `argocd app sync root`나 새 커밋으로
재개한다. 분리의 이득은 "root가 멈추는 것을 막는 것"이 아니라 **ESO Application의 health를 store와 떼어 놓는 것**이다.
(Argo CD v3.5.2 소스 판독 — `gitops-engine/pkg/sync/sync_context.go` · `controller/appcontroller.go`. **라이브 미실측
VD-11**이라 게이트로 쓰기 전에는 실측이 필요하다.)

---

## 1. Ready 판정

**합격 조건은 세 겹이다.** status·reason만 보면 가장 위험한 오설정(첫 불릿)을 놓친다.

| # | 보는 것 | 합격 문면 | 이것만 잡는 것 |
|---|---|---|---|
| ① | `status.conditions[Ready].status` | 5행 모두 `True` | Vault 불가 · 인증 실패 · 권한 부족 |
| ② | 같은 condition의 `reason` | 5행 모두 `Valid` | **`k8s-data-ca`의 `ValidationUnknown`**(SSRR/SSAR 호출 자체 실패) |
| ③ | vault store 4장의 **spec** `…auth.kubernetes.serviceAccountRef.namespace` | 4행 모두 `external-secrets` | **referent auth 가짜 PASS** — ①②로는 못 잡는다. **머지 전에는 `validate.sh` 검사 9.2(`CSS-auth-referent`)가 CI에서 강제한다** |

store별 ①② 기대값(전부 같다):

| store | 기대 `status` | 기대 `reason` |
|---|---|---|
| `vault-platform` | `True` | `Valid` |
| `vault-dev` | `True` | `Valid` |
| `vault-prod` | `True` | `Valid` |
| `vault-data` | `True` | `Valid` |
| `k8s-data-ca` | `True` | `Valid` |

명령은 §2에 있다(①② = `custom-columns`, ③ = `jsonpath` 또는 렌더 grep).

- **⚠ `namespace`를 생략한 vault store는 상태로 구분되지 않는다 — 진짜 가짜 PASS다.**
  `auth.kubernetes.serviceAccountRef.namespace`가 없으면 ClusterSecretStore는 'referent auth'가 되어 ESO가
  **로그인을 한 번도 하지 않은 채** `Ready=True` · `reason=Valid` · `message "store validated"`가 된다. 정상 store와
  status·reason·message가 **전부 같다.** vault provider는 `ValidationUnknown`을 내지 않는다
  (`providers/v1/vault/validate.go`의 유일한 Unknown 반환이 `err=nil`이라 컨트롤러가 `ReasonStoreValid`로 찍는다).
  그래서 방어선은 상태가 아니라 ⓐ **`validate.sh` 검사 9.2 `CSS-auth-referent`**(원본 파일 + 렌더 결과를 둘 다 보고,
  required check `validate`로 CI에서 머지를 막는다 — 이 디렉터리의 1차 방어선이다) ⓑ 라이브 spec 확인(§2 ③)
  ⓒ Vault 감사 로그의 role별 login 유무 셋이다. (ESO 2.10.0 소스 판독 — **라이브 미실측 VD-2**.)
- **`ValidationUnknown`이 나올 수 있는 store는 `k8s-data-ca` 하나뿐이고, 나오면 불합격이다.** kubernetes provider는
  SelfSubjectRulesReview/SelfSubjectAccessReview 호출 **자체가** 실패할 때(x509 · 401 · 6443 경로) `(Unknown, err)`를
  돌려주고 그때만 `Ready=True / reason=ValidationUnknown`이 된다. 즉 이 값은 "namespace 누락" 신호가 아니라
  "`k8s-data-ca`가 API 서버에 못 닿았다" 신호다.
- `namespace`를 적은 vault store는 검증 때 **실제로 로그인**한다: TokenRequest(audience `vault`, 만료 600초) →
  `auth/kubernetes/login` → `lookup-self`. 다만 그 증거는 status가 아니라 **Vault 감사 로그의 role별 login 기록**이다.
- 실패 메시지별 원인 — store의 `status.message`는 대개 `unable to create client`(reason `InvalidProviderConfig`,
  `Ready=False`)로만 찍힌다. **상세 문면은 `kubectl describe clustersecretstore <name>`의 Events 또는 ESO 로그**에서 본다.
  | 로그·메시지 조각 | 원인 | 손대는 곳 |
  |---|---|---|
  | `invalid audience (aud) claim: audience claim does not match any expected audience`(403) | ESO `audiences` 오기·누락. Vault가 TokenReview **전에** aud 클레임을 먼저 검사한다 | store의 `audiences` 또는 `infra/vault/roles.tf` |
  | `Vault is sealed`(HTTP 503 — 연결은 성립한다. `publishNotReadyAddresses: true`) | init 전(첫 배포 · PVC `data-vault-0` 재생성 — 런북 `vault-unseal.md` §1 해석표 1행·§4) 또는 수동 seal(§1 해석표 3행: 60초 뒤 재조회 → 지속이면 §3) | Vault 상태(`seal-status`) |
  | `connection refused` · `i/o timeout` · `context deadline exceeded` | Vault 미기동·CrashLoopBackOff(재시작 중 seal 설정 실패 = KMS 미도달·인가·값 오류 — 런북 §1 해석표 4행·§3), 또는 egress 경로 | Vault 파드 → `platform/policies` |
  | `Unauthorized` · `permission denied` | role 바인드(SA 이름·ns) 또는 정책 경로 불일치 | `infra/vault/roles.tf`·`policies.tf` |
  | **vault store 4장**: `cannot request Kubernetes service account token for service account "eso-<x>": cannot find secrets bound to service account: "eso-<x>"` | TokenRequest가 거부돼 레거시 SA Secret 경로로 폴백했는데 그 Secret도 없다(eso-* SA는 automount false) = **G2r을 잘못 좁힌 것** | 즉시 revert(§4) |
  | **`k8s-data-ca`**: `cannot create service account token: … serviceaccounts/token` | 같은 원인의 kubernetes provider 쪽 문면 | 즉시 revert(§4) |
  | sync 실패: `one or more objects failed to apply (dry run)` | ESO webhook 미Ready 또는 정책(G1p) 미반영 — admission 거부 | 머지 순서 박스 |
  옛 문면 `jwt valid for audience(s) … but wanted …`는 JWT가 이미 `vault`를 담고 있는데 apiserver TokenReview의
  `status.audiences`만 어긋나는 **TokenReview 단계**의 메시지다. role에 `audience="vault"`가 바인드된 이 배치에서는
  cap/jwt 검사가 항상 먼저 걸리므로 드물다.
- **`k8s-data-ca`의 Ready는 CA 미러가 동작한다는 증거가 아니다.** 이 provider의 Ready 판정은
  SelfSubjectRulesReview 1회이고 ESO는 `resourceNames`를 보지 않는다 — 대상 Secret이 아직 없어도(미러 ES는 T056)
  `Valid`가 된다. 미러 쪽 증거는 모노레포 하네스 `ca-1`이 따로 본다: 세 ns에 `pg-main-ca`가 하나도 없으면
  **`SKIP … until T056`** 이다(`tests/platform/cluster.tests.ps1` `ClusterAssert 'ca-1'`). T056 전에 `ca-1`이 **FAIL이면
  진짜 결함이다** — `ca.key` 유출이나 세 ns 중 일부 누락 같은 것이고, SKIP과 혼동하지 않는다.
- **`conditions.namespaces`는 Ready와 무관하다.** ES가 그 store를 쓸 때만 평가된다(거부 문면
  `denied by spec.condition`). 즉 store가 Ready인 것과 특정 ns에서 쓸 수 있는 것은 별개다 — **Ready 5행이 전부
  `True Valid`여도 참조 범위가 넓어진 것은 상태로 드러나지 않는다.** 그 범위는 머지 전에 `validate.sh` 검사 9.4가
  §0의 표와 정확 일치로 강제한다(`namespaceSelector`·`namespaceRegexes`·중복 ns·conditions 누락 전부 FAIL).
- **Vault가 불가하면 이 Application은 Degraded이고 root health도 Degraded가 된다(하네스 `argo-1` FAIL) — 그러나
  root sync는 여기서 기다리지 않는다.** 첫 operation에서 이 wave task만 실패하고, 10초 뒤 retry부터
  `ApplyOutOfSyncOnly=true`가 이미 만들어진 CR을 걸러내 다음 wave로 진행한다(§0의 ⚠ 문단 · Argo v3.5.2 소스 판독,
  라이브 미실측 VD-11). 콜드 부트스트랩의 **실제 대기 지점은 Vault wave**다 — init 전 Vault는 readinessProbe 실패로
  `Synced Progressing`이고 Progressing이 진짜 대기다(`platform/vault/README.md` §6).
  **Vault 시드는 Argo가 기다려 주지 않는다** — kv 시드 → store Ready → ES의 순서는 운영자 런북 절차로 보장한다(설계 R-21).
  이 상태를 없애려고 store를 지우거나 Application을 비활성화하지 않는다.
- store 재검증 주기는 기본 5분이고 Vault 토큰 캐시는 **꺼 둔 상태**다(설계 D9 — 토큰이 메모리에 상주하지 않는 쪽을 골랐다).
  그 대가로 store 하나당 시간당 수십 회 로그인이 발생하고 Vault 감사 로그(file+stdout)가 그만큼 늘어난다
  (**모델 추정이고 실측은 머지 뒤 §2의 Vault 로그 명령으로 한다**). 이것이 G2 머지의 라이브 영향이다.

---

## 2. 배포 뒤 확인

**머지 전 — 렌더 grep 체크리스트**(도구만 필요, 클러스터 불필요):

```bash
kustomize build platform/secret-stores | yq -N ea '[select(.kind=="ClusterSecretStore")] | length'
#   5
#   ⚠ `ea`(eval-all)가 필요하다. `yq -N '[…] | length'`는 문서마다 따로 평가해 `1`을 5줄 찍는다(2026-09-18 실측) —
#   "5장"을 확인한 것처럼 보이지만 실제로는 아무것도 세지 않은 것이다
kustomize build platform/secret-stores | yq -N 'select(.kind=="ClusterSecretStore") | .metadata.namespace'
#   5행 전부 null — 하나라도 값이 있으면 전역 namespace 변환기가 들어간 것이다(즉시 되돌린다)
kustomize build platform/secret-stores \
  | yq -N 'select(.spec.provider.vault != null) | .metadata.name + " " + .spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace + " " + (.spec.provider.vault.auth.kubernetes.serviceAccountRef.audiences | join(","))'
#   4행, 전부 "<store 이름> external-secrets vault"
#   눈으로 보는 용도다 — **판정은 아래 `validate.sh`의 검사 9.2가 한다**(§1 ③). namespace가 비면 여기서는
#   `vault-dev  vault`처럼 가운데가 빈 채로 나오고, 그 store는 라이브에서 로그인 없이 Ready=True/Valid가 되므로
#   상태로는 영영 드러나지 않는다. kubeconform은 CRD 스키마로도 못 잡는다(namespace는 필수 필드가 아니다 —
#   2026-09-18 실측 Valid 5/5)
kustomize build platform/secret-stores \
  | yq -N 'select(.spec.provider.kubernetes != null) | .spec.provider.kubernetes.remoteNamespace + " " + .spec.provider.kubernetes.server.url + " " + .spec.provider.kubernetes.server.caProvider.namespace'
#   data https://kubernetes.default.svc:443 external-secrets
kustomize build platform/secret-stores | yq -N 'select(.spec.provider.kubernetes != null) | .spec.provider.kubernetes.auth | keys'
#   [serviceAccount] 하나 — cert·token이 함께 보이면 CRD가 거부한다. audiences 키가 있으면 apiserver가 401이다
bash tests/validate.sh
#   검사 7.1이 Application ↔ 경로 ↔ 표를, 7.2가 새 디렉터리를 본다
#   **검사 9(CSS)가 이 디렉터리의 정본 게이트다** — required check `validate`에서 CI가 강제한다:
#     9.1 CSS-set        이름 5개 집합 · 위치 platform/secret-stores/ · metadata.namespace 금지
#     9.2 CSS-auth       vault 4장: serviceAccountRef.namespace(= §1 ③ referent auth 차단) · audiences · auth 키 ·
#                        mountPath · server/path/version · store↔SA/role 매핑
#     9.3 CSS-k8s        k8s-data-ca: auth 키 1개(serviceAccount) · audiences 금지 · CRD 기본값 3필드 명시 +
#                        remoteNamespace가 정확히 `data`(생략뿐 아니라 `default` 같은 오기도 잡는다)
#     9.4 CSS-conditions store 5장: conditions 1항목 · 키는 namespaces 하나(namespaceSelector·namespaceRegexes 금지) ·
#                        namespaces 집합 = §0의 표 · 중복 ns 금지. vault-platform의 12개는 네임스페이스 표
#                        14개 − jt-dev − jt-prod로 기계 유도한다(목록을 두 곳에 두지 않는다)
#   원본 파일과 렌더 결과를 **둘 다** 본다(렌더에서 값을 바꿔 우회하는 길도 막힌다)
```

**머지 전 — admission 프로브**(운영자, 클러스터 필요. G2 선행조건 D6-⑤):

```powershell
kubectl apply --dry-run=server -f platform/secret-stores/clustersecretstore-vault-platform.yaml
#   판정 = 종료 코드 0 + `created (server dry run)`. 이 확인이 통과해야 이 PR을 머지한다
#   ⚠ 머지 뒤에는 객체가 이미 있어 `configured`/`unchanged (server dry run)`이 나온다 — `created`는 머지 전 기대값이다
```

**머지 뒤 — agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다.**

```powershell
# ①② status · reason
kubectl get clustersecretstore -o 'custom-columns=N:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status,RE:.status.conditions[?(@.type=="Ready")].reason,M:.status.conditions[?(@.type=="Ready")].message'
#   5행 모두 R=True · RE=Valid (§1의 표). RE=ValidationUnknown은 불합격이고 k8s-data-ca에서만 나올 수 있다
#   ⚠ M 열에는 referent auth 가짜 PASS도 `store validated`가 찍힌다 — 이 명령으로는 ③을 대신할 수 없다
#   ⚠ `-o` 값 **전체**를 한 쌍의 작은따옴표로 감싼다. 쉼표로 이어진 토큰 중간에 따옴표를 열면 PowerShell이 그것을 벗기지
#   않고 kubectl에 그대로 넘겨 JSONPath가 깨지고 그 열이 전부 `<none>`으로 나온다 — "status 누락"으로 오판하기 쉽다
#   (같은 함정의 실측 기록은 `platform/external-secrets/README.md` §7).
# ③ 라이브 spec — vault store 4장의 serviceAccountRef.namespace
kubectl get clustersecretstore -o 'jsonpath={range .items[?(@.spec.provider.vault)]}{.metadata.name}{" "}{.spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace}{"\n"}{end}'
#   4행 전부 "<store> external-secrets". 이름만 있고 뒤가 비면 referent auth다(§1 첫 불릿) — 즉시 고친다
kubectl -n argocd get app platform-secret-stores -o jsonpath='{.status.sync.status} {.status.health.status}'
#   Synced Healthy. Vault가 sealed·미기동이면 Degraded가 정상이다(§1의 「Vault가 불가하면」 항목) — 그때는 Vault부터 본다
(kubectl -n argocd get app platform-secret-stores -o json | ConvertFrom-Json).status.resources |
  Select-Object kind,namespace,name,status,health
#   ClusterSecretStore 5행. namespace 열이 비어 있어야 한다(클러스터 범위 — 값이 찍히면 전역 변환기를 의심한다)
kubectl -n argocd get app platform-external-secrets -o jsonpath='{.status.health.status}'
#   Healthy — 분리의 목적이다(§0). 여기가 Degraded로 바뀌면 store가 저쪽에 섞여 들어간 것이다
```

**운영자 전용**(admin kubeconfig가 필요하거나 쓰기 성격):

```powershell
kubectl -n external-secrets logs deploy/external-secrets --since=10m `
  | Select-String 'connection refused|i/o timeout|context deadline|Unauthorized|permission denied|invalid audience|Vault is sealed|cannot find secrets bound|serviceaccounts/token'
#   0행. 걸리는 줄이 있으면 §1의 실패 메시지 표로 원인을 가른다
kubectl describe clustersecretstore <name>
#   status.message가 `unable to create client`뿐일 때 상세 문면은 여기 Events에 있다(§1)
# Vault 쪽 대조(감사 로그가 늘어난 것이 이 store들 때문인지) — 감사 장치가 `file_path=stdout`으로 켜져 있을 때만 보인다
#   (T044 런북 `docs/runbooks/vault-unseal.md` §9). 값은 HMAC이라 비밀이 그대로 찍히지 않는다
kubectl -n vault logs sts/vault --since=10m | Select-String 'auth/kubernetes/login'
```

---

## 3. 되돌리기

Application `platform-secret-stores`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.**
> git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다. 반대로 revert만 하면
> `prune: false` 때문에 store 객체는 남아 있다(그게 정상 동작이다).

1. revert PR 머지 → hard refresh. **되돌리는 범위에 따라 child의 모습이 다르다.**
   - **(a) 부분 revert**(파일 1장 + `kustomization.yaml`의 그 줄, 또는 디렉터리 내용 전부) → 디렉터리와 Application은
     남고 렌더만 줄거나 0이 된다 → child는 **OutOfSync**(5단계). 객체는 `prune: false`라 그대로 남는다.
   - **(b) 전체 revert**(`platform/secret-stores/` 디렉터리 + `clusters/oci-k3s/apps/platform-secret-stores.yaml` 삭제)
     → child는 소스가 사라져 **`ComparisonError`**, root는 child Application CR이 남아 **OutOfSync**(prune 대기)다.
     이때 child Application CR을 지우면 **finalizer cascade로 store 5장이 함께 지워진다** — 아래 2단계의 webhook 조건을
     먼저 만족시키고 `Delete=confirm` 때문에 `argocd.argoproj.io/deletion-approved` 어노테이션을 붙인 뒤에 한다.
2. 운영자가 수동 삭제 — **ESO webhook이 아직 Ready인 동안에 한다.** `failurePolicy: Fail`이 DELETE도 가로채므로
   webhook Deployment를 먼저 지우면 store를 지울 수 없게 된다(`platform/external-secrets/README.md` §4·§6).
   ```powershell
   kubectl delete clustersecretstore <name>     # 되돌릴 store 이름만. 5장을 한꺼번에 지울 이유는 보통 없다
   ```
3. **지금은 무해하다 — 이 store를 쓰는 ExternalSecret이 아직 한 장도 없다**(ES는 G3부터). store를 지워도 사라지는
   Secret이 없고, 되살리면 그대로 복구된다. G3 이후에는 그 store를 쓰는 ES가 동기화에 실패하므로(이미 만들어진
   Secret의 **값은 남는다** — 갱신이 멈출 뿐이다) 이 문장은 G3 머지와 함께 다시 읽어야 한다.
4. **store 1장 단위로 되돌릴 수 있다** — 파일을 5개로 나눈 이유다. 예를 들어 `k8s-data-ca`만 문제가 되면
   `kustomization.yaml`의 그 한 줄과 파일만 지우는 PR로 끝난다(나머지 4장은 건드리지 않는다).
5. revert만 하고 수동 삭제를 하지 않으면 Application은 **OutOfSync로 남는 것이 정상이다** — `prune: false`로 남긴
   store에 Argo 추적 어노테이션이 있어 렌더 0인 상태에서 'prune 대상'으로 보이기 때문이다(실제로 지워지지는 않는다).
   이 OutOfSync를 없애려고 ESO CRD를 지우지 않는다 — 지우면 클러스터의 **모든** ESO CR이 cascade 삭제된다
   (`platform/external-secrets/README.md` §6).

렌더 실패는 안전하다(`ComparisonError`, 클러스터 변경 0). `platform/external-secrets/`(G1)와 `platform/policies`(G1p)는
각각 별개 PR로 되돌린다.

---

## 4. 인계

- **G2r** — `rbac.serviceAccountTokenCreate: false` + `rbac-token-create.yaml`(ns `external-secrets`의 Role,
  `resourceNames: [eso-platform, eso-dev, eso-prod, eso-data, eso-ca-reader]`). ESO의 전역
  `serviceaccounts/token create`(= 클러스터 admin 등가 경로)를 닫는 **단독 PR**이다. G1·G2와 섞지 않는 이유는
  설계 D7 — 권한 축소가 섞이면 store Ready 실패의 원인을 분리할 수 없다.
  **게이트(VD-16): 머지 뒤 5분 안에 store 5장이 `True Valid`를 유지해야 한다.** 잘못 좁히면 1차 신호는
  **vault store 4장이 동시에 `Ready=False` + `InvalidProviderConfig`** 다. 로그·Events 문면은 두 갈래다 —
  vault store 4장은 `cannot find secrets bound to service account: "eso-<x>"`(TokenRequest 거부 뒤 레거시 Secret 폴백 실패),
  `k8s-data-ca`는 `cannot create service account token: … serviceaccounts/token`. 둘 중 하나라도 보이면 즉시 revert한다.
  G2r 전까지의 노출 창과 G2r 뒤에도 남는 잔여 위험은 `platform/external-secrets/README.md` §5에 있다(여기 옮겨 적지 않는다).
- **G3** — `platform/secrets/` + Application. 이 디렉터리의 store를 처음으로 **쓰는** 쪽이다(cert-manager DNS 토큰 ·
  cloudflared 터널 토큰). 그때부터 §3의 "무해하다"가 성립하지 않는다.
- **T056(CA 미러)** — `k8s-data-ca`를 쓰는 ExternalSecret은 **2종 5장**이다: `pg-main-ca` × `identity`·`jt-dev`·`jt-prod`,
  `jt-kafka-cluster-ca-cert` × `jt-dev`·`jt-prod` — 모두 `ca.crt`만 가져온다.
  그 전까지 이 store의 Ready는 미러 동작의 증거가 아니다(§1). `ca.key` 유출을 막는 통제는 store가 아니라 ES 쪽
  (`property: ca.crt`만 · `dataFrom` 금지, validate 3.4)과 `conditions.namespaces`다.
- **정적 게이트는 이미 있다 — `tests/validate.sh` 검사 9**(이번 G2에 함께 넣었다. 하위 코드는 §2의 `bash tests/validate.sh`
  블록). 저장소 쪽 ③(spec `serviceAccountRef.namespace`)은 9.2 `CSS-auth-referent`가, 참조 허용 ns(§0의 표)는
  9.4 `CSS-conditions-*`가, `remoteNamespace: data`는 9.3 `CSS-k8s-remote`가 required check `validate`에서 막는다.
  검사 9가 **보지 않는 것**은 라이브 status와 "그 조건이 실제로 어느 ES를 막았는지"다 — 그건 아래 하네스 몫이다
  (`tests/README.md` 한계 절).
- **하네스 `eso-1` 강화(G5)** — 지금의 `eso-1`(모노레포 `tests/platform/cluster.tests.ps1`)은 store **이름 집합 5개**와
  `Ready.status == True`만 본다(§1의 ①만). `reason == Valid` 전수를 **더한다** — `k8s-data-ca`의 SSRR/SSAR 호출 실패가
  만드는 `Ready=True / ValidationUnknown`을 잡는다(§1 ②). 라이브 spec(③)까지 하네스에서 볼지는 선택이다:
  gitops 쪽은 검사 9.2가 이미 막으므로, 하네스의 몫은 **git 밖에서 손댄 드리프트**(누군가 `kubectl edit`으로
  namespace를 지운 경우 — `selfHeal: true`가 되돌리지만 그 창에서는 로그인 없이 Valid로 보인다)를 잡는 것이다.
- **VD-2(선택, G2 직후)** — 원하면 `serviceAccountRef.namespace` 없는 임시 store 1장을 dry-run이 아니라 **실제로** 만들어
  status(`Ready`/`reason`/`message`)를 실측하고 즉시 삭제한다(운영자, webhook Ready 필요). 지금 §1의 서술은 ESO 2.10.0
  소스 판독이며 라이브로는 확인되지 않았다.
- **낡은 포인터 3곳(이번 PR에서 함께 고쳤다)** — `platform/vault/kustomization.yaml` · `platform/vault/README.md` §8의
  "ClusterSecretStore 5개 → `platform/external-secrets/`", `platform/policies/tests/externalsecret-assert-env.yaml`의
  "store 정의는 T045 `secrets/`". 셋 다 이 디렉터리(Application `platform-secret-stores`)를 가리키도록 바꿨다(주석·문서만).
- **노드 간 webhook 경로는 여전히 미실측이다** — 근거와 한계는 `platform/external-secrets/README.md` §4(D6-④).
  이 디렉터리는 정책을 만들지 않는다(§0).
