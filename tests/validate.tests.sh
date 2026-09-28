#!/usr/bin/env bash
# =============================================================================
# tests/validate.tests.sh — tests/validate.sh 자기검사 (T033)
#
# tests/fixtures/<case>/ 마다 validate.sh를 --root 로 돌려 기대 exit 코드와 메시지(있어야/없어야)를 단언한다.
#   - positive/            : 계약을 만족하는 최소 완전 트리 → exit 0
#   - 그 밖의 디렉터리      : 검사 항목별 부정 픽스처(각 항목이 실제로 FAIL 코드를 내는 최소 예시) → exit 1 + 코드
#                            ⚠ 부분 트리 픽스처의 exit 1은 판정 근거가 아니다 — 무관한 검사(5.x 등)도 FAIL하므로 결함이 없어도 1이다.
#                            근거는 그 하위 검사에 고유한 `+[FAIL] <코드> — …` 단언과, 그룹 PASS 줄이 없다는 `-[PASS] <코드>` 음성 단언이다
#   - author/*.diff        : 검사 6(봇 작성자) 입력 — positive 트리 위에서 환경변수로 넘긴다
# 실제 트리 검사(validate.sh 기본 실행)는 tests/ 를 제외하므로 픽스처가 실제 결과에 섞이지 않는다.
#
# 도구가 없으면 VALIDATE_SKIP_TOOLS=1로 내려가 실행한다(어떤 검사가 SKIP되는지 출력). yq(mikefarah)가 없으면
# 대부분의 단언이 성립할 수 없으므로 즉시 실패한다(fail-closed). VALIDATE_TESTS_REQUIRE_TOOLS=1 또는 CI=true 이면
# 도구 누락 시 SKIP 모드로 내려가지 않고 exit 1 (CI에서 조용히 불완전한 결과가 통과하지 않도록).
# 각 케이스는 env -u 로 작성자 관련 환경변수를 지우고 시작한다(CI의 GITHUB_EVENT_NAME 등이 새지 않도록).
#
# 부분 실행: VALIDATE_TESTS_ONLY='<bash 확장 정규식>'이면 이름이 맞는 케이스만 돌리고 나머지는 건너뛴다(건너뛴 수를 센다).
#   요약 줄이 "부분 실행 — 필터 '…' · 건너뜀 N"을 드러내고, 맞는 케이스가 0개면 exit 1이다(빈 실행을 통과로 읽지 않는다).
#   예: VALIDATE_TESTS_ONLY='^(positive|app-source-)' bash tests/validate.tests.sh
#   ⚠ 부분 실행은 반복 작업용이다 — PR·과제 마무리 판정은 필터 없는 전체 실행으로 한다(tests/README.md). 비어 있으면 필터 없음.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATE="$HERE/validate.sh"
FIX="$HERE/fixtures"

missing=()
for t in yq kustomize kubeconform gitleaks; do
  if command -v "$t" >/dev/null 2>&1; then
    if [[ $t == yq ]] && ! yq --version 2>/dev/null | grep -q mikefarah; then missing+=("yq(mikefarah 아님)"); fi
  else
    missing+=("$t")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  if [[ ${VALIDATE_TESTS_REQUIRE_TOOLS:-0} == 1 || ${CI:-} == true ]]; then
    printf '도구 없음: %s — VALIDATE_TESTS_REQUIRE_TOOLS=1/CI=true 이므로 SKIP 모드로 내려가지 않고 실패한다(exit 1)\n' "${missing[*]}"
    exit 1
  fi
  printf '도구 없음: %s → VALIDATE_SKIP_TOOLS=1 로 실행(해당 검사는 SKIP, 결과는 CI 기준으로 불완전)\n' "${missing[*]}"
  export VALIDATE_SKIP_TOOLS=1
  for m in "${missing[@]}"; do
    if [[ $m == yq* ]]; then printf 'yq(mikefarah)가 없으면 자기검사를 수행할 수 없다 — 설치 후 다시 실행\n'; exit 1; fi
  done
fi

N=0; NF=0
FAILED=()

# 부분 실행 필터(머리 주석 「부분 실행」). 정규식이 틀리면 조용히 0건이 되지 않도록 먼저 거른다([[ =~ ]]는 2를 돌려준다).
ONLY=${VALIDATE_TESTS_ONLY:-}
NSKIP=0
if [[ -n $ONLY ]]; then
  # 부분 실행은 반복 작업용이다. CI와 판정용 실행(도구 누락 규칙과 같은 두 스위치)에서는 부분 실행의 exit 0이 "전체 통과"로
  # 읽히지 않도록 아예 실행하지 않는다(2026-09-28 범위 한정 검증 DV-4).
  if [[ ${VALIDATE_TESTS_REQUIRE_TOOLS:-0} == 1 || ${CI:-} == true ]]; then
    printf "VALIDATE_TESTS_ONLY='%s' — VALIDATE_TESTS_REQUIRE_TOOLS=1/CI=true 에서는 부분 실행을 허용하지 않는다(exit 1)\n" "$ONLY"
    exit 1
  fi
  only_rc=0
  [[ '' =~ $ONLY ]] || only_rc=$?
  if [[ $only_rc == 2 ]]; then
    printf "VALIDATE_TESTS_ONLY='%s'는 bash 확장 정규식이 아니다 — 실행하지 않는다(exit 1)\n" "$ONLY"
    exit 1
  fi
fi
# selected <케이스 이름> — 필터가 없거나 이름이 맞으면 0. 아니면 건너뜀을 세고 1
selected() {
  if [[ -z $ONLY ]] || [[ $1 =~ $ONLY ]]; then return 0; fi
  NSKIP=$((NSKIP + 1))
  return 1
}

# run_case <이름> <root> <기대 exit> [--env K=V]... [+있어야 할 문자열 | -있으면 안 되는 문자열]...
run_case() {
  selected "$1" || return 0
  local name=$1 root=$2 want=$3; shift 3
  local -a envs=() asserts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) envs+=("$2"); shift 2 ;;
      *) asserts+=("$1"); shift ;;
    esac
  done
  local out rc=0 ok=1 a
  out=$(env -u GITHUB_EVENT_NAME -u VALIDATE_REQUIRE_AUTHOR -u PR_AUTHOR -u CHANGED_FILES -u CHANGED_DIFF \
        -u VALIDATE_BASE_SHA -u VALIDATE_HEAD_SHA "${envs[@]}" bash "$VALIDATE" --root "$root" 2>&1) || rc=$?
  N=$((N + 1))
  local problems=()
  if [[ $rc != "$want" ]]; then ok=0; problems+=("exit $rc ≠ 기대 $want"); fi
  for a in "${asserts[@]}"; do
    case "$a" in
      +*) [[ $out == *"${a:1}"* ]] || { ok=0; problems+=("없음: ${a:1}"); } ;;
      -*) [[ $out != *"${a:1}"* ]] || { ok=0; problems+=("있으면 안 됨: ${a:1}"); } ;;
    esac
  done
  if [[ $ok == 1 ]]; then
    printf '[PASS] %s\n' "$name"
  else
    NF=$((NF + 1)); FAILED+=("$name")
    printf '[FAIL] %s\n' "$name"
    local p; for p in "${problems[@]}"; do printf '       - %s\n' "$p"; done
    printf '       --- validate.sh 출력(FAIL/WARN/SKIP 줄) ---\n'
    printf '%s\n' "$out" | grep -E '^\[(FAIL|WARN|SKIP)\]|^error' | sed 's/^/       | /' || true
  fi
  # 첫 케이스(positive)의 SKIP 줄은 투명성을 위해 보여준다
  if [[ $name == positive ]]; then
    printf '%s\n' "$out" | grep -E '^\[SKIP\]' | sed 's/^/       /' || true
  fi
}

DIGEST_FILE='apps/identity-admin/overlays/dev/kustomization.yaml'

