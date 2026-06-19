# mock-trading-platform-infra

**AWS EKS 기반 Mock Trading Platform 아키텍처**의 인프라 리포지토리. Terraform으로 VPC · EKS · IAM · ECR 등 AWS 리소스를 IaC로 관리합니다.

이 리포는 3개 리포 중 하나로, 클러스터·네트워크·권한 기반을 책임집니다.

## 책임 범위

이 리포가 관리하는 것:

- VPC, subnet, routing
- EKS cluster, managed node group
- ECR repositories
- IAM roles (cluster, node, ALB controller IRSA)
- ALB controller IAM policy (IRSA role + 권한)
- GitHub Actions OIDC provider + IAM role (mock-trading-platform-app → ECR push)

이 리포가 관리하지 않는 것:

- 애플리케이션 코드, Helm chart → `mock-trading-platform-app`
- ArgoCD application 정의, ALB controller Helm 설치 → `mock-trading-platform-gitops`

## 구조

```
envs/dev/
├── providers.tf        # Terraform/provider 버전, provider 설정
├── backend.hcl         # remote backend(S3 + DynamoDB lock) 설정값
├── variables.tf        # 입력 변수 정의
├── terraform.tfvars    # dev 환경 실제 값
├── vpc.tf              # VPC, subnet, IGW, NAT Gateway, route table
├── iam.tf              # EKS cluster/node IAM role, ALB controller IRSA, GitHub Actions OIDC
├── eks.tf              # EKS cluster, OIDC provider, node group, add-ons
├── ecr.tf              # ECR repositories, lifecycle policy
├── storage.tf          # gp2 StorageClass 기본 클래스 annotation
├── alb_policy.json     # AWS Load Balancer Controller IAM policy (v2.7+)
└── outputs.tf          # downstream에서 사용할 output 값
```

## 생성되는 리소스

| 카테고리    | 리소스                                                                                                                                   |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Networking  | VPC, public subnet x2, private subnet x2, IGW, NAT GW x1, EIP, route table x2                                                            |
| EKS         | Cluster (Kubernetes 1.35), managed node group (t3.medium, desired=3 / min=1 / max=4), OIDC provider                                      |
| EKS Add-ons | vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver (IRSA 연결)                                                                             |
| ECR         | auth-service, frontend, order-service, wallet-service, marketdata-service                                                                |
| IAM         | Cluster role, node role, ALB controller IRSA role + policy                                                                               |
| GitHub OIDC | `token.actions.githubusercontent.com` OIDC provider, mock-trading-platform-app 전용 role (ECR push 권한, main 브랜치 + `v*` 태그로 제한) |

## Outputs

`terraform output`으로 확인 가능한 값 목록. downstream 리포에서 이 값들을 사용한다.

| Output                          | 설명                                                                | 소비자                                                                          |
| ------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `cluster_name`                  | EKS 클러스터 이름                                                   | mock-trading-platform-gitops                                                    |
| `cluster_endpoint`              | EKS API 서버 엔드포인트                                             | mock-trading-platform-gitops                                                    |
| `cluster_certificate_authority` | EKS CA 인증서 (base64)                                              | mock-trading-platform-gitops                                                    |
| `oidc_provider_arn`             | IRSA용 OIDC provider ARN                                            | mock-trading-platform-infra (추가 IRSA role 생성 시)                            |
| `oidc_issuer`                   | OIDC issuer URL                                                     | mock-trading-platform-infra (추가 IRSA role 생성 시)                            |
| `node_role_arn`                 | 노드 그룹 IAM role ARN                                              | 참조용                                                                          |
| `alb_controller_role_arn`       | ALB controller ServiceAccount annotation용 role ARN                 | mock-trading-platform-gitops                                                    |
| `ebs_csi_role_arn`              | aws-ebs-csi-driver IRSA role ARN                                    | 참조용 (addon이 직접 wiring)                                                    |
| `github_actions_role_arn`       | mock-trading-platform-app GitHub Actions가 OIDC로 assume할 role ARN | mock-trading-platform-app (`AWS_ROLE_ARN` variable)                             |
| `vpc_id`                        | VPC ID                                                              | 디버깅, ALB controller 설정                                                     |
| `public_subnet_ids`             | Public subnet ID 목록                                               | mock-trading-platform-gitops (ALB/Ingress)                                      |
| `private_subnet_ids`            | Private subnet ID 목록                                              | mock-trading-platform-gitops (internal 서비스)                                  |
| `ecr_repository_urls`           | 서비스별 ECR repository URL map                                     | mock-trading-platform-app (GitHub Actions)                                      |
| `account_id`                    | AWS 계정 ID                                                         | mock-trading-platform-app (`AWS_ACCOUNT_ID` variable)                           |
| `region`                        | AWS 리전                                                            | mock-trading-platform-app (`AWS_REGION` variable), mock-trading-platform-gitops |
| `kubeconfig_command`            | kubectl 설정 명령어                                                 | 수동 작업 시                                                                    |

