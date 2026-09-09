# bootstrap/ — Argo CD 설치 · root app 운영자 절차 (T040 · T041 PR-A)

계약 gitops-repo.md §디렉터리: `argocd/` = remote base(install.yaml, 커밋 SHA 핀) + patches, `root-app.yaml` = Application "root" → `clusters/oci-k3s/apps`(유일한 수동 apply).
이 디렉터리는 Argo CD **자체**와 root Application, 그리고 T041 PR-A부터 **AppProject 5종**(base `../clusters/oci-k3s/projects`)을 소유한다.
나머지(네임스페이스·PSA 라벨·컴포넌트 Application·Ingress·SSO)는 T041 이후 태스크의 몫이며, 그 경계는 `argocd/kustomization.yaml` 머리 주석에 있다.

| 파일 | 내용 |
|---|---|
| `argocd/kustomization.yaml` | `namespace: argocd` + install.yaml@`e258ee23…`(v3.5.2 커밋) + **base `../../clusters/oci-k3s/projects`**(AppProject 5) + 이미지 digest 2개 + 패치: dex 6·applicationset 8·upstream NetworkPolicy 5 삭제, requests/GOMEMLIMIT 5종, `argocd-cmd-params-cm`, `argocd-cm`, CRD 삭제 보호 3 |
| `argocd/argocd-cmd-params-cm.yaml` | `server.insecure` · `controller.diff.server.side` · processors/parallelism 4키 |
| `argocd/argocd-cm.yaml` | `timeout.reconciliation 180s` · `application.resourceTrackingMethod annotation` · Application 헬스 Lua(`resource.exclusions` 기본 유지) · **`kustomize.buildOptions: --enable-helm`**(T042 PR-0 — repo-server의 **모든** kustomize 빌드에 걸리는 전역 값이라 저장소의 어떤 kustomization이라도 원격 차트를 pull 할 수 있게 된다. 실효 통제·후속 의존 T047은 그 파일 머리 주석의 ⚠ 블록) |
| `argocd/resources-*.yaml` | controller(StatefulSet) 256Mi/1Gi · repo-server 128Mi/512Mi · server 128Mi/512Mi · redis 32Mi/128Mi · notifications 64Mi/256Mi + GOMEMLIMIT(Go 4종) |
| `argocd/patch-crd-sync-options.yaml` | Argo CD CRD 3종(applications·appprojects·applicationsets)에 `Delete=false,Prune=false` — strategic merge(install.yaml CRD에 annotations 맵이 없어 JSON6902 add는 빌드 실패) |
| `root-app.yaml` | Application `root`(project **`platform`** — T041 PR-A에서 `default`에서 이관; 순서는 파일 머리 주석과 아래 ⑧) |

- **이 저장소에 비밀은 없다.** 초기 admin 비밀번호는 클러스터가 만들고(④) 운영자 비밀번호 관리자에만 옮긴다.
- 순서: ① ns 수동 생성 → ② `apply --server-side -k` → ③ 롤아웃 확인 → ④ admin 비밀번호 → ⑤ root 적용 → ⑥ 접근(port-forward) → **⑧ AppProject 투입·root 이관(T041 PR-A)**. ⑦은 되돌리기.
  - **T040을 처음부터 다시 하는 경우(재부트스트랩·T114)**: ②의 `apply --server-side -k bootstrap/argocd` 한 번이 Argo CD 40객체와 AppProject 5를 함께 넣으므로 ⑧의 AppProject 투입은 생략하고 root 이관(⑧의 2단계)만 하면 된다.
- **라이브 변경은 이 절차의 운영자만** 한다(admin kubeconfig). 에이전트·tester는 `agent-view` 토큰으로 읽기만 한다.
- 모든 명령은 **이 브랜치가 PR로 main에 머지된 뒤**, main을 최신화한 로컬 클론에서 실행한다(브랜치 상태를 클러스터에 넣지 않는다). 아래 `$REPO`는 그 클론의 절대 경로.

