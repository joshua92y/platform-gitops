# platform-gitops

JoshuaTech v2 플랫폼의 GitOps 정본 저장소 — 클러스터(OCI K3s)가 바라보는 유일한 소스. Argo CD root app이 `clusters/oci-k3s/`를 읽는다.

- **계약(정본)**: 모노레포 `joshua92y/joshuatech_ver2` → `specs/003-platform-foundation/contracts/gitops-repo.md`. 이 저장소의 트리·Application 규약·sync-wave·ExternalSecret 규약·validate 검사 항목은 전부 그 계약을 따른다.
- 시크릿 값은 이 저장소에 없다 — `ExternalSecret`만 커밋한다(store: `vault-*` · `k8s-data-ca`).

## 변경 규칙

- **main은 PR로만** 쓴다(ruleset `main`, 커밋 사본 `.github/ruleset-main.json`). required check `validate` 통과가 머지 조건이다. ⚠ **그 check가 오늘 실제로 보는 것은 gitleaks뿐이다** — `tests/validate.sh`(검사 0–9)를 CI가 부르는 것은 **T047** 뒤이고, 그때까지 강제 수단은 PR 전 로컬 실행과 리뷰다(`tests/README.md` 「CI 배선 상태」).
- **dev bump는 App auto-merge**: GitHub App `joshuatech-gitapp-1`(봇 로그인 `joshuatech-gitapp-1[bot]`)이 `apps/*/overlays/dev/kustomization.yaml`의 `images[].digest`만 바꾸는 PR(`bump/dev-<pod>-<sha7>`)을 열고 `gh pr merge --auto --squash`를 건다(VD-5).
- **prod 승격은 사람이 PR을 열고 사람이 머지한다**(FR-038 · T047 결정): `promote.yml`(T047에서 작성 — 지금은 없음)은 attestation을 검증한 뒤 **브랜치만 만든다**. PR은 운영자가 열고, 렌더링 diff 코멘트를 확인한 뒤 직접 머지한다. 워크플로가 PR을 열지 않는 이유 — App 토큰으로 열면 작성자가 봇이라 검사 6(봇은 `overlays/dev`만)에 걸리고, `GITHUB_TOKEN`으로 열면 워크플로가 일어나지 않아 required check가 보고되지 않는다.

## ruleset 근거 (JSON은 주석이 불가능하므로 여기에 기록)

`.github/ruleset-main.json` — 적용 대상 `~DEFAULT_BRANCH`(= main):

- `pull_request`, `required_approving_review_count: 0` — 1인 운영이므로 승인 수는 0. 게이트는 승인이 아니라 required check `validate`(strict: 브랜치가 main 최신이어야 함)다. ⚠ 그 check의 **오늘 내용은 gitleaks뿐**이다(위 「변경 규칙」 첫 줄 · `tests/README.md` 「CI 배선 상태」) — 검사 본체의 CI 배선은 T047이다.
- `bypass_actors: []` — GitHub App 포함 누구도 우회 불가. App 토큰이 탈취돼도 main 직접 push는 불가능하고 PR + `validate` 경유만 가능하다(추가로 `tests/validate.sh` 검사 6의 `joshuatech-gitapp-1[bot]` 경로 lint가 dev digest 외 변경을 거부한다 — T033이 **스크립트에** 구현했고 **CI 배선은 T047**이다. 그전까지 이 lint는 자동으로 돌지 않는다 — `tests/README.md` 「CI 배선 상태」).
- `non_fast_forward` + `deletion` — main 히스토리 재작성·브랜치 삭제 금지.
- `required_linear_history` + `pull_request.allowed_merge_methods: ["squash"]`(T047) — main에 머지 커밋이 들어오지 못한다. auto-merge의 방식은 거는 쪽이 고르므로, 막지 않으면 App 토큰을 가진 쪽이 `--merge`로 이력을 교차시킬 수 있다. 교차한 이력에서는 merge-base가 둘 이상이 되어 검사 6(경로 lint)의 diff 기준이 흔들린다 — 검사 6도 merge-base가 하나가 아니면 FAIL한다(이중 방어 · `tests/README.md` 「T047 필수 조건」). 2026-09-29까지의 머지는 전부 squash였다.
- **이 파일을 고치는 것만으로는 적용되지 않는다.** PR이 머지된 뒤 운영자가 `gh api -X PUT repos/joshua92y/platform-gitops/rulesets/<id> --input .github/ruleset-main.json`으로 적용하고, `gh api repos/joshua92y/platform-gitops/rulesets/<id>`의 출력과 규칙 의미로 대조한다(`<id>`는 `gh api repos/joshua92y/platform-gitops/rulesets`).
- 서버 사본은 기본값 필드(require_extra_approval_for_unattributed_changes · required_reviewers 등)를 추가 저장하므로 API 출력과 `.github/ruleset-main.json`은 1:1로 일치하지 않는다 — 비교는 규칙 의미로.
- 저장소 설정 **Allow auto-merge 활성** — dev bump PR의 auto-merge 전제(VD-5: 첫 PR에서 실측 확정).

## 뼈대 상태 (T003)

지금은 계약 §디렉터리 트리의 빈 뼈대만 있다(빈 kustomization.yaml·README). 실제 매니페스트·validate 검사는 모노레포 `tasks.md`의 T031 이후 태스크가 작성한다.
