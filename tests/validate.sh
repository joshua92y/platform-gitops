#!/usr/bin/env bash
# =============================================================================
# tests/validate.sh — platform-gitops required check `validate`의 검사 본체 (T033)
#
# 정본(계약) — 이 스크립트는 아래 두 계약을 코드로 옮긴 것이며, 충돌 시 계약이 우선한다.
#   - 모노레포 specs/003-platform-foundation/contracts/gitops-repo.md
#       §validate.yml · §validate.yml ExternalSecret 검사 · §sync-wave 단일 표 · §이미지·승격
#   - 모노레포 specs/003-platform-foundation/contracts/network-policy.md
#       §네임스페이스 표(14개) · §정책 세트 · §외부 egress 규칙 형식 · §포트 출처 각주
#
# 검사 순서(= 모노레포 tasks.md T033 문면 순서) · 출력 코드:
#   0    TOOL / YAML        도구 존재(fail-closed) · YAML 파싱
#   1    KUST               모든 kustomization.yaml `kustomize build` + `kubeconform -strict -ignore-missing-schemas`
#   1b   KUST-plain         (보강) kustomization 밖 매니페스트(clusters/**, bootstrap/root-app.yaml)도 kubeconform
#   2    APP-SSA            Application마다 syncOptions에 ServerSideApply=true
#   3.0  ES-apiVersion/store/dataFrom/sourceRef   ExternalSecret 규약 보강(계약 §이름·인증 규약)
#   3.1  ES-①              remoteRef.key 정규식 ^(platform|dev|prod)/[a-z0-9_./-]+$ (k8s-data-ca 제외)
#   3.2  ES-②              scope ↔ 위치(overlays/dev → vault-dev+dev/, overlays/prod → vault-prod+prod/, secrets/** → vault-platform+platform/)
#   3.3  ES-③              platform/{cnpg-databases,kafka-topics,dragonfly,authentik,openfga}: vault-data(열거 접두) 또는 vault-platform(platform/)
#   3.4  ES-④              k8s-data-ca: key ∈ {pg-main-ca, jt-kafka-cluster-ca-cert} + property ca.crt, dataFrom 금지
#   3.5  ES-⑤              Deployment·StatefulSet·DaemonSet·CronJob의 `-migrate` Secret 참조 금지
#   3.6  ES-⑥              automountServiceAccountToken: false (apps/** · platform/cloudflared · platform/dragonfly)
#   3.7  ES-⑦              apps/** 의 key가 (dev|prod)/(access|web)/ 접두면 FAIL(Workers 전용)
#   4a   IMG-newTag         kustomization images[].newTag 금지(digest 형식도 검사)
#   4b   IMG-platform-digest platform/** 의 image: 줄에 @sha256 없으면 경고(WARN)
#                           한계: `image:` 스칼라 줄만 검사한다 — helm values의 분리형 image.repository / image.tag 는 보지 않는다
#   5.0  POL-location       Namespace·NetworkPolicy·ResourceQuota·LimitRange는 platform/policies/ 에만
#   5.1  POL-ns             platform/policies Namespace 목록 = 계약 표 14개(누락·초과·중복 FAIL)
#   5.2  POL-set            ns마다 공통 정책 세트 존재(deny-imds=kube-system 전용, allow-imds=vault 전용)
#   5.3  POL-egress         모든 egress ipBlock 규칙에 ports + except 4개(IMDS·RFC 1918 3종); IMDS /32는 vault만
#   5.4  POL-port           포트 출처 각주 ↔ 정책 포트 · helm values 포트 ↔ 정책 포트
#   5.5  POL-limitrange     LimitRange에 default.cpu·max.cpu 없음
#   6    AUTHOR             봇 작성자 PR: 변경 파일 = apps/*/overlays/dev/kustomization.yaml, 변경 줄 = images[].digest 뿐
#                           한계: 변경 줄이 `digest: sha256:<64hex>` 형식인지만 본다(값의 진위·서명은 보지 않음). 보증은 이 줄 검사와
#                           같은 실행의 트리 검사(4a·kustomize build)의 결합이며, PR head의 스크립트로 돌리면 같은 PR에서 무력화될 수
#                           있으므로 CI는 base ref의 tests/validate.sh 로 실행해야 한다(tests/README.md). PR 이벤트에서 PR_AUTHOR가
#                           비면 FAIL(조용한 비활성 금지)
#   7.1  WAVE               Application sync-wave = §sync-wave 단일 표(이름·경로 규약 포함)
#   7.2  WAVE-dir           표에 없는 platform/<component>/ 디렉터리 금지
#   8    LEAK               gitleaks 파일 스캔 — 스캔 대상 0개(빈 트리)면 FAIL
#
# 입력(환경변수 또는 인자):
#   --root <dir>            | VALIDATE_ROOT        검사 대상 트리(기본: 저장소 루트). 저장소 밖은 거부
#   --author <login>        | PR_AUTHOR            PR 작성자 로그인(비어 있으면 검사 6은 대상 없음)
#   --changed-files <file>  | CHANGED_FILES        변경 파일 목록(줄 구분; 환경변수는 내용, 인자는 파일)
#   --diff <file>           | CHANGED_DIFF         unified diff 파일 경로
#   VALIDATE_BASE_SHA · VALIDATE_HEAD_SHA           위 둘 대신 `git diff <base> <head>`로 계산(CI 권장)
#   --skip-tools            | VALIDATE_SKIP_TOOLS=1  없는 도구가 필요한 검사를 SKIP(로컬 부분 검증용; CI 기본은 fail-closed)
#   VALIDATE_BOT_AUTHORS    봇 로그인 목록(쉼표). 기본 "jt-ci[bot],joshuatech-gitapp-1[bot]"
#   VALIDATE_K8S_VERSION    kubeconform -kubernetes-version (기본 master)
#   VALIDATE_KUSTOMIZE_FLAGS kustomize build 추가 플래그(예: --load-restrictor LoadRestrictionsNone)
#   VALIDATE_KUBECONFORM_CACHE kubeconform 스키마 캐시 디렉터리(기본 ${TMPDIR:-/tmp}/kubeconform-cache — 저장소 밖 임시 경로)
#   GITHUB_EVENT_NAME=pull_request | VALIDATE_REQUIRE_AUTHOR=1   PR_AUTHOR가 비어 있으면 검사 6 FAIL
#
# 원칙: --root 트리(와 명시적으로 넘긴 입력 파일) 밖을 읽거나 쓰지 않는다(예외: kubeconform 스키마 캐시만 저장소 밖
#       임시 경로에 둔다). 저장소 안에는 임시 파일을 만들지 않는다(파이프·변수만). 자격·비밀을 요구하지 않는다.
#       결과는 [PASS]/[FAIL]/[WARN]/[SKIP] 한 줄씩이며 FAIL이 하나라도 있으면 exit 1(SKIP은 exit에 영향 없음 —
#       단, 요약에 "불완전"으로 표시).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

ROOT="${VALIDATE_ROOT:-$REPO_ROOT}"
PR_AUTHOR="${PR_AUTHOR:-}"
CHANGED_FILES="${CHANGED_FILES:-}"
CHANGED_DIFF="${CHANGED_DIFF:-}"
SKIP_TOOLS="${VALIDATE_SKIP_TOOLS:-0}"
BOT_AUTHORS="${VALIDATE_BOT_AUTHORS:-jt-ci[bot],joshuatech-gitapp-1[bot]}"
K8S_VERSION="${VALIDATE_K8S_VERSION:-master}"
KUSTOMIZE_FLAGS="${VALIDATE_KUSTOMIZE_FLAGS:-}"
BASE_SHA="${VALIDATE_BASE_SHA:-}"
HEAD_SHA="${VALIDATE_HEAD_SHA:-}"
KUBECONFORM_CACHE="${VALIDATE_KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-cache}"
REQUIRE_AUTHOR="${VALIDATE_REQUIRE_AUTHOR:-0}"
GH_EVENT="${GITHUB_EVENT_NAME:-}"

