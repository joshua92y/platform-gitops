# platform/cloudflared/ — 운영자 절차 (T039)

Cloudflare 터널 커넥터(`joshuatech-tunnel`)의 클러스터 쪽 배포. 터널 ingress 3개(`ssh-a` → 노드 A 22 · `ssh-b` → 노드 B 22 ·
`k8s` → K3s API(svc `kubernetes.default` 443 → targetPort 6443))와 Access 앱은 OpenTofu `infra/cloudflare/`(T011)가 소유하고,
이 디렉터리는 **커넥터 Deployment만** 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `namespace: cloudflared` + `deployment.yaml`. 이 디렉터리가 만들지 않는 것(ns·Application·Secret)의 경계가 머리 주석에 있다 |
| `deployment.yaml` | replica 2(노드 A·B 각 1, required anti-affinity), 이미지 digest 핀, `TUNNEL_TOKEN` secretKeyRef, restricted securityContext |

- **이 저장소에 비밀은 없다.** 터널 토큰은 Vault `kv/platform/cloudflare/tunnel`(필드 `token`)과 운영자 비밀번호 관리자에만 있다 —
  T045 G4부터 라이브 Secret의 관리 주체는 ExternalSecret이다(⑨).
- 순서: ① ns 수동 생성 → ② Secret 수동 생성 → ③ 수동 apply → **(터널 동작 확인)** → ⑤⑥ 워크스테이션 접속 전환 → ⑧ 임시 22 규칙 제거 →
  (T041) ④ Argo CD 인수 확인 → (T045) ⑨ ExternalSecret 인수. ⑦은 세션마다 반복한다.

---

## ① 네임스페이스 수동 생성 + PSA 라벨 (T039 시점)

`platform/policies/`(T041)가 아직 없으므로 네임스페이스는 운영자가 만든다. **라벨 값은 계약
(`contracts/network-policy.md` 네임스페이스 표)과 정확히 같아야** T041에서 Argo CD가 서버사이드 적용(SSA)으로
충돌 없이 인수한다(같은 값이면 필드 소유권이 공유로 넘어가고, 값이 다르면 conflict가 난다).

```bash
kubectl create namespace cloudflared
kubectl label namespace cloudflared --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

# 확인 — 세 라벨이 모두 restricted
kubectl get namespace cloudflared -o jsonpath='{.metadata.labels}'; echo
```

## ② 최초 Secret 수동 생성 (값은 저장소에 없다)

⚠ **이 절차는 콜드 부트스트랩과 인수 해제 뒤 복구 전용이다 — T045 G4 인수 뒤의 토큰 회전에는 쓰지 않는다.**
Secret만 새 값으로 바꾸면 ESO가 ≤5분 안에 kv의 옛 값으로 되돌린다. 회전은 ⑨(kv 정정 → ESO 반영 확인 → 파드 1개씩 교체).

Secret `cloudflared-tunnel`, 키 `TUNNEL_TOKEN`(=`deployment.yaml`의 `secretKeyRef`). 값은 비밀번호 관리자의 터널 실행 토큰.

**금지**: `--from-literal=TUNNEL_TOKEN=<값>`(토큰이 명령줄 → 셸 히스토리와 `ps` 출력에 남는다) ·
`--dry-run=client -o yaml > secret.yaml`(평문 파일 생성 → 커밋 사고) · 토큰을 채팅·이슈·로그에 붙여넣기.
**주의**: 끝에 개행이 붙으면 인증이 실패한다 — 아래 두 방법 모두 개행 없이 기록한다.

### 워크스테이션(Windows/PowerShell) — 기본 경로, 임시 파일 없음

파이프로만 넘기므로 토큰이 디스크에 닿지 않는다. `apply --server-side`라 재실행해도 멱등이고,
`last-applied-configuration` 어노테이션(토큰 사본)이 생기지 않는다.
⚠ T045 G4 뒤에는 이 절차가 **회전 수단이 아니다** — Secret만 바꾸면 ESO가 ≤5분 안에 kv 값으로 되돌린다.
회전은 ⑨의 순서(kv 먼저)를 따르고, 이 절차는 콜드 부트스트랩과 인수 해제(⑨ · `../secrets/README.md` §5) 뒤 복구에만 쓴다.

