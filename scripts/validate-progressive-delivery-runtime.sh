#!/usr/bin/env bash

set -euo pipefail

incident_mode='automated'
if [[ "${1:-}" == '--incident-exercise' ]]; then
  incident_mode='interactive'
  shift
fi
[[ $# -eq 0 ]] || {
  printf 'usage: %s [--incident-exercise]\n' "$0" >&2
  exit 2
}

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-progressive-delivery'
kind_context="kind-$cluster_name"
workload_namespace='secure-fastapi-service-local'
monitoring_namespace='monitoring'
argocd_namespace='argocd'
application_name='secure-fastapi-service-local'
rollout_name='secure-fastapi-service-secure-fastapi-service'
stable_service="$rollout_name"
canary_service="${rollout_name}-canary"

kind_version='v0.32.0'
kubernetes_version='v1.32.11'
kind_node_image='kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8'
argocd_version='v3.3.8'
argocd_url='https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/install.yaml'
argocd_sha256='75390e0cc232195d6d1a9614631f2beb0baa23ef227db380351ea235904a1f0d'
argocd_image='quay.io/argoproj/argocd@sha256:5d45dc6db21db32a0638ac9128462c6d9956a90fc81760146dada5a243ff7516'
dex_image='ghcr.io/dexidp/dex@sha256:b08a58c9731c693b8db02154d7afda798e1888dc76db30d34c4a0d0b8a26d913'
redis_image='public.ecr.aws/docker/library/redis@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba'
rollouts_version='v1.9.1'
rollouts_url='https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/namespace-install.yaml'
rollouts_sha256='38eaadc3d8235e49e5222f85ad49448688b6a6acbaaaae13d3d53bd1db0212b4'
rollouts_crds_url='https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/install.yaml'
rollouts_crds_sha256='78c82343803c2bbc13a36049e269a532dd67f25b7e2cb3603c99e31d8d8a40b5'
rollouts_image='quay.io/argoproj/argo-rollouts@sha256:15c0d41f2c69a382d4399bcb28ed4f03ee9f58b56cfc9e6cd55bcbf0f311c06d'
operator_version='v0.93.0'
operator_url='https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.93.0/bundle.yaml'
operator_sha256='a3061ceebd87de793d1ba9bed10cb763be9ce748adb53b5c5ef4c7c65ee38376'
operator_image='quay.io/prometheus-operator/prometheus-operator@sha256:a001ed10a3823bbf2410ea347796d0e35ff8decd24fb98acbe7ab9e98d431c39'
reloader_image='quay.io/prometheus-operator/prometheus-config-reloader@sha256:0ccb22ca9f3f6fd9f76ce95585d18bd2e363d421c534dde710be4bd13caa551d'
prometheus_image='quay.io/prometheus/prometheus@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996'
runtime_repo_url='git://127.0.0.1:9418/forgepath.git'

artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
metadata="$artifact_directory/metadata.json"
runtime_directory=''
evidence_directory=''
original_context=''
cluster_created=false
stable_forward_pid=''
canary_forward_pid=''
prometheus_forward_pid=''
traffic_pid=''
request_started=''
defective_release_started=''
detected_at=''
acknowledged_at=''
recovery_started_at=''
restored_at=''
incident_responder='automated-runtime-validator'
rollback_actor='automated-runtime-validator'
rollback_control='automatic'
traffic_log=''
rollout_samples=''

log() { printf '[forgepath-progressive-runtime] %s\n' "$*"; }
fail() { printf '[forgepath-progressive-runtime] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

now_epoch() {
  python3.12 -c 'import time; print(f"{time.time():.6f}")'
}

acknowledge_incident() {
  local response=''
  if [[ "$incident_mode" == interactive ]]; then
    [[ -r /dev/tty ]] || fail 'interactive incident exercise requires a terminal'
    printf '\nALERT: ForgePathSLOFastBurn is firing. Type "ACK <responder>" to acknowledge: ' >/dev/tty
    IFS= read -r response </dev/tty
    [[ "$response" == 'ACK '* && -n "${response#ACK }" ]] || fail 'alert was not acknowledged'
    incident_responder="${response#ACK }"
  fi
  acknowledged_at="$(now_epoch)"
  log "ACK alert acknowledged by $incident_responder"
}

approve_git_recovery() {
  local response=''
  if [[ "$incident_mode" == interactive ]]; then
    printf '\nDIAGNOSIS: the Git change enabled the 503 fixture; the SLO gate protected stable v1.\n' >/dev/tty
    printf 'Type "APPROVE GIT REVERT <approver>" to authorize recovery: ' >/dev/tty
    IFS= read -r response </dev/tty
    [[ "$response" == 'APPROVE GIT REVERT '* && -n "${response#APPROVE GIT REVERT }" ]] ||
      fail 'Git recovery was not approved'
    rollback_actor="${response#APPROVE GIT REVERT }"
    rollback_control='human-approved'
  fi
  recovery_started_at="$(now_epoch)"
  log "RECOVERY $rollback_control Git revert authorized by $rollback_actor"
}

sample_rollout() {
  local state sample_time
  [[ -n "$rollout_samples" ]] || return 0
  state="$(kube -n "$workload_namespace" get rollout "$rollout_name" -o json 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  sample_time="$(now_epoch)"
  jq -c --argjson observed "$sample_time" '{
    epochSeconds: $observed,
    updatedReplicas: (.status.updatedReplicas // 0),
    desiredReplicas: .spec.replicas,
    stepIndex: (.status.currentStepIndex // 0),
    stableReplicaSet: (.status.stableRS // null),
    candidateReplicaSet: (.status.currentPodHash // null)
  }' <<<"$state" >>"$rollout_samples"
}

kube() { kubectl --context "$kind_context" "$@"; }
require_context() {
  [[ "$(kubectl config current-context 2>/dev/null || true)" == "$kind_context" ]] ||
    fail "current context is not $kind_context"
}

cleanup() {
  local exit_code=$? context_restored=false
  trap - EXIT INT TERM
  for process_id in "$traffic_pid" "$stable_forward_pid" "$canary_forward_pid" "$prometheus_forward_pid"; do
    if [[ -n "$process_id" ]]; then kill "$process_id" 2>/dev/null || true; wait "$process_id" 2>/dev/null || true; fi
  done
  if ((exit_code != 0)) && [[ "$cluster_created" == true ]] && [[ -n "$evidence_directory" ]]; then
    kube -n "$workload_namespace" get rollout,analysisrun,analysistemplate,service,endpoints,pod -o json \
      >"$evidence_directory/failure-workload-state.json" 2>/dev/null || true
    kube -n "$workload_namespace" get prometheusrule,servicemonitor -o yaml \
      >"$evidence_directory/failure-monitoring-config.yaml" 2>/dev/null || true
    kube -n "$argocd_namespace" get application "$application_name" -o json \
      >"$evidence_directory/failure-application.json" 2>/dev/null || true
  fi
  if [[ "$cluster_created" == true ]] && kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi
  if [[ -n "$original_context" ]]; then
    if kubectl config use-context "$original_context" >/dev/null &&
      [[ "$(kubectl config current-context 2>/dev/null || true)" == "$original_context" ]]; then
      context_restored=true
    else
      exit_code=1
    fi
  fi
  if [[ -n "$evidence_directory" ]]; then
    if kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
      printf 'FAIL: disposable cluster still exists\n' >"$evidence_directory/cleanup.txt"
      exit_code=1
    elif [[ "$context_restored" != true ]]; then
      printf 'FAIL: original context was not restored\n' >"$evidence_directory/cleanup.txt"
      exit_code=1
    else
      printf 'PASS: disposable cluster deleted; original context restored to %s\n' "$original_context" >"$evidence_directory/cleanup.txt"
    fi
  fi
  if [[ -n "$runtime_directory" && "$runtime_directory" == /private/tmp/forgepath-progressive-runtime.* ]]; then
    rm -rf "$runtime_directory"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

wait_deployment() {
  kube -n "$1" wait --for=condition=Available deployment/"$2" --timeout=300s >/dev/null
}

wait_pod_label() {
  local namespace="$1" selector="$2" deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    if [[ -n "$(kube -n "$namespace" get pod -l "$selector" -o name 2>/dev/null || true)" ]]; then
      kube -n "$namespace" wait --for=condition=Ready pod -l "$selector" --timeout=300s >/dev/null
      return 0
    fi
    sleep 2
  done
  fail "pod selector did not appear in $namespace: $selector"
}

wait_runtime_git() {
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    if kube -n "$argocd_namespace" exec deployment/argocd-repo-server \
      -c argocd-repo-server -- git ls-remote "$runtime_repo_url" HEAD \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail 'temporary Git remote did not become reachable from Argo CD'
}

wait_http() {
  local process_id="$1" url="$2" log_file="$3" deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    kill -0 "$process_id" 2>/dev/null || { sed -n '1,120p' "$log_file" >&2; fail 'port-forward exited'; }
    curl -fsS -o /dev/null "$url" && return 0
    sleep 2
  done
  fail "HTTP endpoint did not become ready: $url"
}

supervise_port_forward() {
  local namespace="$1" service="$2" mapping="$3" log_file="$4" child_pid=''
  trap 'if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi; exit 0' TERM INT EXIT
  while true; do
    kube -n "$namespace" port-forward service/"$service" "$mapping" >>"$log_file" 2>&1 &
    child_pid=$!
    wait "$child_pid" || true
    child_pid=''
    sleep 1
  done
}

wait_application() {
  local revision="$1" health="$2" deadline=$((SECONDS + 420)) state
  while ((SECONDS < deadline)); do
    state="$(kube -n "$argocd_namespace" get application "$application_name" -o json 2>/dev/null || true)"
    if [[ -n "$state" ]] && jq -e --arg revision "$revision" --arg health "$health" '
      .status.sync.status == "Synced" and .status.sync.revision == $revision and
      .status.health.status == $health
    ' <<<"$state" >/dev/null; then return 0; fi
    sleep 3
  done
  kube -n "$argocd_namespace" get application "$application_name" -o yaml >&2 || true
  fail "Application did not reach Synced/$health at $revision"
}

refresh_application() {
  require_context
  kube -n "$argocd_namespace" annotate application "$application_name" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

commit_runtime_change() {
  local message="$1"
  git -C "$runtime_directory/work" add --all
  git -C "$runtime_directory/work" commit -m "$message" >/dev/null
  git -C "$runtime_directory/work" push origin main >/dev/null
  git -C "$runtime_directory/work" rev-parse HEAD
}

for tool in curl docker git helm jq kind kubectl python3.12 sed shasum yq; do
  command -v "$tool" >/dev/null || fail "required tool not found: $tool"
done
[[ "$(kind version | awk '{print $2}')" == "$kind_version" ]] || fail "Kind $kind_version is required"
kind get clusters | grep -Fxq "$cluster_name" && fail "refusing pre-existing cluster $cluster_name"
original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] || fail 'an original Kubernetes context is required'
trusted_image_inputs=(
  templates/secure-fastapi-service/render.py
  templates/secure-fastapi-service/skeleton/.dockerignore
  templates/secure-fastapi-service/skeleton/Dockerfile
  templates/secure-fastapi-service/skeleton/app
  templates/secure-fastapi-service/skeleton/requirements.txt
)
[[ -z "$(git status --porcelain --untracked-files=all -- \
  "${trusted_image_inputs[@]}" gitops/environments/local/secure-fastapi-service/values.yaml)" ]] ||
  fail 'trusted image inputs and promoted values must be clean'
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null
"$repository_root/scripts/validate-gitops-static.sh" >/dev/null
source_revision="$(jq -er '.build.source_revision' "$metadata")"
artifact_source_dirty="$(jq -er '.build.source_dirty' "$metadata")"
artifact_digest="$(jq -er '.image.digest' "$metadata")"
artifact_repository="$(jq -er '.image.repository' "$metadata")"
[[ "$(git rev-parse "$source_revision")" == "$source_revision" ]] || fail 'artifact source revision is unavailable'
[[ "$(yq -er '.image.digest' gitops/environments/local/secure-fastapi-service/values.yaml)" == "$artifact_digest" ]] ||
  fail 'GitOps digest does not match trusted artifact'

runtime_directory="$(mktemp -d /private/tmp/forgepath-progressive-runtime.XXXXXX)"
evidence_parent="$repository_root/.forgepath/progressive-delivery-evidence"
evidence_directory="$evidence_parent/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$evidence_parent" "$runtime_directory/git"
mkdir "$evidence_directory"
traffic_log="$evidence_directory/request-events.csv"
rollout_samples="$evidence_directory/rollout-samples.jsonl"
printf 'epoch_seconds,delivery_role,path,status_code\n' >"$traffic_log"
: >"$rollout_samples"
jq '{image,build,vulnerability_scan:{result:.vulnerability_scan.result,database:.vulnerability_scan.database},signature:{verification_result:.signature.verification_result}}' \
  "$metadata" >"$evidence_directory/trusted-artifact.json"
printf '%s\n' "$source_revision" >"$evidence_directory/source-sha.txt"
printf '%s\n' "$artifact_digest" >"$evidence_directory/artifact-digest.txt"

git clone --no-local "$repository_root" "$runtime_directory/work" >/dev/null 2>&1
git -C "$runtime_directory/work" config user.name 'ForgePath Progressive Runtime'
git -C "$runtime_directory/work" config user.email 'progressive-runtime@forgepath.invalid'
git clone --bare "$runtime_directory/work" "$runtime_directory/git/forgepath.git" >/dev/null 2>&1
git -C "$runtime_directory/work" remote set-url origin "$runtime_directory/git/forgepath.git"
git --git-dir="$runtime_directory/git/forgepath.git" symbolic-ref HEAD refs/heads/main
initial_revision="$(git -C "$runtime_directory/work" rev-parse HEAD)"

curl -fsSLo "$runtime_directory/argocd.yaml" "$argocd_url"
curl -fsSLo "$runtime_directory/rollouts.yaml" "$rollouts_url"
curl -fsSLo "$runtime_directory/rollouts-full.yaml" "$rollouts_crds_url"
curl -fsSLo "$runtime_directory/operator.yaml" "$operator_url"
[[ "$(sha256_file "$runtime_directory/argocd.yaml")" == "$argocd_sha256" ]] || fail 'Argo CD checksum mismatch'
[[ "$(sha256_file "$runtime_directory/rollouts.yaml")" == "$rollouts_sha256" ]] || fail 'Argo Rollouts checksum mismatch'
[[ "$(sha256_file "$runtime_directory/rollouts-full.yaml")" == "$rollouts_crds_sha256" ]] || fail 'Argo Rollouts CRD checksum mismatch'
[[ "$(sha256_file "$runtime_directory/operator.yaml")" == "$operator_sha256" ]] || fail 'Prometheus Operator checksum mismatch'
sed -e "s#quay.io/argoproj/argocd:$argocd_version#$argocd_image#g" \
  -e "s#ghcr.io/dexidp/dex:v2.43.0#$dex_image#g" \
  -e "s#public.ecr.aws/docker/library/redis:8.2.3-alpine#$redis_image#g" \
  "$runtime_directory/argocd.yaml" >"$runtime_directory/argocd-pinned.yaml"
sed "s#quay.io/argoproj/argo-rollouts:$rollouts_version#$rollouts_image#g" \
  "$runtime_directory/rollouts.yaml" >"$runtime_directory/rollouts-pinned.yaml"
yq 'select(.kind == "CustomResourceDefinition")' "$runtime_directory/rollouts-full.yaml" \
  >"$runtime_directory/rollouts-crds.yaml"
sed -e 's/namespace: default/namespace: monitoring/g' \
  -e "s#quay.io/prometheus-operator/prometheus-operator:$operator_version#$operator_image#g" \
  -e "s#quay.io/prometheus-operator/prometheus-config-reloader:$operator_version#$reloader_image#g" \
  "$runtime_directory/operator.yaml" >"$runtime_directory/operator-pinned-base.yaml"
yq '(select(.kind == "Deployment" and .metadata.name == "prometheus-operator") |
  .spec.template.spec.containers[0].args) +=
  ["--namespaces=monitoring,secure-fastapi-service-local",
   "--prometheus-instance-namespaces=monitoring"]' \
  "$runtime_directory/operator-pinned-base.yaml" >"$runtime_directory/operator-pinned.yaml"
if yq -r -N '.. | select(has("image")) | .image | select(tag == "!!str")' "$runtime_directory/argocd-pinned.yaml" \
  "$runtime_directory/rollouts-pinned.yaml" "$runtime_directory/operator-pinned.yaml" |
  grep -Ev '@sha256:[a-f0-9]{64}$'; then fail 'mutable controller image remains'; fi

cat >"$runtime_directory/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $cluster_name
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $runtime_directory/git
        containerPath: /forgepath-runtime-git
        readOnly: true
EOF
cluster_created=true
kind create cluster --name "$cluster_name" --image "$kind_node_image" --config "$runtime_directory/kind.yaml" --wait 180s
require_context
[[ "$(kube version -o json | jq -r '.serverVersion.gitVersion')" == "$kubernetes_version" ]] || fail 'unexpected Kubernetes version'
kind load image-archive "$artifact_directory/image.oci.tar" --name "$cluster_name"
docker exec "${cluster_name}-control-plane" ctr --namespace k8s.io images tag \
  "$artifact_repository:0.1.0-local" "$artifact_repository@$artifact_digest" >/dev/null

kube create namespace "$argocd_namespace" >/dev/null
kube create namespace "$monitoring_namespace" >/dev/null
kube label namespace "$monitoring_namespace" \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
log 'provisioning the platform-owned governed namespace prerequisite'
kube apply -f gitops/platform/namespaces/secure-fastapi-service-local.yaml >/dev/null
kube get namespace "$workload_namespace" -o json | jq -e '
  .metadata.labels["forgepath.dev/managed-by"] == "platform" and
  .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted"
' >/dev/null
kube -n "$workload_namespace" get resourcequota/forgepath-namespace-boundary \
  limitrange/forgepath-namespace-boundary \
  networkpolicy/forgepath-platform-default-deny \
  networkpolicy/forgepath-platform-allow-prometheus \
  networkpolicy/forgepath-platform-allow-dns \
  networkpolicy/forgepath-platform-allow-rollouts-prometheus-egress >/dev/null

log 'submitting one local developer self-service request'
request_started="$(python3.12 -c 'import time; print(time.time())')"
generation_root="$runtime_directory/self-service/generated"
simulation_root="$runtime_directory/self-service/published"
generated_service="$generation_root/secure-fastapi-service"
python3.12 templates/secure-fastapi-service/render.py \
  --output "$generated_service" --service-name secure-fastapi-service \
  --owner group:default/platform --system forgepath --environment local \
  --data-classification internal \
  --image-repository ghcr.io/securecloudops/secure-fastapi-service \
  --kubernetes-namespace "$workload_namespace"
python3.12 templates/secure-fastapi-service/publish.py \
  --mode local --source "$generated_service" --generation-root "$generation_root" \
  --simulation-root "$simulation_root" --service-name secure-fastapi-service \
  --owner group:default/platform --system forgepath --environment local \
  --data-classification internal --repository-owner SecureCloudOps \
  --gitops-repository SecureCloudOps/forgepath-gitops \
  --backstage-identity user:default/runtime-developer \
  --allowed-owner group:default/platform --allowed-system forgepath \
  --allowed-repository-owner SecureCloudOps >"$evidence_directory/publication.json"
jq -e '
  .developerExperience.manualSteps == 1 and
  .developerExperience.securityControlsInherited == 9 and
  .developerExperience.requestToRepositorySeconds >= 0 and
  .developerExperience.requestToFirstPullRequestSeconds >=
    .developerExperience.requestToRepositorySeconds
' "$evidence_directory/publication.json" >/dev/null
log "installing pinned Argo CD $argocd_version"
kube -n "$argocd_namespace" apply --server-side --force-conflicts -f "$runtime_directory/argocd-pinned.yaml" >/dev/null
wait_deployment "$argocd_namespace" argocd-server
log "installing namespace-scoped Argo Rollouts $rollouts_version"
kube apply --server-side --force-conflicts -f "$runtime_directory/rollouts-crds.yaml" >/dev/null
kube wait --for=condition=Established customresourcedefinition/rollouts.argoproj.io \
  customresourcedefinition/analysistemplates.argoproj.io \
  customresourcedefinition/analysisruns.argoproj.io --timeout=120s >/dev/null
kube -n "$workload_namespace" apply -f "$runtime_directory/rollouts-pinned.yaml" >/dev/null
wait_deployment "$workload_namespace" argo-rollouts
log "installing namespace-filtered Prometheus Operator $operator_version"
kube apply --server-side --force-conflicts -f "$runtime_directory/operator-pinned.yaml" >/dev/null
wait_deployment "$monitoring_namespace" prometheus-operator

cat >"$runtime_directory/monitoring.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: forgepath-prometheus, namespace: $monitoring_namespace}
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: forgepath-prometheus-discovery, namespace: $workload_namespace}
rules:
  - apiGroups: [""]
    resources: ["endpoints", "pods", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: forgepath-prometheus-discovery, namespace: $workload_namespace}
subjects:
  - {kind: ServiceAccount, name: forgepath-prometheus, namespace: $monitoring_namespace}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: forgepath-prometheus-discovery}
---
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata: {name: forgepath, namespace: $monitoring_namespace}
spec:
  replicas: 1
  serviceAccountName: forgepath-prometheus
  image: $prometheus_image
  version: v3.5.0
  retention: 1h
  serviceMonitorSelector:
    matchLabels: {app.kubernetes.io/name: secure-fastapi-service}
  serviceMonitorNamespaceSelector:
    matchLabels: {kubernetes.io/metadata.name: $workload_namespace}
  ruleSelector:
    matchLabels: {app.kubernetes.io/name: secure-fastapi-service}
  ruleNamespaceSelector:
    matchLabels: {kubernetes.io/metadata.name: $workload_namespace}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: 500m, memory: 512Mi}
EOF
kube apply -f "$runtime_directory/monitoring.yaml" >/dev/null
wait_pod_label "$monitoring_namespace" 'app.kubernetes.io/name=prometheus'

cat >"$runtime_directory/repo-server-patch.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: runtime-git-daemon
          image: $argocd_image
          imagePullPolicy: IfNotPresent
          command: [git, daemon]
          args: [--export-all, --base-path=/runtime-git, --reuseaddr, --listen=0.0.0.0, --port=9418, /runtime-git]
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: runtime-git, mountPath: /runtime-git, readOnly: true}]
      volumes: [{name: runtime-git, hostPath: {path: /forgepath-runtime-git, type: Directory}}]
