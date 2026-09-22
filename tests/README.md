# tests/ — validate 검사 스크립트와 자기검사 (T033)

required check `validate`가 **T047에서 배선할** 검사 본체와 그 자기검사. 정본은 모노레포 `specs/003-platform-foundation/contracts/gitops-repo.md`(§validate.yml · §validate.yml ExternalSecret 검사 · §sync-wave 단일 표 · §ClusterSecretStore 5개 · §이름·인증 규약 · §이미지·승격)와 `contracts/network-policy.md`(네임스페이스 표 14개 · 정책 세트 · 외부 egress 규칙 형식 · 포트 출처 각주)다. 계약과 스크립트가 어긋나면 계약을 먼저 고친다.

## CI 배선 상태 — **이 검사들은 아직 CI에서 강제되지 않는다**(2026-09-21 실측)

`.github/workflows/validate.yml`은 T003 골격 그대로다: 검사 1–7 스텝이 전부 `run: echo "자리 — T033에서 작성"`이고 **실제로 도는 스텝은 `actions/checkout`과 `gitleaks/gitleaks-action` 둘뿐**이다(`grep -rn "validate.sh" .github/` → 0건). 즉 required check `validate`는 오늘 **gitleaks만** 본다 — 이 디렉터리의 검사(0–10)는 한 줄도 돌지 않는다.

- **검사는 `tests/validate.sh`에 있고, CI가 이를 실제로 부르는 것은 T047(validate 워크플로 완성) 뒤다.** 그때까지 강제 수단은 **PR 전 로컬 실행**(`bash tests/validate.sh` · `bash tests/validate.tests.sh`)과 **사람 리뷰**뿐이다.
- 그러므로 다른 문서에서 "required check `validate`가 막는다/CI가 강제한다"로 읽히는 문장은 **T047 이후의 상태**를 말한다. 오늘의 통제 현황을 더 자세히 적은 곳은 `bootstrap/argocd/argocd-cm.yaml` 머리 주석의 「통제 현황(실측)」이다.
- 이 사실은 **여기 한 곳에만** 적는다. 다른 README는 이 절을 가리킨다.

| 파일 | 역할 |
|---|---|
| `validate.sh` | 검사 본체. 검사 순서·코드는 파일 머리 주석(tasks.md T033 문면 순서). sync-wave·네임스페이스·정책 세트·포트 각주·ClusterSecretStore 표는 이 파일 안의 단일 사본이 유일한 정본 사본이다 |
| `validate.tests.sh` | 자기검사. `fixtures/<case>/`마다 `validate.sh --root`를 돌려 기대 exit·메시지를 단언한다 |
| `fixtures/positive/` | 계약을 만족하는 최소 완전 트리(exit 0) — 새 검사를 추가하면 이 트리도 통과해야 한다 |
| `fixtures/<code>/` | 검사 항목별 부정 픽스처(각 항목이 실제로 FAIL 코드를 내는 최소 예시). 비밀처럼 보이는 값은 넣지 않는다(gitleaks 실패 케이스는 "대상 0개"로 만든다) |
| `fixtures/author/*.diff` | 검사 6(봇 작성자 경로 lint) 입력 |

## 실행

```bash
bash tests/validate.sh                 # 실제 트리(tests/ 제외). 도구 없으면 fail-closed(설치 안내 후 exit 1)
VALIDATE_SKIP_TOOLS=1 bash tests/validate.sh   # 로컬 부분 검증: 없는 도구가 필요한 검사만 SKIP(요약에 "불완전" 표시)
bash tests/validate.tests.sh           # 픽스처 자기검사(도구가 없으면 자동으로 SKIP 모드; yq는 필수)
VALIDATE_TESTS_REQUIRE_TOOLS=1 bash tests/validate.tests.sh   # CI(CI=true도 동일): 도구 누락 시 SKIP 모드로 내려가지 않고 exit 1
```

