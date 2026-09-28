# platform/reloader/ — 운영자 절차 (T046 G1·G2)

Stakater Reloader 차트 **2.2.16**(appVersion v1.4.21)을 **scoped 모드**로 둔다 — 감시 ns의 Secret·ConfigMap이 바뀌면
어노테이션 `reloader.stakater.com/auto: "true"`를 단 Deployment를 롤링 재시작한다. 설치 방식은
`platform/external-secrets/`·`platform/vault/`·`platform/cert-manager/`와 같은 kustomize `helmCharts` 인플레이트다.
정본 계약은 모노레포 `specs/003-platform-foundation/contracts/gitops-repo.md` §네임스페이스의 `platform/reloader/` 항목,
설계는 `specs/003-platform-foundation/design/t046-design.md`다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(HTTPS helm repo 인플레이트) + `valuesInline` 전량(`resources` 없음). 머리 주석에 scoped 모드·`cloudflared` 제외·권한 사실이 있다 |

- **이 저장소에 비밀은 없다.**
- 로컬 재현(리뷰어용, helm 필요): `kustomize build --enable-helm platform/reloader`. 렌더하면 `platform/reloader/charts/`(차트 사본)가
  생기고 `.gitignore`의 `charts/`가 잡는다.

> sync-wave 숫자는 여기 적지 않는다. 정본은 계약 `gitops-repo.md` §sync-wave **단일 표**이고, 코드 사본은
> `tests/validate.sh`의 `WAVE_TABLE` 하나뿐이다.
>
> CI 강제 여부: 이 README가 말하는 validate 검사(10 REL 포함)는 아직 CI에서 돌지 않는다 — `../../tests/README.md` 「CI 배선 상태」.

---

## 0. 범위와 scoped 모드

**감시 ns = `identity` · `jt-dev` · `jt-prod`** + 릴리스 ns `reloader`(차트가 자동 포함). 목록의 정본은 계약이고, 여기 적은 것은
설명이다(대조 기준은 계약과 `tests/validate.sh`의 `REL_WATCH_NS`).

| ns | 왜 감시하나 |
|---|---|
| `identity` | T080 authentik · T082 openfga가 ESO Secret을 env로 읽는다 |
| `jt-dev` · `jt-prod` | T072 파드 템플릿(Django pod)이 `<pod>-env` Secret을 env로 읽는다 |
| `reloader` | 차트가 자동 포함 — Reloader 자신의 meta-info ConfigMap·events를 위해 필요하다(차트 `_helpers.tpl` 주석) |

- **scoped 모드** = values `reloader.watchGlobally: false` + `reloader.namespaces: [...]`. 차트는 나열한 ns마다 Role + RoleBinding을
  만들고 **ClusterRole·ClusterRoleBinding을 만들지 않는다**(설계 F1). 바이너리는 `--namespaces` 목록의 ns만 감시한다(F2).
- **`cloudflared`는 감시하지 않는다.** 터널 커넥터는 SSH(노드 A·B)와 K8s API의 **유일한 경로**이고, Secret이 바뀌어도 운영자가
  **1개씩 수동 교체**하는 것이 안전장치다(T045 G4 — 자동 재시작이 붙으면 잘못된 kv 값이 두 커넥터를 한꺼번에 교체한다.
  `../cloudflared/README.md` ⑨). `platform/cloudflared` Deployment에도 `auto` 어노테이션이 없다.
