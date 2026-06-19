# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  description = "EKS cluster CA certificate (base64)"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

# -----------------------------------------------------------------------------
# IRSA / IAM
# -----------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_issuer" {
  description = "OIDC issuer URL"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  description = "EKS node group IAM role ARN"
  value       = aws_iam_role.eks_node.arn
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller ServiceAccount annotation"
  value       = aws_iam_role.alb_controller.arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for aws-ebs-csi-driver ServiceAccount annotation"
  value       = aws_iam_role.ebs_csi.arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator ServiceAccount annotation (eks.amazonaws.com/role-arn)"
  value       = aws_iam_role.external_secrets.arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN that mock-trading-platform-app GitHub Actions assumes via OIDC to push to ECR"
  value       = aws_iam_role.github_actions_app.arn
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

# -----------------------------------------------------------------------------
# ECR
# -----------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "ECR repository URLs by service name"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

# -----------------------------------------------------------------------------
# Account / Region
# -----------------------------------------------------------------------------

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

# -----------------------------------------------------------------------------
# Convenience
# -----------------------------------------------------------------------------

output "kubeconfig_command" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}
