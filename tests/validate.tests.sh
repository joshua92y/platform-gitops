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
#   - tests/.tmp/          : (T047) 검사 6의 SHA 경로 케이스가 쓰는 임시 git 저장소(mergebase · lines · submodule · textconv)와
#                            git 밖 디렉터리(nogit), 도구 없는 PATH의 심 디렉터리.
#                            --root는 저장소 안이어야 하므로 여기에 만든다(.gitignore 대상). 시작할 때와 끝날 때(EXIT trap) 통째로 지운다
# 실제 트리 검사(validate.sh 기본 실행)는 tests/ 를 제외하므로 픽스처가 실제 결과에 섞이지 않는다.
#
# 도구가 없으면 VALIDATE_SKIP_TOOLS=1로 내려가 실행한다(어떤 검사가 SKIP되는지 출력). yq(mikefarah)가 없으면
# 대부분의 단언이 성립할 수 없으므로 즉시 실패한다(fail-closed). VALIDATE_TESTS_REQUIRE_TOOLS=1 또는 CI=true 이면
# 도구 누락 시 SKIP 모드로 내려가지 않고 exit 1 (CI에서 조용히 불완전한 결과가 통과하지 않도록). 이 두 스위치에서는
# helm도 필수다(T047) — 없으면 helm이 필요한 케이스(rel-scoped 4개 등)가 "도구 없음" 단언으로 바뀌어 통과하기 때문이다.
# 스위치가 없는 로컬 실행에서 helm이 없을 때의 동작은 그대로다(그 케이스만 "도구 없음" 단언).
# 각 케이스는 env -u 로 작성자·발신자·모드 관련 환경변수를 지우고 시작한다(CI의 GITHUB_EVENT_NAME, PR_SENDER, VALIDATE_ONLY_AUTHOR 등이 새지 않도록 —
# VALIDATE_ONLY_AUTHOR가 새면 모든 케이스가 검사 6만 돌게 된다).
#
# 부분 실행: VALIDATE_TESTS_ONLY='<bash 확장 정규식>'이면 이름이 맞는 케이스만 돌리고 나머지는 건너뛴다(건너뛴 수를 센다 —
#   준비 블록을 통째로 건너뛸 때도 skip_cases로 세므로, 어떤 필터든 건너뜀 + 실행 = 전체 케이스 수).
#   요약 줄이 "부분 실행 — 필터 '…' · 건너뜀 N"을 드러내고, 맞는 케이스가 0개면 exit 1이다(빈 실행을 통과로 읽지 않는다).
#   예: VALIDATE_TESTS_ONLY='^(positive|app-source-)' bash tests/validate.tests.sh
#   ⚠ 부분 실행은 반복 작업용이다 — PR·과제 마무리 판정은 필터 없는 전체 실행으로 한다(tests/README.md). 비어 있으면 필터 없음.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATE="$HERE/validate.sh"
FIX="$HERE/fixtures"
# 임시 git 저장소·심 디렉터리(머리 주석 「tests/.tmp/」). 지난 실행이 실패로 남긴 것을 지우고 시작하고, 어떻게 끝나든 지운다
TMP="$HERE/.tmp"
rm -rf -- "$TMP"
trap 'rm -rf -- "$TMP"' EXIT

missing=()
for t in yq kustomize kubeconform gitleaks; do
  if command -v "$t" >/dev/null 2>&1; then
    if [[ $t == yq ]] && ! yq --version 2>/dev/null | grep -q mikefarah; then missing+=("yq(mikefarah 아님)"); fi
  else
    missing+=("$t")
  fi
done
# helm은 CI·판정용 실행(아래 두 스위치)에서만 필수다(머리 주석). 로컬에서 없으면 helm 케이스가 "도구 없음" 단언으로 바뀐다
if [[ ${VALIDATE_TESTS_REQUIRE_TOOLS:-0} == 1 || ${CI:-} == true ]] && ! command -v helm >/dev/null 2>&1; then
  missing+=(helm)
fi
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
# any_selected <케이스 이름>... — 하나라도 필터에 맞으면 0. 건너뜀을 세지 않는다(준비 작업 — 임시 저장소 등 — 을 할지 정할 때만 쓴다)
any_selected() {
  local c
  for c in "$@"; do
    if [[ -z $ONLY ]] || [[ $c =~ $ONLY ]]; then return 0; fi
  done
  return 1
}
# skip_cases <케이스 이름>... — any_selected가 거짓이라 블록을 통째로 건너뛸 때 그 케이스들을 건너뜀으로 센다
#   (어떤 필터를 주든 건너뜀 + 실행 = 전체 케이스 수가 되게). 필터에 맞는 이름이 섞여 있으면 그 이름은 세지 않으므로
#   any_selected의 else 쪽에서만 부른다
skip_cases() {
  local c
  for c in "$@"; do selected "$c" || true; done
}
# fail_case <이름> <사유> — 준비 단계가 실패해 validate를 돌리지 못한 케이스를 FAIL로 센다(조용히 빠지지 않게)
fail_case() {
  selected "$1" || return 0
  N=$((N + 1)); NF=$((NF + 1)); FAILED+=("$1")
  printf '[FAIL] %s\n       - 준비 실패: %s\n' "$1" "$2"
}

# run_case <이름> <root> <기대 exit> [--env K=V]... [--arg <validate.sh 인자>]... [+있어야 할 문자열 | -있으면 안 되는 문자열]...
#   --arg 는 --root 뒤에 차례로 붙는다(예: --arg --author-id --arg 323873425)
run_case() {
  selected "$1" || return 0
  local name=$1 root=$2 want=$3; shift 3
  local -a envs=() args=() asserts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) envs+=("$2"); shift 2 ;;
      --arg) args+=("$2"); shift 2 ;;
      *) asserts+=("$1"); shift ;;
    esac
  done
  local out rc=0 ok=1 a
  # 봇 목록(VALIDATE_BOT_AUTHORS·VALIDATE_BOT_IDS)도 지운다 — 작성자 단언은 스크립트 기본값을 전제로 한다.
  # 이벤트 발신자(PR_SENDER·PR_SENDER_ID)도 지운다 — CI 러너의 값이 새면 발신자 판정 케이스가 흔들린다
  out=$(env -u GITHUB_EVENT_NAME -u VALIDATE_REQUIRE_AUTHOR -u PR_AUTHOR -u PR_AUTHOR_ID -u PR_SENDER -u PR_SENDER_ID \
        -u CHANGED_FILES -u CHANGED_DIFF \
        -u VALIDATE_BASE_SHA -u VALIDATE_HEAD_SHA -u VALIDATE_ONLY_AUTHOR -u VALIDATE_BOT_AUTHORS -u VALIDATE_BOT_IDS \
        "${envs[@]}" bash "$VALIDATE" --root "$root" "${args[@]}" 2>&1) || rc=$?
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
    '+[PASS] 10 REL — platform/reloader (rendered): ClusterRole·ClusterRoleBinding 0 · Deployment reloader/reloader args = ["--log-level=info","--namespaces=identity,jt-dev,jt-prod,reloader","--reload-strategy=annotations"] · kind {ServiceAccount 1 · Deployment 1 · Role 5 · RoleBinding 5}(합계 12) · Role·RoleBinding ns 집합 = {identity,jt-dev,jt-prod,reloader} · RoleBinding → 같은 ns의 Role · 주체 = ServiceAccount reloader/reloader · reloader-role 규칙 동일·와일드카드 없음 · Reloader 이미지 컨테이너 1개(containers.0 · command 없음)')
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

# (a) 차트 values 갈래 — 네 트리는 **실제 차트 2.2.16 렌더**로 FAIL을 낸다(values 한 줄만 다르다)
#   — helm과 네트워크(차트 pull)가 필요하다(tests/fixtures/pol-port와 같다. 풀린 차트는 픽스처 아래
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
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 1 KUST' '-[FAIL] 10.4 REL-rbac-bind' '-[FAIL] 10.4 REL-image' \
    "-${REL_HINT}'=' 없는 플래그" "-${REL_HINT}같은 플래그"
  #   cloudflared: 감시 목록에 cloudflared 추가 → scoped 그대로(10.1 PASS)지만 인자 · Role·RoleBinding ns 집합 · 개수가 달라진다
  run_case rel-scoped-cloudflared "$FIX/rel-scoped/cloudflared" 1 \
    "${REL_ARGS_FAIL}[\"--log-level=info\",\"--namespaces=cloudflared,identity,jt-dev,jt-prod,reloader\",\"--reload-strategy=annotations\"](3개)" \
    "+${REL_HINT}cloudflared가 든 인자 [\"--namespaces=cloudflared,identity,jt-dev,jt-prod,reloader\"]: 계약 위반 단서" \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [Role 6≠5, RoleBinding 6≠5]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: Role ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: RoleBinding ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.4 REL-rbac-bind' '-[FAIL] 10.4 REL-rbac-rules' '-[FAIL] 10.4 REL-image' \
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

