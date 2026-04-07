---
layout: default
title: App CD Pipeline 筆記
parent: Infra / DevOps
nav_order: 12
---

# App CD Pipeline 筆記
{: .no_toc }

整套 CI/CD 架構、GitHub Actions CI + Jenkins CD 分工、Kaniko build、Deployment 設計、流量路徑
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、整套 CI/CD 架構總覽

整套系統分成兩類 pipeline：**Infra Pipeline**（基礎設施，手動觸發）和 **App Pipeline**（服務，自動觸發）。

```
┌─────────────────────────────────────────────────────┐
│                   Infra Pipelines                   │
│              （jack-wiki repo，手動觸發）              │
│                                                     │
│  Jenkinsfile.alb-controller → 安裝 ALB Controller   │
│  Jenkinsfile.jenkins-agent  → 建 RBAC + IRSA        │
│  Jenkinsfile.ingress        → 部署 Ingress 規則      │
└────────────────────┬────────────────────────────────┘
                     │ 建好基礎設施後
                     ▼
┌─────────────────────────────────────────────────────┐
│                   App Pipeline                      │
│           （app repo，每次 push 自動觸發）             │
│                                                     │
│  GitHub Actions CI                                  │
│    lint → type check → test → coverage              │
│         │ main push + CI 通過                       │
│         ▼                                           │
│  curl Jenkins API                                   │
│         │                                           │
│         ▼                                           │
│  Jenkins CD（K8s agent pod）                         │
│    Setup → Kaniko build → ECR push → deploy → verify│
│                                      │ 失敗          │
│                                      ▼              │
│                               kubectl rollout undo  │
└─────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│                  EKS Cluster                        │
│                                                     │
│  app.u0052041.com/auth  → app-login-service (×2)   │
│  app.u0052041.com/      → test-app (×2)             │
│                                                     │
│  共用同一個 ALB（group.name: main）                  │
└─────────────────────────────────────────────────────┘
                     ▲
              Cloudflare CNAME
                     ▲
                  使用者
```

### Infra vs App 分工原則

| | Infra Pipeline | App Pipeline |
|---|---|---|
| 管理 repo | jack-wiki | app-login-service |
| 觸發方式 | Jenkins 手動觸發 | GitHub Actions 自動 |
| 執行頻率 | 初次建叢集 / 有變更時 | 每次 push main |
| agent | `agent any`（Jenkins Master） | `agent kubernetes`（K8s Pod）|
| 管什麼 | ALB Controller、Ingress 規則、RBAC | 服務 image build + deploy |

**Ingress 由 Infra repo 集中管理**，不放在 app repo。原因：Ingress 規則涉及多服務的 path 優先序（`group.order`）和共用 ALB 設定，集中管理可以避免多個 app 各自改 Ingress 造成衝突。

---

## 二、CI/CD 分工架構

GitHub Actions 只負責 **CI**（品質檢查），Jenkins 只負責 **CD**（build image + deploy）。兩者透過 Jenkins API 串接：

```
開發者 push → GitHub Actions CI
                ├── lint (ruff)
                ├── format check (ruff)
                ├── type check (mypy)
                └── test + coverage (pytest)
                        │
                        │ 只有 main branch push 且 CI 通過
                        ▼
               curl Jenkins API → Jenkins CD Pipeline
                                    ├── Setup（取得 commit hash）
                                    ├── Build & Push ECR（Kaniko）
                                    ├── Configure kubectl
                                    ├── Deploy（envsubst + kubectl apply）
                                    └── Verify
                                            │ 失敗
                                            ▼
                                    kubectl rollout undo（自動 rollback）
```

### 為什麼不全部放 GitHub Actions？

| | GitHub Actions | Jenkins |
|---|---|---|
| ECR push | 需要 AWS credentials 存在 GitHub Secrets | 透過 IRSA，pod 自動取得 IAM 權限 |
| K8s deploy | 需要 kubeconfig 存在 GitHub Secrets | 在 VPC 內直接呼叫 private EKS endpoint |
| image build | DinD（Docker-in-Docker）有安全疑慮 | Kaniko 不需要 Docker daemon |

EKS API endpoint 是 private-only，GitHub Actions runner 在 VPC 外根本連不到，所以 deploy 必須在 Jenkins（同 VPC）執行。

### GitHub Actions 觸發 Jenkins

```yaml
- name: Trigger Jenkins CD
  run: |
    curl -fsS -X POST \
      "${{ secrets.JENKINS_URL }}/job/app-login-service/build" \
      --user "${{ secrets.JENKINS_USER }}:${{ secrets.JENKINS_TOKEN }}"
```

用 Jenkins API Token（不是密碼），存在 GitHub repo 的 Secrets。`-fsS` 讓 curl 在 HTTP 錯誤時也 exit non-zero（CI 會失敗而非假裝成功）。

---

## 二、Python CI Toolchain（GitHub Actions）

```yaml
runs-on: ubuntu-24.04
timeout-minutes: 15
```

### uv — 套件管理

