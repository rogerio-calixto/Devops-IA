terraform {
  required_version = ">= 1.9.0" # confirmado em 2026-07-10: terraform version no executor = v1.15.5 (acima do mínimo exigido)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54.0" # validado via MCP Terraform: hashicorp/aws latest = 6.54.0
    }
  }

  # Nenhum bloco `backend` é declarado propositalmente nesta stack. Esta é a
  # própria stack que cria o backend remoto de state usado por outras stacks
  # do repositório — ela não pode depender de si mesma (bootstrap). O state
  # desta stack permanece local para sempre, ou até uma futura reestruturação
  # de "bootstrap do bootstrap" (não recomendada, fora de escopo). Ver ADR-004.
}
