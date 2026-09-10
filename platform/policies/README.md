# platform/policies — 네임스페이스 · PSA · NetworkPolicy · 쿼터 · agent-view RBAC

이 디렉터리는 클러스터의 **경계 정책 정본**이다. Argo CD Application `platform-policies`가 이
디렉터리를 그대로 읽는다(sync-wave 값은 `contracts/gitops-repo.md` §sync-wave 단일 표에만 있다 —
여기에도, 다른 문서에도 숫자를 복사하지 않는다).

정본 계약(모노레포 `specs/003-platform-foundation/contracts/`):

- `network-policy.md` — 네임스페이스 표 · PSA 레벨 · 정책 세트 · 허용 매트릭스(내부 · 외부/노드 IP)
- `gitops-repo.md` — Application 규약 · 삭제 보호 · sync-wave 단일 표
- `hostnames-and-access.md` §에이전트·tester·CI 자격 — `agent-view` 권한

**허용 매트릭스는 exhaustive다.** 표에 없는 출발·도착·포트를 이 디렉터리에서 열지 않는다.
새 경로가 필요하면 계약을 먼저 고치고(리뷰 경계 `k8s-security`), 그다음 매니페스트를 고친다.

**계약 인용 규약: 줄 번호로 인용하지 않는다.** 계약은 개정되면 줄이 밀린다 — 2026-09-09 모노레포
`d5f8a82`가 §정책 세트 아래에 5줄을 끼워 넣어 그 뒤 번호가 전부 **+5** 밀렸고(옛 `:121` webhook 행 =
지금 `:126`), 그때까지 이 문서와 매니페스트 주석이 달고 있던 `:33`~`:122` 인용은 한 번에 전부 다른 줄을
가리키게 됐다. 그래서 이 문서는 계약을 **절 이름 + 행 키(`<출발> → <도착> <포트>`) 또는 정책 이름**으로만
가리킨다. 행 키는 계약 안에서 검색으로 찾을 수 있고 개정으로 이동해도 유효하다. 약칭 둘:

- **§내부 매트릭스** = 계약의 `## 허용 매트릭스 — 클러스터 내부 (출발 ns → 도착 ns:포트)` 절
- **§외부 매트릭스** = 계약의 `## 허용 매트릭스 — 클러스터 밖 · 노드 IP` 절

(둘 다 그 문자열 그대로 계약에서 검색된다.)

---

## 1. 파일 배치

| 파일 | 내용 | 객체 수 | 정본 |
|---|---|---|---|
| `namespaces.yaml` | Namespace 14개 + PSA 라벨(`enforce`=`warn`=`audit`) + 삭제 보호 어노테이션 | 14 | `network-policy.md` §네임스페이스 표 |
| `policies-common.yaml` | 공통 정책 세트 5종 + 조건부 2종 | 49 | 같은 문서 §정책 세트(공통 5종 표 + 조건부 2종 표) |
| `policies-matrix.yaml` | 클러스터 **내부** 허용 매트릭스(도착 ingress 21 + 출발 egress 10) | 31 | 같은 문서 §허용 매트릭스 — 클러스터 내부 |
| `policies-external.yaml` | 클러스터 **밖**·노드 IP egress | 13 | 같은 문서 §허용 매트릭스 — 클러스터 밖 · 노드 IP |
| `quota.yaml` | `jt-dev`·`jt-prod`의 ResourceQuota + LimitRange | 4 | `spec.md` FR-039 · `gitops-repo.md` §네임스페이스 |
| `rbac-agent-view.yaml` | ServiceAccount `agent-view` + ClusterRole 2 + ClusterRoleBinding 3 + Role/RoleBinding ×3 | 12 | `tasks.md` T041 문면 · `hostnames-and-access.md` §클러스터(K8s)의 `agent-view` 항 |
| `kustomization.yaml` | 위 6파일을 `resources`로만 묶는다(트랜스포머 없음) | — | — |

`tests/`(검사 Job)는 이 `kustomization.yaml`이 **참조하지 않는다**. 전용 AppProject `tests` 소속의
별도 kustomization이며, 자격이 필요한 검사를 tester 대신 클러스터 안에서 돌린다.

### 트랜스포머를 두지 않는 이유

