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
머지 버튼을 누르기 전에 아래 네 줄을 실제로 실행해 눈으로 확인한다. 하나라도 어긋나면 머지하지 않는다.

```bash
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
단 `argo.joshuatech.dev` UI는 함께 죽으므로 복구는 **UI가 아니라 git revert + kubectl**로 한다.

---

## 3. 머지 뒤 확인

```bash
# ① Application 상태
kubectl -n argocd get app platform-traefik -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# 합격: Synced Healthy

# ② TLSStore가 **정확히 1개**인가 (⚠ traefik.io는 agent-view 권한 밖 — 운영자 admin 전용, §8)
kubectl get tlsstore -A
# 합격: kube-system/default 1개. 2개 이상이면 즉시 §8(이름 default 중복 → 양쪽 폐기)로 간다.
kubectl get tlsoption -A
# 합격: kube-system/default 1개(T038 HelmChartConfig 산출물). 이 PR은 TLSOption을 만들지 않는다.

# ③ Traefik이 Secret 참조에 실패하지 않았는가
kubectl -n kube-system logs deploy/traefik --since=10m | grep -Ei 'certificate|tls'
# 합격: Secret을 찾지 못했다는 오류(`secret ... not found`, `unable to fetch certificate`) 없음

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
kubectl -n kube-system get tlsstore default -o jsonpath='{.spec.certificates[0].secretName}{"\n"}'
# 합격: wildcard-joshuatech-dev-tls
# 빈 값  : CRD가 필드를 프루닝했다 → **즉시 중단**. sniStrict로 진행하지 않는다(§7).
#          이 경우 Traefik은 자체 서명으로 서빙 중이므로 이미 526일 수 있다 → §6 즉효 레버 + §7 되돌리기.
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

레버를 쓰지 않고 버티는 선택지도 있다: 526은 **v2 플랫폼 호스트에만** 걸리고 v1 매출 경로는 이 인증서를 쓰지 않는다.
SSH·kubectl 복구 경로도 살아 있으므로(§2), 근본 복구가 수 분 내면 레버를 **당기지 않는 쪽이 낫다.**

---

## 7. 되돌리기 — **PR-4만** revert 한다

### ⚠ PR-3(prod 승격)을 revert 하지 마라

PR-3은 `issuerRef`와 `secretName`을 **한 커밋으로** 바꿨다. 되돌리면 `secretName`이 `…-tls-staging`으로 함께 돌아가고,
Certificate가 가리키는 서빙 Secret `wildcard-joshuatech-dev-tls`는 **쓰는 주체가 사라진 채 남거나(갱신 중단) 대상에서 빠진다.**
그 상태에서 TLSStore는 계속 그 이름을 참조하므로 결과는 **자체 서명 복귀 = 전 호스트 526**이다.
플랫폼 Application은 `selfHeal: true`라 이 변경이 자동으로 적용된다.
(설계 §14.2 각색 D가 없앤 것이 바로 "staging 재발급이 서빙 Secret을 덮는" 경로다. `issuerRef`만 되돌리는 1줄 revert는 **PR-4 이후에는 존재하지 않는 선택지**다.)

### 되돌리기 2단 — 순서를 뒤집지 않는다

```bash
# 1단: git revert 머지가 **먼저**다. 반대로 하면 selfHeal이 즉시 되살린다.
#      (PR-4 revert PR을 만들어 머지한다 — 이 저장소에서 직접 push 하지 않는다.)

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

**이름이 `default`인 TLSStore/TLSOption은 ns와 무관하게 전역 id로 승격되고, 두 개 이상 존재하면 Traefik이 양쪽을 다 버린다.**
오류가 나지 않으므로 `minVersion: VersionTLS12`와 (나중의) `sniStrict`가 **조용히 사라지는 보안 회귀**가 된다.
그래서 소유권을 한 곳씩으로 못박았다.

| 객체 | 정본 소유 | 금지 |
|---|---|---|
| TLSStore `default` | **이 디렉터리**(gitops) | 모노레포 `traefik-config.yaml`에 `tlsStore:` 블록 추가 금지 |
| TLSOption `default` | 모노레포 `infra/bootstrap/traefik-config.yaml`(HelmChartConfig) | 이 디렉터리에 TLSOption 추가 금지 |

계약 `gitops-repo.md` §디렉터리("platform/traefik/에 Middleware·TLSOption·TLSStore")와의 **의도적 편차**이며 converge 인계 항목이다.
확인은 §3 ②의 `kubectl get tlsstore,tlsoption -A`(각각 정확히 1개).

---

## 9. 다음 단계 — 판별 실험 ①② → sniStrict (**이 PR은 sniStrict를 켜지 않는다**)

`/api/certificates`는 DynamicCerts와 DefaultCertificate를 **합쳐서** 반환하므로 판별에 쓸 수 없다.
소스가 보장하는 판별은 **SNI 두 개 비교**다. 워크스테이션은 Cloudflare 대역 밖이라 NSG에서 먼저 막혀 늘 000이므로 **노드 A 안에서** 실행한다
(런북 §3 T038 절차 4와 같은 형식).

```bash
# ① SNI 일치 → LE 와일드카드가 나와야 한다 = DynamicCerts 매칭 성공
ssh … ubuntu@<노드 A> "curl -skv --resolve traefik.joshuatech.dev:443:10.0.7.78 \
  https://traefik.joshuatech.dev -o /dev/null 2>&1 | grep -Ei 'subject:|issuer:|subjectAltName'"

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
- **T047 / converge** — ① `ssl=strict` 드리프트 단언(§6) ② 계약 §디렉터리의 TLSOption 소유권 문구 정정(§8)
  ③ 설계 §14.3-1의 edge 검증 호스트 교체(§5)를 문면에 반영.
- **cert-2 임계값** — `renewBeforePercentage: 33` + LE classic 90일이라 갱신 시작이 잔여 29.7일이고, cert-2 기준(30일)과
  약 60일마다 7.2시간 겹친다. **2027-02-10 LE classic이 64일로 바뀌면 43일 중 약 9일(≈21%) 상시 FAIL**이 되므로
  그때 값을 40으로 올린다(`platform/cert-manager-issuers/README.md` §9).
