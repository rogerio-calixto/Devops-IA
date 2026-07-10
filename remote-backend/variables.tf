variable "project" {
  description = "Configuração do projeto/ambiente, usada em tags e nomes de recursos em toda a stack."
  type = object({
    name        = string
    environment = string
    aws_region  = string
  })
  nullable = false
}

variable "state_bucket" {
  description = "Configuração do bucket S3 usado como backend remoto de state Terraform, compartilhado por todas as stacks deste repositório."
  type = object({
    name                               = string
    force_destroy                      = bool
    noncurrent_version_expiration_days = number
  })
  nullable = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket.name))
    error_message = "state_bucket.name deve seguir as regras de nomenclatura de bucket S3: minúsculas, dígitos, hífens e pontos, entre 3 e 63 caracteres, começando e terminando com letra ou dígito."
  }

  validation {
    condition     = var.state_bucket.noncurrent_version_expiration_days > 0
    error_message = "state_bucket.noncurrent_version_expiration_days deve ser um inteiro positivo."
  }
}
