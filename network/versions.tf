terraform {
  required_version = ">= 1.9.0" # A VALIDAR: confirmar versão do binário Terraform instalado no executor (terraform version)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.53.0" # validado via MCP Terraform: hashicorp/aws latest = 6.53.0
    }
  }
}