EOF
kube -n "$argocd_namespace" patch deployment argocd-repo-server --type strategic \
  --patch-file "$runtime_directory/repo-server-patch.yaml" >/dev/null
wait_deployment "$argocd_namespace" argocd-repo-server
wait_runtime_git
RUNTIME_REPO_URL="$runtime_repo_url" yq '.spec.sourceRepos = [strenv(RUNTIME_REPO_URL)]' \
  gitops/projects/forgepath-local.yaml >"$runtime_directory/project.yaml"
RUNTIME_REPO_URL="$runtime_repo_url" yq '.spec.source.repoURL = strenv(RUNTIME_REPO_URL)' \
  gitops/applications/secure-fastapi-service-local.yaml >"$runtime_directory/application.yaml"
kube apply -f "$runtime_directory/project.yaml" -f "$runtime_directory/application.yaml" >/dev/null
sleep 3
refresh_application
wait_application "$initial_revision" Healthy

initial_rollout="$(kube -n "$workload_namespace" get rollout "$rollout_name" -o json)"
jq -e '.status.conditions[] | select(.type == "Healthy" and .status == "True")' <<<"$initial_rollout" >/dev/null
initial_stable_hash="$(jq -er '.status.stableRS' <<<"$initial_rollout")"
printf '%s\n' "$initial_revision" >"$evidence_directory/initial-git-sha.txt"
printf '%s\n' "$initial_revision" >"$evidence_directory/digest-promotion-sha.txt"
jq . <<<"$initial_rollout" >"$evidence_directory/healthy-v1-rollout.json"
log "PASS healthy v1: $initial_revision stable hash $initial_stable_hash"
request_to_healthy="$(python3.12 -c \
  'import sys,time; print(round(time.time() - float(sys.argv[1]), 3))' "$request_started")"
