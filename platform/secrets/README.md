# platform/secrets/ — 운영자 절차 (T045 G3)

`secrets/<ns>/`에 있는 **ExternalSecret 원본을 클러스터로 배달하는 컴포넌트**다. 이 디렉터리에는 매니페스트가 한 장도 없다 —
`kustomization.yaml` 하나가 `../../secrets/<ns>`를 base로 끌어올 뿐이고, Application `platform-secrets`가 그 렌더 결과를 적용한다.
ExternalSecret의 **원본은 여기가 아니라 저장소 루트 `secrets/<ns>/`**(`../../secrets/README.md`)이고, 오퍼레이터 본체는
`../external-secrets/`, ClusterSecretStore 5장은 `../secret-stores/`가 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources`에 `../../secrets/<ns>` 줄만. helm 없음, 전역 `namespace:` 변환기 없음(ns가 둘 이상이다) |

> **머지 순서: G2 → G2r → (운영자) kv 시드 → G3.** 이 PR은 **Vault kv 시드(`kv/platform/cloudflare/dns-token`의 필드 `token`)가
> 끝난 뒤에만** 머지한다 — **2026-09-21 시드 완료**(필드 `token` version 1 · 되읽기 해시 일치). 시드 전에 머지하면 ES는
> `SecretSyncedError`가 되고 — 그때도 Secret의 **값·UID는 변경되지 않는다**(provider 조회가 실패하면 ESO는 값을 쓰지 않고
> return한다. 다만 그 전에 `reconcile.external-secrets.io/managed=true` 라벨 1개는 붙는다 — 메타데이터 PATCH · resourceVersion
> 변경) — 인수만 지연된다.
> 시드 값이 **라이브 Secret과 다르면** 그때는 조용히 덮어쓴다(`Retain`은 값 덮어쓰기를 막지 않는다). 그래서 머지 전에
> §2의 기준값(해시·UID)을 캡처하고, 머지 뒤 같은 창에서 비교한다.
> **G3 머지 = 즉시 자동 sync = 이 클러스터에서 ExternalSecret이 처음으로 생긴다** — `../secret-stores/README.md` §3의
> "store를 지워도 지금은 무해하다"는 이 머지와 함께 성립하지 않는다.

---

## 0. 역할과 하지 않는 일

**이 컴포넌트가 만드는 것**(= 로컬 렌더 결과):

| ns | ExternalSecret | 인수 대상 Secret(운영자 수동 생성분) | 소비자 |
|---|---|---|---|
| `cert-manager` | `cloudflare-dns-token` | `cloudflare-dns-token`(키 `api-token`, T042) | ClusterIssuer `letsencrypt-staging`·`letsencrypt-prod`의 DNS-01 solver |
| `cloudflared` | `cloudflared-tunnel` — **G4에서 추가한다(이 PR에는 없다)** | `cloudflared-tunnel`(키 `TUNNEL_TOKEN`, T039) | Deployment `cloudflared`(env) |

**범위(설계 D3 조건 1)**: 이 컴포넌트는 위 **ExternalSecret 2장까지만** 담는다.

- CA 미러 ExternalSecret(`pg-main-ca` × 3 ns · `jt-kafka-cluster-ca-cert` × 2 ns)은 **여기 두지 않는다** —
  원본(CNPG·Strimzi CA)이 생긴 뒤인 계약 §sync-wave 표의 `cnpg-databases`·`kafka-topics` 행 소유다(T056).
- **새 ExternalSecret을 추가할 때는 원본과 소비자의 wave를 먼저 확인한다.** 이 컴포넌트의 wave보다 **뒤에** 만들어지는
  원본(예: 오퍼레이터가 런타임에 만드는 CA Secret)을 여기서 읽으면 콜드 부트스트랩에서 영영 Ready가 되지 않는다.
  값의 출처가 Vault kv이고 소비자가 이 wave보다 뒤인 것만 여기 온다.

**이 컴포넌트가 만들지 "않는" 것**

1. ExternalSecret 원본 파일 → `secrets/<ns>/`. 여기로 **옮기지 않는다**: validate 3.2(scope↔위치)의 트리거가 파일 경로
   `^secrets/`라, 옮기는 순간 "store `vault-platform` + key 접두 `platform/`" 검사가 **조용히 꺼진다**.
2. ClusterSecretStore 5장 → `../secret-stores/`. 오퍼레이터 본체·CRD·`eso-*` SA → `../external-secrets/`.
3. **Secret 자체**. 이 저장소에 비밀은 없다. 값은 Vault kv에 있고, 라이브 Secret은 T042·T039에서 운영자가 만든 것을
   ESO가 **인수**한다(삭제·재생성이 아니다 — §1).
4. NetworkPolicy·Namespace → `../policies/`. ESO가 Vault·kube-api로 나가는 경로는 그쪽에 이미 선언돼 있다.

**왜 소비자 컴포넌트가 아니라 별도 Application인가(설계 D3 = B).** ESO의 admission webhook은 `failurePolicy: Fail`이다.
ExternalSecret을 `../cloudflared`·`../cert-manager-issuers`의 kustomization에 넣으면 webhook이 불가한 동안 그 Application의
sync **전체**가 실패한다 — **터널 Deployment 수정조차 Argo로 밀 수 없게 된다**. 분리의 효과는 장애 제거가 아니라
**소비자 배포와 ExternalSecret 적용 작업의 분리**다.

⚠ **Vault·ESO가 불가하면 이 Application은 Degraded이고 root health도 Degraded가 된다(하네스 `argo-1` FAIL) — 그것은
그대로다.** 다만 root **sync**는 이 wave에서 기다리지 않는다: 첫 operation에서 이 wave task만 실패하고, 10초 뒤 retry부터
`ApplyOutOfSyncOnly=true`가 이미 만들어진 CR을 걸러내 다음 wave로 진행한다(Argo CD v3.5.2 소스 판독 · 라이브 미실측 VD-11 —
`../secret-stores/README.md` §0). **kv 시드 순서는 Argo가 보장하지 않는다 — 런북 절차가 보장한다.**

---

## 1. 인수 판정 기준

인수는 **삭제 없이** 된다. ESO v2.10.0의 `applyOwnership`은 **다른 ExternalSecret**이 controller owner일 때만 거부하므로,
ownerReference가 없는 수동 Secret은 제자리에서 관리 대상이 된다(소스 판독 · 라이브 미실측 VD-3).
그래서 합격 조건은 "ES가 Ready"가 아니라 **네 겹**이다.

| # | 보는 것 | 합격 | 이것만 잡는 것 |
|---|---|---|---|
| ① | ES `status.conditions[Ready]` | `status=True` · `reason=SecretSynced` | Vault 불가 · 권한 부족 · 경로 오기 |
| ② | Secret `metadata.uid` | **인수 전후 동일** | 삭제 후 재생성(= 제자리 인수가 아니다) |
| ③ | Secret 값의 SHA-256 | **인수 전후 동일** | kv 값이 라이브 값과 다름(조용한 덮어쓰기) |
| ④ | Secret `metadata.ownerReferences` | **비어 있음** | `creationPolicy`가 Orphan이 아님(= ES 삭제 한 번으로 Secret GC) |

- ④가 걸리면 **ES를 지우지 말고** 매니페스트를 먼저 확인한다. 그 상태에서 `kubectl delete externalsecret`을 하면 Secret이
  함께 GC된다(`deletionPolicy: Retain`은 ownerRef GC를 막지 못한다).
- ⚠ **`Orphan`이어도 인수 시 `secret.Data`는 비워졌다가 다시 채워진다**(Merge 계열이 아닌 정책의 공통 동작). 그래서 ③이
  "값이 같아야 한다"가 아니라 "**kv 값 = 라이브 값이어야 한다**"는 뜻이다 — 다르면 인수 순간 kv 값으로 덮인다.
  같은 이유로 **ES가 매핑하지 않은 키는 인수 순간 삭제된다**(2026-09-21 DR1 드릴 실측: 테스트 Secret의 `extra` 키가 사라졌다).
  이 Secret은 T042 절차상 `api-token` 1개뿐이고, 머지 전 캡처 블록(§2)이 그 전제를 확인한다.
- 실패 메시지별 원인 — **condition의 message는 일반 문구**(`could not get secret data from provider`)뿐이다. 아래 조각은
  `kubectl describe externalsecret <name>`의 **Events**(reason `UpdateFailed`)와 ESO 로그에만 나온다(ESO 2.10.0 소스 판독).
  | 메시지 조각 | 원인 | 손대는 곳 |
  |---|---|---|
  | `Secret does not exist` | **kv 경로에 데이터가 없다**(시드 누락 · 경로 오기 · kv soft-delete). ⚠ K8s Secret 얘기가 아니다 — vault provider의 `NoSecretError` 문면이다 | 운영자 시드(OP1) · `remoteRef.key` |
  | `cannot find secret data for key: "token"` | kv **필드 이름**이 다르다(정본은 `token`) | kv 필드 또는 `remoteRef.property` |
  | `could not get ClusterSecretStore "vault-platform"` | store가 아직 없다 = wave 순서 위반 | `../secret-stores/` Application 상태 |
  | `ClusterSecretStore "vault-platform" is not ready` | Vault sealed·미기동 등으로 store가 `Ready=False`(flood gate 기본 on) | Vault → `../secret-stores/README.md` §1 |
  | `denied by spec.condition` | store의 `conditions.namespaces`에 그 ns가 없다 | `../secret-stores/` (§0의 표) |
  | `permission denied` · `403` (Vault) | Vault 정책 경로가 `kv/{data,metadata}/platform/*`를 덮지 않는다 | 모노레포 `infra/vault/policies.tf` |
  | `no matches for kind "ExternalSecret"` | ESO CRD가 없다(오퍼레이터 미설치·CRD 삭제) | `../external-secrets/` |
  | sync 실패: `one or more objects failed to apply (dry run)` | ESO webhook 미Ready — admission 거부 | `../external-secrets/README.md` §4 |
  | Events `owned by another ExternalSecret` (reason `SecretOwnedByOther`) | **다른 ExternalSecret**이 이미 그 Secret의 owner다 | 중복 ES를 먼저 찾는다(§3) |
- **provider별 함정**: 이 컴포넌트의 ES는 전부 vault provider(store `vault-platform`)를 쓴다. `remoteRef.key`에 `kv/` 접두를
  붙이지 않는다 — store가 `path: kv` + `version: v2`라 ESO가 `kv/data/`를 붙인다(붙이면 validate 3.1이 막는다).
  kv v2의 **필드 이름**은 `data.data` 아래 키이고(`property`), 경로 이름과 다르다.
  `k8s-data-ca`(kubernetes provider)는 이 컴포넌트가 쓰지 않는다 — CA 미러는 T056이다.

---

## 2. 배포 뒤 확인

**머지 전 — 렌더 grep 체크리스트**(도구만 필요, 클러스터 불필요):

```bash
kustomize build platform/secrets | yq -N ea '[select(.kind=="ExternalSecret")] | length'
#   1  (G4 뒤에는 2). ⚠ `ea`(eval-all)가 필요하다 — `yq -N '[…] | length'`는 문서마다 따로 평가해 1을 여러 줄 찍는다
kustomize build platform/secrets \
  | yq -N 'select(.kind=="ExternalSecret") | .metadata.namespace + " " + .metadata.name + " cp=" + .spec.target.creationPolicy + " dp=" + .spec.target.deletionPolicy + " rp=" + .spec.refreshPolicy + " ri=" + .spec.refreshInterval'
#   cert-manager cloudflare-dns-token cp=Orphan dp=Retain rp=Periodic ri=5m
#   ⚠ cp=Owner가 보이면 머지하지 않는다(ES가 지워지는 어떤 경로에서든 Secret이 GC된다 — `Retain`도 막지 못한다)
kustomize build platform/secrets \
  | yq -N 'select(.kind=="ExternalSecret") | .spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name + " " + (.spec.data[] | .secretKey + "<-" + .remoteRef.key + ":" + .remoteRef.property)'
#   ClusterSecretStore/vault-platform api-token<-platform/cloudflare/dns-token:token
#   ⚠ key에 `kv/` 접두가 붙어 있으면 안 된다(§1 provider 함정)
kustomize build platform/secrets | yq -N 'select(.kind=="ExternalSecret") | .spec.target.template'
#   metadata: {}  — template이 없으면 ESO가 ES의 라벨·어노테이션(Argo tracking-id 포함)을 Secret에 전부 복사한다
bash tests/validate.sh
#   검사 3(ES 규약 ①–⑦)이 store·경로·키 접두를, 7.1이 Application ↔ 경로 ↔ 표를, 7.2가 새 디렉터리를,
#   **7.3(WAVE-secrets-base)이 단일 소유와 "죽은 secrets/<ns>"를** 본다(§3)
```

**머지 전 — 기준값 캡처**(운영자, 클러스터 필요. **머지 뒤 게이트와 같은 PowerShell 창을 유지한다**):

```powershell
$ErrorActionPreference = 'Stop'
# ⚠ DNS 토큰 값 자체를 세션 변수로 남기지 않는다(존 전체 DNS 쓰기 권한). 비교는 해시로만 한다 —
#    복구용 원본은 PM과 Vault kv에 있다.
$sha     = { param($s) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$s))) }
# 가드 ⓐ — **아직 인수 전인가.** 인수가 이미 일어난 뒤에 캡처하면 preHash = 덮인 값이라 게이트 ③이 가짜 PASS를 낸다.
#   ESO는 인수 첫 단계에서 managed 라벨을 반드시 붙인다(provider 조회 실패·인수 해제 뒤에도 라벨은 남는다).
$m = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.metadata.labels.reconcile\.external-secrets\.io/managed}'
if ($LASTEXITCODE -ne 0) { throw 'managed 라벨 조회 실패 — 판정 불가' }
if (-not [string]::IsNullOrWhiteSpace($m)) { throw '이미 ESO가 손댄 Secret이다 — 기준값으로 쓸 수 없다(이전 시도·인수 해제 뒤에도 라벨은 남는다. PM 원본과 대조한다)' }
# 가드 ⓑ — **키 집합.** ES가 매핑하지 않은 키는 인수 순간 삭제된다(2026-09-21 DR1 실측). 값은 출력하지 않는다.
$keys = kubectl -n cert-manager get secret cloudflare-dns-token -o 'go-template={{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
if ($LASTEXITCODE -ne 0) { throw '키 목록 취득 실패' }
if (-not [string]::Equals((@($keys) -join ','), 'api-token', [StringComparison]::Ordinal)) { throw "api-token 외의 키가 있다($(@($keys) -join ',')) — 인수하면 삭제된다. ES 매핑에 추가하기 전에는 머지하지 않는다" }
$b64     = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.data.api-token}'
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($b64)) { throw '인수 전 값 취득 실패' }
$preHash = & $sha $b64
Remove-Variable b64
$preUid  = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.metadata.uid}'
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($preUid)) { throw '인수 전 UID 취득 실패' }
```

**머지 뒤 게이트 — ①②③④를 한 번에**(같은 창):

```powershell
$ErrorActionPreference = 'Stop'
try {
  $r = kubectl -n cert-manager get externalsecret cloudflare-dns-token -o 'jsonpath={.status.conditions[?(@.type=="Ready")].reason}'
  if ($LASTEXITCODE -ne 0) { throw 'ES 상태 취득 실패 — 판정 불가' }
  if (-not [string]::Equals($r, 'SecretSynced', [StringComparison]::Ordinal)) { throw "ES reason=$r — provider 실패면 Secret의 값·UID는 미변경이다(managed 라벨만 붙는다). Events·ESO 로그를 §1의 표로 가른다" }
  $post = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.data.api-token}'
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($post)) { throw '인수 후 값 취득 실패' }
  $postHash = & $sha $post
  Remove-Variable post
  $postUid = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.metadata.uid}'
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($postUid)) { throw '인수 후 UID 취득 실패' }
  $own = kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.metadata.ownerReferences}'
  if ($LASTEXITCODE -ne 0) { throw 'ownerReferences 조회 실패 — 판정 불가(빈 문자열을 "없음"으로 읽지 않는다)' }
  if (-not [string]::Equals($preHash, $postHash, [StringComparison]::Ordinal)) { throw '값이 바뀌었다 — G4로 가지 않는다. kv 재확인' }
  if (-not [string]::Equals($preUid,  $postUid,  [StringComparison]::Ordinal)) { throw 'UID가 바뀌었다 = 제자리 인수가 아니다 — G4로 가지 않는다' }
  if (-not [string]::IsNullOrWhiteSpace($own))                                 { throw 'ownerReferences가 붙었다 — creationPolicy가 Orphan이 아니다. ES를 지우지 말고 매니페스트 확인' }
  'OK 값 불변 · UID 불변 · ownerRef 없음'
}
finally {
  Remove-Variable post, postHash, postUid, own, r -ErrorAction SilentlyContinue
}
```

- ⚠ `-o` 값 **전체**를 한 쌍의 작은따옴표로 감싼다. 쉼표·중괄호로 이어진 토큰 중간에 따옴표를 열면 PowerShell이 그것을
  벗기지 않고 kubectl에 그대로 넘겨 JSONPath가 깨지고 결과가 비어 나온다 — "상태 없음"으로 오판하기 쉽다
  (같은 함정의 실측 기록은 `../external-secrets/README.md` §7).

**이어서 보는 것 — agent-view kubeconfig(읽기 전용)로 가능한 명령은 이것뿐이다**:

```powershell
kubectl -n argocd get app platform-secrets -o jsonpath='{.status.sync.status} {.status.health.status}'
#   Synced Healthy. Vault가 sealed·미기동이면 Degraded가 정상이다(§0의 ⚠) — 그때는 Vault부터 본다
```

**운영자 전용**(admin kubeconfig 필요 — `agent-view`는 core Secret을 읽지 못하고 `cert-manager.io` 규칙도 없다.
`../policies/rbac-agent-view.yaml` · `../cert-manager-issuers/README.md` §7):

```powershell
kubectl -n cert-manager get secret cloudflare-dns-token -o 'jsonpath={.metadata.labels}{"|"}{.metadata.annotations}'
#   ES의 라벨·어노테이션(특히 argocd.argoproj.io/tracking-id)이 **복사되지 않았는지** 본다 — `target.template.metadata: {}`의 목적이다
#   ⚠ Orphan 인수에서 ESO가 직접 붙이는 정상 항목은 **둘**뿐이다 — `reconcile.external-secrets.io/managed`(라벨) ·
#     `…/data-hash`(어노테이션). 이 둘은 "복사"가 아니라 관리 표시다
#   ⚠ `…/created-by`(라벨)가 보이면 **creationPolicy가 Owner로 조정된 것**이다(ESO 2.10.0 `applyOwnership`은 Owner일 때만
#     이 라벨을 붙이고 그 밖에는 지운다) — §1 ④와 같이 **ES를 지우지 말고** 매니페스트를 확인한다
kubectl get clusterissuer letsencrypt-staging letsencrypt-prod -o 'custom-columns=N:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status'
#   둘 다 True 유지. DNS 토큰을 잘못 덮어썼다면 여기가 아니라 **다음 챌린지**에서 드러난다(§5)
```

**staging 능동 검증(선택, 운영자)** — prod 재발급은 **금지**다(중복 한도 소비).
임시 Certificate(ns `kube-system` · issuer `letsencrypt-staging` · dnsNames `t045-probe.joshuatech.dev`)를 만들어 5분 안에
`Ready=True`가 되면 Certificate와 그 Secret을 지운다. 실패 문면이 Cloudflare `Authentication error`이면 **kv 값이 틀린 것**이다.

---

## 3. 단일 소유와 Argo 고아 경고

**단일 소유(설계 D3 조건 2)**: 각 ExternalSecret은 Application `platform-secrets` **하나만** 관리한다.
소비자 컴포넌트(`../cert-manager-issuers`·`../cloudflared`)의 kustomization은 `secrets/<ns>`를 base로 포함하지 않는다.
두 Application이 같은 ES를 각자 적용하면 소유권이 갈려 서로의 변경을 되돌리고, 한쪽 revert가 다른 쪽 selfHeal에 덮인다.

- **정적 방어선**: `tests/validate.sh` 검사 **7.3 `WAVE-secrets-base`** — 네 갈래를 본다.
  ⓐ `secrets/` 아래**와 배달자 자신(`platform/secrets`)**을 base로 가질 수 있는 kustomization은 배달자 하나뿐이고,
  절대 경로·저장소 밖으로 나가는 경로는 위치 판정 불가로 FAIL이다. ⓑ `secrets/**` **파일**의 ExternalSecret과 같은 이름이
  배달자 밖 소스(파일 복사본 · 전이 base · helm 렌더)에도 있으면 FAIL. ⓒ `secrets/**` 파일의 ES가 `platform/secrets` **렌더**에
  없으면 **죽은 선언**으로 FAIL(`secrets/` 바로 아래 파일 · `sub/` 하위 · ns kustomization 미등록 파일이 여기 걸린다 —
  kustomize가 있을 때만 돈다). ⓓ `secrets/*`를 가리키는 Application은 금지(multi-source의 두 번째 source 포함)이고,
  배달자가 있으면 `source.path == platform/secrets`인 Application이 있어야 한다. 디렉터리 단위 완전성은 실제 저장소 루트에서
  항상 본다. **보지 않는 것**은 `../../tests/README.md` 「한계」 절에 있다.
  ⚠ 오늘 이 검사의 실행 수단은 **PR 전 로컬 실행**이다 — CI 배선 상태와 그 근거는 `../../tests/README.md` 「CI 배선 상태」
  (한 곳에만 적는다).
- **라이브 확인**:
  ```powershell
  kubectl -n cert-manager get externalsecret cloudflare-dns-token -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
  #   platform-secrets:… 로 시작해야 한다(다른 Application 이름이 보이면 소유권이 갈린 것이다)
  kubectl -n argocd get app platform-cert-manager-issuers -o 'jsonpath={range .status.resources[*]}{.group}/{.kind} {end}'
  #   external-secrets.io 항목 0건 — 소비자 Application이 ES를 들고 있지 않다는 확인
  ```

**Argo 고아(orphaned) 경고는 정상이다.** 두 Secret은 `creationPolicy: Orphan`이라 ownerReference가 없고, git에 선언된
객체도 아니므로 AppProject `platform`의 `orphanedResources.warn: true`가 계속 경고로 표시한다. **드리프트가 아니다** —
이 경고를 없애려고 Secret을 지우거나 정책을 `Owner`로 바꾸지 않는다(§1 ④).

---

## 4. 콜드 부트스트랩 수동 선행

클러스터를 처음부터 다시 올릴 때 root는 `platform-cloudflared`까지 **한 번에 가지 못한다** — root가 실제로 기다리는 곳은
**Vault wave**(init·unseal 전에는 readinessProbe 실패로 `Synced Progressing`)이고, 그것이 사람 손이다.
**kv 시드는 Argo가 기다려 주지 않는다**(§0) — 시드는 root의 진행과 무관하다. 그래서 순서는 이렇다.

1. 터널 Secret `cloudflared-tunnel`과 cloudflared를 **T039 절차대로 수동으로 먼저 올린다**(그것이 운영자의 유일한
   SSH·kubectl 경로다). cert-manager DNS 토큰도 T042 절차대로 수동 Secret으로 먼저 둔다.
2. Vault init·unseal(런북 `vault-unseal.md`) → kv 시드 → store `vault-platform` Ready 확인.
3. 이 컴포넌트는 **unseal 뒤 시드와 무관하게 sync된다.** 시드 전에는 ES가 `SecretSyncedError`이고 Secret의 값·UID는
   미변경이며(managed 라벨만 붙는다),
   시드가 끝나면 다음 조정에서 ESO가 두 Secret을 **인수**한다(`Orphan`이라 삭제·재생성이 아니다).
   즉 **시드가 곧 인수의 방아쇠**이므로 기준값(§2) 캡처는 **시드 전에** 한다.

즉 **ExternalSecret은 부트스트랩의 시작점이 아니라 인수 단계**다. 이 문단은 `../cloudflared/README.md`에도 같은 문면으로 둔다(G5).

---

## 5. 되돌리기 — 인수 해제 절차

Application `platform-secrets`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.** git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다.
> 반대로 **revert만 하면 ES 객체가 남아 조정이 계속된다** — `prune: false`라 파일 revert만으로는 인수가 해제되지 않는다.

**값이 문제인 경우**(잘못된 값이 들어갔다): 먼저 **kv를 정정한다**. Secret만 수동으로 고치면 다음 갱신(≤5분)에 다시 덮인다.
값 정정 절차는 시드 블록이 아니라 런북의 **정정 블록**을 쓴다(시드 블록은 덮어쓰기를 거부하는 것이 설계다).

**인수 뒤의 토큰 회전도 같은 규칙이다 — kv가 먼저다.** 새 토큰을 발급했으면 ⓐ kv를 정정하고 ⓑ ESO가 ≤5분 안에 Secret에
반영하는 것을 확인한다(`data-hash` 어노테이션 변화·소비자 동작). **Secret만 바꾸면** ESO가 다음 주기에 kv의 **옛(폐기된) 값**으로
되돌리고, ClusterIssuer는 `Ready=True`로 남아 **다음 DNS-01 갱신에서야** 실패한다(무증상 구간이 길다).
소비자 README(`../cert-manager-issuers/README.md` §1)의 수동 Secret 절차는 **콜드 부트스트랩과 인수 해제 뒤 복구 전용**이다.

**인수 자체를 해제해야 하는 경우**(ES는 없애고 Secret은 남긴다) — 두 ES 공통 절차다.

1. revert PR을 머지한다(먼저 하지 않으면 `selfHeal`이 ES를 다시 만든다).
2. **Git 제거가 Argo에 반영됐는지 확인한다** — `platform-secrets`의 리비전이 revert 커밋이고, 해당 ES가 `requiresPruning`으로
   표시된다(`prune: false`라 실제로 지워지지는 않는다).
3. `kubectl -n cert-manager delete externalsecret cloudflare-dns-token`.
   **전제: ESO 컨트롤러 Running · webhook Ready**(DELETE도 `failurePolicy: Fail`로 가로챈다 — `../external-secrets/README.md` §4).
   webhook이 죽어 있으면 삭제가 **거부**되고 ES는 활성 그대로라 조정(kv 값 덮어쓰기)이 계속된다 — 해제된 것이 아니다.
   컨트롤러만 죽어 있으면 ES의 ESO finalizer(`externalsecrets.external-secrets.io/externalsecret-cleanup`) 때문에
   Terminating에서 멈춘다(그동안은 조정도 없다). `Retain`이라 복구 뒤 finalizer가 정리될 때도 Secret은 지워지지 않는다.
   어느 쪽이든 **ESO를 먼저 복구한다**(소스 판독 · 라이브 미실측).
4. **Secret 잔존·UID·값(해시) 불변을 확인한다** — `Orphan`이므로 GC되지 않는다(§1 ②③④와 같은 명령).
5. 값이 깨졌으면 stdin JSON으로 복구한다. 복구 값의 출처는 kv 또는 PM이다 — 이 창에 토큰 값을 보관하지 않는다.
6. 소비자 파드를 1개씩 교체한다. cert-manager는 챌린지 순간에만 이 Secret을 읽으므로 대개 불필요하다
   (cloudflared는 env를 시작 시 1회만 읽으므로 G4에서는 필요하다).

**revert PR의 모양을 못박는다**(2단계 판정이 성립해야 하기 때문이다).

- **ES가 2장 이상일 때**: `kustomization.yaml`의 그 한 줄과 해당 `secrets/<ns>/`만 지운다.
- **ES가 1장뿐인 지금(G3)**: 그 줄을 지우면 `resources:`가 비어 kustomize가 `kustomization.yaml is empty`로 **렌더에 실패한다**
  (실측: kustomize v5.8.1 rc=1 · 검사 1도 FAIL). 대신 **`resources: []`로 바꾼다.** `platform/secrets/` 디렉터리 ·
  Application 파일 · `WAVE_TABLE` 행은 그대로 둔다 — 그래야 2단계의 판정 기준(리비전 = revert 커밋 · ES `requiresPruning`)이
  성립한다. 이 저장소에는 `resources: []` 뼈대로 운영한 선례가 많다(T041 시점의 `platform/*`).
- **PR 전체를 revert하는 경우**: `platform/secrets/`가 git에서 사라지므로 child는 `ComparisonError: app path does not exist`가
  되고 **리비전 비교는 할 수 없다**(manifest revision이 갱신되지 않는다 — Argo v3.5.2 소스 판독 · 라이브 미실측). 판정은
  `requiresPruning` 표시 하나로 하고, 뒤처리는 ES를 `kubectl delete`한 뒤 Application CR을 수동 삭제하는 순서다
  (cascade는 `Delete=false` 때문에 ES를 지우지 않는다 — 머리 박스와 같은 사실).

렌더 실패 자체는 안전하다(클러스터 변경 0). 갱신 창(≈2026-11-08) 밖이면 DNS 토큰의 공백·지연은 무해하다 —
cert-manager는 챌린지 때만 읽는다. **터널 토큰은 같은 판단이 성립하지 않는다**(G4에서 다시 읽는다).

---

## 6. 인계

- **G4(터널 토큰)** — `secrets/cloudflared/` + 이 `kustomization.yaml`에 한 줄. **잠금 위험 단계**라 별도 PR이고,
  게이트는 이 문서 §1의 ①②③④와 같다. 소비자 파드는 1개씩 교체한다.
- ~~**DR1 드릴**~~ **완료(2026-09-21)** — 테스트용 ExternalSecret/Secret(ns `external-secrets` · kv `platform/test/t045-probe` ·
  git 미경유)으로 실측했다: 인수 = **UID 불변 · 값 불변 · ownerReferences 없음 · `…/managed` 라벨 부착**,
  **ES에 열거되지 않은 키는 인수 순간 삭제**, ES 삭제 뒤 Secret 잔존(같은 UID·값), **Secret 삭제 뒤 재생성 302초**
  (직전 refreshTime 03:28:25Z → 새 creationTimestamp 03:33:25Z = 정확히 5분 주기 — 즉시가 아니다. **VD-20 해소**).
- **T056(CA 미러)** — `k8s-data-ca`를 쓰는 ExternalSecret 2종 5장은 이 컴포넌트가 아니라 `cnpg-databases`·`kafka-topics`가
  소유한다(§0 범위).
- **하네스(모노레포 G5)** — `eso-2`(ES Ready·reason) · `eso-3`(store ↔ ns ↔ key 접두 scope) · `eso-4`(ES spec의
  `creationPolicy == Orphan` 회귀 — **G5에서 신설 예정이고 그전까지 이 회귀를 보는 자동 검사는 없다**).
  ⚠ **Secret의 UID·ownerReferences·값은 하네스가 보지 않는다**(agent-view는 core Secret을 읽지 못한다) — §2의 게이트(운영자)가
  유일한 확인이다. 이 저장소의 검사 7.3은 **선언**만 본다 — 라이브에서 누가 그 ES를 적용했는지는 §3의 tracking-id로 본다.
- **T048(계획된 교란 창, 선택)** — "ESO webhook 장애 중에도 터널 Deployment를 독립적으로 변경할 수 있다"의 라이브 드릴.
  webhook을 실제로 내리는 것은 `selfHeal` 때문에 PR로만 가능하므로 그 창으로 넘긴다. 구조 검증(소비자 Application의
  `status.resources`에 `external-secrets.io` 0건 · webhook `rules`가 ESO CR 3종뿐 · Deployment server-side dry-run)은 §3에서 한다.
