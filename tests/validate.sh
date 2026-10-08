#!/usr/bin/env bash
# =============================================================================
# tests/validate.sh — platform-gitops required check `validate`의 검사 본체 (T033)
#   `.github/workflows/validate.yml`(T047 G2)이 부른다 — 무엇이 어떤 순서로 도는지(PR에서 먼저 base 커밋의 이 스크립트를
#     --only-author로 돌리는 것 포함)는 tests/README.md 「CI 배선 상태」 한 곳에 적는다.
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
#   3.2  ES-②              scope ↔ 위치(overlays/dev → vault-dev+dev/, overlays/prod → vault-prod+prod/, secrets/** → vault-platform+platform/
#                           · T045 G4: 배달자 렌더 platform/secrets 도 secrets/** 와 같은 규칙으로 본다)
#   3.3  ES-③              platform/{cnpg-databases,kafka-topics,dragonfly,authentik,openfga}: vault-data(열거 접두) 또는 vault-platform(platform/)
#   3.4  ES-④              k8s-data-ca: key ∈ {pg-main-ca, jt-kafka-cluster-ca-cert} + property ca.crt, dataFrom 금지
#   3.5  ES-⑤              Deployment·StatefulSet·DaemonSet·CronJob의 `-migrate` Secret 참조 금지
#   3.6  ES-⑥              automountServiceAccountToken: false (apps/** · platform/cloudflared · platform/dragonfly)
#   3.7  ES-⑦              apps/** 의 key가 (dev|prod)/(access|web)/ 접두면 FAIL(Workers 전용)
#   4a   IMG-newTag         kustomization images[].newTag 금지(digest 형식도 검사)
#   4a   IMG-name           (T047 · 계약 §이미지·승격 「항목마다 name과 digest」) images 항목마다 name — 없음 · 빈 값 · 문자열이 아님이면 FAIL
#   4a   IMG-digest         images 항목마다 digest — 없음 · 빈 값(null · "")이면 FAIL. 형식 오류는 IMG-newTag가 찍으므로 다시 찍지 않는다 —
#                           단 IMG-newTag가 보지 않는 값(그 추출이 '없음'으로 읽는 '-' · false, 그리고 IMG-newTag가 건너뛰는 name 빈 항목)은 여기서 본다
#   4a   IMG-keys           images 항목의 키 ⊆ IMG_ENTRY_KEYS({name, newName, digest}) · 키 중복 금지. newTag는 IMG-newTag가 그 항목에 찍었으면
#                           다시 찍지 않는다(null · false · '-' 값이나 name 빈 항목의 newTag는 여기서 찍는다)
#   4a   IMG-shape          fail-closed: images가 목록이 아님(null은 images 없음과 같다) · 항목이 맵이 아님(앵커 별칭 포함) · 문서가 맵이 아님 ·
#                           yq 추출 실패 · 추출 행 모양 이상. 대상 = IMG-newTag와 같은 모든 kustomization(KUST_FILES — 계약 문면은 apps/** overlay).
#                           그룹 PASS 줄 = 4a IMG-entry(항목 0개면 대상 없음). IMG-newTag의 줄·개수·PASS 줄은 T047 이전과 같다(YQ_IMAGES의 O 행)
#   4b   IMG-platform-digest platform/** 의 image: 줄에 @sha256 없으면 경고(WARN)
#                           한계: `image:` 스칼라 줄만 검사한다 — helm values의 분리형 image.repository / image.tag 는 보지 않는다
#   5.0  POL-location       Namespace·NetworkPolicy·ResourceQuota·LimitRange는 platform/policies/ 에만
#   5.1  POL-ns             platform/policies Namespace 목록 = 계약 표 14개(누락·초과·중복 FAIL)
#   5.2  POL-set            ns마다 공통 정책 세트 존재(deny-imds=kube-system 전용, allow-imds=vault 전용)
#   5.3  POL-egress         모든 egress ipBlock 규칙에 ports + except 4개(IMDS·RFC 1918 3종); IMDS /32는 vault만
#   5.4  POL-port           포트 출처 각주 ↔ 정책 포트 · helm values 포트 ↔ 정책 포트
#   5.5  POL-limitrange     LimitRange에 default.cpu·max.cpu 없음
#   5.6  POL-webhook-src    allow-apiserver-webhook(원본 + kustomize 렌더): 출발 ipBlock 집합·단일 TCP 포트 정확 일치
#                           (cert-manager·external-secrets·cnpg-system = 노드 A private+flannel /32, vault 8200 = private /32)
#   6    AUTHOR             봇 PR: 변경 파일 = apps/*/overlays/dev/kustomization.yaml, 변경 줄 = images[].digest 값의 제자리 교체뿐
#                           봇 판정: 로그인이 VALIDATE_BOT_AUTHORS에 있음(대소문자 무시) 또는 계정 ID(PR_AUTHOR_ID)가 VALIDATE_BOT_IDS에
#                           있음 — ID가 목록에 있으면 로그인이 무엇이든 봇이다(App 이름을 바꿔도 ID는 그대로)
#                           봇 PR = 작성자(PR_AUTHOR · pull_request.user)가 봇 **또는** 이벤트 발신자(PR_SENDER · PR_SENDER_ID = sender —
#                           push한 쪽 · 다시 연 쪽)가 봇(정의는 작성자와 같다). App은 사람이 연 PR의 브랜치에 push하고 머지할 수 있으므로
#                           작성자만 보면 그 PR이 제한 없이 통과한다(계약 「봇 판정의 대상은 PR 작성자와 이벤트 발신자 둘 다다」). 발신자
#                           때문에 봇이면 `봇 판정:` 줄(작성자·발신자)을 찍고, 그 뒤 판정은 봇 작성자 PR과 같다(PR 전체 = merge-base ↔ head).
#                           사람 작성자 + 사람 발신자의 PASS 줄은 발신자도 봇이 아님(또는 발신자 미지정 — PR 이벤트 아님)을 적는다
#                           판정 규칙(계약 gitops-repo.md): ① SHA 입력의 merge-base는 정확히 하나(`git merge-base --all`이 둘 이상이면
#                           6 AUTHOR-input FAIL) ② hunk 안의 변경은 제자리 교체뿐 — '-' 줄 하나 바로 뒤에 '+' 줄 하나가 오는 쌍만 허용하고
#                           (짝 없는 삭제·추가는 줄 형식이 맞아도 FAIL), 두 줄이 모두 digest 줄이면 64hex 밖이 같아야 한다
#                           ('\ No newline at end of file'은 건너뛴다) ③ '@@' 뒤 hunk 구간에서는 '+++ '·'--- '로 시작하는 줄도 내용이다
#                           ④ git diff 옵션 고정(--no-ext-diff · --no-textconv · --no-renames · --ignore-submodules=none · --no-color)
#                           한계: digest 값의 진위·서명과, 교체된 digest가 어떤 이미지인지는 보지 않는다. 보증은 이 줄 검사와
#                           트리 검사(4a·kustomize build)의 결합이며, PR head의 스크립트로 돌리면 같은 PR에서 무력화될 수 있으므로
#                           CI는 base ref의 tests/validate.sh 를 --only-author 로 실행해야 한다(tests/README.md 「T047 필수 조건」 —
#                           트리 검사는 head 스크립트의 전체 실행이 맡는다). SHA 입력의 diff는 merge-base ↔ HEAD(아래 「입력」).
#                           PR 이벤트에서 PR_AUTHOR 또는 PR_SENDER가 비면 FAIL(조용한 비활성 금지 — 둘의 메시지는 다르다. 둘 다 비면 둘 다 찍는다)
#                           한계: PR이 열리기 **전에** 봇이 그 브랜치에 넣은 커밋은 발신자 판정으로 보이지 않는다(브랜치 쓰기 제한
#                           ruleset — .github/ruleset-branches.json — 이 막는다). 봇이 push한 뒤 사람이 그 위에 다시 push하면 새 이벤트의
#                           발신자는 사람이다(사람이 봇의 커밋을 받아서 올린 것으로 본다)
#   7.1  WAVE               Application sync-wave = §sync-wave 단일 표(이름·경로 규약 포함)
#   7.2  WAVE-dir           표에 없는 platform/<component>/ 디렉터리 금지
#   7.3  WAVE-secrets-base  secrets/<ns>의 단일 소유·배달: (a) `secrets/` 아래와 배달자 자신(platform/secrets)을 base로
#                           가질 수 있는 kustomization은 platform/secrets/kustomization.yaml 하나뿐(절대·저장소 밖 경로는
#                           위치 판정 불가로 FAIL · 별칭으로 적은 항목은 풀어서 본다 · base 목록을 yq로 풀어 읽지 못하면 FAIL)
#                           · (b) `secrets/**` 파일의 ES와 같은 이름이 배달자 밖 소스에도 있으면 FAIL
#                           · (c) `secrets/**` 파일의 ES가 platform/secrets 렌더에 없으면 죽은 선언(kustomize 있을 때) ·
#                           (d) secrets/* 를 가리키는 Application 금지(multi-source 포함) + 배달자를 적용하는 Application 필요
#                           · (e) (T045 G4) 변환 키 금지 — 배달자 최상위 키 = {apiVersion,kind,resources}, secrets/** 의
#                           kustomization = 거기에 namespace 까지(그 밖의 키는 FAIL · YAML 맵으로 못 읽어도 FAIL)
#   7.4  APP-source         (T046 · 계약 §validate.yml 4 「(T046)」 둘째 줄) Application은 source를 덮어쓰지 않는다: `spec.source` 키 =
#                           {repoURL, targetRevision, path}뿐(kustomize·helm·directory·plugin 금지) · repoURL = 이 저장소 ·
#                           targetRevision = main(7.4 APP-source-ref) · `spec.sources`(multi-source) 금지(7.4 APP-source-multi)
#                           · `spec.sourceHydrator` 금지(7.4 APP-source-hydrator) · 최상위 `operation` 금지(7.4 APP-source-operation)
#                           · --root 트리(tests/·charts/ 제외)에
#                           `.argocd-source.yaml`·`.argocd-source-*.yaml` 파일 금지(7.4 APP-source-file).
#                           대상 = 7.1과 같은 파일 열거(clusters/**·bootstrap/root-app.yaml 등 모든 Application) + kustomize 렌더
#   8    LEAK               gitleaks 파일 스캔 — 스캔 대상 0개(빈 트리)면 FAIL
#   9.1  CSS-set            ClusterSecretStore 이름 집합 = 계약 5개 · 위치 platform/secret-stores/ · metadata.namespace 금지
#   9.2  CSS-auth           vault provider: serviceAccountRef.namespace(referent auth 금지)·audiences·mountPath·server/path/version
#                           · store ↔ SA/role 매핑 = 계약 §ClusterSecretStore 표
#   9.3  CSS-k8s            kubernetes provider: auth 키 1개(serviceAccount) · audiences 금지 · CRD 기본값 3필드 명시
#                           · remoteNamespace = 계약 표의 값(생략뿐 아니라 오기도 잡는다)
#   9.4  CSS-conditions     conditions = 정확히 1항목 · 그 키는 namespaces 하나 · namespaces 집합 = 계약 §ClusterSecretStore 표
#                           (vault-platform은 §네임스페이스 표에서 jt-dev·jt-prod를 뺀 12개로 기계 유도). 중복 ns 금지
#                           한계: 검사 9는 **선언된 값만** 본다 — 라이브 store의 status(reason=Valid 등)는 보지 않는다
#   10   REL                (T046) platform/reloader **렌더**(Reloader scoped 모드 — 계약 §validate.yml 4 「(T046)」 첫째 줄):
#   10.1 REL-clusterrbac    ClusterRole·ClusterRoleBinding 0
#   10.2 REL-args-exact     Deployment reloader(ns reloader) 첫 컨테이너 args == [--log-level=info, --namespaces=<REL_WATCH_NS + 릴리스 ns
#                           사전순 쉼표 목록>, --reload-strategy=annotations] — 원소 수·순서·값 **정확 일치**(집합 비교가 아니다: 값 없는
#                           플래그가 앞에 오면 pflag가 뒤 인자를 값으로 삼키고, 같은 플래그를 반복하면 --namespaces 목록이 합쳐진다).
#                           불일치 시 실제·기대 목록(JSON — 제어 문자도 이스케이프된다)과 단서('=' 없는 플래그 · 같은 플래그 반복 ·
#                           `$(` 치환 · cloudflared · --namespaces/--reload-strategy 부재)를 같은 코드로 찍는다
#   10.3 REL-kinds          렌더 전체의 kind별 개수 = REL_KINDS(ServiceAccount 1 · Deployment 1 · Role 5 · RoleBinding 5 = 12) · 그 밖의 kind 0
#   10.4 REL-rbac-ns        렌더 전체의 Role·RoleBinding(이름 무관) ns 집합 = REL_WATCH_NS + 릴리스 ns 정확 일치(kind마다 —
#                           모노레포 하네스 reloader-2와 같은 불변식)
#   10.4 REL-rbac-bind      모든 RoleBinding: roleRef.kind = Role · 그 이름의 Role이 같은 ns에 렌더됨 · subjects = 정확히
#                           [ServiceAccount reloader/reloader]
#   10.4 REL-rbac-rules     Role `reloader-role`이 감시 ns + 릴리스 ns마다 있고 그 rules가 서로 같다 · 어떤 Role에도 apiGroups·
#                           resources·verbs에 `*`가 없다
#   10.4 REL-image          렌더 전체에서 이미지 저장소가 `…/stakater/reloader`(태그·digest 무관)인 컨테이너 정확히 1개 =
#                           Deployment reloader/reloader의 containers[0] · 저장소 = REL_IMAGE_REPO · `command` 없음
#   10.0 REL-render         fail-closed: 렌더 없음(kustomize build 실패 — 차트의 `fail` 가드 포함) · Deployment 부재·중복 ·
#                           yq 추출 실패 · 저장소 루트에서 platform/reloader 부재. 부분 트리 픽스처에 platform/reloader가 없으면 대상 없음
#   10.0 REL-args           fail-closed: 같은 args에 제어 문자(개행·CR·탭 등)가 든 인자(10.2는 JSON으로 비교하므로 그대로 판정한다)
#   11   FMT                (T047 · 계약 §validate.yml 4 「(T047) 형식별 정책」) Argo가 읽을 수 있는 형식마다 검사 또는 금지:
#   11.0 FMT-alias          fail-closed: 문서를 yq explode(.)로 풀어 읽지 못했다(맵이 아닌 값을 가리키는 병합 키 등) · 풀었는데 최상위 items가
#                           별칭으로 남았다 — 목록 객체인지 판정할 수 없다. 11.1–11.4는 앵커·별칭·병합 키(<<)를 푼 문서로 판정한다(아래 YQ_DOCS 주석 —
#                           `items: *anchor`도 목록이다)
#   11.1 FMT-list           목록 객체 금지 — 문서의 kind가 List(items 유무 무관)이거나 최상위 items가 목록(시퀀스)이면 FAIL. 대상 = 파일
#                           열거(tests/·charts/ 제외)의 모든 YAML + kustomize 렌더. 계약 문면(<Kind>List + items)보다 넓은 것은 보강이다:
#                           Argo는 kind와 무관하게 최상위 items 목록을 풀어 원소를 적용한다(check_11_formats 머리 주석)
#   11.2 FMT-appset         kind: ApplicationSet(apiVersion argoproj.io/…) 금지 — 파일 + 렌더
#   11.3 FMT-dirsource      directory source 경로(7.4와 같은 Application 집합의 source path 중 kustomization 파일이 없는 디렉터리 —
#                           Argo가 렌더 없이 디렉터리째 읽는다): 바로 아래 심볼릭 링크 금지(파일 · 디렉터리 · 대상 없는 링크 — 파일 열거는 링크를
#                           세지 않는데 Argo는 저장소 안 링크를 따라 읽는다) · *.json·*.jsonnet·*.libsonnet 금지 · 하위 디렉터리 금지 ·
#                           절대 경로·저장소 밖 경로 FAIL(fail-closed) · 트리에 없는 경로는 건너뜀(부분 트리)
#   11.4 FMT-dirsource-kind directory source 경로 바로 아래 *.yaml·*.yml **일반 파일**(링크는 따라가지 않는다 — 11.3이 건다)의 모든 문서 =
#                           kind: Application(argoproj.io/…) — 빈 문서는 건너뛰고 kind 없는 문서는 FAIL(fail-closed). Application에 최상위 items
#                           목록이 있어도 FAIL(보강 — 11.1과 같은 이유). 렌더를 보는 검사(10 · 13)가 이 경로를 보지 않아도 되는 근거다
#   11.5 FMT-symlink        (계약 형식별 정책 「심볼릭 링크」 행) --root 트리 어디든(.git/ 제외 · 루트의 tests/ 포함) 심볼릭 링크 금지 — 파일 열거와
#                           kustomization 열거는 링크를 세지 않는데 Argo와 kustomize는 따라 읽는다(컴포넌트 디렉터리가 링크면 모든 검사의 시야 밖에서
#                           렌더된다): ① 작업 트리의 링크(find -type l — 파일 · 디렉터리 · 깨진 링크)마다 FAIL(트리를 다 훑지 못하면 fail-closed)
#                           ② --root가 git 작업 트리 안이면 인덱스(git ls-files -s)의 모드 120000마다 FAIL(Windows 체크아웃 core.symlinks=false는 링크를
#                           일반 파일로 푼다). git이 없거나 작업 트리가 아니거나 읽지 못하면 그 사실을 한 줄로 적고 ①로만 판정(①은 항상 돈다 · yq 없이 돈다)
#   12   HELM              (T047 · 계약 §validate.yml 4 「(T047) 차트 저장소 허용 목록」·「charts/」·「--enable-helm」)
#   12.1 HELM-repo          helmCharts[] 항목마다 (name, repo) = HELM_CHART_TABLE의 한 행(글자 단위 정확 일치 — 대소문자·끝의 '/' 포함) ·
#                           name·repo 필수(repo 없는 로컬 차트 금지). 대상 = 모든 kustomization + 그것들이 base로 끌어오는 로컬
#                           kustomization(파일 열거 밖 — tests/·charts/ 아래 — 도 포함. 같은 빌드에서 인플레이트되기 때문이다)
#   12.2 HELM-version       helmCharts[] 항목마다 version이 비어 있지 않다(값은 표로 고정하지 않는다)
#   12.3 HELM-legacy        kustomization 최상위 helmGlobals·helmChartInflationGenerator 금지 · generators·transformers가 부르는 파일(문서 안
#                           어디든 — kind: List로 감싼 것 · 별칭 포함)과 파일 열거의 YAML에 kind: HelmChartInflationGenerator 금지 · 그 파일을
#                           yq로 풀어 읽지 못하면 FAIL(fail-closed)
#                           12.1–12.3은 검사 1 **전에** 판정한다(helm_src_scan) — 걸린 kustomization과 그것을 base로 끌어오는 kustomization은
#                           검사 1이 렌더하지 않고 `1 KUST` FAIL로 남긴다(허용하지 않은 출처에서 차트를 받아 오지 않는다). 줄은 검사 12가 찍는다
#   12.4 HELM-argocd        helmCharts를 쓰는 kustomization이 있으면 bootstrap/argocd **렌더**의 ConfigMap argocd/argocd-cm
#                           data."kustomize.buildOptions"를 공백(Go strings.Fields와 같은 집합)으로 나눈 낱말 중 --enable-helm · --enable-helm=<값>이
#                           pflag로 읽어 참이다: 낱말을 차례로 읽어 마지막 값이 이기고(=<참값> 1·t·T·TRUE·true·True / =<거짓값>), 참·거짓 낱말이 아닌
#                           값이 하나라도 있으면 FAIL(pflag가 그 자리에서 멈춘다). 저장소 루트에서 bootstrap/argocd가 없으면 FAIL, 부분 트리(픽스처)
#                           에서는 대상 없음
#   12.5 HELM-chartsdir     이름이 charts인 디렉터리(.git · 루트 tests/ 제외)는 helmCharts를 쓰는 kustomization 바로 아래(인플레이트 캐시)에만.
#                           캐시 안(받은 차트의 하위 차트 charts/)은 보지 않는다 — 파일 열거와 7.4의 파일 찾기가 */charts/*를 통째로
#                           건너뛰므로 그 밖의 charts(예: pod 이름이 charts)는 모든 검사의 시야 밖이 된다. 캐시가 생기기 전후 결과가 같다
#   13   RBAC               (T047 · 계약 §validate.yml 4 「(T047) 권한 경계 — 문자열이 아니라 규칙 구조로 본다」) kustomize **렌더 전부**를 합친 RBAC
#                           객체(apiVersion rbac.authorization.k8s.io/… · kind Role·ClusterRole·RoleBinding·ClusterRoleBinding). 기준선 = RBAC_* 표
#                           (2026-09-29 main 82dd85e 실측). 렌더만 보면 되는 전제 = 11.4(directory source 경로의 문서는 Application뿐) · 11.5(링크 금지 —
#                           링크된 컴포넌트는 kustomization 열거 밖에서 렌더된다)
#   13.1 RBAC-token         토큰 발급 규칙(규칙 하나 안에서 apiGroups ∋ ""|* · verbs ∋ create|* · resources ∋ serviceaccounts/token|serviceaccounts/*|*|*/*|*/token)을
#                           가진 역할 = 기준선 둘: ① ClusterRole argocd-application-controller(이름만) ② Role external-secrets/eso-token-create(토큰 발급
#                           규칙 1개 · apiGroups·resources·verbs 목록 정확 일치 · resourceNames 집합 정확 일치). 같은 이름은 나타난 것마다 판정
#   13.2 RBAC-extref        어느 렌더에도 없는 ClusterRole을 가리키는 바인딩 = 기준선 둘(바인딩 kind·이름·대상 이름) · RoleBinding → Role은 같은 ns에
#                           렌더된 Role만 · ClusterRoleBinding → Role 금지 · roleRef.kind는 Role·ClusterRole만
#   13.3 RBAC-builtin-name  렌더된 ClusterRole의 이름이 cluster-admin·admin·edit·view이거나 system:으로 시작하면 FAIL(13.2의 "렌더에 있는가" 판별을 지킨다)
#   13.4 RBAC-subject       모든 바인딩의 주체 = kind ServiceAccount + name·namespace 비어 있지 않음(User·Group 금지) · subjects는 목록
#   13.5 RBAC-reloader-subject  주체 ServiceAccount reloader/reloader를 가진 바인딩은 platform/reloader 렌더에만(그 렌더 안의 장수·모양은 검사 10)
#   13.6 RBAC-aggregation   aggregationRule을 가진 ClusterRole 금지 · aggregate-to-* 라벨(값 무관)을 가진 ClusterRole = 기준선 다섯
#   13.0 RBAC-render        fail-closed: yq 추출 실패 · 추출 행의 모양 이상 · 렌더가 없는 kustomization(빌드 실패·건너뜀 — 합친 집합이 불완전) — 그룹 PASS
#                           줄을 찍지 않는다. "기준선의 것이 있는가"(완전성)는 --root가 저장소 루트일 때만 보고(13.0이 나면 보지 않는다), 부분 트리에
#                           RBAC 객체가 없으면 대상 없음
#
# 입력(환경변수 또는 인자):
#   --root <dir>            | VALIDATE_ROOT        검사 대상 트리(기본: 저장소 루트). 저장소 밖은 거부
#   --author <login>        | PR_AUTHOR            PR 작성자 로그인(비어 있으면 검사 6은 대상 없음 — 단, PR 이벤트면 FAIL)
#   --author-id <숫자>      | PR_AUTHOR_ID         PR 작성자 계정 ID(pull_request.user.id, 선택). 주어졌는데 숫자가 아니거나, PR_AUTHOR 없이
#                           ID만 있으면 6 AUTHOR-input FAIL
#   --sender <login>        | PR_SENDER            이벤트 발신자 로그인(sender.login — push한 쪽 · 다시 연 쪽). PR 이벤트면 필수(비면
#                           6 AUTHOR-input FAIL). PR 이벤트가 아니면 비어도 된다(작성자로만 판정 — PASS 줄에 드러난다). PR_AUTHOR 없이
#                           발신자만 있으면 6 AUTHOR-input FAIL
#   --sender-id <숫자>      | PR_SENDER_ID         이벤트 발신자 계정 ID(sender.id, 선택). 주어졌는데 숫자가 아니거나, PR_SENDER 없이 ID만
#                           있으면 6 AUTHOR-input FAIL
#   --changed-files <file>  | CHANGED_FILES        변경 파일 목록(줄 구분; 환경변수는 내용, 인자는 파일)
#   --diff <file>           | CHANGED_DIFF         unified diff 파일 경로
#   VALIDATE_BASE_SHA · VALIDATE_HEAD_SHA           위 둘 대신 git으로 계산(CI 권장): **merge-base(BASE, HEAD) ↔ HEAD**의 파일 목록과
#                           diff(두 점 diff가 아니다 — PR 브랜치가 main 끝보다 뒤처져 있어도 main 쪽 변경이 섞이지 않는다).
#                           우선순위: CHANGED_DIFF가 있으면 SHA는 쓰이지 않는다(diff = 그 파일, 파일 목록 = CHANGED_FILES). CHANGED_DIFF가
#                           없고 CHANGED_FILES만 있으면 파일 목록은 그 값을 쓰고 diff만 계산한다 — CI는 두 변수를 설정하지 않는다.
#                           두 값이 커밋으로 풀리지 않거나('-'로 시작 · 객체 없음 · 얕은 체크아웃) --root가 git 작업 트리가 아니거나
#                           공통 조상이 없거나 merge-base가 둘 이상이거나 git diff가 실패하면 6 AUTHOR-input FAIL(요약까지 찍고 exit 1).
#                           이 입력은 **봇 PR(작성자 또는 발신자가 봇)일 때만** 읽는다 — 사람 작성자 + 사람 발신자는 SHA를 보지 않고
#                           PASS다(잘못된 SHA여도)
#   --skip-tools            | VALIDATE_SKIP_TOOLS=1  없는 도구가 필요한 검사를 SKIP(로컬 부분 검증용; CI 기본은 fail-closed)
#   --only-author           | VALIDATE_ONLY_AUTHOR=1 (T047) 검사 6(작성자 검사)만 실행 — 도구 확인·파일 수집·다른 검사를 하지 않는다
#                           (쓰는 외부 명령: git · bash · coreutils의 dirname·tr — --changed-files 인자를 쓰면 cat, -h는 sed).
#                           CI는 base ref의 이 스크립트를 이 모드로 돌린다(tests/README.md 「T047 필수 조건」).
#                           머리의 `모드: --only-author — 작성자 검사만 실행`과 요약의 `결과(작성자 검사만 실행): …`로 드러난다 —
#                           이 모드의 exit 0은 전체 검사 통과가 아니다. VALIDATE_ONLY_AUTHOR는 0·1만 받고(그 밖의 값은 exit 2)
#                           빈 문자열은 0(꺼짐)으로 읽는다
#   VALIDATE_BOT_AUTHORS    봇 로그인 목록(쉼표 — 비교는 대소문자 무시). 기본 "jt-ci[bot],joshuatech-gitapp-1[bot]" — 이 기본값이 봇
#                           로그인 목록의 정본이다. 빈 값이면 기본값
#   VALIDATE_BOT_IDS        봇 계정 ID 목록(쉼표, 숫자만 — 아닌 원소가 있으면 exit 2). 기본 "323873425"(joshuatech-gitapp-1[bot]).
#                           빈 값이면 기본값
#   VALIDATE_K8S_VERSION    kubeconform -kubernetes-version (기본 master)
#   VALIDATE_KUSTOMIZE_FLAGS kustomize build 추가 플래그(예: --load-restrictor LoadRestrictionsNone)
#   VALIDATE_KUBECONFORM_CACHE kubeconform 스키마 캐시 디렉터리(기본 ${TMPDIR:-/tmp}/kubeconform-cache — 저장소 밖 임시 경로)
#   GITHUB_EVENT_NAME=pull_request|pull_request_target | VALIDATE_REQUIRE_AUTHOR=1   PR_AUTHOR 또는 PR_SENDER가 비어 있으면 검사 6 FAIL
#
# 원칙: --root 트리(와 명시적으로 넘긴 입력 파일) 밖을 읽거나 쓰지 않는다(예외: kubeconform 스키마 캐시만 저장소 밖
#       임시 경로에 둔다). 스크립트가 직접 임시 파일을 만들지 않는다(파이프·변수만) — 단, 검사 1의 kustomize --enable-helm
#       인플레이트가 <kustomization>/charts/ 아래에 차트를 풀어 둔다(빌드 산출물 · .gitignore 대상). 자격·비밀을 요구하지 않는다.
#       결과는 [PASS]/[FAIL]/[WARN]/[SKIP] 한 줄씩이며 FAIL이 하나라도 있으면 exit 1(SKIP은 exit에 영향 없음 —
#       단, 요약에 "불완전"으로 표시).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

ROOT="${VALIDATE_ROOT:-$REPO_ROOT}"
PR_AUTHOR="${PR_AUTHOR:-}"
PR_AUTHOR_ID="${PR_AUTHOR_ID:-}"
PR_SENDER="${PR_SENDER:-}"
PR_SENDER_ID="${PR_SENDER_ID:-}"
CHANGED_FILES="${CHANGED_FILES:-}"
CHANGED_DIFF="${CHANGED_DIFF:-}"
SKIP_TOOLS="${VALIDATE_SKIP_TOOLS:-0}"
BOT_AUTHORS="${VALIDATE_BOT_AUTHORS:-jt-ci[bot],joshuatech-gitapp-1[bot]}"
BOT_IDS="${VALIDATE_BOT_IDS:-323873425}"
K8S_VERSION="${VALIDATE_K8S_VERSION:-master}"
KUSTOMIZE_FLAGS="${VALIDATE_KUSTOMIZE_FLAGS:-}"
BASE_SHA="${VALIDATE_BASE_SHA:-}"
HEAD_SHA="${VALIDATE_HEAD_SHA:-}"
KUBECONFORM_CACHE="${VALIDATE_KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-cache}"
REQUIRE_AUTHOR="${VALIDATE_REQUIRE_AUTHOR:-0}"
GH_EVENT="${GITHUB_EVENT_NAME:-}"
ONLY_AUTHOR="${VALIDATE_ONLY_AUTHOR:-0}"

usage() {
  # 머리 주석 전체(2행 ~ 닫는 `# ====` 줄). 줄 번호를 박지 않는다 — 검사를 추가해도 잘리지 않게.
  sed -n '2,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --author) PR_AUTHOR="$2"; shift 2 ;;
    --author-id) PR_AUTHOR_ID="$2"; shift 2 ;;
    --sender) PR_SENDER="$2"; shift 2 ;;
    --sender-id) PR_SENDER_ID="$2"; shift 2 ;;
    --changed-files) CHANGED_FILES="$(cat "$2")"; shift 2 ;;
    --diff) CHANGED_DIFF="$2"; shift 2 ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    --only-author) ONLY_AUTHOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
# 모드 스위치는 값이 모호하면 거부한다 — 'true' 등을 조용히 전체 모드로 읽지 않는다
case "$ONLY_AUTHOR" in
  0|1) ;;
  *) printf 'error: VALIDATE_ONLY_AUTHOR는 0 또는 1이어야 한다: %s\n' "$ONLY_AUTHOR" >&2; exit 2 ;;
esac
# 봇 계정 ID 목록(검사 6)은 숫자만 받는다 — 틀린 원소가 조용히 "그 ID는 봇 아님"으로 읽히지 않게 인자 오류로 거부한다
IFS=',' read -r -a BOT_ID_LIST <<< "$BOT_IDS"
for _id in "${BOT_ID_LIST[@]}"; do
  [[ $_id =~ ^[0-9]+$ ]] || { printf "error: VALIDATE_BOT_IDS의 원소는 숫자여야 한다: '%s' (목록 '%s')\n" "$_id" "$BOT_IDS" >&2; exit 2; }
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
secret-stores 15 external-secrets
secrets 18 -
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
allow-apiserver-webhook cert-manager,external-secrets,cnpg-system,vault EXCLUSIVE
deny-imds kube-system EXCLUSIVE
allow-imds vault EXCLUSIVE
'

# network-policy.md §외부 egress 규칙 형식: except 4개
EXCEPT_REQUIRED='169.254.169.254/32 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
IMDS_CIDR='169.254.169.254/32'