jq --argjson healthy "$request_to_healthy" '
  .developerExperience.requestToHealthySeconds = $healthy |
  .developerExperience + {
    developerNeedsKubectl: false,
    developerNeedsToUnderstand: {
      "Argo CD": false,
      "Kyverno": false,
      "Argo Rollouts": false,
      "Prometheus": false,
      "NetworkPolicy": false
    }
  }
' "$evidence_directory/publication.json" >"$evidence_directory/developer-experience.json"
log "PASS developer request to Healthy: ${request_to_healthy}s"

yq -i '.failureFixture.enabled = true |
  .monitoring.slo.windowProfile = "demo" |
  .progressiveDelivery.analysis.burnRateWindow = "1m" |
  .progressiveDelivery.analysis.initialDelay = "360s"' \
  "$runtime_directory/work/gitops/environments/local/secure-fastapi-service/values.yaml"
defective_release_started="$(now_epoch)"
promotion_revision="$(commit_runtime_change 'demo: promote trusted defective v2 fixture')"
printf '%s\n' "$promotion_revision" >"$evidence_directory/promotion-sha.txt"
printf '%s\n' "$promotion_revision" >"$evidence_directory/defective-promotion-sha.txt"
refresh_application

deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  endpoints="$(kube -n "$workload_namespace" get endpoints "$canary_service" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$endpoints" ]] && break
  sleep 2
