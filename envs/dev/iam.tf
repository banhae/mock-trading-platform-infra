# -----------------------------------------------------------------------------
# EKS Cluster Role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# EKS Node Role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# -----------------------------------------------------------------------------
# ALB Controller IRSA Role + Policy
#
# Trust policy: kube-system:aws-load-balancer-controller SA만 assume 가능
# IAM policy: alb_policy.json (AWS LB Controller v2.7+ 공식 정책 기준)
# Helm 설치는 mock-trading-platform-gitops에서 수행한다.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = file("${path.module}/alb_policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# -----------------------------------------------------------------------------
# EBS CSI Driver IRSA Role
#
# Trust policy: kube-system:ebs-csi-controller-sa만 assume 가능.
# aws-ebs-csi-driver addon이 PVC ↔ EBS 볼륨 프로비저닝할 때 사용한다.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC Provider
#
# GitHub의 OIDC issuer를 AWS에 등록하여 sts:AssumeRoleWithWebIdentity 가능하게 함.
# EKS용 OIDC provider(aws_iam_openid_connect_provider.eks)와는 별개의 리소스.
# 계정당 1개만 존재하면 됨 (여러 레포가 공유 가능).
#
# thumbprint는 tls_certificate data source로 동적으로 가져온다.
# AWS는 well-known GitHub OIDC provider에 대해 실제로는 thumbprint 검증을
# 스킵하지만, 공식 문서가 여전히 thumbprint_list를 요구하므로 제공한다.
# -----------------------------------------------------------------------------

data "tls_certificate" "github_oidc" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
}

# -----------------------------------------------------------------------------
# GitHub Actions Role (mock-trading-platform-app → ECR push)
#
# Trust policy는 banhae/mock-trading-platform-app 레포의 다음 워크플로 컨텍스트만 허용:
#   - main 브랜치 push
#   - v* 태그 push
# PR 빌드는 ECR push가 필요 없으므로 trust policy에서 제외한다.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_actions_app_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:banhae/mock-trading-platform-app:ref:refs/heads/main",
        "repo:banhae/mock-trading-platform-app:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_app" {
  name               = "${var.cluster_name}-github-actions-app"
  assume_role_policy = data.aws_iam_policy_document.github_actions_app_assume.json
}

# -----------------------------------------------------------------------------
# ECR push policy (mock-trading-platform/* 리포지토리로 한정)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "ECRAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "ECRPushToMockTradingPlatformRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/mock-trading-platform/*",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_app_ecr_push" {
  name   = "${var.cluster_name}-github-actions-app-ecr-push"
  role   = aws_iam_role.github_actions_app.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
