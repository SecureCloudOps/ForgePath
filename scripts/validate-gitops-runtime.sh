#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

cluster_name='forgepath-gitops'
kind_context="kind-$cluster_name"
argocd_namespace='argocd'
workload_namespace='secure-fastapi-service-local'
application_name='secure-fastapi-service-local'
visibility_namespace='forgepath-backstage-visibility'
visibility_service_account='backstage-runtime-reader'
backstage_runtime_port='17007'
backstage_frontend_port='13000'

kind_version='v0.32.0'
kubernetes_version='v1.32.11'
kind_node_image='kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8'
argocd_version='v3.3.8'
argocd_manifest_url='https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/install.yaml'
argocd_manifest_sha256='75390e0cc232195d6d1a9614631f2beb0baa23ef227db380351ea235904a1f0d'
argocd_image='quay.io/argoproj/argocd@sha256:5d45dc6db21db32a0638ac9128462c6d9956a90fc81760146dada5a243ff7516'
dex_image='ghcr.io/dexidp/dex@sha256:b08a58c9731c693b8db02154d7afda798e1888dc76db30d34c4a0d0b8a26d913'
redis_image='public.ecr.aws/docker/library/redis@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba'
runtime_repo_url='git://127.0.0.1:9418/forgepath.git'

artifact_directory="${FORGEPATH_ARTIFACT_DIR:-$repository_root/.forgepath/trusted-artifact}"
metadata="$artifact_directory/metadata.json"
runtime_directory=''
original_context=''
cluster_created=false
proxy_pid=''
backstage_pid=''

log() {
  printf '[forgepath-gitops-runtime] %s\n' "$*"
}

