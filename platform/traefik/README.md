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
단 `argo.joshuatech.dev`는 **T043 전까지 Ingress가 없어 애초에 Traefik 443으로 서빙되지 않는다** — 443이 완전히 끊겨도
Argo CD UI는 `kubectl -n argocd port-forward svc/argocd-server 8080:80`으로 계속 쓸 수 있다(런북 §3 T040).
그래도 복구의 정본은 UI가 아니라 **git revert + kubectl**이다 — `selfHeal: true` 때문에 순서가 고정돼 있다(§7).
(T043 뒤에는 이 문장이 뒤집힌다: 그때부터 argo UI도 526과 함께 죽는다.)

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
#   적재 여부의 정본 증거는 **§9 ①의 노드 내부 curl**(issuer + expire date)이고, ③이 0건이어도
#   ④가 526이면 인증서 경로를 용의선상에서 빼지 않는다.

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
#          → **즉시 중단**. sniStrict로 진행하지 않는다(§7).
#          이 경우 Traefik은 자체 서명으로 서빙 중이므로 이미 526일 수 있다 → §7 되돌리기 + forward-fix(§7 마지막 문단).
#          (T043 전에는 §6 즉효 레버를 당기지 않는다 — 526 뒤에 사용자 트래픽이 없다, §6.)
```

---

## 5. 왜 edge 검증이 `auth.joshuatech.dev`인가 (설계 §14.3-1)

설계 초안의 `curl -sI https://traefik.joshuatech.dev → 302` 확인은 **526을 탐지하지 못한다.**
Cloudflare Access가 **edge에서** 302를 돌려주므로 요청이 오리진에 도달하지 않고, 오리진 인증서 상태가 응답에 전혀 반영되지 않기 때문이다
(2026-09-04 실측 기록: `tests/platform/ingress.tests.ps1` 머리 주석).

| 호스트 | edge 동작 | 526 탐지 |
|---|---|---|
| `argo` · `vault` · `traefik` · `admin` | GitHub IdP Access 앱이 **전체 호스트** 보호 → 항상 302 | ✗ |
| `identity-m2m-prod` · `identity-m2m-dev` | Service Auth 401 | ✗ |
| `preview` | A 레코드 없음 | ✗ |
| **`auth`** | Access 앱이 **`/if/admin` 경로만** 보호 → 루트는 오리진까지 도달 | **✓ 유일** |

→ v2 A 레코드 7개 중 오리진 상태 코드가 반영되는 것은 **`auth` 루트뿐**이다.
sniStrict를 켠 뒤에도 와일드카드 SAN이 `auth.joshuatech.dev`를 덮으므로 이 검증은 계속 유효하다.

---

## 6. 526 즉효 레버 — Cloudflare SSL `strict` → `full` (⚠ 존 전역)

526이 걸렸고 근본 복구(§7)에 시간이 필요할 때 쓰는 **한시 레버**다. `full`은 오리진 인증서의 체인·SAN을 검증하지 않으므로
자체 서명·staging 체인이어도 트래픽이 통과한다.

> ### ⚠ 이 레버는 **존 전역 설정**이다
>
> **⚠ 당기기 전 필수 판정 — T043 전에는 당기지 않는다.**
> T042 시점 **이 저장소에는** Ingress·IngressRoute가 **0개**이고(`grep -rn '^kind: Ingress' platform/ clusters/`),
> Argo CD UI조차 `port-forward` 전용이다(런북 §3 T040 — 공개 접근은 T043부터).
> (라이브에는 차트가 만든 `traefik-dashboard` IngressRoute 1개가 있다 — `traefik.joshuatech.dev`, Access 뒤라
>  사용자 트래픽이 아니다. 아래 판정은 그대로 성립한다.)
> 즉 이 구간의 526 뒤에는 **서비스 중인 사용자 트래픽이 없다.** 가용성 이득 0에 v1 존 전역 보안 저하만 남는다.
> 판단 기준은 "526이 보이는가"가 아니라 **"526 뒤에 실제 사용자 트래픽이 있는가"**다.
> T043(호스트별 Ingress + Access) 투입 전에는 이 레버를 **당기지 않는다** — 근본 복구(§7 + forward-fix)만 한다.
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

