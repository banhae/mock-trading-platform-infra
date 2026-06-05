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