# network-policy.md §정책 세트 `allow-apiserver-webhook` 행 + §허용 매트릭스(노드 IP 출발 행)의 출발 주소 2개.
# 두 값은 platform/policies/policies-common.yaml 머리의 「상수 ①·②」와 같은 값이다:
#   ① 노드 A private IP/32            — 노드 A 호스트가 주 NIC로 나갈 때의 주소
#   ② 노드 A flannel 터널 장치 주소/32 — API 서버가 **다른 노드의** 파드 IP로 직접 dial할 때의 출발 IP
#      (= 노드 A `.spec.podCIDR`의 네트워크 주소. wireguard 백엔드의 소스 선택 결과 —
#       계약 §정책 세트의 "이 정책의 두 행은 메커니즘이 다르다" 항)
# 노드 재이미지·재조인으로 flannel 리스나 private IP가 바뀌면 **정책·이 두 상수·픽스처를 한 PR에서 함께** 바꾼다
# (전체 목록은 tests/README.md 규칙 — 계약에는 값이 없다).
# 라이브 쪽 대조는 모노레포 하네스 np-set-5가 노드 객체(InternalIP · `.spec.podCIDR`)에서 유도해 본다 —
# 이 스크립트는 저장소 트리만 보므로 값을 상수로 적는다(두 값은 이미 platform/policies/ 매니페스트에 공개돼 있다).
NODE_A_PRIVATE_CIDR='10.0.7.78/32'
NODE_A_FLANNEL_CIDR='10.42.0.0/32'

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

# `allow-apiserver-webhook` 4장: <ns> <위 PORT_TABLE의 출처 키> <허용 출발 집합>.
# 포트 숫자는 PORT_TABLE 한 곳에만 둔다(중복 기재 금지) — 여기서는 출처 키로 그 행을 가리킨다.
#   flannel = { 노드 A private/32, 노드 A flannel/32 } — admission webhook(API 서버 → 파드 IP 직접 dial)
#   private = { 노드 A private/32 }                     — vault 8200은 webhook이 아니라 port-forward 도착 경로다
#                                                         (계약 §정책 세트의 `vault` 8200 행 각주)
WEBHOOK_SRC_TABLE='
cert-manager cert-manager-webhook flannel
external-secrets eso-webhook flannel
cnpg-system cnpg-webhook flannel
vault vault private
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

# gitops-repo.md §ClusterSecretStore 5개 표 + §이름·인증 규약(검사 9).
#   <store 이름> <provider> <인증 주체 SA 이름 = vault role 이름>
# 5.6의 노드 주소와 달리 이 값들은 **바뀌는 런타임 값이 아니라 계약 문면**이다(계약을 고칠 때만 함께 바꾼다).
# 계약이 정본, 이 블록이 유일한 코드 사본 — README·주석에 다시 적지 않는다.
CSS_TABLE='
vault-platform vault eso-platform
vault-dev vault eso-dev
vault-prod vault eso-prod
vault-data vault eso-data
k8s-data-ca kubernetes eso-ca-reader
'
CSS_SA_NS='external-secrets'                  # 인증 주체 SA가 사는 ns(계약 §ClusterSecretStore 표 열 제목)
CSS_VAULT_SERVER='http://vault.vault.svc:8200' # T044 `global.tlsDisable: true` — 평문 8200
CSS_VAULT_PATH='kv'                            # kv v2 마운트 경로(infra/vault/main.tf)
CSS_VAULT_VERSION='v2'
CSS_VAULT_MOUNT='kubernetes'                   # auth 마운트 경로(infra/vault/main.tf)
CSS_VAULT_AUDIENCE='vault'                     # Vault role `audience`(infra/vault/roles.tf) — 계약은 audiences: [vault]
CSS_K8S_REMOTE_NS='data'                       # k8s-data-ca가 읽는 원본 ns(계약 §ClusterSecretStore 표 `remoteNamespace: data`)

# 같은 표의 `conditions.namespaces` 열(참조 허용 ns): <store 이름> <ns 목록(쉼표)>.
# `vault-platform`은 여기 적지 않는다 — 계약 문면이 "network-policy.md 표에서 jt-dev·jt-prod 제외"이므로
# 아래 NS_TABLE에서 **기계 유도**한다(같은 목록을 두 곳에 두면 한쪽만 고쳐질 수 있다).
CSS_COND_TABLE='
vault-dev jt-dev
vault-prod jt-prod
vault-data data,identity
k8s-data-ca identity,jt-dev,jt-prod
'
CSS_COND_PLATFORM_EXCLUDE='jt-dev jt-prod'

# 검사 10 — gitops-repo.md §네임스페이스 `platform/reloader/` 항목 「(T046) scoped 모드」의 코드 사본.
#   REL_WATCH_NS = 계약의 감시 ns 목록(`reloader.namespaces`). 릴리스 ns `reloader`는 차트가 자동 포함하므로 여기 적지 않고
#   REL_RELEASE_NS로 더한다. `cloudflared`가 없는 것은 의도다(터널 커넥터는 수동 1개씩 교체 — T045 G4).
#   새 소비자 ns는 **계약 목록 먼저** → platform/reloader values → 이 줄 순서로 늘린다(platform/reloader/README.md §0).
#   계약이 정본, 이 블록이 유일한 코드 사본이다 — README·주석의 목록은 설명이지 대조 기준이 아니다.
REL_DIR='platform/reloader'
REL_DEPLOY='reloader'          # fullnameOverride — 모노레포 하네스 reloader-1이 같은 이름을 본다
REL_RELEASE_NS='reloader'      # helmCharts[].namespace = 릴리스 ns
REL_SA='reloader'              # 차트 ServiceAccount(fullnameOverride) — 10.4 REL-rbac-bind가 요구하는 유일한 RoleBinding 주체
REL_WATCH_NS='identity jt-dev jt-prod'
REL_STRATEGY='annotations'
REL_LOG_LEVEL='info'           # 차트 2.2.16 기본 `reloader.logLevel` — 10.2의 첫 기대 인자
# 10.2 REL-args-exact의 기대 목록 = [--log-level=$REL_LOG_LEVEL, --namespaces=<목록>, --reload-strategy=$REL_STRATEGY].
#   <목록>은 REL_WATCH_NS + REL_RELEASE_NS를 **사전순**(LC_ALL=C)으로 중복 없이 쉼표로 잇는다 — 차트 헬퍼가 `uniq | sortAlpha`로
#   만든 인자와 같은 모양이다. check_10_reloader가 여기서 유도한다(목록을 두 번 적지 않는다).
# 10.3 REL-kinds — 렌더 전체의 kind별 개수(차트 12 = ServiceAccount 1 · Deployment 1 · Role 5 · RoleBinding 5). 그 밖의 kind는
#   0이어야 한다. Role·RoleBinding 5 = 감시 ns 3 + 릴리스 ns 1의 `reloader-role(-binding)` + 릴리스 ns의
#   `reloader-metadata-role(-binding)`이다 — 감시 ns를 하나 늘리면 둘 다 +1(platform/reloader/README.md §0).
REL_KINDS='ServiceAccount:1 Deployment:1 Role:5 RoleBinding:5'
REL_ROLE='reloader-role'       # 10.4 REL-rbac-rules: 차트가 감시 ns + 릴리스 ns마다 만드는 Role 이름
# 10.4 REL-image: 렌더에서 "Reloader 컨테이너"를 찾는 저장소 패턴(태그·digest를 뗀 뒤 비교 — ghcr.io·Docker Hub 등 레지스트리 무관)과,
#   찾은 1개가 가져야 할 저장소(차트 2.2.16 기본 `image.repository`). 패턴이 넓은 것은 의도다 — 다른 레지스트리의 같은 이미지로
#   띄운 두 번째 Reloader도 세어야 한다.
REL_IMAGE_REPO='ghcr.io/stakater/reloader'
REL_IMAGE_ANY_RE='(^|/)stakater/reloader$'

# 검사 7.3 — `secrets/<ns>/`의 유일한 배달자(설계 D3 = B · 조건 2). 이 파일 하나만 `secrets/` 아래를 base로 가질 수 있고,
#   모든 `secrets/<ns>/`는 이 파일에 포함돼야 한다(포함되지 않으면 어떤 Application도 적용하지 않는 죽은 선언이다).
#   `secrets/`를 가리키는 Application은 만들 수 없다(7.1의 `platform-<comp>` ↔ `platform/<comp>` 규약) — 그래서 배달자가 있다.
SECRETS_OWNER_KUST='platform/secrets/kustomization.yaml'
SECRETS_OWNER_DIR='platform/secrets'
# 검사 7.3 (e) — 계약 §validate.yml 4 「(T045 G4) 배달자는 base를 묶기만 한다」의 허용 최상위 키.
#   배달자는 `{apiVersion, kind, resources}`뿐, `secrets/<ns>/`는 거기에 `namespace`까지다.
#   변환 키(`patches`·`replacements`·`transformers`·`namePrefix`·`helmCharts` …)가 있으면 원본 파일은 그대로인 채
#   **Argo가 실제로 적용하는 렌더에서만** store·`remoteRef`·`creationPolicy`가 바뀐다(그 렌더에 터널 자격이 있다).
SECRETS_OWNER_KEYS='["apiVersion","kind","resources"]'
SECRETS_NS_KEYS='["apiVersion","kind","resources","namespace"]'
SECRETS_SRC_DIR='secrets'

# 검사 7.4 — 계약 §validate.yml 4 「(T046) Application은 source를 덮어쓰지 않는다」의 코드 사본.
#   Application 수준 오버라이드(`spec.source.kustomize.patches` · `helm.values` 등)와 다른 리비전은 **Argo가 적용하는 렌더를
#   validate가 빌드한 렌더와 다르게** 만든다 — 렌더를 보는 검사(3 · 5.6 · 9 · 10)가 한꺼번에 무력해진다(2026-09-28 검증 V-A2).
#   `spec.source` 밖의 세 경로(`.argocd-source*.yaml` 파일 · `spec.sourceHydrator` · 최상위 `operation`)도 같은 검사가 막는다(재검증
#   RB-1 · DV-1). **모든 우회 경로를 덮는다고 주장하지 않는다**(전수 열거는 T047). 사각은
#   check_7_app_source 머리 주석 「보지 않는 것」. 새 차트 저장소를 source로 직접 쓰는 컴포넌트가 생기면 계약 그 줄을 먼저 고친다.
APP_REPO_URL='https://github.com/joshua92y/platform-gitops.git'
APP_TARGET_REV='main'
APP_SOURCE_KEYS='path,repoURL,targetRevision'   # 허용 키 집합(사전순 — yq `keys | sort | join(",")`의 모양)

# 검사 12 — 계약 §validate.yml 4 「(T047) 차트 저장소 허용 목록」의 코드 사본: <차트 name> <repo>.
#   kustomize helmCharts 인플레이트는 AppProject sourceRepos의 통제 밖이라(Application source는 이 저장소뿐이다) 이 표가 차트 출처의
#   유일한 통제다. 비교는 (name, repo) 쌍의 글자 단위 정확 일치(대소문자·끝의 '/' 포함). 새 차트는 계약 표에 행을 더하는 계약 변경으로
#   시작하고 이 표에 같은 행을 더한다. 계약 표의 "쓰는 곳" 열은 옮기지 않는다 — 검사하지 않는다(같은 차트를 다른 컴포넌트가 써도 된다 ·
#   실제 사용처는 12.1 PASS 줄이 적는다). version 값도 표로 고정하지 않는다(차트 올림은 계약 변경이 아니다 — 12.2는 있는지만 본다).
#   계약이 정본, 이 블록이 유일한 코드 사본이다.
HELM_CHART_TABLE='
cert-manager oci://quay.io/jetstack/charts
external-secrets https://charts.external-secrets.io
reloader https://stakater.github.io/stakater-charts
vault https://helm.releases.hashicorp.com
cloudnative-pg https://cloudnative-pg.github.io/charts
plugin-barman-cloud https://cloudnative-pg.github.io/charts
'
# 12.4 — Argo CD 설정이 사는 kustomization 디렉터리, 그 렌더의 ConfigMap(ns/이름)과 data 키, 그 값에 있어야 할 낱말.
#   yq 식(YQ_ARGOCD_CM)이 strenv로 읽으므로 export한다.
HELM_ARGOCD_DIR='bootstrap/argocd'
export HELM_ARGOCD_CM_NS='argocd' HELM_ARGOCD_CM='argocd-cm' HELM_ARGOCD_KEY='kustomize.buildOptions' HELM_ARGOCD_FLAG='--enable-helm'
# 12.4 — 낱말 하나(Go 정규식): Argo CD가 값을 나누는 strings.Fields의 공백(unicode.IsSpace — \t \n \v \f \r 공백 U+0085 U+00A0 U+1680 U+2000–U+200A
#   U+2028 U+2029 U+202F U+205F U+3000)이 아닌 글자의 연속. RE2의 \s는 [\t\n\f\r ]뿐이라 NBSP 등으로 붙여 쓴 `--enable-helm=false`를 한 낱말 안에 숨긴다.
#   작은따옴표 안이므로 역슬래시는 글자 그대로 yq(strenv — 이스케이프를 다시 풀지 않는다)를 거쳐 정규식에 간다
export HELM_ARGOCD_WORD_RE='[^\t\n\v\f\r \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]+'
# 12.4 — pflag가 불리언 플래그의 `=<값>`을 읽는 strconv.ParseBool의 참·거짓 낱말(Go 표준 라이브러리 — 이 밖의 값은 오류로 인자 해석이 멈춘다)
HELM_BOOL_TRUE='1 t T TRUE true True'
HELM_BOOL_FALSE='0 f F FALSE false False'

# 검사 13 — 계약 §validate.yml 4 「(T047) 권한 경계 — 문자열이 아니라 규칙 구조로 본다」의 코드 사본(기준선 = 2026-09-29 main 82dd85e 실측).
#   계약이 정본, 이 블록이 유일한 코드 사본이다(README·주석의 목록은 설명이지 대조 기준이 아니다). 기준선을 바꾸는 PR은 계약 문장부터 고친다.
# 13.1 토큰 발급 규칙의 정의 — 계약 첫째 항목 「`apiGroups`에 `""` 또는 `*`, `verbs`에 `create` 또는 `*`, `resources`에 `serviceaccounts/token` ·
#   `*` · `*/token` 중 하나가 든 규칙」(Kubernetes RBAC의 ResourceMatches는 `*`와 `*/<subresource>`만 와일드카드로 읽는다 — `*/token`은 2026-09-30
#   계약에 더해졌다). 초판에 있던 `serviceaccounts/*` · `*/*`는 아무것도 뜻하지 않는 문자열이지만 계약대로 엄격한 쪽으로 그것도 잡는다(목록에 둔다).
#   규칙 **하나 안에서** 세 목록이 각각 이 집합과 겹치면 토큰 발급 규칙이다(YQ_RBAC_TOKEN_RULE). yq가 env()로 읽으므로 JSON 목록으로 export한다.
export RBAC_TOKEN_GROUPS='["","*"]' RBAC_TOKEN_VERBS='["create","*"]' RBAC_TOKEN_RESOURCES='["serviceaccounts/token","serviceaccounts/*","*","*/*","*/token"]'
# 13.1 토큰 발급 규칙을 가져도 되는 역할 — 같은 항목 「정확히 둘이다 — ① … ② …」: <kind> <ns(클러스터 범위는 -)> <이름> <모양>.
#   모양 any = 이름만 본다(① — 와일드카드 규칙 · GitOps 컨트롤러의 고유 권한, 받아들인 위험) · fixed = 토큰 발급 규칙이 하나이고 그 규칙이 아래
#   RBAC_TOKEN_FIXED_*와 같다(②). ClusterRole은 ns와 무관하게 이름으로 맞춘다
RBAC_TOKEN_TABLE='
ClusterRole - argocd-application-controller any
Role external-secrets eso-token-create fixed
'
# ②의 모양 — 같은 항목 「`apiGroups: [""]` · `resources: [serviceaccounts/token]` · `verbs: [create]` · `resourceNames` = eso-platform·eso-dev·eso-prod·
#   eso-data·eso-ca-reader(집합 정확 일치)」. 앞의 셋은 yq `to_json(0)`의 모양(목록 정확 일치), 넷째는 공백 구분 집합(순서·중복 무관)
RBAC_TOKEN_FIXED_GROUPS='[""]'
RBAC_TOKEN_FIXED_RESOURCES='["serviceaccounts/token"]'
RBAC_TOKEN_FIXED_VERBS='["create"]'
RBAC_TOKEN_FIXED_NAMES='eso-platform eso-dev eso-prod eso-data eso-ca-reader'
# 13.2 어느 렌더에도 없는 ClusterRole(내장 역할 등)을 가리켜도 되는 바인딩 — 계약 둘째 항목 「정확히 둘이다」: <바인딩 kind> <바인딩 이름> <roleRef.name>
RBAC_EXTREF_TABLE='
ClusterRoleBinding agent-view-view view
ClusterRoleBinding vault-server-binding system:auth-delegator
'
# 13.3 내장 역할의 이름 — 계약 셋째 항목 「`cluster-admin` · `admin` · `edit` · `view`이거나 `system:`으로 시작하면 실패」
RBAC_BUILTIN_NAMES='cluster-admin admin edit view'
RBAC_BUILTIN_PREFIX='system:'
# 13.6 aggregate-to-* 라벨을 가져도 되는 ClusterRole — 계약 여섯째 항목 「정확히 다섯이다」(라벨 접두 rbac.authorization.k8s.io/aggregate-to-는 YQ_RBAC 안)
RBAC_AGG_TABLE='
cert-manager-cluster-view
cert-manager-edit
cert-manager-view
external-secrets-edit
external-secrets-view
'

# 검사 4a(T047) — 계약 §이미지·승격 「(T047) 항목마다 `name`과 `digest`가 있어야 하고, 키는 `{name, newName, digest}` 밖에 없어야 한다」의 코드 사본.
#   계약이 정본, 이 줄이 유일한 코드 사본이다(메시지의 목록도 여기서 만든다). yq가 env()로 읽으므로 JSON 목록으로 export한다(YQ_IMAGES의 E 행)
export IMG_ENTRY_KEYS='["name","newName","digest"]'

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
# 9 전용: 원본 파일(platform/secret-stores/<file>)과 kustomize 렌더 소스(SRC_PATH = platform/secret-stores)를 모두 잡는다
RE_LOC_SECRET_STORES='^platform/secret-stores(/|$)'
# 5.6 전용: 원본 파일(platform/policies/<file>)과 kustomize 렌더 소스(SRC_PATH = platform/policies)를 모두 잡는다
RE_LOC_POLICIES_ALL='^platform/policies(/|$)'
RE_CIDR='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
RE_DIGEST='^sha256:[0-9a-f]{64}$'
RE_ARGO_API='^argoproj\.io/'   # 11.2 · 11.4 — Argo CD의 API 그룹(점까지 글자 그대로)
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

