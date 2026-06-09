output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (IRSA)"
  value       = module.lb_controller_irsa.iam_role_arn
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN (for IRSA roles)"
  value       = module.eks.oidc_provider_arn
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator (IRSA)"
  value       = module.eso_irsa.iam_role_arn
}

output "postgres_secret_arn" {
  description = "ARN of the PostgreSQL password secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.postgres_password.arn
}

output "cloudflare_api_token_secret_arn" {
  description = "ARN of the Cloudflare API token secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.cloudflare_api_token.arn
}

output "github_token_secret_arn" {
  description = "ARN of the GitHub token secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.github_token.arn
}

output "grafana_oauth_client_secret_arn" {
  description = "ARN of the Grafana OAuth client secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.grafana_oauth_client_secret.arn
}
