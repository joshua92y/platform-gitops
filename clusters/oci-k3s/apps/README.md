# apps/ — Application 1개/컴포넌트, app-of-apps (계약 gitops-repo.md §디렉터리·§Application 규약)

이름 규약 `platform-<component>` · `<pod>-<env>`. sync-wave는 계약 §sync-wave 단일 표가 정본(T041에서 어노테이션으로 작성). 표에 없는 디렉터리를 만들면 validate가 실패한다.

project: 플랫폼 컴포넌트 → `platform`, 앱 → `dev`·`prod`, `platform/policies/tests/` 검사 Job → `tests`(정의는 `../projects/`). root Application 자신도 T041 PR-A에서 `default` → `platform`으로 옮겼다 — `default`는 봉인되어 어떤 Application도 쓸 수 없다.

## 현재 파일

| 파일 | Application | source.path | 비고 |
|---|---|---|---|
| `platform-argocd.yaml` | `platform-argocd` | `bootstrap/argocd` | T041 PR-B1. Argo CD 자기 관리 — **finalizer 없음** · T043 PR-1부터 Ingress `argo.joshuatech.dev`(`bootstrap/argocd/ingress.yaml`)도 이 소스에 포함 |
| `platform-policies.yaml` | `platform-policies` | `platform/policies` | T041 PR-B2. **유일한 라이브 위험 구간**(argocd·cloudflared ns에 `default-deny`가 걸린다) · 적용은 운영자 수동 트리거 · **finalizer 없음** |

아래 17개는 T041 PR-C가 추가했다. wave·도착 네임스페이스는 계약 §sync-wave 단일 표에서 **읽어서** 넣으며 여기 옮겨 적지 않는다. 이 17개는 모두 finalizer(`resources-finalizer.argocd.argoproj.io`)를 갖는다 — finalizer를 빼는 것은 위 두 개뿐이다(cascade가 Argo CD 자신과 Namespace 14개를 지울 수 있어서).

| 파일 | Application | source.path | 비고 |
|---|---|---|---|
| `platform-cert-manager.yaml` | `platform-cert-manager` | `platform/cert-manager` | **T042 PR-1로 채워졌다.** kustomize `helmCharts` 인플레이트 = cert-manager v1.21.1(CRD 6장 + controller·webhook·cainjector). 전제는 argocd-cm `kustomize.buildOptions: --enable-helm`(PR-0). CRD 6장은 `Delete=false,Prune=false` 패치로 보호 |
| `platform-external-secrets.yaml` | `platform-external-secrets` | `platform/external-secrets` | 뼈대 — T045. ESO가 ExternalSecret CRD 제공자 |
| `platform-vault.yaml` | `platform-vault` | `platform/vault` | 뼈대 — T044 |
| `platform-cert-manager-issuers.yaml` | `platform-cert-manager-issuers` | `platform/cert-manager-issuers` | **T042 PR-2·PR-3으로 채워졌다.** ClusterIssuer 2종(LE staging·prod, DNS-01/Cloudflare) + 와일드카드 Certificate `wildcard-joshuatech-dev`(ns `kube-system`, apex SAN 포함). PR-3에서 prod 승격 완료. CRD 소비자라 `SkipDryRunOnMissingResource` 필수 |
| `platform-cnpg.yaml` | `platform-cnpg` | `platform/cnpg` | 뼈대 — T052(오퍼레이터) |
| `platform-system-upgrade.yaml` | `platform-system-upgrade` | `platform/system-upgrade` | **첫 배포**(T037 SUC 컨트롤러 + CRD + Plan 2) — 확인 기준값은 파일 머리 주석·VD-SUC |
| `platform-cnpg-cluster.yaml` | `platform-cnpg-cluster` | `platform/cnpg-cluster` | 뼈대 — T053. `Cluster pg-main` = 삭제 보호 1순위 |
| `platform-kafka.yaml` | `platform-kafka` | `platform/kafka` | 뼈대 — T055(Strimzi + `Kafka`/`KafkaNodePool`) |
| `platform-dragonfly.yaml` | `platform-dragonfly` | `platform/dragonfly` | 뼈대 — T057(dev·prod) |
| `platform-cnpg-databases.yaml` | `platform-cnpg-databases` | `platform/cnpg-databases` | 뼈대 — T054(`Database`·`DatabaseRole`) |
| `platform-kafka-topics.yaml` | `platform-kafka-topics` | `platform/kafka-topics` | 뼈대 — T056(`KafkaTopic`·`KafkaUser`) |
| `platform-authentik.yaml` | `platform-authentik` | `platform/authentik` | 뼈대 — T080 |
| `platform-openfga.yaml` | `platform-openfga` | `platform/openfga` | 뼈대 — T082 |
| `platform-monitoring.yaml` | `platform-monitoring` | `platform/monitoring` | 뼈대 — T098(Alloy). 이름은 `monitoring`(`observability` 금지) |
| `platform-cloudflared.yaml` | `platform-cloudflared` | `platform/cloudflared` | T039 배포분 **인수**(소유권 이동) — 확인 기준값은 파일 머리 주석 |
| `platform-reloader.yaml` | `platform-reloader` | `platform/reloader` | 뼈대 — T046(VD-9 scoped 모드) |
| `platform-traefik.yaml` | `platform-traefik` | `platform/traefik` | **T042 PR-4로 채워졌다.** 지금 sync하는 것은 TLSStore `default`(ns `kube-system`) 1장뿐 — 와일드카드를 동적 인증서(`spec.certificates[]`)로 적재한다. Traefik 본체는 K3s 관리(HelmChartConfig, T038). 계약 §디렉터리의 kind 화이트리스트는 Middleware·TLSOption·TLSStore지만 **TLSOption은 이 디렉터리에 두지 않는다** — 아래 각주 참조. Middleware는 아직 없다 |

