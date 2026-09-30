# tests/ — validate 검사 스크립트와 자기검사 (T033)

required check `validate`가 부르는 검사 본체와 그 자기검사(무엇이 어떤 순서로 도는지는 아래 「CI 배선 상태」). 정본은 모노레포 `specs/003-platform-foundation/contracts/gitops-repo.md`(§validate.yml · §validate.yml ExternalSecret 검사 · §sync-wave 단일 표 · §ClusterSecretStore 5개 · §이름·인증 규약 · §이미지·승격)와 `contracts/network-policy.md`(네임스페이스 표 14개 · 정책 세트 · 외부 egress 규칙 형식 · 포트 출처 각주)다. 계약과 스크립트가 어긋나면 계약을 먼저 고친다.

## CI 배선 상태 — `validate.yml`이 이 검사들을 부른다(T047 G2 · G3)

`.github/workflows/validate.yml`의 job `validate`(= ruleset `main`의 required check 이름)가 **main을 향한 PR**과 main push에서 아래 순서로 돈다(다른 브랜치를 base로 한 PR에서는 돌지 않는다 — 아래 「base는 봇이 고른다」). 스텝 하나라도 실패하면 check가 실패하고 머지가 막힌다. 순서의 이유와 입력 규칙(`${{ }}` 값은 `env:`로만 넘긴다 · `VALIDATE_SKIP_TOOLS` 등 스위치 변수는 어디에도 두지 않는다)의 정본은 워크플로 머리 주석이다. 같은 워크플로의 job `render-diff` · `render-comment`는 required check가 아니다(아래 「렌더링 diff PR 코멘트」).

| 순서 | 스텝 | 이벤트 | 실행되는 코드 |
|---|---|---|---|
| 1 | checkout(`fetch-depth: 0` · `persist-credentials: false`) | PR · push | 액션(SHA 고정) |
| 2 | 경로 lint — `bash tests/validate.base.sh --only-author`(검사 6만) | PR만 | **main의 스크립트** — 러너가 가져온 `origin/main`의 끝에 있는 `tests/validate.sh`를 `git show`로 꺼낸 사본(`pull_request.base.sha`가 아니다 — PR이 말하는 base는 확인에만 쓴다: base ref가 `main`이 아니거나 base 커밋이 main의 이력 위에 없으면 실패). diff 기준도 `origin/main`의 끝이다. PR 쪽 코드가 한 줄도 돌기 전에, 러너에 원래 있는 git · bash · coreutils만으로 돈다 |
| 2b | 자기검사 대상 판정 | PR · push | 워크플로 파일 안의 인라인 스크립트(git · bash만 · PR 쪽 코드를 실행하기 전). main push는 항상 돌리고, PR은 `origin/main`의 끝과 head의 merge-base ↔ head에서 `tests/` 또는 `.github/` 아래가 바뀐 경우에만 돌린다(출력 `selftest=run|skip` — 숫자로 읽히지 않는 낱말이다. 식에서 없는 출력은 0으로 읽히므로 `0`·`1`을 쓰면 출력이 없을 때 자기검사가 조용히 꺼진다). 판정에 실패하면(merge-base를 못 구함 · 둘 이상) 돌리는 쪽으로 넘어진다 |
| 3 | 도구 설치 — kustomize v5.8.1 · yq v4.53.6 · gitleaks 8.30.1 · kubeconform v0.8.0 · helm v4.3.0(linux arm64) | PR · push | 워크플로 파일 안의 인라인 스크립트(저장소의 스크립트를 부르지 않는다). 받은 파일마다 sha256 대조, 설치 뒤 버전 대조 — 어긋나면 실패 |
| 4 | 전체 검사 — `bash tests/validate.sh`(검사 0–10) | PR · push | PR 쪽 스크립트. PR 이벤트에서는 `PR_AUTHOR`·`PR_AUTHOR_ID`·`PR_SENDER`·`PR_SENDER_ID`·`VALIDATE_HEAD_SHA`를 넘기고, 기준 커밋 `VALIDATE_BASE_SHA`는 본문이 `origin/main`의 끝에서 정한다(스텝 2와 같은 기준 — 검사 6이 한 번 더 돈다 · 무해). push에서는 작성자와 발신자가 모두 비어 검사 6은 대상 없음이다 — push 이벤트에도 `sender`는 있지만 넘기지 않는다(작성자 없이 발신자만 가면 검사 6이 입력이 어긋났다고 보고 FAIL한다) |
| 5 | 자기검사 — `bash tests/validate.tests.sh` | **main push는 항상 · PR은 2b가 고른 경우만** | PR 쪽 스크립트. 러너가 넣는 `CI=true`로 부분 실행을 거부하고 도구 누락(helm 포함)을 실패로 본다. 4 **뒤에** 둔다 — 자기검사가 픽스처 아래 `charts/`에 풀어 둔 차트를 4의 검사 8(gitleaks 파일 스캔)이 훑지 않게 |
| 6 | gitleaks 액션 — 커밋 히스토리 스캔 | PR · push | 액션(SHA 고정 — 액션이 자기 gitleaks를 받아 쓴다) |

