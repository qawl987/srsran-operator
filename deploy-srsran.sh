#!/bin/bash
# srsRAN gNB Nephio Deployment Script
#
# Deploys the srsran-operator and gNB blueprint to a single workload cluster
# (regional, labeled nephio.org/site-type=combined) via the Nephio Porch pipeline.
#
# Architecture:
#   Management cluster  ── Porch ──> PackageVariant ──> regional repo
#                                        │
#                        Kptfile pipeline (interface-fn + nfdeploy-fn)
#                                        │
#   Regional cluster  <── ConfigSync ──> CU-CP / CU-UP / DU pods
#
# Prerequisites:
#   - Nephio management cluster running; kubectl context points to it.
#   - porchctl v0.0.2+ authenticated to management cluster.
#   - regional.kubeconfig exists for the workload cluster.
#   - Free5GC core (AMF, SMF, UPF) already deployed on the same node.
#   - Go (≥1.22) + Docker accessible for operator image build.
#
# Usage:
#   ./deploy-srsran.sh
#   CLUSTER_NAME=edge1 WORKER_NODE=edge1-control-plane ./deploy-srsran.sh

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-regional}"
WORKER_NODE="${WORKER_NODE:-regional-md-0-n5x7s-qqwrs-q8zwx}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-/home/free5gc/regional.kubeconfig}"

# Gitea / Porch repository settings
GITEA_URL="${GITEA_URL:-http://172.18.0.200:3000}"
GITEA_ORG="${GITEA_ORG:-nephio}"
GITEA_USER="${GITEA_USER:-nephio}"
GITEA_PASS="${GITEA_PASS:-secret}"
CATALOG_REPO="${CATALOG_REPO:-catalog-workloads-srsran}"   # upstream blueprint repo name
CATALOG_PKG="${CATALOG_PKG:-pkg-srsran}"                   # package sub-directory inside repo (matches existing Gitea repo)
DOWNSTREAM_PKG="${DOWNSTREAM_PKG:-srsran-gnb}"             # name in the cluster's git repo
SITE_TYPE="${SITE_TYPE:-combined}"                          # WorkloadCluster label value for target selection

# Operator image
IMG="${IMG:-docker.io/nephio/srsran-operator:latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="${SCRIPT_DIR}/blueprint"
OPERATOR_NS="${OPERATOR_NS:-srsran}"

# Network prefixes for IPAM
N2_PREFIX="172.2.0.0/24"
N3_PREFIX="172.3.0.0/24"
E1_PREFIX="172.4.0.0/24"
F1C_PREFIX="172.5.0.0/24"
F1U_PREFIX="172.6.0.0/24"

echo ""
echo "══════════════════════════════════════════"
echo "  srsRAN Nephio Deployment Script"
echo "══════════════════════════════════════════"
info "Cluster      : ${CLUSTER_NAME}"
info "Worker Node  : ${WORKER_NODE}"
info "Kubeconfig   : ${KUBECONFIG_FILE}"
info "Site type    : ${SITE_TYPE}  (PackageVariantSet target label)"
info "Catalog repo : ${CATALOG_REPO}/${CATALOG_PKG}"
info "Operator img : ${IMG}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
WKCTL="kubectl --kubeconfig=${KUBECONFIG_FILE}"   # targets workload cluster

wait_for_packagerevision_published() {
    local rev_name="$1"
    local timeout="${2:-300}"
    info "Waiting up to ${timeout}s for PackageRevision ${rev_name} to be Published..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local lifecycle
        lifecycle=$(kubectl get packagerevision -n default "${rev_name}" \
            -o jsonpath='{.spec.lifecycle}' 2>/dev/null || true)
        if [[ "${lifecycle}" == "Published" ]]; then
            ok "PackageRevision ${rev_name} is Published"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    warn "PackageRevision ${rev_name} not Published after ${timeout}s"
    return 1
}