fail() {
  printf '[forgepath-gitops-runtime] ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

kube() {
  kubectl --context "$kind_context" "$@"
}

require_target_context() {
  [[ "$(kubectl config current-context 2>/dev/null || true)" == "$kind_context" ]] ||
    fail "refusing mutation because current context is not $kind_context"
}

# ShellCheck cannot infer that this function is reached through the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM

  if [[ -n "$backstage_pid" ]]; then
    kill "$backstage_pid" 2>/dev/null || true
    wait "$backstage_pid" 2>/dev/null || true
  fi
  # The Backstage CLI supervises its backend child. The runtime uses a
  # dedicated port, so an exact listener lookup safely catches that child
  # without touching any pre-existing developer portal process.
  backstage_listener="$(lsof -tiTCP:"$backstage_runtime_port" \
    -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$backstage_listener" ]]; then
    kill "$backstage_listener" 2>/dev/null || true
  fi
  backstage_frontend_listener="$(lsof -tiTCP:"$backstage_frontend_port" \
    -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$backstage_frontend_listener" ]]; then
    kill "$backstage_frontend_listener" 2>/dev/null || true
  fi
  if [[ -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi

  if [[ "$cluster_created" == 'true' ]]; then
    log "deleting only Kind cluster $cluster_name"
    kind delete cluster --name "$cluster_name" >/dev/null || exit_code=1
  fi

  if [[ -n "$original_context" ]]; then
    log "restoring original Kubernetes context $original_context"
    kubectl config use-context "$original_context" >/dev/null || exit_code=1
  fi

  if [[ -n "$runtime_directory" &&
        "$runtime_directory" == /private/tmp/forgepath-gitops-runtime.* &&
        -d "$runtime_directory" ]]; then
    rm -rf "$runtime_directory"
  fi

  if [[ $exit_code -eq 0 ]]; then
    log 'cleanup passed: target cluster and temporary runtime Git data removed'
  else
    printf '[forgepath-gitops-runtime] cleanup encountered an error\n' >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

wait_for_http_process() {
  local pid="$1"
  local url="$2"
  local name="$3"
  local deadline=$((SECONDS + 180))

  while ((SECONDS < deadline)); do
    kill -0 "$pid" 2>/dev/null || {
      [[ -s "$runtime_directory/$name.log" ]] &&
        sed -n '1,200p' "$runtime_directory/$name.log" >&2
      fail "$name exited before becoming available"
    }
    if curl -fsS -o /dev/null "$url"; then
      return 0
    fi
    sleep 2
  done
  fail "$name did not become available at $url"
}

assert_subject_access() {
  local expected="$1"
  local verb="$2"
  local resource="$3"
  local namespace="$4"
  local subject="$5"
  local actual

  # `kubectl auth can-i` intentionally exits 1 when the answer is "no". Keep
  # that answer as evidence instead of letting fail-fast abort a denial test.
  actual="$(kube auth can-i "$verb" "$resource" --namespace "$namespace" \
    --as "$subject" || true)"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $subject can-i $verb $resource in $namespace to be $expected, got $actual"
}

wait_for_application() {
  local expected_revision="$1"
  local timeout_seconds="${2:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  local state sync_status health_status revision

  while ((SECONDS < deadline)); do
    state="$(kube -n "$argocd_namespace" get application "$application_name" -o json 2>/dev/null || true)"
    if [[ -n "$state" ]]; then
      sync_status="$(jq -r '.status.sync.status // ""' <<<"$state")"
      health_status="$(jq -r '.status.health.status // ""' <<<"$state")"
      revision="$(jq -r '.status.sync.revision // ""' <<<"$state")"
      if [[ "$sync_status" == 'Synced' && "$health_status" == 'Healthy' &&
            "$revision" == "$expected_revision" ]]; then
        return 0
      fi
    fi
    sleep 3
  done

  kube -n "$argocd_namespace" get application "$application_name" -o yaml >&2 || true
  fail "Application did not become Synced and Healthy at revision $expected_revision"
}

wait_for_replicas() {
  local expected="$1"
  local deadline=$((SECONDS + 180))
  local desired ready

  while ((SECONDS < deadline)); do
    desired="$(kube -n "$workload_namespace" get deployment secure-fastapi-service-secure-fastapi-service -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    ready="$(kube -n "$workload_namespace" get deployment secure-fastapi-service-secure-fastapi-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "$desired" == "$expected" && "$ready" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  fail "Deployment did not reach $expected desired and ready replicas"
}

refresh_application() {
  require_target_context
  kube -n "$argocd_namespace" annotate application "$application_name" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

commit_runtime_change() {
  local message="$1"
  git -C "$runtime_directory/work" add --all
  git -C "$runtime_directory/work" commit -m "$message" >/dev/null
  git -C "$runtime_directory/work" push origin main >/dev/null
  git --git-dir="$runtime_directory/git/forgepath.git" update-server-info
  git -C "$runtime_directory/work" rev-parse HEAD
}

wait_for_rejection() {
  local candidate="$1"
  local pattern="$2"
  local deadline=$((SECONDS + 180))
  local state messages

  while ((SECONDS < deadline)); do
    state="$(kube -n "$argocd_namespace" get application "$candidate" -o json 2>/dev/null || true)"
    if [[ -n "$state" ]]; then
      messages="$(jq -r '[
        .status.conditions[]?.message,
        .status.operationState.message,
        .status.operationState.syncResult.resources[]?.message
      ] | map(select(. != null)) | join(" ")' <<<"$state")"
      if grep -Eiq "$pattern" <<<"$messages"; then
        printf '%s\n' "$messages"
        return 0
      fi
    fi
    sleep 3
  done
  kube -n "$argocd_namespace" get application "$candidate" -o yaml >&2 || true
  fail "containment Application $candidate was not rejected with pattern: $pattern"
}

python_bin="${PYTHON_BIN:-python3.12}"
for tool in corepack curl docker git helm jq kind kubectl lsof node "$python_bin" tar yq; do
  command -v "$tool" >/dev/null || fail "required runtime tool not found: $tool"
done

actual_kind_version="$(kind version | awk '{print $2}')"
[[ "$actual_kind_version" == "$kind_version" ]] ||
  fail "Kind $kind_version is required; found $actual_kind_version"

if kind get clusters | grep -Fxq "$cluster_name"; then
  fail "refusing to use pre-existing Kind cluster $cluster_name"
fi

original_context="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$original_context" ]] || fail 'an original Kubernetes context is required for exact restoration'
log "recorded original Kubernetes context: $original_context"

[[ -s "$metadata" ]] || fail "trusted artifact metadata is missing: $metadata"
"$repository_root/scripts/validate-trusted-artifact.sh" "$artifact_directory" >/dev/null
trusted_repository="$(jq -er '.image.repository' "$metadata")"
trusted_digest="$(jq -er '.image.digest' "$metadata")"
trusted_reference="$trusted_repository@$trusted_digest"
desired_repository="$(yq -er '.image.repository' gitops/environments/local/secure-fastapi-service/values.yaml)"
desired_digest="$(yq -er '.image.digest' gitops/environments/local/secure-fastapi-service/values.yaml)"
[[ "$trusted_repository" == "$desired_repository" && "$trusted_digest" == "$desired_digest" ]] ||
  fail 'GitOps desired state does not match trusted artifact metadata'

runtime_directory="$(mktemp -d /private/tmp/forgepath-gitops-runtime.XXXXXX)"
mkdir -p "$runtime_directory/git"

log "rebuilding the application and proving digest reproducibility for $trusted_reference"
"$python_bin" templates/secure-fastapi-service/render.py \
  --output "$runtime_directory/rendered-service" --service-name secure-fastapi-service
source_revision="$(jq -er '.build.source_revision' "$metadata")"
build_timestamp="$(jq -er '.build.timestamp' "$metadata")"
source_date_epoch="$(git show -s --format=%ct "$source_revision")"
docker buildx build --provenance=false --sbom=false \
  --tag "$trusted_repository:0.1.0-local" \
  --output "type=oci,dest=$runtime_directory/rebuilt-image.oci.tar" \
  --build-arg "SOURCE_DATE_EPOCH=$source_date_epoch" \
  --label "org.opencontainers.image.created=$build_timestamp" \
  --label "org.opencontainers.image.revision=$source_revision" \
  "$runtime_directory/rendered-service" >/dev/null
rebuilt_digest="$(tar -xOf "$runtime_directory/rebuilt-image.oci.tar" index.json |
  jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI manifest") end')"
[[ "$rebuilt_digest" == "$trusted_digest" ]] ||
  fail "rebuilt image digest $rebuilt_digest does not match trusted digest $trusted_digest"

log 'creating temporary local Git remote from the current committed revision'
git clone --no-local "$repository_root" "$runtime_directory/work" >/dev/null 2>&1
git -C "$runtime_directory/work" config user.name 'ForgePath Runtime Validator'
git -C "$runtime_directory/work" config user.email 'runtime-validator@forgepath.invalid'
git clone --bare "$runtime_directory/work" "$runtime_directory/git/forgepath.git" >/dev/null 2>&1
git -C "$runtime_directory/work" remote set-url origin "$runtime_directory/git/forgepath.git"
git --git-dir="$runtime_directory/git/forgepath.git" symbolic-ref HEAD refs/heads/main
git --git-dir="$runtime_directory/git/forgepath.git" update-server-info
initial_revision="$(git -C "$runtime_directory/work" rev-parse HEAD)"

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

log "creating Kind $kind_version cluster $cluster_name with $kind_node_image"
kind create cluster --name "$cluster_name" --image "$kind_node_image" \
  --config "$runtime_directory/kind.yaml" --wait 180s
cluster_created=true
require_target_context

observed_server="$(kube version -o json | jq -r '.serverVersion.gitVersion')"
[[ "$observed_server" == "$kubernetes_version" ]] ||
  fail "expected Kubernetes $kubernetes_version, observed $observed_server"

log 'loading the trusted OCI archive without a remote registry'
kind load image-archive "$artifact_directory/image.oci.tar" --name "$cluster_name"
# Kind imports the archive's tag, while the workload intentionally requests the
# digest-qualified name. Add that local alias so containerd never resolves it
# against a registry; both names point at the already-verified manifest digest.
docker exec "${cluster_name}-control-plane" ctr --namespace k8s.io images tag \
  "docker.io/$trusted_repository:0.1.0-local" \
  "docker.io/$trusted_repository@$trusted_digest" >/dev/null
kube -n kube-system get pods >/dev/null

manifest="$runtime_directory/argocd-install.yaml"
pinned_manifest="$runtime_directory/argocd-install-pinned.yaml"
log "downloading reviewed Argo CD $argocd_version installation manifest"
curl -fsSLo "$manifest" "$argocd_manifest_url"
[[ "$(sha256_file "$manifest")" == "$argocd_manifest_sha256" ]] ||
  fail 'Argo CD installation manifest checksum mismatch'
sed \
  -e "s#quay.io/argoproj/argocd:$argocd_version#$argocd_image#g" \
  -e "s#ghcr.io/dexidp/dex:v2.43.0#$dex_image#g" \
  -e "s#public.ecr.aws/docker/library/redis:8.2.3-alpine#$redis_image#g" \
  "$manifest" >"$pinned_manifest"
installation_images="$(yq -r -N '.. | select(has("image")) | .image' "$pinned_manifest" | sort -u)"
[[ "$(wc -l <<<"$installation_images" | tr -d ' ')" == '3' ]] ||
  fail 'unexpected Argo CD installation image set'
while IFS= read -r image; do
  [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || fail "installation image is not immutable: $image"
done <<<"$installation_images"

require_target_context
kube create namespace "$argocd_namespace" >/dev/null
kube create namespace "$workload_namespace" >/dev/null
log 'installing Argo CD from the verified local manifest'
kube -n "$argocd_namespace" apply --server-side --force-conflicts -f "$pinned_manifest" >/dev/null
kube -n "$argocd_namespace" wait --for=condition=Available deployment --all --timeout=300s >/dev/null

log 'adding a read-only local Git daemon sidecar to Argo CD repo-server'
cat >"$runtime_directory/repo-server-patch.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: runtime-git-daemon
          image: $argocd_image
          imagePullPolicy: IfNotPresent
          command: [git, daemon]
          args:
            - --export-all
            - --base-path=/runtime-git
            - --reuseaddr
            - --listen=0.0.0.0
            - --port=9418
            - /runtime-git
          ports:
            - name: runtime-git
              containerPort: 9418
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: runtime-git
              mountPath: /runtime-git
              readOnly: true
      volumes:
        - name: runtime-git
          hostPath:
            path: /forgepath-runtime-git
            type: Directory
EOF
kube -n "$argocd_namespace" patch deployment argocd-repo-server \
  --type strategic --patch-file "$runtime_directory/repo-server-patch.yaml" >/dev/null
kube -n "$argocd_namespace" rollout status deployment/argocd-repo-server --timeout=300s >/dev/null

runtime_project="$runtime_directory/project.yaml"
runtime_application="$runtime_directory/application.yaml"
RUNTIME_REPO_URL="$runtime_repo_url" yq \
  '.spec.sourceRepos = [strenv(RUNTIME_REPO_URL)]' \
  gitops/projects/forgepath-local.yaml >"$runtime_project"
RUNTIME_REPO_URL="$runtime_repo_url" yq \
  '.spec.source.repoURL = strenv(RUNTIME_REPO_URL)' \
  gitops/applications/secure-fastapi-service-local.yaml >"$runtime_application"

require_target_context
kube apply -f "$runtime_project" >/dev/null
kube apply -f "$runtime_application" >/dev/null
wait_for_application "$initial_revision" 360
wait_for_replicas 1

application_state="$(kube -n "$argocd_namespace" get application "$application_name" -o json)"
[[ "$(jq -r '.status.sourceType' <<<"$application_state")" == 'Helm' ]] ||
  fail 'Argo CD did not resolve the Helm source'

deployment='secure-fastapi-service-secure-fastapi-service'
for kind_and_name in \
  "deployment/$deployment" \
  "service/$deployment" \
  "serviceaccount/$deployment" \
  "networkpolicy/${deployment}-default-deny"; do
  kube -n "$workload_namespace" get "$kind_and_name" >/dev/null
done
pod="$(kube -n "$workload_namespace" get pod \
  -l app.kubernetes.io/name=secure-fastapi-service \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$pod" ]] || fail 'Argo CD did not create an application Pod'