```bash
REPO=<platform-gitops 로컬 클론 절대 경로>       # 예: D:/code/platform-gitops
git -C "$REPO" checkout main && git -C "$REPO" pull --ff-only
```

---

## ① 네임스페이스 수동 생성 + PSA 라벨 (T040 시점)

`platform/policies/`(T041)가 아직 없으므로 네임스페이스는 운영자가 만든다(cloudflared README ①과 같은 방식). **라벨 값은 계약
(`contracts/network-policy.md` 네임스페이스 표 — `argocd` = `restricted`)과 정확히 같아야** T041에서 Argo CD가 SSA로 충돌 없이 인수한다.
install.yaml@e258ee23의 컨테이너·initContainer 10개는 전부 `runAsNonRoot` · `allowPrivilegeEscalation: false` · `capabilities.drop [ALL]` ·
`seccompProfile RuntimeDefault`를 갖고 있어(렌더링에서 확인) `restricted` enforce에 걸리지 않는다.

```bash
kubectl create namespace argocd
kubectl label namespace argocd --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

kubectl get namespace argocd -o jsonpath='{.metadata.labels}'; echo      # 세 라벨 모두 restricted
```

## ② Argo CD 적용 (server-side apply)

`--server-side`가 **필수**다: ApplicationSet CRD가 client-side apply의 `last-applied-configuration` 어노테이션 한계(262144 B)를 넘고(3.3 릴리스 노트),
T041의 자기 관리 Application도 SSA로 같은 객체를 다루므로 처음부터 field manager를 SSA로 맞춘다. `--force-conflicts`는 재실행(멱등)과 T041 인수에서 필요하다.
워크스테이션의 kubectl(내장 kustomize)이 `raw.githubusercontent.com`에 닿아야 한다(원격 base).

```bash
# (선택) 렌더링 사전 확인 — 문서 45개(59 − 삭제 19 + AppProject 5), 삭제 대상 객체 이름 0, NetworkPolicy 0
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c '^kind:'                                   # 45 (T041 PR-A 전에는 40)
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c '^kind: AppProject'                        # 5 (default platform dev prod tests)
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c -E '^  name: argocd-(dex-server|applicationset-controller)(-network-policy)?$'   # 0
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c '^kind: NetworkPolicy'                     # 0 (upstream NP 5장 제거 — 정본은 T041 platform/policies)

kubectl apply --server-side --force-conflicts -k "$REPO/bootstrap/argocd"
```

위 grep은 `metadata.name`과 roleRef/subjects 참조를 잡는다(삭제 전 원본 install.yaml에서는 20건, 정상 렌더에서는 0건 — 실측).
텍스트로 `dex`·`applicationset`을 찾으면 정상 렌더에서도 12건이 남는데, argocd-server의 upstream env(`ARGOCD_SERVER_DEX_SERVER*` ·
`ARGOCD_APPLICATIONSET_CONTROLLER_*`, cmd-params 키 참조) · `optional: true` 볼륨 `argocd-dex-server-tls` · CRD 설명문의 "indexed" 같은
플러밍이라 무해하다(dex.config가 없으면 서버는 dex를 호출하지 않는다).

## ③ 롤아웃 확인 — Deployment 4 + StatefulSet 1

첫 기동은 arm64 이미지 pull(argocd ≈ 수백 MB)이 있어 수 분 걸린다.

```bash
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-redis argocd-notifications-controller; do
  kubectl -n argocd rollout status deploy/$d --timeout=300s
done
kubectl -n argocd get deploy,statefulset                     # 정확히 5개 — dex·applicationset 없음
kubectl -n argocd get pods -o wide                           # 전부 Running; NODE 열 = 노드 배치 확인(아래 인계 항목 "노드 배치")
kubectl -n argocd get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.initContainers[*].image}{" "}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -v -c '@sha256'                                     # 0 = 모든 컨테이너·initContainer 이미지 참조가 digest(`-o wide`에는 IMAGE 열이 없다)
kubectl -n argocd get events --field-selector reason=FailedCreate   # PSA 거부 0건
kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data}'; echo   # server.insecure · processors 반영
kubectl -n argocd get sts argocd-application-controller \
  -o jsonpath='{.spec.template.spec.containers[0].resources} {.spec.template.spec.containers[0].env}'; echo   # 256Mi/1Gi · GOMEMLIMIT
```

