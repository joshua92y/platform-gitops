# platform/reloader/ — 운영자 절차 (T046 G1)

Stakater Reloader 차트 **2.2.16**(appVersion v1.4.21)을 **scoped 모드**로 둔다 — 감시 ns의 Secret·ConfigMap이 바뀌면
어노테이션 `reloader.stakater.com/auto: "true"`를 단 Deployment를 롤링 재시작한다. 설치 방식은
`platform/external-secrets/`·`platform/vault/`·`platform/cert-manager/`와 같은 kustomize `helmCharts` 인플레이트다.
정본 계약은 모노레포 `specs/003-platform-foundation/contracts/gitops-repo.md` §네임스페이스의 `platform/reloader/` 항목,
설계는 `specs/003-platform-foundation/design/t046-design.md`다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `helmCharts` 한 항목(HTTPS helm repo 인플레이트) + `valuesInline` 전량 + `resources: [vd9-probe]`. 머리 주석에 scoped 모드·`cloudflared` 제외·권한 사실·변환기 금지 이유가 있다 |
| `vd9-probe/` | **일시.** VD-9 실측용 시험 Deployment `jt-dev/vd9-probe`(§3). 판정 뒤 제거 PR(G2)에서 지운다(§4) |

- **이 저장소에 비밀은 없다.** 시험 대상이 읽는 Secret `vd9-probe`도 Git에 두지 않는다 — 운영자가 머지 전에 만든다(§3 단계 0).
- 이 디렉터리에는 **최상위 `namespace:` 변환기를 두지 않는다.** 차트 객체의 ns는 `helmCharts[].namespace`가 정하며 변환기의
  영향을 받지 않는다 — 변환기를 두면 **`vd9-probe`만** 그 ns로 옮겨져(Secret `vd9-probe`가 없는 ns) 시험이 성립하지 않는다
  (kustomize 5.8.1 실측 2026-09-28 · Argo CD v3.5.2가 묶은 kustomize도 5.8.1. validate 10.3 REL-probe가 잡는다).
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
  | 표 밖의 kind(K3s `HelmChart` CR 등) · 객체 수 · 시험 대상이 다른 ns로 옮겨짐 | 10.3 REL-kinds · REL-probe(`extra-kind`·`probe-namespace`) |
  | Application 수준 오버라이드(`spec.source.kustomize.patches` 등) · 다른 리비전 · multi-source | 7.4 APP-source(`../../tests/fixtures/app-source/`) |

  **보지 않는 것**: 다른 컴포넌트 렌더가 ServiceAccount `reloader/reloader`에 주는 RoleBinding·ClusterRoleBinding(전 렌더 교차 검사는
  T047 후보 — `../../tests/README.md` 「검사 10이 보지 않는 것」).

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

PR 본문에 아래 출력을 붙인다(2026-09-22 실측, kind·규칙·주체 줄은 2026-09-28 추가 실측 — kustomize v5.8.1 · helm v4.3.0 · yq v4.53.6).