- **main 쪽 스크립트로 도는 것은 스텝 2 하나다.** 4·5는 PR 쪽 스크립트라 PR이 검사를 고치면 그 PR에서는 고친 검사가 돈다 — 사람 PR은 리뷰가, 봇 PR은 스텝 2가 막는다(봇이 `apps/*/overlays/dev/kustomization.yaml`의 digest 줄 밖을 건드리면 — `tests/`·`.github/` 포함 — main의 규칙으로 FAIL). 스텝 2가 첫 검사 스텝인 이유도 같다: PR 쪽 코드가 `.git`이나 작업 트리를 먼저 바꿀 수 없게.
- 스텝 2의 사본(`tests/validate.base.sh`)은 저장소 루트 판정 때문에 `tests/` 안에 둔다(아래 「T047 필수 조건」). 자리에 이미 있는 파일·심볼릭 링크를 먼저 지우고(`tests/` 자체가 링크면 실패 — PR이 그 이름으로 `/dev/null` 링크를 넣어 두면 사본이 거기로 쓰이고 빈 스크립트가 exit 0으로 끝난다), 끝나면 성공·실패와 무관하게 지운다(남으면 4의 검사 8이 훑는다 — 못 지우면 실패). base SHA가 전체 커밋 ID가 아니거나, base 커밋에 스크립트가 없거나(`git show` 실패), 사본이 비었으면 실패다 — 조용히 건너뛰지 않는다. base 커밋의 스크립트가 `--only-author`를 모르면(T047 G1 이전의 main) 인자 오류(exit 2)로 실패한다.
- 설치한 도구는 `$RUNNER_TEMP/bin`에 두고 PATH 맨 앞에 붙인다. 4는 시작할 때 다섯 도구가 그 경로로 풀리는지 확인한다(러너 이미지의 다른 `yq` 등이 먼저 잡히면 실패). kubeconform 스키마 캐시는 `$RUNNER_TEMP/kubeconform-cache`다(4·5가 공유 — 실행 사이에는 보존하지 않는다).
- **base는 봇이 고른다**(T047 G2 리뷰 — 실험으로 재현): 봇은 `bump/**`에 임의 내용을 쓸 수 있으므로, 검사 스크립트를 무력화한 브랜치를 **base로** 잡은 PR을 열 수 있다. 워크플로가 `pull_request.base.sha`의 스크립트를 쓰던 때에는 그 PR에서 봇의 스크립트가 "base 스크립트"로 돌아 통과했고, 성공한 check는 head 커밋에 붙으므로 같은 head를 main으로 향하게 하면 required check가 채워졌다. 지금은 ①워크플로가 main을 향한 PR에서만 돌고 ②스텝 2가 base ref를 한 번 더 확인하며 ③스크립트와 diff 기준을 `origin/main`의 끝에서 가져온다. ruleset의 required check는 출처를 GitHub Actions로 고정한다(`integration_id`).
- **동시 실행**: PR은 같은 PR의 옛 실행을 취소한다(취소된 실행은 check를 채우지 못한다). **main push 실행은 서로 취소하지 않는다** — "봇 PR의 검사 스크립트는 main push에서 검증한다"가 성립하려면 main의 실행이 끝까지 돌아야 한다. main 실행의 실패는 머지를 막지 못한다(이미 머지된 뒤다) — 커밋의 상태 표시로 드러나므로 머지한 사람이 확인한다(알림은 관측 태스크에서 다룬다).
- **사람 PR의 check가 봇 때문에 실패했을 때**: 봇이 사람의 PR을 닫았다 다시 열면 이벤트 발신자가 봇이라 스텝 2가 FAIL하고 그 커밋의 check가 실패로 남는다(의도한 동작이다 — 봇이 건드린 PR을 통과시키지 않는다). 복구는 **사람이** 그 PR을 다시 열거나 새 커밋을 push하는 것이다(재실행은 같은 이벤트로 돌므로 결과가 같다).
- **봇은 값만 바꾼다 — 첫 `images` 항목은 사람 PR이 만든다**: 스텝 2는 제자리 교체만 허용하므로, dev overlay에 `images` 항목이 아직 없을 때 봇이 그 블록을 **추가**하는 PR은 FAIL한다. pod의 overlay를 처음 만드는 PR(사람)이 첫 digest까지 넣는다.
- **렌더링 diff PR 코멘트(T047 G3 · 계약 §validate.yml 7) — required check가 아니다.** 같은 워크플로의 job 둘이 PR 이벤트에서 `validate`가 **성공한 뒤에만** 돈다(실패해도 머지를 막지 않는다 — 판정은 `validate`가 한다). 운영자가 머지 전에 "이 PR이 클러스터에 무엇을 바꾸는가"를 보는 수단이고, prod 승격 PR은 이 코멘트를 확인한 뒤 머지한다 — 코멘트가 없거나 · `render-diff`가 실패했거나 · 코멘트 머리의 PR head가 PR의 최신 커밋이 아니면 머지하지 않는다. 로직은 모두 워크플로 파일 안의 인라인 스크립트다(봇은 `.github/workflows/`를 못 바꾸지만 `tests/` · `.github/actions/` · `.github/scripts/`는 바꿀 수 있다).

  | job | 조건 · 권한 | 스텝 | 실행되는 코드 |
  |---|---|---|---|
  | `render-diff` | `needs: validate` · PR 이벤트만 · job 권한 `contents: read`뿐 | 1 checkout(`fetch-depth: 0` · `persist-credentials: false`) → 2 도구 설치(kustomize · yq · helm — `validate` 스텝 3과 같은 버전 · sha256) → 2b 두 job의 도구 값 대조(워크플로 파일에서 읽어 어긋나면 실패) → 3 렌더와 비교 → 4 아티팩트 `render-diff`(`body.md` · `full.diff` · 7일 보존) → 5 job 요약 | 인라인 스크립트 + 액션(SHA 고정). PR의 매니페스트를 `kustomize build --enable-helm`으로 렌더한다 — 쓰기 권한이 없는 job이다 |
  | `render-comment` | `needs: render-diff` · 같은 저장소 브랜치의 PR만 · job 권한 `pull-requests: write`뿐(`contents`도 없다) | 1 아티팩트 `render-diff` 받기 → 2 코멘트 달기 | 인라인 스크립트 + 액션(SHA 고정). **체크아웃하지 않고 PR의 내용을 처리하지 않는다** — 쓰기 토큰을 가진 job이 PR이 고른 내용을 렌더하지 않게 권한을 나눴다(`pull_request_target`은 쓰지 않는다) |

  - **비교의 두 쪽**: main = 러너가 가져온 `origin/main`의 끝(`git worktree`로 꺼낸다 — 스텝 2와 같은 기준이고 `pull_request.base.sha`가 아니다), PR = 체크아웃된 merge ref.
  - **대상**: 두 쪽 kustomization 디렉터리의 합집합(`tests/validate.sh`의 열거와 같은 규칙 — 세 파일 이름 · 루트 `tests/` · `.git/` · 경로에 `/charts/`가 든 곳 제외. 한쪽에만 있으면 빈 렌더와 비교해 새 디렉터리 · 디렉터리 삭제로 나온다) + directory source 경로(두 쪽 Application — `clusters/**/apps/*.yaml` · `bootstrap/root-app.yaml` — 의 `spec.source.path` 중 kustomization이 없는 곳 — 오늘은 `clusters/oci-k3s/apps`). directory source는 그 디렉터리 바로 아래의 `*.yaml` · `*.yml` · `*.json`(Argo CD가 읽는 파일 — README는 뺀다)을 파일마다 `diff -uN`과 같은 방식으로 비교한다. 경로는 실제 경로(`realpath`)로 풀어 저장소 루트 아래가 아니면(경로 중간의 심볼릭 링크가 루트 밖을 가리키면) 읽지 않고 렌더 실패로 적는다 — 경로 끝이 심볼릭 링크이거나 디렉터리가 아닌 경우도 같다. 그 디렉터리 안의 파일이 심볼릭 링크면 따라가지 않고 링크라는 사실만 적는다. 한쪽에만 kustomization이 있는 `source.path`(directory source ↔ kustomization 전환)는 없는 쪽을 directory source로 읽어 kustomization 렌더와 비교하고, 표에 `(directory source → kustomization)` · `(kustomization → directory source)`로 적는다 — 두 형식의 diff에는 서식 차이(kustomize가 키를 정렬한다 · 파일 이름 주석 줄)가 섞이므로 무엇이 바뀌었는지는 객체 목록으로 본다.
  - **본문(`body.md`)의 모양**: 첫 줄 표식 `<!-- render-diff:validate -->` → 머리(비교한 main 끝 · PR head · 렌더한 merge ref의 짧은 SHA, 실행 기록 링크, 대상 · 바뀐 · 렌더 실패 디렉터리 수) → 변경이 없으면 `렌더 변경 없음` 한 줄(문서만 바꾼 PR), 있으면 요약 표(디렉터리 · 추가 · 삭제 · 변경 객체 수 · diff 줄 수(+/−) · 렌더 상태 — 정상 · 새 디렉터리 · 디렉터리 삭제 · main 쪽 실패 · PR 쪽 실패 · 양쪽 실패 · 경로 없음(양쪽))와 디렉터리별 `<details>`(바뀐 객체 목록과 unified diff). `경로 없음(양쪽)`은 Application의 `source.path`가 두 쪽 어디에도 없는 경우다 — 머리의 대상 수에 들어가므로 표에도 행으로 싣는다(머리에 그 수를 따로 적는다). diff를 싣지 못한 행(Secret이 든 YAML을 읽지 못함 · diff 오류)은 줄 수를 `—`로 적는다. 객체 비교는 렌더를 문서로 나눠 `apiVersion` · `kind/namespace/name`과 문서 내용(JSON)을 맞추고, 목록에는 `` `kind/namespace/name` (`apiVersion`) ``로 적는다(같은 식별자가 여럿이면 나온 순서로 `#2` · `#3` — apiVersion만 다른 두 객체는 따로 맞추고, apiVersion이 바뀐 객체는 삭제 + 추가로 나온다). 렌더가 실패한 디렉터리는 오류 앞 5줄을 싣고 넘어간다(스텝은 경고만 남기고 통과한다 — 렌더 실패의 판정은 `validate`의 검사 1).
  - **PR이 고른 글자**: diff와 렌더 오류는 코드 울타리 안에만 둔다 — 울타리는 내용의 가장 긴 백틱 연속보다 길다(내용 안의 백틱 3개 줄 · `</details>` · 표식이 울타리를 닫거나 해석되지 않는다). 울타리 밖에 두는 디렉터리 · 객체 이름은 `[A-Za-z0-9_.:@+=,~-]`(경로와 apiVersion은 `/`도) 밖의 바이트를 `%XX`로 바꿔 인라인 코드로 싣는다(백틱 · 개행 · `<` · `|` 포함 — 객체 이름도 YAML에서 풀린 원래 바이트 기준이라 개행은 `%0A`다). 탭 · 개행 밖의 제어 문자는 지운다. 렌더 스텝은 PR이 고른 글자를 표준 출력에 찍지 않는다(워크플로 명령 해석 방지).
  - **크기 한도**: 본문이 60000바이트를 넘으면 디렉터리별 diff 전문을 빼고 요약 표 + 바뀐 객체 목록만 남기며 "전문은 이 실행의 아티팩트 `render-diff`에 있다"를 적는다. 그래도 넘으면 객체 목록을 디렉터리마다 앞의 N개(1000 · 500 · 200 · …)로 자르고 자른 사실을 적고, 그래도 넘으면 요약 표만, 마지막으로 머리만 남긴다(조용히 자르지 않는다). 전문 `full.diff`는 객체 목록 · 렌더 오류 · diff를 전부 담는다.
  - **Secret**: 렌더(또는 directory source 파일)에 `data` · `stringData` · `metadata.annotations`가 있는 `kind: Secret` 맵(List 안 포함)이 있으면 그 디렉터리는 두 쪽 모두 그 값(어노테이션은 전부 — `kubectl.kubernetes.io/last-applied-configuration`에는 값이 통째로 들어간다)을 `Secret 객체 — 값 생략`으로 바꾼 뒤(키는 남긴다) 비교해 본문 · 전문 어디에도 값이 실리지 않는다. 그 디렉터리의 diff는 yq가 다시 쓴 사본끼리의 diff다(원문과 서식 · 따옴표 · 들여쓰기가 다를 수 있다). 값만 바뀐 Secret은 객체 목록에 "값만 바뀌었다"로 나온다(값은 싣지 않는다). **Secret이 아닌 kind에 든 값(ConfigMap에 넣은 Secret 문서 · ExternalSecret의 `template.data` 등)은 가리지 않는다** — 그런 값이 저장소에 들어오지 않게 하는 것은 gitleaks(검사 8 · 스텝 6)다.
  - **코멘트 달기**: 받은 `body.md`를 믿지 않는다 — 일반 파일(심볼릭 링크 아님) · 1–65000바이트 · 첫 줄이 표식이 아니면 코멘트를 달지 않고 실패한다. 본문은 `jq -n --rawfile`로 JSON을 만들어 `gh api --input`으로 보낸다(명령줄 인자로 넘기지 않는다). PR 번호 · 저장소 이름은 `env:`로 받고 형식을 확인한다. 그 PR의 이슈 코멘트를 전부(페이지 넘김 포함) 읽어 **작성자가 `github-actions[bot]`이고 본문이 표식으로 시작하는** 것 중 가장 오래된 하나를 PATCH로 갱신하고, 없으면 POST로 만든다 — PR마다 코멘트 하나다. 다른 계정이 표식을 넣은 코멘트는 건드리지 않고, 조건에 맞는 것이 둘 이상이면 하나만 갱신하고 경고를 남긴다(지우지 않는다). `GH_TOKEN`은 이 스텝의 env에만 있다.
  - **포크 PR**: 토큰이 읽기 전용이라 `render-comment`가 돌지 않는다 — `render-diff`가 job 요약에 본문 전체를 남긴다(같은 저장소 PR의 job 요약에는 머리와 요약 표만).
  - **도구 값**: `render-diff` 스텝 2의 버전 · sha256은 `validate` 스텝 3의 값을 그대로 옮긴 것이다 — 두 job의 값을 함께 바꾼다(스텝 2b가 워크플로 파일에서 두 값을 읽어 어긋나면 실패한다).
  - **한계**
    - 코멘트는 `validate`가 **성공한 뒤에만** 달린다 — 검사가 실패한 PR에는 렌더 비교가 없다. `render-diff`가 실패하면 코멘트가 갱신되지 않아 **이전 커밋의 코멘트가 남는다** — 코멘트 머리의 PR head SHA가 PR의 최신 커밋과 같은지 본다.
    - main 쪽 기준은 **실행 시점의** `origin/main` 끝이다. PR 브랜치가 뒤처져 있으면 PR 쪽(merge ref)에 main의 새 변경이 없어 그 변경이 diff에 거꾸로 섞여 보인다 — ruleset이 브랜치를 main 최신으로 요구하므로(strict) 머지 직전에는 같다.
    - 렌더는 `kustomize build`이지 Argo CD가 실제로 적용한 결과가 아니다 — Application이 source를 덮어쓰지 않는다는 검사 7.4(`spec.source`의 kustomize · helm · directory 설정 · multi-source · hydrator 금지)가 둘을 같게 만든다. 클러스터의 라이브 상태와의 차이(수동 변경 · drift)는 보이지 않는다.
    - 포크 PR에는 코멘트가 없다(job 요약만).
    - helm 차트를 쓰는 컴포넌트는 렌더에 네트워크가 필요하다(차트 저장소). 렌더 한도는 디렉터리마다 60초(+ 정리 10초)이고 job 한도는 15분이다 — helm 디렉터리 넷이 두 쪽 모두 한도에 걸려도 약 9분 20초라 job이 끝까지 돌고, 내려받기가 실패한 디렉터리는 렌더 실패 행으로 코멘트에 실린다. **차트 저장소 장애가 그보다 길게 job을 붙잡아 job 한도를 넘기거나 `render-diff`가 다른 까닭으로 실패하면 코멘트가 갱신되지 않고 이전 커밋의 코멘트가 남는다** — 코멘트 머리의 PR head SHA를 본다. helm 디렉터리가 늘면 두 한도를 함께 본다(워크플로의 `render-diff` `timeout-minutes` 주석).
    - **kustomization 디렉터리도 directory source 경로도 아닌 파일의 변경은 보이지 않는다** — `bootstrap/root-app.yaml` · `tests/` · `.github/` · 문서 등(그런 파일만 바꾼 PR은 "렌더 변경 없음"이다 — Application의 `source.path`를 바꿔 대상 경로가 달라지는 경우만 그 경로가 표에 나온다). 그 변경은 PR의 파일 diff로 본다.
    - **비결정 렌더는 감지하지 않는다** — 차트가 렌더마다 난수 · 시각 · 새 인증서를 넣으면 파일이 그대로여도 그 디렉터리가 바뀐 것으로 나온다(오늘의 차트 넷은 결정적이다).
    - Secret 값은 어디에도 싣지 않으므로 값의 **내용**이 어떻게 바뀌었는지는 보이지 않는다(바뀌었다는 사실만). directory source는 `*.yaml` · `*.yml` · `*.json`만 본다(`.jsonnet`은 평가하지 않는다).
  - **실측**: 로컬(Windows · Git Bash) 렌더와 비교 스텝 약 40–70초(대상 30개 × 두 쪽 · helm 차트 네 개 내려받기 포함). 러너 실측은 첫 PR 실행에서 남긴다.