running_reference="$(kube -n "$workload_namespace" get deployment "$deployment" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$running_reference" == "$trusted_reference" ]] ||
  fail "Deployment image $running_reference does not match $trusted_reference"
runtime_image_id="$(kube -n "$workload_namespace" get pod "$pod" \
  -o jsonpath='{.status.containerStatuses[0].imageID}')"
[[ "$runtime_image_id" == *"@$trusted_digest" ]] ||
  fail "runtime image ID $runtime_image_id does not contain trusted digest $trusted_digest"

pod_ready="$(kube -n "$workload_namespace" get pod "$pod" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
restart_count="$(kube -n "$workload_namespace" get pod "$pod" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
[[ "$pod_ready" == 'True' && "$restart_count" == '0' ]] ||
  fail 'readiness/liveness state is not healthy'
for endpoint in health/live health/ready; do
  response="$(kube -n "$workload_namespace" exec "$pod" -- python -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/$endpoint').read().decode())")"
  [[ "$response" == *'status'* ]] || fail "$endpoint endpoint failed"
done
metrics="$(kube -n "$workload_namespace" exec "$pod" -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/metrics').read().decode())")"
grep -Fq 'http_requests_total' <<<"$metrics" || fail 'metrics endpoint did not return Prometheus metrics'

tracking="$(kube -n "$workload_namespace" get deployment "$deployment" -o json | jq -r '[
  .metadata.labels["app.kubernetes.io/instance"],
  .metadata.labels["argocd.argoproj.io/instance"],
  .metadata.annotations["argocd.argoproj.io/tracking-id"]
] | map(select(. != null)) | join(" ")')"
[[ "$tracking" == *"$application_name"* ]] || fail 'Argo CD tracking metadata is absent'

