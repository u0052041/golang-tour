resource "aws_eks_cluster" "main" {
    name                          = var.cluster_name
    version                       = var.cluster_version
    role_arn                      = aws_iam_role.eks_cluster.arn
    bootstrap_self_managed_addons = false
    tags                          = merge(local.common_tags, { Name = var.cluster_name })

    vpc_config {
        subnet_ids              = data.terraform_remote_state.networking.outputs.private_subnet_ids
        endpoint_private_access = true
        endpoint_public_access  = false
    }

    access_config {
        authentication_mode                         = "API_AND_CONFIG_MAP"
        bootstrap_cluster_creator_admin_permissions = true
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy,
    ]
}

# ── EBS CSI Driver IRSA ──────────────────────────────────────────────────────

resource "aws_iam_role" "ebs_csi" {
    name = "${var.cluster_name}-ebs-csi-role"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-ebs-csi-role" })

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
                    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
                    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
                }
            }
        }]
    })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
    role       = aws_iam_role.ebs_csi.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EBS CSI Driver Addon ─────────────────────────────────────────────────────

resource "aws_eks_addon" "ebs_csi" {
    cluster_name             = aws_eks_cluster.main.name
    addon_name               = "aws-ebs-csi-driver"
    service_account_role_arn = aws_iam_role.ebs_csi.arn

    depends_on = [
        aws_iam_role_policy_attachment.ebs_csi,
    ]
}

# ── Jenkins EKS Access ───────────────────────────────────────────────────────

resource "aws_eks_access_entry" "jenkins_agent" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = aws_iam_role.jenkins_agent.arn
    type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_agent" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = aws_iam_role.jenkins_agent.arn
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
        type = "cluster"
    }
}

resource "aws_eks_access_entry" "jenkins" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-role"
    type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-role"
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
        type = "cluster"
    }
}

# ── OIDC Provider（IRSA 前提）────────────────────────────────────────────────

data "tls_certificate" "eks" {
    url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
    url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
    client_id_list  = ["sts.amazonaws.com"]
    thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
    tags            = merge(local.common_tags, { Name = "${var.cluster_name}-oidc" })
}