- kustomize 공통 `labels:`(구 `commonLabels`)는 **모든** 객체에 라벨을 붙인다. 그러면 (1)
  `kube-system` Namespace가 "PSA 라벨만"이라는 계약(`network-policy.md` §네임스페이스 표의
  "`kube-system`은 … **라벨만 SSA로 패치**하고" 항)을 벗어나고, (2)
  아래 §6 되돌리기 선택자가 `agent-view` RBAC까지 걸려 비상 삭제가 tester·에이전트의 접근 경로를
  함께 지운다. 그래서 되돌리기용 라벨 `app.kubernetes.io/part-of: platform-policies`는
  NetworkPolicy·ResourceQuota·LimitRange 매니페스트에만 **직접** 기재하고
  `namespaces.yaml`·`rbac-agent-view.yaml`에는 두지 않는다.
- `namespace:` 트랜스포머도 없다. 객체마다 ns가 다르고 클러스터 스코프 객체(Namespace·ClusterRole·
  ClusterRoleBinding)가 섞여 있다. 네임스페이스는 매니페스트에 명시한다.

---

## 2. 정책 이름 규약

| 종류 | 이름 |
|---|---|
| 공통 세트 | `default-deny` · `allow-dns` · `allow-same-namespace` · `allow-kube-api` · `allow-apiserver-webhook` |
| 조건부 | `deny-imds`(`kube-system` 전용) · `allow-imds`(`vault` 전용) |
| 도착 ns ingress | `allow-from-<출발>` · `allow-scrape-from-monitoring` · `allow-otlp-from-<출발>` |
| 출발 ns egress(내부) | `allow-egress-to-<도착>` · `allow-egress-scrape` |
| 출발 ns egress(외부·노드) | `allow-egress-external-443` · `allow-egress-dns-1111` · `allow-egress-kubelet` · `allow-egress-tunnel` · `allow-egress-ssh-nodes` |

- 공통 세트 7종의 이름은 `tests/validate.sh` 검사 5.2가 문자열로 강제한다(`deny-imds`·`allow-imds`는
  전용 ns 밖에 있으면 FAIL). 그 7개 이름을 매트릭스 정책에 재사용하지 않는다 — 같은 ns에 같은 이름이
  두 번 나오면 kustomize 중복 ID이고 5.2 EXCLUSIVE 위반이다.
- `namespaceSelector`는 `kubernetes.io/metadata.name` **matchLabels만** 쓴다. `matchExpressions`는
  `tests/platform/cluster.tests.ps1`의 정적 파서가 평가하지 못해 np-3·np-4가 FAIL한다.
- 외부(광역 `ipBlock`) egress 규칙은 반드시 `ports` + `except` 4개다(§9 상수). `/32` 목적지는
  `ports`만 둔다.

---

## 3. 계약 매트릭스 행 → 정책 이름 대응표

계약 행은 **행 키**(`<출발> → <도착> <포트>`) 또는 정책 이름으로 가리킨다 — 줄 번호를 쓰지 않는 이유는
위 §계약 인용 규약을 볼 것. 파일 약어: **C** = `policies-common.yaml` ·
**M** = `policies-matrix.yaml` · **E** = `policies-external.yaml`.

### 3.1 공통 세트 · 조건부 (C, 49장)

계약 §정책 세트의 표는 정책 이름이 곧 행 키다. 매트릭스 쪽에도 짝이 있는 행은 그 행 키를 함께 적는다.

| 계약 행 | 규칙 | 정책 이름 | 적용 ns | 장수 |
|---|---|---|---|---|
| §정책 세트 `default-deny` | ingress·egress 전면 차단 | `default-deny` | `kube-system` 제외 13 | 13 |
| §정책 세트 `allow-dns` + §내부 매트릭스 `전 ns → kube-dns 53` | → `kube-system` kube-dns 53 UDP·TCP | `allow-dns` | 같은 13 | 13 |
| §정책 세트 `allow-same-namespace` | 자기 ns 안 통신 | `allow-same-namespace` | `argocd` `data` `cnpg-system` `external-secrets` `cert-manager` `monitoring` `identity` | 7 |
| §정책 세트 `allow-kube-api` + §외부 매트릭스 `위 10 ns → 노드 A private IP 6443` | → 노드 A/32 6443(K8s API) | `allow-kube-api` | `argocd` `vault` `external-secrets` `cert-manager` `cnpg-system` `data` `monitoring` `system-upgrade` `reloader` `cloudflared` | 10 |
| §정책 세트 `allow-apiserver-webhook` + §외부 매트릭스의 `노드 A private IP → vault 8200` 행 및 `노드 A private IP 및 노드 A flannel 터널 장치 주소 → cert-manager · external-secrets · cnpg-system` 행 | ← 노드 A/32(webhook · port-forward) **+ 노드 A flannel-wg/32**(`cert-manager` · `cnpg-system`, T042 PR-A) ※ | `allow-apiserver-webhook` | `cert-manager` 10250 · `external-secrets` 10250 · `cnpg-system` 9443 · `vault` 8200 | 4 |
| §정책 세트 `deny-imds` | IMDS만 제외한 egress 허용 1장 | `deny-imds` | `kube-system` 전용 | 1 |
| §정책 세트 `allow-imds` + §외부 매트릭스 `vault → 169.254.169.254 80` | → IMDS 169.254.169.254:80 | `allow-imds` | `vault` 전용 | 1 |