레버를 쓰지 않고 버티는 근거는 T043 뒤에도 남는다: 526은 **v2 플랫폼 호스트에만** 걸리고 v1 매출 경로는 이 인증서를 쓰지 않는다.
SSH·kubectl 복구 경로도 살아 있으므로(§2), 근본 복구가 수 분 내면 그때도 **당기지 않는 쪽이 낫다.**
(T043 전에는 "낫다"가 아니라 **당기지 않는다** — 위 판정 참조.)

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
  **만료된 LE 인증서를 그대로 계속 내민다.** edge 결과는 똑같이 526이지만 §9 ①의 노드 내부 curl에는
  `TRAEFIK DEFAULT CERT`가 아니라 정상 발급자(`CN=YE2`)가 보인다 — "자체 서명을 찾는" 진단은 여기서 헛돈다.
  526을 만나면 **`notAfter`를 먼저 본다**(§9 ①의 `expire date` 줄).
- 만료 알림은 T098 전까지 존재하지 않는다(§10).
- 유일한 자동 신호는 `cert-1`(`found 0`)·`cert-2`이고, 그 문면은 "cert-manager 고장"과 구별되지 않는다
  (`platform/cert-manager-issuers/README.md` §6).

그래서 **PR-4 이후의 되돌리기는 PR-4만 revert 한다.** 부득이 PR-3을 되돌린다면 만료일을 사람이 기록·감시하는
조건에서만 하고 즉시 forward-fix(prod 재승격)를 계획한다 — prod 동일 SAN 중복 한도는 **5/7일이고 override가 없다**
(`platform/cert-manager-issuers/README.md` §9).

`issuerRef`만 되돌리는 1줄 revert는 다르다 — 그쪽은 **성공한 staging 재발급이 서빙 Secret을 덮어 즉시 전 호스트 526**이고
`selfHeal: true`라 자동 적용된다. **PR-4 이후에는 존재하지 않는 선택지다**(설계 §14.2 각색 D가 없앤 경로).

### 되돌리기 2단 — 순서를 뒤집지 않는다

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

**⚠ sniStrict를 이미 적용한 뒤라면 순서가 하나 더 앞선다: `sniStrict` 제거(모노레포 → 노드 A) → TLSStore 삭제.**
반대로 하면 `GetBestCertificate`가 `nil`을 반환하고 `sniStrict` 때문에 폴백 없이 `nil, nil` → **443 전면 중단**이다(설계 §8 R6).

**되돌린 뒤의 상태는 "정상"이 아니다.** Traefik은 자체 서명으로 돌아가므로 Full(strict)에서 여전히 526이다(§2).
되돌리기는 잘못된 인증서를 치우는 조치일 뿐이고, 서비스 회복은 **올바른 Secret을 다시 실어야** 끝난다.

---

## 8. 관측 사각 · 이름 `default` 중복 (설계 §8 R7 · R18)

**agent-view는 `traefik.io` 그룹(TLSStore·TLSOption·IngressRoute)을 읽지 못한다.** `cert-1`/`cert-2` 검사는 Certificate만 보므로
"Traefik이 실제로 그 인증서를 서빙하는가"는 **운영자 admin·노드 내부 curl 전용**으로 남는다(계약 §에이전트 자격 변경 후보).

**이름이 `default`인 TLSStore/TLSOption은 ns와 무관하게 전역 id로 승격되고, 두 개 이상 존재하면 그 이름의 항목이 삭제된다.**
다만 **삭제되는 대상이 다르다**(v3.7.8 `kubernetes.go` 실측) — 진단할 때 둘을 바꿔 찾지 않도록 구분해 둔다.

