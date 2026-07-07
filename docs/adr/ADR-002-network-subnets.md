# ADR-002: Subnets Públicas/Privadas, Internet Gateway, NAT Gateway e Roteamento — Pasta `network/`

## Status
Aceito — decisão de NAT Gateway revisada e confirmada por humano em 2026-07-07 (ver seção "Decisão")

## Contexto

A stack `network/` (ADR-001) hoje contém apenas uma `aws_vpc.this` (`vpc-0f312e3252e7b82fe`, CIDR `10.0.0.0/16`, região `us-east-1`), já aplicada. O ADR-001 explicitamente deixou fora de escopo subnets, Internet Gateway, NAT Gateway, route tables customizadas e security groups adicionais.

Esta VPC hoje é funcionalmente inútil para hospedar qualquer workload: sem subnets não é possível lançar instâncias, load balancers, RDS, EKS nodes, etc. Este ADR evolui a stack de rede adicionando a topologia mínima de subnets públicas e privadas com roteamento, para viabilizar ADRs futuros de computação (ex.: EC2, EKS, RDS, ALB).

Este ADR é o contrato entre este agente planejador (`aws-solution-architect`) e o agente de implementação (`aws-devops-engineer`), que executará `terraform init/validate/plan/apply` a partir desta especificação. Este agente **não cria, não edita e não aplica** nenhum arquivo `.tf` — todo o conteúdo de código abaixo é especificação de referência.

**Diferença crítica em relação ao ADR-001**: pela primeira vez nesta stack, um dos componentes propostos (NAT Gateway) tem **custo mensal recorrente real e não desprezível**, independentemente de uso. Isso muda o perfil de risco financeiro da stack e exige aprovação humana explícita de custo antes do `apply`, além da aprovação de mudança já exigida pelo ADR-001.

## Premissas

Assumidas por ausência de informação de negócio explícita; o que não pôde ser assumido com segurança está marcado como **A VALIDAR**.