※ `allow-apiserver-webhook` 행은 **한때** 매니페스트가 계약을 의도적으로 벗어난 유일한 행이었다. 지금은
아니다 — 계약 정정(모노레포 `d5f8a82`, 2026-09-09 15:17:57)이 이 매니페스트를 담은 PR #13 머지(`cad608a`,
15:21:51)보다 **3분 54초 먼저** 들어가 그 이탈은 해소됐고, 계약의 webhook 행 출발 열은 지금
"노드 A private IP **및** 노드 A flannel 터널 장치 주소"다. 남은 것은 **잔여 1건(`external-secrets`)**뿐이며
그 내용은 §8을 볼 것. 실측 근거와 메커니즘은 `policies-common.yaml`의 `allow-apiserver-webhook` 절 머리
주석에 있다.

### 3.2 클러스터 내부 매트릭스 (M, 31장)

첫 열이 계약 §허용 매트릭스 — 클러스터 내부의 **행 키 그대로**다(그 문자열로 계약에서 검색한다).

| 계약 행 키 (출발 → 도착:포트) | 도착 ns ingress | 출발 ns egress |
|---|---|---|
| `kube-system`(traefik) → `argocd` 8080 | `argocd/allow-from-traefik` | — |
| `kube-system`(traefik) → `vault` 8200 | `vault/allow-from-traefik` | — |
| `kube-system`(traefik) → `identity` 9000 | `identity/allow-from-traefik` | — |
| `kube-system`(traefik) → `jt-dev`·`jt-prod` 8000 | `jt-dev/allow-from-traefik` · `jt-prod/allow-from-traefik` | — |
| `kube-system`(traefik) → `monitoring` 4317 | `monitoring/allow-otlp-from-traefik` | — |
| `jt-dev`·`jt-prod` → `data` 5432·9093·6379 | `data/allow-from-apps` | `jt-dev/allow-egress-to-data` · `jt-prod/allow-egress-to-data` |
| `jt-dev`·`jt-prod` → `identity` 9000·8080 | `identity/allow-from-apps` | `jt-dev/allow-egress-to-identity` · `jt-prod/allow-egress-to-identity` |
| `jt-dev`·`jt-prod` → `monitoring` 4317·4318 | `monitoring/allow-otlp-from-apps` | `jt-dev/allow-egress-to-monitoring` · `jt-prod/allow-egress-to-monitoring` |
| `identity` → `data` 5432 | `data/allow-from-identity` | `identity/allow-egress-to-data` |
| `identity` → `jt-prod` 8000 | `jt-prod/allow-from-identity` | `identity/allow-egress-to-apps` |
| `identity` → `jt-dev` 8000 | `jt-dev/allow-from-identity` | `identity/allow-egress-to-apps`(prod 행과 같은 1장) |
| `external-secrets` → `vault` 8200 | `vault/allow-from-external-secrets` | `external-secrets/allow-egress-to-vault` |
| `monitoring` → `argocd` 8082·8083·8084 | `argocd/allow-scrape-from-monitoring` | `monitoring/allow-egress-scrape` |
| `monitoring` → `vault` 8200 | `vault/allow-scrape-from-monitoring` | 〃 |
| `monitoring` → `external-secrets` 8080 | `external-secrets/allow-scrape-from-monitoring` | 〃 |
| `monitoring` → `cert-manager` 9402 | `cert-manager/allow-scrape-from-monitoring` | 〃 |
| `monitoring` → `cnpg-system` 8080 | `cnpg-system/allow-scrape-from-monitoring` | 〃 |
| `monitoring` → `data` 9187·9404 | `data/allow-scrape-from-monitoring` | 〃 |
| `monitoring` → `jt-dev`·`jt-prod` 9100·9464 | `jt-dev/allow-scrape-from-monitoring` · `jt-prod/allow-scrape-from-monitoring` | 〃 |
| 전 ns → `kube-system` kube-dns 53 | — | `allow-dns`(C, 13장) |

