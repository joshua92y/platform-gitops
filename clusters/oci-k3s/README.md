# clusters/oci-k3s/ — Argo CD root app 진입점 (계약 gitops-repo.md §디렉터리)

- `projects/` — AppProject 4종 `{platform,dev,prod,tests}.yaml` (계약 §Application 규약의 AppProject 행).
- `apps/` — 컴포넌트당 Application 1개(app-of-apps). sync-wave 값의 정본은 계약 §sync-wave 단일 표 — T041이 그 표를 Application 어노테이션으로 옮긴다.