1. **Ambiente**: brownfield controlado — a `aws_vpc.this` já existe e está aplicada; este ADR é estritamente aditivo (nenhum recurso do ADR-001 é modificado ou substituído).
2. **Região/conta**: `us-east-1`, mesma conta já usada pelo ADR-001. Account ID de destino continua **A VALIDAR** (mesma pendência do ADR-001, ainda não confirmada).
3. **Perfil do ambiente**: `dev`/baixo custo (herdado de `var.project.environment = "dev"`). **Confirmado pelo solicitante em 2026-07-07**: o ambiente continua "dev" por enquanto, sem plano de promoção a staging/produção no curto prazo. Por isso este ADR prioriza uma topologia enxuta (2 AZs, sem NAT Gateway nesta primeira aplicação — ver Premissa #7 e "Decisão").
4. **Quantidade de AZs**: 2 AZs (`us-east-1a`, `us-east-1b`), 1 subnet pública + 1 subnet privada por AZ (4 subnets no total). Ver justificativa na seção "Alternativas".
5. **Mapeamento de nome de AZ para AZ ID é específico da conta AWS**: a AWS randomiza o mapeamento `us-east-1a`/`us-east-1b` → AZ ID (`use1-az1`...`use1-az6`) por conta, para distribuir carga entre AZs físicas. Os nomes `us-east-1a`/`us-east-1b` usados neste ADR são lógicos e válidos em qualquer conta (toda conta tem pelo menos essas duas AZs, já que `us-east-1` tem 6 AZs conforme documentação AWS consultada via MCP), mas a AZ física real por trás desses nomes **varia por conta** — isso não compromete a validade do plano (a topologia funciona igual), mas é uma nuance a registrar. **A VALIDAR** apenas se houver necessidade futura de alinhar AZ física específica (ex.: para peering ou latência com outro serviço já provisionado em uma AZ conhecida) — não há tooling MCP disponível para consultar o mapeamento AZ-name→AZ-ID de uma conta específica sem credenciais de execução real (`aws ec2 describe-availability-zones`), portanto o agente de implementação deve rodar esse comando antes do `apply` caso essa nuance importe.
6. **CIDRs das subnets**: `/20` cada (4096 endereços, 4091 utilizáveis), alocados dentro do bloco `10.0.0.0/16` já existente, sem sobreposição entre si nem com o range reservado da VPC. Os valores concretos (`10.0.0.0/20`, `10.0.16.0/20`, `10.0.128.0/20`, `10.0.144.0/20`) foram inicialmente definidos como exemplo ilustrativo em `.claude/rules/terraform-naming.md` (seção 3) e são adotados aqui como valores reais, pois já seguem uma alocação sem conflitos e deixam blocos `/20` livres entre os índices 2–7 (`10.0.32.0/20`–`10.0.112.0/20`) e 10–15 (`10.0.160.0/20`–`10.0.240.0/20`) para subnets futuras (novas AZs, subnets isoladas de banco de dados, etc.), sem necessidade de re-endereçar o que for criado agora. **A VALIDAR**: confirmar que nenhum outro consumidor/peering já usa essas subfaixas de `10.0.0.0/16` (não há indicação de tal uso no repositório).
7. **NAT Gateway**: a arquitetura recomendada (Alternativa B) prevê **1 NAT Gateway compartilhado** caso habilitado. **Decisão confirmada pelo solicitante em 2026-07-07**: aplicar esta ADR com `nat_gateway.enabled = false` nesta primeira rodada — sem custo recorrente adicional, subnets privadas ficam sem egress à internet até uma mudança futura pontual e isolada. Ver seção "Decisão" para o detalhamento.
8. **Volume de tráfego de saída (egress) esperado pelas subnets privadas**: não informado pelo usuário. A estimativa de custo do NAT Gateway inclui apenas a taxa horária fixa; o componente de "data processing" (US$ 0,045/GB) depende do volume real de tráfego e está marcado como **A VALIDAR**/estimativa não incluída no total.
9. **Security Groups, VPC Endpoints, VPC Flow Logs, subnets isoladas (ex.: banco de dados sem rota alguma para internet)**: fora de escopo deste ADR, por não terem sido solicitados. Ficam sinalizados como candidatos a ADRs futuros (ex.: "ADR-003: Security Groups e VPC Endpoints", "ADR-004: VPC Flow Logs"). Nenhuma instância ou recurso de computação é criado por este ADR — apenas rede.
10. **IPv6**: fora de escopo, consistente com o ADR-001 (a VPC não tem bloco IPv6 associado).
11. **Convenção de nomenclatura**: este ADR segue integralmente `.claude/rules/terraform-naming.md` — variáveis agrupadas por domínio em `object`, sem `default` em `variables.tf`, valores em `terraform.tfvars`, arquivos nomeados por domínio (`vpc.public-subnets.tf`, `vpc.private-subnets.tf`, `vpc.internet-gateway.tf`, `vpc.nat-gateway.tf`, `vpc.nat-gateway-eip.tf`, `vpc.public-route-table.tf`, `vpc.private-route-table.tf`).
12. **Backend de state**: continua não configurado (backend local), mesma pendência **A VALIDAR** do ADR-001. Como este ADR adiciona múltiplos recursos com dependências entre si, o risco de perda/corrupção de state local é maior do que no ADR-001 (mais blast radius). Reforça-se a recomendação de migrar para backend remoto (S3 + DynamoDB lock) antes de qualquer uso além de teste individual.
13. **Versão do Terraform CLI e do provider AWS**: reaproveitadas do ADR-001 sem alteração — `>= 1.9.0` (Terraform core, **A VALIDAR** no executor) e `~> 6.53.0` (provider AWS, revalidado nesta data via MCP Terraform como ainda a versão mais recente — sem mudança de versão necessária em `versions.tf`).

## Requisitos considerados

- **Funcional**: subnets públicas e privadas distribuídas em múltiplas AZs; Internet Gateway anexado à VPC; NAT Gateway para egress das subnets privadas; route tables públicas e privadas associadas corretamente; tagging consistente (`Project`, `Environment`, `ManagedBy`, `Repository`, `Name`, mais `Tier` para diferenciar público/privado).
- **Não-funcional**:
  - Alta disponibilidade parcial: subnets distribuídas em 2 AZs (tolerância a falha de 1 AZ para subnets; NAT Gateway único não é tolerante a falha de AZ — ver Alternativas).
  - Custo: NAT Gateway é o primeiro recurso desta stack com custo recorrente real; deve ser dimensionado conscientemente e aprovado por humano antes do apply.
  - Segurança: nenhuma credencial hardcoded; isolamento de rede mínimo mantido (subnets privadas sem rota direta de entrada da internet; nenhum Security Group customizado criado — default SG da VPC permanece restritivo).
  - Rastreabilidade: tagging obrigatório em todo novo recurso via `default_tags` (herdado do provider) + `tags` locais por recurso.
  - RTO/RPO, compliance, escala de tráfego: não informados pelo usuário; não aplicável a este ADR de rede — a ser detalhado em ADRs de workload futuros.

## Alternativas consideradas

Cada alternativa combina: (a) quantidade de AZs/subnets, (b) estratégia de NAT Gateway. Internet Gateway é comum a todas as alternativas (é a única forma nativa de dar rota de internet às subnets públicas; não há alternativa arquitetural a avaliar aqui).

### Alternativa A — 1 AZ, 1 subnet pública + 1 privada, sem NAT Gateway

Uma única AZ (`us-east-1a`), uma subnet pública e uma privada. Subnets privadas **sem** rota de saída para a internet (nenhum NAT Gateway criado) — apenas roteamento interno da VPC (`local`).

- **Prós**: custo adicional zero; menor superfície e complexidade; adequado se as subnets privadas hospedarem apenas recursos que não precisam de egress (ex.: RDS que só recebe conexões da própria VPC).
- **Contras**: nenhuma tolerância a falha de AZ; recursos em subnet privada não conseguem baixar pacotes, se conectar a APIs externas, ou puxar imagens de container de fora da VPC (sem VPC Endpoints, que também estão fora de escopo) — limita fortemente o que pode ser hospedado ali sem uma ADR adicional.
- **Impacto Well-Architected**:
  - Excelência Operacional: neutro/positivo (menos peças móveis).
  - Segurança: positivo (menor superfície de exposição; sem gateway de saída, reduz vetores de exfiltração acidental).
  - Confiabilidade: negativo (zero tolerância a falha de AZ).
  - Eficiência de Performance: neutro.
  - Otimização de Custo: máximo (US$ 0,00 adicional).
  - Sustentabilidade: neutro/positivo (menor pegada de recursos ociosos).
- **Estimativa de custo mensal adicional**: US$ 0,00 (subnets, IGW e route tables não têm custo direto).

### Alternativa B — 2 AZs, 1 subnet pública + 1 privada por AZ, 1 NAT Gateway compartilhado (RECOMENDADA)

2 AZs (`us-east-1a`, `us-east-1b`), 1 subnet pública e 1 privada em cada. Um único NAT Gateway, provisionado na subnet pública da primeira AZ (`public-a` / `us-east-1a`), com uma única route table privada compartilhada pelas duas subnets privadas apontando `0.0.0.0/0` para esse NAT Gateway.

- **Prós**: subnets distribuídas em 2 AZs (tolerância a falha de AZ para o que roda nas subnets, exceto o próprio NAT); egress de internet disponível para as subnets privadas; custo bem menor que NAT por AZ; alinhado ao perfil "dev/baixo custo" do ambiente.
- **Contras**: o NAT Gateway é um ponto único de falha para egress — se `us-east-1a` tiver um evento de indisponibilidade, a subnet privada de `us-east-1b` também perde egress (mesmo estando "no ar"); tráfego de `private-b` até a internet atravessa a AZ `us-east-1a` (pequena taxa adicional de transferência de dados entre AZs, além da taxa de NAT Gateway).
- **Impacto Well-Architected**:
  - Excelência Operacional: neutro (topologia simples, fácil de operar/entender).
  - Segurança: neutro (mesmo perímetro de segurança que a Alternativa C).
  - Confiabilidade: parcial — subnets com HA, mas egress com ponto único de falha (aceitável para "dev", não para produção).
  - Eficiência de Performance: neutro/levemente negativo (tráfego cross-AZ para `private-b`).
  - Otimização de Custo: bom equilíbrio (≈metade do custo da Alternativa C).
  - Sustentabilidade: melhor que Alternativa C (menos NAT Gateways ociosos rodando 24/7).
- **Estimativa de custo mensal adicional**: ≈ US$ 36,50 (taxa horária do NAT Gateway + taxa horária do IPv4 público do Elastic IP associado) **+ processamento de dados variável** (ver seção "Estimativa de custo" para o detalhamento e fontes).

### Alternativa C — 2 AZs, 1 subnet pública + 1 privada por AZ, 1 NAT Gateway por AZ

Mesma distribuição de subnets da Alternativa B, mas com um NAT Gateway dedicado em cada AZ (2 no total), e uma route table privada por AZ, cada uma apontando para o NAT Gateway da própria AZ (padrão recomendado pela AWS para cargas de produção, conforme documentação consultada via MCP).

- **Prós**: sem ponto único de falha para egress; tráfego permanece dentro da mesma AZ (sem custo de transferência cross-AZ); é o padrão recomendado pela AWS para produção.
- **Contras**: dobra o custo fixo de NAT Gateway em relação à Alternativa B; mais recursos para gerenciar (2 EIPs, 2 NAT Gateways, 2 route tables privadas).
- **Impacto Well-Architected**:
  - Excelência Operacional: neutro (mais recursos, mas o padrão é bem documentado/idiomático).
  - Segurança: neutro (mesmo perímetro de segurança).
  - Confiabilidade: melhor entre as três (tolerância completa a falha de AZ, incluindo egress).
  - Eficiência de Performance: melhor (tráfego local à AZ, sem custo/latência cross-AZ).
  - Otimização de Custo: pior entre as três (custo fixo dobrado, independentemente de uso).
  - Sustentabilidade: pior (2 NAT Gateways sempre ativos, mesmo com baixa utilização em ambiente dev).
- **Estimativa de custo mensal adicional**: ≈ US$ 73,00 (2× a taxa da Alternativa B) **+ processamento de dados variável**.

## Decisão

**Topologia de subnets: Alternativa B — 2 AZs, 1 subnet pública + 1 privada por AZ.** A arquitetura de referência para o NAT Gateway, caso venha a ser habilitado no futuro, é a Alternativa B (1 NAT Gateway compartilhado) — ver justificativa abaixo. **Decisão final sobre o NAT Gateway nesta rodada: `nat_gateway.enabled = false`.**

Justificativa da topologia de subnets: o ambiente é declaradamente "dev"/baixo custo (herdado das premissas do ADR-001), e a Alternativa C introduz um custo fixo recorrente ≈2× maior por uma garantia de resiliência (tolerância a falha de AZ no egress) que não foi solicitada como requisito de negócio (não há RTO/RPO ou SLA informado). A Alternativa B seria o equilíbrio natural entre HA de subnets (2 AZs) e custo controlado, caso o NAT fosse habilitado.

**Decisão sobre o NAT Gateway, confirmada por humano em 2026-07-07**: aplicar esta ADR com `nat_gateway.enabled = false`. O solicitante confirmou que (a) o ambiente continua "dev" sem promoção prevista no curto prazo, e (b) prefere não incorrer no custo recorrente do NAT Gateway (≈US$ 36,50/mês fixos + processamento de dados variável) nesta rodada — mesmo a Alternativa A (sem NAT) não foi descartada por custo, ao contrário do que este ADR originalmente recomendava por padrão. Isso significa que, nesta aplicação, as subnets privadas ficam **sem rota de saída para a internet** (equivalente à Alternativa A em termos de egress, mas já com a topologia de 2 AZs/4 subnets da Alternativa B pronta). O toggle `nat_gateway.enabled` permanece disponível em `terraform.tfvars` para habilitar o NAT Gateway compartilhado depois, como mudança pontual e isolada, sem necessidade de um novo ADR (a especificação de implementação abaixo já cobre os dois estados).

**GATE DE APROVAÇÃO HUMANA — status**: como `nat_gateway.enabled = false` nesta aplicação, o gate específico de custo recorrente (NAT Gateway) **não se aplica agora** — não há custo mensal recorrente introduzido por este ADR em sua forma atual. Caso o NAT Gateway seja habilitado no futuro, o gate volta a valer: a mudança de `nat_gateway.enabled` para `true` exigirá confirmação humana explícita e documentada do custo recorrente **antes** de qualquer `terraform apply` que o aplique. O gate geral de aprovação de mudança (herdado do ADR-001) continua valendo normalmente para o `apply` desta ADR.

## Especificação de implementação (para o agente DevOps)

### 1. Estrutura de diretório e arquivos a criar/alterar

Todos os caminhos são relativos a `network/` (stack já existente).

```
network/
├── versions.tf                     # inalterado
├── providers.tf                    # inalterado
├── variables.tf                    # ALTERAR: estender var.vpc, adicionar var.nat_gateway
├── terraform.tfvars                # ALTERAR: estender vpc, adicionar nat_gateway
├── vpc.tf                          # inalterado (aws_vpc.this já aplicado — não tocar)
├── vpc.public-subnets.tf           # NOVO
├── vpc.private-subnets.tf          # NOVO
├── vpc.internet-gateway.tf         # NOVO
├── vpc.nat-gateway-eip.tf          # NOVO
├── vpc.nat-gateway.tf              # NOVO
├── vpc.public-route-table.tf       # NOVO
├── vpc.private-route-table.tf      # NOVO
└── outputs.tf                      # ALTERAR: adicionar outputs novos, manter os existentes
```

Nenhum Security Group, VPC Endpoint, VPC Flow Log ou recurso de computação deve ser criado nesta ADR (fora de escopo — ver Premissas #9).

### 2. `network/variables.tf` (arquivo completo após a alteração)

Argumentos e tipos validados via MCP Terraform (`mcp__terraform__get_provider_details`, providerDocIDs `12705604` `aws_subnet`, `12704890` `aws_internet_gateway`, `12705072` `aws_nat_gateway`, `12704704` `aws_eip`, `12705341` `aws_route_table`, `12705342` `aws_route_table_association`, `12705300` `aws_route`, provider `hashicorp/aws` v6.53.0).

```hcl
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
```

### 3. `network/terraform.tfvars` (arquivo completo após a alteração)

```hcl
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
```

### 4. `network/vpc.public-subnets.tf` (novo)

```hcl
resource "aws_subnet" "public" {
  for_each = { for s in var.vpc.public_subnets : s.name => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project.name}-${var.project.environment}-${each.value.name}"
    Tier = "public"
  }
}
```

Nota: `map_public_ip_on_launch = true` faz com que instâncias lançadas nesta subnet recebam IPv4 público automaticamente. Desde a mudança de preço da AWS de fevereiro de 2024, **todo IPv4 público incorre em cobrança horária (US$ 0,005/h)**, inclusive os atribuídos automaticamente a instâncias — relevante para o custo de ADRs futuros de computação que usem esta subnet, não para o custo desta ADR (nenhuma instância é criada aqui).

### 5. `network/vpc.private-subnets.tf` (novo)

```hcl
resource "aws_subnet" "private" {
  for_each = { for s in var.vpc.private_subnets : s.name => s }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  tags = {
    Name = "${var.project.name}-${var.project.environment}-${each.value.name}"
    Tier = "private"
  }
}
```

### 6. `network/vpc.internet-gateway.tf` (novo)

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project.name}-${var.project.environment}-igw"
  }
}
```

### 7. `network/vpc.nat-gateway-eip.tf` (novo)

```hcl
resource "aws_eip" "nat" {
  count = var.nat_gateway.enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.project.name}-${var.project.environment}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}
