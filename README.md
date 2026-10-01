# platform-gitops

JoshuaTech v2 플랫폼의 GitOps 정본 저장소 — 클러스터(OCI K3s)가 바라보는 유일한 소스. Argo CD root app이 `clusters/oci-k3s/`를 읽는다.

- **계약(정본)**: 모노레포 `joshua92y/joshuatech_ver2` → `specs/003-platform-foundation/contracts/gitops-repo.md`. 이 저장소의 트리·Application 규약·sync-wave·ExternalSecret 규약·validate 검사 항목은 전부 그 계약을 따른다.
- 시크릿 값은 이 저장소에 없다 — `ExternalSecret`만 커밋한다(store: `vault-*` · `k8s-data-ca`).

## 변경 규칙

- **main은 PR로만** 쓴다(ruleset `main`, 커밋 사본 `.github/ruleset-main.json`). required check `validate` · `prod-approval` 둘 다 통과가 머지 조건이다(운영 overlay를 건드린 PR은 `prod-approval`이 관문 승인을 요구한다 — 「ruleset 근거」). 두 check는 `.github/workflows/validate.yml`의 job이다. `validate`는 PR에서 먼저 **main 쪽** `tests/validate.sh`를 `--only-author`로 돌려 봇 작성자 경로 lint(검사 6)를 하고, 이어 PR 쪽 `tests/validate.sh` 전체 검사(0–10) · 자기검사(`tests/validate.tests.sh`) · gitleaks 히스토리 스캔을 돌린다 — 순서와 어느 스텝이 main의 스크립트로 도는지는 `tests/README.md` 「CI 배선 상태」 한 곳에 적는다. PR 전 로컬 실행은 여전히 1차 확인 수단이다.
- **dev bump는 App auto-merge**: GitHub App `joshuatech-gitapp-1`(봇 로그인 `joshuatech-gitapp-1[bot]`)이 `apps/*/overlays/dev/kustomization.yaml`의 `images[].digest`만 바꾸는 PR(`bump/dev-<pod>-<sha7>`)을 열고 `gh pr merge --auto --squash`를 건다(VD-5).
- **prod 승격은 워크플로가 PR을 열고 사람이 승인·머지한다**(FR-038 · T047 결정 D8 2026-09-30 — 운영자가 PR을 열던 이전 형태 D1을 대체): 운영자가 `promote.yml`을 main에서 실행하면(`gh workflow run promote.yml -f pod=<pod>`) 입력 검증 → dev overlay digest 읽기 → **attestation 검증(먼저 — 실패하면 중단)** → prod overlay digest 제자리 교체 → 브랜치 `promote/prod-<pod>-<sha7>` push → PR 열기 → 브랜치 끝 확인을 전부 **워크플로 토큰(`GITHUB_TOKEN`)**으로 한다(PR 작성자 `github-actions[bot]`). App 토큰을 쓰지 않으므로 이 저장소에는 App 자격이 없다. 워크플로 토큰이 연 PR의 검사 실행은 **승인 대기**로 만들어지고, 승격 PR은 운영 overlay를 건드리므로 **승인 관문**(required check `prod-approval`)을 지나야 머지된다 — 승격마다 운영자가 하는 일: 승격 실행 · 검사 실행 승인 · 렌더링 diff 코멘트 확인(`validate.yml`의 job `render-diff` · `render-comment`가 PR마다 하나를 갱신한다 — 코멘트가 없거나 실패했거나 코멘트의 PR head가 최신 커밋이 아니면 머지하지 않는다) · 관문 승인 · 머지. auto-merge는 걸지 않는다. App 토큰으로 열지 않는 이유 — 작성자가 봇이라 검사 6(봇은 `overlays/dev`만)에 걸리고, lint를 넓히면 토큰이 탈취됐을 때 prod가 사람 없이 머지된다. 흐름 ①–⑦과 남는 틈은 `promote.yml` 머리 주석, 배선과 관문 판정은 `tests/README.md` 「CI 배선 상태」.

## ruleset 근거 (JSON은 주석이 불가능하므로 여기에 기록)

`.github/ruleset-main.json` — 적용 대상 `~DEFAULT_BRANCH`(= main):