# ── Step 0: Pre-flight checks ─────────────────────────────────────────────────
echo ""
echo "=== Step 0: Pre-flight checks ==="

command -v kubectl  >/dev/null || die "kubectl not found"
command -v porchctl >/dev/null || die "porchctl not found"
command -v docker   >/dev/null || warn "docker not found – operator image build will be skipped"
command -v git      >/dev/null || die "git not found"
command -v curl     >/dev/null || die "curl not found"

[[ -f "${KUBECONFIG_FILE}" ]] \
    || die "Kubeconfig not found: ${KUBECONFIG_FILE}"

# Verify workload cluster is reachable
${WKCTL} cluster-info --request-timeout=10s &>/dev/null \
    || die "Cannot reach workload cluster via ${KUBECONFIG_FILE}"

ok "Pre-flight checks passed"

# ── Step 1: Label WorkloadCluster ─────────────────────────────────────────────
echo ""
echo "=== Step 1: Ensure WorkloadCluster label ==="
if kubectl get workloadcluster "${CLUSTER_NAME}" -n default &>/dev/null; then
    kubectl label workloadcluster "${CLUSTER_NAME}" \
        nephio.org/site-type=combined \
        --overwrite -n default
    ok "WorkloadCluster '${CLUSTER_NAME}' labeled site-type=combined"
else
    warn "WorkloadCluster '${CLUSTER_NAME}' not found in management cluster."
    warn "If you haven't created it yet, run:"
    warn "  kubectl label workloadcluster ${CLUSTER_NAME} nephio.org/site-type=combined --overwrite -n default"
fi

# ── Step 2: VLAN interfaces on worker node ────────────────────────────────────
echo ""
echo "=== Step 2: Create VLAN interfaces on worker node ==="
info "Creating dummy eth1 + VLANs 2–6 (N2/N3/E1/F1C/F1U) on ${WORKER_NODE}"

sudo docker exec "${WORKER_NODE}" \
    ip link add eth1 type dummy 2>/dev/null || info "eth1 already exists"
sudo docker exec "${WORKER_NODE}" ip link set eth1 up

declare -A VLAN_MAP=([2]="n2" [3]="n3" [4]="e1" [5]="f1c" [6]="f1u")
for vlan_id in 2 3 4 5 6; do
    iface="eth1.${vlan_id}"
    sudo docker exec "${WORKER_NODE}" \
        ip link add link eth1 name "${iface}" type vlan id "${vlan_id}" 2>/dev/null \
        || info "  ${iface} already exists"
    sudo docker exec "${WORKER_NODE}" ip link set up "${iface}"
    info "  ${iface} (${VLAN_MAP[$vlan_id]}) ready"
done

ok "VLAN interfaces ready"
sudo docker exec "${WORKER_NODE}" ip link show | grep -E "eth1[.:]" || true

# ── Step 3: Deploy / verify network package (NetworkInstances) ────────────────
echo ""
echo "=== Step 3: Verify NetworkInstances ==="
NETWORK_YAML="${NETWORK_YAML:-/home/free5gc/test-infra/e2e/tests/free5gc/002-network.yaml}"

if kubectl get packagevariant network -n default &>/dev/null; then
    info "PackageVariant/network already exists – skipping deploy"
elif [[ -f "${NETWORK_YAML}" ]]; then
    info "Deploying network PackageVariant from ${NETWORK_YAML}"
    BRANCH=main envsubst < "${NETWORK_YAML}" | kubectl apply -f -
    info "Waiting up to 3 min for network PackageVariant to become Ready..."
    kubectl wait --for=condition=Ready packagevariant/network \
        --timeout=180s 2>/dev/null \
        || warn "network PackageVariant not Ready yet – continuing"
    info "Waiting 20s for NetworkInstances to be created..."
    sleep 20
    ok "Network package deployed"
else
    warn "${NETWORK_YAML} not found. Assuming NetworkInstances (vpc-ran, vpc-internal) already exist."
