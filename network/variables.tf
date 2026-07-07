variable "project" {
  description = "Configuração do projeto/ambiente, usada em tags e nomes de recursos em toda a stack."
  type = object({
    name        = string
    environment = string
    aws_region  = string
  })
  nullable = false
}

variable "vpc" {
  description = "Configuração da VPC."
  type = object({
    cidr_block           = string
    enable_dns_support   = bool
    enable_dns_hostnames = bool
  })
  nullable = false

  validation {
    condition     = can(cidrhost(var.vpc.cidr_block, 0))
    error_message = "vpc.cidr_block deve ser um bloco CIDR IPv4 válido."
  }
}