- **아직 CI가 하지 않는 것**
  - 스키마 캐시 보존(`actions/cache`) — 넣지 않았다. 캐시 없이도 전체 검사가 35초라 얻을 것이 적다.
- **러너 실측(2026-09-29 · ubuntu-24.04-arm · 캐시 없음)**: 경로 lint 1초 · 도구 설치 2초 · 전체 검사 **35초** · 자기검사 122 케이스 **184초** · gitleaks 히스토리 3초 · job 전체 약 3분 48초. 같은 검사가 Windows · Git Bash에서는 전체 검사 약 10분 · 자기검사 약 1시간이다(프로세스 생성 비용) — **로컬은 영향 받는 케이스만 돌리고(`VALIDATE_TESTS_ONLY`) 전체 판정은 CI가 맡는다.** 각 run 스텝은 스텝 이름 · 시작·종료 시각(UTC) · 초 · exit를 job 요약에 한 줄씩 남긴다.
- **자기검사를 PR마다 돌리지 않는 이유**: 봇의 dev bump PR은 required check가 끝나야 자동 머지되므로 검사 시간이 그대로 배포 지연이다(dev bump → sync 5분 이내가 목표다). 봇은 `tests/`를 고칠 수 없으므로(스텝 2) 봇 PR의 검사 스크립트는 main의 것과 같고, 그것은 main push에서 이미 검증됐다. 검사를 고치는 PR(`tests/` · `.github/`)은 항상 자기검사를 거친다.
- 로컬 실행(아래 「실행」)은 여전히 PR 전 1차 확인 수단이다 — CI는 같은 스크립트를 부를 뿐이다.
- 이 사실은 **여기 한 곳에만** 적는다. 다른 README·주석은 이 절을 가리킨다. 그중 배선 전 상태("CI가 아직 보지 않는다 · 실행 수단은 PR 전 로컬 실행뿐")를 적은 문장(예: `bootstrap/argocd/argocd-cm.yaml` 머리 주석의 「통제 현황(실측 2026-09-09)」)은 G2 이전의 기록이다 — 이 절이 우선한다.