- 출발이 `kube-system`인 위 5행은 **도착 ns의 ingress로만** 구현한다. `kube-system`에는 default-deny가
  없고(계약 §정책 세트 `default-deny` 행의 "`kube-system` 제외 13 ns"와 그 아래 "`kube-system`에는
  default-deny를 걸지 않는다" 항) 정책은 `deny-imds` 한 장뿐이어야 하므로(계약 §네임스페이스 표의
  "라벨만 SSA로 패치하고(정책은 `deny-imds`만)" 항 · cluster.tests `np-1`) 그 ns에 egress 정책을 둘 수
  없다. 계약 §허용 매트릭스 — 클러스터 내부 머리글의 "한 쌍" 문언과의 차이는 규칙 추가가 아니라 누락
  쪽이며 converge 인계 항목이다.
- 검산: ingress 21 = `argocd` 2 · `vault` 3 · `external-secrets` 1 · `cert-manager` 1 ·
  `cnpg-system` 1 · `data` 3 · `identity` 2 · `jt-dev` 3 · `jt-prod` 3 · `monitoring` 2.
  egress 10 = `external-secrets` 1 · `identity` 2 · `jt-dev` 3 · `jt-prod` 3 · `monitoring` 1.

### 3.3 클러스터 밖 · 노드 IP (E, 13장)

첫 열이 계약 §허용 매트릭스 — 클러스터 밖 · 노드 IP의 **행 키 그대로**다.

| 계약 행 키 (출발 → 도착:포트) | 정책 이름 | 파일 |
|---|---|---|
| `identity` → 외부 443 | `allow-egress-external-443` | E |
| `jt-dev`·`jt-prod` → 외부 443 | 〃 (2장) | E |
| `cert-manager` → 외부 443 | 〃 | E |
| `cert-manager` → `1.1.1.1` 53 UDP·TCP | `allow-egress-dns-1111` | E |
| `vault` → 외부 443 | `allow-egress-external-443` | E |
| `vault` → `169.254.169.254` 80 | `allow-imds` | C |
| `argocd` → 외부 443 | `allow-egress-external-443` | E |
| `data` → 외부 443 | 〃 | E |
| `monitoring` → 외부 443 | 〃 | E |
| `monitoring` → 노드 A·B private IP 10250 | `allow-egress-kubelet` | E |
| `system-upgrade` → 외부 443 | `allow-egress-external-443` | E |
| `cloudflared` → 외부 7844·443 | `allow-egress-tunnel`(**UDP 7844 + TCP 7844 + TCP 443** — §8) | E |
| `cloudflared` → 노드 A 22 · 노드 B 22 | `allow-egress-ssh-nodes`(2행 = 1장 2목적지) | E |
| 노드 A private IP → `vault` 8200 | `allow-apiserver-webhook` | C |
| 노드 A private IP **및** 노드 A flannel 터널 장치 주소 → `cert-manager`·`external-secrets`·`cnpg-system` | 〃 | C |
| 위 10 ns → 노드 A private IP 6443 | `allow-kube-api` | C |

`allow-egress-external-443` 9장 = `identity` `jt-dev` `jt-prod` `cert-manager` `vault` `argocd`
`data` `monitoring` `system-upgrade`. NetworkPolicy는 FQDN을 지원하지 않으므로 계약의 "용도"
호스트는 매니페스트 주석으로만 남는다.

---

## 4. 검산

```bash
kustomize build platform/policies | kubeconform -strict -summary   # Valid 123 / Invalid 0
kustomize build platform/policies | yq -N '.kind' | sort | uniq -c
#   14 Namespace · 93 NetworkPolicy · 2 ResourceQuota · 2 LimitRange
#    1 ServiceAccount · 2 ClusterRole · 3 ClusterRoleBinding · 3 Role · 3 RoleBinding   = 123
kustomize build platform/policies | yq -N 'select(.kind=="NetworkPolicy") | .metadata.name' | sort | uniq -c
#   default-deny 13 · allow-dns 13 · allow-same-namespace 7 · allow-kube-api 10 ·
#   allow-apiserver-webhook 4 · deny-imds 1 · allow-imds 1  (= 공통 49)
#   + 내부 매트릭스 31 + 외부·노드 13 = 93
```