[[ -z "$(helm --kube-context "$kind_context" list --all-namespaces --output json | jq -r '.[]?.name')" ]] ||
  fail 'a Helm release unexpectedly owns runtime resources'
[[ -z "$(kube get secret,configmap --all-namespaces -l owner=helm -o name)" ]] ||
  fail 'Helm release ownership objects unexpectedly exist'

log 'testing self-heal after safe direct replica drift'
require_target_context
kube -n "$workload_namespace" scale deployment "$deployment" --replicas=2 >/dev/null
wait_for_replicas 1

log 'testing reconciliation to a new local Git revision'
yq -i '.replicaCount = 2' \
  "$runtime_directory/work/gitops/environments/local/secure-fastapi-service/values.yaml"
replica_revision="$(commit_runtime_change 'test: set runtime replicas to two')"
refresh_application
wait_for_application "$replica_revision" 300
wait_for_replicas 2

log 'testing Git-managed creation and pruning'
prune_template="$runtime_directory/work/services/secure-fastapi-service/chart/templates/runtime-prune-probe.yaml"
cat >"$prune_template" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: forgepath-runtime-prune-probe
automountServiceAccountToken: false
EOF
create_revision="$(commit_runtime_change 'test: add safe runtime prune probe')"
refresh_application
wait_for_application "$create_revision" 300
kube -n "$workload_namespace" wait --for=jsonpath='{.metadata.name}'=forgepath-runtime-prune-probe \
  serviceaccount/forgepath-runtime-prune-probe --timeout=120s >/dev/null
