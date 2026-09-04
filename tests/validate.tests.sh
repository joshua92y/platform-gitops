#!/usr/bin/env bash
# =============================================================================
# tests/validate.tests.sh — tests/validate.sh 자기검사 (T033)
#
# tests/fixtures/<case>/ 마다 validate.sh를 --root 로 돌려 기대 exit 코드와 메시지(있어야/없어야)를 단언한다.
#   - positive/            : 계약을 만족하는 최소 완전 트리 → exit 0
#   - 그 밖의 디렉터리      : 검사 항목별 부정 픽스처(각 항목이 실제로 FAIL 코드를 내는 최소 예시) → exit 1 + 코드
#   - author/*.diff        : 검사 6(봇 작성자) 입력 — positive 트리 위에서 환경변수로 넘긴다
# 실제 트리 검사(validate.sh 기본 실행)는 tests/ 를 제외하므로 픽스처가 실제 결과에 섞이지 않는다.
#
# 도구가 없으면 VALIDATE_SKIP_TOOLS=1로 내려가 실행한다(어떤 검사가 SKIP되는지 출력). yq(mikefarah)가 없으면
# 대부분의 단언이 성립할 수 없으므로 즉시 실패한다(fail-closed). VALIDATE_TESTS_REQUIRE_TOOLS=1 또는 CI=true 이면
# 도구 누락 시 SKIP 모드로 내려가지 않고 exit 1 (CI에서 조용히 불완전한 결과가 통과하지 않도록).
# 각 케이스는 env -u 로 작성자 관련 환경변수를 지우고 시작한다(CI의 GITHUB_EVENT_NAME 등이 새지 않도록).
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

# run_case <이름> <root> <기대 exit> [--env K=V]... [+있어야 할 문자열 | -있으면 안 되는 문자열]...
run_case() {
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
  '+[PASS] 6 AUTHOR' '+[PASS] 7.1 WAVE' '+[PASS] 7.2 WAVE-dir' '+결과: PASS' '-[FAIL]')
if command -v kustomize >/dev/null 2>&1 && command -v kubeconform >/dev/null 2>&1; then
  positive_asserts+=('+[PASS] 1 KUST' '+[PASS] 1b KUST-plain' '+ExternalSecret 22개(파일+렌더링)')
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
  '-helm values server.extraArgs'
run_case pol-limitrange "$FIX/pol-limitrange" 1 \
  "+[FAIL] 5.5 POL-limitrange — platform/policies/limitrange.yaml LimitRange/jt-dev/defaults[Container]: default.cpu=500m 금지" \
  "+LimitRange/jt-dev/defaults[Container]: max.cpu=2 금지"
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

# --- gitleaks: 대상 0개 = FAIL --------------------------------------------------
run_case gitleaks-empty "$FIX/gitleaks-empty" 1 \
  '+[FAIL] 8 LEAK-no-target — 스캔 대상 파일 0개'

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
outside_rc=0
bash "$VALIDATE" --root / >/dev/null 2>&1 || outside_rc=$?
N=$((N + 1))
if [[ $outside_rc == 2 ]]; then printf '[PASS] root-outside-repo-rejected\n'; else NF=$((NF + 1)); FAILED+=(root-outside-repo-rejected); printf '[FAIL] root-outside-repo-rejected (exit %s ≠ 2)\n' "$outside_rc"; fi

printf '\n== 자기검사 요약: %d 케이스, 실패 %d ==\n' "$N" "$NF"
if [[ $NF -gt 0 ]]; then
  printf '실패: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