필요 도구: `yq`(mikefarah v4) · `kustomize` · `kubeconform` · `gitleaks` (+ `helm`은 helmCharts가 있는 kustomization에만 — 자기검사의 `fixtures/pol-port`·`fixtures/rel-scoped/{typo-key,typo-parent,cloudflared,env-vars}`는 helm과 **네트워크**(차트 pull)가 필요하다. 풀린 차트는 픽스처 아래 `charts/`에 남고 `.gitignore` 대상이다). CI(validate.yml, T047)는 네 도구를 sha256 핀으로 설치하고 `PR_AUTHOR`·`VALIDATE_BASE_SHA`·`VALIDATE_HEAD_SHA`를 넘긴다. kubeconform 스키마 캐시는 `${TMPDIR:-/tmp}/kubeconform-cache`(`VALIDATE_KUBECONFORM_CACHE`로 변경) — 저장소 밖 임시 경로이며 저장소에 파일을 남기지 않는다.

## 규칙

- `validate.sh`는 `--root` 트리(와 명시적으로 넘긴 diff 파일) 밖을 읽거나 쓰지 않고(예외: 저장소 밖 임시 경로의 kubeconform 스키마 캐시), 저장소 안에 임시 파일을 만들지 않으며, 자격·비밀을 요구하지 않는다.
- 검사를 추가·변경하면: 부정 픽스처 1개 + `validate.tests.sh` 단언 + `fixtures/positive/` 통과를 함께 갱신한다.
- 계약 표(sync-wave·네임스페이스·정책 세트·포트·ClusterSecretStore)를 바꾸면 `validate.sh`의 해당 표만 바꾼다 — 다른 곳에 중복 기재하지 않는다.
- 검사 9가 쓰는 상수(`CSS_TABLE`·`CSS_SA_NS`·`CSS_VAULT_*`·`CSS_K8S_REMOTE_NS`·`CSS_COND_TABLE`·`CSS_COND_PLATFORM_EXCLUDE`)는 5.6의 노드 주소와 **성격이 다르다.** 노드 주소는 재이미지·재조인으로 바뀌는 런타임 값이라 다섯 곳을 함께 고쳐야 하지만, 검사 9의 값은 **계약 문면**(§ClusterSecretStore 5개 표 · §이름·인증 규약)이라 계약을 고칠 때만 함께 바꾼다. 복제본은 `validate.sh`의 그 블록 하나뿐이다(store 매니페스트 자체는 검사 대상이지 사본이 아니다).
- 검사 5.6이 쓰는 노드 A 주소 2개(private `/32` · flannel 터널 장치 `/32`)는 여러 곳에 복제돼 있다. 노드 재이미지·재조인으로 값이 바뀌면 **아래 다섯 곳을 한 PR에서 함께** 바꾼다 — 아무것도 고치지 않으면 검사는 통과하면서 정책만 조용히 무력해지고, 일부만 고치면 5.6·자기검사가 FAIL한다. 이 목록은 **검사 5.6 관련 복제본**이다(private IP는 그 밖에 `allow-kube-api` 10장과 `policies-external.yaml`의 노드 IP 규칙에도 있다 — 전체는 `platform/policies/README.md` 상수 표의 "쓰이는 곳" 열을 따른다): ① `platform/policies/policies-common.yaml`의 `allow-apiserver-webhook` 4장 ② `tests/validate.sh`의 상수 `NODE_A_PRIVATE_CIDR`·`NODE_A_FLANNEL_CIDR` ③ `tests/fixtures/positive/platform/policies/policies-common.yaml`의 webhook 4장 ④ `tests/fixtures/pol-webhook-src/**`의 정책 픽스처 ⑤ `tests/validate.tests.sh`의 5.6 단언 문자열(빠짐·여분 목록).
- 계약 `network-policy.md`에는 값이 없다(자리표시자뿐) — 값이 바뀌어도 계약은 고칠 것이 없고, **메커니즘이 바뀔 때만** 모노레포에서 별도 커밋으로 고친다. 모노레포 쪽 리터럴은 private IP가 `infra/oci/instances.tf`·`infra/oci/network.tf`·`infra/bootstrap/k3s-*.sh`·`infra/cloudflare/variables.tf` 등에 있고(별도 저장소·별도 커밋 — **전수는 모노레포에서 grep**한다), flannel 값은 런북·빌드 노트의 실측 기록뿐이다(`np-set-5`는 노드 객체에서 유도하므로 바꿀 상수가 없다).
- **T047 필수 조건**: 작성자 lint(검사 6)는 PR head가 아니라 **base ref의 `tests/validate.sh`**로 실행한다 — `git show "$VALIDATE_BASE_SHA:tests/validate.sh" > tests/validate.base.sh && bash tests/validate.base.sh`(같은 `tests/` 안에 두어야 저장소 루트 판정이 유지된다). 그래야 App이 같은 PR에서 스크립트를 무력화할 수 없다. PR 이벤트(`GITHUB_EVENT_NAME=pull_request`)에서 `PR_AUTHOR`가 비면 검사 6이 FAIL이므로 반드시 넘긴다.

