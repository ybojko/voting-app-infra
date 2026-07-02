provider "aws" {
  region = var.region
}

# --- Helm + Kubernetes provider (використовує EKS endpoint) ---
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    command     = "aws"
  }
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

# =============================================================================
# POST-EKS: Add-ons, Security, Gateway, ArgoCD — все автоматично
# =============================================================================

# --- EBS CSI Driver ---
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-ebs-csi-driver"

  depends_on = [module.eks.eks_managed_node_groups]
}

# --- AmazonEBSCSIDriverPolicy on node IAM role ---
resource "aws_iam_role_policy_attachment" "eks_node_ebs_csi" {
  role       = data.aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

  depends_on = [module.eks.eks_managed_node_groups]
}

# --- Cross-node Security Group self-reference ---
resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id = module.eks.node_security_group_id

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "-1"

  depends_on = [module.eks.eks_managed_node_groups]
}

# --- Wait for EKS to be fully ready before Helm/K8s ---
resource "time_sleep" "eks_wait" {
  depends_on = [
    module.eks,
    aws_eks_addon.ebs_csi,
    aws_iam_role_policy_attachment.eks_node_ebs_csi,
    aws_vpc_security_group_ingress_rule.node_self,
  ]

  create_duration = "60s"
}

# --- Gateway API CRDs ---
resource "null_resource" "gateway_crds" {
  depends_on = [time_sleep.eks_wait]

  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
  }
}

# --- Envoy Gateway ---
resource "helm_release" "envoy_gateway" {
  depends_on = [null_resource.gateway_crds]

  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "1.2.0"
  namespace        = "envoy-gateway"
  create_namespace = true
  skip_crds        = true
}

# --- GatewayClass ---
resource "null_resource" "gatewayclass" {
  depends_on = [helm_release.envoy_gateway]

  provisioner "local-exec" {
    command = "kubectl apply -f - <<EOF\napiVersion: gateway.networking.k8s.io/v1\nkind: GatewayClass\nmetadata:\n  name: eg\nspec:\n  controllerName: gateway.envoyproxy.io/gatewayclass-controller\nEOF\n"
  }
}

# --- ArgoCD ---
resource "helm_release" "argocd" {
  depends_on = [null_resource.gatewayclass]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.23"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "dex.enabled"
    value = "false"
  }
  set {
    name  = "notifications.enabled"
    value = "false"
  }
  set {
    name  = "applicationSet.enabled"
    value = "false"
  }
}

# --- ArgoCD repo secret ---
resource "kubernetes_secret" "repo_gitops" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "repo-voting-app-gitops"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = "https://github.com/ybojko/voting-app-gitops.git"
    username = "ybojko"
    password = var.github_token
  }
}

# --- ArgoCD root-app (App-of-Apps) ---
resource "null_resource" "root_app" {
  depends_on = [kubernetes_secret.repo_gitops]

  provisioner "local-exec" {
    command = "kubectl apply -f - <<EOF\napiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: root-app\n  namespace: argocd\nspec:\n  project: default\n  source:\n    repoURL: https://github.com/ybojko/voting-app-gitops.git\n    targetRevision: master\n    path: apps\n    directory:\n      recurse: true\n      include: '*.yaml'\n      exclude: 'root-app.yaml'\n  destination:\n    server: https://kubernetes.default.svc\n    namespace: argocd\n  syncPolicy:\n    automated:\n      prune: true\n      selfHeal: true\nEOF\n"
  }
}

# --- Pre-create secrets for ESO consumers (avoids race conditions) ---
resource "kubernetes_secret" "postgres_password" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "postgres-password"
    namespace = "voting"
  }

  data = {
    "postgres-password" = var.postgres_password
  }
}

resource "kubernetes_secret" "postgres_password_keycloak" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "postgres-password"
    namespace = "keycloak"
  }

  data = {
    "postgres-password" = var.postgres_password
  }
}

resource "kubernetes_secret" "cloudflare_api_token_kube_system" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "cloudflare-api-token"
    namespace = "kube-system"
  }

  data = {
    cloudflare_api_token = var.cloudflare_api_token
    cloudflare_api_email = "yurkabojko@gmail.com"
  }
}

resource "kubernetes_secret" "cloudflare_api_token_cert_manager" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }
}

resource "kubernetes_secret" "grafana_oauth_creds" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "grafana-oauth-creds"
    namespace = "monitoring"
  }

  data = {
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = var.grafana_oauth_client_secret
  }
}

# --- GHCR pull secret (для приватних image-ів) ---
resource "kubernetes_secret" "ghcr_secret_voting" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "ghcr-secret"
    namespace = "voting"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          auth = base64encode("ybojko:${var.github_token}")
        }
      }
    })
  }
}

resource "kubernetes_secret" "ghcr_secret_keycloak" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "ghcr-secret"
    namespace = "keycloak"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          auth = base64encode("ybojko:${var.github_token}")
        }
      }
    })
  }
}
