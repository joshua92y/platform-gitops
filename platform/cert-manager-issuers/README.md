# platform/cert-manager-issuers/ — 운영자 절차 (T042 PR-2)

ACME 발급자 2종(Let's Encrypt staging · prod)과 이 클러스터의 **오리진 인증서 1장**(와일드카드 `*.joshuatech.dev` + apex)을 소유한다.
cert-manager 컨트롤 플레인은 `platform/cert-manager/`(PR-1), Namespace·PSA·NetworkPolicy는 `platform/policies/`(T041),
Traefik의 TLSStore `default`는 `platform/traefik/`(PR-4), Application은 `clusters/oci-k3s/apps/platform-cert-manager-issuers.yaml`(T041 PR-C)이 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | 아래 3개를 `resources`로. 전역 `namespace:` 변환기가 **없는** 이유가 머리 주석에 있다 |
| `clusterissuer-letsencrypt-staging.yaml` | ACME staging · DNS-01(Cloudflare) · 계정 키 `letsencrypt-staging-account-key` |
| `clusterissuer-letsencrypt-prod.yaml` | ACME prod · 같은 형태 · 계정 키 `letsencrypt-prod-account-key`. **PR-2에서는 아무도 참조하지 않는다**(§8) |
| `certificate-wildcard-joshuatech-dev.yaml` | Certificate **1개**(kube-system). 지금은 staging 발급자 + `…-tls-staging` Secret — PR-3에서 두 줄이 함께 바뀐다(§4·§5) |

> **이 저장소에 비밀은 없다.** Cloudflare API 토큰 값도, ACME 계정 키도 여기에 없다.
> Argo CD는 이 Secret들을 만들지도 지우지도 않는다(Application이 `prune: false`).

**PR 순서**: PR-0(`--enable-helm`) → PR-1(cert-manager) → 운영자 수동 Secret(§1) → **PR-2(이 PR, staging)** →
PR-3(prod 승격) → PR-4(TLSStore). PR-4를 prod 발급 전에 넣으면 전 호스트 526이고 **되돌리기(TLSStore 삭제)도 자체 서명 복귀 = 여전히 526**이다 —
T042에서 유일하게 "되돌리기가 곧 장애"인 구간이며, PR 순서가 유일한 방어선이다.

---

## 1. 선행 — 운영자 수동 Secret `cloudflare-dns-token` (이 PR 머지 **전**)

| 항목 | 값 |
|---|---|
| Secret 이름 | `cloudflare-dns-token` |
| 네임스페이스 | **`cert-manager`** |
| 키 | `api-token` |
| 토큰 실물 | Cloudflare API 토큰 **`joshuatech-cert-manager-dns01`** (권한 Zone → DNS → **Edit** + Zone → Zone → **Read**, Zone Resources = `joshuatech.dev` 한정) |

**왜 ns가 `cert-manager`인가.** ClusterIssuer는 cluster-scoped라 자기 ns가 없으므로, 참조하는 Secret은 컨트롤러의
`--cluster-resource-namespace`에서 찾는다. 차트 값 `clusterResourceNamespace`가 비어 있으면 그 인자가 `$(POD_NAMESPACE)`,
즉 **릴리스 네임스페이스**(= `cert-manager`)가 된다. 우리는 그 값을 비워 두었으므로 Secret은 `cert-manager` ns에 있어야 한다.
`kube-system`(Certificate가 사는 곳)에 두면 컨트롤러가 찾지 못한다.
ns 자체는 T041 `platform/policies/`가 이미 선언·적용했으므로 **T039 cloudflared와 달리 ns 수동 생성 단계가 없다.**

**⚠ `Zone:Zone:Read`가 빠지면 발급이 실패한다** — DNS-01 솔버가 존 목록을 조회해 존 ID를 찾기 때문에
`com.cloudflare.api.account.zone.list` 권한 오류가 난다. `Zone:DNS:Edit` 하나만으로는 부족하다.
Global API Key 금지, `joshuatech-tofu-deploy` 재사용 금지(스코프가 넓고 용도가 다르다).
**토큰 값은 사용자 비밀번호 관리자에만 있다 — 저장소·PR 본문·이슈·채팅·로그 어디에도 넣지 않는다.**
회전은 T084 회전 매트릭스에 등재한다(회전 = 아래 절차 재실행이면 되고 cert-manager 재시작은 불필요하다).

### 생성 절차 (워크스테이션 PowerShell 7 + 운영자 admin kubeconfig)

**금지**: `--from-literal=`(토큰이 명령줄 → 셸 히스토리·`ps` 출력에 남는다) ·
`--dry-run=client -o yaml > secret.yaml`(평문 파일 → 커밋 사고) · 값 끝 개행(Cloudflare 인증 실패).
**Git Bash에서 실행하지 않는다** — MSYS가 `/dev/stdin`을 재작성해 네이티브 `kubectl.exe`가 열지 못한다(cloudflared README에 재현 기록).

```powershell
Set-PSReadLineOption -HistorySaveStyle SaveNothing      # 이 세션 히스토리 저장 끄기
$sec  = Read-Host -AsSecureString 'Cloudflare DNS-01 token (joshuatech-cert-manager-dns01)'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
           [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)))     # 개행 없음
  @"
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-dns-token
  namespace: cert-manager
type: Opaque
data:
  api-token: $b64
"@ | kubectl apply --server-side --field-manager=operator-bootstrap -f -
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $b64 = $null; $sec = $null; [GC]::Collect()
}
```

확인은 **키 이름만**(값은 절대 출력하지 않는다):

```powershell
kubectl -n cert-manager get secret cloudflare-dns-token `
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'     # → api-token
```

되돌리기: `kubectl -n cert-manager delete secret cloudflare-dns-token`. Argo는 이 Secret을 추적하지 않는다.

**Secret이 없으면 어떻게 되나 — 안전한 실패다.** ClusterIssuer가 `Ready=False`가 되고 Certificate는 pending에 머문다.
**이 상태에서는 ACME 호출 자체가 일어나지 않으므로 레이트리밋은 한 슬롯도 소비되지 않는다.** 그래도 진단 노이즈를 없애기 위해
순서를 지켜 Secret을 먼저 만든다.

---

## 2. 머지 뒤 확인

```bash
# 운영자 admin 전용 — ClusterIssuer는 agent-view로 읽을 수 없다(§7)
kubectl get clusterissuer -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status} {end}{"\n"}'
        # 둘 다 True = ACME 계정 등록 성공(contact@joshuatech.dev 수리) = 외부 443 정상
