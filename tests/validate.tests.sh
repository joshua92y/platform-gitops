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
#                            git 밖 디렉터리(nogit), 도구 없는 PATH의 심 디렉터리, 검사 12.4·12.5의 임시 트리(helm-src-* — 이름이
#                            charts인 디렉터리는 .gitignore 대상이라 커밋되는 픽스처로 만들 수 없다. 원본은 fixtures/helm-src/tree/),
#                            검사 13의 저장소 루트 케이스(rbac-root-* — 임시 트리의 tests/에 validate.sh 사본을 넣어 그 트리를 저장소 루트로
#                            돌린다: 완전성 판정은 --root가 스크립트의 저장소 루트일 때만 돈다), 검사 12.4의 저장소 루트 케이스(helm-src-root-no-argocd
#                            — 같은 방식), 검사 11.3·11.4의 심볼릭 링크 케이스(fmt-dirsource-link — 링크는 커밋하지 않는다. 원본은 fixtures/fmt/link/.
#                            링크를 만들 수 없는 환경에서는 이유를 적은 [SKIP]으로 건너뜀에 센다 — CI · 판정용 실행에서는 실패), 검사 11.5의
#                            심볼릭 링크 케이스(fmt-symlink · fmt-symlink-nogit — 같은 방식. 원본은 fixtures/fmt/symlink/)와 인덱스 케이스의 임시
#                            git 저장소(fmt-symlink-index — 작업 트리에는 일반 파일 · 인덱스에만 모드 120000).
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
# TMP는 이 스크립트의 셸 변수다 — 환경에 TMP가 이미 내보내져 있으면(Windows) 위 대입이 자식 프로세스의 TMP까지 바꿔, Go 도구(kustomize의 helm
#   인플레이트)가 아직 없는 tests/.tmp에 임시 디렉터리를 만들려다 렌더가 실패한다(2026-09-30 실측 — rel-scoped의 helm 케이스). 내보내지 않는다
#   (Linux는 Go가 TMPDIR을 보므로 영향이 없었다 — 환경에 TMP가 없으면 이 줄은 아무것도 하지 않는다).
export -n TMP
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

# run_case <이름> <root> <기대 exit> [--env K=V]... [--arg <validate.sh 인자>]... [--script <경로>] [+있어야 할 문자열 | -있으면 안 되는 문자열]...
#   --arg 는 --root 뒤에 차례로 붙는다(예: --arg --author-id --arg 323873425)
#   --script 는 validate.sh 대신 돌릴 사본(검사 13의 저장소 루트 케이스 — 임시 트리의 tests/validate.sh. 기본은 이 디렉터리의 validate.sh)
run_case() {
  selected "$1" || return 0
  local name=$1 root=$2 want=$3; shift 3
  local -a envs=() args=() asserts=()
  local script=$VALIDATE
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) envs+=("$2"); shift 2 ;;
      --arg) args+=("$2"); shift 2 ;;
      --script) script=$2; shift 2 ;;
      *) asserts+=("$1"); shift ;;
    esac
  done
  local out rc=0 ok=1 a
  # 봇 목록(VALIDATE_BOT_AUTHORS·VALIDATE_BOT_IDS)도 지운다 — 작성자 단언은 스크립트 기본값을 전제로 한다.
  # 이벤트 발신자(PR_SENDER·PR_SENDER_ID)도 지운다 — CI 러너의 값이 새면 발신자 판정 케이스가 흔들린다
  out=$(env -u GITHUB_EVENT_NAME -u VALIDATE_REQUIRE_AUTHOR -u PR_AUTHOR -u PR_AUTHOR_ID -u PR_SENDER -u PR_SENDER_ID \
        -u CHANGED_FILES -u CHANGED_DIFF \
        -u VALIDATE_BASE_SHA -u VALIDATE_HEAD_SHA -u VALIDATE_ONLY_AUTHOR -u VALIDATE_BOT_AUTHORS -u VALIDATE_BOT_IDS \
        "${envs[@]}" bash "$script" --root "$root" "${args[@]}" 2>&1) || rc=$?
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
  # 4a IMG-entry(T047 G4c): overlays/dev · overlays/prod의 images 항목 각 1개(name + newName + digest)
  '+[PASS] 4a IMG-entry — kustomization images 2개 항목(kustomization 2개): 항목마다 name(문자열)·digest 있음 · 키 ⊆ {name, newName, digest}'
  '+[PASS] 5.1 POL-ns' '+[PASS] 5.2 POL-set' '+[PASS] 5.3 POL-egress' '+[PASS] 5.4 POL-port' '+[PASS] 5.5 POL-limitrange'
  '+[PASS] 5.6 POL-webhook-src'
  '+[PASS] 6 AUTHOR' '+[PASS] 7.1 WAVE' '+[PASS] 7.2 WAVE-dir' '+[PASS] 7.3 WAVE-secrets-base'
  '+[PASS] 7.4 APP-source — Application 24개(파일+렌더링) spec.source 키 = {path, repoURL, targetRevision}'
  '+[PASS] 9.1 CSS-set' '+[PASS] 9.2 CSS-auth' '+[PASS] 9.3 CSS-k8s' '+[PASS] 9.4 CSS-conditions'
  # 검사 11 · 12(T047): directory source 경로는 root가 읽는 clusters/oci-k3s/apps 하나(Application 23 = 앱 2 + 플랫폼 21) · helmCharts 없음
  '+[PASS] 11.1 FMT-list' '+[PASS] 11.2 FMT-appset'
  '+[PASS] 11.3 FMT-dirsource — directory source 경로 1개(clusters/oci-k3s/apps) — .json·.jsonnet·.libsonnet 파일·하위 디렉터리 없음 · Application source.path 24개 = directory source 1 · kustomization 23 · 트리에 없음 0'
  '+[PASS] 11.4 FMT-dirsource-kind — directory source 경로 1개의 YAML 파일 2개 · 문서 23개 모두 Application(argoproj.io/…) · 빈 문서 0개 건너뜀'
  # 11.5: 링크 0 — 항목 수는 단언하지 않는다(인덱스 항목 수는 픽스처가 커밋됐는지에 따라 로컬과 CI가 다르다)
  '+[PASS] 11.5 FMT-symlink — 심볼릭 링크 0개 — 작업 트리 항목 '
  '+[PASS] 12.1 HELM-repo' '+[PASS] 12.2 HELM-version' '+[PASS] 12.3 HELM-legacy'
  '+[PASS] 12.4 HELM-argocd — helmCharts를 쓰는 kustomization 0개 — 대상 없음' '+[PASS] 12.5 HELM-chartsdir'
  '+결과: PASS' '-[FAIL]')
if command -v kustomize >/dev/null 2>&1 && command -v kubeconform >/dev/null 2>&1; then
  # 5.6 PASS 줄의 소스 수는 kustomize 유무로 갈린다(SKIP 모드에서는 "렌더 0" — 한계 절 참조)
  # ES 수: `secrets/<ns>`의 ES는 파일 · 자기 디렉터리 렌더 · 배달자 렌더로 3번 세어진다 —
  # 배달자에 ns를 하나 더하면 +3이다(T045 G4에서 두 번째 ns를 더해 23 → 26).
  positive_asserts+=('+[PASS] 1 KUST' '+[PASS] 1b KUST-plain' '+ExternalSecret 26개(파일+렌더링)'
    '+webhook 정책을 담은 소스: 원본 1 · 렌더 1'
    # 검사 10(T046): 긍정 트리의 platform/reloader는 순수 매니페스트라 helm 없이 렌더된다(kustomize만 필요).
    '+[PASS] 10 REL — platform/reloader (rendered): ClusterRole·ClusterRoleBinding 0 · Deployment reloader/reloader args = ["--log-level=info","--namespaces=identity,jt-dev,jt-prod,reloader","--reload-strategy=annotations"] · kind {ServiceAccount 1 · Deployment 1 · Role 5 · RoleBinding 5}(합계 12) · Role·RoleBinding ns 집합 = {identity,jt-dev,jt-prod,reloader} · RoleBinding → 같은 ns의 Role · 주체 = ServiceAccount reloader/reloader · reloader-role 규칙 동일·와일드카드 없음 · Reloader 이미지 컨테이너 1개(containers.0 · command 없음)'
    # 검사 13(T047 G4b): 긍정 트리의 RBAC는 platform/reloader의 Role 5 · RoleBinding 5뿐이다(기준선 밖의 것 없음 · 부분 트리라 완전성은 보지 않는다)
    '+[PASS] 13 RBAC — 렌더 27개 합산(부분 트리 — 기준선 밖의 것만 본다) — Role 5 · ClusterRole 0 · 바인딩 5장(RoleBinding 5 · ClusterRoleBinding 0) · 주체 5개 모두 이름을 다 적은 ServiceAccount · 토큰 발급 규칙을 가진 역할 0개(없음) · 렌더되지 않은 ClusterRole을 가리키는 바인딩 0장(없음) · Role을 가리키는 RoleBinding 5장 모두 같은 ns의 렌더된 Role · 내장 역할 이름의 ClusterRole 0 · aggregationRule 0 · aggregate-to-* 라벨 ClusterRole 0개(없음) · Reloader 주체(ServiceAccount reloader/reloader) 바인딩은 platform/reloader 렌더에만 — 그 렌더 안 5장(장수·모양은 검사 10)')
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