done
[[ -n "${endpoints:-}" ]] || fail 'canary Service never received an endpoint'
deadline=$((SECONDS + 180))
while ((SECONDS < deadline)); do
  rollout_progress="$(kube -n "$workload_namespace" get rollout "$rollout_name" -o json 2>/dev/null || true)"
  if [[ -n "$rollout_progress" ]] && jq -e '
    .status.currentStepIndex == 1 and .status.updatedReplicas == 1 and
    .status.readyReplicas >= 20
  ' <<<"$rollout_progress" >/dev/null; then break; fi
  sleep 2
done
if [[ -z "${rollout_progress:-}" ]] || ! jq -e '
  .status.currentStepIndex == 1 and .status.updatedReplicas == 1 and
  .status.readyReplicas >= 20
' <<<"$rollout_progress" >/dev/null; then
  fail '5% replica weighting did not settle at one canary pod'
fi
sample_rollout
candidate_hash="$(jq -er '.status.currentPodHash' <<<"$rollout_progress")"
supervise_port_forward "$workload_namespace" "$stable_service" 18080:80 "$runtime_directory/stable-forward.log" &
stable_forward_pid=$!
supervise_port_forward "$workload_namespace" "$canary_service" 18081:80 "$runtime_directory/canary-forward.log" &
canary_forward_pid=$!
wait_http "$stable_forward_pid" 'http://127.0.0.1:18080/health/ready' "$runtime_directory/stable-forward.log"
wait_http "$canary_forward_pid" 'http://127.0.0.1:18081/health/ready' "$runtime_directory/canary-forward.log"
canary_status="$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:18081/_test/failure' || true)"
[[ "$canary_status" == 503 ]] || fail "defective canary fixture returned HTTP $canary_status instead of 503"
supervise_port_forward "$monitoring_namespace" prometheus-operated 19090:9090 "$runtime_directory/prometheus-forward.log" &
prometheus_forward_pid=$!
wait_http "$prometheus_forward_pid" 'http://127.0.0.1:19090/-/ready' "$runtime_directory/prometheus-forward.log"
(
  while true; do
    cycle_epoch="$(now_epoch)"
    for _ in {1..19}; do
      status="$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:18080/docs' 2>/dev/null || true)"
      printf '%s,stable,/docs,%s\n' "$cycle_epoch" "$status" >>"$traffic_log"
    done
    failure_epoch="$(now_epoch)"
    status="$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:18081/_test/failure' 2>/dev/null || true)"
    printf '%s,canary,/_test/failure,%s\n' "$failure_epoch" "$status" >>"$traffic_log"
    [[ "$status" == 503 ]] || sleep 1
  done
) &
traffic_pid=$!

