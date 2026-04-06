---
layout: default
title: Jenkins 部署筆記
parent: Infra / DevOps
nav_order: 4
---

# Jenkins 部署筆記

## 專案結構

```
infra/
├── networking/          ← 共用網路層（VPC、subnet、NAT GW、ACM wildcard cert）
│   ├── provider.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── vpc.tf
│   ├── acm.tf           ← Wildcard ACM *.u0052041.com + SSM parameter
│   └── outputs.tf
└── jenkins/
    ├── data.tf          ← 讀 networking remote state
    ├── provider.tf
    ├── variables.tf
    ├── locals.tf
    ├── alb.tf           ← ALB + Listener（cert 來自 networking wildcard）
    ├── sg.tf            ← ALB SG + Controller SG
    ├── iam.tf           ← IAM Role + SSM + EKS + ECR
    ├── ecr.tf           ← ECR repo + image build（buildx --platform linux/amd64）
    ├── Dockerfile       ← Custom Jenkins image（aws cli + kubectl + helm）
    ├── main.tf          ← EC2 + EBS + user_data + container update
    └── outputs.tf
```

## IaC 分層原則

```
networking/  → 管共用網路（VPC、subnet、NAT GW）+ 共用 ACM wildcard cert
jenkins/     → 管 Jenkins infra（EC2、ALB、SG、IAM）
             → user_data 負責 EC2 上的軟體安裝（Docker、Jenkins）
```

EC2 軟體安裝用 `user_data`，只在開機時跑一次。升級 Jenkins image 改 Dockerfile 的 `FROM` 版本後跑 Terraform：

```bash
# 改 Dockerfile 的 FROM jenkins/jenkins:x.x.x-lts
# Terraform 偵測 filemd5() 變化 → 自動 buildx + push ECR → SSM restart container
terraform apply
```

## .gitignore

```
.terraform/
terraform.tfstate
terraform.tfstate.backup
```

`terraform.lock.hcl` **要進版控**（鎖定 provider 版本）

---

## Step 1：Networking 層

Jenkins 和其他服務（EKS、RDS）共用同一個 VPC。

```
VPC 10.0.0.0/16
├── public-1a   10.0.1.0/24   ← ALB、NAT GW
├── public-1c   10.0.2.0/24   ← ALB
├── private-1a  10.0.10.0/24  ← Jenkins EC2、EKS nodes
└── private-1c  10.0.11.0/24  ← EKS nodes
```

```bash
cd infra/networking
terraform init && terraform apply
```

### 開關 NAT Gateway（省錢）

```bash
terraform apply -var="enable_nat_gateway=false"  # 關（省 $32/月）
terraform apply -var="enable_nat_gateway=true"   # 開
```

> **注意**：Jenkins EC2 在 private subnet，`enable_nat_gateway=false` 時 EC2 無法對外，user_data 會失敗（dnf install、docker pull 都需要出口）。關 NAT Gateway 前確保 EC2 已經正常跑起來。

---

## Step 2：Remote State（data.tf）

Jenkins 透過 remote state 讀取 networking 的 output：

```hcl
data "terraform_remote_state" "networking" {
    backend = "local"
    config  = { path = "../networking/terraform.tfstate" }
}

# 使用
vpc_id     = data.terraform_remote_state.networking.outputs.vpc_id
subnet_ids = data.terraform_remote_state.networking.outputs.public_subnet_ids
```

---

## Step 3：ACM 憑證

ACM wildcard 憑證 `*.u0052041.com` 放在 `networking/acm.tf`，所有服務（Jenkins、K8s Ingress）共用同一張。

這樣做的原因：
- 一張 wildcard cert 涵蓋所有 subdomain，不需要每個服務各簽一張
- DNS 驗證只需要在 Cloudflare 加一次 CNAME
- 憑證放在 networking 共用層，各模組透過 remote state 讀取 cert ARN

```hcl
certificate_arn = data.terraform_remote_state.networking.outputs.wildcard_cert_arn
```

ACM DNS 驗證在 networking apply 時處理，參考 `terraform output acm_validation_cname`。

---

## Step 4：ALB（alb.tf）

internet-facing ALB，HTTP 自動 redirect 到 HTTPS：

