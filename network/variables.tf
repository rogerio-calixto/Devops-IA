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
  description = "Configuração da VPC e das subnets públicas/privadas associadas."
  type = object({
    cidr_block           = string
    enable_dns_support   = bool
    enable_dns_hostnames = bool
    public_subnets = list(object({
      name              = string
      cidr_block        = string
      availability_zone = string
    }))
    private_subnets = list(object({
      name              = string
      cidr_block        = string
      availability_zone = string
    }))
  })
  nullable = false

  validation {
    condition     = can(cidrhost(var.vpc.cidr_block, 0))
    error_message = "vpc.cidr_block deve ser um bloco CIDR IPv4 válido."
  }

  validation {
    condition     = length(var.vpc.public_subnets) > 0 && length(var.vpc.private_subnets) > 0
    error_message = "vpc.public_subnets e vpc.private_subnets devem conter ao menos 1 elemento cada."
  }

  validation {
    condition = alltrue([
      for s in concat(var.vpc.public_subnets, var.vpc.private_subnets) : can(cidrhost(s.cidr_block, 0))
    ])
    error_message = "Todo cidr_block de subnet (pública ou privada) deve ser um bloco CIDR IPv4 válido."
  }
}

variable "nat_gateway" {
  description = "Configuração do NAT Gateway compartilhado usado para saída de internet das subnets privadas. Recurso com custo mensal recorrente real — ver ADR-002."
  type = object({
    enabled = bool
  })
  nullable = false
}