- **차트 기본값은 `watchGlobally: true`다.** values 스키마가 키 오타를 막지 않으므로(`additionalProperties: false` 없음) 두 갈래가 있다
  (2026-09-22 실측 — 픽스처 `../../tests/fixtures/rel-scoped/`):

  | 실수 | 결과 | 잡는 곳 |
  |---|---|---|
  | `watchGlobaly: false`(한 키 오타, `namespaces`는 그대로) | 차트 가드가 렌더를 `fail`로 멈춘다 — Argo는 `ComparisonError` | validate 1 KUST · 10.0 REL-render |
  | 부모 키 `reloadr:` 오타 · 들여쓰기 실수(두 키가 함께 빠짐) | 렌더 **성공** + 전역 모드(ClusterRole·ClusterRoleBinding · `--namespaces` 없음 · 감시 ns Role 없음) | validate 10.1 · 10.2 · 10.3 REL-kinds · 10.4 REL-rbac-ns · REL-rbac-rules |

  values 밖으로 감시 범위·권한을 넓히는 경로도 validate가 렌더에서 잡는다(픽스처 `../../tests/fixtures/rel-scoped/`):

  | 경로 | 잡는 곳 |
  |---|---|
  | 값 없는 플래그가 뒤 인자를 삼킴(`--log-format` 뒤의 `--namespaces=…` → 감시 목록이 비어 전역 모드) · `$(VAR)` 치환 · 여분 플래그(`--auto-reload-all=true`) · 인자 순서 | 10.2 REL-args-exact — args **목록 정확 일치**(`swallow-ns`·`swallow-strategy`·`var-expansion`·`extra-arg`·`args-order`) |
  | 이름이 다른 두 번째 Reloader · 같은 파드의 두 번째 컨테이너 · `command` 안의 `--namespaces=` · `containers[0]` 미끼 · 다른 레지스트리 이미지 | 10.4 REL-image(`second-deploy`·`second-container`·`command`·`decoy-container`·`image-registry`) |
  | 감시 목록 밖 ns의 Role·RoleBinding · 다른 주체·ClusterRole을 가리키는 RoleBinding · 한 ns만 넓힌 규칙·와일드카드 | 10.4 REL-rbac-ns · REL-rbac-bind · REL-rbac-rules(`rb-subject`·`role-wildcard`) |
  | 표 밖의 kind(K3s `HelmChart` CR 등) · 객체 수 | 10.3 REL-kinds(`extra-kind`) |
  | Application `spec.source`의 오버라이드 키(`kustomize.patches` 등) · 다른 리비전 · multi-source · `spec.sourceHydrator` · source 경로의 `.argocd-source.yaml`·`.argocd-source-<앱 이름>.yaml` · Application 최상위 `operation`(`operation.sync`의 source·revision·manifests) | 7.4 APP-source · -ref · -multi · -hydrator · -file · -operation(`../../tests/fixtures/app-source/`) — **우회 경로를 전부 덮는다고 주장하지 않는다**(전수 열거는 T047): 사각(`kind: List`로 감싼 Application 등)은 `../../tests/README.md` 「검사 7.4가 보지 않는 것」 |

  **보지 않는 것**: 다른 컴포넌트 렌더가 ServiceAccount `reloader/reloader`에 주는 RoleBinding·ClusterRoleBinding(전 렌더 교차 검사는
  T047 후보), `reloader-role` 4장을 똑같이 넓힌 규칙 · 이름이 `reloader-role`이 아닌 Role의 규칙 내용(둘 다 §1의 대조가 잡는다) —
  전체 목록은 `../../tests/README.md` 「검사 10이 보지 않는 것」.

**새 소비자 ns를 더하는 순서**(한 줄씩, 세 곳):

1. 계약 `gitops-repo.md` §네임스페이스 `platform/reloader/` 항목의 목록(모노레포 PR — 계약이 먼저다).
2. 이 디렉터리 `kustomization.yaml`의 `reloader.namespaces`.
3. `tests/validate.sh`의 `REL_WATCH_NS`와 `REL_KINDS`(Role·RoleBinding 각 +1) — 기대 args의 `--namespaces=` 목록은 거기서 사전순으로
   유도된다. 함께: 긍정 픽스처 `tests/fixtures/positive/platform/reloader/`의 `deployment.yaml` `--namespaces` 인자(사전순)와 `rbac.yaml`
   `reloader-role`·`reloader-role-binding` 한 쌍, 그 사본(`tests/fixtures/rel-scoped/*/platform/reloader/`의 `deployment.yaml`·`rbac.yaml` —
   `cp`로 다시 복사한다), 결함 패치 안에 ns 목록을 글자로 적은 픽스처(`rel-scoped/{args-order,decoy-container}`의 `kustomization.yaml`),
   차트 values를 담은 `tests/fixtures/rel-scoped/{typo-key,typo-parent,cloudflared,env-vars}/`의 `namespaces`, `tests/validate.tests.sh`의
   단언 문자열(ns 목록·개수가 박힌 것). 2·3은 한 PR이다 — 한쪽만 고치면 10.2·10.3·10.4가 FAIL한다.

그 ns가 이미 네임스페이스 표(14개)에 있어야 한다. Reloader는 kube-api(6443)만 쓰므로 NetworkPolicy 행은 늘지 않는다(설계 F11).

---

## 1. 렌더 체크리스트

