project = {
  name        = "devops-ia"
  environment = "dev"
  aws_region  = "us-east-1"
}

vpc = {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  # us-east-1a/us-east-1b são nomes lógicos de AZ; o mapeamento para AZ ID físico
  # é específico da conta AWS (ver ADR-002, Premissa #5). Ambas as AZs existem em
  # qualquer conta na região us-east-1 (região tem 6 AZs, validado via MCP AWS).
  public_subnets = [
    { name = "public-a", cidr_block = "10.0.0.0/20", availability_zone = "us-east-1a" },
    { name = "public-b", cidr_block = "10.0.16.0/20", availability_zone = "us-east-1b" },
  ]
  private_subnets = [
    { name = "private-a", cidr_block = "10.0.128.0/20", availability_zone = "us-east-1a" },
    { name = "private-b", cidr_block = "10.0.144.0/20", availability_zone = "us-east-1b" },
  ]
}

nat_gateway = {
  # DECISÃO (ver ADR-002, seção "Decisão", confirmada por humano em 2026-07-07):
  # desabilitado nesta rodada — sem custo recorrente adicional. Subnets privadas
  # ficam sem egress à internet até uma mudança futura pontual.
  # Se true: CUSTO RECORRENTE REAL (~US$ 36,50/mês fixos + processamento de dados
  # variável) — exige aprovação humana explícita antes do apply.
  enabled = false
}
