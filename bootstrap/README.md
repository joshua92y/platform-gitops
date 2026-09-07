# bootstrap/ — Argo CD 설치 · root app 운영자 절차 (T040)

계약 gitops-repo.md §디렉터리: `argocd/` = remote base(install.yaml, 커밋 SHA 핀) + patches, `root-app.yaml` = Application "root" → `clusters/oci-k3s/apps`(유일한 수동 apply).
이 디렉터리는 Argo CD **자체**와 root Application만 소유한다. 나머지(네임스페이스·PSA 라벨·AppProject·컴포넌트 Application·Ingress·SSO)는 T041 이후 태스크의 몫이며,
그 경계는 `argocd/kustomization.yaml` 머리 주석에 있다.

| 파일 | 내용 |
|---|---|
| `argocd/kustomization.yaml` | `namespace: argocd` + install.yaml@`e258ee23…`(v3.5.2 커밋) + 이미지 digest 2개 + 패치: dex 6·applicationset 8 삭제, requests/GOMEMLIMIT 5종, `argocd-cmd-params-cm`, `argocd-cm` |
| `argocd/argocd-cmd-params-cm.yaml` | `server.insecure` · `controller.diff.server.side` · processors/parallelism 4키 |
| `argocd/argocd-cm.yaml` | `timeout.reconciliation 180s` · `application.resourceTrackingMethod annotation` · Application 헬스 Lua(`resource.exclusions` 기본 유지) |
| `argocd/resources-*.yaml` | controller(StatefulSet) 256Mi/1Gi · repo-server 128Mi/512Mi · server 128Mi/512Mi · redis 32Mi/128Mi · notifications 64Mi/256Mi + GOMEMLIMIT(Go 4종) |
| `root-app.yaml` | Application `root`(project `default` — 임시, T041에서 `platform`으로 이관; 절차는 파일 머리 주석) |

- **이 저장소에 비밀은 없다.** 초기 admin 비밀번호는 클러스터가 만들고(④) 운영자 비밀번호 관리자에만 옮긴다.
- 순서: ① ns 수동 생성 → ② `apply --server-side -k` → ③ 롤아웃 확인 → ④ admin 비밀번호 → ⑤ root 적용 → ⑥ 접근(port-forward) → (T041) 인수·이관. ⑦은 되돌리기.
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
# (선택) 렌더링 사전 확인 — 문서 45개(59 − 삭제 14), dex·applicationset 0
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c '^kind:'
kubectl kustomize "$REPO/bootstrap/argocd" | grep -c -i -E 'dex|applicationset-controller'   # 0

kubectl apply --server-side --force-conflicts -k "$REPO/bootstrap/argocd"
```

## ③ 롤아웃 확인 — Deployment 4 + StatefulSet 1

첫 기동은 arm64 이미지 pull(argocd ≈ 수백 MB)이 있어 수 분 걸린다.

```bash
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-redis argocd-notifications-controller; do
  kubectl -n argocd rollout status deploy/$d --timeout=300s
done
kubectl -n argocd get deploy,statefulset                     # 정확히 5개 — dex·applicationset 없음
kubectl -n argocd get pods -o wide                           # 전부 Running, 이미지 참조는 @sha256
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

- **T041 전 기대값 = `Synced Healthy`, 리소스 0개.** `clusters/oci-k3s/apps/`는 main에 존재하지만 `README.md`뿐이라 directory 소스가 매니페스트
  (`*.yaml|*.yml|*.json`)를 0개 찾는다 — 비교 대상이 없으니 Synced, 집계할 리소스가 없으니 Healthy. 이것이 "저장소 도달 + 조정 루프 동작"의 증명이다.
- `app path does not exist`가 나오면 `clusters/oci-k3s/apps/`가 main에 없다는 뜻이다(저장소 상태를 본다). `project ... does not exist`가 나오면
  `root-app.yaml`의 project가 `default`가 아니라는 뜻이다(T040 시점에는 `default`여야 한다 — 파일 머리 주석).
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

port-forward는 admin kubeconfig의 API 경로(`cloudflared access tcp` 6443 리스너)를 그대로 탄다 — 별도 노출 없음. 세션 종료 시 포워딩을 끊고 `cloudflared access logout`.