## Prerequisites

- AWS CLI 설정 완료 (`aws configure` 또는 환경변수)
- Terraform >= 1.5
- kubectl

## Apply 순서

1. bootstrap (local state)

```bash
cd bootstrap
terraform init
terraform apply
```

2. bootstrap output 확인

```bash
terraform output tfstate_bucket_name
terraform output tflock_table_name
terraform output region
```

2.5) auth-jwt 시크릿 값 주입 (최초 1회 / 회전 시)

bootstrap apply는 `mock-trading-platform/dev/auth-jwt` **빈 컨테이너**만 만든다. 실제 값은
out-of-band로 주입한다 (실값이 커밋되는 bootstrap tfstate에 남지 않도록 의도).
ESO의 ExternalSecret이 property `JWT_SECRET`을 읽으므로 JSON 키를 맞춘다.

```bash
# 강키 생성 (256-bit hex) 후 주입. auth-service / order-service가 같은 값을 공유한다.
JWT=$(openssl rand -hex 32)
aws secretsmanager put-secret-value \
  --region "$(terraform output -raw region)" \
  --secret-id "$(terraform output -raw auth_jwt_secret_name)" \
  --secret-string "{\"JWT_SECRET\":\"$JWT\"}"
```

> 이 단계 없이 ESO를 켜면 ExternalSecret이 `SecretSyncedError`(버전 없음)로 멈춘다.
> 값 주입은 envs/dev·gitops가 올라오기 전 아무 때나 해도 된다.

3. `envs/dev/backend.hcl` 값 반영

- `bucket`: `tfstate_bucket_name` 값으로 치환 (플레이스홀더 `<aws-account-id>`를 실제 12자리 AWS 계정 ID로 교체)
- `dynamodb_table`: `tflock_table_name` 값과 일치 확인
- `region`: `region` 값과 일치 확인

계정 ID는 `aws sts get-caller-identity --query Account --output text`로 확인 가능.

4. envs/dev remote backend 초기화

```bash
cd ../envs/dev
terraform init -backend-config=backend.hcl
```

5. 계획/적용

```bash
terraform plan
terraform apply
```

apply 완료 후 kubeconfig 설정:

```bash
# terraform output에서 직접 복사하거나:
aws eks update-kubeconfig --region ap-northeast-2 --name mock-trading-platform-dev
kubectl get nodes
```

## 기존 apply 이후 변경사항 반영하기

이미 step 5까지 완료한 상태에서 Terraform 코드가 변경되었다면 (예: GitHub Actions
OIDC role 추가), state는 그대로 두고 증분 apply만 수행한다.

```bash
cd envs/dev

# 변경된 코드 pull (또는 로컬에서 수정)
git pull

# plan으로 추가/변경되는 리소스 확인
terraform plan

# Plan 출력에서 "to add" 항목만 있고 "to destroy"가 없는지 확인 후 apply
terraform apply
```

### GitHub Actions OIDC role 추가 시 예상 plan

다음 5개 리소스가 새로 추가되어야 한다. VPC/EKS/ECR 기존 리소스는 건드리지 않음.

```
+ data.tls_certificate.github_oidc
+ aws_iam_openid_connect_provider.github
+ aws_iam_role.github_actions_app
+ aws_iam_role_policy.github_actions_app_ecr_push
```

apply 후 새 output을 확인:

```bash
terraform output github_actions_role_arn
terraform output account_id
terraform output region
```

### mock-trading-platform-app 레포에 Variables 등록

위 output 값을 GitHub 레포 Settings → Secrets and variables → Actions →
**Variables** 탭에 등록한다. Secrets가 아니라 Variables다 (ARN은 비밀 아님).

| Variable 이름    | 값 소스                                    |
| ---------------- | ------------------------------------------ |
| `AWS_ACCOUNT_ID` | `terraform output account_id`              |
| `AWS_ROLE_ARN`   | `terraform output github_actions_role_arn` |
| `AWS_REGION`     | `terraform output region`                  |

