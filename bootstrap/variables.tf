variable "region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Project name prefix used in resource naming"
  type        = string
  default     = "mock-trading-platform"
}

variable "environment" {
  description = "Environment name used in resource naming"
  type        = string
  default     = "dev"
}
