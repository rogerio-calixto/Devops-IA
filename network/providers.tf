provider "aws" {
  region = var.project.aws_region

  default_tags {
    tags = {
      Project     = var.project.name
      Environment = var.project.environment
      ManagedBy   = "terraform"
      Repository  = "Devops-IA"
    }
  }
}
