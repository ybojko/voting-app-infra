provider "aws" {
  region = var.region
}

# --- VPC (публічний модуль Бабенка) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# --- EKS (публічний модуль Бабенка) ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  # Дозволити публічний доступ до API (для навчання)
  cluster_endpoint_public_access = true

  # Дозволити creator admin доступ
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 5
      desired_size   = 4
      instance_types = ["t3.small"]
    }
  }

  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

# --- IAM Role for AWS Load Balancer Controller (IRSA) ---
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# --- IAM Role for External Secrets Operator (IRSA) ---
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                     = "${var.cluster_name}-eso"
  attach_external_secrets_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# --- AWS Secrets Manager ---
resource "aws_secretsmanager_secret" "postgres_password" {
  name = "${var.cluster_name}-postgres-password"
  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

resource "aws_secretsmanager_secret_version" "postgres_password" {
  secret_id     = aws_secretsmanager_secret.postgres_password.id
  secret_string = var.postgres_password
}

resource "aws_secretsmanager_secret" "cloudflare_api_token" {
  name = "${var.cluster_name}-cloudflare-api-token"
  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

resource "aws_secretsmanager_secret_version" "cloudflare_api_token" {
  secret_id     = aws_secretsmanager_secret.cloudflare_api_token.id
  secret_string = var.cloudflare_api_token
}

resource "aws_secretsmanager_secret" "github_token" {
  name = "${var.cluster_name}-github-token"
  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

resource "aws_secretsmanager_secret_version" "github_token" {
  secret_id     = aws_secretsmanager_secret.github_token.id
  secret_string = var.github_token
}

resource "aws_secretsmanager_secret" "grafana_oauth_client_secret" {
  name = "${var.cluster_name}-grafana-oauth-client-secret"
  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

resource "aws_secretsmanager_secret_version" "grafana_oauth_client_secret" {
  secret_id     = aws_secretsmanager_secret.grafana_oauth_client_secret.id
  secret_string = var.grafana_oauth_client_secret
}

# --- Attach ECR read-only policy to node IAM role ---
data "aws_iam_role" "eks_node_role" {
  name = module.eks.eks_managed_node_groups["default"].iam_role_name
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr_readonly" {
  role       = data.aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- GitHub OIDC Identity Provider ---
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- IAM Role for GitHub Actions ECR Push (OIDC) ---
resource "aws_iam_role" "github_actions_ecr_push" {
  name               = "github-actions-ecr-push"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub": "repo:ybojko/voting-app-*"
          }
        }
      }
    ]
  })

  tags = {
    Environment = "dev"
    Project     = "voting-app"
  }
}

# --- ECR Push Policy for GitHub Actions ---
resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name   = "ecr-push-policy"
  role   = aws_iam_role.github_actions_ecr_push.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = [
          for repo in module.ecr.repository_arns : "${repo}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- ВЛАСНИЙ МОДУЛЬ: ECR repositories ---
module "ecr" {
  source = "./modules/ecr"

  repositories = ["voting-app-vote", "voting-app-result", "voting-app-worker"]
  environment  = "dev"
}
