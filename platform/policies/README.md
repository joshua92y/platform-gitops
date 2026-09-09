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

---

## 1. 파일 배치

| 파일 | 내용 | 객체 수 | 정본 |
|---|---|---|---|
| `namespaces.yaml` | Namespace 14개 + PSA 라벨(`enforce`=`warn`=`audit`) + 삭제 보호 어노테이션 | 14 | `network-policy.md` §네임스페이스 표 |
| `policies-common.yaml` | 공통 정책 세트 5종 + 조건부 2종 | 49 | 같은 문서 §정책 세트(:33–:37 · :43–:44) |
| `policies-matrix.yaml` | 클러스터 **내부** 허용 매트릭스(도착 ingress 21 + 출발 egress 10) | 31 | 같은 문서 §허용 매트릭스 — 클러스터 내부(:77–:95) |
| `policies-external.yaml` | 클러스터 **밖**·노드 IP egress | 13 | 같은 문서 §허용 매트릭스 — 클러스터 밖·노드 IP(:106–:119) |
| `quota.yaml` | `jt-dev`·`jt-prod`의 ResourceQuota + LimitRange | 4 | `spec.md` FR-039 · `gitops-repo.md` §네임스페이스 |
| `rbac-agent-view.yaml` | ServiceAccount `agent-view` + ClusterRole 2 + ClusterRoleBinding 3 + Role/RoleBinding ×3 | 12 | `tasks.md:120` 문면 · `hostnames-and-access.md` :51–:58 |
| `kustomization.yaml` | 위 6파일을 `resources`로만 묶는다(트랜스포머 없음) | — | — |

`tests/`(검사 Job)는 이 `kustomization.yaml`이 **참조하지 않는다**. 전용 AppProject `tests` 소속의
별도 kustomization이며, 자격이 필요한 검사를 tester 대신 클러스터 안에서 돌린다.

### 트랜스포머를 두지 않는 이유

- kustomize 공통 `labels:`(구 `commonLabels`)는 **모든** 객체에 라벨을 붙인다. 그러면 (1)
  `kube-system` Namespace가 "PSA 라벨만"이라는 계약(`network-policy.md:26`)을 벗어나고, (2)
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

행 번호는 `contracts/network-policy.md`의 줄 번호다. 파일 약어: **C** = `policies-common.yaml` ·
**M** = `policies-matrix.yaml` · **E** = `policies-external.yaml`.

### 3.1 공통 세트 · 조건부 (C, 49장)

| 계약 행 | 규칙 | 정책 이름 | 적용 ns | 장수 |
|---|---|---|---|---|
| :33 | ingress·egress 전면 차단 | `default-deny` | `kube-system` 제외 13 | 13 |
| :34 :96 | → `kube-system` kube-dns 53 UDP·TCP | `allow-dns` | 같은 13 | 13 |
| :35 | 자기 ns 안 통신 | `allow-same-namespace` | `argocd` `data` `cnpg-system` `external-secrets` `cert-manager` `monitoring` `identity` | 7 |
| :36 :122 | → 노드 A/32 6443(K8s API) | `allow-kube-api` | `argocd` `vault` `external-secrets` `cert-manager` `cnpg-system` `data` `monitoring` `system-upgrade` `reloader` `cloudflared` | 10 |
| :37 :120 :121 | ← 노드 A/32(webhook · port-forward) **+ 노드 A flannel-wg/32**(`cert-manager` · `cnpg-system`, T042 PR-A) ※ | `allow-apiserver-webhook` | `cert-manager` 10250 · `external-secrets` 10250 · `cnpg-system` 9443 · `vault` 8200 | 4 |
| :43 | IMDS만 제외한 egress 허용 1장 | `deny-imds` | `kube-system` 전용 | 1 |
| :44 :111 | → IMDS 169.254.169.254:80 | `allow-imds` | `vault` 전용 | 1 |

※ `allow-apiserver-webhook` 행은 **매니페스트가 계약을 의도적으로 벗어난 유일한 행**이다 — 계약 `:37`·`:121`은
아직 출발지를 "노드 A private IP/32"로만 적고 있고, 정정은 대기 중이다(§8 갭 표의 같은 행이 잔여 항목과 선행
조건을 적는다). 실측 근거와 메커니즘은 `policies-common.yaml`의 `allow-apiserver-webhook` 절 머리 주석에 있다.

### 3.2 클러스터 내부 매트릭스 (M, 31장)