rm -f "$prune_template"
prune_revision="$(commit_runtime_change 'test: remove safe runtime prune probe')"
refresh_application
wait_for_application "$prune_revision" 300
if kube -n "$workload_namespace" get serviceaccount forgepath-runtime-prune-probe >/dev/null 2>&1; then
  fail 'Argo CD did not prune the removed Git resource'
fi

log 'preparing safe Git fixtures for runtime containment tests'
mkdir -p "$runtime_directory/work/runtime-containment/secret"
mkdir -p "$runtime_directory/work/runtime-containment/cluster"
cat >"$runtime_directory/work/runtime-containment/secret/secret.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: forgepath-runtime-forbidden-secret
type: Opaque
stringData:
  synthetic: non-sensitive-fixture
EOF
cat >"$runtime_directory/work/runtime-containment/cluster/clusterrole.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: forgepath-runtime-forbidden-clusterrole
rules: []
EOF
containment_revision="$(commit_runtime_change 'test: add runtime containment fixtures')"

create_containment_application() {
  local name="$1"
  local repo="$2"
  local namespace="$3"
  local path="$4"
  NAME="$name" REPO="$repo" NAMESPACE="$namespace" PATH_VALUE="$path" \
    REVISION="$containment_revision" yq -n '
      .apiVersion = "argoproj.io/v1alpha1" |
      .kind = "Application" |
      .metadata.name = strenv(NAME) |
      .metadata.namespace = "argocd" |
      .spec.project = "forgepath-local" |
      .spec.source.repoURL = strenv(REPO) |
      .spec.source.targetRevision = strenv(REVISION) |
      .spec.source.path = strenv(PATH_VALUE) |
      .spec.destination.server = "https://kubernetes.default.svc" |
      .spec.destination.namespace = strenv(NAMESPACE) |
      .spec.syncPolicy.automated.prune = true |
      .spec.syncPolicy.automated.selfHeal = true
    ' | kube apply -f - >/dev/null
}

require_target_context
create_containment_application containment-unauthorized-source \
  'https://example.invalid/unauthorized.git' "$workload_namespace" \
  'runtime-containment/secret'
wait_for_rejection containment-unauthorized-source 'not permitted|not allowed' >/dev/null