usage() {
  sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --author) PR_AUTHOR="$2"; shift 2 ;;
    --changed-files) CHANGED_FILES="$(cat "$2")"; shift 2 ;;
    --diff) CHANGED_DIFF="$2"; shift 2 ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { printf 'error: 검사 대상 디렉터리 없음: %s\n' "$ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) ;;
  *) printf 'error: 검사 대상은 저장소 안이어야 한다: %s (저장소: %s)\n' "$ROOT" "$REPO_ROOT" >&2; exit 2 ;;
esac

# -----------------------------------------------------------------------------
# 단일 표(정본 사본) — 계약을 바꾸면 여기만 바꾼다. 다른 곳에 wave·포트를 중복 기재하지 않는다.
# -----------------------------------------------------------------------------

# gitops-repo.md §sync-wave 단일 표: <platform/ 디렉터리> <wave> <컴포넌트가 사는 네임스페이스>
# (apps/<pod>/overlays/<env> 의 Application `<pod>-<env>` 는 wave 100 — 코드에서 처리)
WAVE_TABLE='
argocd -20 argocd
policies -10 -
cert-manager 0 cert-manager
external-secrets 0 external-secrets
vault 10 vault
cert-manager-issuers 20 cert-manager
cnpg 20 cnpg-system
system-upgrade 20 system-upgrade
cnpg-cluster 30 data
kafka 30 data
dragonfly 30 data
cnpg-databases 40 data
kafka-topics 40 data
authentik 50 identity
openfga 50 identity
monitoring 60 monitoring
cloudflared 60 cloudflared
reloader 60 reloader
traefik 60 kube-system
'
APP_WAVE=100

# network-policy.md §네임스페이스 표(14개)
NS_TABLE='kube-system argocd vault external-secrets cert-manager cnpg-system data identity jt-dev jt-prod monitoring system-upgrade cloudflared reloader'

# network-policy.md §정책 세트: <정책 이름> <적용 ns 목록 | ALL13(kube-system 제외 13개)> ; EXCLUSIVE = 그 ns에만 존재해야 함
POLICY_SETS='
default-deny ALL13
allow-dns ALL13
allow-same-namespace argocd,data,cnpg-system,external-secrets,cert-manager,monitoring,identity
allow-kube-api argocd,vault,external-secrets,cert-manager,cnpg-system,data,monitoring,system-upgrade,reloader,cloudflared
allow-apiserver-webhook cert-manager,external-secrets,cnpg-system,vault
deny-imds kube-system EXCLUSIVE
allow-imds vault EXCLUSIVE
'

# network-policy.md §외부 egress 규칙 형식: except 4개
EXCEPT_REQUIRED='169.254.169.254/32 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
IMDS_CIDR='169.254.169.254/32'

# network-policy.md §포트 출처 각주: <ns> <포트> <출처>. 각 포트는 그 ns의 어떤 NetworkPolicy ingress ports에 선언돼야 한다
PORT_TABLE='
cert-manager 10250 cert-manager-webhook
external-secrets 10250 eso-webhook
cnpg-system 9443 cnpg-webhook
argocd 8082 argocd-metrics
argocd 8083 argocd-metrics
argocd 8084 argocd-metrics
external-secrets 8080 eso-metrics
cert-manager 9402 cert-manager-metrics
cnpg-system 8080 cnpg-operator-metrics
data 9187 cnpg-instance-exporter
data 9404 strimzi-kafka-exporter
vault 8200 vault
identity 9000 authentik
identity 8080 openfga
jt-dev 8000 pod-web
jt-dev 9100 pod-web-metrics
jt-dev 9464 relay-outbox-metrics
jt-prod 8000 pod-web
jt-prod 9100 pod-web-metrics
jt-prod 9464 relay-outbox-metrics
'

# helm values에서 포트를 바꾸는 알려진 키: <platform/ 디렉터리> <values yq 경로> <각주 포트>.
# 값이 설정돼 있으면 각주 포트와 같아야 한다(설정이 없으면 차트 기본값 = 각주 포트). 컴포넌트 배포 태스크가
# 차트를 고르면서 키를 확정하면 여기에 행을 추가한다(그 밖의 port 류 키는 5.4c가 WARN으로 드러낸다).
HELM_PORT_KEYS='
cert-manager .webhook.securePort 10250
external-secrets .webhook.port 10250
external-secrets .metrics.listen.port 8080
cnpg .webhook.port 9443
vault .server.service.port 8200
vault .server.service.targetPort 8200
'

# ExternalSecret 규약 정규식(계약 §validate.yml ExternalSecret 검사)
RE_KEY='^(platform|dev|prod)/[a-z0-9_./-]+$'
RE_WORKERS='^(dev|prod)/(access|web)/'
RE_DATA_ENUM='^(dev|prod)/((db|kafka|dragonfly|openfga)/|authentik/webhooks/)[a-z0-9_./-]+$'
RE_LOC_DEV='^apps/[^/]+/overlays/dev(/|$)'
RE_LOC_PROD='^apps/[^/]+/overlays/prod(/|$)'
RE_LOC_SECRETS='^secrets/'
RE_LOC_DATA='^platform/(cnpg-databases|kafka-topics|dragonfly|authentik|openfga)(/|$)'
RE_LOC_APPS='^apps/'
RE_LOC_AUTOMOUNT='^(apps/|platform/(cloudflared|dragonfly)(/|$))'
RE_LOC_POLICIES='^platform/policies/'
RE_DIGEST='^sha256:[0-9a-f]{64}$'
RE_BOT_FILE='^apps/[^/]+/overlays/dev/kustomization\.yaml$'
RE_BOT_LINE='^[[:space:]]*(-[[:space:]]*)?digest:[[:space:]]*sha256:[0-9a-f]{64}[[:space:]]*$'
RE_PORT_KEY='(^|\.)(port|[a-z]+Port[A-Za-z]*)$'
RE_ADDR='^[A-Za-z0-9.:_-]*:([0-9]{2,5})$'
DATREE_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# -----------------------------------------------------------------------------
# 결과 기록
# -----------------------------------------------------------------------------
N_PASS=0; N_FAIL=0; N_WARN=0; N_SKIP=0
FAIL_LINES=()
report() { printf '[%s] %s — %s\n' "$1" "$2" "$3"; }
pass() { N_PASS=$((N_PASS + 1)); report PASS "$1" "$2"; }
fail() { N_FAIL=$((N_FAIL + 1)); FAIL_LINES+=("$1 — $2"); report FAIL "$1" "$2"; }
warn() { N_WARN=$((N_WARN + 1)); report WARN "$1" "$2"; }
skip() { N_SKIP=$((N_SKIP + 1)); report SKIP "$1" "$2"; }
header() { printf '\n== 검사 %s: %s ==\n' "$1" "$2"; }
# 검사 그룹 하나가 새 FAIL 없이 끝났으면 PASS 한 줄
finish_group() { # code message fails_before
  if [[ $N_FAIL -eq $3 ]]; then pass "$1" "$2"; fi
}

rel() { # 절대 경로 → ROOT 기준 상대 경로
  if [[ $1 == "$ROOT" ]]; then printf '.'; else printf '%s' "${1#"$ROOT"/}"; fi
}

