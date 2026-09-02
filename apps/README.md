# apps/ — pod 배포 매니페스트 (계약 gitops-repo.md §디렉터리·§이미지·승격)

`<pod>/base/` + `<pod>/overlays/{dev,prod}/`. overlays의 `images:`는 `newName: ghcr.io/joshua92y/<pod>` + `digest: sha256:…`만 — 태그 금지, `newTag`가 있으면 validate 실패. base의 Ingress host는 `PLACEHOLDER.joshuatech.dev`. 실제 매니페스트는 T031+에서 작성한다.