fi

# ── Step 4: Patch NetworkInstance IPAM prefixes ───────────────────────────────
echo ""
echo "=== Step 4: Patch NetworkInstance IPAM prefixes for srsRAN ==="
info "N2=${N2_PREFIX}  N3=${N3_PREFIX}  E1=${E1_PREFIX}  F1C=${F1C_PREFIX}  F1U=${F1U_PREFIX}"

sleep 3  # Give NIs a moment

# vpc-ran: N2 (NGAP→AMF) and N3 (GTP-U→UPF)
info "Patching vpc-ran with N2 and N3 prefixes..."
kubectl patch networkinstances.ipam.resource.nephio.org vpc-ran \
    --type=json -p="[
      {\"op\": \"add\", \"path\": \"/spec/prefixes/-\", \"value\": {
        \"prefix\": \"${N2_PREFIX}\",
        \"labels\": {
          \"nephio.org/network-name\":  \"n2\",
          \"nephio.org/address-family\": \"ipv4\",
          \"nephio.org/cluster-name\":  \"${CLUSTER_NAME}\"
        }
      }},
      {\"op\": \"add\", \"path\": \"/spec/prefixes/-\", \"value\": {
        \"prefix\": \"${N3_PREFIX}\",
        \"labels\": {
          \"nephio.org/network-name\":  \"n3\",
          \"nephio.org/address-family\": \"ipv4\",
          \"nephio.org/cluster-name\":  \"${CLUSTER_NAME}\"
        }
      }}
    ]" 2>/dev/null || warn "Could not patch vpc-ran (may already exist)"

# vpc-internal: E1, F1C, F1U (all intra-cluster inter-pod)
info "Patching vpc-internal with E1, F1C, F1U prefixes..."
kubectl patch networkinstances.ipam.resource.nephio.org vpc-internal \
    --type=json -p="[
      {\"op\": \"add\", \"path\": \"/spec/prefixes/-\", \"value\": {
        \"prefix\": \"${E1_PREFIX}\",
        \"labels\": {
          \"nephio.org/network-name\":  \"e1\",
          \"nephio.org/address-family\": \"ipv4\",
          \"nephio.org/cluster-name\":  \"${CLUSTER_NAME}\"
        }
      }},
      {\"op\": \"add\", \"path\": \"/spec/prefixes/-\", \"value\": {
        \"prefix\": \"${F1C_PREFIX}\",
        \"labels\": {
          \"nephio.org/network-name\":  \"f1c\",
          \"nephio.org/address-family\": \"ipv4\",
          \"nephio.org/cluster-name\":  \"${CLUSTER_NAME}\"
        }
      }},
      {\"op\": \"add\", \"path\": \"/spec/prefixes/-\", \"value\": {
        \"prefix\": \"${F1U_PREFIX}\",
        \"labels\": {
          \"nephio.org/network-name\":  \"f1u\",
          \"nephio.org/address-family\": \"ipv4\",
          \"nephio.org/cluster-name\":  \"${CLUSTER_NAME}\"
        }
      }}
    ]" 2>/dev/null || warn "Could not patch vpc-internal (may already exist)"

ok "NetworkInstance prefixes patched"
info "Waiting 15s for IPAM to process..."
sleep 15

# ── Step 5: Build & load srsran-operator image ────────────────────────────────
echo ""
echo "=== Step 5: Build srsran-operator image ==="

if ! command -v docker &>/dev/null; then
    warn "docker not available – skipping image build."
    warn "Ensure ${IMG} is already accessible in ${WORKER_NODE}."
