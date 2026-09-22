# platform/secrets/ — 운영자 절차 (T045 G3·G4)

`secrets/<ns>/`에 있는 **ExternalSecret 원본을 클러스터로 배달하는 컴포넌트**다. 이 디렉터리에는 매니페스트가 한 장도 없다 —
`kustomization.yaml` 하나가 `../../secrets/<ns>`를 base로 끌어올 뿐이고, Application `platform-secrets`가 그 렌더 결과를 적용한다.
ExternalSecret의 **원본은 여기가 아니라 저장소 루트 `secrets/<ns>/`**(`../../secrets/README.md`)이고, 오퍼레이터 본체는
`../external-secrets/`, ClusterSecretStore 5장은 `../secret-stores/`가 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `resources`에 `../../secrets/<ns>` 2줄만. helm 없음, 전역 `namespace:` 변환기 없음(ns가 둘이다) |

> **머지 순서: G2 → G2r → (운영자) kv 시드 → G3 → G4.** 각 PR은 그 PR이 읽는 **Vault kv 경로의 시드가 끝난 뒤에만** 머지한다
> — `kv/platform/cloudflare/dns-token`·`kv/platform/cloudflare/tunnel` 둘 다 필드 `token`, **2026-09-21 시드 완료**
> (version 1 · 되읽기 해시 일치). 시드 전에 머지하면 ES는 `SecretSyncedError`가 되고 — 그때도 Secret의 **값·UID는 변경되지
> 않는다**(provider 조회가 실패하면 ESO는 값을 쓰지 않고 return한다. 다만 그 전에
> `reconcile.external-secrets.io/managed=true` 라벨 1개는 붙는다 — 메타데이터 PATCH · resourceVersion 변경) — 인수만 지연된다.
> 시드 값이 **라이브 Secret과 다르면** 그때는 조용히 덮어쓴다(`Retain`은 값 덮어쓰기를 막지 않는다). 그래서 머지 전에
> 기준값(해시·UID)을 캡처하고, 머지 뒤 같은 창에서 비교한다(§2).
> **G3 머지 = 즉시 자동 sync = 이 클러스터에서 ExternalSecret이 처음으로 생겼다** — `../secret-stores/README.md` §3의
> "store를 지워도 지금은 무해하다"는 그 머지와 함께 성립하지 않는다.
> ⚠⚠ **G4 머지는 잠금 위험 단계다.** 이 PR이 더하는 ExternalSecret은 **SSH·K8s API의 유일한 경로**인 터널 커넥터의 자격
> (`cloudflared/cloudflared-tunnel`)을 인수한다. 값이 같으면 실행 중 컨테이너에는 영향이 없지만, 값이 달랐다면 증상은
> **다음 파드 교체 또는 컨테이너 재시작**에서 나타난다(env는 컨테이너가 시작할 때마다 다시 읽힌다 — §1 ⑤).
> 그래서 머지는 **사용자 입회 + 열어 둔 노드 A SSH 세션 + 2차 break-glass(OCI 자격)
> 확인** 아래에서만 하고, 머지 뒤 판정과 드릴을 끝낼 때까지 그 창을 닫지 않는다(§2 「터널 ES」).

---

## 0. 역할과 하지 않는 일

**이 컴포넌트가 만드는 것**(= 로컬 렌더 결과):

| ns | ExternalSecret | 인수 대상 Secret(운영자 수동 생성분) | 소비자 |
|---|---|---|---|
| `cert-manager` | `cloudflare-dns-token` | `cloudflare-dns-token`(키 `api-token`, T042) | ClusterIssuer `letsencrypt-staging`·`letsencrypt-prod`의 DNS-01 solver |
| `cloudflared` | `cloudflared-tunnel`(G4) | `cloudflared-tunnel`(키 `TUNNEL_TOKEN`, T039) | Deployment `cloudflared`(env — **컨테이너 시작 시마다** 다시 읽힌다) |

**범위(설계 D3 조건 1)**: 이 컴포넌트는 위 **ExternalSecret 2장까지만** 담는다.

- CA 미러 ExternalSecret(`pg-main-ca` × 3 ns · `jt-kafka-cluster-ca-cert` × 2 ns)은 **여기 두지 않는다** —
  원본(CNPG·Strimzi CA)이 생긴 뒤인 계약 §sync-wave 표의 `cnpg-databases`·`kafka-topics` 행 소유다(T056).
