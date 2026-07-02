terraform {
  backend "s3" {
    bucket         = "voting-app-terraform-state-522868276919"
    key            = "eks/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "voting-app-terraform-state-522868276919"
    encrypt        = true
  }
}
