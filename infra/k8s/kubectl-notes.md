---
layout: default
title: kubectl 指令參考
parent: Infra / DevOps
nav_order: 13
---

# kubectl 指令參考
{: .no_toc }

Production 常用指令、除錯流程、資源操作
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Context / Cluster

```bash
# 查目前連哪個 cluster
kubectl config current-context

# 列出所有 context
kubectl config get-contexts

# 切換 cluster
kubectl config use-context <context-name>

# EKS 專用：更新 kubeconfig（會新增或覆蓋 context）
aws eks update-kubeconfig --name main-eks --region ap-northeast-1

# 用獨立 kubeconfig 操作（不影響預設 ~/.kube/config）
export KUBECONFIG=/tmp/kubeconfig
aws eks update-kubeconfig --name main-eks --region ap-northeast-1 --kubeconfig /tmp/kubeconfig
```

---

## 二、查看資源

### 常用 get

```bash
# Pod
kubectl get pods                          # 當前 namespace
kubectl get pods -n kube-system           # 指定 namespace
kubectl get pods -A                       # 所有 namespace
kubectl get pods -o wide                  # 顯示 node IP、所在 node
kubectl get pods -l app=app-login-service # 用 label 篩選
kubectl get pods --watch                  # 即時監控狀態變化

# Deployment / Service / Ingress
kubectl get deployment,service,ingress

# Node
kubectl get nodes
kubectl get nodes -o wide                 # 顯示 internal/external IP、OS

# 所有資源（常用於盤點）
kubectl get all -n <namespace>
```

### describe — 看詳細事件

```bash
kubectl describe pod <pod-name>
kubectl describe deployment <name>
kubectl describe node <node-name>
kubectl describe ingress <name>
```

`describe` 最重要的是底部的 **Events** 區塊，pod 啟動失敗、image pull 失敗、OOMKill 都在這裡。

### 輸出格式

```bash
kubectl get pod <name> -o yaml            # 完整 YAML（debug 用）
kubectl get pod <name> -o json            # JSON 格式
kubectl get pod <name> -o jsonpath='{.status.podIP}'  # 取特定欄位
```

---

## 三、Pod 除錯

### Logs

```bash
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container>    # 多 container pod 指定 container
kubectl logs <pod-name> --previous        # 看上一次崩潰的 log（OOMKill 必用）
kubectl logs <pod-name> -f                # follow（即時串流）
kubectl logs <pod-name> --tail=100        # 只看最後 100 行
kubectl logs -l app=app-login-service     # 用 label 看多個 pod 的 log
```

### Exec — 進入 Pod

```bash
kubectl exec -it <pod-name> -- /bin/bash
kubectl exec -it <pod-name> -c <container> -- /bin/sh   # 指定 container
kubectl exec <pod-name> -- env | grep DATABASE           # 確認環境變數注入
kubectl exec <pod-name> -- cat /etc/resolv.conf          # 確認 DNS 設定
```

### 臨時 Debug Pod

```bash
# 在 cluster 內起一個臨時 pod（測完自動刪）
kubectl run debug --image=busybox --rm -it --restart=Never -- sh

# 用 curlimages/curl 測試 service 連線
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
    curl http://app-login-service/health

# 複製現有 pod 的設定起 debug pod（保留 env、volume）
kubectl debug -it <pod-name> --image=busybox --copy-to=debug-pod
```

### Port Forward — 本機測試 service

```bash
kubectl port-forward svc/app-login-service 8080:80
kubectl port-forward pod/<pod-name> 8000:8000
# 之後本機 curl localhost:8080
```

---

## 四、Deployment 操作

### Rollout

```bash
# 查 rollout 狀態（deploy 後等待用）
kubectl rollout status deployment/app-login-service

# 查 rollout 歷史
kubectl rollout history deployment/app-login-service

# 回滾到上一版
kubectl rollout undo deployment/app-login-service

# 回滾到指定版本
kubectl rollout undo deployment/app-login-service --to-revision=3

# 重啟所有 pod（不改 image，觸發 rolling restart）
kubectl rollout restart deployment/app-login-service
```

### Scale

```bash
kubectl scale deployment/app-login-service --replicas=3
```

### 更新 Image

```bash
kubectl set image deployment/app-login-service \
    app-login-service=677856867919.dkr.ecr.ap-northeast-1.amazonaws.com/app-login-service:a3f1b2c
```

### 查 Rollout 停住的原因

```bash
# 若 rollout status 一直等，檢查新 pod 的事件
kubectl describe pod <new-pod-name>

# 常見原因：
# - ImagePullBackOff → ECR 權限或 image 不存在
# - CrashLoopBackOff → 應用程式啟動失敗（看 logs --previous）
# - Pending → 資源不足或 node selector 不符（看 describe）
```