# -----------------------------------------------------------------------------
# 도구 — 없으면 fail-closed(설치 안내 후 FAIL). VALIDATE_SKIP_TOOLS=1이면 해당 검사만 SKIP
# -----------------------------------------------------------------------------
declare -A TOOL_OK=()
declare -A TOOL_HINT=(
  [yq]='mikefarah yq v4 — https://github.com/mikefarah/yq/releases (brew install yq · winget install mikefarah.yq · CI: 바이너리 sha256 핀 다운로드). python yq(kislyuk)는 문법이 달라 인정하지 않는다'
  [kustomize]='kustomize v5 — https://github.com/kubernetes-sigs/kustomize/releases (brew install kustomize)'
  [kubeconform]='kubeconform — https://github.com/yannh/kubeconform/releases (brew install kubeconform)'
  [gitleaks]='gitleaks v8 — https://github.com/gitleaks/gitleaks/releases (brew install gitleaks)'
  [helm]='helm v3 — https://github.com/helm/helm/releases (kustomization helmCharts 렌더링에만 필요)'
)
detect_tool() {
  local t=$1
  TOOL_OK[$t]=0
  command -v "$t" >/dev/null 2>&1 || return 0
  if [[ $t == yq ]]; then
    yq --version 2>/dev/null | grep -q 'mikefarah' || return 0
  fi
  TOOL_OK[$t]=1
}
tool_version() {
  case "$1" in
    yq) yq --version 2>/dev/null | tr -d '\r' ;;
    kustomize) kustomize version 2>/dev/null | tr -d '\r' ;;
    kubeconform) kubeconform -v 2>/dev/null | tr -d '\r' ;;
    gitleaks) gitleaks version 2>/dev/null | tr -d '\r' ;;
    helm) helm version --short 2>/dev/null | tr -d '\r' ;;
  esac
}
# need_tool <code> <tool> : 있으면 0. 없으면 SKIP(skip 모드) 또는 FAIL을 기록하고 1
need_tool() {
  local code=$1 t=$2
  [[ ${TOOL_OK[$t]:-0} == 1 ]] && return 0
  if [[ $SKIP_TOOLS == 1 ]]; then
    skip "$code" "도구 없음($t) — VALIDATE_SKIP_TOOLS=1로 건너뜀(CI에서는 fail-closed)"
  else
    fail "$code" "도구 없음($t) — fail-closed. 설치: ${TOOL_HINT[$t]}"
  fi
  return 1
}

# -----------------------------------------------------------------------------
# yq 추출 — 탭 대신 US(0x1f)로 필드를 구분한다(빈 필드 보존). 표현식은 mikefarah yq v4 문법
# -----------------------------------------------------------------------------
export YQ_SEP=$'\x1f'

# shellcheck disable=SC2016  # 아래 $ps·$ns·$n·$r·$c 는 yq 변수이지 셸 변수가 아니다
# 주의: yq v4는 없는 경로를 traverse하면 그 키를 만들어 버린다(`.extract.key` 한 번이면 find 항목에도 `extract`가 생겨
# 뒤따르는 `select(.extract == null)`이 0이 된다). dataFrom 판정은 traverse 대신 has("extract")로만 한다.
YQ_ES='select(.kind == "ExternalSecret") | [ (.apiVersion // "-"), (.metadata.namespace // "-"), (.metadata.name // "-"), (.spec.secretStoreRef.kind // "-"), (.spec.secretStoreRef.name // "-"), ((.spec.data // []) | map((.remoteRef.key // "-") + "=" + (.remoteRef.property // "-")) | join(",")), ((.spec.dataFrom // []) | map(select(has("extract")) | .extract.key | select(. != null)) | join(",")), ((.spec.dataFrom // []) | map(select(has("extract") | not)) | length | tostring), ((((.spec.data // []) | map(select(.sourceRef != null)) | length) + ((.spec.dataFrom // []) | map(select(.sourceRef != null)) | length)) | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
# (yq v4의 `,` 합집합은 수집자 안에서 두 번째 가지를 잃으므로 배열 셋을 `+`로 이어 붙인다)
YQ_WL='select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob") | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // {}) as $ps | (($ps.containers // []) + ($ps.initContainers // [])) as $cs | [ .kind, (.metadata.namespace // "-"), (.metadata.name // "-"), ($ps.automountServiceAccountToken | tostring), (([ $cs[] | (.envFrom // [])[] | .secretRef.name | select(. != null) ] + [ $cs[] | (.env // [])[] | .valueFrom.secretKeyRef.name | select(. != null) ] + [ ($ps.volumes // [])[] | .secret.secretName | select(. != null) ]) | join(",")) ] | join(strenv(YQ_SEP))'
YQ_APP='select(.kind == "Application" and ((.apiVersion // "") | test("^argoproj.io/"))) | [ (.metadata.name // "-"), ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-") | tostring), (.spec.source.path // ((.spec.sources // [])[0].path // "-")), ((.spec.syncPolicy.syncOptions // []) | join(";")) ] | join(strenv(YQ_SEP))'
YQ_NS='select(.kind == "Namespace") | (.metadata.name // "-")'
YQ_NP='select(.kind == "NetworkPolicy") | [ (.metadata.namespace // "-"), (.metadata.name // "-") ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_EGRESS_IPBLOCK='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.egress // [])[] as $r | ($r.to // [])[] | select(.ipBlock != null) | .ipBlock | [ $ns, $n, (.cidr // "-"), ((.except // []) | join(",")), (($r.ports // []) | map((.port // "-") | tostring) | join(",")) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_INGRESS_PORTS='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.ingress // [])[] | (.ports // [])[] | [ $ns, $n, ((.port // "-") | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_EGRESS_PORTS='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.egress // [])[] | (.ports // [])[] | [ $ns, $n, ((.port // "-") | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_LR='select(.kind == "LimitRange") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.limits // [])[] | [ $ns, $n, (.type // "-"), ((.default.cpu // "-") | tostring), ((.max.cpu // "-") | tostring) ] | join(strenv(YQ_SEP))'
YQ_POLICY_KINDS='select(.kind == "Namespace" or .kind == "NetworkPolicy" or .kind == "ResourceQuota" or .kind == "LimitRange") | .kind + "/" + (.metadata.name // "-")'
YQ_IMAGES='(.images // [])[] | [ (.name // "-"), (.newName // "-"), ((.newTag // "-") | tostring), (.digest // "-") ] | join(strenv(YQ_SEP))'
YQ_HELM_COUNT='(.helmCharts // []) | length'
# shellcheck disable=SC2016
YQ_HELM_LEAVES='(.helmCharts // [])[] | (.name // "-") as $c | (.valuesInline // {}) | [.. | select(tag == "!!int" or tag == "!!str") | {"p": (path | join(".")), "v": (. | tostring)}] | .[] | [ $c, .p, .v ] | join(strenv(YQ_SEP))'
YQ_HELM_VALUES_FILES='(.helmCharts // [])[] | .valuesFile | select(. != null)'
YQ_FILE_LEAVES='[.. | select(tag == "!!int" or tag == "!!str") | {"p": (path | join(".")), "v": (. | tostring)}] | .[] | [ .p, .v ] | join(strenv(YQ_SEP))'