# 도구 의존 검사의 PASS 단언은 도구가 있을 때만(없으면 SKIP이 정답)
positive_asserts=('+[PASS] 2 APP-SSA' '+[PASS] 3 ES' '+[PASS] 3.5 ES-⑤⑥' '+[PASS] 4a IMG-newTag'
  '+[PASS] 5.1 POL-ns' '+[PASS] 5.2 POL-set' '+[PASS] 5.3 POL-egress' '+[PASS] 5.4 POL-port' '+[PASS] 5.5 POL-limitrange'
  '+[PASS] 5.6 POL-webhook-src'
  '+[PASS] 6 AUTHOR' '+[PASS] 7.1 WAVE' '+[PASS] 7.2 WAVE-dir' '+[PASS] 7.3 WAVE-secrets-base'
  '+[PASS] 7.4 APP-source — Application 24개(파일+렌더링) spec.source 키 = {path, repoURL, targetRevision}'
  '+[PASS] 9.1 CSS-set' '+[PASS] 9.2 CSS-auth' '+[PASS] 9.3 CSS-k8s' '+[PASS] 9.4 CSS-conditions'
  '+결과: PASS' '-[FAIL]')
if command -v kustomize >/dev/null 2>&1 && command -v kubeconform >/dev/null 2>&1; then
  # 5.6 PASS 줄의 소스 수는 kustomize 유무로 갈린다(SKIP 모드에서는 "렌더 0" — 한계 절 참조)
  # ES 수: `secrets/<ns>`의 ES는 파일 · 자기 디렉터리 렌더 · 배달자 렌더로 3번 세어진다 —
  # 배달자에 ns를 하나 더하면 +3이다(T045 G4에서 두 번째 ns를 더해 23 → 26).
  positive_asserts+=('+[PASS] 1 KUST' '+[PASS] 1b KUST-plain' '+ExternalSecret 26개(파일+렌더링)'
    '+webhook 정책을 담은 소스: 원본 1 · 렌더 1'
    # 검사 10(T046): 긍정 트리의 platform/reloader는 순수 매니페스트라 helm 없이 렌더된다(kustomize만 필요).
    #   ⚠ VD-9 시험 대상 제거 PR(G2)에서 `Deployment 2`·`합계 13`·`vd9-probe ns jt-dev`가 바뀐다(platform/reloader/README.md §4)
    '+[PASS] 10 REL — platform/reloader (rendered): ClusterRole·ClusterRoleBinding 0 · Deployment reloader/reloader args = ["--log-level=info","--namespaces=identity,jt-dev,jt-prod,reloader","--reload-strategy=annotations"] · kind {ServiceAccount 1 · Deployment 2 · Role 5 · RoleBinding 5}(합계 13) · vd9-probe ns jt-dev · Role·RoleBinding ns 집합 = {identity,jt-dev,jt-prod,reloader} · RoleBinding → 같은 ns의 Role · 주체 = ServiceAccount reloader/reloader · reloader-role 규칙 동일·와일드카드 없음 · Reloader 이미지 컨테이너 1개(containers.0 · command 없음)')
else
  positive_asserts+=('+webhook 정책을 담은 소스: 원본 1 · 렌더 0')
fi
if command -v gitleaks >/dev/null 2>&1; then
  positive_asserts+=('+[PASS] 8 LEAK')
fi

# --- 긍정 ---------------------------------------------------------------------
run_case positive "$FIX/positive" 0 "${positive_asserts[@]}"

# --- 1b: kustomization 밖 매니페스트 스키마 오류(kubeconform 없으면 SKIP이 정답) ----------
kust_plain_asserts=()
if command -v kubeconform >/dev/null 2>&1; then
  kust_plain_asserts+=('+[FAIL] 1b KUST-plain — kubeconform 실패: clusters/oci-k3s/apps/bad-app.yaml')
else
  kust_plain_asserts+=('+[SKIP] 1b KUST-plain — 도구 없음(kubeconform)')
fi
run_case kust-plain "$FIX/kust-plain" 1 "${kust_plain_asserts[@]}"

# --- ExternalSecret 규약 보강(3.0) · ①–⑦ ---------------------------------------
run_case es-0-conventions "$FIX/es-0-conventions" 1 \
  "+[FAIL] 3.0 ES-apiVersion — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-apiversion: apiVersion=external-secrets.io/v1beta1" \
  "+[FAIL] 3.0 ES-store — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-storekind: secretStoreRef.kind=SecretStore" \
  "+[FAIL] 3.0 ES-store — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-unknown-store: 알 수 없는 store 'vault-all'" \
  "+[FAIL] 3.0 ES-dataFrom — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-datafrom-find: dataFrom은 extract.key만 허용" \
  "+[FAIL] 3.0 ES-sourceRef — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-data-sourceref: data[]/dataFrom[].sourceRef" \
  "+[FAIL] 3.0 ES-sourceRef — apps/identity-admin/base/externalsecrets.yaml ExternalSecret/-/es-datafrom-sourceref: data[]/dataFrom[].sourceRef"
run_case es-1-key-regex "$FIX/es-1-key-regex" 1 \
  "+[FAIL] 3.1 ES-① — apps/identity-admin/base/externalsecret.yaml ExternalSecret/jt-dev/identity-admin-env: remoteRef.key 'dev/DB/Identity Admin'" \
  "+remoteRef.key 'secret/data/dev/db/identity_admin' 정규식 위반"
run_case es-2-scope-location "$FIX/es-2-scope-location" 1 \
  "+[FAIL] 3.2 ES-② — apps/identity-admin/overlays/dev/externalsecret.yaml ExternalSecret/jt-dev/identity-admin-env: 위치 'apps/identity-admin/overlays/dev/externalsecret.yaml'는 store vault-dev 이어야 함(현재 vault-prod)" \
  "+key 'prod/db/identity_admin/app'는 'dev/' 접두여야 함" \
  "+[FAIL] 3.2 ES-② — secrets/vault/externalsecret.yaml ExternalSecret/vault/vault-backup-oci: 위치 'secrets/vault/externalsecret.yaml'의 key 'dev/oci/backup-credentials'는 'platform/' 접두여야 함"
run_case es-3-data-store "$FIX/es-3-data-store" 1 \
  "+[FAIL] 3.3 ES-③ — platform/authentik/externalsecrets.yaml ExternalSecret/identity/authentik-bad-store: 위치 'platform/authentik/externalsecrets.yaml'의 store 'vault-dev' 불허" \
  "+[FAIL] 3.3 ES-③ — platform/authentik/externalsecrets.yaml ExternalSecret/identity/authentik-bad-prefix: vault-data key 'dev/authentik/identity-admin'는 열거 접두 밖"
run_case es-4-ca-mirror "$FIX/es-4-ca-mirror" 1 \
  "+[FAIL] 3.4 ES-④ — platform/cnpg-databases/ca-mirror.yaml ExternalSecret/jt-dev/pg-main-ca-datafrom: k8s-data-ca에 dataFrom 금지" \
  "+ExternalSecret/jt-prod/pg-main-ca-key: k8s-data-ca key 'pg-main-ca' property='ca.key' (ca.crt만)" \
  "+ExternalSecret/identity/pg-main-server: k8s-data-ca key 'pg-main-server' 불허"
run_case es-5-migrate-envfrom "$FIX/es-5-migrate-envfrom" 1 \
  "+[FAIL] 3.5 ES-⑤ — apps/identity-admin/base/workloads.yaml Deployment/jt-dev/identity-admin: Secret 'identity-admin-migrate' 참조 금지" \
  "+[FAIL] 3.5 ES-⑤ — apps/identity-admin/base/workloads.yaml CronJob/jt-dev/identity-admin-cleanup: Secret 'identity-admin-migrate' 참조 금지" \
  '-Job/jt-dev/identity-admin-migrate-job'
run_case es-6-automount "$FIX/es-6-automount" 1 \
  "+[FAIL] 3.6 ES-⑥ — apps/identity-admin/base/deployment.yaml Deployment/jt-dev/identity-admin: automountServiceAccountToken: false 필요(현재 null)" \
  "+[FAIL] 3.6 ES-⑥ — platform/cloudflared/deployment.yaml Deployment/cloudflared/cloudflared: automountServiceAccountToken: false 필요(현재 true)" \
  '-platform/vault/deployment.yaml'
