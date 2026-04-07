---
layout: default
title: Infra / DevOps
nav_order: 5
has_children: true
---

# Infra / DevOps

基礎設施自動化、AWS 架構與 IaC 實務筆記。

## 筆記索引

| 筆記 | 內容摘要 |
|------|---------|
| [Jenkins 部署筆記](jenkins/deploy-notes) | Jenkins EC2、ALB、ECR、IAM、user_data 完整部署流程 |
| [EKS 部署筆記](k8s/deploy-notes) | EKS Cluster、ALB Controller、Jenkins K8s Agent、Ingress 設計 |
| [App CD Pipeline 筆記](k8s/app-deploy-pipeline-notes) | GitHub Actions CI + Jenkins CD 分工、Kaniko build、自動 rollback |
| [kubectl 指令參考](k8s/kubectl-notes) | Production 常用指令、除錯流程、Rollout / Node 操作 |
| [AWS VPC 網路筆記](aws-vpc-networking-notes) | VPC、Subnet、NAT GW、Route Table |
| [AWS EKS 筆記](aws-eks-notes) | EKS 概念、IRSA、OIDC、Access Entry |
| [ACM / ALB 筆記](acm-alb-notes) | Certificate Manager、ALB、Listener、Target Group |
| [AWS 加密筆記](aws-encryption-notes) | KMS、EBS 加密、S3 加密 |
| [Terraform 筆記](terraform-notes) | 常用語法、state 操作、import、CI 流程 |
| [Ansible 筆記](ansible-notes) | Playbook、Inventory、常用模組 |
