# ── Jenkins Agent IRSA ────────────────────────────────────────────────────────
# Agent pod 裡的 aws-cli 需要 AWS 認證（讀 SSM、呼叫 EKS）
# 模式同 alb-controller.tf：OIDC federation → IAM Role → pod ServiceAccount

resource "aws_iam_role" "jenkins_agent" {
    name = "${var.cluster_name}-jenkins-agent"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-jenkins-agent" })

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = {
                Federated = aws_iam_openid_connect_provider.eks.arn
            }
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {
                StringEquals = {
                    "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
                    "${local.oidc_issuer}:sub" = "system:serviceaccount:jenkins-agents:jenkins-agent"
                }
            }
        }]
    })
}

resource "aws_iam_policy" "jenkins_agent" {
    name = "${var.cluster_name}-jenkins-agent"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-jenkins-agent" })

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Sid    = "SSMParameterRead"
                Effect = "Allow"
                Action = [
                    "ssm:GetParameter",
                    "ssm:GetParameters",
                    "ssm:GetParametersByPath"
                ]
                Resource = [
                    "arn:aws:ssm:*:*:parameter/eks/*",
                    "arn:aws:ssm:*:*:parameter/shared/*"
                ]
            },
            {
                Sid    = "EKSAccess"
                Effect = "Allow"
                Action = [
                    "eks:DescribeCluster",
                    "eks:ListClusters"
                ]
                Resource = "*"
            },
            {
                Sid    = "ECRPush"
                Effect = "Allow"
                Action = [
                    "ecr:GetAuthorizationToken",
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:BatchGetImage",
                    "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload",
                    "ecr:PutImage"
                ]
                Resource = "*"
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "jenkins_agent" {
    role       = aws_iam_role.jenkins_agent.name
    policy_arn = aws_iam_policy.jenkins_agent.arn
}

# ── SSM Parameter（供 RBAC yaml 注入 annotation 使用）────────────────────────

resource "aws_ssm_parameter" "jenkins_agent_role_arn" {
    name  = "/eks/${var.cluster_name}/jenkins-agent-role-arn"
    type  = "String"
    value = aws_iam_role.jenkins_agent.arn
    tags  = merge(local.common_tags, { Name = "${var.cluster_name}-jenkins-agent-role-arn" })
}