**각주 — `platform/traefik/`에 TLSOption을 두지 않는 이유(정본과 provider 조건 구분은 `platform/traefik/README.md` §8).** 이름이 `default`인 TLSStore/TLSOption은 ns와 무관하게 전역 id로 승격되고, 두 개 이상 존재하면 Traefik이 그 이름의 항목을 삭제한다. 다만 **삭제되는 대상이 다르다.** TLSOption 중복은 옵션 객체 자체를 지우고 서버가 내장 기본값으로 되돌아가는데, 내장 기본에 `minVersion: VersionTLS12`는 있고 `sniStrict`·`clientAuth`는 **없다** — 그래서 그 둘만 조용히 사라진다. `sniStrict`는 2026-09-10에, `clientAuth`(AOP `RequireAndVerifyClientCert`)는 2026-09-11 승격으로 모노레포 `infra/bootstrap/traefik-config.yaml`의 `tlsOptions.default`에 **둘 다 실제로 투입됐으므로** 이것은 가정이 아니라 **살아 있는 보안 설정**이다 — 중복으로 둘이 사라지면 edge 클라이언트 인증서 검증(AOP)이 조용히 해제된다. 반대로 TLSStore 중복은 Store 설정(`defaultCertificate`·`defaultGeneratedCert`)만 지우고 `certificates:` 목록은 살아남아 계속 서빙된다. 양쪽 다 TLS 핸드셰이크는 성공하고 Error 로그 한 줄만 남으므로 **동작으로는 드러나지 않는다.** 그래서 소유권을 못박는다 — TLSOption `default`는 모노레포 HelmChartConfig 단독, TLSStore `default`는 `platform/traefik/` 단독, 각각 정확히 한 곳. 계약 `gitops-repo.md` §디렉터리는 **kind 화이트리스트**이고 같은 줄이 HelmChartConfig를 Traefik 자체 설정의 정본으로 지목하므로 이 배치는 계약과 충돌하지 않는다. (단 이 "내장 기본값 복귀"는 중복이 **같은 provider**(Kubernetes CRD) 안에서 일어날 때다 — 서로 다른 provider가 각각 `default`를 주면 집계기가 지우기만 하고 기본값을 넣지 않아 그 옵션에 의존하는 **라우터 초기화가 통째로 실패한다**. 오늘 배치는 둘 다 CRD provider라 결론은 바뀌지 않는다.)

앱 Application(`<pod>-<env>`)은 후속 PR에서 이 디렉터리에 추가된다.

## `platform-argocd` — 자기 관리 Application이 하는 일

root(app-of-apps)가 이 디렉터리를 읽어 child `platform-argocd`를 만들고, 그 Application이 `bootstrap/argocd`(Argo CD 본체 + AppProject 5종 + Argo CRD 어노테이션 패치 + Ingress `argo.joshuatech.dev`(T043))를 서버 사이드 적용으로 **인수**한다.

**인수의 의미 — 소유권만 옮긴다.** 대상 객체는 운영자가 T040·T041 PR-A에서 `kubectl apply --server-side --field-manager=operator-bootstrap` 로 이미 넣어 둔 것들이다. 이 단계는 그 객체들의 필드 소유자를 `operator-bootstrap` → `argocd-controller` 로 바꿀 뿐, 워크로드를 새로 만들거나 다시 굴리지 않는다(렌더 결과가 같으면 no-op). Argo CD의 SSA 경로는 항상 force conflicts 이므로(gitops-engine `pkg/utils/kube/resource_ops.go:469` — `o.ForceConflicts = serverSideApply`) 필드 소유권 충돌이 오류로 표면화되지 않고 그대로 넘어간다.

