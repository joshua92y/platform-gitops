# platform-gitops

JoshuaTech v2 플랫폼의 GitOps 정본 저장소 — 클러스터(OCI K3s)가 바라보는 유일한 소스. Argo CD root app이 `clusters/oci-k3s/`를 읽는다.

- **계약(정본)**: 모노레포 `joshua92y/joshuatech_ver2` → `specs/003-platform-foundation/contracts/gitops-repo.md`. 이 저장소의 트리·Application 규약·sync-wave·ExternalSecret 규약·validate 검사 항목은 전부 그 계약을 따른다.
- 시크릿 값은 이 저장소에 없다 — `ExternalSecret`만 커밋한다(store: `vault-*` · `k8s-data-ca`).

## 변경 규칙

- **main은 PR로만** 쓴다(ruleset `main`, 커밋 사본 `.github/ruleset-main.json`). required check `validate` 통과가 머지 조건이다.
- **dev bump는 App auto-merge**: GitHub App `joshuatech-gitapp-1`(봇 로그인 `joshuatech-gitapp-1[bot]`)이 `apps/*/overlays/dev/kustomization.yaml`의 `images[].digest`만 바꾸는 PR(`bump/dev-<pod>-<sha7>`)을 열고 `gh pr merge --auto --squash`를 건다(VD-5).
- **prod 승격은 사람 머지**(FR-038): `promote.yml`은 PR을 열기만 하고 auto-merge를 걸지 않는다 — 운영자가 렌더링 diff 코멘트를 확인하고 직접 머지한다.

## ruleset 근거 (JSON은 주석이 불가능하므로 여기에 기록)

`.github/ruleset-main.json` — 적용 대상 `~DEFAULT_BRANCH`(= main):

- `pull_request`, `required_approving_review_count: 0` — 1인 운영이므로 승인 수는 0. 게이트는 승인이 아니라 required check `validate`(strict: 브랜치가 main 최신이어야 함)다.
- `bypass_actors: []` — GitHub App 포함 누구도 우회 불가. App 토큰이 탈취돼도 main 직접 push는 불가능하고 PR + `validate` 경유만 가능하다(추가로 validate의 `joshuatech-gitapp-1[bot]` 경로 lint가 dev digest 외 변경을 거부한다 — T033).
- `non_fast_forward` + `deletion` — main 히스토리 재작성·브랜치 삭제 금지.
- 저장소 설정 **Allow auto-merge 활성** — dev bump PR의 auto-merge 전제(VD-5: 첫 PR에서 실측 확정).

## 뼈대 상태 (T003)

지금은 계약 §디렉터리 트리의 빈 뼈대만 있다(빈 kustomization.yaml·README). 실제 매니페스트·validate 검사는 모노레포 `tasks.md`의 T031 이후 태스크가 작성한다.