NetworkPolicy 93 = 공통 49 + 내부 31 + 외부 13. 이 수치가 바뀌면 계약 표가 먼저 바뀌었어야 한다.
전체 lint는 저장소 루트에서 `bash tests/validate.sh`(검사 5.0–5.5가 이 디렉터리를 본다).

---

## 5. agent-view RBAC (`rbac-agent-view.yaml`)

에이전트·tester·CI가 클러스터를 읽는 **유일한 신원**이다. 운영자 admin kubeconfig는 사람 전용이다.

| 객체 | 내용 |
|---|---|
| ServiceAccount `agent-view`(ns `kube-system`) | `automountServiceAccountToken: false` — 파드용이 아니라 토큰 발급용 신원 |
| ClusterRoleBinding `agent-view-view` | 기본 제공 집계 ClusterRole `view`(이 저장소는 바인딩만 소유) |
| ClusterRole `argocd-applications-view` + CRB `agent-view-argocd-applications` | `argoproj.io` `applications` get·list |
| ClusterRole `agent-view-extra` + CRB `agent-view-extra` | 전부 get·list·watch: core `nodes` · `apiextensions.k8s.io` `customresourcedefinitions` · `argoproj.io` `appprojects` · `postgresql.cnpg.io` `clusters`·`backups`·`scheduledbackups`·`databases`·`databaseroles` · `kafka.strimzi.io` `*` · `external-secrets.io` `*` |
| Role + RoleBinding `agent-view-portforward` × 3 | ns `vault`·`data`·`identity` — `pods/portforward` **create**(port-forward는 create 동사; 파드 조회는 `view`가 준다) |

토큰 발급은 이 한 줄뿐이고, 결과를 파일·저장소에 남기지 않는다:

```bash
kubectl create token agent-view -n kube-system --duration=8h
```

### 기대 권한표

운영자는 `--as=`(사칭)로, 에이전트·tester는 자기 토큰 kubeconfig로 `--as` 없이 확인한다
(`auth can-i`는 자기 자신에 대해서는 누구나 물을 수 있다). agent-view에는 사칭 권한이 없다.

| 명령 | 기대 |
|---|---|
| `kubectl auth whoami` | `system:serviceaccount:kube-system:agent-view` |
| `kubectl auth can-i --list --as=system:serviceaccount:kube-system:agent-view` | `view` 집계 + 위 표의 추가 항목만 |
| `kubectl auth can-i get nodes` | **yes**(`agent-view-extra`) |
| `kubectl auth can-i list applications.argoproj.io -n argocd` | **yes** |
| `kubectl auth can-i watch applications.argoproj.io -n argocd` | **no**(문면이 get·list만 준다 — §8 계약 차이) |
| `kubectl auth can-i list appprojects.argoproj.io -n argocd` | **yes** |
| `kubectl auth can-i list customresourcedefinitions.apiextensions.k8s.io` | **yes** |
| `kubectl auth can-i list clusters.postgresql.cnpg.io -n data` | **yes** |
| `kubectl auth can-i list externalsecrets.external-secrets.io -A` | **yes** |
| `kubectl auth can-i get secrets -A` | **no** |
| `kubectl auth can-i create pods/exec -A` | **no** |
| `kubectl auth can-i create pods/portforward -n vault` (`data`·`identity`도 같음) | **yes** |
| `kubectl auth can-i create pods/portforward -n jt-dev` | **no**(3 ns 밖) |
| 쓰기 동사(`create`·`patch`·`delete`) 일반 | **no** — 유일한 예외가 위 `pods/portforward` create |

`kubectl top nodes`가 동작하려면 core `nodes` 읽기가 필요하다(`nodes.metrics.k8s.io`만으로는
안 된다). `tests/platform/run-platform-tests.ps1`은 컨텍스트 사용자가 `agent-view`가 아니면
실행을 거부한다(admin kubeconfig 사용 방지).

---

## 6. 되돌리기 (prune 경로를 쓰지 않는다)

정책 적용으로 접근이 끊기는 징후(새 터널 세션 실패 · Argo CD CrashLoop · repo-server DNS 실패)에는
**운영자가** 다음 순서로 되돌린다. 에이전트·tester는 실행하지 않는다.