source.path가 `platform/argocd`가 아니라 `bootstrap/argocd`인 이유와 `manifest-generate-paths`에 `../../clusters/oci-k3s/projects`를 함께 적는 이유는 `platform-argocd.yaml` 머리 주석과 `../../../platform/argocd/kustomization.yaml` 주석에 있다.

### 운영자 적용

머지하면 root가 자동 sync(`automated` + `selfHeal`)로 child를 만든다 — 폴링 주기(argocd-cm `timeout.reconciliation`) 안에 반영된다. 즉시 당기려면:

```bash
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=normal --overwrite
```

### 확인(기준값)

```bash
kubectl -n argocd get app root platform-argocd                 # 둘 다 Synced/Healthy
kubectl -n argocd get pods                                     # AGE·RESTARTS 불변 = no-op 인수
kubectl -n argocd get appproject platform \
  -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}'     # argocd-controller 포함
kubectl get crd applications.argoproj.io \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}'   # Delete=false,Prune=false
# 런타임에 채워지는 Secret 보존 확인: port-forward svc/argocd-server → admin 로그인 성공
```

파드가 재생성되거나 RESTARTS가 늘면 인수가 아니라 스펙 차이다 — 되돌리기 전에 `kubectl -n argocd get app platform-argocd -o jsonpath='{.status.operationState.syncResult}'` 로 차이 필드를 먼저 기록한다(Server-Side Diff에서 계속 OutOfSync로 남는 필드는 `ignoreDifferences` 후보).

### 되돌리기

1. 이 파일을 제거하는 PR을 머지한다. root는 `prune: false`라 child Application 객체는 클러스터에 남는다(정책상 자동 삭제 없음).
2. 그래도 지워야 하면 `kubectl -n argocd delete app platform-argocd`. **finalizer가 없으므로 cascade가 없다** — Argo CD 본체·AppProject·CRD는 그대로 남고 소유권만 놓는다.
3. 자동 sync 자체를 멈춰야 하는 상황이면 child만 패치해서는 안 된다(root의 selfHeal이 되돌린다). 정지 스위치는 `kubectl -n argocd scale sts argocd-application-controller --replicas=0` 하나다.

**금지:** `kubectl delete -k bootstrap/argocd`(AppProject·Argo CRD까지 함께 지운다) · 이 Application에 finalizer 추가 · `argocd app sync --prune`.

## `platform-policies` — 유일한 라이브 위험 구간

root가 child `platform-policies`를 만들고, 그 Application이 `platform/policies`(Namespace 14 · NetworkPolicy 93 · ResourceQuota 2 · LimitRange 2 · agent-view RBAC 12 = **123객체**)를 적용한다. 구성·매트릭스 대응표·기대 권한표는 `../../../platform/policies/README.md`.

**왜 위험 구간인가.** 이 저장소의 다른 Application은 워크로드를 바꾸지 않거나(`platform-argocd` = 필드 소유권만 이전) 정책이 깔린 뒤에 배포된다. 이 Application만 클러스터의 **패킷 필터를 처음으로 켠다.** 첫 sync에서 `argocd`(정책을 되돌릴 컨트롤러·repo-server가 사는 곳)와 `cloudflared`(T039 이후 운영자의 **유일한** SSH·kubectl 경로)에 `default-deny`가 걸리므로, 허용 규칙이 실제 트래픽과 어긋나면 되돌릴 손이 함께 끊긴다. 알려진 두 경로는 `allow-kube-api`가 kube-proxy DNAT **뒤** 주소와 매칭되지 않는 경우와, `deny-imds`가 CoreDNS 업스트림(169.254.169.254 가능성)을 함께 막는 경우다.

**그래서 머지 = 적용이 아니다.** 두 가능성은 적용 전에 실측으로 닫고(프로브 네임스페이스 · 노드 resolv.conf/CoreDNS Corefile), 적용 시각은 운영자가 쥔다.

### 운영자 적용(사전 점검 → 트리거)

```bash
# 0) 사전 점검(하나라도 미통과면 머지 금지)
#    - 프로브 ns 실측: allow-kube-api가 DNAT 후 주소로 매칭 · 프로브 통과 · 외부 443 except 형식 확인 후 ns 삭제
#    - 노드 A·B resolv.conf 업스트림과 CoreDNS Corefile forward 대상 확인(IMDS면 계약 개정 선행)
#    - 노드 A 대화형 SSH 세션을 열어 두고 `sudo k3s kubectl get ns` 동작 확인(1차 break-glass, 창 내내 유지)
#    - 기준값 캡처: kubectl get networkpolicy -A(0) · -n cloudflared get pods -o wide(2/2) ·
#      -n argocd get pods -o wide(RESTARTS) · -n default get endpoints kubernetes · argocd admin 로그인
kubectl -n argocd patch app root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'   # 머지가 곧 적용이 되지 않게
# (PR 머지) → git -C "$REPO" checkout main && git -C "$REPO" pull --ff-only → 사전 점검 재확인
kubectl apply -f "$REPO/bootstrap/root-app.yaml"     # automated 복원 = 적용 시작(3-way merge)
```

