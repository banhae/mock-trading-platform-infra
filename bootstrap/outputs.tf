output "tfstate_bucket_name" {
  description = "Terraform remote state S3 bucket name (includes AWS account ID)"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tflock_table_name" {
  description = "Terraform state lock DynamoDB table name"
  value       = aws_dynamodb_table.tflock.name
}

output "region" {
  description = "AWS region used for bootstrap resources"
  value       = var.region
}

output "auth_jwt_secret_name" {
  description = "Secrets Manager secret name for the auth/order JWT secret (use with put-secret-value)"
  value       = aws_secretsmanager_secret.auth_jwt.name
}

output "auth_jwt_secret_arn" {
  description = "Secrets Manager secret ARN for the auth/order JWT secret"
  value       = aws_secretsmanager_secret.auth_jwt.arn
}
