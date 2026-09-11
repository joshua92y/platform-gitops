# platform/traefik/ — 운영자 절차 (T042 PR-4 · TLSStore `default`)

이 디렉터리는 Traefik의 **TLSStore `default` 한 장**을 소유한다. 하는 일은 하나다 —
cert-manager가 발급해 둔 Secret `kube-system/wildcard-joshuatech-dev-tls`를 Traefik의 **동적 인증서**로 적재해
`Cloudflare Full(strict) ← Traefik 443`의 오리진 체인을 확정한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | 아래 1개를 `resources`로. 전역 `namespace:` 변환기가 **없는** 이유가 머리 주석에 있다 |
| `tlsstore-default.yaml` | TLSStore `default`(ns `kube-system`) · `certificates:` 목록 1줄. 왜 `defaultCertificate`가 아닌지, 왜 병기하면 안 되는지, 왜 `kube-system`인지가 머리 주석에 소스 근거와 함께 있다 |

**소유권 경계** — Traefik 본체는 K3s 번들이고 설정 정본은 모노레포 `infra/bootstrap/traefik-config.yaml`(HelmChartConfig, T038)이다.
**TLSOption `default`는 그 파일 단독 소유**이고 여기 두지 않는다(§8). Certificate·ClusterIssuer·Secret은 `platform/cert-manager-issuers/`,
Namespace·PSA·NetworkPolicy는 `platform/policies/`, Application `platform-traefik`은 `clusters/oci-k3s/apps/`가 소유한다.

> **이 저장소에 비밀은 없다.** 인증서 Secret은 cert-manager가 만들고 Argo CD는 만들지도 지우지도 않는다(Application이 `prune: false`).