用 [uv](https://github.com/astral-sh/uv) 取代 pip/poetry：

```yaml
- uses: astral-sh/setup-uv@v5
  with:
    version: "0.11.3"
    enable-cache: true
    cache-dependency-glob: "uv.lock"   # lock file 不變就用快取

- run: uv python install 3.13
- run: uv sync --dev                   # 安裝含 dev 依賴
```

`uv.lock` 鎖定所有套件版本（含 transitive），確保 CI 環境與本機一致。

### ruff — Lint + Format

```bash
uv run ruff check src/ tests/          # lint
uv run ruff format --check src/ tests/ # format（不改檔案，只檢查）
```

ruff 同時取代 flake8 + isort + pyupgrade，速度比 pylint 快幾十倍。

### mypy — 靜態型別檢查

```bash
uv run mypy src/app/
```

只掃 `src/app/`（source），不掃 tests（test code 型別嚴格度通常放寬）。

### pytest — 測試 + 覆蓋率

```bash
uv run pytest \
  --junit-xml=pytest-report.xml \   # JUnit XML 供後續 step 解析
  --cov-report=xml \                # coverage.xml 上傳 Codecov
  --cov-report=term-missing \       # terminal 顯示哪行沒被覆蓋
  --cov-fail-under=80               # 低於 80% 直接 fail
```

### 測試結果 + 覆蓋率報告

```yaml
- uses: dorny/test-reporter@v1      # 把 JUnit XML 轉成 GitHub Checks（PR 頁面可見）
  if: always()                       # 即使 test 失敗也要上傳

- uses: codecov/codecov-action@v5   # 上傳 coverage.xml 到 Codecov
  with:
    fail_ci_if_error: false          # Codecov 掛掉不影響 CI 結果
```

### concurrency — 自動取消舊 run

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

同一個 PR 連續 push 時，新的 run 啟動後自動取消還在跑的舊 run，省 CI 資源。

---

## 三、Kaniko — 在 K8s Pod 裡 Build Image

Jenkins K8s agent pod 包含三個 container（關於 K8s agent 原理見 [EKS 部署筆記](deploy-notes#六jenkins-kubernetes-agent)）：

```yaml
containers:
  - name: jnlp        # WebSocket 連回 Jenkins Master
  - name: aws-tools   # kubectl / aws-cli（EKS 操作）
  - name: kaniko      # 建 Docker image
    image: gcr.io/kaniko-project/executor:debug
```

### 為什麼用 Kaniko 而不是 docker build？

Jenkins agent 跑在 K8s Pod 裡，Pod 內沒有 Docker daemon，無法直接 `docker build`。

選項比較：

| 方案 | 做法 | 問題 |
|------|------|------|
| DinD（Docker-in-Docker） | Pod 裡跑一個 Docker daemon | 需要 `privileged: true`，有安全風險 |
| Docker socket mount | 掛 host 的 `/var/run/docker.sock` | 等同 root 存取 host，更危險 |
| **Kaniko** | 直接解析 Dockerfile，不需要 daemon | 不需要 privileged，適合 K8s 環境 |

### Kaniko 執行

```bash
/kaniko/executor \
  --context=dir:///home/jenkins/agent/workspace/${JOB_NAME} \
  --dockerfile=Dockerfile \
  --destination=${IMAGE_FULL} \         # 帶 commit hash 的 tag
  --destination=${ECR_REGISTRY}/${IMAGE_NAME}:latest \  # 同時 push latest
  --cache=true                           # 快取 layer 到 ECR，加速後續 build
```

`--cache=true` 會把中間 layer 存到 ECR（同一個 registry 下），下次 build 時 Kaniko 比對 layer hash，沒變的直接複用。

### 不需要 `docker login`

Kaniko container 透過 Jenkins Agent 的 IRSA（`jenkins-agent` ServiceAccount）自動取得 ECR 認證，不需要手動 `aws ecr get-login-password`。

---

## 四、Image Tagging 策略

```groovy
env.GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
env.IMAGE_TAG  = env.GIT_COMMIT_SHORT     // e.g. a3f1b2c
env.IMAGE_FULL = "${ECR_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
```

同時 push 兩個 tag：

| Tag | 用途 |
|-----|------|
| `a3f1b2c`（commit hash） | 精確指向某次 build，rollback 時用 |
| `latest` | 方便手動 pull 最新版 debug 用 |

Deployment 用 commit hash tag（不用 `latest`），讓 K8s 知道 image 有沒有變，才能正確觸發 rollout。

---

## 五、Deploy 與自動 Rollback

### Deploy

```bash
export KUBECONFIG=/tmp/kubeconfig   # 用獨立 kubeconfig，不污染預設路徑
export IMAGE_FULL=${IMAGE_FULL}
envsubst < k8s/deployment.yaml | kubectl apply -f -
kubectl rollout status deployment/${IMAGE_NAME} -n ${K8S_NAMESPACE} --timeout=120s
```

`kubectl rollout status --timeout=120s`：等待 rollout 完成，超過 2 分鐘或 pod 啟動失敗就 exit non-zero，觸發 Jenkins pipeline 進入 `post { failure }`。

### 自動 Rollback

```groovy
post {
    failure {
        container('aws-tools') {
            sh "kubectl rollout undo deployment/${IMAGE_NAME} -n ${K8S_NAMESPACE} || true"
        }
    }
}
```

任何 stage 失敗都會執行 `rollout undo`，把 deployment 回到上一個版本。`|| true` 避免 rollback 本身失敗（如：首次部署沒有上一版）再拋錯。

---

## 六、前置條件（一次性設定）

### ECR Repo

```bash
aws ecr create-repository \
  --repository-name app-login-service \
  --region ap-northeast-1
```

> Kaniko 的 `--cache=true` 會直接把 cache layer 存到這個 repo 下，不需要另建 cache repo。

### K8s Secret

```bash
kubectl create secret generic app-login-service-secret \
  --from-literal=SECRET_KEY=$(openssl rand -hex 32) \
  --from-literal=DATABASE_URL=postgresql+asyncpg://user:pass@host:5432/logindb \
  --from-literal=ENVIRONMENT=production
```

Secret 不進版控，手動建一次。Deployment YAML 透過 `envFrom` 或 `valueFrom.secretKeyRef` 引用。

### Jenkins Agent IRSA ECR 權限

Jenkins Agent IAM Policy 已包含 ECR push 所需的 action（`ecr:PutImage`、`ecr:InitiateLayerUpload` 等），見 `infra/k8s/jenkins-agent-irsa.tf`。

### GitHub Secrets

| Secret | 說明 |
|--------|------|
| `JENKINS_URL` | `https://jenkins.u0052041.com` |
| `JENKINS_USER` | Jenkins 帳號 |
| `JENKINS_TOKEN` | Jenkins API Token（不是密碼） |

---

## 七、Deployment 設計

### 基本設定

```yaml
replicas: 2          # 兩個 pod，搭配 PDB 確保 rolling update 時至少 1 個在跑
namespace: default
```

### Pod Security Context

```yaml
securityContext:
  runAsNonRoot: true     # 禁止以 root 跑 container
  runAsUser: 1001
  fsGroup: 1001
```

Container 層：
```yaml
securityContext:
  allowPrivilegeEscalation: false   # 禁止提權
  readOnlyRootFilesystem: false     # FastAPI 需要寫入（log、tmp），保持 false
```

### Resource Limits

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

`requests` 是 K8s scheduler 用來決定放到哪個 node 的依據；`limits` 是容器的上限，超過 CPU limit 會被 throttle，超過 memory limit 會被 OOMKill。

### Readiness / Liveness Probe

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 10   # 等 10 秒才開始探，讓 app 有時間啟動
  periodSeconds: 10
  failureThreshold: 3        # 連續失敗 3 次才標記為 not ready

livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 20   # liveness 比 readiness 晚開始，避免啟動中就被殺
  periodSeconds: 30
  failureThreshold: 3        # 連續失敗 3 次才重啟 pod
```

兩個 probe 的差異：
- **readiness**：pod not ready → 從 Service Endpoint 移除，不再收流量，但 pod 不重啟
- **liveness**：pod not alive → K8s 重啟 pod

### PodDisruptionBudget

```yaml
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: app-login-service
```

保證 rolling update 或 node drain 時，至少 1 個 pod 持續服務。配合 `replicas: 2`，同時只能下線 1 個 pod。

### Secret 注入

```yaml
envFrom:
  - secretRef:
      name: app-login-service-secret
```

把 Secret 裡所有 key-value 一次全部注入為環境變數（`SECRET_KEY`、`DATABASE_URL`、`ENVIRONMENT`），不需要逐一列出。

---

## 八、流量路徑

```
使用者
  │ HTTPS app.u0052041.com
  ▼
Cloudflare（CNAME → ALB DNS）
  │ TLS 終止在 ALB
  ▼
ALB（internet-facing，ELBSecurityPolicy-TLS13-1-2-2021-06）
  │
  ├─ /auth  → Target Group: app-login-service（group.order: 20）
  │               │ target-type: ip（直打 Pod IP）
  │               ▼
  │           app-login-service Pod :8000
  │
  └─ /      → Target Group: test-app（group.order: 100）
                  │ target-type: ip
                  ▼
              test-app Pod :8080（nginx）
```

### 關鍵設計點

**`target-type: ip`**：ALB 直接打 Pod IP（透過 ENI），不經過 NodePort。延遲更低，也不受 node 數量限制。

**共用 ALB（`group.name: main`）**：所有服務共用同一個 ALB，每個 ALB 約 $16/月，不需要每個服務各建一個。

**path 優先序（`group.order`）**：數字小的先匹配。`/auth`（order 20）比 `/`（order 100）先判斷，所以 `/auth` 的請求不會誤落到 test-app。

**Health Check**：ALB 直接對 Pod IP 打 `/health`（app-login-service）或 `/`（test-app），health check 失敗的 Pod 自動從 Target Group 移除。