burn_query="forgepath:slo_availability_burn_rate{forgepath_service=\"$rollout_name\",window=\"1m\"}"
canary_error_query="sum(increase(http_requests_total{forgepath_service=\"$rollout_name\",path=\"/_test/failure\",status_code=\"503\"}[1m]))"
alert_query='ALERTS{alertname="ForgePathSLOFastBurn",alertstate="firing"}'
budget_query="forgepath:slo_error_budget_remaining:ratio{forgepath_service=\"$rollout_name\",window=\"1h\"}"
deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  curl -fsS --get --data-urlencode "query=$canary_error_query" 'http://127.0.0.1:19090/api/v1/query' \
    >"$evidence_directory/prometheus-canary-errors.json"
  curl -fsS --get --data-urlencode "query=$burn_query" 'http://127.0.0.1:19090/api/v1/query' \
    >"$evidence_directory/prometheus-burn-rate.json"
  curl -fsS --get --data-urlencode "query=$alert_query" 'http://127.0.0.1:19090/api/v1/query' \
    >"$evidence_directory/prometheus-alert.json"
  canary_errors="$(jq -r '.data.result[0].value[1] // "0"' "$evidence_directory/prometheus-canary-errors.json")"
  burn="$(jq -r '.data.result[0].value[1] // "0"' "$evidence_directory/prometheus-burn-rate.json")"
  alerts="$(jq '.data.result | length' "$evidence_directory/prometheus-alert.json")"
  sample_rollout
  if jq -ne --argjson errors "$canary_errors" --argjson burn "$burn" \
    '$errors > 0 and $burn > 14.4 and $burn < 100' >/dev/null && [[ "$alerts" -gt 0 ]]; then break; fi
  sleep 5