## ⑦ 되돌리기 — `kubectl delete -k`는 CRD까지 지운다

`kubectl delete -k "$REPO/bootstrap/argocd"`는 Application·AppProject·ApplicationSet **CRD를 함께 삭제**한다 → 모든 Application CR이 사라지고,
`resources-finalizer`가 붙은 Application은 컨트롤러가 cascade(관리 리소스 삭제)를 끝내야 사라지는데 컨트롤러도 같이 지워지므로 Terminating에 갇히거나,
컨트롤러가 살아 있는 동안이면 **플랫폼 리소스 전체가 삭제**된다. T041 이후에는 절대 쓰지 않는다(롤백 런북 T114).

T040 단계(root만 있고 apps/가 비어 있을 때)의 완전 철회 순서:

```bash
# 1) root 삭제 — Delete=confirm 이라 승인 어노테이션이 먼저 필요하다(값은 RFC 3339 UTC 시각)
kubectl -n argocd annotate application root argocd.argoproj.io/deletion-approved="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl -n argocd delete application root
kubectl -n argocd get applications          # 비어 있어야 다음으로
# 2) Argo CD 삭제(CRD 포함) → 3) 네임스페이스(①에서 수동 생성했으므로 수동 삭제)
kubectl delete -k "$REPO/bootstrap/argocd"
kubectl delete namespace argocd
```

부분 되돌리기(설정만): 이 디렉터리의 패치를 고쳐 PR → ②를 재실행한다(SSA라 재적용이 diff만 반영). T041 뒤에는 `platform-argocd` Application이 같은 일을 자동으로 한다.

---

## T041·T043·이후로 넘기는 항목

- **Namespace 인수**: `platform/policies/`가 `argocd` ns + PSA restricted 라벨을 선언 → Argo CD가 SSA로 ①의 수동 생성분을 인수(라벨 값이 같아야 conflict 없음 — cloudflared README ④와 같은 판정: managedFields).
- **AppProject → root 이관**: `clusters/oci-k3s/projects/` 4종 + `default` 봉인, `root-app.yaml` `project: platform`, 재적용 순서는 `root-app.yaml` 머리 주석. root의 path가 `apps/`라 `projects/`는 root가 동기화하지 못한다 — T041이 투입 방법을 정한다(계약 트리의 구조적 순환).
- **자기 관리**: Application `platform-argocd`(source `bootstrap/argocd`, wave는 계약 §sync-wave 단일 표, syncOptions 표준 + `Prune=confirm` · `Delete=confirm`). 이후 업그레이드는 `kustomization.yaml`의 SHA·digest 변경 PR = Argo가 자기 자신을 갱신(research D13). 첫 인수에서 field conflict가 나면 ②를 1회 재실행.
- **NetworkPolicy**: `argocd` ns의 `default-deny` 뒤에도 repo-server → `github.com`/`raw.githubusercontent.com` 443(원격 base·저장소), 전 컴포넌트 → kube-api 6443(`allow-kube-api`), `allow-same-namespace`(redis·repo-server), `monitoring → argocd 8082·8083·8084`가 계약 매트릭스대로 열려 있어야 한다.
- **T043 Ingress·SSO**: `argocd-cm`에 `url` · `oidc.config`(Authentik PKCE public client, research D8) · `argocd-rbac-cm` · `admin.enabled: "false"`. 호스트 이름은 계약 hostnames-and-access.md(`argo.joshuatech.dev`)를 따른다 — research D8·D11의 `argocd.joshuatech.dev` 표기와 다르므로 계약이 우선.
- **알림**: `argocd-notifications-cm` 서비스·트리거 + ESO Merge Secret(research D9).
- **노드 배치(검토)**: plan A14는 Argo CD 0.6 GiB를 **노드 A(`role=platform`)** 예산에 넣지만 이 kustomization은 nodeSelector를 두지 않는다(T040 문면에 없음 — 라이브 라벨을 확인하지 않은 상태에서 잘못 두면 Pending). 첫 롤아웃의 `get pods -o wide` NODE 열을 보고 필요하면 T041·T046에서 `nodeSelector: {role: platform}` 패치를 추가한다.