run_case es-7-workers-path "$FIX/es-7-workers-path" 1 \
  "+[FAIL] 3.7 ES-⑦ — apps/identity-admin/base/externalsecret-env.yaml ExternalSecret/-/identity-admin-env: apps/**의 key 'dev/access/service-token'는 Workers 전용 경로" \
  "+key 'dev/web/session'는 Workers 전용 경로"

# --- 이미지 -------------------------------------------------------------------
run_case img-newtag "$FIX/img-newtag" 1 \
  "+[FAIL] 4a IMG-newTag — apps/identity-admin/overlays/dev/kustomization.yaml images[ghcr.io/joshua92y/identity-admin]: newTag='v1.2.3' 금지" \
  "+images[ghcr.io/joshua92y/relay]: digest 'sha256:abc' 형식 오류"
run_case img-platform-digest "$FIX/img-platform-digest" 1 \
  "+[WARN] 4b IMG-platform-digest — platform/cloudflared/deployment.yaml: image 'cloudflare/cloudflared:2026.1.0'에 @sha256 digest 없음" \
  '-[FAIL] 4b' "-image 'busybox:1.37@sha256" \
  '+[PASS] 4b IMG-platform-digest — platform/** image: 줄 2개 중 digest 없는 줄 1개(경고만)'

# --- 정책 ---------------------------------------------------------------------
run_case pol-ns-set "$FIX/pol-ns-set" 1 \
  "+[FAIL] 5.1 POL-ns — Namespace 'reloader' 누락(계약 표 14개)" \
  "+[FAIL] 5.1 POL-ns — Namespace 'observability'는 계약 표에 없음(초과)" \
  "+[FAIL] 5.1 POL-ns — Namespace 'argocd' 중복 선언"
run_case pol-policy-set "$FIX/pol-policy-set" 1 \
  "+[FAIL] 5.2 POL-set — ns 'argocd'에 정책 'default-deny' 없음" \
  "+[FAIL] 5.2 POL-set — ns 'kube-system'에 정책 'deny-imds' 없음" \
  "+[FAIL] 5.2 POL-set — 정책 'deny-imds'은 kube-system 전용 — ns 'jt-dev'에 있으면 안 됨" \
  "+[FAIL] 5.2 POL-set — 정책 'allow-imds'은 vault 전용 — ns 'identity'에 있으면 안 됨" \
  "+NetworkPolicy/default-deny: metadata.namespace 없음"
run_case pol-egress-ipblock "$FIX/pol-egress-ipblock" 1 \
  "+[FAIL] 5.3 POL-egress-ports — platform/policies/policies.yaml NetworkPolicy/jt-dev/allow-egress-all ipBlock 0.0.0.0/0: ports 없음" \
  "+[FAIL] 5.3 POL-egress-except — platform/policies/policies.yaml NetworkPolicy/jt-dev/allow-egress-443 ipBlock 0.0.0.0/0: except 누락 → 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" \
  "+[FAIL] 5.3 POL-imds — platform/policies/policies.yaml NetworkPolicy/jt-dev/allow-imds-wrong-ns ipBlock 169.254.169.254/32: IMDS 도달은 vault(allow-imds)만 허용" \
  "+[FAIL] 5.3 POL-egress — platform/policies/policies.yaml NetworkPolicy/kube-system/deny-imds ipBlock 10.0.0.0/8: deny-imds는 cidr 0.0.0.0/0 + except 169.254.169.254/32 이어야 함"
run_case pol-port "$FIX/pol-port" 1 \
  "+[FAIL] 5.4 POL-port-table — ns 'vault' 포트 8200(vault): 계약 §포트 출처 각주의 포트가 platform/policies의 ingress ports에 없음" \
  "+[FAIL] 5.4 POL-port-values — platform/vault/kustomization.yaml helm values .server.service.port=8300: 계약 §포트 출처 각주 8200 와 다름" \
  "+[FAIL] 5.4 POL-port-values — platform/vault/kustomization.yaml helm values .server.service.targetPort=8300" \
  "+[WARN] 5.4 POL-port-unknown — platform/vault/kustomization.yaml helm values ui.servicePortHttp=8300: 포트 8300 이(가) ns 'vault'의 정책 포트에 없음" \
  '-helm values server.extraArgs' \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook #1: 계약 포트 8200 밖의 ingress 규칙 — ports [8201]" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook: 계약 포트 8200을 가진 ingress 규칙이 없음"
run_case pol-limitrange "$FIX/pol-limitrange" 1 \
  "+[FAIL] 5.5 POL-limitrange — platform/policies/limitrange.yaml LimitRange/jt-dev/defaults[Container]: default.cpu=500m 금지" \
  "+LimitRange/jt-dev/defaults[Container]: max.cpu=2 금지"
# 5.6(set): 출발 ipBlock 집합 · 중복 cidr · peer(ipBlock 아닌 peer·except) · 포트(집합·endPort·계약 밖 규칙)
run_case pol-webhook-src-set "$FIX/pol-webhook-src/set" 1 \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/external-secrets/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치 — 빠짐 [10.42.0.0/32] 여분 []" \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/cert-manager/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치 — 빠짐 [] 여분 [10.0.0.10/32, 10.0.0.0/24]" \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치 — 빠짐 [] 여분 [10.42.0.0/32]" \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/cnpg-system/allow-apiserver-webhook #1: 중복 cidr 10.42.0.0/32" \
  "+[FAIL] 5.6 POL-webhook-peer — platform/policies/policies.yaml NetworkPolicy/cert-manager/allow-apiserver-webhook #1: ipBlock에 except 1개 금지" \
  "+[FAIL] 5.6 POL-webhook-peer — platform/policies/policies.yaml NetworkPolicy/cnpg-system/allow-apiserver-webhook #1: from에 ipBlock 아닌 peer 1개" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/cnpg-system/allow-apiserver-webhook #1: endPort 1개 금지" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/external-secrets/allow-apiserver-webhook #2: 계약 포트 10250 밖의 ingress 규칙 — ports 없음(전 포트 개방)" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook #1: ports 집합 [8200,8201] ≠ 계약 포트 {8200}" \
  '-NetworkPolicy/cnpg-system/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치'
# 5.6(shape): 혼합 peer · 한 문자열 cidr · 문자열 포트 · protocol / 표 밖 ns의 동명 정책은 5.2 EXCLUSIVE가 잡는다
run_case pol-webhook-src-shape "$FIX/pol-webhook-src/shape" 1 \
  "+[FAIL] 5.6 POL-webhook-peer — platform/policies/policies.yaml NetworkPolicy/cert-manager/allow-apiserver-webhook #1: from에 ipBlock 아닌 peer 1개" \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/external-secrets/allow-apiserver-webhook #1: cidr 값 형식 위반 [10.0.7.78/32,10.42.0.0/32]" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/cnpg-system/allow-apiserver-webhook #1: 정수가 아닌 port 1개" \
  "+[FAIL] 5.6 POL-webhook-port — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook #1: protocol [UDP] ≠ TCP" \
  "+[FAIL] 5.6 POL-webhook-src — platform/policies/policies.yaml NetworkPolicy/vault/allow-apiserver-webhook #1: cidr 값 형식 위반 — 순수 ipBlock peer 2개인데 파싱된 cidr 1개" \
  "+[FAIL] 5.2 POL-set — 정책 'allow-apiserver-webhook'은 cert-manager,external-secrets,cnpg-system,vault 전용 — ns 'data'에 있으면 안 됨" \
  '-NetworkPolicy/cert-manager/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치' \
  '-NetworkPolicy/external-secrets/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치'
# 5.6(render): 원본은 정확하지만 kustomize patches가 렌더에서 출발지를 넓히는 경우(kustomize 없으면 SKIP이 정답)
webhook_render_asserts=()
if command -v kustomize >/dev/null 2>&1; then
  webhook_render_asserts+=("+[FAIL] 5.6 POL-webhook-src — platform/policies (rendered) NetworkPolicy/external-secrets/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치 — 빠짐 [] 여분 [0.0.0.0/0]" \
    '-platform/policies/policies.yaml NetworkPolicy/external-secrets/allow-apiserver-webhook #1: 출발 ipBlock 집합 불일치')