**현재 상태(2026-09-11)** — **T043 라이브 반영 완료(AOP 승격 `RequireAndVerifyClientCert` · Argo CD Ingress)** — 잔여 검증(+180초 양성 재확인·러너)과 실행 기록은 모노레포 런북 §3 T043(M5). PR-4 머지(gitops main `4f23abd`)로 prod 와일드카드가 실려 `auth.joshuatech.dev`가 526 → **404**로
바뀌었고 v2 호스트 526은 0건, 모노레포 쪽 `sniStrict`는 2026-09-10 **투입 완료**(§9.1). 이어서 2026-09-11에 AOP를
**`RequireAndVerifyClientCert`로 승격**했다 — kube-system Secret `cloudflare-origin-pull-ca` 설치 `06:39:01Z` → 관찰 단계
`VerifyClientCertIfGiven` 설치 `06:49:41Z` → 승격 설치 `2026-09-11T07:48:23Z`(정본은 모노레포 `infra/bootstrap/traefik-config.yaml`·
`cloudflare-origin-pull-ca.yaml`, 실행 기록은 모노레포 런북 §3 T043). 같은 날 Argo CD Ingress `argocd/argocd-server`(`argo.joshuatech.dev`,
`bootstrap/argocd/ingress.yaml`, gitops PR #18 → main `54fdb59`)도 라이브가 됐다. 아래 §1·§3은 **T042 시점(2026-09-10)에 실행한 절차의
기록**이며 되돌리기·재투입 때 그대로 다시 쓴다 — 단 §3 ③의 "노드 내부 curl" 판정은 승격 뒤 사정이 달라졌으므로 §9.2 D5(ii)를 따른다.

---

## 1. ⚠ 머지 순서 규율 — prod `Ready=True` 확인 **뒤에만** 머지한다

**T042 전체에서 이 PR만이 "되돌리기가 곧 장애"인 구간이다**(설계 §8 R5 · §7 단계 7). PR 순서가 **유일한 방어선**이며,
머지 버튼을 누르기 전에 아래 다섯 줄을 실제로 실행해 눈으로 확인한다. 하나라도 어긋나면 머지하지 않는다.

```bash
# ⓪ 머지 전 기준선 — 지금 auth가 무엇을 반환하는지 적어 둔다(§3 ④의 대조군)
curl -sI https://auth.joshuatech.dev | head -1
# 예상: 상태 코드 **526** (오리진이 아직 자체 서명 = 이 PR이 고치려는 상태). 머지 뒤 404로 바뀌면 성공이다.
#      프로토콜 표기(`HTTP/2` / `HTTP/1.1`)는 curl 빌드에 따라 다르다 — **상태 코드만 본다**
#      (2026-09-10 워크스테이션 실측: `HTTP/1.1 526 <none>`).
#      머지 전에 이미 404라면 어딘가 다른 경로로 인증서가 실려 있다는 뜻이므로 머지하지 말고 원인을 찾는다.

# ① Certificate가 prod로 발급 완료인가 (운영자 admin · certificates는 agent-view로도 읽힌다)
kubectl -n kube-system get certificate wildcard-joshuatech-dev \
  -o jsonpath='{.spec.secretName}{"  ready="}{.status.conditions[?(@.type=="Ready")].status}{"  rev="}{.status.revision}{"\n"}'
# 합격: wildcard-joshuatech-dev-tls  ready=True  rev=2

# ② 서빙 Secret이 실제로 존재하는가 (이름 오타·ns 오배치 검출)
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls

# ③ 발급자가 staging이 아닌가 — 체인의 진위는 이 한 줄로만 확정된다 (⚠ 운영자 admin 전용 · agent-view는 Secret get 없음)
kubectl -n kube-system get secret wildcard-joshuatech-dev-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -issuer -dates -ext subjectAltName
# 합격: issuer에 (STAGING) 표기가 **없고** · SAN = joshuatech.dev, *.joshuatech.dev · 유효기간 90일

# ④ 설치된 CRD에 spec.certificates가 실재하는가 (§4의 사전 확인 — 프루닝이면 이 PR 자체가 무의미해진다)
kubectl get crd tlsstores.traefik.io \
  -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].schema.openAPIV3Schema.properties.spec.properties.certificates.type}{"\n"}'
# 합격: array
```

**머지 시각 조건**: Traefik(kube-system, replica 1)이 Ready이고 **SUC 업그레이드 창 밖**일 것
(창의 정본은 `platform/system-upgrade/plan-k3s-server.yaml`의 `window` — 현재 일요일 03:00–05:00 KST).

---

## 2. 526 시나리오 — 왜 되돌리기가 장애인가

Cloudflare 존 SSL 모드가 **Full (strict)**다(`infra/cloudflare/zone_settings.tf` `ssl = "strict"`).
edge는 오리진이 내미는 인증서의 **체인과 SAN을 검증**하고, 통과하지 못하면 오리진에 요청을 넘기지 않고 **526**을 반환한다.

| 오리진이 서빙하는 것 | edge 판정 | 결과 |
|---|---|---|
| LE **prod** 와일드카드(`*.joshuatech.dev` + apex) | 신뢰 | 정상 |
| LE **staging** 체인 | 루트가 공개 신뢰 저장소에 없음 | **전 호스트 526** |
| Traefik 자체 서명(`TRAEFIK DEFAULT CERT`) | 신뢰 불가 | **전 호스트 526** |
| 인증서 없음(sniStrict 상태에서 매칭 실패) | 핸드셰이크 거절 | 525/526 |

표의 2·3행이 핵심이다 — **staging 상태로 이 PR을 머지하면 526이고, TLSStore를 지워 되돌려도 자체 서명으로 복귀 = 여전히 526**이다.
"적용을 취소하면 원상 복구"라는 통상의 가정이 이 구간에서만 성립하지 않는다.

**영향 범위와 살아남는 것**: 526은 Traefik 443을 지나는 **v2 호스트 전부**(`argo`·`vault`·`traefik`·`auth`·`admin`·`*-m2m-{dev,prod}` 등)에 걸린다.
다만 cloudflared 터널의 ingress는 `ssh://` 2건 + `tcp://kubernetes.default.svc:443`뿐이라 **Traefik을 경유하지 않는다**
(`infra/cloudflare/tunnel.tf`) → **443이 완전히 끊겨도 SSH·kubectl 복구 경로는 살아 있다.**
`argo.joshuatech.dev`는 **T043(2026-09-11)부터 Ingress `argocd/argocd-server`(`bootstrap/argocd/ingress.yaml`)로 Traefik 443을 탄다** —
526이든 AOP 장애든 443이 끊기면 **Argo CD UI도 함께 죽는다**(T042 시점에는 Ingress가 없어 무관했다). 그때 UI는
`kubectl -n argocd port-forward svc/argocd-server 8080:80`으로 우회한다(런북 §3 T040 방식 — Traefik 443을 지나지 않는다).
어느 쪽이든 복구의 정본은 UI가 아니라 **git revert + kubectl**이다 — `selfHeal: true` 때문에 순서가 고정돼 있다(§7).
증상 구분: **526 = 오리진 서버 인증서 계열**(이 절·§7), **525 또는 520 = AOP(클라이언트 인증서) 계열이 유력**(어느 코드인지는 미실측 — 런북 VD-7; 단 525는 §2 표의 sniStrict 매칭 실패에서도 나오므로 먼저 §9.2 D5(ii) ①(서버 인증서·notAfter)·③(TLSOption spec)으로 갈라낸다;
첫 조치는 §6 판정 ②) — 판별표는 §9.2 D5(ii).

---

## 3. 머지 뒤 확인

```bash
# ⓪ 머지 직후 Argo가 main의 새 SHA를 아직 못 볼 수 있다(reconciliation 주기 180s)
#   ⚠ 대상은 **자식 Application**이다. 이 PR이 바꾼 것은 `platform/traefik/`이고 그 경로를 보는 것은
#     child `platform-traefik`이다 — root의 source는 `clusters/oci-k3s/apps/`라 이 PR에서 바뀌지 않는다.
#     **root에만 걸면 자식에 전파되지 않는다**(2026-09-09 실측: root만 갱신했을 때 platform-cert-manager가
#     옛 리비전에서 Synced/Healthy로 보였다). root가 정답인 경우는 `apps/`가 바뀌어 **새 child가 생길 때**뿐이다(T041 PR-B2).
kubectl -n argocd annotate app platform-traefik argocd.argoproj.io/refresh=hard --overwrite

# ① Application 상태
kubectl -n argocd get app platform-traefik -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# 합격: Synced Healthy

# ② TLSStore가 **정확히 1개**인가 (⚠ traefik.io는 agent-view 권한 밖 — 운영자 admin 전용, §8)
kubectl get tlsstore -A
# 합격: kube-system/default 1개. 2개 이상이면 §8(이름 default 중복)로 간다 — 이 형태(certificates 단독)에서는
#       와일드카드 서빙이 유지되지만 Store 설정이 폐기되므로 그대로 두지 않는다.
kubectl get tlsoption -A
# 합격: kube-system/default 1개(T038 HelmChartConfig 산출물). 이 PR은 TLSOption을 만들지 않는다.

# ③ Traefik이 Secret 참조·적재에 실패하지 않았는가 (표적 스크리닝 — **적재 성공의 증거는 아니다**, 아래 참조)
#   ⚠ 넓은 패턴('certificate|tls')으로 찾지 않는다. 이 클러스터는 **JSON 접근 로그가 켜져 있고**
#     필터가 `statuscodes: "400-599"`라(모노레포 `infra/bootstrap/traefik-config.yaml`), T042 시점에는
#     Ingress가 없어 모든 요청이 404다 → 접근 로그 줄이 계속 쌓여 "0건" 판정이 불가능해진다.
#     아래는 v3.7.8 소스에서 그대로 옮긴 **실제** 메시지다(임의 문면으로 찾으면 놓친다).
kubectl -n kube-system logs deploy/traefik --since=10m \
  | grep -E 'Unable to read certificate secret|Unable to parse certificate|Could not get certificate blocks|Failed to fetch secret|does not exist|Default TLS (Stores|Options) defined'
# PowerShell:
#   kubectl -n kube-system logs deploy/traefik --since=10m |
#     Select-String -Pattern 'Unable to read certificate secret|Unable to parse certificate|Could not get certificate blocks|Failed to fetch secret|does not exist|Default TLS (Stores|Options) defined'
#
# 각 문자열의 뜻 — `certificates:` 경로(이 PR이 쓰는 경로)는 **2단**이라 실패 문면도 2종이다:
#   · Unable to read certificate secret <ns>/<name>, skipping   ← 1단: Secret이 없거나 tls.crt/tls.key 키가 없음
#   · Unable to parse certificate <name>                        ← 2단: 키는 있으나 X509KeyPair 파싱 실패
#                                                                  → **그 인증서만 조용히 탈락**한다(가장 놓치기 쉬움)
#   · Failed to fetch secret <ns>/<name>                        ← `defaultCertificate` 경로(이 PR에는 없어야 정상)
#   · Secret <ns>/<name> does not exist                         ← 〃
#   · Could not get certificate blocks                          ← 〃
#   · Default TLS Stores/Options defined in multiple namespaces ← 이름 `default` 중복(§8)
#
# 합격: 0건. ⚠ **0건은 "알려진 실패 문면이 없다"는 뜻일 뿐 "인증서가 실렸다"는 뜻이 아니다.**
#   어떤 로그 목록도 닫힌 집합이 될 수 없다 — 이 PR의 지배적 실패 모드인 **유효하지만 틀린 인증서**
#   (staging 체인·만료된 prod)는 파싱에 성공하므로 로그를 **한 줄도 남기지 않는다.**
#   적재 여부의 정본 증거는 **§9.2 D5(ii) ①의 `openssl s_client -servername`**(issuer + notAfter)이고, ③이 0건이어도
#   ④가 526이면 인증서 경로를 용의선상에서 빼지 않는다.
#   (T042 실행 당시에는 §9.3 판별 실험 ①의 노드 내부 curl이 그 증거였다 — AOP 승격(2026-09-11) 뒤에는 무인증서 curl이
#    거절되는 것이 정상이라 openssl로 대체했다. 서버 인증서는 클라이언트 인증서와 무관하게 서버 플라이트로 오므로 승격 뒤에도 읽힌다.)

# ④ ⚠ edge 검증 — 반드시 auth 루트로 한다 (§5)
curl -sI https://auth.joshuatech.dev | head -1
# 합격: 오리진이 만든 상태 코드(T042 시점에는 그 호스트의 Ingress가 없으므로 Traefik 404)
# 불합격: 526 → 오리진 인증서 문제 확정. 다음 단계로 가지 말고 §6·§7.
```

---

## 4. ⚠ CRD 왕복 확인 — `spec.certificates`가 살아 있는가

TLSStore CRD가 `spec.certificates`를 모르면 API 서버가 그 필드를 **조용히 잘라낸다**(구조적 프루닝).
그러면 Argo는 Synced/Healthy로 보이는데 Traefik에는 인증서가 한 장도 실리지 않는다 — **무증상 실패**다.
차트 40.1.0의 `crds/traefik.io_tlsstores.yaml`에 `certificates`(array of `{secretName}`, required)가 실재함은 2026-09-09에 확인했지만,
**라이브 설치본은 다를 수 있으므로** 머지 직후 왕복을 반드시 확인한다.

```bash
# ⚠ 운영자 admin 전용 — traefik.io는 agent-view 권한 밖(§8)
kubectl -n kube-system get tlsstore default -o jsonpath='{.spec.certificates[0].secretName}{"\n"}'
# 합격: wildcard-joshuatech-dev-tls
# 빈 값  : **명령이 exit 0이고 stderr가 비었을 때만** CRD 프루닝으로 판정한다
#          (Forbidden도 stdout이 비므로 stderr를 먼저 본다 — agent-view kubeconfig로 실행하면 오진한다)
#          → **즉시 중단**(당시 규율은 "여기서 sniStrict로 진행하지 않는다"였다 — 재적용 때도 같다, §7·§9).
#          이 경우 Traefik은 자체 서명으로 서빙 중이므로 이미 526일 수 있다 → §7 되돌리기 + forward-fix(§7 마지막 문단).
#          (§6 즉효 레버는 이때도 당기지 않는다 — CRD 프루닝 526은 서버 인증서 계열이라 §7 근본 복구가 답이고,
#           T043 뒤에도 526 뒤에 사용자 트래픽이 없다. 판정 순서는 §6.)
```

---

## 5. 왜 edge 검증이 `auth.joshuatech.dev`인가 (설계 §14.3-1)

설계 초안의 `curl -sI https://traefik.joshuatech.dev → 302` 확인은 **526을 탐지하지 못한다.**
Cloudflare Access가 **edge에서** 302를 돌려주므로 요청이 오리진에 도달하지 않고, 오리진 인증서 상태가 응답에 전혀 반영되지 않기 때문이다
(2026-09-04 실측 기록: `tests/platform/ingress.tests.ps1` 머리 주석).

| 호스트 | edge 동작 | 526 탐지 |
|---|---|---|
| `argo` | Ingress `argocd/argocd-server`(T043)로 오리진에 닿는 호스트지만 GitHub IdP Access 앱이 **전체 호스트** 보호 → 루트는 항상 edge 302 | ✗ |
| `vault` · `traefik` · `admin` | GitHub IdP Access 앱이 **전체 호스트** 보호 → 항상 302 | ✗ |
| `identity-m2m-prod` · `identity-m2m-dev` | Service Auth 401 | ✗ |
| `preview` | A 레코드 없음 | ✗ |
| **`auth`** | Access 앱이 **`/if/admin` 경로만** 보호 → 루트는 오리진까지 도달 | **✓ 유일** |

→ v2 A 레코드 7개 중 오리진 상태 코드가 반영되는 것은 **`auth` 루트뿐**이다(T043 뒤에도 같다 — `argo`에 Ingress가 생겼어도 Access 302가 앞선다).
sniStrict 투입(2026-09-10) 뒤에도 와일드카드 SAN이 `auth.joshuatech.dev`를 덮으므로 이 검증은 그대로 유효하다 —
투입 직후 실측도 `404`(526 아님)로 변화가 없었다(§9.1). AOP 승격(2026-09-11) 뒤에도 `auth`는 404를 유지했다 — edge가 Cloudflare
클라이언트 인증서를 내밀므로 이 검증은 **443 생존 판정**(§9.2 D5(ii) ②)으로 계속 쓴다. 단 여기서 보이는 것은 서버 인증서 계열(526)뿐이고,
AOP 계열은 525 또는 520으로 나타난다(어느 쪽인지 미실측 — VD-7; 525는 §2 표의 sniStrict 매칭 실패에서도 나오므로 §9.2 D5(ii) ①·③으로 먼저 갈라낸다).

---

## 6. 526 즉효 레버 — Cloudflare SSL `strict` → `full` (⚠ 존 전역)

526이 걸렸고 근본 복구(§7)에 시간이 필요할 때 쓰는 **한시 레버**다. `full`은 오리진 인증서의 체인·SAN을 검증하지 않으므로
자체 서명·staging 체인이어도 트래픽이 통과한다.

> ### ⚠ 이 레버는 **존 전역 설정**이다
>
> **⚠ 당기기 전 필수 판정 — 증상을 먼저 분류하고, 526 뒤에 사용자 트래픽이 없으면 당기지 않는다.**
> 판단 기준은 "526이 보이는가"가 아니라 **"526 뒤에 실제 사용자 트래픽이 있는가"**다.
> T043(2026-09-11) 뒤 **이 저장소의** Ingress는 `bootstrap/argocd/ingress.yaml`(`argo.joshuatech.dev`) **1개**이고
> (`grep -rn '^kind: Ingress' platform/ clusters/ bootstrap/`), 라이브에는 차트가 만든 `traefik-dashboard` IngressRoute 1개가 더 있다
> (`traefik.joshuatech.dev`). 둘 다 GitHub IdP Access 뒤의 **운영자 트래픽**이고 사용자(앱) 호스트의 Ingress는 없다(앱 Application은 후속 PR).
> 즉 지금의 526 뒤에도 **서비스 중인 사용자 트래픽은 없다** — 가용성 이득 0에 v1 존 전역 보안 저하만 남으므로 **당기지 않는다**.
> Argo CD UI는 `port-forward`로 우회한다(§2).
>
> **T043 뒤의 판정 순서**
> ① **526 = 오리진 서버 인증서 계열** → 먼저 근본 복구(§7 + forward-fix); 레버는 526 뒤에 사용자 트래픽이 있고 근본 복구가 길어질 때만(지금은 해당 없음). `notAfter`부터 본다(§9.2 D5(ii) ①).
> ② **525 또는 520 = AOP(클라이언트 인증서) 계열이 유력**(어느 코드인지는 미실측 — 런북 VD-7; 525는 sniStrict 매칭 실패(§2 표)일 수도 있으니 §9.2 D5(ii) ①·③으로 먼저 갈라낸다) → 이 레버는 **무관**하다: `full`은 edge의
>    오리진 **서버** 인증서 검증만 끄고, 오리진(Traefik)이 edge의 클라이언트 인증서를 요구·거절하는 쪽은 바꾸지 않는다.
>    첫 조치는 모노레포 `infra/bootstrap/traefik-config.yaml`의 **clientAuth 없는 사본(`traefik-config.pre-t043.yaml`) 재설치**
>    (그 파일 헤더 절차 1~2 · 반영 약 15초 · 롤아웃 없음 — 30초 안에 끝난다)이고, Secret `cloudflare-origin-pull-ca`는 그 뒤에도
>    지우지 않는다(계약 §오리진 보호 3중 2.의 되돌리기 순서: clientAuth 제거 → spec에서 빈 값 확인 → 그다음에야 Secret). 판별표는 §9.2 D5(ii) ⑤.
>
> 정본은 `infra/cloudflare/zone_settings.tf`의 `cloudflare_zone_setting.ssl`이고 값은 존 하나에 하나뿐이다.
> 당기는 순간 v2 호스트만이 아니라 **v1 매출 경로(`api`·`mainapi`·`mcp`·`cache`·apex·`www`)의 오리진 검증까지 함께 꺼진다.**
> **가용성 영향 0 · 보안 영향 ≠ 0**이며, 되돌림을 검출할 자동 경로가 **없다**
> (tofu 자동 apply 없음 · `tests/infra/tofu.tests.ps1`에 `ssl=strict` 단언 0건).
>
> **규율 3가지**
> 1. **같은 유지보수 창 안에서 반드시 `strict`로 복구한다.** 창을 넘기지 않는다.
> 2. 하향 시각과 복구 시각을 **런북 §3에 남긴다**(자동 검출이 없으므로 기록이 유일한 감사 흔적이다).
> 3. 콘솔에서 손으로 바꿨다면 코드(`zone_settings.tf`)와의 드리프트가 생긴 것이다 — 복구 뒤 `tofu plan`이
>    **No changes**인지 확인한다. (`ssl=strict` 드리프트 단언 추가는 T047/converge 인계 후보.)

레버를 쓰지 않고 버티는 근거는 T043 뒤에도 그대로다: 526은 **v2 플랫폼 호스트에만** 걸리고 v1 매출 경로는 이 인증서를 쓰지 않는다.
SSH·kubectl 복구 경로도 살아 있으므로(§2), 사용자 호스트의 Ingress가 생긴 뒤에도 근본 복구가 수 분 내면 **당기지 않는 쪽이 낫다.**
(사용자 트래픽이 없는 지금은 "낫다"가 아니라 **당기지 않는다** — 위 판정 참조.)

---

## 7. 되돌리기 — **PR-4만** revert 한다

### ⚠ PR-3(prod 승격)을 revert 하지 마라

PR-3은 `issuerRef`와 `secretName`을 **한 커밋으로** 바꿨다. 되돌리면 Certificate의 쓰기 대상이 `…-tls-staging`으로
돌아가고, 서빙 Secret `wildcard-joshuatech-dev-tls`는 **갱신 주체를 잃은 채 남는다**
(`enableCertificateOwnerRef: false` 기본값 — Certificate가 대상을 바꿔도, 삭제돼도 발급된 Secret은 지워지지 않는다:
`platform/cert-manager-issuers/README.md` §10).

**즉시 526이 되지는 않는다.** Traefik은 그 Secret의 prod 인증서를 만료일까지 계속 서빙한다.
위험은 반대 방향의 **조용한 만료 폭탄**이다:
- 갱신 주체가 없으므로 남은 유효기간(최대 90일)이 지나면 아무 경고 없이 **전 호스트 526**이 된다.
  ⚠ 이때 오리진은 **자체 서명으로 바뀌지 않는다.** Traefik의 인증서 적재는 `tls.X509KeyPair` 파싱만 하고
  유효기간을 검사하지 않으므로(v3.7.8 `certificate_store.go` `parseCertificate` — `NotAfter` 참조 0건)
  **만료된 LE 인증서를 그대로 계속 내민다.** edge 결과는 똑같이 526이지만 §9.2 D5(ii) ①의 `openssl s_client`에는
  `TRAEFIK DEFAULT CERT`가 아니라 정상 발급자(`CN=YE2`)가 보인다 — "자체 서명을 찾는" 진단은 여기서 헛돈다.
  526을 만나면 **`notAfter`를 먼저 본다**(§9.2 D5(ii) ①의 `notAfter=` 줄).
- 만료 알림은 T098 전까지 존재하지 않는다(§10).
- 유일한 자동 신호는 `cert-1`(`found 0`)·`cert-2`이고, 그 문면은 "cert-manager 고장"과 구별되지 않는다
  (`platform/cert-manager-issuers/README.md` §6).

그래서 **PR-4 이후의 되돌리기는 PR-4만 revert 한다.** 부득이 PR-3을 되돌린다면 만료일을 사람이 기록·감시하는
조건에서만 하고 즉시 forward-fix(prod 재승격)를 계획한다 — prod 동일 SAN 중복 한도는 **5/7일이고 override가 없다**
(`platform/cert-manager-issuers/README.md` §9).

`issuerRef`만 되돌리는 1줄 revert는 다르다 — 그쪽은 **성공한 staging 재발급이 서빙 Secret을 덮어 즉시 전 호스트 526**이고
`selfHeal: true`라 자동 적용된다. **PR-4 이후에는 존재하지 않는 선택지다**(설계 §14.2 각색 D가 없앤 경로).

### 되돌리기 3단 — 순서를 뒤집지 않는다

**0단이 먼저다 — `sniStrict`를 제거한다.** 종전 문면은 이 단계를 "sniStrict를 이미 적용한 뒤라면"이라는 **조건문**으로
적었는데, 2026-09-10 17:24 KST 투입(§9)으로 그 조건은 **항상 참**이 됐다. 그래서 조건이 아니라 기본 순서다.

```text
0단: 모노레포 infra/bootstrap/traefik-config.yaml의 `tlsOptions.default`에서 `sniStrict: true`를 빼고 노드 A에 재설치한다
     (그 파일 헤더의 절차 1~2). 반영에 약 15초가 걸리므로
     `kubectl -n kube-system get tlsoption default -o yaml`의 spec에서 사라진 것을 **눈으로 확인한 뒤** 1단으로 간다.
```

0단을 건너뛰고 TLSStore부터 지우면 `GetBestCertificate`가 `nil`을 반환하고 `sniStrict` 때문에 폴백 없이 `nil, nil` →
**443 전면 중단**이다(설계 §8 R6).

**0단만 하고 멈추면 서빙은 그대로다.** TLSStore가 남아 있어 SNI가 일치하는 v2 호스트는 계속 와일드카드를 받는다 —
달라지는 것은 SNI 불일치 요청이 `000`(핸드셰이크 거절) 대신 자체 서명을 받는 것뿐이고, Cloudflare edge는 항상 일치하는 SNI를
보내므로 **엣지 영향이 없다**. 자체 서명 복귀 = 전 호스트 526은 **2단(TLSStore 삭제) 뒤**의 상태이고, 그것이 되돌리기 도중의
정상 중간 상태다(§2). 0단 직후에 526이 보이면 원인은 다른 데 있다.

```bash
# 1단: git revert 머지가 **먼저**다. 반대로 하면 selfHeal이 즉시 되살린다.
#      (PR-4 revert PR을 만들어 머지한다 — 이 저장소에서 직접 push 하지 않는다.)
#   ⚠ 머지가 즉시 반영되지 않으면 당긴다 — 대상은 **자식**이다(root는 이 경로를 보지 않는다, §3 ⓪):
#        kubectl -n argocd annotate app platform-traefik argocd.argoproj.io/refresh=hard --overwrite
#   ⚠ PR을 머지할 수 없는데(GitHub 장애·리뷰 대기) 지금 지워야 하면 selfHeal을 먼저 멈춘다:
#        kubectl -n argocd scale sts argocd-application-controller --replicas=0
#      복구 뒤 --replicas=1로 되돌리고, 그 전에 revert 머지를 반드시 끝낸다.
#      (child Application만 `automated: null`로 패치하면 root의 selfHeal이 되돌린다 — 런북 §3.)

# 2단: revert 머지가 Synced 된 것을 확인한 **뒤에** 운영자가 수동 삭제한다.
#      revert만으로는 리소스가 사라지지 않는다 — Application이 `prune: false` + `Prune=confirm`/`Delete=confirm`이라
#      git에서 빠진 리소스는 OutOfSync로 남을 뿐이다(설계 §8 R9).
kubectl -n kube-system delete tlsstore default
```

**되돌린 뒤의 상태는 "정상"이 아니다.** Traefik은 자체 서명으로 돌아가므로 Full(strict)에서 여전히 526이다(§2).
되돌리기는 잘못된 인증서를 치우는 조치일 뿐이고, 서비스 회복은 **올바른 Secret을 다시 실어야** 끝난다.

---

## 8. 관측 사각 · 이름 `default` 중복 (설계 §8 R7 · R18)

**agent-view는 `traefik.io` 그룹(TLSStore·TLSOption·IngressRoute)을 읽지 못한다.** `cert-1`/`cert-2` 검사는 Certificate만 보므로
"Traefik이 실제로 그 인증서를 서빙하는가"는 **운영자 admin·노드 내부 `openssl s_client -servername` 전용**으로 남는다(계약 §에이전트 자격 변경 후보).
AOP 승격(2026-09-11) 뒤에는 노드 내부 **무인증서 curl이 거절되는 것이 정상**이라 서빙 확인 수단이 아니다 — 서버 인증서는 CertificateRequest와
무관하게 서버 플라이트로 오므로 `openssl s_client`로는 승격 뒤에도 읽힌다(§9.2 D5(ii) ①).

**이름이 `default`인 TLSStore/TLSOption은 ns와 무관하게 전역 id로 승격되고, 두 개 이상 존재하면 그 이름의 항목이 삭제된다.**
다만 **삭제되는 대상이 다르다**(v3.7.8 `kubernetes.go` 실측) — 진단할 때 둘을 바꿔 찾지 않도록 구분해 둔다.

| 중복 대상 | 삭제되는 것 | 살아남는 것 | 실제 증상 |
|---|---|---|---|
| **TLSOption `default`** | 옵션 객체 자체(`kubernetes.go:1380`) | 서버가 **내장 기본값**으로 되돌아감(`tlsmanager.go:34-38`) | `minVersion`은 그대로 `VersionTLS12`(내장 기본이 같은 값) · **내장 기본이 없는 설정만 소실** = 2026-09-10 투입한 **`sniStrict`**와 2026-09-11 승격한 **`clientAuth`(AOP 검증)** — 둘 다 실려 있으므로 중복 즉시 **둘 다 사라진다**(= AOP 검증 해제, 무인증서 직접 TLS가 다시 통과). 투입 완료 상태의 **현재형** 위험이다 |
| **TLSStore `default`** | Store 설정만(`defaultCertificate`·`defaultGeneratedCert` — `kubernetes.go:1450`) | **`certificates:` 목록 전부**(이미 `tlsConfigs`에 담겨 DynamicCerts로 편입) | 이 형태에서는 **와일드카드 서빙 유지** |

삭제 호출은 `delete(tlsOptions, tls.DefaultTLSConfigName)`과 `delete(tlsStores, tls.DefaultTLSStoreName)`이고
두 상수의 값은 모두 `"default"`다(`tlsmanager.go:27`·`:30`) — 소스에서 리터럴 `"default"`로 찾으면 나오지 않는다.
양쪽 모두 Error 로그를 남긴다(`Default TLS Options/Stores defined in multiple namespaces: [...]`).
그러나 **TLS 핸드셰이크는 계속 성공하므로 동작으로는 드러나지 않는다** — 로그를 보지 않으면 무증상이다.

⚠ TLSOption 행의 "내장 기본값 복귀"는 **중복이 같은 provider(Kubernetes CRD) 안에서 일어날 때**의 이야기다
(차트가 만드는 TLSOption과 이 디렉터리가 만들 TLSOption은 둘 다 CRD provider라 이 경우에 해당한다).
**서로 다른 provider**가 각각 `default`를 주면 집계기가 지우기만 하고 기본값을 넣지 않아
그 옵션에 의존하는 **라우터 초기화가 통째로 실패한다**(`aggregator.go` — "cascading failure" 주석).
어느 쪽이든 결론은 같다: 각각 정확히 한 곳. 그래서 소유권을 못박았다.

| 객체 | 정본 소유 | 금지 |
|---|---|---|
| TLSStore `default` | **이 디렉터리**(gitops) | 모노레포 `traefik-config.yaml`에 `tlsStore:` 블록 추가 금지 |
| TLSOption `default` | 모노레포 `infra/bootstrap/traefik-config.yaml`(HelmChartConfig) | 이 디렉터리에 TLSOption 추가 금지 |

계약 `gitops-repo.md` §디렉터리는 **kind 화이트리스트**이고 같은 줄이 HelmChartConfig를 Traefik 자체 설정의 정본으로 지목하므로
이 배치는 계약과 **충돌하지 않는다** — 다만 이름 `default` 중복(R7)이 무증상 보안 회귀이므로 소유권을 여기서 못박는다.
확인은 §3 ②의 `kubectl get tlsstore,tlsoption -A`(각각 정확히 1개).

---

## 9. sniStrict·clientAuth — **투입 완료** · 판별 실험 D5(ii)

TLSOption `default`에는 지금 `minVersion: VersionTLS12` + `sniStrict: true`(2026-09-10) + `clientAuth{secretNames: [cloudflare-origin-pull-ca],
clientAuthType: RequireAndVerifyClientCert}`(2026-09-11 승격)가 실려 있다. 정본은 모두 모노레포 `infra/bootstrap/traefik-config.yaml`이고
이 디렉터리는 TLSStore만 소유한다(§8). 9.1은 투입 기록, 9.2가 **승격 뒤의 현재 판정(D5(ii))**, 9.3은 승격 전·재투입 전용 판별이다.

### 9.1 투입 기록 — sniStrict(2026-09-10 17:24 KST) · clientAuth(2026-09-11)

PR-4(이 디렉터리의 TLSStore)가 머지된 **뒤에** 판별 실험 ①②(§9.3)를 노드 A 안에서 실행해 둘 다 성립하는 것을 확인하고 `sniStrict: true`를 켰다.
스위치는 이 저장소가 아니라 모노레포 `infra/bootstrap/traefik-config.yaml`의 `valuesContent` → `tlsOptions.default`에 있다
(D5 = T042 단계 9, 커밋 `0bdc621`+`829226d`). 아래는 그날 실제로 얻은 출력이다.

| 실험 | SNI | 실측 출력 | 뜻 |
|---|---|---|---|
| ① | `traefik.joshuatech.dev`(일치) | issuer `C=US; O=Let's Encrypt; CN=YE2` · `expire date Dec  8 08:59:09 2026 GMT` | 와일드카드가 **DynamicCerts에 편입**돼 SNI 매칭에 잡힌다 |
| ② | `no-such.example.invalid`(불일치) | `subject`·`issuer` 모두 `CN=TRAEFIK DEFAULT CERT` | 폴백이 와일드카드가 **아니다** = `defaultCertificate` 미설정 |

②가 자체 서명이라는 것이 "sniStrict를 켜도 가려질 폴백이 없다"의 증거다(와일드카드가 나왔다면 어딘가 `defaultCertificate`가
설정돼 있다는 뜻이므로 켜지 않는다). **최종 판정은 적용 뒤 ②를 다시 돌린 결과였다 — 그 요청이 `000`(핸드셰이크 거절)으로
바뀌었다.** ①은 그대로 LE 와일드카드다. Cloudflare edge는 항상 SNI를 보내므로 서비스 영향은 없고, 실제로 `auth`는 404를 유지했다.

**운영 정보 — 투입/제거는 파드를 건드리지 않는다.** `tlsOptions`만 바꾸는 값은 차트가 `templates/tlsoption.yaml`의 CR 하나로만
렌더하므로 **Deployment 롤아웃이 나지 않는다**: 실측에서 파드 AGE·RESTARTS가 그대로였고(6일째 같은 파드) **443 순단은 0초**였다.
대신 파일 설치 → K3s deploy 컨트롤러가 집기까지 **약 15초** 걸리므로 직후 조회하면 옛 spec이 보인다 — 실패로 오독하지 않는다.
정본 서술은 모노레포 `traefik-config.yaml` 헤더의 절차 3(b)·4다. clientAuth 투입·승격도 같은 성질(`tlsOptions`만)이라 롤아웃이 없었다.

**clientAuth(AOP) 투입 기록 — 2026-09-11, T043.** 순서는 계약 §오리진 보호 3중 2.대로 **Secret → 지문·notAfter 대조 → clientAuth**였다:
kube-system Secret `cloudflare-origin-pull-ca`(키 `ca.crt`, 정본 모노레포 `infra/bootstrap/cloudflare-origin-pull-ca.yaml`, K3s AddOn) 설치
`06:39:01Z` → 관찰 단계 `clientAuthType: VerifyClientCertIfGiven` 설치 `06:49:41Z` → 승격 `RequireAndVerifyClientCert` 설치
`2026-09-11T07:48:23Z`. 관찰 단계 실측: 매트릭스 8 호스트(`auth`·`api`·`mcp`·`argo`·`vault`·`admin`·`identity-m2m-prod`·`identity-m2m-dev`)의
`/__probe-404` 액세스 로그 전부에 `TLSClientSubject=CN=origin-pull.cloudflare.net,O=Cloudflare Inc.,L=San Francisco,ST=CA,C=US`(TLS 1.3)가
찍혔고, 노드 A 자체 서명 클라이언트 인증서는 `TLS alert, unknown CA (560)`으로 거절, 무인증서는 (관찰 단계라) 404 통과였다 —
`VerifyClientCertIfGiven`도 **제시된 인증서는 검증**하므로 관대한 것은 "인증서 부재"뿐이었다. `traefik` 호스트는 대시보드가 `api@internal`이라
액세스 로그에 **구조적으로 남지 않는다**(Traefik v3 `accesslog.addInternals` 기본 false) — TLSOption `default`는 라우터 무관 전역이므로
8 호스트로 충족하며, 승격 뒤 양성 재확인에서도 `traefik` 줄은 기대하지 않는다. 승격 설치 시각을 포함한 실행 기록의 정본은 모노레포 런북 §3 T043이다.

### 9.2 판별 실험 D5(ii) — 승격 뒤의 현재 판정(①~⑤)

승격 뒤에는 **노드 내부 무인증서 curl이 거절되는 것이 정상**이라 T042 때의 판별 실험 ①(§9.3)로는 서버 인증서를 읽을 수 없다.
그래서 판정을 다섯으로 나눈다. 명령은 모노레포 `traefik-config.yaml` 헤더 절차 4와 같다(노드 A 안 · 사설 IP `10.0.7.78` · `traefik.io` 조회는
운영자 admin 전용, §8).

```bash
# ① 서버 인증서(LE 발급자 + notAfter) — 클라이언트 인증서 없이 읽힌다: 서버 인증서는 CertificateRequest와 무관하게
#    서버 플라이트로 오므로 승격 뒤에도 그대로다. 526 진단 시 1순위(§7 — 만료된 인증서도 계속 서빙된다).
ssh … ubuntu@<노드 A> "echo | openssl s_client -connect 10.0.7.78:443 -servername traefik.joshuatech.dev 2>/dev/null \
  | openssl x509 -noout -issuer -enddate"
# 합격: issuer=C = US, O = Let's Encrypt, CN = YE2 · notAfter=Dec  8 08:59:09 2026 GMT(갱신되면 뒤로 밀린다; OpenSSL 3.x 출력은 ' = ' 구분자)
#   (TLS 1.3에서는 s_client 자체가 핸드셰이크 성공처럼 보이고 그 뒤 alert가 온다 — 인증서 출력은 그 전에 끝나므로 판정에 지장이 없다.)

# ② 443 생존 — edge 경유 auth 루트(§5). 보조: 공개 CT 로그(crt.sh)의 와일드카드 발급 이력.
curl -sI https://auth.joshuatech.dev | head -1
# 합격: 404(오리진 Traefik이 만든 코드 = 서버 인증서·AOP 둘 다 통과). 526 = 서버 인증서 계열(§7) · 525/520 = AOP 계열이 유력(§6 판정 ② — 525는 sniStrict 매칭 실패일 수도 있어 ①·③으로 먼저 갈라낸다).

# ③ TLSOption 반영 — spec + 로그 grep 6패턴(⚠ traefik.io는 운영자 admin 전용 — §8)
kubectl -n kube-system get tlsoption default -o yaml
# 합격: spec에 minVersion: VersionTLS12 · sniStrict: true · clientAuth{secretNames: [cloudflare-origin-pull-ca], clientAuthType: RequireAndVerifyClientCert}
kubectl get tlsoption -A
# 합격: 이름 default 정확히 1개(2개면 옵션 통째 폐기 = sniStrict·clientAuth 소실, §8)
kubectl -n kube-system logs deploy/traefik --since=10m \
  | grep -E 'CAFiles is required|invalid certificate|does not exist|Failed to extract CA|unknown client auth|Default TLS Options defined in multiple'
# 합격: 0줄(--tail은 옛 로그를 보여 무의미 · 일반 error는 T098 전 OTLP 잡음이라 게이트에 쓰지 않는다)

# ④ AOP 양성 — edge 프로브의 액세스 로그 줄에 TLSClientSubject가 있어야 한다.
#    ⚠ TLSOption 반영 시각 + idleTimeout(기본 180초) **이후**의 프로브만 유효하다 — 옛 keep-alive 연결은 옛 TLS 설정으로 산다.
curl.exe -sI https://auth.joshuatech.dev/__probe-404
kubectl -n kube-system logs deploy/traefik --since=5m | grep __probe-404 | tail -1
# 합격: "TLSClientSubject":"CN=origin-pull.cloudflare.net,O=Cloudflare Inc.,L=San Francisco,ST=CA,C=US" · TLSVersion 1.3
#   (traefik. 호스트는 api@internal이라 이 로그가 남지 않는다 — auth 등 8 호스트로 판정한다, §9.1)

# ⑤ AOP 음성(승격 뒤 정상) — 노드 내부 무인증서 직접 TLS는 거절돼야 한다. 판정은 http 코드가 아니라 -v의 TLS alert로 한다.
ssh … ubuntu@<노드 A> "curl -skv --resolve traefik.joshuatech.dev:443:10.0.7.78 https://traefik.joshuatech.dev \
  -o /dev/null -w 'exit=%{exitcode} http=%{http_code}\n' 2>&1 | grep -Ei 'TLS alert|exit='"
ssh … ubuntu@<노드 A> "curl -skv --tls-max 1.2 --resolve traefik.joshuatech.dev:443:10.0.7.78 https://traefik.joshuatech.dev \
  -o /dev/null -w 'exit=%{exitcode} http=%{http_code}\n' 2>&1 | grep -Ei 'TLS alert|exit='"
# 합격: http=000 + 아래 판별표의 "인증서 부재" 줄. 302/404 같은 숫자가 나오면 clientAuth가 실려 있지 않은 것이다(→ ③).
```

**⑤ 판별표 — `curl -v`의 TLS alert 리터럴로 원인을 가른다**(2026-09-11 실측):

| stderr 리터럴 | 뜻 | 판정 |
|---|---|---|
| TLS 1.3: `tlsv13 alert certificate required` — curl -v 표기 `TLS alert, unknown (628)`, exit 56 | post-handshake에서 서버가 클라이언트 인증서를 요구했는데 없음 | **인증서 부재** = 승격 뒤 **정상** |
| TLS 1.2: `TLS alert, handshake failure (552)`, exit 35 | 핸드셰이크 중 거절 | **인증서 부재** = 승격 뒤 **정상** |
| `TLS alert, unknown CA (560)` · `bad certificate` | 제시한 인증서가 CA `origin-pull.cloudflare.net`과 불일치(관찰 단계 자체 서명 실측) | **인증서 불일치** — 관찰 단계(Verify)에서도 똑같이 실패한다 |
| `TLS alert, unrecognized name (624)` | SNI가 와일드카드 SAN과 불일치(`no-such.example.invalid`) | **SNI 불일치** = sniStrict 정상 |

curl exit 56/35는 참고값이고 판정은 alert·거절 여부로 한다(계약 §오리진 보호 3중 2.). 워크스테이션에서 공인 IP로 걸면 NSG 때문에 늘 000이며
거절과 구분되지 않는다 — 반드시 노드 안에서 실행한다.

### 9.3 판별 실험 ①② — 승격 전 마지막 점검 · clientAuth 재투입 절차 전용

①②는 **clientAuth가 빠진 상태에서만 성립한다** — ①이 무인증서 curl이라 승격된 현재 상태에서는 거절되는 것이 정상이고, 그것은 실패가 아니라
D5(ii) ⑤의 합격이다. 그래서 지금은 두 경우에만 쓴다: **되돌리기 뒤 재투입**(§7의 0단으로 sniStrict를 뺐다가 다시 켤 때 · §6 판정 ②로
clientAuth를 pre-t043 사본으로 내렸다가 다시 올리기 직전의 마지막 점검)과 T042 실행 기록(§9.1)의 재현. **526 진단**은 §9.2 D5(ii) ①로 옮겼다.

`/api/certificates`는 DynamicCerts와 DefaultCertificate를 **합쳐서** 반환하므로 판별에 쓸 수 없다.
소스가 보장하는 판별은 **SNI 두 개 비교**다. 워크스테이션은 Cloudflare 대역 밖이라 NSG에서 먼저 막혀 늘 000이므로 **노드 A 안에서** 실행한다
(런북 §3 T038 절차 4와 같은 형식).

```bash
# ① SNI 일치 → LE 와일드카드가 나와야 한다 = DynamicCerts 매칭 성공
#   ⚠ `expire date`를 반드시 함께 본다 — Traefik은 만료된 인증서도 계속 서빙하므로(§7)
#     발급자만 보면 "정상"으로 오독한다. (승격 뒤 526 진단은 §9.2 D5(ii) ① — 이 curl 은 클라이언트 인증서 없이는 거절되므로 여기 ①은 재투입 절차 전용이다.)
ssh … ubuntu@<노드 A> "curl -skv --resolve traefik.joshuatech.dev:443:10.0.7.78 \
  https://traefik.joshuatech.dev -o /dev/null 2>&1 | grep -Ei 'subject:|issuer:|subjectAltName|expire date|start date'"

# ② SNI 불일치 → 자체 서명 'TRAEFIK DEFAULT CERT'가 나와야 한다 = 폴백 경로가 와일드카드가 아님
ssh … ubuntu@<노드 A> "curl -skv --resolve no-such.example.invalid:443:10.0.7.78 \
  https://no-such.example.invalid -o /dev/null 2>&1 | grep -Ei 'subject:|issuer:'"
```

**①②가 둘 다 성립할 때만 sniStrict를 켠다** — 재투입에도 같은 규율이다. ②에서 와일드카드가 나오면 어딘가에
`defaultCertificate`가 설정된 것이므로 켜지 않고 원인을 찾는다. 이미 켜져 있는 동안에는 ②가 `000`이므로 이 판별을 하려면
0단(§7)으로 sniStrict를 먼저 빼야 하고, 승격 뒤에는 ①도 `000`(인증서 부재 거절)이므로 **clientAuth까지 뺀 사본(pre-t043)에서만** ①②가 읽힌다.
보조 판별: 차트 값 `logs.general.level: DEBUG`를 한시 적용하면 편입은 `Adding certificate for domain(s) …`, 폴백 사용은
`Serving default certificate for request: …`로 직접 보인다(확인 후 INFO 복귀 — 이것은 `tlsOptions`와 달리 **Traefik 롤아웃을 유발한다**).

투입·재투입 전에는 **노드 A에 현재 파일 사본을 반드시 먼저 보존한다**(1분 롤백 — clientAuth 없는 사본은 `traefik-config.pre-t043.yaml`).
적용 순서는 T038 헤더가 못박은 대로 **T042(와일드카드가 동적 인증서가 된 것 확인) → sniStrict → T043(CA Secret) → clientAuth**이고,
**네 단계 모두 끝났다**(sniStrict 2026-09-10 · CA Secret 2026-09-11 `06:39:01Z` · clientAuth 관찰 `06:49:41Z` → 승격 `2026-09-11T07:48:23Z` —
기록은 모노레포 런북 §3 T043). 되돌리기는 반대 순서이며 **clientAuth 제거 → Secret 삭제**, **sniStrict 제거 → TLSStore 삭제**를 각각
뒤집지 않는다(§7 · 계약 §오리진 보호 3중 2.).

---

## 10. 인계 (모노레포 §11)

- **T098 관측** — 갱신 실패 감시가 없다. 단일 노드라 cert-manager가 2주 이상 죽으면 만료 → 526이다.
  `certmanager_certificate_expiration_timestamp_seconds` 기반 Grafana Cloud 알림이 반드시 들어가야 한다.
- **T047 / converge** — ① `ssl=strict` 드리프트 단언(§6)
  ② 계약 §디렉터리 줄에 **소유권 한 문장 보강**(TLSOption 정본 = 모노레포 HelmChartConfig · TLSStore 정본 = `platform/traefik/`).
     현재 문면은 kind 화이트리스트라 충돌은 없다 — 정정이 아니라 보강이다(§8).
  ③ 설계 §14.3-1의 edge 검증 호스트 교체(§5)를 문면에 반영.
  ④ **`validate.sh` 교차 파일 단언** — `platform/traefik/`의 TLSStore는 `default`/`kube-system` 1개이고
     `spec.certificates[].secretName`이 `platform/cert-manager-issuers/`의 Certificate `spec.secretName`과 **문자열 일치**할 것 ·
     `spec.defaultCertificate` 키 존재 시 FAIL(하이브리드 금지) · `platform/traefik/`에 kind `TLSOption` 존재 시 FAIL(R7 소유권) ·
     `platform/traefik/`에 kind `Secret` 존재 시 FAIL(T047 후보 — AOP 루트 CA Secret `cloudflare-origin-pull-ca`의 정본은 모노레포
     `infra/bootstrap/cloudflare-origin-pull-ca.yaml`(K3s AddOn)이고 gitops에 두지 않는다, 계약 §오리진 보호 3중 2.).
     자격·라이브 접근이 필요 없는 순수 트리 검사다.
     **현재 정적 검사 실태(2026-09-10 재확인)**: 이 파일은 검사 1에서 **이미 스키마 검증되고 있다.**
     `validate.sh`는 `-schema-location`에 datree CRDs-catalog를 항상 넘기고(`tests/validate.sh:201`·`:351`),
     그 카탈로그의 `traefik.io/tlsstore_v1alpha1.json`이 PR-4 검증 때 캐시에 실제로 받아졌다. 스키마가
     `spec.additionalProperties: false` · `certificates[].required: [secretName]` · 항목도 `additionalProperties: false`라
     **키 오타는 `-strict`에서 FAIL한다.** (이전 문면의 "kubeconform이 이 파일을 skip 한다"는 **오류였다** —
     `-schema-location` 없이 맨몸 kubeconform을 돌린 결과를 옮겨 적은 것이다.)
     그래서 위 네 단언의 실제 몫은 스키마가 **못 잡는** 것들이다: 교차 파일 이름 일치 · `defaultCertificate` 존재
     (스키마에 있는 정상 필드라 통과한다) · 두 번째 TLSStore/TLSOption · 이 디렉터리 안의 Secret(kind 자체는 유효하다). 덧붙여 스키마는 GitHub raw에서 받으므로
     오프라인·403이면 `-ignore-missing-schemas`가 조용히 건너뛴다 → 저장소 안 벤더링은 "공백 메우기"가 아니라
     **결정성 개선** 항목이다.
     (이 PR에서 `tests/validate.sh`를 고치지 않는다 — T033 산출물이고 게이트 PR의 범위를 넘는다.)
  ⑤ ~~PR-5: 이미 머지된 `platform/cert-manager-issuers/` 문면 정정 5건~~ → **완료(PR-5)**. 전부 PR-3 승격 이후
     낡았거나 사실과 어긋났던 것이고, `certificate-wildcard-joshuatech-dev.yaml`과 그 디렉터리 README에서 함께 고쳤다:
     · Certificate 주석의 "서빙 Secret이 사라지고 … 전 호스트 526"(되돌리기 경고 문단) → **사실과 반대**였다.
       `enableCertificateOwnerRef: false`(차트 기본값, `platform/`에 오버라이드 0건)라 Secret은 남는다 →
       §7의 **조용한 만료 폭탄** 모델로 교체.
     · 머리 주석의 "지금은 staging 단계다" → PR-3 승격(gitops main `32a1022`)으로 낡았다 → "prod 승격 완료(rev 2)"로.
     · 고아 Secret 삭제 절차를 "(README §6)"으로 지목 → §6은 **기대 실패** 절이고 삭제 절차는 **§10**이다.
     · 되돌리기 근거를 "(README §5)"로 지목 → §5는 `-staging` 이름의 근거이고, "PR-4만 revert" 규율의 정본은
       **이 README §7**이다(그 저장소 §12가 아니다 — §12는 그 디렉터리 자체의 되돌리기다).
     · 64일 전환 대응값 **40**(Certificate의 `renewBeforePercentage` 주석과 그 README §9) → 산술 오류다(바로 아래 항목).
- **cert-2 임계값** — `renewBeforePercentage: 33` + LE classic 90일이라 갱신 시작이 잔여 29.7일이고, cert-2 기준(30일)과
  약 60일마다 7.2시간 겹친다. **2027-02-10 LE classic이 64일로 바뀌면 43일 중 약 9일(≈21%) 상시 FAIL**이 된다.
  ⚠ 그때의 대응값으로 여러 문서가 적어 둔 **40은 틀렸다.** `renewBeforePercentage`는 **잔여** 비율이므로
  64일 × 0.40 = **25.6일**이고 cert-2 기준(30일)을 여전히 못 넘긴다 — 주기 38.4일 중 4.4일(≈11%)이 계속 FAIL한다.
  ("잔여 36일"이라는 병기 수치는 90일로 계산한 값이다.) 30일을 넘기려면 **≥47%**(64×0.47 = 30.1일)이고
  실용값은 **50**(32일)이다. 이 값이 적힌 세 곳(Certificate의 `renewBeforePercentage` 주석 ·
  `platform/cert-manager-issuers/README.md` §9 · 이 문단)은 **PR-5에서 함께 고쳤다.**
  값 자체를 바꾸는 것은 아직 남았다 — 2027-02-10 전에 별도 PR로 `renewBeforePercentage`를 올린다.
  근본 해법은 cert-2를 `status.renewalTime` 기준으로 바꾸는 것(converge).
- **Argo UI 고아 경고 정상 목록** — AppProject `platform`이 `orphanedResources.warn: true`라 `platform-traefik`(destination `kube-system`)이
  선언하지 않은 `kube-system` 객체가 Argo UI에 고아로 뜬다. **정상이며 지우지 않는다**(선례: `platform/cert-manager-issuers/README.md` §3).
  · `kube-system/Secret cloudflare-origin-pull-ca` — AOP 루트 CA(공개 인증서 · K3s AddOn · 정본 모노레포 `infra/bootstrap/cloudflare-origin-pull-ca.yaml`,
    그 파일 헤더가 이 절을 가리킨다). **Argo UI에 고아로 보여도 지우지 않는다 — 지우면 443 전면 중단**이다: clientAuth가 실린 채 Secret이 없으면
    Traefik이 `CAFiles is required`로 TLSOption 등록에 실패해 websecure 전 호스트가 죽는다(파드는 Ready 유지 — 능동 확인 필수).
    제거는 계약 §오리진 보호 3중 2.의 순서(clientAuth 제거·재설치 → `tlsoption default` spec의 `clientAuth`가 빈 값임을 확인 → 그다음에야 Secret)로만 한다.
  · `kube-system/Secret wildcard-joshuatech-dev-tls` — cert-manager가 만드는 서빙 Secret(`platform/cert-manager-issuers/` 소유). 지우면 자체 서명 복귀 = 전 호스트 526(§2).