| 계약 행 | 출발 → 도착:포트 | 도착 ns ingress | 출발 ns egress |
|---|---|---|---|
| :77 | `kube-system`(traefik) → `argocd` 8080 | `argocd/allow-from-traefik` | — |
| :78 | `kube-system`(traefik) → `vault` 8200 | `vault/allow-from-traefik` | — |
| :79 | `kube-system`(traefik) → `identity` 9000 | `identity/allow-from-traefik` | — |
| :80 | `kube-system`(traefik) → `jt-dev`·`jt-prod` 8000 | `jt-dev/allow-from-traefik` · `jt-prod/allow-from-traefik` | — |
| :81 | `kube-system`(traefik) → `monitoring` 4317 | `monitoring/allow-otlp-from-traefik` | — |
| :82 | `jt-dev`·`jt-prod` → `data` 5432·9093·6379 | `data/allow-from-apps` | `jt-dev/allow-egress-to-data` · `jt-prod/allow-egress-to-data` |
| :83 | `jt-dev`·`jt-prod` → `identity` 9000·8080 | `identity/allow-from-apps` | `jt-dev/allow-egress-to-identity` · `jt-prod/allow-egress-to-identity` |
| :84 | `jt-dev`·`jt-prod` → `monitoring` 4317·4318 | `monitoring/allow-otlp-from-apps` | `jt-dev/allow-egress-to-monitoring` · `jt-prod/allow-egress-to-monitoring` |
| :85 | `identity` → `data` 5432 | `data/allow-from-identity` | `identity/allow-egress-to-data` |
| :86 | `identity` → `jt-prod` 8000 | `jt-prod/allow-from-identity` | `identity/allow-egress-to-apps` |
| :87 | `identity` → `jt-dev` 8000 | `jt-dev/allow-from-identity` | `identity/allow-egress-to-apps`(:86과 같은 1장) |
| :88 | `external-secrets` → `vault` 8200 | `vault/allow-from-external-secrets` | `external-secrets/allow-egress-to-vault` |
| :89 | `monitoring` → `argocd` 8082·8083·8084 | `argocd/allow-scrape-from-monitoring` | `monitoring/allow-egress-scrape` |
| :90 | `monitoring` → `vault` 8200 | `vault/allow-scrape-from-monitoring` | 〃 |
| :91 | `monitoring` → `external-secrets` 8080 | `external-secrets/allow-scrape-from-monitoring` | 〃 |
| :92 | `monitoring` → `cert-manager` 9402 | `cert-manager/allow-scrape-from-monitoring` | 〃 |
| :93 | `monitoring` → `cnpg-system` 8080 | `cnpg-system/allow-scrape-from-monitoring` | 〃 |
| :94 | `monitoring` → `data` 9187·9404 | `data/allow-scrape-from-monitoring` | 〃 |
| :95 | `monitoring` → `jt-dev`·`jt-prod` 9100·9464 | `jt-dev/allow-scrape-from-monitoring` · `jt-prod/allow-scrape-from-monitoring` | 〃 |
| :96 | 전 ns → kube-dns 53 | — | `allow-dns`(C, 13장) |

- 출발이 `kube-system`인 5행(:77–:81)은 **도착 ns의 ingress로만** 구현한다. `kube-system`에는
  default-deny가 없고(계약 :33 :46) 정책은 `deny-imds` 한 장뿐이어야 하므로(계약 :26 ·
  cluster.tests `np-1`) 그 ns에 egress 정책을 둘 수 없다. 계약 :73의 "한 쌍" 문언과의 차이는
  규칙 추가가 아니라 누락 쪽이며 converge 인계 항목이다.
- 검산: ingress 21 = `argocd` 2 · `vault` 3 · `external-secrets` 1 · `cert-manager` 1 ·
  `cnpg-system` 1 · `data` 3 · `identity` 2 · `jt-dev` 3 · `jt-prod` 3 · `monitoring` 2.
  egress 10 = `external-secrets` 1 · `identity` 2 · `jt-dev` 3 · `jt-prod` 3 · `monitoring` 1.

### 3.3 클러스터 밖 · 노드 IP (E, 13장)

| 계약 행 | 출발 → 도착:포트 | 정책 이름 | 파일 |
|---|---|---|---|
| :106 | `identity` → 외부 443 | `allow-egress-external-443` | E |
| :107 | `jt-dev`·`jt-prod` → 외부 443 | 〃 (2장) | E |
| :108 | `cert-manager` → 외부 443 | 〃 | E |
| :109 | `cert-manager` → `1.1.1.1` 53 UDP·TCP | `allow-egress-dns-1111` | E |
| :110 | `vault` → 외부 443 | `allow-egress-external-443` | E |
| :111 | `vault` → IMDS 80 | `allow-imds` | C |
| :112 | `argocd` → 외부 443 | `allow-egress-external-443` | E |
| :113 | `data` → 외부 443 | 〃 | E |
| :114 | `monitoring` → 외부 443 | 〃 | E |
| :115 | `monitoring` → 노드 A·B 10250 | `allow-egress-kubelet` | E |
| :116 | `system-upgrade` → 외부 443 | `allow-egress-external-443` | E |
| :117 | `cloudflared` → 외부 7844·443 | `allow-egress-tunnel`(현재 **TCP만** — §8) | E |
| :118 :119 | `cloudflared` → 노드 A·B 22 | `allow-egress-ssh-nodes`(2행 = 1장 2목적지) | E |
| :120 | 노드 A → `vault` 8200 | `allow-apiserver-webhook` | C |
| :121 | 노드 A → `cert-manager`·`external-secrets`·`cnpg-system` | 〃 | C |
| :122 | 위 10 ns → 노드 A 6443 | `allow-kube-api` | C |

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
  **어노테이션**이다(`bootstrap/argocd/argocd-cm.yaml:16`
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
  (validate 5.1은 14개 초과를 FAIL로 본다). 계약 :26의 "모든 네임스페이스" 문구와의 차이는
  converge 인계 항목이다.

---

## 8. 계약 공백 — 여기서 규칙을 추가하지 않는 것들

발견된 공백은 매니페스트에 추가 허용 규칙으로 넣지 않고, 계약 개정(또는 해당 태스크)에서 처리한다.

**예외 1건(2026-09-09 · T042 PR-A).** `allow-apiserver-webhook` 행은 실측으로 "계약에 적힌 출발지가
원리적으로 매칭 불가"임이 드러나 **계약 정정보다 매니페스트가 먼저 갔다**(운영 중인 webhook이 502로
죽어 있었다). 계약 정정은 취소가 아니라 **머지 선행 조건으로 남아 있다** — 아래 표의 해당 행을 볼 것.
이것이 이 저장소 안에서 그 의도적 이탈을 기록하는 유일한 장치다.