## 한계(명시)

- 검사 3(ES 규약)이 **보지 않는 것**: `target.creationPolicy`/`deletionPolicy` · `refreshInterval`/`refreshPolicy` · 어노테이션(`argocd.argoproj.io/sync-options` 포함) · `target.template` · `data[].secretKey`. 즉 인수형 ES가 `Orphan`에서 `Owner`로 뒤집혀도 검사 3은 PASS다 — 머지 전 방어선은 `platform/secrets/README.md` §2의 yq 렌더 체크, 라이브 방어선은 모노레포 하네스 `eso-4`(적용된 뒤에만 보인다)다.
- 4b(platform 이미지 digest 경고)는 `image:` **스칼라 줄만** 검사한다 — helm values의 분리형 `image.repository` / `image.tag`는 보지 않는다(Renovate `pinDigests`와 컴포넌트 태스크의 수동 병기에 맡긴다).
- 검사 5.6(`allow-apiserver-webhook`)이 **보는 것**: `platform/policies/` 아래 원본 YAML **과 그 디렉터리의 `kustomize build` 렌더 결과**, 출발 `ipBlock` cidr 집합(값 단위 정확 일치 · 중복 금지 · 형식 검사 · `except` 금지 · ipBlock 아닌 peer와 혼합 peer 금지), 계약 포트 집합(정확 일치 · 정수 · `endPort` 금지) · `protocol`(TCP만). 렌더 쪽은 세 가지를 더 본다: `patches`·merge key로 **넓어지는** 경우, 표 밖 ns에 같은 이름이 **나타나는** 경우(`kind: List` 풀림 · ns 변경 — 5.2의 EXCLUSIVE는 원본 파일만 본다), 표의 4개 ns에서 정책이 **사라지는** 경우(이름·ns 변경).
- 검사 5.6이 **보지 않는 것**: 그 주소가 **오늘의 노드 실물과 같은지**(리스가 바뀌면 정책은 조용히 무력해진다 — 라이브 대조는 모노레포 하네스 `np-set-5`가 노드 객체 InternalIP · `.spec.podCIDR`에서 유도해 본다), `spec.policyTypes`·`spec.podSelector`(validate 전체가 어느 정책에서도 보지 않는다), 그리고 정책이 실제로 클러스터에 적용됐는지. kustomize가 없어 검사 1이 SKIP되면 **렌더 소스가 아예 없다** — 그 사실은 5.6 PASS 줄의 "webhook 정책을 담은 소스: 원본 N · 렌더 M"에서 `M = 0`으로 드러난다.
- 검사 7.3(`WAVE-secrets-base`)이 **보는 것**(다섯 갈래):
  - ⓐ **base 참조**: 모든 `kustomization.yaml`의 `resources`·`bases`·`components` 항목을 경로로 정규화해 `secrets/` 아래를 가리키는 항목이 `platform/secrets/kustomization.yaml`에만 있는지 본다. **배달자 자신(`platform/secrets`)을 base로 끌어가는 전이 참조도 위반**이다(소비자 렌더에 ES가 들어간다). `secrets/<ns>/kustomization.yaml`이 자기 디렉터리 안의 파일을 가리키는 것은 위반이 아니고, 다른 ns를 가리키면 위반이다. **절대 경로(`/…`)와 저장소 밖으로 나가는 상대 경로는 위치 판정 불가로 FAIL**한다(fail-closed — 로컬에서만 렌더되고 Argo repo-server의 체크아웃 경로에서는 실패한다).
  - ⓑ **소유자 대조(렌더 기준)**: `secrets/**` **파일**의 ExternalSecret과 **같은 이름**이 배달자 밖 소스(파일·렌더)에도 있으면 FAIL — 파일 복사본 · 전이 base · helm 렌더로 두 Application이 같은 ES를 각자 적용하는 경로를 잡는다. 이름으로 맞추는 이유는 `secrets/<ns>/kustomization.yaml`의 `namespace:` 변환기가 원본에 없던 ns를 렌더에서 채울 수 있어서다(그래서 **같은 이름을 다른 ns에 두는 트리는 구분하지 못한다**).
  - ⓒ **죽은 선언(파일 단위)**: `secrets/**` 파일의 ES가 `platform/secrets` **렌더**에 없으면 FAIL — `secrets/` 바로 아래 파일 · `secrets/<ns>/sub/` 하위 · ns kustomization에 등록하지 않은 파일이 전부 걸린다. kustomize가 없으면 이 갈래는 돌지 않고, 그 사실은 PASS 줄의 "배달자 렌더 0"으로 드러난다(5.6의 "원본 N · 렌더 M" 관례와 같다). 디렉터리 단위 완전성(YAML을 담은 `secrets/<ns>/`가 배달자에 포함됐는지)도 함께 보며, **실제 저장소 루트(`--root`가 저장소 루트)에서는 항상** 본다. 부분 트리 예외(배달자 구조를 쓰지 않는 픽스처)는 픽스처 실행에만 적용된다.
  - ⓓ **적용 주체**: `secrets` 또는 `secrets/*`를 가리키는 Application은 금지다(`.spec.source.path`와 **multi-source `.spec.sources[].path` 전부** — 7.1은 첫 source만 본다). 배달자 파일이 있으면 `source.path == platform/secrets`인 Application이 하나는 있어야 한다.
  - ⓔ **변환 키 금지(T045 G4 · 계약 §validate.yml 4)**: `platform/secrets/kustomization.yaml`의 최상위 키는 `{apiVersion, kind, resources}`, `secrets/**`의 `kustomization.yaml`은 거기에 `namespace`까지만이다. `patches`·`replacements`·`transformers`·`namePrefix`·`helmCharts` 등이 있으면 **벗어난 키 이름을 적어** FAIL한다(YAML 맵으로 읽히지 않으면 fail-closed로 FAIL). 이유는 ⓐ–ⓓ가 **원본 파일의 경로**로 판정하기 때문이다 — 변환 키는 원본을 그대로 둔 채 **Argo가 실제로 적용하는 배달자 렌더에서만** store·`remoteRef`·`creationPolicy`를 바꾼다. 같은 PR에서 3.2(scope↔위치)의 대상에 배달자 렌더(`platform/secrets`)를 더해 결과도 함께 본다.
  - **보지 않는 것**: 원격(URL) base, 배달자가 `secrets/` 밖에서 끌어오는 리소스, ES **이름이 같고 ns만 다른** 경우, 라이브에서 실제로 어느 Application이 그 ES를 적용했는지(그것은 ES의 Argo tracking 어노테이션 — `platform/secrets/README.md` §3). 그리고 **Windows 로컬 실행은 경로 대소문자 오기를 잡지 못한다**(대소문자 무시 파일시스템 — Linux의 검사 1이 빌드 실패로 잡는 일반 문제다).
  - **닫힌 구멍(기록)**: G3까지 **3.2는 `platform/secrets` 렌더를 위치로 보지 않았다**(트리거가 원본 경로 `^secrets/`였다) — 배달자에 `patches:`를 넣으면 원본은 그대로인 채 렌더에서만 `creationPolicy: Owner`·`remoteRef.key`가 바뀌어도 전 검사 PASS였다. T045 G4에서 **변환 키 금지(ⓔ)** + **3.2 대상에 배달자 렌더 포함**으로 닫았다(픽스처 `secrets-owner/deliverer-patch`·`secrets-owner/ns-transform`).