kubectl -n cert-manager get secret | grep letsencrypt     # 계정 키 2장 생성 확인(값은 읽지 않는다)

kubectl -n kube-system get certificate,certificaterequest,order,challenge
kubectl -n kube-system wait --for=condition=Ready certificate/wildcard-joshuatech-dev --timeout=600s
```

**DNS-01 self-check 실패는 오류가 아니라 침묵으로 온다** — Challenge가 `pending`에 머물고 컨트롤러 로그에
`Waiting for DNS-01 challenge propagation`이 반복된다. 그때 **가장 먼저** 확인할 것은 values의 리졸버 값이다
(`dns01RecursiveNameservers`가 `"1.1.1.1:53"` **단독**인가 — 정책이 `1.1.1.1/32`:53만 열어 두었고,
`Only: true`의 self-check는 리졸버를 하나씩 단독 질의하고 첫 오류에서 즉시 중단하기 때문이다).

```bash
kubectl -n cert-manager logs deploy/cert-manager --since=15m | grep -Ei 'challenge|propagation|cloudflare|1\.1\.1\.1'
```

Cloudflare 대시보드에서 `_acme-challenge.joshuatech.dev` TXT가 생성·삭제되는지 본다(apex + 와일드카드라 같은 이름에 TXT 2건).
**이 단계에서 Traefik은 아직 자체 서명으로 서빙한다**(TLSStore 없음) → staging 인증서가 외부에 노출되는 일이 없다.

---

## 3. ⚠ 절대 지우면 안 되는 Secret 2장

`letsencrypt-staging-account-key` · `letsencrypt-prod-account-key` (둘 다 ns `cert-manager`)

cert-manager가 **스스로 만드는 ACME 계정 개인키**이고 이 저장소에 없다. Application이 `prune: false`라 Argo는 건드리지 않지만,
**운영자 수동 삭제도 금지한다.** 지우면 계정을 다시 등록해야 하는데 그 한도는 **10회 / 3시간 / IP**이고, 소진되면 발급·갱신이 통째로 막힌다.
AppProject `platform`이 `orphanedResources.warn: true`라 Argo UI에 이 Secret들이 고아 경고로 뜨는데 — **정상이다. 지우지 않는다.**
(같은 이유로 §1의 `cloudflare-dns-token`, PR-1이 남기는 `cert-manager-webhook-ca`도 경고로 뜬다. 드리프트가 아니다.)

---

## 4. PR-3 승격 절차 (staging → prod)

**전제**: §2에서 staging Certificate가 `Ready=True`인 것을 실제로 봤을 것.

`certificate-wildcard-joshuatech-dev.yaml`에서 **두 줄을 한 커밋·한 diff로** 바꾼다.

| 줄 | PR-2(지금) | PR-3(승격 뒤) |
|---|---|---|
| `spec.issuerRef.name` | `letsencrypt-staging` | `letsencrypt-prod` |
| `spec.secretName` | `wildcard-joshuatech-dev-tls-staging` | `wildcard-joshuatech-dev-tls` |

> ⚠ **쪼개지 말 것.** 두 줄을 별도 커밋·별도 PR로 나누면 그 사이에 Certificate가 한 번 더 변경되고,
> in-flight CertificateRequest가 삭제·재생성되어 **ACME 주문이 2회** 나갈 수 있다. prod 중복 한도는 5/7일이고 override가 없다.
> 다른 변경(dnsNames·renewBeforePercentage·주석 정리 등)도 이 PR에 섞지 않는다.

**이 PR이 LE prod 발급 1회를 소비한다.** 실패하면 **prod로 재시도하지 않는다** — `issuerRef`를 staging으로 되돌려
원인을 staging에서 분석한다(staging 재발급은 staging 한도만 쓴다). §9.

### 승격 게이트 4층 (전부 통과해야 PR-4로 간다)

**A. 선언 확인 — 두 줄이 실제로 함께 바뀌었는가**

```bash
kubectl -n kube-system get certificate wildcard-joshuatech-dev \
  -o jsonpath='{.spec.issuerRef.name} {.spec.secretName}{"\n"}'