yq_lines() { # <expr> <file> — 빈 줄 제거·CR 제거. 실패 시 비영 상태
  yq -N "$1" "$2" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# 원본(source) 목록: 파일 + (kustomize가 있으면) 각 kustomization의 렌더링 결과.
#   SRC_PATH  = 위치 판정에 쓰는 ROOT 기준 경로(파일 경로 또는 kustomization 디렉터리)
#   SRC_LABEL = 사람용 표시  SRC_KIND = file|rendered  SRC_CONTENT = 렌더링 결과(rendered만)
SRC_N=0
declare -a SRC_PATH=() SRC_LABEL=() SRC_KIND=() SRC_CONTENT=()
add_src() { SRC_PATH[SRC_N]=$1; SRC_LABEL[SRC_N]=$2; SRC_KIND[SRC_N]=$3; SRC_CONTENT[SRC_N]=${4:-}; SRC_N=$((SRC_N + 1)); }
src_extract() { # <idx> <expr>
  local i=$1 expr=$2
  if [[ ${SRC_KIND[$i]} == file ]]; then
    yq -N "$expr" "$ROOT/${SRC_PATH[$i]}"
  else
    printf '%s\n' "${SRC_CONTENT[$i]}" | yq -N "$expr"
  fi | tr -d '\r' | sed '/^[[:space:]]*$/d'
}
# collect_rows <expr> <code> <all|file> [경로 정규식] → 전역 ROWS ("idx<US>행" 줄들). yq 실패는 FAIL 기록
ROWS=''
collect_rows() {
  local expr=$1 code=$2 scope=$3 pathre=${4:-} i rows line
  ROWS=''
  for ((i = 0; i < SRC_N; i++)); do
    [[ $scope == all || ${SRC_KIND[$i]} == file ]] || continue
    if [[ -n $pathre ]]; then [[ ${SRC_PATH[$i]} =~ $pathre ]] || continue; fi
    if ! rows=$(src_extract "$i" "$expr"); then
      fail "$code" "yq 추출 실패: ${SRC_LABEL[$i]}"
      continue
    fi
    [[ -n $rows ]] || continue
    while IFS= read -r line; do
      ROWS+="${i}${YQ_SEP}${line}"$'\n'
    done < <(printf '%s\n' "$rows")
  done
}

# -----------------------------------------------------------------------------
# 시작: 도구 · 파일 수집 · YAML 파싱
# -----------------------------------------------------------------------------
printf 'platform-gitops validate — 대상: %s\n' "$ROOT"
if [[ $SKIP_TOOLS == 1 ]]; then
  printf '모드: VALIDATE_SKIP_TOOLS=1 (없는 도구가 필요한 검사는 SKIP — CI 기준 불완전)\n'
fi

header 0 "도구 · 파일 수집 · YAML 파싱"
for t in yq kustomize kubeconform gitleaks helm; do
  detect_tool "$t"
  if [[ ${TOOL_OK[$t]} == 1 ]]; then
    printf '  도구 %-12s 있음  %s\n' "$t" "$(tool_version "$t")"
  else
    printf '  도구 %-12s 없음  (설치: %s)\n' "$t" "${TOOL_HINT[$t]}"
  fi
done

# kubeconform 공통 인자. 스키마 캐시는 저장소 밖 임시 경로(카탈로그를 실행마다 다시 받지 않도록) — 생성 실패 시 캐시 없이 진행
KC_ARGS=(-strict -ignore-missing-schemas -summary -kubernetes-version "$K8S_VERSION" -schema-location default -schema-location "$DATREE_SCHEMA")
if [[ ${TOOL_OK[kubeconform]} == 1 ]]; then
  if mkdir -p "$KUBECONFORM_CACHE" 2>/dev/null; then
    KC_ARGS+=(-cache "$KUBECONFORM_CACHE")
    printf '  kubeconform 스키마 캐시: %s\n' "$KUBECONFORM_CACHE"
  else
    printf '  kubeconform 스키마 캐시 디렉터리 생성 실패(%s) — 캐시 없이 실행\n' "$KUBECONFORM_CACHE"
  fi
fi

mapfile -t YAML_FILES < <(find "$ROOT" -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -not -path '*/.git/*' -not -path "$ROOT/tests/*" -not -path '*/charts/*' | LC_ALL=C sort)
mapfile -t KUST_FILES < <(find "$ROOT" -type f \( -name 'kustomization.yaml' -o -name 'kustomization.yml' -o -name 'Kustomization' \) \
  -not -path '*/.git/*' -not -path "$ROOT/tests/*" -not -path '*/charts/*' | LC_ALL=C sort)
printf '  YAML 파일 %d개, kustomization %d개 (tests/·.git/·charts/ 제외)\n' "${#YAML_FILES[@]}" "${#KUST_FILES[@]}"

for f in "${YAML_FILES[@]}"; do
  add_src "$(rel "$f")" "$(rel "$f")" file
done

if [[ ${TOOL_OK[yq]} == 1 ]]; then
  fails_before=$N_FAIL
  for f in "${YAML_FILES[@]}"; do
    if ! yq -N 'true' "$f" >/dev/null 2>&1; then
      fail "0 YAML" "파싱 실패: $(rel "$f")"
    fi
  done
  finish_group "0 YAML" "YAML ${#YAML_FILES[@]}개 파싱" "$fails_before"
else
  need_tool "0 YAML" yq || true
fi

# -----------------------------------------------------------------------------
# 검사 1 — kustomize build + kubeconform (렌더링 결과는 이후 검사에도 원본으로 추가)
# -----------------------------------------------------------------------------
check_1_kustomize() {
  header 1 "kustomize build(모든 kustomization) + kubeconform -strict -ignore-missing-schemas"
  need_tool "1 KUST" kustomize || return 0
  local fails_before=$N_FAIL n=0 kfile dir rdir rendered has_helm out
  local -a flags
  for kfile in "${KUST_FILES[@]}"; do
    dir=$(dirname "$kfile"); rdir=$(rel "$dir")
    flags=()
    has_helm=0
    if grep -Eq '^[[:space:]]*helmCharts:' "$kfile"; then has_helm=1; fi
    if [[ $has_helm == 1 ]]; then
      need_tool "1 KUST" helm || continue
      flags+=(--enable-helm)
    fi
    # shellcheck disable=SC2086  # KUSTOMIZE_FLAGS는 의도적으로 단어 분리
    if ! rendered=$(kustomize build "$dir" "${flags[@]}" $KUSTOMIZE_FLAGS 2>&1); then
      fail "1 KUST" "kustomize build 실패: $rdir — $(printf '%s' "$rendered" | tail -n 3 | tr '\n' ' ')"
      continue
    fi
    rendered=$(printf '%s' "$rendered" | tr -d '\r')
    add_src "$rdir" "$rdir (rendered)" rendered "$rendered"
    n=$((n + 1))
    if [[ ${TOOL_OK[kubeconform]} == 1 ]]; then
      if ! out=$(printf '%s\n' "$rendered" | kubeconform "${KC_ARGS[@]}" 2>&1); then
        fail "1 KUST" "kubeconform 실패: $rdir — $(printf '%s' "$out" | tr -d '\r' | head -n 5 | tr '\n' ' ')"
      fi
    fi
  done
  if [[ ${TOOL_OK[kubeconform]} != 1 ]]; then
    need_tool "1 KUST" kubeconform || true
  fi
  finish_group "1 KUST" "kustomization ${n}개 빌드·스키마 검증(렌더링 결과는 검사 3에도 포함)" "$fails_before"
}

# 1b(보강) — 어떤 kustomization에도 속하지 않는 매니페스트(clusters/**, bootstrap/root-app.yaml 등 Argo가 디렉터리로 읽는 것)도 kubeconform.
# kustomize 유무와 무관하게 실행한다(kubeconform만 필요).
check_1b_plain() {
  local f1b=$N_FAIL m=0 f rf kfile kdir covered out
  need_tool "1b KUST-plain" kubeconform || return 0
  for f in "${YAML_FILES[@]}"; do
    rf=$(rel "$f")
    [[ $rf != .github/* ]] || continue
    covered=0
    for kfile in "${KUST_FILES[@]}"; do
      kdir=$(dirname "$kfile")
      if [[ $f == "$kdir"/* ]]; then covered=1; break; fi
    done
    [[ $covered == 0 ]] || continue
    m=$((m + 1))
    if ! out=$(kubeconform "${KC_ARGS[@]}" "$f" 2>&1); then
      fail "1b KUST-plain" "kubeconform 실패: $rf — $(printf '%s' "$out" | tr -d '\r' | head -n 5 | tr '\n' ' ')"
    fi
  done
  finish_group "1b KUST-plain" "kustomization 밖 매니페스트 ${m}개 스키마 검증" "$f1b"
}

# -----------------------------------------------------------------------------
# 검사 2 — Application마다 ServerSideApply=true (원본 파일 기준)
# -----------------------------------------------------------------------------
check_2_app_ssa() {
  header 2 "Application syncOptions ServerSideApply=true"
  need_tool "2 APP-SSA" yq || return 0
  local fails_before=$N_FAIL n=0 i name wave path opts
  collect_rows "$YQ_APP" "2 APP-SSA" file
  while IFS="$YQ_SEP" read -r i name wave path opts; do
    [[ -n $i ]] || continue
    n=$((n + 1))
    [[ ";$opts;" == *";ServerSideApply=true;"* ]] || fail "2 APP-SSA" "${SRC_LABEL[$i]} Application/$name: syncOptions에 ServerSideApply=true 없음"
  done < <(printf '%s' "$ROWS")
  finish_group "2 APP-SSA" "Application ${n}개 모두 ServerSideApply=true" "$fails_before"
}

# -----------------------------------------------------------------------------
# 검사 3 — ExternalSecret 7항목 (원본 파일 + 렌더링 결과)
# -----------------------------------------------------------------------------
check_3_externalsecrets() {
  header 3 "ExternalSecret 규약 ①–⑦ (파일 + 렌더링 결과)"
  need_tool "3 ES" yq || return 0
  local fails_before=$N_FAIL n=0 i apiv ns name skind store dkeys dfkeys dfother dsref
  local p label es kv k prop want_store want_prefix idx
  local -a keys props arr
  collect_rows "$YQ_ES" "3 ES" all
  while IFS="$YQ_SEP" read -r i apiv ns name skind store dkeys dfkeys dfother dsref; do
    [[ -n $i ]] || continue
    n=$((n + 1)); p=${SRC_PATH[$i]}; label=${SRC_LABEL[$i]}
    es="$label ExternalSecret/$ns/$name"

    # 3.0 규약 보강(계약 §이름·인증 규약·§ClusterSecretStore 5개): v1 · ClusterSecretStore · 5개 store · dataFrom/sourceRef 우회 금지
    [[ $apiv == external-secrets.io/v1 ]] || fail "3.0 ES-apiVersion" "$es: apiVersion=$apiv (external-secrets.io/v1만, v1beta1 금지)"
    [[ $skind == ClusterSecretStore ]] || fail "3.0 ES-store" "$es: secretStoreRef.kind=$skind (ClusterSecretStore만)"
    case "$store" in
      vault-platform|vault-dev|vault-prod|vault-data|k8s-data-ca) ;;
      *) fail "3.0 ES-store" "$es: 알 수 없는 store '$store' (vault-platform·vault-dev·vault-prod·vault-data·k8s-data-ca)" ;;
    esac
    [[ $dfother == 0 ]] || fail "3.0 ES-dataFrom" "$es: dataFrom은 extract.key만 허용(find·sourceRef 금지 — 경로 lint 우회)"
    [[ $dsref == 0 ]] || fail "3.0 ES-sourceRef" "$es: data[]/dataFrom[].sourceRef(항목별 store 우회) 금지"

    # 키 목록 = data[].remoteRef(key=property) + dataFrom[].extract.key(property 없음)
    keys=(); props=()
    IFS=',' read -r -a arr <<< "$dkeys"
    for kv in "${arr[@]}"; do [[ -n $kv ]] || continue; keys+=("${kv%%=*}"); props+=("${kv#*=}"); done
    IFS=',' read -r -a arr <<< "$dfkeys"
    for k in "${arr[@]}"; do [[ -n $k ]] || continue; keys+=("$k"); props+=("-"); done

    # ④ k8s-data-ca(CA 미러): key ∈ {pg-main-ca, jt-kafka-cluster-ca-cert} + property ca.crt, dataFrom 금지. ①②③⑦ 제외
    if [[ $store == k8s-data-ca ]]; then
      if [[ -n $dfkeys || $dfother != 0 ]]; then
        fail "3.4 ES-④" "$es: k8s-data-ca에 dataFrom 금지(ca.key까지 복사됨 — property: ca.crt만)"
      fi
      for idx in "${!keys[@]}"; do
        k=${keys[$idx]}; prop=${props[$idx]}
        [[ $k == pg-main-ca || $k == jt-kafka-cluster-ca-cert ]] || fail "3.4 ES-④" "$es: k8s-data-ca key '$k' 불허(pg-main-ca·jt-kafka-cluster-ca-cert만)"
        [[ $prop == ca.crt ]] || fail "3.4 ES-④" "$es: k8s-data-ca key '$k' property='$prop' (ca.crt만)"
      done
      continue
    fi

    # ① 정규식 · ⑦ Workers 전용 경로(apps/**)
    for k in "${keys[@]}"; do
      [[ $k =~ $RE_KEY ]] || fail "3.1 ES-①" "$es: remoteRef.key '$k' 정규식 위반 ($RE_KEY)"
      if [[ $p =~ $RE_LOC_APPS && $k =~ $RE_WORKERS ]]; then
        fail "3.7 ES-⑦" "$es: apps/**의 key '$k'는 Workers 전용 경로((dev|prod)/(access|web)/) — pod 반입 금지"
      fi
    done

    # ② scope ↔ 위치
    want_store=''; want_prefix=''
    if [[ $p =~ $RE_LOC_DEV ]]; then want_store=vault-dev; want_prefix=dev/
    elif [[ $p =~ $RE_LOC_PROD ]]; then want_store=vault-prod; want_prefix=prod/
    elif [[ $p =~ $RE_LOC_SECRETS ]]; then want_store=vault-platform; want_prefix=platform/
    fi
    if [[ -n $want_store ]]; then
      [[ $store == "$want_store" ]] || fail "3.2 ES-②" "$es: 위치 '$p'는 store $want_store 이어야 함(현재 $store)"
      for k in "${keys[@]}"; do
        [[ $k == "$want_prefix"* ]] || fail "3.2 ES-②" "$es: 위치 '$p'의 key '$k'는 '$want_prefix' 접두여야 함"
      done
    fi

    # ③ platform/{cnpg-databases,kafka-topics,dragonfly,authentik,openfga}: vault-data(열거 접두) 또는 vault-platform(platform/)
    if [[ $p =~ $RE_LOC_DATA ]]; then
      case "$store" in
        vault-data)
          for k in "${keys[@]}"; do
            [[ $k =~ $RE_DATA_ENUM ]] || fail "3.3 ES-③" "$es: vault-data key '$k'는 열거 접두 밖(kv/{dev,prod}/{db,kafka,dragonfly,openfga}/* · kv/{dev,prod}/authentik/webhooks/*)"
          done ;;
        vault-platform)
          for k in "${keys[@]}"; do
            [[ $k == platform/* ]] || fail "3.3 ES-③" "$es: vault-platform key '$k'는 platform/ 접두여야 함"
          done ;;
        *) fail "3.3 ES-③" "$es: 위치 '$p'의 store '$store' 불허(vault-data 또는 vault-platform만)" ;;
      esac
    fi
  done < <(printf '%s' "$ROWS")
  finish_group "3 ES" "ExternalSecret ${n}개(파일+렌더링) ①②③④⑦ 통과" "$fails_before"
}

# 3.5 · 3.6 — 워크로드(Deployment·StatefulSet·DaemonSet·Job·CronJob) 검사
check_3_workloads() {
  header 3.5 "워크로드: -migrate Secret 참조 금지(⑤) · automountServiceAccountToken: false(⑥)"
  need_tool "3.5 ES-⑤" yq || return 0
  local fails_before=$N_FAIL n=0 i kind ns name automount refs p label w r
  local -a arr
  collect_rows "$YQ_WL" "3.5 ES-⑤" all
  while IFS="$YQ_SEP" read -r i kind ns name automount refs; do
    [[ -n $i ]] || continue
    n=$((n + 1)); p=${SRC_PATH[$i]}; label=${SRC_LABEL[$i]}
    w="$label $kind/$ns/$name"
    # ⑤ 장기 실행·주기 워크로드에서 <pod>-migrate 참조 금지(Job은 PreSync migrate 전용이므로 제외)
    if [[ $kind != Job ]]; then
      IFS=',' read -r -a arr <<< "$refs"
      for r in "${arr[@]}"; do
        [[ -n $r ]] || continue
        if [[ $r == *-migrate ]]; then
          fail "3.5 ES-⑤" "$w: Secret '$r' 참조 금지(envFrom·secretKeyRef·volume — owner DB 자격은 PreSync Job 전용)"
        fi
      done
    fi
    # ⑥ 범위: apps/** · platform/cloudflared · platform/dragonfly
    if [[ $p =~ $RE_LOC_AUTOMOUNT ]]; then
      [[ $automount == false ]] || fail "3.6 ES-⑥" "$w: automountServiceAccountToken: false 필요(현재 $automount)"
    fi
  done < <(printf '%s' "$ROWS")
  finish_group "3.5 ES-⑤⑥" "워크로드 ${n}개(파일+렌더링) ⑤⑥ 통과" "$fails_before"
}

# -----------------------------------------------------------------------------
# 검사 4 — images[].newTag 금지(4a) · platform/** image: digest 경고(4b)
# -----------------------------------------------------------------------------
check_4_images() {
  header 4 "images[].newTag 금지 · platform/** image: @sha256 경고"
  local fails_before=$N_FAIL n=0 kfile rk name newtag digest f line val
  if need_tool "4a IMG-newTag" yq; then
    for kfile in "${KUST_FILES[@]}"; do
      rk=$(rel "$kfile")
      while IFS="$YQ_SEP" read -r name _ newtag digest; do
        [[ -n $name ]] || continue
        n=$((n + 1))
        [[ $newtag == "-" ]] || fail "4a IMG-newTag" "$rk images[$name]: newTag='$newtag' 금지(digest만)"
        if [[ $digest != "-" && ! $digest =~ $RE_DIGEST ]]; then
          fail "4a IMG-newTag" "$rk images[$name]: digest '$digest' 형식 오류(sha256:<64 hex>)"
        fi
      done < <(yq_lines "$YQ_IMAGES" "$kfile" || true)
    done
    finish_group "4a IMG-newTag" "kustomization images ${n}개 항목 newTag 없음" "$fails_before"
  fi
  # 4b — platform/** 의 `image:` 스칼라 줄(따옴표 허용). digest 없으면 WARN(FAIL 아님)
  local warned=0 total=0
  for f in "${YAML_FILES[@]}"; do
    rk=$(rel "$f")
    [[ $rk == platform/* ]] || continue
    while IFS= read -r line; do
      val=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//')
      [[ -n $val && $val != '{}' && $val != '|'* && $val != '>'* ]] || continue
      total=$((total + 1))
      if [[ $val != *@sha256:* ]]; then
        warned=$((warned + 1))
        warn "4b IMG-platform-digest" "$rk: image '$val'에 @sha256 digest 없음(태그에 digest 병기 권장)"
      fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*[^[:space:]]' "$f" || true)
  done
  pass "4b IMG-platform-digest" "platform/** image: 줄 ${total}개 중 digest 없는 줄 ${warned}개(경고만)"
}

# -----------------------------------------------------------------------------
# 검사 5 — 정책(platform/policies) lint
# -----------------------------------------------------------------------------
declare -A NS_INGRESS_PORTS=() NS_ALL_PORTS=()
check_5_policies() {
  header 5 "정책 lint(platform/policies): Namespace 14개 · 정책 세트 · egress ipBlock · 포트 · LimitRange"
  need_tool "5 POL" yq || return 0
  local fails_before=$N_FAIL i x ns name rk
  local -A ns_seen=() np_seen=()
  local -a arr

  # 5.0 정책 객체는 platform/policies/ 에만(원본 파일 기준; helm 렌더링 결과는 제외)
  local f0=$N_FAIL
  collect_rows "$YQ_POLICY_KINDS" "5.0 POL-location" file
  while IFS="$YQ_SEP" read -r i x; do
    [[ -n $i ]] || continue
    [[ ${SRC_PATH[$i]} =~ $RE_LOC_POLICIES ]] || fail "5.0 POL-location" "${SRC_LABEL[$i]} $x: 정책 객체(Namespace·NetworkPolicy·ResourceQuota·LimitRange)는 platform/policies/ 에만 둔다"
  done < <(printf '%s' "$ROWS")
  finish_group "5.0 POL-location" "정책 객체가 platform/policies/ 밖에 없음" "$f0"

  # 5.1 Namespace 목록 = 표 14개
  local f1=$N_FAIL
  collect_rows "$YQ_NS" "5.1 POL-ns" file "$RE_LOC_POLICIES"
  while IFS="$YQ_SEP" read -r i ns; do
    [[ -n $i ]] || continue
    if [[ -n ${ns_seen[$ns]:-} ]]; then fail "5.1 POL-ns" "Namespace '$ns' 중복 선언(${SRC_LABEL[$i]})"; fi
    ns_seen[$ns]=1
  done < <(printf '%s' "$ROWS")
  for ns in $NS_TABLE; do
    [[ -n ${ns_seen[$ns]:-} ]] || fail "5.1 POL-ns" "Namespace '$ns' 누락(계약 표 14개)"
  done
  for ns in "${!ns_seen[@]}"; do
    [[ " $NS_TABLE " == *" $ns "* ]] || fail "5.1 POL-ns" "Namespace '$ns'는 계약 표에 없음(초과)"
  done
  finish_group "5.1 POL-ns" "Namespace ${#ns_seen[@]}개 = 계약 표 14개" "$f1"

  # 5.2 정책 세트
  local f2=$N_FAIL pol targets flag t
  collect_rows "$YQ_NP" "5.2 POL-set" file "$RE_LOC_POLICIES"
  while IFS="$YQ_SEP" read -r i ns name; do
    [[ -n $i ]] || continue
    [[ $ns != "-" ]] || { fail "5.2 POL-set" "${SRC_LABEL[$i]} NetworkPolicy/$name: metadata.namespace 없음"; continue; }
    np_seen["$ns/$name"]=1
  done < <(printf '%s' "$ROWS")
  while read -r pol targets flag; do
    [[ -n $pol ]] || continue
    if [[ $targets == ALL13 ]]; then targets=${NS_TABLE/kube-system /}; targets=${targets// /,}; fi
    IFS=',' read -r -a arr <<< "$targets"
    for t in "${arr[@]}"; do
      [[ -n ${np_seen["$t/$pol"]:-} ]] || fail "5.2 POL-set" "ns '$t'에 정책 '$pol' 없음"
    done
    if [[ ${flag:-} == EXCLUSIVE ]]; then
      for x in "${!np_seen[@]}"; do
        if [[ ${x#*/} == "$pol" && " ${targets//,/ } " != *" ${x%%/*} "* ]]; then
          fail "5.2 POL-set" "정책 '$pol'은 $targets 전용 — ns '${x%%/*}'에 있으면 안 됨"
        fi
      done
    fi
  done <<< "$POLICY_SETS"
  finish_group "5.2 POL-set" "ns별 공통 정책 세트 존재(default-deny·allow-dns·allow-same-namespace·allow-kube-api·allow-apiserver-webhook·deny-imds·allow-imds)" "$f2"

  # 5.3 egress ipBlock: ports + except 4개. 예외 = kube-system deny-imds(0.0.0.0/0 except IMDS, 전 포트 — 계약 §정책 세트)
  local f3=$N_FAIL cidr excepts ports prefix e missing
  collect_rows "$YQ_NP_EGRESS_IPBLOCK" "5.3 POL-egress" file "$RE_LOC_POLICIES"
  while IFS="$YQ_SEP" read -r i ns name cidr excepts ports; do
    [[ -n $i ]] || continue
    x="${SRC_LABEL[$i]} NetworkPolicy/$ns/$name ipBlock $cidr"
    if [[ $ns == kube-system && $name == deny-imds ]]; then
      [[ $cidr == 0.0.0.0/0 && ",$excepts," == *",$IMDS_CIDR,"* ]] || fail "5.3 POL-egress" "$x: deny-imds는 cidr 0.0.0.0/0 + except $IMDS_CIDR 이어야 함"
      continue
    fi
    [[ -n $ports ]] || fail "5.3 POL-egress-ports" "$x: ports 없음(전 포트 개방 금지)"
    if [[ $cidr == "$IMDS_CIDR" && $ns != vault ]]; then
      fail "5.3 POL-imds" "$x: IMDS 도달은 vault(allow-imds)만 허용"
    fi
    prefix=${cidr##*/}
    if [[ $prefix != 32 ]]; then
      missing=''
      for e in $EXCEPT_REQUIRED; do
        [[ ",$excepts," == *",$e,"* ]] || missing+="$e "
      done
      [[ -z $missing ]] || fail "5.3 POL-egress-except" "$x: except 누락 → $missing(IMDS·RFC 1918 3종 4개 필수)"
    fi
  done < <(printf '%s' "$ROWS")
  finish_group "5.3 POL-egress" "egress ipBlock 규칙 모두 ports + except 4개" "$f3"

  # 5.4 포트: (a) 각주 포트가 그 ns의 ingress ports에 선언 (b) helm values 알려진 키 = 각주 포트 (c) 그 밖의 port 류 값이 정책에 없으면 WARN
  local f4=$N_FAIL port src comp path expected val kfile leaves key c vf
  collect_rows "$YQ_NP_INGRESS_PORTS" "5.4 POL-port" file "$RE_LOC_POLICIES"
  while IFS="$YQ_SEP" read -r i ns name port; do
    [[ -n $i ]] || continue
    NS_INGRESS_PORTS[$ns]+=" $port "; NS_ALL_PORTS[$ns]+=" $port "
  done < <(printf '%s' "$ROWS")
  collect_rows "$YQ_NP_EGRESS_PORTS" "5.4 POL-port" file "$RE_LOC_POLICIES"
  while IFS="$YQ_SEP" read -r i ns name port; do
    [[ -n $i ]] || continue
    NS_ALL_PORTS[$ns]+=" $port "
  done < <(printf '%s' "$ROWS")
  while read -r ns port src; do
    [[ -n $ns ]] || continue
    [[ ${NS_INGRESS_PORTS[$ns]:-} == *" $port "* ]] || fail "5.4 POL-port-table" "ns '$ns' 포트 $port($src): 계약 §포트 출처 각주의 포트가 platform/policies의 ingress ports에 없음"
  done <<< "$PORT_TABLE"
  # (b)(c) helm values
  for kfile in "${KUST_FILES[@]}"; do
    rk=$(rel "$kfile")
    [[ $rk =~ ^platform/([^/]+)/kustomization\.ya?ml$ ]] || continue
    comp=${BASH_REMATCH[1]}
    [[ $(yq -N "$YQ_HELM_COUNT" "$kfile" | tr -d '\r') != 0 ]] || continue
    while read -r c path expected; do
      [[ -n $c && $c == "$comp" ]] || continue
      val=$(yq -N "(.helmCharts // [])[] | (.valuesInline | $path) // \"-\"" "$kfile" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -n 1)
      if [[ -n $val && $val != "-" && $val != "$expected" ]]; then
        fail "5.4 POL-port-values" "$rk helm values $path=$val: 계약 §포트 출처 각주 $expected 와 다름(values·정책·계약을 함께 바꿔야 함)"
      fi
    done <<< "$HELM_PORT_KEYS"
    # valuesInline 잎(path 접두 helmCharts.N.valuesInline. 제거) + valuesFile 잎
    leaves=$(yq_lines "$YQ_HELM_LEAVES" "$kfile" | sed "s/^\([^$YQ_SEP]*\)${YQ_SEP}helmCharts\.[0-9]*\.valuesInline\./\1${YQ_SEP}/" || true)
    while IFS="$YQ_SEP" read -r vf key val; do
      [[ -n $vf ]] || continue
      leaves+=$'\n'"$vf${YQ_SEP}$key${YQ_SEP}$val"
    done < <(
      for vf in $(yq_lines "$YQ_HELM_VALUES_FILES" "$kfile" || true); do
        if [[ -f "$(dirname "$kfile")/$vf" ]]; then
          yq_lines "$YQ_FILE_LEAVES" "$(dirname "$kfile")/$vf" | sed "s|^|$vf${YQ_SEP}|"
        fi
      done)
    ns=${COMP_NS[$comp]:-}
    while IFS="$YQ_SEP" read -r c key val; do
      [[ -n $key ]] || continue
      port=''
      if [[ $key =~ $RE_PORT_KEY && $val =~ ^[0-9]+$ ]]; then port=$val
      elif [[ $val =~ $RE_ADDR ]]; then port=${BASH_REMATCH[1]}
      fi
      [[ -n $port ]] || continue
      if [[ -z $ns || $ns == "-" || ${NS_ALL_PORTS[$ns]:-} != *" $port "* ]]; then
        warn "5.4 POL-port-unknown" "$rk helm values $key=$val: 포트 $port 이(가) ns '${ns:-?}'의 정책 포트에 없음(내부 포트면 무시, 노출 포트면 정책·계약 갱신)"
      fi
    done < <(printf '%s\n' "$leaves")
  done
  finish_group "5.4 POL-port" "각주 포트 ↔ 정책 ingress 포트 일치 · helm values 포트 ↔ 각주 일치" "$f4"

  # 5.5 LimitRange: default.cpu · max.cpu 금지
  local f5=$N_FAIL ltype dcpu mcpu
  collect_rows "$YQ_LR" "5.5 POL-limitrange" file
  while IFS="$YQ_SEP" read -r i ns name ltype dcpu mcpu; do
    [[ -n $i ]] || continue
    x="${SRC_LABEL[$i]} LimitRange/$ns/${name}[$ltype]"
    [[ $dcpu == "-" ]] || fail "5.5 POL-limitrange" "$x: default.cpu=$dcpu 금지(CPU limit 없음 — defaultRequest.cpu만)"
    [[ $mcpu == "-" ]] || fail "5.5 POL-limitrange" "$x: max.cpu=$mcpu 금지"
  done < <(printf '%s' "$ROWS")
  finish_group "5.5 POL-limitrange" "LimitRange에 default.cpu·max.cpu 없음" "$f5"
}

# -----------------------------------------------------------------------------
# 검사 6 — 작성자(봇) 경로 lint
# -----------------------------------------------------------------------------
check_6_author() {
  header 6 "작성자 검사(봇 PR은 apps/*/overlays/dev/kustomization.yaml의 images[].digest 줄만)"
  local fails_before=$N_FAIL is_bot=0 b f n=0 diff_text='' line content a_path b_path
  local -a arr_bots
  if [[ -z $PR_AUTHOR ]]; then
    # PR 이벤트(또는 명시 요구)인데 작성자가 비어 있으면 검사 6이 조용히 꺼진 것이므로 fail-closed
    if [[ $GH_EVENT == pull_request || $GH_EVENT == pull_request_target || $REQUIRE_AUTHOR == 1 ]]; then
      fail "6 AUTHOR-input" "PR 이벤트(GITHUB_EVENT_NAME='$GH_EVENT', VALIDATE_REQUIRE_AUTHOR=$REQUIRE_AUTHOR)인데 PR_AUTHOR가 비어 있음 — 작성자 lint의 조용한 비활성 금지"
      return 0
    fi
    pass "6 AUTHOR" "PR 작성자 미지정(push 이벤트 등) — 봇 경로 lint 대상 없음"
    return 0
  fi
  IFS=',' read -r -a arr_bots <<< "$BOT_AUTHORS"
  for b in "${arr_bots[@]}"; do
    if [[ $PR_AUTHOR == "$b" ]]; then is_bot=1; fi
  done
  if [[ $is_bot == 0 ]]; then
    pass "6 AUTHOR" "작성자 '$PR_AUTHOR'는 봇 아님 — 경로 제한 없음(ruleset·리뷰가 게이트)"
    return 0
  fi
  # 입력: CHANGED_DIFF(+CHANGED_FILES) 또는 git(VALIDATE_BASE_SHA·VALIDATE_HEAD_SHA). 없으면 fail-closed
  if [[ -n $CHANGED_DIFF ]]; then
    [[ -f $CHANGED_DIFF ]] || { fail "6 AUTHOR-input" "diff 파일 없음: $CHANGED_DIFF"; return 0; }
    diff_text=$(tr -d '\r' < "$CHANGED_DIFF")
  elif [[ -n $BASE_SHA && -n $HEAD_SHA ]]; then
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      [[ -n $CHANGED_FILES ]] || CHANGED_FILES=$(git -C "$ROOT" diff --name-only "$BASE_SHA" "$HEAD_SHA" | tr -d '\r')
      diff_text=$(git -C "$ROOT" diff "$BASE_SHA" "$HEAD_SHA" | tr -d '\r')
    else
      fail "6 AUTHOR-input" "봇 작성자 '$PR_AUTHOR'인데 git 저장소가 아니라 diff를 계산할 수 없음"
      return 0
    fi
  fi
  if [[ -z $CHANGED_FILES || -z $diff_text ]]; then
    fail "6 AUTHOR-input" "봇 작성자 '$PR_AUTHOR'인데 변경 파일 목록/diff 입력이 없음(CHANGED_FILES+CHANGED_DIFF 또는 VALIDATE_BASE_SHA+VALIDATE_HEAD_SHA) — fail-closed"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    n=$((n + 1))
    [[ $f =~ $RE_BOT_FILE ]] || fail "6 AUTHOR-file" "봇 '$PR_AUTHOR'의 변경 파일 '$f' 불허(apps/*/overlays/dev/kustomization.yaml만)"
  done < <(printf '%s\n' "$CHANGED_FILES")
  [[ $n -gt 0 ]] || fail "6 AUTHOR-file" "봇 '$PR_AUTHOR' PR에 변경 파일이 없음"
  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        a_path=${line#diff --git a/}; b_path=${a_path#* b/}; a_path=${a_path%% b/*}
        [[ $a_path == "$b_path" ]] || fail "6 AUTHOR-file" "봇 diff: 이름 변경 불허 ($a_path → $b_path)"
        [[ $b_path =~ $RE_BOT_FILE ]] || fail "6 AUTHOR-file" "봇 diff: 파일 '$b_path' 불허"
        ;;
      "new file mode"*|"deleted file mode"*|"rename "*|"similarity index"*|"Binary files"*|"old mode"*|"new mode"*)
        fail "6 AUTHOR-file" "봇 diff: 파일 추가·삭제·이름/모드 변경 불허 ($line)" ;;
      "--- "*|"+++ "*|"@@"*|"index "*|" "*|"\\"*|"") ;;
      "+"*|"-"*)
        content=${line:1}
        [[ $content =~ $RE_BOT_LINE ]] || fail "6 AUTHOR-line" "봇 diff: images[].digest 외 줄 변경 불허 → '${content}'"
        ;;
      *) fail "6 AUTHOR-line" "봇 diff: 해석할 수 없는 줄 → '$line'" ;;
    esac
  done < <(printf '%s\n' "$diff_text")
  finish_group "6 AUTHOR" "봇 '$PR_AUTHOR' PR: 변경 파일 ${n}개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest" "$fails_before"
}