- **새 ExternalSecret을 추가할 때는 원본과 소비자의 wave를 먼저 확인한다.** 이 컴포넌트의 wave보다 **뒤에** 만들어지는
  원본(예: 오퍼레이터가 런타임에 만드는 CA Secret)을 여기서 읽으면 콜드 부트스트랩에서 영영 Ready가 되지 않는다.
  값의 출처가 Vault kv이고 소비자가 이 wave보다 뒤인 것만 여기 온다.

**이 컴포넌트가 만들지 "않는" 것**

1. ExternalSecret 원본 파일 → `secrets/<ns>/`. 여기로 **옮기지 않는다**: validate 3.2(scope↔위치)의 트리거가 파일 경로
   `^secrets/`라, 옮기는 순간 "store `vault-platform` + key 접두 `platform/`" 검사가 **조용히 꺼진다**.
   같은 이유로 **배달자와 `secrets/<ns>`의 kustomization에 변환 키를 넣지 않는다**(`patches`·`replacements`·`transformers`·
   `namePrefix`·`helmCharts` …). 변환 키가 있으면 원본 파일은 그대로인 채 **Argo가 실제로 적용하는 렌더에서만**
   store·`remoteRef`·`creationPolicy`가 바뀐다 — 검사 7.3이 이 구조를 막고, 3.2는 배달자 렌더도 함께 본다
   (계약 §validate.yml 4 「(T045 G4) 배달자는 base를 묶기만 한다」).
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
ownerReference가 없는 수동 Secret은 제자리에서 관리 대상이 된다(소스 판독 · 2026-09-21 DR1 드릴과 G3 인수로 실측).
그래서 합격 조건은 "ES가 Ready"가 아니라 **네 겹(①–④)**이고, 여기에 **⑥(ESO가 실제로 썼다는 양성 증거)**을 더한다.
터널 토큰에는 **⑤(파드 서명)**까지 붙는다.

| # | 보는 것 | 합격 | 이것만 잡는 것 |
|---|---|---|---|
| ① | ES `status.conditions[Ready]` | `status=True` · `reason=SecretSynced` | Vault 불가 · 권한 부족 · 경로 오기 |
| ② | Secret `metadata.uid` | **인수 전후 동일** | 삭제 후 재생성(= 제자리 인수가 아니다) |
| ③ | Secret 값의 SHA-256 | **인수 전후 동일** | kv 값이 라이브 값과 다름(조용한 덮어쓰기) |
| ④ | Secret `metadata.ownerReferences` | **비어 있음** | `creationPolicy`가 Orphan이 아님(= ES 삭제 한 번으로 Secret GC) |
| ⑤ | **터널 전용** — `cloudflared` 파드의 이름·`restartCount` | **인수 전후 동일** | 인수가 파드를 건드림(= 자격이 바뀐 채 커넥터가 교체됐을 수 있다) |
| ⑥ | Secret의 `reconcile.external-secrets.io/data-hash` 어노테이션 | **존재한다** | ESO가 실제로 **쓰지 않은** 통과(managed 라벨은 provider 조회 **전에도** 붙는다 — 라벨만으로는 양성 증거가 아니다) |

- ⑤는 "아무 일도 일어나지 않았다"의 확인이다. 인수는 Secret만 만지고 파드는 만지지 않는다(이 Deployment에는 reloader
  어노테이션이 없다). 파드 이름이 그대로여도 **`restartCount`가 올랐다면 그 컨테이너는 이미 현재 값을 읽었다** —
  env는 컨테이너가 시작할 때마다 다시 읽히기 때문이다. 값이 달랐다면 새 파드·재시작된 컨테이너는 이미 새 자격으로 떠 있다.
  `rollout restart`는 어느 경우에도 하지 않는다(§2 「터널 ES」).
- ⑥은 ①의 보강이다. `…/managed` 라벨은 ESO가 provider를 조회하기 **전에** 붙일 수 있으므로 "손댔다"는 뜻일 뿐이고,
  **데이터를 썼다**는 양성 증거는 `…/data-hash`다(정본 블록 `g4-adopt.ps1`도 이것을 본다). 인수 뒤 회전·복구에서도
  이 어노테이션의 변화가 "ESO가 반영했다"의 신호다(⑨ · §5).