done
jq -ne --argjson errors "${canary_errors:-0}" '$errors > 0' >/dev/null ||
  fail 'Prometheus did not observe the defective canary 503 counter'
jq -ne --argjson burn "${burn:-0}" '$burn > 14.4 and $burn < 100' >/dev/null ||
  fail 'Prometheus burn rate did not establish the expected replica-weighted breach before analysis'
[[ "${alerts:-0}" -gt 0 ]] || fail 'fast-burn alert did not fire before analysis'
detected_at="$(now_epoch)"
log "PASS Prometheus precondition: canary errors $canary_errors; burn rate $burn; fast-burn alert firing"
acknowledge_incident

kube -n "$workload_namespace" get pod -l "rollouts-pod-template-hash=$candidate_hash" -o json \
  >"$evidence_directory/canary-pods.json"
kube -n "$workload_namespace" logs -l "rollouts-pod-template-hash=$candidate_hash" \
  -c application --prefix=true >"$evidence_directory/canary-logs.txt"
kube -n "$workload_namespace" get rollout "$rollout_name" -o json \
  >"$evidence_directory/diagnostic-rollout.json"
kube -n "$argocd_namespace" get application "$application_name" -o json \
  >"$evidence_directory/diagnostic-application.json"
git -C "$runtime_directory/work" diff "$initial_revision" "$promotion_revision" -- \
  gitops/environments/local/secure-fastapi-service/values.yaml \
  >"$evidence_directory/defective-release.patch"
jq -e 'any(.items[].spec.containers[];
  any(.env[]?; .name == "FORGEPATH_FAILURE_FIXTURE_ENABLED" and .value == "true"))' \
  "$evidence_directory/canary-pods.json" >/dev/null || fail 'candidate pod did not contain the controlled fixture setting'
grep -Fq '"path":"/_test/failure","status_code":503' "$evidence_directory/canary-logs.txt" ||
  fail 'canary logs did not correlate the controlled route with HTTP 503'
grep -Fq '+failureFixture:' "$evidence_directory/defective-release.patch" ||
  grep -Fq '+  enabled: true' "$evidence_directory/defective-release.patch" ||
  fail 'Git evidence did not identify the enabled failure fixture'
log 'DIAGNOSIS Git diff, candidate configuration, logs, metrics, and alert confirm the controlled 503 fixture'

analysis_name=''
analysis_phase=''
previous_analysis_phase=''
deadline=$((SECONDS + 360))
while ((SECONDS < deadline)); do
  analysis_name="$(kube -n "$workload_namespace" get analysisrun \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$analysis_name" ]]; then
    kube -n "$workload_namespace" get analysisrun "$analysis_name" -o json \
      >"$evidence_directory/analysisrun-observed.json"
    analysis_phase="$(jq -r '.status.phase // "Pending"' "$evidence_directory/analysisrun-observed.json")"
    if [[ "$analysis_phase" != "$previous_analysis_phase" ]]; then
      log "AnalysisRun $analysis_name phase: $analysis_phase"
      previous_analysis_phase="$analysis_phase"
    fi
    [[ "$analysis_phase" == Failed ]] && break
    if [[ "$analysis_phase" =~ ^(Successful|Error|Inconclusive)$ ]]; then
      fail "AnalysisRun entered unexpected terminal phase: $analysis_phase"
    fi
  fi
  sample_rollout
  kill -0 "$traffic_pid" 2>/dev/null || fail 'traffic generator exited'
  kill -0 "$stable_forward_pid" 2>/dev/null || fail 'stable Service port-forward exited'
  kill -0 "$canary_forward_pid" 2>/dev/null || fail 'canary Service port-forward exited'
  sleep 3
done
[[ -n "$analysis_name" ]] || fail 'AnalysisRun was not created'
[[ "$analysis_phase" == Failed ]] || fail "AnalysisRun did not fail; last phase: ${analysis_phase:-unknown}"
kube -n "$workload_namespace" get analysisrun "$analysis_name" -o json >"$evidence_directory/failed-analysisrun.json"

aborted_rollout="$(kube -n "$workload_namespace" get rollout "$rollout_name" -o json)"
jq -e --arg stable "$initial_stable_hash" '
  .status.stableRS == $stable and .status.currentStepIndex <= 1 and
  any(.status.conditions[]; .reason == "RolloutAborted" or (.message | tostring | test("abort"; "i")))
