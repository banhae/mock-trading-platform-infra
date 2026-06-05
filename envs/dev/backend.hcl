bucket         = "mock-trading-platform-dev-<aws-account-id>-tfstate"
key            = "envs/dev/terraform.tfstate"
region         = "ap-northeast-2"
dynamodb_table = "mock-trading-platform-dev-tflock"
encrypt        = true