- `pull_request`, `required_approving_review_count: 0` — 1인 운영이므로 PR 승인 수는 0. 게이트는 PR 승인이 아니라 required check 둘 — `validate`와 `prod-approval`(둘 다 strict: 브랜치가 main 최신이어야 함)이다. 그 check가 무엇을 돌리는지는 위 「변경 규칙」 · `tests/README.md` 「CI 배선 상태」.
- `bypass_actors: []` — GitHub App 포함 누구도 우회 불가. App 토큰이 탈취돼도 main 직접 push는 불가능하고 PR + `validate` 경유만 가능하다(추가로 `validate`의 첫 검사 스텝이 **main 쪽** `tests/validate.sh`를 `--only-author`로 돌려, `joshuatech-gitapp-1[bot]`(로그인 또는 계정 ID로 판정) PR의 dev digest 외 변경을 거부한다 — PR 쪽 코드가 돌기 전에 main의 규칙으로 판정하므로 같은 PR이 검사를 고쳐 끌 수 없다. App에는 `workflows` 권한이 없어 워크플로 파일도 못 바꾼다 — `tests/README.md` 「CI 배선 상태」).
- `required_status_checks`의 `integration_id: 15368`(T047) — required check 둘(`validate` · `prod-approval`)의 **출처를 GitHub Actions로 고정**한다. 없으면 이름만 같은 check·commit status는 어떤 App이 만든 것이든 조건을 채운다. 15368은 GitHub Actions App의 ID다(PR의 check run `app.id`로 확인 — `gh api repos/joshua92y/platform-gitops/commits/<sha>/check-runs`).
- `required_status_checks`의 `prod-approval`(T047 G5 · 결정 D7) — **승인 관문**. 운영 overlay(`apps/*/overlays/prod/**`)를 건드린 PR은 `validate.yml`의 job `gate`가 Environment `production`(필수 검토자 = 운영자)의 승인을 받아야 `prod-approval`이 성공한다 — 승인 전에는 이 check가 보고되지 않아 머지가 막히고, 거절하면 실패한다. 승인 수 0 · bypass 없음인 이 ruleset에서 **App 토큰이 스스로 채울 수 없는 조건**이다(Environment의 검토자는 사용자 · 팀만 될 수 있다 — 문서 근거이고, App 토큰으로 승인 API를 부르는 실측은 T115). 운영 overlay를 건드리지 않은 PR(봇의 dev bump 포함)은 승인 없이 성공한다. 범위는 운영 overlay뿐이다 — 플랫폼 · 검사 · 문서 변경 PR은 관문 밖이다(D7 — 받아들인 위험). 판정 규칙은 `tests/README.md` 「CI 배선 상태」.
- `non_fast_forward` + `deletion` — main 히스토리 재작성·브랜치 삭제 금지.
- `required_linear_history` + `pull_request.allowed_merge_methods: ["squash"]`(T047) — main에 머지 커밋이 들어오지 못한다. auto-merge의 방식은 거는 쪽이 고르므로, 막지 않으면 App 토큰을 가진 쪽이 `--merge`로 이력을 교차시킬 수 있다. 교차한 이력에서는 merge-base가 둘 이상이 되어 검사 6(경로 lint)의 diff 기준이 흔들린다 — 검사 6도 merge-base가 하나가 아니면 FAIL한다(이중 방어 · `tests/README.md` 「T047 필수 조건」). 2026-09-29까지의 머지는 전부 squash였다.
- **이 파일을 고치는 것만으로는 적용되지 않는다.** PR이 머지된 뒤 운영자가 `gh api -X PUT repos/joshua92y/platform-gitops/rulesets/22066865 --input .github/ruleset-main.json`으로 적용하고, `gh api repos/joshua92y/platform-gitops/rulesets/22066865`의 출력과 규칙 의미로 대조한다(ruleset `main` = 22066865 — `gh api repos/joshua92y/platform-gitops/rulesets`로 확인). 서버 기본값 필드(`require_extra_approval_for_unattributed_changes` · `do_not_enforce_on_create` · `required_reviewers`)가 PUT 뒤에 어떻게 됐는지도 본다(이 파일에 없는 필드다 — 2026-09-30 원격 값은 차례로 `true` · `false` · `[]`). `prod-approval`을 더해 적용한 뒤에는 운영 overlay를 건드린 PR로 「승인 전 머지 거부 · 승인 뒤 머지」를 한 번 잰다(계약 §validate.yml 8).
- 서버 사본은 기본값 필드(require_extra_approval_for_unattributed_changes · required_reviewers 등)를 추가 저장하므로 API 출력과 `.github/ruleset-main.json`은 1:1로 일치하지 않는다 — 비교는 규칙 의미로.
- 저장소 설정 **Allow auto-merge 활성** — dev bump PR의 auto-merge 전제(VD-5: 첫 PR에서 실측 확정).

