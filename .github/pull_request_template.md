<!-- 머지 전 확인(계약 gitops-repo.md §validate.yml 8 · §변경 권한). 해당 없는 항목은 지우지 말고 "해당 없음"을 적는다. -->
<!-- 봇의 dev bump PR과 promote.yml의 승격 PR은 이 템플릿을 쓰지 않는다(본문을 직접 준다). -->

## 확인

- [ ] 렌더링 diff 코멘트를 확인했다 — 코멘트 머리의 PR head가 이 PR의 최신 커밋이다(코멘트가 없거나 `render-diff`가 실패했으면 머지하지 않는다)
- [ ] 운영 overlay(`apps/*/overlays/prod/**`)를 건드렸으면 승인 관문(`prod-approval` — `gate` job · Environment `production`)의 승인을 받았다
- [ ] 비가역 파일(오퍼레이터 차트 · `Kafka` · `Cluster` · `metadataVersion` · PG major · Authentik 차트)을 건드렸으면 스냅샷 3종(Vault raft · CNPG 백업 · K3s SQLite)을 확인했다
- [ ] `platform/` · `clusters/` 변경이면 k8s-security 경계 리뷰(approval-review) 대상임을 안다
