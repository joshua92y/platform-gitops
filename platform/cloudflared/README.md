# platform/cloudflared/ — 운영자 절차 (T039)

Cloudflare 터널 커넥터(`joshuatech-tunnel`)의 클러스터 쪽 배포. 터널 ingress 3개(`ssh-a` → 노드 A 22 · `ssh-b` → 노드 B 22 ·
`k8s` → K3s API 6443)와 Access 앱은 OpenTofu `infra/cloudflare/`(T011)가 소유하고, 이 디렉터리는 **커넥터 Deployment만** 소유한다.

| 파일 | 내용 |
|---|---|
| `kustomization.yaml` | `namespace: cloudflared` + `deployment.yaml`. 이 디렉터리가 만들지 않는 것(ns·Application·Secret)의 경계가 머리 주석에 있다 |
| `deployment.yaml` | replica 2(노드 A·B 각 1, required anti-affinity), 이미지 digest 핀, `TUNNEL_TOKEN` secretKeyRef, restricted securityContext |

- **이 저장소에 비밀은 없다.** 터널 토큰은 운영자 비밀번호 관리자(→ T045 뒤 Vault `kv/platform/cloudflare/tunnel`)에만 있다.
- 순서: ① ns 수동 생성 → ② Secret 수동 생성 → ③ 수동 apply → **(터널 동작 확인)** → ⑤⑥ 워크스테이션 접속 전환 → ⑧ 임시 22 규칙 제거 →
  (T041) ④ Argo CD 인수 확인 → (T045) ⑨ ExternalSecret 전환. ⑦은 세션마다 반복한다.

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

Secret `cloudflared-tunnel`, 키 `TUNNEL_TOKEN`(=`deployment.yaml`의 `secretKeyRef`). 값은 비밀번호 관리자의 터널 실행 토큰.

**금지**: `--from-literal=TUNNEL_TOKEN=<값>`(토큰이 명령줄 → 셸 히스토리와 `ps` 출력에 남는다) ·
`--dry-run=client -o yaml > secret.yaml`(평문 파일 생성 → 커밋 사고) · 토큰을 채팅·이슈·로그에 붙여넣기.
**주의**: 끝에 개행이 붙으면 인증이 실패한다 — 아래 두 방법 모두 개행 없이 기록한다.

PowerShell(운영자 워크스테이션):

```powershell
Set-PSReadLineOption -HistorySaveStyle SaveNothing      # 이 세션 히스토리 저장 끄기
$sec  = Read-Host -AsSecureString 'TUNNEL_TOKEN 붙여넣기(화면에 표시되지 않음)'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
try {
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  [IO.File]::WriteAllText($tmp, $plain, (New-Object Text.UTF8Encoding $false))   # 개행 없음
  kubectl create secret generic cloudflared-tunnel -n cloudflared --from-file=TUNNEL_TOKEN=$tmp
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $plain = $null; $sec = $null; [GC]::Collect()
}
```

bash(Git Bash · 노드 셸):

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

```bash
git -C <platform-gitops 경로> checkout main && git -C <platform-gitops 경로> pull --ff-only
kubectl apply -k platform/cloudflared            # 저장소 루트에서

kubectl -n cloudflared rollout status deploy/cloudflared --timeout=180s
kubectl -n cloudflared get pods -o wide          # pod 2개, NODE 열이 서로 달라야 한다(노드 A·B)
kubectl -n cloudflared logs deploy/cloudflared --tail=50 | grep -i 'Registered tunnel connection'
```

Cloudflare 대시보드(Zero Trust → Networks → Tunnels)에서 커넥터 2개가 HEALTHY인지도 함께 본다.
그다음 터널 경로 자체를 확인한다 — ⑤의 SSH·kubeconfig가 실제로 동작해야 ⑧(임시 22 규칙 제거)로 넘어갈 수 있다.

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

- 기대: managedFields에 Argo CD 컨트롤러의 `Apply` 항목이 있고, 마지막 명령의 출력이 비어 있다(수동 apply 잔재 없음).
- 잔재가 남거나 Argo CD가 field conflict를 보고하면 1회만 마이그레이션한다:
  `kubectl apply --server-side --force-conflicts -k platform/cloudflared` → Argo CD 재Sync → 위 4개 명령 재확인.

## ⑤ 워크스테이션 접속 전환 (SSH ProxyCommand · kubeconfig)

SSH 키는 `joshuatech-ops`(FIDO2 또는 passphrase + `ssh-add -c`; `.claude/rules/infra.md`의 실명 예외).
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
- 확인: `ssh ssh-a hostname` · `ssh ssh-b hostname`.