- 검사 6(봇 작성자)은 변경 줄이 `digest: sha256:<64hex>` 형식인지만 본다(digest 값의 진위·attestation은 보지 않음). 보증은 이 줄 검사와 같은 실행의 **트리 검사(4a 형식·kustomize build·②)의 결합**이며, 위 base ref 실행 조건이 함께 있어야 성립한다.
- 검사 9(ClusterSecretStore)가 **보는 것**: 원본 YAML과 `kustomize build` 렌더 결과 양쪽의 **선언된 값**.
  - 9.1 위치(`platform/secret-stores/`) · `metadata.namespace` 금지 · 이름/provider 집합 = 계약 표 5개
  - 9.2 vault 4장의 `auth` 키 · `serviceAccountRef.namespace`(referent auth 차단) · `audiences` · `mountPath` · `server`/`path`/`version` · store↔SA·role 매핑
  - 9.3 kubernetes 1장의 `auth` 키 1개 · SA ns · `audiences` 금지 · CRD 기본값 3필드 명시 · `remoteNamespace`가 **정확히 `data`**(생략뿐 아니라 `default` 같은 오기도 잡는다)
  - 9.4 `conditions`가 **정확히 1항목**이고 그 키가 `namespaces` **하나**이며(`namespaceSelector`·`namespaceRegexes` 금지) 그 집합이 계약 표와 정확 일치(중복 ns도 FAIL). `vault-platform`의 12개는 `NS_TABLE`에서 `jt-dev`·`jt-prod`를 빼서 **기계 유도**하므로 목록이 두 곳에 복제되지 않는다
  - 이름 집합의 완전성은 `platform/secret-stores/` 디렉터리가 있는 트리에서만 요구한다(부분 트리 픽스처를 오탐하지 않기 위해).
