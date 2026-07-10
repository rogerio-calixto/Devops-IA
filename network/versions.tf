terraform {
  # Elevado de ">= 1.9.0" para ">= 1.11.0" nesta ADR-005: use_lockfile (locking
  # nativo do backend s3, sem DynamoDB) exige Terraform CLI >= 1.11.0. Executor
  # confirmado em v1.15.5 (2026-07-10) — acima do novo mínimo. Se a stack for
  # operada por um executor diferente no futuro, reconfirmar `terraform version`
  # antes de qualquer plan/apply (mesma ressalva já registrada no ADR-004).
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.53.0" # inalterado nesta ADR — sem necessidade de upgrade de provider
    }
  }

  # Backend remoto de state, criado e aplicado pela stack `remote-backend/`
  # (ADR-004). Bucket único compartilhado por todas as stacks do repositório,
  # diferenciadas pela `key` do objeto (ver ADR-004, "Decisão").
  #
  # ATENÇÃO: blocos `backend` não aceitam interpolação de variáveis (var.*,
  # local.*) — é uma limitação arquitetural do Terraform core (o backend é
  # processado antes do motor de interpolação estar disponível). Os valores
  # abaixo são literais fixos, deliberadamente, não uma violação da convenção
  # do projeto de evitar hardcode (ver Premissa #13 do ADR-005).
  backend "s3" {
    bucket       = "devops-ia-tfstate-508591324807-us-east-1"
    key          = "network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    # Sem dynamodb_table — decisão já tomada no ADR-004 (locking nativo via
    # use_lockfile, caminho recomendado pela HashiCorp; dynamodb_table está
    # oficialmente deprecado).
  }
}