| 파일 | 역할 |
|---|---|
| `validate.sh` | 검사 본체. 검사 순서·코드는 파일 머리 주석(tasks.md T033 문면 순서). sync-wave·네임스페이스·정책 세트·포트 각주·ClusterSecretStore 표는 이 파일 안의 단일 사본이 유일한 정본 사본이다 |
| `validate.tests.sh` | 자기검사. `fixtures/<case>/`마다 `validate.sh --root`를 돌려 기대 exit·메시지를 단언한다. 검사 6의 SHA 경로(merge-base ↔ HEAD · 교차 이력 · 이름 변경 · hunk 모양 · 제자리 교체 · submodule · textconv · git 밖 `--root`)와 도구 없는 PATH 케이스는 `tests/.tmp/`에 임시 git 저장소·심 디렉터리를 만들고 시작·종료 때 지운다(`.gitignore` 대상 — `--root`가 저장소 안이어야 해서 저장소 안에 둔다) |
| `fixtures/positive/` | 계약을 만족하는 최소 완전 트리(exit 0) — 새 검사를 추가하면 이 트리도 통과해야 한다 |
| `fixtures/<code>/` | 검사 항목별 부정 픽스처(각 항목이 실제로 FAIL 코드를 내는 최소 예시). 비밀처럼 보이는 값은 넣지 않는다(gitleaks 실패 케이스는 "대상 0개"로 만든다) |
| `fixtures/author/*.diff` | 검사 6(봇 작성자 경로 lint) 입력 |

## 실행

```bash
bash tests/validate.sh                 # 실제 트리(tests/ 제외). 도구 없으면 fail-closed(설치 안내 후 exit 1)
VALIDATE_SKIP_TOOLS=1 bash tests/validate.sh   # 로컬 부분 검증: 없는 도구가 필요한 검사만 SKIP(요약에 "불완전" 표시)
bash tests/validate.tests.sh           # 픽스처 자기검사(도구가 없으면 자동으로 SKIP 모드; yq는 필수)
VALIDATE_TESTS_REQUIRE_TOOLS=1 bash tests/validate.tests.sh   # CI(CI=true도 동일): 도구 누락 시 SKIP 모드로 내려가지 않고 exit 1
VALIDATE_TESTS_ONLY='^(positive|app-source-)' bash tests/validate.tests.sh   # 부분 실행: 케이스 이름이 bash 확장 정규식에 맞는 것만
PR_AUTHOR='<login>' PR_AUTHOR_ID=<id> PR_SENDER='<login>' PR_SENDER_ID=<id> VALIDATE_BASE_SHA=<base> VALIDATE_HEAD_SHA=<head> bash tests/validate.sh --only-author   # 작성자 검사(검사 6)만: 봇 판정은 작성자와 이벤트 발신자 둘 다, 도구 불필요, diff는 merge-base ↔ head, 요약 「결과(작성자 검사만 실행): …」
```

**부분 실행(`VALIDATE_TESTS_ONLY`)은 반복 작업용이다 — PR·과제 마무리 판정은 필터 없는 전체 실행으로 한다.** 필터를 주면 이름이 맞지 않는
케이스는 validate를 돌리지 않고 건너뛰며(마지막 `root-outside-repo-rejected`도 같다. 임시 git 저장소를 만드는 블록을 통째로 건너뛸 때도
그 케이스들을 건너뜀으로 센다 — 어떤 필터든 건너뜀 N + 실행 M = 전체 케이스 수), 요약 줄이
`== 자기검사 요약(부분 실행 — 필터 '<정규식>' · 건너뜀 N): M 케이스, 실패 K ==`로 바뀌어 부분 실행임을 드러낸다. 맞는 케이스가 0개이거나
정규식이 틀리면 exit 1이다(빈 실행을 통과로 읽지 않는다). 필터가 비어 있으면 출력·종료 코드는 필터가 없던 때와 같다. 케이스 이름은
`validate.tests.sh`의 `run_case` 첫 인자다(검사 코드가 아니다 — 예: `app-source-`·`rel-scoped-`·`pol-webhook-src-`·`author-`). 바꾼 검사에
걸리는 케이스와 `positive`를 함께 고르면 된다.

필요 도구: `yq`(mikefarah v4) · `kustomize` · `kubeconform` · `gitleaks` (+ `helm`은 helmCharts가 있는 kustomization에만 — 자기검사의 `fixtures/pol-port`·`fixtures/rel-scoped/{typo-key,typo-parent,cloudflared,env-vars}`는 helm과 **네트워크**(차트 pull)가 필요하다. 풀린 차트는 픽스처 아래 `charts/`에 남고 `.gitignore` 대상이다). CI(`validate.yml` — 「CI 배선 상태」)는 helm을 포함한 다섯 도구를 sha256 핀으로 설치하고, PR 이벤트에서 `PR_AUTHOR`·`PR_AUTHOR_ID`·`PR_SENDER`·`PR_SENDER_ID`·`VALIDATE_BASE_SHA`·`VALIDATE_HEAD_SHA`를 넘긴다. 자기검사를 `CI=true`(또는 `VALIDATE_TESTS_REQUIRE_TOOLS=1`)로 돌리면 helm도 도구 게이트에 들어간다 — 없으면 케이스를 돌리기 전에 exit 1이다(로컬에서 두 스위치 없이 돌리면 helm 케이스만 "도구 없음" 단언으로 바뀐다). kubeconform 스키마 캐시는 `${TMPDIR:-/tmp}/kubeconform-cache`(`VALIDATE_KUBECONFORM_CACHE`로 변경 — CI는 `$RUNNER_TEMP/kubeconform-cache`) — 저장소 밖 임시 경로이며 저장소에 파일을 남기지 않는다.

## 규칙

- `validate.sh`는 `--root` 트리(와 명시적으로 넘긴 diff 파일) 밖을 읽거나 쓰지 않고(예외: 저장소 밖 임시 경로의 kubeconform 스키마 캐시), 스크립트가 직접 임시 파일을 만들지 않으며(파이프·변수만 — 단, 검사 1의 kustomize `--enable-helm` 인플레이트가 `<kustomization>/charts/` 아래에 차트를 풀어 둔다. 빌드 산출물이며 `.gitignore` 대상이다), 자격·비밀을 요구하지 않는다.
- 검사를 추가·변경하면: 부정 픽스처 1개 + `validate.tests.sh` 단언 + `fixtures/positive/` 통과를 함께 갱신한다.
- **부분 트리 픽스처의 exit 1은 판정 근거가 아니다.** 부정 픽스처는 대개 최소 트리라 무관한 검사(5.1 POL-ns · 5.2 POL-set 등)도 FAIL해 결함이
  없어도 exit 1이다. 근거는 그 하위 검사에 **고유한** `+[FAIL] <코드> — …` 단언과, 그 그룹의 PASS 줄이 없다는 `-[PASS] <코드>` 음성 단언이다
  (검사 7.4·10의 픽스처는 모두 이 음성 단언을 건다 — 2026-09-28 검증 V-A7). 분기 하나를 지웠을 때 어떤 픽스처가 깨지는지로 단언의 고유성을 확인한다.