```powershell
Set-PSReadLineOption -HistorySaveStyle SaveNothing      # 이 세션 히스토리 저장 끄기
$sec  = Read-Host -AsSecureString 'TUNNEL_TOKEN 붙여넣기(화면에 표시되지 않음)'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
           [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)))   # 개행 없음
  @"
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel
  namespace: cloudflared
type: Opaque
data:
  TUNNEL_TOKEN: $b64
"@ | kubectl apply --server-side --field-manager=operator-bootstrap -f -
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $b64 = $null; $sec = $null; [GC]::Collect()
}
```

### 노드 셸(Linux)에서 할 때만

**Git Bash에서는 쓰지 말 것** — MSYS가 `/dev/stdin`을 `/proc/self/fd/0`으로 바꿔 네이티브 `kubectl.exe`가 열지 못한다(재현 확인).
Windows에서는 위 PowerShell 경로만 쓴다.

```bash
read -rs TUNNEL_TOKEN     # 입력은 화면에도 히스토리에도 남지 않는다(read는 셸 빌트인)
printf '%s' "$TUNNEL_TOKEN" | kubectl create secret generic cloudflared-tunnel -n cloudflared \
  --from-file=TUNNEL_TOKEN=/dev/stdin
unset TUNNEL_TOKEN
```

값을 출력하지 않는 확인(키 이름만 본다):

```bash
kubectl -n cloudflared get secret cloudflared-tunnel -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# → TUNNEL_TOKEN
```

## ③ 매니페스트 수동 apply (T041 전까지)

Argo CD Application `platform-cloudflared`는 T041 산출물이므로, 그 전까지는 운영자가 직접 적용한다.
**이 매니페스트가 PR로 main에 머지된 뒤**, main을 최신화한 로컬 클론에서 실행한다(브랜치 상태를 클러스터에 넣지 않는다).

```bash
REPO=<platform-gitops 로컬 클론 절대 경로>       # 예: D:/code/platform-gitops
git -C "$REPO" checkout main && git -C "$REPO" pull --ff-only
kubectl apply -k "$REPO/platform/cloudflared"    # cwd와 무관하게 명시 경로로

kubectl -n cloudflared rollout status deploy/cloudflared --timeout=180s
kubectl -n cloudflared get pods -o wide          # pod 2개, NODE 열이 서로 달라야 한다(노드 A·B)
kubectl -n cloudflared logs deploy/cloudflared --tail=50 | grep -i 'Registered tunnel connection'
```

Cloudflare 대시보드(Zero Trust → Networks → Tunnels)에서 커넥터 2개가 HEALTHY인지도 함께 본다.
그다음 터널 경로 자체를 확인한다 — ⑤의 SSH·kubeconfig가 실제로 동작해야 ⑧(임시 22 규칙 제거)로 넘어갈 수 있다.

기동 로그의 `ICMP proxy feature is disabled` WARN은 **정상**이다 — `capabilities.drop: [ALL]` + 비루트라 ICMP 소켓을 열 수 없어서
나는 경고이며, `ssh-a`·`ssh-b`·`k8s`(TCP) 터널 기능과는 무관하다.

## ④ T041 인수 확인 (Argo CD가 수동 적용분을 넘겨받았는가)

T041이 `platform/policies/`(ns·PSA 라벨)와 `clusters/oci-k3s/apps/platform-cloudflared.yaml`(Application,
project `platform`, path `platform/cloudflared`, destination ns `cloudflared`, sync-wave·syncOptions는 계약 §sync-wave 단일 표와
§Application 규약)을 추가한 뒤:

```bash
kubectl get namespace cloudflared -o jsonpath='{.metadata.labels}'; echo          # ①과 같은 값
kubectl -n argocd get app platform-cloudflared \
  -o jsonpath='{.status.sync.status} {.status.health.status}'; echo               # Synced Healthy
kubectl -n cloudflared get deploy cloudflared \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager}/{.operation}{"\n"}{end}'
kubectl -n cloudflared get deploy cloudflared \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'; echo
```

