variable "region" {
  default = "eu-central-1"
}

variable "cluster_name" {
  default = "voting-app-eks"
}

variable "cluster_version" {
  default = "1.31"
}

variable "postgres_password" {
  description = "PostgreSQL password stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub personal access token stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
}

variable "grafana_oauth_client_secret" {
  description = "Grafana OAuth client secret (Keycloak) stored in AWS Secrets Manager"
  type        = string
  sensitive   = true
}