# --- 4a IMG-entry: images 항목마다 name · digest(T047 G4c · 계약 §이미지·승격 「(T047) 항목마다 name과 digest」) ---------------------------
# 모든 트리가 부분 트리다 — exit 1은 무관한 FAIL로도 나므로 판정 근거가 아니다. 근거는 하위 코드의 `+[FAIL] 4a IMG-…` 단언, 그룹 PASS 줄이 없다는
# `-[PASS] 4a IMG-entry`, 그리고 그 트리의 결함이 다른 새 코드로 번지지 않는다는 `-[FAIL] 4a IMG-…`다. 기존 4a IMG-newTag의 줄(newTag · 형식 오류)은
# 그대로 나오고 새 코드는 그것을 다시 찍지 않는다 — 기존 줄이 나와야 하는 곳은 `+[FAIL] 4a IMG-newTag`로, 그룹이 서로 독립인 것은 mixed의
# `+[PASS] 4a IMG-newTag`로 짚는다. yq만 쓴다(helm·네트워크 불필요). "통과해야 하는 것"은 pass(항목 있음)와 none(대상 없음) 두 트리다.
IE='apps/demo/overlays/dev/kustomization.yaml images'
IE_ALL=('-[FAIL] 4a IMG-name' '-[FAIL] 4a IMG-digest' '-[FAIL] 4a IMG-keys' '-[FAIL] 4a IMG-shape')
ie_others() { # <이 트리가 거는 새 코드…(예: IMG-digest)> — 그 밖의 새 코드 FAIL이 없고 그룹 PASS 줄도 없다는 음성 단언 목록 → 전역 IE_NEG
  local a c keep
  IE_NEG=('-[PASS] 4a IMG-entry')
  for a in "${IE_ALL[@]}"; do
    keep=1
    for c in "$@"; do [[ $a == "-[FAIL] 4a $c" ]] && keep=0; done
    [[ $keep == 0 ]] || IE_NEG+=("$a")
  done
}
#   digest: 없음(digest 줄을 지운 모양) · "" · null · false · "-"(기존 추출이 '없음'과 같은 '-'로 읽던 값) · 따옴표 없는 숫자(형식 오류 —
#     기존 4a IMG-newTag가 찍고 IMG-digest는 다시 찍지 않는다). ""는 기존 코드도 형식 오류로 찍는다(기존 줄은 바꾸지 않는다)
ie_others IMG-digest
run_case img-entry-digest "$FIX/img-entry/digest" 1 \
  "+[FAIL] 4a IMG-digest — $IE #1 'ghcr.io/joshua92y/demo-a': digest 없음 — 이미지 고정이 풀린다" \
  "+[FAIL] 4a IMG-digest — $IE #2 'ghcr.io/joshua92y/demo-b': digest가 빈 값 — 이미지 고정이 풀린다" \
  "+[FAIL] 4a IMG-digest — $IE #3 'ghcr.io/joshua92y/demo-c': digest가 빈 값(null)" \
  "+[FAIL] 4a IMG-digest — $IE #4 'ghcr.io/joshua92y/demo-d': digest false(태그 !!bool) — 문자열 sha256:<64 hex>가 아니다" \
  "+[FAIL] 4a IMG-digest — $IE #5 'ghcr.io/joshua92y/demo-e': digest \"-\"(태그 !!str) — 문자열 sha256:<64 hex>가 아니다" \
  "+[FAIL] 4a IMG-newTag — apps/demo/overlays/dev/kustomization.yaml images[ghcr.io/joshua92y/demo-b]: digest '' 형식 오류" \
  "+[FAIL] 4a IMG-newTag — apps/demo/overlays/dev/kustomization.yaml images[ghcr.io/joshua92y/demo-f]: digest '12345' 형식 오류" \
  "-[FAIL] 4a IMG-digest — $IE #6" \
  "${IE_NEG[@]}"
#   name: 없음 · "" · 정수 · 목록. 문자열 "-"(#5)는 통과 — 기존 추출은 name이 없을 때 '-'를 채웠다("없음"과 "값이 '-'"를 구분하는지 본다)
ie_others IMG-name
run_case img-entry-name "$FIX/img-entry/name" 1 \
  "+[FAIL] 4a IMG-name — $IE #1: name 없음" \
  "+[FAIL] 4a IMG-name — $IE #2: name이 빈 값" \
  "+[FAIL] 4a IMG-name — $IE #3: name이 문자열이 아니다(태그 !!int)" \
  "+[FAIL] 4a IMG-name — $IE #4: name이 문자열이 아니다(태그 !!seq)" \
  "-[FAIL] 4a IMG-name — $IE #5" \
  "${IE_NEG[@]}"
#   keys: tagSuffix · 오타 digset(digest도 없어진다 — IMG-digest 함께) · newTag: ~(기존 코드가 '없음'으로 읽어 찍지 않는 newTag) · digest 키 중복 ·
#     newTag: v1(기존 4a IMG-newTag가 찍는다 — IMG-keys는 다시 찍지 않는다). 중복의 뒤 값은 형식이 맞다 — IMG-digest는 #2 말고 걸리지 않는다
ie_others IMG-keys IMG-digest
run_case img-entry-keys "$FIX/img-entry/keys" 1 \
  "+[FAIL] 4a IMG-keys — $IE #1 'ghcr.io/joshua92y/demo-a': 키 [\"tagSuffix\"] — 항목의 키는 {name, newName, digest}만" \
  "+[FAIL] 4a IMG-keys — $IE #2 'ghcr.io/joshua92y/demo-b': 키 [\"digset\"]" \
  "+[FAIL] 4a IMG-digest — $IE #2 'ghcr.io/joshua92y/demo-b': digest 없음" \
  "+[FAIL] 4a IMG-keys — $IE #3 'ghcr.io/joshua92y/demo-c': 키 [\"newTag\"]" \
  "+[FAIL] 4a IMG-keys — $IE #4 'ghcr.io/joshua92y/demo-d': 키 중복 [\"digest\"]" \
  "+[FAIL] 4a IMG-newTag — apps/demo/overlays/dev/kustomization.yaml images[ghcr.io/joshua92y/demo-e]: newTag='v1' 금지" \
  "-[FAIL] 4a IMG-keys — $IE #5" \
  "-[FAIL] 4a IMG-digest — $IE #1" "-[FAIL] 4a IMG-digest — $IE #3" "-[FAIL] 4a IMG-digest — $IE #4" "-[FAIL] 4a IMG-digest — $IE #5" \
  "${IE_NEG[@]}"
#   shape(fail-closed): images가 맵 · images가 문자열 · 문자열 항목과 별칭 항목(앵커를 단 맵 #2는 걸리지 않는다) · 문서가 문자열 · 문서가 목록(yq 실패)
IS='apps/shape-'
ie_others IMG-shape
run_case img-entry-shape "$FIX/img-entry/shape" 1 \
  "+[FAIL] 4a IMG-shape — ${IS}map/overlays/dev/kustomization.yaml: images가 목록이 아니다(map · 태그 !!map)" \
  "+[FAIL] 4a IMG-shape — ${IS}scalar/overlays/dev/kustomization.yaml: images가 목록이 아니다(scalar · 태그 !!str)" \
  "+[FAIL] 4a IMG-shape — ${IS}entry/overlays/dev/kustomization.yaml images #1: 항목이 맵이 아니다(scalar · 태그 !!str)" \
  "+[FAIL] 4a IMG-shape — ${IS}entry/overlays/dev/kustomization.yaml images #3: 항목이 맵이 아니다(alias · 태그 -)" \
  "+[FAIL] 4a IMG-shape — ${IS}strdoc/overlays/dev/kustomization.yaml: 문서가 맵이 아니다(scalar · 태그 !!str)" \
  "+[FAIL] 4a IMG-shape — ${IS}seqdoc/overlays/dev/kustomization.yaml: yq 추출 실패" \
  "-${IS}entry/overlays/dev/kustomization.yaml images #2" \
  "${IE_NEG[@]}"
#   skipped: 기존 4a IMG-newTag가 통째로 건너뛰는 항목(name: "") — newTag와 틀린 digest가 있어도 기존 코드는 아무것도 찍지 않는다(음성 단언으로 고정).
#     새 판정이 name · digest(형식 — 기존 코드가 보지 않았으므로 여기서 찍는다) · 키(newTag — 같은 이유)를 모두 찍는다
ie_others IMG-name IMG-digest IMG-keys
run_case img-entry-skipped "$FIX/img-entry/skipped" 1 \
  "+[FAIL] 4a IMG-name — $IE #1: name이 빈 값" \
  "+[FAIL] 4a IMG-digest — $IE #1: digest \"sha256:abc\"(태그 !!str) — 문자열 sha256:<64 hex>가 아니다" \
  "+[FAIL] 4a IMG-keys — $IE #1: 키 [\"newTag\"]" \
  '-[FAIL] 4a IMG-newTag' '+[PASS] 4a IMG-newTag — kustomization images 0개 항목 newTag 없음' \
  "${IE_NEG[@]}"
#   mixed: 정상 #1·#3 사이의 digest 없는 #2 — #2만 걸리고 그룹 PASS 줄이 없다. 기존 4a IMG-newTag 그룹은 그대로 PASS다(newTag 없음)
ie_others IMG-digest
run_case img-entry-mixed "$FIX/img-entry/mixed" 1 \
  "+[FAIL] 4a IMG-digest — $IE #2 'ghcr.io/joshua92y/demo-b': digest 없음" \
  "-$IE #1" "-$IE #3" \
  '+[PASS] 4a IMG-newTag — kustomization images 3개 항목 newTag 없음' \
  "${IE_NEG[@]}"
#   pass(경계): name + digest · name + newName + digest(키 순서 무관) — 그룹 PASS 줄을 개수까지 단언한다
run_case img-entry-pass "$FIX/img-entry/pass" 1 \
  '+[PASS] 4a IMG-entry — kustomization images 3개 항목(kustomization 2개): 항목마다 name(문자열)·digest 있음 · 키 ⊆ {name, newName, digest}' \
  '+[PASS] 4a IMG-newTag — kustomization images 3개 항목 newTag 없음' \
  '-[FAIL] 4a'
#   none(경계): images: 뒤가 빈 값(null) · images: [] · images 키 없음 · 끝의 `---` 뒤 빈 문서 — 항목 0개 = 대상 없음(null은 없는 것과 같이 읽는다 ·
#     빈 문서는 "맵이 아닌 문서"가 아니다)
run_case img-entry-none "$FIX/img-entry/none" 1 \
  '+[PASS] 4a IMG-entry — kustomization images 항목 0개 — 대상 없음' \
  '+[PASS] 4a IMG-newTag — kustomization images 0개 항목 newTag 없음' \
  '-[FAIL] 4a'

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
#   (A1 후속 · 2026-09-30) platform/kafka가 secrets/data를 YAML 별칭 항목(`*s`)으로 끌어온다 — kustomize는 풀어서 빌드하는데 base 추출은 문자열 태그
#     항목만 보아 건너뛰었다(namePrefix가 렌더의 ES 이름을 바꿔 이름으로 맞추는 ⓑ도 비켜 간다 — ⓐ의 고유 줄로 짚는다)
run_case secrets-base-owner "$FIX/secrets-base-owner" 1 \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/cert-manager-issuers/kustomization.yaml: base '../../secrets/cert-manager'(→ secrets/cert-manager) — secrets/ 아래를 base로 가질 수 있는 kustomization은 platform/secrets/kustomization.yaml 하나뿐이다" \
  "+[FAIL] 7.3 WAVE-secrets-base — platform/kafka/kustomization.yaml: base '../../secrets/data'(→ secrets/data) — secrets/ 아래를 base로 가질 수 있는 kustomization은 platform/secrets/kustomization.yaml 하나뿐이다" \
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

# --- 검사 11: 형식별 정책(T047 · 계약 §validate.yml 4 「(T047) 형식별 정책」) ---------------------------------------------
# 모든 트리가 부분 트리다 — exit 1은 5.x 등 무관한 FAIL로도 나므로 판정 근거가 아니다. 근거는 하위 코드의 `+[FAIL]` 단언과
# `-[PASS] <코드>` 음성 단언이다. "통과해야 하는 것"(경계)은 fmt/pass 한 트리에 모아 11.1–11.4의 PASS 줄(개수 포함)을 단언한다.
# 렌더에서만 보이는 결함(패치가 더한 items · List가 풀린 ApplicationSet)의 단언은 kustomize가 있을 때만 건다.
fmt_list_r=(); fmt_appset_r=()
if command -v kustomize >/dev/null 2>&1; then
  fmt_list_r=("+[FAIL] 11.1 FMT-list — platform/cloudflared (rendered) 문서 #1 kind 'ConfigMap': 목록 객체 금지(최상위 items 목록")
  fmt_appset_r=("+[FAIL] 11.2 FMT-appset — platform/argocd (rendered) 문서 #1 ApplicationSet/rendered-apps(apiVersion 'argoproj.io/v1alpha1'): ApplicationSet 금지")