```
Internet → ALB:80  → redirect 301 → ALB:443 → Jenkins EC2:8080
```

### 開關 ALB（省錢）

```bash
terraform apply -var="enable_alb=false"  # 關（省 $16/月）
terraform apply -var="enable_alb=true"   # 開
```

ALB 關掉（destroy）後重新建立，DNS name 會不同，需要到 Cloudflare 更新 CNAME。

### Health Check 與 TLS Policy

Target Group health check：
- **path**：`/login`（Jenkins 未登入會 302 redirect，所以不能用 `/`）
- **matcher**：`200,302`（必須同時接受 302，否則健康檢查會一直失敗）
- healthy_threshold：2 / unhealthy_threshold：3

HTTPS Listener 使用 `ELBSecurityPolicy-TLS13-1-2-2021-06`，只允許 TLS 1.2 和 1.3，與 EKS Ingress 的 TLS policy 保持一致。

---

## Step 5：Security Group（sg.tf）

| SG | 規則 |
|----|------|
| `jenkins-alb-sg` | ingress 80/443 from 0.0.0.0/0 |
| `jenkins-controller-sg` | ingress 8080 from ALB SG（SG chaining）|

SG chaining：不寫死 IP，用 SG ID 當來源，IP 變動不影響規則。

```hcl
resource "aws_security_group_rule" "controller_from_alb" {
    source_security_group_id = aws_security_group.alb[0].id  # 來源是 ALB SG
    security_group_id        = aws_security_group.jenkins_controller.id
}
```

---

## Step 6：EC2 + EBS（main.tf）

```
aws_instance          → Jenkins Controller（user_data 自動裝 Docker + Jenkins）
aws_ebs_volume        → 20GB gp3（Jenkins 資料持久化）
aws_volume_attachment → 掛載到 EC2（/dev/xvdf 或 /dev/nvme1n1）
```

EBS 有 `prevent_destroy = true`，`terraform destroy` EC2 不會刪掉資料。

**靜態加密**：EC2 root volume（`root_block_device { encrypted = true }`）和 EBS 資料卷（`encrypted = true`）都啟用靜態加密，使用 AWS 管理金鑰（KMS 預設）。

**`user_data_replace_on_change = false`**：改動 `user_data` 不會觸發 EC2 重建。這是刻意設計的——user_data 只在第一次開機時跑，EC2 跑起來後更新 Jenkins 是透過 `null_resource.jenkins_container_update`（SSM 送指令），而不是換 EC2。若需強制重跑 user_data，用 `-replace=aws_instance.jenkins`。

user_data 啟動流程：
1. 安裝 Docker
2. 等待 EBS 裝置出現（最多等 150 秒）
3. 格式化 EBS（首次）並掛載到 `/mnt/jenkins-data`
4. 登入 ECR，拉取 custom Jenkins image
5. 啟動 Jenkins container（使用 ECR image）

---

## Step 7：ECR + Custom Jenkins Image（ecr.tf + Dockerfile）

### Dockerfile

在 `jenkins/jenkins:2.541.3-lts` 基礎上加裝 CI/CD 工具：

```
FROM jenkins/jenkins:2.541.3-lts
├── AWS CLI      ← Terraform、SSM、ECR 操作
├── kubectl      ← 操作 EKS 叢集
└── Helm         ← 部署 K8s 應用
```

### ECR 資源

```
aws_ecr_repository        → 存放 custom Jenkins image
aws_ecr_lifecycle_policy  → 只保留最近 5 個 image
null_resource             → Dockerfile 變動時自動 build + push
```

Repository 設定細節：
- **`image_tag_mutability = "MUTABLE"`**：允許覆蓋同一個 tag（如 `latest`）。每次 build 都 push 到 `latest`，EC2 pull 時永遠拿最新版。若改成 `IMMUTABLE`，同 tag 不能覆蓋，需要改用帶版本號的 tag 策略。
- **`scan_on_push = true`**：每次 push image 時，ECR 自動掃描 OS 層套件的 CVE 漏洞。結果在 AWS Console → ECR → Repositories → jenkins → Images 查看。不影響 push 流程（掃到漏洞不會阻擋 push）。

### Cross-Platform Build

