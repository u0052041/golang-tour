resource "aws_iam_role" "jenkins" {
    name = "jenkins-role"
    tags = merge(local.common_tags, { Name = "jenkins-role" })

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
        Effect = "Allow"
        Principal = {Service = "ec2.amazonaws.com"}
        Action = "sts:AssumeRole"
        }]
    })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
    role       = aws_iam_role.jenkins.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "jenkins_eks" {
    name = "jenkins-eks-policy"
    tags = merge(local.common_tags, { Name = "jenkins-eks-policy" })

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
                Resource = "arn:aws:ssm:*:*:parameter/eks/*"
            },
            {
                Sid    = "EKSAccess"
                Effect = "Allow"
                Action = [
                    "eks:DescribeCluster",
                    "eks:ListClusters"
                ]
                Resource = "*"
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "jenkins_eks" {
    role       = aws_iam_role.jenkins.name
    policy_arn = aws_iam_policy.jenkins_eks.arn
}

resource "aws_iam_role_policy_attachment" "jenkins_ecr" {
    role       = aws_iam_role.jenkins.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_instance_profile" "jenkins" {
    name = "jenkins-profile"
    role = aws_iam_role.jenkins.name
}
