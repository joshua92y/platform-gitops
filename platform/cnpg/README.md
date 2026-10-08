# platform/cnpg/ — 운영자 절차 (T052)

CloudNativePG **operator 1.30.0**(차트 `cloudnative-pg` 0.29.0 · CRD 11장) + **plugin-barman-cloud v0.14.0**(차트 `plugin-barman-cloud` 0.7.1 · CRD 1장)
+ **ClusterImageCatalog `postgresql-standard-trixie`**(upstream vendoring)를 소유한다. Argo CD Application **`platform-cnpg` 하나**가 이 디렉터리 하나를
적용한다 — 과제 문면의 "operator Application + plugin-barman-cloud Application"은 계약 §sync-wave 단일 표의 `cnpg` 행("CNPG operator + barman-cloud
plugin") 하나로 구현했다(표에 없는 디렉터리는 validate 7.2가 거부하고, 플러그인은 operator와 **같은 ns**에 있어야만 발견된다 — §4).
설치 방식은 `platform/cert-manager/`·`platform/vault/`·`platform/external-secrets/`·`platform/reloader/`와 같은 kustomize `helmCharts` 인플레이트다(§1).

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` **2항목**(같은 HTTPS helm repo) + `valuesInline` 전량 + CRD 삭제 보호 `patches`(SMP, CRD 12장). 이 디렉터리가 만들지 않는 것의 경계는 머리 주석 |
| `clusterimagecatalog-standard-trixie.yaml` | upstream 카탈로그 vendoring(6 major · 본문은 upstream과 **바이트 단위 동일**) + 리소스 수준 sync-wave `"1"`. 출처 URL·커밋·sha256은 파일 머리 주석, 갱신 절차는 §2 |

> **머지 = 즉시 자동 sync = CRD 12장 + Deployment 2 기동 = 이 시점부터 CNPG CR의 admission이 `Fail`로 동작한다**(§4).
> 같은 PR이 AppProject `platform`(`clusters/oci-k3s/projects/platform.yaml`)의 두 곳을 함께 바꾼다 — ① `sourceRepos`의 cloudnative-pg 줄 삭제(§1),
> ② `clusterResourceWhitelist`에 `postgresql.cnpg.io` / `ClusterImageCatalog` 추가(§0 마지막 불릿 — 지시문에 없던 항목을 빌더가 렌더 대조에서 발견해 더했다).

- **이 저장소에 비밀은 없다.** 이 디렉터리의 3개 파일에는 토큰·키·OCID가 한 건도 없다. 런타임 Secret **4장**(operator가 만드는 `cnpg-webhook-cert` + 그 CA
  `cnpg-ca-secret` — CNPG 1.30 `internal/cmd/manager/controller/controller.go` `WebhookSecretName` :63 · `CaSecretName` :76 / cert-manager가 만드는
  `barman-cloud-server-tls` · `barman-cloud-client-tls`)은 전부 런타임 산출물이다 — 희망 상태에 Secret은 0장이다(§4 · 되돌리기 삭제 목록은 §6).
- **전역 `namespace:` 변환기가 없다.** 없는 것이 정답이다 — 이유는 §0 마지막 불릿.
- 로컬 재현(리뷰어용, helm 필요 — 아래 한 줄):
  ```bash
  kustomize build --enable-helm platform/cnpg | kubeconform -strict -ignore-missing-schemas -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  # 2026-10-08 실측(kustomize v5.8.1 · helm v4.3.0 · kubeconform v0.8.0): 문서 35장 · Valid 23 · Invalid 0 · Errors 0 · Skipped 12(= CRD 12장)
  #   ClusterImageCatalog · Issuer · Certificate는 datreeio 카탈로그 스키마로 **실제로 검증된다**(Skipped가 아니다 — validate 검사 1도 같은 두 스키마 위치를 쓴다).
  ```
  렌더하면 `platform/cnpg/charts/`(차트 사본 2개 — `cloudnative-pg-0.29.0/` · `plugin-barman-cloud-0.7.1/`)가 생긴다. `.gitignore`의 `charts/`(T042 PR-0)가
  잡으므로 `git add`에 끌려오지 않는다(validate 12.5가 자리를 본다).

---

## 0. 소유 / 비소유

**이 디렉터리가 만드는 것**(Argo CD 적용 대상 = 로컬 렌더 결과. 2026-10-08 실측 **35장** — kind별 대조 명령은 §2):

| 객체 | 수 | 출처 | 역할 |
|---|---|---|---|
| CustomResourceDefinition | 12 | 차트 2개의 `templates/crds/crds.yaml` | `postgresql.cnpg.io` 11(backups · clusters · clusterimagecatalogs · databaseroles · databases · failoverquorums · imagecatalogs · poolers · publications · scheduledbackups · subscriptions) + `barmancloud.cnpg.io` 1(objectstores). 전부 `Delete=false,Prune=false`(§6) · `helm.sh/resource-policy: keep`도 남는다(Argo와 무관) |
| Deployment `cnpg-cloudnative-pg` · `plugin-barman-cloud` | 2 | 차트 | operator · 백업 플러그인. 둘 다 replicas 1 · `nodeSelector role: data`(노드 B). 플러그인은 `strategy: Recreate`(차트 고정) |
| ServiceAccount `cnpg-cloudnative-pg` · `plugin-barman-cloud` | 2 | 차트 | 두 파드의 신원 |
| ClusterRole `cnpg-cloudnative-pg`(규칙 23) · `plugin-barman-cloud`(규칙 7) | 2 | 차트 | 폭발 반경은 §5 |
| ClusterRole `cnpg-cloudnative-pg-view` · `-edit` | 2 | 차트 | **aggregate 라벨 0 · 바인딩 0**(`rbac.aggregateClusterRoles: false`) — 객체만 있고 아무에게도 권한을 주지 않는다(§5) |
| ClusterRoleBinding `cnpg-cloudnative-pg` · `plugin-barman-cloud-binding` | 2 | 차트 | 위 두 본체 ClusterRole ↔ 차트 SA(ns `cnpg-system`) |
| Role / RoleBinding `plugin-barman-cloud-leader-election-role` / `-rolebinding` | 2 | 차트 | ns `cnpg-system` 안 리더 선출(configmaps · leases 전체 동사 · events create,patch) |
| Service `cnpg-webhook-service` | 1 | 차트 | 443 → targetPort 이름 `webhook-server`(= 9443). API 서버가 여기로 dial 한다 |
| Service `barman-cloud` | 1 | 차트 | 9090 → 9090. 라벨 `cnpg.io/pluginName: barman-cloud.cloudnative-pg.io` + 어노테이션 `cnpg.io/pluginPort: "9090"` · `pluginServerSecret: barman-cloud-server-tls` · `pluginClientSecret: barman-cloud-client-tls` = operator의 플러그인 발견 계약(§4) |
| ConfigMap `cnpg-controller-manager-config` | 1 | 차트 | `ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES: "true"` 한 키(§3) — operator args `--config-map-name=cnpg-controller-manager-config` |
| ConfigMap `cnpg-default-monitoring` | 1 | 차트 | 인스턴스 exporter(data 9187)의 기본 쿼리 — 차트 기본값 그대로(`MONITORING_QUERIES_CONFIGMAP` env) |
| ConfigMap `plugin-barman-cloud-config` | 1 | 차트 | `SIDECAR_IMAGE` = 사이드카 digest(§2) — operator가 ns `data`의 인스턴스 파드에 주입한다 |
| MutatingWebhookConfiguration `cnpg-mutating-webhook-configuration`(webhook 4: backups · clusters · databases · scheduledbackups) · ValidatingWebhookConfiguration `cnpg-validating-webhook-configuration`(webhook 5: + poolers) | 2 | 차트 | `failurePolicy: Fail` · `sideEffects: None` · operations **CREATE·UPDATE만**(DELETE 없음 — §4). `caBundle` 필드는 희망 상태에 **없다**(operator가 런타임에 채운다) |
| Issuer `plugin-barman-cloud-selfsigned-issuer` | 1 | 차트 | `selfSigned: {}` — "cert-manager 재사용"의 실체(§4) |
| Certificate `barman-cloud-server`(dnsNames `[barman-cloud]`) · `barman-cloud-client` | 2 | 차트 | Secret `barman-cloud-server-tls` · `barman-cloud-client-tls`, duration 2160h · renewBefore 360h |
| ClusterImageCatalog `postgresql-standard-trixie` | 1 | `clusterimagecatalog-standard-trixie.yaml` | 6 major(13–18). `pg-main`(T053)이 `major: 18`만 참조 — 나머지 5개는 참조되지 않는 선언 |

**이 디렉터리가 만들지 않는 것**:

- Namespace `cnpg-system` · PSA 라벨(**baseline**) · NetworkPolicy(`default-deny` · `allow-dns` · `allow-same-namespace` · `allow-kube-api` ·
  `allow-apiserver-webhook` 9443 · `allow-scrape-from-monitoring` 8080) → `platform/policies/`. **이미 적용돼 있다**(T041) — 이 PR은 정책을 한 줄도 바꾸지 않는다.
  ⚠ operator(`cnpg-system`) → 인스턴스 파드(`data`) **8000** 경로는 계약·정책 어디에도 없다 — T053 **전**에 계약 PR → 정책 PR로 더한다(§8 · 2026-10-08 리뷰 K1).
- `Cluster pg-main` · `ObjectStore oci-backups` · `ScheduledBackup` → `platform/cnpg-cluster/`(T053). `Database` · `DatabaseRole` → `platform/cnpg-databases/`(T054).
  CRD 제공자(여기)와 소비자(거기)는 다른 Application이다.
- Application `platform-cnpg` → `clusters/oci-k3s/apps/platform-cnpg.yaml`(T041부터 라이브). 이 PR은 그 파일을 **건드리지 않는다** —
  검사 7.1이 `source.path = platform/cnpg`를 대조한다.
- 시크릿 값: 없다.
- AppProject `platform`은 이 디렉터리 소유가 아니지만 **같은 PR에서 두 곳이 움직인다** — ① `sourceRepos` 줄 삭제(§1) ② **`clusterResourceWhitelist`에
  `postgresql.cnpg.io` / `ClusterImageCatalog` 추가.** whitelist는 열거형이고(와일드카드 금지) ClusterImageCatalog는 클러스터 범위 CR이라, 거기 없으면
  Argo CD가 `resource postgresql.cnpg.io:ClusterImageCatalog is not permitted in project platform`으로 거부한다(그 파일 주석: "빠진 kind 는 sync 실패로 드러나고
  whitelist 추가 PR 1건으로 푼다"). T041이 `ClusterIssuer`·`ClusterSecretStore`를 미리 올린 것과 같은 자리다. 지시문에 없던 항목을 빌더가 렌더의 클러스터 범위
  kind 목록(CRD · ClusterRole · ClusterRoleBinding · webhook 설정 2 · ClusterImageCatalog)을 whitelist와 대조하다 발견해 더했다 — 리뷰 대상이며,
  validate에는 "렌더의 클러스터 범위 kind ⊆ whitelist" 정적 검사가 없다(후속 후보, §8).

> sync-wave 숫자는 여기 적지 않는다. 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**이고 코드 사본은 `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
> 카탈로그 파일의 `argocd.argoproj.io/sync-wave: "1"`은 **그 표의 숫자가 아니라** 이 Application 안의 리소스 적용 순서다(§2 카탈로그 절).

- **전역 `namespace:` 변환기가 없다** — 차트 객체는 `helmCharts[].namespace: cnpg-system`으로 렌더되고, 카탈로그는 클러스터 범위라 `metadata.namespace`가 없다.
  변환기를 두면 클러스터 범위 객체 21장(CRD 12 · ClusterRole 4 · ClusterRoleBinding 2 · webhook 설정 2 · ClusterImageCatalog 1)에 ns가 찍힌다
  (cert-manager·ESO 선례). `platform/cloudflared`·`platform/system-upgrade`는 변환기를 쓰므로 거기서 복사할 때 주의한다.

---

## 1. 왜 kustomize `helmCharts` 인플레이트인가

cert-manager(T042 D1)·vault(T044)·ESO(T045)·reloader(T046)와 같은 이유이고, 같은 대가를 알고 골랐다.

1. **검사 7.1이 `source.path`를 강제한다.** `platform-cnpg`의 `.spec.source.path`는 `platform/cnpg`여야 한다. Argo 네이티브 helm source(`source.chart`)에는
   `path`가 없어 즉시 FAIL이고, 차트 둘을 Application 둘로 나누려면 계약 §sync-wave 표와 `validate.sh`를 함께 고쳐야 한다.
2. **Application source가 gitops 저장소 하나뿐이다.** 차트 2개는 repo-server의 kustomize가 `helmCharts[].repo`에서 직접 당긴다. AppProject `platform`의
   `sourceRepos`는 Application `source.repoURL`만 검사하므로 거기 있던 `https://cloudnative-pg.github.io/charts` 줄은 아무것도 통제하지 않았다 —
   **이 PR에서 지웠다**(D7 규칙의 다섯 번째 실행). T046과 같이 컴포넌트와 **같은 PR**이다: 이 줄을 `source.repoURL`로 쓰는 Application이 처음부터 0이라
   순서를 나눠도 원인 구분 신호가 생기지 않는다.
3. **차트 출처의 유일한 통제는 `tests/validate.sh` 검사 12.1의 허용 목록**(`HELM_CHART_TABLE` — 계약 §validate.yml 4 (T047) 표의 유일한 코드 사본)이다.
   이 PR이 `cloudnative-pg` · `plugin-barman-cloud` 두 행을 더했다(계약 표가 먼저다 — 모노레포 `0b8917c`). (name, repo) 쌍 글자 단위 일치라
   `oci://` 접두나 끝의 `/`가 붙으면 FAIL이다.
4. **HTTPS helm repo라 `oci://` 접두가 없다**(ESO·vault와 같고 cert-manager와 반대). 한 저장소에서 차트 둘을 받는다.
5. **helm 릴리스가 아니다.** `helm list -n cnpg-system`은 비어 있고 `helm rollback`·`helm uninstall`은 쓸 수 없다. 되돌리기는 §6의 git 경로뿐이다.
6. 전제: `bootstrap/argocd/argocd-cm.yaml`의 `kustomize.buildOptions: "--enable-helm"`(T042 PR-0, 라이브 · validate 12.4가 본다). 없으면 `platform-cnpg`가
   `ComparisonError`로 굳는다 — 리소스 손실은 없지만(`prune: false`) `argo-1`과 root 헬스 신호를 잃는다.
7. 부수 효과로 **검사 5.4b가 살아 있다** — `valuesInline`의 `.webhook.port`(`HELM_PORT_KEYS cnpg .webhook.port 9443`)를 계약 §포트 각주와 대조한다.
   **키가 없으면 조용히 건너뛰므로** 값 그대로 명시했다. `service.port`(443 · 9090)는 적지 않는다 — 5.4c가 정책 포트에 없는 port 값을 WARN으로 올린다.
8. **CRD 2장이 256 KiB를 넘는다**(렌더 원문 기준 `clusters.postgresql.cnpg.io` 464,022 B · `poolers.postgresql.cnpg.io` 653,565 B — yq 재직렬화로는 472,391 · 655,912 B,
   한도 262,144 B). Argo CD는 `ServerSideApply=true`라 무관하다. **수동 적용은 `kubectl apply --server-side` / `kubectl create` / `kubectl replace`만** — 클라이언트 사이드
   `kubectl apply`는 `kubectl.kubernetes.io/last-applied-configuration` 어노테이션 한도(256 KiB)에 걸려 `metadata.annotations: Too long`으로 실패한다.

---

## 2. 차트 bump 절차 · 카탈로그 갱신

`kustomization.yaml`에서 함께 움직여야 하는 곳은 **일곱 군데**다(차트 version 2 + tgz sha256 주석 2 + 이미지 digest 3).

| 위치 | 값(2026-10-08 실측) | 누가 갱신하나 |
|---|---|---|
| `helmCharts[0].version` | `0.29.0`(appVersion `1.30.0`) | Renovate(T116)가 올릴 수 있다. **2026-10-08 index.yaml 최신은 0.29.1(appVersion 1.30.1, 2026-09-23)** — 과제 문면이 0.29.0으로 동결, 올리는 결정은 사용자 몫 |
| `helmCharts[1].version` | `0.7.1`(appVersion `v0.14.0`) | 같다. **최신은 0.8.1(appVersion v0.15.1, 2026-09-30)** |
| `version:` 줄 주석의 tgz sha256 ×2 | `668e065ff53508d5…0e6a9362e6d32f` · `3b385372b21c9a5b…a50eb6207f2`(index.yaml `digest` = tgz sha256) | **사람이** — 값 고정이 아니라 **같은 버전 재푸시의 대조용 기록** |
| `image.tag`(operator) | `1.30.0@sha256:a2701eb97cdd2a34…cd8580efefebb` | **사람이** — 멀티아치 **인덱스** digest(linux/amd64 + linux/arm64 확인) |
| `image.tag`(plugin) | `v0.14.0@sha256:823a8893690980ba…33baebf32417c` | **사람이** |
| `sidecarImage.tag` | `v0.14.0@sha256:9880817c285c7afa…9abe59b1feb558a4` | **사람이** — ConfigMap `SIDECAR_IMAGE`로 간다(인스턴스 파드 주입). plugin과 sidecar는 같은 appVersion 태그지만 **다른 이미지 · 다른 digest** |

**⚠ 세 digest는 별개 트리이고 자동 검사가 없다.** validate 4b는 저장소 파일의 `image:` 스칼라 줄만 보는데 여기서는 `image.tag`/`sidecarImage.tag` 블록 표기라
매칭하지 않는다(카탈로그 파일의 `image:` 6줄만 4b가 본다 — 전부 digest 병기라 통과). **유일한 방어선은 렌더 결과 대조다** — bump PR 본문에 아래 출력을 붙인다.

**⚠ cloudnative-pg 차트의 `values.schema.json`에는 `additionalProperties`가 0곳이다**(plugin 차트는 12곳이 있지만 **전부 `true`(열림)**라 마찬가지다 — 2026-10-08 원본
확인). 키 오타(`nodeSelctor` 등)는 조용히 무시되고 렌더는 성공한다 — 파드가 노드 A에 뜨고 아무 검사도 울리지 않는다.

```bash
kustomize build --enable-helm platform/cnpg > /tmp/cnpg.yaml
yq -N '.kind' /tmp/cnpg.yaml | wc -l                                                                 # 35
yq -N '.kind' /tmp/cnpg.yaml | sort | uniq -c | sort -rn                                             # 아래 실측표
grep -c 'kind: CustomResourceDefinition' /tmp/cnpg.yaml                                              # 12
grep -c 'argocd.argoproj.io/sync-options: Delete=false,Prune=false' /tmp/cnpg.yaml                   # 12
grep -c 'ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0@sha256:a2701eb9' /tmp/cnpg.yaml                # 2  (Deployment image + env OPERATOR_IMAGE_NAME)
grep -c 'ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.14.0@sha256:823a8893' /tmp/cnpg.yaml         # 1
grep -c 'ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.14.0@sha256:9880817c' /tmp/cnpg.yaml # 1  (ConfigMap SIDECAR_IMAGE)
grep -c 'role: data' /tmp/cnpg.yaml                                                                  # 2
grep -c -- '--webhook-port=9443' /tmp/cnpg.yaml                                                      # 1
grep -c 'aggregate-to-' /tmp/cnpg.yaml                                                               # 0
grep -c 'serviceaccounts/token' /tmp/cnpg.yaml                                                       # 0
grep -c 'helm.sh/hook' /tmp/cnpg.yaml                                                                # 0  (두 차트 모두 templates/tests · 훅이 없다)
grep -c '@sha256:' /tmp/cnpg.yaml                                                                    # 11 = 이미지 참조 10 + CRD 스키마 설명문 1(`<image>:<tag>@sha256:<digestValue>`)
kubeconform -strict -ignore-missing-schemas -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' /tmp/cnpg.yaml
#   Summary: 35 resources found in 1 file - Valid: 23, Invalid: 0, Errors: 0, Skipped: 12
```

**2026-10-08 실측 kind별 장수(합계 35 = cloudnative-pg 차트 **22** + plugin 차트 **12** + 카탈로그 1)** — cloudnative-pg 22 = CRD 11 · ClusterRole 3 · ConfigMap 2 ·
Deployment · Service · ServiceAccount · ClusterRoleBinding · MutatingWebhookConfiguration · ValidatingWebhookConfiguration 1씩(`config.clusterWide: true`에서는
Role/RoleBinding을 렌더하지 않는다 — 차트 `templates/rbac.yaml:80` `if eq .Values.config.clusterWide false`) / plugin 12 = CRD 1 · ClusterRole 1 · ConfigMap 1 ·
Certificate 2 · Deployment · Service · ServiceAccount · ClusterRoleBinding · Role · RoleBinding · Issuer 1씩:

| kind | 장 | 내역 |
|---|---|---|
| CustomResourceDefinition | 12 | operator 11 + plugin 1 |
| ClusterRole | 4 | `cnpg-cloudnative-pg` · `-view` · `-edit` · `plugin-barman-cloud` |
| ConfigMap | 3 | `cnpg-controller-manager-config` · `cnpg-default-monitoring` · `plugin-barman-cloud-config` |
| Deployment · Service · ServiceAccount · ClusterRoleBinding · Certificate | 2씩 | §0 표 |
| MutatingWebhookConfiguration · ValidatingWebhookConfiguration · Issuer · Role · RoleBinding · ClusterImageCatalog | 1씩 | §0 표 |

**절차**(차트 bump) — 차트 버전을 올리는 PR에서:

1. `helmCharts[0].version` · `helmCharts[1].version`을 새 버전으로(둘을 함께 올릴 필요는 없다 — 각자 독립 차트).
2. `https://cloudnative-pg.github.io/charts/index.yaml`의 `entries.cloudnative-pg[]` · `entries.plugin-barman-cloud[]`에서 그 버전 항목의 `digest`(tgz sha256)를
   `version:` 줄 주석에. 차트 태그는 가변이므로 이 기록이 **같은 버전 재푸시의 유일한 대조 수단**이다(단계 5의 캐시 서술과 짝). tgz를 직접 받아 `sha256sum`으로
   대조한다 — 이 워크스테이션의 `helm pull --repo …`는 캐시 오류를 내므로(2026-10-08) GitHub Releases의 tgz URL(index.yaml `urls`)을 `curl`로 받는다.
3. 새 appVersion의 **인덱스 digest 3개**(operator · plugin · sidecar)를 `image.tag` · `image.tag`(plugin) · `sidecarImage.tag`에 `<tag>@sha256:<digest>` 형태로.
   아키텍처별 digest가 아니라 매니페스트 리스트 digest여야 한다(노드 2대 arm64 Ampere A1). 얻는 법: 익명 토큰
   `https://ghcr.io/token?scope=repository:cloudnative-pg/<repo>:pull` → `GET https://ghcr.io/v2/cloudnative-pg/<repo>/manifests/<tag>`에 Accept
   `application/vnd.oci.image.index.v1+json` → 응답 헤더 `docker-content-digest`; 본문 `manifests[].platform`에 `linux/arm64`가 있는지 본다.
4. 위 grep 묶음을 돌려 출력을 PR 본문에.
5. **캐시 범위**: `charts/<name>-<version>/`이라 version bump는 캐시 미스(즉시 새로 pull). 가려지는 것은 **같은 버전 문자열의 재푸시**뿐이고 그때는 repo-server
   재시작(또는 그 `charts/` 제거)이 필요하다(ESO README §2 단계 5와 같다 — 라이브 미확인). 그 경우의 대조 수단이 단계 2의 tgz sha256.
6. **둘 다 Deployment라 머지 = 즉시 롤아웃이다.** operator 교체 시 `ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES`가 인스턴스 파드 재시작을 피한다(§3 — 라이브 미실측).
   플러그인은 `Recreate`라 교체 중 잠깐 0 replicas다 — 그 사이의 백업·WAL 아카이브 호출은 실패하고 재시도된다(라이브 미실측).
7. CRD 12장이 함께 갱신되므로 새 필드·제거된 필드가 곧바로 적용된다. CRD의 `Delete=false,Prune=false`는 패치라 자동으로 유지된다(렌더 grep으로 확인 — 위 12).

**카탈로그 갱신 절차**(`clusterimagecatalog-standard-trixie.yaml` — major 18 minor 올림 포함):

1. upstream 파일을 받는다: `curl -fsSL https://raw.githubusercontent.com/cloudnative-pg/artifacts/main/image-catalogs/catalog-standard-trixie.yaml -o /tmp/cat.yaml`
   → `sha256sum /tmp/cat.yaml`, GitHub API `repos/cloudnative-pg/artifacts/commits?path=image-catalogs/catalog-standard-trixie.yaml&per_page=1`의 `sha`·
   `commit.committer.date`를 파일 머리 주석에 적는다.
2. major 18 줄의 digest를 ghcr 인덱스 digest와 대조한다(위 단계 3과 같은 방법 — repo `cloudnative-pg/postgresql`, 태그 = 그 줄의 태그). 다르면 upstream이
   아직 반영 전이거나 재푸시된 것이다 — 머지하지 않는다.
3. 주석 블록과 `annotations` 2줄을 제외한 본문을 upstream과 **바이트 단위로** 같게 둔다:
   `diff /tmp/cat.yaml <(grep -v '^[[:space:]]*#' platform/cnpg/clusterimagecatalog-standard-trixie.yaml | grep -v -E '^  annotations:$|^    argocd.argoproj.io/sync-wave:')`
   → 출력 없음(`cmp`로도 같다). 13–17 항목을 trim하지 않는 이유 = 이 대조가 성립해야 vendoring이다.
4. **유지보수 창에 머지한다** — `pg-main`(T053)은 인스턴스 1개라 카탈로그의 major 18 이미지가 바뀌면 operator가 그 파드를 새 이미지로 재생성한다 = PG 재시작
   (수 초~수십 초 다운타임). 13–17 항목의 변화는 아무 효과가 없다(참조하는 Cluster가 없다). Renovate가 이 파일의 6줄에 PR을 낸다면 T116에서 packageRule로 거른다.
5. 리소스 수준 sync-wave `"1"`은 그대로 둔다(아래).

**리소스 수준 sync-wave(저장소 첫 사용)** — 카탈로그 CR에만 `argocd.argoproj.io/sync-wave: "1"`. Application 표의 wave가 아니라 **이 Application 안의 적용 순서**다:
Argo는 같은 sync에서 wave 0(CRD 12 · Deployment 2 · 나머지 전부)이 Synced **and** Healthy(CRD는 Established · Deployment는 Available)가 된 뒤 wave 1을 적용한다.
`SkipDryRunOnMissingResource=true`가 dry-run은 넘겨도, 같은 wave였다면 첫 apply가 CRD established 전에 "no matches for kind"로 실패해 selfHeal 재시도에 기대야 한다 —
그것을 피한다. 실제로 필요한 것은 CRD established뿐이다: 렌더 실측으로 webhook 설정 2장의 rules에 `clusterimagecatalogs`는 **없으므로** operator webhook 준비는 이 CR의
조건이 아니다(Deployment Healthy까지 기다리는 것은 보수적 순서). 검사 7.1은 Application 어노테이션만 보므로 이 값과 무관하다. ⚠ 첫 sync에서 한 번에 Synced/Healthy가
되는지는 VD(§7).

---

## 3. values 선택 근거 (전문은 `kustomization.yaml` 주석)

| 키 | 값 | 이유 |
|---|---|---|
| `patches`(CRD) | `argocd.argoproj.io/sync-options: Delete=false,Prune=false` | 계약 §삭제 보호. 두 차트 모두 `crds.annotations` 류 키가 **없어** cert-manager 선례의 kustomize SMP 패치로 CRD **12장 전부**에 붙인다(실측 12/12). 하네스 `argo-4-cnpg-crd`가 값의 글자·순서를 정확 일치로 본다 |
| `replicaCount`(둘 다) | `1` | 노드 B 단독 배치. 차트 기본값이지만 명시 |
| `nodeSelector`(둘 다) | `role: data` | 과제 문면 · plan A14 노드 B(cert-manager 3종과 같은 노드). 렌더 실측 2건. 배치 단언은 T097 |
| `image.tag`(둘 다) · `sidecarImage.tag` | `<tag>@sha256:<인덱스 digest>` | 두 차트 모두 `image.digest` 키가 **없다** → 태그 문자열에 병기(ESO 선례). `repo:tag@digest`는 유효한 OCI 참조. operator env `OPERATOR_IMAGE_NAME`도 같은 문자열(인스턴스 파드의 instance manager init 이미지) |
| `crds.create`(둘 다) | `true` | 기본값 명시. CRD는 `templates/crds/crds.yaml`로 렌더되므로 `includeCRDs` 불필요 |
| `config.data.ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES` | `"true"`(문자열) | research CNPG-D1 — operator 업그레이드 때 인스턴스 파드를 재시작하지 않고 instance manager 바이너리만 제자리 교체. 단일 PG 인스턴스의 재시작 다운타임 회피. ConfigMap data라 문자열이어야 한다(실측 렌더 `"true"`) |
| `config.create` · `config.clusterWide` | `true` · `true` | 기본값 명시. `clusterWide: false`면 차트가 Role/RoleBinding 경로로 바뀌고 `WATCH_NAMESPACE`가 붙는다 — ns `data`의 Cluster를 못 본다 |
| `webhook.port` | `9443` | 명시해야 validate 5.4b(`HELM_PORT_KEYS`)가 **실제로 대조한다**. 계약 §포트 각주 · `PORT_TABLE` · 정책 `allow-apiserver-webhook` **3중 일치 — 변경 금지**(셋을 함께). Service 443 → targetPort 이름 `webhook-server` |
| `webhook.mutating.failurePolicy` · `webhook.validating.failurePolicy` | `Fail` · `Fail` | 차트 기본값 명시. 대가는 §4(CREATE·UPDATE 거부 — DELETE는 가로채지 않는다) |
| `rbac.create` · `rbac.aggregateClusterRoles` | `true` · **`false`** | 기본값이지만 **명시**. 차트는 `-view`·`-edit` ClusterRole을 항상 렌더하고 `aggregate-to-*` 라벨만 이 키로 켠다 — 켜면 validate 13.6 기준선("aggregate 라벨 ClusterRole 정확히 5" = cert-manager 3 · ESO 2)이 깨지고 내장 `view`에 걸린 `agent-view-view`가 넓어진다. agent-view는 이미 `platform/policies/rbac-agent-view.yaml`의 `agent-view-extra`로 `postgresql.cnpg.io`(clusters · backups · scheduledbackups · databases · databaseroles)를 읽는다 — T052가 RBAC에 더할 것은 없다 |
| `rbac.cnpgGroup`(plugin) | `postgresql.cnpg.io` | 기본값 명시 — plugin ClusterRole의 `backups` get/list/watch · `clusters/finalizers` update의 API 그룹 |
| `containerSecurityContext` · `podSecurityContext`(둘 다) | 차트 기본값 **전체 맵** 명시 | 계약 §워크로드 강화(helm 컴포넌트는 values에 securityContext 명시). ns PSA baseline이라 admission 조건은 아니지만 의도를 코드에. 깊은 병합에 기대지 않고 전체를 적었다(allowPrivilegeEscalation false · readOnlyRootFilesystem true · runAsUser/Group 10001 · seccomp RuntimeDefault · drop ALL / runAsNonRoot true · seccomp RuntimeDefault) — 렌더 실측 두 Deployment 동일 |
| `resources` | operator requests 50m/200Mi · limits memory 400Mi / plugin requests 20m/100Mi · limits memory 200Mi | 차트 기본 `{}`. plan A14 노드 B 예산 "CNPG 오퍼레이터 0.2 GiB · barman-cloud 플러그인 0.1 GiB"(requests 기준)의 대조용 **초기 추정** — T097 실측으로 교정(VD). CPU limit은 두지 않는다(저장소 관례) |
| `monitoring.podMonitorEnabled` · `monitoring.grafanaDashboard.create` | `false` · `false` | 기본값 명시 — PodMonitor CRD가 없다. 스크레이프는 T098(`platform/monitoring`) 소유, metrics 8080은 정책 `allow-scrape-from-monitoring` 행과 짝 |
| `certificate.*`(plugin) | `createIssuer true` · `issuerName ""` · `createServerCertificate true` · `createClientCertificate true` · `duration 2160h` · `renewBefore 360h` | 전부 차트 기본값 명시 — §4 |

**적지 않은 키와 이유**:

| 적지 않은 키 | 이유 |
|---|---|
| `service.*`(둘 다 — 443 · 9090) | 차트 기본 그대로. 적으면 validate 5.4c가 "정책 포트에 없는 port 값"으로 WARN을 올린다(내부 포트라 정책에 없다). plugin의 Service 이름 `barman-cloud`는 차트가 "변경 금지"로 못박는다(인증서 dnsNames와 발견 계약에 쓰인다) |
| `config.name` · `config.secret` · `config.maxConcurrentReconciles` | 기본값(`cnpg-controller-manager-config` · `false` · `10`) |
| `monitoringQueriesConfigMap.*` | 기본 쿼리 ConfigMap 1장 그대로(`cnpg-default-monitoring`) |
| `additionalArgs` · `additionalEnv`(둘 다) | 과제 문면 밖. plugin의 `--log-level=debug`는 차트 고정 인자라 이 키로 **바꿀 수 없고** 덧붙일 수만 있다(§4) |
| `hostNetwork` · `priorityClassName` · `updateStrategy` · `affinity` · `tolerations` · `topologySpreadConstraints` | 기본값. plugin의 `updateStrategy`는 템플릿이 쓰지 않는다(`Recreate` 고정) |
| 전역 `namespace:` 변환기 | §0 마지막 불릿 |

---

## 4. 플러그인 인증서 · 발견 계약 · webhook

**발견 계약**(렌더 실측 — Service `barman-cloud`): operator는 **자기 ns**에서 라벨 `cnpg.io/pluginName`을 가진 Service를 찾아 어노테이션
`cnpg.io/pluginPort`(`"9090"`) · `cnpg.io/pluginServerSecret`(`barman-cloud-server-tls` — 서버 인증서 검증용) · `cnpg.io/pluginClientSecret`
(`barman-cloud-client-tls` — operator가 제시할 클라이언트 인증서)로 gRPC **mTLS** 연결을 만든다. 그래서 플러그인은 operator와 **같은 ns 필수**다 —
다른 ns에 두면 찾지 못하고, 이 저장소에서는 계약 §sync-wave 표의 `cnpg` 행 하나가 둘을 담는다. 통신(operator 파드 → plugin 9090)은 정책 `allow-same-namespace`로
통한다 — 정책 변경 0.

**"cert-manager 재사용"의 뜻**: cert-manager **설치**(CRD·컨트롤러, 앞 wave T042)를 재사용해 차트가 자체 self-signed `Issuer plugin-barman-cloud-selfsigned-issuer`를
만들고 Certificate 2장(`barman-cloud-server` dnsNames `[barman-cloud]` · `barman-cloud-client`)을 발급한다. ClusterIssuer(LE)와 무관하고 공개 인증서가 아니다.
cert-manager가 Secret 2장을 채울 때까지 플러그인 파드는 Secret 볼륨 마운트 대기(ContainerCreating)다 — Certificate Ready까지의 시간은 VD(§7).
agent-view는 `certificates.cert-manager.io`·`issuers.cert-manager.io`를 읽을 수 있다(cert-manager `aggregate-to-view`).

**인증서 갱신(재시작 불필요)**: Certificate 2장은 `duration 2160h`(90일) · `renewBefore 360h`(15일) · `privateKey.rotationPolicy: Always`(렌더 실측)라 발급 ≈ 75일 뒤
cert-manager가 Secret 2장을 새 키·인증서로 교체한다(머지가 2026-10-08이면 첫 갱신 ≈ 2026-12-22 — 정확한 날짜는 `status.renewalTime`). 두 쪽 모두 파일을 다시 읽는다:
플러그인은 cnpg-i-machinery v0.4.2(plugin-barman-cloud `go.mod`)의 `getConfigForClient`가 **연결마다** 인증서 파일을 새로 읽고(`server.go` :264 "loads certificates
fresh for each new connection"), operator는 CNPG 1.30 `internal/cnpi/plugin/repository/setup.go`가 인증서 갱신 시 `RegisterRemotePlugin`을 다시 부른다(:183-184 주석
"called … when the certificates of an existing plugin get refreshed"). 그래서 Reloader 대상이 아니다. 실측은 VD-C9(§7) — 실패하면 갱신 절차에 운영자
`kubectl -n cnpg-system rollout restart deploy/plugin-barman-cloud`를 더한다.

**차트 고정 인자**: plugin args는 `operator --server-cert=/server/tls.crt --server-key=/server/tls.key --client-cert=/client/tls.crt --server-address=:9090
--leader-elect --log-level=debug`로 **고정**이다. `additionalArgs`는 덧붙일 뿐 바꾸지 못한다(같은 플래그를 두 번 줬을 때의 우선순위는 미확인) →
`--log-level=debug`의 로그 양은 **T098 Alloy 필터 후보**로 인계한다(§8). `strategy: Recreate`도 고정 — 차트 주석 "RollingUpdate is not supported by the operator yet".
프로브는 tcpSocket **8081**(readiness · liveness, initialDelay 10s). 8081은 ns 정책에 없다 — kubelet 출발 프로브가 default-deny 아래 통과하는 것은 ESO에서 실측됐고
(VD-9) 이 ns에서는 VD(§7). operator 프로브 3종은 HTTPS `/readyz` **9443**(webhook-server) — 같은 성질.

**operator webhook**(렌더 실측):

| 설정 | webhook | 대상 | operations | failurePolicy |
|---|---|---|---|---|
| `cnpg-mutating-webhook-configuration` | 4 | backups · clusters · databases · scheduledbackups | CREATE · UPDATE | Fail |
| `cnpg-validating-webhook-configuration` | 5 | backups · clusters · scheduledbackups · databases · poolers | CREATE · UPDATE | Fail |

- 9개 전부 `sideEffects: None` · apiGroup `postgresql.cnpg.io` v1 · Service `cnpg-webhook-service` 443(→ 9443).
- **DELETE는 가로채지 않는다** — ESO(§4의 "DELETE도 가로챈다")와 **다르다.** operator가 죽으면 Cluster · Backup · ScheduledBackup · Database · Pooler의 생성·수정이
  거부되고(Argo sync가 그 리소스에서 실패) 삭제는 admission에서 막히지 않는다. 다만 Database · Publication · Subscription은 operator가 **finalizer**로 정리하므로
  operator 없이 지우면 Terminating에 머문다(upstream 문서·소스 기준 — 렌더의 CRD 문면에는 finalizer 서술이 없고 라이브 미실측) — §6의 순서 규율은 그래서 유지한다.
- **ClusterImageCatalog · ImageCatalog · ObjectStore · DatabaseRole은 webhook 대상이 아니다** — 카탈로그 적용에 operator 준비가 조건이 아닌 근거(§2).
- **인증서 흐름**: 희망 상태에 `caBundle` 필드가 **없다**(9개 전부). operator가 Secret `cnpg-webhook-cert`(렌더에 없음 · Deployment 볼륨이 `optional: true`로 마운트)를
  만들고 두 설정에 주입한다 — ClusterRole에 `mutatingwebhookconfigurations,validatingwebhookconfigurations get,patch`가 그 용도다. 희망 상태에 그 필드가 없으므로
  `ignoreDifferences`를 넣지 않았다 — 드리프트로 잡히는지는 ESO VD-5와 같은 판정(15분 간격 2회 Synced 유지, §7).
- **API 서버 → webhook 경로**는 `platform/policies`의 `allow-apiserver-webhook`(ns `cnpg-system`, 9443, 출발 {노드 A private/32, 노드 A flannel/32})이 연다.
  두 파드가 **노드 B**에 있으므로 이 경로는 **노드 간**(API 서버 노드 A → 파드 노드 B)이다 — cert-manager 3종이 같은 배치로 T042에서 통과했고(그 선례가 근거), 이 ns는
  VD(§7). 판정 기준은 ESO README §4와 같다: 유효한 CNPG CR의 `kubectl apply --dry-run=server`가 종료 코드 0(운영자 전용 — T053 전에는 객체를 만들지 않으므로
  dry-run만), 음성 대조는 webhook 규칙을 어기는 Cluster(스키마는 통과)의 `admission webhook "vcluster.cnpg.io" denied the request`.

---

## 5. RBAC — 지금 들이는 권한의 폭발 반경

아래는 전부 **렌더 결과**에서 직접 뽑았다(ClusterRole 4장 · Role 1장 — 2026-10-08 렌더 35장 기준, 동사는 `yq`로 재추출한 그대로 — 묶어 적지 않는다). validate 13의 판정: 토큰 발급 규칙 0 ·
렌더 밖 역할을 가리키는 바인딩 0 · 주체는 전부 이름·ns가 있는 ServiceAccount · aggregate 라벨 0 · aggregationRule 0.

| ClusterRole `cnpg-cloudnative-pg`(규칙 23, 전 네임스페이스) | 비고 |
|---|---|
| `"" configmaps,secrets,services: create,delete,get,list,patch,update,watch` · `configmaps/status,secrets/status: get,patch,update` | 클러스터 **전 Secret** CRUD(ESO 컨트롤러와 같은 급). 인스턴스 자격·TLS·백업 자격이 전부 Secret이라 operator의 존재 이유지만, 파드가 뚫리면 전 ns의 Secret이 읽힌다. ⚠ `create`+`get`은 `kubernetes.io/service-account-token` 타입 Secret을 통한 **임의 SA 레거시 토큰 획득과 등가**(ESO §5와 같은 잔여 위험) |
| `"" persistentvolumeclaims,pods,pods/exec: create,delete,get,list,patch,watch` · `pods/status: get` | **`pods/exec create` 전 ns** — 임의 파드에 exec = 그 파드의 신원·마운트로 행동 가능(`argocd` · `vault` · `external-secrets` 파드 포함). 이 ClusterRole이 들이는 가장 넓은 권한이다 |
| `"" serviceaccounts: create,get,list,patch,update,watch` · `rbac.authorization.k8s.io roles,rolebindings: create,get,list,patch,update,watch` | 인스턴스 SA·Role 생성. **`serviceaccounts/token` 규칙 없음**(validate 13.1 기준선 유지). Role/RoleBinding 생성은 API 서버의 escalation 방지로 자기 권한 범위 안이지만 그 범위가 이미 위처럼 넓다 |
| `"" nodes: get,list,watch` · `discovery.k8s.io endpointslices: get,list,watch` · `coordination.k8s.io leases: create,get,list,update,watch` · `"" events: create,patch` | 노드 토폴로지 · 리더 선출(전역, 이름 제한 없음 — 전 ns의 Lease update 가능) |
| `apps deployments: create,delete,get,list,patch,update,watch` · `policy poddisruptionbudgets: create,delete,get,list,patch,update,watch` · `batch jobs: create,delete,get,list,patch,watch`(update 없음) · `monitoring.coreos.com podmonitors: create,delete,get,list,patch,watch`(update 없음) · `snapshot.storage.k8s.io volumesnapshots: create,get,list,patch,watch`(**delete·update 없음** — 스냅샷을 만들지만 지우지 못한다) | Pooler Deployment · 초기화 Job · PDB · 볼륨 스냅샷 · PodMonitor(CRD 없음 — 미사용 권한). 동사는 렌더 그대로(규칙 5개) |
| `admissionregistration.k8s.io mutatingwebhookconfigurations,validatingwebhookconfigurations: get,patch` | 자기 webhook 설정에 caBundle 주입용인데 **이름 제한이 없다** — cert-manager·ESO의 webhook 설정도 patch 가능(예: `failurePolicy`를 Ignore로). 차트 values로 좁힐 수 없다(`rbac.create: false` + 수기 RBAC 뿐 — 미검증) |
| `postgresql.cnpg.io backups,clusters,databaseroles,databases,poolers,publications,scheduledbackups,subscriptions: create,delete,get,list,patch,update,watch` · `failoverquorums: create,delete,get,list,watch`(patch·update 없음) · `clusterimagecatalogs: get,list,watch` · `imagecatalogs: get,list,watch`(카탈로그 2종은 **읽기뿐**) · `backups/status,databases/status,publications/status,scheduledbackups/status,subscriptions/status: get,patch,update` · `clusters/status,databaseroles/status,poolers/status,failoverquorums/status: get,patch,update,watch` · `clusters/finalizers,databaseroles/finalizers,poolers/finalizers: update` | 자기 CR 군의 조정(규칙 7개). operator는 카탈로그를 고치지 않는다 — 카탈로그의 희망 상태는 이 디렉터리뿐 |

| ClusterRole `plugin-barman-cloud`(규칙 7, 전 네임스페이스) | 비고 |
|---|---|
| `"" secrets: create,delete,get,list,watch` | 전 ns Secret 읽기·생성·삭제(update·patch 없음). ObjectStore 자격(T053 `oci-backups`)을 읽고 사이드카용 Secret을 만든다 |
| `barmancloud.cnpg.io objectstores: create,delete,get,list,patch,update,watch` · `objectstores/status: get,patch,update` · `objectstores/finalizers: update` · `postgresql.cnpg.io backups: get,list,watch` · `clusters/finalizers: update` | 플러그인의 존재 이유(규칙 5개) |
| `rbac.authorization.k8s.io roles,rolebindings: create,get,list,patch,update,watch` | 인스턴스 ns에 사이드카용 Role/RoleBinding 생성 |

- Role `plugin-barman-cloud-leader-election-role`(ns `cnpg-system`, 규칙 3): `configmaps` · `coordination.k8s.io leases`: get,list,watch,create,update,patch,delete(**7동사** — deletecollection 없음) · `events: create,patch` — ns 안이라 폭발 반경이 좁다.
- ClusterRole `cnpg-cloudnative-pg-view`(get,list,watch) · `-edit`(create,delete,deletecollection,patch,update) — `postgresql.cnpg.io` 12종에 대한 규칙 1개씩. **라벨 0 · 바인딩 0**이라
  아무 주체에게도 권한을 주지 않는다. `rbac.aggregateClusterRoles: true`로 바꾸면 내장 `view`·`edit`·`admin`에 합쳐져 `agent-view-view`가 CNPG CR을 **보게 되고**
  edit/admin 바인딩이 생기는 날 그 주체가 Cluster를 만들 수 있다 — validate 13.6이 그 변경을 FAIL로 막는다.
- **받아들인 위험**: CNPG operator는 설계상 cluster-wide로 인스턴스 파드·PVC·Secret·SA·Role을 만든다(`config.clusterWide: true` — ns `data`의 Cluster를 보려면 필요).
  `pods/exec`·전 Secret CRUD·webhook 설정 patch가 가장 넓은 세 권한이고, 차트 values로는 줄이지 못한다(`rbac.create: false` + 수기 ClusterRole이 유일한 길 — 범위 밖 ·
  후속 하드닝 후보 §8). 완화는 노드 B 격리 · ns PSA baseline · `default-deny` 아래 필요한 경로만 연 정책이다.

---

## 6. 되돌리기 — 순서가 곧 안전장치

Application `platform-cnpg`는 `prune: false` + `Prune=confirm` + `Delete=confirm` + `selfHeal: true`다. 그래서

> **git revert 머지가 먼저, 수동 삭제가 그다음.** git을 되돌리지 않은 채 `kubectl delete`부터 하면 selfHeal이 즉시 재생성한다.
> 반대로 revert만 하면 `prune: false` 때문에 객체는 남아 있다(그게 정상 동작이다).

1. revert PR 머지 → `kustomization.yaml`이 `resources: []` 뼈대로 복귀 → 렌더 0 → hard refresh. 객체는 그대로 남는다. 같은 PR의 AppProject 변경(sourceRepos 줄 · whitelist)은
   되돌리지 않아도 해롭지 않다(whitelist 항목은 permission이지 객체가 아니다).
2. **CNPG CR(Cluster · Database …, T053 이후)을 지워야 한다면 지금, operator가 아직 살아 있는 동안에 한다.** webhook은 DELETE를 가로채지 않지만(§4) Database 류의
   finalizer 처리와 Cluster 삭제 시 PVC 정리는 operator가 한다 — operator Deployment를 먼저 지우면 Terminating에 머문다.
3. 운영자가 수동 삭제, **이 순서로**(admin kubeconfig):
   ```powershell
   # ① Deployment 2
   kubectl -n cnpg-system delete deploy cnpg-cloudnative-pg plugin-barman-cloud
   # ② webhook 설정 2 — 이걸 지워야 CNPG CR의 admission이 풀린다(operator가 없으면 CREATE·UPDATE가 전부 거부된다)
   kubectl delete mutatingwebhookconfiguration cnpg-mutating-webhook-configuration
   kubectl delete validatingwebhookconfiguration cnpg-validating-webhook-configuration
   # ③ Service · ConfigMap · Issuer · Certificate · 런타임 Secret · SA · RBAC
   kubectl -n cnpg-system delete svc cnpg-webhook-service barman-cloud
   kubectl -n cnpg-system delete cm cnpg-controller-manager-config cnpg-default-monitoring plugin-barman-cloud-config
   kubectl -n cnpg-system delete certificate barman-cloud-server barman-cloud-client
   kubectl -n cnpg-system delete issuer plugin-barman-cloud-selfsigned-issuer
   kubectl -n cnpg-system delete secret cnpg-webhook-cert cnpg-ca-secret barman-cloud-server-tls barman-cloud-client-tls
   #   cnpg-ca-secret(operator CA)은 남겨 둬도 해롭지 않다 — 다시 배포하면 operator가 그대로 재사용한다
   kubectl -n cnpg-system delete sa cnpg-cloudnative-pg plugin-barman-cloud
   kubectl -n cnpg-system delete role plugin-barman-cloud-leader-election-role
   kubectl -n cnpg-system delete rolebinding plugin-barman-cloud-leader-election-rolebinding
   #   role,rolebinding을 한 명령에 묶으면 타입×이름 조합(role/<rolebinding 이름> · rolebinding/<role 이름>)으로 NotFound 2건 + exit 1
   kubectl delete clusterrole cnpg-cloudnative-pg cnpg-cloudnative-pg-view cnpg-cloudnative-pg-edit plugin-barman-cloud
   kubectl delete clusterrolebinding cnpg-cloudnative-pg plugin-barman-cloud-binding
   ```
4. **④ CRD 12장은 남긴다.** 지우면 클러스터의 **모든 Cluster · Backup · ScheduledBackup · Database · DatabaseRole · ObjectStore CR이 cascade 삭제되고, Cluster가
   지워지면 그 PVC(= PG 데이터)까지 지워진다** — T053 이후 비가역이다. `Delete=false,Prune=false`는 Argo에게 주는 표식일 뿐 `kubectl delete crd`를 막지 않는다.
   정말로 지워야 한다면 남은 CR과 백업을 먼저 확인한다.
5. **⑤ ClusterImageCatalog `postgresql-standard-trixie`는 CRD와 함께 남긴다.** 참조하는 Cluster가 없을 때만 지워도 무해하다(`kubectl delete clusterimagecatalog …`) —
   참조하는 Cluster가 있는데 지우면 그 Cluster의 이미지 해석이 실패한다.

**되돌린 뒤 Application `platform-cnpg`는 OutOfSync로 남는 것이 정상이다** — 남긴 CRD 12장(+카탈로그)에 Argo 추적 어노테이션이 있어 렌더 0에서는 'prune 대상'으로
보이기 때문이다(`prune: false`라 실제로 지워지지는 않는다). 그동안 하네스 `argo-1`은 FAIL하고, `argo-4-cnpg-crd`는 CRD가 남아 있으면 PASS한다 — **operator 생존 신호로
쓰지 않는다.** 이 OutOfSync를 없애려고 CRD를 지우지 않는다. 컴포넌트를 다시 머지하면 Synced로 돌아온다.

렌더 실패는 안전하다(`ComparisonError`, 클러스터 변경 0 — 단 `argo-1`과 root 헬스 신호는 잃는다).

---

## 7. 배포 뒤 확인

agent-view kubeconfig(읽기 전용)로 가능한 명령만 적는다. **라이브 클러스터 접근 없이 작성했다**(KUBECONFIG 없음 — 기대값은 렌더에서 왔고 실측은 머지 뒤 VD).

```powershell
kubectl -n argocd get app platform-cnpg -o jsonpath='{.status.sync.status} {.status.health.status}'
#   Synced Healthy. plugin의 readinessProbe initialDelay 10s · cert-manager 발급 대기 동안은 Progressing이 정상이다.
(kubectl -n argocd get app platform-cnpg -o json | ConvertFrom-Json).status.resources | Group-Object kind | Select-Object Count,Name
#   CustomResourceDefinition 12 · ClusterRole 4 · ConfigMap 3 · Deployment 2 · Service 2 · ServiceAccount 2 · ClusterRoleBinding 2 · Certificate 2 ·
#   Issuer 1 · Role 1 · RoleBinding 1 · MutatingWebhookConfiguration 1 · ValidatingWebhookConfiguration 1 · ClusterImageCatalog 1 = 35
(kubectl -n argocd get app platform-cnpg -o json | ConvertFrom-Json).status.resources |
  Where-Object { $_.kind -eq 'ClusterImageCatalog' } | Select-Object name,status,health
#   postgresql-standard-trixie Synced. ⚠ agent-view는 clusterimagecatalogs를 직접 읽지 못한다(agent-view-extra에 없다) → Application status.resources로 본다.
#   비어 있거나 SyncFailed면 AppProject whitelist(§0)를 먼저 본다.
kubectl -n cnpg-system get deploy -o 'custom-columns=N:.metadata.name,R:.status.readyReplicas,IMG:.spec.template.spec.containers[0].image'
#   cnpg-cloudnative-pg 1 ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0@sha256:a2701eb9…
#   plugin-barman-cloud 1 ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.14.0@sha256:823a8893…
kubectl -n cnpg-system get cm plugin-barman-cloud-config -o jsonpath='{.data.SIDECAR_IMAGE}'
#   ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.14.0@sha256:9880817c…   ← digest 3번째
kubectl -n cnpg-system get cm cnpg-controller-manager-config -o jsonpath='{.data}'
#   {"ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES":"true"}
kubectl -n cnpg-system get deploy cnpg-cloudnative-pg -o jsonpath='{.metadata.labels.helm\.sh/chart}'
#   cloudnative-pg-0.29.0  (plugin: plugin-barman-cloud-0.7.1)
kubectl -n cnpg-system get pod -o wide
#   2개 모두 노드 B(role=data). 노드 A에 있으면 nodeSelector 오타를 의심한다(§2)
kubectl get crd -o 'custom-columns=N:.metadata.name,S:.metadata.annotations.argocd\.argoproj\.io/sync-options' | Select-String 'cnpg.io'
#   12행 전부 Delete=false,Prune=false
#   ⚠ `-o` 값 **전체**를 한 쌍의 작은따옴표로 감싼다 — 토큰 중간에 따옴표를 열면 PowerShell이 그대로 넘겨 S 열이 전부 <none>으로 나온다(ESO README §7 각주).
kubectl -n cnpg-system get certificate,issuer
#   barman-cloud-server · barman-cloud-client READY True · plugin-barman-cloud-selfsigned-issuer READY True
kubectl -n cnpg-system get svc
#   cnpg-webhook-service 443/TCP · barman-cloud 9090/TCP
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --since=10m | Select-String -Pattern 'error|forbidden|barman-cloud.cloudnative-pg.io'
#   error·forbidden 0행. 플러그인 발견 줄(barman-cloud.cloudnative-pg.io)이 있어야 한다 — 정확한 문구는 VD
kubectl auth can-i list databaseroles.postgresql.cnpg.io -n data
#   yes (agent-view-extra — T050 리뷰 인계 확인 항목)
```

**운영자 전용**(admin kubeconfig가 필요하거나 쓰기 성격):

```powershell
(kubectl get validatingwebhookconfiguration cnpg-validating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}').Length   # > 0 (주입 확인)
kubectl get clusterimagecatalog postgresql-standard-trixie -o jsonpath='{.spec.images[?(@.major==18)].image}'
#   ghcr.io/cloudnative-pg/postgresql:18.6-202610050823-standard-trixie@sha256:79be0d10…
# webhook 도달(노드 간 경로) — 객체를 만들지 않는 dry-run. T053 전에 Cluster를 만들지 않는다.
kubectl apply --dry-run=server -f <유효한 최소 Cluster 매니페스트>      # exit 0 · "created (server dry run)"
```

**VD(검증 후 결정 — 머지 뒤 실측해 기록)**:

| ID | 무엇을 | 판정 |
|---|---|---|
| VD-C1 | 첫 sync가 한 번에 Synced/Healthy가 되는가(CRD wave 0 → 카탈로그 wave 1) — operationState의 retry 횟수 · 소요 시간 | 1회 성공이면 리소스 wave 설계 유지. 실패 문면이 `is not permitted in project`면 whitelist(§0), `no matches for kind`면 wave 값 재검토 |
| VD-C2 | webhook `caBundle` 드리프트 — 15분 간격 2회 `Synced` 유지(ESO VD-5와 같은 판정) | OutOfSync면 `ignoreDifferences` PR |
| VD-C3 | Certificate 2 Ready까지 시간 · plugin 파드 Running까지 시간 | 기록만 |
| VD-C4 | operator 로그의 플러그인 발견·등록 줄의 정확한 문구 | §7 grep 패턴 갱신 |
| VD-C5 | 두 파드 노드 B · `kubectl top` 실사용 vs requests(50m/200Mi · 20m/100Mi) | T097이 교정 |
| VD-C6 | kubelet 프로브(9443 HTTPS · 8081 tcp)가 default-deny 아래 통과 — RESTARTS 0 · Ready | 실패면 정책 계약 개정 |
| VD-C7 | 노드 간 webhook 경로(API 서버 노드 A → 파드 노드 B) — 위 운영자 dry-run | 거부·타임아웃이면 `allow-apiserver-webhook` 출발 집합 재검토 |
| VD-C8 | 모노레포 하네스 `tests/platform/cluster.tests.ps1` `argo-4-cnpg-crd` PASS(12장) · `data.tests.ps1`의 CRD 관련 사유가 "CRD not installed (T052)"에서 T053 사유로 바뀜 | T052 완료 신호 |
| VD-C9 | 플러그인 mTLS 인증서 **첫 갱신** 뒤(≈ 2026-12-22 — `kubectl -n cnpg-system get certificate -o jsonpath='{.items[*].status.renewalTime}'`로 날짜 확정, agent-view 가능) operator 로그에 플러그인 재등록 줄 · TLS 오류 0 · 백업 1회 성공(T053 ScheduledBackup 또는 운영자 수동 Backup) | 통과면 "갱신에 재시작 불필요"(§4) 확정. 실패(operator 로그 TLS handshake 오류 · 백업 실패)면 갱신 절차에 운영자 `kubectl -n cnpg-system rollout restart deploy/plugin-barman-cloud`를 추가 |
| VD-C10 | (T053) operator → `pg-main` 인스턴스 파드 **8000** 도달 — §8의 계약·정책 보강 뒤 operator 로그에 status 수집 오류(`/pg/status` 연결 실패 · timeout) 0 · Cluster `status.instancesStatus` 갱신 | 보강 전에 실패가 재현되면 K1 경로의 실측 근거. 5432 필요 여부(문서 문면)도 같은 로그로 판정 — 열지 않고 시작한다 |

---

## 8. 인계

- **T053(`platform/cnpg-cluster/`)**: `Cluster pg-main`(`imageCatalogRef` kind ClusterImageCatalog · name `postgresql-standard-trixie` · major 18) ·
  `ObjectStore oci-backups`(`barmancloud.cnpg.io/v1`, ns `data` — 이 디렉터리 소유 아님) · `ScheduledBackup`. 모노레포 build-notes 「T050 · T051」 인계 그대로:
  ObjectStore `serverName`은 기본(= 클러스터 이름 `pg-main`) 유지 — T050이 `pg-main/pg-main/{base,wals}/` 접두를 고정한다 · `destinationPath s3://joshuatech-backup/pg-main/`
  (버킷 실명 `joshuatech-backup`, 계약의 `jt-backup`은 이름 예외) · 사이드카 env `AWS_REQUEST_CHECKSUM_CALCULATION`·`AWS_RESPONSE_CHECKSUM_VALIDATION` = `when_required`
  (OCI S3 호환 — `AWS_*_CHECKSUM_*=when_required`) · 배포 직후 `status.conditions[type=ContinuousArchiving]` 갱신 여부 실측(T050 bucket-2 규칙). Cluster는 webhook
  `vcluster.cnpg.io`(Fail) 대상이라 operator Healthy 뒤에만 적용된다 — 그 Application도 `SkipDryRunOnMissingResource`를 갖는다(T041 표준).
- **T053 전 계약 변경 선행(2026-10-08 리뷰 K1 — 이 PR에서는 인계만)**: operator(ns `cnpg-system`) → 인스턴스 파드(ns `data`) **8000** 경로가 계약
  `specs/003-platform-foundation/contracts/network-policy.md` 매트릭스에 **없고**, 그 파일 :47이 "CNPG operator ↔ instance"를 `allow-same-namespace`의 근거로
  **오분류**한다(operator와 인스턴스는 다른 ns — 같은 ns 규칙으로는 통하지 않는다). 근거: CNPG 1.30 `docs/src/security.md` :814 "The operator needs to communicate to
  each instance on TCP port 8000 … in case you add any network policy" · `docs/src/networking.md` :26 "ports 8000 and 5432" · `pkg/management/url/url.go` :79
  `StatusPort = 8000`(`/pg/status` · `/pg/backup` · `/update`). **5432는 문서 문면일 뿐** 필요 여부는 VD — 열지 않고 시작해 operator 로그로 판정한다(VD-C10).
  순서: ① 계약 PR(매트릭스 행 추가 + :47 정정) → ② gitops `platform/policies` PR(`data` ingress from `cnpg-system` `podSelector app.kubernetes.io/name=cloudnative-pg`
  8000 · `cnpg-system` egress to `data` 8000 — operator 파드 라벨은 렌더 실측 `app.kubernetes.io/name: cloudnative-pg` · `app.kubernetes.io/instance: cnpg`) →
  ③ 모노레포 `tests/platform/cluster.tests.ps1` np 단언 갱신 → ④ T053. **T052 sync는 막히지 않는다**(Cluster가 없어 이 경로를 쓰는 파드가 아직 없다).
- **T054(`platform/cnpg-databases/`)**: `Database` · `DatabaseRole`(app role 둘에 `login: true` 명시 — T050 role-2). DatabaseRole은 webhook 대상이 아니다(§4).
- **T097**: 배치 단언(Deployment 2 = 노드 B) · 자원 실측 교정(VD-C5) · 플러그인 `Recreate` 교체 중 0 replicas 구간 측정.
- **T098(`platform/monitoring`)**: operator metrics 8080 스크레이프(정책 `allow-scrape-from-monitoring` 행 준비됨 · `monitoring.podMonitorEnabled`는 false 유지) ·
  plugin `--log-level=debug` 로그 필터 후보 · `cnpg-default-monitoring` 쿼리의 인스턴스 exporter(data 9187)는 T053 뒤.
- **T116(Renovate)**: 차트 최신 cloudnative-pg 0.29.1(1.30.1) · plugin 0.8.1(v0.15.1) — 올릴 때 §2의 일곱 군데. 카탈로그 파일 13–17 항목에 대한 PR 소음 가능성 →
  packageRule로 거른다(trim하지 않은 이유는 §2).
- **후속 하드닝 후보(범위 밖)**: ① operator ClusterRole의 `pods/exec` · 전 Secret CRUD · webhook 설정 patch(§5) — `rbac.create: false` + 수기 RBAC는 미검증.
  ② validate에 "platform 렌더의 클러스터 범위 kind ⊆ AppProject whitelist" 정적 검사(§0 — 이번에 사람이 발견했다). ③ plugin `--log-level` 조정은 upstream 차트 변경 필요.
- **VD 목록**: §7 표(VD-C1 ~ C10 — C9 인증서 갱신 · C10 operator → data 8000은 2026-10-08 리뷰 K6 · K1).