# ROOT 기준 경로 정규화(문자열 연산만 — 대상이 존재하지 않아도 동작한다). ROOT 밖으로 나가면 빈 문자열.
#   kustomization의 base 항목(`../../secrets/<ns>` 같은 상대 경로)을 위치 판정에 쓰기 위한 것이다(검사 7.3).
norm_rel() { # <기준 디렉터리(ROOT 기준, 빈 문자열 = ROOT)> <항목>
  local base=$1 entry=$2 p seg
  local -a out=() segs=()
  if [[ $entry == /* ]]; then p=${entry#/}; else p="${base:+$base/}$entry"; fi
  IFS='/' read -r -a segs <<< "$p"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|'.') ;;
      '..')
        [[ ${#out[@]} -gt 0 ]] || return 0      # ROOT 위로 올라가는 경로 — 빈 문자열
        out=("${out[@]:0:$((${#out[@]} - 1))}") ;;
      *) out+=("$seg") ;;
    esac
  done
  local IFS='/'
  printf '%s' "${out[*]}"
}

# 디렉터리의 kustomization 파일(절대 경로) — kustomize와 Argo CD가 kustomization으로 보는 이름 3개(argo-cd v3.5.2 util/kustomize
#   KustomizationNames) 중 첫 번째. 없으면 1(검사 11.3 directory source 판정 · 12.x base 추적 · 12.5 캐시 자리 판정)
kust_file_in() { # <디렉터리(절대 경로)>
  local kn
  for kn in kustomization.yaml kustomization.yml Kustomization; do
    if [[ -f "$1/$kn" ]]; then printf '%s' "$1/$kn"; return 0; fi
  done
  return 1
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
# 값 안에 쉼표가 들어갈 수 있는 목록(5.6의 cidr)은 RS(0x1e)로 잇는다 — 쉼표 join은 값 하나와 목록을 구분하지 못한다
export YQ_SEP2=$'\x1e'
# 앵커·별칭·병합 키(<<) — (T047 G4 리뷰 A1 · 계약 형식별 정책 「목록 객체」 행 「YAML 별칭(`items: *anchor`)으로 참조한 목록도 풀어서 본다」)
#   yq v4.53.6은 별칭 노드의 종류를 `alias`(태그는 빈 값)로 보고하고, has()는 병합으로 들어온 키를 보지 못하며, `.kind == "…"` 비교는 별칭을 문자열로
#   보지 않는다. Argo의 디코더(sigs.k8s.io/yaml — go-yaml v2)와 kustomize는 풀어서 읽는다 — `items: *seq`인 문서는 Argo에게 목록 객체다(2026-09-30
#   리뷰가 실행으로 재현: 11.1 · 11.4를 지나 안의 Namespace가 적용된다). 그래서 형식 판정과 그 판정이 받아들인 문서를 다시 보는 식은 **판정 전에
#   explode(.)로 푼다**: YQ_DOCS(11 · 12.3) · YQ_APP(2 · 7.1) · YQ_APP_SRC(7.4) · YQ_APP_PATHS(7.3 ⓓ · 11.3) · YQ_KUST_BASES(7.3 ⓐ) ·
#   YQ_HELM_SCAN(12.1–12.3) · YQ_LEGACY_GEN(12.3). 11.4가 풀어서 `kind: *k` Application을 받아들이면 풀지 않는 2 · 7.x는 그 문서를 통째로 지나치므로
#   (`select(.kind == "Application")`이 별칭을 보지 못한다) 같은 문서를 보는 식을 함께 푼다. 병합 키의 우선순위는 yq 기본값
#   (--yaml-fix-merge-anchor-to-spec=false — 명시 키와 병합은 문서 순서로 뒤의 것이 이기고, 병합 목록 `<<: [*a, *b]`는 앞 원소가 이긴다)이 go-yaml v2와
#   같다(2026-09-30 실측 4경우 · 풀지 않고 읽으면 병합 목록에서 어긋난다 — 픽스처 fmt/list/misc/merge-order-carrier.yaml이 이 의미를 고정한다).
#   풀지 못하는 문서(맵이 아닌 값을 가리키는 병합 키 등 — go-yaml v2 · kustomize도 거부한다)는 yq가 실패하고, 그 식을 쓰는 검사가 fail-closed로 FAIL한다
#   (11.0 FMT-alias · 7.3 ⓐ · 12.1 · 12.3 · 그 밖은 collect_rows의 "yq 추출 실패"). kustomize 렌더에는 별칭이 없다(새로 직렬화한 출력) — 파일 쪽 문제다.
#   풀지 않는 식(YQ_ES 등 렌더로도 보는 검사 · YQ_IMAGES — 4a는 별칭 항목을 FAIL로 둔다)은 그대로다.

# shellcheck disable=SC2016  # 아래 $ps·$ns·$n·$r·$c 는 yq 변수이지 셸 변수가 아니다
# 주의: yq v4는 없는 경로를 traverse하면 그 키를 만들어 버린다(`.extract.key` 한 번이면 find 항목에도 `extract`가 생겨
# 뒤따르는 `select(.extract == null)`이 0이 된다). dataFrom 판정은 traverse 대신 has("extract")로만 한다.
YQ_ES='select(.kind == "ExternalSecret") | [ (.apiVersion // "-"), (.metadata.namespace // "-"), (.metadata.name // "-"), (.spec.secretStoreRef.kind // "-"), (.spec.secretStoreRef.name // "-"), ((.spec.data // []) | map((.remoteRef.key // "-") + "=" + (.remoteRef.property // "-")) | join(",")), ((.spec.dataFrom // []) | map(select(has("extract")) | .extract.key | select(. != null)) | join(",")), ((.spec.dataFrom // []) | map(select(has("extract") | not)) | length | tostring), ((((.spec.data // []) | map(select(.sourceRef != null)) | length) + ((.spec.dataFrom // []) | map(select(.sourceRef != null)) | length)) | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
# (yq v4의 `,` 합집합은 수집자 안에서 두 번째 가지를 잃으므로 배열 셋을 `+`로 이어 붙인다)
YQ_WL='select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob") | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // {}) as $ps | (($ps.containers // []) + ($ps.initContainers // [])) as $cs | [ .kind, (.metadata.namespace // "-"), (.metadata.name // "-"), ($ps.automountServiceAccountToken | tostring), (([ $cs[] | (.envFrom // [])[] | .secretRef.name | select(. != null) ] + [ $cs[] | (.env // [])[] | .valueFrom.secretKeyRef.name | select(. != null) ] + [ ($ps.volumes // [])[] | .secret.secretName | select(. != null) ]) | join(",")) ] | join(strenv(YQ_SEP))'
YQ_APP='explode(.) | select(.kind == "Application" and ((.apiVersion // "") | test("^argoproj.io/"))) | [ (.metadata.name // "-"), ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-") | tostring), (.spec.source.path // ((.spec.sources // [])[0].path // "-")), ((.spec.syncPolicy.syncOptions // []) | join(";")) ] | join(strenv(YQ_SEP))'
YQ_NS='select(.kind == "Namespace") | (.metadata.name // "-")'
YQ_NP='select(.kind == "NetworkPolicy") | [ (.metadata.namespace // "-"), (.metadata.name // "-") ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_EGRESS_IPBLOCK='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.egress // [])[] as $r | ($r.to // [])[] | select(.ipBlock != null) | .ipBlock | [ $ns, $n, (.cidr // "-"), ((.except // []) | join(",")), (($r.ports // []) | map((.port // "-") | tostring) | join(",")) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_INGRESS_PORTS='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.ingress // [])[] | (.ports // [])[] | [ $ns, $n, ((.port // "-") | tostring) ] | join(strenv(YQ_SEP))'
YQ_NP_WEBHOOK_POL='select(.kind == "NetworkPolicy" and .metadata.name == "allow-apiserver-webhook") | (.metadata.namespace // "-")'
# ingress 규칙 1개 = 1행(10열): ns · 규칙 번호(1-기반) · ports[].port 목록(쉼표) · endPort를 가진 port 항목 수 ·
#   **순수** ipBlock peer의 cidr 목록(RS 구분 — 값에 쉼표가 들어가도 값 단위로 비교하기 위해) ·
#   순수 ipBlock이 아닌 peer 수(podSelector·namespaceSelector, 그리고 ipBlock과 selector를 **한 peer에** 섞은 항목) ·
#   except를 가진 ipBlock 수 · protocol 집합(생략은 TCP) · 정수가 아닌 port 수(문자열·named port) ·
#   **순수 ipBlock peer 수**(위 cidr 목록의 원소 수와 달라지면 빈 문자열이거나 값에 RS가 들어간 것이다).
#   "순수"는 `has("ipBlock") and (keys | length) == 1` — API 서버는 ipBlock과 다른 peer를 한 항목에 쓰면 거절한다.
#   (`.ipBlock.cidr` traverse는 has("ipBlock")로 거른 뒤에만 한다 — yq v4가 없는 경로를 만들어 버리는 것을 피한다)
# shellcheck disable=SC2016
YQ_NP_WEBHOOK_RULE='select(.kind == "NetworkPolicy" and .metadata.name == "allow-apiserver-webhook") | (.metadata.namespace // "-") as $ns | (.spec.ingress // []) | to_entries[] | (.value.from // []) as $from | (.value.ports // []) as $ports | ($from | map(select(has("ipBlock") and ((keys | length) == 1)))) as $pure | [ $ns, ((.key + 1) | tostring), ($ports | map((.port // "-") | tostring) | join(",")), ($ports | map(select(has("endPort"))) | length | tostring), ($pure | map(.ipBlock.cidr // "-") | join(strenv(YQ_SEP2))), (($from | length) - ($pure | length) | tostring), ($from | map(select(has("ipBlock")) | select(.ipBlock | has("except"))) | length | tostring), ($ports | map(.protocol // "TCP") | unique | join(",")), ($ports | map(select((.port | tag) != "!!int")) | length | tostring), ($pure | length | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_NP_EGRESS_PORTS='select(.kind == "NetworkPolicy") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.egress // [])[] | (.ports // [])[] | [ $ns, $n, ((.port // "-") | tostring) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_LR='select(.kind == "LimitRange") | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | (.spec.limits // [])[] | [ $ns, $n, (.type // "-"), ((.default.cpu // "-") | tostring), ((.max.cpu // "-") | tostring) ] | join(strenv(YQ_SEP))'
YQ_POLICY_KINDS='select(.kind == "Namespace" or .kind == "NetworkPolicy" or .kind == "ResourceQuota" or .kind == "LimitRange") | .kind + "/" + (.metadata.name // "-")'
# 검사 4a — kustomization 1개 = yq 1번. 행의 첫 필드가 종류다(문서마다 D → E… → O 순서로 나온다):
#   D  문서: 노드 종류 · 태그 · images의 노드 종류 · 태그(images 키가 없거나 문서가 맵이 아니면 none)
#   E  images가 목록일 때 항목마다: 번호(0-기반) · 항목 노드 종류 · 태그 · name 유무 · name 태그 · digest 유무 · digest 태그 · digest(JSON) · newTag 유무 ·
#      IMG_ENTRY_KEYS 밖 키(JSON — newTag 포함) · 같은 것(newTag 제외) · 중복 키(JSON) · 그리고 O 행과 같은 방법으로 읽은 name · newTag · digest
#      (4a IMG-newTag가 그 항목에 이미 찍었는지를 셸이 판단한다 — 같은 결함을 두 코드가 두 번 찍지 않게)
#   O  기존 4a IMG-newTag의 추출(T047 이전의 YQ_IMAGES 식 그대로 — 없으면 '-'): name · newName · newTag · digest. 기존 판정(줄 · 개수 · 건너뛰는
#      항목)이 그대로이도록 식을 바꾸지 않는다 — 이 행으로는 "name 없음"과 "값이 '-'"를 구분하지 못하므로 새 판정은 E 행의 유무 필드를 쓴다
#   ⚠ 가지(`,`)는 같은 문서 노드를 왼쪽부터 차례로 본다 — O 가지의 `.images`·`.name`·`.newTag`·`.digest`는 없는 키를 **만든다**(YQ_CSS 주석). O 가지를
#     맨 뒤에 두지 않으면 D·E의 has()·keys·kind가 만들어진 키를 본다(2026-09-30 실측 — 모든 항목이 newTag 있음으로, 주석뿐인 문서가 맵으로 읽혔다).
#     D·E 가지는 has()로 거른 뒤에만 traverse한다. 수집자 `[...]`는 선택되지 않은 문서마다 빈 줄을 낸다(yq_lines가 지운다)
#   ⚠ yq v4.53.6의 `-`는 오른쪽부터 묶인다 — `a - b - c`는 `a - (b - c)`다(2026-09-30 실측: `10 - 3 - 2` = 9). 빼는 목록은 `+`로 합쳐 한 번에 뺀다
# shellcheck disable=SC2016  # $k·$ek·$et·$ks·$hn·$hd·$ht·$nt·$dt·$dj 는 yq 변수다
YQ_IMAGES='( [ "D", kind, tag, ((select(kind == "map") | select(has("images")) | .images | kind) // "none"), ((select(kind == "map") | select(has("images")) | .images | tag) // "none") ] | join(strenv(YQ_SEP)) ), ( select(kind == "map") | select(has("images")) | .images | select(kind == "seq") | to_entries[] | .key as $k | .value | kind as $ek | tag as $et | ((select(kind == "map") | keys | map(tostring)) // []) as $ks | ((select(kind == "map") | has("name")) // false | tostring) as $hn | ((select(kind == "map") | has("digest")) // false | tostring) as $hd | ((select(kind == "map") | has("newTag")) // false | tostring) as $ht | ((select(kind == "map") | select(has("name")) | .name | tag) // "-") as $nt | ((select(kind == "map") | select(has("digest")) | .digest | tag) // "-") as $dt | ((select(kind == "map") | select(has("digest")) | .digest | to_json(0)) // "-") as $dj | [ "E", ($k | tostring), $ek, $et, $hn, $nt, $hd, $dt, $dj, $ht, (($ks - env(IMG_ENTRY_KEYS)) | to_json(0)), (($ks - (env(IMG_ENTRY_KEYS) + ["newTag"])) | to_json(0)), ($ks | group_by(.) | map(select(length > 1) | .[0]) | to_json(0)), ((select(kind == "map") | .name) // "-"), (((select(kind == "map") | .newTag) // "-") | tostring), ((select(kind == "map") | .digest) // "-") ] | join(strenv(YQ_SEP)) ), ( (.images // [])[] | [ "O", (.name // "-"), (.newName // "-"), ((.newTag // "-") | tostring), (.digest // "-") ] | join(strenv(YQ_SEP)) )'
# 7.3 — kustomization의 base 참조(resources·bases·components 전부. 셋을 `+`로 잇는다: yq v4의 `,` 합집합은 수집자 안에서 가지를 잃는다).
#   별칭으로 적은 항목(`- *b`)은 풀어서 본다 — kustomize 5.8.1은 풀어서 그 base를 빌드한다(2026-09-30 실측). 풀지 않으면 별칭 노드의 태그는 빈 값이라
#   `tag == "!!str"`이 건너뛰었다(위 「앵커·별칭·병합 키」)
YQ_KUST_BASES='explode(.) | ((.resources // []) + (.bases // []) + (.components // []))[] | select(tag == "!!str")'
# 7.3 — Application의 **모든** source path(단일 `.spec.source` + multi-source `.spec.sources[]`).
#   YQ_APP(검사 2·7.1 공용)은 `.spec.sources[0]`만 보므로 두 번째 source가 검사 밖으로 빠진다 — 그 구멍을 여기서 막는다.
# shellcheck disable=SC2016  # $n 은 yq 변수다
YQ_APP_PATHS='explode(.) | select(.kind == "Application" and ((.apiVersion // "") | test("^argoproj.io/"))) | (.metadata.name // "-") as $n | (([.spec.source.path] + [(.spec.sources // [])[].path]) | map(select(. != null)))[] | [ $n, . ] | join(strenv(YQ_SEP))'
# 7.4 — Application 1개 = 1행: 이름 · `spec.source` 유무 · `spec.sources` 유무 · `spec.sourceHydrator` 유무 · 최상위 `operation` 유무 ·
#   source 키 집합(정렬) · repoURL · targetRevision.
#   ⚠ yq v4가 없는 경로를 traverse하면 그 키를 만들어 버리므로 유무(`has`)와 `keys`는 source를 traverse하기 **전에** 바인딩한다.
#   spec·source가 맵이 아니면 has/keys가 실패한다 → collect_rows가 "yq 추출 실패"로 FAIL(fail-closed).
# shellcheck disable=SC2016  # $ho·$sp·$s·$hs·$hss·$hh·$sk 는 yq 변수다
YQ_APP_SRC='explode(.) | select(.kind == "Application" and ((.apiVersion // "") | test("^argoproj.io/"))) | (has("operation") | tostring) as $ho | (.spec // {}) as $sp | (($sp | has("source")) | tostring) as $hs | (($sp | has("sources")) | tostring) as $hss | (($sp | has("sourceHydrator")) | tostring) as $hh | ($sp.source // {}) as $s | (($s | keys | sort) | join(",")) as $sk | [ (.metadata.name // "-"), $hs, $hss, $hh, $ho, $sk, (($s.repoURL // "-") | tostring), (($s.targetRevision // "-") | tostring) ] | join(strenv(YQ_SEP))'
YQ_HELM_COUNT='(.helmCharts // []) | length'
# shellcheck disable=SC2016
YQ_HELM_LEAVES='(.helmCharts // [])[] | (.name // "-") as $c | (.valuesInline // {}) | [.. | select(tag == "!!int" or tag == "!!str") | {"p": (path | join(".")), "v": (. | tostring)}] | .[] | [ $c, .p, .v ] | join(strenv(YQ_SEP))'
YQ_HELM_VALUES_FILES='(.helmCharts // [])[] | .valuesFile | select(. != null)'
YQ_FILE_LEAVES='[.. | select(tag == "!!int" or tag == "!!str") | {"p": (path | join(".")), "v": (. | tostring)}] | .[] | [ .p, .v ] | join(strenv(YQ_SEP))'
# 검사 9 — ClusterSecretStore. `keys`는 전부 sort 해 출력 순서를 문서 순서에 의존하지 않게 한다.
#   ⚠ yq v4가 없는 경로를 traverse하면 그 키를 만들어 버리므로, `keys` 문자열은 그 맵을 traverse하기 **전에** 먼저 바인딩한다.
YQ_CSS='select(.kind == "ClusterSecretStore") | [ (.metadata.name // "-"), (.metadata.namespace // "-"), (((.spec.provider // {}) | keys | sort) | join(",")) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016  # $v·$a·$ak·$sa 는 yq 변수다
YQ_CSS_VAULT='select(.kind == "ClusterSecretStore") | select((.spec.provider // {}) | has("vault")) | .spec.provider.vault as $v | ($v.auth // {}) as $a | (($a | keys | sort) | join(",")) as $akeys | ($a.kubernetes // {}) as $ak | ($ak.serviceAccountRef // {}) as $sa | [ (.metadata.name // "-"), ($v.server // "-"), ($v.path // "-"), ($v.version // "-"), $akeys, ($ak.mountPath // "-"), ($ak.role // "-"), ($sa.name // "-"), ($sa.namespace // "-"), (($sa.audiences // []) | join(",")) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
# shellcheck disable=SC2016
YQ_CSS_COND='select(.kind == "ClusterSecretStore") | (.spec.conditions // []) as $c | ([$c[] | keys[]] | unique | sort | join(",")) as $ckeys | [ (.metadata.name // "-"), (($c | length) | tostring), $ckeys, ([$c[] | (.namespaces // [])[]] | join(",")) ] | join(strenv(YQ_SEP))'
# shellcheck disable=SC2016
YQ_CSS_K8S='select(.kind == "ClusterSecretStore") | select((.spec.provider // {}) | has("kubernetes")) | .spec.provider.kubernetes as $k | ($k.auth // {}) as $a | (($a | keys | sort) | join(",")) as $akeys | ($a.serviceAccount // {}) as $sa | (($sa | keys | sort) | join(",")) as $sakeys | ($k.server // {}) as $srv | [ (.metadata.name // "-"), ($k.remoteNamespace // "-"), ($srv.url // "-"), (($srv.caProvider // {}).namespace // "-"), $akeys, ($sa.name // "-"), ($sa.namespace // "-"), $sakeys ] | join(strenv(YQ_SEP))'
# 검사 11 · 12.3 — 문서 1개 = 1행: 순번(1-기반) · 노드 종류(map|seq|scalar) · 태그 · kind 키 유무 · kind · apiVersion · 최상위 items의
#   노드 종류(없으면 -) · metadata.name. 맵이 아닌 문서(빈 문서 = scalar + !!null)에서는 키를 traverse하지 않는다(yq v4는 시퀀스 문서의
#   `.kind`에서 오류로 멈춘다). 태그가 아니라 노드 종류(`kind` 연산자)로 보므로 커스텀 태그(`--- !Foo {…}`)가 붙은 맵도 맵이다.
#   문서를 explode(.)로 푼 뒤 본다(위 「앵커·별칭·병합 키」 — `items: *seq`의 items는 seq, `<<: *m`으로 들인 items도 보인다). 풀지 못하면 yq가 실패하고
#   (collect_doc_rows → 11.0), 풀었는데 items 종류가 alias로 남으면 11.1이 11.0으로 건다(fail-closed — yq v4.53.6의 explode는 풀거나 실패한다: 실측)
YQ_DOCS='explode(.) | [ ((document_index + 1) | tostring), kind, tag, ((select(kind == "map") | has("kind")) // false | tostring), ((select(kind == "map") | .kind | select(kind == "scalar")) // "-" | tostring), ((select(kind == "map") | .apiVersion | select(kind == "scalar")) // "-" | tostring), ((select(kind == "map") | select(has("items")) | .items | kind) // "-"), ((select(kind == "map") | .metadata | select(kind == "map") | .name | select(kind == "scalar")) // "-" | tostring) ] | join(strenv(YQ_SEP))'
# 12.1–12.3 사전 판정 — kustomization 파일 1개 = yq 1번. 행의 첫 필드가 종류다:
#   K  최상위: helmGlobals 유무 · helmChartInflationGenerator 유무 · helmCharts 태그(없으면 none)
#   E  helmCharts 항목: 번호(1-기반) · name 유무 · name · repo 유무 · repo · version 유무 · version(항목이 맵이 아니면 유무 false · 값 '')
#   G  generators·transformers의 문자열 항목(레거시 생성기 설정 파일이나 kustomization 디렉터리를 가리킬 수 있다)
#   B  resources·bases·components의 문자열 항목(base로 끌려오는 kustomization — 같은 --enable-helm 빌드에서 그 helmCharts도 인플레이트된다)
#   최상위의 `,`는 가지를 모두 낸다(수집자 `[...]` 안에서만 두 번째 가지를 잃는다). 선택되지 않은 가지가 빈 줄을 낼 수 있어 빈 줄은 버린다.
#   문서를 explode(.)로 푼 뒤 본다(위 「앵커·별칭·병합 키」 — 병합으로 들인 helmGlobals · 별칭으로 적은 base 항목 `- *b`도 보인다: kustomize 5.8.1은
#   풀어서 그 base의 helmCharts까지 인플레이트한다 — 2026-09-30 실측). ⚠ yq v4.53.6에서 `,`는 `|`보다 느슨하게 묶인다(`a | b, c` = `(a | b), c` —
#   2026-09-30 실측) — 네 가지를 괄호로 감싸 모두 푼 문서에서 돌게 한다. (괄호가 없어도 오늘은 결과가 같다: explode(.)는 문서 노드를 제자리에서
#   바꾸므로 뒤 가지도 푼 문서를 본다 — 2026-09-30 실측 · 변이 M6b가 살아남은 이유. 그 부수 효과에 기대지 않으려고 괄호를 둔다.)
#   풀지 못하면 yq가 실패한다(helm_src_scan이 12.1로 FAIL — fail-closed)
# shellcheck disable=SC2016  # $k 는 yq 변수다
YQ_HELM_SCAN='explode(.) | ( ( [ "K", (has("helmGlobals") | tostring), (has("helmChartInflationGenerator") | tostring), ((select(has("helmCharts")) | .helmCharts | tag) // "none") ] | join(strenv(YQ_SEP)) ), ( select(has("helmCharts") and (.helmCharts | tag) == "!!seq") | .helmCharts | to_entries[] | .key as $k | .value | [ "E", (($k + 1) | tostring), ((select(kind == "map") | has("name")) // false | tostring), ((select(kind == "map") | .name) // "" | tostring), ((select(kind == "map") | has("repo")) // false | tostring), ((select(kind == "map") | .repo) // "" | tostring), ((select(kind == "map") | has("version")) // false | tostring), ((select(kind == "map") | .version) // "" | tostring) ] | join(strenv(YQ_SEP)) ), ( ((.generators // []) + (.transformers // []))[] | select(tag == "!!str") | "G" + strenv(YQ_SEP) + . ), ( ((.resources // []) + (.bases // []) + (.components // []))[] | select(tag == "!!str") | "B" + strenv(YQ_SEP) + . ) )'
# 12.3 — generators·transformers가 가리키는 파일에 레거시 생성기 설정이 있는가. 문서를 explode(.)로 푼 뒤 **모든 맵**(`..` — 최상위 문서뿐 아니라
#   `kind: List`의 items 안 등)에서 kind가 HelmChartInflationGenerator인 것의 kind를 낸다(2026-09-30 G4 리뷰 A3 — kustomize는 생성기 설정 파일의 List를
#   풀어 생성기를 돌린다. 최상위 kind만 보면 List로 감싼 생성기를 지나친다). has("kind")로 거른 뒤에만 .kind를 읽는다(없는 키를 만들지 않게 — YQ_CSS
#   주석). 문자열 리터럴이 아니라 .kind를 낸다(리터럴은 선택되지 않은 문서마다에도 나온다 — 검사 10 주석). 풀지 못하면 yq가 실패한다(12.3 FAIL)
YQ_LEGACY_GEN='explode(.) | .. | select(kind == "map") | select(has("kind")) | select((.kind | tostring) == "HelmChartInflationGenerator") | .kind'
# 12.4 — 렌더의 ConfigMap argocd/argocd-cm 1개 = 1행: data에서 그 키의 개수(0|1) · 값(JSON 한 줄 — 줄바꿈이 든 블록 값도 한 줄로
#   이스케이프된다) · 값을 낱말(HELM_ARGOCD_WORD_RE — Go strings.Fields와 같은 공백으로 나눈 조각)로 나눠 `--enable-helm` · `--enable-helm=…`인
#   낱말만 순서대로(각각 JSON 문자열 · 공백 하나로 잇는다 — 낱말에는 공백이 없고 JSON은 제어 문자를 이스케이프하므로 US·줄바꿈도 없다). Argo CD는
#   이 값을 strings.Fields로 나눠 kustomize 인자로 붙인다(argo-cd v3.5.2 util/kustomize parseKustomizeBuildOptions) — 글자 포함(`--enable-helmfoo`)이
#   아니라 낱말이다. 참·거짓 판정(pflag — 마지막 값 · 읽지 못하는 값)은 셸이 한다(check_12_helm — yq v4.53.6에는 if가 없다)
# shellcheck disable=SC2016  # $d·$e 는 yq 변수다
YQ_ARGOCD_CM='select(kind == "map") | select(((.kind // "") | tostring) == "ConfigMap" and ((.metadata.name // "") | tostring) == strenv(HELM_ARGOCD_CM) and ((.metadata.namespace // "") | tostring) == strenv(HELM_ARGOCD_CM_NS)) | (.data // {}) as $d | ($d | to_entries | map(select(.key == strenv(HELM_ARGOCD_KEY)))) as $e | [ (($e | length) | tostring), (($e[0].value // "") | tostring | to_json(0)), ([ ($e[0].value // "") | tostring | match(strenv(HELM_ARGOCD_WORD_RE); "g") | .string | select(test("^" + strenv(HELM_ARGOCD_FLAG) + "(=|$)")) ] | map(to_json(0)) | join(" ")) ] | join(strenv(YQ_SEP))'
# 13.1 — 규칙(맵) 하나가 토큰 발급 규칙인가: apiGroups · verbs · resources가 각각 RBAC_TOKEN_* 집합과 겹친다(교집합 = a - (a - b)). 목록이 아니거나
#   없는 필드는 빈 목록이다(토큰 발급 규칙이 아니다 — API 서버도 받지 않는다). apiGroups의 원소 null은 ""로 읽는다(API 서버가 JSON null을 빈
#   문자열로 풀어 core 그룹이 된다). ⚠ `X as $v | …`를 셋 이어 `and`로 묶으면 yq v4.53.6이 앞 바인딩을 잃고 거짓을 낸다(2026-09-30 실측) —
#   조건마다 바인딩을 괄호 안에 가둔다.
# shellcheck disable=SC2016  # $ag·$vb·$rs 는 yq 변수다
YQ_RBAC_TOKEN_RULE='((((((.apiGroups | select(kind == "seq")) // []) | map(. // "")) as $ag | ($ag - ($ag - env(RBAC_TOKEN_GROUPS))) | length) > 0) and ((((.verbs | select(kind == "seq")) // []) as $vb | ($vb - ($vb - env(RBAC_TOKEN_VERBS))) | length) > 0) and ((((.resources | select(kind == "seq")) // []) as $rs | ($rs - ($rs - env(RBAC_TOKEN_RESOURCES))) | length) > 0))'
# 검사 13 — RBAC 문서 하나에서 여러 행(첫 필드가 종류). 대상 = 맵 문서 중 apiVersion이 rbac.authorization.k8s.io/로 시작하고 kind가 넷 중 하나.
#   R 역할: kind · ns(없으면 -) · 이름 · 규칙 수 · aggregationRule 키 유무 · aggregate-to-* 라벨 키 목록(JSON) · 토큰 발급 규칙 수
#   T 토큰 발급 규칙(역할의 규칙마다): kind · ns · 이름 · 규칙 번호(1-기반) · apiGroups · resources · verbs(JSON — 목록이 아니면 []) ·
#     resourceNames 키 유무 · resourceNames(정렬·중복 제거 JSON)
#   B 바인딩: kind · ns · 이름 · roleRef.kind · roleRef.name(없으면 -) · subjects 태그(없으면 none) · 주체 수(목록일 때)
#   S 주체(바인딩의 subjects 목록 원소마다): kind · ns · 이름 · 주체 번호 · 노드 종류 · 주체 kind(없으면 -) · name · namespace(없으면 빈 값)
#   ⚠ yq v4.53.6의 두 함정(검사 10 주석): 문자열 리터럴은 선택되지 않은 문서에도 나온다 · 수집자 `[...]`는 선택되지 않은 문서마다 빈 결과(빈 줄 —
#   src_extract가 지운다). 그래서 모든 행은 수집자 `[ "R", … ] | join`으로 만들고, 셸이 행마다 종류·구분자 수를 확인한다(아니면 13.0). 또
#   `빈 스트림 as $v | $w…`처럼 **변수로 시작하는** 식은 빈 문맥에서도 값을 낸다(2026-09-30 실측) — T·S 행은 문서의 경로(.rules · .subjects)에서
#   출발한다. has()는 그 키를 traverse하기 전에 바인딩한다(없는 경로를 traverse하면 키가 생긴다 — YQ_CSS 주석).
# shellcheck disable=SC2016  # $kk·$k·$ns·$n·$ar·$al·$rules·$ti·$hrn·$st·$rr·$si 는 yq 변수다
YQ_RBAC='select(kind == "map") | select(((.apiVersion // "") | tostring | test("^rbac\\.authorization\\.k8s\\.io/")) and (((.kind // "") | tostring) as $kk | ($kk == "Role" or $kk == "ClusterRole" or $kk == "RoleBinding" or $kk == "ClusterRoleBinding"))) | (.kind | tostring) as $k | (((.metadata | select(kind == "map") | .namespace | select(kind == "scalar")) // "-") | tostring) as $ns | (((.metadata | select(kind == "map") | .name | select(kind == "scalar")) // "-") | tostring) as $n | ( ( select($k == "Role" or $k == "ClusterRole") | (has("aggregationRule") | tostring) as $ar | ([ ((.metadata | select(kind == "map") | .labels | select(kind == "map") | keys) // [])[] | tostring | select(test("^rbac\\.authorization\\.k8s\\.io/aggregate-to-")) ] | to_json(0)) as $al | ((.rules | select(kind == "seq")) // []) as $rules | ( ([ "R", $k, $ns, $n, ($rules | length | tostring), $ar, $al, ($rules | map(select(kind == "map") | select('"$YQ_RBAC_TOKEN_RULE"')) | length | tostring) ] | join(strenv(YQ_SEP))), (.rules | select(kind == "seq") | to_entries[] | select(.value | kind == "map") | select(.value | '"$YQ_RBAC_TOKEN_RULE"') | .key as $ti | .value | (has("resourceNames") | tostring) as $hrn | [ "T", $k, $ns, $n, (($ti + 1) | tostring), (((.apiGroups | select(kind == "seq")) // []) | to_json(0)), (((.resources | select(kind == "seq")) // []) | to_json(0)), (((.verbs | select(kind == "seq")) // []) | to_json(0)), $hrn, (((.resourceNames | select(kind == "seq")) // []) | map(tostring) | sort | unique | to_json(0)) ] | join(strenv(YQ_SEP))) ) ), ( select($k == "RoleBinding" or $k == "ClusterRoleBinding") | ((select(has("subjects")) | .subjects | tag) // "none") as $st | ((.roleRef | select(kind == "map")) // {}) as $rr | ( ([ "B", $k, $ns, $n, (($rr.kind // "-") | tostring), (($rr.name // "-") | tostring), $st, (((.subjects | select(kind == "seq")) // []) | length | tostring) ] | join(strenv(YQ_SEP))), (.subjects | select(kind == "seq") | to_entries[] | .key as $si | .value | [ "S", $k, $ns, $n, (($si + 1) | tostring), kind, (((select(kind == "map") | .kind) // "-") | tostring), (((select(kind == "map") | .name) // "") | tostring), (((select(kind == "map") | .namespace) // "") | tostring) ] | join(strenv(YQ_SEP))) ) ) )'

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
# 시작: 도구 · 파일 수집 · YAML 파싱  (--only-author 모드는 이 절을 통째로 건너뛴다 — 도구 설치 여부와 무관하게 판정한다)
# -----------------------------------------------------------------------------
printf 'platform-gitops validate — 대상: %s\n' "$ROOT"
if [[ $ONLY_AUTHOR == 1 ]]; then
  # 실행은 맨 아래 「실행」 절(검사 6 하나 + 별도 문구의 요약). 여기서는 모드만 알린다
  printf '모드: --only-author — 작성자 검사만 실행(검사 6). 도구 확인·파일 수집·다른 검사(0–5 · 7–13)는 하지 않는다 — 이 결과는 전체 검사 통과가 아니다\n'
else
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
fi

# -----------------------------------------------------------------------------
# 검사 12 사전 판정(12.1–12.3) — 검사 1 **전에** 돈다. 출력하지 않고 결과만 모은다(FAIL·PASS 줄은 check_12_helm이 검사 번호 순서대로 찍는다).
#   허용하지 않은 출처에서 차트를 받아 오는 것 자체가 막아야 할 일이다: 걸린 kustomization은 검사 1이 렌더하지 않는다(`1 KUST` FAIL로 남는다).
#   대상 = 모든 kustomization(KUST_FILES) + 그것들이 base(resources·bases·components)나 generators·transformers로 끌어오는 로컬
#   kustomization(파일 열거 밖 — tests/·charts/ 아래 — 도 포함): `kustomize build --enable-helm`은 끌려온 kustomization의 helmCharts도
#   같은 빌드에서 인플레이트한다. 끌려온 쪽이 걸리면 끌어온 쪽도 렌더하지 않는다(전파 — 사유 `base <디렉터리>`).
#   generators·transformers가 부르는 로컬 파일이 kind: HelmChartInflationGenerator이면 그 kustomization도 걸린다(12.3 — --enable-helm
#   빌드는 레거시 생성기로 허용 목록 밖의 차트를 받는다. --enable-helm 없는 빌드는 kustomize가 "must specify --enable-helm"으로 멈춘다).
#   원격 base(URL · git@)는 따라가지 않는다 — 그 내용은 저장소 밖이다(tests/README.md 「검사 12가 보지 않는 것」).
# -----------------------------------------------------------------------------
declare -A HELM_BLOCK=() HELM_NCH=() HELM_ALLOW=()   # 걸린 kustomization(절대 경로) → 사유 · kustomization → helmCharts 항목 수 · 허용 목록
HELM_F1=(); HELM_F2=(); HELM_F3=()                    # 코드별 FAIL 메시지(check_12_helm이 찍는다)
HELM_USE=''; HELM_NENT=0; HELM_NKUST=0; HELM_NEXTRA=0; HELM_NUSER=0
helm_block() { # <kustomization 절대 경로> <사유> — 사유는 " · "로 잇고 같은 사유는 한 번만
  local cur=${HELM_BLOCK[$1]:-}
  [[ " · $cur · " == *" · $2 · "* ]] || HELM_BLOCK[$1]="${cur:+$cur · }$2"
}
helm_uses() { # <kustomization 절대 경로> — helmCharts 항목이 1개 이상이면 0 · 없으면 1 · 읽지 못하면 2(사전 판정 값이 있으면 그것을 쓴다)
  local n=${HELM_NCH[$1]:-}
  if [[ -z $n ]]; then
    n=$(yq -N "$YQ_HELM_COUNT" "$1" 2>/dev/null | tr -d '\r') || return 2
  fi
  [[ $n =~ ^[0-9]+$ ]] || return 2
  [[ $n -gt 0 ]]
}
helm_src_scan() {
  [[ ${TOOL_OK[yq]:-0} == 1 ]] || return 0   # yq가 없으면 검사 12가 need_tool로 SKIP/FAIL한다(여기서는 판정하지 못한다)
  local c r kf rk kdir out gen typ n hn nm hr rp hv ver nk x ref dep changed
  local -a queue=()
  local -A seen=() listed=() deps=()
  while read -r c r; do
    [[ -n $c ]] || continue
    HELM_ALLOW[$c]=$r
  done <<< "$HELM_CHART_TABLE"
  for kf in "${KUST_FILES[@]}"; do listed[$kf]=1; queue+=("$kf"); done
  while [[ ${#queue[@]} -gt 0 ]]; do
    kf=${queue[0]}; queue=("${queue[@]:1}")
    [[ -z ${seen[$kf]:-} ]] || continue
    seen[$kf]=1; HELM_NKUST=$((HELM_NKUST + 1))
    [[ -n ${listed[$kf]:-} ]] || HELM_NEXTRA=$((HELM_NEXTRA + 1))
    rk=$(rel "$kf"); kdir=$(dirname "$rk"); [[ $kdir != . ]] || kdir=''
    HELM_NCH[$kf]=0
    if ! out=$(yq -N "$YQ_HELM_SCAN" "$kf" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'); then
      HELM_F1+=("$rk: yq로 읽지 못했다 — 차트 출처를 판정할 수 없다(fail-closed · 검사 1은 렌더하지 않는다)")
      helm_block "$kf" 12.1
      continue
    fi
    nk=0
    # K행: n=helmGlobals 유무 hn=helmChartInflationGenerator 유무 nm=helmCharts 태그 · E행: n=번호 hn=name 유무 nm=name hr=repo 유무
    #   rp=repo hv=version 유무 ver=version · G·B행: n=항목
    while IFS="$YQ_SEP" read -r typ n hn nm hr rp hv ver; do
      case $typ in
        K)
          nk=$((nk + 1))
          if [[ $n == true ]]; then
            HELM_F3+=("$rk: 최상위 키 'helmGlobals' 금지 — helmCharts 밖의 차트 설정(전역 chartHome·configHome · 레거시 생성기)은 허용 목록 대조와 인플레이트 캐시 자리(12.5)를 벗어난다")
            helm_block "$kf" 12.3
          fi
          if [[ $hn == true ]]; then
            HELM_F3+=("$rk: 최상위 키 'helmChartInflationGenerator' 금지 — helmCharts 밖의 차트 설정(전역 chartHome·configHome · 레거시 생성기)은 허용 목록 대조와 인플레이트 캐시 자리(12.5)를 벗어난다")
            helm_block "$kf" 12.3
          fi
          case $nm in
            none|'!!seq'|'!!null') ;;
            *) HELM_F1+=("$rk: helmCharts가 목록이 아니다(태그 $nm) — 항목을 판정할 수 없다(fail-closed)"); helm_block "$kf" 12.1 ;;
          esac ;;
        E)
          HELM_NENT=$((HELM_NENT + 1)); HELM_NCH[$kf]=$((${HELM_NCH[$kf]} + 1))
          if [[ $hn != true || -z $nm ]]; then
            x="$rk helmCharts #$n"
            HELM_F1+=("$x: name 없음 — (이름, 저장소) 쌍을 허용 목록과 대조할 수 없다")
            helm_block "$kf" 12.1
          else
            x="$rk helmCharts #$n '$nm'"
            if [[ $hr != true || -z $rp ]]; then
              HELM_F1+=("$x: repo 없음 — repo 없는 항목(<kustomization>/charts/ 아래의 로컬 차트를 그대로 쓴다)은 금지")
              helm_block "$kf" 12.1
            elif [[ -z ${HELM_ALLOW[$nm]+set} ]]; then
              HELM_F1+=("$x: repo '$rp' — (이름, 저장소) 쌍이 허용 목록에 없다(새 차트는 계약 표에 행을 더하는 계약 변경으로 시작한다)")
              helm_block "$kf" 12.1
            elif [[ $rp != "${HELM_ALLOW[$nm]}" ]]; then
              HELM_F1+=("$x: repo '$rp' ≠ 허용 목록의 '${HELM_ALLOW[$nm]}'(이름·저장소 쌍 — 글자 단위 정확 일치: 대소문자·끝의 '/' 포함)")
              helm_block "$kf" 12.1
            else
              HELM_USE+="${HELM_USE:+ · }${kdir:-.} → $nm"
            fi
          fi
          if [[ $hv != true ]]; then
            HELM_F2+=("$x: version 없음 — 없으면 kustomize가 받는 시점의 최신 차트를 쓴다(값은 표로 고정하지 않지만 있어야 한다)")
            helm_block "$kf" 12.2
          elif [[ -z $ver ]]; then
            HELM_F2+=("$x: version이 빈 값 — 없으면 kustomize가 받는 시점의 최신 차트를 쓴다(값은 표로 고정하지 않지만 있어야 한다)")
            helm_block "$kf" 12.2
          fi ;;
        G|B)
          # 원격(URL · git@)은 따라가지 않는다. 절대 경로와 저장소 밖 경로는 건너뛴다(base 항목은 7.3이 위치 판정 불가로 FAIL한다)
          case $n in *://*|git@*|/*) continue ;; esac
          r=$(norm_rel "$kdir" "$n")
          [[ -n $r ]] || continue
          if [[ -d "$ROOT/$r" ]]; then
            ref=$(kust_file_in "$ROOT/$r") || continue
            deps[$kf]+="$ref"$'\n'
            [[ -n ${seen[$ref]:-} ]] || queue+=("$ref")
          elif [[ $typ == G && -f "$ROOT/$r" ]]; then
            # 풀어 읽지 못하는 파일은 레거시 생성기인지 판정할 수 없다 — 조용히 지나가지 않는다(fail-closed · YQ_LEGACY_GEN 주석)
            if ! gen=$(yq -N "$YQ_LEGACY_GEN" "$ROOT/$r" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'); then
              HELM_F3+=("$rk: generators·transformers 항목 '$n'(→ $r)를 yq로 풀어 읽지 못했다 — 레거시 생성기(kind: HelmChartInflationGenerator)인지 판정할 수 없다(fail-closed · 앵커·병합 키를 풀 수 없거나 YAML로 읽히지 않는다)")
              helm_block "$kf" 12.3
            elif [[ -n $gen ]]; then
              HELM_F3+=("$rk: generators·transformers 항목 '$n'(→ $r)가 kind: HelmChartInflationGenerator — 레거시 생성기 금지(helmCharts 허용 목록 밖에서 차트를 받는다)")
              helm_block "$kf" 12.3
            fi
          fi ;;
        *)
          HELM_F1+=("$rk: yq 추출 행을 해석할 수 없다(종류 '$typ' — 값에 줄바꿈 등) — fail-closed")
          helm_block "$kf" 12.1 ;;
      esac
    done <<< "$out"
    if [[ $nk -ne 1 ]]; then
      HELM_F1+=("$rk: 최상위 문서 ${nk}개 — kustomization은 문서 하나여야 한다(판정할 수 없다 — fail-closed)")
      helm_block "$kf" 12.1
    fi
    [[ ${HELM_NCH[$kf]} -eq 0 ]] || HELM_NUSER=$((HELM_NUSER + 1))
  done
  # 전파(고정점까지) — 걸린 kustomization을 끌어오는 kustomization도 렌더하지 않는다
  changed=1
  while [[ $changed == 1 ]]; do
    changed=0
    for kf in "${!seen[@]}"; do
      [[ -z ${HELM_BLOCK[$kf]:-} ]] || continue
      while IFS= read -r dep; do
        [[ -n $dep && -n ${HELM_BLOCK[$dep]:-} ]] || continue
        helm_block "$kf" "base $(dirname "$(rel "$dep")")"
        changed=1
        break
      done <<< "${deps[$kf]:-}"
    done
  done
}

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
    # (T047) 차트 출처 판정(12.1–12.3 — helm_src_scan)에 걸린 kustomization은 빌드하지 않는다: --enable-helm 빌드가 허용하지 않은 출처의
    #   차트를 받아 온다. 이 kustomization의 렌더는 없고, 이 FAIL로 결과는 이미 실패다(판정 내용은 검사 12가 찍는다)
    if [[ -n ${HELM_BLOCK[$kfile]:-} ]]; then
      fail "1 KUST" "kustomize build 건너뜀: $rdir — 차트 출처 판정(${HELM_BLOCK[$kfile]})에 걸렸다: 허용하지 않은 출처의 차트를 받아 오지 않는다(검사 12)"
      continue
    fi
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
    elif [[ $p =~ $RE_LOC_SECRETS || $p == "$SECRETS_OWNER_DIR" ]]; then want_store=vault-platform; want_prefix=platform/
    fi
    # ⚠ `$p == $SECRETS_OWNER_DIR`(배달자 렌더)를 함께 보는 이유: 원본 파일이 아니라 **Argo가 실제로 적용하는 렌더**가
    #   기준이어야 한다(계약 §validate.yml 4 · T045 G4). 배달자에 변환 키가 있으면 원본은 그대로인 채 렌더에서만
    #   store·key가 바뀐다 — 그 구조 자체는 7.3이 금지하고, 여기서는 결과를 한 번 더 본다.
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
# 검사 4 — images[].newTag 금지(4a) · images 항목의 name · digest · 키(4a IMG-entry — T047) · platform/** image: digest 경고(4b)
# -----------------------------------------------------------------------------
# KUST_FILES와 같은 순서의 YQ_IMAGES 출력 · 종료 코드 — check_4_images가 채우고 두 판정(4a IMG-newTag · 4a IMG-entry)이 읽는다
IMG_OUT=(); IMG_RC=()
check_4_images() {
  header 4 "images[].newTag 금지 · platform/** image: @sha256 경고"
  local fails_before=$N_FAIL n=0 kfile rk name newtag digest f line val i out rc typ
  if need_tool "4a IMG-newTag" yq; then
    IMG_OUT=(); IMG_RC=()
    for kfile in "${KUST_FILES[@]}"; do
      rc=0
      out=$(yq_lines "$YQ_IMAGES" "$kfile") || rc=$?
      IMG_OUT+=("$out"); IMG_RC+=("$rc")
    done
    # 4a IMG-newTag — O 행만 읽는다(T047 이전과 같은 판정 · 줄 · 개수. yq가 실패하면 그 전까지 나온 행으로 판정하던 것도 같다 — 실패 자체는 4a IMG-shape가 찍는다)
    for i in "${!KUST_FILES[@]}"; do
      rk=$(rel "${KUST_FILES[$i]}")
      while IFS="$YQ_SEP" read -r typ name _ newtag digest; do
        [[ $typ == O ]] || continue
        [[ -n $name ]] || continue
        n=$((n + 1))
        [[ $newtag == "-" ]] || fail "4a IMG-newTag" "$rk images[$name]: newTag='$newtag' 금지(digest만)"
        if [[ $digest != "-" && ! $digest =~ $RE_DIGEST ]]; then
          fail "4a IMG-newTag" "$rk images[$name]: digest '$digest' 형식 오류(sha256:<64 hex>)"
        fi
      done <<< "${IMG_OUT[$i]}"
    done
    finish_group "4a IMG-newTag" "kustomization images ${n}개 항목 newTag 없음" "$fails_before"
    check_4a_entries
  else
    need_tool "4a IMG-entry" yq || true
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

# 4a IMG-entry(T047 · 계약 §이미지·승격 「(T047) 항목마다 name과 digest」) — images 항목마다 name · digest 필수 · 키 ⊆ IMG_ENTRY_KEYS · 키 중복 금지 ·
#   fail-closed(IMG-shape). YQ_IMAGES의 D·E 행을 읽는다(O 행은 4a IMG-newTag의 몫). 그룹 PASS 줄은 이 판정의 FAIL만 센다 — 4a IMG-newTag의 PASS 줄은
#   이 판정과 무관하게 전과 같이 찍힌다(그래서 IMG-newTag의 finish_group 뒤에 돈다).
#   기존 코드가 이미 찍는 결함(newTag · 비어 있지 않은 digest의 형식 오류)은 다시 찍지 않는다. 그 판단은 E 행에 실은 기존 방식의 name·newTag·digest로
#   한다 — 기존 코드는 그 name이 빈 항목(name: "" · 목록·맵 name)을 통째로 건너뛰고, 값이 null·false·'-'인 digest·newTag를 '없음'으로 읽는다.
#   그 항목·값은 여기서 찍는다(빈틈을 남기지 않는다). ""인 digest는 기존 코드도 형식 오류로 찍지만 여기서도 "빈 값"으로 찍는다(계약 문면의 "빈 값").
#   보지 않는 것은 tests/README.md 「검사 4a가 보지 않는 것」.
check_4a_entries() {
  local fb=$N_FAIL ne=0 nk=0 i rk line typ nsep cont had lbl x keystxt oldseen
  local dk dtg ik it idx ek et hn nt hd dt dj ht xall xnot dups oname onewtag odigest
  keystxt=${IMG_ENTRY_KEYS//\"/}; keystxt=${keystxt#\[}; keystxt=${keystxt%\]}; keystxt="{${keystxt//,/, }}"
  for i in "${!KUST_FILES[@]}"; do
    rk=$(rel "${KUST_FILES[$i]}")
    if [[ ${IMG_RC[$i]} != 0 ]]; then
      fail "4a IMG-shape" "$rk: yq 추출 실패 — images 항목을 판정할 수 없다(fail-closed)"
      continue
    fi
    cont=none; had=0
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      typ=${line%%"$YQ_SEP"*}
      [[ $typ != O ]] || continue
      nsep=${line//[!$YQ_SEP]/}; nsep=${#nsep}
      case "$typ:$nsep" in
        D:4)
          # 문서 — 노드 종류 · 태그 · images의 노드 종류 · 태그
          IFS=$YQ_SEP read -r typ dk dtg ik it <<< "$line"
          cont=none
          if [[ $dk != map ]]; then
            if [[ $dk != scalar || $dtg != '!!null' ]]; then   # 빈 문서(주석뿐)는 images 없음
              fail "4a IMG-shape" "$rk: 문서가 맵이 아니다($dk · 태그 ${dtg:--}) — images를 판정할 수 없다(fail-closed)"
            fi
          elif [[ $ik == seq ]]; then
            cont=seq
          elif [[ $ik != none && ( $ik != scalar || $it != '!!null' ) ]]; then   # images: null은 images 없음과 같다(kustomize도 빈 목록으로 읽는다)
            fail "4a IMG-shape" "$rk: images가 목록이 아니다($ik · 태그 ${it:--}) — 항목을 판정할 수 없다(kustomize는 images를 목록으로만 읽는다 · fail-closed)"
          fi ;;
        E:15)
          IFS=$YQ_SEP read -r typ idx ek et hn nt hd dt dj ht xall xnot dups oname onewtag odigest <<< "$line"
          if [[ $cont != seq || ! $idx =~ ^[0-9]+$ || ! $hn =~ ^(true|false)$ || ! $hd =~ ^(true|false)$ || ! $ht =~ ^(true|false)$ \
                || $xall != \[* || $xnot != \[* || $dups != \[* ]]; then
            fail "4a IMG-shape" "$rk: yq 추출 행의 모양이 기대와 다르다(항목 행 — 필드 값) — fail-closed"
            continue
          fi
          ne=$((ne + 1)); had=1
          lbl="$rk images #$((idx + 1))"
          if [[ $hn == true && $nt == '!!str' && -n $oname ]]; then lbl+=" '$oname'"; fi
          if [[ $ek != map ]]; then
            fail "4a IMG-shape" "$lbl: 항목이 맵이 아니다($ek · 태그 ${et:--}) — name·digest를 판정할 수 없다(앵커 별칭도 판정하지 않는다 · fail-closed)"
            continue
          fi
          # 4a IMG-name — kustomize는 name과 같은 이미지만 바꾼다
          if [[ $hn != true ]]; then
            fail "4a IMG-name" "$lbl: name 없음 — kustomize는 name이 가리키는 이미지만 바꾸므로 이 항목은 아무 이미지도 고정하지 않는다"
          elif [[ $nt != '!!str' ]]; then
            fail "4a IMG-name" "$lbl: name이 문자열이 아니다(태그 $nt)"
          elif [[ -z $oname ]]; then
            fail "4a IMG-name" "$lbl: name이 빈 값"
          fi
          # 기존 4a IMG-newTag가 이 항목을 판정했는가 — 기존 코드는 O 행의 name이 빈 항목을 건너뛴다(E 행의 oname이 같은 값이다)
          oldseen=0
          if [[ -n $oname ]]; then oldseen=1; fi
          # 4a IMG-digest — 없음 · 빈 값. 형식 오류는 기존 코드가 찍지 않은 것만(기존 코드는 '-'·false를 '없음'으로 읽고 name 빈 항목을 건너뛴다)
          if [[ $hd != true ]]; then
            fail "4a IMG-digest" "$lbl: digest 없음 — 이미지 고정이 풀린다(태그 없는 이름은 latest로 풀린다 · 계약 §이미지·승격)"
          elif [[ $dt == '!!null' ]]; then
            fail "4a IMG-digest" "$lbl: digest가 빈 값(null) — 이미지 고정이 풀린다"
          elif [[ $dt == '!!str' && -z $odigest ]]; then
            fail "4a IMG-digest" "$lbl: digest가 빈 값 — 이미지 고정이 풀린다"
          elif ! [[ $dt == '!!str' && $odigest =~ $RE_DIGEST ]] && ! [[ $oldseen == 1 && $odigest != "-" && ! $odigest =~ $RE_DIGEST ]]; then
            fail "4a IMG-digest" "$lbl: digest $dj(태그 $dt) — 문자열 sha256:<64 hex>가 아니다(기존 형식 검사 4a IMG-newTag가 보지 않는 값: '-'·false는 없음으로 읽히고 name이 빈 항목은 건너뛴다)"
          fi
          # 4a IMG-keys — newTag는 기존 코드가 이 항목에 찍었으면 빼고 본다(값이 null·false·'-'이거나 name 빈 항목이면 기존 코드는 찍지 않았다)
          if [[ $oldseen == 1 && $onewtag != "-" ]]; then x=$xnot; else x=$xall; fi
          if [[ $x != '[]' ]]; then
            fail "4a IMG-keys" "$lbl: 키 $x — 항목의 키는 ${keystxt}만(계약 §이미지·승격)"
          fi
          if [[ $dups != '[]' ]]; then
            fail "4a IMG-keys" "$lbl: 키 중복 $dups — yq와 kustomize는 뒤의 값을 쓴다(앞의 값을 읽은 사람과 다르게 읽힌다)"
          fi ;;
        *)
          fail "4a IMG-shape" "$rk: yq 추출 행의 모양이 기대와 다르다(종류 '${typ:0:12}' · 구분자 ${nsep}개) — 값에 줄바꿈·구분 문자가 든 이름 등(fail-closed)" ;;
      esac
    done <<< "${IMG_OUT[$i]}"
    if [[ $had == 1 ]]; then nk=$((nk + 1)); fi
  done
  if [[ $N_FAIL -eq $fb ]]; then
    if [[ $ne -eq 0 ]]; then
      pass "4a IMG-entry" "kustomization images 항목 0개 — 대상 없음"
    else
      pass "4a IMG-entry" "kustomization images ${ne}개 항목(kustomization ${nk}개): 항목마다 name(문자열)·digest 있음 · 키 ⊆ $keystxt"
    fi
  fi
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

  # 5.6 allow-apiserver-webhook: 출발 ipBlock 집합 · peer · 포트(계약 §정책 세트의 allow-apiserver-webhook 행)
  #   ns마다 계약 포트를 가진 ingress 규칙이 있어야 하고, 그 규칙은
  #     (a) ports 집합이 정확히 {계약 포트}이며 endPort(포트 범위)가 없고
  #     (b) from[]이 ipBlock 전용(except 없음)이고 cidr 집합이 위 표의 기대 집합과 정확히 같아야 한다.
  #   계약 포트를 갖지 않은 ingress 규칙(ports 자체가 없는 전 포트 개방 포함)이 그 정책에 있으면 FAIL —
  #   넓은 규칙이 곁에 붙으면 집합 검사가 무의미해진다.
  #   대상은 **원본 파일 + platform/policies의 kustomize 렌더 결과**다: Argo CD가 적용하는 것은 렌더 결과이고,
  #   `patches`·YAML merge key는 원본을 그대로 둔 채 렌더만 넓힐 수 있다(그때는 같은 위반이 file·rendered
  #   두 소스 라벨로 각각 보고된다 — 검사 3·3.5의 all 관례와 같다).
  #   ns 판정은 소스 종류마다 다르다:
  #     - 원본 파일: 표 밖 ns의 같은 이름 정책은 5.2의 EXCLUSIVE가 잡는다(POLICY_SETS의 allow-apiserver-webhook 행).
  #     - 렌더: 5.2가 원본만 보므로 5.6이 직접 본다 — (a) 표 밖 ns에 이 이름이 나타나면 FAIL(`kind: List` 풀림 ·
  #       patches의 ns 변경), (b) `platform/policies` 렌더에 표의 4개 ns가 모두 있어야 한다(이름·ns를 바꿔
  #       정책을 사라지게 하는 우회를 막는다). 경로를 정확 일치로 거는 이유는 중첩된 `platform/policies/tests`
  #       렌더에는 정책이 없기 때문이다.
  local f6=$N_FAIL wns wsrc wkind wport pns pport psrc rno pcsv ecnt ccsv npeer nexc protos nonint npure
  local miss extra bad dup c key cnt nfile=0 nrend=0
  local -A WPORT=() WEXP=() wseen=() wmatch=() cseen=() wsrcseen=()
  while read -r wns wsrc wkind; do
    [[ -n $wns ]] || continue
    wport=''
    while read -r pns pport psrc; do
      [[ -n $pns ]] || continue
      if [[ $pns == "$wns" && $psrc == "$wsrc" ]]; then wport=$pport; fi
    done <<< "$PORT_TABLE"
    if [[ -z $wport ]]; then
      fail "5.6 POL-webhook-port" "내부 표 불일치: ns '$wns'의 출처 '$wsrc' 행이 §포트 출처 각주 표에 없음(PORT_TABLE과 WEBHOOK_SRC_TABLE을 함께 고친다)"
      continue
    fi
    WPORT[$wns]=$wport
    if [[ $wkind == flannel ]]; then
      WEXP[$wns]="$NODE_A_PRIVATE_CIDR $NODE_A_FLANNEL_CIDR"
    else
      WEXP[$wns]="$NODE_A_PRIVATE_CIDR"
    fi
  done <<< "$WEBHOOK_SRC_TABLE"
  collect_rows "$YQ_NP_WEBHOOK_POL" "5.6 POL-webhook-src" all "$RE_LOC_POLICIES_ALL"
  while IFS="$YQ_SEP" read -r i ns; do
    [[ -n $i ]] || continue
    if [[ -z ${wsrcseen[$i]:-} ]]; then
      wsrcseen[$i]=1
      if [[ ${SRC_KIND[$i]} == rendered ]]; then nrend=$((nrend + 1)); else nfile=$((nfile + 1)); fi
    fi
    if [[ -z ${WPORT[$ns]:-} ]]; then
      # 렌더에만 보이는 표 밖 ns — 5.2(원본 파일 기준)가 볼 수 없는 자리다
      if [[ ${SRC_KIND[$i]} == rendered ]]; then
        fail "5.6 POL-webhook-src" "${SRC_LABEL[$i]} NetworkPolicy/$ns/allow-apiserver-webhook: 표 밖 ns(렌더 결과에만 보인다 — kind: List 풀림 · patches의 ns 변경. 5.2의 EXCLUSIVE는 원본 파일만 본다)"
      fi
      continue
    fi
    wseen["$i/$ns"]=1
  done < <(printf '%s' "$ROWS")
  collect_rows "$YQ_NP_WEBHOOK_RULE" "5.6 POL-webhook-src" all "$RE_LOC_POLICIES_ALL"
  while IFS="$YQ_SEP" read -r i ns rno pcsv ecnt ccsv npeer nexc protos nonint npure; do
    [[ -n $i ]] || continue
    [[ -n ${WPORT[$ns]:-} ]] || continue
    x="${SRC_LABEL[$i]} NetworkPolicy/$ns/allow-apiserver-webhook #$rno"
    if [[ ",$pcsv," != *",${WPORT[$ns]},"* ]]; then
      if [[ -z $pcsv ]]; then
        fail "5.6 POL-webhook-port" "$x: 계약 포트 ${WPORT[$ns]} 밖의 ingress 규칙 — ports 없음(전 포트 개방)"
      else
        fail "5.6 POL-webhook-port" "$x: 계약 포트 ${WPORT[$ns]} 밖의 ingress 규칙 — ports [$pcsv]"
      fi
      continue
    fi
    wmatch["$i/$ns"]=1
    [[ $pcsv == "${WPORT[$ns]}" ]] || fail "5.6 POL-webhook-port" "$x: ports 집합 [$pcsv] ≠ 계약 포트 {${WPORT[$ns]}}(여분 포트만큼 노드 A 출발 트래픽에 더 열린다)"
    [[ $ecnt == 0 ]] || fail "5.6 POL-webhook-port" "$x: endPort ${ecnt}개 금지(포트 범위 — 계약은 ns마다 단일 포트)"
    [[ $nonint == 0 ]] || fail "5.6 POL-webhook-port" "$x: 정수가 아닌 port ${nonint}개(숫자 문자열은 API 서버가 거절하고, named port는 계약 위반이다)"
    [[ $protos == TCP ]] || fail "5.6 POL-webhook-port" "$x: protocol [$protos] ≠ TCP(T045 D6: TCP 유지 — 계약은 protocol을 명시하지 않는다 · 생략은 TCP)"
    [[ $npeer == 0 ]] || fail "5.6 POL-webhook-peer" "$x: from에 ipBlock 아닌 peer ${npeer}개(podSelector·namespaceSelector 금지 · ipBlock과 selector를 한 peer에 섞는 것도 금지 — 출발지는 노드 주소 /32뿐)"
    [[ $nexc == 0 ]] || fail "5.6 POL-webhook-peer" "$x: ipBlock에 except ${nexc}개 금지(출발 집합은 /32 정확 일치)"
    # cidr는 RS로 이어져 오므로 값 단위로 본다(한 문자열에 쉼표로 여러 주소를 넣는 우회를 막는다)
    miss=''; extra=''; bad=''; dup=''; cnt=0; cseen=()
    IFS=$YQ_SEP2 read -r -a arr <<< "$ccsv"
    for c in "${arr[@]}"; do
      [[ -n $c ]] || continue
      cnt=$((cnt + 1))
      if [[ ! $c =~ $RE_CIDR ]]; then
        if [[ ", $bad," != *", $c,"* ]]; then bad+="${bad:+, }$c"; fi
        continue
      fi
      if [[ -n ${cseen[$c]:-} ]]; then
        if [[ ", $dup," != *", $c,"* ]]; then dup+="${dup:+, }$c"; fi
        continue
      fi
      cseen[$c]=1
    done
    if [[ -n $bad ]]; then
      # 형식이 깨진 값이 있으면 집합 비교는 하지 않는다(같은 결함을 빠짐·여분으로 두 번 보고하지 않는다)
      fail "5.6 POL-webhook-src" "$x: cidr 값 형식 위반 [$bad](IPv4 a.b.c.d/len 하나만 — 한 문자열에 여러 주소를 넣을 수 없다)"
    elif [[ $cnt != "$npure" ]]; then
      # 빈 문자열이거나 값 안에 구분자(RS)가 들어가 목록이 어긋난 경우 — 값 목록만 보면 "집합이 맞다"로 보인다
      fail "5.6 POL-webhook-src" "$x: cidr 값 형식 위반 — 순수 ipBlock peer ${npure}개인데 파싱된 cidr ${cnt}개(빈 문자열이거나 값 안에 구분자가 들어 있다)"
    else
      [[ -z $dup ]] || fail "5.6 POL-webhook-src" "$x: 중복 cidr $dup(같은 주소가 from에 두 번 이상 — 하네스 np-set-5는 다중집합으로 비교해 FAIL한다)"
      for c in ${WEXP[$ns]}; do
        [[ -n ${cseen[$c]:-} ]] || miss+="${miss:+, }$c"
      done
      for c in "${arr[@]}"; do
        [[ -n $c ]] || continue
        if [[ " ${WEXP[$ns]} " != *" $c "* && ", $extra," != *", $c,"* ]]; then extra+="${extra:+, }$c"; fi
      done
      if [[ -n $miss || -n $extra ]]; then
        fail "5.6 POL-webhook-src" "$x: 출발 ipBlock 집합 불일치 — 빠짐 [$miss] 여분 [$extra]"
      fi
    fi
  done < <(printf '%s' "$ROWS")
  while read -r wns _; do
    [[ -n $wns ]] || continue
    [[ -n ${WPORT[$wns]:-} ]] || continue
    for key in "${!wseen[@]}"; do
      [[ ${key#*/} == "$wns" ]] || continue
      [[ -z ${wmatch[$key]:-} ]] || continue
      fail "5.6 POL-webhook-port" "${SRC_LABEL[${key%%/*}]} NetworkPolicy/$wns/allow-apiserver-webhook: 계약 포트 ${WPORT[$wns]}을 가진 ingress 규칙이 없음(도달 경로가 통째로 막힌다)"
    done
  done <<< "$WEBHOOK_SRC_TABLE"
  # platform/policies 렌더에는 표의 4개 ns가 모두 있어야 한다(렌더에서 이름·ns를 바꿔 없애는 우회를 막는다).
  # 경로 정확 일치: 중첩된 platform/policies/tests 렌더에는 정책이 없다.
  for ((i = 0; i < SRC_N; i++)); do
    [[ ${SRC_KIND[$i]} == rendered && ${SRC_PATH[$i]} == platform/policies ]] || continue
    while read -r wns _; do
      [[ -n $wns && -n ${WPORT[$wns]:-} ]] || continue
      [[ -n ${wseen["$i/$wns"]:-} ]] || fail "5.6 POL-webhook-src" "${SRC_LABEL[$i]}: ns '$wns'에 allow-apiserver-webhook 없음(렌더에서 이름이나 ns가 바뀌었다 — 적용되는 것은 원본이 아니라 렌더다)"
    done <<< "$WEBHOOK_SRC_TABLE"
  done
  finish_group "5.6 POL-webhook-src" "allow-apiserver-webhook: 출발 ipBlock 집합 = 계약(webhook 3 ns는 노드 A private+flannel /32, vault 8200은 private /32) · ns마다 단일 TCP 포트 — webhook 정책을 담은 소스: 원본 ${nfile} · 렌더 ${nrend}" "$f6"
}