# -----------------------------------------------------------------------------
# 검사 7 — sync-wave 단일 표 · platform/ 디렉터리
# -----------------------------------------------------------------------------
declare -A WAVE_OF=() COMP_NS=()
load_wave_table() {
  local c w n
  while read -r c w n; do [[ -n $c ]] || continue; WAVE_OF[$c]=$w; COMP_NS[$c]=$n; done <<< "$WAVE_TABLE"
}
check_7_sync_wave() {
  header 7 "sync-wave = 계약 §sync-wave 단일 표 · 표에 없는 platform/<component>/ 금지"
  local f1=$N_FAIL n=0 i name wave path opts comp expected want_path x
  if need_tool "7.1 WAVE" yq; then
    collect_rows "$YQ_APP" "7.1 WAVE" file
    while IFS="$YQ_SEP" read -r i name wave path opts; do
      [[ -n $i ]] || continue
      n=$((n + 1))
      x="${SRC_LABEL[$i]} Application/$name"
      if [[ $name == root ]]; then
        # root app(app-of-apps 진입점, 수동 apply)은 bootstrap/root-app.yaml 에서 clusters/oci-k3s/apps 를 가리킬 때만 표 밖
        if [[ ${SRC_PATH[$i]} != bootstrap/root-app.yaml || $path != clusters/oci-k3s/apps ]]; then
          fail "7.1 WAVE-name" "$x: 'root'는 bootstrap/root-app.yaml에서 source.path clusters/oci-k3s/apps 로만 허용(현재 위치 ${SRC_PATH[$i]}, path '$path', wave $wave)"
        fi
        continue
      elif [[ $name =~ ^platform-(.+)$ ]]; then
        comp=${BASH_REMATCH[1]}
        if [[ -z ${WAVE_OF[$comp]:-} ]]; then
          fail "7.1 WAVE-unknown" "$x: 컴포넌트 '$comp'는 §sync-wave 단일 표에 없음(계약을 먼저 고친다)"
          continue
        fi
        expected=${WAVE_OF[$comp]}
        want_path="platform/$comp"
        if [[ $comp == argocd ]]; then
          [[ $path == platform/argocd || $path == bootstrap/argocd ]] || fail "7.1 WAVE-path" "$x: source.path '$path' ≠ platform/argocd|bootstrap/argocd"
        else
          [[ $path == "$want_path" ]] || fail "7.1 WAVE-path" "$x: source.path '$path' ≠ $want_path"
        fi
      elif [[ $name =~ ^(.+)-(dev|prod)$ ]]; then
        expected=$APP_WAVE
        want_path="apps/${BASH_REMATCH[1]}/overlays/${BASH_REMATCH[2]}"
        [[ $path == "$want_path" ]] || fail "7.1 WAVE-path" "$x: source.path '$path' ≠ $want_path"
      else
        fail "7.1 WAVE-name" "$x: 이름 규약 위반(platform-<component> · <pod>-<env> · root)"
        continue
      fi
      if [[ $wave == "-" ]]; then
        fail "7.1 WAVE-missing" "$x: argocd.argoproj.io/sync-wave 어노테이션 없음(기대 $expected)"
      elif [[ $wave != "$expected" ]]; then
        fail "7.1 WAVE-mismatch" "$x: sync-wave $wave ≠ 표 $expected"
      fi
    done < <(printf '%s' "$ROWS")
    finish_group "7.1 WAVE" "Application ${n}개 sync-wave·이름·경로 = 단일 표" "$f1"
  fi
  local f2=$N_FAIL d dn cnt=0
  if [[ -d "$ROOT/platform" ]]; then
    for d in "$ROOT"/platform/*/; do
      [[ -d $d ]] || continue
      dn=$(basename "$d"); cnt=$((cnt + 1))
      [[ -n ${WAVE_OF[$dn]:-} ]] || fail "7.2 WAVE-dir" "platform/$dn/: §sync-wave 단일 표에 없는 디렉터리(표를 먼저 고친다)"
    done
  fi
  finish_group "7.2 WAVE-dir" "platform/ 디렉터리 ${cnt}개 모두 단일 표에 있음" "$f2"
}

# -----------------------------------------------------------------------------
# 검사 8 — gitleaks(파일 스캔). 대상 0개면 FAIL(빈 트리에서 조용히 통과하지 않음)
# -----------------------------------------------------------------------------
check_8_gitleaks() {
  header 8 "gitleaks 파일 스캔(대상 0개면 FAIL)"
  local fails_before=$N_FAIL targets out rc
  targets=$(find "$ROOT" -type f -not -path '*/.git/*' -not -name '.gitkeep' -not -name '.keep' | wc -l | tr -d '[:space:]')
  if [[ $targets -eq 0 ]]; then
    fail "8 LEAK-no-target" "스캔 대상 파일 0개 — 빈 트리는 통과가 아니라 실패다"
    return 0
  fi
  need_tool "8 LEAK" gitleaks || return 0
  rc=0
  if gitleaks dir --help >/dev/null 2>&1; then
    out=$(gitleaks dir "$ROOT" --no-banner --no-color --redact --exit-code 1 2>&1) || rc=$?
  else
    out=$(gitleaks detect --no-git --source "$ROOT" --no-banner --no-color --redact --exit-code 1 2>&1) || rc=$?
  fi
  case $rc in
    0) ;;
    1) fail "8 LEAK" "gitleaks가 비밀 후보를 찾음: $(printf '%s' "$out" | tr -d '\r' | grep -E 'Finding|File|RuleID|Fingerprint' | head -n 8 | tr '\n' ' ')" ;;
    *) fail "8 LEAK" "gitleaks 실행 오류(rc=$rc): $(printf '%s' "$out" | tr -d '\r' | tail -n 3 | tr '\n' ' ')" ;;
  esac
  finish_group "8 LEAK" "gitleaks 파일 스캔 대상 ${targets}개, 비밀 없음" "$fails_before"
}

# -----------------------------------------------------------------------------
# 실행
# -----------------------------------------------------------------------------
load_wave_table
check_1_kustomize
check_1b_plain
check_2_app_ssa
check_3_externalsecrets
check_3_workloads
check_4_images
check_5_policies
check_6_author
check_7_sync_wave
check_8_gitleaks

printf '\n== 요약 ==\n'
printf 'PASS %d · FAIL %d · WARN %d · SKIP %d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
if [[ ${#FAIL_LINES[@]} -gt 0 ]]; then
  printf '실패 목록:\n'
  for l in "${FAIL_LINES[@]}"; do printf '  - %s\n' "$l"; done
fi
if [[ $N_SKIP -gt 0 ]]; then
  printf '주의: SKIP %d개 — 도구가 없어 건너뛴 검사가 있으므로 이 결과는 CI 기준으로 불완전하다.\n' "$N_SKIP"
fi
if [[ $N_FAIL -gt 0 ]]; then
  printf '결과: FAIL\n'
  exit 1
fi
printf '결과: PASS\n'
exit 0