Jenkins EC2 是 `x86_64`，本機 Mac 是 `arm64`，build 時必須指定平台：

```bash
docker buildx build --platform linux/amd64 -t <ecr_url>:latest .
```

不加 `--platform` 會 push arm64 image，EC2 pull 時報錯：
```
no matching manifest for linux/amd64 in the manifest list entries
```

### Image 更新機制（null_resource）

Dockerfile 改動 → Terraform 偵測 `filemd5()` 變化 → 觸發兩個 `null_resource`：

```
1. jenkins_image_build      → 本機 buildx + push 到 ECR
2. jenkins_container_update → SSM 送指令到 EC2：pull + restart container
```

強制測試整個流程（不改 Dockerfile）：
```bash
terraform apply \
    -replace=null_resource.jenkins_image_build \
    -replace=null_resource.jenkins_container_update
```

`filemd5()` 的上次數值存在 `terraform.tfstate` 的 triggers 裡，每次 plan/apply 時跟當前值比較。

---

## Step 8：IAM（iam.tf）

| Resource | 用途 |
|----------|------|
| `aws_iam_role` (jenkins) | EC2 掛的 role |
| `AmazonSSMManagedInstanceCore` | SSM Session Manager（不需要 SSH）|
| `jenkins-eks-policy` | SSM Parameter 讀取 + EKS DescribeCluster |
| `AmazonEC2ContainerRegistryPowerUser` | ECR push/pull（build image + 拉 Jenkins image）|
| `aws_iam_instance_profile` | EC2 與 IAM Role 的橋樑 |

EC2 不能直接掛 Role，需透過 `instance_profile`。

---

## Step 9：Outputs（outputs.tf）

```bash
terraform output                    # 查所有
terraform output -raw instance_id   # 查單一（-raw 不含引號）
```

| Output | 用途 |
|--------|------|
| `instance_id` | SSM 連入、CLI 操作用 |
| `ssm_command` | 直接複製貼上連入 EC2 |
| `alb_dns_name` | 在 Cloudflare 加 CNAME 指向這個 |

ACM 相關 output（`wildcard_cert_arn`、`acm_validation_cname`）在 networking module。

---

## Step 10：部署流程

```bash
# 1. 建 networking（含 wildcard ACM cert）
cd infra/networking
terraform init && terraform apply

# 2. 驗證 ACM 憑證（首次部署才需要）
terraform output acm_validation_cname
# → 到 Cloudflare 加 CNAME，Terraform 會等待驗證完成

# 3. 建 Jenkins（首次 apply 會 build + push ECR image）
cd infra/jenkins
terraform init && terraform apply

# 4. 設定 domain
terraform output alb_dns_name
# → 到 Cloudflare 加 CNAME：jenkins.u0052041.com → ALB DNS

# 5. 等 EC2 user_data 跑完（約 2-3 分鐘）
aws ssm start-session --target $(terraform output -raw instance_id)
docker ps  # 確認 jenkins container 在跑

# 6. 拿初始密碼
aws ssm start-session --target $(terraform output -raw instance_id)
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Jenkins 初始設定：
1. `https://jenkins.yourdomain.com`
2. 貼初始密碼
3. Install suggested plugins
4. 建立管理員帳號

### 常用操作

```bash
# 強制重建 EC2（user_data 會重跑，但 EBS 資料保留）
terraform apply -replace=aws_instance.jenkins

# 更新 Jenkins image（改 Dockerfile 後）
terraform apply
# → 自動 buildx --platform linux/amd64 → push ECR → SSM restart container

# 強制重新 build + deploy（不改 Dockerfile）
terraform apply \
    -replace=null_resource.jenkins_image_build \
    -replace=null_resource.jenkins_container_update
```

---

## Terraform 補充筆記

這份 Jenkins 部署文保留「Jenkins 專案本身」的部署流程與操作。  
更完整的 Terraform 知識（常用語法、state 操作、import/moved、CI 流程、業界實務）已獨立整理到：

- [`infra/terraform-notes.md`](../terraform-notes)

如果你是來複習 Terraform，建議先看 `infra/terraform-notes.md`，再回來搭配本篇的 Jenkins 實作段落一起看。