- **신뢰 판정은 managedFields다**: Argo CD 컨트롤러의 `Apply` 항목이 spec을 소유하면 인수된 것이다.
  `last-applied-configuration` 어노테이션은 **남아 있을 수 있다** — SSA는 다른 매니저가 쓴 필드를 지우지 않는다. 남았다고 실패가 아니다.
- 어노테이션이 남았거나 Argo CD가 field conflict를 보고하면 1회만 마이그레이션한다(이것이 정상 절차다):
  `kubectl apply --server-side --force-conflicts -k "$REPO/platform/cloudflared"` → Argo CD 재Sync → 위 4개 명령 재확인.

## ⑤ 워크스테이션 접속 전환 (SSH ProxyCommand · kubeconfig)

SSH 키는 `joshuatech-ops`(FIDO2 또는 passphrase + `ssh-add -c`).
설계 문서의 `jt-ops` 표기를 이 실명으로 읽는 **이름 예외의 기록처는 모노레포 `docs/runbooks/bootstrap.md` §0**이다.
`~/.ssh/config`(Windows는 `%USERPROFILE%\.ssh\config`):

```sshconfig
Host ssh-a ssh-b
  HostName %h.joshuatech.dev
  User ubuntu
  IdentityFile ~/.ssh/joshuatech-ops
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
```

- Windows에서 `cloudflared.exe`가 PATH에 없으면 ProxyCommand에 절대 경로를 적는다(공백 없는 경로 권장).
- passphrase 키는 `ssh-add -c ~/.ssh/joshuatech-ops`로 올려 사용마다 확인 프롬프트를 받는다.
- 첫 접속에서 브라우저가 열리고 Access 앱 `ssh`(GitHub IdP, `session_duration` 1h)를 통과해야 한다.
- **GitHub IdP 앱 권한(현행 = GitHub App `joshuatech-cf-access`)**: GitHub App이면 **Account permissions → Email addresses: Read-only가 필수**다.
  없으면 Access가 `GET https://api.github.com/user/emails` **403**을 받아 "Authentication error — Failed to fetch user/group information"으로
  로그인이 실패한다(2026-09-07 실측; Zero Trust → Settings → Authentication의 IdP "Test"로 재현된다).
- 확인: `ssh ssh-a hostname` → `joshtech-api` · `ssh ssh-b hostname` → `joshtech-cache`(호스트 키 지문은 기존 known_hosts의 노드 항목과 같아야 한다).

K8s API는 로컬 리스너로 받는다(`k8s` Access 앱):

```bash
cloudflared access tcp --hostname k8s.joshuatech.dev --url 127.0.0.1:6443    # 세션 동안 켜 둔다
```

부트스트랩 창에서 쓰던 SSH 로컬 포워딩(`ssh -L 6443:127.0.0.1:6443`)을 **먼저 끊어야** 같은 포트를 쓸 수 있다.
포트를 6443으로 맞추는 이유: T035에서 받아 둔 admin kubeconfig의 `server: https://127.0.0.1:6443`을 그대로 쓰기 위해서다
(포트를 바꾸면 kubeconfig를 매번 고쳐야 한다).

- 리스너가 실제로 떠 있는지 먼저 본다: `Test-NetConnection 127.0.0.1 -Port 6443`(True) + 6443을 잡은 프로세스가 `cloudflared`인지.
  리스너 없이 `kubectl`을 치면 전부 connection refused다(2026-09-07 ②에서 실제로 겪음 — 적용 0건).
- **새 창에서는 `$KC`(kubeconfig 경로 변수)를 다시 정의**한다 — PowerShell 세션 변수는 창마다 사라진다. `kubectl --kubeconfig $KC …`가
  빈 값으로 실행되면 기본 kubeconfig로 떨어져 엉뚱한 컨텍스트를 볼 수 있다.

kubeconfig의 cluster 항목(운영자 admin kubeconfig · 에이전트/tester/CI의 `agent-view` 토큰 kubeconfig 모두 같은 형태):