## ④ 초기 admin 비밀번호 — 화면에 찍지 않고 비밀번호 관리자로

`argocd-initial-admin-secret`의 `password`를 **클립보드로만** 꺼내 비밀번호 관리자에 저장한다. 값을 `echo`·로그·채팅에 남기지 않는다.

```powershell
# 워크스테이션(PowerShell) — 기본 경로
$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | Set-Clipboard
$b64 = $null
```

```bash
# 노드 셸(Linux)에서 할 때만 — 클립보드 도구(xclip · wl-copy)가 있는 환경
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | xclip -selection clipboard
```

첫 로그인(⑥) 뒤: 비밀번호 관리자에 저장했으면 이 Secret을 지운다(공식 권장 — 평문 보관 외의 용도가 없다). 필요하면 `argocd account update-password`로 교체한 뒤 지운다.

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

`admin` 계정 자체는 SSO(Authentik OIDC) 검증이 끝난 뒤 `argocd-cm admin.enabled: "false"`로 끈다(뒤 태스크 · break-glass 런북).

## ⑤ root Application 적용 → Synced/Healthy

```bash
kubectl apply -f "$REPO/bootstrap/root-app.yaml"
kubectl -n argocd get applications
kubectl -n argocd get app root -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}{.status.conditions}'; echo
```

- **T041 PR-B1 전 기대값 = `Synced Healthy`, 리소스 0개.** `clusters/oci-k3s/apps/`는 main에 존재하지만 `README.md`뿐이라 directory 소스가 매니페스트
  (`*.yaml|*.yml|*.json`)를 0개 찾는다 — 비교 대상이 없으니 Synced, 집계할 리소스가 없으니 Healthy. 이것이 "저장소 도달 + 조정 루프 동작"의 증명이다.
- `app path does not exist`가 나오면 `clusters/oci-k3s/apps/`가 main에 없다는 뜻이다(저장소 상태를 본다). `project ... does not exist`가 나오면
  AppProject `platform`이 아직 클러스터에 없다는 뜻이다 — ⑧의 1단계를 먼저 실행한다(T041 PR-A 전 상태라면 `root-app.yaml`의 project가 `default`여야 한다).
- root는 `Prune=confirm` · `Delete=confirm` — 삭제·prune은 승인 어노테이션 전까지 대기한다(⑦).
- T041 뒤: child Application(platform-* 19개)이 wave 순서로 나타나고, `kubectl -n argocd get applications`가 root 포함 전부 Synced/Healthy여야 한다(quickstart §US2).

## ⑥ 접근 — T043 전에는 port-forward(http)