- 계약 표(sync-wave·네임스페이스·정책 세트·포트·ClusterSecretStore)를 바꾸면 `validate.sh`의 해당 표만 바꾼다 — 다른 곳에 중복 기재하지 않는다.
- 검사 9가 쓰는 상수(`CSS_TABLE`·`CSS_SA_NS`·`CSS_VAULT_*`·`CSS_K8S_REMOTE_NS`·`CSS_COND_TABLE`·`CSS_COND_PLATFORM_EXCLUDE`)는 5.6의 노드 주소와 **성격이 다르다.** 노드 주소는 재이미지·재조인으로 바뀌는 런타임 값이라 다섯 곳을 함께 고쳐야 하지만, 검사 9의 값은 **계약 문면**(§ClusterSecretStore 5개 표 · §이름·인증 규약)이라 계약을 고칠 때만 함께 바꾼다. 복제본은 `validate.sh`의 그 블록 하나뿐이다(store 매니페스트 자체는 검사 대상이지 사본이 아니다).
- 검사 5.6이 쓰는 노드 A 주소 2개(private `/32` · flannel 터널 장치 `/32`)는 여러 곳에 복제돼 있다. 노드 재이미지·재조인으로 값이 바뀌면 **아래 다섯 곳을 한 PR에서 함께** 바꾼다 — 아무것도 고치지 않으면 검사는 통과하면서 정책만 조용히 무력해지고, 일부만 고치면 5.6·자기검사가 FAIL한다. 이 목록은 **검사 5.6 관련 복제본**이다(private IP는 그 밖에 `allow-kube-api` 10장과 `policies-external.yaml`의 노드 IP 규칙에도 있다 — 전체는 `platform/policies/README.md` 상수 표의 "쓰이는 곳" 열을 따른다): ① `platform/policies/policies-common.yaml`의 `allow-apiserver-webhook` 4장 ② `tests/validate.sh`의 상수 `NODE_A_PRIVATE_CIDR`·`NODE_A_FLANNEL_CIDR` ③ `tests/fixtures/positive/platform/policies/policies-common.yaml`의 webhook 4장 ④ `tests/fixtures/pol-webhook-src/**`의 정책 픽스처 ⑤ `tests/validate.tests.sh`의 5.6 단언 문자열(빠짐·여분 목록).
- 계약 `network-policy.md`에는 값이 없다(자리표시자뿐) — 값이 바뀌어도 계약은 고칠 것이 없고, **메커니즘이 바뀔 때만** 모노레포에서 별도 커밋으로 고친다. 모노레포 쪽 리터럴은 private IP가 `infra/oci/instances.tf`·`infra/oci/network.tf`·`infra/bootstrap/k3s-*.sh`·`infra/cloudflare/variables.tf` 등에 있고(별도 저장소·별도 커밋 — **전수는 모노레포에서 grep**한다), flannel 값은 런북·빌드 노트의 실측 기록뿐이다(`np-set-5`는 노드 객체에서 유도하므로 바꿀 상수가 없다).
- **T047 필수 조건**(구현: `validate.yml` 스텝 2·4 — 「CI 배선 상태」): 작성자 lint(검사 6)는 PR head가 아니라 **base ref의 `tests/validate.sh`**를 **`--only-author`**로 실행한다 — `git show "<base>:tests/validate.sh" > tests/validate.base.sh && bash tests/validate.base.sh --only-author`(`<base>`는 base ref(main) 쪽 커밋 — 예: `$VALIDATE_BASE_SHA`. 같은 `tests/` 안에 두어야 저장소 루트 판정이 유지된다).
  - base 스크립트로 돌리므로 App이 같은 PR에서 스크립트를 고쳐 검사를 무력화할 수 없다(main의 규칙으로 판정한다).
  - `--only-author`라서 base 쪽 표(sync-wave 표 등)가 head 트리 전체를 판정하지 않는다 — 표와 트리를 함께 바꾸는 정상 PR이 base 표에서 FAIL하지 않는다. 이 모드는 도구를 확인하지 않고(쓰는 외부 명령은 git · bash · coreutils의 `dirname`·`tr` — `--changed-files` 인자를 쓰면 `cat`) 머리에 `모드: --only-author`, 끝에 `결과(작성자 검사만 실행): …`를 찍는다. **그 exit 0은 전체 통과가 아니다** — 전체 검사(head의 `bash tests/validate.sh`)를 따로 돌린다. `VALIDATE_ONLY_AUTHOR`는 `0`·`1`만 받고(그 밖의 값은 exit 2) 빈 문자열은 `0`(꺼짐)으로 읽는다.
  - 변경 파일 목록과 diff는 `VALIDATE_BASE_SHA`·`VALIDATE_HEAD_SHA`의 **merge-base ↔ head**로 계산한다(두 점 diff가 아니다 — PR 브랜치가 main 끝보다 뒤처져 있어도 main 쪽 변경이 섞이지 않는다). 두 값이 커밋으로 풀리지 않거나(객체 없음 · 얕은 체크아웃 · `-`로 시작) `--root`가 git 작업 트리가 아니거나 공통 조상이 없거나 **merge-base가 둘 이상이거나**(`git merge-base --all` — 교차 이력) `git diff`가 실패하면 요약 없이 끝나지 않고 `6 AUTHOR-input` FAIL(exit 1)이다 — 체크아웃은 두 커밋과 merge-base를 모두 가져와야 한다. 이 FAIL은 **봇 PR(작성자 또는 이벤트 발신자가 봇)일 때만** 난다 — 사람 작성자 + 사람 발신자는 SHA를 읽지 않고 PASS다(잘못된 SHA여도).
  - 입력 우선순위: `CHANGED_DIFF`가 있으면 SHA는 쓰이지 않는다(diff = 그 파일, 파일 목록 = `CHANGED_FILES`). `CHANGED_DIFF` 없이 `CHANGED_FILES`만 있으면 파일 목록은 그 값을 쓰고 diff만 SHA로 계산한다. **CI는 `CHANGED_FILES`·`CHANGED_DIFF`를 설정하지 않는다(빈 값으로 명시한다)** — 러너 환경에 남은 값이 SHA 계산을 대신하지 못하게.
  - 작성자는 `PR_AUTHOR`(= `pull_request.user.login`)와 `PR_AUTHOR_ID`(= `pull_request.user.id`, 인자 `--author-id`)를 함께 넘긴다. 봇 판정 = 로그인이 `VALIDATE_BOT_AUTHORS`에 있음(**대소문자 무시**) **또는** ID가 `VALIDATE_BOT_IDS`에 있음 — App 이름을 바꾸면 로그인은 바뀌지만 ID(`joshuatech-gitapp-1[bot]` = `323873425`)는 그대로다. 봇 로그인 목록의 정본은 `VALIDATE_BOT_AUTHORS` 기본값, ID 목록은 `VALIDATE_BOT_IDS` 기본값이다(둘 다 빈 값이면 기본값). `PR_AUTHOR_ID`가 숫자가 아니거나 `PR_AUTHOR` 없이 ID만 오면 `6 AUTHOR-input` FAIL, `VALIDATE_BOT_IDS`에 숫자가 아닌 원소가 있으면 인자 오류(exit 2)다.
  - **봇 판정의 대상은 작성자와 이벤트 발신자 둘 다다**(계약 gitops-repo.md): 워크플로는 `PR_SENDER`(= `sender.login`, 인자 `--sender`)와 `PR_SENDER_ID`(= `sender.id`, 인자 `--sender-id`)도 넘긴다. App은 저장소 쓰기 권한으로 **사람이 연 PR의 브랜치에 push하고 머지할 수 있다**(승인 수 0) — 작성자만 보면 그 PR은 사람 PR이라 제한 없이 통과한다. 그래서 작성자가 사람이어도 그 이벤트를 일으킨 계정(push한 쪽 · 다시 연 쪽)이 봇이면(정의는 작성자와 같다 — 로그인 대소문자 무시 또는 ID) 봇 PR로 보고, `봇 판정: 작성자 '…'는 봇 아님 · 이벤트 발신자 '…'는 봇(…)` 줄을 찍은 뒤 **봇 작성자 PR과 똑같이** PR 전체(merge-base ↔ head)가 dev digest 제자리 교체뿐이어야 한다. 사람 작성자 + 사람 발신자의 PASS 줄은 `이벤트 발신자 '…'도 봇 아님`을 적는다. `PR_SENDER_ID`가 숫자가 아니거나 `PR_SENDER` 없이 ID만 오거나, `PR_AUTHOR` 없이 발신자만 오면 `6 AUTHOR-input` FAIL이다.
  - PR 이벤트(`GITHUB_EVENT_NAME=pull_request`·`pull_request_target`, 또는 `VALIDATE_REQUIRE_AUTHOR=1`)에서 `PR_AUTHOR`가 비거나 **`PR_SENDER`가 비면** 검사 6이 FAIL이므로(메시지는 서로 다르고, 둘 다 비면 둘 다 찍는다) 반드시 넘긴다. PR 이벤트가 아니면(push 등) 발신자가 없어도 되고, PASS 줄이 `이벤트 발신자 미지정(PR 이벤트 아님) — 작성자로만 판정`으로 드러낸다.
  - **전체 검사 전에 `tests/validate.base.sh`를 지운다** — 검사 8(gitleaks 파일 스캔)은 `--root` 트리 전체(`tests/` 포함)를 훑으므로 남겨 두면 스캔 대상에 섞인다.

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
- 검사 7.4(`APP-source` — T046 · 계약 §validate.yml 4 「(T046)」 둘째 줄)가 **보는 것**: 7.1과 같은 파일 열거(실제 트리에서는
  `clusters/oci-k3s/apps/*.yaml` 21개 + `bootstrap/root-app.yaml`)에 kustomize 렌더를 더한 모든 `kind: Application`에서 `spec.source`의 키 집합이
  **정확히** `{repoURL, targetRevision, path}`(`kustomize`·`helm`·`directory`·`plugin` 등은 FAIL — `7.4 APP-source`) · `repoURL` = 이 저장소 ·
  `targetRevision: main`(`7.4 APP-source-ref`) · `spec.sources`(multi-source) 없음(`7.4 APP-source-multi`) · `spec.sourceHydrator` 없음
  (`7.4 APP-source-hydrator`) · 문서 최상위 `operation` 없음(`7.4 APP-source-operation`), 그리고 `--root` 트리(`tests/`·`charts/`·`.git/` 제외)에 `.argocd-source.yaml`·`.argocd-source-*.yaml` 파일 0개
  (`7.4 APP-source-file` — 파일 이름만 보므로 yq 없이도 돈다). 이유: 렌더를 보는 검사(3 · 5.6 · 9 · 10)는
  전부 `kustomize build <디렉터리>`를 보는데, Argo는 Application의 source로 렌더한다 — `spec.source.kustomize.patches` 한 줄이면 **적용되는 렌더 ≠
  검사한 렌더**가 되고, 그 PR은 오버라이드가 없는 트리와 똑같이 PASS했다(2026-09-28 검증 V-A2). `spec.source`를 건드리지 않는 두 경로도 같다
  (2026-09-28 재검증 RB-1 — Argo CD v3.5.2 소스 판독, 라이브 미실측): repo-server는 source 경로 안의 `.argocd-source.yaml`·`.argocd-source-<앱 이름>.yaml`을
  매 렌더마다 source 파라미터에 합치고(`kustomize`·`helm`·`directory`·`plugin`이 남는다), `spec.sourceHydrator`가 있으면 `spec.source`보다
  hydrator의 syncSource(다른 브랜치·경로)를 먼저 쓴다. Application 최상위 `operation`도 같다(2026-09-28 범위 검증 DV-1 — 같은 소스 판독,
  라이브 미실측): `operation.sync`의 `source`·`revision`·`manifests`는 **그 한 번의 동기화**가 쓰는 source를 바꾸고(`types.go`
  `SyncOperation.Source` — "overrides the source definition set in the application"), `spec` 아래만 보던 7.4는 그 트리를 PASS시켰다.
  `operation`은 Git에 선언하는 필드가 아니므로(동기화를 요청하는 쪽이 쓰고 컨트롤러가 처리한 뒤 지운다) 키가 **있기만 하면** FAIL한다.
  픽스처 `fixtures/app-source/{kustomize-patches,multi-source,ref,source-file,hydrator,operation}`.