fi
#   list: directory source 경로 안의 `kind: List`로 감싼 Application(11.4도 함께 건다) · ConfigMapList + items · items 없는 `kind: List` ·
#     (보강) kind와 무관한 최상위 items 목록 — 파일(ConfigMap)과, 원본은 멀쩡하고 패치가 렌더에서만 더한 것 ·
#     (A1 · 2026-09-30 G4 리뷰) YAML 별칭 `items: *seq` — 파일 쪽 ConfigMap과, directory source 경로의 platform-monitoring(리뷰어의 재현 그대로 —
#     2 · 7.1 · 7.4를 모두 만족하므로 그 검사들의 FAIL 줄이 없고 11.1 · 11.4만 건다) · 병합 키의 우선순위(명시한 items: null 뒤의 병합이 이긴다 —
#     yq의 병합 기본값이 Argo의 디코더와 같다는 것을 고정한다)
run_case fmt-list "$FIX/fmt/list" 1 \
  "+[FAIL] 11.1 FMT-list — clusters/oci-k3s/apps/wrapped-list.yaml 문서 #1 kind 'List': 목록 객체 금지(kind: List — items 유무와 무관)" \
  "+[FAIL] 11.1 FMT-list — misc/configmaplist.yaml 문서 #1 kind 'ConfigMapList': 목록 객체 금지(<Kind>List + 최상위 items 목록)" \
  "+[FAIL] 11.1 FMT-list — misc/list-no-items.yaml 문서 #1 kind 'List': 목록 객체 금지(kind: List — items 유무와 무관)" \
  "+[FAIL] 11.1 FMT-list — misc/items-carrier.yaml 문서 #1 kind 'ConfigMap': 목록 객체 금지(최상위 items 목록" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/wrapped-list.yaml 문서 #1 kind 'List'" \
  "+[FAIL] 11.1 FMT-list — misc/alias-carrier.yaml 문서 #1 kind 'ConfigMap': 목록 객체 금지(최상위 items 목록" \
  "+[FAIL] 11.1 FMT-list — clusters/oci-k3s/apps/platform-monitoring.yaml 문서 #1 kind 'Application': 목록 객체 금지(최상위 items 목록" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/platform-monitoring.yaml 문서 #1 Application/platform-monitoring: 최상위 items 목록 금지(보강)" \
  "+[FAIL] 11.1 FMT-list — misc/merge-order-carrier.yaml 문서 #1 kind 'ConfigMap': 목록 객체 금지(최상위 items 목록" \
  '-clusters/oci-k3s/apps/platform-monitoring.yaml Application/platform-monitoring' '-[FAIL] 11.0' \
  "${fmt_list_r[@]}" '-[FAIL] 11.1 FMT-list — platform/cloudflared/carrier.yaml' '-[PASS] 11.1 FMT-list' '-[FAIL] 11.2' '-[FAIL] 11.3'
#   appset: 파일의 ApplicationSet · 렌더에만 나타나는 ApplicationSet(파일은 ApplicationSetList — 그 목록 객체는 11.1이 건다)
run_case fmt-appset "$FIX/fmt/appset" 1 \
  "+[FAIL] 11.2 FMT-appset — misc/appset.yaml 문서 #1 ApplicationSet/generated-apps(apiVersion 'argoproj.io/v1alpha1'): ApplicationSet 금지" \
  "+[FAIL] 11.1 FMT-list — platform/argocd/appset-list.yaml 문서 #1 kind 'ApplicationSetList'" \
  "${fmt_appset_r[@]}" '-[FAIL] 11.2 FMT-appset — platform/argocd/appset-list.yaml' '-[PASS] 11.2 FMT-appset'
#   dirsource: directory source 경로의 .json · .jsonnet · .libsonnet · 하위 디렉터리 + 위치를 판정할 수 없는 source.path(절대 · 저장소 밖)
run_case fmt-dirsource "$FIX/fmt/dirsource" 1 \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/platform-apps.yaml Application/platform-vault: spec.source.path '/srv/platform/vault' — 절대 경로 금지" \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/platform-apps.yaml Application/platform-dragonfly: spec.source.path '../outside/platform/dragonfly' — 저장소 밖으로 나가는 경로" \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/extra.json: directory source 경로 clusters/oci-k3s/apps(kustomization 없음 — Argo가 디렉터리째 읽는다)에 .json 파일 금지" \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/extra.jsonnet: directory source 경로 clusters/oci-k3s/apps(kustomization 없음 — Argo가 디렉터리째 읽는다)에 .jsonnet 파일 금지" \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/lib.libsonnet: directory source 경로 clusters/oci-k3s/apps(kustomization 없음 — Argo가 디렉터리째 읽는다)에 .libsonnet 파일 금지" \
  "+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/nested/: directory source 경로 clusters/oci-k3s/apps의 하위 디렉터리 금지" \
  '-[PASS] 11.3 FMT-dirsource' '-[FAIL] 11.1' '-[FAIL] 11.2' '-[FAIL] 11.4'
#   dirsource-kind: Role · 둘째 문서의 ClusterRoleBinding(첫 문서 Application은 걸리지 않는다) · apiVersion이 다른 Application ·
#     kind 없는 문서 · (보강) 최상위 items 목록을 가진 Application. kustomization이 있는 경로(platform/)는 보지 않는다 ·
#     (A1 후속) 병합 키(`<<: *m`)로 들인 items 목록 — has()는 병합으로 들어온 키를 보지 못했다 ·
#     별칭으로 적은 kind(`kind: *k`)의 multi-source Application — 11.4는 풀어서 Application으로 받아들이고, 같은 파일을 보는 7.4가 풀어서 건다
#     (11.4만 풀면 `select(.kind == "Application")`이 별칭을 보지 못하는 2 · 7.x를 이 문서가 통째로 지난다 — 회귀를 막는 단언)
run_case fmt-dirsource-kind "$FIX/fmt/dirsource-kind" 1 \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/role.yaml 문서 #1 kind 'Role'(apiVersion 'rbac.authorization.k8s.io/v1'): directory source 경로에는 Application(argoproj.io/…)만" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/app-then-crb.yaml 문서 #2 kind 'ClusterRoleBinding'(apiVersion 'rbac.authorization.k8s.io/v1')" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/not-argo-app.yaml 문서 #1 kind 'Application'(apiVersion 'example.com/v1')" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/no-kind.yaml 문서 #1: kind 없음" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/items-app.yaml 문서 #1 Application/platform-dragonfly: 최상위 items 목록 금지(보강)" \
  "+[FAIL] 11.1 FMT-list — clusters/oci-k3s/apps/items-app.yaml 문서 #1 kind 'Application': 목록 객체 금지(최상위 items 목록" \
  "+[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/merge-items-app.yaml 문서 #1 Application/platform-kafka: 최상위 items 목록 금지(보강)" \
  "+[FAIL] 11.1 FMT-list — clusters/oci-k3s/apps/merge-items-app.yaml 문서 #1 kind 'Application': 목록 객체 금지(최상위 items 목록" \
  "+[FAIL] 7.4 APP-source-multi — clusters/oci-k3s/apps/alias-kind-app.yaml Application/platform-openfga: spec.sources(multi-source) 금지" \
  '-[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/alias-kind-app.yaml' '-[FAIL] 11.0' \
  '-[FAIL] 11.4 FMT-dirsource-kind — clusters/oci-k3s/apps/app-then-crb.yaml 문서 #1' '-[FAIL] 11.4 FMT-dirsource-kind — platform/' \
  '-[PASS] 11.4 FMT-dirsource-kind' '-[FAIL] 11.3'
#   pass(경계): README.md · kustomization 경로의 .json·Role · 트리에 없는 경로 · 빈 문서가 섞인 Application 파일 ·
#     items 없는 <Kind>List · items가 맵인 <Kind>List · argoproj.io가 아닌 ApplicationSet — 11.x의 FAIL이 하나도 없어야 한다
run_case fmt-pass "$FIX/fmt/pass" 1 \
  '+[PASS] 11.1 FMT-list — 목록 객체(kind: List · 최상위 items 목록) 없음' \
  '+[PASS] 11.2 FMT-appset — ApplicationSet(argoproj.io/…) 없음' \
  '+[PASS] 11.3 FMT-dirsource — directory source 경로 1개(clusters/oci-k3s/apps) — .json·.jsonnet·.libsonnet 파일·하위 디렉터리 없음 · Application source.path 3개 = directory source 1 · kustomization 1 · 트리에 없음 1' \
  '+[PASS] 11.4 FMT-dirsource-kind — directory source 경로 1개의 YAML 파일 1개 · 문서 2개 모두 Application(argoproj.io/…) · 빈 문서 2개 건너뜀' \
  '+[PASS] 11.5 FMT-symlink — 심볼릭 링크 0개 — 작업 트리 항목 ' \
  '-[FAIL] 11.'
#   alias-unresolvable(11.0 fail-closed): 맵이 아닌 값(문자열 앵커)을 가리키는 병합 키 — 파싱은 되지만 explode(.)가 멈춘다. 풀지 못한 문서는
#     목록 객체인지 판정할 수 없어 11.0이 걸고 11.1 PASS 줄이 없다. 같은 문서를 풀어 읽는 다른 식도 조용히 건너뛰지 않는다(fail-closed) —
#     misc/의 파일은 2 · 7.1(YQ_APP) · 7.4(YQ_APP_SRC) · 11.3(YQ_APP_PATHS)의 "yq 추출 실패", platform/kafka의 kustomization은 7.3 ⓐ(YQ_KUST_BASES)와
#     12.1(YQ_HELM_SCAN), platform/dragonfly의 generators:가 부르는 파일은 12.3(YQ_LEGACY_GEN). 이 줄들은 식마다 explode(.)가 있다는 것도 짚는다
#     (풀지 않는 식은 이 문서들을 오류 없이 읽고 지나간다 — 2026-09-30 G4 수정 전 실측)
run_case fmt-alias-unresolvable "$FIX/fmt/alias-unresolvable" 1 \
  '+[FAIL] 11.0 FMT-alias — misc/unresolvable-merge.yaml: yq로 문서를 풀어 읽지 못했다' \
  '+[FAIL] 11.0 FMT-alias — platform/kafka/kustomization.yaml: yq로 문서를 풀어 읽지 못했다' \
  '+[FAIL] 2 APP-SSA — yq 추출 실패: misc/unresolvable-merge.yaml' \
  '+[FAIL] 7.1 WAVE — yq 추출 실패: misc/unresolvable-merge.yaml' \
  '+[FAIL] 7.4 APP-source — yq 추출 실패: misc/unresolvable-merge.yaml' \
  '+[FAIL] 11.3 FMT-dirsource — yq 추출 실패: misc/unresolvable-merge.yaml' \
  '+[FAIL] 7.3 WAVE-secrets-base — platform/kafka/kustomization.yaml: base 항목(resources·bases·components)을 yq로 풀어 읽지 못했다' \
  '+[FAIL] 12.1 HELM-repo — platform/kafka/kustomization.yaml: yq로 읽지 못했다 — 차트 출처를 판정할 수 없다' \
  "+[FAIL] 12.3 HELM-legacy — platform/dragonfly/kustomization.yaml: generators·transformers 항목 'unresolvable-gen.yaml'(→ platform/dragonfly/unresolvable-gen.yaml)를 yq로 풀어 읽지 못했다" \
  '-[PASS] 11.1 FMT-list' '-[FAIL] 11.1' '-[FAIL] 11.4'