등록 후 mock-trading-platform-app의 main 브랜치나 `v*` 태그에 푸시하면 CI가 ECR push까지
진행한다. PR 빌드는 OIDC trust policy에서 제외되어 있으므로 test/build까지만
실행된다.

## Troubleshooting

### `EntityAlreadyExists` — GitHub OIDC provider가 이미 계정에 존재

`terraform apply` 시 아래 에러가 발생하는 경우:

```
Error: creating IAM OIDC Provider: EntityAlreadyExists:
Provider with url https://token.actions.githubusercontent.com already exists.
```

**원인**: IAM OIDC provider는 issuer URL당 **AWS 계정 내 1개**만 허용된다.
이전에 다른 Terraform 스택, 다른 레포, 혹은 콘솔에서 수동으로 이미 등록했을
가능성이 있다. 한 계정을 여러 GitHub 레포가 공유하는 경우 흔히 발생한다.

**해결**: 기존 provider를 현재 Terraform state로 import한다. 새로 만드는 게
아니라 "이미 있는 걸 내 state 관리 하에 둔다"는 의미다.

```bash
# 1. 계정 ID 확인
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 2. import
cd envs/dev
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com

# 3. drift 확인 (thumbprint, client_id_list 등)
terraform plan

# 4. drift가 없으면 완료. 있으면 apply로 Terraform 정의에 맞춤
terraform apply
```

**주의**: import한 provider를 다른 시스템도 사용 중이라면 `client_id_list`나
`thumbprint_list`를 변경하기 전에 해당 시스템에 미치는 영향을 먼저 확인할 것.

### `InvalidBucketName` — backend.hcl 플레이스홀더 미치환

`terraform init -backend-config=backend.hcl` 시 아래 에러:

```
Error: Failed to get existing workspaces: ... InvalidBucketName:
The specified bucket is not valid.
```

`backend.hcl`의 `<aws-account-id>` 플레이스홀더가 실제 계정 ID로 치환되지 않은
상태다. Apply 순서 step 3을 참조해 실제 12자리 계정 ID로 치환 후 재실행한다.

### `Backend configuration changed` — 이전 init 캐시와 불일치

`destroy` 후 재init이나 backend 값 변경 시:

```
Error: Backend configuration changed
```

이전 state를 보존할 필요가 없으면 `-reconfigure` 플래그로 재초기화한다.

```bash
terraform init -backend-config=backend.hcl -reconfigure
```

이전 state를 새 백엔드로 옮겨야 한다면 `-migrate-state`를 쓴다.

### `dynamodb_table is deprecated` 경고

Terraform 1.10+에서 S3 네이티브 locking(`use_lockfile = true`)이 추가되며
`dynamodb_table` 파라미터가 deprecated 되었다. 현 설정은 여전히 동작하므로
당장 대응할 필요는 없다. 전환할 경우 `backend.hcl`에서 `dynamodb_table` 제거 후
`use_lockfile = true` 추가 → `terraform init -backend-config=backend.hcl -reconfigure`.
기존 DynamoDB lock table은 수동으로 삭제한다.

## Destroy 주의사항

EKS 위에 LoadBalancer type Service나 Ingress가 존재하면 AWS 리소스(ALB, NLB 등)가
Terraform 외부에서 생성된 상태이므로, `terraform destroy`만으로는 삭제되지 않는다.
반드시 아래 순서로 정리한 후 destroy를 실행한다.

### 1. ArgoCD 앱 삭제 (Ingress/ALB 리소스 정리)

ArgoCD가 관리하는 Application을 먼저 삭제해야 ALB/NLB가 정리된다.

```bash
kubectl delete applications --all -n argocd

# Ingress와 LoadBalancer가 남아있는지 확인
kubectl get ingress -A
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Application에 finalizer가 걸려 삭제가 멈추면:

```bash
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"metadata":{"finalizers":null}}'
```

### 2. ArgoCD 자체 삭제

```bash
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

### 3. Terraform destroy

```bash
# 리포 루트에서 실행하는 경우
cd envs/dev
terraform destroy

# Apply 절차를 따라 이미 envs/dev에 있는 경우
terraform destroy
```

### 4. Bootstrap 삭제 (선택)

tfstate bucket과 lock table까지 완전히 정리하려면:

```bash
# 리포 루트에서 실행하는 경우
cd bootstrap
terraform destroy

# step 3에서 이어서 실행하는 경우 (현재 경로: envs/dev)
cd ../../bootstrap
terraform destroy
```

