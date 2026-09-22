# secrets/ — 플랫폼 네임스페이스별 ExternalSecret (계약 gitops-repo.md §디렉터리·§ExternalSecret 규약)

`secrets/<ns>/` — `platform/` 경로만, store `vault-platform`. 시크릿 값은 절대 커밋하지 않는다(`ExternalSecret`만).

**누가 이 디렉터리를 클러스터에 적용하는가**: `platform/secrets/kustomization.yaml`이 `../../secrets/<ns>`를 base로 끌어가고
Application `platform-secrets`가 그것을 동기화한다. 새 ns를 추가하면 그 kustomization에 한 줄을 넣는다.
**그 kustomization이 `../../secrets/*`를 base로 가지는 유일한 파일이다**(단일 소유 — 소비자 컴포넌트에 같은 base를 넣지 않는다.
`tests/validate.sh` 검사 7.3이 정적으로 막고, 어디에도 포함되지 않은 `secrets/<ns>/`도 같은 검사가 "죽은 선언"으로 FAIL한다).
파일을 `platform/` 아래로 옮기지 않는다 — validate 3.2의 위치 판정이 `^secrets/`라 옮기는 순간 scope↔위치 검사가 **조용히 꺼진다**.

| ns | 파일 | 소비자 | creationPolicy / deletionPolicy | refresh |
|---|---|---|---|---|
| `cert-manager` | `externalsecret-cloudflare-dns-token.yaml` | ClusterIssuer letsencrypt-{staging,prod} (DNS-01) | `Orphan` / `Retain` | `Periodic` · `5m` |
| `cloudflared` | `externalsecret-cloudflared-tunnel.yaml`(G4) | Deployment cloudflared (`TUNNEL_TOKEN`, env — **컨테이너 시작 시마다** 다시 읽힌다) | `Orphan` / `Retain`(⚠ 잠금 경로) | `Periodic` · `5m` |

⚠ 둘 다 `Orphan`이다 — ownerReference를 만들지 않으므로 ExternalSecret을 지워도 Secret은 남는다. 대신 Argo의 고아 리소스
목록에 계속 뜬다(드리프트가 아니다 — AppProject `platform`의 `orphanedResources.warn: true`). `Owner`로 바꾸면 **ES가 지워지는
어떤 경로에서든**(`kubectl delete` · `Delete=false`가 빠진 Application cascade) Secret이 GC된다(`deletionPolicy: Retain`은 못
막는다) — 이 회귀는 모노레포 하네스 `eso-4`(ES spec의 Orphan/Retain/Periodic/빈 `template.metadata`/sync-options)가 본다.
**라이브 검사라 적용된 뒤에만 보이고 `agent-view`로 수동 실행한다 — 상시 감시가 아니다.** 머지 전 정적 방어선은
`../platform/secrets/README.md` §2의 yq 렌더 체크다.
⚠ 어느 정책이든 값은 Vault kv에서 덮어쓴다(`Retain`은 잘못된 값의 덮어쓰기를 막지 않는다) — 값 문제의 복구는 kv 정정이 먼저다.
**인수 뒤 토큰 회전도 kv가 먼저다**: Secret만 새 값으로 바꾸면 ESO가 다음 주기(≤5분)에 kv의 옛 값으로 되돌리고, 소비자는
그 순간 아무 신호도 내지 않는다(cert-manager는 다음 DNS-01 갱신에서야, cloudflared는 다음 **파드 교체 또는 컨테이너 재시작**에서야
드러난다). 터널 회전의 전제와 Cloudflare 쪽 순서는 `../platform/cloudflared/README.md` ⑨이 정본이다.
⚠ **ES가 매핑하지 않은 키는 인수 순간 삭제된다**(2026-09-21 DR1 드릴 실측). 인수형 ES를 새로 추가할 때는 **라이브 Secret의 키를
전부 열거**해 ES의 `data[]`에 담는다(머지 전 키 목록 확인은 `../platform/secrets/README.md` §2 — DNS는 캡처 블록,
터널은 같은 절의 사전 조건 ⓓ).
⚠ Secret이 지워졌을 때의 재생성은 **ESO·Vault가 정상일 때 다음 주기 refresh(5분)에서** 일어난다 — 즉시가 아니다
(2026-09-21 DR1 실측 302초). 터널 Secret이 그 창에 없으면 **새 컨테이너는 시작하지 못한다**(새 파드도, 제자리 재시작도
`CreateContainerConfigError`). 실행 중 컨테이너는 마지막 시작 시점의 값으로 계속 동작하므로 **재시작되지 않는 동안만**
영향이 없다 — 그 비대칭이 잠금을 늦추는 안전망이자, 잘못된 값이 조용히 숨는 이유다(env는 컨테이너 시작 시마다 다시 읽힌다).
⚠ **인수를 해제하려면**(ES는 지우고 Secret은 남기려면) 순서가 있다: revert PR 머지 → Argo에 반영됐는지 확인(Application 리비전 =
revert 커밋, 해당 ES가 `requiresPruning`) → `kubectl delete externalsecret <name>`(ESO 컨트롤러·webhook이 살아 있어야 한다) →
Secret 잔존·UID·값 확인 → 필요 시 복구 → 소비자 파드 1개씩 교체. `prune: false`라 파일만 revert하면 ES 객체가 남아 조정이 계속된다.
지금은 ES가 2장이라 **되돌릴 쪽의 그 한 줄과 그 `secrets/<ns>/`만** 지우면 된다(다른 ES의 인수는 그대로 간다).
**마지막 1장까지 지워야 할 때는 그 줄을 지우지 말고 `platform/secrets/kustomization.yaml`을 `resources: []`로 바꾼다**
(빈 `resources:`는 `kustomization.yaml is empty`로 렌더가 깨져 2단계 판정이 성립하지 않는다).
Application 파일·디렉터리·`WAVE_TABLE` 행은 유지한다.

절차의 전문(범위 · 단일 소유 · 콜드 부트스트랩 · 머지 뒤 게이트 · 되돌리기)은 `../platform/secrets/README.md`에 있다.

터널 G4의 운영자 블록 정본은 모노레포 `specs/003-platform-foundation/design/t045-blocks/g4/`의
**`g4-adopt.ps1`**(캡처·머지 대기·판정, **클러스터 쓰기 0건**) · **`g4-drill.ps1`**(값 해시·UID 재검증 뒤 파드 1개 교체) ·
**`g4-restore.ps1`**(인수 해제 뒤 값 복구)다. 머지와 드릴은 각각 사용자 입회 단계이며, adopt는 드릴을 자동 실행하지 않는다.
드릴 재실행은 옛 값을 든 커넥터의 안전망을 잃을 수 있으므로 결과를 확인하기 전에 반복하지 않는다.
