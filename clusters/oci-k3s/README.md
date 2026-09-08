# clusters/oci-k3s/ — Argo CD root app 진입점 (계약 gitops-repo.md §디렉터리)

- `projects/` — AppProject 5종 `{default,platform,dev,prod,tests}.yaml` (계약 §Application 규약의 AppProject 행). root가 읽는 경로가 아니므로 `bootstrap/argocd/kustomization.yaml`이 이 디렉터리를 base로 포함한다(첫 투입 = 운영자 `kubectl apply -k`, 이후 소유 = `platform-argocd`). 자세한 내용은 `projects/README.md`.
- `apps/` — 컴포넌트당 Application 1개(app-of-apps). root Application(`bootstrap/root-app.yaml`, project `platform`)이 이 디렉터리만 읽는다. sync-wave 값의 정본은 계약 §sync-wave 단일 표 — T041이 그 표를 Application 어노테이션으로 옮긴다.
