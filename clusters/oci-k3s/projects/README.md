# projects/ — AppProject 5종 (계약 gitops-repo.md §Application 규약)

| 파일 | AppProject | 요약 |
|---|---|---|
| `default.yaml` | `default` | 봉인(sourceRepos·sourceNamespaces·destinations·clusterResourceWhitelist 전부 `[]` + `namespaceResourceBlacklist */*`). 삭제하면 argocd-server가 전권으로 재생성하므로 "빈 값"으로 존치한다 |
| `platform.yaml` | `platform` | 플랫폼 컴포넌트 Application(`platform-<component>`) + root. sourceRepos = gitops + 차트 저장소, destinations = 계약 네임스페이스 표 14개, clusterResourceWhitelist 열거형 |
| `dev.yaml` · `prod.yaml` | `dev` · `prod` | 앱 Application(`<pod>-<env>`). 자기 ns(`jt-dev`·`jt-prod`)만 · cluster 리소스 금지 · `namespaceResourceBlacklist` 6종 |
| `tests.yaml` | `tests` | `platform/policies/tests/` 검사 Job 전용. sourceRepos = gitops만 · destination `jt-dev`만 · cluster 리소스 금지 |
| `kustomization.yaml` | — | `namespace: argocd` + 위 5파일. `bootstrap/argocd/`가 이 디렉터리를 base로 포함한다 |

- **네임스페이스는 두 곳에 적는다**: 파일마다 `metadata.namespace: argocd` + kustomization의 `namespace: argocd`. AppProject가 `argocd` 밖에 있으면 Argo CD가 인식하지 못하는데, 다른 ns로 떨어져도 apply는 성공해 조용히 어긋난다.
- **삭제 보호**: 5개 모두 `argocd.argoproj.io/sync-options: Delete=false,Prune=false`. 프로젝트가 사라지면 모든 Application이 "project does not exist"로 멈춘다(자기 참조 잠금).
- **wave 값은 여기에 없다.** AppProject에는 sync-wave를 두지 않으며, Application의 wave 정본은 계약 §sync-wave 단일 표 하나뿐이다.

## 투입 · 소유 · 복구

root Application은 `clusters/oci-k3s/apps`만 읽는 비재귀 directory 소스라 이 디렉터리를 스스로 동기화하지 못한다(구조적 순환: AppProject 없이는 root가 유효하지 않고, root는 `projects/`를 읽지 않는다). 그래서 `bootstrap/argocd/kustomization.yaml`이 이 디렉터리를 base로 포함한다.

1. **첫 투입(운영자 1회)**: `kubectl apply --server-side --field-manager=operator-bootstrap -k clusters/oci-k3s/projects` — 5객체만 건드리는 작은 blast radius. 절차와 확인 명령은 `../../../bootstrap/README.md` ⑧.
2. **이후 소유**: 자기 관리 Application `platform-argocd`(source `bootstrap/argocd`)가 SSA로 인수한다. Argo CD의 SSA는 항상 force라 `operator-bootstrap` 필드 소유권은 conflict 없이 넘어간다.
3. **복구(자기 참조 잠금)**: 잘못된 AppProject 커밋으로 Application이 잠기면 수정 PR을 머지한 뒤 1)을 다시 실행한다(비파괴·멱등). Argo CD를 통한 자가 복구는 잠긴 상태에서는 동작하지 않는다.

변경은 계약 §변경 권한에 따라 approval-review `k8s-security` 경계 대상이다(`platform/`·`clusters/`).