Ingress `argo.joshuatech.dev`(Traefik + Cloudflare Access)는 T043이 만든다. 그 전에는 로컬 포워딩만 쓴다.
`server.insecure: "true"`라 서비스 포트 80이 **http**다(TLS 종료는 Traefik 몫).

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80     # 세션 동안 켜 둔다
# UI: http://localhost:8080  (admin / ④의 비밀번호)
# CLI(선택, v3.5.2 — 서버와 같은 태그): argocd login localhost:8080 --plaintext --username admin
```

port-forward는 admin kubeconfig의 API 경로(`cloudflared access tcp` 6443 리스너)를 그대로 탄다 — 별도 노출 없음.
**세션 종료** = port-forward와 `cloudflared access tcp` 프로세스 종료 + Access 토큰 캐시 삭제: `~/.cloudflared/`(Windows `%USERPROFILE%\.cloudflared\`)의
`*-token` · `*-token.lock` · `*-token.url` · `*-org-token*` 파일(`<host>-<hash>-token` 형태; `cert.pem` 같은 터널 자격은 건드리지 않는다).
`cloudflared access logout`이라는 하위 명령은 **없다** — 2026.8.3 `cloudflared access --help`의 하위 명령은 login · curl · token · tcp/rdp/ssh/smb · ssh-config · ssh-gen 뿐(실측).

## ⑦ 되돌리기 — `kubectl delete -k`는 CRD와 AppProject까지 지운다

`kubectl delete -k "$REPO/bootstrap/argocd"`는 Application·AppProject·ApplicationSet **CRD를 함께 삭제**한다 → 모든 Application CR이 사라지고,
`resources-finalizer`가 붙은 Application은 컨트롤러가 cascade(관리 리소스 삭제)를 끝내야 사라지는데 컨트롤러도 같이 지워지므로 Terminating에 갇히거나,
컨트롤러가 살아 있는 동안이면 **플랫폼 리소스 전체가 삭제**된다. T041 이후에는 절대 쓰지 않는다(롤백 런북 T114).

T041 PR-A부터 이 명령의 범위에 **AppProject 5종도 들어온다**(base `../clusters/oci-k3s/projects`). AppProject가 사라지면 CRD 삭제가 없어도 모든
Application이 "project does not exist"로 멈춘다. 그래서 5개 모두에 `argocd.argoproj.io/sync-options: Delete=false,Prune=false`를 두었지만,
그 어노테이션은 **Argo CD의 sync·cascade에만** 효과가 있고 운영자의 `kubectl delete`는 막지 못한다. 이 디렉터리에 `delete -k`를 쓰지 않는 것이 유일한 방어다.

T040 단계(root만 있고 apps/가 비어 있을 때)의 완전 철회 순서:

```bash
# 1) root 삭제 — Delete=confirm: 승인 어노테이션의 시각이 deletionTimestamp "이상"이어야 승인으로 인정된다
#    (v3.5.2 types.go IsDeletionConfirmed(app.DeletionTimestamp) — 어노테이션을 delete 보다 먼저 달면 무시된다). 그래서 delete 가 먼저다.
kubectl -n argocd delete application root --wait=false
kubectl -n argocd get app root -o jsonpath='{.status.conditions}'; echo      # 'requires manual confirmation' 이 보이면 아래 승인
kubectl -n argocd annotate application root argocd.argoproj.io/deletion-approved="$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # 또는: argocd app confirm-deletion root
kubectl -n argocd get applications          # root 가 사라질 때까지 대기 — 비어 있어야 다음으로
# 2) Argo CD 삭제(CRD 포함) → 3) 네임스페이스(①에서 수동 생성했으므로 수동 삭제)
kubectl delete -k "$REPO/bootstrap/argocd"
kubectl delete namespace argocd
```

- 승인 시각은 UTC RFC 3339이고 **deletionTimestamp 이상**이어야 한다(`date -u`). 승인 대기는 관리 리소스마다 `RequiresDeletionConfirmation` 을 볼 때만 걸리므로
  **T040 시점(관리 리소스 0)에는 승인 단계가 발생하지 않고 root 는 바로 사라진다** — 위 승인 명령은 T041 이후(child Application 이 있을 때)에 필요하다.

부분 되돌리기(설정만): 이 디렉터리의 패치를 고쳐 PR → ②를 재실행한다(SSA라 재적용이 diff만 반영). T041 뒤에는 `platform-argocd` Application이 같은 일을 자동으로 한다.

## ⑧ AppProject 투입 · root project 이관 (T041 PR-A)

**전제**: T041 PR-A가 main에 머지되고 `$REPO`가 최신화된 상태. PR-A는 워크로드를 바꾸지 않는다 — `clusters/oci-k3s/apps/`에는 여전히 Application 파일이 없다.
그래서 이 단계에서 새로 만들어지거나 재기동되는 파드는 없고, 바뀌는 것은 AppProject 5개(신규)와 root의 `spec.project` 한 줄뿐이다.

**왜 운영자가 직접 넣는가**: root Application은 `clusters/oci-k3s/apps`만 읽는 비재귀 directory 소스라 `clusters/oci-k3s/projects/`를 스스로 동기화하지 못한다.
AppProject가 없으면 root를 포함한 어떤 Application도 유효하지 않으므로(구조적 순환), AppProject는 Argo CD 자체와 함께 부트스트랩 묶음에 둔다.
이후 관리는 `platform-argocd`(T041 PR-B1)가 이어받는다.

```bash
# 0) 사전 상태 — 봉인 전의 기준값
kubectl -n argocd get appprojects                       # default 1개(전권)
kubectl -n argocd get app root -o jsonpath='{.spec.project} {.status.sync.status} {.status.health.status}{"\n"}'
                                                        # default Synced Healthy (관리 리소스 0)
