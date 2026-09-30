// 부정 픽스처 11.3 FMT-dirsource — Argo directory source는 .jsonnet을 평가해 적용한다(파일 열거는 *.yaml·*.yml뿐이다)
local lib = import 'lib.libsonnet';
{
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'ClusterRoleBinding',
  metadata: { name: lib.name },
  roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: 'cluster-admin' },
  subjects: [{ kind: 'ServiceAccount', name: 'default', namespace: 'argocd' }],
}