- 검사 7.4는 **우회 경로를 전부 덮는다고 주장하지 않는다** — 아는 경로를 하나씩 막은 목록이고(검증을 돌릴 때마다 새 경로가 나왔다:
  `.argocd-source*.yaml` → `sourceHydrator` → `operation`), 전수 열거는 T047이 맡는다(CI 배선은 T047 G2 — 「CI 배선 상태」).
- 검사 7.4가 **보지 않는 것**: `spec.source.path`의 값(7.1이 이름 규약으로 본다), `project`·`destination`·`syncPolicy`(2가 SSA만 본다), 그리고 클러스터에
  이미 있는 Application이 Git과 같은지(root가 selfHeal로 되돌리지만, root 밖에서 `kubectl`로 만든 Application은 Git에 없으므로 이 검사 밖이다).
  코드로 확인한 사각: kustomization이 없는 디렉터리(root가 읽는 `clusters/oci-k3s/apps` 등)에서 **`kind: List`로 감싼 Application**(파일 단위 추출은
  최상위 문서의 kind만 본다 — Argo directory source는 List를 풀어 적용한다. kustomize 렌더는 List를 풀므로 kustomize 디렉터리는 렌더 쪽에서 보인다) ·
  **`.json`·`.jsonnet` 파일의 Application**(파일 열거는 `*.yaml`·`*.yml`뿐인데 Argo directory source는 둘도 읽는다) · ApplicationSet의 template
  (kind가 `Application`인 문서만 본다). 7.1·2는 파일만 추출하므로(렌더는 보지 않는다) `kind: List` 사각이 kustomize 디렉터리에서도 그대로다.
  **경로에 `/charts/`가 든 곳의 `.argocd-source*.yaml`**도 보지 않는다(2026-09-28 DV-5): `7.4 APP-source-file`의 파일 찾기는 기존 파일 열거와
  같은 제외 규칙(helm 캐시 `charts/`)을 쓰는데, 제외가 경로 어디에든 걸리므로 이름이 `charts`인 pod(`apps/charts/overlays/<env>`)의 source
  경로가 통째로 빠진다. 실제 트리에 그런 pod는 없다 — **T047 후보**: 제외를 kustomization 디렉터리 바로 아래 `charts/`로 좁히거나 7.1에서
  pod 이름 `charts`를 금지한다.