create_containment_application containment-unauthorized-destination \
  "$runtime_repo_url" 'forgepath-runtime-unauthorized' 'runtime-containment/secret'
wait_for_rejection containment-unauthorized-destination \
  'not permitted|not allowed|do not match.*allowed destinations' >/dev/null

create_containment_application containment-secret "$runtime_repo_url" \
  "$workload_namespace" 'runtime-containment/secret'
wait_for_rejection containment-secret 'Secret.*not permitted|not permitted.*Secret' >/dev/null
if kube -n "$workload_namespace" get secret forgepath-runtime-forbidden-secret >/dev/null 2>&1; then
  fail 'AppProject allowed the forbidden Secret'
fi

create_containment_application containment-cluster-resource "$runtime_repo_url" \
  "$workload_namespace" 'runtime-containment/cluster'
wait_for_rejection containment-cluster-resource 'ClusterRole.*not permitted|not permitted.*ClusterRole' >/dev/null
if kube get clusterrole forgepath-runtime-forbidden-clusterrole >/dev/null 2>&1; then
  fail 'AppProject allowed the forbidden cluster-scoped resource'
fi

kube -n "$argocd_namespace" delete application \
  containment-unauthorized-source containment-unauthorized-destination \
  containment-secret containment-cluster-resource --wait=true >/dev/null

log 'installing the dedicated Backstage read-only runtime identity'
require_target_context
kube create namespace "$visibility_namespace" >/dev/null
cat <<EOF | kube apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $visibility_service_account
  namespace: $visibility_namespace
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backstage-workload-reader
  namespace: $workload_namespace
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backstage-workload-reader
  namespace: $workload_namespace
subjects:
  - kind: ServiceAccount
    name: $visibility_service_account
    namespace: $visibility_namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: backstage-workload-reader
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backstage-application-reader
  namespace: $argocd_namespace
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backstage-application-reader
  namespace: $argocd_namespace
subjects:
  - kind: ServiceAccount
    name: $visibility_service_account
    namespace: $visibility_namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: backstage-application-reader
EOF

readonly_subject="system:serviceaccount:$visibility_namespace:$visibility_service_account"
for verb in get list watch; do
  assert_subject_access yes "$verb" deployments "$workload_namespace" "$readonly_subject"
  assert_subject_access yes "$verb" pods "$workload_namespace" "$readonly_subject"
  assert_subject_access yes "$verb" applications.argoproj.io "$argocd_namespace" "$readonly_subject"
done
for denied_access in \
  'get secrets' \
  'list secrets' \
  'watch secrets' \
  'delete pods' \
  'create pods/exec' \
  'create deployments' \
  'update deployments' \
  'patch deployments' \
  'delete deployments' \
  'create serviceaccounts/token' \
  'update applications.argoproj.io' \
  'patch applications.argoproj.io'; do
  read -r verb resource <<<"$denied_access"
  case "$resource" in
    applications.argoproj.io)
      denied_namespace="$argocd_namespace"
      ;;
    *)
      denied_namespace="$workload_namespace"
      ;;
  esac
  assert_subject_access no "$verb" "$resource" "$denied_namespace" "$readonly_subject"
done

log 'starting a loopback-only kubectl proxy that always impersonates the read-only identity'
kube --as "$readonly_subject" proxy --address=127.0.0.1 --port=8001 \
  --accept-hosts='^localhost$,^127\.0\.0\.1$' \
  >"$runtime_directory/kubectl-proxy.log" 2>&1 &
proxy_pid=$!
wait_for_http_process "$proxy_pid" 'http://localhost:8001/version' 'kubectl-proxy'

proxy_deployment_status="$(curl -sS -o "$runtime_directory/proxy-deployment.json" \
  -w '%{http_code}' \
  "http://localhost:8001/apis/apps/v1/namespaces/$workload_namespace/deployments/$deployment")"
[[ "$proxy_deployment_status" == '200' ]] ||
  fail "read-only proxy could not get the demo Deployment: HTTP $proxy_deployment_status"
proxy_secret_status="$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://localhost:8001/api/v1/namespaces/$workload_namespace/secrets")"
[[ "$proxy_secret_status" == '403' ]] ||
  fail "read-only proxy did not deny Secret access: HTTP $proxy_secret_status"
proxy_delete_status="$(curl -sS -X DELETE -o /dev/null -w '%{http_code}' \
  "http://localhost:8001/api/v1/namespaces/$workload_namespace/pods/$pod")"
