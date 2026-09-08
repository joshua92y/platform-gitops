# apps/ — Application 1개/컴포넌트, app-of-apps (계약 gitops-repo.md §디렉터리·§Application 규약)

이름 규약 `platform-<component>` · `<pod>-<env>`. sync-wave는 계약 §sync-wave 단일 표가 정본(T041에서 어노테이션으로 작성). 표에 없는 디렉터리를 만들면 validate가 실패한다.

project: 플랫폼 컴포넌트 → `platform`, 앱 → `dev`·`prod`, `platform/policies/tests/` 검사 Job → `tests`(정의는 `../projects/`). root Application 자신도 T041 PR-A에서 `default` → `platform`으로 옮겼다 — `default`는 봉인되어 어떤 Application도 쓸 수 없다.
