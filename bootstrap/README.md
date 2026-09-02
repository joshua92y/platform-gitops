# bootstrap/ — Argo CD 설치·root app (계약 gitops-repo.md §디렉터리)

- `argocd/` — kustomization: remote base(install.yaml, `?ref=<commit sha>`로 핀 — 태그 금지) + patches(dex·applicationset 비활성, requests, ServerSideApply). 실제 내용은 T031+에서 작성.
- `root-app.yaml` — Application "root" → `clusters/oci-k3s/apps` (유일한 수동 apply). T031+에서 작성(지금은 없음).