```

### 8. `network/vpc.nat-gateway.tf` (novo)

O NAT Gateway é criado na subnet pública da **primeira** AZ declarada em `var.vpc.public_subnets` (índice `0`, ou seja `public-a` / `us-east-1a`, conforme `terraform.tfvars`).

```hcl
resource "aws_nat_gateway" "this" {
  count = var.nat_gateway.enabled ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[var.vpc.public_subnets[0].name].id

  tags = {
    Name = "${var.project.name}-${var.project.environment}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}
```

### 9. `network/vpc.public-route-table.tf` (novo)

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project.name}-${var.project.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
```

### 10. `network/vpc.private-route-table.tf` (novo)

Uma única route table privada, compartilhada pelas duas subnets privadas (consistente com a decisão de 1 NAT Gateway compartilhado). A rota `0.0.0.0/0` só é adicionada se `var.nat_gateway.enabled = true`.

```hcl
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.nat_gateway.enabled ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = {
    Name = "${var.project.name}-${var.project.environment}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

### 11. `network/outputs.tf` (adicionar aos outputs já existentes do ADR-001, sem removê-los)

```hcl
output "public_subnet_ids" {
  description = "IDs das subnets públicas, indexados pelo nome declarado em vpc.public_subnets."
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas, indexados pelo nome declarado em vpc.private_subnets."
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "internet_gateway_id" {
  description = "ID do Internet Gateway anexado à VPC."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway compartilhado (null se nat_gateway.enabled = false)."
  value       = try(aws_nat_gateway.this[0].id, null)
}

output "nat_gateway_public_ip" {
  description = "Endereço IPv4 público do NAT Gateway compartilhado (null se nat_gateway.enabled = false)."
  value       = try(aws_eip.nat[0].public_ip, null)
}

output "public_route_table_id" {
  description = "ID da route table pública."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID da route table privada."
  value       = aws_route_table.private.id
}
```

### 12. IAM (least privilege para o executor do Terraform)

Adicionar as permissões abaixo às já existentes do ADR-001 (não removê-las). Mesma justificativa do ADR-001 se aplica: as ações de API de criação/leitura de recursos de rede do EC2 não suportam restrição granular por ARN de recurso específico ainda não existente; a criação é, portanto, liberada com `Resource: "*"`, e a gestão de tags é restrita por condição.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SubnetActions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:ModifySubnetAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "InternetGatewayActions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:DescribeInternetGateways"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NatGatewayActions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNatGateway",
        "ec2:DeleteNatGateway",
        "ec2:DescribeNatGateways"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElasticIpActions",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:DescribeAddresses",
        "ec2:DescribeAddressesAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RouteTableActions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:ReplaceRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:ReplaceRouteTableAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TagManagementScopedToProject",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags",
        "ec2:DeleteTags"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:subnet/*",
        "arn:aws:ec2:*:*:internet-gateway/*",
        "arn:aws:ec2:*:*:natgateway/*",
        "arn:aws:ec2:*:*:elastic-ip/*",
        "arn:aws:ec2:*:*:route-table/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "devops-ia"
        }
      }
    }
  ]
}
```

### 13. Dependências e ordem de execução

1. Confirmar que `aws_vpc.this` já existe no state (`terraform state show aws_vpc.this` dentro de `network/`) antes de prosseguir — este ADR é aditivo sobre um recurso já aplicado.
2. Alterar `network/variables.tf` e `network/terraform.tfvars` conforme especificado (seções 2 e 3).
3. Criar os 7 novos arquivos `.tf` (seções 4 a 10).
4. Alterar `network/outputs.tf` adicionando os novos outputs (seção 11), preservando os já existentes.
5. `cd network/`
6. `terraform init -upgrade=false` (nenhum novo provider é necessário; deve reaproveitar o provider já baixado na constraint `~> 6.53.0`).
7. `terraform fmt -check` — corrigir com `terraform fmt` se houver diferenças.
8. `terraform validate` — deve retornar `Success!`.
9. `terraform plan -out=tfplan` — revisar cuidadosamente. **Decisão vigente: `nat_gateway.enabled = false`**, portanto o plano esperado é **11 resources to add** (`aws_subnet.public["public-a"]`, `aws_subnet.public["public-b"]`, `aws_subnet.private["private-a"]`, `aws_subnet.private["private-b"]`, `aws_internet_gateway.this`, `aws_route_table.public`, `aws_route_table.private` + 4 associations `aws_route_table_association.public["public-a"]`, `["public-b"]`, `aws_route_table_association.private["private-a"]`, `["private-b"]`), **sem** `aws_eip.nat[0]`/`aws_nat_gateway.this[0]` e sem rota `0.0.0.0/0` na route table privada. **0 to change, 0 to destroy, e nenhuma alteração em `aws_vpc.this`.** Se no futuro `nat_gateway.enabled` for alterado para `true`, o total passa a ser 13 resources to add (ver seção 14/"Critérios de aceite" para o detalhamento desse cenário).
10. **Ponto de decisão humana obrigatório nº 1 (mudança em infraestrutura já em uso)**: qualquer `terraform apply` deve ser aprovado explicitamente por um humano, conforme já exigido pelo ADR-001.
11. **Ponto de decisão humana obrigatório nº 2 (custo recorrente — específico deste ADR)**: não se aplica a este `apply`, pois `nat_gateway.enabled = false` (decisão já confirmada — ver seção "Decisão"). Só volta a valer se `nat_gateway.enabled` for alterado para `true` em uma mudança futura: nesse caso, a aprovação humana deve registrar explicitamente ciência do custo recorrente estimado (~US$ 36,50/mês fixos + processamento de dados variável, ver "Estimativa de custo") antes do `apply` correspondente.
12. Após aprovação humana do gate nº 1, o `aws-devops-engineer` executa `terraform apply tfplan`.

### 14. Parâmetros validados via MCP vs. A VALIDAR

| Parâmetro | Valor | Validado via | Status |
|---|---|---|---|
| Versão provider `hashicorp/aws` (reconfirmação) | 6.53.0 (sem mudança) | `mcp__terraform__get_latest_provider_version` | Validado |
| Schema do recurso `aws_subnet` | argumentos `vpc_id`, `cidr_block`, `availability_zone`, `map_public_ip_on_launch`, `tags`; atributos `id`, `arn` | `mcp__terraform__get_provider_details` (providerDocID 12705604) | Validado |
| Schema do recurso `aws_internet_gateway` | argumentos `vpc_id`, `tags`; atributos `id`, `arn` | `mcp__terraform__get_provider_details` (providerDocID 12704890) | Validado |
| Schema do recurso `aws_route_table` (+ `route` inline, attribute-as-blocks) | argumentos `vpc_id`, `route` (`cidr_block`, `gateway_id`/`nat_gateway_id`), `tags` | `mcp__terraform__get_provider_details` (providerDocID 12705341) | Validado |
| Schema do recurso `aws_route_table_association` | argumentos `subnet_id`, `gateway_id`, `route_table_id` (mutuamente exclusivos `subnet_id`/`gateway_id`) | `mcp__terraform__get_provider_details` (providerDocID 12705342) | Validado |
| Schema do recurso `aws_nat_gateway` (modo zonal, `connectivity_type = "public"`) | argumentos `allocation_id`, `subnet_id`, `tags`; atributos `id`, `public_ip` | `mcp__terraform__get_provider_details` (providerDocID 12705072) | Validado |
| Schema do recurso `aws_eip` | argumento `domain = "vpc"`; atributos `id`, `public_ip`; nota de dependência recomendada do IGW | `mcp__terraform__get_provider_details` (providerDocID 12704704) | Validado |
| Schema do recurso `aws_route` (avaliado e descartado em favor de `route` inline em `aws_route_table` — ver Alternativas de estilo de código, nota abaixo) | argumentos `route_table_id`, `destination_cidr_block`, `gateway_id`/`nat_gateway_id` | `mcp__terraform__get_provider_details` (providerDocID 12705300) | Validado |
| Disponibilidade do serviço "Amazon Virtual Private Cloud (VPC)" em `us-east-1` (reconfirmação) | `isAvailableIn` | `mcp__aws-mcp__aws___get_regional_availability` | Validado |
| Disponibilidade do recurso "NAT Gateway" em `us-east-1` | `isAvailableIn` | `mcp__aws-mcp__aws___get_regional_availability` (filtro "NAT Gateway") | Validado |
| Quantidade de AZs em `us-east-1` | 6 AZs (`use1-az1`…`use1-az6`), com uma 7ª anunciada para 2026 (ainda não disponível) | `mcp__aws-mcp__aws___search_documentation` (AWS Availability Zones) | Validado |
| Preço do NAT Gateway (taxa horária) em `us-east-1` | US$ 0,045/hora | `mcp__aws-mcp__aws___search_documentation` (Amazon VPC Pricing / AWS Workspaces getting started, ambos citando US East regions) | Validado |
| Preço de processamento de dados do NAT Gateway | US$ 0,045/GB | `mcp__aws-mcp__aws___search_documentation` (Amazon VPC Pricing) | Validado |
| Cobrança de todo IPv4 público (incluindo EIP do NAT Gateway) desde a mudança de preço de fev/2024 | US$ 0,005/hora | `mcp__aws-mcp__aws___search_documentation` (AWS SDK docs `mapPublicIpOnLaunch`; AWS CUR troubleshooting guide) | Validado |
| Recomendação de 1 NAT Gateway por AZ para produção / tráfego local à AZ | prática recomendada AWS | `mcp__aws-mcp__aws___search_documentation` (blog "Using NAT Gateways with multiple-Amazon VPCs at scale"; guidance "Network Connectivity on AWS") | Validado (referência de boas práticas, não obrigatoriedade) |
| Mapeamento AZ-name → AZ-ID específico da conta de destino | desconhecido | Não validável sem credenciais da conta real | **A VALIDAR** pelo agente de implementação (`aws ec2 describe-availability-zones`), apenas se essa nuance importar ao caso de uso |
| Account ID de destino | não informado | Não validável sem input do usuário | **A VALIDAR** — mesma pendência do ADR-001 |
| Volume de tráfego de saída esperado (para estimar custo de "data processing" do NAT) | não informado | N/A | **A VALIDAR** com o solicitante ou por observação após operação |
| Backend de state remoto (S3/DynamoDB) | não configurado | N/A | **A VALIDAR** — mesma pendência do ADR-001, agravada pelo maior número de recursos |

> Nota sobre o uso de `route` inline em `aws_route_table` em vez de `aws_route` standalone: a documentação do provider (ambos os provider docs consultados) alerta explicitamente que os dois padrões não podem ser misturados na mesma route table sob risco de conflito de regras. Este ADR usa exclusivamente o padrão inline (`route` dentro de `aws_route_table`), por ser mais simples de auditar em uma stack pequena com poucas rotas fixas; `aws_route` standalone fica descartado para este escopo.

## Consequências

**Positivas**
- A VPC deixa de ser "vazia": passa a ter uma topologia mínima e funcional de rede, viabilizando ADRs futuros de computação (EC2, EKS, RDS, ALB, etc.).
- Separação clara entre subnets públicas e privadas via tag `Tier`, útil para políticas de Security Group/NACL futuras e para filtros em outputs/data sources.
- Custo controlado e explícito: a única fonte de custo recorrente (NAT Gateway) é isolada atrás de uma variável de toggle (`nat_gateway.enabled`), permitindo ligar/desligar sem reestruturar a stack.
- Endereçamento com espaço de crescimento: blocos `/20` deixam ampla margem de IPs livres em `10.0.0.0/16` para novas AZs ou subnets (ex.: isoladas de banco de dados) sem re-planejamento de CIDR.
- Reaproveita integralmente o padrão de arquivos e nomenclatura já estabelecido em `.claude/rules/terraform-naming.md`, sem introduzir uma convenção nova.

**Negativas / riscos e mitigação**
- **NAT Gateway como ponto único de falha de egress**: se a AZ do NAT Gateway ficar indisponível, ambas as subnets privadas perdem egress. Mitigação: aceito conscientemente para o perfil "dev/baixo custo"; documentado como trade-off explícito na Alternativa C para quando o ambiente evoluir.
- **Custo recorrente contínuo enquanto o NAT Gateway existir**, mesmo sem tráfego. Mitigação: gate de aprovação humana obrigatório; toggle `nat_gateway.enabled` permite desabilitar rapidamente.
- **Tráfego cross-AZ da subnet `private-b` até o NAT Gateway em `us-east-1a`**: gera uma pequena taxa adicional de transferência de dados entre AZs (não incluída na estimativa de custo desta ADR, tipicamente baixa para volumes de dev). Mitigação: se o volume crescer, migrar para a Alternativa C (NAT por AZ) em ADR futuro.
- **State local com mais recursos e mais dependências entre eles** (subnets → route tables → associations → NAT Gateway → EIP): maior risco de state corrompido/perdido do que no ADR-001. Mitigação: mesma recomendação do ADR-001, reforçada — migrar para backend remoto antes de uso além de teste individual.
- **Nenhum VPC Flow Log, Security Group customizado ou VPC Endpoint criado**: a stack de rede permanece sem visibilidade de tráfego nem controle de acesso granular além dos defaults da VPC. Mitigação: sinalizado como próximos ADRs naturais (Flow Logs para observabilidade/auditoria; Security Groups quando houver um primeiro consumidor de computação).

**Impactos operacionais**
- Monitoramento: nenhum recurso de logging é criado por este ADR (VPC Flow Logs fora de escopo — mesma decisão que o ADR-001 tomou para a VPC). Recomenda-se abrir um ADR específico assim que houver tráfego real passando pelas subnets.
- Backup: não aplicável (recursos de rede não têm dados a backupear).
- Manutenção: se o NAT Gateway for desabilitado (`nat_gateway.enabled = false`) após já ter sido aplicado com `true`, o `terraform apply` subsequente irá destruir `aws_nat_gateway.this[0]` e `aws_eip.nat[0]` e remover a rota `0.0.0.0/0` da route table privada — isso interrompe imediatamente o egress das subnets privadas; deve ser tratado como mudança planejada, não acidental.

## Estimativa de custo

Todos os valores validados via MCP AWS (`mcp__aws-mcp__aws___search_documentation`, Amazon VPC Pricing e documentação de preço de IPv4 público), assumindo ~730 horas/mês e **sem considerar tráfego de dados** (não informado pelo usuário — ver Premissas #8).

| Recurso | Custo unitário | Alternativa B (recomendada, 1 NAT) | Alternativa C (1 NAT por AZ) |
|---|---|---|---|
| Subnets (4x), Internet Gateway, Route Tables, Associations | US$ 0,00 (sem cobrança direta) | US$ 0,00 | US$ 0,00 |
| NAT Gateway — taxa horária | US$ 0,045/h | 1 × US$ 32,85/mês | 2 × US$ 32,85/mês = US$ 65,70/mês |
| Elastic IP do NAT Gateway — taxa de IPv4 público (cobrada mesmo associado, desde fev/2024) | US$ 0,005/h | 1 × US$ 3,65/mês | 2 × US$ 3,65/mês = US$ 7,30/mês |
| **Total fixo mensal (sem tráfego)** | — | **≈ US$ 36,50/mês** | **≈ US$ 73,00/mês** |
| Processamento de dados do NAT Gateway (variável) | US$ 0,045/GB processado | **A VALIDAR** (depende do volume real de egress) | **A VALIDAR** |
| Transferência de dados padrão de saída à internet (variável, cobrada à parte, mesma regra em qualquer alternativa) | US$ 0,01–0,09/GB (varia por volume/destino) | **A VALIDAR** | **A VALIDAR** |

Com `nat_gateway.enabled = false`, o custo adicional desta ADR é **US$ 0,00/mês** (equivalente à Alternativa A), ao custo de não haver egress de internet nas subnets privadas.

## Estratégia de rollback

1. **Rollback do NAT Gateway isoladamente (cenário mais provável de reversão por custo)**: definir `nat_gateway.enabled = false` em `terraform.tfvars`, rodar `terraform plan` (deve mostrar a destruição de `aws_eip.nat[0]` e `aws_nat_gateway.this[0]` e a remoção da rota `0.0.0.0/0` da `aws_route_table.private`) e aplicar após aprovação humana. Isso interrompe a cobrança recorrente imediatamente, preservando subnets, IGW e route tables.
2. **Rollback completo desta ADR**: `terraform destroy -target=aws_route_table_association.private -target=aws_route_table_association.public -target=aws_route_table.private -target=aws_route_table.public -target=aws_nat_gateway.this -target=aws_eip.nat -target=aws_internet_gateway.this -target=aws_subnet.private -target=aws_subnet.public` dentro de `network/`, ou reverter o commit que introduziu os arquivos `.tf` novos e rodar `terraform apply` do state anterior (o `aws_vpc.this` do ADR-001 não é afetado em nenhum dos dois casos).
3. Antes de qualquer `destroy`, fazer backup do state (`terraform.tfstate`/`terraform.tfstate.backup`, enquanto o backend for local).
4. Se o `apply` falhar parcialmente (ex.: NAT Gateway criado mas falha na associação de rota), usar `terraform plan` para diagnosticar o estado real vs. desejado antes de qualquer ação destrutiva — não presumir que um recurso "provavelmente" foi criado.
5. Qualquer `destroy` que afete subnets/route tables já em uso por recursos de computação de ADRs futuros exige aprovação humana explícita e checagem prévia de dependências (`terraform plan` deve ser revisado por completo, incluindo destruições implícitas em cascata).

## Critérios de aceite

- [ ] `network/variables.tf` contém `var.vpc` estendido com `public_subnets`/`private_subnets` e o novo `var.nat_gateway`, sem `default` em nenhuma variável.
- [ ] `network/terraform.tfvars` contém os valores concretos de `public_subnets`, `private_subnets` e `nat_gateway.enabled`.
- [ ] Os 7 novos arquivos `.tf` existem exatamente com os nomes especificados na seção "Estrutura de diretório".
- [ ] `terraform init` executa sem erros, sem exigir upgrade de provider.
- [ ] `terraform fmt -check` não reporta diferenças.
- [ ] `terraform validate` retorna `Success!`.
- [ ] `terraform plan` mostra **11 resources to add** (decisão vigente: `nat_gateway.enabled = false`), 0 a alterar, 0 a destruir, e **nenhuma alteração/destruição de `aws_vpc.this`**.
- [ ] Nenhum arquivo `.tf` contém `access_key`, `secret_key` ou qualquer credencial literal.
- [ ] **Aprovação humana registrada** para o `apply` (gate geral, herdado do ADR-001). Gate específico de custo do NAT Gateway não se aplica nesta rodada (`nat_gateway.enabled = false`); volta a valer se essa variável for alterada para `true` no futuro.
- [ ] Após `apply` aprovado: as 4 subnets existem com os CIDRs e AZs corretos, tags `Project`, `Environment`, `ManagedBy`, `Repository`, `Name` e `Tier` presentes.
- [ ] `aws_internet_gateway.this` está anexado (`attached`) à `aws_vpc.this`.
- [ ] A route table pública tem rota `0.0.0.0/0` → Internet Gateway e está associada às duas subnets públicas.
- [ ] A route table privada está associada às duas subnets privadas e, com `nat_gateway.enabled = false`, não tem rota de saída além do `local` implícito da VPC.
- [ ] Nenhum `aws_eip`/`aws_nat_gateway` foi criado nesta aplicação (consistente com `nat_gateway.enabled = false`).
- [ ] Outputs `public_subnet_ids`, `private_subnet_ids`, `internet_gateway_id`, `public_route_table_id`, `private_route_table_id` retornam valores não vazios; `nat_gateway_id` e `nat_gateway_public_ip` retornam `null`.
- [ ] Nenhum Security Group customizado, VPC Endpoint, VPC Flow Log ou recurso de computação foi criado por esta ADR.

## Referências

- MCP Terraform — `mcp__terraform__get_latest_provider_version` (hashicorp/aws) → 6.53.0 (reconfirmado, sem mudança em relação ao ADR-001).
- MCP Terraform — `mcp__terraform__search_providers` + `mcp__terraform__get_provider_details` → schemas de `aws_subnet` (providerDocID 12705604), `aws_internet_gateway` (12704890), `aws_route_table` (12705341), `aws_route_table_association` (12705342), `aws_nat_gateway` (12705072), `aws_eip` (12704704), `aws_route` (12705300).
- MCP AWS — `mcp__aws-mcp__aws___get_regional_availability` (resource_type `product`, region `us-east-1`) → "Amazon Virtual Private Cloud (VPC)": `isAvailableIn` (reconfirmado); "NAT Gateway": `isAvailableIn`.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` (tópico `general`) → "AWS Availability Zones" (docs.aws.amazon.com/global-infrastructure) — confirmação de 6 AZs em `us-east-1`.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` (tópicos `reference_documentation`, `general`) → "Amazon VPC Pricing" (aws.amazon.com/vpc/pricing), "Pricing for NAT gateways" (docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-pricing.html), blog "Using NAT Gateways with multiple-Amazon VPCs at scale" — taxas de NAT Gateway (US$ 0,045/h) e processamento de dados (US$ 0,045/GB), e recomendação de 1 NAT por AZ para produção.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` → AWS SDK Kotlin docs (`mapPublicIpOnLaunch`) e AWS CUR troubleshooting guide — confirmação da cobrança de US$ 0,005/h para todo IPv4 público desde a mudança de preço de fevereiro de 2024.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` → "Security best practices" (AWS Solutions) e "Guidance for Network Connectivity on AWS" — referência de boas práticas para subnets públicas/privadas/isoladas em múltiplas AZs.
- `.claude/rules/terraform-naming.md` — convenção de nomenclatura de arquivos, variáveis agrupadas por domínio e ausência de `default` em `variables.tf`, incluindo o exemplo ilustrativo de `public_subnets`/`private_subnets` do qual os CIDRs concretos desta ADR foram adotados.
- ADR-001 (`docs/adr/ADR-001-network-vpc.md`) — contexto da `aws_vpc.this` já aplicada e pendências ainda em aberto (Account ID, backend de state, versão do Terraform CLI), herdadas por este ADR.