- 검사 9가 **보지 않는 것**: 라이브 store의 `status`(`Ready`/`reason`/`message`), Vault role·정책의 실제 존재(그쪽은 모노레포 `infra/vault/`와 하네스 `eso-1`), `caProvider`의 `type`/`name`/`key` 값, `conditions`가 **실제로** 어느 ExternalSecret을 막았는지(라이브 `denied by spec.condition`). 특히 vault store에서 `serviceAccountRef.namespace`를 빠뜨리면 라이브는 로그인 없이 `Ready=True/reason=Valid`가 되어 **status로는 절대 드러나지 않는다** — 그 한 가지를 잡는 것이 9.2 `CSS-auth-referent`의 존재 이유이고, CRD 스키마에 필수 필드가 아니라 kubeconform으로는 잡히지 않는다.
- 검사 10(`REL` — T046 · 계약 §validate.yml 4 「(T046)」)이 **보는 것**: `platform/reloader`의 `kustomize build` **렌더 하나**(경로 정확 일치 — 중첩된 `platform/reloader/vd9-probe` 렌더를 따로 보지는 않지만 부모 렌더에 포함되므로 10.4는 그 객체도 본다).
  - 10.1 `ClusterRole`·`ClusterRoleBinding` **0**(scoped 모드의 증거)
  - 10.2 Deployment `reloader`(ns `reloader`) 첫 컨테이너 `args`의 `--namespaces` 인자가 **정확히 1개**이고(`--namespaces x`처럼 값을 다음 인자로 넘기는 형식도 세며, 형식은 `--namespaces=<쉼표 목록>` 하나만 허용) 원소 집합이 `REL_WATCH_NS`(계약 목록) + 릴리스 ns와 정확 일치(누락·여분·중복·빈 원소 FAIL). 2개 이상이 FAIL인 이유는 "뒤의 값이 이긴다"가 아니라 **목록이 합쳐진다**는 것이다 — Reloader v1.4.21 `util.go`가 `StringSliceVar`로 정의하고 pflag StringSlice는 두 번째 값부터 덧붙인다(감시 범위 확대)
  - 10.3 같은 `args`의 `--reload-strategy` 인자가 정확히 1개이고 `--reload-strategy=annotations`(이쪽은 `StringVar`라 여럿이면 마지막 값이 적용된다)
  - 인자 수·플래그 수는 **yq 안에서 직접 센다**. 예전처럼 args를 구분자로 이어 셸 `read`로 나누면 개행이 든 인자에서 읽기가 끝나 그 뒤의 두 번째 `--namespaces=`를 놓쳤다(가짜 PASS — `fixtures/rel-scoped/args-newline`). 제어 문자(개행·CR·탭 등)가 든 인자가 있으면 **10.0 `REL-args`** FAIL이고, 개수 판정은 그대로 하되 집합·값 비교는 생략한다(고친 뒤 다시 돌린다)
  - 10.4 `REL-rbac-ns` 렌더 전체의 `Role`·`RoleBinding`(이름 무관) ns 집합이 kind마다 `REL_WATCH_NS` + 릴리스 ns와 정확 일치 — 모노레포 하네스 `reloader-2`가 라이브 `status.resources`에서 보는 것과 같은 불변식이다(하네스는 Role `reloader-role`만 본다)
  - 10.4 `REL-image` 렌더 전체의 모든 `image` 키에서 저장소(태그·digest를 뗀 값)가 `…/stakater/reloader`(레지스트리 무관)인 컨테이너가 **정확히 1개**이고, 그것이 Deployment `reloader/reloader`의 `containers[0]`(10.2·10.3이 보는 자리)이며, 저장소가 `ghcr.io/stakater/reloader`이고 `command`가 없다. 10.2·10.3의 시야 밖에서 감시 범위를 넓히는 경로 — 이름이 다른 두 번째 Reloader(`fixtures/rel-scoped/second-deploy`) · 두 번째 컨테이너(`second-container`) · `command` 안의 `--namespaces=`(`command` — args는 command 뒤에 붙어 pflag가 두 목록을 합친다) — 를 닫는다(셋 다 10.4 이전에는 가짜 PASS였다 — 2026-09-22 독립 리뷰 실측)
  - 10.0 fail-closed: 렌더 없음(kustomize build 실패 — 차트의 `fail` 가드 포함) · Deployment 부재·중복 · yq 추출 실패 · 저장소 루트에서 `platform/reloader` 부재. 부분 트리 픽스처에 `platform/reloader`가 없으면 "대상 없음" PASS다. Deployment가 없거나 렌더가 없으면 10.2–10.4는 돌지 않는다
  - 원본 values가 아니라 렌더를 보는 이유: 차트 기본값이 `watchGlobally: true`이고 values 스키마가 키 오타를 막지 않는다. `watchGlobaly` 한 키 오타는 차트 가드가 렌더를 멈추지만(→ 10.0), 부모 키 `reloader:` 오타처럼 두 키가 함께 빠지면 렌더는 **성공한 채** 전역 모드가 된다(→ 10.1·10.2·10.3·10.4 `REL-rbac-ns`). 픽스처 `fixtures/rel-scoped/{typo-key,typo-parent,cloudflared,env-vars}`가 values 갈래를 실제 차트 렌더로 재현하고(helm·네트워크 필요), `{second-deploy,command,second-container,args-newline}`은 긍정 트리의 사본에 결함 하나를 더한 순수 매니페스트다(helm 불필요 — `deployment.yaml`·`rbac.yaml`은 `fixtures/positive/platform/reloader/`의 사본이므로 함께 고친다).
- 검사 10이 **보지 않는 것**: Role의 **규칙**과 RoleBinding의 `roleRef`·`subjects`(`platform/reloader/README.md` §1의 yq 체크리스트가 사람 손으로 본다), 다른 컴포넌트 렌더에 든 Reloader, `stakater/reloader`가 아닌 이름으로 다시 올린 이미지, args의 `$(VAR)` 치환(kubelet이 컨테이너 env로 펼친다 — 정적으로 알 수 없다), 소비자 Deployment의 `reloader.stakater.com/auto` 어노테이션 유무·위치, 라이브에서 Reloader가 실제로 그 ns만 감시하는지(시작 로그)와 Application `status.resources`(모노레포 하네스 `reloader-2` · README §3 판정 ⑥), Argo와의 드리프트(VD-9 — README §3).