- ④가 걸리면 **ES를 지우지 말고** 매니페스트를 먼저 확인한다. 그 상태에서 `kubectl delete externalsecret`을 하면 Secret이
  함께 GC된다(`deletionPolicy: Retain`은 ownerRef GC를 막지 못한다).
- ⚠ **`Orphan`이어도 인수 시 `secret.Data`는 비워졌다가 다시 채워진다**(Merge 계열이 아닌 정책의 공통 동작). 그래서 ③이
  "값이 같아야 한다"가 아니라 "**kv 값 = 라이브 값이어야 한다**"는 뜻이다 — 다르면 인수 순간 kv 값으로 덮인다.
  같은 이유로 **ES가 매핑하지 않은 키는 인수 순간 삭제된다**(2026-09-21 DR1 드릴 실측: 테스트 Secret의 `extra` 키가 사라졌다).
  두 Secret은 절차상 키가 하나씩이고(T042 `api-token` · T039 `TUNNEL_TOKEN`), 머지 전 캡처가 그 전제를 확인한다(§2).
  키가 더 있으면 ES의 `data[]`에 **전부 열거하기 전에는 머지하지 않는다**.
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
#   2  (G4 뒤 = 범위의 최대치. 3이 나오면 §0의 범위를 벗어난 것이다)
#   ⚠ `ea`(eval-all)가 필요하다 — `yq -N '[…] | length'`는 문서마다 따로 평가해 1을 여러 줄 찍는다
kustomize build platform/secrets \
  | yq -N 'select(.kind=="ExternalSecret") | .metadata.namespace + " " + .metadata.name + " cp=" + .spec.target.creationPolicy + " dp=" + .spec.target.deletionPolicy + " rp=" + .spec.refreshPolicy + " ri=" + .spec.refreshInterval'
#   cert-manager cloudflare-dns-token cp=Orphan dp=Retain rp=Periodic ri=5m
#   cloudflared cloudflared-tunnel cp=Orphan dp=Retain rp=Periodic ri=5m
#   ⚠ cp=Owner가 보이면 머지하지 않는다(ES가 지워지는 어떤 경로에서든 Secret이 GC된다 — `Retain`도 막지 못한다)
kustomize build platform/secrets \
  | yq -N 'select(.kind=="ExternalSecret") | .spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name + " " + (.spec.data[] | .secretKey + "<-" + .remoteRef.key + ":" + .remoteRef.property)'
#   ClusterSecretStore/vault-platform api-token<-platform/cloudflare/dns-token:token
#   ClusterSecretStore/vault-platform TUNNEL_TOKEN<-platform/cloudflare/tunnel:token
#   ⚠ key에 `kv/` 접두가 붙어 있으면 안 된다(§1 provider 함정). 터널 쪽 secretKey는 소비자 env 이름과 같은 `TUNNEL_TOKEN`이다
kustomize build platform/secrets | yq -N 'select(.kind=="ExternalSecret") | .spec.target.template'
#   metadata: {}  (2줄) — template이 없으면 ESO가 ES의 라벨·어노테이션(Argo tracking-id 포함)을 Secret에 전부 복사한다
kustomize build platform/secrets \
  | yq -N 'select(.kind=="ExternalSecret") | .metadata.name + " " + .metadata.annotations["argocd.argoproj.io/sync-options"]'