| 중복 대상 | 삭제되는 것 | 살아남는 것 | 실제 증상 |
|---|---|---|---|
| **TLSOption `default`** | 옵션 객체 자체(`kubernetes.go:1380`) | 서버가 **내장 기본값**으로 되돌아감(`tlsmanager.go:34-38`) | `minVersion`은 그대로 `VersionTLS12`(내장 기본이 같은 값) · **내장 기본이 없는 설정만 소실** = 지금은 없고 **`sniStrict`(T042 단계 9)·`clientAuth`(T043)를 넣는 순간 그 둘이 사라진다** |
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

## 9. 다음 단계 — 판별 실험 ①② → sniStrict (**이 PR은 sniStrict를 켜지 않는다**)

`/api/certificates`는 DynamicCerts와 DefaultCertificate를 **합쳐서** 반환하므로 판별에 쓸 수 없다.
소스가 보장하는 판별은 **SNI 두 개 비교**다. 워크스테이션은 Cloudflare 대역 밖이라 NSG에서 먼저 막혀 늘 000이므로 **노드 A 안에서** 실행한다
(런북 §3 T038 절차 4와 같은 형식).

```bash
# ① SNI 일치 → LE 와일드카드가 나와야 한다 = DynamicCerts 매칭 성공
#   ⚠ `expire date`를 반드시 함께 본다 — Traefik은 만료된 인증서도 계속 서빙하므로(§7)
#     발급자만 보면 "정상"으로 오독한다. 526 진단 시에는 이 줄이 1순위다.
ssh … ubuntu@<노드 A> "curl -skv --resolve traefik.joshuatech.dev:443:10.0.7.78 \
  https://traefik.joshuatech.dev -o /dev/null 2>&1 | grep -Ei 'subject:|issuer:|subjectAltName|expire date|start date'"

# ② SNI 불일치 → 자체 서명 'TRAEFIK DEFAULT CERT'가 나와야 한다 = 폴백 경로가 와일드카드가 아님
ssh … ubuntu@<노드 A> "curl -skv --resolve no-such.example.invalid:443:10.0.7.78 \
  https://no-such.example.invalid -o /dev/null 2>&1 | grep -Ei 'subject:|issuer:'"
```

**①②가 둘 다 성립할 때만 sniStrict를 켠다.** ②에서 와일드카드가 나오면 어딘가에 `defaultCertificate`가 설정된 것이므로 켜지 않고 원인을 찾는다.
보조 판별: 차트 값 `logs.general.level: DEBUG`를 한시 적용하면 편입은 `Adding certificate for domain(s) …`, 폴백 사용은
`Serving default certificate for request: …`로 직접 보인다(확인 후 INFO 복귀 — 이것도 Traefik 롤아웃을 유발한다).

**sniStrict는 이 저장소가 아니라 모노레포에 있다**(D5 = T042 단계 9): `infra/bootstrap/traefik-config.yaml`의
`valuesContent` → `tlsOptions.default`에 `sniStrict: true`를 넣고 노드 A의 `server/manifests/traefik-config.yaml`로 설치한다.
투입 전 **노드 A에 현재 파일 사본을 반드시 먼저 보존한다**(1분 롤백). 적용 순서는 T038 헤더가 못박은 대로
**T042(와일드카드가 동적 인증서가 된 것 확인) → sniStrict → T043(CA Secret) → clientAuth**다.

