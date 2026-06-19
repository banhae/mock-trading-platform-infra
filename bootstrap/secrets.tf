# -----------------------------------------------------------------------------
# Application secrets (빈 컨테이너만 — 실값은 Terraform 밖에서 주입)
#
# ESO(External Secrets Operator)가 읽어 K8s Secret 으로 동기화하는 시크릿.
# 여기서는 빈 컨테이너만 만들고, 실제 값은 Terraform 밖에서 AWS CLI 로 주입한다.
# → 실값이 (이 repo 에 커밋되는) bootstrap tfstate 에 남지 않는다.
# aws_secretsmanager_secret_version 은 의도적으로 만들지 않는다(값 비관리 → drift 없음).
#
# 값 주입(생성/회전): ExternalSecret remoteRef 가 property "JWT_SECRET" 을 읽으므로
# JSON 키를 맞춰야 한다.
#
#   aws secretsmanager put-secret-value \
#     --region <region> --secret-id mock-trading-platform/dev/auth-jwt \
#     --secret-string '{"JWT_SECRET":"<256-bit hex>"}'
#
# bootstrap(영속)에 두는 이유: envs/dev 의 cost-saving destroy 에 영향받지 않음.
# IRSA role(envs/dev/iam.tf, mock-trading-platform-dev-external-secrets-role)이 이 시크릿을
# secretsmanager:GetSecretValue 로 읽을 수 있게 정책 범위(mock-trading-platform/dev/auth-jwt-??????)가
# 이 이름에 맞춰져 있다.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "auth_jwt" {
  name        = "${var.project_name}/${var.environment}/auth-jwt"
  description = "JWT signing/verification secret for auth-service & order-service (consumed via ESO)"

  # dev: 즉시 삭제 허용. 기본 30일 복구창은 동일 이름 재생성 시 friction 을 유발하고,
  # 이 값은 언제든 재생성 가능하므로 복구창을 두지 않는다.
  recovery_window_in_days = 0

  tags = local.common_tags
}