PR 본문에 아래 출력을 붙인다(2026-09-22 실측, kind·규칙·주체 줄은 2026-09-28 추가 실측, 장 수·kind 개수·securityContext 줄은 2026-09-28
G2 렌더로 다시 실측 — kustomize v5.8.1 · helm v4.3.0 · yq v4.53.6).

```bash
kustomize build --enable-helm platform/reloader > "${TMPDIR:-/tmp}/rel.yaml"
R="${TMPDIR:-/tmp}/rel.yaml"
yq -N '.kind' "$R" | wc -l                                                            # 12 (아래 표)
yq -N '.kind' "$R" | sort | uniq -c                                                   # 1 Deployment · 5 Role · 5 RoleBinding · 1 ServiceAccount(그 밖의 kind 0)
yq -N 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name' "$R" | wc -l   # 0
yq -N 'select(.kind == "Role" or .kind == "RoleBinding") | .kind + " " + .metadata.namespace' "$R" | sort | uniq -c
#   Role·RoleBinding 각각 identity 1 · jt-dev 1 · jt-prod 1 · reloader 2  (cloudflared 0)
yq -N 'select(.kind == "Deployment" and .metadata.name == "reloader") | .spec.template.spec.containers[0].args[]' "$R"
#   --log-level=info
#   --namespaces=identity,jt-dev,jt-prod,reloader
#   --reload-strategy=annotations          (이 3줄이 **순서까지 정확히** 같아야 한다 — 여분·누락·순서 차이는 validate 10.2 FAIL.
#                                           ns 목록은 차트 헬퍼가 `uniq | sortAlpha`로 정렬해 만든다)
grep -c 'ghcr.io/stakater/reloader:v1.4.21@sha256:b253579350a835082cdad8d8736671cedaa0f8309437c894bd1bf1c2f0e0d45e' "$R"   # 1
yq -N 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name + " pod=" + (.spec.template.spec.securityContext | to_json(0)) + " ctr=" + (.spec.template.spec.containers[0].securityContext | to_json(0))' "$R"
#   reloader/reloader pod={"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}} ctr={"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}
yq -N 'select(.kind == "Service" or .kind == "ServiceMonitor" or .kind == "PodMonitor" or .kind == "NetworkPolicy" or .kind == "PodDisruptionBudget" or .kind == "VerticalPodAutoscaler" or .kind == "Secret") | .kind' "$R" | wc -l   # 0
yq -N 'select(.kind == "Role" and .metadata.name == "reloader-role") | .metadata.namespace as $ns | .rules[] | $ns + " " + (.apiGroups | join(",")) + " " + (.resources | join(",")) + " " + (.verbs | join(","))' "$R"
#   20줄 = ns 4개(identity·jt-dev·jt-prod·reloader) × 아래 5줄. 예: identity의 5줄
#   identity  secrets,configmaps list,get,watch
#   identity apps deployments,daemonsets,statefulsets list,get,update,patch
#   identity batch cronjobs list,get
#   identity batch jobs create,delete,list,get
#   identity  events create,patch                  (§2 표)
yq -N 'select(.kind == "Role" and .metadata.name == "reloader-role") | .rules[] | (.apiGroups | join(",")) + " " + (.resources | join(",")) + " " + (.verbs | join(","))' "$R" | sort | uniq -c
#   5줄, 전부 4 — 4보다 작은 줄이나 여분 줄이 있으면 한 ns의 규칙만 다르다(validate 10.4 REL-rbac-rules와 같은 대조)
yq -N 'select(.kind == "Role") | .rules[] | (.apiGroups + .resources + .verbs)[] | select(contains("*"))' "$R" | wc -l   # 0 (와일드카드 없음)
yq -N 'select(.kind == "RoleBinding") | .metadata.namespace + " " + .roleRef.kind + "/" + .roleRef.name + " " + (.subjects | to_json(0))' "$R"
#   identity Role/reloader-role [{"kind":"ServiceAccount","name":"reloader","namespace":"reloader"}]
#   jt-dev Role/reloader-role [{"kind":"ServiceAccount","name":"reloader","namespace":"reloader"}]
#   jt-prod Role/reloader-role [{"kind":"ServiceAccount","name":"reloader","namespace":"reloader"}]
#   reloader Role/reloader-metadata-role [{"kind":"ServiceAccount","name":"reloader","namespace":"reloader"}]
#   reloader Role/reloader-role [{"kind":"ServiceAccount","name":"reloader","namespace":"reloader"}]
kubeconform -strict -ignore-missing-schemas -summary "$R"                            # Invalid 0
bash tests/validate.sh                                                                # 7.4 APP-source · 10 REL PASS 포함 FAIL 0
```