' <<<"$aborted_rollout" >/dev/null || fail 'Rollout did not abort at the 5% gate'
stable_selector="$(kube -n "$workload_namespace" get service "$stable_service" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}')"
[[ "$stable_selector" == "$initial_stable_hash" ]] || fail 'stable Service moved away from v1'
jq . <<<"$aborted_rollout" >"$evidence_directory/aborted-rollout.json"
kube -n "$workload_namespace" get service,endpoints,pod -o json >"$evidence_directory/stable-workload.json"
sample_rollout

kube -n "$workload_namespace" get events --sort-by=.metadata.creationTimestamp -o json \
  >"$evidence_directory/workload-events.json"
jq -e '.status.phase == "Failed" and
  any(.status.metricResults[]?; .name == "availability-burn-rate" and .phase == "Failed")' \
  "$evidence_directory/failed-analysisrun.json" >/dev/null || fail 'AnalysisRun evidence did not confirm the failed SLO gate'

curl -fsS --get --data-urlencode "query=$burn_query" 'http://127.0.0.1:19090/api/v1/query' \
  >"$evidence_directory/prometheus-post-abort-burn-rate.json" || true
curl -fsS --get --data-urlencode "query=$budget_query" 'http://127.0.0.1:19090/api/v1/query' \
  >"$evidence_directory/prometheus-error-budget.json"
kube -n "$argocd_namespace" get application "$application_name" -o json >"$evidence_directory/aborted-application.json"
log "PASS defective v2 aborted at 5%; burn rate $burn; stable hash $stable_selector"

kill "$traffic_pid" 2>/dev/null || true
wait "$traffic_pid" 2>/dev/null || true
traffic_pid=''
if awk -F, 'NR > 1 && $4 != 200 && $4 != 503 {exit 1}' "$traffic_log"; then :; else
  fail 'traffic evidence contains a status other than the expected 200 and 503'
fi
failed_requests="$(awk -F, 'NR > 1 && $4 >= 500 {count++} END {print count + 0}' "$traffic_log")"
total_requests="$(awk 'END {print NR - 1}' "$traffic_log")"
[[ "$failed_requests" -gt 0 && "$total_requests" -gt "$failed_requests" ]] ||
  fail 'traffic evidence did not capture both healthy and failed requests'
error_budget_remaining="$(jq -er '.data.result[0].value[1]' "$evidence_directory/prometheus-error-budget.json")"
jq -ne --argjson remaining "$error_budget_remaining" '$remaining >= 0 and $remaining <= 1' >/dev/null ||
  fail 'Prometheus error-budget result was invalid'

approve_git_recovery
git -C "$runtime_directory/work" revert --no-edit "$promotion_revision" >/dev/null
git -C "$runtime_directory/work" push origin main >/dev/null
revert_revision="$(git -C "$runtime_directory/work" rev-parse HEAD)"
printf '%s\n' "$revert_revision" >"$evidence_directory/revert-sha.txt"
refresh_application
wait_application "$revert_revision" Healthy
final_rollout="$(kube -n "$workload_namespace" get rollout "$rollout_name" -o json)"
jq -e --arg stable "$initial_stable_hash" '
  .status.stableRS == $stable and any(.status.conditions[]; .type == "Healthy" and .status == "True")
' <<<"$final_rollout" >/dev/null || fail 'healthy desired state was not restored'
curl -fsS -o /dev/null 'http://127.0.0.1:18080/docs' || fail 'restoration verification request failed'
restored_at="$(now_epoch)"
jq . <<<"$final_rollout" >"$evidence_directory/final-rollout.json"
kube -n "$argocd_namespace" get application "$application_name" -o json >"$evidence_directory/final-application.json"