```bash
# ① 컨트롤러 freeze — root의 selfHeal이 정책을 되살리는 것을 먼저 막는다
kubectl -n argocd scale sts argocd-application-controller --replicas=0
#    (터널이 죽었으면 노드 A 대화형 SSH 세션에서 `sudo k3s kubectl -n argocd scale ...`)
# ② 정책 일괄 삭제 — kube-router가 즉시 full sync 한다
kubectl delete networkpolicy -A -l app.kubernetes.io/part-of=platform-policies
# ③ 접근 복구 확인 → 원인 수정 PR 머지 → ④ kubectl -n argocd scale sts argocd-application-controller --replicas=1
```

- **선택자가 `app.kubernetes.io/part-of`인 이유:** 이 클러스터의 Argo CD 리소스 추적 방식은
  **어노테이션**이다(`bootstrap/argocd/argocd-cm.yaml`의
  `application.resourceTrackingMethod: annotation`). 따라서 흔히 쓰는
  `-l argocd.argoproj.io/instance=platform-policies` 라벨 선택자는 **객체에 존재하지 않는다**
  (그 라벨은 `label` 추적 방식에서만 생긴다). 그래서 매니페스트가 자체 라벨을 직접 갖는다.
- 이 선택자에 걸리는 것은 NetworkPolicy·ResourceQuota·LimitRange뿐이다. Namespace와
  `agent-view` RBAC에는 라벨이 없으므로 위 명령으로 지워지지 않는다(의도 — tester 경로 보존).
- **금지:** `argocd app sync --prune`(agent-view RBAC까지 prune된다) ·
  `kubectl delete networkpolicy -A --all`(`kube-system` 포함) ·
  `platform-policies`·`platform-argocd`의 cascade 삭제 · `kubectl delete -k bootstrap/argocd`.
- child Application만 `automated: null`로 패치하는 것은 무효다 — root의 selfHeal이 spec을 되돌린다.
  freeze를 쓸 수 없으면 root와 child를 **둘 다** 패치한다.
- Namespace 14개는 `argocd.argoproj.io/sync-options: Delete=false,Prune=false`를 갖고,
  Application `platform-policies`에는 finalizer가 없다(cascade 2중 차단).

---

## 7. `kube-system` 경계

- `kube-system`은 K3s가 만든 네임스페이스다. 이 디렉터리는 **PSA 라벨 3개만** SSA로 패치한다
  (`namespaces.yaml`의 `kube-system` 객체에는 PSA 라벨과 삭제 보호 어노테이션 밖의 필드가 없다).
- `kube-system`에는 **default-deny를 걸지 않는다.** 정책은 `deny-imds` **한 장**이어야 한다
  (`cluster.tests.ps1` np-1이 "kube-system policies == {deny-imds}"를 단언한다).
- 그래서 traefik 출발 행은 도착 ns의 ingress로만 구현한다(§3.2).
- `default`·`kube-public`·`kube-node-lease`는 계약 표 14개 밖이라 여기서 선언하지 않는다
  (validate 5.1은 14개 초과를 FAIL로 본다). 계약 §네임스페이스 표의 "T031이 클러스터의 **모든**
  네임스페이스가 PSA 라벨 + 해당 정책을 가짐을 단언한다" 문구와의 차이는 converge 인계 항목이다.

---

## 8. 계약 공백 — 여기서 규칙을 추가하지 않는 것들

발견된 공백은 매니페스트에 추가 허용 규칙으로 넣지 않고, 계약 개정(또는 해당 태스크)에서 처리한다.

**예외 1건 — 이미 닫혔다(2026-09-09 · T042 PR-A).** `allow-apiserver-webhook` 행은 실측으로 "계약에 적힌
출발지가 원리적으로 매칭 불가"임이 드러나 계약 정정보다 매니페스트 작성이 먼저 갔다(운영 중인 webhook이
502로 죽어 있었다). **머지 시점에는 순서가 지켜졌다**: 계약 정정 커밋(모노레포 `d5f8a82`, 15:17:57)이
매니페스트 PR #13 머지(`cad608a`, 15:21:51)보다 3분 54초 먼저 들어갔다. 그러니 "계약 정정 대기 중" ·
"머지 선행 조건" · "매니페스트가 계약을 벗어난 상태"라고 적힌 문면을 어디서 보든 **그 문서가 낡은 것**이다.
남은 것은 아래 표의 **잔여 1건(`external-secrets`)**뿐이고, 그것은 이탈이 아니라 미결 결정이다.