kubectl kustomize "$REPO/clusters/oci-k3s/projects" | grep -c '^kind: AppProject'   # 5

# 1) AppProject 투입 — 5객체만(작은 blast radius). bootstrap/argocd 전체 대신 projects/ 만 적용한다
kubectl apply --server-side --field-manager=operator-bootstrap -k "$REPO/clusters/oci-k3s/projects"
kubectl -n argocd get appprojects                       # default platform dev prod tests
kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos} {.spec.destinations}{"\n"}'   # 빈 값 = 봉인
#    이 순간부터 다음 조정(≤180 s)까지 root(project default)는 InvalidSpecError·Unknown이 될 수 있다 — 관리 리소스 0이라 영향 없음.
#    argocd-server는 default가 NotFound일 때만 전권으로 재생성하므로, 봉인본이 존재하는 한 그대로 유지된다.

# 2) root 이관 — 같은 파일 재적용은 멱등이고, Application spec 변경은 즉시 refresh를 트리거한다
kubectl apply -f "$REPO/bootstrap/root-app.yaml"
kubectl -n argocd get app root -o jsonpath='{.spec.project} {.status.sync.status} {.status.health.status}{"\n"}'
                                                        # platform Synced Healthy (≤60 s)
kubectl -n argocd get app root -o jsonpath='{.status.conditions}{"\n"}'      # [] (InvalidSpecError 해소)
```

- **`default` 봉인은 되돌리지 않는다.** 봉인 뒤 root는 `platform`에서만 유효하므로 되돌리면 오히려 잠긴다.
- root가 InvalidSpec에 머물면 원인은 `clusters/oci-k3s/projects/platform.yaml`의 `sourceRepos` 문자열(정규화 후 glob 매칭) 또는 `destinations` 누락이다 →
  수정 PR 머지 → 1)을 다시 실행(SSA 멱등). 급하면 `kubectl -n argocd patch app root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`로 자동 sync를 끄고 원인을 분석한다.
- **복구(자기 참조 잠금)**: PR-B1 이후 잘못된 AppProject 커밋으로 Application이 잠기면 Argo CD는 스스로 고치지 못한다. 수정 PR을 머지한 뒤
  `kubectl apply --server-side --field-manager=operator-bootstrap -k "$REPO/clusters/oci-k3s/projects"` 한 번이 복구 경로다(비파괴·멱등).
- **금지**: 이 단계에서 `kubectl delete -k "$REPO/bootstrap/argocd"`(⑦) · AppProject 개별 삭제 · `argocd app sync --prune`.

---

## T041·T043·이후로 넘기는 항목

- **Namespace 인수**: `platform/policies/`가 `argocd` ns + PSA restricted 라벨을 선언 → Argo CD가 SSA로 ①의 수동 생성분을 인수(라벨 값이 같아야 conflict 없음 — cloudflared README ④와 같은 판정: managedFields).
- **AppProject → root 이관**: ~~T041이 투입 방법을 정한다~~ → **완료(T041 PR-A)**. `clusters/oci-k3s/projects/` 5종(`default` 봉인 포함) + `root-app.yaml` `project: platform`, 투입 경로 = `bootstrap/argocd`가 `projects/`를 base로 포함(첫 투입은 운영자 `apply -k`, 이후 `platform-argocd` 소유). 실행 순서는 ⑧.
- **자기 관리**(T041 PR-B1): Application `platform-argocd`(source `bootstrap/argocd`, wave는 계약 §sync-wave 단일 표, syncOptions 표준 + `Prune=confirm` · `Delete=confirm`). PR-A 이후 그 소스에는 **AppProject 5종도 포함**되므로 이 Application이 프로젝트 정의까지 소유한다(자기 참조 — 복구는 ⑧). 이후 업그레이드는 `kustomization.yaml`의 SHA·digest 변경 PR = Argo가 자기 자신을 갱신(research D13). 첫 인수에서 field conflict 때문에 ②를 재실행할 필요는 없다 — Argo CD의 SSA는 항상 force(`gitops-engine/pkg/utils/kube/resource_ops.go:469` `o.ForceConflicts = serverSideApply`)라 conflict가 표면화되지 않고 필드 소유권이 Argo 컨트롤러로 넘어간다.
- **NetworkPolicy**: T040이 install.yaml 동봉 upstream NP 5장을 제거했으므로(합집합 방지 — `argocd-server-network-policy`는 전 출발지 허용) **T041 `default-deny` 적용 전까지 argocd ns는 NetworkPolicy 없음**(다른 ns와 동일한 과도기). `default-deny` 뒤에는 repo-server → `github.com`/`raw.githubusercontent.com` 443(원격 base·저장소), 전 컴포넌트 → kube-api 6443(`allow-kube-api`), `allow-same-namespace`(server↔repo-server 8081↔redis 6379↔controller), `kube-system(traefik) → argocd 8080`, `monitoring → argocd 8082·8083·8084`가 계약 매트릭스대로 열려야 한다(대조 완료 — 전부 있음). 매트릭스에 없는 것: notifications-controller metrics **9001**(upstream NP는 전 ns에 열었음) — 스크레이프가 필요하면 T098/converge에서 행 추가.
- **T043 Ingress·SSO**: `argocd-cm`에 `url` · `oidc.config`(Authentik PKCE public client, research D8) · `argocd-rbac-cm` · `admin.enabled: "false"`. 호스트 이름은 계약 hostnames-and-access.md(`argo.joshuatech.dev`)를 따른다 — research D8·D11의 `argocd.joshuatech.dev` 표기와 다르므로 계약이 우선.
- **알림**: `argocd-notifications-cm` 서비스·트리거 + ESO Merge Secret(research D9).
- **노드 배치(검토)**: plan A14는 Argo CD 0.6 GiB를 **노드 A(`role=platform`)** 예산에 두지만 T040 task 문면에 nodeSelector 지시가 없어 두지 않았다(노드 라벨 `role=platform`/`role=data`는 런북 §3 T035/T036에서 실측 확인됨). 첫 롤아웃(③)의 `get pods -o wide` NODE 열을 확인하고, 노드 B로 분산되면 T041/T046에서 `nodeSelector: {role: platform}` 패치를 결정한다.
- **validate 공백 후보(T047, 미검증 — 리뷰 지적)**: ① 삭제 패치 `target`이 base에 없는 객체를 가리킬 때의 불일치 검사(②의 객체 이름 grep을 validate로 옮기는 안) ② 원격 base URL의 태그 문자열 ref(`?ref=v…` · `/v3.5.2/`) 금지 검사 ③ `bootstrap/**` 이미지 digest 요구(4b는 `platform/**`만) ④ GOMEMLIMIT ≤ memory limit 검사.
