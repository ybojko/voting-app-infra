terraform {
  backend "s3" {
    bucket         = "voting-app-terraform-state-179686849870"
    key            = "eks/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