# (b) 순수 매니페스트 갈래 — 긍정 트리의 사본(deployment.yaml·rbac.yaml)에 결함 하나씩을 더했다(helm·네트워크 불필요 —
#   kustomize만. kustomize가 없으면 "도구 없음"이 정답이다). 앞의 넷(e1·e2·e3·e5)은 2026-09-22 독립 리뷰, 뒤의 열은 2026-09-28
#   적대적 검증(V-A1·A3·A4·A5·A6·A9)이 예전 검사에서 가짜 PASS(또는 단언 없는 분기)로 실측한 경로다.
REL_PURE='second-deploy command second-container args-newline swallow-ns swallow-strategy extra-arg var-expansion args-order decoy-container image-registry rb-subject role-wildcard extra-kind'
if command -v kustomize >/dev/null 2>&1; then
  #   second-deploy(e1): 이름이 다른 두 번째 Reloader Deployment + cloudflared ns Role·RoleBinding(규칙 2개 — 다른 ns와 다르다)
  run_case rel-scoped-second-deploy "$FIX/rel-scoped/second-deploy" 1 \
    "+[FAIL] 10.4 REL-image — $REL_L: Reloader 이미지(…/stakater/reloader) 컨테이너 2개 [Deployment/reloader/reloader spec.template.spec.containers.0, Deployment/reloader/reloader-cf spec.template.spec.containers.0]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: Role ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.4 REL-rbac-ns — $REL_L: RoleBinding ns 집합 불일치 — 빠짐 [] 여분 [cloudflared]" \
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [Deployment 2≠1, Role 6≠5, RoleBinding 6≠5]" \
    "+[FAIL] 10.4 REL-rbac-rules — $REL_L Role/cloudflared/reloader-role: rules ≠ 다수 규칙(4/5장" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.4 REL-rbac-bind' '-command 있음' \
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
    "+[FAIL] 10.3 REL-kinds — $REL_L: kind별 개수 불일치 [ConfigMap 1≠0] — 실제 {ConfigMap 1 · Deployment 1 · Role 5 · RoleBinding 5 · ServiceAccount 1}(합계 13)" \
    '-[PASS] 10 REL' '-[FAIL] 10.0' '-[FAIL] 10.1' '-[FAIL] 10.2' '-[FAIL] 10.4'
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
# PR 이벤트인데 PR_AUTHOR가 비면 조용히 꺼지지 않고 FAIL.
# PR 이벤트에서는 이벤트 발신자(PR_SENDER)도 필수다 — 작성자 누락 케이스는 발신자를 넣어 FAIL 사유를 작성자 하나로 좁힌다(음성 단언)
SND_MISS='PR_SENDER(이벤트 발신자 sender.login)가 비어 있음'
run_case author-required-pr-event "$FIX/positive" 1 \
  --env "GITHUB_EVENT_NAME=pull_request" --env 'PR_SENDER=joshua92y' \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 PR_AUTHOR가 비어 있음" \
  "-$SND_MISS"
run_case author-required-flag "$FIX/positive" 1 \
  --env "VALIDATE_REQUIRE_AUTHOR=1" --env 'PR_SENDER=joshua92y' \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='', VALIDATE_REQUIRE_AUTHOR=1)인데 PR_AUTHOR가 비어 있음" \
  "-$SND_MISS"
run_case author-push-event-ok "$FIX/positive" 0 \
  --env "GITHUB_EVENT_NAME=push" \
  "+[PASS] 6 AUTHOR — PR 작성자 미지정(push 이벤트 등)"

# --- 검사 6만 실행(--only-author · T047 전제 ②) -------------------------------------------------------------
# CI는 base ref의 스크립트를 이 모드로 돌린다(tests/README.md 「T047 필수 조건」). run_case는 --root 뒤에 인자를 넘기지 않으므로
# 같은 뜻의 환경 변수 VALIDATE_ONLY_AUTHOR=1로 켠다. 모든 케이스가 "작성자 검사만 실행" 문구를 요구하고, 전체 실행의 결과 줄
# (`결과: PASS`·`결과: FAIL`)과 검사 0(도구 확인) 출력이 없음을 단언한다 — 이 모드의 exit 0이 전체 통과로 읽히지 않고, 도구를 보지
# 않는다는 증거다.
OA='VALIDATE_ONLY_AUTHOR=1'
OA_MODE='+모드: --only-author — 작성자 검사만 실행'
OA_NOFULL=('-결과: PASS' '-결과: FAIL' '-== 검사 0' '-도구 yq')
run_case author-only-bot-ok "$FIX/positive" 0 --env "$OA" \
  --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/ok.diff" \
  "+[PASS] 6 AUTHOR — 봇 'jt-ci[bot]' PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest" \
  "$OA_MODE" '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): PASS' "${OA_NOFULL[@]}" '-[FAIL]'
run_case author-only-bot-bad-file "$FIX/positive" 1 --env "$OA" \
  --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE"$'\n'"platform/vault/kustomization.yaml" --env "CHANGED_DIFF=$FIX/author/bad-file.diff" \
  "+[FAIL] 6 AUTHOR-file — 봇 'jt-ci[bot]'의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
  "$OA_MODE" '+결과(작성자 검사만 실행): FAIL' "${OA_NOFULL[@]}" '-[PASS] 6 AUTHOR'
# PR 이벤트가 아니면(발신자 입력 없음) 작성자로만 판정한다 — PASS 줄이 그 사실을 드러낸다
run_case author-only-human "$FIX/positive" 0 --env "$OA" \
  --env "PR_AUTHOR=joshua92y" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/bad-line.diff" \
  "+[PASS] 6 AUTHOR — 작성자 'joshua92y'는 봇 아님" '+이벤트 발신자 미지정(PR 이벤트 아님) — 작성자로만 판정' \
  "$OA_MODE" '+결과(작성자 검사만 실행): PASS' "${OA_NOFULL[@]}"
run_case author-only-required-pr-event "$FIX/positive" 1 --env "$OA" \
  --env "GITHUB_EVENT_NAME=pull_request" --env 'PR_SENDER=joshua92y' \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 PR_AUTHOR가 비어 있음" \
  "-$SND_MISS" "$OA_MODE" '+결과(작성자 검사만 실행): FAIL' "${OA_NOFULL[@]}"
# 다른 검사가 돌지 않는다: img-newtag는 일반 모드에서 4a IMG-newTag FAIL(위 img-newtag 케이스 — 부분 트리라 5.x 등도 FAIL)이다.
# 이 모드에서는 exit 0이고 검사 6 밖의 머리·PASS·FAIL 줄이 하나도 없어야 한다.
run_case author-only-skips-other-checks "$FIX/img-newtag" 0 --env "$OA" \
  "+[PASS] 6 AUTHOR — PR 작성자 미지정(push 이벤트 등)" "$OA_MODE" '+결과(작성자 검사만 실행): PASS' "${OA_NOFULL[@]}" \
  '-[FAIL]' '-4a IMG-newTag' '-== 검사 1' '-== 검사 4' '-== 검사 5' '-[PASS] 0 YAML'
# 모드 스위치 값이 모호하면(0·1 밖) 전체 모드로 조용히 읽지 않고 인자 오류(exit 2)다. 빠른 부분 트리(gitleaks-empty)로 돈다 —
# 이 분기가 없으면 전체 모드로 돌아 exit 1이 된다.
run_case author-only-bad-switch "$FIX/gitleaks-empty" 2 --env 'VALIDATE_ONLY_AUTHOR=true' \
  '+error: VALIDATE_ONLY_AUTHOR는 0 또는 1이어야 한다: true' '-== 검사' '-결과'