# --- 검사 11.3 · 11.4 · 심볼릭 링크(A2 · 계약 형식별 정책 「심볼릭 링크」 행 — 그중 directory source 경로 바로 아래) — 임시 트리(tests/.tmp) ---------
# 링크는 커밋되는 픽스처로 두지 않는다(체크아웃 설정 core.symlinks에 따라 일반 파일로 풀릴 수 있다). 원본 fixtures/fmt/link/를 tests/.tmp/로 복사하고
# directory source 경로(clusters/oci-k3s/apps)에 링크 셋 — 파일(→ 열거 밖 payload/evil-app.txt의 Application: 다른 리비전 · kustomize 패치) ·
# 디렉터리(→ payload/) · 대상 없음 — 을 만든다. 11.3이 셋 다 "심볼릭 링크 금지"로 걸고(디렉터리 링크를 "하위 디렉터리"로 읽지 않는다), 11.4는 링크를
# 따라가지 않으므로 일반 파일 1개만 본다(PASS 줄의 개수로 짚는다). 같은 링크를 트리 어디든의 판정(11.5)도 건다 — 코드가 달라 두 줄씩 나온다
# (트리 어디든의 링크 케이스는 아래 「검사 11.5」 — 임시 git 저장소 도우미 tg 뒤에 둔다). Git Bash는 MSYS=winsymlinks:nativestrict일 때만 진짜 링크를 만든다(아니면 조용히
# 복사한다) — 만든 뒤 [[ -L ]]로 확인하고, 링크를 만들 수 없는 환경(권한 없는 Windows 등)에서는 준비 실패가 아니라 이유를 적은 [SKIP]이다(건너뜀으로
# 센다). CI · 판정용 실행(CI=true · VALIDATE_TESTS_REQUIRE_TOOLS=1)에서는 SKIP하지 않고 실패한다 — 러너(Linux)는 링크를 만든다.
FL_ROOT="$TMP/fmt-dirsource-link"
FL_WHY=''
fl_tree() { # → 0 준비됨 · 1 준비 실패 · 2 링크를 만들 수 없는 환경(FL_WHY에 이유)
  local a="$FL_ROOT/clusters/oci-k3s/apps" l
  mkdir -p "$FL_ROOT" || return 1
  cp -R "$FIX/fmt/link/." "$FL_ROOT/" || return 1
  if ! ( cd "$a" && export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" \
         && ln -s ../../../payload/evil-app.txt evil.yaml && ln -s ../../../payload linked-dir \
         && ln -s ../../../payload/missing.yaml broken.yaml ); then
    FL_WHY='ln -s 실패(Windows는 개발자 모드나 관리자 권한이 있어야 진짜 링크를 만든다)'; return 2
  fi
  for l in evil.yaml linked-dir broken.yaml; do
    [[ -L "$a/$l" ]] || { FL_WHY="ln -s가 링크가 아닌 것을 만들었다($l)"; return 2; }
  done
}
if any_selected fmt-dirsource-link; then
  mkdir -p "$TMP"
  fl_rc=0; fl_tree 2>>"$TMP/fmt-link.log" || fl_rc=$?
  FL='+[FAIL] 11.3 FMT-dirsource — clusters/oci-k3s/apps/'
  FL_MSG=': directory source 경로 clusters/oci-k3s/apps의 심볼릭 링크 금지'
  if [[ $fl_rc == 0 ]]; then
    run_case fmt-dirsource-link "$FL_ROOT" 1 \
      "${FL}evil.yaml${FL_MSG}" "${FL}linked-dir${FL_MSG}" "${FL}broken.yaml${FL_MSG}" \
      '-하위 디렉터리 금지' '-[PASS] 11.3 FMT-dirsource' \
      "+[FAIL] 11.5 FMT-symlink — clusters/oci-k3s/apps/evil.yaml: 심볼릭 링크 금지(→ '../../../payload/evil-app.txt')" \
      "+[FAIL] 11.5 FMT-symlink — clusters/oci-k3s/apps/linked-dir: 심볼릭 링크 금지(→ '../../../payload')" \
      "+[FAIL] 11.5 FMT-symlink — clusters/oci-k3s/apps/broken.yaml: 심볼릭 링크 금지(→ '../../../payload/missing.yaml' · 대상 없음)" \
      '-[PASS] 11.5 FMT-symlink' \
      '+[PASS] 11.4 FMT-dirsource-kind — directory source 경로 1개의 YAML 파일 1개 · 문서 1개 모두 Application(argoproj.io/…) · 빈 문서 0개 건너뜀' \
      '-[FAIL] 11.4' '-[FAIL] 11.1' '-[FAIL] 11.0'
  elif [[ $fl_rc == 2 && ${VALIDATE_TESTS_REQUIRE_TOOLS:-0} != 1 && ${CI:-} != true ]]; then
    NSKIP=$((NSKIP + 1))
    printf '[SKIP] fmt-dirsource-link — 이 환경에서 심볼릭 링크를 만들 수 없다: %s — 11.3(링크 금지) · 11.4(링크를 따라가지 않음)는 이번 실행에서 확인되지 않았다(CI 러너는 돌린다)\n' "$FL_WHY"
  else
    fail_case fmt-dirsource-link "임시 트리를 만들 수 없음 — ${FL_WHY:-$(tr -d '\r' < "$TMP/fmt-link.log" | tail -n 3 | tr '\n' ' ')}"
  fi
else
  skip_cases fmt-dirsource-link
fi

# --- 검사 12: 차트 출처(T047 · 계약 §validate.yml 4 「(T047) 차트 저장소 허용 목록」·「charts/」·「--enable-helm」) ---------------
# 12.1–12.3은 kustomization **파일**을 검사 1보다 먼저 읽는다 — 걸린 kustomization(과 그것을 base로 끌어오는 kustomization)은 검사 1이
# 렌더하지 않으므로 아래 네 트리는 helm·네트워크 없이 돈다(허용하지 않은 저장소에서 차트를 받아 오지 않는다). 렌더를 건너뛴 줄(1 KUST)은
# 검사 1이 도는 경우(kustomize 있음)에만 찍히므로 그 단언은 kustomize가 있을 때만 건다.
HS_SKIP='kustomize build 건너뜀: '
hs_repo_k=(); hs_version_k=(); hs_legacy_k=(); hs_block_k=()
if command -v kustomize >/dev/null 2>&1; then
  hs_repo_k=("+[FAIL] 1 KUST — ${HS_SKIP}platform/cert-manager — 차트 출처 판정(12.1)에 걸렸다" '-kustomize build 실패: platform/cert-manager')
  hs_version_k=("+[FAIL] 1 KUST — ${HS_SKIP}platform/external-secrets — 차트 출처 판정(12.2)에 걸렸다"
    "+[FAIL] 1 KUST — ${HS_SKIP}platform/vault — 차트 출처 판정(12.2)에 걸렸다")
  hs_legacy_k=("+[FAIL] 1 KUST — ${HS_SKIP}platform/vault — 차트 출처 판정(12.3)에 걸렸다"
    "+[FAIL] 1 KUST — ${HS_SKIP}platform/cert-manager — 차트 출처 판정(12.3)에 걸렸다"
    "+[FAIL] 1 KUST — ${HS_SKIP}platform/external-secrets — 차트 출처 판정(12.3)에 걸렸다")
  hs_block_k=("+[FAIL] 1 KUST — ${HS_SKIP}platform/cert-manager — 차트 출처 판정(base tests/vendored-base)에 걸렸다")
fi
#   repo: #1 목록 밖 저장소 · #2 이름은 맞고 저장소가 다름 · #3 저장소는 맞고 이름이 다름 · #4 끝의 '/' · #5 repo 없음 · #6 name 없음 ·
#     #7 허용 쌍(걸리지 않는다). bootstrap/argocd가 없는 부분 트리라 12.4는 대상 없음이다
HR='platform/cert-manager/kustomization.yaml helmCharts'
run_case helm-src-repo "$FIX/helm-src/repo" 1 \
  "+[FAIL] 12.1 HELM-repo — $HR #1 'mystery-chart': repo 'https://charts.example.invalid' — (이름, 저장소) 쌍이 허용 목록에 없다" \
  "+[FAIL] 12.1 HELM-repo — $HR #2 'cert-manager': repo 'https://charts.jetstack.io' ≠ 허용 목록의 'oci://quay.io/jetstack/charts'" \
  "+[FAIL] 12.1 HELM-repo — $HR #3 'cert-manager-csi-driver': repo 'oci://quay.io/jetstack/charts' — (이름, 저장소) 쌍이 허용 목록에 없다" \
  "+[FAIL] 12.1 HELM-repo — $HR #4 'cert-manager': repo 'oci://quay.io/jetstack/charts/' ≠ 허용 목록의 'oci://quay.io/jetstack/charts'" \
  "+[FAIL] 12.1 HELM-repo — $HR #5 'cert-manager': repo 없음" \
  "+[FAIL] 12.1 HELM-repo — $HR #6: name 없음" \
  '+[PASS] 12.4 HELM-argocd — bootstrap/argocd 없음 — 부분 트리(픽스처)라 대상 없음(helmCharts를 쓰는 kustomization 1개)' \
  "-$HR #7" '-[PASS] 12.1 HELM-repo' '-[FAIL] 12.2' '-[FAIL] 12.3' "${hs_repo_k[@]}"
#   version: version 없음 · 빈 문자열(둘 다 허용 쌍 — 12.1은 걸리지 않는다)
run_case helm-src-version "$FIX/helm-src/version" 1 \
  "+[FAIL] 12.2 HELM-version — platform/external-secrets/kustomization.yaml helmCharts #1 'external-secrets': version 없음" \
  "+[FAIL] 12.2 HELM-version — platform/vault/kustomization.yaml helmCharts #1 'vault': version이 빈 값" \
  '+[PASS] 12.1 HELM-repo' '-[PASS] 12.2 HELM-version' '-[FAIL] 12.1' '-[FAIL] 12.3' "${hs_version_k[@]}"
#   legacy: 최상위 helmGlobals · 최상위 helmChartInflationGenerator · generators:가 부르는 kind: HelmChartInflationGenerator 파일
#     (그 kustomization의 helmCharts는 허용 쌍이지만 --enable-helm 빌드가 레거시 생성기를 돌리므로 렌더하지 않는다) ·
#     (A3 · 2026-09-30 G4 리뷰) 같은 생성기를 `kind: List`로 감싼 파일 — 최상위 kind만 보던 판정은 지나갔다
run_case helm-src-legacy "$FIX/helm-src/legacy" 1 \
  "+[FAIL] 12.3 HELM-legacy — platform/vault/kustomization.yaml: 최상위 키 'helmGlobals' 금지" \
  "+[FAIL] 12.3 HELM-legacy — platform/cert-manager/kustomization.yaml: 최상위 키 'helmChartInflationGenerator' 금지" \
  "+[FAIL] 12.3 HELM-legacy — platform/external-secrets/kustomization.yaml: generators·transformers 항목 'legacy-inflator.yaml'(→ platform/external-secrets/legacy-inflator.yaml)가 kind: HelmChartInflationGenerator" \
  "+[FAIL] 12.3 HELM-legacy — platform/external-secrets/kustomization.yaml: generators·transformers 항목 'wrapped-inflator.yaml'(→ platform/external-secrets/wrapped-inflator.yaml)가 kind: HelmChartInflationGenerator" \
  "+[FAIL] 12.3 HELM-legacy — platform/external-secrets/legacy-inflator.yaml 문서 #1 kind 'HelmChartInflationGenerator': 레거시 생성기 설정 금지" \
  '+[PASS] 12.1 HELM-repo' '+[PASS] 12.2 HELM-version' '-[PASS] 12.3 HELM-legacy' "${hs_legacy_k[@]}"
#   block(보강): 허용 쌍만 쓰는 kustomization이 파일 열거 밖(--root의 tests/)의 kustomization을 base로 끌어오고, 그 base가 목록 밖 저장소를
#     쓴다 — 12.1은 base로 끌려온 kustomization까지 보고, 끌어온 쪽도 렌더하지 않는다(--enable-helm 빌드가 base의 차트까지 받는다) ·
#     (A1 후속) platform/vault가 resources 항목을 YAML 별칭으로 적어 tests/vendored-alias를 끌어온다 — kustomize는 별칭을 풀어 빌드하는데,
#     문자열 태그 항목만 따라가던 사전 판정은 건너뛰었다(허용 목록 밖 차트를 검사 1이 받으러 갔다)
if command -v kustomize >/dev/null 2>&1; then
  hs_block_k+=("+[FAIL] 1 KUST — ${HS_SKIP}platform/vault — 차트 출처 판정(base tests/vendored-alias)에 걸렸다" '-kustomize build 실패: platform/vault')
fi
run_case helm-src-block "$FIX/helm-src/block" 1 \
  "+[FAIL] 12.1 HELM-repo — tests/vendored-base/kustomization.yaml helmCharts #1 'mystery-chart': repo 'https://charts.example.invalid' — (이름, 저장소) 쌍이 허용 목록에 없다" \
  "+[FAIL] 12.1 HELM-repo — tests/vendored-alias/kustomization.yaml helmCharts #1 'alias-chart': repo 'https://charts.example.invalid' — (이름, 저장소) 쌍이 허용 목록에 없다" \
  '-[FAIL] 12.1 HELM-repo — platform/cert-manager' '-[FAIL] 12.1 HELM-repo — platform/vault' '-[PASS] 12.1 HELM-repo' "${hs_block_k[@]}"

# --- 검사 12.4 · 12.5 · 임시 트리(tests/.tmp) ----------------------------------------------------------------------------------
# .gitignore의 앵커 없는 `charts/` 때문에 이름이 charts인 디렉터리 아래의 파일은 커밋되는 픽스처로 만들 수 없다. 트리의 나머지는
# tests/fixtures/helm-src/tree/ 에 두고, 실행 중에 tests/.tmp/<케이스>/ 로 복사한 뒤 argocd-cm 변형(helm-src/argocd-cm/<변형>.yaml)과
# charts/ 아래를 여기서 만든다(준비 실패는 fail_case — 검사 6 SHA 경로의 임시 저장소와 같다).
# helmCharts 인플레이트는 네트워크를 쓰지 않는다: kustomize는 <kustomization>/charts/<name>-<version>/<name>/ 에 차트가 이미 있으면 받지 않고
# 그것을 쓴다(kustomize v5.8.1 chartExistsLocally) — 그 자리에 작은 차트(ConfigMap 1장)를 둔다. 트리의 version(0.0.1-local)은 실재하지 않으므로
# 로컬 차트가 없으면 받기가 실패한다(조용히 인터넷의 차트를 쓰지 않는다). 로컬 차트 렌더에는 helm이 필요하다.
HS_ES_VER='0.0.1-local'   # tests/fixtures/helm-src/tree/platform/external-secrets/kustomization.yaml 의 version과 같아야 한다
HS_ROOT=''
hs_local_chart() { # <트리> <kustomization 디렉터리(트리 기준)> <차트 이름> <version> — 인플레이트 캐시 자리에 작은 차트를 둔다
  local c="$1/$2/charts/$3-$4/$3"
  mkdir -p "$c/templates" || return 1
  printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$3" "$4" > "$c/Chart.yaml" || return 1
  : > "$c/values.yaml" || return 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s-local-chart\n' "$3" > "$c/templates/configmap.yaml"
}
hs_tree() { # <케이스> <argocd-cm 변형> — helm-src/tree 복사 + argocd-cm 변형 + 로컬 차트 → 전역 HS_ROOT (if 조건 안 — 단계마다 확인)
  HS_ROOT="$TMP/$1"
  mkdir -p "$HS_ROOT" || return 1
  cp -R "$FIX/helm-src/tree/." "$HS_ROOT/" || return 1
  cp "$FIX/helm-src/argocd-cm/$2.yaml" "$HS_ROOT/bootstrap/argocd/argocd-cm.yaml" || return 1
  hs_local_chart "$HS_ROOT" platform/external-secrets external-secrets "$HS_ES_VER"
}
hs_tree_chartsdir() { # 12.5 — hs_tree(ok) + 캐시 자리 밖의 charts 둘 + 캐시 안의 하위 차트 자리(세지 않아야 한다)
  hs_tree helm-src-chartsdir ok || return 1
  mkdir -p "$HS_ROOT/platform/external-secrets/charts/external-secrets-$HS_ES_VER/external-secrets/charts" || return 1
  mkdir -p "$HS_ROOT/apps/charts/overlays/dev" || return 1
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
    > "$HS_ROOT/apps/charts/overlays/dev/kustomization.yaml" || return 1
  mkdir -p "$HS_ROOT/platform/cloudflared/charts" || return 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: leftover\n' > "$HS_ROOT/platform/cloudflared/charts/leftover.yaml"
}
# hs_case <케이스> <트리를 만드는 명령...> -- <기대 exit> [단언...] — 필터 밖이면 건너뜀으로 센다. 트리를 만들지 못하면 fail_case
hs_case() {
  local name=$1; shift
  local -a build=()
  while [[ $# -gt 0 && $1 != -- ]]; do build+=("$1"); shift; done
  shift
  if ! any_selected "$name"; then skip_cases "$name"; return 0; fi
  mkdir -p "$TMP"
  if "${build[@]}" 2>>"$TMP/helm-src.log"; then
    run_case "$name" "$HS_ROOT" "$@"
  else
    fail_case "$name" "임시 트리를 만들 수 없음 — $(tr -d '\r' < "$TMP/helm-src.log" | tail -n 3 | tr '\n' ' ')"
  fi
}
HS_CM='bootstrap/argocd (rendered) ConfigMap/argocd/argocd-cm'
if command -v kustomize >/dev/null 2>&1; then
  hs_helm=()   # 로컬 차트의 렌더가 성공했다는 단언 — helm이 있을 때만
  if command -v helm >/dev/null 2>&1; then hs_helm=('-[FAIL] 1 KUST'); fi
  #   12.4: helmCharts를 쓰는 kustomization(platform/external-secrets)이 있는데 argocd-cm의 kustomize.buildOptions에 --enable-helm 낱말이 없다
  #     — 다른 옵션만 · 글자는 들어 있지만 낱말이 아님(--enable-helmfoo) · 키 자체가 없음. ok는 여러 옵션 중 하나로 있는 경계(통과)다
  hs_case helm-src-argocd-no-flag hs_tree helm-src-argocd-no-flag no-flag -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" \"--load-restrictor LoadRestrictionsNone\"에 --enable-helm 낱말 없음" \
    '-[PASS] 12.4 HELM-argocd' '-[FAIL] 12.5' "${hs_helm[@]}"
  hs_case helm-src-argocd-helmfoo hs_tree helm-src-argocd-helmfoo helmfoo -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" \"--enable-helmfoo\"에 --enable-helm 낱말 없음" \
    '-[PASS] 12.4 HELM-argocd' "${hs_helm[@]}"
  hs_case helm-src-argocd-no-key hs_tree helm-src-argocd-no-key no-key -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" 없음" \
    '-[PASS] 12.4 HELM-argocd' "${hs_helm[@]}"
  hs_case helm-src-argocd-ok hs_tree helm-src-argocd-ok ok -- 1 \
    "+[PASS] 12.4 HELM-argocd — helmCharts를 쓰는 kustomization 1개 → $HS_CM data.\"kustomize.buildOptions\" \"--load-restrictor LoadRestrictionsNone --enable-helm\"에 --enable-helm 있음" \
    '+[PASS] 12.5 HELM-chartsdir' '-[FAIL] 12.' '-[FAIL] 11.' "${hs_helm[@]}"
  #   (B1 · 2026-09-30 G4 리뷰) `--enable-helm=<참값>`도 낱말로 받는다(pflag ParseBool) · 같은 플래그가 여럿이면 마지막 값이 이긴다(pflag) —
  #     eq-true는 앞의 =false를 뒤의 =true가 이기는 통과 경계, eq-false는 앞의 맨 --enable-helm을 뒤의 =false가 이기는 실패다
  hs_case helm-src-argocd-eq-true hs_tree helm-src-argocd-eq-true eq-true -- 1 \
    "+[PASS] 12.4 HELM-argocd — helmCharts를 쓰는 kustomization 1개 → $HS_CM data.\"kustomize.buildOptions\" \"--enable-helm=false --load-restrictor LoadRestrictionsNone --enable-helm=true\"에 --enable-helm 있음" \
    '-[FAIL] 12.' "${hs_helm[@]}"
  hs_case helm-src-argocd-eq-false hs_tree helm-src-argocd-eq-false eq-false -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" \"--enable-helm --load-restrictor LoadRestrictionsNone --enable-helm=false\"의 마지막 --enable-helm 낱말 \"--enable-helm=false\"이 참이 아니다" \
    '-[PASS] 12.4 HELM-argocd' '-낱말 없음' "${hs_helm[@]}"
  #   eq-invalid: 값이 참·거짓 낱말이 아닌 `--enable-helm=yes` 뒤에 맨 `--enable-helm` — pflag는 읽지 못하는 값에서 인자 해석을 멈춘다(kustomize build
  #     실패). 마지막 낱말만 보면 통과했을 설정이다
  hs_case helm-src-argocd-eq-invalid hs_tree helm-src-argocd-eq-invalid eq-invalid -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" \"--enable-helm=yes --enable-helm\"의 --enable-helm 낱말 \"--enable-helm=yes\"의 값을 pflag가 참·거짓으로 읽지 못한다" \
    '-[PASS] 12.4 HELM-argocd' '-낱말 없음' '-참이 아니다' "${hs_helm[@]}"
  #   eq-space: 마지막 `--enable-helm=false`를 U+2028로 앞 낱말에 붙였다 — strings.Fields(unicode.IsSpace)는 U+2028에서 나눈다. 낱말 정규식이 RE2의 \s
  #     집합이면 그 거짓이 한 낱말 안에 숨어 통과한다(yq의 to_json은 값의 U+2028을 JSON 유니코드 이스케이프로 적는다 — 아래 단언의 역슬래시 둘은
  #     bash 큰따옴표 안에서 하나가 된다)
  hs_case helm-src-argocd-eq-space hs_tree helm-src-argocd-eq-space eq-space -- 1 \
    "+[FAIL] 12.4 HELM-argocd — $HS_CM: data.\"kustomize.buildOptions\" \"--enable-helm --load-restrictor LoadRestrictionsNone\\u2028--enable-helm=false\"의 마지막 --enable-helm 낱말 \"--enable-helm=false\"이 참이 아니다" \
    '-[PASS] 12.4 HELM-argocd' '-낱말 없음' "${hs_helm[@]}"
else
  for c in no-flag helmfoo no-key ok eq-true eq-false eq-invalid eq-space; do
    hs_case "helm-src-argocd-$c" hs_tree "helm-src-argocd-$c" "$c" -- 1 '+[SKIP] 12.4 HELM-argocd — 도구 없음(kustomize)'
  done
fi
#   (F9 · 2026-09-30 G4 리뷰) 저장소 루트에서 bootstrap/argocd가 없다 — helmCharts를 쓰는 kustomization이 있는데 Argo CD 설정을 판정할 수 없어
#     FAIL(fail-closed). 부분 트리에서는 같은 부재가 "대상 없음"이므로(helm-src-repo 단언) 루트 판별을 픽스처로 돌린다 — 검사 13의 rbac-root-*와
#     같은 방식(임시 트리의 tests/에 validate.sh 사본). 12.4의 부재 판정은 렌더를 보지 않아 kustomize 유무와 무관하다(로컬 차트는 검사 1이
#     네트워크로 차트를 받으러 가지 않게 둔다)
HS_RT="$TMP/helm-src-root-no-argocd"
hs_root_tree() { # → 전역 HS_ROOT (if 조건 안 — 단계마다 확인)
  HS_ROOT=$HS_RT
  mkdir -p "$HS_ROOT/tests" || return 1
  cp -R "$FIX/helm-src/tree/platform" "$HS_ROOT/" || return 1
  cp "$VALIDATE" "$HS_ROOT/tests/validate.sh" || return 1
  hs_local_chart "$HS_ROOT" platform/external-secrets external-secrets "$HS_ES_VER"
}
hs_case helm-src-root-no-argocd hs_root_tree -- 1 --script "$HS_RT/tests/validate.sh" \
  '+[FAIL] 12.4 HELM-argocd — bootstrap/argocd/kustomization.yaml 없음 — helmCharts를 쓰는 kustomization 1개가 있는데 Argo CD 설정(argocd-cm)을 판정할 수 없다(fail-closed)' \
  '-[PASS] 12.4 HELM-argocd'
#   12.5: 캐시 자리 밖의 charts 둘 — pod 이름이 charts(apps/charts/overlays/dev) · helmCharts를 쓰지 않는 kustomization 아래. 캐시 자리
#     (helmCharts를 쓰는 platform/external-secrets 바로 아래)와 그 안의 하위 차트 자리(…/external-secrets/charts)는 걸리지 않는다
hs_case helm-src-chartsdir hs_tree_chartsdir -- 1 \
  '+[FAIL] 12.5 HELM-chartsdir — apps/charts/: 이름이 charts인 디렉터리 — 부모 apps/에 kustomization이 없다' \
  '+[FAIL] 12.5 HELM-chartsdir — platform/cloudflared/charts/: 이름이 charts인 디렉터리 — 부모 platform/cloudflared/의 kustomization이 helmCharts를 쓰지 않는다' \
  '-[FAIL] 12.5 HELM-chartsdir — platform/external-secrets/' '-[PASS] 12.5 HELM-chartsdir'

# --- 검사 13: 권한 경계(T047 G4b · 계약 §validate.yml 4 「(T047) 권한 경계 — 문자열이 아니라 규칙 구조로 본다」) ---------------------
# 모든 트리가 부분 트리다 — exit 1은 무관한 FAIL로도 나므로 판정 근거가 아니다. 근거는 하위 코드의 `+[FAIL] 13.x` 단언, 그룹 PASS 줄이 없다는
# `-[PASS] 13 RBAC`, 그리고 그 트리의 결함이 다른 하위 코드로 번지지 않는다는 `-[FAIL] 13.x`다. 대조군(걸리면 안 되는 객체)은 `-` 단언으로 짚는다.
# "통과해야 하는 것"(경계)은 rbac/pass 한 트리에 모아 그룹 PASS 줄(개수 포함)을 단언한다. 렌더를 보는 검사라 kustomize가 없으면 모든 케이스가
# "도구 없음"(SKIP)이 정답이다. helm·네트워크는 쓰지 않는다.
RB_CASES='token extref builtin-name subject reloader-subject aggregation render-fail pass'
RB_ALL13=('-[FAIL] 13.0' '-[FAIL] 13.1' '-[FAIL] 13.2' '-[FAIL] 13.3' '-[FAIL] 13.4' '-[FAIL] 13.5' '-[FAIL] 13.6')
rb_others() { # <이 트리가 거는 하위 코드(예: 13.1)> — 그 밖의 13.x FAIL이 없다는 음성 단언 목록 → 전역 RB_NEG
  local a
  RB_NEG=('-[PASS] 13 RBAC')
  for a in "${RB_ALL13[@]}"; do [[ $a == "-[FAIL] $1" ]] || RB_NEG+=("$a"); done
}
RB_PASS_BODY='Role 4 · ClusterRole 7 · 바인딩 6장(RoleBinding 2 · ClusterRoleBinding 4) · 주체 6개 모두 이름을 다 적은 ServiceAccount · 토큰 발급 규칙을 가진 역할 2개(ClusterRole/argocd-application-controller · Role/external-secrets/eso-token-create) · 렌더되지 않은 ClusterRole을 가리키는 바인딩 2장(ClusterRoleBinding/agent-view-view → view · ClusterRoleBinding/vault-server-binding → system:auth-delegator) · Role을 가리키는 RoleBinding 1장 모두 같은 ns의 렌더된 Role · 내장 역할 이름의 ClusterRole 0 · aggregationRule 0 · aggregate-to-* 라벨 ClusterRole 5개(cert-manager-cluster-view · cert-manager-edit · cert-manager-view · external-secrets-edit · external-secrets-view) · Reloader 주체(ServiceAccount reloader/reloader) 바인딩은 platform/reloader 렌더에만 — 그 렌더 안 0장(장수·모양은 검사 10)'
if command -v kustomize >/dev/null 2>&1; then
  #   token: 기준선 밖 역할의 토큰 발급 규칙 ⓐ–ⓓ(platform/cloudflared) · 기준선 ②(Role external-secrets/eso-token-create)의 모양 불일치 —
  #     ⓔ resourceNames 하나 더(platform/external-secrets) · ⓕ resourceNames 없음(platform/vault) · ⓖ 토큰 발급 규칙 둘(platform/openfga) ·
  #     ⓗ 다른 렌더(platform/cloudflared)가 같은 이름으로 넓은 규칙. 같은 이름은 나타난 것마다 판정한다(기준선 밖이라고 하지 않고 모양으로 건다) ·
  #     ⓘ resources ["*/token"] 하나뿐인 규칙(platform/cloudflared — RBAC ResourceMatches가 `*/<subresource>`를 와일드카드로 읽는다 · 계약 2026-09-30 추가) ·
  #     ⓙ 기준선 ②의 resourceNames가 빈 목록(platform/dragonfly — RBAC에서 빈 목록은 "제한 없음"이다 · 2026-09-30 G4 리뷰 F9: 빈 목록 분기의 고유 문구를 짚는다)
  RB_TOK='+[FAIL] 13.1 RBAC-token — '
  RB_CF='platform/cloudflared (rendered)'
  RB_ESO='Role/external-secrets/eso-token-create'
  rb_others 13.1
  run_case rbac-token "$FIX/rbac/token" 1 \
    "${RB_TOK}$RB_CF Role/cloudflared/sa-token 규칙 #2(apiGroups [\"\"] · resources [\"serviceaccounts/token\"] · verbs [\"create\"]): ServiceAccount 토큰 발급 규칙 — 기준선(ClusterRole/argocd-application-controller · $RB_ESO) 밖의 역할이다" \
    "${RB_TOK}$RB_CF Role/cloudflared/core-wild 규칙 #1(apiGroups [\"\"] · resources [\"*\"] · verbs [\"*\"]): ServiceAccount 토큰 발급 규칙" \
    "${RB_TOK}$RB_CF Role/cloudflared/sa-subwild 규칙 #1(apiGroups [\"\"] · resources [\"serviceaccounts/*\"] · verbs [\"create\"]): ServiceAccount 토큰 발급 규칙" \
    "${RB_TOK}$RB_CF ClusterRole/all-wild 규칙 #1(apiGroups [\"*\"] · resources [\"*/*\"] · verbs [\"create\"]): ServiceAccount 토큰 발급 규칙" \
    "${RB_TOK}$RB_CF Role/cloudflared/any-token 규칙 #1(apiGroups [\"\"] · resources [\"*/token\"] · verbs [\"create\"]): ServiceAccount 토큰 발급 규칙" \
    "${RB_TOK}platform/external-secrets (rendered) $RB_ESO 규칙 #1: resourceNames 집합 [\"eso-ca-reader\",\"eso-data\",\"eso-dev\",\"eso-extra\",\"eso-platform\",\"eso-prod\"] ≠ 기준선 ② [\"eso-ca-reader\",\"eso-data\",\"eso-dev\",\"eso-platform\",\"eso-prod\"]" \
    "${RB_TOK}platform/vault (rendered) $RB_ESO 규칙 #1: resourceNames 없음" \
    "${RB_TOK}platform/openfga (rendered) $RB_ESO: 토큰 발급 규칙 2개 ≠ 1" \
    "${RB_TOK}platform/openfga (rendered) $RB_ESO 규칙 #2: resourceNames 집합 [\"external-secrets\"] ≠ 기준선 ②" \
    "${RB_TOK}$RB_CF $RB_ESO 규칙 #1: apiGroups·resources·verbs가 기준선 ②와 다르다 — 실제 apiGroups [\"\"] · resources [\"*\"] · verbs [\"*\"]" \
    "${RB_TOK}$RB_CF $RB_ESO 규칙 #1: resourceNames 없음" \
    "${RB_TOK}platform/dragonfly (rendered) $RB_ESO 규칙 #1: resourceNames가 빈 목록 — 제한이 없다" \
    "-[FAIL] 13.1 RBAC-token — platform/dragonfly (rendered) $RB_ESO 규칙 #1: resourceNames 집합" \
    "-[FAIL] 13.1 RBAC-token — $RB_CF Role/cloudflared/sa-token 규칙 #1" \
    "-[FAIL] 13.1 RBAC-token — $RB_CF $RB_ESO 규칙 #1(" \
    "-[FAIL] 13.1 RBAC-token — platform/openfga (rendered) $RB_ESO 규칙 #1" \
    "-[FAIL] 13.1 RBAC-token — platform/external-secrets (rendered) $RB_ESO 규칙 #1: apiGroups" \
    "-[FAIL] 13.1 RBAC-token — platform/external-secrets (rendered) $RB_ESO: 토큰 발급 규칙" \
    "-[FAIL] 13.1 RBAC-token — platform/vault (rendered) $RB_ESO: 토큰 발급 규칙" \
    "${RB_NEG[@]}"
  #   extref: 렌더에 없는 ClusterRole을 가리키는 바인딩 ⓐ–ⓓ(기준선은 바인딩 kind · 이름 · 대상 이름의 세 값) · 다른 ns에만 있는 Role(ⓔ) ·
  #     ClusterRoleBinding → Role(ⓕ) · roleRef.kind가 둘 밖(ⓖ). 기준선 vault-server-binding(platform/vault)은 걸리지 않는다
  RB_EXT='+[FAIL] 13.2 RBAC-extref — platform/policies (rendered) '
  rb_others 13.2
  run_case rbac-extref "$FIX/rbac/extref" 1 \
    "${RB_EXT}ClusterRoleBinding/grant-all → ClusterRole 'cluster-admin': 그 이름의 ClusterRole이 어느 렌더에도 없다(내장 역할 등 — 규칙을 볼 수 없다)" \
    "${RB_EXT}RoleBinding/jt-dev/dev-edit → ClusterRole 'edit': 그 이름의 ClusterRole이 어느 렌더에도 없다" \
    "${RB_EXT}ClusterRoleBinding/agent-view-view → ClusterRole 'admin': 그 이름의 ClusterRole이 어느 렌더에도 없다" \
    "${RB_EXT}ClusterRoleBinding/agent-view-extra → ClusterRole 'view': 그 이름의 ClusterRole이 어느 렌더에도 없다" \
    "${RB_EXT}RoleBinding/jt-dev/cross-ns → Role 'only-in-prod': 같은 ns(jt-dev)의 그 Role이 어느 렌더에도 없다" \
    "${RB_EXT}ClusterRoleBinding/crb-to-role → Role 'only-in-prod': ClusterRoleBinding은 Role을 가리킬 수 없다" \
    "${RB_EXT}RoleBinding/jt-dev/odd-kind: roleRef.kind 'Group' — Role·ClusterRole만" \
    '-[FAIL] 13.2 RBAC-extref — platform/vault (rendered)' \
    "${RB_NEG[@]}"
  #   builtin-name: 내장 역할 이름의 ClusterRole(view · system:custom) — 그것을 가리키는 바인딩 둘은 13.2가 아니라 13.3(역할 쪽)으로 잡힌다
  RB_BI='+[FAIL] 13.3 RBAC-builtin-name — platform/monitoring (rendered) ClusterRole/'
  rb_others 13.3
  run_case rbac-builtin-name "$FIX/rbac/builtin-name" 1 \
    "${RB_BI}view: 내장 역할의 이름(cluster-admin·admin·edit·view · system: 접두) 금지" \
    "${RB_BI}system:custom: 내장 역할의 이름(cluster-admin·admin·edit·view · system: 접두) 금지" \
    "${RB_NEG[@]}"
  #   subject: Group · User(ServiceAccount의 사용자 이름 표기) · namespace 없는 SA · name이 빈 SA · 둘째 주체만 Group · subjects가 맵.
  #     ok-sa와 mixed의 첫 주체는 걸리지 않는다. User system:serviceaccount:reloader:reloader는 13.4가 걸고 13.5(SA 주체만 본다)는 걸지 않는다
  RB_SUB='+[FAIL] 13.4 RBAC-subject — platform/monitoring (rendered) RoleBinding/monitoring/'
  rb_others 13.4
  run_case rbac-subject "$FIX/rbac/subject" 1 \
    "${RB_SUB}group-sa 주체 #1 kind 'Group' name 'system:serviceaccounts': 주체는 이름을 다 적은 ServiceAccount뿐이다" \
    "${RB_SUB}user-sa 주체 #1 kind 'User' name 'system:serviceaccount:reloader:reloader': 주체는 이름을 다 적은 ServiceAccount뿐이다" \
    "${RB_SUB}sa-no-ns 주체 #1 ServiceAccount 'prometheus': namespace가 비었다" \
    "${RB_SUB}sa-empty-name 주체 #1 ServiceAccount: name이 비었다" \
    "${RB_SUB}mixed 주체 #2 kind 'Group' name 'system:authenticated'" \
    "${RB_SUB}subjects-map: subjects가 목록이 아니다(태그 !!map)" \
    '-[FAIL] 13.4 RBAC-subject — platform/monitoring (rendered) RoleBinding/monitoring/mixed 주체 #1' \
    '-[FAIL] 13.4 RBAC-subject — platform/monitoring (rendered) RoleBinding/monitoring/ok-sa' \
    "${RB_NEG[@]}"
  #   reloader-subject: platform/reloader 밖(platform/cloudflared)의 RoleBinding과 ClusterRoleBinding(둘째 주체)이 ServiceAccount reloader/reloader를
  #     주체로 가진다. platform/reloader 렌더 안의 바인딩(대조군)은 걸리지 않는다
  RB_RS='+[FAIL] 13.5 RBAC-reloader-subject — platform/cloudflared (rendered) '
  rb_others 13.5
  run_case rbac-reloader-subject "$FIX/rbac/reloader-subject" 1 \
    "${RB_RS}RoleBinding/cloudflared/reloader-read 주체 #1 ServiceAccount reloader/reloader: platform/reloader 밖의 렌더가 Reloader에게 권한을 준다" \
    "${RB_RS}ClusterRoleBinding/reloader-extra 주체 #2 ServiceAccount reloader/reloader: platform/reloader 밖의 렌더가 Reloader에게 권한을 준다" \
    '-[FAIL] 13.5 RBAC-reloader-subject — platform/reloader (rendered)' \
    '-[FAIL] 13.5 RBAC-reloader-subject — platform/cloudflared (rendered) ClusterRoleBinding/reloader-extra 주체 #1' \
    "${RB_NEG[@]}"
  #   aggregation: aggregationRule · 기준선 밖 이름의 aggregate-to-view: "true" · 값이 "false"인 라벨(그래도 FAIL). 기준선 이름 cert-manager-view는 걸리지 않는다
  RB_AG='+[FAIL] 13.6 RBAC-aggregation — platform/monitoring (rendered) ClusterRole/'
  rb_others 13.6
  run_case rbac-aggregation "$FIX/rbac/aggregation" 1 \
    "${RB_AG}agg-parent: aggregationRule 금지" \
    "${RB_AG}extra-view: aggregate-to-* 라벨 [\"rbac.authorization.k8s.io/aggregate-to-view\"] — 기준선(" \
    "${RB_AG}extra-false: aggregate-to-* 라벨 [\"rbac.authorization.k8s.io/aggregate-to-edit\"] — 기준선(" \
    '-[FAIL] 13.6 RBAC-aggregation — platform/cert-manager (rendered)' \
    '-[FAIL] 13.6 RBAC-aggregation — platform/monitoring (rendered) ClusterRole/agg-parent: aggregate-to-*' \
    "${RB_NEG[@]}"
  #   render-fail: 렌더에 실패하는 kustomization이 섞인 트리 — 합친 집합이 불완전하므로 그룹 PASS 줄이 없다(fail-closed)
  rb_others 13.0
  run_case rbac-render-fail "$FIX/rbac/render-fail" 1 \
    '+[FAIL] 13.0 RBAC-render — 렌더가 없는 kustomization 1개 [platform/monitoring]' \
    "${RB_NEG[@]}"
  #   pass(경계): 토큰이 아닌 규칙(serviceaccounts create · apps 그룹 와일드카드 · 규칙 둘에 나뉜 조건) · 기준선 ①(이름만)과 ②(resourceNames 순서만
  #     다르다) · 다른 렌더가 정의한 ClusterRole을 가리키는 바인딩 · 기준선 바인딩 2장 · 기준선 이름의 aggregate-to-* 라벨 ClusterRole 5장
  run_case rbac-pass "$FIX/rbac/pass" 1 \
    "+[PASS] 13 RBAC — 렌더 7개 합산(부분 트리 — 기준선 밖의 것만 본다) — $RB_PASS_BODY" \
    '-[FAIL] 13.'
else
  for c in $RB_CASES; do
    run_case "rbac-$c" "$FIX/rbac/$c" 1 '+[SKIP] 13 RBAC — 도구 없음(kustomize)'
  done
fi

# --- 검사 13 · 저장소 루트(완전성) — 임시 트리(tests/.tmp) ------------------------------------------------------------------------
# "기준선의 것이 있는가"는 --root가 **스크립트의 저장소 루트**일 때만 판정한다(부분 트리 픽스처는 기준선 밖의 것만 본다). 그 분기를 픽스처로
# 돌리려고 임시 트리의 tests/에 validate.sh 사본을 넣고(스크립트는 자기 위치의 부모를 저장소 루트로 삼는다) 그 트리를 --root로 준다.
#   rbac-root-ok      = fixtures/rbac/pass(기준선 전부) — 부분 트리 실행(rbac-pass)과 같은 줄에 모드만 "저장소 루트"
#   rbac-root-missing = 빈 트리 — 기준선의 역할 2 · 바인딩 2 · 라벨 ClusterRole 5가 모두 없다(렌더가 0개여도 "대상 없음" PASS가 아니다)
RB_ROOT=''
rb_root_tree() { # <케이스> [<fixtures/rbac 아래 트리>] — 임시 트리 + validate.sh 사본 → 전역 RB_ROOT (if 조건 안 — 단계마다 확인)
  RB_ROOT="$TMP/$1"
  mkdir -p "$RB_ROOT/tests" || return 1
  if [[ -n ${2:-} ]]; then cp -R "$FIX/rbac/$2/." "$RB_ROOT/" || return 1; fi
  cp "$VALIDATE" "$RB_ROOT/tests/validate.sh"
}
rb_root_case() { # <케이스> <트리|''> <기대 exit> [단언...] — 필터 밖이면 건너뜀으로 센다. 트리를 만들지 못하면 fail_case
  local name=$1 src=$2; shift 2
  if ! any_selected "$name"; then skip_cases "$name"; return 0; fi
  mkdir -p "$TMP"
  if rb_root_tree "$name" "$src" 2>>"$TMP/rbac-root.log"; then
    run_case "$name" "$RB_ROOT" "$@" --script "$RB_ROOT/tests/validate.sh"
  else
    fail_case "$name" "임시 트리를 만들 수 없음 — $(tr -d '\r' < "$TMP/rbac-root.log" | tail -n 3 | tr '\n' ' ')"
  fi
}
if command -v kustomize >/dev/null 2>&1; then
  rb_root_case rbac-root-ok pass 1 \
    "+[PASS] 13 RBAC — 렌더 7개 합산(저장소 루트 — 기준선 전부 있음) — $RB_PASS_BODY" \
    '-[FAIL] 13.'
  RB_RM='저장소 루트에 기준선의 '
  rb_root_case rbac-root-missing '' 1 \
    "+[FAIL] 13.1 RBAC-token — ${RB_RM}토큰 발급 역할 ClusterRole/argocd-application-controller 없음" \
    "+[FAIL] 13.1 RBAC-token — ${RB_RM}토큰 발급 역할 Role/external-secrets/eso-token-create 없음" \
    "+[FAIL] 13.2 RBAC-extref — ${RB_RM}바인딩 ClusterRoleBinding/agent-view-view → ClusterRole 'view' 없음" \
    "+[FAIL] 13.2 RBAC-extref — ${RB_RM}바인딩 ClusterRoleBinding/vault-server-binding → ClusterRole 'system:auth-delegator' 없음" \
    "+[FAIL] 13.6 RBAC-aggregation — ${RB_RM}aggregate-to-* 라벨 ClusterRole 'cert-manager-cluster-view' 없음" \
    "+[FAIL] 13.6 RBAC-aggregation — ${RB_RM}aggregate-to-* 라벨 ClusterRole 'external-secrets-view' 없음" \
    '-[PASS] 13 RBAC' '-[FAIL] 13.0' '-[FAIL] 13.3' '-[FAIL] 13.4' '-[FAIL] 13.5'
else
  rb_root_case rbac-root-ok pass 1 '+[SKIP] 13 RBAC — 도구 없음(kustomize)'
  rb_root_case rbac-root-missing '' 1 '+[SKIP] 13 RBAC — 도구 없음(kustomize)'
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

# --- 검사 11.5 · 심볼릭 링크(계약 형식별 정책 「심볼릭 링크」 행 — --root 트리 어디든) — 임시 트리 · 임시 git 저장소(tests/.tmp) ---------------
# 링크는 커밋되는 픽스처로 두지 않는다(fmt-dirsource-link와 같은 이유 · 같은 만드는 법). 원본 fixtures/fmt/symlink/(링크의 대상만 — 파일 열거 밖인
# tests/ 아래)를 tests/.tmp/fmt-symlink/로 복사하고 링크 셋을 만든다:
#   ⓐ 파일 링크      platform/vault/kustomization.yaml → ../../tests/payload/kustomization.yaml — kustomization 열거(find -type f)가 세지 않는다
#   ⓑ 디렉터리 링크  platform/cloudflared → ../tests/hidden-cf — 컴포넌트 디렉터리 자체가 링크(2026-09-30 수정 빌더의 재현 모양: 안의 cluster-admin
#                    바인딩이 모든 검사의 시야 밖에서 렌더되어 exit 0이었다)
#   ⓒ 깨진 링크      platform/broken.yaml → ../tests/payload/missing.yaml
# 이 트리에는 Application이 없어 directory source 경로가 없다 — 링크를 거는 것은 11.5뿐이다(11.3 FAIL 없음).
#   fmt-symlink        --root가 git 작업 트리 안(tests/.tmp는 무시 대상이라 인덱스 항목 0) — ①(작업 트리)이 셋을 건다
#   fmt-symlink-nogit  같은 트리를 GIT_CEILING_DIRECTORIES로 git 밖에 둔다 — ②(인덱스)를 볼 수 없다는 사실을 적고도 ①이 돈다(fail-open 아님)
#   fmt-symlink-index  임시 git 저장소: 작업 트리의 platform/cloudflared는 일반 파일(링크 대상 문자열 — core.symlinks=false 체크아웃의 모양)이고
#                      인덱스에만 모드 120000(update-index --cacheinfo) — ①은 못 보고 ②가 건다. 링크를 만들지 않으므로 어느 환경에서나 돈다
# 링크를 만들 수 없는 환경에서는 앞 두 케이스가 이유를 적은 [SKIP]이다(fmt-dirsource-link와 같다 — CI · 판정용 실행에서는 실패).
SL_ROOT="$TMP/fmt-symlink"
SL_IDX="$TMP/fmt-symlink-index"
SL_WHY=''
sl_tree() { # → 0 준비됨 · 1 준비 실패 · 2 링크를 만들 수 없는 환경(SL_WHY에 이유)
  local l
  mkdir -p "$SL_ROOT/platform/vault" || return 1
  cp -R "$FIX/fmt/symlink/." "$SL_ROOT/" || return 1
  if ! ( cd "$SL_ROOT/platform" && export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" \
         && ln -s ../../tests/payload/kustomization.yaml vault/kustomization.yaml && ln -s ../tests/hidden-cf cloudflared \
         && ln -s ../tests/payload/missing.yaml broken.yaml ); then
    SL_WHY='ln -s 실패(Windows는 개발자 모드나 관리자 권한이 있어야 진짜 링크를 만든다)'; return 2
  fi
  for l in vault/kustomization.yaml cloudflared broken.yaml; do
    [[ -L "$SL_ROOT/platform/$l" ]] || { SL_WHY="ln -s가 링크가 아닌 것을 만들었다(platform/$l)"; return 2; }
  done
}
sl_index_tree() { # 임시 git 저장소 — 작업 트리에는 일반 파일 · 인덱스에는 모드 120000(if 조건 안에서 부르므로 set -e가 꺼진다 — 단계마다 확인한다)
  local blob
  mkdir -p "$SL_IDX/platform" || return 1
  tg "$SL_IDX" init -q || return 1
  cp -R "$FIX/fmt/symlink/tests" "$SL_IDX/" || return 1
  printf '%s' '../tests/hidden-cf' > "$SL_IDX/platform/cloudflared" || return 1
  tg "$SL_IDX" add -A -- tests || return 1
  blob=$(printf '%s' '../tests/hidden-cf' | tg "$SL_IDX" hash-object -w --stdin) || return 1
  tg "$SL_IDX" update-index --add --cacheinfo "120000,$blob,platform/cloudflared" || return 1
  [[ -f "$SL_IDX/platform/cloudflared" && ! -L "$SL_IDX/platform/cloudflared" ]]
}
SL='[FAIL] 11.5 FMT-symlink — '
SL_NOIDX='11.5 git 인덱스를 보지 않았다'
# ②가 도는 것(인덱스를 읽음)의 음성 단언은 이 저장소가 git 작업 트리일 때만 건다(CI · 로컬 체크아웃 — git 밖에서 돌린 자기검사는 그 줄이 정답이다)
sl_inrepo=()
if [[ $(git -C "$HERE" rev-parse --is-inside-work-tree 2>/dev/null) == true ]]; then sl_inrepo=("-$SL_NOIDX"); fi
SL_CASES=(fmt-symlink fmt-symlink-nogit)
if any_selected "${SL_CASES[@]}"; then
  mkdir -p "$TMP"
  sl_rc=0; sl_tree 2>>"$TMP/fmt-symlink.log" || sl_rc=$?
  if [[ $sl_rc == 0 ]]; then
    run_case fmt-symlink "$SL_ROOT" 1 \
      "+${SL}platform/vault/kustomization.yaml: 심볼릭 링크 금지(→ '../../tests/payload/kustomization.yaml')" \
      "+${SL}platform/cloudflared: 심볼릭 링크 금지(→ '../tests/hidden-cf')" \
      "+${SL}platform/broken.yaml: 심볼릭 링크 금지(→ '../tests/payload/missing.yaml' · 대상 없음)" \
      '-[PASS] 11.5 FMT-symlink' '-[FAIL] 11.3' '-git 인덱스의 모드 120000' "${sl_inrepo[@]}"
    run_case fmt-symlink-nogit "$SL_ROOT" 1 --env "GIT_CEILING_DIRECTORIES=$TMP" \
      "+$SL_NOIDX(git 작업 트리가 아니다)" \
      "+${SL}platform/cloudflared: 심볼릭 링크 금지(→ '../tests/hidden-cf')" \
      '-[PASS] 11.5 FMT-symlink'
  elif [[ $sl_rc == 2 && ${VALIDATE_TESTS_REQUIRE_TOOLS:-0} != 1 && ${CI:-} != true ]]; then
    for c in "${SL_CASES[@]}"; do
      selected "$c" || continue
      NSKIP=$((NSKIP + 1))
      printf '[SKIP] %s — 이 환경에서 심볼릭 링크를 만들 수 없다: %s — 11.5의 작업 트리 판정(①)은 이번 실행에서 확인되지 않았다(CI 러너는 돌린다)\n' "$c" "$SL_WHY"
    done
  else
    sl_why=${SL_WHY:-$(tr -d '\r' < "$TMP/fmt-symlink.log" | tail -n 3 | tr '\n' ' ')}
    for c in "${SL_CASES[@]}"; do fail_case "$c" "임시 트리를 만들 수 없음 — $sl_why"; done
  fi
else
  skip_cases "${SL_CASES[@]}"
fi
if any_selected fmt-symlink-index; then
  mkdir -p "$TMP"
  if sl_index_tree 2>"$TMP/fmt-symlink-index.log"; then
    run_case fmt-symlink-index "$SL_IDX" 1 \
      "+${SL}platform/cloudflared: git 인덱스의 모드 120000(심볼릭 링크) 금지" \
      "-${SL}platform/cloudflared: 심볼릭 링크 금지" '-[PASS] 11.5 FMT-symlink' "-$SL_NOIDX"
  else
    fail_case fmt-symlink-index "임시 git 저장소를 만들 수 없음 — $(tr -d '\r' < "$TMP/fmt-symlink-index.log" | tail -n 3 | tr '\n' ' ')"
  fi
else
  skip_cases fmt-symlink-index
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
elif [[ $NSKIP -gt 0 ]]; then
  # 필터가 없는데 건너뜀이 있다 = 이 환경에서 준비할 수 없는 케이스(fmt-dirsource-link의 심볼릭 링크 — 위 [SKIP] 줄). 결과를 온전하다고 읽지 않도록 드러낸다
  printf '\n== 자기검사 요약: %d 케이스, 실패 %d · 환경 SKIP %d(위 [SKIP] 줄 — 이 실행은 그 케이스를 확인하지 않았다) ==\n' "$N" "$NF" "$NSKIP"
else
  printf '\n== 자기검사 요약: %d 케이스, 실패 %d ==\n' "$N" "$NF"
fi
if [[ $NF -gt 0 ]]; then
  printf '실패: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