```yaml
clusters:
  - name: oci-k3s
    cluster:
      server: https://127.0.0.1:6443
      tls-server-name: kubernetes      # 로컬 리스너 주소가 아니라 API 서버 인증서의 이름으로 검증한다
      certificate-authority-data: <K3s CA — 비밀 아님>
```

- 운영자 = admin kubeconfig(`/etc/rancher/k3s/k3s.yaml`, **비밀번호 관리자에만** 보관).
- 에이전트·tester·CI = `kubectl create token agent-view -n kube-system --duration=8h`로 만든 단명 토큰 kubeconfig. admin kubeconfig를 이들에게 주지 않는다.

## ⑥ 워크스테이션 cloudflared 클라이언트는 2026.8.3 유지 (2026.5.1 핀은 VD)

운영자 워크스테이션의 클라이언트는 **설치된 2026.8.3(MSI, `C:\Program Files (x86)\cloudflared`)을 그대로 쓴다**(2026-09-07 결정).
클러스터 안 daemon도 이 저장소의 2026.8.3(digest 핀)이다.

- 2026.5.1 핀(plan A12)은 **서비스 토큰(비대화형) 경로에만** 관련된 조치다 — 2026.6+에서 `cloudflared access tcp/ssh`가 Access
  서비스 토큰을 무시하는 회귀 보고가 있어 tester의 `tester-k8s`가 깨질 수 있다는 것이지, 운영자의 **브라우저(GitHub IdP) 대화형 로그인**과는
  무관하다. 운영자 경로는 2026.8.3으로 ⑤a·⑤b 모두 실측 통과했다.
- **VD(검증 후 결정)**: 서비스 토큰이 2026.8.3에서 동작하는지 **T041/T049에서 tester 경로로 실측**한 뒤 핀을 유지할지 폐기할지 정한다.
  실측 전까지 tester 워크스테이션에도 2026.5.1을 설치하지 않는다(2026.5.1 릴리스 자산에는 체크섬 파일이 없다 — exe 54,110,064 B).
- 자동 업데이트는 켜지 않는다(daemon은 `--no-autoupdate`, 클라이언트는 MSI 수동 갱신). `deployment.yaml`의 이미지 태그·digest는
  클라이언트 결정과 무관하게 유지한다.

## ⑦ 세션 종료

`cloudflared access tcp` 프로세스 종료 + `%USERPROFILE%\.cloudflared\`(Linux `~/.cloudflared/`)의 `*-token`·`*-org-token` 캐시 파일 삭제.
`cloudflared access logout` 하위 명령은 **존재하지 않는다**(2026-09-07 확인 — 2026.8.3 `cloudflared access --help`의 하위 명령은
login · curl · token · tcp/rdp/ssh/smb · ssh-config · ssh-gen 뿐).

```powershell
# 워크스테이션(PowerShell): 리스너 종료 → 토큰 캐시만 삭제(cert.pem 같은 터널 자격은 건드리지 않는다)
Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process
Remove-Item "$env:USERPROFILE\.cloudflared\*-token*", "$env:USERPROFILE\.cloudflared\*-org-token*" -ErrorAction SilentlyContinue
```

passphrase 키를 올렸으면 `ssh-add -D`.

## ⑧ 임시 22 NSG 규칙 제거 (T039의 마지막 단계)

부트스트랩 예외로 `nsg-cluster`에 열어 둔 22/tcp ← `<운영자 IP>/32` 규칙을 **⑤가 동작하는 것을 확인한 뒤** 제거한다.
운영자 자격으로만 실행한다 — 읽기 전용 `svc-verify` 프로파일에는 `remove` 권한이 없다.

```bash
# 1) 대상 규칙 id 확인
oci network nsg rules list --nsg-id <nsg-cluster OCID> --all

# 2) 제거(인라인 JSON 배열)
oci network nsg rules remove --nsg-id <nsg-cluster OCID> --security-rule-ids "[\"<rule-id>\"]"