# pull_request_target도 PR 이벤트다 — PR_AUTHOR가 비면 조용히 꺼지지 않고 FAIL
run_case author-only-required-pr-target-event "$FIX/positive" 1 --env "$OA" \
  --env "GITHUB_EVENT_NAME=pull_request_target" --env 'PR_SENDER=joshua92y' \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request_target', VALIDATE_REQUIRE_AUTHOR=0)인데 PR_AUTHOR가 비어 있음" \
  "-$SND_MISS" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'

# --- 봇 판정: 로그인(대소문자 무시) 또는 계정 ID(계약 「봇 판정은 로그인과 계정 ID 둘 다로 한다」) ------------------------------
# App 이름을 바꾸면 로그인은 바뀌지만 ID는 그대로다. 금지된 diff(bad-line — namespace 변경)를 넘기므로 봇으로 판정되면 FAIL, 사람이면 PASS다.
BOT_ID='323873425'
BAD_LINE_ENV=(--env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/bad-line.diff")
BAD_LINE_FAIL="+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'namespace: jt-prod'"
run_case author-only-bot-login-case "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=Joshuatech-GitApp-1[bot]" "${BAD_LINE_ENV[@]}" \
  "$BAD_LINE_FAIL" '+결과(작성자 검사만 실행): FAIL' '-봇 아님' '-[PASS] 6 AUTHOR'
run_case author-only-bot-id "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=renamed-app[bot]" --env "PR_AUTHOR_ID=$BOT_ID" \
  "${BAD_LINE_ENV[@]}" \
  "+봇 판정: 로그인 'renamed-app[bot]' — 봇 로그인 목록 밖 · 계정 ID $BOT_ID — VALIDATE_BOT_IDS 안 → 봇으로 본다" \
  "$BAD_LINE_FAIL" '+결과(작성자 검사만 실행): FAIL' '-봇 아님' '-[PASS] 6 AUTHOR'
# 인자 --author-id 는 PR_AUTHOR_ID와 같은 입력이다
run_case author-only-bot-id-arg "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=renamed-app[bot]" --arg --author-id --arg "$BOT_ID" \
  "${BAD_LINE_ENV[@]}" "$BAD_LINE_FAIL" '-봇 아님' '-[PASS] 6 AUTHOR'
# VALIDATE_BOT_IDS가 빈 값이면 기본값(VALIDATE_BOT_AUTHORS와 같은 규칙) — 빈 목록으로 읽혀 ID 판정이 꺼지지 않는다
run_case author-only-bot-ids-empty-default "$FIX/positive" 1 --env "$OA" --env 'VALIDATE_BOT_IDS=' \
  --env "PR_AUTHOR=renamed-app[bot]" --env "PR_AUTHOR_ID=$BOT_ID" "${BAD_LINE_ENV[@]}" "$BAD_LINE_FAIL" '-봇 아님' '-[PASS] 6 AUTHOR'
run_case author-only-human-id "$FIX/positive" 0 --env "$OA" --env "PR_AUTHOR=joshua92y" --env "PR_AUTHOR_ID=12345678" \
  "${BAD_LINE_ENV[@]}" "+[PASS] 6 AUTHOR — 작성자 'joshua92y'는 봇 아님" '+계정 ID 12345678도 VALIDATE_BOT_IDS 밖' \
  '+결과(작성자 검사만 실행): PASS' '-[FAIL]'
# PR_AUTHOR_ID는 선택 입력이지만, 주어졌는데 숫자가 아니거나 로그인 없이 ID만 있으면 입력이 어긋난 것이다(fail-closed)
run_case author-only-bad-id "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=joshua92y" --env "PR_AUTHOR_ID=12a" "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR_AUTHOR_ID '12a'가 숫자가 아님" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
run_case author-only-id-without-login "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR_ID=$BOT_ID" \
  "+[FAIL] 6 AUTHOR-input — PR_AUTHOR_ID '$BOT_ID'만 있고 PR_AUTHOR가 비어 있음" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
# 봇 ID 목록에 숫자가 아닌 원소가 있으면 인자 오류(exit 2) — 틀린 목록이 조용히 "봇 없음"으로 읽히지 않게
run_case author-only-bad-bot-ids "$FIX/gitleaks-empty" 2 --env "$OA" --env 'VALIDATE_BOT_IDS=323873425,abc' \
  "+error: VALIDATE_BOT_IDS의 원소는 숫자여야 한다: 'abc'" '-== 검사' '-결과'

# --- 봇 판정 · 이벤트 발신자(계약 「봇 판정의 대상은 PR 작성자와 이벤트 발신자 둘 다다」) --------------------------------------
# App은 저장소 쓰기 권한으로 **사람이 연 PR의 브랜치에 push하고 머지할 수 있다**. 작성자(pull_request.user)가 사람이어도 이벤트
# 발신자(sender — push한 쪽 · 다시 연 쪽)가 봇이면 봇 규칙(PR 전체 = merge-base ↔ head 가 dev digest 제자리 교체뿐)을 적용한다.
# 발신자의 "봇" 정의는 작성자와 같다(로그인 대소문자 무시 · 계정 ID). PR 이벤트에서 발신자가 비면 FAIL(조용한 비활성 금지).
# 워크플로 입력: PR_SENDER = sender.login · PR_SENDER_ID = sender.id (인자 --sender · --sender-id)
SND_HUMAN='joshua92y'
SND_PR_EV='GITHUB_EVENT_NAME=pull_request'
SND_BOT_LOGIN="+봇 판정: 작성자 '$SND_HUMAN'는 봇 아님 · 이벤트 발신자 'jt-ci[bot]'는 봇(로그인이 봇 로그인 목록 안) → 발신자 기준으로 봇 PR로 본다"
SND_LBL="봇 발신자 'jt-ci[bot]'(작성자 '$SND_HUMAN')"
SND_PASS_PREFIX="+[PASS] 6 AUTHOR — 작성자 '$SND_HUMAN'는 봇 아님 — 경로 제한 없음"
BAD_FILE_ENV=(--env "CHANGED_FILES=$DIGEST_FILE"$'\n'"platform/vault/kustomization.yaml" --env "CHANGED_DIFF=$FIX/author/bad-file.diff")
# 사람 작성자 + 봇 발신자(로그인) + 금지 파일 → 봇 규칙으로 FAIL. 봇 판정 줄이 작성자·발신자를 함께 드러낸다
run_case author-only-sender-bot-login "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env 'PR_SENDER=jt-ci[bot]' "${BAD_FILE_ENV[@]}" "$SND_BOT_LOGIN" \
  "+[FAIL] 6 AUTHOR-file — ${SND_LBL}의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
  "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'resources: [evil.yaml]'" \
  '+결과(작성자 검사만 실행): FAIL' "-${SND_PASS_PREFIX:1}" '-[PASS] 6 AUTHOR' "-$SND_MISS"
# 봇 발신자(ID만 — 로그인은 사람처럼 보인다): App 이름을 바꿔도 ID는 그대로다
run_case author-only-sender-bot-id "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env 'PR_SENDER=helpful-human' --env "PR_SENDER_ID=$BOT_ID" "${BAD_LINE_ENV[@]}" \
  "+봇 판정: 작성자 '$SND_HUMAN'는 봇 아님 · 이벤트 발신자 'helpful-human'는 봇(계정 ID $BOT_ID — VALIDATE_BOT_IDS 안) → 발신자 기준으로 봇 PR로 본다" \
  "$BAD_LINE_FAIL" '+결과(작성자 검사만 실행): FAIL' "-${SND_PASS_PREFIX:1}" '-[PASS] 6 AUTHOR'
# 봇 발신자 + 허용된 diff(dev digest 제자리 교체) → 봇 규칙을 **통과**한 PASS(사람 PASS가 아니다)
run_case author-only-sender-bot-ok "$FIX/positive" 0 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env 'PR_SENDER=jt-ci[bot]' --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/ok.diff" "$SND_BOT_LOGIN" \
  "+[PASS] 6 AUTHOR — ${SND_LBL} PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest 값의 제자리 교체" \
  '+결과(작성자 검사만 실행): PASS' '-[FAIL]' "-${SND_PASS_PREFIX:1}"
# 사람 작성자 + 사람 발신자 + 금지된 diff → 제한 없음(PASS). PASS 줄이 발신자도 봇이 아님을 드러낸다
run_case author-only-sender-human "$FIX/positive" 0 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env 'PR_AUTHOR_ID=12345678' --env "PR_SENDER=$SND_HUMAN" --env 'PR_SENDER_ID=12345678' "${BAD_LINE_ENV[@]}" \
  "${SND_PASS_PREFIX}(ruleset·리뷰가 게이트) · 계정 ID 12345678도 VALIDATE_BOT_IDS 밖 · 이벤트 발신자 '$SND_HUMAN'도 봇 아님(계정 ID 12345678도 VALIDATE_BOT_IDS 밖)" \
  '+결과(작성자 검사만 실행): PASS' '-[FAIL]' '-봇 판정:'
# 봇 작성자 + 사람 발신자 → 작성자가 봇이면 발신자와 무관하게 봇 규칙(발신자 판정 줄 없음)
run_case author-only-sender-author-bot "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env 'PR_AUTHOR=jt-ci[bot]' \
  --env "PR_SENDER=$SND_HUMAN" --env 'PR_SENDER_ID=12345678' "${BAD_LINE_ENV[@]}" \
  "$BAD_LINE_FAIL" '+결과(작성자 검사만 실행): FAIL' '-봇 아님' '-봇 판정:' '-[PASS] 6 AUTHOR'
# PR 이벤트(pull_request · pull_request_target · VALIDATE_REQUIRE_AUTHOR=1)인데 발신자가 비면 FAIL — 작성자 누락과 다른 메시지
run_case author-only-sender-missing "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 $SND_MISS" \
  '-PR_AUTHOR가 비어 있음' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
run_case author-only-sender-missing-pr-target "$FIX/positive" 1 --env "$OA" --env 'GITHUB_EVENT_NAME=pull_request_target' \
  --env "PR_AUTHOR=$SND_HUMAN" "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request_target', VALIDATE_REQUIRE_AUTHOR=0)인데 $SND_MISS" \
  '-PR_AUTHOR가 비어 있음' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
run_case author-only-sender-missing-flag "$FIX/positive" 1 --env "$OA" --env 'VALIDATE_REQUIRE_AUTHOR=1' \
  --env "PR_AUTHOR=$SND_HUMAN" "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='', VALIDATE_REQUIRE_AUTHOR=1)인데 $SND_MISS" \
  '-PR_AUTHOR가 비어 있음' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
# 작성자와 발신자가 모두 비면 두 누락을 모두 찍는다(하나만 고치고 다시 돌려야 다른 하나가 보이는 일이 없게)
run_case author-only-sender-both-missing "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 PR_AUTHOR가 비어 있음" \
  "+[FAIL] 6 AUTHOR-input — PR 이벤트(GITHUB_EVENT_NAME='pull_request', VALIDATE_REQUIRE_AUTHOR=0)인데 $SND_MISS" \
  '+PASS 0 · FAIL 2' '+결과(작성자 검사만 실행): FAIL'
# PR_SENDER_ID는 선택 입력 — 주어졌는데 숫자가 아니거나, 발신자 로그인 없이 ID만 있으면 입력이 어긋난 것이다(fail-closed)
run_case author-only-sender-bad-id "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env "PR_SENDER=$SND_HUMAN" --env 'PR_SENDER_ID=12a' "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR_SENDER_ID '12a'가 숫자가 아님(sender.id) — fail-closed" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
run_case author-only-sender-id-without-login "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=$SND_HUMAN" \
  --env "PR_SENDER_ID=$BOT_ID" "${BAD_LINE_ENV[@]}" \
  "+[FAIL] 6 AUTHOR-input — PR_SENDER_ID '$BOT_ID'만 있고 PR_SENDER가 비어 있음 — 발신자 입력이 어긋남(fail-closed)" \
  '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
# 발신자만 있고 작성자가 없으면(PR 이벤트 아님) PR_AUTHOR_ID만 있는 경우와 같이 fail-closed — "대상 없음" PASS로 읽지 않는다
run_case author-only-sender-without-author "$FIX/positive" 1 --env "$OA" --env 'PR_SENDER=jt-ci[bot]' \
  "+[FAIL] 6 AUTHOR-input — 이벤트 발신자(PR_SENDER 'jt-ci[bot]' · PR_SENDER_ID '')만 있고 PR_AUTHOR가 비어 있음 — 작성자 입력이 어긋남(fail-closed)" \
  '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
# 발신자 로그인 비교도 대소문자를 가리지 않는다
run_case author-only-sender-login-case "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --env 'PR_SENDER=Joshuatech-GitApp-1[BOT]' "${BAD_LINE_ENV[@]}" \
  "+봇 판정: 작성자 '$SND_HUMAN'는 봇 아님 · 이벤트 발신자 'Joshuatech-GitApp-1[BOT]'는 봇(로그인이 봇 로그인 목록 안)" \
  "$BAD_LINE_FAIL" "-${SND_PASS_PREFIX:1}" '-[PASS] 6 AUTHOR'
# 인자 --sender · --sender-id 는 PR_SENDER · PR_SENDER_ID와 같은 입력이다(로그인은 사람처럼 보이고 ID로만 봇 — 두 인자가 모두 읽혀야 FAIL)
run_case author-only-sender-arg "$FIX/positive" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
  --arg --sender --arg helpful-human --arg --sender-id --arg "$BOT_ID" "${BAD_LINE_ENV[@]}" \
  "+봇 판정: 작성자 '$SND_HUMAN'는 봇 아님 · 이벤트 발신자 'helpful-human'는 봇(계정 ID $BOT_ID — VALIDATE_BOT_IDS 안)" \
  "$BAD_LINE_FAIL" "-$SND_MISS" "-${SND_PASS_PREFIX:1}" '-[PASS] 6 AUTHOR'

# --- 제자리 교체(계약 판정 규칙 ②) · CHANGED_DIFF 입력 -------------------------------------------------------------------
# git은 붙은 두 줄의 교체를 '-X -Y +Z +W'로 묶어 보여 준다. 쌍은 바로 붙은 -Y/+Z 하나뿐이다 — X는 짝 없는 삭제, W는 짝 없는 추가.
# (kustomization의 digest 줄은 images 항목마다 name 줄을 사이에 두므로 정상 봇 PR에서 이 모양은 나오지 않는다)
IP_DEL='봇 diff: 제자리 교체만 허용 — 짝 없는 삭제 줄(바로 뒤에 추가 줄이 없다) → '
IP_ADD='봇 diff: 제자리 교체만 허용 — 짝 없는 추가 줄(바로 앞에 삭제 줄이 없다) → '
run_case author-only-inplace-grouped "$FIX/positive" 1 --env "$OA" --env "PR_AUTHOR=jt-ci[bot]" \
  --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/grouped.diff" \
  "+[FAIL] 6 AUTHOR-line — ${IP_DEL}'    digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'" \
  "+[FAIL] 6 AUTHOR-line — ${IP_ADD}'    digest: sha256:2222222222222222222222222222222222222222222222222222222222222222'" \
  "-${IP_DEL}'    digest: sha256:1111" "-${IP_ADD}'    digest: sha256:fedc" '-images[].digest 외 줄' '-[PASS] 6 AUTHOR'
# 도구 없이 돈다: PATH에서 도구 5종(yq·kustomize·kubeconform·gitleaks·helm)이 든 디렉터리를 빼고 돌린다. 남은 PATH에서 못 찾는
# bash·git·dirname·tr·cat은 tests/.tmp/no-tools-bin/ 에 심볼릭 링크로 보탠다(예: ubuntu 러너는 /usr/bin에 yq가 있어 /usr/bin이
# 통째로 빠진다). 새 bash 프로세스로 "도구 0 · git 있음"을 먼저 확인하고, 구성하지 못하면 조용히 건너뛰지 않고 FAIL로 센다.
TOOLFREE_PATH=''; TF_ERR=''
tool_free_path() { # → 전역 TOOLFREE_PATH. 실패하면 TF_ERR에 사유를 두고 1(if 조건 안에서 부르므로 단계마다 실패를 확인한다)
  local d t hit shim="$TMP/no-tools-bin" src
  local -a dirs=() keep=()
  IFS=':' read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [[ -n $d ]] || continue
    hit=0
    for t in yq kustomize kubeconform gitleaks helm; do
      if [[ -e $d/$t || -e $d/$t.exe ]]; then hit=1; break; fi
    done
    [[ $hit == 1 ]] || keep+=("$d")
  done
  TOOLFREE_PATH=$(IFS=':'; printf '%s' "${keep[*]}")
  mkdir -p "$shim" || { TF_ERR="mkdir $shim 실패"; return 1; }
  for t in bash git dirname tr cat; do
    if (PATH=$TOOLFREE_PATH; command -v "$t") >/dev/null 2>&1; then continue; fi
    src=$(command -v "$t") || { TF_ERR="$t 를 찾을 수 없음"; return 1; }
    ln -s "$src" "$shim/$t" || { TF_ERR="$t 링크 실패"; return 1; }
  done
  TOOLFREE_PATH="$shim${TOOLFREE_PATH:+:$TOOLFREE_PATH}"
  TF_ERR=$(env PATH="$TOOLFREE_PATH" bash -c 'for t in yq kustomize kubeconform gitleaks helm; do
      if command -v "$t" >/dev/null 2>&1; then echo "도구가 남아 있음: $(command -v "$t")"; exit 1; fi
    done
    command -v git >/dev/null 2>&1 || { echo "git 없음"; exit 1; }' 2>&1) || { TF_ERR="확인 실패: ${TF_ERR:-bash 실행 불가}"; return 1; }
}
if any_selected author-only-no-tools; then
  if tool_free_path; then
    run_case author-only-no-tools "$FIX/positive" 0 --env "$OA" --env "PATH=$TOOLFREE_PATH" \
      --env "PR_AUTHOR=jt-ci[bot]" --env "CHANGED_FILES=$DIGEST_FILE" --env "CHANGED_DIFF=$FIX/author/ok.diff" \
      "+[PASS] 6 AUTHOR — 봇 'jt-ci[bot]' PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest" \
      "$OA_MODE" '+결과(작성자 검사만 실행): PASS' "${OA_NOFULL[@]}" '-[FAIL]' '-도구 없음'
  else
    fail_case author-only-no-tools "도구 없는 PATH를 만들 수 없음 — $TF_ERR"
  fi
else
  skip_cases author-only-no-tools
fi

# --- 검사 6 · SHA 입력(VALIDATE_BASE_SHA · VALIDATE_HEAD_SHA): merge-base ↔ HEAD(T047 전제 ③) · fail-closed -------------
# git 이력이 필요하므로 tests/.tmp/mergebase/ 에 임시 git 저장소를 만든다(--root는 저장소 안이어야 한다). 커밋은 -c 로 이름·메일·
# 서명·훅·줄끝 설정을 주고 만든다 — 전역 git 설정을 바꾸지도, 그 영향을 받지도 않는다. 부분 트리라 모두 --only-author로 돌린다.
#
#   c0 ─┬─ c2            main이 앞서감: platform/vault/kustomization.yaml 변경(봇에게 금지된 파일)   ← BASE
#       └─ c1 ─ c1b      PR: dev digest 한 줄(c1) · 이어서 금지된 파일도 고침(c1b)                  ← HEAD
#   c3                    고아 이력(공통 조상 없음)
# 두 점 diff(c2 c1)라면 main 쪽 변경의 역(platform/vault)이 섞여 c1이 FAIL한다 — merge-base(c0) ↔ c1은 digest 한 줄뿐이다.
# mb_build_t2가 c0에서 더 가른다(계약 판정 규칙 ①·④와 입력 분기):
#   c0 ─┬─ cx ─┬─ xmain = merge(cx, cy)            main이 교차 이력을 머지 커밋으로 받음                  ← BASE
#       └─ cy ─┴─ xhead = parents (cx, cy)          또 하나의 머지 커밋, 트리 = (git이 고르는 쪽) + digest ← HEAD
#                                                   → merge-base --all = {cx, cy} 2개
#   c0 ── cr              platform/vault/kustomization.yaml → apps/vault/overlays/dev/kustomization.yaml 이름 변경
MB_REPO="$TMP/mergebase"
MB_BROKEN="$TMP/mergebase-broken"
MB_FILE='apps/demo/overlays/dev/kustomization.yaml'
MB_C0=''; MB_C1=''; MB_C1B=''; MB_C2=''; MB_C3=''
MB_CX=''; MB_CY=''; MB_XMAIN=''; MB_XHEAD=''; MB_CR=''
# tg <저장소> <git 인자>... — 임시 저장소용 git(전역 설정에 기대지도, 바꾸지도 않는다)
tg() {
  local repo=$1; shift
  # gc.auto=0 · maintenance.auto=false: 임시 저장소에서 git이 뒤에서 객체를 pack으로 묶지 않게 한다(merge · commit 뒤의 자동
  # 정리). mb_break는 느슨한 객체 파일 하나를 지워 diff만 실패시키는데, 그 객체가 pack 안에 있으면 지워지지 않는다
  git -c user.name=validate-tests -c user.email=validate-tests@example.invalid -c commit.gpgsign=false \
    -c core.autocrlf=false -c core.hooksPath="$TMP/no-hooks" -c init.defaultBranch=main -c advice.detachedHead=false \
    -c gc.auto=0 -c maintenance.auto=false \
    -C "$repo" "$@"
}
mb_git() { tg "$MB_REPO" "$@"; }
# hex64 <문자 1개> · hex40 <문자 1개> — 그 문자를 64개·40개 이은 값(가짜 digest · 가짜 커밋 ID)
hex64() { local d=$1$1$1$1$1$1$1$1; printf '%s' "$d$d$d$d$d$d$d$d"; }
hex40() { local d=$1$1$1$1$1$1$1$1; printf '%s' "$d$d$d$d$d"; }
mb_kust() { # <digest 문자 1개> — dev overlay kustomization(digest = 그 문자 64개)
  local d=$1$1$1$1$1$1$1$1
  d=$d$d$d$d$d$d$d$d
  printf 'resources:\n  - ../../base\nimages:\n  - name: ghcr.io/example/demo\n    newName: ghcr.io/example/demo\n    digest: sha256:%s\n' "$d" > "$MB_REPO/$MB_FILE"
}
mb_build() { # → 전역 MB_C0·MB_C1·MB_C1B·MB_C2·MB_C3 (if 조건 안에서 부르므로 set -e가 꺼진다 — 단계마다 실패를 확인한다)
  mkdir -p "$MB_REPO/apps/demo/overlays/dev" "$MB_REPO/platform/vault" || return 1
  mb_git init -q || return 1
  mb_kust a || return 1
  printf 'resources: []\n' > "$MB_REPO/platform/vault/kustomization.yaml" || return 1
  mb_git add -A || return 1
  mb_git commit -q -m c0 || return 1
  MB_C0=$(mb_git rev-parse HEAD) || return 1
  printf 'resources: [evil.yaml]\n' > "$MB_REPO/platform/vault/kustomization.yaml" || return 1
  mb_git commit -q -am c2 || return 1
  MB_C2=$(mb_git rev-parse HEAD) || return 1
  mb_git checkout -q --detach "$MB_C0" || return 1
  mb_kust b || return 1
  mb_git commit -q -am c1 || return 1
  MB_C1=$(mb_git rev-parse HEAD) || return 1
  printf 'resources: [pr-evil.yaml]\n' > "$MB_REPO/platform/vault/kustomization.yaml" || return 1
  mb_git commit -q -am c1b || return 1
  MB_C1B=$(mb_git rev-parse HEAD) || return 1
  mb_git checkout -q --orphan unrelated || return 1
  mb_git commit -q -m c3 || return 1
  MB_C3=$(mb_git rev-parse HEAD) || return 1
}
mb_build_t2() { # → 전역 MB_CX·MB_CY·MB_XMAIN·MB_XHEAD·MB_CR (mb_build 뒤에 — 위 그림의 둘째 부분)
  local p pick t i
  mb_git checkout -q --detach "$MB_C0" || return 1
  printf 'resources: [cx.yaml]\n' > "$MB_REPO/platform/vault/kustomization.yaml" || return 1
  mb_git commit -q -am cx || return 1
  MB_CX=$(mb_git rev-parse HEAD) || return 1
  mb_git checkout -q --detach "$MB_C0" || return 1
  printf 'resources: [cy.yaml]\n' > "$MB_REPO/platform/cy.yaml" || return 1
  mb_git add -A || return 1
  mb_git commit -q -m cy || return 1
  MB_CY=$(mb_git rev-parse HEAD) || return 1
  mb_git checkout -q --detach "$MB_CX" || return 1
  mb_git merge -q --no-ff --no-edit -m xmain "$MB_CY" || return 1
  MB_XMAIN=$(mb_git rev-parse HEAD) || return 1
  # xhead 트리 = git merge-base(하나만)가 고르는 쪽의 트리 + digest 한 줄 — 그 하나로 보면 diff가 깨끗하다(리뷰 F1의 우회 모양).
  # 고르는 쪽은 그래프·날짜로 정해지므로 cx로 만들어 보고 다르면 고른 쪽으로 한 번 다시 만든다(어느 쪽이든 merge-base는 2개다)
  p=$MB_CX
  for i in 1 2; do
    mb_git checkout -q --detach "$p" || return 1
    mb_kust c || return 1
    mb_git add -A || return 1
    t=$(mb_git write-tree) || return 1
    mb_git reset -q --hard || return 1
    MB_XHEAD=$(mb_git commit-tree "$t" -p "$MB_CX" -p "$MB_CY" -m xhead) || return 1
    pick=$(mb_git merge-base "$MB_XMAIN" "$MB_XHEAD") || return 1
    if [[ $pick == "$p" ]]; then break; fi
    p=$pick
  done
  mb_git checkout -q --detach "$MB_C0" || return 1
  mkdir -p "$MB_REPO/apps/vault/overlays/dev" || return 1
  mb_git mv platform/vault/kustomization.yaml apps/vault/overlays/dev/kustomization.yaml || return 1
  mb_git commit -q -m cr || return 1
  MB_CR=$(mb_git rev-parse HEAD) || return 1
}
mb_break() { # 사본에서 c1의 dev kustomization blob을 지운다 → 커밋 해석·merge-base·파일 목록은 되고 diff 본문만 실패한다
  # 객체가 pack 안에 있으면 느슨한 파일을 지워도 남는다(2026-09-30 러너에서 1회 — 어제는 같은 러너에서 네 번 통과했다). 그래서
  # 사본의 pack을 전부 밖으로 옮긴 뒤 느슨한 객체로 풀어 놓고(pack이 저장소 안에 있으면 unpack-objects가 "이미 있다"며 건너뛴다)
  # 그 다음에 지운다. 그래도 남으면 객체 저장 상태를 로그에 남긴다(fail_case 메시지에 실린다)
  local blob p b hold
  cp -R "$MB_REPO" "$MB_BROKEN" || return 1
  blob=$(mb_git rev-parse "$MB_C1:$MB_FILE") || return 1
  hold="$TMP/mergebase-broken-packs"
  mkdir -p "$hold" || return 1
  for p in "$MB_BROKEN"/.git/objects/pack/*.pack; do
    [[ -e $p ]] || continue
    b=${p%.pack}
    mv -f "$b".pack "$hold"/ || return 1
    rm -f "$b".idx "$b".rev "$b".bitmap "$b".promisor "$b".mtimes
    git -C "$MB_BROKEN" unpack-objects -q < "$hold/$(basename "$b").pack" || return 1
  done
  rm -f "$MB_BROKEN/.git/objects/${blob:0:2}/${blob:2}" || return 1
  if git -C "$MB_BROKEN" cat-file -e "$blob" 2>/dev/null; then
    printf 'mb_break: blob %s이 사본에 아직 있다 — count-objects: %s · packs: %s\n' "$blob" \
      "$(git -C "$MB_BROKEN" count-objects -v 2>&1 | tr '\n' ' ')" "$(ls "$MB_BROKEN/.git/objects/pack" 2>&1 | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}
MB_CASES=(author-mergebase-main-ahead author-mergebase-head-forbidden author-mergebase-unrelated author-mergebase-bad-sha
  author-mergebase-dash-sha author-mergebase-criss-cross author-mergebase-files-fail author-mergebase-no-renames
  author-mergebase-given-files author-mergebase-diff-fails author-only-sender-sha-head-forbidden)
MB_ENV=(--env "$OA" --env "PR_AUTHOR=jt-ci[bot]")
if any_selected "${MB_CASES[@]}"; then
  mkdir -p "$TMP"
  if mb_build 2>"$TMP/mergebase.log" && mb_build_t2 2>>"$TMP/mergebase.log"; then
    # main이 앞서간 PR: 두 점 diff였다면 platform/vault(main 쪽 변경의 역)가 섞여 FAIL — merge-base 기준이면 digest 한 줄뿐이라 PASS
    run_case author-mergebase-main-ahead "$MB_REPO" 0 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1" \
      "+[PASS] 6 AUTHOR — 봇 'jt-ci[bot]' PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest" \
      '+결과(작성자 검사만 실행): PASS' '-[FAIL]' '-platform/vault'
    # merge-base 기준이 PR 자신의 변경은 그대로 본다: head 쪽 금지 파일 변경은 FAIL, main 쪽 줄('resources: [evil.yaml]')은 섞이지 않는다
    run_case author-mergebase-head-forbidden "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1B" \
      "+[FAIL] 6 AUTHOR-file — 봇 'jt-ci[bot]'의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'resources: [pr-evil.yaml]'" \
      "-→ 'resources: [evil.yaml]'" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    # fail-closed: 요약 없이 git의 종료 코드로 끝나지 않고 6 AUTHOR-input FAIL + 요약 + exit 1
    run_case author-mergebase-unrelated "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C3" --env "VALIDATE_HEAD_SHA=$MB_C1" \
      "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — merge-base 계산 실패: 공통 조상 없음" \
      '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    run_case author-mergebase-bad-sha "$MB_REPO" 1 "${MB_ENV[@]}" \
      --env "VALIDATE_BASE_SHA=0123456789abcdef0123456789abcdef01234567" --env "VALIDATE_HEAD_SHA=$MB_C1" \
      "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — VALIDATE_BASE_SHA '0123456789abcdef0123456789abcdef01234567'가 이 저장소의 커밋으로 풀리지 않음" \
      '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    run_case author-mergebase-dash-sha "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=-x" \
      "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — VALIDATE_HEAD_SHA '-x'가 '-'로 시작한다(git 옵션으로 읽힌다)" \
      '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    # 교차 이력(계약 판정 규칙 ①): merge-base가 cx·cy 둘이다. git merge-base(하나만)는 그중 하나를 골라 주고, xhead 트리가 "고른 쪽 +
    # digest 한 줄"이라 그 diff는 깨끗하다 — 실제 머지 결과는 다른 쪽의 변경까지 바꾼다. 하나가 아니면 입력 오류로 FAIL
    run_case author-mergebase-criss-cross "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_XMAIN" --env "VALIDATE_HEAD_SHA=$MB_XHEAD" \
      "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — merge-base가 2개" \
      '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    # 파일 목록 계산 실패: diff.orderFile이 없는 파일을 가리키면 git diff 계열만 죽는다(rev-parse·merge-base는 산다) — 목록이 먼저다
    run_case author-mergebase-files-fail "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1" \
      --env 'GIT_CONFIG_COUNT=1' --env 'GIT_CONFIG_KEY_0=diff.orderFile' --env "GIT_CONFIG_VALUE_0=$TMP/no-such-orderfile" \
      "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — 변경 파일 목록 계산 실패(git diff --name-only merge-base " \
      '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR' '-diff 계산 실패'
    # --no-renames: 금지 파일(platform/vault)을 허용 경로(apps/vault/overlays/dev)로 옮긴 PR. 이름 변경 감지가 켜져 있으면 파일 목록에는
    # 새 경로(허용)만 나오고 diff는 rename 머리줄이 된다 — 끄면 옛 경로가 파일 목록에 드러나고 diff는 삭제 + 추가다
    run_case author-mergebase-no-renames "$MB_REPO" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C0" --env "VALIDATE_HEAD_SHA=$MB_CR" \
      "+[FAIL] 6 AUTHOR-file — 봇 'jt-ci[bot]'의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
      "+[FAIL] 6 AUTHOR-file — 봇 diff: 파일 추가·삭제·이름/모드 변경 불허 (deleted file mode 100644)" \
      '-이름 변경 불허' '-similarity index' '-rename from' '-[PASS] 6 AUTHOR'
    # CHANGED_FILES가 주어지면 파일 목록은 그 값을 쓰고 diff만 계산한다: 목록(허용 파일 하나)에 없는 platform/vault 변경이
    # 계산된 diff에서 FAIL하고, 파일 목록 쪽 FAIL(…의 변경 파일 … 불허)은 없다
    run_case author-mergebase-given-files "$MB_REPO" 1 "${MB_ENV[@]}" --env "CHANGED_FILES=$MB_FILE" \
      --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1B" \
      "+[FAIL] 6 AUTHOR-file — 봇 diff: 파일 'platform/vault/kustomization.yaml' 불허" \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'resources: [pr-evil.yaml]'" \
      "-의 변경 파일 'platform/vault/kustomization.yaml' 불허" '-입력이 없음' '-[PASS] 6 AUTHOR'
    # 발신자 판정은 SHA 경로에서도 같다: 사람이 연 PR(작성자 사람)에 봇이 push(발신자 봇) — head 이력의 금지 파일 변경(c1b)이
    # merge-base ↔ head 전체 diff에서 FAIL한다(main 쪽 줄은 섞이지 않는다)
    run_case author-only-sender-sha-head-forbidden "$MB_REPO" 1 --env "$OA" --env "$SND_PR_EV" --env "PR_AUTHOR=$SND_HUMAN" \
      --env 'PR_SENDER=jt-ci[bot]' --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1B" "$SND_BOT_LOGIN" \
      "+[FAIL] 6 AUTHOR-file — ${SND_LBL}의 변경 파일 'platform/vault/kustomization.yaml' 불허" \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'resources: [pr-evil.yaml]'" \
      "-→ 'resources: [evil.yaml]'" '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    if any_selected author-mergebase-diff-fails; then
      if mb_break 2>>"$TMP/mergebase.log"; then
        run_case author-mergebase-diff-fails "$MB_BROKEN" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$MB_C2" --env "VALIDATE_HEAD_SHA=$MB_C1" \
          "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]' — diff 계산 실패(git diff merge-base " \
          '+== 요약(작성자 검사만 실행' '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR' '-변경 파일 목록 계산 실패'
      else
        fail_case author-mergebase-diff-fails "객체를 지운 사본을 만들 수 없음 — $(tr -d '\r' < "$TMP/mergebase.log" | tail -n 3 | tr '\n' ' ')"
      fi
    else
      skip_cases author-mergebase-diff-fails
    fi
  else
    mb_why=$(tr -d '\r' < "$TMP/mergebase.log" | tail -n 3 | tr '\n' ' ')
    for c in "${MB_CASES[@]}"; do fail_case "$c" "임시 git 저장소를 만들 수 없음 — $mb_why"; done
  fi
else
  skip_cases "${MB_CASES[@]}"
fi

# git 작업 트리가 아닌 --root + SHA 입력 → fail-closed. --root는 저장소 안이어야 하므로 tests/.tmp/nogit 을 쓰고,
# GIT_CEILING_DIRECTORIES로 git이 그 위(이 저장소)로 올라가 찾지 못하게 한다
mkdir -p "$TMP/nogit"
run_case author-mergebase-not-git "$TMP/nogit" 1 "${MB_ENV[@]}" --env "GIT_CEILING_DIRECTORIES=$TMP" \
  --env 'VALIDATE_BASE_SHA=HEAD' --env 'VALIDATE_HEAD_SHA=HEAD' \
  "+[FAIL] 6 AUTHOR-input — 봇 작성자 'jt-ci[bot]'인데 git 저장소가 아니라 diff를 계산할 수 없음" \
  '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR' '-커밋으로 풀리지 않음'

# --- 검사 6 · hunk 구간(계약 판정 규칙 ③) · 제자리 교체(규칙 ②) — 실제 git diff 모양으로 ------------------------------------------
# tests/.tmp/lines/ 의 L0: 두 images 항목(demo는 digest 있음, side는 없음) + 끝줄 '-- guard: keep' 인 파일과, 줄 끝 개행 없이 digest
# 줄로 끝나는 파일. L0에서 갈라진 커밋마다 변경 한 가지를 담고 BASE = L0 · HEAD = 그 커밋으로 돌린다.
#   ok        demo digest 값만 교체                         → PASS
#   noeol     개행 없는 마지막 digest 줄 교체('-' / '\' / '+' / '\')   → PASS
#   move      demo의 digest 줄을 지우고 side에 추가(고정이 side로 옮겨 간다) → 짝 없는 삭제 + 짝 없는 추가
#   delete    demo의 digest 줄 삭제만                       → 짝 없는 삭제
#   add       side 뒤에 '- digest:' 목록 항목 삽입           → 짝 없는 추가
#   reshape   demo의 '    digest:' 를 '  - digest:' 로 교체(쌍이지만 새 images 항목이 된다) → digest 값 밖이 바뀐 교체
#   plusplus  끝에 '++ anything: goes' 추가 → diff 줄 '+++ anything: goes'(파일 머리줄과 같은 모양)
#   minusminus 끝줄 '-- guard: keep' 삭제 → diff 줄 '--- guard: keep'
LN_REPO="$TMP/lines"
LN_FILE='apps/lines/overlays/dev/kustomization.yaml'
LN_NOEOL='apps/noeol/overlays/dev/kustomization.yaml'
LN_L0=''
declare -A LN=()
ln_git() { tg "$LN_REPO" "$@"; }
ln_file() { # <demo의 digest 줄 | ''> <side 뒤에 붙일 줄 | ''> <꼬리(개행 포함)>
  {
    printf 'resources:\n  - ../../base\nimages:\n  - name: ghcr.io/example/demo\n    newName: ghcr.io/example/demo\n'
    if [[ -n $1 ]]; then printf '%s\n' "$1"; fi
    printf '  - name: ghcr.io/example/side\n    newName: ghcr.io/example/side\n'
    if [[ -n $2 ]]; then printf '%s\n' "$2"; fi
    printf '%s' "$3"
  } > "$LN_REPO/$LN_FILE"
}
ln_noeol() { # <digest 문자 1개> — 마지막 줄(digest) 뒤에 개행이 없다
  printf 'images:\n  - name: ghcr.io/example/noeol\n    newName: ghcr.io/example/noeol\n    digest: sha256:%s' "$(hex64 "$1")" > "$LN_REPO/$LN_NOEOL"
}
ln_variant() { # <이름> <명령>... — L0에서 갈라 명령으로 파일을 고치고 커밋한다 → LN[<이름>]
  local name=$1; shift
  ln_git checkout -q --detach "$LN_L0" || return 1
  "$@" || return 1
  ln_git commit -q -am "$name" || return 1
  LN[$name]=$(ln_git rev-parse HEAD) || return 1
}
ln_build() { # if 조건 안에서 부르므로 set -e가 꺼진다 — 단계마다 실패를 확인한다
  local g=$'-- guard: keep\n' dc="    digest: sha256:$(hex64 c)"
  mkdir -p "$LN_REPO/${LN_FILE%/*}" "$LN_REPO/${LN_NOEOL%/*}" || return 1
  ln_git init -q || return 1
  ln_file "$dc" '' "$g" || return 1
  ln_noeol a || return 1
  ln_git add -A || return 1
  ln_git commit -q -m l0 || return 1
  LN_L0=$(ln_git rev-parse HEAD) || return 1
  ln_variant ok ln_file "    digest: sha256:$(hex64 d)" '' "$g" || return 1
  ln_variant noeol ln_noeol d || return 1
  ln_variant move ln_file '' "$dc" "$g" || return 1
  ln_variant delete ln_file '' '' "$g" || return 1
  ln_variant add ln_file "$dc" "  - digest: sha256:$(hex64 e)" "$g" || return 1
  ln_variant reshape ln_file "  - digest: sha256:$(hex64 f)" '' "$g" || return 1
  ln_variant plusplus ln_file "$dc" '' "$g"$'++ anything: goes\n' || return 1
  ln_variant minusminus ln_file "$dc" '' '' || return 1
}
ln_case() { # <케이스> <변형> <기대 exit> [단언...]
  local c=$1 v=$2 w=$3; shift 3
  run_case "$c" "$LN_REPO" "$w" "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$LN_L0" --env "VALIDATE_HEAD_SHA=${LN[$v]:-}" "$@"
}
LN_CASES=(author-only-inplace-ok author-only-inplace-noeol-ok author-only-inplace-move author-only-inplace-delete
  author-only-inplace-add author-only-inplace-reshape author-only-hunk-plusplus author-only-hunk-minusminus)
if any_selected "${LN_CASES[@]}"; then
  mkdir -p "$TMP"
  if ln_build 2>"$TMP/lines.log"; then
    HC=$(hex64 c)
    LN_OK="+[PASS] 6 AUTHOR — 봇 'jt-ci[bot]' PR: 변경 파일 1개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest 값의 제자리 교체"
    ln_case author-only-inplace-ok ok 0 "$LN_OK" '+결과(작성자 검사만 실행): PASS' '-[FAIL]'
    ln_case author-only-inplace-noeol-ok noeol 0 "$LN_OK" '+결과(작성자 검사만 실행): PASS' '-[FAIL]'
    ln_case author-only-inplace-move move 1 \
      "+[FAIL] 6 AUTHOR-line — ${IP_DEL}'    digest: sha256:$HC'" "+[FAIL] 6 AUTHOR-line — ${IP_ADD}'    digest: sha256:$HC'" \
      '-images[].digest 외 줄' '-[PASS] 6 AUTHOR'
    ln_case author-only-inplace-delete delete 1 \
      "+[FAIL] 6 AUTHOR-line — ${IP_DEL}'    digest: sha256:$HC'" "-$IP_ADD" '-images[].digest 외 줄' '-[PASS] 6 AUTHOR'
    ln_case author-only-inplace-add add 1 \
      "+[FAIL] 6 AUTHOR-line — ${IP_ADD}'  - digest: sha256:$(hex64 e)'" "-$IP_DEL" '-images[].digest 외 줄' '-[PASS] 6 AUTHOR'
    ln_case author-only-inplace-reshape reshape 1 \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: 제자리 교체만 허용 — digest 값 밖이 바뀐 교체 '    digest: sha256:$HC' → '  - digest: sha256:$(hex64 f)'" \
      "-$IP_DEL" "-$IP_ADD" '-images[].digest 외 줄' '-[PASS] 6 AUTHOR'
    ln_case author-only-hunk-plusplus plusplus 1 \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → '++ anything: goes'" \
      "+[FAIL] 6 AUTHOR-line — ${IP_ADD}'++ anything: goes'" '-[PASS] 6 AUTHOR'
    ln_case author-only-hunk-minusminus minusminus 1 \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → '-- guard: keep'" \
      "+[FAIL] 6 AUTHOR-line — ${IP_DEL}'-- guard: keep'" '-[PASS] 6 AUTHOR'
  else
    ln_why=$(tr -d '\r' < "$TMP/lines.log" | tail -n 3 | tr '\n' ' ')
    for c in "${LN_CASES[@]}"; do fail_case "$c" "임시 git 저장소를 만들 수 없음 — $ln_why"; done
  fi
else
  skip_cases "${LN_CASES[@]}"
fi

# --- 검사 6 · diff 옵션 고정(계약 판정 규칙 ④): 저장소 내용·설정이 출력 모양을 바꾸지 못한다 ------------------------------------------
#   submodule  base에 이미 'ignore = all' 인 .gitmodules + gitlink sub. head = digest 한 줄 + gitlink 변경. 옵션 없이는 git diff가
#              gitlink 변경을 통째로 숨긴다(파일 목록·diff 모두) → --ignore-submodules=none 이면 'sub'가 드러나 FAIL
#   textconv   .gitattributes '*.yaml diff=digestonly' + (러너 설정을 흉내 낸) diff.digestonly.textconv='grep digest'. head = namespace
#              변경 + digest 교체. textconv가 켜져 있으면 diff에 digest 줄만 남는다 → --no-textconv 이면 namespace 줄이 드러나 FAIL
FMT_SUB="$TMP/submodule"
FMT_TC="$TMP/textconv"
FMT_S0=''; FMT_S1=''; FMT_T0=''; FMT_T1=''
fmt_build() { # if 조건 안에서 부르므로 set -e가 꺼진다 — 단계마다 실패를 확인한다
  mkdir -p "$FMT_SUB/${MB_FILE%/*}" "$FMT_TC/${MB_FILE%/*}" || return 1
  tg "$FMT_SUB" init -q || return 1
  printf '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n\tignore = all\n' > "$FMT_SUB/.gitmodules" || return 1
  printf 'images:\n  - name: ghcr.io/example/demo\n    digest: sha256:%s\n' "$(hex64 a)" > "$FMT_SUB/$MB_FILE" || return 1
  tg "$FMT_SUB" add -A || return 1
  tg "$FMT_SUB" update-index --add --cacheinfo "160000,$(hex40 1),sub" || return 1
  tg "$FMT_SUB" commit -q -m s0 || return 1
  FMT_S0=$(tg "$FMT_SUB" rev-parse HEAD) || return 1
  printf 'images:\n  - name: ghcr.io/example/demo\n    digest: sha256:%s\n' "$(hex64 b)" > "$FMT_SUB/$MB_FILE" || return 1
  tg "$FMT_SUB" add "$MB_FILE" || return 1
  tg "$FMT_SUB" update-index --cacheinfo "160000,$(hex40 2),sub" || return 1
  tg "$FMT_SUB" commit -q -m s1 || return 1
  FMT_S1=$(tg "$FMT_SUB" rev-parse HEAD) || return 1
  tg "$FMT_TC" init -q || return 1
  printf '*.yaml diff=digestonly\n' > "$FMT_TC/.gitattributes" || return 1
  printf 'namespace: jt-dev\nimages:\n  - name: ghcr.io/example/demo\n    digest: sha256:%s\n' "$(hex64 a)" > "$FMT_TC/$MB_FILE" || return 1
  tg "$FMT_TC" add -A || return 1
  tg "$FMT_TC" commit -q -m t0 || return 1
  FMT_T0=$(tg "$FMT_TC" rev-parse HEAD) || return 1
  printf 'namespace: jt-prod\nimages:\n  - name: ghcr.io/example/demo\n    digest: sha256:%s\n' "$(hex64 b)" > "$FMT_TC/$MB_FILE" || return 1
  tg "$FMT_TC" commit -q -am t1 || return 1
  FMT_T1=$(tg "$FMT_TC" rev-parse HEAD) || return 1
}
FMT_CASES=(author-mergebase-submodule-ignore author-mergebase-no-textconv)
if any_selected "${FMT_CASES[@]}"; then
  mkdir -p "$TMP"
  if fmt_build 2>"$TMP/format.log"; then
    run_case author-mergebase-submodule-ignore "$FMT_SUB" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$FMT_S0" --env "VALIDATE_HEAD_SHA=$FMT_S1" \
      "+[FAIL] 6 AUTHOR-file — 봇 'jt-ci[bot]'의 변경 파일 'sub' 불허" "+[FAIL] 6 AUTHOR-file — 봇 diff: 파일 'sub' 불허" \
      '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
    run_case author-mergebase-no-textconv "$FMT_TC" 1 "${MB_ENV[@]}" --env "VALIDATE_BASE_SHA=$FMT_T0" --env "VALIDATE_HEAD_SHA=$FMT_T1" \
      --env 'GIT_CONFIG_COUNT=1' --env 'GIT_CONFIG_KEY_0=diff.digestonly.textconv' --env 'GIT_CONFIG_VALUE_0=grep digest' \
      "+[FAIL] 6 AUTHOR-line — 봇 diff: images[].digest 외 줄 변경 불허 → 'namespace: jt-prod'" \
      '+결과(작성자 검사만 실행): FAIL' '-[PASS] 6 AUTHOR'
  else
    fmt_why=$(tr -d '\r' < "$TMP/format.log" | tail -n 3 | tr '\n' ' ')
    for c in "${FMT_CASES[@]}"; do fail_case "$c" "임시 git 저장소를 만들 수 없음 — $fmt_why"; done
  fi
else
  skip_cases "${FMT_CASES[@]}"
fi

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