else
    info "Building ${IMG} from ${SCRIPT_DIR}..."
    docker build -t "${IMG}" "${SCRIPT_DIR}" \
        || die "docker build failed"
    ok "Image built: ${IMG}"

    info "Loading image into kind cluster node ${WORKER_NODE}..."
    kind load docker-image "${IMG}" \
        --name "${CLUSTER_NAME}" 2>/dev/null \
        || {
            warn "kind load failed – trying docker save | docker exec..."
            docker save "${IMG}" \
                | sudo docker exec -i "${WORKER_NODE}" ctr images import - \
                || warn "Image load may have failed; continuing anyway"
        }
    ok "Image loaded into ${WORKER_NODE}"
fi

# ── Step 6: Generate CRDs and deploy operator to workload cluster ─────────────
echo ""
echo "=== Step 6: Deploy srsran-operator to workload cluster ==="

TMPMANIFEST="/tmp/srsran-operator-manifests"
mkdir -p "${TMPMANIFEST}"

# Generate CRDs using controller-gen (requires Go)
if command -v controller-gen &>/dev/null || go run sigs.k8s.io/controller-tools/cmd/controller-gen@latest --help &>/dev/null 2>&1; then
    info "Generating CRD manifests..."
    cd "${SCRIPT_DIR}"
    CONTROLLER_GEN="${CONTROLLER_GEN:-$(command -v controller-gen 2>/dev/null || echo "go run sigs.k8s.io/controller-tools/cmd/controller-gen@latest")}"
    ${CONTROLLER_GEN} crd \
        paths="./api/..." \
        output:crd:artifacts:config="${TMPMANIFEST}" 2>/dev/null \
        || warn "CRD generation failed – skipping CRD apply"
    cd - >/dev/null

    # Apply CRDs to workload cluster
    if ls "${TMPMANIFEST}"/*.yaml &>/dev/null; then
        ${WKCTL} apply -f "${TMPMANIFEST}/"
        ok "CRDs applied to workload cluster"
    fi
fi

# Create namespace on workload cluster
${WKCTL} create namespace "${OPERATOR_NS}" 2>/dev/null \
    || info "Namespace ${OPERATOR_NS} already exists"

# Generate RBAC and operator Deployment manifest inline
cat > "${TMPMANIFEST}/srsran-operator-deploy.yaml" <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: srsran-operator
  namespace: ${OPERATOR_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: srsran-operator
rules:
- apiGroups: ["workload.nephio.org"]
  resources: ["nfdeployments", "nfdeployments/status", "nfdeployments/finalizers", "nfconfigs"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: [""]
  resources: ["configmaps","serviceaccounts","services","pods","events"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["workload.nephio.org"]
  resources: ["srscellconfigs","plmnconfigs","srsranconfigs"]
  verbs: ["get","list","watch"]
- apiGroups: ["k8s.cni.cncf.io"]
  resources: ["network-attachment-definitions"]
  verbs: ["get","list","watch","create","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: srsran-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: srsran-operator
subjects:
- kind: ServiceAccount
  name: srsran-operator
  namespace: ${OPERATOR_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: srsran-operator
  namespace: ${OPERATOR_NS}
  labels:
    app: srsran-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: srsran-operator
  template:
    metadata:
      labels:
        app: srsran-operator
    spec:
      serviceAccountName: srsran-operator
      containers:
      - name: operator
        image: ${IMG}
        imagePullPolicy: IfNotPresent
        command: ["/manager"]
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
EOF

${WKCTL} apply -f "${TMPMANIFEST}/srsran-operator-deploy.yaml"
ok "srsran-operator deployed to workload cluster"

# Wait for operator to be ready
info "Waiting up to 2 min for srsran-operator to be Available..."
${WKCTL} wait deployment/srsran-operator \
    --namespace="${OPERATOR_NS}" \
    --for=condition=Available \
    --timeout=120s 2>/dev/null \
    || warn "Operator not yet Available – may still be pulling image"

# ── Step 7: Push blueprint to Gitea catalog repo ──────────────────────────────
echo ""
echo "=== Step 7: Register srsRAN blueprint in Porch ==="

# 7a. Create Gitea repo if missing
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${GITEA_ORG}/${CATALOG_REPO}")

if [[ "${HTTP_CODE}" == "200" ]]; then
    info "Gitea repo ${CATALOG_REPO} already exists"
else
    info "Creating Gitea repo ${CATALOG_REPO}..."
    CREATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${GITEA_URL}/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        -d "{\"name\":\"${CATALOG_REPO}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}")
    [[ "${CREATE_CODE}" == "201" ]] \
        || die "Failed to create Gitea repo (HTTP ${CREATE_CODE})"
    ok "Gitea repo created (HTTP ${CREATE_CODE})"
    sleep 3
fi

# 7b. Push blueprint files into pkg sub-directory
REPO_DIR="/tmp/srsran-catalog-push"
rm -rf "${REPO_DIR}"
git clone "http://${GITEA_USER}:${GITEA_PASS}@${GITEA_URL#http://}/${GITEA_ORG}/${CATALOG_REPO}.git" \
    "${REPO_DIR}" \
    || die "git clone failed for ${GITEA_URL}/${GITEA_ORG}/${CATALOG_REPO}.git"

mkdir -p "${REPO_DIR}/${CATALOG_PKG}"
cp -r "${BLUEPRINT_DIR}/." "${REPO_DIR}/${CATALOG_PKG}/"

pushd "${REPO_DIR}" >/dev/null
git config user.email "nephio@nephio.org"
git config user.name  "Nephio"
git add .
if git diff --cached --quiet; then
    info "Blueprint already up to date in ${CATALOG_REPO}/${CATALOG_PKG}"
else
    git commit -m "Add/update srsRAN gNB blueprint (${CATALOG_PKG})"
    git push origin main \
        || die "git push failed"
    ok "Blueprint pushed to ${CATALOG_REPO}/${CATALOG_PKG}"
fi
popd >/dev/null

# 7c. Register Porch Repository (catalog)
if kubectl get repository "${CATALOG_REPO}" -n default &>/dev/null; then
    info "Porch Repository ${CATALOG_REPO} already registered"
else
    info "Registering ${CATALOG_REPO} with Porch..."
    kubectl create secret generic srsran-catalog-creds \
        --from-literal=username="${GITEA_USER}" \
        --from-literal=password="${GITEA_PASS}" \
        --type=kubernetes.io/basic-auth \
        -n default 2>/dev/null \
        || info "(secret srsran-catalog-creds already exists)"

    cat > /tmp/srsran-porch-repo.yaml <<EOF
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: ${CATALOG_REPO}
  namespace: default
spec:
  content: Package
  deployment: false
  git:
    branch: main
    directory: /
    repo: ${GITEA_URL}/${GITEA_ORG}/${CATALOG_REPO}.git
    secretRef:
      name: srsran-catalog-creds
  type: git
EOF
    kubectl apply -f /tmp/srsran-porch-repo.yaml
    info "Waiting 20s for Porch to sync ${CATALOG_REPO}..."
    sleep 20
    ok "Porch Repository ${CATALOG_REPO} registered"
fi

# ── Step 8: Create PackageVariantSet to deploy blueprint to all matching clusters ─
echo ""
echo "=== Step 8: Create PackageVariantSet srsran-gnb (site-type=${SITE_TYPE}) ==="
# Uses PackageVariantSet (v1alpha2) so that every WorkloadCluster labeled
# nephio.org/site-type=<SITE_TYPE> automatically receives a rendered copy.
# Currently that is the single "${CLUSTER_NAME}" node; adding more nodes later
# requires only adding the label – no script changes needed.
#
# injectors.nameExpr: target.name  →  Porch substitutes the WorkloadCluster
# name at render time so the IPAM / interface-fn know which cluster to use.
cat > /tmp/srsran-packagevariantset.yaml <<EOF
apiVersion: config.porch.kpt.dev/v1alpha2
kind: PackageVariantSet
metadata:
  name: srsran-gnb
  namespace: default
spec:
  upstream:
    repo: ${CATALOG_REPO}
    package: ${CATALOG_PKG}
    workspaceName: main
  targets:
  - objectSelector:
      apiVersion: infra.nephio.org/v1alpha1
      kind: WorkloadCluster
      matchLabels:
        nephio.org/site-type: ${SITE_TYPE}
    template:
      downstream:
        package: ${DOWNSTREAM_PKG}
      annotations:
        approval.nephio.org/policy: always
      injectors:
      - nameExpr: target.name
EOF

kubectl apply -f /tmp/srsran-packagevariantset.yaml
ok "PackageVariantSet srsran-gnb applied (targets: site-type=${SITE_TYPE})"
info "Porch will create one PackageRevision per matching WorkloadCluster."

# ── Step 9: Propose + Approve PackageRevisions generated by the PVS ─────────────
# PackageVariantSet generates one PackageRevision per matching WorkloadCluster.
# With approval.nephio.org/policy: always the revision may go straight to
# Published; otherwise it sits in Draft and needs propose + approve.
echo ""
echo "=== Step 9: Propose and Approve PackageRevision(s) ==="
info "Waiting 30s for Porch to render the package(s) from PackageVariantSet..."
sleep 30

SRSRAN_REV=""
for attempt in 1 2 3 4 5; do
    # PVS-generated revisions are named: <cluster>.<downstream_pkg>.packagevariant-<n>
    SRSRAN_REV=$(porchctl rpkg get -n default 2>/dev/null \
        | grep "${CLUSTER_NAME}\.${DOWNSTREAM_PKG}\." \
        | grep -v "Published" \
        | awk '{print $1}' \
        | head -1)
    if [[ -n "${SRSRAN_REV}" ]]; then
        break
    fi
    info "Attempt ${attempt}/5: revision not found yet, waiting 15s..."
    sleep 15
done

if [[ -z "${SRSRAN_REV}" ]]; then
    warn "PackageRevision for ${DOWNSTREAM_PKG} not found after 5 attempts."
    warn "Check: porchctl rpkg get -n default | grep srsran"
    warn "Then manually: porchctl rpkg propose <rev> -n default"
    warn "               porchctl rpkg approve <rev> -n default"
else
    info "Found PackageRevision: ${SRSRAN_REV}"

    # Check if it needs proposing (Draft state)
    LIFECYCLE=$(kubectl get packagerevision -n default "${SRSRAN_REV}" \
        -o jsonpath='{.spec.lifecycle}' 2>/dev/null || echo "Unknown")
    info "Current lifecycle: ${LIFECYCLE}"

    if [[ "${LIFECYCLE}" == "Draft" ]]; then
        porchctl rpkg propose "${SRSRAN_REV}" -n default
        info "Proposed ${SRSRAN_REV}"
        # Wait for Proposed state
        kubectl wait --for=jsonpath='{.spec.lifecycle}'=Proposed \
            packagerevision "${SRSRAN_REV}" -n default \
            --timeout=60s 2>/dev/null || true
    fi

    if [[ "${LIFECYCLE}" != "Published" ]]; then
        porchctl rpkg approve "${SRSRAN_REV}" -n default
        ok "Approved: ${SRSRAN_REV}"
        wait_for_packagerevision_published "${SRSRAN_REV}" 120
    else
        ok "PackageRevision already Published: ${SRSRAN_REV}"
    fi
fi

# ── Step 10: Wait for srsRAN pods on workload cluster ────────────────────────
echo ""
echo "=== Step 10: Wait for srsRAN gNB pods ==="
info "Waiting for ConfigSync to apply the package (up to 3 min)..."
sleep 30

# The operator creates pods in a namespace matching the NFDeployment name
# Try common namespace patterns
SRSRAN_NS="srsran"
for ns_candidate in "srsran" "srsran-${CLUSTER_NAME}" "free5gc-srsran"; do
    if ${WKCTL} get namespace "${ns_candidate}" &>/dev/null; then
        SRSRAN_NS="${ns_candidate}"
        info "Using namespace: ${SRSRAN_NS}"
        break
    fi
done

for component in cucp cuup du; do
    DEP_PATTERN="${CLUSTER_NAME}-gnb-${component}"
    info "Checking for deployment matching '${DEP_PATTERN}' in ${SRSRAN_NS}..."
    ${WKCTL} wait deployment \
        --selector="app.kubernetes.io/component=${component}" \
        --namespace="${SRSRAN_NS}" \
        --for=condition=Available \
        --timeout=180s 2>/dev/null \
        || warn "  ${component} deployment not yet Available (check manually)"
done

# ── Step 11: Status summary ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  Deployment Summary"
echo "══════════════════════════════════════════"
echo ""

info "srsRAN pods (workload cluster):"
${WKCTL} get pods -A 2>/dev/null \
    | grep -iE "cucp|cuup|\bdu\b|gnb|srsran" \
    || echo "  (no srsRAN pods visible yet)"

echo ""
info "NFDeployments:"
${WKCTL} get nfdeployment -A 2>/dev/null \
    | grep -i gnb \
    || echo "  (none yet)"

echo ""
info "Services:"
${WKCTL} get svc -A 2>/dev/null \
    | grep -iE "cucp|cuup|\bdu\b|gnb|srsran" \
    || echo "  (none yet)"

echo ""
info "PackageRevision status:"
porchctl rpkg get -n default 2>/dev/null \
    | grep -i srsran \
    || echo "  (run: porchctl rpkg get -n default | grep srsran)"

echo ""
echo "══════════════════════════════════════════"
echo "  Troubleshooting"
echo "══════════════════════════════════════════"
echo ""
cat <<TIPS
Check workload cluster pods:
  kubectl --kubeconfig=${KUBECONFIG_FILE} get pods -A | grep -iE "cucp|cuup|du|srsran"

Check srsran-operator logs:
  kubectl --kubeconfig=${KUBECONFIG_FILE} logs -n ${OPERATOR_NS} deployment/srsran-operator --tail=80

Check NFDeployment (IPAM-injected IPs):
  kubectl --kubeconfig=${KUBECONFIG_FILE} get nfdeployment -A -o yaml | grep -A20 'interfaces:'

Inspect PackageVariantSet and generated PackageRevisions:
  kubectl get packagevariantset srsran-gnb -n default -o yaml
  porchctl rpkg get -n default | grep srsran
  porchctl rpkg pull -n default <rev> /tmp/srsran-inspect

Manually approve if auto-approval is off:
  porchctl rpkg propose <rev> -n default
  porchctl rpkg approve <rev> -n default

Add a new cluster to the gNB rollout (3-node setup):
  kubectl label workloadcluster <new-cluster> nephio.org/site-type=${SITE_TYPE} -n default
  # Porch will automatically generate + deploy a new PackageRevision for it

Restart operator:
  kubectl --kubeconfig=${KUBECONFIG_FILE} rollout restart deployment/srsran-operator -n ${OPERATOR_NS}

Re-run with different cluster:
  CLUSTER_NAME=edge1 WORKER_NODE=edge1-control-plane ${0}

Interface → IP prefix mapping:
  N2  (CU-CP NGAP→AMF)        ${N2_PREFIX}  vpc-ran
  N3  (CU-UP GTP-U→UPF)       ${N3_PREFIX}  vpc-ran
  E1  (CU-CP↔CU-UP E1AP)      ${E1_PREFIX}  vpc-internal
  F1C (CU-CP↔DU   F1-AP ctrl) ${F1C_PREFIX}  vpc-internal
  F1U (CU-UP↔DU   GTP-U data) ${F1U_PREFIX}  vpc-internal
TIPS

echo ""
echo "══════════════════════════════════════════"