# 3) 증명 — 선언된 규칙(자기참조 1개)만 남는다
oci network nsg rules list --nsg-id <nsg-cluster OCID> --all --query 'length(data)'   # = 1
```

- PowerShell에서는 `--security-rule-ids '["<rule-id>"]'`(작은따옴표)가 안전하다.
- `tofu plan`이 깨끗한 것은 증명이 되지 않는다 — OpenTofu가 만들지 않은 규칙은 상태에 없다. 반드시 `nsg rules list`로 확인한다.
- 제거 뒤 SSH 경로는 터널뿐이다. 터널이 죽으면 다시 예외 규칙을 여는 것이 break-glass 절차다(런북).

## ⑨ ExternalSecret 인수 (T045 G4)

Secret `cloudflared-tunnel`(키 `TUNNEL_TOKEN`)의 관리 주체는 **G4 머지 시점부터 ExternalSecret
`cloudflared/cloudflared-tunnel`**이다. 매니페스트 정본은 `../../secrets/cloudflared/externalsecret-cloudflared-tunnel.yaml`,
적용 주체는 Application `platform-secrets`(`../secrets/README.md`), 값의 정본은 Vault `kv/platform/cloudflare/tunnel`의
필드 `token`이다. **이 디렉터리는 바뀌지 않는다** — `deployment.yaml`은 전과 같은 이름·키의 Secret을 같은 `secretKeyRef`로
계속 읽는다(G4의 렌더는 main과 바이트 동일하다).

> ⚠ **폐기된 옛 지시(2026-09-17 T045 G0에서 정정).** 여기 있던 "수동 Secret을 지운다 → ExternalSecret 머지 →
> `rollout restart`"는 **실행하지 않는다.** 이 Secret은 SSH·K8s API의 유일한 접근 경로(터널)의 자격이라, 지운 채 파드가
> 교체되면 운영자가 잠긴다. 확정 방식은 **삭제 없는 인수**다(`creationPolicy: Orphan` · `deletionPolicy: Retain` —
> ownerReference를 만들지 않는다): 라이브 Secret의 값을 Vault로 파이프 복사해 바이트 동일성을 먼저 보장하고(시드 —
> 2026-09-21 완료), 인수 전후 **값 해시 불변 · UID 불변 · ownerReferences 없음 · 파드 이름·`restartCount` 불변**을 확인하며,
> `rollout restart` 대신 **파드 1개만** 교체하는 드릴로 새 자격이 도는 것을 본다. 판정 항목은 `../secrets/README.md` §1·§2,
> 실행 블록의 정본은 모노레포 `specs/003-platform-foundation/design/t045-blocks/g4/`의 **`g4-adopt.ps1`**(캡처·머지 대기·판정,
> **클러스터 쓰기 0건**) · **`g4-drill.ps1`**(별도 입회 후 파드 1개 교체) · **`g4-restore.ps1`**(인수 해제 뒤 값 복구)과
> 런북 `docs/runbooks/bootstrap.md` §3 T045 절이다. adopt의 **값 해시·UID**를 drill에서 다시 검증한다.
> drill을 두 번 실행하면 옛 값을 든 커넥터의 안전망이 사라질 수 있으므로 자동 재실행하지 않는다.
> 드릴 뒤에는 남은 파드 미접촉뿐 아니라 **창 A SSH 세션이 여전히 연결되는지**도 확인한다.

**토큰 회전(T084)의 순서 — kv가 먼저다.**

0. **시작 전.** ES `cloudflared-tunnel`이 `Ready=True`/`SecretSynced`다 — **Vault·ESO가 불가한 동안에는 Cloudflare에서
   토큰을 Refresh하지 않는다**(G4 뒤로는 복구가 kv → ESO 경로에 의존한다). Secret의 `…/data-hash` 값을 **먼저 적어 둔다**
   (2단계의 비교 기준이다). 노드 A SSH 세션과 OCI break-glass도 G4와 같이 확인한다.
   > ⚠ Cloudflare에서 새 토큰을 발급(**Refresh**)하면 그 순간부터 **옛 토큰으로는 새 연결을 맺지 못한다**(기존 연결만
   > 유지된다 — **Cloudflare 문서 기준 · 실측은 T084 VD**). 즉 라이브 Secret은 그때부터 죽은 자격이므로 1–3을
   > **같은 창에서** 끝낸다. Cloudflare 문서의 'compromised token' 순서(연결 전부 삭제 · `cloudflared tunnel cleanup` ·
   > 대시보드 connector 삭제)는 **두 파드가 모두 새 토큰으로 Ready·Registered인 것을 확인한 뒤에만** 한다 —
   > 먼저 하면 두 커넥터가 한꺼번에 끊기고 kv를 고칠 경로까지 사라진다.
1. **Vault kv를 정정한다**(`kv/platform/cloudflare/tunnel`의 `token`). 시드 블록이 아니라 모노레포
   `specs/003-platform-foundation/design/t045-blocks/kv-correct.ps1`(정정 블록 — 런북 `bootstrap.md` §3 T045 절이
   가리킨다)을 쓴다 — 시드 블록은 값이 이미 있으면 덮어쓰기를 거부하는 것이 설계다.
2. **ESO 반영을 확인한다**(≤5분 — `refreshInterval: 5m`). Secret의 `…/data-hash`가 **0단계에 적어 둔 값과 달라졌고**
   ES가 `Ready=True`다(둘을 함께 본다 — Vault 불가로 `SecretSyncedError`인 상태와 구분하기 위해서다).
3. **파드를 1개씩 수동으로 교체한다.** env는 컨테이너가 시작할 때마다 다시 읽히므로, 교체 전까지 도는 커넥터는 마지막
   시작 시점의 옛 토큰으로 동작한다. 앞 파드가 Ready이고 로그에 `Registered tunnel connection`이 찍힌 것을 본 뒤 다음
   파드로 넘어간다 — **반대쪽 커넥터가 살아 있는 동안에만** 교체한다. **`rollout restart` 금지**: 두 커넥터를 동시에
   교체하면 새 토큰이 틀렸을 때 복구할 손이 함께 끊긴다.
   첫 파드가 Ready가 되지 않으면 **두 번째 파드는 건드리지 않고** kv를 다시 정정한다(실패한 파드는 kubelet이 컨테이너를
   재시작할 때마다 Secret을 다시 읽으므로, kv만 고쳐 두면 스스로 회복한다).

- 이 Deployment에는 `reloader.stakater.com/auto` 어노테이션이 **없고** T046의 감시 대상 목록에도 넣지 않는다 —
  그 수동성이 안전장치다(자동 재시작이 붙으면 잘못된 kv 값이 두 커넥터를 한꺼번에 교체한다).
- ⚠ **Secret만 새 값으로 바꾸는 것은 회전이 아니다** — ESO가 다음 주기(≤5분)에 kv의 **옛(폐기된) 값**으로 되돌리고,
  증상은 그때가 아니라 **다음 파드 교체 또는 컨테이너 재시작**에서야 나타난다. 값 문제의 복구 1순위도 같은 이유로 kv 정정이다.
- ⚠ **env는 컨테이너가 시작할 때마다 다시 읽힌다** — 파드 교체뿐 아니라 같은 파드 안의 제자리 재시작(liveness `/ready`
  10s × 6 실패 · OOMKill · 크래시 · 노드 재부팅 = 파드 이름 그대로, `restartCount`만 증가)도 포함이다. 그래서 "지금 도는
  커넥터가 옛 값을 들고 있다"는 안전망은 **재시작되지 않는 동안만** 유효하다. 값이 틀린 상태는 **시한 상태**이므로
  복구를 미루지 않고, 그동안 노드 재부팅·SUC Plan·drain을 하지 않는다(edge 단절이 ≈60초 이어지면 두 커넥터가 파드 교체
  없이 거의 동시에 재시작한다).
- 인수 자체를 해제해야 하면(ES는 없애고 Secret은 남긴다) 순서가 있다: revert PR 머지 → Argo 반영 확인 →
  `kubectl -n cloudflared delete externalsecret cloudflared-tunnel` → Secret 잔존·UID·값(해시) 확인 →
  **값이 깨졌으면 복구하고 해시를 다시 확인** → (값을 복구한 경우에만) 파드 **1개**씩 교체.
  전문은 `../secrets/README.md` §5다(`prune: false`라 파일 revert만으로는 해제되지 않는다).
- ⚠ Secret이 지워졌을 때의 재생성은 **다음 주기 refresh**다(최대 5분 · 2026-09-21 DR1 실측 302초). 그 창에서 실행 중
  커넥터는 무영향이지만(**재시작되지 않는 한** — 재시작하면 Secret이 재생성될 때까지 `CreateContainerConfigError`),
  **새 파드는 시작하지 못한다**.

**콜드 부트스트랩(클러스터를 처음부터 다시 올릴 때)의 순서는 그대로다.**
① 이 README ①②③대로 네임스페이스·**수동 Secret**·cloudflared를 **먼저** 올린다(그것이 운영자의 유일한 SSH·kubectl 경로다) →
② Vault init·unseal(런북 `vault-unseal.md`) → kv 시드 → ③ 그 뒤에야 ESO가 이 Secret을 **인수**한다.
즉 **ExternalSecret은 부트스트랩의 시작점이 아니라 인수 단계**다. root는 `platform-cloudflared`까지 한 번에 가지 못하고
실제로 기다리는 곳은 Vault(init·unseal 전에는 Progressing)이며, kv 시드 순서는 Argo가 아니라 런북 절차가 보장한다
(`../secrets/README.md` §4).

---

## T041·T046·T098로 넘기는 항목

- **kubelet 프로브는 `default-deny`에 막히지 않는다** — 계약에 cloudflared ingress 행을 **추가하지 않는다**.
  K3s 기본 NetworkPolicy 엔진인 kube-router는 pod 방화벽 체인의 **맨 앞(-I … 1)** 에
  `-m addrtype --src-type LOCAL -d <pod IP> -j ACCEPT`("from local node")를 넣으므로, 노드에서 출발하는 kubelet 프로브는
  NetworkPolicy 평가 이전에 통과한다(kube-router `pkg/controllers/netpol/pod.go`에서 확인).
  프로브 때문에 정책을 완화하지 말 것. **CNI/정책 엔진을 바꾸면**(Calico·Cilium 등) 이 전제가 사라지므로 그때 재검토한다.
- **`cloudflared` → 외부 7844는 TCP와 UDP 둘 다** 필요하다. NetworkPolicy `ports[].protocol` 기본값은 TCP라,
  UDP 7844가 없으면 QUIC이 막혀 http2로 조용히 폴백한다(성능·연결 특성이 달라진다). 443/TCP는 폴백 경로.
- **`k8s` ingress 경로**: origin은 `tcp://kubernetes.default.svc.cluster.local:443`이다(Service port 443 → targetPort 6443).
  `allow-dns`(svc DNS 해석) + `allow-kube-api`(노드 A private IP **6443**)가 둘 다 있어야 도달한다 —
  ClusterIP DNAT가 정책 평가보다 먼저라 egress 규칙의 포트는 6443이 맞다.
  전제 확인(운영자 1회): `kubectl -n default get svc kubernetes -o jsonpath='{.spec.ports[0].port} {.spec.ports[0].targetPort}'`
  → `443 6443`. 다르게 나오면 모노레포 `infra/cloudflare/tunnel.tf`의 origin 포트를 그 값으로 맞춘다(하네스 단언 `tunnel-1`도 함께).
- **`ssh-b` 경로**: 계약 매트릭스의 `cloudflared` → 노드 B private IP:22 행이 실제 정책으로 선언되어야 한다.
- **알림 경로 0(T098)**: 지금 cloudflared에는 scrape도 알림도 없다 — 커넥터가 전부 죽어도 사람이 알 수 없다.
  계약 매트릭스에 `monitoring → cloudflared 2000` 행을 추가할지 T098에서 결정한다(추가하면 Service·scrape 설정이 함께 필요).
- **PodDisruptionBudget · `priorityClassName`(후보)**: 노드 drain(system-upgrade)·자원 압박에서 터널을 지키려면 유용하지만
  지금은 계약에 없다. T041(정책·프로젝트)·T046(운영 강화) 때 도입 여부를 결정한다.
