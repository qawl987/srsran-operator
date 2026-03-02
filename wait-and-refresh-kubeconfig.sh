#!/bin/bash
# wait-and-refresh-kubeconfig.sh
# Run ONCE after VM restart to fully recover the regional Kubernetes cluster.
#
# What this script fixes (in order):
#   1. Regenerates apiserver.crt (lost on container-fs reboot) with correct
#      SAN IPs including the load-balancer IP so the worker kubelet can
#      verify the apiserver TLS cert.
#   2. Fixes the worker node kubelet.conf server address if the LB container
#      IP changed between reboots.
#   3. Restarts the worker kubelet so it re-registers with the API server.
#   4. Restarts kube-proxy pod if iptables rules are empty (in-cluster
#      ClusterIP routing is broken without these rules).
#   5. Writes a corrected regional.kubeconfig from admin.conf.
#
# Usage:
#   bash /home/free5gc/wait-and-refresh-kubeconfig.sh [output_kubeconfig]
#   CLUSTER_NAME=regional bash wait-and-refresh-kubeconfig.sh

set -euo pipefail

KUBECONFIG_OUT="${1:-/home/free5gc/regional.kubeconfig}"
CLUSTER_NAME="${CLUSTER_NAME:-regional}"

# Helper: get primary IP of a docker container
container_ip() {
    sudo docker inspect "$1" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null \
        | tr ' ' '\n' | grep -v '^$' | head -1
}

# ── Step 1: wait for Docker to be up ─────────────────────────────────────────
echo "[INFO] Waiting for Docker daemon..."
until sudo docker info &>/dev/null; do
    echo "  docker not ready, retrying in 5s..."
    sleep 5
done
echo "[OK]  Docker is up"

# ── Step 2: discover cluster containers ──────────────────────────────────────
echo "[INFO] Discovering '${CLUSTER_NAME}' cluster containers..."
CP_CONTAINER=""
for i in $(seq 1 30); do
    CP_CONTAINER=$(sudo docker ps --format '{{.Names}}' \
        | grep -E "^${CLUSTER_NAME}-[a-z0-9]+-jb7nh$" \
        | head -1 || true)
    if [[ -z "${CP_CONTAINER}" ]]; then
        CP_CONTAINER=$(sudo docker ps --format '{{.Names}}' \
            | grep "${CLUSTER_NAME}" | grep -Ev -- "-lb$|-md-" | head -1 || true)
    fi
    [[ -n "${CP_CONTAINER}" ]] && break
    echo "  containers not ready (attempt ${i}/30), waiting 10s..."
    sleep 10
done

[[ -n "${CP_CONTAINER}" ]] || { echo "[ERROR] Cannot find control-plane container for '${CLUSTER_NAME}'"; exit 1; }

LB_CONTAINER=$(sudo docker ps --format '{{.Names}}' | grep "^${CLUSTER_NAME}-lb$" | head -1 || true)
WORKER_CONTAINER=$(sudo docker ps --format '{{.Names}}' \
    | grep "${CLUSTER_NAME}" | grep -- "-md-" | head -1 || true)

CP_IP=$(container_ip "${CP_CONTAINER}")
LB_IP=$([[ -n "${LB_CONTAINER}" ]] && container_ip "${LB_CONTAINER}" || echo "")
WORKER_IP=$([[ -n "${WORKER_CONTAINER}" ]] && container_ip "${WORKER_CONTAINER}" || echo "")

echo "[OK]  Control-plane : ${CP_CONTAINER}  IP=${CP_IP}"
[[ -n "${LB_CONTAINER}" ]]     && echo "[OK]  Load-balancer  : ${LB_CONTAINER}  IP=${LB_IP}"
[[ -n "${WORKER_CONTAINER}" ]] && echo "[OK]  Worker node    : ${WORKER_CONTAINER}  IP=${WORKER_IP}"