`.github/ruleset-branches.json`(T047 · G5에서 `promote/**` 추가) — 적용 대상 **main과 `bump/**` · `promote/**`를 뺀 모든 브랜치**:

- `creation` + `update` + `deletion` 제한, bypass는 저장소 관리자 역할(`RepositoryRole` 5)뿐 — **App과 워크플로의 `GITHUB_TOKEN`은 `bump/**` · `promote/**`만 만들고 고칠 수 있다.** 사람이 작업하는 브랜치에는 push하지 못한다.
- 왜 필요한가: App은 저장소에 쓰기 권한이 있어, 막지 않으면 **사람이 연 PR의 브랜치에 커밋을 push하고 머지할 수 있다**(승인 수 0 · 머지 API와 auto-merge 둘 다). 검사 6이 PR 작성자만 보던 때에는 그 PR이 사람 PR이라 제한 없이 통과했다. 지금은 검사 6이 이벤트 발신자도 보지만(봇이 push한 커밋이 head인 상태로는 통과하지 못한다), PR이 열리기 **전에** 봇이 그 브랜치에 넣은 커밋은 발신자로 보이지 않는다 — 그 빈틈을 이 ruleset이 막는다(이중 방어).
- main을 대상에서 뺀 이유: 머지는 main의 갱신이다. main을 넣으면 봇의 dev bump 머지가 갱신 제한에 걸린다. main은 `ruleset-main.json`이 맡는다.
- `promote/**`를 뺀 이유(T047 결정 D8 · 2026-09-30 운영자 적용 — 원격 값이 정본이고 이 파일은 그것에 맞춘 선언이다): **워크플로 토큰**(`promote.yml`)이 승격 브랜치를 만들 수 있게 하려는 것이다. GitHub Actions만 쓸 수 있는 이름 공간을 만들려고 GitHub Actions를 우회 주체로 한 전용 ruleset을 시도했으나 개인 계정 저장소에서 **거부됐다**(2026-09-30 실측 — 422 `Actor GitHub Actions integration must be part of the ruleset source or owner organization`). 그래서 이 이름 공간은 App도 쓸 수 있다. 틈을 좁히는 것: `promote.yml`의 브랜치 끝 확인(⑦ — PR을 연 직후 원격 브랜치의 끝이 자기가 올린 커밋이 아니면 PR을 닫고 브랜치를 지운 뒤 실패) · 발신자 판정(PR이 열린 뒤 App이 push하면 검사 6이 봇 규칙으로 판정 → 운영 overlay 변경은 실패) · 승인 관문(`prod-approval`). 남는 틈(받아들인 위험 — 모노레포 `report.md`): 워크플로가 브랜치를 올리고 PR을 열어 ⑦로 확인하기까지 몇 초 사이에 App 토큰으로 커밋을 끼워 넣는 것. 승격 PR에 다른 커밋이 들어오면(발신자가 App이라 `validate`가 실패한다) PR을 닫고 다시 열지 말고 브랜치를 지운다 — 다시 열면 발신자가 사람이 되어 App의 커밋이 사람 규칙으로 검사된다.
- 새 자동화가 브랜치를 만들어야 하면(Renovate 등) 계약을 먼저 고치고 이 파일의 `exclude`에 패턴을 더한다(`promote/**`도 그렇게 더했다).
- 적용(운영자 · 처음 한 번은 생성): `gh api -X POST repos/joshua92y/platform-gitops/rulesets --input .github/ruleset-branches.json`. 이후 갱신은 `gh api -X PUT repos/joshua92y/platform-gitops/rulesets/24166519 --input .github/ruleset-branches.json`(ruleset `branches` = 24166519).
- **실측 범위**: 관리자의 push가 통과하는 것과 브랜치 이름별 적용 규칙(`gh api repos/joshua92y/platform-gitops/rules/branches/<브랜치>`)은 적용 직후 확인한다. App 토큰의 push가 **실제로 거부되는 것**은 App 키가 있어야 시험할 수 있다 — 첫 dev bump(T074)와 승격 실연(T115)에서 증거를 남긴다. 그때까지는 "설정으로 확인 · 거부는 미실측"이다.

## 뼈대 상태 (T003)

지금은 계약 §디렉터리 트리의 빈 뼈대만 있다(빈 kustomization.yaml·README). 실제 매니페스트·validate 검사는 모노레포 `tasks.md`의 T031 이후 태스크가 작성한다.