[[ "$proxy_delete_status" == '403' ]] ||
  fail "read-only proxy did not deny Pod deletion: HTTP $proxy_delete_status"

log 'starting the Backstage backend and proving Catalog, TechDocs, workload, and Argo CD visibility'
cat >"$runtime_directory/backstage-runtime.yaml" <<EOF
app:
  baseUrl: http://localhost:$backstage_frontend_port
backend:
  baseUrl: http://localhost:$backstage_runtime_port
  listen:
    host: 127.0.0.1
    port: $backstage_runtime_port
  cors:
    origin: http://localhost:$backstage_frontend_port
EOF
(
  cd "$repository_root/platform/backstage"
  exec env NODE_ENV=development corepack yarn start \
    --config "$repository_root/platform/backstage/app-config.yaml" \
    --config "$runtime_directory/backstage-runtime.yaml"
) >"$runtime_directory/backstage.log" 2>&1 &
backstage_pid=$!
backstage_url="http://localhost:$backstage_runtime_port"
wait_for_http_process "$backstage_pid" \
  "$backstage_url/api/auth/guest/refresh" 'backstage'

auth_response="$(curl -fsS "$backstage_url/api/auth/guest/refresh")"
backstage_token="$(jq -er '.backstageIdentity.token' <<<"$auth_response")"
auth_header="Authorization: Bearer $backstage_token"

