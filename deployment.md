# srsRAN gNB Nephio Deployment — Complete Command Reference

> 環境：Nephio management cluster + regional workload cluster（KIND），2026-03  
> Operator 路徑：`/home/free5gc/srsran-operator/`  
> Kubeconfig：`/home/free5gc/regional.kubeconfig`（指向 workload cluster）

---

## 目錄

1. [環境變數速查](#0-環境變數速查)
2. [Phase 1：Build & Push Operator Image](#phase-1-build--push-operator-image)
3. [Phase 2：推 Blueprint 到 Gitea](#phase-2-推-blueprint-到-gitea)
4. [Phase 3：Register Porch Repository](#phase-3-register-porch-repository)
5. [Phase 4：PVS 部署](#phase-4-pvs-部署)
6. [Phase 5：Deploy Operator 到 Workload Cluster](#phase-5-deploy-operator-到-workload-cluster)
7. [Phase 6：驗證部署結果](#phase-6-驗證部署結果)
8. [清理殘留資源（壞掉的 PV / PVS / PackageRevision）](#清理殘留資源壞掉的-pv--pvs--packagerevision)

---

## 0 環境變數速查

```bash
WORKER_NODE="regional-md-0-n5x7s-qqwrs-q8zwx"
KUBECONFIG="/home/free5gc/regional.kubeconfig"
WKCTL="kubectl --kubeconfig=${KUBECONFIG}"

GITEA_URL="http://172.18.0.200:3000"
GITEA_ORG="nephio"
GITEA_USER="nephio"
GITEA_PASS="secret"
CATALOG_REPO="catalog-workloads-srsran"
CATALOG_PKG="pkg-srsran"

IMG="docker.io/nephio/srsran-operator:latest"
OPERATOR_NS="srsran"
OPERATOR_DIR="/home/free5gc/srsran-operator"
```

---

## Phase 1：Build & Push Operator Image

### 1-a  編譯 Go binary

```bash
cd /home/free5gc/srsran-operator
go build -o manager ./cmd/main.go
```

### 1-b  Build Docker image

```bash
docker build -t "${IMG}" .
```

> Dockerfile 使用 distroless/static，把本地已編好的 `manager` binary 直接 COPY 進去：
> ```dockerfile
> FROM gcr.io/distroless/static:nonroot
> WORKDIR /
> COPY manager .
> USER 65532:65532
> ENTRYPOINT ["/manager"]
> ```

### 1-c  載入 image 到 worker node（KIND 環境，非 Pull Hub）

工人節點用的是 containerd，需把 image 直接 import：

```bash
docker save "${IMG}" \
  | sudo docker exec -i "${WORKER_NODE}" \
      ctr -n k8s.io images import -
```

> 注意：`ctr images import` 預設寫入 `default` namespace，  
> 必須加 `-n k8s.io` 才能讓 Kubernetes kubelet 找到。

### 1-d  驗證 image 已在 worker node

```bash
sudo docker exec "${WORKER_NODE}" \
  ctr -n k8s.io images ls | grep srsran
```

---

## Phase 2：推 Blueprint 到 Gitea

### 2-a  確認 / 建立 Gitea repo

```bash
# 如果 repo 不存在才需要建立
curl -s -o /dev/null -w "%{http_code}" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_URL}/api/v1/repos/${GITEA_ORG}/${CATALOG_REPO}"
# 200 = 已存在，404 = 需建立

curl -X POST "${GITEA_URL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -d '{"name":"catalog-workloads-srsran","private":false,"auto_init":true,"default_branch":"main"}'
```

### 2-b  Clone → 複製 blueprint → Push

```bash
REPO_DIR="/tmp/srsran-catalog-push"
rm -rf "${REPO_DIR}"
git clone "http://${GITEA_USER}:${GITEA_PASS}@${GITEA_URL#http://}/${GITEA_ORG}/${CATALOG_REPO}.git" \
  "${REPO_DIR}"

mkdir -p "${REPO_DIR}/${CATALOG_PKG}"
cp -r "${OPERATOR_DIR}/blueprint/." "${REPO_DIR}/${CATALOG_PKG}/"

cd "${REPO_DIR}"
git config user.email "nephio@nephio.org"
git config user.name  "Nephio"
git add .
git diff --cached --quiet || \
  git commit -m "Add/update srsRAN gNB blueprint (${CATALOG_PKG})" && git push origin main
```

### 2-c  更新已存在的 regional repo 的 srsranconfig（修正 image）

如果 regional repo 的 `srsran-gnb/srsranconfig.yaml` 需要修正（例如直接 push 不走 Porch pipeline）：

```bash
REGIONAL_DIR="/tmp/regional-fix"
rm -rf "${REGIONAL_DIR}"
git clone "http://${GITEA_USER}:${GITEA_PASS}@${GITEA_URL#http://}/${GITEA_ORG}/regional.git" \
  "${REGIONAL_DIR}"

# 手動編輯 srsranconfig.yaml，把 image 改成 qawl987/srsran-split:latest
vim "${REGIONAL_DIR}/srsran-gnb/srsranconfig.yaml"

cd "${REGIONAL_DIR}"
git config user.email "nephio@nephio.org"
git config user.name  "Nephio"
git add srsran-gnb/srsranconfig.yaml
git commit -m "fix: use qawl987/srsran-split:latest images"
git push origin main
```

> 推完後重啟 ConfigSync reconciler pod 讓它立刻 re-sync：
> ```bash
> kubectl delete pod -n config-management-system \
>   -l app=reconciler-manager
> ```

---

## Phase 3：Register Porch Repository

```bash
kubectl create secret generic srsran-catalog-creds \
  --from-literal=username="${GITEA_USER}" \
  --from-literal=password="${GITEA_PASS}" \
  --type=kubernetes.io/basic-auth \
  -n default 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: catalog-workloads-srsran
  namespace: default
spec:
  content: Package
  deployment: false
  git:
    branch: main
    directory: /
    repo: http://172.18.0.200:3000/nephio/catalog-workloads-srsran.git
    secretRef:
      name: srsran-catalog-creds
  type: git
EOF

# 等 Porch sync
sleep 20
kubectl get packagerevision -n default | grep catalog-workloads-srsran
```

---

## Phase 4：PVS 部署

### 4-a  確認 WorkloadCluster 有 site-type 標籤

```bash
kubectl label workloadcluster regional \
  nephio.org/site-type=combined --overwrite -n default

# 確認
kubectl get workloadcluster regional -n default \
  -o jsonpath='{.metadata.labels}' | python3 -m json.tool
```

> ⚠️ **重要**：PVS v1alpha2 的 `repositorySelector` 匹配的是 **Repository** 資源，  
> 不是 WorkloadCluster。ConfigSync 管理的 regional Repository 標籤會被覆蓋，  
> 正確做法是用 `objectSelector` 搭配 `WorkloadCluster`，或直接用 `repositories` 指定。

### 4-b  建立 PackageVariantSet

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: config.porch.kpt.dev/v1alpha2
kind: PackageVariantSet
metadata:
  name: srsran-gnb
  namespace: default
spec:
  upstream:
    repo: catalog-workloads-srsran
    package: pkg-srsran
    workspaceName: main
  targets:
  - objectSelector:
      apiVersion: infra.nephio.org/v1alpha1
      kind: WorkloadCluster
      matchLabels:
        nephio.org/site-type: combined
    template:
      downstream:
        package: srsran-gnb
      annotations:
        approval.nephio.org/policy: always
      injectors:
      - nameExpr: target.name
EOF
```

> 若 `objectSelector` 無效（沒產生 packagevariant），改用顯式 `repositories`：
> ```yaml
>   targets:
>   - repositories:
>     - name: regional
>       packageNames:
>       - srsran-gnb
> ```

### 4-c  等待並確認 PackageRevision 建立

```bash
sleep 15
kubectl get packagerevision -n default | grep srsran-gnb
porchctl rpkg get -n default | grep srsran-gnb
```

### 4-d  Propose → Approve PackageRevision

```bash
# 找到 Draft 狀態的 revision
REV=$(porchctl rpkg get -n default \
  | grep "regional.srsran-gnb.packagevariant" \
  | grep -v Published \
  | awk '{print $1}' | head -1)

echo "Revision: ${REV}"

porchctl rpkg propose "${REV}" -n default
sleep 5
porchctl rpkg approve  "${REV}" -n default

# 確認 Published
kubectl get packagerevision -n default "${REV}" \
  -o jsonpath='{.spec.lifecycle}'
```

---

## Phase 5：Deploy Operator 到 Workload Cluster

### 5-a  套用 CRDs

```bash
kubectl --kubeconfig="${KUBECONFIG}" apply \
  -f "${OPERATOR_DIR}/config/crd/bases/"
```

### 5-b  建立 namespace + RBAC + Deployment

```bash
kubectl --kubeconfig="${KUBECONFIG}" \
  create namespace "${OPERATOR_NS}" 2>/dev/null || true

cat <<EOF | kubectl --kubeconfig="${KUBECONFIG}" apply -f -
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
  resources: ["nfdeployments","nfdeployments/status","nfdeployments/finalizers","nfconfigs"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: [""]
  resources: ["configmaps","serviceaccounts","services","pods","events"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["workload.nephio.org"]
  resources: ["srsrancellconfigs","plmnconfigs","srsranconfigs"]
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
```

### 5-c  確認 operator 跑起來

```bash
kubectl --kubeconfig="${KUBECONFIG}" get pods -n "${OPERATOR_NS}"
kubectl --kubeconfig="${KUBECONFIG}" logs \
  -n "${OPERATOR_NS}" deploy/srsran-operator --tail=50
```

---

## Phase 6：驗證部署結果

```bash
# srsRAN pods
kubectl --kubeconfig="${KUBECONFIG}" get pods -A \
  | grep -iE "cucp|cuup|du|srsran|gnb"

# NFDeployment
kubectl --kubeconfig="${KUBECONFIG}" get nfdeployment -A

# SrsRANConfig（確認 image 是 qawl987）
kubectl --kubeconfig="${KUBECONFIG}" get srsranconfig -A -o yaml \
  | grep -E "Image|image"

# Multus NetworkAttachmentDefinition
kubectl --kubeconfig="${KUBECONFIG}" get net-attach-def -n srsran-gnb

# PackageRevision 最終狀態
kubectl get packagerevision -n default | grep srsran
```

---

## 清理殘留資源（壞掉的 PV / PVS / PackageRevision）

### 狀況一：PackageRevision 卡在 `DeletionProposed`

Porch 把 PackageRevision 標成 DeletionProposed 後需要再一次 delete 才會真的刪除：

```bash
# 查看所有 DeletionProposed
kubectl get packagerevision -n default \
  --no-headers \
  | grep "DeletionProposed" \
  | awk '{print $1}'

# 批次刪除（porchctl rpkg delete 也可以）
for pr in \
  regional.srsran-gnb.packagevariant-1 \
  regional.srsran-gnb.packagevariant-2 \
  regional.srsran-gnb.packagevariant-3; do
  porchctl rpkg delete "${pr}" -n default 2>&1 || true
done

# 確認清乾淨
kubectl get packagerevision -n default | grep srsran
```

### 狀況二：PackageVariantSet 不見了但仍有殘留 PackageRevision

```bash
# PVS 已刪除但 packagevariant-N 還在 → 手動 delete
kubectl delete packagerevision \
  regional.srsran-gnb.packagevariant-1 \
  regional.srsran-gnb.packagevariant-2 \
  regional.srsran-gnb.packagevariant-3 \
  -n default 2>/dev/null || true
```

### 狀況三：Namespace 卡住，無法 delete（Terminating）

```bash
# 找出造成卡住的 finalizer
kubectl get namespace srsran-gnb -o json \
  | python3 -m json.tool | grep -A5 finalizer

# 強制移除 finalizer（最後手段）
kubectl patch namespace srsran-gnb \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge

# 或用 raw API
kubectl proxy &
curl -s -X PUT \
  http://localhost:8001/api/v1/namespaces/srsran-gnb/finalize \
  -H "Content-Type: application/json" \
  --data-binary '{"kind":"Namespace","apiVersion":"v1","metadata":{"name":"srsran-gnb"},"spec":{"finalizers":[]}}'
kill %1
```

### 狀況四：ConfigSync 不斷把 operator 建立的 Deployment 刪掉（prune）

根本原因：ConfigSync 只保留 git 裡有的資源，operator 動態建立的 Deployment 不在 git 中。

解決方法：
```bash
# 看 ConfigSync prune 事件
kubectl get events -n srsran-gnb \
  | grep -i "pruned\|delete"

# 選項 A：在 Kptfile pipeline 產出 Deployment YAML（讓 ConfigSync 以 owner 身份管理）
# 選項 B：用 RootSync 的 ignoredFields 跳過 prune（需 ConfigSync v1.16+）
# 選項 C（最簡單）：讓 operator 在 ConfigSync Apply 後才建立
#   → 重啟 operator 讓它 reconcile 成功後，不要手動刪 Deployment
```

### 狀況五：全部重來（nuclear option）

```bash
# 1. 刪 PVS
kubectl delete packagevariantset srsran-gnb -n default 2>/dev/null || true

# 2. 刪殘留 PackageRevision
for pr in $(kubectl get packagerevision -n default --no-headers \
    | grep "srsran-gnb" | awk '{print $1}'); do
  kubectl delete packagerevision "${pr}" -n default 2>/dev/null || true
done

# 3. 刪 workload cluster 上的資源
kubectl --kubeconfig="${KUBECONFIG}" delete namespace srsran-gnb 2>/dev/null || true
kubectl --kubeconfig="${KUBECONFIG}" delete namespace "${OPERATOR_NS}" 2>/dev/null || true

# 4. 刪 CRDs（若要完全重置）
kubectl --kubeconfig="${KUBECONFIG}" delete crd \
  srsranconfigs.workload.nephio.org \
  srsrancellconfigs.workload.nephio.org \
  plmnconfigs.workload.nephio.org 2>/dev/null || true

# 5. 重新走 Phase 1 ~ Phase 6
```

---

## 關鍵注意事項

| 問題 | 原因 | 解決 |
|---|---|---|
| image 用 `softwareradiosystems` | operator 預設值錯誤 | 改為 `qawl987/srsran-split:latest` |
| `CrashLoopBackOff` Exit Code 0 | binary 路徑不存在於 image | 改用 `entrypoint-cucp.sh` 等 entrypoint |
| ConfigMap 無法掛載 | key 名稱不符（`cu_cp.yml` vs `gnb-config.yml`） | key 統一改為 `gnb-config.yml` |
| ConfigSync 覆蓋 SrsRANConfig | regional git repo 有舊內容 | 直接 push 修正到 `nephio/regional` repo |
| Deployments 被 ConfigSync prune | operator 建立的資源不在 git | operator 先啟動，再讓 ConfigSync sync |
| `repositorySelector` 找不到 repo | regional Repository 無 site-type 標籤（ConfigSync 管理） | PVS 改用 `objectSelector`（WorkloadCluster）或 `repositories` 直接指定 |
| image 在 worker node 但 pull 失敗 | `imagePullPolicy: Always` 強制向 Hub 拉 | 改 `imagePullPolicy: IfNotPresent` |
| `ctr images import` 進錯 namespace | 預設寫入 `default` namespace | 加 `-n k8s.io` flag |

---

## qawl987/srsran-split Image 結構

```
Binaries:   srscucp, srscuup, srsdu
Entrypoints:
  CU-CP → /usr/local/bin/entrypoint-cucp.sh
  CU-UP → /usr/local/bin/entrypoint-cuup.sh
  DU    → /usr/local/bin/entrypoint-du.sh
Config mount path: /etc/config/gnb-config.yml
```

---

## 一鍵重部署（全新環境）

```bash
cd /home/free5gc/srsran-operator
./deploy-srsran.sh
```

腳本涵蓋上述所有步驟（Phase 0–10），可用環境變數覆蓋預設值：

```bash
CLUSTER_NAME=edge1 \
WORKER_NODE=edge1-control-plane \
IMG=docker.io/myrepo/srsran-operator:v2 \
./deploy-srsran.sh
```