| 공백 | 영향 | 처리 |
|---|---|---|
| `argocd` notifications-controller metrics 9001이 매트릭스에 없음 | 알림 스크레이프 불가 | monitoring 태스크에서 결정 후 계약 행 추가 |
| node-exporter(hostNetwork, 노드 IP:9100) 스크레이프 egress 행 없음 · `allow-same-namespace`는 hostNetwork 파드를 덮지 못함 | Alloy → node-exporter 실패 가능 | 같은 태스크(+노드 방화벽 9100) |
| Traefik metrics 9100(`kube-system`) 스크레이프 egress 행 없음 | Traefik 지표 누락 | 같은 태스크 |
| cloudflared metrics 2000 스크레이프 행 없음 | 터널 지표 없음 | 같은 태스크 |
| `cnpg-system` → `data` 8000(operator → instance status, 추정) 행 없음 | CNPG 운영 영향 가능 | CNPG 태스크에서 실측 |
| ~~`allow-apiserver-webhook`의 ipBlock = 노드 A/32 — 노드 B 배치 webhook은 flannel-wg 주소로 도착할 수 있음~~ **해소(2026-09-09 · T042 PR-A)** — VD-W 실측: apiserver → 파드 IP 직접 dial의 출발 IP는 노드 A flannel-wg 주소 `10.42.0.0`(노드 A podCIDR의 네트워크 주소)이다 | (해소) cert-manager 10250 · cnpg-system 9443에 `10.42.0.0/32` **add-only** 추가 — 기존 `10.0.7.78/32`는 유지 | **잔여 ①** 계약 `:37`·`:121`(출발 열)·`:48`(port-forward 근거의 webhook 행 오적용) 정정 — 모노레포 단독 커밋, **이 정책 변경 머지의 선행 조건**(converge는 tasks.md append만 가능해 contracts/를 고칠 수 없다) · **잔여 ②** `external-secrets`(T045 계획상 노드 A, kube-router LOCAL 예외 추정·**미검증**)는 T045에서 실측 후 결정 |
| cert-manager `dns01RecursiveNameservers`가 1.1.1.1**/8.8.8.8** — 매트릭스에는 1.1.1.1/32 행만 | 8.8.8.8 조회 차단 | cert-manager 태스크에서 values를 1.1.1.1만으로 두거나 계약 행 추가 |
| `identity`에 `allow-kube-api` 없음(Authentik outpost의 in-cluster API 시도) | 오류 로그 가능(기능 영향 없음 추정) | Authentik 태스크에서 관찰 |
| `agent-view`의 `applications` 권한: 문면은 `argocd-applications-view` get·list, 계약 :52–:55는 `agent-view-extra` 안 get·list·watch | `kubectl get app -w` 거부 | converge에서 문면·계약 통일(현재는 문면을 따름) |
| CoreDNS 업스트림이 IMDS 주소(`169.254.169.254`)이면 `deny-imds`(ports 없음)가 외부 이름 해석을 끊는다 | 적용 시 전면 DNS 실패 | 적용 전 노드 실측(VD-DNS) — IMDS면 계약 개정 후 예외 1장 |
| 계약 :117이 cloudflared 7844의 **프로토콜을 적지 않는다** — `allow-egress-tunnel`은 현재 TCP 7844·443만 선언한다(UDP 7844 없음) | QUIC이 막혀 http2로 **조용히 폴백**한다(기능은 유지, 성능·재연결 특성 저하) | 계약 :117에 UDP+TCP를 명시한 뒤 정책에 UDP 7844 추가. 적용 후 확인은 cloudflared 로그의 `Registered tunnel connection` `protocol=quic` |

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
