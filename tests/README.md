# tests/ — validate 검사 스크립트와 자기검사 (T033)

required check `validate`의 본체와 그 자기검사. 정본은 모노레포 `specs/003-platform-foundation/contracts/gitops-repo.md`(§validate.yml · §validate.yml ExternalSecret 검사 · §sync-wave 단일 표 · §이미지·승격)와 `contracts/network-policy.md`(네임스페이스 표 14개 · 정책 세트 · 외부 egress 규칙 형식 · 포트 출처 각주)다. 계약과 스크립트가 어긋나면 계약을 먼저 고친다.

| 파일 | 역할 |
|---|---|
| `validate.sh` | 검사 본체. 검사 순서·코드는 파일 머리 주석(tasks.md T033 문면 순서). sync-wave·네임스페이스·정책 세트·포트 각주 표는 이 파일 안의 단일 사본이 유일한 정본 사본이다 |
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

필요 도구: `yq`(mikefarah v4) · `kustomize` · `kubeconform` · `gitleaks` (+ `helm`은 helmCharts가 있는 kustomization에만). CI(validate.yml, T047)는 네 도구를 sha256 핀으로 설치하고 `PR_AUTHOR`·`VALIDATE_BASE_SHA`·`VALIDATE_HEAD_SHA`를 넘긴다. kubeconform 스키마 캐시는 `${TMPDIR:-/tmp}/kubeconform-cache`(`VALIDATE_KUBECONFORM_CACHE`로 변경) — 저장소 밖 임시 경로이며 저장소에 파일을 남기지 않는다.

## 규칙

- `validate.sh`는 `--root` 트리(와 명시적으로 넘긴 diff 파일) 밖을 읽거나 쓰지 않고(예외: 저장소 밖 임시 경로의 kubeconform 스키마 캐시), 저장소 안에 임시 파일을 만들지 않으며, 자격·비밀을 요구하지 않는다.
- 검사를 추가·변경하면: 부정 픽스처 1개 + `validate.tests.sh` 단언 + `fixtures/positive/` 통과를 함께 갱신한다.
- 계약 표(sync-wave·네임스페이스·정책 세트·포트)를 바꾸면 `validate.sh`의 해당 표만 바꾼다 — 다른 곳에 중복 기재하지 않는다.
- **T047 필수 조건**: 작성자 lint(검사 6)는 PR head가 아니라 **base ref의 `tests/validate.sh`**로 실행한다 — `git show "$VALIDATE_BASE_SHA:tests/validate.sh" > tests/validate.base.sh && bash tests/validate.base.sh`(같은 `tests/` 안에 두어야 저장소 루트 판정이 유지된다). 그래야 App이 같은 PR에서 스크립트를 무력화할 수 없다. PR 이벤트(`GITHUB_EVENT_NAME=pull_request`)에서 `PR_AUTHOR`가 비면 검사 6이 FAIL이므로 반드시 넘긴다.

## 한계(명시)

- 4b(platform 이미지 digest 경고)는 `image:` **스칼라 줄만** 검사한다 — helm values의 분리형 `image.repository` / `image.tag`는 보지 않는다(Renovate `pinDigests`와 컴포넌트 태스크의 수동 병기에 맡긴다).
- 검사 6(봇 작성자)은 변경 줄이 `digest: sha256:<64hex>` 형식인지만 본다(digest 값의 진위·attestation은 보지 않음). 보증은 이 줄 검사와 같은 실행의 **트리 검사(4a 형식·kustomize build·②)의 결합**이며, 위 base ref 실행 조건이 함께 있어야 성립한다.