else
  webhook_render_asserts+=('+[SKIP] 1 KUST — 도구 없음(kustomize)')
fi
run_case pol-webhook-src-render "$FIX/pol-webhook-src/render" 1 "${webhook_render_asserts[@]}"
# 5.6(render-shape): 렌더에서 ns를 옮기거나 이름을 바꾸거나 kind: List로 숨긴 경우(원본 파일 기준 검사는 통과한다)
webhook_shape_asserts=()
if command -v kustomize >/dev/null 2>&1; then
  webhook_shape_asserts+=("+[FAIL] 5.6 POL-webhook-src — platform/policies (rendered) NetworkPolicy/monitoring/allow-apiserver-webhook: 표 밖 ns(렌더 결과에만 보인다" \
    "+[FAIL] 5.6 POL-webhook-src — platform/policies (rendered) NetworkPolicy/data/allow-apiserver-webhook: 표 밖 ns(렌더 결과에만 보인다" \
    "+[FAIL] 5.6 POL-webhook-src — platform/policies (rendered): ns 'cnpg-system'에 allow-apiserver-webhook 없음" \
    "+[FAIL] 5.6 POL-webhook-src — platform/policies (rendered): ns 'external-secrets'에 allow-apiserver-webhook 없음" \
    '-platform/policies/policies.yaml NetworkPolicy/cert-manager/allow-apiserver-webhook')
else
  webhook_shape_asserts+=('+[SKIP] 1 KUST — 도구 없음(kustomize)')
fi
run_case pol-webhook-src-render-shape "$FIX/pol-webhook-src/render-shape" 1 "${webhook_shape_asserts[@]}"
run_case pol-location "$FIX/pol-location" 1 \
  "+[FAIL] 5.0 POL-location — apps/identity-admin/base/networkpolicy.yaml NetworkPolicy/allow-all: 정책 객체(Namespace·NetworkPolicy·ResourceQuota·LimitRange)는 platform/policies/ 에만 둔다"

# --- Application · sync-wave -------------------------------------------------
run_case wave-and-app "$FIX/wave-and-app" 1 \
  "+[FAIL] 2 APP-SSA — clusters/oci-k3s/apps/apps.yaml Application/identity-admin-dev: syncOptions에 ServerSideApply=true 없음" \
  "+[FAIL] 7.1 WAVE-mismatch — clusters/oci-k3s/apps/apps.yaml Application/platform-vault: sync-wave 20 ≠ 표 10" \
  "+[FAIL] 7.1 WAVE-unknown — clusters/oci-k3s/apps/apps.yaml Application/platform-foo: 컴포넌트 'foo'는 §sync-wave 단일 표에 없음" \
  "+[FAIL] 7.1 WAVE-mismatch — clusters/oci-k3s/apps/apps.yaml Application/identity-admin-dev: sync-wave 50 ≠ 표 100" \
  "+[FAIL] 7.1 WAVE-missing — clusters/oci-k3s/apps/apps.yaml Application/platform-cnpg: argocd.argoproj.io/sync-wave 어노테이션 없음(기대 20)" \
  "+[FAIL] 7.1 WAVE-path — clusters/oci-k3s/apps/apps.yaml Application/platform-kafka: source.path 'platform/kafka-topics' ≠ platform/kafka" \
  "+[FAIL] 7.1 WAVE-name — clusters/oci-k3s/apps/apps.yaml Application/weird-name: 이름 규약 위반" \
  "+[FAIL] 7.1 WAVE-name — clusters/oci-k3s/apps/apps.yaml Application/root: 'root'는 bootstrap/root-app.yaml에서 source.path clusters/oci-k3s/apps 로만 허용(현재 위치 clusters/oci-k3s/apps/apps.yaml, path 'platform/vault', wave 999)" \
  "+[FAIL] 7.2 WAVE-dir — platform/unknown-thing/: §sync-wave 단일 표에 없는 디렉터리"

# --- 7.3: secrets/<ns>의 단일 소유(설계 D3 조건 2) --------------------------------
# 두 갈래를 한 트리로 덮는다: 소비자 컴포넌트가 같은 base를 포함(단일 소유 위반) · 어디에도 포함되지 않은 secrets/<ns>(죽은 선언).
# 음성 단언: 배달자 자신과 배달자에 포함된 ns는 걸리지 않아야 하고, `secrets/<ns>`가 자기 파일을 가리키는 것도 위반이 아니다.
run_case secrets-base-owner "$FIX/secrets-base-owner" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/cert-manager-issuers/kustomization.yaml: base '../../secrets/cert-manager'(→ secrets/cert-manager) — secrets/ 아래를 base로 가질 수 있는 kustomization은 platform/secrets/kustomization.yaml 하나뿐이다" \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/data/: platform/secrets/kustomization.yaml 의 resources에 없음 — 어떤 Application도 적용하지 않는 죽은 선언이다" \
  '-[FAIL] 7.3 WAVE-secrets-base — platform/secrets/kustomization.yaml' \
  '-[FAIL] 7.3 WAVE-secrets-base — secrets/cert-manager' \
  '-[FAIL] 7.2 WAVE-dir'
# 7.3 보강 4트리(리뷰 G3-VRA-2·4·5·6·7의 가짜 PASS 경로). 트리마다 자기 갈래만 걸려야 한다.
#   owner-scope: 전이 base(배달자 자체) · 저장소 밖 경로 · 절대 경로 · 파일 복사본/렌더 중복 · multi-source Application
run_case secrets-owner-scope "$FIX/secrets-owner/owner-scope" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/cert-manager-issuers/kustomization.yaml: base '../secrets'(→ platform/secrets) — 배달자 platform/secrets 를 base로 끌어가면" \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/dragonfly/kustomization.yaml: base '../../../owner-scope/secrets/cert-manager' — 저장소 밖으로 나가는 경로" \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/reloader/kustomization.yaml: base '/nonexistent-secrets/cert-manager' — 절대 경로 금지" \
  "+[FAIL] 7.3 WAVE-secrets-base — ExternalSecret 'cert-manager/cloudflare-dns-token'(원본 secrets/cert-manager/externalsecret.yaml)이 배달자 밖 소스에도 있다: platform/cloudflared/externalsecret-copy.yaml" \
  "+[FAIL] 7.3 WAVE-secrets-base — clusters/oci-k3s/apps/apps.yaml Application/platform-cert-manager-issuers: source.path 'secrets/cert-manager' — secrets/<ns>의 적용 주체는 platform/secrets 하나뿐이다" \
  '-[FAIL] 7.3 WAVE-secrets-base — Application 없음' \
  '-렌더에 없다'
#   dead-files: 배달되지 않는 ES 파일 3종(secrets/ 바로 아래 · sub/ 하위 · ns kustomization 미등록)
run_case secrets-owner-dead-files "$FIX/secrets-owner/dead-files" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/externalsecret-stray.yaml ExternalSecret 'stray-token': platform/secrets 렌더에 없다" \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/cert-manager/externalsecret-unregistered.yaml ExternalSecret 'unregistered-token': platform/secrets 렌더에 없다" \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/data/sub/externalsecret-sub.yaml ExternalSecret 'sub-token': platform/secrets 렌더에 없다" \
  '-배달자 밖 소스에도 있다' \
  '-[FAIL] 7.3 WAVE-secrets-base — Application 없음'
#   no-app: 배달자는 있는데 그것을 sync하는 Application이 없다
run_case secrets-owner-no-app "$FIX/secrets-owner/no-app" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — Application 없음 — source.path가 platform/secrets 인 Application이 하나도 없다" \
  '-렌더에 없다' \
  '-배달자 밖 소스에도 있다'