# -----------------------------------------------------------------------------
# 검사 6 — 작성자(봇) 경로 lint
# -----------------------------------------------------------------------------
check_6_author() {
  header 6 "작성자 검사(봇 PR은 apps/*/overlays/dev/kustomization.yaml의 images[].digest 줄만)"
  local fails_before=$N_FAIL is_bot=0 by_id=0 b f n=0 diff_text='' line content a_path b_path
  local pr_event=0 s_login=0 s_by_id=0 s_why='' msg snd_miss lbl_actor lbl_bot
  local -a arr_bots
  # PR 이벤트(또는 명시 요구)에서는 작성자와 이벤트 발신자가 모두 필수다(계약 — 조용한 비활성 금지)
  if [[ $GH_EVENT == pull_request || $GH_EVENT == pull_request_target || $REQUIRE_AUTHOR == 1 ]]; then pr_event=1; fi
  snd_miss="PR 이벤트(GITHUB_EVENT_NAME='$GH_EVENT', VALIDATE_REQUIRE_AUTHOR=$REQUIRE_AUTHOR)인데 PR_SENDER(이벤트 발신자 sender.login)가 비어 있음 — 발신자 판정의 조용한 비활성 금지(사람이 연 PR에 봇이 push한 경우를 가리지 못한다)"
  if [[ -z $PR_AUTHOR ]]; then
    # PR 이벤트(또는 명시 요구)인데 작성자가 비어 있으면 검사 6이 조용히 꺼진 것이므로 fail-closed
    if [[ $pr_event == 1 ]]; then
      fail "6 AUTHOR-input" "PR 이벤트(GITHUB_EVENT_NAME='$GH_EVENT', VALIDATE_REQUIRE_AUTHOR=$REQUIRE_AUTHOR)인데 PR_AUTHOR가 비어 있음 — 작성자 lint의 조용한 비활성 금지"
      # 발신자도 비었으면 함께 찍는다 — 하나를 고친 뒤에야 다른 하나가 보이는 일이 없게
      if [[ -z $PR_SENDER ]]; then fail "6 AUTHOR-input" "$snd_miss"; fi
      return 0
    fi
    # 계정 ID만 오고 로그인이 없으면 입력이 어긋난 것이다(워크플로는 둘을 함께 넘긴다) — 대상 없음으로 읽지 않는다
    if [[ -n $PR_AUTHOR_ID ]]; then
      fail "6 AUTHOR-input" "PR_AUTHOR_ID '$PR_AUTHOR_ID'만 있고 PR_AUTHOR가 비어 있음 — 작성자 입력이 어긋남(fail-closed)"
      return 0
    fi
    # 발신자만 오고 작성자가 없어도 같다(워크플로는 작성자·발신자를 함께 넘긴다)
    if [[ -n $PR_SENDER || -n $PR_SENDER_ID ]]; then
      fail "6 AUTHOR-input" "이벤트 발신자(PR_SENDER '$PR_SENDER' · PR_SENDER_ID '$PR_SENDER_ID')만 있고 PR_AUTHOR가 비어 있음 — 작성자 입력이 어긋남(fail-closed)"
      return 0
    fi
    pass "6 AUTHOR" "PR 작성자 미지정(push 이벤트 등) — 봇 경로 lint 대상 없음"
    return 0
  fi
  # PR_AUTHOR_ID(pull_request.user.id)는 선택 입력이다. 주어졌는데 숫자가 아니면 ID 판정을 할 수 없으므로 fail-closed
  if [[ -n $PR_AUTHOR_ID && ! $PR_AUTHOR_ID =~ ^[0-9]+$ ]]; then
    fail "6 AUTHOR-input" "PR_AUTHOR_ID '$PR_AUTHOR_ID'가 숫자가 아님(pull_request.user.id) — fail-closed"
    return 0
  fi
  # 이벤트 발신자(sender.login)는 PR 이벤트에서 필수다. PR 이벤트가 아니면(push 등) 비어도 된다 — 작성자로만 판정한다
  if [[ $pr_event == 1 && -z $PR_SENDER ]]; then
    fail "6 AUTHOR-input" "$snd_miss"
    return 0
  fi
  # PR_SENDER_ID(sender.id)는 선택 입력이다. 주어졌는데 숫자가 아니거나, 발신자 로그인 없이 ID만 있으면 fail-closed
  if [[ -n $PR_SENDER_ID && ! $PR_SENDER_ID =~ ^[0-9]+$ ]]; then
    fail "6 AUTHOR-input" "PR_SENDER_ID '$PR_SENDER_ID'가 숫자가 아님(sender.id) — fail-closed"
    return 0
  fi
  if [[ -n $PR_SENDER_ID && -z $PR_SENDER ]]; then
    fail "6 AUTHOR-input" "PR_SENDER_ID '$PR_SENDER_ID'만 있고 PR_SENDER가 비어 있음 — 발신자 입력이 어긋남(fail-closed)"
    return 0
  fi
  # 봇 판정(계약): 로그인이 봇 로그인 목록에 있음(대소문자 무시) 또는 계정 ID가 VALIDATE_BOT_IDS에 있음.
  # App 이름을 바꾸면 로그인은 바뀌지만 ID는 그대로다 — ID가 목록에 있으면 로그인이 무엇이든 봇이다.
  # 대상은 작성자(pull_request.user)와 이벤트 발신자(sender) 둘 다다 — App은 사람이 연 PR의 브랜치에 push하고 머지할 수 있다
  IFS=',' read -r -a arr_bots <<< "$BOT_AUTHORS"
  for b in "${arr_bots[@]}"; do
    if [[ ${PR_AUTHOR,,} == "${b,,}" ]]; then is_bot=1; fi
    if [[ -n $PR_SENDER && ${PR_SENDER,,} == "${b,,}" ]]; then s_login=1; fi
  done
  if [[ -n $PR_AUTHOR_ID ]]; then
    for b in "${BOT_ID_LIST[@]}"; do
      if [[ $PR_AUTHOR_ID == "$b" ]]; then by_id=1; fi
    done
  fi
  if [[ -n $PR_SENDER_ID ]]; then
    for b in "${BOT_ID_LIST[@]}"; do
      if [[ $PR_SENDER_ID == "$b" ]]; then s_by_id=1; fi
    done
  fi
  if [[ $is_bot == 0 && $by_id == 1 ]]; then
    printf "  봇 판정: 로그인 '%s' — 봇 로그인 목록 밖 · 계정 ID %s — VALIDATE_BOT_IDS 안 → 봇으로 본다\n" "$PR_AUTHOR" "$PR_AUTHOR_ID"
    is_bot=1
  fi
  # 봇 규칙 메시지의 주어: 작성자가 봇이면 기존 문구 그대로, 발신자 때문에 봇이면 발신자와 작성자를 함께 적는다
  lbl_actor="봇 작성자 '$PR_AUTHOR'"; lbl_bot="봇 '$PR_AUTHOR'"
  if [[ $is_bot == 0 && ( $s_login == 1 || $s_by_id == 1 ) ]]; then
    if [[ $s_login == 1 ]]; then s_why='로그인이 봇 로그인 목록 안'; fi
    if [[ $s_by_id == 1 ]]; then s_why+="${s_why:+ · }계정 ID ${PR_SENDER_ID} — VALIDATE_BOT_IDS 안"; fi
    printf "  봇 판정: 작성자 '%s'는 봇 아님 · 이벤트 발신자 '%s'는 봇(%s) → 발신자 기준으로 봇 PR로 본다 — PR 전체(merge-base ↔ head)에 봇 규칙을 적용한다\n" "$PR_AUTHOR" "$PR_SENDER" "$s_why"
    lbl_actor="봇 발신자 '$PR_SENDER'(작성자 '$PR_AUTHOR')"; lbl_bot=$lbl_actor
    is_bot=1
  fi
  if [[ $is_bot == 0 ]]; then
    msg="작성자 '$PR_AUTHOR'는 봇 아님 — 경로 제한 없음(ruleset·리뷰가 게이트)"
    if [[ -n $PR_AUTHOR_ID ]]; then msg+=" · 계정 ID ${PR_AUTHOR_ID}도 VALIDATE_BOT_IDS 밖"; fi
    if [[ -n $PR_SENDER ]]; then
      msg+=" · 이벤트 발신자 '$PR_SENDER'도 봇 아님"
      if [[ -n $PR_SENDER_ID ]]; then msg+="(계정 ID ${PR_SENDER_ID}도 VALIDATE_BOT_IDS 밖)"; fi
    else
      msg+=" · 이벤트 발신자 미지정(PR 이벤트 아님) — 작성자로만 판정"
    fi
    pass "6 AUTHOR" "$msg"
    return 0
  fi
  # 입력: CHANGED_DIFF(+CHANGED_FILES) 또는 git(VALIDATE_BASE_SHA·VALIDATE_HEAD_SHA). 없으면 fail-closed
  if [[ -n $CHANGED_DIFF ]]; then
    [[ -f $CHANGED_DIFF ]] || { fail "6 AUTHOR-input" "diff 파일 없음: $CHANGED_DIFF"; return 0; }
    diff_text=$(tr -d '\r' < "$CHANGED_DIFF")
  elif [[ -n $BASE_SHA && -n $HEAD_SHA ]]; then
    if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      fail "6 AUTHOR-input" "${lbl_actor}인데 git 저장소가 아니라 diff를 계산할 수 없음"
      return 0
    fi
    # merge-base ↔ HEAD(계약 §이미지·승격 전제 ③). 두 점 diff(BASE HEAD)는 PR 브랜치가 main 끝보다 뒤처져 있으면 main 쪽 변경의
    # 역까지 섞는다(정상 봇 PR이 main의 변경 때문에 FAIL한다). 입력 해석·merge-base·diff가 실패하면 set -e로 요약 없이 끝나지 않고
    # 6 AUTHOR-input FAIL로 남긴다(fail-closed). '-'로 시작하는 값은 git 옵션으로 읽히므로 해석 전에 거부하고, 해석은
    # `^{commit}`으로 커밋 객체를 실제로 읽어 본다(40자 hex는 객체가 없어도 형식만으로 풀리기 때문이다).
    # merge-base는 정확히 하나여야 한다(계약 판정 규칙 ①): `git merge-base --all`이 둘 이상이면(교차 이력) git merge-base는 그중
    # 하나를 골라 주는데, head 트리를 "고른 쪽 + digest 한 줄"로 만들면 그 diff는 깨끗하고 실제 머지 결과는 다른 파일을 바꾼다.
    # git diff 옵션 고정(규칙 ④) — 각 옵션이 막는 것:
    #   --no-ext-diff              diff.external·GIT_EXTERNAL_DIFF·diff.<driver>.command 가 출력을 대신 만들지 못한다
    #   --no-textconv              .gitattributes 의 diff=<driver> 에 설정된 textconv가 내용을 바꿔 보여 주지 못한다
    #   --no-renames               이름 변경을 옛 경로 삭제 + 새 경로 추가로 — 파일 목록에 옛 경로도 나온다(diff.renames 무시)
    #   --ignore-submodules=none   .gitmodules·설정의 submodule.<name>.ignore(all 등)가 gitlink 변경을 숨기지 못한다
    #   --no-color                 color.diff 설정이 색 코드를 넣지 못한다
    local -a sha_in=(VALIDATE_BASE_SHA "$BASE_SHA" VALIDATE_HEAD_SHA "$HEAD_SHA") sha_c=() mb_list=() diff_opts=(--no-ext-diff
      --no-textconv --no-renames --ignore-submodules=none --no-color)
    local k c mb mbs mb_rc=0
    for ((k = 0; k < ${#sha_in[@]}; k += 2)); do
      if [[ ${sha_in[k+1]} == -* ]]; then
        fail "6 AUTHOR-input" "${lbl_actor} — ${sha_in[k]} '${sha_in[k+1]}'가 '-'로 시작한다(git 옵션으로 읽힌다) — fail-closed"
        return 0
      fi
      if ! c=$(git -C "$ROOT" rev-parse --verify --quiet "${sha_in[k+1]}^{commit}"); then
        fail "6 AUTHOR-input" "${lbl_actor} — ${sha_in[k]} '${sha_in[k+1]}'가 이 저장소의 커밋으로 풀리지 않음(객체 없음 · 잘못된 값 · 얕은 체크아웃) — fail-closed"
        return 0
      fi
      sha_c+=("${c%$'\r'}")
    done
    mbs=$(git -C "$ROOT" merge-base --all "${sha_c[0]}" "${sha_c[1]}") || mb_rc=$?
    while IFS= read -r c; do
      c=${c%$'\r'}
      if [[ -n $c ]]; then mb_list+=("$c"); fi
    done <<< "$mbs"
    if [[ $mb_rc != 0 || ${#mb_list[@]} -eq 0 ]]; then
      if [[ $mb_rc == 1 ]]; then c='공통 조상 없음(얕은 체크아웃이면 이력이 모자라도 이렇게 나온다)'; else c="git merge-base exit $mb_rc"; fi
      fail "6 AUTHOR-input" "${lbl_actor} — merge-base 계산 실패: $c — VALIDATE_BASE_SHA '$BASE_SHA' · VALIDATE_HEAD_SHA '$HEAD_SHA' — fail-closed"
      return 0
    fi
    if [[ ${#mb_list[@]} -ne 1 ]]; then
      fail "6 AUTHOR-input" "${lbl_actor} — merge-base가 ${#mb_list[@]}개(git merge-base --all — 교차 이력): 정확히 하나여야 한다(하나를 골라 본 diff는 실제 머지 결과와 다를 수 있다) — VALIDATE_BASE_SHA '$BASE_SHA' · VALIDATE_HEAD_SHA '$HEAD_SHA' — fail-closed"
      return 0
    fi
    mb=${mb_list[0]}
    if [[ -z $CHANGED_FILES ]]; then
      if ! CHANGED_FILES=$(git -C "$ROOT" diff "${diff_opts[@]}" --name-only "$mb" "${sha_c[1]}" | tr -d '\r'); then
        fail "6 AUTHOR-input" "${lbl_actor} — 변경 파일 목록 계산 실패(git diff --name-only merge-base ${mb:0:12} ↔ HEAD ${sha_c[1]:0:12}) — fail-closed"
        return 0
      fi
    fi
    if ! diff_text=$(git -C "$ROOT" diff "${diff_opts[@]}" "$mb" "${sha_c[1]}" | tr -d '\r'); then
      fail "6 AUTHOR-input" "${lbl_actor} — diff 계산 실패(git diff merge-base ${mb:0:12} ↔ HEAD ${sha_c[1]:0:12}) — fail-closed"
      return 0
    fi
  fi
  if [[ -z $CHANGED_FILES || -z $diff_text ]]; then
    fail "6 AUTHOR-input" "${lbl_actor}인데 변경 파일 목록/diff 입력이 없음(CHANGED_FILES+CHANGED_DIFF 또는 VALIDATE_BASE_SHA+VALIDATE_HEAD_SHA) — fail-closed"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    n=$((n + 1))
    [[ $f =~ $RE_BOT_FILE ]] || fail "6 AUTHOR-file" "${lbl_bot}의 변경 파일 '$f' 불허(apps/*/overlays/dev/kustomization.yaml만)"
  done < <(printf '%s\n' "$CHANGED_FILES")
  [[ $n -gt 0 ]] || fail "6 AUTHOR-file" "${lbl_bot} PR에 변경 파일이 없음"
  # diff 파서(계약 판정 규칙 ②·③):
  #   - 상태: 'diff --git' 줄에서 머리 구간(in_hunk=0)으로 돌아가고, '@@' 줄 뒤는 hunk 구간(in_hunk=1)이다. hunk 구간에서는 '+'·'-'로
  #     시작하는 모든 줄이 내용이다('+++ '·'--- ' 포함 — 내용이 '++ '·'-- '로 시작하는 줄은 diff에서 파일 머리줄과 같은 모양이 된다).
  #     머리 구간의 '--- '·'+++ '·'index ' 줄은 머리줄이고, 머리 구간의 그 밖의 '+'·'-' 줄은 해석할 수 없는 줄이다.
  #   - 제자리 교체: hunk 안에서 '-' 줄 하나 바로 뒤에 '+' 줄 하나가 오는 쌍만 허용한다. 짝 없는 '-'(뒤에 문맥·'-'·hunk 끝이 옴)와
  #     짝 없는 '+'(앞에 '-'가 없음 — '+' 뒤의 '+' 포함)는 줄 형식이 맞아도 FAIL — digest 줄 삭제·다른 images 항목으로 옮김·'- digest:'
  #     목록 항목 삽입이 모두 여기 걸린다. 쌍의 두 줄이 모두 digest 줄이면 64hex 밖(들여쓰기·'- '·키·공백)이 같아야 한다 — 쌍이어도
  #     '    digest:'를 '  - digest:'로 바꾸면 새 images 항목이 되어 원래 항목의 고정이 풀린다.
  #     '\ No newline at end of file' 줄은 쌍 판정에서 건너뛴다(개행 없는 마지막 digest 줄의 교체는 '-'·'\'·'+'·'\' 모양이다).
  local in_hunk=0 pend='' pend_on=0 old_shape new_shape re_hex='^(.*sha256:)[0-9a-f]{64}(.*)$'
  while IFS= read -r line; do
    if [[ $in_hunk == 1 ]]; then
      case "$line" in
        "-"*)
          content=${line:1}
          [[ $content =~ $RE_BOT_LINE ]] || fail "6 AUTHOR-line" "봇 diff: images[].digest 외 줄 변경 불허 → '${content}'"
          if [[ $pend_on == 1 ]]; then
            fail "6 AUTHOR-line" "봇 diff: 제자리 교체만 허용 — 짝 없는 삭제 줄(바로 뒤에 추가 줄이 없다) → '${pend}'"
          fi
          pend=$content; pend_on=1
          continue ;;
        "+"*)
          content=${line:1}
          [[ $content =~ $RE_BOT_LINE ]] || fail "6 AUTHOR-line" "봇 diff: images[].digest 외 줄 변경 불허 → '${content}'"
          if [[ $pend_on == 0 ]]; then
            fail "6 AUTHOR-line" "봇 diff: 제자리 교체만 허용 — 짝 없는 추가 줄(바로 앞에 삭제 줄이 없다) → '${content}'"
          elif [[ $pend =~ $RE_BOT_LINE && $content =~ $RE_BOT_LINE ]]; then
            old_shape=$pend; new_shape=$content
            if [[ $pend =~ $re_hex ]]; then old_shape=${BASH_REMATCH[1]}${BASH_REMATCH[2]}; fi
            if [[ $content =~ $re_hex ]]; then new_shape=${BASH_REMATCH[1]}${BASH_REMATCH[2]}; fi
            if [[ $old_shape != "$new_shape" ]]; then
              fail "6 AUTHOR-line" "봇 diff: 제자리 교체만 허용 — digest 값 밖이 바뀐 교체 '${pend}' → '${content}'"
            fi
          fi
          pend_on=0
          continue ;;
        "\\"*) continue ;;
      esac
      # 그 밖의 줄에 닿으면 짝을 기다리던 삭제 줄은 짝이 없는 것이다
      if [[ $pend_on == 1 ]]; then
        fail "6 AUTHOR-line" "봇 diff: 제자리 교체만 허용 — 짝 없는 삭제 줄(바로 뒤에 추가 줄이 없다) → '${pend}'"
        pend_on=0
      fi
      case "$line" in
        " "*|""|"@@"*) continue ;;
        "diff --git "*) in_hunk=0 ;;
        *) fail "6 AUTHOR-line" "봇 diff: 해석할 수 없는 줄 → '$line'"; continue ;;
      esac
    fi
    case "$line" in
      "diff --git "*)
        a_path=${line#diff --git a/}; b_path=${a_path#* b/}; a_path=${a_path%% b/*}
        [[ $a_path == "$b_path" ]] || fail "6 AUTHOR-file" "봇 diff: 이름 변경 불허 ($a_path → $b_path)"
        [[ $b_path =~ $RE_BOT_FILE ]] || fail "6 AUTHOR-file" "봇 diff: 파일 '$b_path' 불허"
        ;;
      "new file mode"*|"deleted file mode"*|"rename "*|"similarity index"*|"Binary files"*|"old mode"*|"new mode"*)
        fail "6 AUTHOR-file" "봇 diff: 파일 추가·삭제·이름/모드 변경 불허 ($line)" ;;
      "@@"*) in_hunk=1 ;;
      "--- "*|"+++ "*|"index "*|" "*|"\\"*|"") ;;
      *) fail "6 AUTHOR-line" "봇 diff: 해석할 수 없는 줄 → '$line'" ;;
    esac
  done < <(printf '%s\n' "$diff_text")
  if [[ $pend_on == 1 ]]; then
    fail "6 AUTHOR-line" "봇 diff: 제자리 교체만 허용 — 짝 없는 삭제 줄(바로 뒤에 추가 줄이 없다) → '${pend}'"
  fi
  finish_group "6 AUTHOR" "${lbl_bot} PR: 변경 파일 ${n}개 모두 overlays/dev kustomization, 변경 줄 모두 images[].digest 값의 제자리 교체" "$fails_before"
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

  # 7.3 `secrets/<ns>/`의 단일 소유와 배달(설계 D3 조건 2). 네 갈래를 본다:
  #   (a) base 참조: `secrets/` 아래를 base(resources·bases·components)로 포함하는 kustomization은 배달자 하나뿐이고,
  #       **배달자 자신(`platform/secrets`)을 base로 끌어가는 것도 금지**다(전이 이중 소유 — 소비자 렌더에 ES가 들어간다).
  #       예외는 `secrets/<ns>/kustomization.yaml`이 **자기 디렉터리 안**의 파일을 가리키는 경우뿐이다.
  #       위치를 판정할 수 없는 항목(절대 경로 · 저장소 밖으로 나가는 상대 경로)은 fail-closed로 FAIL한다 —
  #       로컬에서는 렌더되지만 Argo repo-server의 체크아웃 경로에서는 같은 경로가 성립하지 않는다.
  #   (b) 소유자 대조(렌더 기준): `secrets/**` **파일**의 ExternalSecret과 같은 이름이 배달자 밖 소스(파일·렌더)에도
  #       있으면 FAIL. 파일 복사본 · 전이 base · helm 렌더로 두 Application이 같은 ES를 각자 적용하는 경로를 잡는다.
  #   (c) 죽은 선언(파일 단위): `secrets/**` 파일의 ES가 `platform/secrets` **렌더**에 없으면 FAIL —
  #       `secrets/` 바로 아래 파일 · `secrets/<ns>/sub/` · ns kustomization에 등록하지 않은 파일이 모두 여기 걸린다.
  #       kustomize가 없으면(렌더 0) 이 갈래는 돌지 않는다(5.6의 "원본 N · 렌더 M" 관례와 같다).
  #   (d) 적용 주체: `secrets` 또는 `secrets/*`를 가리키는 Application은 없어야 하고(multi-source의 두 번째 source 포함),
  #       배달자가 있으면 `source.path == platform/secrets`인 Application이 있어야 한다.
  #   (e) 구조 금지(계약 §validate.yml 4 · T045 G4): 배달자의 최상위 키는 `{apiVersion, kind, resources}`,
  #       `secrets/**`의 kustomization은 거기에 `namespace`까지만. 변환 키가 있으면 원본은 그대로인 채 배달자 **렌더에서만**
  #       store·`remoteRef`·`creationPolicy`가 바뀐다(3.2의 위치 판정은 원본 경로 기준이라 그 변형을 보지 못했다 — 같은 PR에서
  #       3.2에 배달자 렌더를 더해 결과도 함께 본다). YAML 맵으로 읽히지 않으면 fail-closed로 FAIL한다.
  #   디렉터리 단위 완전성((c)의 보완 · kustomize 없이도 도는 그물)은 **실제 저장소 루트에서는 항상** 본다.
  #   부분 트리 예외(배달자 구조를 쓰지 않는 픽스처)는 `--root`가 저장소 루트가 아닐 때만 적용한다.
  local f3=$N_FAIL nref=0 nown=0 nself=0 ndir=0 nin=0 nskip=0 owner=0 owner_rendered=0 napp_owner=0 nkey=0
  local nes_src=0 nes_render=0 kfile rk kdir entry r rd sdir msg3 i p ns name app apath kallow extra bases
  local -A SEC_INCLUDED=() ES_FILE_SRC=() ES_FILE_NS=() ES_OWNER_RENDER=() ES_FOREIGN=()
  if [[ -f "$ROOT/$SECRETS_OWNER_KUST" ]]; then owner=1; fi
  if need_tool "7.3 WAVE-secrets-base" yq; then
    # (a) base 참조. 항목은 문서를 explode(.)로 푼 뒤 읽는다(YQ_KUST_BASES) — 풀어 읽지 못하면 위치를 판정할 수 없으므로 FAIL(fail-closed)
    for kfile in "${KUST_FILES[@]}"; do
      rk=$(rel "$kfile"); kdir=$(dirname "$rk")
      [[ $kdir != . ]] || kdir=''
      if ! bases=$(yq_lines "$YQ_KUST_BASES" "$kfile"); then
        fail "7.3 WAVE-secrets-base" "$rk: base 항목(resources·bases·components)을 yq로 풀어 읽지 못했다 — secrets/ 아래를 가리키는지 판정할 수 없다(fail-closed · 맵이 아닌 문서 · 풀 수 없는 앵커·병합 키 등)"
        continue
      fi
      while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        case "$entry" in *://*|git@*) continue ;; esac   # 원격 base는 경로 판정 대상이 아니다
        if [[ $entry == /* ]]; then
          fail "7.3 WAVE-secrets-base" "$rk: base '$entry' — 절대 경로 금지(위치 판정 불가 · Argo repo-server의 체크아웃 경로에서는 성립하지 않는다)"
          continue
        fi
        r=$(norm_rel "$kdir" "$entry")
        if [[ -z $r ]]; then
          fail "7.3 WAVE-secrets-base" "$rk: base '$entry' — 저장소 밖으로 나가는 경로(위치 판정 불가 · 로컬에서만 렌더되고 Argo repo-server에서는 실패한다)"
          continue
        fi
        if [[ $rk != "$SECRETS_OWNER_KUST" && ( $r == "$SECRETS_OWNER_DIR" || $r == "$SECRETS_OWNER_DIR"/* ) ]]; then
          fail "7.3 WAVE-secrets-base" "$rk: base '$entry'(→ $r) — 배달자 $SECRETS_OWNER_DIR 를 base로 끌어가면 그 소비자 Application이 ExternalSecret을 함께 적용한다(전이 이중 소유)"
          continue
        fi
        [[ $r == "$SECRETS_SRC_DIR" || $r == "$SECRETS_SRC_DIR"/* ]] || continue
        nref=$((nref + 1))
        if [[ $rk == "$SECRETS_OWNER_KUST" ]]; then
          SEC_INCLUDED[$r]=1; nown=$((nown + 1))
        elif [[ -n $kdir && ( $r == "$kdir" || $r == "$kdir"/* ) ]]; then
          nself=$((nself + 1))   # `secrets/<ns>/kustomization.yaml`이 자기 디렉터리 안의 파일을 가리키는 것은 정상이다
        else
          fail "7.3 WAVE-secrets-base" "$rk: base '$entry'(→ $r) — secrets/ 아래를 base로 가질 수 있는 kustomization은 $SECRETS_OWNER_KUST 하나뿐이다(단일 소유 — 두 Application이 한 ExternalSecret을 각자 적용하면 소유권이 갈린다)"
        fi
      done <<< "$bases"
    done

    # (e) 변환 키 금지 — 배달자와 `secrets/**`의 kustomization은 base를 묶기만 한다(계약 §validate.yml 4 · T045 G4)
    for kfile in "${KUST_FILES[@]}"; do
      rk=$(rel "$kfile")
      if [[ $rk == "$SECRETS_OWNER_KUST" ]]; then kallow=$SECRETS_OWNER_KEYS
      elif [[ $rk == "$SECRETS_SRC_DIR"/* ]]; then kallow=$SECRETS_NS_KEYS
      else continue
      fi
      nkey=$((nkey + 1))
      if ! extra=$(yq -N "keys - $kallow | join(\",\")" "$kfile" 2>/dev/null); then
        fail "7.3 WAVE-secrets-base" "$rk: 최상위 키를 읽지 못했다(YAML 맵이 아니거나 파싱 실패) — 변환 키 검사 불가라 fail-closed"
        continue
      fi
      extra=$(printf '%s' "$extra" | tr -d '\n' | tr -s ',' ',')
      extra=${extra%,}; extra=${extra#,}
      [[ -z $extra ]] || fail "7.3 WAVE-secrets-base" "$rk: 최상위 키 '$extra' 금지 — 허용은 $kallow 뿐이다(배달자·secrets/<ns>는 base를 묶기만 한다: 계약 §validate.yml 4). 변환 키가 있으면 원본 파일은 그대로인 채 Argo가 적용하는 렌더에서만 store·remoteRef·creationPolicy가 바뀐다"
    done

    # (b)(c) ExternalSecret 소유자 대조. 이름으로 맞춘다 — `secrets/<ns>/kustomization.yaml`의 `namespace:` 변환기가
    #   원본 파일에 없던 ns를 렌더에서 채울 수 있어 (ns/name) 쌍으로는 정상 트리가 어긋난다(긍정 픽스처가 그 모양이다).
    for ((i = 0; i < SRC_N; i++)); do
      if [[ ${SRC_KIND[$i]} == rendered && ${SRC_PATH[$i]} == "$SECRETS_OWNER_DIR" ]]; then owner_rendered=1; fi
    done
    collect_rows "$YQ_ES" "7.3 WAVE-secrets-base" all
    while IFS="$YQ_SEP" read -r i _ ns name _ _ _ _ _ _; do
      [[ -n $i ]] || continue
      p=${SRC_PATH[$i]}
      if [[ ${SRC_KIND[$i]} == file && $p =~ $RE_LOC_SECRETS ]]; then
        ES_FILE_SRC[$name]=$p; ES_FILE_NS[$name]=$ns; nes_src=$((nes_src + 1))
      elif [[ ${SRC_KIND[$i]} == rendered && $p == "$SECRETS_OWNER_DIR" ]]; then
        ES_OWNER_RENDER[$name]=1; nes_render=$((nes_render + 1))
      elif [[ $p == "$SECRETS_OWNER_DIR" || $p =~ $RE_LOC_SECRETS ]]; then
        :   # 배달자 자신과 `secrets/<ns>` 렌더는 같은 소유자다 — 비교 대상이 아니다
      else
        ES_FOREIGN[$name]="${ES_FOREIGN[$name]:+${ES_FOREIGN[$name]}, }${SRC_LABEL[$i]}"
      fi
    done < <(printf '%s' "$ROWS")
    for name in "${!ES_FILE_SRC[@]}"; do
      if [[ -n ${ES_FOREIGN[$name]:-} ]]; then
        fail "7.3 WAVE-secrets-base" "ExternalSecret '${ES_FILE_NS[$name]}/$name'(원본 ${ES_FILE_SRC[$name]})이 배달자 밖 소스에도 있다: ${ES_FOREIGN[$name]} — 같은 ExternalSecret을 두 Application이 각자 적용한다(파일 복사본 · 전이 base · helm 렌더)"
      fi
      if [[ $owner_rendered == 1 && -z ${ES_OWNER_RENDER[$name]:-} ]]; then
        fail "7.3 WAVE-secrets-base" "${ES_FILE_SRC[$name]} ExternalSecret '$name': $SECRETS_OWNER_DIR 렌더에 없다 — 어떤 Application도 적용하지 않는 죽은 선언이다(배달자 또는 그 ns kustomization에 등록되지 않았다)"
      fi
    done

    # (d) 적용 주체 — Application의 모든 path
    collect_rows "$YQ_APP_PATHS" "7.3 WAVE-secrets-base" file
    while IFS="$YQ_SEP" read -r i app apath; do
      [[ -n $i ]] || continue
      if [[ $apath == "$SECRETS_SRC_DIR" || $apath == "$SECRETS_SRC_DIR"/* ]]; then
        fail "7.3 WAVE-secrets-base" "${SRC_LABEL[$i]} Application/$app: source.path '$apath' — secrets/<ns>의 적용 주체는 $SECRETS_OWNER_DIR 하나뿐이다(계약 §디렉터리 · multi-source의 두 번째 source도 포함)"
      fi
      if [[ $apath == "$SECRETS_OWNER_DIR" ]]; then napp_owner=$((napp_owner + 1)); fi
    done < <(printf '%s' "$ROWS")
    if [[ $owner == 1 && $napp_owner -eq 0 ]]; then
      fail "7.3 WAVE-secrets-base" "Application 없음 — source.path가 $SECRETS_OWNER_DIR 인 Application이 하나도 없다(배달자를 적용하는 주체가 없어 secrets/<ns>가 클러스터에 도달하지 않는다)"
    fi

    # 디렉터리 단위 완전성
    if [[ -d "$ROOT/$SECRETS_SRC_DIR" ]]; then
      for sdir in "$ROOT/$SECRETS_SRC_DIR"/*/; do
        sdir=${sdir%/}
        [[ -d $sdir ]] || continue
        [[ -n $(find "$sdir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit) ]] || continue
        rd=$(rel "$sdir"); ndir=$((ndir + 1))
        if [[ -n ${SEC_INCLUDED[$rd]:-} ]]; then nin=$((nin + 1)); continue; fi
        if [[ $owner == 1 ]]; then
          fail "7.3 WAVE-secrets-base" "$rd/: $SECRETS_OWNER_KUST 의 resources에 없음 — 어떤 Application도 적용하지 않는 죽은 선언이다(ExternalSecret이 git에만 있고 클러스터에는 오지 않는다)"
        elif [[ $ROOT == "$REPO_ROOT" || -d "$ROOT/$SECRETS_OWNER_DIR" || -f "$sdir/kustomization.yaml" ]]; then
          fail "7.3 WAVE-secrets-base" "$rd/: 배달자 $SECRETS_OWNER_KUST 가 없음 — 이 디렉터리를 적용하는 Application이 없다(죽은 선언)"
        else
          nskip=$((nskip + 1))   # 배달자 구조를 쓰지 않는 부분 트리(픽스처) — 완전성 검사 대상이 아니다
        fi
      done
    fi
    msg3="secrets/ 경로 base 참조 ${nref}건(배달자 ${nown} · secrets/<ns> 자기 디렉터리 ${nself}) · secrets/<ns> ${ndir}개 중 배달자 포함 ${nin}개 · secrets/** 파일 ES ${nes_src}개 ↔ 배달자 렌더 ES ${nes_render}개 · 배달자·secrets/** kustomization ${nkey}개 변환 키 없음"
    [[ $owner_rendered == 1 ]] || msg3+=" · 배달자 렌더 0(kustomize 없음이거나 배달자가 없는 트리 — 파일 단위 죽은 선언·소유자 대조는 돌지 않았다)"
    [[ $nskip -eq 0 ]] || msg3+=" · 배달자 구조가 아닌 트리라 완전성 검사 제외 ${nskip}개"
    finish_group "7.3 WAVE-secrets-base" "$msg3" "$f3"
  fi
}

# 7.4 Application은 source를 덮어쓰지 않는다(계약 §validate.yml 4 「(T046)」 둘째 줄 · 설계 t046 D8).
#   이 스크립트의 렌더 검사는 전부 `kustomize build <디렉터리>`를 본다. Argo는 Application의 `spec.source`로 렌더하므로
#   `kustomize.patches`·`helm.values`·`directory`·`plugin` 같은 키, 다른 `repoURL`·`targetRevision`, multi-source(`spec.sources`)
#   중 하나만 있어도 **적용되는 렌더 ≠ 검사한 렌더**가 된다(2026-09-28 검증 V-A2: Application에 args 패치를 넣은 미니 트리가
#   검사 10을 포함한 전체 PASS). 대상은 7.1과 같은 파일 열거(모든 YAML의 Application — 실제 트리에서는 clusters/oci-k3s/apps/*.yaml
#   과 bootstrap/root-app.yaml)에 **kustomize 렌더도 더한다**(렌더에서만 나타나는 Application도 Argo가 적용할 수 있다).
# `spec.source`를 건드리지 않고 적용 렌더를 바꾸는 두 경로도 막는다(2026-09-28 재검증 RB-1 — Argo CD v3.5.2 소스 판독, 라이브 미실측):
#   (a) 7.4 APP-source-file — source 경로 안의 `.argocd-source.yaml` · `.argocd-source-<앱 이름>.yaml`. repo-server가 매 렌더마다 이 파일을
#       source에 JSON merge patch로 합친다(reposerver/repository/repository.go `mergeSourceParameters` — Chart·Path·RepoURL·TargetRevision만
#       원래 값으로 되돌리고 kustomize·helm·directory·plugin은 남긴다). 파일 위치로는 어느 Application의 경로인지 가리지 않고
#       --root 트리(tests/·charts/·.git/ 제외 — 7.1의 파일 열거와 같은 제외) 어디에 있든 FAIL한다.
#   (b) 7.4 APP-source-hydrator — Application `spec.sourceHydrator`. 있으면 Argo는 `spec.source`보다 hydrator의 syncSource(다른 브랜치·
#       경로)를 먼저 쓴다(pkg/apis/application/v1alpha1/types.go `GetSource`).
#   (c) 7.4 APP-source-operation — Application **최상위** `operation`(spec 밖). `operation.sync.source`·`revision`·`manifests`로 한 번의
#       동기화 source를 바꾼다(2026-09-28 범위 한정 검증 DV-1 — types.go 필드 판독, 컨트롤러 동작은 라이브 미실측). Git에 선언하는
#       필드가 아니므로 키가 있으면(빈 맵 포함) FAIL한다.
#   ⚠ 이 목록이 Argo의 모든 우회 경로를 덮는다고 주장하지 않는다 — 형식별 정책(T047)은 검사 11 · 12.5가 맡는다.
# 7.4 혼자서는 보지 못하던 사각(코드로 확인)은 검사 11 · 12.5가 막는다(T047): `kind: List`로 감싼 Application과 kind와 무관한 최상위
#   items 목록(11.1 — 파일 단위 추출은 최상위 문서의 kind만 본다), directory source 경로의 `.json`·`.jsonnet`(11.3 — 파일 열거가
#   *.yaml·*.yml뿐인데 Argo directory source는 둘도 읽는다), ApplicationSet의 template(11.2 — kind가 Application인 문서만 본다),
#   경로에 `/charts/`가 든 곳의 `.argocd-source*.yaml`(12.5 — 이름이 charts인 디렉터리는 인플레이트 캐시 자리에만 있을 수 있다).
check_7_app_source() {
  header 7.4 "Application source 덮어쓰기 금지 — spec.source 키 = {${APP_SOURCE_KEYS//,/, }} · multi-source·sourceHydrator 금지 · repoURL·targetRevision 고정 · .argocd-source*.yaml 금지"
  local f4=$N_FAIL n=0 nsf=0 i name hs hss hh ho sk repo rev x p
  # (a) 파일 이름만 보므로 yq가 없어도 돈다(도구 없음 SKIP 모드에서도 이 갈래는 판정한다)
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    nsf=$((nsf + 1))
    fail "7.4 APP-source-file" "$(rel "$p"): Argo CD가 이 경로를 source로 쓰는 Application의 source 파라미터(kustomize·helm·directory·plugin)에 이 파일을 합친다 — Argo가 적용하는 렌더가 validate가 빌드한 렌더와 갈린다(파일 이름 .argocd-source.yaml · .argocd-source-<앱 이름>.yaml 금지)"
  done < <(find "$ROOT" \( -name '.argocd-source.yaml' -o -name '.argocd-source-*.yaml' \) -not -type d \
             -not -path '*/.git/*' -not -path "$ROOT/tests/*" -not -path '*/charts/*' | LC_ALL=C sort)
  need_tool "7.4 APP-source" yq || return 0
  collect_rows "$YQ_APP_SRC" "7.4 APP-source" all
  while IFS="$YQ_SEP" read -r i name hs hss hh ho sk repo rev; do
    [[ -n $i ]] || continue
    n=$((n + 1))
    x="${SRC_LABEL[$i]} Application/$name"
    if [[ $ho != false ]]; then
      fail "7.4 APP-source-operation" "$x: 최상위 operation 금지 — operation.sync(source·revision·manifests)는 한 번의 동기화 source를 바꿔 Argo가 적용하는 렌더가 validate가 빌드한 렌더와 갈린다(Git에 선언하는 필드가 아니다)"
    fi
    if [[ $hss != false ]]; then
      fail "7.4 APP-source-multi" "$x: spec.sources(multi-source) 금지 — 원소마다 저장소·리비전·오버라이드를 따로 둘 수 있어 Argo가 적용하는 렌더가 validate가 빌드한 렌더와 갈린다"
    fi
    if [[ $hh != false ]]; then
      fail "7.4 APP-source-hydrator" "$x: spec.sourceHydrator 금지 — Argo는 spec.source보다 hydrator의 syncSource(다른 브랜치·경로)를 먼저 써서 적용하는 렌더가 validate가 빌드한 렌더와 갈린다"
    fi
    if [[ $hs != true ]]; then
      [[ $hss != false ]] || fail "7.4 APP-source" "$x: spec.source 없음 — 판정할 source가 없다(fail-closed)"
      continue
    fi
    [[ $sk == "$APP_SOURCE_KEYS" ]] \
      || fail "7.4 APP-source" "$x: spec.source 키 [$sk] ≠ {${APP_SOURCE_KEYS//,/, }} — kustomize·helm·directory·plugin 같은 Application 수준 오버라이드는 Argo가 적용하는 렌더를 validate가 빌드한 렌더와 다르게 만든다(렌더를 보는 검사 3·5.6·9·10이 한꺼번에 무력해진다)"
    [[ $repo == "$APP_REPO_URL" ]] \
      || fail "7.4 APP-source-ref" "$x: spec.source.repoURL '$repo' ≠ $APP_REPO_URL(이 저장소 — 다른 저장소의 매니페스트는 이 검사를 거치지 않는다)"
    [[ $rev == "$APP_TARGET_REV" ]] \
      || fail "7.4 APP-source-ref" "$x: spec.source.targetRevision '$rev' ≠ $APP_TARGET_REV(리뷰·검사를 거치지 않은 브랜치·태그·커밋을 적용하는 길)"
  done < <(printf '%s' "$ROWS")
  finish_group "7.4 APP-source" "Application ${n}개(파일+렌더링) spec.source 키 = {${APP_SOURCE_KEYS//,/, }} · multi-source 없음 · repoURL = 이 저장소 · targetRevision = $APP_TARGET_REV · sourceHydrator·operation 없음 · .argocd-source*.yaml ${nsf}개" "$f4"
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
# 검사 9 — ClusterSecretStore(계약 §ClusterSecretStore 5개 표 · §이름·인증 규약)
#
# 왜 검사 3 그룹이 아닌가: 계약 §ExternalSecret 규약의 "7항목"과 3.1–3.7이 1:1이라 3.x를 더 쓰면 번호가 충돌한다
#   (같은 이유로 G3의 WAVE-secrets-base도 3 그룹 밖에 둔다 — 설계 R-12).
#
# 이 검사가 막는 것 중 **가장 중요한 하나**: vault store에서 `auth.kubernetes.serviceAccountRef.namespace`를 빠뜨리면
#   ESO 2.10.0은 'referent auth'로 보고 **로그인을 한 번도 하지 않은 채** `Ready=True / reason=Valid / "store validated"`를
#   찍는다. 라이브 status로는 정상 store와 구분되지 않으므로(`platform/secret-stores/README.md` §1) 이 정적 검사가
#   유일한 자동 방어선이다. CRD 스키마에도 필수 필드가 아니라 kubeconform으로는 잡히지 않는다.
# -----------------------------------------------------------------------------
check_9_clustersecretstores() {
  header 9 "ClusterSecretStore: 이름 집합·위치·provider별 인증 = 계약 §ClusterSecretStore 5개 표"
  need_tool "9 CSS" yq || return 0
  local i name ns pkeys x want_provider want_sa n=0 c p s rest
  local server vpath vver akeys mount role saname sans auds
  local rns url cans saks
  local -a arr
  local -A CSS_PROVIDER=() CSS_SA=() seen=()

  while read -r c p s; do
    [[ -n $c ]] || continue
    CSS_PROVIDER[$c]=$p; CSS_SA[$c]=$s
  done <<< "$CSS_TABLE"

  # 9.1 위치 · metadata.namespace · provider · 이름 집합
  local f1=$N_FAIL
  collect_rows "$YQ_CSS" "9.1 CSS-set" all
  while IFS="$YQ_SEP" read -r i name ns pkeys; do
    [[ -n $i ]] || continue
    n=$((n + 1))
    x="${SRC_LABEL[$i]} ClusterSecretStore/$name"
    [[ ${SRC_PATH[$i]} =~ $RE_LOC_SECRET_STORES ]] \
      || fail "9.1 CSS-location" "$x: ClusterSecretStore는 platform/secret-stores/ 에만 둔다(계약 §디렉터리) — 현재 위치 '${SRC_PATH[$i]}'"
    [[ $ns == "-" ]] \
      || fail "9.1 CSS-namespace" "$x: metadata.namespace '$ns' 금지 — ClusterSecretStore는 클러스터 범위다(전역 namespace 변환기 → 영구 OutOfSync)"
    want_provider=${CSS_PROVIDER[$name]:-}
    if [[ -z $want_provider ]]; then
      fail "9.1 CSS-set" "$x: 계약 §ClusterSecretStore 표에 없는 store 이름(vault-platform·vault-dev·vault-prod·vault-data·k8s-data-ca)"
    else
      if [[ ${SRC_PATH[$i]} =~ $RE_LOC_SECRET_STORES ]]; then seen[$name]=1; fi
      [[ $pkeys == "$want_provider" ]] \
        || fail "9.1 CSS-set" "$x: spec.provider [$pkeys] ≠ 표의 '$want_provider'(provider는 정확히 하나여야 하고 표와 같아야 한다)"
    fi
  done < <(printf '%s' "$ROWS")
  # 이름 집합은 `platform/secret-stores/` 디렉터리가 있을 때만 완전성을 요구한다(부분 트리 픽스처를 오탐하지 않게).
  if [[ -d "$ROOT/platform/secret-stores" ]]; then
    while read -r c rest; do
      [[ -n $c ]] || continue
      [[ -n ${seen[$c]:-} ]] \
        || fail "9.1 CSS-set" "platform/secret-stores/ 에 store '$c' 없음(계약 표 5개 — 이름 집합이 정확히 같아야 한다)"
    done <<< "$CSS_TABLE"
  fi
  finish_group "9.1 CSS-set" "ClusterSecretStore ${n}개(파일+렌더링): 위치 platform/secret-stores/ · metadata.namespace 없음 · 이름·provider = 계약 표 5개" "$f1"

  # 9.2 vault provider
  local f2=$N_FAIL nv=0
  collect_rows "$YQ_CSS_VAULT" "9.2 CSS-auth" all
  while IFS="$YQ_SEP" read -r i name server vpath vver akeys mount role saname sans auds; do
    [[ -n $i ]] || continue
    nv=$((nv + 1))
    x="${SRC_LABEL[$i]} ClusterSecretStore/$name"
    if [[ $sans == "-" || -z $sans ]]; then
      fail "9.2 CSS-auth-referent" "$x: auth.kubernetes.serviceAccountRef.namespace 없음 = referent auth — ESO가 로그인을 하지 않은 채 Ready=True/reason=Valid가 된다(라이브 status로는 드러나지 않는 가짜 PASS). '$CSS_SA_NS'를 반드시 적는다"
    elif [[ $sans != "$CSS_SA_NS" ]]; then
      fail "9.2 CSS-auth-referent" "$x: serviceAccountRef.namespace '$sans' ≠ $CSS_SA_NS(계약 §이름·인증 규약)"
    fi
    [[ $auds == "$CSS_VAULT_AUDIENCE" ]] \
      || fail "9.2 CSS-auth-audience" "$x: serviceAccountRef.audiences [$auds] ≠ [$CSS_VAULT_AUDIENCE] — Vault role의 audience와 다르면 403 'invalid audience (aud) claim'이다"
    [[ $akeys == "kubernetes" ]] \
      || fail "9.2 CSS-auth-method" "$x: auth 키 [$akeys] — kubernetes 하나여야 한다(계약 §이름·인증 규약)"
    [[ $mount == "$CSS_VAULT_MOUNT" ]] \
      || fail "9.2 CSS-auth-mount" "$x: auth.kubernetes.mountPath '$mount' ≠ $CSS_VAULT_MOUNT(Vault auth 마운트 경로)"
    if [[ $server != "$CSS_VAULT_SERVER" || $vpath != "$CSS_VAULT_PATH" || $vver != "$CSS_VAULT_VERSION" ]]; then
      fail "9.2 CSS-auth-server" "$x: server/path/version = '$server'/'$vpath'/'$vver' ≠ '$CSS_VAULT_SERVER'/'$CSS_VAULT_PATH'/'$CSS_VAULT_VERSION'(path+version이 다르면 ES의 remoteRef.key 접두 규약(3.1·3.2)이 깨진다)"
    fi
    want_sa=${CSS_SA[$name]:-}
    if [[ -n $want_sa && ( $role != "$want_sa" || $saname != "$want_sa" ) ]]; then
      fail "9.2 CSS-auth-map" "$x: role '$role' · serviceAccountRef.name '$saname' ≠ 계약 표의 '$want_sa'(store ↔ SA/role 매핑 — 뒤바뀌면 그 store가 다른 스코프의 Vault 정책으로 읽는다)"
    fi
  done < <(printf '%s' "$ROWS")
  finish_group "9.2 CSS-auth" "vault provider store ${nv}개(파일+렌더링): serviceAccountRef.namespace=$CSS_SA_NS · audiences=[$CSS_VAULT_AUDIENCE] · mountPath·server·path·version · store↔SA/role 매핑" "$f2"

  # 9.3 kubernetes provider
  local f3=$N_FAIL nk=0
  collect_rows "$YQ_CSS_K8S" "9.3 CSS-k8s" all
  while IFS="$YQ_SEP" read -r i name rns url cans akeys saname sans saks; do
    [[ -n $i ]] || continue
    nk=$((nk + 1))
    x="${SRC_LABEL[$i]} ClusterSecretStore/$name"
    [[ $akeys == "serviceAccount" ]] \
      || fail "9.3 CSS-k8s-auth" "$x: auth 키 [$akeys] — serviceAccount 하나여야 한다(CRD는 cert|serviceAccount|token 중 정확히 하나만 받는다)"
    [[ $sans == "$CSS_SA_NS" ]] \
      || fail "9.3 CSS-k8s-auth" "$x: auth.serviceAccount.namespace '$sans' ≠ $CSS_SA_NS(ClusterSecretStore에서는 생략하면 ES의 ns에서 SA를 찾는다)"
    [[ ",$saks," != *",audiences,"* ]] \
      || fail "9.3 CSS-k8s-audience" "$x: auth.serviceAccount에 audiences 금지 — 이 토큰은 apiserver에 bearer로 제시되므로 aud가 붙으면 401이다"
    if [[ $rns == "-" || -z $rns ]]; then
      fail "9.3 CSS-k8s-default" "$x: remoteNamespace 없음 — CRD 기본값이 'default'라 생략하면 조용히 엉뚱한 ns를 읽는다"
    elif [[ $rns != "$CSS_K8S_REMOTE_NS" ]]; then
      # 생략(위)만 막으면 `remoteNamespace: default`처럼 **잘못 적은** 값은 통과한다 — 계약 표의 값과 정확히 비교한다
      fail "9.3 CSS-k8s-remote" "$x: remoteNamespace '$rns' ≠ '$CSS_K8S_REMOTE_NS'(계약 §ClusterSecretStore 표 — CA 원본이 사는 ns)"
    fi
    [[ $url != "-" && -n $url ]] \
      || fail "9.3 CSS-k8s-default" "$x: server.url 없음 — CRD 기본값이 'kubernetes.default'(스킴·포트 없음)다"
    [[ $cans != "-" && -n $cans ]] \
      || fail "9.3 CSS-k8s-default" "$x: server.caProvider.namespace 없음 — CA는 기본값이 없고 ClusterSecretStore에서는 namespace가 필수다(비우면 시스템 루트로 떨어져 x509 실패)"
  done < <(printf '%s' "$ROWS")
  finish_group "9.3 CSS-k8s" "kubernetes provider store ${nk}개(파일+렌더링): auth=serviceAccount 하나(ns $CSS_SA_NS·audiences 없음) · remoteNamespace=$CSS_K8S_REMOTE_NS · server.url·caProvider.namespace 명시" "$f3"

  # 9.4 conditions(참조 허용 ns) = 계약 §ClusterSecretStore 표
  local f4=$N_FAIL nc=0 nconds ckeys nscsv miss extra dup v w
  local -A CSS_COND=() nsseen=()
  while read -r c p; do
    [[ -n $c ]] || continue
    CSS_COND[$c]=${p//,/ }
  done <<< "$CSS_COND_TABLE"
  # vault-platform = NS_TABLE − CSS_COND_PLATFORM_EXCLUDE (계약 문면 그대로 기계 유도 — 5.2의 ALL13과 같은 방식)
  p=" $NS_TABLE "
  for v in $CSS_COND_PLATFORM_EXCLUDE; do p=${p// $v / }; done
  CSS_COND[vault-platform]=$p
  collect_rows "$YQ_CSS_COND" "9.4 CSS-conditions" all
  while IFS="$YQ_SEP" read -r i name nconds ckeys nscsv; do
    [[ -n $i ]] || continue
    # 표 밖 이름은 9.1이 이미 잡았다(기대 ns 집합이 없다)
    [[ -n ${CSS_COND[$name]:-} ]] || continue
    nc=$((nc + 1))
    x="${SRC_LABEL[$i]} ClusterSecretStore/$name"
    if [[ $nconds == 0 ]]; then
      fail "9.4 CSS-conditions-count" "$x: spec.conditions 없음 — 비우면 **모든 네임스페이스**가 이 store를 쓸 수 있다(계약 §ClusterSecretStore 표의 참조 허용 ns가 무의미해진다)"
      continue
    fi
    [[ $nconds == 1 ]] \
      || fail "9.4 CSS-conditions-count" "$x: spec.conditions 항목 ${nconds}개 — 1개여야 한다(항목은 OR로 합쳐져 범위가 넓어진다)"
    if [[ $ckeys != "namespaces" ]]; then
      fail "9.4 CSS-conditions-key" "$x: conditions 항목 키 [$ckeys] — namespaces 하나만 쓴다(namespaceSelector·namespaceRegexes는 ns가 늘거나 라벨이 붙는 순간 조용히 범위가 넓어진다)"
    fi
    miss=''; extra=''; dup=''; nsseen=()
    IFS=',' read -r -a arr <<< "$nscsv"
    for v in "${arr[@]}"; do
      [[ -n $v ]] || continue
      if [[ -n ${nsseen[$v]:-} ]]; then
        if [[ ", $dup," != *", $v,"* ]]; then dup+="${dup:+, }$v"; fi
      else
        nsseen[$v]=1
      fi
    done
    [[ -z $dup ]] || fail "9.4 CSS-conditions-set" "$x: conditions.namespaces 중복 [$dup]"
    for w in ${CSS_COND[$name]}; do
      [[ -n ${nsseen[$w]:-} ]] || miss+="${miss:+, }$w"
    done
    for v in "${arr[@]}"; do
      [[ -n $v ]] || continue
      if [[ " ${CSS_COND[$name]} " != *" $v "* && ", $extra," != *", $v,"* ]]; then extra+="${extra:+, }$v"; fi
    done
    if [[ -n $miss || -n $extra ]]; then
      fail "9.4 CSS-conditions-set" "$x: conditions.namespaces 집합 불일치 — 빠짐 [$miss] 여분 [$extra](여분만큼 그 ns가 이 store로 비밀을 읽는다)"
    fi
  done < <(printf '%s' "$ROWS")
  finish_group "9.4 CSS-conditions" "store ${nc}개(파일+렌더링) conditions = 1항목 · namespaces 집합 = 계약 표(vault-platform은 네임스페이스 표에서 ${CSS_COND_PLATFORM_EXCLUDE// /·} 제외로 유도)" "$f4"
}

# -----------------------------------------------------------------------------
# 검사 10 — Reloader scoped 모드(계약 gitops-repo.md §네임스페이스 `platform/reloader/` 항목 · §validate.yml 4 「(T046)」)
#
# 왜 원본 values가 아니라 **렌더**를 보는가: 차트 2.2.16의 기본값이 `watchGlobally: true`이고 values 스키마가 키 오타를
#   막지 않는다(`additionalProperties: false` 없음). 부모 키 `reloader:` 오타·들여쓰기 실수처럼 `watchGlobally`와
#   `namespaces`가 **함께** 빠지면 렌더는 성공한 채 전역 모드(ClusterRole + ClusterRoleBinding · `--namespaces` 없음 ·
#   `--reload-strategy` 없음)로 돌아간다. `watchGlobally` 한 키만 틀리면(`watchGlobaly`) 차트의 `fail` 가드가 렌더를
#   멈추므로 10.0이 잡는다(2026-09-22 실측 — tests/fixtures/rel-scoped/). Argo가 적용하는 것은 렌더이므로 판정도 렌더로 한다.
# 범위: `platform/reloader` 렌더 하나(경로 정확 일치). 10.2는 Deployment reloader/reloader 첫 컨테이너의 args만 보므로, 그 시야 밖에서
#   감시 범위·권한을 넓히는 경로 — 이름이 다른 두 번째 Reloader · 두 번째 컨테이너 · `command` 안의 인자(2026-09-22 독립 리뷰
#   e1–e3) · 감시 ns 안의 추가 권한·다른 주체·와일드카드 · 여분 kind(HelmChart CR 등 — 2026-09-28 검증 V-A4·V-A5) — 는
#   10.3·10.4가 렌더 전체에서 닫는다.
# 10.2가 집합이 아니라 **목록 정확 일치**인 이유(2026-09-28 검증 V-A1·V-A3·V-A9, pflag v1.0.10 + Reloader v1.4.21 플래그 정의
#   하네스로 실측): 값 없는 `--log-format` 뒤의 `--namespaces=…`는 그 플래그의 **값으로 삼켜져** 감시 목록이 비고(전역 모드),
#   `$(VAR)`는 kubelet이 펼친 뒤 `--namespaces`를 하나 더 만들 수 있으며(목록 합침), `--auto-reload-all=true` 같은 여분 플래그는
#   어노테이션 없는 워크로드까지 재시작한다. 인자를 하나씩 세던 예전 검사는 셋 다 PASS시켰다.
# 한계: 라이브 — Application `status.resources`의 ClusterRole·ClusterRoleBinding 0과 Role `reloader-role` ns 집합, Deployment 인자는
#   모노레포 하네스 `reloader-2`가 본다. kind별 개수와 Reloader 시작 로그(실제로 감시하는 ns)는 상시 라이브 가드가 없다 — VD-9 판정 ⑥에서
#   한 번 실측했다(platform/reloader/README.md §3 판정 기록 · `reloader-2`는 개수와 로그를 보지 않는다).
#   정적으로 보지 않는 것: **다른 컴포넌트 렌더**가 ServiceAccount reloader/reloader에 주는 RoleBinding·ClusterRoleBinding(검사 13.5가
#   전 렌더 교차로 본다)과 그 안의 Reloader(이미지 — 여전히 보지 않는다), `reloader-metadata-role`의 규칙 내용(와일드카드만 본다), `stakater/reloader`가 아닌
#   이름으로 다시 올린 이미지를 **같은 파드의 두 번째 컨테이너**로 넣는 경우(두 번째 Deployment로 올리면 10.3의 개수가 잡는다),
#   `reloader-role` 4장을 **똑같이** 넓힌 규칙(서로 같은지만 본다 — README §1의 20줄 대조가 잡는다), 이름이 `reloader-role`이 아닌
#   Role의 규칙 내용(와일드카드만 본다 — 개수·ns를 유지한 채 바꿔 넣는 경우 포함).
#   Argo가 적용하는 렌더를 validate가 빌드한 렌더와 갈라놓는 Application 쪽 경로 — `spec.source`의 오버라이드 키 · 다른 repoURL·
#   targetRevision · multi-source · `spec.sourceHydrator` · 최상위 `operation` · `.argocd-source*.yaml` 파일 — 는 7.4가 막는다
#   (그 밖의 경로는 7.4 「보지 않는 것」 — 전수 열거는 T047).
# -----------------------------------------------------------------------------
check_10_reloader() {
  header 10 "Reloader(platform/reloader 렌더): ClusterRole·ClusterRoleBinding 0 · args 정확 일치 · kind 개수 · Role·RoleBinding ns 집합·주체·규칙 · Reloader 이미지 컨테이너 1개"
  local f0=$N_FAIL i idx=-1 kn kfile='' label rows line sel ndep ax row v w x kv
  local nargs=0 nctl=0 nns=0 nstr=0 ajson='' ejson='' wantcsv='' noeq dups dollar cf miss='' extra='' want
  local kind have rk rns rname rpath rimg rcmd repo nimg=0 hits='' hit1='' repo1=''
  local ntot=0 wtot=0 kmis='' kact='' kexp=''
  local rref rrefk rsubj esubj rrules rwild rrns=' ' nrr=0 best=-1 j
  local -a arr=() hv=() eargs=() ks=() rrns_list=() rrules_list=() rcnt=()
  local -A kcount=() kwant=() roleset=()
  for kn in kustomization.yaml kustomization.yml Kustomization; do
    if [[ -f "$ROOT/$REL_DIR/$kn" ]]; then kfile="$ROOT/$REL_DIR/$kn"; break; fi
  done
  if [[ -z $kfile ]]; then
    if [[ $ROOT == "$REPO_ROOT" ]]; then
      fail "10.0 REL-render" "$REL_DIR/kustomization.yaml 없음 — 계약 §네임스페이스의 platform/reloader 컴포넌트가 저장소에 없다(fail-closed)"
    else
      pass "10 REL" "$REL_DIR 없음 — 부분 트리(픽스처)라 대상 없음"
    fi
    return 0
  fi
  need_tool "10 REL" yq || return 0
  need_tool "10 REL" kustomize || return 0
  if grep -Eq '^[[:space:]]*helmCharts:' "$kfile"; then need_tool "10 REL" helm || return 0; fi
  for ((i = 0; i < SRC_N; i++)); do
    if [[ ${SRC_KIND[$i]} == rendered && ${SRC_PATH[$i]} == "$REL_DIR" ]]; then idx=$i; fi
  done
  if [[ $idx -lt 0 ]]; then
    fail "10.0 REL-render" "$REL_DIR 렌더 결과 없음 — kustomize build가 실패했다(검사 1의 KUST 줄 참조 · 차트의 fail 가드 포함). 판정할 대상이 없으므로 fail-closed"
    return 0
  fi
  label=${SRC_LABEL[$idx]}

  # 10.1 클러스터 범위 RBAC 0
  if ! rows=$(src_extract "$idx" 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + "/" + (.metadata.name // "-")'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(ClusterRole·ClusterRoleBinding) — fail-closed"
    return 0
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    fail "10.1 REL-clusterrbac" "$label $line: scoped 모드는 ClusterRole·ClusterRoleBinding 0이어야 한다 — 전역 모드로 돌아갔다(values 키 오타·watchGlobally 누락 · 계약 §네임스페이스 platform/reloader)"
  done <<< "$rows"

  # Deployment reloader/reloader 정확히 1개 — 없으면 인자를 판정할 수 없으므로 fail-closed
  sel="select(.kind == \"Deployment\" and .metadata.name == \"$REL_DEPLOY\" and (.metadata.namespace // \"-\") == \"$REL_RELEASE_NS\")"
  # ⚠ `select(...) | "D"`처럼 **문자열 리터럴**을 내보내면 yq v4는 선택되지 않은 문서마다에도 그 리터럴을 낸다(2026-09-22 실측,
  #   v4.53.6) — 문서 수가 세어진다. 그래서 선택된 문서의 필드(`.kind`)를 낸다.
  if ! rows=$(src_extract "$idx" "$sel | .kind"); then
    fail "10.0 REL-render" "$label: yq 추출 실패(Deployment) — fail-closed"
    return 0
  fi
  ndep=0
  while IFS= read -r line; do
    if [[ -n $line ]]; then ndep=$((ndep + 1)); fi
  done <<< "$rows"
  if [[ $ndep -eq 0 ]]; then
    fail "10.0 REL-render" "$label: Deployment $REL_RELEASE_NS/$REL_DEPLOY 없음 — 인자를 판정할 대상이 없으므로 fail-closed(fullnameOverride · helmCharts[].namespace 확인)"
    return 0
  elif [[ $ndep -gt 1 ]]; then
    fail "10.0 REL-render" "$label: Deployment $REL_RELEASE_NS/$REL_DEPLOY ${ndep}개 — 정확히 1개여야 한다"
    return 0
  fi
  # 10.2 REL-args-exact — 첫 컨테이너 args == 기대 목록(원소 수·순서·값). 비교는 yq가 낸 **JSON 한 줄**(`to_json(0)` — 개행·탭 같은
  #   제어 문자도 `\n` 등으로 이스케이프된다)로 한다. 셸에서 인자를 구분자로 이어 `read`로 나누면 개행이 든 인자에서 읽기가 끝나
  #   그 뒤 인자를 놓친다(2026-09-22 독립 리뷰 e5 — 가짜 PASS 실측).
  #   yq 한 번으로 9필드를 받는다: args JSON · 인자 수 · 제어 문자 인자 수 · '=' 없는 플래그(JSON) · 두 번 이상 나온 플래그 이름(JSON)
  #   · `$(`가 든 인자(JSON) · cloudflared가 든 인자(JSON) · --namespaces 인자 수 · --reload-strategy 인자 수. 뒤의 여덟은 불일치일 때
  #   **단서**로만 쓴다(판정은 JSON 정확 일치 하나다 — 인자를 하나씩 세던 예전 검사는 값 없는 플래그의 "다음 인자 삼킴"·`$(VAR)`
  #   치환·여분 플래그를 통과시켰다: 2026-09-28 검증 V-A1·V-A3·V-A9).
  #   ⚠ 수집자 `[...]`는 선택되지 않은 문서마다 빈 결과(빈 줄 — src_extract가 지운다)를 낸다(2026-09-22 실측, v4.53.6) —
  #   그래서 결과가 "9필드 한 줄"인지 확인하고, 아니면 fail-closed다.
  mapfile -t arr < <(printf '%s\n' $REL_WATCH_NS "$REL_RELEASE_NS" | LC_ALL=C sort -u)
  wantcsv=$(IFS=,; printf '%s' "${arr[*]}")
  eargs=("--log-level=$REL_LOG_LEVEL" "--namespaces=$wantcsv" "--reload-strategy=$REL_STRATEGY")
  ejson=$(printf '"%s",' "${eargs[@]}"); ejson="[${ejson%,}]"
  ax="$sel | ((.spec.template.spec.containers // [])[0].args // []) | map(tostring)"
  # shellcheck disable=SC2016  # `$(`는 yq 문자열 리터럴이다(셸 치환이 아니다)
  if ! row=$(src_extract "$idx" "$ax"' | [ to_json(0), (length | tostring), (map(select(test("[[:cntrl:]]"))) | length | tostring), (map(select(test("^-") and (test("=") | not))) | to_json(0)), (map(select(test("^-")) | sub("(?s)=.*$"; "")) | group_by(.) | map(select(length > 1) | .[0] + " ×" + (length | tostring)) | to_json(0)), (map(select(contains("$("))) | to_json(0)), (map(select(contains("cloudflared"))) | to_json(0)), (map(select(test("^--?namespaces(=|$)"))) | length | tostring), (map(select(test("^--?reload-strategy(=|$)"))) | length | tostring) ] | join(strenv(YQ_SEP))'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(args) — fail-closed"
    return 0
  fi
  if [[ $row == *$'\n'* ]] || ! IFS=$YQ_SEP read -r ajson nargs nctl noeq dups dollar cf nns nstr <<< "$row" \
     || [[ ! $nargs =~ ^[0-9]+$ || ! $nctl =~ ^[0-9]+$ || ! $nns =~ ^[0-9]+$ || ! $nstr =~ ^[0-9]+$ || $ajson != \[* ]]; then
    fail "10.0 REL-render" "$label: args 추출 결과가 9필드 한 줄이 아니다 — fail-closed"
    return 0
  fi
  x="$label Deployment/$REL_RELEASE_NS/$REL_DEPLOY"
  if [[ $nctl -gt 0 ]]; then
    fail "10.0 REL-args" "$x: 첫 컨테이너 args ${nargs}개 중 ${nctl}개에 제어 문자(개행·CR·탭 등) — 줄 단위 도구로는 값을 그대로 읽을 수 없다(fail-closed). 10.2는 이스케이프된 JSON으로 비교하므로 계속 판정한다"
  fi
  if [[ $ajson != "$ejson" ]]; then
    fail "10.2 REL-args-exact" "$x: 첫 컨테이너 args ≠ 기대 목록(원소 수·순서·값 정확 일치 — 계약 §validate.yml 4 「(T046)」) — 실제 $ajson(${nargs}개) · 기대 $ejson(${#eargs[@]}개)"
    [[ $noeq == '[]' ]] || fail "10.2 REL-args-exact" "$x: 단서 — '=' 없는 플래그 $noeq: 값을 받는 플래그(문자열·목록)는 **다음 인자를 값으로 삼킨다**(pflag) — 뒤의 --namespaces/--reload-strategy가 무력해진다(감시 목록이 비면 전역 모드 · 전략은 바이너리 기본값). bool 플래그만 예외다"
    [[ $dups == '[]' ]] || fail "10.2 REL-args-exact" "$x: 단서 — 같은 플래그 2개 이상 $dups: --namespaces는 목록이 **합쳐진다**(StringSlice — Reloader v1.4.21 util.go StringSliceVar · pflag v1.0.10은 두 번째 값부터 덧붙인다 → 감시 범위 확대) · --reload-strategy는 마지막 값이 이긴다(StringVar)"
    [[ $dollar == '[]' ]] || fail "10.2 REL-args-exact" "$x: 단서 — '\$(' 든 인자 $dollar: kubelet 환경 변수 치환 — 컨테이너 env로 펼쳐지므로 렌더만으로는 실행 시 인자를 알 수 없다(펼친 값이 --namespaces면 목록이 합쳐진다)"
    [[ $cf == '[]' ]] || fail "10.2 REL-args-exact" "$x: 단서 — cloudflared가 든 인자 $cf: 계약 위반 단서(cloudflared는 감시하지 않는다 — 터널 커넥터는 수동 1개씩 교체가 안전장치 · T045 G4)"
    [[ $nns -ne 0 ]] || fail "10.2 REL-args-exact" "$x: 단서 — --namespaces 인자 없음: 전역 모드(values 부모 키 오타의 모양 — ClusterRole과 함께 온다) 또는 KUBERNETES_NAMESPACE 단일 ns 모드"
    [[ $nstr -ne 0 ]] || fail "10.2 REL-args-exact" "$x: 단서 — --reload-strategy 인자 없음: 바이너리 기본 전략 env-vars(파드 템플릿 env를 바꾼다 — 계약은 $REL_STRATEGY)"
  fi

  # 10.3 REL-kinds — 렌더 전체의 kind별 개수 = REL_KINDS, 그 밖의 kind 0. 문서 1개 = 1행(kind · ns · name — 선택 없이 모든 문서).
  #   여분 객체는 그대로 적용된다: 감시 ns 안의 추가 Role·RoleBinding, 이름 바꾼 이미지의 두 번째 Reloader, K3s `HelmChart` CR(전역
  #   모드 차트를 따로 설치) 등은 10.2·10.4의 시야 밖이다(2026-09-28 검증 V-A4 b03·b04·c04·c10 — 넷 다 객체 수가 1 늘어난다).
  #   같은 행으로 10.4 REL-rbac-ns를 판정하고, Role 이름 집합(10.4 REL-rbac-bind)도 여기서 모은다.
  if ! rows=$(src_extract "$idx" '[ (.kind // "-"), (.metadata.namespace // "-"), (.metadata.name // "-") ] | join(strenv(YQ_SEP))'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(kind) — fail-closed"
    return 0
  fi
  for kv in $REL_KINDS; do
    kwant[${kv%%:*}]=${kv#*:}; wtot=$((wtot + ${kv#*:}))
    kexp+="${kexp:+ · }${kv%%:*} ${kv#*:}"
  done
  while IFS=$YQ_SEP read -r rk rns rname; do
    [[ -n $rk ]] || continue
    kcount[$rk]=$(( ${kcount[$rk]:-0} + 1 )); ntot=$((ntot + 1))
    if [[ $rk == Role ]]; then roleset["$rns/$rname"]=1; fi
  done <<< "$rows"
  mapfile -t ks < <(printf '%s\n' "${!kcount[@]}" "${!kwant[@]}" | LC_ALL=C sort -u)
  for rk in "${ks[@]}"; do
    [[ -n $rk ]] || continue
    [[ ${kcount[$rk]:-0} == "${kwant[$rk]:-0}" ]] || kmis+="${kmis:+, }$rk ${kcount[$rk]:-0}≠${kwant[$rk]:-0}"
    [[ -z ${kcount[$rk]:-} ]] || kact+="${kact:+ · }$rk ${kcount[$rk]}"
  done
  if [[ -n $kmis ]]; then
    fail "10.3 REL-kinds" "$label: kind별 개수 불일치 [$kmis] — 실제 {$kact}(합계 $ntot) · 기대 {$kexp}(합계 $wtot) · 그 밖의 kind 0. 여분 객체는 그대로 적용된다(감시 ns 안의 추가 권한 · 이름 바꾼 두 번째 Reloader · HelmChart CR 등)"
  fi

  # 10.4 REL-rbac-ns — 렌더 전체의 Role·RoleBinding(이름 무관) ns 집합 = REL_WATCH_NS + 릴리스 ns, kind마다 정확 일치.
  #   모노레포 하네스 reloader-2가 라이브 `status.resources`에서 보는 불변식과 같다(하네스는 Role `reloader-role`의 ns를 보고, 여기는
  #   이름과 무관하게 모든 Role·RoleBinding을 본다 — 이름을 바꾼 두 번째 Role도 센다). 같은 ns의 두 번째 Role(`reloader-metadata-role`)은
  #   집합이라 한 번만 센다. ns가 없는 객체는 '-'로 세어 여분이 된다. 행은 10.3에서 뽑은 것을 그대로 쓴다.
  want="$REL_WATCH_NS $REL_RELEASE_NS"
  for kind in Role RoleBinding; do
    have=' '
    while IFS=$YQ_SEP read -r rk rns rname; do
      [[ $rk == "$kind" ]] || continue
      [[ $have == *" $rns "* ]] || have+="$rns "
    done <<< "$rows"
    miss=''; extra=''
    read -r -a hv <<< "$have"
    for w in $want; do
      [[ $have == *" $w "* ]] || miss+="${miss:+, }$w"
    done
    for v in "${hv[@]}"; do
      [[ " $want " == *" $v "* ]] || extra+="${extra:+, }$v"
    done
    if [[ -n $miss || -n $extra ]]; then
      fail "10.4 REL-rbac-ns" "$label: $kind ns 집합 불일치 — 빠짐 [$miss] 여분 [$extra](기대 = 계약 목록 ${REL_WATCH_NS// /·} + 릴리스 ns $REL_RELEASE_NS · 모노레포 하네스 reloader-2와 같은 불변식. 여분 ns에는 Reloader 권한이 생기고, 빠진 ns는 감시해도 권한이 없다)"
    fi
  done

  # 10.4 REL-rbac-bind — 모든 RoleBinding은 같은 ns에 렌더된 Role을 가리키고(roleRef.kind = Role) 주체는 정확히
  #   [ServiceAccount reloader/reloader]다. ClusterRole을 가리키면 렌더되지 않은 권한(예: cluster-admin)이 감시 ns에 붙고, 다른 주체를
  #   넣으면 그 주체가 Reloader 권한(그 ns의 Secret 전부 읽기 · Deployment patch)을 얻는다 — 둘 다 ns 집합은 그대로라 REL-rbac-ns로는
  #   보이지 않는다(2026-09-28 검증 V-A4 b03·b04). subjects는 원소마다 키를 정렬한 JSON으로 비교한다(값에 구분자를 넣어 문자열을
  #   맞추는 우회를 막는다).
  esubj="[{\"kind\":\"ServiceAccount\",\"name\":\"$REL_SA\",\"namespace\":\"$REL_RELEASE_NS\"}]"
  if ! rows=$(src_extract "$idx" 'select(.kind == "RoleBinding") | [ .kind, (.metadata.namespace // "-"), (.metadata.name // "-"), ((.roleRef // {}).kind // "-"), ((.roleRef // {}).name // "-"), ((.subjects // []) | map(to_entries | sort_by(.key) | from_entries) | to_json(0)) ] | join(strenv(YQ_SEP))'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(RoleBinding) — fail-closed"
    return 0
  fi
  while IFS=$YQ_SEP read -r rk rns rname rrefk rref rsubj; do
    [[ $rk == RoleBinding ]] || continue
    x="$label RoleBinding/$rns/$rname"
    if [[ $rrefk != Role ]]; then
      fail "10.4 REL-rbac-bind" "$x: roleRef.kind '$rrefk' ≠ Role — ClusterRole을 가리키면 렌더되지 않은 권한(예: cluster-admin)이 그 ns에 붙는다"
    elif [[ -z ${roleset["$rns/$rref"]:-} ]]; then
      fail "10.4 REL-rbac-bind" "$x: roleRef Role '$rref'가 같은 ns($rns)에 렌더돼 있지 않다 — 렌더 밖 Role의 권한은 이 검사가 볼 수 없다"
    fi
    [[ $rsubj == "$esubj" ]] \
      || fail "10.4 REL-rbac-bind" "$x: subjects $rsubj ≠ $esubj — 다른 주체가 Reloader 권한(그 ns의 Secret 전부 읽기 · Deployment patch)을 얻는다"
  done <<< "$rows"

  # 10.4 REL-rbac-rules — Role `reloader-role`이 감시 ns + 릴리스 ns마다 있고 rules가 서로 같다(차트가 한 템플릿으로 찍는다 — 한 ns만
  #   다르면 patches로 그 ns만 넓힌 것이다) · 어떤 Role에도 apiGroups·resources·verbs에 `*`가 든 값이 없다(2026-09-28 검증 V-A5 b05:
  #   jt-prod Role에 `*`/`*`/`*` 규칙을 더해도 예전 검사는 PASS였다). 규칙 비교는 원소마다 키를 정렬한 JSON이다(목록 안 순서는
  #   보존한다 — 차트가 같은 순서로 찍는다). `reloader-metadata-role`의 규칙 내용은 와일드카드만 본다.
  if ! rows=$(src_extract "$idx" 'select(.kind == "Role") | [ .kind, (.metadata.namespace // "-"), (.metadata.name // "-"), ((.rules // []) | map(to_entries | sort_by(.key) | from_entries) | to_json(0)), ([ (.rules // [])[] | ((.apiGroups // []) + (.resources // []) + (.verbs // []))[] | tostring | select(contains("*")) ] | unique | to_json(0)) ] | join(strenv(YQ_SEP))'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(Role rules) — fail-closed"
    return 0
  fi
  while IFS=$YQ_SEP read -r rk rns rname rrules rwild; do
    [[ $rk == Role ]] || continue
    x="$label Role/$rns/$rname"
    [[ $rwild == '[]' ]] \
      || fail "10.4 REL-rbac-rules" "$x: apiGroups·resources·verbs에 와일드카드 $rwild — Role은 리소스·동사를 이름으로 나열한다(차트 2.2.16 기본 규칙에는 '*'가 없다)"
    [[ $rname == "$REL_ROLE" ]] || continue
    [[ $rrns == *" $rns "* ]] || rrns+="$rns "
    rrns_list+=("$rns"); rrules_list+=("$rrules")
  done <<< "$rows"
  # 기준 = 가장 많은 `reloader-role`이 가진 규칙(동률이면 릴리스 ns의 것). 렌더 순서의 첫 Role을 기준으로 삼으면 여분 ns(예: cloudflared)가
  #   먼저 나올 때 정상인 넷이 전부 "다르다"로 보고된다 — 다른 장만 짚어야 원인이 보인다. 장 수가 작아(ns 수) 쌍마다 비교한다.
  nrr=${#rrules_list[@]}
  for ((i = 0; i < nrr; i++)); do
    rcnt[i]=0
    for ((j = 0; j < nrr; j++)); do
      if [[ ${rrules_list[j]} == "${rrules_list[i]}" ]]; then rcnt[i]=$((rcnt[i] + 1)); fi
    done
  done
  best=-1
  for ((i = 0; i < nrr; i++)); do
    if (( best < 0 )) || (( rcnt[i] > rcnt[best] )); then
      best=$i
    elif (( rcnt[i] == rcnt[best] )) && [[ ${rrns_list[i]} == "$REL_RELEASE_NS" ]]; then
      best=$i
    fi
  done
  for ((i = 0; i < nrr; i++)); do
    if [[ ${rrules_list[i]} != "${rrules_list[best]}" ]]; then
      fail "10.4 REL-rbac-rules" "$label Role/${rrns_list[i]}/$REL_ROLE: rules ≠ 다수 규칙(${rcnt[best]}/${nrr}장 — 예: Role/${rrns_list[best]}/$REL_ROLE) — 감시 ns마다 같은 규칙이어야 한다(한 ns만 넓히거나 좁힌 권한) — 이 Role ${rrules_list[i]} · 다수 ${rrules_list[best]}"
    fi
  done
  miss=''
  for w in $want; do
    [[ $rrns == *" $w "* ]] || miss+="${miss:+, }$w"
  done
  [[ -z $miss ]] \
    || fail "10.4 REL-rbac-rules" "$label: Role $REL_ROLE 없는 ns [$miss] — 감시 ns·릴리스 ns마다 있어야 규칙 대조가 성립한다(이름을 바꾼 Role은 대조 밖이다)"

  # 10.4 REL-image — 렌더 전체에서 이미지 저장소가 `…/stakater/reloader`인 컨테이너가 정확히 1개이고, 그것이 Deployment
  #   reloader/reloader의 containers[0](10.2가 보는 자리)이며, 저장소 = REL_IMAGE_REPO, `command`가 없다.
  #   닫는 가짜 PASS(2026-09-22 독립 리뷰 실측): 이름이 다른 두 번째 Reloader Deployment(e1) · 같은 파드의 두 번째 컨테이너(e3)
  #   · `command` 안의 `--namespaces=`(e2 — args는 command 뒤에 붙으므로 pflag가 두 목록을 합친다).
  #   대상 = 렌더의 모든 `image` 키(containers·initContainers 등 — 위치를 경로로 보고한다). 저장소는 digest(`@…`)와 마지막 경로
  #   조각의 태그(`:…`)를 뗀 값이다(레지스트리 포트 `:5000`은 남는다).
  # shellcheck disable=SC2016  # $k·$ns·$n 은 yq 변수다
  if ! rows=$(src_extract "$idx" '(.kind // "-") as $k | (.metadata.namespace // "-") as $ns | (.metadata.name // "-") as $n | .. | select(tag == "!!map") | select(has("image")) | [ $k, $ns, $n, (path | join(".")), (.image | tostring), (has("command") | tostring) ] | join(strenv(YQ_SEP))'); then
    fail "10.0 REL-render" "$label: yq 추출 실패(image) — fail-closed"
    return 0
  fi
  while IFS=$YQ_SEP read -r kind rns rname rpath rimg rcmd; do
    [[ -n $kind ]] || continue
    repo=${rimg%%@*}
    if [[ ${repo##*/} == *:* ]]; then repo=${repo%:*}; fi
    [[ $repo =~ $REL_IMAGE_ANY_RE ]] || continue
    nimg=$((nimg + 1))
    hits+="${hits:+, }$kind/$rns/$rname $rpath"
    hit1="$kind/$rns/$rname $rpath"; repo1=$repo
    if [[ $rcmd == true ]]; then
      fail "10.4 REL-image" "$label $kind/$rns/$rname $rpath: command 있음 — Reloader 컨테이너는 command를 두지 않는다(args는 command 뒤에 붙으므로 command 안의 --namespaces=는 10.2가 보지 않은 채 pflag가 목록을 합친다 · 감시 범위 확대)"
    fi
  done <<< "$rows"
  if [[ $nimg -ne 1 ]]; then
    fail "10.4 REL-image" "$label: Reloader 이미지(…/stakater/reloader) 컨테이너 ${nimg}개 [$hits] — 렌더 전체에서 정확히 1개(Deployment/$REL_RELEASE_NS/$REL_DEPLOY spec.template.spec.containers.0)여야 한다(10.2는 그 컨테이너의 args만 본다 — 다른 Reloader는 다른 ns를 감시할 수 있다)"
  else
    if [[ $hit1 != "Deployment/$REL_RELEASE_NS/$REL_DEPLOY spec.template.spec.containers.0" ]]; then
      fail "10.4 REL-image" "$label: Reloader 이미지 컨테이너가 '$hit1'에 있다 — Deployment/$REL_RELEASE_NS/$REL_DEPLOY spec.template.spec.containers.0이어야 한다(10.2가 보는 자리 — 그 자리의 미끼 컨테이너가 기대 args를 가져도 실제 Reloader는 다른 인자로 돈다)"
    fi
    if [[ $repo1 != "$REL_IMAGE_REPO" ]]; then
      fail "10.4 REL-image" "$label $hit1: 이미지 저장소 '$repo1' ≠ $REL_IMAGE_REPO(차트 2.2.16 기본 image.repository)"
    fi
  fi

  finish_group "10 REL" "$label: ClusterRole·ClusterRoleBinding 0 · Deployment $REL_RELEASE_NS/$REL_DEPLOY args = $ejson · kind {$kexp}(합계 $wtot) · Role·RoleBinding ns 집합 = {${want// /,}} · RoleBinding → 같은 ns의 Role · 주체 = ServiceAccount $REL_RELEASE_NS/$REL_SA · $REL_ROLE 규칙 동일·와일드카드 없음 · Reloader 이미지 컨테이너 1개(containers.0 · command 없음)" "$f0"
}

# -----------------------------------------------------------------------------
# 검사 11 — 형식별 정책(계약 §validate.yml 4 「(T047) 형식별 정책」 — Argo가 읽을 수 있는 형식마다 "검사한다" 또는 "금지한다")
#
# 계약 표의 행 ↔ 막는 곳: 목록 객체(--root 트리의 모든 YAML) → 11.1 · ApplicationSet(파일 + 렌더) → 11.2 · directory source 경로의
#   *.json·*.jsonnet·*.libsonnet과 하위 디렉터리 → 11.3 · directory source 경로 YAML의 kind(Application만) → 11.4 · 심볼릭 링크(트리 어디든) → 11.5
#   (directory source 경로 바로 아래의 링크는 11.3도 건다 — 코드가 달라 두 줄이 나온다). 나머지 행(*.yaml 최상위
#   문서 · 렌더의 Application · kustomization이 가리키는 *.json)은 기존 검사(7.1 · 2 · 7.4 · 렌더 기반 검사)가 본다.
# directory source 경로 = Application(파일 + 렌더 — 7.4와 같은 집합)의 source path 중 kustomization 파일(kust_file_in의 이름 3개)이 **없는**
#   디렉터리. Argo는 그 경로를 렌더 없이 디렉터리째 읽는다(argo-cd v3.5.2 reposerver/repository/repository.go findManifests —
#   `^.*\.(yaml|yml|json|jsonnet)$` · 저장소 안을 가리키는 심볼릭 링크는 따라간다 · directory.recurse가 없으면 하위 디렉터리를 읽지 않는다).
#   그래서 11.3은 파일 열거(YAML_FILES — tests/·charts/ 제외 · 일반 파일만)가 아니라 그 디렉터리의 목록을 직접 본다. 그 목록의 **심볼릭 링크는
#   금지**다(계약 형식별 정책 「심볼릭 링크」 행 중 이 경로 — 2026-09-30 G4 리뷰 A2): 파일 열거는 링크를 세지 않는데 Argo는 링크를
#   따라 읽으므로, 링크된 Application은 kind 판정(11.4)만 받고 2 · 7.1 · 7.4의 판정을 지나 적용된다. 11.4는 일반 파일만 본다(링크를 따라가지 않는다).
# 11.x의 문서 판정은 앵커·별칭·병합 키를 explode(.)로 푼 문서로 한다(YQ_DOCS · 「앵커·별칭·병합 키」 주석). 풀지 못하는 문서는 11.0 FMT-alias가 건다.
# 11.1 보강 — 계약 문면(`kind: List` · `<Kind>List` + items)보다 넓다(2026-09-29 소스 판독 · kustomize 실측): Argo는 kind와 무관하게
#   최상위 items가 목록이면 그 원소를 풀어 적용하고 감싼 문서는 버린다(repository.go GenerateManifests `case obj.IsList():` —
#   apimachinery v0.36.1 Unstructured.IsList는 items가 []interface{}인지만 본다. directory source와 kustomize 렌더에 똑같이 걸린다).
#   kustomize 5.8.1은 `<Kind>List`만 풀고 그 밖의 kind는 items를 그대로 내보낸다 — `kind: ConfigMap` + `items: [Role]`은 렌더에서 ConfigMap으로
#   보이는데 Argo는 Role을 적용한다. 그래서 11.1은 kind와 무관한 최상위 items 목록을 파일과 렌더 양쪽에서 금지하고(계약의 <Kind>List + items를
#   포함), 11.4는 directory source 경로의 Application에 items 목록이 있어도 FAIL한다.
# 보지 않는 것은 tests/README.md 「검사 11이 보지 않는 것」.
# -----------------------------------------------------------------------------
DOC_ROWS=''; DOC_ROWS_DONE=0
collect_doc_rows() { # 검사 11 · 12.3 공용: 모든 소스(파일 + 렌더)의 문서 1개 = 1행(YQ_DOCS — "idx<US>행") — 한 번만 모은다.
  #   yq 실패(문서를 explode(.)로 풀지 못함 · YAML로 읽지 못함)는 11.0 FAIL(fail-closed — 목록 객체인지 판정할 수 없다). 11.1의 그룹 구간 안에서
  #   부르므로 11.1 PASS 줄도 나오지 않는다
  local i rows line
  if [[ $DOC_ROWS_DONE == 0 ]]; then
    DOC_ROWS=''
    for ((i = 0; i < SRC_N; i++)); do
      if ! rows=$(src_extract "$i" "$YQ_DOCS"); then
        fail "11.0 FMT-alias" "${SRC_LABEL[$i]}: yq로 문서를 풀어 읽지 못했다(explode — 맵이 아닌 값을 가리키는 병합 키 등 · 또는 YAML로 읽히지 않는다) — 목록 객체인지 · kind가 무엇인지 판정할 수 없다(fail-closed)"
        continue
      fi
      [[ -n $rows ]] || continue
      while IFS= read -r line; do
        DOC_ROWS+="${i}${YQ_SEP}${line}"$'\n'
      done < <(printf '%s\n' "$rows")
    done
    DOC_ROWS_DONE=1
  fi
}
check_11_formats() {
  header 11 "형식별 정책 — 목록 객체 · ApplicationSet · directory source 경로(심볼릭 링크 · .json·.jsonnet·.libsonnet · 하위 디렉터리 · Application만)"
  # 11.5(심볼릭 링크)는 yq가 필요 없다 — yq가 없어도 돈다
  need_tool "11 FMT" yq || { check_11_symlinks; return 0; }
  local i idx nk tg hk kd av ik nm why x nf=0 nr=0 nd=0
  for ((i = 0; i < SRC_N; i++)); do
    if [[ ${SRC_KIND[$i]} == file ]]; then nf=$((nf + 1)); else nr=$((nr + 1)); fi
  done

  # 11.1 목록 객체 — 파일 + 렌더. kind: List는 items가 없어도, 그 밖의 kind는 최상위 items가 목록(시퀀스)이면 FAIL
  local f1=$N_FAIL
  collect_doc_rows
  while IFS="$YQ_SEP" read -r i idx nk tg hk kd av ik nm; do
    [[ -n $i && $nk == map ]] || continue
    nd=$((nd + 1))
    if [[ $ik == alias ]]; then
      fail "11.0 FMT-alias" "${SRC_LABEL[$i]} 문서 #$idx kind '$kd': 최상위 items가 풀리지 않은 별칭으로 남았다 — 목록 객체인지 판정할 수 없다(fail-closed · Argo의 디코더는 별칭을 풀어 읽는다)"
      continue
    fi
    why=''
    if [[ $kd == List ]]; then why='kind: List — items 유무와 무관'
    elif [[ $ik == seq && $kd == *List ]]; then why='<Kind>List + 최상위 items 목록'
    elif [[ $ik == seq ]]; then why='최상위 items 목록 — Argo는 kind와 무관하게 풀어 원소를 적용한다(IsList · 보강)'
    fi
    [[ -z $why ]] || fail "11.1 FMT-list" "${SRC_LABEL[$i]} 문서 #$idx kind '$kd': 목록 객체 금지($why) — 파일 단위 검사는 최상위 문서의 kind만 보는데 Argo(directory source · 렌더)와 kustomize는 목록을 풀어 그 안의 Application·RBAC을 적용한다"
  done < <(printf '%s' "$DOC_ROWS")
  finish_group "11.1 FMT-list" "목록 객체(kind: List · 최상위 items 목록) 없음 — 문서 ${nd}개(YAML 파일 ${nf}개 · 렌더 ${nr}개)" "$f1"

  # 11.2 ApplicationSet — 같은 행(파일 + 렌더). kind만 같고 API 그룹이 다른 객체는 Argo가 만들지 않는다
  local f2=$N_FAIL
  while IFS="$YQ_SEP" read -r i idx nk tg hk kd av ik nm; do
    [[ -n $i && $nk == map && $kd == ApplicationSet && $av =~ $RE_ARGO_API ]] || continue
    fail "11.2 FMT-appset" "${SRC_LABEL[$i]} 문서 #$idx ApplicationSet/$nm(apiVersion '$av'): ApplicationSet 금지 — template이 만드는 Application은 Git에 없어 검사할 수 없다(쓰게 되면 계약을 먼저 고친다)"
  done < <(printf '%s' "$DOC_ROWS")
  finish_group "11.2 FMT-appset" "ApplicationSet(argoproj.io/…) 없음 — 문서 ${nd}개(YAML 파일 ${nf}개 · 렌더 ${nr}개)" "$f2"

  # 11.3 directory source 경로 — Application(파일 + 렌더 — 7.4와 같은 집합)의 source path(spec.source.path · spec.sources[].path)를
  #   ROOT 기준으로 정규화해 고유 경로마다 판정한다: 트리에 없음(부분 트리 — 건너뜀) · kustomization 있음(렌더 쪽 검사의 몫) · 그 밖 = directory source
  local f3=$N_FAIL app ap np d e base ep nkz=0 nmiss=0 nds=0 dslist=''
  local -A pseen=()
  local -a ds=() ents=()
  collect_rows "$YQ_APP_PATHS" "11.3 FMT-dirsource" all
  while IFS="$YQ_SEP" read -r i app ap; do
    [[ -n $i ]] || continue
    x="${SRC_LABEL[$i]} Application/$app"
    if [[ $ap == /* ]]; then
      fail "11.3 FMT-dirsource" "$x: spec.source.path '$ap' — 절대 경로 금지(directory source 여부를 판정할 수 없다 · fail-closed)"
      continue
    fi
    # 끝에 조각 하나(`_`)를 붙여 정규화한다 — norm_rel은 ROOT 자신과 저장소 밖을 둘 다 빈 문자열로 돌려주므로 둘을 가르기 위해서다
    np=$(norm_rel "" "$ap/_")
    if [[ -z $np ]]; then
      fail "11.3 FMT-dirsource" "$x: spec.source.path '$ap' — 저장소 밖으로 나가는 경로(판정할 수 없다 · fail-closed)"
      continue
    fi
    np=${np%_}; np=${np%/}; [[ -n $np ]] || np='.'
    [[ -z ${pseen[$np]:-} ]] || continue
    pseen[$np]=1
    d=$ROOT; [[ $np == . ]] || d="$ROOT/$np"
    if [[ ! -d $d ]]; then nmiss=$((nmiss + 1)); continue; fi
    if kust_file_in "$d" >/dev/null; then nkz=$((nkz + 1)); continue; fi
    ds+=("$np")
  done < <(printf '%s' "$ROWS")
  if [[ ${#ds[@]} -gt 0 ]]; then mapfile -t ds < <(printf '%s\n' "${ds[@]}" | LC_ALL=C sort); fi
  nds=${#ds[@]}
  for np in "${ds[@]}"; do
    dslist+="${dslist:+ · }$np"
    d=$ROOT; [[ $np == . ]] || d="$ROOT/$np"
    mapfile -d '' -t ents < <(find "$d" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
    for e in "${ents[@]}"; do
      base=${e##*/}; ep=$base; [[ $np == . ]] || ep="$np/$base"
      # 심볼릭 링크 — 대상의 종류(파일 · 디렉터리 · 없음)와 이름(확장자)을 보기 전에 건다(링크는 하위 디렉터리로도 · .json으로도 따로 찍지 않는다)
      if [[ -L $e ]]; then
        fail "11.3 FMT-dirsource" "$ep: directory source 경로 $np의 심볼릭 링크 금지 — 파일 열거(find -type f)는 링크를 세지 않는데 Argo는 저장소 안을 가리키는 링크를 따라 읽는다(링크된 Application은 kind 판정만 받고 2 · 7.1 · 7.4의 판정 — SSA · 이름↔경로 · spec.source — 을 지나 적용된다. 파일 · 디렉터리 · 대상 없는 링크 모두)"
        continue
      fi
      if [[ -d $e ]]; then
        fail "11.3 FMT-dirsource" "$ep/: directory source 경로 $np의 하위 디렉터리 금지 — directory.recurse는 7.4가 금지하므로 그 아래 파일은 적용되지 않는 죽은 선언이다(파일은 경로 바로 아래에만)"
        continue
      fi
      case $base in
        *.json|*.jsonnet|*.libsonnet)
          fail "11.3 FMT-dirsource" "$ep: directory source 경로 $np(kustomization 없음 — Argo가 디렉터리째 읽는다)에 .${base##*.} 파일 금지 — 파일 열거는 *.yaml·*.yml뿐인데 Argo directory source는 .json·.jsonnet을 읽는다(.libsonnet은 .jsonnet이 import한다)" ;;
      esac
    done
  done
  finish_group "11.3 FMT-dirsource" "directory source 경로 ${nds}개(${dslist:-없음}) — .json·.jsonnet·.libsonnet 파일·하위 디렉터리 없음 · Application source.path $((nds + nkz + nmiss))개 = directory source ${nds} · kustomization ${nkz} · 트리에 없음 ${nmiss}" "$f3"

  # 11.4 directory source 경로 바로 아래 *.yaml·*.yml **일반 파일**의 모든 문서 = Application(argoproj.io/…). 빈 문서는 건너뛴다.
  #   심볼릭 링크는 따라가지 않는다(find -type f — 기본 -P는 링크 자신의 종류를 본다). 링크는 11.3이 금지한다 — 따라가서 "Application이다"라고 세면
  #   2 · 7.1 · 7.4가 보지 않은 문서를 받아들이는 셈이다(2026-09-30 G4 리뷰 A2)
  local f4=$N_FAIL nyf=0 nad=0 nempty=0 rows
  for np in "${ds[@]}"; do
    d=$ROOT; [[ $np == . ]] || d="$ROOT/$np"
    mapfile -d '' -t ents < <(find "$d" -mindepth 1 -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | LC_ALL=C sort -z)
    for e in "${ents[@]}"; do
      base=${e##*/}; ep=$base; [[ $np == . ]] || ep="$np/$base"
      nyf=$((nyf + 1))
      if ! rows=$(yq -N "$YQ_DOCS" "$e" | tr -d '\r' | sed '/^[[:space:]]*$/d'); then
        fail "11.4 FMT-dirsource-kind" "$ep: yq로 읽지 못했다(fail-closed)"
        continue
      fi
      while IFS="$YQ_SEP" read -r idx nk tg hk kd av ik nm; do
        [[ -n $idx ]] || continue
        if [[ $nk == scalar && $tg == '!!null' ]]; then nempty=$((nempty + 1)); continue; fi
        if [[ $nk != map ]]; then
          fail "11.4 FMT-dirsource-kind" "$ep 문서 #$idx: 맵이 아닌 문서($nk) — kind 없음(fail-closed)"
        elif [[ $hk != true || $kd == - || -z $kd ]]; then
          fail "11.4 FMT-dirsource-kind" "$ep 문서 #$idx: kind 없음 — directory source 경로에는 Application(argoproj.io/…)만 둔다(fail-closed)"
        elif [[ $kd != Application || ! $av =~ $RE_ARGO_API ]]; then
          fail "11.4 FMT-dirsource-kind" "$ep 문서 #$idx kind '$kd'(apiVersion '$av'): directory source 경로에는 Application(argoproj.io/…)만 — Argo가 렌더 없이 그대로 적용하는 이 파일들은 렌더를 보는 검사(10 · 13 등)의 시야 밖이다"
        elif [[ $ik == seq ]]; then
          fail "11.4 FMT-dirsource-kind" "$ep 문서 #$idx Application/$nm: 최상위 items 목록 금지(보강) — Argo는 items 목록을 풀어 그 원소를 적용하고 이 Application은 버린다"
        elif [[ $ik == alias ]]; then
          fail "11.4 FMT-dirsource-kind" "$ep 문서 #$idx Application/$nm: 최상위 items가 풀리지 않은 별칭으로 남았다 — 목록 객체인지 판정할 수 없다(fail-closed)"
        else
          nad=$((nad + 1))
        fi
      done <<< "$rows"
    done
  done
  finish_group "11.4 FMT-dirsource-kind" "directory source 경로 ${nds}개의 YAML 파일 ${nyf}개 · 문서 ${nad}개 모두 Application(argoproj.io/…) · 빈 문서 ${nempty}개 건너뜀" "$f4"

  check_11_symlinks
}

# 11.5 심볼릭 링크 — --root 트리 어디든(계약 형식별 정책 「심볼릭 링크」 행 — .git/ 제외 · 파일 · 디렉터리 · 깨진 링크 · 루트의 tests/도 본다).
#   파일 열거(find -type f)와 kustomization 열거는 링크를 세지 않는데 Argo와 kustomize는 저장소 안 링크를 따라 읽는다 — 컴포넌트 디렉터리 자체가
#   링크(platform/<comp> → 다른 곳)면 그 렌더는 모든 검사의 시야 밖이다(2026-09-30 실측 — cluster-admin 바인딩이 든 링크된 컴포넌트가 exit 0).
#   ① 작업 트리: find(기본 -P — 링크 자신의 종류를 본다 · 링크된 디렉터리 안으로 내려가지 않는다)가 찾은 링크마다 FAIL(대상 문자열 · 대상 없음 표시).
#      find·sort의 종료 코드는 프로세스 치환을 넘어오지 않으므로 목록 끝의 원소로 받는다(치환 안은 set +e — 물려받은 errexit가 그 원소를 찍기 전에
#      끝내지 않게). 트리를 다 훑지 못했으면 FAIL(fail-closed)
#   ② git 인덱스: Windows 체크아웃(core.symlinks=false)은 링크를 일반 파일로 풀어 ①이 보지 못한다. --root가 git 작업 트리 안이면 그 아래 인덱스 항목
#      (git ls-files -s — 경로는 --root 기준)의 모드 120000마다 FAIL. git이 없거나 작업 트리가 아니거나 읽지 못하면 그 사실을 한 줄로 적고 ①로만
#      판정한다(fail-open이 아니다 — ①은 항상 돈다). Linux 체크아웃의 커밋된 링크는 ①과 ②가 둘 다 찍는다(사유가 다르다)
#   yq가 필요 없다(검사 11의 yq 확인이 실패해도 check_11_formats가 부른다). 11.3의 directory source 경로 링크 판정은 그대로다(같은 링크가 11.3 · 11.5로
#   두 번 찍힌다). 경로 · 대상 문자열의 제어 문자는 '?'로 바꿔 찍는다(이름의 개행이 출력 줄을 나누지 않게).
check_11_symlinks() {
  local f5=$N_FAIL e p t gone rc='' idxnote='' lsf line nent=0 nidx=0
  local -a ents=()
  mapfile -d '' -t ents < <(set +e; find "$ROOT" -mindepth 1 -path "$ROOT/.git" -prune -o -printf '%y %P\0' | LC_ALL=C sort -z
    printf 'find-sort-rc=%s,%s\0' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}")
  if [[ ${#ents[@]} -gt 0 ]]; then rc=${ents[-1]}; unset 'ents[-1]'; fi
  if [[ $rc != find-sort-rc=0,0 ]]; then
    fail "11.5 FMT-symlink" "--root 트리를 다 훑지 못했다(${rc:-종료 코드를 받지 못함}) — 링크가 없다고 판정할 수 없다(fail-closed)"
  fi
  for e in "${ents[@]}"; do
    nent=$((nent + 1))
    [[ ${e:0:1} == l ]] || continue
    p=${e:2}
    t=$(readlink -- "$ROOT/$p" 2>/dev/null) || t='(읽지 못함)'
    gone=''; [[ -e "$ROOT/$p" ]] || gone=' · 대상 없음'
    fail "11.5 FMT-symlink" "${p//[[:cntrl:]]/?}: 심볼릭 링크 금지(→ '${t//[[:cntrl:]]/?}'$gone) — 파일 열거(find -type f)와 kustomization 열거는 링크를 세지 않는데 Argo와 kustomize는 저장소 안 링크를 따라 읽는다(컴포넌트 디렉터리가 링크면 그 렌더는 모든 검사의 시야 밖이다 — 파일 · 디렉터리 · 대상 없는 링크 모두)"
  done

  # ② 경로는 core.quotePath=false로 받는다(비 ASCII를 8진 이스케이프로 바꾸지 않는다 — 제어 문자 · 따옴표가 든 경로는 여전히 C 형식 한 줄이다)
  if ! command -v git >/dev/null 2>&1; then
    idxnote='git 없음'
  elif [[ $(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null | tr -d '\r') != true ]]; then
    idxnote='git 작업 트리가 아니다'
  elif ! lsf=$(git -C "$ROOT" -c core.quotePath=false ls-files -s -- . 2>/dev/null | tr -d '\r'); then
    idxnote='git ls-files 실패'
  else
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      nidx=$((nidx + 1))
      [[ ${line%% *} == 120000 ]] || continue
      p=${line#*$'\t'}
      fail "11.5 FMT-symlink" "${p//[[:cntrl:]]/?}: git 인덱스의 모드 120000(심볼릭 링크) 금지 — Windows 체크아웃(core.symlinks=false)은 링크를 일반 파일로 풀어 작업 트리 판정(find -type l)이 보지 못한다(Argo의 체크아웃에서는 링크다)"
    done <<< "$lsf"
  fi
  if [[ -n $idxnote ]]; then
    printf '  11.5 git 인덱스를 보지 않았다(%s) — 작업 트리의 링크(find -type l)만으로 판정한다(core.symlinks=false 체크아웃이 일반 파일로 푼 링크는 이 실행에서 보이지 않는다)\n' "$idxnote"
    finish_group "11.5 FMT-symlink" "심볼릭 링크 0개 — 작업 트리 항목 ${nent}개(.git 제외) · git 인덱스는 보지 않았다($idxnote — 작업 트리만으로 판정)" "$f5"
  else
    finish_group "11.5 FMT-symlink" "심볼릭 링크 0개 — 작업 트리 항목 ${nent}개(.git 제외) · git 인덱스 항목 ${nidx}개(모드 120000 0개)" "$f5"
  fi
}

# -----------------------------------------------------------------------------
# 검사 12 — 차트 출처(계약 §validate.yml 4 「(T047) 차트 저장소 허용 목록」·「charts/라는 이름의 디렉터리는 helm 인플레이트 캐시 전용이다」·
#   「helmCharts를 쓰는 kustomization이 하나라도 있으면 … --enable-helm」)
# 12.1–12.3의 판정은 helm_src_scan(검사 1 전)이 했다 — 여기서는 검사 번호 순서대로 찍는다. 12.4는 bootstrap/argocd **렌더**를, 12.5는
#   디렉터리 이름을 본다(12.5는 인플레이트 캐시가 생기기 전후 결과가 같다 — 캐시 자리는 허용이고 그 안은 보지 않는다).
# -----------------------------------------------------------------------------
check_12_helm() {
  header 12 "차트 출처 — helmCharts (이름, 저장소) = 허용 목록 · version · 레거시 생성기 금지 · argocd-cm --enable-helm · charts 디렉터리 = 인플레이트 캐시 자리"
  need_tool "12 HELM" yq || return 0
  local m i idx nk tg hk kd av ik nm nfile=0

  local f1=$N_FAIL
  for m in "${HELM_F1[@]}"; do fail "12.1 HELM-repo" "$m"; done
  finish_group "12.1 HELM-repo" "helmCharts 항목 ${HELM_NENT}개 모두 허용 목록의 (이름, 저장소) 쌍 — kustomization ${HELM_NKUST}개 판정(열거 밖 base ${HELM_NEXTRA}개 포함)${HELM_USE:+ · 사용: $HELM_USE}" "$f1"

  local f2=$N_FAIL
  for m in "${HELM_F2[@]}"; do fail "12.2 HELM-version" "$m"; done
  finish_group "12.2 HELM-version" "helmCharts 항목 ${HELM_NENT}개 모두 version 있음" "$f2"

  # 12.3 — kustomization 쪽(최상위 키 · generators·transformers 참조)은 사전 판정, 파일 열거의 YAML 문서 kind는 여기서(검사 11과 같은 행)
  local f3=$N_FAIL
  for m in "${HELM_F3[@]}"; do fail "12.3 HELM-legacy" "$m"; done
  collect_doc_rows
  while IFS="$YQ_SEP" read -r i idx nk tg hk kd av ik nm; do
    [[ -n $i && ${SRC_KIND[$i]} == file && $nk == map && $kd == HelmChartInflationGenerator ]] || continue
    fail "12.3 HELM-legacy" "${SRC_LABEL[$i]} 문서 #$idx kind 'HelmChartInflationGenerator': 레거시 생성기 설정 금지 — generators:로 부르면 helmCharts 허용 목록 밖에서 차트를 받는다"
  done < <(printf '%s' "$DOC_ROWS")
  for ((i = 0; i < SRC_N; i++)); do
    if [[ ${SRC_KIND[$i]} == file ]]; then nfile=$((nfile + 1)); fi
  done
  finish_group "12.3 HELM-legacy" "kustomization ${HELM_NKUST}개에 helmGlobals·helmChartInflationGenerator·레거시 생성기 참조 없음 · YAML 파일 ${nfile}개에 kind: HelmChartInflationGenerator 없음" "$f3"

  # 12.4 — helmCharts를 쓰는 kustomization이 있으면 Argo repo-server의 kustomize 빌드 옵션에 --enable-helm(없으면 그 컴포넌트를 렌더하지 못한다).
  #   값은 kustomize build의 인자가 되고 pflag가 읽는다(불리언 플래그): `--enable-helm`은 참, `--enable-helm=<값>`은 strconv.ParseBool(HELM_BOOL_*)로
  #   읽으며 같은 플래그가 여럿이면 차례로 덮어써 마지막 값이 이긴다. 참·거짓 낱말이 아닌 값은 그 자리에서 오류다(kustomize build 실패 — 뒤의 낱말은
  #   소용이 없다). 2026-09-30 G4 리뷰 B1: `--enable-helm=true`를 낱말로 보지 않던 판정은 동작하는 설정을 FAIL시켰다
  local f4=$N_FAIL ai=-1 label rows cnt hkey='' json='' words='' verdict='' vword='' w wv v x
  local -a warr=()
  if [[ $HELM_NUSER -eq 0 ]]; then
    pass "12.4 HELM-argocd" "helmCharts를 쓰는 kustomization 0개 — 대상 없음"
  elif ! kust_file_in "$ROOT/$HELM_ARGOCD_DIR" >/dev/null; then
    if [[ $ROOT == "$REPO_ROOT" ]]; then
      fail "12.4 HELM-argocd" "$HELM_ARGOCD_DIR/kustomization.yaml 없음 — helmCharts를 쓰는 kustomization ${HELM_NUSER}개가 있는데 Argo CD 설정(argocd-cm)을 판정할 수 없다(fail-closed)"
    else
      pass "12.4 HELM-argocd" "$HELM_ARGOCD_DIR 없음 — 부분 트리(픽스처)라 대상 없음(helmCharts를 쓰는 kustomization ${HELM_NUSER}개)"
    fi
  elif need_tool "12.4 HELM-argocd" kustomize; then
    for ((i = 0; i < SRC_N; i++)); do
      if [[ ${SRC_KIND[$i]} == rendered && ${SRC_PATH[$i]} == "$HELM_ARGOCD_DIR" ]]; then ai=$i; fi
    done
    if [[ $ai -lt 0 ]]; then
      fail "12.4 HELM-argocd" "$HELM_ARGOCD_DIR 렌더 결과 없음 — kustomize build가 실패했거나 건너뛰었다(검사 1 참조) · 판정할 대상이 없으므로 fail-closed"
    else
      label=${SRC_LABEL[$ai]}
      x="$label ConfigMap/$HELM_ARGOCD_CM_NS/$HELM_ARGOCD_CM"
      if ! rows=$(src_extract "$ai" "$YQ_ARGOCD_CM"); then
        fail "12.4 HELM-argocd" "$label: yq 추출 실패($HELM_ARGOCD_CM) — fail-closed"
      else
        cnt=0
        while IFS= read -r m; do
          if [[ -n $m ]]; then cnt=$((cnt + 1)); fi
        done <<< "$rows"
        IFS="$YQ_SEP" read -r hkey json words <<< "$rows" || true
        if [[ $cnt -ne 1 ]]; then
          fail "12.4 HELM-argocd" "$label: ConfigMap $HELM_ARGOCD_CM_NS/$HELM_ARGOCD_CM ${cnt}개 — 정확히 1개여야 판정할 수 있다(fail-closed · helmCharts를 쓰는 kustomization ${HELM_NUSER}개)"
        elif [[ $hkey == 0 ]]; then
          fail "12.4 HELM-argocd" "$x: data.\"$HELM_ARGOCD_KEY\" 없음 — helmCharts를 쓰는 kustomization ${HELM_NUSER}개가 있는데 Argo repo-server는 $HELM_ARGOCD_FLAG 없이 빌드한다(그 Application은 렌더 실패로 굳는다)"
        elif [[ $hkey != 1 ]]; then
          fail "12.4 HELM-argocd" "$x: data.\"$HELM_ARGOCD_KEY\" 키 ${hkey}개 — 판정할 수 없다(fail-closed)"
        elif [[ -z $words ]]; then
          fail "12.4 HELM-argocd" "$x: data.\"$HELM_ARGOCD_KEY\" $json에 $HELM_ARGOCD_FLAG 낱말 없음 — helmCharts를 쓰는 kustomization ${HELM_NUSER}개가 있는데 Argo repo-server는 $HELM_ARGOCD_FLAG 없이 빌드한다(공백으로 나눈 낱말 단위 — Argo CD는 strings.Fields로 나눈다)"
        else
          # words = `--enable-helm`·`--enable-helm=…` 낱말의 JSON 문자열(공백 구분 — YQ_ARGOCD_CM). read -a는 경로 확장(글롭)을 하지 않는다
          read -r -a warr <<< "$words"
          for w in "${warr[@]}"; do
            vword=$w; wv=${w#\"}; wv=${wv%\"}
            if [[ $wv == "$HELM_ARGOCD_FLAG" ]]; then
              verdict=true
            elif [[ $wv == "$HELM_ARGOCD_FLAG="* ]]; then
              v=${wv#"$HELM_ARGOCD_FLAG="}
              if [[ -n $v && " $HELM_BOOL_TRUE " == *" $v "* ]]; then verdict=true
              elif [[ -n $v && " $HELM_BOOL_FALSE " == *" $v "* ]]; then verdict=false
              else verdict=invalid; break
              fi
            else
              verdict=invalid; break
            fi
          done
          if [[ $verdict == true ]]; then
            pass "12.4 HELM-argocd" "helmCharts를 쓰는 kustomization ${HELM_NUSER}개 → $x data.\"$HELM_ARGOCD_KEY\" $json에 $HELM_ARGOCD_FLAG 있음"
          elif [[ $verdict == false ]]; then
            fail "12.4 HELM-argocd" "$x: data.\"$HELM_ARGOCD_KEY\" $json의 마지막 $HELM_ARGOCD_FLAG 낱말 $vword이 참이 아니다 — pflag는 같은 플래그의 마지막 값을 쓴다(참: $HELM_ARGOCD_FLAG · $HELM_ARGOCD_FLAG=<${HELM_BOOL_TRUE// /·}>). helmCharts를 쓰는 kustomization ${HELM_NUSER}개가 있는데 Argo repo-server는 helm 없이 빌드한다(그 Application은 렌더 실패로 굳는다)"
          else
            fail "12.4 HELM-argocd" "$x: data.\"$HELM_ARGOCD_KEY\" $json의 $HELM_ARGOCD_FLAG 낱말 $vword의 값을 pflag가 참·거짓으로 읽지 못한다(strconv.ParseBool — ${HELM_BOOL_TRUE// /·} / ${HELM_BOOL_FALSE// /·}만) — 인자 해석이 그 자리에서 멈춰 kustomize build가 실패한다(Argo repo-server가 helmCharts를 쓰는 kustomization ${HELM_NUSER}개를 렌더하지 못한다)"
          fi
        fi
      fi
    fi
  fi

  # 12.5 — 이름이 charts인 디렉터리(심볼릭 링크 포함)는 helmCharts를 쓰는 kustomization 바로 아래에만. 허용된 캐시 안은 보지 않는다
  #   (받은 차트 안의 하위 차트 charts/ — 정렬하면 캐시가 그 안의 경로보다 먼저 온다). .git과 루트의 tests/는 보지 않는다
  local f5=$N_FAIL cdir pd pk why a inside hu
  local -a cds=() allowed=()
  mapfile -d '' -t cds < <(find "$ROOT" \( -path "$ROOT/tests" -o -name .git \) -prune -o -name charts -xtype d -print0 | LC_ALL=C sort -z)
  for cdir in "${cds[@]}"; do
    inside=0
    for a in "${allowed[@]}"; do
      if [[ $cdir == "$a"/* ]]; then inside=1; break; fi
    done
    [[ $inside == 0 ]] || continue
    pd=$(dirname "$cdir")
    if pk=$(kust_file_in "$pd"); then
      hu=0
      helm_uses "$pk" || hu=$?
      if [[ $hu == 0 ]]; then allowed+=("$cdir"); continue; fi
      if [[ $hu == 2 ]]; then why="부모 $(rel "$pd")/의 kustomization을 읽지 못했다(fail-closed)"
      else why="부모 $(rel "$pd")/의 kustomization이 helmCharts를 쓰지 않는다"
      fi
    else
      why="부모 $(rel "$pd")/에 kustomization이 없다"
    fi
    fail "12.5 HELM-chartsdir" "$(rel "$cdir")/: 이름이 charts인 디렉터리 — $why. charts는 helmCharts를 쓰는 kustomization 바로 아래(인플레이트 캐시)에만 둔다 — 파일 열거와 7.4의 파일 찾기가 경로에 /charts/가 든 곳을 통째로 건너뛰므로 이 아래는 모든 검사의 시야 밖이다"
  done
  finish_group "12.5 HELM-chartsdir" "이름이 charts인 디렉터리는 인플레이트 캐시 자리(helmCharts를 쓰는 kustomization 바로 아래)에만 있다 — 캐시 안은 보지 않는다(.git · 루트 tests/ 제외)" "$f5"
}

# -----------------------------------------------------------------------------
# 검사 13 — 권한 경계(계약 §validate.yml 4 「(T047) 권한 경계 — 문자열이 아니라 규칙 구조로 본다」 · 기준선 = 2026-09-29 main 82dd85e 실측)
#
# 대상: kustomize **렌더 전부**(SRC_KIND rendered)를 합친 RBAC 객체 — apiVersion이 rbac.authorization.k8s.io/로 시작하고 kind가 Role·ClusterRole·
#   RoleBinding·ClusterRoleBinding인 문서. 검사 10은 컴포넌트 하나(platform/reloader)의 렌더 안만 본다 — 다른 컴포넌트의 렌더가 같은 계정에 권한을
#   주거나 ServiceAccount 토큰을 발급할 수 있는 규칙을 새로 넣는 경로는 여기서 본다. 판정은 문자열 찾기가 아니라 규칙의 구조(목록의 원소)로 한다 —
#   와일드카드와 주체 표기의 여러 형태가 같은 권한을 준다.
# 렌더만 봐도 되는 전제: Argo가 적용하는 것은 kustomization의 렌더이거나 directory source 경로(clusters/oci-k3s/apps)의 파일이다. 뒤쪽은 11.4
#   (FMT-dirsource-kind)가 "문서는 Application(argoproj.io/…)뿐"으로 닫는다 — 그 경로에 RBAC를 두면 11.4가 FAIL한다. 렌더 안에 숨는 경로 중
#   목록 객체(items 안의 RBAC)는 11.1이, Application 수준에서 렌더를 바꾸는 경로(source 오버라이드 등)는 7.4가, kustomization 열거 밖에서
#   렌더되는 링크된 컴포넌트는 11.5가 막는다. Argo가 적용하지 않는
#   렌더(pod의 base 등)도 합쳐서 본다 — 넓게 잡는 쪽이다.
# 추출: 렌더 하나 = yq 한 번(YQ_RBAC — 행 종류 R 역할 · T 토큰 발급 규칙 · B 바인딩 · S 주체). 모든 렌더를 모은 뒤 판정한다 — 13.2의 "렌더에 있는
#   ClusterRole"과 "같은 ns의 Role"은 **모든 렌더를 합친** 집합이다(바인딩과 역할이 다른 컴포넌트의 렌더에 있어도 된다). 같은 객체가 여러 렌더에
#   나타나면(base와 overlay 등) 나타난 것마다 판정·계수한다(다른 컴포넌트가 같은 이름으로 넓은 규칙을 정의하는 경로).
# 완전성(기준선의 것이 있는가)은 --root가 저장소 루트일 때만 요구한다(검사 10과 같은 판별 — 부분 트리 픽스처는 기준선 **밖의** 것만 본다).
#   13.0이 나면(렌더가 빠져 합친 집합이 불완전하다) 완전성은 판정하지 않는다 — 빠진 렌더에 기준선의 것이 있을 수 있다.
# 보지 않는 것은 tests/README.md 「검사 13이 보지 않는 것」.
# -----------------------------------------------------------------------------
RB_O=''
rb_obj() { # <kind> <ns> <이름> → 전역 RB_O(클러스터 범위는 kind/이름, ns 범위는 kind/ns/이름) — $(…) 없이 부르려고 전역에 둔다
  if [[ $1 == Cluster* ]]; then RB_O="$1/$3"; else RB_O="$1/$2/$3"; fi
}
check_13_rbac() {
  header 13 "권한 경계(전 렌더 합산 RBAC) — 토큰 발급 규칙 · 렌더되지 않은 역할을 가리키는 바인딩 · 내장 역할 이름 · 주체 · Reloader 주체 · 역할 집계"
  need_tool "13 RBAC" yq || return 0
  need_tool "13 RBAC" kustomize || return 0
  local f0=$N_FAIL kf rdir i out line typ nsep idx a b c d e f g h j key shape ok x L O
  local nren=0 nmiss=0 missing='' needhelm=0 bad=0 atroot=0 rows=''
  local nrole=0 ncr=0 nbind=0 nrb=0 ncrb=0 nsubj=0 ntok=0 next=0 nrr=0 nagg=0
  local toklist='' extlist='' agglist='' toktab='' exttab='' aggtab='' expnames='' mode
  local -a arr=()
  local -A have=() crset=() roleset=() tokwant=() extwant=() aggwant=() seen=() relb=()
  # helmCharts를 쓰는 kustomization이 있으면 렌더에 helm이 필요하다(검사 1과 같은 판별 — 사전 판정에 걸린 것은 렌더하지 않으므로 빼고 센다)
  for kf in "${KUST_FILES[@]}"; do
    [[ -z ${HELM_BLOCK[$kf]:-} ]] || continue
    if grep -Eq '^[[:space:]]*helmCharts:' "$kf"; then needhelm=1; break; fi
  done
  if [[ $needhelm == 1 ]]; then need_tool "13 RBAC" helm || return 0; fi
  [[ $ROOT != "$REPO_ROOT" ]] || atroot=1

  # 표(계약 사본) → 조회용 맵 · 메시지용 목록
  while read -r a b c d; do
    [[ -n $a ]] || continue
    rb_obj "$a" "$b" "$c"; tokwant[$RB_O]=$d; toktab+="${toktab:+ · }$RB_O"
  done <<< "$RBAC_TOKEN_TABLE"
  while read -r a b c; do
    [[ -n $a ]] || continue
    extwant["$a $b $c"]=1; exttab+="${exttab:+ · }$a/$b → $c"
  done <<< "$RBAC_EXTREF_TABLE"
  while read -r a; do
    [[ -n $a ]] || continue
    aggwant[$a]=1; aggtab+="${aggtab:+ · }$a"
  done <<< "$RBAC_AGG_TABLE"
  mapfile -t arr < <(printf '%s\n' $RBAC_TOKEN_FIXED_NAMES | LC_ALL=C sort -u)
  expnames=$(printf '"%s",' "${arr[@]}"); expnames="[${expnames%,}]"

  # 13.0 — 렌더마다 yq 한 번. 행마다 종류와 구분자 수(R 7 · T 9 · B 7 · S 8)와 수·참거짓 필드를 확인한다(아니면 fail-closed)
  for ((i = 0; i < SRC_N; i++)); do
    [[ ${SRC_KIND[$i]} == rendered ]] || continue
    nren=$((nren + 1)); have[${SRC_PATH[$i]}]=1
    if ! out=$(src_extract "$i" "$YQ_RBAC"); then
      fail "13.0 RBAC-render" "${SRC_LABEL[$i]}: yq 추출 실패 — 이 렌더의 RBAC를 판정할 수 없다(fail-closed)"
      bad=1; continue
    fi
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      typ=${line%%"$YQ_SEP"*}
      nsep=${line//[!$YQ_SEP]/}; nsep=${#nsep}
      ok=0
      IFS=$YQ_SEP read -r typ a b c d e f g h j <<< "$line"
      case "$typ:$nsep" in
        R:7) [[ $d =~ ^[0-9]+$ && $g =~ ^[0-9]+$ && ( $e == true || $e == false ) && $f == \[* ]] && ok=1 ;;
        T:9) [[ $d =~ ^[0-9]+$ && ( $h == true || $h == false ) && $e == \[* && $f == \[* && $g == \[* && $j == \[* ]] && ok=1 ;;
        B:7) [[ $g =~ ^[0-9]+$ ]] && ok=1 ;;
        S:8) [[ $d =~ ^[0-9]+$ ]] && ok=1 ;;
      esac
      if [[ $ok == 1 ]]; then
        rows+="$i$YQ_SEP$line"$'\n'
      else
        fail "13.0 RBAC-render" "${SRC_LABEL[$i]}: 추출 행의 모양이 기대와 다르다(종류 '${typ:0:12}' · 구분자 ${nsep}개) — 값에 줄바꿈·구분 문자가 든 이름 등(fail-closed)"
        bad=1
      fi
    done <<< "$out"
  done
  for kf in "${KUST_FILES[@]}"; do
    rdir=${kf%/*}
    if [[ $rdir == "$ROOT" ]]; then rdir='.'; else rdir=${rdir#"$ROOT"/}; fi
    [[ -n ${have[$rdir]:-} ]] || { missing+="${missing:+ · }$rdir"; nmiss=$((nmiss + 1)); }
  done
  if [[ $nmiss -gt 0 ]]; then
    fail "13.0 RBAC-render" "렌더가 없는 kustomization ${nmiss}개 [$missing] — 빌드가 실패했거나 건너뛰었다(검사 1 · 12 참조). 그 렌더의 RBAC를 볼 수 없어 합친 집합이 불완전하다(fail-closed)"
    bad=1
  fi

  # 1차 — 역할(R)과 토큰 발급 규칙(T): 13.1 · 13.3 · 13.6, 그리고 13.2가 쓸 역할 집합(모든 렌더 합산)
  while IFS=$YQ_SEP read -r idx typ a b c d e f g h j; do
    [[ $typ == R || $typ == T ]] || continue
    L=${SRC_LABEL[$idx]}
    rb_obj "$a" "$b" "$c"; O=$RB_O; key=$O   # ClusterRole은 ns와 무관하게 이름으로 맞춘다(rb_obj가 ns를 버린다)
    shape=${tokwant[$key]:-}
    if [[ $typ == R ]]; then
      # R: d=규칙 수 e=aggregationRule 유무 f=aggregate-to-* 라벨(JSON) g=토큰 발급 규칙 수
      if [[ $a == ClusterRole ]]; then ncr=$((ncr + 1)); crset[$c]=1; else nrole=$((nrole + 1)); roleset["$b/$c"]=1; fi
      [[ -z $shape ]] || seen["tok $key"]=1
      if [[ $g -gt 0 ]]; then ntok=$((ntok + 1)); toklist+="${toklist:+ · }$O"; fi
      if [[ $shape == fixed && $g -ne 1 ]]; then
        fail "13.1 RBAC-token" "$L $O: 토큰 발급 규칙 ${g}개 ≠ 1(규칙 ${d}개 중) — 기준선 ②의 모양은 토큰 발급 규칙 하나다(늘어난 규칙은 다른 ServiceAccount의 토큰을 발급한다)"
      fi
      [[ $a == ClusterRole ]] || continue
      if [[ " $RBAC_BUILTIN_NAMES " == *" $c "* || $c == "$RBAC_BUILTIN_PREFIX"* ]]; then
        fail "13.3 RBAC-builtin-name" "$L $O: 내장 역할의 이름(${RBAC_BUILTIN_NAMES// /·} · ${RBAC_BUILTIN_PREFIX} 접두) 금지 — 13.2는 그 이름의 ClusterRole이 렌더에 있으면 \"렌더된 역할\"로 읽으므로, 내장 역할에 거는 바인딩이 13.2를 지난다(그리고 API 서버의 내장 역할을 덮어쓴다)"
      fi
      if [[ $e == true ]]; then
        fail "13.6 RBAC-aggregation" "$L $O: aggregationRule 금지 — 합쳐진 결과 규칙은 렌더에 없어 볼 수 없다(라벨이 맞는 ClusterRole이 생기면 조용히 넓어진다)"
      fi
      if [[ $f != '[]' ]]; then
        nagg=$((nagg + 1)); agglist+="${agglist:+ · }$c"
        if [[ -n ${aggwant[$c]:-} ]]; then
          seen["agg $c"]=1
        else
          fail "13.6 RBAC-aggregation" "$L $O: aggregate-to-* 라벨 $f — 기준선($aggtab) 밖이다(라벨 값과 무관 — \"false\"도 센다: 값이 바뀌는 순간 집계된다). 내장 view·edit·admin에 규칙이 더해진다 — agent-view-view가 view에 걸려 있으므로 view에 Secret 읽기가 더해지면 에이전트의 읽기 전용 자격이 Secret을 읽는다"
        fi
      fi
    else
      # T: d=규칙 번호 e=apiGroups f=resources g=verbs h=resourceNames 유무 j=resourceNames(정렬·중복 제거)
      if [[ -z $shape ]]; then
        fail "13.1 RBAC-token" "$L $O 규칙 #$d(apiGroups $e · resources $f · verbs $g): ServiceAccount 토큰 발급 규칙 — 기준선($toktab) 밖의 역할이다. 이 역할을 받은 주체는 그 ns(ClusterRole이면 클러스터 전체)의 ServiceAccount 토큰을 발급받아 그 계정의 권한으로 행동한다"
      elif [[ $shape == fixed ]]; then
        if [[ $e != "$RBAC_TOKEN_FIXED_GROUPS" || $f != "$RBAC_TOKEN_FIXED_RESOURCES" || $g != "$RBAC_TOKEN_FIXED_VERBS" ]]; then
          fail "13.1 RBAC-token" "$L $O 규칙 #$d: apiGroups·resources·verbs가 기준선 ②와 다르다 — 실제 apiGroups $e · resources $f · verbs $g · 기준선 apiGroups $RBAC_TOKEN_FIXED_GROUPS · resources $RBAC_TOKEN_FIXED_RESOURCES · verbs $RBAC_TOKEN_FIXED_VERBS(목록 정확 일치 — 와일드카드·여분 원소는 다른 리소스·동사까지 준다)"
        fi
        if [[ $h != true ]]; then
          fail "13.1 RBAC-token" "$L $O 규칙 #$d: resourceNames 없음 — 그 ns의 모든 ServiceAccount 토큰을 발급한다(기준선 ② $expnames)"
        elif [[ $j == '[]' ]]; then
          fail "13.1 RBAC-token" "$L $O 규칙 #$d: resourceNames가 빈 목록 — 제한이 없다(그 ns의 모든 ServiceAccount 토큰 발급 · 기준선 ② $expnames)"
        elif [[ $j != "$expnames" ]]; then
          fail "13.1 RBAC-token" "$L $O 규칙 #$d: resourceNames 집합 $j ≠ 기준선 ② $expnames(집합 정확 일치 — 더한 이름의 ServiceAccount 토큰도 발급된다)"
        fi
      fi
    fi
  done < <(printf '%s' "$rows")

  # 2차 — 바인딩(B)과 주체(S): 13.2 · 13.4 · 13.5
  while IFS=$YQ_SEP read -r idx typ a b c d e f g h j; do
    [[ $typ == B || $typ == S ]] || continue
    L=${SRC_LABEL[$idx]}
    rb_obj "$a" "$b" "$c"; O=$RB_O
    if [[ $typ == B ]]; then
      # B: d=roleRef.kind e=roleRef.name f=subjects 태그 g=주체 수
      nbind=$((nbind + 1))
      if [[ $a == RoleBinding ]]; then nrb=$((nrb + 1)); else ncrb=$((ncrb + 1)); fi
      case $d in
        ClusterRole)
          if [[ -n ${crset[$e]:-} ]]; then
            :   # 어느 렌더에 있는 ClusterRole — 그 규칙은 13.1 · 13.6이 본다
          elif [[ -n ${extwant["$a $c $e"]:-} ]]; then
            next=$((next + 1)); extlist+="${extlist:+ · }$O → $e"; seen["ext $a $c $e"]=1
          else
            fail "13.2 RBAC-extref" "$L $O → ClusterRole '$e': 그 이름의 ClusterRole이 어느 렌더에도 없다(내장 역할 등 — 규칙을 볼 수 없다) · 기준선($exttab) 밖이다 — 내장 cluster-admin·admin·edit는 클러스터나 ns 전체의 쓰기 권한을 준다"
          fi ;;
        Role)
          if [[ $a == ClusterRoleBinding ]]; then
            fail "13.2 RBAC-extref" "$L $O → Role '$e': ClusterRoleBinding은 Role을 가리킬 수 없다(API 서버가 거부한다 — 선언과 적용이 갈린다)"
          elif [[ -z ${roleset["$b/$e"]:-} ]]; then
            fail "13.2 RBAC-extref" "$L $O → Role '$e': 같은 ns($b)의 그 Role이 어느 렌더에도 없다 — 렌더 밖 Role의 권한은 볼 수 없다(다른 ns의 같은 이름 Role은 쓰이지 않는다)"
          else
            nrr=$((nrr + 1))
          fi ;;
        *)
          fail "13.2 RBAC-extref" "$L $O: roleRef.kind '$d' — Role·ClusterRole만 허용한다(판정할 수 없다 — fail-closed)" ;;
      esac
      case $f in
        none|'!!null'|'!!seq') ;;
        *) fail "13.4 RBAC-subject" "$L $O: subjects가 목록이 아니다(태그 $f) — 주체를 판정할 수 없다(fail-closed)" ;;
      esac
    else
      # S: d=주체 번호 e=노드 종류 f=kind g=name h=namespace
      nsubj=$((nsubj + 1))
      x="$L $O 주체 #$d"
      if [[ $e != map ]]; then
        fail "13.4 RBAC-subject" "$x: 맵이 아니다(노드 $e) — 판정할 수 없다(fail-closed)"
      elif [[ $f != ServiceAccount ]]; then
        fail "13.4 RBAC-subject" "$x kind '$f' name '$g': 주체는 이름을 다 적은 ServiceAccount뿐이다 — User·Group은 계정을 포함하는 그룹(system:serviceaccounts[:<ns>] · system:authenticated 등)이나 계정의 사용자 이름 표기(system:serviceaccount:<ns>:<name>)로 같은 권한을 주는 경로다(사람·그룹 주체가 필요해지면 계약에 행을 더한다 — T084)"
      else
        [[ -n $g ]] || fail "13.4 RBAC-subject" "$x ServiceAccount: name이 비었다 — 누구에게 주는 권한인지 렌더로 알 수 없다(fail-closed)"
        [[ -n $h ]] || fail "13.4 RBAC-subject" "$x ServiceAccount '$g': namespace가 비었다 — RoleBinding에서는 API 서버가 바인딩의 ns로 채워 읽으므로 렌더의 글자만으로는 누구인지 드러나지 않는다"
        if [[ $g == "$REL_SA" && $h == "$REL_RELEASE_NS" ]]; then
          if [[ ${SRC_PATH[$idx]} == "$REL_DIR" ]]; then
            relb["$idx $O"]=1
          else
            fail "13.5 RBAC-reloader-subject" "$x ServiceAccount $REL_RELEASE_NS/$REL_SA: $REL_DIR 밖의 렌더가 Reloader에게 권한을 준다 — Reloader는 받은 권한만큼 Secret을 읽고 워크로드를 재시작한다(검사 10은 $REL_DIR 렌더만 본다)"
          fi
        fi
      fi
    fi
  done < <(printf '%s' "$rows")

  # 완전성 — 저장소 루트에서만 · 합친 집합이 온전할 때만
  if [[ $atroot == 1 && $bad == 0 ]]; then
    while read -r a b c d; do
      [[ -n $a ]] || continue
      rb_obj "$a" "$b" "$c"
      [[ -n ${seen["tok $RB_O"]:-} ]] \
        || fail "13.1 RBAC-token" "저장소 루트에 기준선의 토큰 발급 역할 $RB_O 없음 — 계약의 기준선(2026-09-29 실측)과 트리가 어긋났다(바뀐 것이 맞으면 계약과 RBAC_TOKEN_TABLE을 먼저 고친다)"
    done <<< "$RBAC_TOKEN_TABLE"
    while read -r a b c; do
      [[ -n $a ]] || continue
      [[ -n ${seen["ext $a $b $c"]:-} ]] \
        || fail "13.2 RBAC-extref" "저장소 루트에 기준선의 바인딩 $a/$b → ClusterRole '$c' 없음 — 어느 렌더에도 없는 ClusterRole을 가리키는 바인딩으로 나타나야 한다(바뀐 것이 맞으면 계약과 RBAC_EXTREF_TABLE을 먼저 고친다)"
    done <<< "$RBAC_EXTREF_TABLE"
    while read -r a; do
      [[ -n $a ]] || continue
      [[ -n ${seen["agg $a"]:-} ]] \
        || fail "13.6 RBAC-aggregation" "저장소 루트에 기준선의 aggregate-to-* 라벨 ClusterRole '$a' 없음 — 그 라벨을 가진 ClusterRole로 나타나야 한다(바뀐 것이 맞으면 계약과 RBAC_AGG_TABLE을 먼저 고친다)"
    done <<< "$RBAC_AGG_TABLE"
  fi

  if [[ $atroot == 0 && $((nrole + ncr + nbind)) -eq 0 ]]; then
    finish_group "13 RBAC" "렌더 ${nren}개에 RBAC 객체(Role·ClusterRole·RoleBinding·ClusterRoleBinding) 0개 — 부분 트리(픽스처)라 대상 없음" "$f0"
    return 0
  fi
  if [[ $atroot == 1 ]]; then mode='저장소 루트 — 기준선 전부 있음'; else mode='부분 트리 — 기준선 밖의 것만 본다'; fi
  finish_group "13 RBAC" "렌더 ${nren}개 합산($mode) — Role ${nrole} · ClusterRole ${ncr} · 바인딩 ${nbind}장(RoleBinding ${nrb} · ClusterRoleBinding ${ncrb}) · 주체 ${nsubj}개 모두 이름을 다 적은 ServiceAccount · 토큰 발급 규칙을 가진 역할 ${ntok}개(${toklist:-없음}) · 렌더되지 않은 ClusterRole을 가리키는 바인딩 ${next}장(${extlist:-없음}) · Role을 가리키는 RoleBinding ${nrr}장 모두 같은 ns의 렌더된 Role · 내장 역할 이름의 ClusterRole 0 · aggregationRule 0 · aggregate-to-* 라벨 ClusterRole ${nagg}개(${agglist:-없음}) · Reloader 주체(ServiceAccount $REL_RELEASE_NS/$REL_SA) 바인딩은 $REL_DIR 렌더에만 — 그 렌더 안 ${#relb[@]}장(장수·모양은 검사 10)" "$f0"
}

# -----------------------------------------------------------------------------
# 실행
# -----------------------------------------------------------------------------
if [[ $ONLY_AUTHOR == 1 ]]; then
  # --only-author(T047): 검사 6 하나만. 요약 머리와 결과 줄의 문구가 전체 실행과 다르다 — 이 모드의 exit 0이 전체 통과로 읽히지 않게
  check_6_author
  printf '\n== 요약(작성자 검사만 실행 — 검사 6 외의 검사는 돌지 않았다) ==\n'
  printf 'PASS %d · FAIL %d · WARN %d · SKIP %d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
  if [[ ${#FAIL_LINES[@]} -gt 0 ]]; then
    printf '실패 목록:\n'
    for l in "${FAIL_LINES[@]}"; do printf '  - %s\n' "$l"; done
  fi
  if [[ $N_FAIL -gt 0 ]]; then
    printf '결과(작성자 검사만 실행): FAIL\n'
    exit 1
  fi
  printf '결과(작성자 검사만 실행): PASS\n'
  exit 0
fi
load_wave_table
helm_src_scan        # 12.1–12.3 사전 판정(출력 없음) — 걸린 kustomization을 검사 1이 렌더하지 않게 검사 1보다 먼저 돈다. 줄은 검사 12가 찍는다
check_1_kustomize
check_1b_plain
check_2_app_ssa
check_3_externalsecrets
check_3_workloads
check_4_images
check_5_policies
check_6_author
check_7_sync_wave
check_7_app_source
check_8_gitleaks
check_9_clustersecretstores
check_10_reloader
check_11_formats
check_12_helm
check_13_rbac

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