- 검사 6(봇 PR — 작성자 또는 이벤트 발신자가 봇)이 **막는 것**(계약 판정 규칙 ①–④):
  - 사람이 연 PR의 브랜치에 봇이 push한 경우(그 `pull_request` 이벤트의 발신자가 봇) — 작성자가 사람이어도 아래 규칙을 PR 전체(merge-base ↔ head)에 적용한다
  - 허용 파일(`apps/*/overlays/dev/kustomization.yaml`) 밖의 변경 · 파일 추가·삭제·이름/모드 변경(이름 변경 감지를 끄므로 옛 경로도 파일 목록에 나온다)
  - digest 줄 형식(`digest: sha256:<64hex>`, 목록 항목 `- digest:` 포함) 밖의 줄 변경 — `@@` 뒤 hunk 구간에서는 `+++ `·`--- `로 시작하는 줄도 내용으로 본다(내용이 `++ `·`-- `로 시작하는 줄)
  - 제자리 교체가 아닌 변경: `-` 줄 하나 바로 뒤에 `+` 줄 하나가 오는 쌍만 허용한다 — digest 줄 삭제만 · 다른 images 항목으로 옮김 · 끼워 넣기(`- digest:` 목록 항목 삽입 · 중복 키)는 줄 형식이 맞아도 FAIL. 쌍의 두 줄이 모두 digest 줄이면 64hex 밖(들여쓰기·`- `·공백)이 같아야 한다(`    digest:`를 `  - digest:`로 바꾸면 새 images 항목이 되어 원래 항목의 고정이 풀린다). `\ No newline at end of file`은 쌍 판정에서 건너뛴다
  - 교차 이력(merge-base 둘 이상 — 하나를 골라 본 diff가 실제 머지 결과와 다를 수 있다)
  - 저장소 내용·설정으로 diff 모양 바꾸기: `--no-ext-diff`(외부 diff) · `--no-textconv`(`.gitattributes` + textconv) · `--no-renames` · `--ignore-submodules=none`(`.gitmodules`의 `ignore = all`이 gitlink 변경을 숨김) · `--no-color`
- 검사 6이 **여전히 보지 않는 것**: digest 값의 진위·서명(attestation) · 교체된 digest가 어떤 이미지인지(형식이 맞는 다른 이미지의 digest로 바꿔도 PASS) · images 항목에 digest가 아예 없는 경우 — 이것은 검사 4a의 몫인데 **4a는 아직 digest를 요구하지 않는다**(있으면 형식만 보고, `name` 없는 항목은 건너뛴다). 보증은 이 줄 검사와 **트리 검사(4a 형식·kustomize build·②)의 결합**이며(CI에서는 base 스크립트의 `--only-author` 실행과 head 스크립트의 전체 실행 — 봇 PR이 `tests/validate.sh`를 고치면 base 실행이 FAIL하므로, 통과한 봇 PR에서는 두 실행의 규칙이 같다), 위 base ref 실행 조건이 함께 있어야 성립한다.
- 발신자 판정이 **여전히 막지 못하는 것**(검사 6은 이벤트 하나의 발신자만 본다 — 브랜치에 쌓인 커밋을 누가 넣었는지는 모른다):
  - **PR이 열리기 전에** 봇이 그 브랜치에 넣은 커밋 — 사람이 나중에 PR을 열면 그 이벤트(`opened`)의 발신자는 사람이라 제한 없이 통과한다. 이것은 저장소의 **브랜치 쓰기 제한 ruleset**(선언 `.github/ruleset-branches.json` — main과 `bump/**` 밖의 브랜치는 관리자만 만들고 고칠 수 있다. main은 ruleset(main)이 따로 맡는다)이 막는다. 계약이 이 빈틈을 그 ruleset에 맡긴다. App 토큰의 push가 실제로 거부되는지는 계약 「실측 범위」대로 T074·T115에서 실측한다(그때까지 "설정으로 확인 · 거부는 미실측").
  - 봇이 push한 **뒤에** 사람이 그 위에 다시 push하면 새 이벤트(`synchronize`)의 발신자는 사람이다 — 사람이 봇의 커밋을 받아서 자기 이름으로 올린 것으로 본다(그 커밋을 검토하는 책임은 사람에게 있다). 사람의 작업 브랜치(`bump/**` 밖)에서는 같은 브랜치 쓰기 제한이 봇의 첫 push부터 막는다.
- 검사 9(ClusterSecretStore)가 **보는 것**: 원본 YAML과 `kustomize build` 렌더 결과 양쪽의 **선언된 값**.
  - 9.1 위치(`platform/secret-stores/`) · `metadata.namespace` 금지 · 이름/provider 집합 = 계약 표 5개
  - 9.2 vault 4장의 `auth` 키 · `serviceAccountRef.namespace`(referent auth 차단) · `audiences` · `mountPath` · `server`/`path`/`version` · store↔SA·role 매핑
  - 9.3 kubernetes 1장의 `auth` 키 1개 · SA ns · `audiences` 금지 · CRD 기본값 3필드 명시 · `remoteNamespace`가 **정확히 `data`**(생략뿐 아니라 `default` 같은 오기도 잡는다)
  - 9.4 `conditions`가 **정확히 1항목**이고 그 키가 `namespaces` **하나**이며(`namespaceSelector`·`namespaceRegexes` 금지) 그 집합이 계약 표와 정확 일치(중복 ns도 FAIL). `vault-platform`의 12개는 `NS_TABLE`에서 `jt-dev`·`jt-prod`를 빼서 **기계 유도**하므로 목록이 두 곳에 복제되지 않는다
  - 이름 집합의 완전성은 `platform/secret-stores/` 디렉터리가 있는 트리에서만 요구한다(부분 트리 픽스처를 오탐하지 않기 위해).