incident_id="INC-$(basename "$evidence_directory")"
jq -n \
  --arg incident_id "$incident_id" \
  --arg responder "$incident_responder" \
  --arg rollback_control "$rollback_control" \
  --arg rollback_actor "$rollback_actor" \
  --arg healthy_revision "$initial_revision" \
  --arg defective_revision "$promotion_revision" \
  --arg recovery_revision "$revert_revision" \
  --arg analysis_name "$analysis_name" \
  --arg stable_hash "$initial_stable_hash" \
  --arg candidate_hash "$candidate_hash" \
  --argjson release_started "$defective_release_started" \
  --argjson detected "$detected_at" \
  --argjson acknowledged "$acknowledged_at" \
  --argjson recovery_started "$recovery_started_at" \
  --argjson restored "$restored_at" \
  --argjson remaining "$error_budget_remaining" \
  --argjson burn "$burn" \
  --argjson failed "$failed_requests" \
  --argjson total "$total_requests" \
  --argjson artifact_source_dirty "$artifact_source_dirty" \
  '{
    schemaVersion: 1,
    incidentId: $incident_id,
    service: "secure-fastapi-service",
    status: "resolved",
    severity: "SEV-2 exercise",
    responder: $responder,
    objective: {availabilityTarget: 0.999, budgetWindow: "1h"},
    timestamps: {
      defectiveReleaseStartedAtEpochSeconds: $release_started,
      detectedAtEpochSeconds: $detected,
      acknowledgedAtEpochSeconds: $acknowledged,
      recoveryStartedAtEpochSeconds: $recovery_started,
      restoredAtEpochSeconds: $restored
    },
    errorBudgetRemainingRatio: $remaining,
    rollback: {control: $rollback_control, actor: $rollback_actor},
    revisions: {healthy: $healthy_revision, defective: $defective_revision, recovery: $recovery_revision},
    impact: ("A controlled defective canary returned " + ($failed | tostring) +
      " HTTP 503 responses among " + ($total | tostring) +
      " synthetic requests. The stable Service remained on the healthy ReplicaSet."),
    detection: ("Prometheus observed the ForgePathSLOFastBurn alert firing at " +
      ($burn | tostring) + "x burn before AnalysisRun " + $analysis_name + " completed."),
    rootCause: ("The defective Git revision enabled failureFixture.enabled and routed the canary " +
      "test endpoint to an intentional HTTP 503 response. Canary logs, the Git diff, Prometheus " +
      "metrics, and the failed AnalysisRun independently confirm the causal chain."),
    contributingFactors: [
      "The demo profile intentionally compresses alert and error-budget windows for an operational exercise.",
      "Replica weighting requires the synthetic generator to preserve the explicit 95/5 stable/canary request mix.",
      "The canary stays probe-healthy, so SLO telemetry—not readiness—must identify the defect."
    ],
    recovery: ("After evidence collection and authorization, a Git revert restored the healthy desired state. " +
      "Argo CD reconciled the recovery revision; no imperative Rollout promotion or workload patch was used."),
    correctiveActions: [
      {id: "CA-1", action: "Run this evidence-producing incident exercise after changes to rollout or SLO policy.", owner: "platform", status: "open"},
      {id: "CA-2", action: "Integrate the production alert route with an external paging and acknowledgment system.", owner: "observability", status: "open"},
      {id: "CA-3", action: "Set and review target thresholds for MTTD, MTTA, MTTR, exposure, and budget consumption.", owner: "service-owner", status: "open"},
      {id: "CA-4", action: "Rebuild the trusted artifact from a clean source state so provenance records source_dirty=false.", owner: "supply-chain", status: (if $artifact_source_dirty then "open" else "closed" end)}
    ],
    detectionGaps: ([
      "The disposable exercise polls Prometheus directly and does not prove Alertmanager notification delivery.",
      "Traffic is synthetic and does not validate client-side retry or regional impact behavior."
    ] + (if $artifact_source_dirty then
      [("Trusted-artifact integrity is verified, but its retained provenance records source_dirty=" + ($artifact_source_dirty | tostring) + ".")]
    else [] end)),
    unverifiedHypotheses: [],
    evidence: [
      {id: "synthetic-requests", path: "request-events.csv", observation: "Authoritative per-request status evidence used for impact start and the exact failed-request count."},
      {id: "trusted-artifact", path: "trusted-artifact.json", observation: ("Signature, digest, vulnerability, and source metadata were retained; source_dirty=" + ($artifact_source_dirty | tostring) + ".")},
      {id: "rollout-samples", path: "rollout-samples.jsonl", observation: "Time-series Rollout samples used to calculate maximum canary exposure."},
      {id: "canary-logs", path: "canary-logs.txt", observation: "Structured application logs show request_complete for /_test/failure with status_code 503."},
      {id: "canary-pods", path: "canary-pods.json", observation: ("Candidate ReplicaSet " + $candidate_hash + " had the controlled failure environment enabled.")},
      {id: "git-change", path: "defective-release.patch", observation: "The only incident-triggering desired-state change enabled the fixture and accelerated demo telemetry windows."},
      {id: "prometheus-errors", path: "prometheus-canary-errors.json", observation: "Prometheus counted eligible canary HTTP 503 responses."},
      {id: "prometheus-burn", path: "prometheus-burn-rate.json", observation: ("The recorded availability burn rate was " + ($burn | tostring) + "x, above the 14.4x gate.")},
      {id: "prometheus-alert", path: "prometheus-alert.json", observation: "ForgePathSLOFastBurn was firing before rollout analysis completed."},
      {id: "prometheus-budget", path: "prometheus-error-budget.json", observation: "The 1-hour demo availability error-budget remaining ratio was captured at peak impact."},
      {id: "analysisrun", path: "failed-analysisrun.json", observation: ("AnalysisRun " + $analysis_name + " failed its availability burn-rate measurement.")},
      {id: "diagnostic-rollout", path: "diagnostic-rollout.json", observation: "The live Rollout was at the first analysis gate when the diagnosis was recorded."},
      {id: "argocd-at-diagnosis", path: "diagnostic-application.json", observation: "Argo CD tied the live candidate to the defective Git revision during triage."},
      {id: "aborted-rollout", path: "aborted-rollout.json", observation: ("The Rollout aborted at the first gate and retained stable ReplicaSet " + $stable_hash + ".")},
      {id: "argocd-before-recovery", path: "aborted-application.json", observation: "Argo CD runtime state tied the defective workload to the defective Git revision."},
      {id: "workload-events", path: "workload-events.json", observation: "Kubernetes events preserve the controller-side rollout sequence."},
      {id: "restored-rollout", path: "final-rollout.json", observation: "The Rollout returned Healthy on the stable ReplicaSet after Git recovery."},
      {id: "argocd-after-recovery", path: "final-application.json", observation: "Argo CD reconciled the Git recovery revision to Synced/Healthy."}
    ]
  }' >"$evidence_directory/incident-context.json"

python3.12 "$repository_root/scripts/render-incident-postmortem.py" \
  --context "$evidence_directory/incident-context.json" \
  --output-dir "$evidence_directory"
expected_rollback_control='automatic'
[[ "$incident_mode" == interactive ]] && expected_rollback_control='human-approved'
jq -e --arg control "$expected_rollback_control" '
  .mttdSeconds >= 0 and .mttaSeconds >= 0 and .mttrSeconds >= .mttdSeconds and
  .maximumCanaryExposurePercent == 5 and .failedSyntheticRequests > 0 and
  .errorBudgetConsumedRatio >= 0 and .errorBudgetConsumedRatio <= 1 and
  .rollbackControl == $control
' "$evidence_directory/incident-metrics.json" >/dev/null
printf 'PASS source=%s artifact=%s digest_promotion=%s defective_promotion=%s analysis=%s revert=%s incident=%s\n' \
  "$source_revision" "$artifact_digest" "$initial_revision" "$promotion_revision" "$analysis_name" "$revert_revision" "$incident_id" \
  >"$evidence_directory/summary.txt"
log "PASS Git revert reconciled Healthy at $revert_revision"
log "PASS incident metrics and postmortem rendered for $incident_id"
log "EVIDENCE $evidence_directory"