# ── Step 3: regenerate apiserver cert with LB IP in SAN ─────────────────────
# After reboot the container FS loses apiserver.crt/.key (they are not in a
# Docker volume).  We must also include the LB IP in the SAN list so that the
# worker kubelet (which connects via the LB) can verify the cert.
CERT_PATH="/etc/kubernetes/pki/apiserver.crt"
EXTRA_SANS="${CP_IP},127.0.0.1"
[[ -n "${LB_IP}" ]] && EXTRA_SANS="${LB_IP},${EXTRA_SANS}"

NEED_REGEN=0
if ! sudo docker exec "${CP_CONTAINER}" test -f "${CERT_PATH}" 2>/dev/null; then
    echo "[WARN] apiserver.crt missing – will regenerate"
    NEED_REGEN=1
elif [[ -n "${LB_IP}" ]]; then
    # Check if LB IP is already in the cert SAN
    CERT_SANS=$(sudo docker exec "${CP_CONTAINER}" \
        openssl x509 -in "${CERT_PATH}" -noout -text 2>/dev/null \
        | grep -A1 "Subject Alternative" || echo "")
    if ! echo "${CERT_SANS}" | grep -q "${LB_IP}"; then
        echo "[WARN] LB IP ${LB_IP} not in apiserver cert SAN – will regenerate"
        NEED_REGEN=1
    fi
fi

if [[ "${NEED_REGEN}" -eq 1 ]]; then
    sudo docker exec "${CP_CONTAINER}" \
        rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key 2>/dev/null || true
    sudo docker exec "${CP_CONTAINER}" \
        kubeadm init phase certs apiserver \
        --apiserver-cert-extra-sans="${EXTRA_SANS}" 2>&1 \
        | grep -E "Generating|signed for|Error|error" || true
    echo "[OK]  Certificates regenerated (SANs: ${EXTRA_SANS})"
    echo "[INFO] Waiting 30s for kubelet to detect new cert and restart apiserver..."
    sleep 30
else
    echo "[OK]  apiserver.crt present and LB IP covered"
fi

# ── Step 4: wait for the API server inside the container to be ready ──────────
echo "[INFO] Waiting for kube-apiserver to become ready (may take up to 3 min)..."
READY=0
for i in $(seq 1 36); do
    STATUS=$(sudo docker exec "${CP_CONTAINER}" crictl ps 2>/dev/null \
        | grep kube-apiserver | awk '{print $5}' | head -1)
    if [[ "${STATUS}" == "Running" ]]; then
        # Also check the API is actually answering
        if sudo docker exec "${CP_CONTAINER}" \
               kubectl --kubeconfig=/etc/kubernetes/admin.conf \
               cluster-info &>/dev/null 2>&1; then
            echo "[OK]  kube-apiserver is Running and answering (attempt ${i})"
            READY=1
            break
        fi
    fi
    echo "  apiserver status='${STATUS:-starting}' (attempt ${i}/36), waiting 5s..."
    sleep 5
done

if [[ "${READY}" -eq 0 ]]; then
    echo "[ERROR] kube-apiserver did not become ready after 3 minutes."
    echo "        Manual check: sudo docker exec ${CP_CONTAINER} crictl ps"
    exit 1
fi

# ── Step 5: write kubeconfig ─────────────────────────────────────────────────
echo "[INFO] Extracting admin.conf from ${CP_CONTAINER}..."
sudo docker exec "${CP_CONTAINER}" cat /etc/kubernetes/admin.conf \
    | sed "s|https://[^:]*:6443|https://${CP_IP}:6443|g" \
    > "${KUBECONFIG_OUT}"
chmod 600 "${KUBECONFIG_OUT}"
echo "[OK]  Kubeconfig written to: ${KUBECONFIG_OUT}  (server=${CP_IP}:6443)"