K8s API는 로컬 리스너로 받는다(`k8s` Access 앱):

```bash
cloudflared access tcp --hostname k8s.joshuatech.dev --url 127.0.0.1:6443    # 세션 동안 켜 둔다
```

부트스트랩 창에서 쓰던 SSH 로컬 포워딩(`ssh -L 6443:127.0.0.1:6443`)을 **먼저 끊어야** 같은 포트를 쓸 수 있다.
포트를 6443으로 맞추는 이유: T035에서 받아 둔 admin kubeconfig의 `server: https://127.0.0.1:6443`을 그대로 쓰기 위해서다
(포트를 바꾸면 kubeconfig를 매번 고쳐야 한다).

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

## ⑥ 워크스테이션 cloudflared 클라이언트는 2026.5.1로 핀

클러스터 안 daemon은 이 저장소의 2026.8.3(digest 핀)을 쓰지만, **워크스테이션·tester의 클라이언트는 2026.5.1**로 고정한다 —
2026.6+에서 `cloudflared access tcp/ssh`가 Access 서비스 토큰을 무시하는 회귀가 있어 비대화형 접근(tester `tester-k8s`)이 깨진다(plan A12).

- GitHub Releases의 2026.5.1 자산을 받아 sha256을 확인한 뒤 고정 경로에 두고, 자동 업데이트를 켜지 않는다.
- 확인: `cloudflared --version` → `2026.5.1`.
- 이 핀은 클라이언트에만 적용된다. `deployment.yaml`의 이미지 태그·digest를 이 버전으로 내리지 않는다.

## ⑦ 세션 종료

```bash
cloudflared access logout      # 캐시된 Access 토큰 제거(모든 운영자 세션 종료 시 필수)
```

`cloudflared access tcp` 프로세스도 함께 종료한다. passphrase 키를 올렸으면 `ssh-add -D`.

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

## ⑨ T045 뒤 ExternalSecret 전환 (예고)

ESO와 `ClusterSecretStore vault-platform`이 생기면(T045) 수동 Secret을 `secrets/cloudflared/`의 ExternalSecret으로 바꾼다.
전환 후에도 `deployment.yaml`은 그대로다(같은 Secret 이름·키를 본다).

```yaml
# secrets/cloudflared/externalsecret.yaml — T045에서 추가한다(지금은 없다)
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflared-tunnel
  namespace: cloudflared
spec:
  refreshInterval: 5m
  secretStoreRef: { kind: ClusterSecretStore, name: vault-platform }
  target: { name: cloudflared-tunnel, creationPolicy: Owner }
  data:
    - secretKey: TUNNEL_TOKEN
      remoteRef: { key: platform/cloudflare/tunnel, property: <T045에서 확정> }
```

전환 순서:

1. Vault에 `kv/platform/cloudflare/tunnel`을 넣는다(T045).
2. 수동 Secret을 지운다 — `creationPolicy: Owner`는 남의 Secret을 인수하지 않는다:
   `kubectl -n cloudflared delete secret cloudflared-tunnel`(실행 중인 pod의 env는 시작 시 주입된 값이라 영향 없다).
3. ExternalSecret을 머지 → Argo CD Sync → `kubectl -n cloudflared get externalsecret cloudflared-tunnel`이 `SecretSynced`.
4. `kubectl -n cloudflared rollout restart deploy/cloudflared` — cloudflared는 토큰을 시작 시에만 읽는다.
   이 Deployment에는 `reloader.stakater.com/auto` 어노테이션이 없다(T046의 감시 대상 목록에도 없다) → 토큰 회전 때마다 이 수동 재시작이 필요하다.

---

## T041로 넘기는 확인 항목

- **kubelet 프로브 도달**: `default-deny`(ingress+egress)가 `cloudflared` ns에 걸린 뒤, 노드에서 오는 liveness/readiness 프로브가
  막히지 않는지 확인한다. 계약의 cloudflared 행에는 ingress 허용이 없다(`allow-apiserver-webhook`도 이 ns 대상이 아니다).
  프로브가 막히면 계약을 먼저 고친 뒤 정책을 추가한다 — 매니페스트 쪽에서 프로브를 지우는 방식으로 넘기지 않는다.
- **`k8s` ingress 경로**: `tcp://kubernetes.default.svc.cluster.local:6443` → `allow-dns` + `allow-kube-api`(노드 A private IP:6443)가
  둘 다 있어야 도달한다.
- **`ssh-b` 경로**: 계약 매트릭스의 `cloudflared` → 노드 B private IP:22 행이 실제 정책으로 선언되어야 한다.