# 합격: letsencrypt-prod wildcard-joshuatech-dev-tls
```

**B. Certificate 상태 — 신선한 Ready인가 (fail-closed)**

```bash
kubectl -n kube-system get certificate wildcard-joshuatech-dev -o jsonpath='{"gen="}{.metadata.generation}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" og="}{.status.conditions[?(@.type=="Ready")].observedGeneration}{" issuing="}{.status.conditions[?(@.type=="Issuing")].status}{" notAfter="}{.status.notAfter}{" rev="}{.status.revision}{"\n"}'
```

합격 조건 세 가지를 **모두** 만족해야 한다.

1. `Ready=True`
2. `Ready.observedGeneration == metadata.generation` — **값이 비어 있으면 FAIL로 판정한다**(fail-closed).
   `observedGeneration`은 CRD 스키마상 optional이라 없을 수 있는데, 없는 것을 통과로 치면 "옛 스펙에 대한 Ready"를 새 스펙의 증거로 오독하게 된다.
3. `Issuing != True` — **`== False`를 요구하지 말 것.** 발급이 끝나면 `Issuing` condition 자체가 사라질 수 있어
   `False`를 요구하면 정상 완료 상태에서 FAIL한다.

`notAfter`가 약 +90일이고 `revision`이 증가했는지도 함께 본다(VD-P: prod 발급이 **정확히 1회**인가).

**C. CertificateRequest — 실제로 prod 발급자가 서명했는가**

```bash
kubectl -n kube-system get certificaterequest \
  -o custom-columns=N:.metadata.name,REV:'.metadata.annotations.cert-manager\.io/certificate-revision',ISSUER:.spec.issuerRef.name,READY:'.status.conditions[?(@.type=="Ready")].status'
