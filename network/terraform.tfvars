project = {
  name        = "devops-ia"
  environment = "dev"
  aws_region  = "us-east-1"
}

vpc = {
  cidr_block           = "10.0.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  # us-east-1a/us-east-1b são nomes lógicos de AZ; o mapeamento para AZ ID físico
  # é específico da conta AWS (ver ADR-002, Premissa #5). Ambas as AZs existem em
  # qualquer conta na região us-east-1 (região tem 6 AZs, validado via MCP AWS).
  #
  # ADR-003: CIDRs redimensionados de /20 para /26. Os 4 blocos abaixo consomem
  # integralmente o espaço de endereçamento do novo /24 da VPC (256 endereços =
  # 4 x 64) — não resta CIDR livre para novas subnets dentro deste bloco primário
  # (ver ADR-003, Premissa #6 e "Consequências").
  public_subnets = [
    { name = "public-a", cidr_block = "10.0.0.0/26", availability_zone = "us-east-1a" },
    { name = "public-b", cidr_block = "10.0.0.64/26", availability_zone = "us-east-1b" },
  ]
  private_subnets = [
    { name = "private-a", cidr_block = "10.0.0.128/26", availability_zone = "us-east-1a" },
    { name = "private-b", cidr_block = "10.0.0.192/26", availability_zone = "us-east-1b" },
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
