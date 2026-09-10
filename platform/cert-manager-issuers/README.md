# platform/cert-manager-issuers/ — 운영자 절차 (T042)

> **현재 상태(2026-09-10) = prod 승격 완료.** PR-3(`32a1022`)이 `letsencrypt-prod`로 전환했고 와일드카드는 **`rev 2`**
> (issuer `C=US, O=Let's Encrypt, CN=YE2` · SAN `*.joshuatech.dev` + `joshuatech.dev` · `notAfter 2026-12-08`).
> PR-4(`4f23abd`, TLSStore)까지 머지돼 `auth.joshuatech.dev`가 526 → **404**로 바뀌었고, 그 뒤 sniStrict도 투입됐다.
> 아래 §4·§6·§8·§10은 **끝난 전이 구간의 기록**이고(과거형으로 읽는다), §1·§2는 기록이자 **회전·재부트스트랩·진단 때 다시 쓰는 절차**다.
> 앞으로 실제로 해야 할 일은 **§13(갱신 전제 체크리스트)** — 첫 갱신 ≈**2026-11-08**, 만료 **2026-12-08** — 이고,
> 그 밖의 미완 작업은 **§11(T045 ExternalSecret 전환)**과 **§1의 토큰 회전(T084)**이다.

ACME 발급자 2종(Let's Encrypt staging · prod)과 이 클러스터의 **오리진 인증서 1장**(와일드카드 `*.joshuatech.dev` + apex)을 소유한다.
cert-manager 컨트롤 플레인은 `platform/cert-manager/`(PR-1), Namespace·PSA·NetworkPolicy는 `platform/policies/`(T041),
Traefik의 TLSStore `default`는 `platform/traefik/`(PR-4), Application은 `clusters/oci-k3s/apps/platform-cert-manager-issuers.yaml`(T041 PR-C)이 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | 아래 3개를 `resources`로. 전역 `namespace:` 변환기가 **없는** 이유가 머리 주석에 있다 |
| `clusterissuer-letsencrypt-staging.yaml` | ACME staging · DNS-01(Cloudflare) · 계정 키 `letsencrypt-staging-account-key` |
| `clusterissuer-letsencrypt-prod.yaml` | ACME prod · 같은 형태 · 계정 키 `letsencrypt-prod-account-key`. **PR-2 시점에는 아무도 참조하지 않았다**(§8) — 지금은 Certificate가 이것을 가리킨다 |
| `certificate-wildcard-joshuatech-dev.yaml` | Certificate **1개**(kube-system). PR-2 시점에는 staging 발급자 + `…-tls-staging` Secret이었고, PR-3에서 두 줄이 함께 바뀌었다(§4·§5) |

> **이 저장소에 비밀은 없다.** Cloudflare API 토큰 값도, ACME 계정 키도 여기에 없다.
> Argo CD는 이 Secret들을 만들지도 지우지도 않는다(Application이 `prune: false`).

**PR 순서(전부 머지 완료)**: PR-0(`--enable-helm` `8f2b943`) → PR-1(cert-manager `8cb1149`) → (그 사이 `cad608a` = webhook egress 정책 add-only —
이 디렉터리 밖이지만 PR-2의 admission 선행 조건이다) → 운영자 수동 Secret(§1) →
PR-2(staging `c9be2f8`) → PR-3(prod 승격 `32a1022`) → PR-4(TLSStore `4f23abd`).
PR-4를 prod 발급 전에 넣었다면 전 호스트가 526이 되고 **되돌리기(TLSStore 삭제)도 자체 서명 복귀 = 여전히 526**이었을 것이다 —
T042에서 유일하게 "되돌리기가 곧 장애"인 구간이었고, PR 순서가 유일한 방어선이었다. 실제로는 순서를 지켜 회귀가 없었다.

**머지 시각 조건**(당시 조건이자, 이 객체들을 다시 CREATE 할 때 — revert 뒤 재적용·재부트스트랩 — 그대로 유효하다):
노드 B(`joshtech-cache`, `role=data`)가 Ready이고 **SUC 업그레이드 창 밖**일 것
(창의 정본은 `platform/system-upgrade/plan-k3s-agent.yaml`의 `window` — 현재 일요일 03:00–05:00 KST).
cert-manager 3종이 노드 B 단독 배치이고 webhook이 `failurePolicy: Fail`이라, 그 창의 drain 중(또는 노드 B 장애 중)에는
ClusterIssuer·Certificate의 **CREATE가 admission에서 거부**되어 첫 sync가 SyncFailed로 떨어진다.
창이 끝나면 `selfHeal: true`가 재시도해 저절로 회복되지만, 그 사이의 SyncFailed를 진짜 고장으로 오독하게 된다.
(같은 규칙이 `platform/cert-manager/README.md`에도 있다 — "SUC 업그레이드 창 동안 issuers를 sync 하지 않는다".)

---

## 1. 선행 — 운영자 수동 Secret `cloudflare-dns-token` (**완료** · PR-2 머지 전에 생성)

이 절차는 끝났다(운영자가 PR-2 머지 전에 Secret을 만들었고, 그 상태로 staging·prod 발급이 모두 성공했다).
아래는 **회전(T084)·재부트스트랩·T045 전환 실패 시 되돌아올 때** 그대로 다시 쓰는 절차다.

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

**`--server-side`는 선택이 아니다** — client-side apply는 `kubectl.kubernetes.io/last-applied-configuration` 어노테이션에
**토큰 base64 사본**을 남기고, 그 사본은 `kubectl get secret -o yaml`·etcd 스냅샷·야간 백업까지 그대로 따라간다
(선례: `platform/cloudflared/README.md` ② "`apply --server-side`라 회전 시 재실행해도 되고, `last-applied-configuration` 어노테이션(토큰 사본)이 생기지 않는다").
회전으로 이 절차를 재실행할 때도 이 플래그를 빼지 않는다.

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

**Secret이 없으면 어떻게 되나 — prod 한도는 안전하지만 증상은 다르다(진단 지점 주의).**
**ClusterIssuer 2개는 그대로 `Ready=True`가 된다.** ACME 계정 등록은 솔버 Secret과 무관하기 때문이다 — §8이 바로 그 성질에 기대어
"참조되지 않는 prod ClusterIssuer"만으로 계정 등록·외부 443을 미리 검증한다. 솔버의 `apiTokenSecretRef`는 Challenge의 `Present` 단계에서 처음 읽힌다.
실제 시퀀스는 이렇다: 두 ClusterIssuer `Ready=True` → Certificate `Issuing=True`·`Ready=False` → CertificateRequest·Order까지 생성되어
**staging 엔드포인트로 newOrder 호출이 실제로 나가고** → Challenge가 `secret "cloudflare-dns-token" not found`로 `pending`에 정체한다.
따라서 이 상태의 진단 지점은 ClusterIssuer가 **아니라** `kubectl -n kube-system get certificate,certificaterequest,order,challenge`와 cert-manager 로그다.
§2의 첫 확인("둘 다 True = 정상")은 이 고장 상태에서도 True를 돌려주므로 그것만으로 판단하지 않는다.
**prod 한도(중복 5/7일 · 실패 검증 5/시간)는 소비되지 않는다** — Certificate가 staging만 가리키기 때문이다(§9).
그래도 순서를 지켜 Secret을 먼저 만든다.

**⚠ 이 상태에서 안전한 것은 레이트리밋뿐이다 — 신호는 함께 죽는다.** Certificate가 `Ready=True`가 될 때까지
`platform-cert-manager-issuers`와 `root` Application이 `Progressing`이고(Argo CD 내장 `cert-manager.io/Certificate` health가
발급 전까지 Progressing, argocd-cm의 Application health Lua가 그 상태를 root까지 전파한다 — 설계 §8 R13),
그 결과 `tests/platform/cluster.tests.ps1`의 `argo-1`이 FAIL한다(`reboot.tests.ps1`의 `reboot-3`은 `-AfterReboot`로 돌릴 때만 같이 FAIL한다 — §6).
또 이 구간에 `clusters/oci-k3s/apps/` 변경을 머지하면 root sync가 이 컴포넌트의 wave에서 health를 기다리며 멈춰
**뒤 wave Application들의 변경이 적용되지 않는다**(wave 값의 정본은 계약 §sync-wave 단일 표 — 여기 숫자를 다시 적지 않는다).
**발급 확인 전까지 이 PR을 뒤 컴포넌트 PR과 섞지 않는다.**

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

⚠ **ClusterIssuer 두 개가 `True`인 것은 계정 등록까지만 증명한다.** DNS-01 토큰 Secret이 없거나 권한이 틀려도 이 줄은 `True`다 —
솔버의 `apiTokenSecretRef`는 Challenge의 `Present` 단계에서 처음 읽히기 때문이다(§1). 배선 판정은 아래 Certificate·Challenge 확인으로 한다.

### DNS-01이 `pending`에 정체할 때 — 진단 순서 (실측으로 다시 쓴 절)

**DNS-01 self-check 실패는 오류가 아니라 침묵으로 온다** — Challenge가 `pending`에 머물고 컨트롤러 로그에
`Waiting for DNS-01 challenge propagation`이 반복된다. **순서대로** 본다.

**① 존에 남은 `_acme-challenge` CNAME(그리고 CAA) — 여기가 첫 번째다.**
staging 발급이 **107분** 정체한 실제 원인이 이것이었다: v1 시절 잔재인 `_acme-challenge.joshuatech.dev` CNAME이
`fly.dev`를 가리키고 있었고, cert-manager는 TXT를 조회하기 **전에** `followCNAMEs`로 그 CNAME을 따라가
남의 존에서 자기 TXT를 찾고 있었다. 레코드를 지우자 즉시 풀렸다.
`infra/cloudflare/dns.tf`가 `_acme-challenge`를 **관리 대상에서 영구 제외**하므로 `tofu plan`은 이 잔재를 영원히 보지 못한다 —
**사람이 조회하는 것 말고는 감지 수단이 없다.**

```powershell
# 공개 DoH(Cloudflare). 클러스터·kubectl·자격증명 없이 되고, 로컬 리졸버 캐시를 타지 않는다.
$h = @{ accept = 'application/dns-json' }
(Invoke-RestMethod 'https://cloudflare-dns.com/dns-query?name=_acme-challenge.joshuatech.dev&type=CNAME' -Headers $h).Answer   # 합격: 출력 없음
(Invoke-RestMethod 'https://cloudflare-dns.com/dns-query?name=_acme-challenge.joshuatech.dev&type=TXT'   -Headers $h).Answer   # 챌린지 밖에서는 출력 없음
(Invoke-RestMethod 'https://cloudflare-dns.com/dns-query?name=joshuatech.dev&type=CAA'                   -Headers $h).Answer   # 합격: 없음 또는 letsencrypt.org 허용
```

CNAME 행이 하나라도 나오면 **그것이 원인이다** — Cloudflare 대시보드에서 삭제한다(IaC 밖이므로 삭제도 사람이 한다).
같은 확인을 bash에서 하려면 `curl -s -H 'accept: application/dns-json' '<위 URL>'`을 쓴다.

**② values의 리졸버 값** — `dns01RecursiveNameservers`가 `"1.1.1.1:53"` **단독**인가.
정책이 `1.1.1.1/32`:53만 열어 두었고, `Only: true`의 self-check는 리졸버를 하나씩 단독 질의하고 첫 오류에서 즉시 중단한다.

**③ 컨트롤러 로그**

```bash
kubectl -n cert-manager logs deploy/cert-manager --since=15m | grep -Ei 'challenge|propagation|cloudflare|1\.1\.1\.1'
```

⚠ **로그 침묵을 컨트롤러 정지로 읽지 않는다.** 자기검사 재시도 로그는 `V(4)`인데 차트 기본이 `--v=2`라 보이지 않고,
Challenge의 `resourceVersion`이 고정돼 보이는 것도 `Semantic.DeepEqual` 조기 반환일 뿐이다(정체 당시 실제로 이렇게 오진했다).
컨트롤러 생존의 증거는 `certmanager_controller_sync_call_count{controller="challenges"}`가 증가하는 것이다.

**④ TXT 생성·삭제 관측** — Cloudflare 대시보드에서 `_acme-challenge.joshuatech.dev` TXT가 생성·삭제되는지 본다
(apex + 와일드카드라 같은 이름에 TXT 2건).

**PR-2 시점에는 Traefik이 아직 자체 서명으로 서빙했다**(TLSStore 없음) → staging 인증서가 외부에 노출되는 일이 없었다.
지금은 PR-4가 머지돼 **prod 와일드카드를 서빙한다** — 이 진단을 다시 할 때(갱신 실패 등)는 서빙 중인 인증서가 걸려 있다는 점이 다르다.

---

## 3. ⚠ 절대 지우면 안 되는 Secret 2장

`letsencrypt-staging-account-key` · `letsencrypt-prod-account-key` (둘 다 ns `cert-manager`)

cert-manager가 **스스로 만드는 ACME 계정 개인키**이고 이 저장소에 없다. Application이 `prune: false`라 Argo는 건드리지 않지만,
**운영자 수동 삭제도 금지한다.** 지우면 계정을 다시 등록해야 하는데 그 한도는 **10회 / 3시간 / IP**이고, 소진되면 발급·갱신이 통째로 막힌다.
AppProject `platform`이 `orphanedResources.warn: true`라 Argo UI에 이 Secret들이 고아 경고로 뜨는데 — **정상이다. 지우지 않는다.**
(같은 이유로 §1의 `cloudflare-dns-token`, PR-1이 남기는 `cert-manager-webhook-ca`도 경고로 뜬다. 드리프트가 아니다.)

---

## 4. PR-3 승격 절차 (staging → prod) — **완료(`32a1022` · `rev 2`)**

**전제**: §2에서 staging Certificate가 `Ready=True`인 것을 실제로 봤을 것. (충족했다.)

`certificate-wildcard-joshuatech-dev.yaml`에서 **두 줄을 한 커밋·한 diff로** 바꿨다.

| 줄 | PR-2(전이 구간) | PR-3(승격 뒤 = 현재) |
|---|---|---|
| `spec.issuerRef.name` | `letsencrypt-staging` | `letsencrypt-prod` |
| `spec.secretName` | `wildcard-joshuatech-dev-tls-staging` | `wildcard-joshuatech-dev-tls` |

> ⚠ **쪼개지 말 것.** 두 줄을 별도 커밋·별도 PR로 나누면 그 사이에 Certificate가 한 번 더 변경되고,
> in-flight CertificateRequest가 삭제·재생성되어 **ACME 주문이 2회** 나갈 수 있다. prod 중복 한도는 5/7일이고 override가 없다.
> 다른 변경(dnsNames·renewBeforePercentage·주석 정리 등)도 이 PR에 섞지 않는다.

**이 PR이 LE prod 발급 1회를 소비했다**(실측: 중복 한도 **1슬롯**). 실패했다면 **prod로 재시도하지 않고**
`issuerRef`를 staging으로 되돌려 원인을 staging에서 분석했을 것이다(staging 재발급은 staging 한도만 쓴다). §9.

### 승격 게이트 4층 (전부 통과해야 PR-4로 간다) — 전부 통과함

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

`notAfter`가 약 +90일인지, 그리고 `revision`이 **정확히 1만 증가**했는지를 함께 본다 — 이것이 VD-P("prod 발급이 **정확히 1회**인가")의 유일한 판정 신호다.
**승격 PR을 머지하기 직전에 이 명령을 한 번 돌려 `rev=` 값을 기록해 둔다**(전이가 순조로웠다면 staging 발급이 rev 1이므로 승격 뒤 값은 **2**다).
2 이상 증가했으면 prod 슬롯을 추가로 소비한 것이므로 **즉시 멈춘다**(한도 5/7일, override 불가).
**실측 결과: `rev 2` · `notAfter 2026-12-08` — 예상대로 +1이고 prod 슬롯 1개만 썼다.**

**C. CertificateRequest — 실제로 prod 발급자가 서명했는가**

```bash
kubectl -n kube-system get certificaterequest \
  -o custom-columns=N:.metadata.name,REV:'.metadata.annotations.cert-manager\.io/certificate-revision',ISSUER:.spec.issuerRef.name,READY:'.status.conditions[?(@.type=="Ready")].status'
# 합격: 최신 revision 행의 ISSUER=letsencrypt-prod · READY=True
```

⚠ **CertificateRequest에는 `observedGeneration`이 없다** — 게이트 B와 달리 여기서는 요구하지 않는다.

⚠ **개수는 중복 발급의 신호가 되지 못한다.** 이 Certificate는 `revisionHistoryLimit: 1`이라 cert-manager의 revision manager가
`status.revision - 1` 이하의 CertificateRequest를 GC한다 — 승격 뒤 staging rev 1은 사라지고 어느 시점에나 최신 1건만 남는다.
중복 주문이 나가 rev가 3이 되어도 개수는 여전히 1이고, 반대로 발급 직후 짧은 구간에는 정상 상태에서도 2건이 보여 오경보가 난다.
**중복 발급 판정은 게이트 B의 `.status.revision`으로 한다**(위: 승격 직전 값 대비 정확히 +1). 이 명령은 최신 revision 행의
`ISSUER`·`READY` 확인용으로만 쓴다.

**D. 실물 인증서 — 운영자 admin 전용**

```bash
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -issuer -dates -ext subjectAltName
# 합격: issuer에 (STAGING) 표기 없음 · SAN = joshuatech.dev, *.joshuatech.dev · notBefore/notAfter가 방금 발급분
```

**agent-view로는 이 게이트를 수행할 수 없다** — Secret get 권한이 없다(계약 §에이전트 자격). 게이트 A~C도
ClusterIssuer를 확인하려면 admin이 필요하다(§7).

**E. 공개 CT — kubectl 없이 체인 진위를 확정한다 (위 4층 밖의 독립 교차 확인 · 실제 승격 뒤에 추가한 절)**

Secret을 읽을 수 없는 자격(agent-view · 외부 검증자 · 클러스터에 접근할 수 없는 상황)도 이것만은 할 수 있다.
CT 집계기(certspotter)에서 `joshuatech.dev`의 발급 이력을 열고, 네 값이 모두 맞는 항목이 있는지 본다:
**유효기간 `2026-09-09 → 2026-12-08`** · **발급자 `Let's Encrypt CN=YE2`** · **SAN 2개**(`*.joshuatech.dev`, `joshuatech.dev`).
(PR-4 머지 게이트를 실제로 이 방법으로 독립 확인했다.)

**staging 인증서는 공개 CT에 오르지 않으므로**, 이 목록에 항목이 있다는 사실 자체가 "체인이 staging이 아니다"를 증명한다 —
게이트 D(Secret에서 issuer 문자열 읽기)와 서로 다른 경로로 같은 결론에 닿는다.
⚠ **집계기 한 곳만 믿지 않는다** — crt.sh는 이 인증서를 하루가 지나도록 색인하지 못했고 certspotter에는 바로 떴다.
한쪽이 비어 있는 것은 "발급되지 않았다"의 증거가 되지 못한다.

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

## 6. ⚠ staging 구간(PR-2 ~ PR-3)의 기대 실패 — `cert-1`·`cert-2` **그리고** `argo-1`

> **이 구간은 PR-3(`32a1022`) 머지로 끝났다.** 아래는 그 구간의 기록이다 —
> **지금 같은 문면의 FAIL이 보인다면 그것은 기대 실패가 아니라 진짜 실패다.**

`tests/platform/ingress.tests.ps1`을 이 구간에 돌리면 다음 두 줄이 나온다(**출력 전문** — 운영자가 그대로 대조할 수 있게 `--` 구분자까지 옮긴다). **정상이다.**

```
FAIL cert-1: Secret kube-system/wildcard-joshuatech-dev-tls exists (cert-manager Certificate spec.secretName match, Ready=True) -- expected exactly 1 cert-manager Certificate in kube-system with spec.secretName=wildcard-joshuatech-dev-tls, found 0
FAIL cert-2: wildcard certificate status.notAfter is more than 30 days away (TotalDays > 30) -- no certificate source
```

**같은 구간에 `tests/platform/cluster.tests.ps1`의 `argo-1`도 FAIL한다.** Certificate가 `Ready=True`가 되기 전까지 Argo CD 내장
health(`cert-manager.io/Certificate`)가 `platform-cert-manager-issuers`를 Healthy로 보지 않고, `argocd-cm`의 Application health Lua가
그 상태를 `root`까지 전파하기 때문이다(설계 §8 R13). 기대 출력:

```
FAIL argo-1: not Synced/Healthy: platform-cert-manager-issuers=Synced/Progressing, root=Synced/Progressing
```

`cluster.tests.ps1`의 `$argoExcludedApps`는 **빈 배열**이고 `run-platform-tests.ps1`에는 기대 실패 allowlist가 없으므로,
이 구간에는 **러너 전체가 exit 1**이다(원인은 cert-1·cert-2·argo-1 셋).
`reboot.tests.ps1`의 `reboot-3`(argocd ns Application 전부 Healthy)도 같은 조건을 보지만 **`-AfterReboot`로 돌릴 때만** 평가된다 —
평상시 러너 실행에서는 `SKIP reboot-3: manual trigger only (-AfterReboot) -- argocd applications all Healthy`다.
즉 이 구간에 재부팅 검증을 겹쳐 돌리면 `reboot-3`도 함께 FAIL하므로, **발급이 끝난 뒤로 미룬다.**

- **정상 경로에서도** 발급이 끝나기 전 2–5분 동안 `argo-1`이 FAIL할 수 있다 — §2의
  `wait --for=condition=Ready`가 끝나면 곧 회복된다.
- **해소되지 않으면 그것은 진짜 실패다.** §1의 Secret 미생성·DNS-01 오배선 상태에서는 `argo-1`이 **영구 FAIL**로 남는다
  (그때 볼 곳은 ClusterIssuer가 아니라 Challenge·이벤트·컨트롤러 로그 — §1).

> **왜 사전에 적어 두는가 — 문면이 고장과 구별되지 않기 때문이다.**
> - cert-1의 `found 0`은 (a) 지금처럼 `secretName`이 아직 `-staging`인 정상 전이 상태와
>   (b) Certificate가 삭제됐거나 cert-manager가 죽어 아무것도 없는 상태를 **같은 문장으로** 낸다.
> - cert-2의 `no certificate source`는 **kubectl 목록 실패 경로에서도 똑같이** 출력된다(스크립트에 두 갈래가 있다).
>
> 즉 이 두 줄만으로는 "정상 전이"와 "진짜 고장"을 구별할 수 없다. tester·T049는 이 구간의 FAIL을
> **알려진 기대 실패**로 보고하되, 근거로 §2의 확인 명령 출력(staging Certificate가 `Ready=True`인가)을 함께 남긴다.
> **승격 직후 발급이 끝나기 전의 과도 상태는 또 다른(세 번째) 문면으로 나온다** — `secretName`이 문면값으로 바뀌는 순간
> 필터는 통과하지만 아직 `Ready=True`가 아니기 때문이다(`secretName` 변경은 재발급을 유발하므로 반드시 한 번 거친다):
>
> ```
> FAIL cert-1: Secret kube-system/wildcard-joshuatech-dev-tls exists (cert-manager Certificate spec.secretName match, Ready=True) -- Certificate wildcard-joshuatech-dev Ready != True (reason=[...]) -- cert-manager sets Ready=True only when the Secret exists and is valid
> FAIL cert-2: wildcard certificate status.notAfter is more than 30 days away (TotalDays > 30) -- certificate not Ready
> ```
>
> PR-3 머지 **뒤 §4 게이트 B(`Ready=True`)까지 통과하면** 둘 다 PASS로 돌아와야 하며, 그때도 FAIL이면 그것은 진짜 실패다.
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

**참조되지 않는 ClusterIssuer는 발급 슬롯을 쓰지 않는다.** 그런데도 PR-2에서 미리 만든 덕분에 다음 셋이 미리 검증됐다.

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

⚠ **갱신 실패를 알려 줄 메일은 없다.** Let's Encrypt는 2025-06-04부로 만료 알림 메일 발송을 중단했다("Ending Support for Expiration Notification Emails") —
ClusterIssuer의 `email:`은 **계정 연락처 기록일 뿐 알림 경로가 아니다**(발급·갱신은 그 주소의 메일 라우팅과 무관하게 동작한다).
`certmanager_certificate_expiration_timestamp_seconds` 기반 알림(T098)이 유일한 자동 감지 수단이고, 그 전까지는 **만료일을 사람이 본다**(설계 §8 R19).
갱신이 실제로 일어나기 전에 사람이 확인해야 할 전제는 **§13**에 모아 두었다.

**Secret이 없는 상태도 prod 한도는 소비하지 않는다** — 단 이유는 "ACME 호출이 없어서"가 아니다.
ClusterIssuer는 그대로 `Ready=True`이고 staging newOrder는 실제로 나간다. prod가 안전한 것은 Certificate가 staging만 가리키기 때문이다(§1).
`renewBeforePercentage: 33`의 첫 갱신은 prod 발급 +60일 = **≈2026-11-08**(잔여 29.7일)이며,
cert-2 임계값(30일)과 겹치는 7.2시간 창이 60일마다 생긴다.
⚠ **2027-02-10 LE classic이 64일로 바뀌면 33% = 잔여 21.1일**이 되어 cert-2가 43일 중 약 9일(≈21%) 상시 FAIL하므로,
그 전에 이 값을 올린다.

**⚠ 대응값 정정: `40`이 아니라 `≥47`, 실용값 `50`이다.**
`renewBeforePercentage`는 **남은 수명의 비율**이다. 64일 수명에서 40%는 **64 × 0.40 = 25.6일**이고, 이는 cert-2 임계 30일보다 **작다** —
40으로 올려도 갱신 주기 38.4일 중 4.4일(≈11%)이 계속 FAIL한다. 30일을 넘기려면 64 × 0.47 = **30.1일**이라 **최소 47%**가 필요하고,
여유를 둔 실용값이 **50**(잔여 32일 · 주기 32일 중 FAIL 0일)이다.
**왜 `40`이 나왔나 — 수명 90일로 계산한 값을 64일 문맥에 그대로 옮겨 적었다**(90 × 0.40 = 36 → 옛 문면의 "잔여 36일").
수명이 바뀌면 같은 퍼센트의 일수 의미가 바뀐다는 것을 놓친 산술 오류다.
같은 오기가 `certificate-wildcard-joshuatech-dev.yaml`의 `renewBeforePercentage` 주석과 `platform/traefik/README.md`에도 있(었)다 —
값을 실제로 올릴 때 **세 곳을 함께** 고친다.

---

## 10. 승격 뒤 정리 — `-staging` Secret 삭제 (**완료** · 운영자 admin)

> **실제 순서는 이 절이 적어 둔 것과 달랐다 — 그리고 그래도 무해했다.**
> 이 절은 삭제를 "PR-4 안정화 뒤"로 못박았지만, **운영자는 PR-4 머지 전에 지웠다.**
> 무해했던 이유는 그 시점에 이미 **그 Secret을 참조하는 것이 0개**였기 때문이다 — PR-3이 `secretName`을 `wildcard-joshuatech-dev-tls`로
> 바꾼 순간 Certificate는 새 Secret만 쓰고, TLSStore는 아직 존재하지도 않았다(PR-4가 그것을 만든다).
> "PR-4 안정화 뒤"라는 조건이 지키려던 것은 **롤백 여지**였는데, 그 여지는 애초에 없었다: PR-4 이후 `issuerRef`를 되돌리는 조작 자체가
> 금지돼 있고(§5·§12), `-staging` Secret이 남아 있어도 그것을 다시 서빙하려면 TLSStore를 손대야 한다.
> 즉 이 조건은 **과하게 보수적이었고**, 지금 트리로는 `-staging` Secret이 재생성되지 않으므로 이 절 전체가 **1회성 기록**이다.

PR-3에서 `secretName`이 바뀌자 옛 Secret `wildcard-joshuatech-dev-tls-staging`은 **아무도 참조하지 않는 채로 남았다.**
git에 선언된 객체가 아니므로 **Argo의 prune 대상이 아니다** — 운영자가 지웠다(아래가 그때 쓴 명령이다).

```bash
# ⚠ 삭제 전에 반드시 대상 이름을 눈으로 확인한다(값은 읽지 않는다)
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls-staging
kubectl -n kube-system delete secret wildcard-joshuatech-dev-tls-staging
```

> ⚠ **오삭제 위험 — 각색 D가 들여오는 유일한 파괴적 단계다.** 실수로 prod 쪽(`wildcard-joshuatech-dev-tls`)을 지우면
> Certificate가 남아 있어 cert-manager가 **즉시 재발급**을 시작한다 → prod 중복 한도 1슬롯 소비 +
> 발급이 끝날 때까지 서빙할 인증서가 없어 **526 구간**이 생긴다. 그래서 `get`으로 이름을 확인한 뒤에 지운다.

**이 절이 존재하는 이유 자체가 `enableCertificateOwnerRef: false`다.** 차트 기본값이 `false`이고 `platform/`에 이를 뒤집는 오버라이드가 0건이라,
cert-manager는 발급한 Secret에 Certificate를 owner로 달지 않는다. 그래서 **Certificate를 지워도, ClusterIssuer를 지워도,
`secretName`을 바꿔도 이미 발급된 Secret은 그대로 남는다** — 옛 Secret이 고아로 남아 사람이 지워야 하는 것도 같은 성질의 결과다.
(이 기본값은 바꾸지 않는다. 바꾸면 아래 §12의 되돌리기 성질이 통째로 달라진다.)

---

## 11. T045 — ExternalSecret 전환

지금은 운영자 수동 Secret이고, T045에서 `secrets/cert-manager/`의 ExternalSecret으로 교체한다.

| 항목 | 확정값 |
|---|---|
| Vault kv 경로 | `kv/platform/cloudflare/dns-token` |
| remoteRef | `key: platform/cloudflare/dns-token`, `property: api-token` |
| target | `name: cloudflare-dns-token`, `creationPolicy: Owner` |
| store | `secretStoreRef: {kind: ClusterSecretStore, name: vault-platform}` (`apiVersion: external-secrets.io/v1` — v1beta1 금지) |

- ⚠ **kv 시드에도 §1과 같은 규율을 적용한다 — 값을 argv에 두지 않는다.** `vault kv put <경로> api-token=<값>` 형태는 §1이 금지한
  `--from-literal=`과 **정확히 같은 노출 등급**이다(셸 히스토리 · `ps` 출력). 값이 `-`이면 Vault CLI가 stdin에서 읽으므로
  `… | vault kv put kv/platform/cloudflare/dns-token api-token=-` 로 파이프해 넣는다(평문 파일을 만들어 `@file`로 넘기지 않는다).
  시드 뒤 확인은 `vault kv get -field=…`(값 출력)이 아니라 `vault kv metadata get kv/platform/cloudflare/dns-token`(키·버전만)으로 한다.
- ✅ **런북 오기 정정 완료(2026-09-10).** 모노레포 `docs/runbooks/bootstrap.md` §0의 "토큰 ① Cloudflare 배포 토큰" 줄이
  "cert-manager 토큰은 Vault kv 시드(**T043**)에서 소비 예정"이라고 적고 있었다. 두 곳이 틀렸고 둘 다 그 줄에서 고쳤다 —
  ⓐ kv 시드·ExternalSecret 전환은 **T045**다(T043은 AOP 강제) ⓑ "예정"도 낡았다: **T042에서 이미 소비했다**(§1의 운영자 수동 Secret).
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

⚠ **PR-4(TLSStore) 이후에는 이 되돌리기가 무해하지 않다** — 서빙 중인 인증서의 **갱신 주체**가 사라진다.
그 시점 이후의 revert는 만료일을 사람이 기록·감시하는 조건에서만 한다(T098의 만료 알림 전에는 자동 감지 수단이 없다).

**위험의 모양을 정확히 적어 둔다(사후 감사 2026-09-10에서 반대로 적혀 있던 것을 고친다).**
"이 디렉터리를 revert 하면 서빙 Secret이 사라져 **즉시 526**"은 **사실과 반대다.**
`enableCertificateOwnerRef: false`(§10)라 Certificate·ClusterIssuer가 사라져도 발급된 Secret은 **그대로 남고 계속 서빙된다.**
진짜 위험은 **조용함**이다 — 갱신할 주체가 없는 채로 최대 `notAfter`(**2026-12-08**)까지 정상처럼 보이다가 그날 만료한다.
단, revert **직후**에는 harness `cert-1`이 `found 0`으로 즉시 FAIL한다(Certificate CR이 사라지므로) — 조용한 것은 revert가 아니라
그 뒤의 **만료**다. harness는 사람이 돌려야 보이므로 자동 알림은 여전히 T098 전까지 없다.
게다가 **Traefik v3.7.8은 인증서를 적재할 때 유효기간을 검사하지 않는다**
(`certificate_store.go`의 `parseCertificate`가 `tls.X509KeyPair`만 부르고 `NotAfter`를 참조하지 않으며, `GetBestCertificate`도 `matchDomain`만 본다) —
따라서 만료해도 자체 서명으로 **바뀌지 않고 만료된 인증서를 그대로 계속 서빙한다.**
엣지에서 보이는 결과는 526으로 같지만 원인이 다르므로, 그때 Traefik 로그나 "자체 서명 폴백"을 찾으면 헤맨다.
판정은 서빙 중인 인증서의 `notAfter`를 직접 보는 것으로 한다(§4 게이트 D 또는 게이트 E의 공개 CT).

---

## 13. 갱신 전제 체크리스트 (첫 갱신 ≈**2026-11-08** · 만료 **2026-12-08**)

**이 절이 지금 이 문서에서 유일하게 "앞으로 할 일"이다.** §1~§12는 이미 일어난 일의 기록이거나 그때 쓴 절차다.

발급은 한 번 성공했지만 **갱신은 발급과 같은 경로를 처음부터 다시 탄다** — DNS-01 챌린지, Cloudflare API, 외부 443,
ACME 계정, admission webhook까지 전부 그 시점에 다시 살아 있어야 한다. 그 사이(≈2개월)에 하나가 조용히 죽어도 아무도 알려 주지 않는다:
**LE의 만료 알림 메일은 2025-06-04부로 없어졌고**(§9), 메트릭 기반 알림은 **T098** 몫이며, 지금 존재하는 **유일한 자동 신호는
`tests/platform/ingress.tests.ps1`의 `cert-2`(Certificate CR의 `.status.notAfter`가 30일보다 가까우면 FAIL — 서빙 Secret이 아니라 **CR 상태**를 본다, §7)** 하나뿐이다.
그런데 그 신호는 **갱신이 시작되기 7.2시간 전부터** 울린다(임계 30일 > 갱신 시작 잔여 29.7일). 즉 첫 FAIL만으로는
**정상 겹침**과 **갱신 실패**를 구별할 수 없다 — 성공하면 `notAfter`가 +90일로 밀려 곧 PASS로 돌아오고, 며칠이 지나도 FAIL이면 그때가 진짜 실패다.
어느 쪽이든 신호가 오는 시점에는 이미 잔여 30일이고 남은 판단 시간이 짧다.
그래서 **갱신 창(2026-11-08 전후)에 들어가기 전에** 아래를 사람이 한 번 훑는다.

| # | 전제 | 확인 | 합격 |
|---|---|---|---|
| ① | 존에 `_acme-challenge` 잔재가 없고 CAA가 막지 않는다 | 공개 DoH(§2 ①의 명령 그대로) | CNAME **응답 없음** · 챌린지 밖에서 TXT 없음 · CAA 없음 또는 `letsencrypt.org` 허용 |
| ② | Cloudflare 토큰 `joshuatech-cert-manager-dns01`이 살아 있다 | Cloudflare 대시보드 → My Profile → API Tokens | Active · **만료일 없음** · **Client IP Address Filtering 비어 있음** · 스코프가 §1 표 그대로(`Zone:DNS:Edit` + `Zone:Zone:Read`) |
| ③ | cert-manager ns의 egress 정책 2장이 그대로 있다 | 아래 kubectl | `allow-egress-external-443`(외부 443) · `allow-egress-dns-1111`(`1.1.1.1/32` 53 UDP·TCP) 둘 다 존재 |
| ④ | ACME 계정 키가 살아 있다 | 아래 kubectl | Secret `letsencrypt-prod-account-key` 존재(**값은 읽지 않는다**) |
| ⑤ | 노드 B와 admission webhook이 가동 중이다 | 아래 kubectl | cert-manager 3종 파드 Ready |
| ⑥ | LE prod 한도가 남아 있다 | 발급 이력 계산(§4 게이트 E의 공개 CT로도 센다) | 최근 7일 내 동일 SAN 발급 < 5 |

```bash
# ③ egress 정책 2장 — 이름이 사라졌거나 ns가 다르면 갱신이 챌린지 단계에서 조용히 막힌다
kubectl -n cert-manager get networkpolicy allow-egress-external-443 allow-egress-dns-1111

# ④ 계정 키 — 이 Secret이 없으면 계정을 다시 등록해야 하고 그 한도는 10회/3시간/IP다(§3)
kubectl -n cert-manager get secret letsencrypt-prod-account-key -o name

# ⑤ 노드 B·webhook — webhook은 failurePolicy: Fail이라 죽으면 CertificateRequest·Order·Challenge의 CREATE가 거부된다
kubectl -n cert-manager get pod -o wide

# 서빙 중인 인증서의 만료일(운영자 admin 전용 — agent-view는 Secret을 읽을 수 없다, §7)
kubectl -n kube-system get certificate wildcard-joshuatech-dev \
  -o jsonpath='{"notAfter="}{.status.notAfter}{" rev="}{.status.revision}{"\n"}'
```

**항목별 주의**

- ① **가장 먼저 본다.** 첫 발급을 107분 막은 원인이 바로 이 CNAME 잔재였고(§2), `infra/cloudflare/dns.tf`가 `_acme-challenge`를
  관리 대상에서 영구 제외하므로 `tofu plan`은 재발을 **영원히 감지하지 못한다**. 누가 존에 손대면 소리 없이 돌아올 수 있다.
- ② 토큰 **회전은 T084**의 몫이다. 여기서는 "회전하라"가 아니라 **"아직 유효한가"만** 본다.
  회전이 필요하면 §1의 절차를 그대로 재실행한다(cert-manager 재시작은 불필요하다).
- ⑤ 갱신 시각이 **SUC 업그레이드 창**(일요일 03:00–05:00 KST · 정본은 `platform/system-upgrade/plan-k3s-agent.yaml`의 `window`)과
  겹쳐 노드 B가 drain 중이면 그 시도는 실패한다. **치명적이지는 않다** — cert-manager가 재시도하고, 갱신은 만료 29.7일 전에 시작하므로 여유가 크다.
  다만 그 창에 본 SyncFailed·챌린지 실패를 진짜 고장으로 오독하지 않는다(헤더의 "머지 시각 조건"과 같은 성질이다).
- ⑥ 갱신 1회는 중복 슬롯 **1개**를 쓴다. 갱신이 실패해 수동으로 재발급을 반복하면 여기서 소진된다 —
  **원인 분석은 staging에서 한다**(§9). 실패 원인이 ①~⑤ 중 하나면 재발급은 몇 번을 해도 실패한다.

**갱신이 성공했는지 확인하는 법**: `.status.revision`이 **정확히 +1**(즉 `rev 3`)이고 `notAfter`가 약 +90일로 밀렸는지 본다(§4 게이트 B).
kubectl 없이는 §4 게이트 E의 공개 CT에 새 항목이 뜨는 것으로 같은 판정을 할 수 있다.