# 합격: 최신 revision 행의 ISSUER=letsencrypt-prod · READY=True
```

⚠ **CertificateRequest에는 `observedGeneration`이 없다** — 게이트 B와 달리 여기서는 요구하지 않는다.
CertificateRequest 개수가 예상보다 늘었으면 즉시 멈추고 원인을 규명한다(한도 5/7일).

**D. 실물 인증서 — 운영자 admin 전용**

```bash
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -issuer -dates -ext subjectAltName
# 합격: issuer에 (STAGING) 표기 없음 · SAN = joshuatech.dev, *.joshuatech.dev · notBefore/notAfter가 방금 발급분
```

**agent-view로는 이 게이트를 수행할 수 없다** — Secret get 권한이 없다(계약 §에이전트 자격). 게이트 A~C도
ClusterIssuer를 확인하려면 admin이 필요하다(§7).

---

## 5. 왜 staging 구간에만 `-staging` Secret 이름을 쓰는가 (설계 §14.2 각색 D)

"Certificate 하나에 `secretName`을 고정해 두고 `issuerRef` 한 줄만 갈아끼운다"(A안)가 더 단순해 보이지만, 실측된 결함이 둘 있다.

1. **거짓 초록.** `tests/platform/ingress.tests.ps1`의 cert-1은 **발급자를 보지 않는다** — kube-system의 Certificate 중
   `spec.secretName`이 `wildcard-joshuatech-dev-tls`와 Ordinal 일치하는 것이 정확히 1개이고 `Ready=True`이면 PASS다.
   `issuerRef`도 CertificateRequest도 Secret 내용도 보지 않는다. A안에서는 **staging 인증서만 있는 상태에서 cert-1이 PASS**하는데,
   그 단언의 헤더는 그 Secret을 "오리진 인증서 = TLSStore default"라고 규정한다. 초록불의 의미와 실제 상태가 어긋난다.
2. **1줄 revert가 곧 장애.** PR-4(TLSStore) 이후에 `issuerRef`를 staging으로 되돌리면 **성공한 staging 재발급**이
   서빙 중인 Secret을 덮어써 Cloudflare Full(strict)가 오리진을 거부한다 → **전 호스트 526**. 게다가 플랫폼 Application은
   `selfHeal: true`라 자동으로 적용된다. "안전한 롤백"처럼 보이는 조작이 장애다.

각색 D에서는 **쓰기 대상이 `spec.secretName` 한 줄로 유일하게 결정**되므로 두 경로가 구조적으로 존재하지 않는다.
staging 구간에는 `wildcard-joshuatech-dev-tls`라는 이름의 Secret이 아예 없어 cert-1은 정직하게 FAIL하고(§6),
`issuerRef`만 되돌리는 조작은 `-staging` Secret에만 쓴다.
롤백 왕복 비용도 낮다 — A안은 왕복 1회마다 prod 중복 슬롯(5/7일)을 하나씩 더 쓰지만 각색 D는 prod 재발급이 0회다.

**문면(`tasks.md:121`)과의 관계**: 종착 Secret 이름 `wildcard-joshuatech-dev-tls`는 **그대로 보존된다.**
편차는 "전이 구간(PR-2~PR-3)에 문면에 없는 임시 Secret 1장이 존재하고 승격 뒤 운영자가 지운다" 하나뿐이며,
이 편차로 깨지는 검사는 **0건**이다(다른 편차들과 달리 실행 불가나 검사 파손 때문이 아니라 위험 저감을 위해 선택한 편차다).

---

## 6. ⚠ staging 구간(PR-2 ~ PR-3)에서 `cert-1`·`cert-2` FAIL은 **기대 상태**다

`tests/platform/ingress.tests.ps1`을 이 구간에 돌리면 다음 두 줄이 나온다. **정상이다.**

```
FAIL cert-1: ... expected exactly 1 cert-manager Certificate in kube-system with spec.secretName=wildcard-joshuatech-dev-tls, found 0
FAIL cert-2: ... no certificate source
```

> **왜 사전에 적어 두는가 — 문면이 고장과 구별되지 않기 때문이다.**
> - cert-1의 `found 0`은 (a) 지금처럼 `secretName`이 아직 `-staging`인 정상 전이 상태와
>   (b) Certificate가 삭제됐거나 cert-manager가 죽어 아무것도 없는 상태를 **같은 문장으로** 낸다.
> - cert-2의 `no certificate source`는 **kubectl 목록 실패 경로에서도 똑같이** 출력된다(스크립트에 두 갈래가 있다).
>
> 즉 이 두 줄만으로는 "정상 전이"와 "진짜 고장"을 구별할 수 없다. tester·T049는 이 구간의 FAIL을
> **알려진 기대 실패**로 보고하되, 근거로 §2의 확인 명령 출력(staging Certificate가 `Ready=True`인가)을 함께 남긴다.
> PR-3 머지 뒤에는 둘 다 PASS로 돌아와야 하며, 그때도 FAIL이면 그것은 진짜 실패다.
> (`ingress.tests.ps1:26`이 vault-2에 대해 같은 방식으로 사전 문서화해 둔 선례가 있다.)

이 구간에는 `traefik.joshuatech.dev` 등 edge 확인으로 오리진 인증서를 판단할 수 없다는 점도 함께 기억한다 —
Access 앱이 edge에서 302를 돌려주므로 오리진에 닿지 않는다. 오리진 상태가 드러나는 호스트는 `auth.joshuatech.dev` 루트뿐이다.

---

## 7. 관측 사각 — agent-view로 무엇을 볼 수 없나

`global.rbac.aggregateClusterRoles: true`(PR-1) 덕분에 `certificates` · `certificaterequests` · `issuers` · `challenges` · `orders`는
`view`에 집계되어 agent-view가 읽는다. 하지만 **`clusterissuers`는 집계되지 않는다** —
차트가 그것을 `cert-manager-cluster-view`(`cluster-reader` 라벨)에만 넣기 때문이다. **정상 동작이며 계약대로다.**
따라서 다음은 **운영자 admin 전용**이다.

- ClusterIssuer의 Ready 상태(§2·§4)
- Secret 내용을 보는 모든 확인(§4 게이트 D · 만료일 확인)
- `traefik.io` 리소스(TLSStore·TLSOption·IngressRoute) — "Traefik이 실제로 그 인증서를 서빙하는가"

---

## 8. 왜 prod ClusterIssuer를 PR-2에서 미리 만드는가

**참조되지 않는 ClusterIssuer는 발급 슬롯을 쓰지 않는다.** 그런데도 지금 만들면 다음 셋이 미리 검증된다.

- ACME **계정 등록** 성공(= `contact@joshuatech.dev`가 수리됨)
- cert-manager ns의 **외부 443 egress**가 실제로 열려 있음
- 계정 키 Secret `letsencrypt-prod-account-key` 생성

한도를 소비하는 것은 Certificate가 이 발급자를 가리키는 순간(PR-3)뿐이다. 즉 PR-3에서 실패할 수 있는 원인 중
"발급자 자체가 잘못됨"을 미리 걷어낸다.

---

## 9. 레이트리밋 규율

| 한도 | 값 | 함의 |
|---|---|---|
| prod 동일 SAN 중복 인증서 | **5 / 7일** (override 불가) | prod 발급은 **정확히 1회**. 실패해도 prod 재시도 금지 — staging으로 되돌려 분석한다 |
| prod 실패 검증(Failed Validation) | 5 / 시간 / 계정 / 호스트 | 배선이 틀린 채 prod로 가면 여기부터 갉아먹는다 |
| ACME 계정 재등록 | 10 / 3시간 / IP | §3의 계정 키 Secret 2장을 지우면 안 되는 이유 |
| staging | 훨씬 넉넉하다 | **배선 검증은 전부 staging에서 끝낸다** |

**Secret이 없어 ClusterIssuer가 `Ready=False`인 상태는 한도를 소비하지 않는다**(ACME 호출 자체가 없다 — §1).
`renewBeforePercentage: 33`의 첫 갱신은 prod 발급 +60일쯤이며, cert-2 임계값(30일)과 겹치는 7.2시간 창이 60일마다 생긴다.
⚠ **2027-02-10 LE classic이 64일로 바뀌면 33% = 잔여 21.1일**이 되어 cert-2가 43일 중 약 9일(≈21%) 상시 FAIL하므로,
그 전에 이 값을 40으로 올린다(잔여 36일 갱신).

---

## 10. 승격 뒤 정리 — `-staging` Secret 삭제 (운영자 admin · PR-4 안정화 뒤)

PR-3에서 `secretName`이 바뀌면 옛 Secret `wildcard-joshuatech-dev-tls-staging`은 **아무도 참조하지 않는 채로 남는다.**
git에 선언된 객체가 아니므로 **Argo의 prune 대상이 아니다** — 운영자가 지운다.

```bash
# ⚠ 삭제 전에 반드시 대상 이름을 눈으로 확인한다(값은 읽지 않는다)
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls-staging
kubectl -n kube-system delete secret wildcard-joshuatech-dev-tls-staging
```

> ⚠ **오삭제 위험 — 각색 D가 들여오는 유일한 파괴적 단계다.** 실수로 prod 쪽(`wildcard-joshuatech-dev-tls`)을 지우면
> Certificate가 남아 있어 cert-manager가 **즉시 재발급**을 시작한다 → prod 중복 한도 1슬롯 소비 +
> 발급이 끝날 때까지 서빙할 인증서가 없어 **526 구간**이 생긴다. 그래서 `get`으로 이름을 확인한 뒤에 지운다.

Certificate·ClusterIssuer 삭제에도 발급된 Secret은 보존된다(`enableCertificateOwnerRef=false` 기본값 유지 — 바꾸지 않는다).

---

## 11. T045 — ExternalSecret 전환

지금은 운영자 수동 Secret이고, T045에서 `secrets/cert-manager/`의 ExternalSecret으로 교체한다.

| 항목 | 확정값 |
|---|---|
| Vault kv 경로 | `kv/platform/cloudflare/dns-token` |
| remoteRef | `key: platform/cloudflare/dns-token`, `property: api-token` |
| target | `name: cloudflare-dns-token`, `creationPolicy: Owner` |
| store | `secretStoreRef: {kind: ClusterSecretStore, name: vault-platform}` (`apiVersion: external-secrets.io/v1` — v1beta1 금지) |

- ⚠ **`docs/runbooks/bootstrap.md:36`의 "cert-manager 토큰은 Vault kv 시드(T043)에서 소비 예정"은 오기다** — kv 시드는 **T045**이고 T043은 AOP다.
- ⚠ **인수 함정(VD-10 · 미검증)**: ESO의 `creationPolicy: Owner`가 **자신이 만들지 않은 기존 Secret을 인수하는지** 실측된 바 없다
  (라벨/어노테이션 선인수가 필요한지, `Merge`를 써야 하는지도 미확인).
  **완화**: cert-manager는 이 토큰을 **DNS-01 챌린지를 푸는 순간에만** 읽고 상주 감시하지 않는다.
  따라서 인수가 불가능해 "수동 Secret 삭제 → ExternalSecret 재생성"으로 가더라도, **갱신 창(잔여 29.7일 이전) 밖이면 공백이 무해하다.**
  ⚠ 같은 판단이 T039 `cloudflared-tunnel`에는 **적용되지 않는다**(그쪽 파드는 토큰을 상주 참조한다) — 두 건을 한 번에 결정하되 위험 등급을 구분한다.
- T045 전환 검증은 **staging 발급으로만** 한다(prod 재발급 금지 — 중복 한도 소비).
  `letsencrypt-prod`가 `Ready=True`를 유지하는지 + 다음 갱신 성공으로 확인한다.
- ClusterSecretStore `vault-platform`의 `conditions.namespaces`에 `cert-manager`가 포함돼야 한다 — T045 설계 시 확인한다.

---

## 12. 되돌리기

**규율: git revert 머지가 먼저, 수동 삭제가 그다음.** Application은 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`라,
git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다. 반대로 revert만 하면 리소스는 남아 있다(정상 동작이다).

1. revert PR 머지 → `kustomization.yaml`이 `resources: []`로 복귀 → hard refresh.
2. (필요할 때만) 운영자 수동 삭제:
   ```bash
   kubectl -n kube-system delete certificate wildcard-joshuatech-dev
   kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod
   ```
3. **계정 키 Secret 2장(§3)과 발급된 인증서 Secret은 지우지 않는다.**

⚠ **PR-4(TLSStore) 이후에는 이 되돌리기가 무해하지 않다** — 서빙 중인 인증서의 갱신 주체가 사라진다.
그 시점 이후의 revert는 만료일을 사람이 기록·감시하는 조건에서만 한다(T098의 만료 알림 전에는 자동 감지 수단이 없다).
