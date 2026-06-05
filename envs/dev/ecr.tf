locals {
  ecr_repositories = toset([
    "auth-service",
    "frontend",
    "order-service",
    "wallet-service",
    "marketdata-service",
  ])
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name = "mock-trading-platform/${each.key}"

  # dev 환경: latest 태그 덮어쓰기를 허용해 반복 배포가 쉽도록 MUTABLE.
  # 프로덕션에서는 IMMUTABLE + sha 태그 전략으로 전환할 것.
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