catalog_deadline=$((SECONDS + 120))
catalog_entity=''
argo_catalog_entity=''
while ((SECONDS < catalog_deadline)); do
  catalog_entity="$(curl -fsS -H "$auth_header" \
    "$backstage_url/api/catalog/entities/by-name/component/default/secure-fastapi-service" \
    2>/dev/null || true)"
  argo_catalog_entity="$(curl -fsS -H "$auth_header" \
    "$backstage_url/api/catalog/entities/by-name/resource/default/secure-fastapi-service-argocd" \
    2>/dev/null || true)"
  if [[ -n "$catalog_entity" && -n "$argo_catalog_entity" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$catalog_entity" || -z "$argo_catalog_entity" ]]; then
  sed -n '1,240p' "$runtime_directory/backstage.log" >&2
  fail 'Backstage catalog entities were not ingested'
fi
if ! jq -e '
  .metadata.annotations."backstage.io/techdocs-ref" ==
    "dir:." and
  any(.relations[]?; .type == "dependsOn" and
    .targetRef == "resource:default/secure-fastapi-service-argocd")
' <<<"$catalog_entity" >/dev/null; then
  jq -c . <<<"$catalog_entity" >&2
  fail 'Backstage Component catalog contract did not match'
fi

techdocs_response_file="$runtime_directory/backstage-techdocs.json"
techdocs_status="$(curl -sS -o "$techdocs_response_file" -w '%{http_code}' \
  -H "$auth_header" \
  "$backstage_url/api/techdocs/metadata/entity/default/component/secure-fastapi-service")"
if [[ "$techdocs_status" != '200' ]]; then
  jq -c . "$techdocs_response_file" >&2 2>/dev/null ||
    sed -n '1,120p' "$techdocs_response_file" >&2
  sed -n '1,240p' "$runtime_directory/backstage.log" >&2
  fail "Backstage TechDocs metadata returned HTTP $techdocs_status"
fi
techdocs_entity="$(<"$techdocs_response_file")"
if ! jq -e '
  .metadata.name == "secure-fastapi-service" and
  .metadata.annotations."backstage.io/techdocs-ref" ==
    "dir:."
' <<<"$techdocs_entity" >/dev/null; then
  jq -c . <<<"$techdocs_entity" >&2
  fail 'Backstage TechDocs metadata contract did not match'
fi

workload_response_file="$runtime_directory/backstage-workloads.json"
workload_status="$(curl -sS -o "$workload_response_file" -w '%{http_code}' \
  -H "$auth_header" \
  -H 'Content-Type: application/json' \
  -d '{"entityRef":"component:default/secure-fastapi-service","auth":{}}' \
  "$backstage_url/api/kubernetes/resources/workloads/query")"
if [[ "$workload_status" != '200' ]]; then
  jq -c . "$workload_response_file" >&2 2>/dev/null ||
    sed -n '1,120p' "$workload_response_file" >&2
  sed -n '1,240p' "$runtime_directory/backstage.log" >&2
  fail "Backstage workload query returned HTTP $workload_status"
fi
workload_response="$(<"$workload_response_file")"
if ! jq -e --arg deployment "$deployment" '
  (.items | length) == 1 and
  (.items[0].errors | length) == 1 and
  any(.items[0].errors[]?;
    .statusCode == 403 and
    .resourcePath ==
      "/apis/argoproj.io/v1alpha1/namespaces/secure-fastapi-service-local/applications") and
  any(.items[0].resources[]?;
    .type == "deployments" and
    any(.resources[]?; .metadata.name == $deployment and
      .status.availableReplicas >= 1)) and
  any(.items[0].resources[]?;
    .type == "pods" and
    any(.resources[]?; any(.status.conditions[]?;
      .type == "Ready" and .status == "True")))
' <<<"$workload_response" >/dev/null; then
  jq -c . <<<"$workload_response" >&2
  fail 'Backstage workload response did not contain the ready demo workload'
fi

application_response_file="$runtime_directory/backstage-applications.json"
application_status="$(curl -sS -o "$application_response_file" -w '%{http_code}' \
  -H "$auth_header" \
  -H 'Content-Type: application/json' \
  -d '{"entityRef":"resource:default/secure-fastapi-service-argocd","auth":{},"customResources":[{"group":"argoproj.io","apiVersion":"v1alpha1","plural":"applications"}]}' \
  "$backstage_url/api/kubernetes/resources/custom/query")"
if [[ "$application_status" != '200' ]]; then
  jq -c . "$application_response_file" >&2 2>/dev/null ||
    sed -n '1,120p' "$application_response_file" >&2
  sed -n '1,240p' "$runtime_directory/backstage.log" >&2
  fail "Backstage Argo CD Application query returned HTTP $application_status"
fi
application_response="$(<"$application_response_file")"
if ! jq -e --arg application "$application_name" '
  (.items | length) == 1 and
  (.items[0].errors | length) == 0 and
  any(.items[0].resources[]?;
    .type == "customresources" and
    any(.resources[]?; .metadata.name == $application and
      .status.sync.status == "Synced" and
      .status.health.status == "Healthy"))
' <<<"$application_response" >/dev/null; then
  jq -c . <<<"$application_response" >&2
  fail 'Backstage Application response did not contain Synced and Healthy status'
fi

backstage_proxy_status="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "$auth_header" -H 'Backstage-Kubernetes-Cluster: local' \
  "$backstage_url/api/kubernetes/proxy/api/v1/namespaces")"
[[ "$backstage_proxy_status" == '403' ]] ||
  fail "Backstage kubernetes.proxy permission was not denied: HTTP $backstage_proxy_status"

if [[ -n "${FORGEPATH_SCREENSHOT_HOLD_FILE:-}" ]]; then
  [[ "$FORGEPATH_SCREENSHOT_HOLD_FILE" == /private/tmp/forgepath-screenshot-* ]] ||
    fail 'screenshot hold file must be beneath /private/tmp with the forgepath-screenshot- prefix'
  log "screenshot capture ready: http://localhost:$backstage_frontend_port"
  screenshot_deadline=$((SECONDS + 600))
  while [[ ! -e "$FORGEPATH_SCREENSHOT_HOLD_FILE" ]]; do
    ((SECONDS < screenshot_deadline)) || fail 'timed out waiting for screenshot capture'
    sleep 2
  done
fi

log "PASS source resolution: Helm at $initial_revision"
log 'PASS initial state: Synced, Healthy, Deployment, Pod, Service, ServiceAccount, NetworkPolicy'
log "PASS trusted runtime image: $trusted_reference"
log 'PASS readiness, liveness, metrics, Argo CD tracking, and no Helm release ownership'
log "PASS reconciliation: self-heal; Git replicas at $replica_revision; create $create_revision; prune $prune_revision"
log 'PASS containment: unauthorized repository, destination namespace, Secret, and ClusterRole rejected'
log 'PASS Backstage catalog and TechDocs metadata: secure-fastapi-service'
log 'PASS Backstage workload visibility: Deployment and ready Pod'
log 'PASS Backstage Argo CD visibility: Application Synced and Healthy'
log 'PASS read-only identity: get/list/watch only; Secrets, delete, exec, mutation, sync, and credentials denied'
log "VERSIONS Kind $kind_version; Kubernetes $observed_server; Argo CD $argocd_version"

exit 0