#   no-owner: 배달자가 통째로 없는 트리 — "배달자 … 가 없음" 가지를 문구로 고정한다
run_case secrets-owner-no-owner "$FIX/secrets-owner/no-owner" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/cert-manager/: 배달자 platform/secrets/kustomization.yaml 가 없음 — 이 디렉터리를 적용하는 Application이 없다(죽은 선언)" \
  '-[FAIL] 7.3 WAVE-secrets-base — Application 없음'
# 7.3 (e) 변환 키 금지(T045 G4 · 계약 §validate.yml 4 「배달자는 base를 묶기만 한다」). 두 트리로 양쪽 경로를 덮는다.
#   deliverer-patch: 배달자에 `patches:` — 원본 파일은 정상이고 **Argo가 적용하는 렌더에서만** creationPolicy가 Owner가 되고
#     remoteRef.key가 DNS 토큰 경로로 바뀐다. store도 키 접두도 그대로라 **3.2는 잡지 못한다**(음성 단언으로 고정한다 —
#     이것이 구조 금지가 필요한 이유다). 다른 갈래((b)(c))도 걸리지 않아야 한다.
run_case secrets-owner-deliverer-patch "$FIX/secrets-owner/deliverer-patch" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/secrets/kustomization.yaml: 최상위 키 'patches' 금지 — 허용은 [\"apiVersion\",\"kind\",\"resources\"] 뿐이다" \
  '-[FAIL] 3.2 ES-②' \
  '-렌더에 없다' \
  '-배달자 밖 소스에도 있다' \
  '-[FAIL] 7.3 WAVE-secrets-base — Application 없음'
#   ns-transform: `secrets/<ns>`에 `namePrefix` — 허용 키 4개(`namespace`까지)를 벗어난다. 이름까지 바뀌므로
#     (c)「죽은 선언」도 함께 걸린다(원본 ES 이름이 배달자 렌더에 없다) — 두 줄을 모두 고정한다.
run_case secrets-owner-ns-transform "$FIX/secrets-owner/ns-transform" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/cloudflared/kustomization.yaml: 최상위 키 'namePrefix' 금지 — 허용은 [\"apiVersion\",\"kind\",\"resources\",\"namespace\"] 뿐이다" \
  "+[FAIL] 7.3 WAVE-secrets-base — secrets/cloudflared/externalsecret.yaml ExternalSecret 'cloudflared-tunnel': platform/secrets 렌더에 없다" \
  "-최상위 키 'patches' 금지" \
  '-[FAIL] 7.3 WAVE-secrets-base — Application 없음'

# --- 7.4: Application은 source를 덮어쓰지 않는다(T046 · 계약 §validate.yml 4 「(T046)」 둘째 줄) ---------------
# 다섯 트리 모두 부분 트리다(Application 파일 하나 — source-file은 거기에 `.argocd-source*.yaml` 둘) — exit 1은 5.x 등 무관한 FAIL로도 나므로 판정 근거가 아니다.
# 근거는 그 하위 코드의 `+[FAIL]` 단언과 `-[PASS] 7.4 APP-source`(그룹이 통과하지 않았음) 음성 단언이다(2026-09-28 검증 V-A7).
run_case app-source-kustomize-patches "$FIX/app-source/kustomize-patches" 1 \
  "+[FAIL] 7.4 APP-source — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: spec.source 키 [kustomize,path,repoURL,targetRevision] ≠ {path, repoURL, targetRevision}" \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source-multi' '-[FAIL] 7.4 APP-source-ref' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'
run_case app-source-multi-source "$FIX/app-source/multi-source" 1 \
  "+[FAIL] 7.4 APP-source-multi — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: spec.sources(multi-source) 금지" \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source —' '-[FAIL] 7.4 APP-source-ref' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'
run_case app-source-ref "$FIX/app-source/ref" 1 \
  "+[FAIL] 7.4 APP-source-ref — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: spec.source.repoURL 'https://github.com/someone-else/platform-gitops.git' ≠ https://github.com/joshua92y/platform-gitops.git" \
  "+[FAIL] 7.4 APP-source-ref — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: spec.source.targetRevision 'some-unreviewed-branch' ≠ main" \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source —' '-[FAIL] 7.4 APP-source-multi' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'
# `spec.source`를 건드리지 않고 적용 렌더를 바꾸는 두 경로(2026-09-28 재검증 RB-1 — Argo CD v3.5.2 소스 판독, 라이브 미실측).
#   source-file: Application은 정상(키 3개)이고 source 경로 안에 `.argocd-source.yaml` · `.argocd-source-<앱 이름>.yaml`이 있다
#   — Argo가 두 파일을 source 파라미터에 합친다. 파일마다 7.4 APP-source-file 한 줄, 다른 7.4 코드는 없어야 한다.
run_case app-source-source-file "$FIX/app-source/source-file" 1 \
  "+[FAIL] 7.4 APP-source-file — platform/reloader/.argocd-source-platform-reloader.yaml: " \
  "+[FAIL] 7.4 APP-source-file — platform/reloader/.argocd-source.yaml: " \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source —' '-[FAIL] 7.4 APP-source-multi' '-[FAIL] 7.4 APP-source-ref' '-[FAIL] 7.4 APP-source-hydrator' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'
#   hydrator: `spec.source`는 키 3개 그대로인데 `spec.sourceHydrator`가 있다 — Argo는 `spec.source`보다 hydrator의 syncSource를 먼저 쓴다.
run_case app-source-hydrator "$FIX/app-source/hydrator" 1 \
  "+[FAIL] 7.4 APP-source-hydrator — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: spec.sourceHydrator 금지" \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source —' '-[FAIL] 7.4 APP-source-multi' '-[FAIL] 7.4 APP-source-ref' '-[FAIL] 7.4 APP-source-file' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'
#   operation: `spec.source`는 키 3개 그대로인데 문서 최상위에 `operation`이 있다 — 한 번의 동기화 source를 바꾼다(DV-1).
run_case app-source-operation "$FIX/app-source/operation" 1 \
  "+[FAIL] 7.4 APP-source-operation — clusters/oci-k3s/apps/platform-reloader.yaml Application/platform-reloader: 최상위 operation 금지" \
  '-[PASS] 7.4 APP-source' '-[FAIL] 7.4 APP-source —' '-[FAIL] 7.4 APP-source-multi' '-[FAIL] 7.4 APP-source-ref' '-[FAIL] 7.4 APP-source-hydrator' '-[FAIL] 7.4 APP-source-file' '-[FAIL] 2 APP-SSA' '-[FAIL] 7.1'

# --- gitleaks: 대상 0개 = FAIL --------------------------------------------------
run_case gitleaks-empty "$FIX/gitleaks-empty" 1 \
  '+[FAIL] 8 LEAK-no-target — 스캔 대상 파일 0개'

# --- 검사 9: ClusterSecretStore ------------------------------------------------
# 세 트리로 하위 코드 전부를 덮는다. 각 트리는 원본 파일 줄과 `(rendered)` 줄을 **둘 다** 내야 한다
# (kustomization.yaml을 함께 둔 이유 — 렌더에서 값을 바꿔 검사를 우회하는 길을 막는다).
# 트리마다 자기 코드 외에는 걸리지 않아야 한다(음성 단언) — 한 결함이 여러 코드로 번지면 원인 분리가 안 된다.
run_case css-auth-vault "$FIX/css-auth/vault" 1 \
  "+[FAIL] 9.1 CSS-namespace — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-platform: metadata.namespace 'external-secrets' 금지" \
  "+[FAIL] 9.1 CSS-namespace — platform/secret-stores (rendered) ClusterSecretStore/vault-platform: metadata.namespace 'external-secrets' 금지" \
  "+[FAIL] 9.2 CSS-auth-referent — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-dev: auth.kubernetes.serviceAccountRef.namespace 없음 = referent auth" \
  "+[FAIL] 9.2 CSS-auth-referent — platform/secret-stores (rendered) ClusterSecretStore/vault-dev: auth.kubernetes.serviceAccountRef.namespace 없음 = referent auth" \
  "+[FAIL] 9.2 CSS-auth-audience — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-prod: serviceAccountRef.audiences [kubernetes] ≠ [vault]" \
  "+[FAIL] 9.2 CSS-auth-map — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-data: role 'eso-dev' · serviceAccountRef.name 'eso-dev' ≠ 계약 표의 'eso-data'" \
  "-[FAIL] 9.3 CSS-k8s" \
  "+[PASS] 9.3 CSS-k8s — kubernetes provider store 2개"
run_case css-auth-k8s "$FIX/css-auth/k8s" 1 \
  "+[FAIL] 9.1 CSS-location — platform/external-secrets/clustersecretstore-stray.yaml ClusterSecretStore/vault-stray: ClusterSecretStore는 platform/secret-stores/ 에만 둔다" \
  "+[FAIL] 9.1 CSS-set — platform/external-secrets/clustersecretstore-stray.yaml ClusterSecretStore/vault-stray: 계약 §ClusterSecretStore 표에 없는 store 이름" \
  "+[FAIL] 9.1 CSS-set — platform/secret-stores/ 에 store 'vault-data' 없음" \
  "+[FAIL] 9.3 CSS-k8s-auth — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: auth 키 [serviceAccount,token]" \
  "+[FAIL] 9.3 CSS-k8s-audience — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: auth.serviceAccount에 audiences 금지" \
  "+[FAIL] 9.3 CSS-k8s-default — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: remoteNamespace 없음" \
  "+[FAIL] 9.3 CSS-k8s-default — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: server.url 없음" \
  "+[FAIL] 9.3 CSS-k8s-default — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: server.caProvider.namespace 없음" \
  "+[FAIL] 9.3 CSS-k8s-default — platform/secret-stores (rendered) ClusterSecretStore/k8s-data-ca: server.caProvider.namespace 없음" \
  "-[FAIL] 9.2 CSS-auth" \
  "-[FAIL] 9.4 CSS-conditions"
run_case css-auth-conditions "$FIX/css-auth/conditions" 1 \
  "+[FAIL] 9.4 CSS-conditions-count — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-platform: spec.conditions 없음" \
  "+[FAIL] 9.4 CSS-conditions-count — platform/secret-stores (rendered) ClusterSecretStore/vault-platform: spec.conditions 없음" \
  "+[FAIL] 9.4 CSS-conditions-set — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-dev: conditions.namespaces 집합 불일치 — 빠짐 [] 여분 [jt-prod]" \
  "+[FAIL] 9.4 CSS-conditions-set — platform/secret-stores (rendered) ClusterSecretStore/vault-dev: conditions.namespaces 집합 불일치 — 빠짐 [] 여분 [jt-prod]" \
  "+[FAIL] 9.4 CSS-conditions-key — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-prod: conditions 항목 키 [namespaceSelector]" \
  "+[FAIL] 9.4 CSS-conditions-set — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/vault-data: conditions.namespaces 중복 [data]" \
  "+[FAIL] 9.3 CSS-k8s-remote — platform/secret-stores/clustersecretstores.yaml ClusterSecretStore/k8s-data-ca: remoteNamespace 'default' ≠ 'data'" \
  "+[FAIL] 9.3 CSS-k8s-remote — platform/secret-stores (rendered) ClusterSecretStore/k8s-data-ca: remoteNamespace 'default' ≠ 'data'" \
  "-[FAIL] 9.1 CSS" \
  "-[FAIL] 9.2 CSS" \
  "-[FAIL] 9.3 CSS-k8s-auth" \
  "-[FAIL] 9.3 CSS-k8s-audience" \
  "-[FAIL] 9.3 CSS-k8s-default"

# --- 검사 10: Reloader scoped 모드(T046 · 계약 §validate.yml 4 「(T046)」 첫째 줄) --------------------------
# 트리마다 그 결함이 실제로 낳는 하위 코드만 걸려야 한다(음성 단언) — 한 결함이 무관한 코드로 번지면 원인 분리가 안 된다.
# 모든 트리에 `-[PASS] 10 REL`을 건다: 부분 트리라 exit 1은 5.x 등 무관한 FAIL로도 나므로 판정 근거가 아니다(2026-09-28 검증 V-A7).
# 10.2의 단서 줄(`단서 — …`)은 같은 코드로 찍히는 진단이다 — 결함 종류마다 그 단서가 있고 다른 단서는 없어야 한다.
REL_L='platform/reloader (rendered)'
REL_ARGS_FAIL="+[FAIL] 10.2 REL-args-exact — $REL_L Deployment/reloader/reloader: 첫 컨테이너 args ≠ 기대 목록(원소 수·순서·값 정확 일치 — 계약 §validate.yml 4 「(T046)」) — 실제 "
REL_HINT="[FAIL] 10.2 REL-args-exact — $REL_L Deployment/reloader/reloader: 단서 — "
REL_OK_ARGS='"--log-level=info","--namespaces=identity,jt-dev,jt-prod,reloader","--reload-strategy=annotations"'

# (a) 차트 values 갈래 — 네 트리는 **실제 차트 2.2.16 렌더**로 FAIL을 낸다(values 한 줄만 다르고, 실제 트리와 같이 시험 대상
#   `vd9-probe.yaml`을 포함한다) — helm과 네트워크(차트 pull)가 필요하다(tests/fixtures/pol-port와 같다. 풀린 차트는 픽스처 아래
#   charts/에 남고 .gitignore 대상이다). helm이나 kustomize가 없으면 검사 10은 "도구 없음"(SKIP 또는 fail-closed FAIL)이 정답이다.
#   (전역 모드는 ClusterRole·인자·kind 개수·감시 ns Role이 **함께** 바뀌므로 typo-parent는 10.1–10.4가 모두 걸리는 것이 정답이다.)
if command -v kustomize >/dev/null 2>&1 && command -v helm >/dev/null 2>&1; then
  #   typo-key: `watchGlobaly` 오타 → 차트의 fail 가드가 렌더를 멈춘다 → 판정할 렌더가 없으므로 fail-closed
  run_case rel-scoped-typo-key "$FIX/rel-scoped/typo-key" 1 \
    "+[FAIL] 1 KUST — kustomize build 실패: platform/reloader" \
    "+[FAIL] 10.0 REL-render — platform/reloader 렌더 결과 없음 — kustomize build가 실패했다" \
    '-[PASS] 10 REL' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4'
  #   typo-parent: 부모 키 `reloadr:` 오타 → 렌더 성공 + 전역 모드(ClusterRole·ClusterRoleBinding · args는 --log-level 하나 ·
  #   감시 ns Role 없음 — 릴리스 ns의 reloader-metadata-role 한 쌍만 남는다)
  run_case rel-scoped-typo-parent "$FIX/rel-scoped/typo-parent" 1 \
    "+[FAIL] 10.1 REL-clusterrbac — $REL_L ClusterRole/reloader-role: scoped 모드는 ClusterRole·ClusterRoleBinding 0이어야 한다" \
    "+[FAIL] 10.1 REL-clusterrbac — $REL_L ClusterRoleBinding/reloader-role-binding: scoped 모드는" \
    "${REL_ARGS_FAIL}[\"--log-level=info\"](1개)" \
    "+${REL_HINT}--namespaces 인자 없음: 전역 모드" \
    "+${REL_HINT}--reload-strategy 인자 없음: 바이너리 기본 전략 env-vars" \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [ClusterRole 1≠0, ClusterRoleBinding 1≠0, Role 1≠5, RoleBinding 1≠5]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: Role ns 집합 불일치 — 빠짐 [identity, jt-dev, jt-prod] 여분 []" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: RoleBinding ns 집합 불일치 — 빠짐 [identity, jt-dev, jt-prod] 여분 []" \
    "+[FAIL] 10.4 REL-rbac-rules — $REL_L: Role reloader-role 없는 ns [identity, jt-dev, jt-prod, reloader]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 1 KUST' '-[FAIL] 10.3 REL-probe' '-[FAIL] 10.4 REL-rbac-bind' '-[FAIL] 10.4 REL-image' \
    "-${REL_HINT}'=' 없는 플래그" "-${REL_HINT}같은 플래그"
  #   cloudflared: 감시 목록에 cloudflared 추가 → scoped 그대로(10.1 PASS)지만 인자 · Role·RoleBinding ns 집합 · 개수가 달라진다
  run_case rel-scoped-cloudflared "$FIX/rel-scoped/cloudflared" 1 \
    "${REL_ARGS_FAIL}[\"--log-level=info\",\"--namespaces=cloudflared,identity,jt-dev,jt-prod,reloader\",\"--reload-strategy=annotations\"](3개)" \
    "+${REL_HINT}cloudflared가 든 인자 [\"--namespaces=cloudflared,identity,jt-dev,jt-prod,reloader\"]: 계약 위반 단서" \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [Role 6≠5, RoleBinding 6≠5]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: Role ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: RoleBinding ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3 REL-probe' '-[FAIL] 10.4 REL-rbac-bind' '-[FAIL] 10.4 REL-rbac-rules' '-[FAIL] 10.4 REL-image' \
    "-${REL_HINT}'=' 없는 플래그" "-${REL_HINT}같은 플래그"
  #   env-vars: 전략만 다르다 — 목록 불일치 한 줄, 단서 없음
  run_case rel-scoped-env-vars "$FIX/rel-scoped/env-vars" 1 \
    "${REL_ARGS_FAIL}[\"--log-level=info\",\"--namespaces=identity,jt-dev,jt-prod,reloader\",\"--reload-strategy=env-vars\"](3개)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}"
else
  for c in typo-key typo-parent cloudflared env-vars; do
    run_case "rel-scoped-$c" "$FIX/rel-scoped/$c" 1 '+10 REL — 도구 없음'
  done
fi
#   no-deployment: 렌더는 성공하지만 Deployment가 없다(뼈대) → PASS가 아니라 fail-closed. helm 불필요
no_dep_asserts=()
if command -v kustomize >/dev/null 2>&1; then
  no_dep_asserts+=("+[FAIL] 10.0 REL-render — platform/reloader (rendered): Deployment reloader/reloader 없음 — 인자를 판정할 대상이 없으므로 fail-closed" \
    '-[PASS] 10 REL' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4')
else
  no_dep_asserts+=('+[SKIP] 10 REL — 도구 없음(kustomize)')
fi
run_case rel-scoped-no-deployment "$FIX/rel-scoped/no-deployment" 1 "${no_dep_asserts[@]}"

# (b) 순수 매니페스트 갈래 — 긍정 트리의 사본(deployment.yaml·rbac.yaml·vd9-probe.yaml)에 결함 하나씩을 더했다(helm·네트워크 불필요 —
#   kustomize만. kustomize가 없으면 "도구 없음"이 정답이다). 앞의 넷(e1·e2·e3·e5)은 2026-09-22 독립 리뷰, 뒤의 열하나는 2026-09-28
#   적대적 검증(V-A1·A3·A4·A5·A6·A8·A9)이 예전 검사에서 가짜 PASS(또는 단언 없는 분기)로 실측한 경로다.
REL_PURE='second-deploy command second-container args-newline swallow-ns swallow-strategy extra-arg var-expansion args-order decoy-container image-registry rb-subject role-wildcard extra-kind probe-namespace'
if command -v kustomize >/dev/null 2>&1; then
  #   second-deploy(e1): 이름이 다른 두 번째 Reloader Deployment + cloudflared ns Role·RoleBinding(규칙 2개 — 다른 ns와 다르다)
  run_case rel-scoped-second-deploy "$FIX/rel-scoped/second-deploy" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L: Reloader 이미지(…/stakater/reloader) 컨테이너 2개 [Deployment/reloader/reloader spec.template.spec.containers.0, Deployment/reloader/reloader-cf spec.template.spec.containers.0]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: Role ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: RoleBinding ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [Deployment 3≠2, Role 6≠5, RoleBinding 6≠5]" \
    "+[FAIL] 10.4 REL-rbac-rules — $REL_L Role/cloudflared/reloader-role: rules ≠ 다수 규칙(4/5장" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3 REL-probe' '-[FAIL] 10.4 REL-rbac-bind' '-command 있음' \
    "-[FAIL] 10.4 REL-rbac-rules — $REL_L Role/identity/"
  #   command(e2): Reloader 컨테이너의 command에 --namespaces=cloudflared
  run_case rel-scoped-command "$FIX/rel-scoped/command" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L Deployment/reloader/reloader spec.template.spec.containers.0: command 있음" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac' '-Reloader 이미지(…/stakater/reloader) 컨테이너'
  #   second-container(e3): 같은 파드에 두 번째 Reloader 컨테이너
  run_case rel-scoped-second-container "$FIX/rel-scoped/second-container" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L: Reloader 이미지(…/stakater/reloader) 컨테이너 2개 [Deployment/reloader/reloader spec.template.spec.containers.0, Deployment/reloader/reloader spec.template.spec.containers.1]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac' '-command 있음'
  #   args-newline(e5): 개행이 든 인자 뒤의 두 번째 --namespaces= — JSON(이스케이프된 `\n`)으로 비교하므로 뒤 인자까지 보인다
  run_case rel-scoped-args-newline "$FIX/rel-scoped/args-newline" 1 \
    "+[FAIL] 10.0 REL-args — $REL_L Deployment/reloader/reloader: 첫 컨테이너 args 5개 중 1개에 제어 문자" \
    "${REL_ARGS_FAIL}[${REL_OK_ARGS},\"--log-format=\n\",\"--namespaces=cloudflared\"](5개)" \
    "+${REL_HINT}같은 플래그 2개 이상 [\"--namespaces ×2\"]: --namespaces는 목록이 **합쳐진다**(StringSlice" \
    "+${REL_HINT}cloudflared가 든 인자 [\"--namespaces=cloudflared\"]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0 REL-render' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}'=' 없는 플래그"
  #   swallow-ns(V-A1 a01): 값 없는 --log-format이 --namespaces= 앞 — pflag가 뒤 인자를 삼켜 감시 목록이 빈다
  run_case rel-scoped-swallow-ns "$FIX/rel-scoped/swallow-ns" 1 \
    "${REL_ARGS_FAIL}[\"--log-level=info\",\"--log-format\",\"--namespaces=identity,jt-dev,jt-prod,reloader\",\"--reload-strategy=annotations\"](4개)" \
    "+${REL_HINT}'=' 없는 플래그 [\"--log-format\"]: 값을 받는 플래그(문자열·목록)는 **다음 인자를 값으로 삼킨다**(pflag)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}같은 플래그" "-${REL_HINT}cloudflared" "-${REL_HINT}'\$('"
  #   swallow-strategy(V-A1 a03): 값 없는 --pprof-addr가 --reload-strategy= 앞 — 전략이 바이너리 기본값이 된다
  run_case rel-scoped-swallow-strategy "$FIX/rel-scoped/swallow-strategy" 1 \
    "${REL_ARGS_FAIL}[\"--log-level=info\",\"--namespaces=identity,jt-dev,jt-prod,reloader\",\"--pprof-addr\",\"--reload-strategy=annotations\"](4개)" \
    "+${REL_HINT}'=' 없는 플래그 [\"--pprof-addr\"]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}같은 플래그"
  #   extra-arg(V-A9 a12): 여분 인자 --auto-reload-all=true — 목록 불일치 한 줄, 단서 없음
  run_case rel-scoped-extra-arg "$FIX/rel-scoped/extra-arg" 1 \
    "${REL_ARGS_FAIL}[${REL_OK_ARGS},\"--auto-reload-all=true\"](4개)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}"
  #   var-expansion(V-A3 a04): args의 $(VAR) — kubelet이 펼친 뒤 --namespaces가 합쳐진다
  run_case rel-scoped-var-expansion "$FIX/rel-scoped/var-expansion" 1 \
    "${REL_ARGS_FAIL}[${REL_OK_ARGS},\"\$(RELOADER_EXTRA)\"](4개)" \
    "+${REL_HINT}'\$(' 든 인자 [\"\$(RELOADER_EXTRA)\"]: kubelet 환경 변수 치환" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}'=' 없는 플래그" "-${REL_HINT}같은 플래그"
  #   args-order: 값·개수는 같고 순서만 다르다 — 목록 정확 일치라 FAIL(단서 없음)
  run_case rel-scoped-args-order "$FIX/rel-scoped/args-order" 1 \
    "${REL_ARGS_FAIL}[\"--namespaces=identity,jt-dev,jt-prod,reloader\",\"--log-level=info\",\"--reload-strategy=annotations\"](3개)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.3' '-[FAIL] 10.4' "-${REL_HINT}"
  #   decoy-container(V-A6 d05): containers[0]에 기대 args를 가진 미끼 → 10.2는 통과, REL-image 위치 판정만 잡는다
  run_case rel-scoped-decoy-container "$FIX/rel-scoped/decoy-container" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L: Reloader 이미지 컨테이너가 'Deployment/reloader/reloader spec.template.spec.containers.1'에 있다" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac' '-이미지 저장소' '-command 있음' '-Reloader 이미지(…/stakater/reloader) 컨테이너'
  #   image-registry(V-A6): 다른 레지스트리의 같은 이미지 → REL-image 저장소 판정만 잡는다
  run_case rel-scoped-image-registry "$FIX/rel-scoped/image-registry" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L Deployment/reloader/reloader spec.template.spec.containers.0: 이미지 저장소 'docker.io/stakater/reloader' ≠ ghcr.io/stakater/reloader" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac' '-컨테이너가 ' '-command 있음' '-Reloader 이미지(…/stakater/reloader) 컨테이너'
  #   rb-subject(V-A4 b03): jt-prod RoleBinding 주체가 다른 SA → REL-rbac-bind만
  run_case rel-scoped-rb-subject "$FIX/rel-scoped/rb-subject" 1 \
    "+[FAIL] 10.4 REL-rbac-bind — $REL_L RoleBinding/jt-prod/reloader-role-binding: subjects [{\"kind\":\"ServiceAccount\",\"name\":\"default\",\"namespace\":\"cloudflared\"}] ≠ [{\"kind\":\"ServiceAccount\",\"name\":\"reloader\",\"namespace\":\"reloader\"}]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac-ns' '-[FAIL] 10.4 REL-rbac-rules' '-[FAIL] 10.4 REL-image' '-roleRef'
  #   role-wildcard(V-A5 b05): jt-prod reloader-role에 */*/* 규칙 → REL-rbac-rules 두 줄(와일드카드 · 다수 규칙과 다름)
  run_case rel-scoped-role-wildcard "$FIX/rel-scoped/role-wildcard" 1 \
    "+[FAIL] 10.4 REL-rbac-rules — $REL_L Role/jt-prod/reloader-role: apiGroups·resources·verbs에 와일드카드 [\"*\"]" \
    "+[FAIL] 10.4 REL-rbac-rules — $REL_L Role/jt-prod/reloader-role: rules ≠ 다수 규칙(3/4장" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3' '-[FAIL] 10.4 REL-rbac-ns' '-[FAIL] 10.4 REL-rbac-bind' '-[FAIL] 10.4 REL-image' \
    "-[FAIL] 10.4 REL-rbac-rules — $REL_L Role/identity/"
  #   extra-kind(V-A4): 표 밖 kind(ConfigMap) → REL-kinds만
  run_case rel-scoped-extra-kind "$FIX/rel-scoped/extra-kind" 1 \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [ConfigMap 1≠0] — 실제 {ConfigMap 1 · Deployment 2 · Role 5 · RoleBinding 5 · ServiceAccount 1}(합계 14)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3 REL-probe' '-[FAIL] 10.4'
  #   probe-namespace(V-A8 d02): 시험 대상이 다른 ns로 옮겨짐 → REL-probe만(개수는 그대로)
  run_case rel-scoped-probe-namespace "$FIX/rel-scoped/probe-namespace" 1 \
    "+[FAIL] 10.3 REL-probe — $REL_L: Deployment reloader/vd9-probe — ns ≠ jt-dev" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.3 REL-kinds' '-[FAIL] 10.4'
else
  for c in $REL_PURE; do
    run_case "rel-scoped-$c" "$FIX/rel-scoped/$c" 1 '+[SKIP] 10 REL — 도구 없음(kustomize)'
  done
fi

# --- 작성자(봇) 경로 lint: positive 트리 + diff 입력 ---------------------------------
run_case author-bot-ok "$FIX/positive" 0 \
  --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/ok.diff" \
  "+[PASS] 6 AUTHOR — 봇 'jt-ci[bot]' PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest"
run_case author-bot-alt-login-ok "$FIX/positive" 0 \
  --env "PR_AUTHOR=joshuatech-gitapp-1[bot]" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/ok.diff" \
  "+[PASS] 6 AUTHOR — 봇 'joshuatech-gitapp-1[bot]' PR"
run_case author-bot-bad-file "$FIX/positive" 1 \
  --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE"$'\n'"platform/vault/kustomization.yaml" --env "CHANGED_DIFF=$FIX/author/bad-file.diff" \
  "+[FAIL] 6 AUTHOR-file — 봇 'jt-ci[bot]'의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
  "+[FAIL] 6 AUTHOR-file — 봇 diff: 파일 'platform/vault/kustomization.yaml' 불허" \
  "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'resources: [evil.yaml]'"
run_case author-bot-bad-line "$FIX/positive" 1 \
  --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/bad-line.diff" \
  "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'namespace: jt-dev'" \
  "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'namespace: jt-prod'"
run_case author-bot-no-input "$FIX/positive" 1 \
  --env "PR_AUTHOR=jt-ci[bot]" \
  "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]'인데 변경 파일 목록/diff 입력이 없음"
run_case author-human-unrestricted "$FIX/positive" 0 \
  --env "PR_AUTHOR=joshua92y" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/bad-line.diff" \
  "+[PASS] 6 AUTHOR — 작성자 'joshua92y'는 봇 아님"
# PR 이벤트인데 PR_AUTHOR가 비면 조용히 꺼지지 않고 FAIL
run_case author-required-pr-event "$FIX/positive" 1 \
  --env "GITHUB_EVENT_NAME=pull_request" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 PR_AUTHOR가 비어 있음"
run_case author-required-flag "$FIX/positive" 1 \
  --env "VALIDATE_REQUIRE_AUTHOR=1" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='', VALIDATE_REQUIRE_AUTHOR=1)인데 PR_AUTHOR가 비어 있음"
run_case author-push-event-ok "$FIX/positive" 0 \
  --env "GITHUB_EVENT_NAME=push" \
  "+[PASS] 6 AUTHOR — PR 작성자 미지정(push 이벤트 등)"

# --- 저장소 밖 root 거부(exit 2) — 실제 트리 검사는 여기서 하지 않는다(트리 상태에 따라 결과가 달라지므로) -----
if selected root-outside-repo-rejected; then
  outside_rc=0
  bash "$VALIDATE" --root / >/dev/null 2>&1 || outside_rc=$?
  N=$((N + 1))
  if [[ $outside_rc == 2 ]]; then printf '[PASS] root-outside-repo-rejected\n'; else NF=$((NF + 1)); FAILED+=(root-outside-repo-rejected); printf '[FAIL] root-outside-repo-rejected (exit %s ≠ 2)\n' "$outside_rc"; fi
fi

if [[ -n $ONLY ]]; then
  printf "\n== 자기검사 요약(부분 실행 — 필터 '%s' · 건너뜀 %d): %d 케이스, 실패 %d ==\n" "$ONLY" "$NSKIP" "$N" "$NF"
  if [[ $N -eq 0 ]]; then
    printf "필터 '%s'에 맞는 케이스 0개 — 빈 실행을 통과로 읽지 않는다(exit 1)\n" "$ONLY"
    exit 1
  fi
else
  printf '\n== 자기검사 요약: %d 케이스, 실패 %d ==\n' "$N" "$NF"
fi
if [[ $NF -gt 0 ]]; then
  printf '실패: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