켠 뒤에는 ①은 그대로, **②는 핸드셰이크 실패로 바뀌는 것이 정상**이다. Cloudflare edge는 항상 SNI를 보내므로 서비스 영향이 없다.

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
     `spec.defaultCertificate` 키 존재 시 FAIL(하이브리드 금지) · `platform/traefik/`에 kind `TLSOption` 존재 시 FAIL(R7 소유권).
     자격·라이브 접근이 필요 없는 순수 트리 검사다.
     **현재 정적 검사 실태(2026-09-10 재확인)**: 이 파일은 검사 1에서 **이미 스키마 검증되고 있다.**
     `validate.sh`는 `-schema-location`에 datree CRDs-catalog를 항상 넘기고(`tests/validate.sh:201`·`:351`),
     그 카탈로그의 `traefik.io/tlsstore_v1alpha1.json`이 PR-4 검증 때 캐시에 실제로 받아졌다. 스키마가
     `spec.additionalProperties: false` · `certificates[].required: [secretName]` · 항목도 `additionalProperties: false`라
     **키 오타는 `-strict`에서 FAIL한다.** (이전 문면의 "kubeconform이 이 파일을 skip 한다"는 **오류였다** —
     `-schema-location` 없이 맨몸 kubeconform을 돌린 결과를 옮겨 적은 것이다.)
     그래서 위 세 단언의 실제 몫은 스키마가 **못 잡는** 것들이다: 교차 파일 이름 일치 · `defaultCertificate` 존재
     (스키마에 있는 정상 필드라 통과한다) · 두 번째 TLSStore/TLSOption. 덧붙여 스키마는 GitHub raw에서 받으므로
     오프라인·403이면 `-ignore-missing-schemas`가 조용히 건너뛴다 → 저장소 안 벤더링은 "공백 메우기"가 아니라
     **결정성 개선** 항목이다.
     (이 PR에서 `tests/validate.sh`를 고치지 않는다 — T033 산출물이고 게이트 PR의 범위를 넘는다.)
  ⑤ **PR-5: 이미 머지된 `platform/cert-manager-issuers/` 문면 정정 5건.** 전부 PR-3 승격 이후 낡았거나 사실과 어긋난다.
     이미 머지된 파일이라 이 PR에서 고치지 않는다. `certificate-wildcard-joshuatech-dev.yaml` 기준:
     · `:48-50` "서빙 Secret이 사라지고 … 전 호스트 526" → **사실과 반대**다(`enableCertificateOwnerRef: false`라 Secret은
       남는다). §7의 **조용한 만료 폭탄** 모델로 바꾼다.
     · `:6-8` "⚠ 지금은 staging 단계다" → PR-3 승격으로 낡았다(같은 파일 `:19`·`:47`은 이미 prod). "현재 = prod 승격 완료(rev 2)"로.
     · `:26` 고아 Secret 삭제 절차를 "(README §6)"으로 지목 → §6은 **기대 실패** 절이고 삭제 절차는 **§10**이다.
     · `:50` 되돌리기 근거를 "(README §5)"로 지목 → §5는 `-staging` 이름의 근거이고, "PR-4만 revert" 규율의 정본은
       **이 README §7**이다(그 저장소 §12가 아니다 — §12는 이 디렉터리 자체의 되돌리기다).
     · `:41`과 `platform/cert-manager-issuers/README.md` §9의 64일 전환 대응값 **40** → 산술 오류다(바로 아래 항목).
- **cert-2 임계값** — `renewBeforePercentage: 33` + LE classic 90일이라 갱신 시작이 잔여 29.7일이고, cert-2 기준(30일)과
  약 60일마다 7.2시간 겹친다. **2027-02-10 LE classic이 64일로 바뀌면 43일 중 약 9일(≈21%) 상시 FAIL**이 된다.
  ⚠ 그때의 대응값으로 여러 문서가 적어 둔 **40은 틀렸다.** `renewBeforePercentage`는 **잔여** 비율이므로
  64일 × 0.40 = **25.6일**이고 cert-2 기준(30일)을 여전히 못 넘긴다 — 주기 38.4일 중 4.4일(≈11%)이 계속 FAIL한다.
  ("잔여 36일"이라는 병기 수치는 90일로 계산한 값이다.) 30일을 넘기려면 **≥47%**(64×0.47 = 30.1일)이고
  실용값은 **50**(32일)이다. 세 곳(`certificate-…dev.yaml:41` · `platform/cert-manager-issuers/README.md` §9 · 이 문단)을
  PR-5에서 함께 고친다. 근본 해법은 cert-2를 `status.renewalTime` 기준으로 바꾸는 것(converge).