| 공백 | 영향 | 처리 |
|---|---|---|
| `argocd` notifications-controller metrics 9001이 매트릭스에 없음 | 알림 스크레이프 불가 | monitoring 태스크에서 결정 후 계약 행 추가 |
| node-exporter(hostNetwork, 노드 IP:9100) 스크레이프 egress 행 없음 · `allow-same-namespace`는 hostNetwork 파드를 덮지 못함 | Alloy → node-exporter 실패 가능 | 같은 태스크(+노드 방화벽 9100) |
| Traefik metrics 9100(`kube-system`) 스크레이프 egress 행 없음 | Traefik 지표 누락 | 같은 태스크 |
| cloudflared metrics 2000 스크레이프 행 없음 | 터널 지표 없음 | 같은 태스크 |
| `cnpg-system` → `data` 8000(operator → instance status, 추정) 행 없음 | CNPG 운영 영향 가능 | CNPG 태스크에서 실측 |
| ~~`allow-apiserver-webhook`의 ipBlock = 노드 A/32 — 노드 B 배치 webhook은 flannel-wg 주소로 도착할 수 있음~~ **해소(2026-09-09 · T042 PR-A)** — VD-W 실측: apiserver → 파드 IP 직접 dial의 출발 IP는 노드 A flannel-wg 주소 `10.42.0.0`(노드 A podCIDR의 네트워크 주소)이다 | (해소) cert-manager 10250 · cnpg-system 9443에 `10.42.0.0/32` **add-only** 추가 — 기존 `10.0.7.78/32`는 유지 | ~~계약 정정 대기~~ **해소(모노레포 `d5f8a82`, PR #13 머지 전)** — §정책 세트 `allow-apiserver-webhook` 행과 §외부 매트릭스 webhook 행의 출발 열에 "노드 A flannel 터널 장치 주소"가 들어갔고, webhook 행에 잘못 걸려 있던 port-forward 근거 문장은 삭제된 뒤 "이 정책의 두 행은 메커니즘이 다르다" 항으로 대체됐다 · **잔여 1건** `external-secrets`: 계약은 webhook 행에 이 ns도 열거하지만 매니페스트 규칙에는 flannel 주소가 없다. 이탈이 아니라 미결 결정이다 — ESO를 노드 A에 두면(T045 계획) kube-router의 LOCAL 예외로 flannel 주소 없이 통과할 수 있어 **필요한 값 자체가 달라진다**. T045에서 배치를 확정하고 파드 방화벽 체인의 `--src-type LOCAL` 행 존재를 확인한 뒤 결정 |
| ~~cert-manager `dns01RecursiveNameservers`가 1.1.1.1**/8.8.8.8** — 매트릭스에는 1.1.1.1/32 행만~~ **해소(커밋 2026-09-09 `8cb1149` · 확인 2026-09-10)** | (해소) 설계 결정 D2 = A로 values를 계약에 맞췄다 — `platform/cert-manager/kustomization.yaml`의 `dns01RecursiveNameservers`가 `"1.1.1.1:53"` **단독**이고 `dns01RecursiveNameserversOnly: true`가 짝이다. 계약 행 1개 · 정책 1장 · values 셋이 일치한다 | **규율**: 8.8.8.8이든 다른 리졸버든 되넣으려면 ① 계약 §외부 매트릭스에 행 추가 ② `policies-external.yaml`에 정책 1장 추가 ③ 그다음 values. values만 먼저 고치면 그 리졸버로 나가는 질의가 정책에 막혀 조용히 타임아웃하고, 증상은 "DNS-01이 pending에서 안 넘어간다"로만 보인다 |
| `identity`에 `allow-kube-api` 없음(Authentik outpost의 in-cluster API 시도) | 오류 로그 가능(기능 영향 없음 추정) | Authentik 태스크에서 관찰 |
| `agent-view`의 `applications` 권한: `tasks.md` T041 문면은 `argocd-applications-view` get·list, `hostnames-and-access.md` §클러스터(K8s)의 `agent-view-extra` 항은 get·list·watch | `kubectl get app -w` 거부 | converge에서 문면·계약 통일(현재는 `tasks.md` 문면을 따름) |
| CoreDNS 업스트림이 IMDS 주소(`169.254.169.254`)이면 `deny-imds`(ports 없음)가 외부 이름 해석을 끊는다 | 적용 시 전면 DNS 실패 | 적용 전 노드 실측(VD-DNS) — IMDS면 계약 개정 후 예외 1장 |
| 계약의 `cloudflared` → 외부 7844·443 행이 **프로토콜을 적지 않는다**(매트릭스에 프로토콜 열이 없다) | 문면만 보면 "TCP만"으로 읽을 여지가 있고, 그 판독을 따르면 QUIC이 막혀 http2로 **조용히 폴백**한다(기능은 유지, 성능·재연결 특성 저하) | **정책 쪽은 이미 정해졌다** — 2026-09-08 사용자 결정 A(용도 열의 "QUIC/HTTP2"를 그대로 읽는다)로 `allow-egress-tunnel`은 **UDP 7844 + TCP 7844 + TCP 443**을 선언한다(`policies-external.yaml`이 정본). 남은 것은 계약 문면뿐: 매트릭스에 프로토콜 열을 두거나 그 행의 포트 열을 `7844(UDP·TCP) · 443(TCP)`로 적어 해석 여지를 없앤다(동작 변경 아님). 확인은 cloudflared 로그의 `Registered tunnel connection` `protocol=quic` |

---

## 9. 상수

| 상수 | 값 | 쓰이는 곳 |
|---|---|---|
| 노드 A private IP | `10.0.7.78` | `allow-kube-api`(6443) · `allow-apiserver-webhook` · `allow-egress-kubelet` · `allow-egress-ssh-nodes` |
| 노드 A flannel-wg 주소 | `10.42.0.0` (= 노드 A `.spec.podCIDR` `10.42.0.0/24`의 **네트워크 주소**) | `allow-apiserver-webhook`(`cert-manager` 10250 · `cnpg-system` 9443) — apiserver가 **파드 IP로 직접 dial**할 때의 출발 IP(VD-W 실측 2026-09-09). 노드 재조인·재이미지 시 `.spec.podCIDR`과 **재대조**할 것 — 리스가 바뀌면 이 규칙은 조용히 무력해진다 |
| 노드 B private IP | `10.0.10.193` | `allow-egress-kubelet` · `allow-egress-ssh-nodes` |
| IMDS | `169.254.169.254` | `deny-imds`(except) · `allow-imds`(:80) · 외부 규칙 except |
| 광역 egress `except` 4개 | `169.254.169.254/32` · `10.0.0.0/8` · `172.16.0.0/12` · `192.168.0.0/16` | `0.0.0.0/0` 규칙 전부 |
| DNS-01 리졸버 | `1.1.1.1/32` (UDP·TCP 53) | `cert-manager/allow-egress-dns-1111` |

노드 IP가 바뀌면 계약(`network-policy.md` · `hostnames-and-access.md`)을 먼저 고치고,
`policies-common.yaml`·`policies-external.yaml`과 이 표를 함께 갱신한다.

### `10.42.0.0/32`의 전제 두 가지

자세한 근거는 `policies-common.yaml`의 `allow-apiserver-webhook` 절 머리 주석에 있다.

- 이 값은 "노드 A의" 주소이기 이전에 **apiserver가 도는 노드의 podCIDR 네트워크 주소**다. 오늘은
  서버(컨트롤 플레인) 노드가 노드 A 하나뿐이라 값 하나로 족하다. 서버 노드를 추가하거나 옮기면(HA에서는
  어느 서버가 dial할지 고정되지 않는다) 그 노드의 값도 이 규칙에 함께 넣어야 한다.
- 이 주소는 어떤 파드에도 할당되지 않으므로 허용 대상은 그 노드의 **호스트 네임스페이스**뿐이다. 다만 그
  netns를 쓰는 것은 apiserver만이 아니다: 노드 A에 뜬 **hostNetwork 파드**(계약 §hostNetwork · 호스트
  네임스페이스 예외표의 node-exporter · SUC Plan Job)와 노드 A에 뜨는(스케줄되는) **`kube-system` 워크로드**
  (traefik · coredns · svclb 등)가 같은 netns를 쓴다. 셋 다 PSA `privileged` ns라 "노드 A의 비-특권
  워크로드는 argocd·cloudflared뿐"이라는 셈(= default-deny가 걸린 13 ns만 센 것)에 들어가지 않는다.