- 검사 9가 **보지 않는 것**: 라이브 store의 `status`(`Ready`/`reason`/`message`), Vault role·정책의 실제 존재(그쪽은 모노레포 `infra/vault/`와 하네스 `eso-1`), `caProvider`의 `type`/`name`/`key` 값, `conditions`가 **실제로** 어느 ExternalSecret을 막았는지(라이브 `denied by spec.condition`). 특히 vault store에서 `serviceAccountRef.namespace`를 빠뜨리면 라이브는 로그인 없이 `Ready=True/reason=Valid`가 되어 **status로는 절대 드러나지 않는다** — 그 한 가지를 잡는 것이 9.2 `CSS-auth-referent`의 존재 이유이고, CRD 스키마에 필수 필드가 아니라 kubeconform으로는 잡히지 않는다.
- 검사 10(`REL` — T046 · 계약 §validate.yml 4 「(T046)」 첫째 줄)이 **보는 것**: `platform/reloader`의 `kustomize build` **렌더 하나**(경로 정확 일치).
  - 10.1 `ClusterRole`·`ClusterRoleBinding` **0**(scoped 모드의 증거)
  - 10.2 `REL-args-exact` Deployment `reloader`(ns `reloader`) 첫 컨테이너 `args`가 **정확히** `[--log-level=info, --namespaces=<REL_WATCH_NS + 릴리스 ns 사전순 쉼표 목록>, --reload-strategy=annotations]` — 원소 수·순서·값 모두(집합 비교가 아니다). 비교는 yq가 낸 **JSON 한 줄**(`to_json` — 개행·탭도 `\n` 등으로 이스케이프된다)로 하므로 개행이 든 인자 뒤의 인자도 놓치지 않는다. 정확 일치인 이유(2026-09-28 검증 — pflag v1.0.10 + Reloader v1.4.21 플래그 정의 하네스 실측): **값 없는 플래그**(`--log-format`·`--pprof-addr` 등)가 앞에 오면 pflag가 뒤의 `--namespaces=…`·`--reload-strategy=…`를 그 값으로 **삼켜** 감시 목록이 비고(전역 모드) 전략이 기본값이 되며, 같은 플래그를 반복하면 `--namespaces`는 목록이 **합쳐지고**(StringSlice) `--reload-strategy`는 마지막 값이 이긴다(StringVar). `$(VAR)`는 kubelet이 펼친 뒤 `--namespaces`를 하나 더 만들 수 있고, `--auto-reload-all=true` 같은 여분 플래그는 어노테이션 없는 워크로드까지 재시작한다 — 인자를 하나씩 세던 예전 10.2·10.3은 넷 다 PASS시켰다
  - 10.2의 **단서**: 불일치면 실제·기대 목록(JSON)을 한 줄에 찍고, 해당할 때만 같은 코드로 단서 줄을 더한다 — `'=' 없는 플래그`(다음 인자 삼킴) · `같은 플래그 2개 이상`(목록 합침 · 마지막 값) · `'$(' 든 인자`(kubelet 치환) · `cloudflared가 든 인자`(계약 위반) · `--namespaces`·`--reload-strategy` 인자 없음(전역 모드 · 기본 전략). 제어 문자가 든 인자는 **10.0 `REL-args`**로도 FAIL한다
  - 10.3 `REL-kinds` 렌더 전체의 kind별 개수 = `REL_KINDS`(ServiceAccount 1 · Deployment 1 · Role 5 · RoleBinding 5 = 12) · 그 밖의 kind 0. 감시 ns 안의 추가 Role·RoleBinding, 이름 바꾼 이미지의 두 번째 Reloader, K3s `HelmChart` CR처럼 10.2·10.4의 시야 밖에 있는 여분 객체를 개수로 잡는다
  - 10.4 `REL-rbac-ns` 렌더 전체의 `Role`·`RoleBinding`(이름 무관) ns 집합이 kind마다 `REL_WATCH_NS` + 릴리스 ns와 정확 일치 — 모노레포 하네스 `reloader-2`가 라이브 `status.resources`에서 보는 것과 같은 불변식이다(하네스는 Role `reloader-role`만 본다)
  - 10.4 `REL-rbac-bind` 모든 RoleBinding이 `roleRef.kind: Role`이고 그 이름의 Role이 **같은 ns에 렌더돼** 있으며, `subjects`가 정확히 `[ServiceAccount reloader/reloader]`(원소마다 키를 정렬한 JSON 비교). ClusterRole(예: `cluster-admin`)을 가리키거나 다른 주체를 넣는 경로는 ns 집합이 그대로라 `REL-rbac-ns`로는 보이지 않는다
  - 10.4 `REL-rbac-rules` Role `reloader-role`이 감시 ns + 릴리스 ns마다 있고 그 `rules`가 서로 같으며(다수 규칙과 다른 장만 짚는다), 렌더의 어떤 Role에도 `apiGroups`·`resources`·`verbs`에 `*`가 든 값이 없다
  - 10.4 `REL-image` 렌더 전체의 모든 `image` 키에서 저장소(태그·digest를 뗀 값)가 `…/stakater/reloader`(레지스트리 무관)인 컨테이너가 **정확히 1개**이고, 그것이 Deployment `reloader/reloader`의 `containers[0]`(10.2가 보는 자리 — 그 자리의 미끼 컨테이너가 기대 args를 가져도 여기서 걸린다)이며, 저장소가 `ghcr.io/stakater/reloader`이고 `command`가 없다(이름이 다른 두 번째 Reloader · 두 번째 컨테이너 · `command` 안의 `--namespaces=` — 2026-09-22 독립 리뷰 실측)
  - 10.0 fail-closed: 렌더 없음(kustomize build 실패 — 차트의 `fail` 가드 포함) · Deployment 부재·중복 · yq 추출 실패·형식 이상 · 저장소 루트에서 `platform/reloader` 부재. 부분 트리 픽스처에 `platform/reloader`가 없으면 "대상 없음" PASS다. Deployment가 없거나 렌더가 없으면 10.2–10.4는 돌지 않는다
  - 원본 values가 아니라 렌더를 보는 이유: 차트 기본값이 `watchGlobally: true`이고 values 스키마가 키 오타를 막지 않는다. `watchGlobaly` 한 키 오타는 차트 가드가 렌더를 멈추지만(→ 10.0), 부모 키 `reloader:` 오타처럼 두 키가 함께 빠지면 렌더는 **성공한 채** 전역 모드가 된다(→ 10.1 · 10.2 · 10.3 · 10.4 `REL-rbac-ns`·`REL-rbac-rules`).
  - 픽스처: `fixtures/rel-scoped/{typo-key,typo-parent,cloudflared,env-vars}`는 values 갈래를 실제 차트 렌더로 재현하고(helm·네트워크 필요), 나머지는 긍정 트리의 사본(`deployment.yaml`·`rbac.yaml` — `fixtures/positive/platform/reloader/`에서 `cp`)에 결함 하나를 더한 순수 매니페스트다(helm 불필요): 2026-09-22 리뷰의 `{second-deploy,command,second-container,args-newline}`, 2026-09-28 검증의 `{swallow-ns,swallow-strategy,extra-arg,var-expansion,args-order}`(10.2) · `{decoy-container,image-registry}`(10.4 REL-image의 위치·저장소 분기 — 전에는 단언이 없어 분기를 지워도 자기검사가 통과했다) · `{rb-subject,role-wildcard}`(10.4 REL-rbac-bind·rules) · `extra-kind`(10.3). 긍정 트리의 두 파일을 고치면 사본도 다시 복사한다.
- 검사 10이 **보지 않는 것**:
  - **다른 컴포넌트 렌더가 ServiceAccount `reloader/reloader`에 주는 RoleBinding·ClusterRoleBinding** — 검사 10은 `platform/reloader` 렌더만 보므로, 예컨대 `platform/cloudflared` 렌더에 그 SA를 주체로 하는 RoleBinding을 두면 Reloader가 그 ns의 Secret을 읽을 권한을 얻어도 PASS다(감시 목록은 10.2가 고정하므로 이 경로만으로 감시가 넓어지지는 않는다). **T047 후보**: 전 렌더(모든 kustomization) 교차 검사 — subjects에 `ServiceAccount reloader/reloader`가 든 RoleBinding·ClusterRoleBinding은 `platform/reloader` 렌더에만 있을 수 있다.
  - 다른 컴포넌트 렌더에 든 Reloader 이미지, `stakater/reloader`가 아닌 이름으로 다시 올린 이미지를 **같은 파드의 두 번째 컨테이너**로 넣는 경우(두 번째 Deployment로 올리면 10.3이 잡는다), 소비자 Deployment의 `reloader.stakater.com/auto` 어노테이션 유무·위치.
  - `reloader-role`의 `rules`는 **4장이 서로 같은지만** 본다(기대 규칙 상수와 대조하지 않는다) — 4장을 **똑같이** 넓힌 경우(예: 네 장 모두에 `pods/exec` create 추가)는 PASS다. 그 경우는 `platform/reloader/README.md` §1의 20줄 대조(규칙 줄 · `uniq -c`)가 잡는다.
  - 이름이 `reloader-role`이 아닌 Role의 규칙 **내용**(`reloader-metadata-role` 포함 — 와일드카드만 본다). kind별 개수와 Role·RoleBinding ns 집합을 유지한 채 `reloader-metadata-role` 한 쌍을 다른 이름의 넓은 Role·RoleBinding(주체 `reloader/reloader`)으로 바꿔 넣는 경우도 PASS다(2026-09-28 재검증 RB-4 실측). README §1의 RoleBinding 줄 대조가 잡는다.
  - 라이브: Application `status.resources`의 ClusterRole·ClusterRoleBinding 0과 Role `reloader-role` ns 집합, Deployment 인자는 모노레포 하네스 `reloader-2`가 본다. kind별 개수와 Reloader 시작 로그(실제로 감시하는 ns)는 상시 라이브 가드가 없다 — VD-9 판정 ⑥에서 한 번 실측했다(`platform/reloader/README.md` §3 판정 기록 · `reloader-2`는 개수와 로그를 보지 않는다). Argo와의 드리프트(VD-9)는 README §3. Argo가 적용하는 렌더를 validate가 빌드한 렌더와 갈라놓는 Application 쪽 경로(`spec.source` 오버라이드 키 · 다른 리비전 · multi-source · `spec.sourceHydrator` · `.argocd-source*.yaml` · 최상위 `operation`)는 7.4가 막는다 — 전부 덮는다는 주장은 아니며, 그 사각은 「검사 7.4가 보지 않는 것」.
