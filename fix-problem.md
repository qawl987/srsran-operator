# 問題修復紀錄

## etcd NOSPACE 問題

### 症狀

執行 kubectl 寫入操作時出現錯誤：
```
error: failed to patch: etcdserver: mvcc: database space exceeded
```

### 診斷

檢查 etcd 狀態：
```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig kubectl exec -n kube-system etcd-regional-pmv5z-4fbk6 -- sh -c "
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint status --write-out=table"
```

輸出顯示 `alarm:NOSPACE` 且 DB SIZE 達到 2.1GB。

### 修復步驟

1. **解除 NOSPACE alarm 並獲取當前 revision**：
```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig kubectl exec -n kube-system etcd-regional-pmv5z-4fbk6 -- sh -c "
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  alarm disarm && \
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint status --write-out=json"
```

從輸出的 JSON 中找到 `"revision":XXXXXXX`。

2. **執行 compaction（使用上一步獲取的 revision）**：
```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig kubectl exec -n kube-system etcd-regional-pmv5z-4fbk6 -- sh -c "
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  compact XXXXXXX"
```

3. **執行 defragmentation（需要較長時間）**：
```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig kubectl exec -n kube-system etcd-regional-pmv5z-4fbk6 -- sh -c "
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  defrag --command-timeout=120s"
```

4. **驗證修復結果**：
```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig kubectl exec -n kube-system etcd-regional-pmv5z-4fbk6 -- sh -c "
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint status --write-out=table"
```

DB SIZE 應該大幅縮小（例如從 2.1GB 減少到 76MB），且 ERRORS 欄位為空。

### 根本原因

etcd 預設配額為 2GB。長時間運行的 Kubernetes cluster 會累積大量歷史 revision，導致空間耗盡。建議定期執行 compaction 或增加 etcd 配額。