**실측 객체(합계 12 — 2026-09-28 G2 렌더)**:

| kind | 장 | 내역 |
|---|---|---|
| Role | 5 | `reloader-role` × 4(`identity`·`jt-dev`·`jt-prod`·`reloader`) + `reloader-metadata-role`(`reloader` — 자기 ns의 configmaps create/update) |
| RoleBinding | 5 | 위와 같은 짝(`reloader-role-binding` × 4 + `reloader-metadata-role-binding`) |
| Deployment | 1 | `reloader/reloader`(차트) |
| ServiceAccount | 1 | `reloader/reloader` |
| **ClusterRole · ClusterRoleBinding** | **0** | scoped 모드의 증거. 1장이라도 보이면 전역 모드로 돌아간 것이다(§0 표) |

- 이미지는 **태그에 digest를 병기**한다(`image.tag: "v1.4.21@sha256:…"`). 이 차트는 `image.digest`를 주면 태그를 버리고
  `repo@digest`만 렌더하므로 병기 형식이 태그를 남기는 유일한 방법이다. digest는 **멀티아치 인덱스** digest(linux/arm64 포함).
- 차트 bump PR은 `version` · `version:` 줄 주석의 tgz sha256(대조용 기록) · `image.tag`를 함께 바꾸고 위 명령 출력을 붙인다.
  캐시(`charts/<name>-<version>/`)의 성질은 `../external-secrets/README.md` §2 단계 5와 같다.

---

## 2. 권한과 잔여 위험 (설계 D3 — 수치 대신 사실)

**Reloader SA가 감시 ns마다 갖는 것**(차트 `_helpers.tpl`의 `reloader-namespaced-rules` — §1의 `.rules[]` 줄로 렌더에서 확인):

| apiGroup | 리소스 | 동사 |
|---|---|---|
| `""` | secrets · configmaps | get · list · watch |
| `apps` | deployments · daemonsets · statefulsets | get · list · update · patch |
| `batch` | cronjobs | get · list |
| `batch` | jobs | **create · delete** · get · list |
| `""` | events | create · patch |

- **감시 ns의 Secret을 전부 읽는다.** `identity`·`jt-dev`·`jt-prod`의 앱 DB·Kafka·Authentik 자격이 전부 포함된다.
  Reloader 파드(또는 그 SA 토큰)가 탈취되면 세 ns의 비밀이 전부 노출된다.
- **`patch deployments`만으로도 그 ns에서 임의 코드를 실행할 수 있다**(이미지·명령 교체). 그래서 Job `create`·`delete`는
  위험 수준을 올리지 않는다고 보고 **차트 기본값을 유지한다**(수기 RBAC로 깎지 않는다 — jobs·cronjobs 규칙은 values와 무관하게
  항상 렌더된다).
- 전역 모드였다면 같은 권한이 **클러스터 전체**(ClusterRole)였다 — scoped 모드가 줄이는 것은 이 범위다. `cloudflared`·`vault`·
  `external-secrets`·`argocd`·`data` 등 나머지 ns의 Secret은 읽지 못한다.
- 잔여 위험을 줄이는 수단은 이 디렉터리에 없다: 파드는 노드 A(`role: platform`)에서 restricted 보안 설정으로 돌고, 네트워크는
  `allow-kube-api`(6443)만 열려 있다(`platform/policies/`). metrics 포트 9090은 수집 행이 없어 막혀 있다(설계 F11).

---

## 3. VD-9 판정 기록 (설계 §3)