```bash
kustomize build --enable-helm platform/reloader > "${TMPDIR:-/tmp}/rel.yaml"
R="${TMPDIR:-/tmp}/rel.yaml"
yq -N '.kind' "$R" | wc -l                                                            # 13 (차트 12 + vd9-probe 1 — 아래 표)
yq -N '.kind' "$R" | sort | uniq -c                                                   # 2 Deployment · 5 Role · 5 RoleBinding · 1 ServiceAccount(그 밖의 kind 0)
yq -N 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name' "$R" | wc -l   # 0
yq -N 'select(.kind == "Role" or .kind == "RoleBinding") | .kind + " " + .metadata.namespace' "$R" | sort | uniq -c
#   Role·RoleBinding 각각 identity 1 · jt-dev 1 · jt-prod 1 · reloader 2  (cloudflared 0)
yq -N 'select(.kind == "Deployment" and .metadata.name == "reloader") | .spec.template.spec.containers[0].args[]' "$R"
#   --log-level=info
#   --namespaces=identity,jt-dev,jt-prod,reloader
#   --reload-strategy=annotations          (이 3줄이 **순서까지 정확히** 같아야 한다 — 여분·누락·순서 차이는 validate 10.2 FAIL.
#                                           ns 목록은 차트 헬퍼가 `uniq | sortAlpha`로 정렬해 만든다)
grep -c 'ghcr.io/stakater/reloader:v1.4.21@sha256:b253579350a835082cdad8d8736671cedaa0f8309437c894bd1bf1c2f0e0d45e' "$R"   # 1
grep -c 'registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a' "$R"          # 1
yq -N 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name + " pod=" + (.spec.template.spec.securityContext | to_json(0)) + " ctr=" + (.spec.template.spec.containers[0].securityContext | to_json(0))' "$R"
#   jt-dev/vd9-probe pod={"runAsNonRoot":true,"runAsUser":65535,"seccompProfile":{"type":"RuntimeDefault"}} ctr={"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}
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

**2026-09-22 실측 객체(합계 13)**:

| kind | 장 | 내역 |
|---|---|---|
| Role | 5 | `reloader-role` × 4(`identity`·`jt-dev`·`jt-prod`·`reloader`) + `reloader-metadata-role`(`reloader` — 자기 ns의 configmaps create/update) |
| RoleBinding | 5 | 위와 같은 짝(`reloader-role-binding` × 4 + `reloader-metadata-role-binding`) |
| Deployment | 2 | `reloader/reloader`(차트) + `jt-dev/vd9-probe`(일시 — §3) |
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

## 3. VD-9 실측 절차와 판정 (설계 §3)

**무엇을 재나**: 실제 소비자와 같은 구조 — **Argo가 관리하는 Deployment + Argo 밖에서 값이 바뀌는 Secret** — 에서
① Secret 변경 1회 → 롤아웃 **정확히 1회**, ② Reloader가 파드 템플릿에 넣은 어노테이션을 Argo(selfHeal · Server-Side Diff)가
되돌리지 않고 `platform-reloader`가 **Synced로 남는가**. 시험 대상은 `vd9-probe/deployment.yaml`(`jt-dev/vd9-probe`,
이미지 `pause` · 어노테이션 `auto` · `envFrom.secretRef: vd9-probe`).

**실행 주체** — 쓰기와 Secret 읽기는 운영자만 한다(`agent-view`에는 Secret get이 없다 — `../policies/rbac-agent-view.yaml`):

| 블록 | 주체 | 필요한 권한 |
|---|---|---|
| 단계 0 첫 줄 · 단계 2 첫 줄(쓰기) · §4·§5의 삭제 | 운영자(admin kubeconfig) | 쓰기 |
| 단계 0 둘째 줄 · 단계 2 마지막 줄(Secret 값 확인) | 운영자(admin kubeconfig) | Secret get |
| 단계 1 · 단계 3 · 판정 ⑥ | 운영자 또는 에이전트(`agent-view` 토큰) | 읽기만 — `applications` get·list + 기본 ClusterRole `view`(Deployment·ReplicaSet·`pods/log`) |

- **단계 1–3은 한 주체가 한 PowerShell 세션에서 돌린다.** 단계 3은 단계 1의 기준값(`$baseHistMax`·`$baseOpStart`·`$baseAuto`·`$baseHeal`)과
  단계 2의 `$t0`을 변수로 쓴다. 나눠 돌리면(예: 단계 2는 운영자, 단계 1·3은 에이전트 — 에이전트 실행은 호출마다 새 프로세스다) 단계 1·2가 찍은
  `base…=`·`t0=` 줄을 **기록해 두고**, 단계 3 첫머리의 주석 줄에 그 값을 적어 넣는다. 값이 없으면 단계 3은 throw로 멈춘다(기준 없이 판정하지 않는다).
- 명령은 **PowerShell 7.3 이상(pwsh)** 기준이다. 7.3부터 Windows의 네이티브 인자 전달(`$PSNativeCommandArgumentPassing = 'Windows'`)이 인자 안의
  큰따옴표를 보존한다 — 7.2 이하의 `Legacy` 동작과 Windows PowerShell 5.1은 `patch -p`의 JSON과 jsonpath 필터의 `"Available"`을 깨뜨린다.
- 인용 규칙: **`-o` 값, 그리고 중괄호·따옴표·`=`가 든 인자는 전체를 한 쌍의 작은따옴표로** 감싼다(`'jsonpath=…'` · `'--from-literal=…'` ·
  `'app=vd9-probe'` · `'--since=10m'` — `../secrets/README.md` §2의 같은 함정).
- 읽기 블록의 조회는 전부 블록 머리의 `kq` 함수로 한다. kubectl이 실패하면(`$LASTEXITCODE` ≠ 0 — `$ErrorActionPreference`는 네이티브 명령의
  실패를 잡지 않는다) **throw**해, 실패한 조회의 빈 출력이 기대값(`last-reloaded-from=[]` 등)처럼 보이는 일을 막는다. jsonpath 출력은 끝 개행이
  없으므로 변수에 받아 한 줄로 찍는다.
- 쓰기는 **단계 0과 단계 2의 두 줄뿐**이고 나머지 블록은 읽기만 한다. 블록을 한꺼번에 붙여 넣지 않는다 — 단계마다 사람이 결과를 보고 넘어간다.

**단계 0 — 머지 전: Secret 생성(쓰기 1)**. 더미 값이라 argv에 둬도 된다.

```powershell
kubectl -n jt-dev create secret generic vd9-probe '--from-literal=probe=v1'
$v = kubectl -n jt-dev get secret vd9-probe -o 'jsonpath={.data.probe}'; "probe=$v"      # probe=djE=  (base64 "v1")
```

이미 있으면 `AlreadyExists`다 — 값이 `djE=`인지만 확인하고 넘어간다.

**Secret 없이 머지했을 때**(라이브 미실측 — 아래는 소스·설정 대조로 정한 예상이다. 겪으면 실제로 본 순서를 이 아래에 적는다):

1. `vd9-probe` 파드가 `CreateContainerConfigError`(`secret "vd9-probe" not found`)로 멈춘다(`envFrom.secretRef`에 `optional`이 없다).
   Deployment는 Progressing이고 Argo health도 `Progressing`이다.
2. 매니페스트에 `progressDeadlineSeconds`가 없으므로 k8s 기본값 **600초** 뒤 `Progressing=False`(reason `ProgressDeadlineExceeded`)가 되고,
   Argo가 그 Deployment를 **Degraded**로 본다(Argo CD v3.5.2 `gitops-engine/pkg/health/health_deployment.go`).
3. `platform-reloader`의 health가 **Degraded**가 된다(sync는 `Synced` 그대로 — 이 Application의 리소스는 wave가 하나라 적용 즉시
   동기화가 성공으로 끝나고, 뒤이은 Degraded는 동기화 결과를 바꾸지 않는다). `bootstrap/argocd/argocd-cm.yaml`의 Application health
   Lua가 child의 `status.health`를 그대로 올리므로 **root의 health도 Degraded**가 된다.
4. 모노레포 하네스 `argo-1`(모든 Application `Synced/Healthy`)이 `platform-reloader`·`root`로 FAIL한다(600초 전에도 `Progressing`이라 FAIL이다).

- **없는 것**: 다른 워크로드 영향(파드 하나가 뜨지 못할 뿐이다)과 root 동기화 차단. `platform-reloader`는 root의 **마지막** sync-wave에
  있어(그보다 뒤 wave의 Application이 지금은 없다 — 계약 §sync-wave 단일 표) 그 health를 기다릴 뒤 wave가 없고, 마지막 wave의 리소스는
  적용되는 즉시 성공으로 처리된다(`gitops-engine/pkg/sync/sync_context.go` — "successful EVEN if those objects subsequently degrades").
  root는 `ApplyOutOfSyncOnly=true`라 이후 동기화에서 Synced인 `platform-reloader`를 다시 적용하지도 않는다.
- **복구**: 단계 0의 첫 줄로 Secret을 만든다(쓰기는 그대로 1회). kubelet이 컨테이너 생성을 다시 시도해 파드가 뜨고 Deployment가
  Available이 되면 Progressing 사유가 `NewReplicaSetAvailable`로 돌아가 `platform-reloader`·root가 Healthy로 돌아온다. Reloader는
  `reloadOnCreate: false`(차트 기본값 — 렌더에 `--reload-on-create` 인자가 없고 바이너리 기본값도 `"false"`)라 Secret **생성**
  이벤트로는 롤아웃하지 않는다(v1.4.21 `internal/pkg/controller/controller.go`의 `Add`). 그래서 revision은 `1`로 남아 판정 ①이
  그대로 유효하다 — 단계 1은 Healthy로 돌아온 뒤에 돌린다.

**단계 1 — 머지 뒤: 기준 판정(판정 ①)**. 이 세션을 단계 3까지 유지한다(`$base*` 변수를 쓴다 — 나눠 돌리면 마지막 줄을 기록한다).

```powershell
$ErrorActionPreference = 'Stop'
function kq { $o = kubectl @args; if ($LASTEXITCODE -ne 0) { throw "kubectl $args → exit $LASTEXITCODE — 판정 불가" }; (@($o) -join "`n").TrimEnd() }
$app = kq -n argocd get application platform-reloader -o 'jsonpath={.status.sync.status}/{.status.health.status}/{.status.sync.revision}'
$rev = kq -n jt-dev get deploy vd9-probe -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}'
$avl = kq -n jt-dev get deploy vd9-probe -o 'jsonpath={.status.conditions[?(@.type=="Available")].status}'
$lrf = kq -n jt-dev get deploy vd9-probe -o 'jsonpath={.spec.template.metadata.annotations.reloader\.stakater\.com/last-reloaded-from}'
"app=$app rev=$rev available=$avl last-reloaded-from=[$lrf]"   # app=Synced/Healthy/<머지 커밋 SHA> rev=1 available=True last-reloaded-from=[]
$hist = kq -n argocd get application platform-reloader -o 'jsonpath={.status.history[*].id}'
if (-not $hist) { throw 'status.history 빈 값 — 판정 불가(머지 뒤 동기화가 있었으므로 비어 있을 수 없다)' }
$baseHistMax = (@(-split $hist) | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
$op = kq -n argocd get application platform-reloader -o 'jsonpath={.status.operationState.startedAt}|{.status.operationState.operation.initiatedBy.automated}|{.status.operationState.operation.sync.autoHealAttemptsCount}'
$baseOpStart, $baseAuto, $baseHeal = $op -split '\|', 3
if (-not $baseOpStart) { throw 'operationState.startedAt 빈 값 — 판정 불가(머지 뒤 동기화가 있었으므로 비어 있을 수 없다)' }
"baseHistMax=$baseHistMax baseOpStart=$baseOpStart baseAuto=[$baseAuto] baseHeal=[$baseHeal]"   # 단계 3의 기준값
```

판정 ① PASS = `app=Synced/Healthy/<머지 커밋>` · `rev=1` · `available=True` · `last-reloaded-from=[]`. 하나라도 다르면 단계 2로 가지 않는다.
`baseAuto`·`baseHeal`은 기록용이다 — 두 필드는 `omitempty`라 빈 값이 `false`·`0`이다(머지가 일으킨 자동 동기화 뒤라면 `baseAuto=[true]`가 정상).

**단계 2 — Secret 값을 한 번 바꾼다(쓰기 1 · 운영자)**.

```powershell
kubectl -n jt-dev patch secret vd9-probe --type merge -p '{"stringData":{"probe":"v2"}}'
if ($LASTEXITCODE -ne 0) { throw 'patch 실패 — 단계 3으로 가지 않는다' }
$t0 = Get-Date
"t0=$($t0.ToString('o'))"                                                    # 단계 3의 기준 시각
$v = kubectl -n jt-dev get secret vd9-probe -o 'jsonpath={.data.probe}'; "probe=$v"      # probe=djI=  (base64 "v2")
```

**단계 3 — 5분 관찰(읽기만)**. 30초마다 한 줄. 도중에 `rev`가 3 이상이 되면 그 자리에서 멈추고 판정 ③ FAIL로 기록한다.

```powershell
$ErrorActionPreference = 'Stop'
function kq { $o = kubectl @args; if ($LASTEXITCODE -ne 0) { throw "kubectl $args → exit $LASTEXITCODE — 판정 불가" }; (@($o) -join "`n").TrimEnd() }
# 단계 1·2와 다른 세션이면 기록한 값을 아래 주석을 풀어 적는다(같은 세션이면 그대로 둔다):
# $t0 = [datetime]::Parse('<t0=의 값>', $null, 'RoundtripKind'); $baseHistMax = <n>; $baseOpStart = '<…>'; $baseAuto = '<…>'; $baseHeal = '<…>'
if ($null -eq $t0 -or $null -eq $baseHistMax -or -not $baseOpStart) { throw '기준값($t0·$baseHistMax·$baseOpStart) 없음 — 단계 1·2를 같은 세션에서 돌리거나 기록한 값을 위 줄에 적는다' }
while ((Get-Date) - $t0 -lt [TimeSpan]::FromMinutes(5)) {
  $rev = kq -n jt-dev get deploy vd9-probe -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}'
  $app = kq -n argocd get application platform-reloader -o 'jsonpath={.status.sync.status}/{.status.health.status}'
  $ops = kq -n argocd get application platform-reloader -o 'jsonpath={.status.operationState.startedAt}'
  "{0:HH:mm:ss} rev={1} app={2} opStart={3}" -f (Get-Date), $rev, $app, $ops
  if ([int]$rev -ge 3) { '판정 ③ FAIL — revision 3 이상(여기서 멈춘다)'; break }
  Start-Sleep -Seconds 30
}
kq -n jt-dev get rs -l 'app=vd9-probe' -o 'jsonpath={range .items[*]}{.metadata.name} replicas={.spec.replicas} rev={.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}'
$lrf = kq -n jt-dev get deploy vd9-probe -o 'jsonpath={.spec.template.metadata.annotations.reloader\.stakater\.com/last-reloaded-from}'
"last-reloaded-from=[$lrf]"
$hist = kq -n argocd get application platform-reloader -o 'jsonpath={.status.history[*].id}'
if (-not $hist) { throw 'status.history 빈 값 — 판정 불가' }
$histMax = (@(-split $hist) | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
$op = kq -n argocd get application platform-reloader -o 'jsonpath={.status.operationState.startedAt}|{.status.operationState.operation.initiatedBy.automated}|{.status.operationState.operation.sync.autoHealAttemptsCount}'
$opStart, $auto, $heal = $op -split '\|', 3
if (-not $opStart) { throw 'operationState.startedAt 빈 값 — 판정 불가' }
'opStart={0} (기준 {1}) {2}' -f $opStart, $baseOpStart, $(if ([string]::Equals($opStart, $baseOpStart, [StringComparison]::Ordinal)) { 'OK — 관찰 중 새 operation 없음' } else { 'FAIL — 관찰 중 새 operation(아래 두 값으로 종류를 가린다)' })
'autoHealAttemptsCount=[{0}] (기준 [{1}]) · initiatedBy.automated=[{2}] (기준 [{3}]) — 빈 값 = 0·false(omitempty)' -f $heal, $baseHeal, $auto, $baseAuto
'histMax={0} (기준 {1}) {2}' -f $histMax, $baseHistMax, $(if ($histMax -eq $baseHistMax) { 'OK — 전체 동기화가 끼어들지 않았다(보조 확인)' } else { '다름 — 전체 동기화가 끼어들었다(관찰 창 무효 · 재측정)' })
@((kq -n reloader logs deploy/reloader '--since=10m') -split "`r?`n" | Select-String -SimpleMatch 'vd9-probe')
```

**판정 ⑥ 명령(읽기만)**. 빈 출력을 PASS로 읽지 않는다 — 조회 실패는 `kq`가 멈추고, 개수와 로그 문구는 기대값과 **항목마다** OK/FAIL로
대조한다. 기대 개수는 §1 표(렌더 13장)와 같다.

```powershell
$ErrorActionPreference = 'Stop'
function kq { $o = kubectl @args; if ($LASTEXITCODE -ne 0) { throw "kubectl $args → exit $LASTEXITCODE — 판정 불가" }; (@($o) -join "`n").TrimEnd() }
function okf([bool]$c) { if ($c) { 'OK' } else { 'FAIL' } }
$kinds = @((kq -n argocd get application platform-reloader -o 'jsonpath={range .status.resources[*]}{.kind}{"\n"}{end}') -split "`r?`n" | Where-Object { $_ -ne '' })
$want = [ordered]@{ Role = 5; RoleBinding = 5; Deployment = 2; ServiceAccount = 1; ClusterRole = 0; ClusterRoleBinding = 0 }
foreach ($k in $want.Keys) {
  $n = @($kinds | Where-Object { [string]::Equals($_, $k, [StringComparison]::Ordinal) }).Count
  '{0} = {1} (기대 {2}) {3}' -f $k, $n, $want[$k], (okf ($n -eq $want[$k]))
}
'합계 = {0} (기대 13 — 표 밖의 kind가 있거나 빠지면 FAIL) {1}' -f $kinds.Count, (okf ($kinds.Count -eq 13))
$log = @((kq -n reloader logs deploy/reloader) -split "`r?`n")
# logrus 텍스트 형식은 msg="…"가 줄 끝이다(추가 필드 없음) — 닫는 따옴표와 줄 끝($)까지 맞춰, 목록 뒤에 ns가 더 붙은 줄을 세지 않는다.
$scoped = @($log | Select-String -CaseSensitive -Pattern 'msg="Watching scoped namespaces: identity, jt-dev, jt-prod, reloader"$').Count
$allNs = @($log | Select-String -CaseSensitive -SimpleMatch 'will detect changes in all namespaces').Count
$ctrl = [string[]]@($log | Select-String -CaseSensitive -Pattern 'msg="Starting Controller to watch resource type: (configmaps|secrets) in namespace: ([a-z0-9-]+)"$' | ForEach-Object { $_.Matches[0].Groups[1].Value + '/' + $_.Matches[0].Groups[2].Value })
$wantCtrl = [string[]]@(foreach ($t in 'configmaps', 'secrets') { foreach ($n in 'identity', 'jt-dev', 'jt-prod', 'reloader') { "$t/$n" } })
[Array]::Sort($ctrl, [StringComparer]::Ordinal); [Array]::Sort($wantCtrl, [StringComparer]::Ordinal)
'scoped = {0} (기대 1) {1}' -f $scoped, (okf ($scoped -eq 1))
'all-ns = {0} (기대 0) {1}' -f $allNs, (okf ($allNs -eq 0))
'controller = {0}개 [{1}] (기대 8 = configmaps·secrets × identity·jt-dev·jt-prod·reloader) {2}' -f $ctrl.Count, ($ctrl -join ' '), (okf ([string]::Equals(($ctrl -join ' '), ($wantCtrl -join ' '), [StringComparison]::Ordinal)))
```

**판정(6항목 전부 만족해야 PASS)**:

| # | 판정 | 보는 곳 |
|---|---|---|
| ① | 머지 뒤 기준: `vd9-probe` revision `1` · Available · 파드 템플릿에 `last-reloaded-from` 없음 · `platform-reloader` Synced/Healthy(`.status.sync.revision` = 머지 커밋) | 단계 1 |
| ② | 운영자가 Secret 값을 **한 번** 바꿨다(`djE=` → `djI=`) | 단계 2 |
| ③ | **롤아웃 정확히 1회**: revision `1 → 2`, 이후 5분 동안 `3` 없음 · ReplicaSet 2개(옛 것 `replicas=0`) | 단계 3 관찰 줄 · `get rs` |
| ④ | **Argo Synced 유지**: 5분 동안 `platform-reloader`의 **sync는 매 표본 `Synced`**. health는 롤아웃 직후 표본에서만 `Progressing`을 허용하고(Reloader가 일으킨 롤아웃 자체가 Deployment를 잠시 Progressing으로 만든다 — Argo CD v3.5.2 `gitops-engine/pkg/health/health_deployment.go`) 이후 `Healthy`로 돌아와 유지. **selfHeal 판정 = `opStart = baseOpStart`**(관찰 중 새 operation 0건). `histMax = baseHistMax`는 "전체 동기화가 끼어들지 않았다"는 보조 확인일 뿐이다 | 단계 3 |
| ⑤ | 파드 템플릿 어노테이션 `reloader.stakater.com/last-reloaded-from` **존재**(annotations 전략 동작 증거) · Reloader 로그에 `vd9-probe` 재적재 줄 1개 | 단계 3 |
| ⑥ | Application `status.resources` kind 개수 = Role 5 · RoleBinding 5 · Deployment 2 · ServiceAccount 1 · **ClusterRole·ClusterRoleBinding 0**(합계 13 — 조회 실패·빈 목록은 FAIL) · Reloader 시작 로그: `msg="Watching scoped namespaces: identity, jt-dev, jt-prod, reloader"`로 **끝나는** 줄 1개 · `Starting Controller to watch resource type: … in namespace: …` 8줄 = configmaps·secrets × ns 4 정확히 · 전역 모드 경고 `… will detect changes in all namespaces` 0줄 — 전 항목 OK | 판정 ⑥ 명령 |

- ④의 selfHeal 근거(Argo CD v3.5.2 소스): selfHeal은 OutOfSync 리소스만 `operation.sync.resources`에 담는 **부분 동기화**이고
  (`controller/appcontroller.go` 2412–2421행), `status.history`는 리소스를 지정하지 않은 동기화가 성공했을 때만 기록된다(`controller/sync.go`
  408행) — 그래서 history로는 selfHeal을 볼 수 없다. 모든 operation은 `status.operationState.startedAt`을 새로 쓰므로 이 값이 기준과 같으면
  관찰 중 operation이 없었다. 값이 바뀌었으면 `status.operationState.operation.sync.autoHealAttemptsCount`가 기준보다 커졌는지로 가린다 —
  커졌으면 **selfHeal**(= Argo가 Reloader의 어노테이션을 되돌렸다 → ④ FAIL), 그대로면 다른 동기화(새 커밋의 자동 동기화 ·
  `initiatedBy.automated`가 빈 값이면 사람의 수동 동기화)가 끼어든 것이라 관찰 창이 무효다(재측정). 필드 이름은
  `pkg/apis/application/v1alpha1/types.go` 1442행의 JSON 태그 `autoHealAttemptsCount`(Go 필드는 `SelfHealAttemptsCount`)다 —
  jsonpath에 `selfHealAttemptsCount`를 쓰면 없는 키라 **빈 출력 + exit 0**(가짜 `0`)이 된다.
- ④의 health 허용 폭: 롤링 업데이트(replicas 1)는 `UpdatedReplicas < Replicas` 또는 `AvailableReplicas < UpdatedReplicas`인 동안
  `Progressing`을 반드시 지나고, Application health는 관리 리소스 중 가장 나쁜 값이다. 지속 시간은 라이브 미실측이다 — **첫 실측 때 실제로 본
  관찰 줄을 이 표 아래에 옮긴다.**
- ⑥의 로그 문구는 v1.4.21 소스에서 그대로 옮겼다: `internal/pkg/cmd/reloader.go` 144행
  `logrus.Infof("Watching scoped namespaces: %s", strings.Join(watchNamespaces, ", "))`(ns 순서 = `--namespaces` 인자 순서이고, 그 인자는
  차트 헬퍼가 `uniq | sortAlpha`로 **사전순 정렬**해 만든다 — 그래서 기대 문구의 ns가 사전순이다) ·
  219행 `logrus.Infof("Starting Controller to watch resource type: %s in namespace: %s", k, currentNamespace)`(`configmaps`·`secrets`만 —
  `namespaces`는 namespace-selector가 없어 건너뛰고 `secretproviderclasspodstatuses`는 CSI 연동이 꺼져 건너뛴다) · 131행 전역 모드 경고
  `KUBERNETES_NAMESPACE is unset, will detect changes in all namespaces.`. 차트가 `--log-format`을 주지 않으므로 logrus 기본 텍스트 형식이고
  문구는 `msg="…"` 안에 찍힌다(추가 필드가 없어 `msg="…"`가 줄 끝이다 — ⑥ 명령이 닫는 따옴표와 줄 끝까지 맞추는 이유: pflag가 목록을
  합치면 `…, reloader, cloudflared"`처럼 **뒤에** ns가 붙는데, 부분 문자열 일치는 그 줄도 센다). **첫 실행 때 실제 로그로 확인해** 해당 줄을
  이 표 아래에 그대로 옮겨 적는다. ⑤의 재적재 줄은 형식을 아직 실측하지 않았다(추측으로 채우지 않는다).
- **머지 뒤 `platform-reloader`에 고아(orphaned) 경고가 붙을 수 있다 — 정상이다.** Reloader가 런타임에 자기 ns에 ConfigMap
  `reloader-meta-info`(v1.4.21 `pkg/common/metainfo.go` 24행 `MetaInfoConfigmapName`)를 만들고, AppProject `platform`이
  `orphanedResources.warn: true`라 destination ns(`reloader`)의 선언에 없는 이 객체를 `OrphanedResourceWarning`으로 드러낸다. sync·health에는
  영향이 없고(라이브 미실측) 지우지 않는다 — Reloader가 **기동할 때마다** 만들거나 갱신하는 객체다(`internal/pkg/cmd/reloader.go` 233행 →
  `pkg/common/common.go` 103행 `PublishMetaInfoConfigmap`). 되돌릴 때만 §5에서 지운다.
- **실패 시**(설계 §3): ③에서 revision이 3 이상이면 Argo와 충돌한 것이다 → `reloadStrategy: env-vars`로 바꿔 재측정하거나
  `ignoreDifferences`를 검토한다(**결정은 사용자**). ⑥에서 감시가 안 되면 과제의 **옵션 B**(`watchGlobally: true` + `namespaceSelector` —
  ClusterRole이 남는 트레이드오프)로 전환하고 모노레포 `report.md`에 기록한다. 어느 쪽이든 계약·validate 10을 함께 고친다.
- 라이브 자동 가드는 모노레포 하네스 `reloader-2`(Application `status.resources`의 ClusterRole·ClusterRoleBinding 0 · Deployment 인자 —
  계약 §validate.yml 4 「(T046)」 첫째 줄과 같은 규칙)다. `reloader-2`는 **로그를 읽지 않는다** — 시작 로그(실제로 감시하는 ns)는 판정 ⑥
  명령만 본다. 이 절의 명령은 판정 기록용이다.

---

## 4. 뒷정리 (VD-9 판정 뒤)

1. **제거 PR(G2)** — 시험 대상을 언급하는 곳을 **전부** 한 PR에서 정리한다(2026-09-28 `grep -rn vd9` 전수 기준):
   - `platform/reloader/kustomization.yaml`: `- vd9-probe` 한 줄과 그 위 ⚠ 주석 두 줄 · 머리 주석의 변환기 문단(시험 대상 언급)
   - `platform/reloader/vd9-probe/` 디렉터리
   - 이 README: 머리 표의 `vd9-probe/` 행과 변환기 문단 · §1(렌더 13 → 12 · kind 줄 기대값 `Deployment 1` · pause 이미지 grep 줄 ·
     securityContext 기대 출력의 `jt-dev/vd9-probe` 줄 · 표의 Deployment 행) · §3 절차(판정 **기록 문단만** 남긴다) · 이 §4 · §5의 시험 대상 문장
   - `clusters/oci-k3s/apps/platform-reloader.yaml` 머리 주석 · `platform/README.md`의 reloader 행
   - `tests/validate.sh`: **`REL_KINDS`의 `Deployment:2` → `Deployment:1`(합계 13 → 12)** · `REL_PROBE`·`REL_PROBE_NS`를 빈 문자열로 · 그 주석
   - 픽스처: `tests/fixtures/positive/platform/reloader/vd9-probe.yaml`과 그 사본 `tests/fixtures/rel-scoped/*/platform/reloader/vd9-probe.yaml`
     삭제 + 각 `kustomization.yaml`의 `- vd9-probe.yaml` 줄 · `tests/fixtures/rel-scoped/probe-namespace/` 삭제
   - `tests/validate.tests.sh`: 긍정 단언의 10 REL PASS 문구(kind 합계 · `vd9-probe ns jt-dev`) · 개수가 박힌 단언(`Deployment 3≠2` 등) ·
     `rel-scoped-probe-namespace` 케이스 · `tests/README.md` 검사 10 절의 시험 대상·`REL-probe` 언급
   - 모노레포(별도 저장소): 하네스 `reloader-2`·런북에 시험 대상 개수(Deployment 2 · 합계 13)가 있으면 같은 시점에 고친다

   **완료 조건**: `grep -rn vd9 --exclude-dir=charts --exclude-dir=.git .` 결과 **0건**(이 README §3의 판정 기록 문단 제외) ·
   `bash tests/validate.sh` FAIL 0 · `bash tests/validate.tests.sh` 실패 0.
2. 머지 뒤 `platform-reloader`는 `prune: false`라 **`vd9-probe`를 지우지 않는다** — Git에서 사라진 객체로 남아 Application이
   OutOfSync(prune 필요)로 보인다.
3. **운영자가 지운다**(쓰기 2 — Deployment 먼저):

   ```powershell
   kubectl -n jt-dev delete deployment vd9-probe
   kubectl -n jt-dev delete secret vd9-probe
   kubectl -n argocd get application platform-reloader -o 'jsonpath={.status.sync.status}/{.status.health.status}'   # Synced/Healthy
   ```

---

## 5. 되돌리기

- **revert PR** → 렌더가 `resources: []` 뼈대로 돌아간다. `prune: false`라 객체는 남는다 → 운영자가 지운다:
  Deployment `reloader/reloader` · ServiceAccount `reloader/reloader` · Role/RoleBinding `reloader-role(-binding)` 4 ns
  (`identity`·`jt-dev`·`jt-prod`·`reloader`) + `reloader-metadata-role(-binding)`(`reloader`). 시험 대상이 아직 있으면 §4의 두 줄도.
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