### 확인(기준값)

```bash
kubectl -n argocd get app root platform-argocd platform-policies   # 전부 Synced/Healthy
kubectl get networkpolicy -A --no-headers | wc -l                  # 93
kubectl get ns -L pod-security.kubernetes.io/enforce               # 14개 ns에 라벨(kube-system 포함)
kubectl -n cloudflared get pods -o wide                            # 파드 이름·RESTARTS 불변
kubectl -n cloudflared logs deploy/cloudflared --since=5m | grep -Ei 'error|Unregistered|failed'   # 0
# 별도 창에서 새 터널 세션: kubectl get nodes · ssh ssh-a true · ssh ssh-b true
kubectl -n argocd logs deploy/argocd-repo-server --since=2m | grep -Ei 'no such host|i/o timeout|dial tcp'   # 0
kubectl -n kube-system logs deploy/coredns --since=5m | grep -Eic 'i/o timeout|SERVFAIL'                     # 0
kubectl get events -A --field-selector reason=FailedCreate | grep -ci podsecurity                            # 0
kubectl create token agent-view -n kube-system --duration=8h > /dev/null && echo token-ok
```

### 정지 스위치 · 되돌리기

```bash
# ① freeze — root의 selfHeal이 정책을 되살리는 것을 먼저 막는다
kubectl -n argocd scale sts argocd-application-controller --replicas=0
#    (터널이 죽었으면 노드 A 대화형 SSH 세션에서 `sudo k3s kubectl -n argocd scale ...`)
# ② 정책 일괄 삭제 — kube-router가 즉시 full sync 한다
kubectl delete networkpolicy -A -l app.kubernetes.io/part-of=platform-policies
# ③ 접근 복구 확인 → 원인 수정 PR 머지 → kubectl -n argocd scale sts argocd-application-controller --replicas=1
```

- **child만 `automated: null`로 패치하는 것은 무효다** — 이 Application 객체를 root가 git에서 관리하고 root는 `selfHeal: true`이므로 라이브 패치가 되돌려지고 `default-deny`가 재생성된다. freeze를 쓸 수 없으면 root와 child를 **둘 다** 패치한다.
- 선택자가 `app.kubernetes.io/part-of`인 이유: 리소스 추적 방식이 어노테이션이라(`bootstrap/argocd/argocd-cm.yaml:16`) `argocd.argoproj.io/instance` 라벨은 객체에 **존재하지 않는다**. 이 라벨은 NetworkPolicy 93 · ResourceQuota 2 · LimitRange 2 = 97객체가 매니페스트에 직접 갖고 있고, Namespace와 agent-view RBAC에는 없다(비상 삭제가 tester 경로와 ns를 함께 지우지 않게 하려는 의도).
- `automated.prune: false`라 **`git revert`만으로는 정책이 클러스터에서 사라지지 않는다.** 롤백 경로는 위 3단계뿐이다.
- **금지:** 이 Application의 cascade 삭제(Namespace 14개 삭제 시도 — 그래서 finalizer가 없다) · `argocd app sync --prune`(agent-view RBAC까지 prune) · `kubectl delete networkpolicy -A --all`(kube-system 포함).

## Application 추가 절차

1. 계약 §sync-wave 단일 표에 컴포넌트 행이 있는지 확인한다. 없으면 **계약을 먼저 고친다**(그 다음 `tests/validate.sh`의 `WAVE_TABLE`, 마지막이 이 디렉터리 — 순서를 뒤집지 않는다).
2. `platform-<component>.yaml` 1파일. `metadata.annotations["argocd.argoproj.io/sync-wave"]`(문자열)과 `spec.destination.namespace`는 그 표에서 **읽어서** 넣는다. 값을 README·주석·PR 본문에 옮겨 적지 않는다(표의 3열이 `-`이면 destination은 `kube-system`).
3. syncPolicy는 계약 §Application 규약의 플랫폼 표준. 상태를 가진 컴포넌트는 `Prune=confirm`·`Delete=confirm`을 반드시 포함한다.
4. `bash tests/validate.sh` — 검사 2(APP-SSA)와 7.1(WAVE 이름·경로·값)이 새 파일을 인정하는지 확인한다. 사람이 표와 눈으로 대조하지 않는다.
