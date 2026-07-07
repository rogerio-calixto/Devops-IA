variable "aws_region" {
  description = "Regiao AWS onde a stack de rede sera provisionada."
  type        = string
  default     = "us-east-1" # premissa assumida; confirmar disponibilidade do serviço na região desejada antes de alterar
}

variable "project_name" {
  description = "Nome do projeto, usado em tags e nomes de recursos."
  type        = string
  default     = "devops-ia"
}

variable "environment" {
  description = "Nome do ambiente logico (ex.: dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Bloco CIDR IPv4 da VPC. Deve ser um bloco RFC1918 entre /16 e /28."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr deve ser um bloco CIDR IPv4 valido."
  }
}

variable "enable_dns_support" {
  description = "Habilita resolucao DNS dentro da VPC."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Habilita atribuicao de hostnames DNS a instancias na VPC."
  type        = bool
  default     = true
}
