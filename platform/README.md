# platform/ — 플랫폼 컴포넌트 (계약 gitops-repo.md §디렉터리·§sync-wave 단일 표)

컴포넌트마다 `kustomization.yaml`(helmCharts values 인라인 또는 순수 매니페스트). 계약 §sync-wave 단일 표에 없는 디렉터리를 만들면 validate가 실패한다. 지금은 빈 뼈대(T003)만 있고 실제 매니페스트는 T031+에서 작성한다.

- `traefik/` — Middleware·TLSOption·TLSStore만. Traefik 자체 설정(HelmChartConfig)의 정본은 노드 A `server/manifests/traefik-config.yaml`.
- `argocd/` — Argo CD 자기 관리 Application(`bootstrap/argocd/`를 소스로).
- `reloader/` — 차트 2.2.16 고정, VD-9(scoped 모드 기본 가정)는 T046 배포 시 확정.
