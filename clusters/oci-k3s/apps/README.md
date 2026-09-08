# apps/ — Application 1개/컴포넌트, app-of-apps (계약 gitops-repo.md §디렉터리·§Application 규약)

이름 규약 `platform-<component>` · `<pod>-<env>`. sync-wave는 계약 §sync-wave 단일 표가 정본(T041에서 어노테이션으로 작성). 표에 없는 디렉터리를 만들면 validate가 실패한다.

project: 플랫폼 컴포넌트 → `platform`, 앱 → `dev`·`prod`, `platform/policies/tests/` 검사 Job → `tests`(정의는 `../projects/`). root Application 자신도 T041 PR-A에서 `default` → `platform`으로 옮겼다 — `default`는 봉인되어 어떤 Application도 쓸 수 없다.

## 현재 파일

| 파일 | Application | source.path | 비고 |
|---|---|---|---|
| `platform-argocd.yaml` | `platform-argocd` | `bootstrap/argocd` | T041 PR-B1. Argo CD 자기 관리 — **finalizer 없음** |

나머지 플랫폼 Application과 앱 Application은 후속 PR에서 이 디렉터리에 추가된다.

## `platform-argocd` — 자기 관리 Application이 하는 일

root(app-of-apps)가 이 디렉터리를 읽어 child `platform-argocd`를 만들고, 그 Application이 `bootstrap/argocd`(Argo CD 본체 + AppProject 5종 + Argo CRD 어노테이션 패치)를 서버 사이드 적용으로 **인수**한다.

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

## Application 추가 절차

1. 계약 §sync-wave 단일 표에 컴포넌트 행이 있는지 확인한다. 없으면 **계약을 먼저 고친다**(그 다음 `tests/validate.sh`의 `WAVE_TABLE`, 마지막이 이 디렉터리 — 순서를 뒤집지 않는다).
2. `platform-<component>.yaml` 1파일. `metadata.annotations["argocd.argoproj.io/sync-wave"]`(문자열)과 `spec.destination.namespace`는 그 표에서 **읽어서** 넣는다. 값을 README·주석·PR 본문에 옮겨 적지 않는다.
3. syncPolicy는 계약 §Application 규약의 플랫폼 표준. 상태를 가진 컴포넌트는 `Prune=confirm`·`Delete=confirm`을 반드시 포함한다.
4. `bash tests/validate.sh` — 검사 2(APP-SSA)와 7.1(WAVE 이름·경로·값)이 새 파일을 인정하는지 확인한다. 사람이 표와 눈으로 대조하지 않는다.