S3 bucket에 versioning이 켜져 있으므로, 오브젝트 버전이 남아 destroy가 실패할 수 있다.
이 경우 AWS 콘솔에서 "모든 버전 영구 삭제" 후 다시 실행한다.

### 참고

- ECR repository는 `force_delete = true`이므로 step 3에서 이미지 포함 자동 삭제된다.
- NAT Gateway, EIP 등 Terraform 관리 리소스는 step 3에서 정리된다.
- **ALB/NLB만** Terraform 외부 생성이므로 반드시 step 1에서 먼저 제거해야 한다.

## 비용 주의사항

주요 비용 드라이버:

| 항목                           | 특성                                  |
| ------------------------------ | ------------------------------------- |
| **EKS control plane**          | 클러스터가 존재하는 동안 시간당 과금  |
| **NAT Gateway**                | 시간당 과금 + 데이터 처리량 비례 과금 |
| **EC2 instances (node group)** | 인스턴스 수와 타입에 따라 시간당 과금 |

- 정확한 비용은 [AWS Pricing Calculator](https://calculator.aws/)로 산정할 것
- 사용하지 않을 때는 `terraform destroy`로 전체 삭제 권장
- NAT Gateway는 단일 AZ에만 배치 (비용 절감, dev 환경이므로 HA 불필요)
- `cluster_version` 변수로 EKS 버전을 관리한다. dev 환경은 1.35를 사용하며, EKS standard support 기간(마이너 버전당 약 14개월) 내 유지가 원칙이다. Extended Support 구간으로 넘어가면 클러스터당 시간당 약 $0.60의 추가 요금이 붙으므로, 비용 측면에서 standard support 기간 내 업그레이드가 중요하다.

## ALB Controller 부트스트랩

이 리포는 ALB controller가 동작하기 위한 **IAM 기반**을 제공한다.

### 이 리포에서 완료된 것

1. IRSA trust policy — `kube-system:aws-load-balancer-controller` ServiceAccount에 대한 assume role 허용
2. IAM policy — ALB/NLB 생성·관리에 필요한 AWS API 권한 (`alb_policy.json`, v2.7+ 기준)
3. Subnet tagging — `kubernetes.io/role/elb` (public), `kubernetes.io/role/internal-elb` (private)

### mock-trading-platform-gitops에서 해야 할 것

Helm으로 AWS Load Balancer Controller를 설치할 때 아래 값을 사용:

```yaml
# Helm values 예시
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: <alb_controller_role_arn> # terraform output 참조

clusterName: <cluster_name> # terraform output 참조
region: <region> # terraform output 참조
vpcId: <vpc_id> # terraform output 참조
```

공식 Helm chart: https://kubernetes-sigs.github.io/aws-load-balancer-controller

### IAM policy 업데이트

ALB controller 버전을 올릴 때 IAM policy도 함께 확인해야 한다.
공식 정책: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

## 스토리지 부트스트랩

PVC가 별도 `storageClassName` 없이도 EBS 볼륨에 바인딩되도록 EBS CSI 드라이버
설치와 기본 StorageClass 지정까지 이 리포에서 마친다.

### 이 리포에서 완료된 것

1. `aws-ebs-csi-driver` EKS add-on 설치 (`eks.tf`)
2. EBS CSI용 IRSA role — `kube-system:ebs-csi-controller-sa` trust + AWS 관리형
   `AmazonEBSCSIDriverPolicy` attach. addon 리소스의 `service_account_role_arn`에
   직접 wiring되어 별도 ServiceAccount annotation 작업이 필요 없다.
3. EKS가 자동 생성하는 `gp2` StorageClass에 기본 클래스 annotation 부착 (`storage.tf`):
   - `storageclass.kubernetes.io/is-default-class=true`
   - StorageClass 객체 자체는 EKS가 소유하므로 `kubernetes_storage_class`로
     재생성하지 않고, `kubernetes_annotations` 리소스로 annotation만 관리한다
     (`force = true`로 다른 컨트롤러가 덮어써도 재적용).

### mock-trading-platform-gitops에서 해야 할 것

별도 작업 없음. PVC가 `storageClassName`을 명시하지 않으면 자동으로 gp2에
바인딩된다. 다른 StorageClass를 기본으로 두고 싶다면 `storage.tf`의
`kubernetes_annotations.gp2_default`를 제거하고 새 StorageClass에 동일 annotation을
부여한다.

## GitHub Actions OIDC 부트스트랩

이 리포는 mock-trading-platform-app이 ECR로 이미지를 푸시할 수 있도록 **OIDC 신뢰 관계와
IAM role**을 제공한다.

### 이 리포에서 완료된 것

1. GitHub OIDC provider (`token.actions.githubusercontent.com`) — AWS 계정에 등록
2. IAM role (`<cluster_name>-github-actions-app`) — trust policy로 다음만 허용:
   - `repo:banhae/mock-trading-platform-app:ref:refs/heads/main`
   - `repo:banhae/mock-trading-platform-app:ref:refs/tags/v*`
3. ECR push inline policy — `mock-trading-platform/*` 리포지토리로만 스코프 제한

### mock-trading-platform-app에서 해야 할 것

- Repository Variables 3개 등록 (위 "Variables 등록" 섹션 참조)
- 워크플로에 `permissions: id-token: write` 설정 (`ci.yaml`에 이미 포함됨)
- `aws-actions/configure-aws-credentials@v4`에 `role-to-assume: ${{ vars.AWS_ROLE_ARN }}` 전달

### Trust policy 확장이 필요한 경우

다른 브랜치(예: `develop`)에서도 ECR push가 필요해지면 `iam.tf`의
`github_actions_app_assume` data source의 `sub` 조건에 추가한다:

```hcl
values = [
  "repo:banhae/mock-trading-platform-app:ref:refs/heads/main",
  "repo:banhae/mock-trading-platform-app:ref:refs/heads/develop",  # 추가
  "repo:banhae/mock-trading-platform-app:ref:refs/tags/v*",
]
```

## Observability Integration

이 리포는 관측성 스택의 **인프라 기반**만 제공하고, 실제 Prometheus / Grafana /
Loki 배포는 `mock-trading-platform-gitops` 에서 ArgoCD 로 관리한다. 책임 분리는 다음과 같다.

### 이 리포에서 완료된 것

1. EKS 클러스터 자체 (Prometheus / Grafana 가 동작하는 컴퓨트 기반)
2. EBS CSI 드라이버 + 기본 gp2 StorageClass — Prometheus TSDB / Grafana persistence
   PVC 가 별도 설정 없이 바인딩됨
3. 노드 그룹 사이즈 (t3.medium x 3) — kube-prometheus-stack + loki 가
   기본값으로 안착 가능한 최소 리소스
4. IRSA 트러스트 패턴 — 향후 Grafana → CloudWatch / Amazon Managed Prometheus
   연동 시 동일 패턴(`module-style`)을 그대로 재사용 가능

### mock-trading-platform-gitops에서 해야 할 것

- `argocd/applications/dev/kube-prometheus-stack.yaml` (sync-wave 5) — Prometheus
  - Grafana CRD 설치
- `argocd/applications/dev/loki.yaml` (sync-wave 5) — 로그 집계
- `argocd/applications/dev/mock-trading-platform-monitoring.yaml` (sync-wave 6) — mock-trading-platform 도메인
  PodMonitor / PrometheusRule / Grafana 대시보드

### 향후 확장 시 이 리포에서 추가할 것 (현재 단계 아님)

| 확장                                | 추가 리소스                                                  |
| ----------------------------------- | ------------------------------------------------------------ |
| Amazon Managed Prometheus 원격 쓰기 | AMP workspace + IRSA role for prometheus SA                  |
| Amazon Managed Grafana              | AMG workspace + IAM SAML/SSO trust                           |
| CloudWatch Logs 백업                | IRSA role for fluent-bit / vector + Logs put policy          |
| ALB access log → S3                 | S3 bucket + ALB attribute 설정 (현재 ALB 자체는 gitops 관리) |

학습용 dev 단계에서는 클러스터 내부 Prometheus / Grafana / Loki 만으로 충분.

## 다음 단계

이 리포의 인프라 적용이 완료되면 아래 순서로 진행한다.

1. **mock-trading-platform-app** — ECR에 서비스 이미지 푸시
   - Repository Variables(`AWS_ACCOUNT_ID`, `AWS_ROLE_ARN`, `AWS_REGION`) 등록 후 main/`v*` push
   - 대상: auth-service, order-service, wallet-service, marketdata-service, frontend

2. **mock-trading-platform-gitops** — 플레이스홀더 치환 후 ArgoCD 배포
   - `terraform output` 값으로 `.env` 작성 → `./scripts/bootstrap-values.sh` 실행
   - ArgoCD 설치 → root-app 적용 → sync 확인
   - 상세 절차는 mock-trading-platform-gitops README의 Bootstrap 절차 참조