#   cloudflare-dns-token Delete=false,Prune=false
#   cloudflared-tunnel Delete=false,Prune=false
#   ⚠ 이 어노테이션이 빠지면 Application cascade가 ES를 지운다 — 검사 3은 어노테이션을 보지 않는다(`../../tests/README.md` 한계)
git diff --stat origin/main -- platform/cloudflared/deployment.yaml platform/cloudflared/kustomization.yaml
#   출력 없음 — 터널 PR은 소비자 **매니페스트**를 건드리지 않는다(렌더 바이트 동일, README만 바뀐다).
#   ⚠ 여기에 한 줄이라도 나오면 "인수만 하는 PR"이 아니다 — 파드 교체가 섞여 판정 ⑤(파드 불변)가 성립하지 않는다
bash tests/validate.sh
#   검사 3(ES 규약 ①–⑦)이 store·경로·키 접두를(3.2는 배달자 렌더도 함께 본다), 7.1이 Application ↔ 경로 ↔ 표를,
#   7.2가 새 디렉터리를, **7.3(WAVE-secrets-base)이 단일 소유·"죽은 secrets/<ns>"·배달자와 `secrets/<ns>`의 변환 키 금지**를
#   본다(§3 · §0의 2번). 검사 3이 보지 않는 필드는 위 yq 체크와 라이브 하네스 `eso-4`가 나눠 본다
```

**머지 전 — 기준값 캡처 · DNS 토큰(G3)**(운영자, 클러스터 필요. **머지 뒤 게이트와 같은 PowerShell 창을 유지한다**):

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

**머지 뒤 게이트 · DNS 토큰(G3) — ①②③④를 한 번에**(같은 창):

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

**터널 ES(G4) — 실행 블록의 정본은 여기가 아니다.** **정본**은 모노레포 `specs/003-platform-foundation/design/t045-blocks/g4/`의
**`g4-adopt.ps1`**(기준값 캡처 · 머지 대기 · 인수 판정, **클러스터 쓰기 0건**) · **`g4-drill.ps1`**(별도 입회 후 파드 1개 교체) ·
**`g4-restore.ps1`**(인수 해제 뒤 필요한 값 복구 1건), 그리고 런북 `docs/runbooks/bootstrap.md` §3 T045 절이다.
머지·드릴·복구 쓰기는 운영자가 실행한다. adopt는 끝에서 비밀이 아닌 **값 해시·UID**를 출력하고 종료하며, 드릴을 자동으로 잇지 않는다.
같은 블록을 이 저장소에 복사해 두지 않는다 — 두 사본이 어긋나면 **잠금 위험 단계에서 어느 쪽이 정본인지 가릴 시간이 없다.**
여기에는 **판정 항목만** 둔다.

- **머지 전(사전 조건).** 하나라도 실패하면 머지하지 않고, 이 창은 드릴이 끝날 때까지 닫지 않는다.
  ⓐ 별도 창에 노드 A 대화형 SSH 세션이 열려 있다(1차 break-glass = 그 세션의 `sudo k3s kubectl`. kubectl은 호출마다 새 dial이라
  열어 둔 터널이 kubectl의 안전망은 아니다) · ⓑ 2차 break-glass 자격(OCI, 운영자 프로파일)이 지금 동작한다 ·
  ⓒ PM에 터널 토큰 항목이 있다(값 출력 금지) · ⓓ 기준값 캡처: **값 해시 · UID · 키 집합이 `TUNNEL_TOKEN` 하나 ·
  `reconcile.external-secrets.io/managed` 라벨과 `…/data-hash` 어노테이션이 **둘 다 없음**(아직 인수 전이라는 증거) ·
  `cloudflared` 파드 이름과 `restartCount`**.
- **머지 뒤 판정 — §1의 여섯 겹(①–⑥) + 단일 소유 둘(⑦⑧)이 모두 성립해야 PASS다.** ①–⑥의 번호는 §1의 것을 그대로 쓴다.
  ① ES `cloudflared/cloudflared-tunnel`의 `Ready` reason이 `SecretSynced`다 · ② Secret UID가 불변이다 ·
  ③ Secret 값의 해시가 불변이다 · ④ `ownerReferences`가 비어 있다(**조회 실패의 빈 문자열을 "없음"으로 읽지 않는다**) ·
  ⑤ `cloudflared` 파드의 이름·`restartCount`가 불변이다 ·
  ⑥ Secret에 `reconcile.external-secrets.io/data-hash` 어노테이션이 있다(= ESO가 **실제로 썼다**는 양성 증거.
  `…/managed` 라벨만으로는 부족하다 — 그 라벨은 provider 조회 전에도 붙는다) ·
  ⑦ ES의 `argocd.argoproj.io/tracking-id`가 `platform-secrets`로 시작한다(§3) ·
  ⑧ `platform-cloudflared`의 `status.resources`에 `external-secrets.io` 항목이 **0건**이다(§3).
- **그 뒤 드릴(같은 창, 별도 실행·입회).** `g4-drill.ps1`에 adopt가 출력한 **값 해시·UID**를 입력한다. ES 동기화·`data-hash`·
  두 파드 Ready·break-glass를 다시 확인하고, 운영자가 **삭제할 파드 이름**을 타자한 뒤 삭제 직전 값·UID·파드를 재확인한다.
  삭제 대상은 시작 시각이 가장 늦은 파드 1개다(동률은 이름 Ordinal). ES 생성 뒤 시작한 파드가 보이면 경고와 `second` 확인을 받는다.
  **이 블록을 두 번 실행하면 두 커넥터가 모두 교체되어 옛 값을 든 커넥터의 안전망이 사라질 수 있다.** 자동 재실행하지 않는다.
  삭제 대상이 사라지고 파드가 정확히 2개 · 새 파드 Ready · 로그에 `Registered tunnel connection` · 남은 파드 불변 ·
  **창 A SSH 세션 재확인** · `ssh ssh-a hostname` 성공 ·
  `kubectl get nodes` 2 Ready를 본다. 실패하면 **남은 파드는 건드리지 않고** 복구 절차로 간다. **`rollout restart`는 하지 않는다.**
- **판정이 깨졌을 때.** ①이 아니면 Secret은 대개 손대지 않은 상태다(provider 실패는 값·UID 미변경 — §1의 표로 원인을 가른다).
  ②③이 깨졌으면 **파드를 재시작하지 않되, 복구를 미루지 않는다.**
  ⚠ **안전망에는 시한이 있다** — env는 컨테이너가 시작할 때마다 다시 읽히고, 이 Deployment의 liveness(`/ready` 10s × 6)는
  edge 단절이 ≈60초 이어지면 **두 커넥터를 파드 교체 없이** 재시작시킨다. 그때 두 컨테이너가 모두 틀린 값을 읽는다.
  그러므로 ②③이 깨지면 **지체 없이 kv를 정정하고**(복구 1순위 · §5), 그다음이 인수 해제다.
  그동안 **노드 재부팅 · SUC Plan · drain · eviction을 유발하는 작업을 하지 않는다**(제자리 재시작도 같은 결과를 낸다).
  ④가 걸리면 **ES를 지우지 않는다**(§1 ④ — 그 상태의 삭제는 Secret을 함께 GC한다).
  ⑥만 없고 ①②③이 성립하면 ESO가 아직 쓰지 않은 것이다 — 값은 그대로이므로 파드를 건드리지 말고 ES status·Events를 본다.

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
  터널 ES도 **같은 두 가지**를 본다(ns `cloudflared`의 ES tracking-id · Application `platform-cloudflared`의
  `status.resources`). 그 둘은 G4 판정의 ⑥⑦이고, 실행 블록의 정본은 §2가 가리키는 곳이다.
  `platform-cloudflared`의 `external-secrets.io` 0건은 "ESO webhook 장애 중에도 터널 Deployment를 독립적으로 밀 수 있다"의
  **구조 쪽 근거**이기도 하다(§0의 분리 이유 · 라이브 드릴은 §6의 T048).

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

즉 **ExternalSecret은 부트스트랩의 시작점이 아니라 인수 단계**다. 같은 문면을 `../cloudflared/README.md` ⑨에도 둔다(G4에서 넣었다).

⚠ Vault를 **스냅샷으로 복원**하는 경로(모노레포 런북 `vault-unseal.md` §7)에는 시드 단계가 없다 — `snapshot restore`가 곧
덮어쓰기의 방아쇠다(≤5분 안에 **스냅샷 시점의 kv 값**으로 덮인다). 복원 **전에** 라이브 터널 Secret의 값 해시 · UID ·
파드 서명을 캡처한다(§2의 항목). 복원 뒤 해시가 달라졌으면 **파드를 건드리지 말고 곧바로 kv를 정정한다**
(스냅샷 뒤에 회전한 적이 있으면 그 값은 이미 폐기된 자격이다 — `../cloudflared/README.md` ⑨).

---

## 5. 되돌리기 — 인수 해제 절차

Application `platform-secrets`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.** git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다.
> 반대로 **revert만 하면 ES 객체가 남아 조정이 계속된다** — `prune: false`라 파일 revert만으로는 인수가 해제되지 않는다.

**값이 문제인 경우**(잘못된 값이 들어갔다): 먼저 **kv를 정정한다**. Secret만 수동으로 고치면 다음 갱신(≤5분)에 다시 덮인다.
값 정정은 시드 블록이 아니라 모노레포 `specs/003-platform-foundation/design/t045-blocks/kv-correct.ps1`
(정정 블록 — 런북 `bootstrap.md` §3 T045 절이 가리킨다)을 쓴다(시드 블록은 덮어쓰기를 거부하는 것이 설계다).

**인수 뒤의 토큰 회전도 같은 규칙이다 — kv가 먼저다.** 새 토큰을 발급했으면 ⓐ kv를 정정하고 ⓑ ESO가 ≤5분 안에 Secret에
반영하는 것을 확인한다(`data-hash` 어노테이션 변화·소비자 동작). **Secret만 바꾸면** ESO가 다음 주기에 kv의 **옛(폐기된) 값**으로
되돌리고, ClusterIssuer는 `Ready=True`로 남아 **다음 DNS-01 갱신에서야** 실패한다(무증상 구간이 길다).
소비자 README(`../cert-manager-issuers/README.md` §1)의 수동 Secret 절차는 **콜드 부트스트랩과 인수 해제 뒤 복구 전용**이다.

**터널 토큰 회전(T084)은 여기에 ⓒ가 하나 더 붙는다 — 파드 교체다.** 이 Deployment에는 reloader 어노테이션이 없고
T046 감시 대상에도 넣지 않으므로(그 수동성이 안전장치다), kv 정정과 ESO 반영만으로는 **실행 중 커넥터가 옛 토큰을 계속 쓴다**.
새 값을 실제로 쓰게 하려면 파드를 **1개씩** 교체하고, 앞쪽이 Ready로 등록된 것을 본 뒤 다음 파드로 넘어간다.
`rollout restart`로 한꺼번에 돌리지 않는다. 반대로 **Secret만 새 값으로 바꾸면** 다음 주기(≤5분)에 kv의 옛 값으로 되돌아가고,
증상은 그때가 아니라 **다음 파드 교체 또는 컨테이너 재시작**에서야 나타난다.
⚠ 터널 회전의 **Cloudflare 쪽 순서와 시작 전 전제**(Refresh의 비가역성 · 연결 삭제 시점)는 여기 복제하지 않는다 —
정본은 `../cloudflared/README.md` ⑨이고, 그 절을 먼저 읽는다.

**인수 자체를 해제해야 하는 경우**(ES는 없애고 Secret은 남긴다) — 두 ES 공통 절차다.

1. revert PR을 머지한다(먼저 하지 않으면 `selfHeal`이 ES를 다시 만든다).
2. **Git 제거가 Argo에 반영됐는지 확인한다** — `platform-secrets`의 리비전이 revert 커밋이고, 해당 ES가 `requiresPruning`으로
   표시된다(`prune: false`라 실제로 지워지지는 않는다).
3. `kubectl -n cert-manager delete externalsecret cloudflare-dns-token`
   (터널 쪽은 `kubectl -n cloudflared delete externalsecret cloudflared-tunnel` — **평시 금지, 해제·비상 시에만**).
   **전제: ESO 컨트롤러 Running · webhook Ready**(DELETE도 `failurePolicy: Fail`로 가로챈다 — `../external-secrets/README.md` §4).
   webhook이 죽어 있으면 삭제가 **거부**되고 ES는 활성 그대로라 조정(kv 값 덮어쓰기)이 계속된다 — 해제된 것이 아니다.
   컨트롤러만 죽어 있으면 ES의 ESO finalizer(`externalsecrets.external-secrets.io/externalsecret-cleanup`) 때문에
   Terminating에서 멈춘다(그동안은 조정도 없다). `Retain`이라 복구 뒤 finalizer가 정리될 때도 Secret은 지워지지 않는다.
   어느 쪽이든 **ESO를 먼저 복구한다**(소스 판독 · 라이브 미실측).
4. **Secret 잔존·UID·값(해시) 불변을 확인한다** — `Orphan`이므로 GC되지 않는다(§1 ②③④와 같은 명령).
5. 값이 깨졌으면 stdin JSON으로 복구하고 **해시를 다시 대조한다**. 복구 값의 출처는 **PM**이다(해시를 기준값과 대조한다) —
   값이 **kv 때문에** 깨진 경우 kv는 원본이 아니다. kv를 쓰려면 먼저 해시를 대조한다. 이 창에 토큰 값을 보관하지 않는다.
6. **값을 복구한 경우에만** 소비자 파드를 1개씩 교체한다. cert-manager는 챌린지 순간에만 이 Secret을 읽으므로 대개 불필요하다.
   **cloudflared의 env는 컨테이너가 시작할 때마다 다시 읽히므로, 값을 복구했다면 파드를 1개씩 교체해야 지금 도는 커넥터에
   반영된다** — 그전까지 실행 중 컨테이너는 마지막 시작 시점의 값으로 동작한다(값이 틀려도 즉시 끊기지는 않지만,
   liveness·OOM·재부팅에 의한 재시작이 일어나면 그때 현재 값을 읽는다 — 안전망에는 시한이 있다).

**revert PR의 모양을 못박는다**(2단계 판정이 성립해야 하기 때문이다).

- **ES가 2장인 지금(G4 뒤)**: 되돌릴 쪽의 **그 한 줄과 해당 `secrets/<ns>/`만** 지운다. 나머지 한 줄이 남으므로 렌더는 깨지지 않고,
  다른 ES의 인수는 그대로 간다(터널만 해제 · DNS만 해제가 각각 성립한다 — 잠금 위험 단계를 남의 사정으로 건드리지 않는다).
  **G4 PR 전체 revert(GitHub Revert 버튼)도 이 모양과 같다** — `platform/secrets/`는 남고 렌더도 깨지지 않으며 2단계 판정
  (리비전 = revert 커밋 · ES `requiresPruning`)이 그대로 성립한다. 잠금 위험 단계에서 가장 빠른 수단이다.
  ⚠ 다만 **이 README와 `../cloudflared/README.md` ⑨의 터널 해제 문면도 함께 되돌아간다**(G3 판에는 터널 쪽
  `kubectl -n cloudflared delete externalsecret` 줄이 없다). `prune: false`라 라이브 ES는 3단계가 끝날 때까지 남으므로,
  3–6단계를 마칠 때까지 **되돌리기 전 판(또는 정본 `g4-restore.ps1`)을 열어 둔다**.
- **마지막 1장까지 지워야 할 때**(= G3 시점처럼 `resources:`가 비는 경우): 그 줄을 지우면 kustomize가
  `kustomization.yaml is empty`로 **렌더에 실패한다**(실측: kustomize v5.8.1 rc=1 · 검사 1도 FAIL). 대신 **`resources: []`로
  바꾼다.** `platform/secrets/` 디렉터리 · Application 파일 · `WAVE_TABLE` 행은 그대로 둔다 — 그래야 2단계의 판정 기준
  (리비전 = revert 커밋 · ES `requiresPruning`)이 성립한다. 이 저장소에는 `resources: []` 뼈대로 운영한 선례가 많다
  (T041 시점의 `platform/*`).
- **G3 PR(#28)까지 되돌려 `platform/secrets/` 자체가 사라지는 경우**: child는 `ComparisonError: app path does not exist`가
  되고 **리비전 비교는 할 수 없다**(manifest revision이 갱신되지 않는다 — Argo v3.5.2 소스 판독 · 라이브 미실측). 판정은
  `requiresPruning` 표시 하나로 하고, 뒤처리는 ES를 `kubectl delete`한 뒤 Application CR을 수동 삭제하는 순서다
  (cascade는 `Delete=false` 때문에 ES를 지우지 않는다 — 머리 박스와 같은 사실).

렌더 실패 자체는 안전하다(클러스터 변경 0). 갱신 창(≈2026-11-08) 밖이면 DNS 토큰의 공백·지연은 무해하다 —
cert-manager는 챌린지 때만 읽는다. **터널 토큰은 같은 판단이 성립하지 않는다.** 실행 중 컨테이너는 마지막 시작 시점의 값으로
동작하므로 ES·Secret의 공백이 **즉시** 끊지는 않지만, 그 창에서 **새 컨테이너는 뜨지 못한다** — Secret이 없으면 새 파드도,
**제자리 재시작(liveness·OOMKill·노드 재부팅)도** `CreateContainerConfigError`가 되고, ESO에 의한 재생성은 다음 주기
refresh까지 최대 5분 걸린다(2026-09-21 DR1 실측 302초).
노드 재부팅·eviction·업그레이드·edge 단절이 그 창에 겹치면 커넥터가 둘 다 사라질 수 있다. 그래서 터널 쪽 revert는 값 복구를
먼저 확인하고, 파드 교체는 그다음이다.

---

## 6. 인계

- ~~**G4(터널 토큰)**~~ **이 PR** — `secrets/cloudflared/`(ES 1장 + kustomization) + 이 컴포넌트 `kustomization.yaml`에 한 줄.
  **잠금 위험 단계**라 별도 PR이고, 판정은 §1의 ①②③④ + **⑤(파드 서명)** + **⑥(data-hash)** + §2의 ⑦⑧(tracking-id ·
  소비자 Application `external-secrets.io` 0건)이다. `platform/cloudflared/`의 매니페스트는 **한 글자도 바뀌지 않는다**
  (렌더 바이트 동일) — 소비자는 전과 같은 이름·키의 Secret을 계속 읽는다. 드릴은 파드 **1개만** 교체이고
  `rollout restart`는 하지 않는다.
- **T084(터널 토큰 회전) · 남은 수동성** — 회전은 kv 정정 → ESO 반영(≤5분) → **파드 1개씩 교체** 순이다
  (전제와 Cloudflare 쪽 순서는 `../cloudflared/README.md` ⑨이 정본이다).
  reloader를 붙이지 않는 결정은 T046에서 유지한다 — 자동 재시작이 붙으면 **잘못된 kv 값이 두 커넥터를 동시에** 교체한다.
  **Cloudflare 쪽 단계(Refresh의 비가역성 · 10분 대기 · 연결 삭제 시점)는 T084 `secret-rotation.md`에서 실측해 확정한다**
  (지금 문면은 Cloudflare 문서 기준이고 라이브 미실측이다 — VD).
- ~~**DR1 드릴**~~ **완료(2026-09-21)** — 테스트용 ExternalSecret/Secret(ns `external-secrets` · kv `platform/test/t045-probe` ·
  git 미경유)으로 실측했다: 인수 = **UID 불변 · 값 불변 · ownerReferences 없음 · `…/managed` 라벨 부착**,
  **ES에 열거되지 않은 키는 인수 순간 삭제**, ES 삭제 뒤 Secret 잔존(같은 UID·값), **Secret 삭제 뒤 재생성 302초**
  (직전 refreshTime 03:28:25Z → 새 creationTimestamp 03:33:25Z = 정확히 5분 주기 — 즉시가 아니다. **VD-20 해소**).
- **T056(CA 미러)** — `k8s-data-ca`를 쓰는 ExternalSecret 2종 5장은 이 컴포넌트가 아니라 `cnpg-databases`·`kafka-topics`가
  소유한다(§0 범위).
- **하네스(모노레포)** — `eso-2`(ES Ready·reason) · `eso-3`(store ↔ ns ↔ key 접두 scope) · `eso-4`(인수형 ES 2장의
  `creationPolicy == Orphan` · `deletionPolicy == Retain` · `refreshPolicy == Periodic` · 빈 `template.metadata` ·
  sync-options 회귀 — **신설됐다**. 라이브 검사라 **적용된 뒤에만** 보이고 `agent-view`로 수동 실행한다 ·
  G4 머지 전에는 터널 ES가 없어 FAIL이 기대값이다. 머지 전 정적 방어선은 §2의 yq 렌더 체크다).
  ⚠ **Secret의 UID·ownerReferences·값은 하네스가 보지 않는다**(agent-view는 core Secret을 읽지 못한다) — §2의 게이트(운영자)가
  유일한 확인이다. 이 저장소의 검사 7.3은 **선언**만 본다 — 라이브에서 누가 그 ES를 적용했는지는 §3의 tracking-id로 본다.
- **T048(계획된 교란 창, 선택)** — "ESO webhook 장애 중에도 터널 Deployment를 독립적으로 변경할 수 있다"의 라이브 드릴.
  webhook을 실제로 내리는 것은 `selfHeal` 때문에 PR로만 가능하므로 그 창으로 넘긴다. 구조 검증(소비자 Application의
  `status.resources`에 `external-secrets.io` 0건 · webhook `rules`가 ESO CR 3종뿐 · Deployment server-side dry-run)은 §3에서 한다.