---

## 五、Service / Ingress

```bash
# 確認 service endpoint 有沒有 pod（Endpoints 空 = label 不符或 pod not ready）
kubectl get endpoints app-login-service

# 確認 ingress 有沒有拿到 ALB DNS
kubectl get ingress
# ADDRESS 欄位有值 = ALB 已建立

# 詳細看 ingress annotation 有沒有被 ALB controller 接受
kubectl describe ingress app-login-service
# 底部 Events 若有 error = ALB controller 解析 annotation 失敗
```

---

## 六、Secret / ConfigMap

```bash
# 列出 secret（不顯示值）
kubectl get secret

# 解碼 secret 的值
kubectl get secret app-login-service-secret -o jsonpath='{.data.DATABASE_URL}' | base64 -d

# 建立 secret（指令方式，不進版控）
kubectl create secret generic my-secret \
    --from-literal=KEY=value \
    --from-file=cert.pem

# 確認 pod 有沒有正確拿到 secret（進去看環境變數）
kubectl exec <pod-name> -- env | grep SECRET_KEY
```

---

## 七、Node 操作

```bash
# 查 node 資源使用量（需要 metrics-server）
kubectl top nodes
kubectl top pods

# 把 node 標為不可排程（維護前用）
kubectl cordon <node-name>

# 把 node 上的 pod 全部驅逐（rolling 到其他 node）
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 維護完，恢復可排程
kubectl uncordon <node-name>
```

`cordon` + `drain` 是 node 輪換（換 AMI、升級）的標準流程。`drain` 會遵守 PodDisruptionBudget，不會強制刪超過限制。

---

## 八、Namespace

```bash
kubectl get namespaces
kubectl create namespace staging
kubectl delete namespace staging

# 切換預設 namespace（不用每次打 -n）
kubectl config set-context --current --namespace=jenkins-agents
```

---

## 九、RBAC

```bash
# 確認某個 ServiceAccount 有哪些權限
kubectl auth can-i get pods --as=system:serviceaccount:jenkins-agents:jenkins-agent

# 列出 ClusterRoleBinding（誰有 cluster-admin）
kubectl get clusterrolebinding | grep admin

# 看某個 ClusterRole 的具體 rules
kubectl describe clusterrole jenkins-agent-deploy
```

---

## 十、Events — 全局事件

```bash
# 看當前 namespace 所有 event（按時間排序）
kubectl get events --sort-by='.lastTimestamp'

# 只看 Warning
kubectl get events --field-selector type=Warning

# 指定 namespace
kubectl get events -n kube-system --sort-by='.lastTimestamp'
```

`events` 是 cluster-wide 的除錯起點，pod 出問題時比 `describe` 更快找到根因。

---

## 十一、Apply / Delete

```bash
# 套用 manifest（idempotent）
kubectl apply -f deployment.yaml
kubectl apply -f k8s/                   # 套用整個目錄
kubectl apply -f - <<EOF                # 從 stdin（envsubst 搭配用）
...
EOF

# 刪除資源
kubectl delete -f deployment.yaml
kubectl delete pod <pod-name>           # 刪單一 pod（deployment 會自動重建）
kubectl delete pod <pod-name> --force   # 強制刪（stuck terminating 時用）

# Dry run — 確認 manifest 格式正確但不實際套用
kubectl apply -f deployment.yaml --dry-run=client
kubectl apply -f deployment.yaml --dry-run=server   # server-side 驗證更嚴格
```

---

## 十二、常見除錯流程

### Pod 一直 CrashLoopBackOff

```bash
kubectl get pods                          # 確認狀態
kubectl logs <pod> --previous             # 看上次崩潰的 log
kubectl describe pod <pod>               # 看 Events（OOMKill、probe 失敗）
```

### Pod 一直 Pending

```bash
kubectl describe pod <pod>
# Events 通常會說：
# - Insufficient cpu/memory → scale up node 或降低 requests
# - no nodes match node selector → 檢查 nodeSelector / taint
```

### ImagePullBackOff

```bash
kubectl describe pod <pod>
# Events 裡看 image 名稱有沒有打錯
# ECR 的話確認 node role 有 AmazonEC2ContainerRegistryReadOnly
```

### Service 打不到 Pod

```bash
kubectl get endpoints <service>          # 是否有 pod IP？
kubectl get pods -l <label>             # label 是否跟 service selector 一致？
kubectl exec <other-pod> -- curl http://<service>:<port>  # 在 cluster 內測連線
```

### ALB 沒有 ADDRESS

```bash
kubectl describe ingress <name>          # Events 看 ALB controller 有沒有報錯
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```