# ── Step 6: fix worker kubelet.conf if LB IP changed ─────────────────────────
# Worker kubelet connects to the API via the LB.  After reboot the LB container
# gets a new IP but kubelet.conf still holds the old one → TLS failures, node
# stays NotReady.
if [[ -n "${WORKER_CONTAINER}" && -n "${LB_IP}" ]]; then
    CURRENT_SERVER=$(sudo docker exec "${WORKER_CONTAINER}" \
        grep "server:" /etc/kubernetes/kubelet.conf 2>/dev/null \
        | awk '{print $2}' | head -1 || echo "")
    EXPECTED_SERVER="https://${LB_IP}:6443"
    if [[ "${CURRENT_SERVER}" != "${EXPECTED_SERVER}" ]]; then
        echo "[WARN] Worker kubelet.conf server=${CURRENT_SERVER}, expected ${EXPECTED_SERVER} – fixing..."
        sudo docker exec "${WORKER_CONTAINER}" \
            sed -i "s|https://[0-9.]*:6443|${EXPECTED_SERVER}|g" \
            /etc/kubernetes/kubelet.conf
        echo "[OK]  Worker kubelet.conf updated → ${EXPECTED_SERVER}"
        echo "[INFO] Restarting worker kubelet..."
        sudo docker exec "${WORKER_CONTAINER}" systemctl restart kubelet
        echo "[INFO] Waiting 30s for worker node to re-register..."
        sleep 30
    else
        echo "[OK]  Worker kubelet.conf server address is correct (${CURRENT_SERVER})"
    fi
else
    echo "[WARN] Worker container or LB IP not found – skipping kubelet.conf fix"
    echo "       If worker stays NotReady, check: sudo docker exec <worker> grep server: /etc/kubernetes/kubelet.conf"
fi

# ── Step 7: verify nodes ─────────────────────────────────────────────────────
echo ""
echo "[INFO] Node status:"
kubectl --kubeconfig="${KUBECONFIG_OUT}" get nodes -o wide 2>/dev/null \
    || echo "  (cluster not yet reachable – try again in 30s)"

# ── Step 8: fix kube-proxy if iptables rules are empty ───────────────────────
# kube-proxy repopulates iptables on startup, but sometimes needs a kick after
# reboot.  Without these rules, ClusterIP services (including the 'kubernetes'
# service used by all pods) are unreachable → operators crash-loop.
if [[ -n "${WORKER_CONTAINER}" ]]; then
    RULE_COUNT=$(sudo docker exec "${WORKER_CONTAINER}" \
        iptables -t nat -L 2>/dev/null | grep -c "KUBE-" || echo "0")
    if [[ "${RULE_COUNT}" -lt 5 ]]; then
        echo "[WARN] iptables KUBE rules appear missing (count=${RULE_COUNT}) – restarting kube-proxy..."
        KPROXY=$(kubectl --kubeconfig="${KUBECONFIG_OUT}" get pods -n kube-system \
            -l k8s-app=kube-proxy \
            --field-selector "spec.nodeName=${WORKER_CONTAINER}" \
            -o name 2>/dev/null | head -1 || true)
        if [[ -n "${KPROXY}" ]]; then
            kubectl --kubeconfig="${KUBECONFIG_OUT}" delete -n kube-system "${KPROXY}" 2>/dev/null || true
            echo "[INFO] Waiting 20s for new kube-proxy pod..."
            sleep 20
            echo "[OK]  kube-proxy restarted"
        else
            echo "[WARN] kube-proxy pod not found – restart it manually:"
            echo "       kubectl --kubeconfig=${KUBECONFIG_OUT} delete pod -n kube-system -l k8s-app=kube-proxy"
        fi
    else
        echo "[OK]  iptables rules present (count=${RULE_COUNT})"
    fi
fi

# ── Step 9: summary ──────────────────────────────────────────────────────────
echo ""
echo "[OK]  Recovery complete"
echo "      Kubeconfig : ${KUBECONFIG_OUT}"
echo ""
echo "      Next steps:"
echo "        kubectl --kubeconfig=${KUBECONFIG_OUT} get nodes"
echo "        kubectl --kubeconfig=${KUBECONFIG_OUT} scale deployment srsran-operator -n srsran --replicas=1"