**무엇을 재나**: 실제 소비자와 같은 구조 — **Argo가 관리하는 Deployment + Argo 밖에서 값이 바뀌는 Secret** — 에서
① Secret 변경 1회 → 롤아웃 **정확히 1회**, ② Reloader가 파드 템플릿에 넣은 어노테이션을 Argo(selfHeal · Server-Side Diff)가
되돌리지 않고 `platform-reloader`가 **Synced로 남는가**. 시험 대상은 일시 Deployment `jt-dev/vd9-probe`(이미지 `pause` · 어노테이션
`auto` · `envFrom.secretRef: vd9-probe`)였다 — G1(PR #31)이 넣었고 G2가 Git에서 지웠다(§4). 측정 절차(단계 0–3 명령 · 판정 ⑥ 명령)는
G1의 이 README §3에 있다.

**판정(6항목 전부 만족해야 PASS)**:

| # | 판정 | 보는 곳(G1 README §3의 블록) |
|---|---|---|
| ① | 머지 뒤 기준: `vd9-probe` revision `1` · Available · 파드 템플릿에 `last-reloaded-from` 없음 · `platform-reloader` Synced/Healthy(`.status.sync.revision` = 머지 커밋) | 단계 1 |
| ② | 운영자가 Secret 값을 **한 번** 바꿨다(`djE=` → `djI=`) | 단계 2 |
| ③ | **롤아웃 정확히 1회**: revision `1 → 2`, 이후 5분 동안 `3` 없음 · ReplicaSet 2개(옛 것 `replicas=0`) | 단계 3 관찰 줄 · `get rs` |
| ④ | **Argo Synced 유지**: 5분 동안 `platform-reloader`의 **sync는 매 표본 `Synced`**. health는 롤아웃 직후 표본에서만 `Progressing`을 허용하고(Reloader가 일으킨 롤아웃 자체가 Deployment를 잠시 Progressing으로 만든다 — Argo CD v3.5.2 `gitops-engine/pkg/health/health_deployment.go`) 이후 `Healthy`로 돌아와 유지. **selfHeal 판정 = `opStart = baseOpStart`**(관찰 중 새 operation 0건). `histMax = baseHistMax`는 "전체 동기화가 끼어들지 않았다"는 보조 확인일 뿐이다 | 단계 3 |
| ⑤ | 파드 템플릿 어노테이션 `reloader.stakater.com/last-reloaded-from` **존재**(annotations 전략 동작 증거) · Reloader 로그에 `vd9-probe` 재적재 줄 1개 | 단계 3 |
| ⑥ | Application `status.resources` kind 개수 — **측정 시점(시험 대상 포함)의 기대는** Role 5 · RoleBinding 5 · Deployment 2 · ServiceAccount 1 · **ClusterRole·ClusterRoleBinding 0**(합계 13 — 조회 실패·빈 목록은 FAIL)**이었다**. 시험 대상 제거 뒤 상시 기대는 Deployment 1 · 합계 12(§1 표) · Reloader 시작 로그: `msg="Watching scoped namespaces: identity, jt-dev, jt-prod, reloader"`로 **끝나는** 줄 1개 · `Starting Controller to watch resource type: … in namespace: …` 8줄 = configmaps·secrets × ns 4 정확히 · 전역 모드 경고 `… will detect changes in all namespaces` 0줄 — 전 항목 OK | 판정 ⑥ 명령 |

- **④ selfHeal은 `status.history`에 남지 않는다**(Argo CD v3.5.2 소스): selfHeal은 OutOfSync 리소스만 `operation.sync.resources`에 담는
  **부분 동기화**이고(`controller/appcontroller.go` 2412–2421행), `status.history`는 리소스를 지정하지 않은 동기화가 성공했을 때만 기록된다
  (`controller/sync.go` 408행). 모든 operation은 `status.operationState.startedAt`을 새로 쓰므로 **이 값이 그대로면 operation이 없었다**.
  값이 바뀌었으면 `status.operationState.operation.sync.autoHealAttemptsCount`로 종류를 가린다 — 기준보다 크면 selfHeal(= Argo가 Reloader의
  어노테이션을 되돌렸다), 아니면 다른 동기화(새 커밋의 자동 동기화 · `initiatedBy.automated`가 빈 값이면 사람의 수동 동기화)다. 새 리비전의
  자동 동기화는 새 Operation이라 count가 빈 값(= 0)으로 시작하고(`controller/appcontroller.go` 2367–2378행), operation이 두 번 이상 있었으면
  마지막 operationState만 남아 앞의 selfHeal이 가려질 수 있다.
- **JSON 키는 `autoHealAttemptsCount`다** — `pkg/apis/application/v1alpha1/types.go` 1442행의 JSON 태그(Go 필드는 `SelfHealAttemptsCount`).
  jsonpath에 `selfHealAttemptsCount`를 쓰면 없는 키라 **빈 출력 + exit 0**(가짜 `0`)이 된다. `autoHealAttemptsCount`·`initiatedBy.automated`는
  `omitempty`라 빈 값이 `0`·`false`다.
- **⑥의 로그 문구와 출처**(v1.4.21 소스 그대로): `internal/pkg/cmd/reloader.go` 144행
  `logrus.Infof("Watching scoped namespaces: %s", strings.Join(watchNamespaces, ", "))`(ns 순서 = `--namespaces` 인자 순서이고, 그 인자는
  차트 헬퍼가 `uniq | sortAlpha`로 **사전순 정렬**해 만든다 — 그래서 기대 문구의 ns가 사전순이다) ·
  219행 `logrus.Infof("Starting Controller to watch resource type: %s in namespace: %s", k, currentNamespace)`(`configmaps`·`secrets`만 —
  `namespaces`는 namespace-selector가 없어 건너뛰고 `secretproviderclasspodstatuses`는 CSI 연동이 꺼져 건너뛴다) · 131행 전역 모드 경고
  `KUBERNETES_NAMESPACE is unset, will detect changes in all namespaces.`. 차트가 `--log-format`을 주지 않으므로 logrus 기본 텍스트 형식이고
  문구는 `msg="…"` 안에 찍힌다(추가 필드가 없어 `msg="…"`가 줄 끝이다 — 닫는 따옴표와 줄 끝까지 맞춰야 하는 이유: pflag가 목록을
  합치면 `…, reloader, cloudflared"`처럼 **뒤에** ns가 붙는데, 부분 문자열 일치는 그 줄도 센다). 실제 로그 줄은 아래 판정 기록에 옮긴다.
  ⑤의 재적재 줄도 실측한 형식 그대로 아래에 옮겼다.
- **`platform-reloader`에 고아(orphaned) 경고가 붙을 수 있다 — 정상이다.** Reloader가 런타임에 자기 ns에 ConfigMap
  `reloader-meta-info`(v1.4.21 `pkg/common/metainfo.go` 24행 `MetaInfoConfigmapName`)를 만들고, AppProject `platform`이
  `orphanedResources.warn: true`라 destination ns(`reloader`)의 선언에 없는 이 객체를 `OrphanedResourceWarning`으로 드러낸다. sync·health에는
  영향이 없고(2026-09-28 실측 — 아래 기록) 지우지 않는다 — Reloader가 **기동할 때마다** 만들거나 갱신하는 객체다(`internal/pkg/cmd/reloader.go` 233행 →
  `pkg/common/common.go` 103행 `PublishMetaInfoConfigmap`). 되돌릴 때만 §5에서 지운다.
- **실패 시**(설계 §3): ③에서 revision이 3 이상이면 Argo와 충돌한 것이다 → `reloadStrategy: env-vars`로 바꿔 재측정하거나
  `ignoreDifferences`를 검토한다(**결정은 사용자**). ⑥에서 감시가 안 되면 과제의 **옵션 B**(`watchGlobally: true` + `namespaceSelector` —
  ClusterRole이 남는 트레이드오프)로 전환하고 모노레포 `report.md`에 기록한다. 어느 쪽이든 계약·validate 10을 함께 고친다.
- 상시 라이브 가드는 모노레포 하네스 `reloader-2`(Application `status.resources`의 ClusterRole·ClusterRoleBinding 0과 Role `reloader-role` ns 집합 ·
  Deployment 인자 — 계약 §validate.yml 4 「(T046)」 첫째 줄과 같은 규칙)다. `reloader-2`는 kind별 개수와 **로그를 보지 않는다** — 개수와
  시작 로그(실제로 감시하는 ns)는 VD-9 판정 ⑥에서 한 번 실측했다(아래 기록). 다시 보려면 G1 README §3의 판정 ⑥ 명령을 기대 개수
  Deployment 1 · 합계 12로 바꿔 쓴다.

**판정 기록**:

**2026-09-28 실측 — 판정 PASS**(①–⑥ 실질 전부 충족 · 관찰 창 기준 한 줄은 아래 「관찰 창」대로 · 사용자 확정). 대상은 main `f5a2d86`(PR #31)이고
시각은 UTC다. 실측값 전체(표본 줄 · 기준값)는 모노레포 런북 `docs/runbooks/bootstrap.md` §3 T046 절에 있다.

| # | 실측 |
|---|---|
| ① | 머지 08:34:44 → Argo 반영 08:42:58(자동 동기화 · history id 0). 08:43:44 기준: `Synced/Healthy/f5a2d86…` · revision `1` · Available · `last-reloaded-from` 없음 |
| ② | t0 = 09:11:41 · `probe=djI=` |
| ③ | revision `1 → 2` **한 번**(t0 + 6초 표본에서 이미 `2`) · 이후 `3` 없음 · ReplicaSet 2개(옛 것 `replicas=0`) · ns 이벤트도 scale up 1 · scale down 1 · `Reloaded` 1 |
| ④ | sync는 전 표본 `Synced` · `opStart`가 기준 그대로(관찰 중 operation 0건 · `autoHealAttemptsCount` 1 = 기준 1) · `histMax` 0 = 기준. **Argo는 변경 뒤에 실제로 다시 비교했다**: `status.reconciledAt` 09:18:18(> t0)에서 `Synced`. Deployment의 필드 관리자 기록은 `argocd-controller`(Apply 08:42:59) → `Reloader`(Update 09:11:41) → kube-controller-manager(09:11:42) 순서이고 Reloader 뒤에 Argo의 적용이 없다 |
| ⑤ | 어노테이션 있음 — 값은 JSON 한 줄 `{"type":"SECRET","name":"vd9-probe","namespace":"jt-dev","hash":"<Secret 데이터의 SHA-1>","containerRefs":["pause"],"observedAt":<유닉스 초>}` · 재적재 로그 1줄(아래) |
| ⑥ | Role 5 · RoleBinding 5 · Deployment 2 · ServiceAccount 1 · ClusterRole 0 · ClusterRoleBinding 0(합계 13) · scoped 줄 1 · 전역 모드 경고 0 · 컨트롤러 8줄 = configmaps·secrets × `identity`·`jt-dev`·`jt-prod`·`reloader` 정확히 |

- **실제 로그 줄**(v1.4.21 · logrus 텍스트 형식 — 시각만 바꿔 옮겼다):

  ```text
  time="…" level=info msg="Starting Reloader"
  time="…" level=info msg="Watching scoped namespaces: identity, jt-dev, jt-prod, reloader"
  time="…" level=info msg="created controller for: secrets"
  time="…" level=info msg="Starting Controller to watch resource type: secrets in namespace: jt-dev"
  time="…" level=info msg="Skipping secretproviderclasspodstatuses controller: EnableCSIIntegration is disabled"
  time="…" level=info msg="Changes detected in 'vd9-probe' of type 'SECRET' in namespace 'jt-dev'; updated 'vd9-probe' of type 'Deployment' in namespace 'jt-dev'"
  ```

  같은 문구가 Deployment의 이벤트(reason `Reloaded`)로도 남는다. 시작 로그는 컨트롤러 8줄을 포함해 24줄이었다.
- **health `Progressing`은 한 번도 잡히지 않았다.** 롤아웃이 1초 안에 끝났다(새 파드 시작 09:11:41 · Application health 전환 시각
  09:11:42) — 10초 간격 표본으로는 보이지 않는 길이다. ④의 "롤아웃 직후 `Progressing` 허용"은 이미지를 새로 받는 워크로드를 위한 여유다.
- **기준의 `autoHealAttemptsCount`가 1이었다 — Reloader와 무관하다.** 첫 전체 동기화(08:42:58) 1초 뒤 Argo가 Deployment 두 장
  (`reloader`·`vd9-probe`)만 대상으로 selfHeal 부분 동기화를 한 번 했다(08:42:59 · `operation.sync.resources` 2항목). 생성 직후의 일이고
  Secret을 바꾸기 28분 전이며, 그 뒤 새 operation은 없었다. 그래서 판정은 count의 절대값이 아니라 **기준과의 비교**로 한다.
- **고아 경고는 예상대로 붙었다**: `OrphanedResourceWarning — Application has 1 orphaned resources`(`reloader-meta-info`). sync·health는
  `Synced/Healthy` 그대로다.
- **관찰 창**: 절차(G1 README §3 단계 3)의 표본은 6개 · 첫 표본 t0 + 108초 · 마지막 t0 + 296초라 `표본` 줄이 **FAIL**이었다(단계 3을
  늦게 시작했다 — 기준은 첫 표본 60초 이내). 그 빈 구간은 읽기 전용 계정으로 따로 돌린 보조 관찰(10초 간격 · t0 − 34초부터 t0 + 341초까지
  38표본 · 조회 실패 0)이 덮었고 결과는 위 표와 같다. 절차의 문면("전부 OK여야 PASS")으로는 운영자 실행 **단독**은 PASS가 아니다 —
  두 관찰을 합쳐 PASS로 확정했다(사용자 결정). 표본 간격은 실측 약 37초였다(30초 대기 + 터널 너머 조회 3회) — 5분 창에 8개가 상한이다.

**시험 대상 삭제(운영자 · 쓰기 2 — Deployment 먼저)**: G2 머지 뒤에도 `platform-reloader`는 `prune: false`라 `vd9-probe`를 지우지 않는다 —
Git에서 사라진 객체로 남아 Application이 OutOfSync(prune 필요)로 보인다. 운영자가 admin kubeconfig로 지운다(`agent-view`에는 쓰기가 없다).
실행 결과(시각 · 출력)는 모노레포 런북 §3 T046 절에 적는다(삭제는 이 PR의 머지 **뒤**에 하므로 여기에 적으려면 PR이 하나 더 필요하다).

```powershell
kubectl -n jt-dev delete deployment vd9-probe
kubectl -n jt-dev delete secret vd9-probe
kubectl -n argocd get application platform-reloader -o 'jsonpath={.status.sync.status}/{.status.health.status}'   # Synced/Healthy
```

---

## 4. 뒷정리 (VD-9 판정 뒤 — 끝난 일)

- **제거 PR(G2)**: 시험 대상을 Git에서 지웠다 — 시험 대상 디렉터리와 `kustomization.yaml`의 `resources` 항목 · validate 10.3의 시험 대상
  검사와 상수 · 픽스처 사본과 그 부정 픽스처 · 자기검사 단언 문자열 · 이 README와 `tests/README.md`의 언급. 상시 기대 렌더는
  12장(Deployment 1 — §1 표)이다.
- 클러스터에 남은 시험 대상(Deployment·Secret)은 `prune: false`라 운영자가 지운다 — 명령과 실행 기록은 §3 끝.
- 모노레포(별도 저장소)의 하네스 `reloader-2`·런북에 시험 대상 개수가 있으면 그쪽에서 같은 시점에 고친다.

---

## 5. 되돌리기

- **revert PR** → 렌더가 `resources: []` 뼈대로 돌아간다. `prune: false`라 객체는 남는다 → 운영자가 지운다:
  Deployment `reloader/reloader` · ServiceAccount `reloader/reloader` · Role/RoleBinding `reloader-role(-binding)` 4 ns
  (`identity`·`jt-dev`·`jt-prod`·`reloader`) + `reloader-metadata-role(-binding)`(`reloader`).
  Reloader가 기동할 때 만든 ConfigMap도 지운다(Git에 없는 객체다 — 이름은 v1.4.21 `pkg/common/metainfo.go` 24행 `MetaInfoConfigmapName`,
  Deployment를 먼저 지운 뒤에 지워야 다시 생기지 않는다):

  ```powershell
  kubectl -n reloader delete configmap reloader-meta-info
  ```
- **Reloader가 없어도 소비자 파드는 멈추지 않는다** — Secret이 바뀌어도 재시작이 일어나지 않을 뿐이다(T046 이전과 같은 상태).
  소비자 Deployment의 `auto` 어노테이션과 파드 템플릿의 `last-reloaded-from` 어노테이션은 남아도 무해하다.
- scoped → 전역(옵션 B) 전환은 되돌리기가 아니라 **계약 변경**이다(§3 실패 시).

---

## 6. 인계

- **어노테이션을 다는 태스크**: T072(Django 파드 템플릿 — `jt-dev`·`jt-prod`) · T080(authentik — `identity`) · T082(openfga — `identity`)가
  각자의 Deployment에 `reloader.stakater.com/auto: "true"`를 단다. 감시 ns 밖(예: `data`)의 워크로드에 달면 **아무 일도 일어나지
  않는다** — §0의 순서로 ns부터 늘린다.
- **모니터링 행 없음**: 네트워크 정책 매트릭스에 Reloader metrics(9090) 수집 행이 없으므로 Service·ServiceMonitor·PodMonitor를 켜지
  않았다. T098(Alloy)이 수집하려면 계약 `network-policy.md`에 행을 먼저 더한다.
- **VD-9 결과**: 판정표(§3)의 실측값은 모노레포 런북·학습 로그에 기록하고, 이 README에는 로그 문구(⑤⑥)만 옮긴다.
