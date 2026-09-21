# platform/ — 플랫폼 컴포넌트 (계약 gitops-repo.md §디렉터리·§sync-wave 단일 표)

컴포넌트마다 `kustomization.yaml`(helmCharts values 인라인 또는 순수 매니페스트). 계약 §sync-wave 단일 표에 없는 디렉터리를 만들면 validate가 실패한다. 디렉터리 21개 중 19개는 T003이 뼈대로 만들었고(`secret-stores/`는 T045 G2, `secrets/`는 T045 G3에서 신설), 그 뒤 컴포넌트 태스크가 하나씩 채우고 있다.

**채워진 컴포넌트**(2026-09-21 기준 11개) — 각 디렉터리의 `README.md`가 운영자 절차 정본이다.

| 디렉터리 | 채운 태스크 | 내용 |
|---|---|---|
| `policies/` | T041 | Namespace 14 · NetworkPolicy · ResourceQuota · LimitRange · agent-view RBAC. 정책 객체는 **여기에만** 둔다(validate 5.0) |
| `argocd/` | T041 | Argo CD 자기 관리 Application(`bootstrap/argocd/`를 소스로) — 이 디렉터리 자체는 `resources: []`가 정상이다 |
| `cert-manager/` | T042 | helmCharts 인플레이트 v1.21.1 |
| `cert-manager-issuers/` | T042 | ClusterIssuer 2종(LE staging·prod) + 와일드카드 Certificate |
| `traefik/` | T042 | 지금 있는 것은 TLSStore `default` 1장(Middleware는 아직 없다). Traefik 자체 설정(HelmChartConfig)의 정본은 노드 A `server/manifests/traefik-config.yaml`이고 **TLSOption은 여기 두지 않는다**(근거는 `../clusters/oci-k3s/apps/README.md` 각주) |
| `system-upgrade/` | T037 | SUC 컨트롤러 + CRD + Plan 2 |
| `cloudflared/` | T039 | 터널 Deployment(T041에서 Argo가 인수) |
| `vault/` | T044 | helmCharts 인플레이트 Vault 2.0.4(Raft · OCI KMS auto-unseal) + Ingress |
| `external-secrets/` | T045 G1 | helmCharts 인플레이트 ESO 2.10.0(CRD 25 + Deployment 3) + `eso-*` SA 5 + `eso-ca-reader` RBAC |
| `secret-stores/` | T045 G2 | ClusterSecretStore 5장. ESO와 **다른 Application**인 이유는 그 디렉터리 README §0 |
| `secrets/` | T045 G3 | 매니페스트 0장 — `kustomization.yaml`이 `../../secrets/<ns>`를 base로 끌어오는 **배달자**다(ExternalSecret 원본은 저장소 루트 `secrets/<ns>/`). 소비자 컴포넌트가 같은 base를 끌어가지 않는 이유와 단일 소유(validate 7.3)는 그 디렉터리 README §0·§3 |

**아직 뼈대**(`resources: []`) — `cnpg/`(T052) · `cnpg-cluster/`(T053) · `cnpg-databases/`(T054) · `kafka/`(T055) · `kafka-topics/`(T056) · `dragonfly/`(T057) · `authentik/`(T080) · `openfga/`(T082) · `monitoring/`(T098) · `reloader/`(T046 — 차트 2.2.16 고정, VD-9 scoped 모드 기본 가정은 배포 시 확정).
