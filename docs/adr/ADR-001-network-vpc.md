# ADR-001: Stack de Rede Base (VPC) em Terraform — Pasta `network/`

## Status
Aprovado

## Contexto

O time solicitou a criação de uma nova stack de redes em Terraform para o repositório `Devops-IA`. O objetivo mínimo e explícito é:

1. Criar a pasta `network/` na raiz do repositório.
2. Organizar o código Terraform em múltiplos arquivos `.tf`, seguindo boas práticas de estruturação (separação de providers, variáveis, recursos e outputs).
3. Configurar o provider `aws`.
4. Provisionar uma `aws_vpc` com um CIDR razoável.

Este ADR é o único contrato entre este agente (planejador, `aws-solution-architect`) e o agente de implementação (`aws-devops-engineer`), que executará `terraform init/validate/plan/apply` a partir da especificação aqui descrita. Este agente **não cria, não edita e não aplica** nenhum arquivo `.tf` — todo o conteúdo de código abaixo é especificação de referência para o agente executor.

Trata-se de um cenário de baixo risco (rede básica, sem dados sensíveis, sem carga de produção declarada), portanto premissas razoáveis foram assumidas em vez de bloquear o planejamento — todas listadas explicitamente na seção seguinte.

## Premissas

Assumidas por ausência de informação de negócio (marcadas como tal); o que não pôde ser assumido com segurança está marcado como **A VALIDAR**.

1. **Ambiente**: greenfield. Não há stack de rede pré-existente no repositório (confirmado por varredura do diretório raiz — não há arquivos `.tf` hoje).
2. **Região AWS**: `us-east-1` (assumida como padrão de exemplo/dev). Disponibilidade do serviço "Amazon Virtual Private Cloud (VPC)" em `us-east-1` **validada via MCP AWS** (`mcp__aws-mcp__aws___get_regional_availability`, resultado: `isAvailableIn`).
3. **CIDR da VPC**: `10.0.0.0/16`. Escolhido por ser o exemplo oficial do provider AWS (`aws_vpc` resource doc, HashiCorp Registry) e por estar alinhado ao padrão de alocação recomendado pelo AWS Well-Architected Framework para VPCs de ambiente "Dev" na primeira região (`10.0.0.0/16`), conforme documentação AWS consultada via MCP.
4. **Ambiente lógico**: `dev` (nome do projeto/tag). **A VALIDAR** com o solicitante o nome definitivo do projeto/conta e a convenção de tagging corporativa, se houver uma já estabelecida.
5. **Escopo estritamente limitado a VPC**: este ADR **não** cria subnets, Internet Gateway, NAT Gateway, route tables customizadas, VPC Endpoints ou Security Groups adicionais — nada disso foi solicitado. Isso é matéria de um ADR subsequente (ex.: ADR-002 "Subnets e Roteamento").
6. **IPv6**: fora de escopo. A VPC será criada apenas com CIDR IPv4.
7. **Tenancy**: `default` (não dedicada), para evitar custo adicional de US$ 2/hora por instância, dado que não há requisito de tenancy dedicada.
8. **Backend de state**: **A VALIDAR / decisão humana necessária**. Não há informação sobre bucket S3, tabela DynamoDB de lock, ou conta AWS de management state já existentes. Este ADR especifica a stack sem backend remoto configurado (backend local implícito), o que é aceitável para uma primeira validação, mas **não deve ser usado em cenário multiusuário/produção** sem migrar para backend remoto (S3 + DynamoDB lock) — ver seção "Consequências".
9. **Versão do Terraform CLI**: nenhuma ferramenta MCP disponível valida a versão do binário Terraform instalado no executor. Assumida constraint mínima `>= 1.9.0` (compatível com sintaxe de `import` blocks e funcionalidades usadas). **A VALIDAR** pelo agente de implementação executando `terraform version` no ambiente de execução real.
10. **Credenciais AWS**: assume-se que o agente de implementação já possui credenciais configuradas via variáveis de ambiente, SSO ou profile nomeado (nunca hardcoded no `.tf`), conforme premissa de segurança padrão.
11. **Conta AWS de destino**: não informada. **A VALIDAR** — recomenda-se que o agente de implementação confirme o Account ID esperado antes do `apply` (ex.: via `allowed_account_ids` no provider ou checagem manual), para evitar aplicar em conta errada.

## Requisitos considerados

- **Funcional**: pasta `network/` na raiz; múltiplos arquivos `.tf`; provider AWS configurado; uma `aws_vpc` provisionada com CIDR válido.
- **Não-funcional**:
  - Legibilidade e manutenibilidade do código (organização em arquivos por responsabilidade).
  - Determinismo de versões (provider e, na medida do possível, Terraform core).
  - Segurança: sem credenciais hardcoded, tagging para rastreabilidade, least privilege na policy IAM do executor.
  - Baixo custo: nenhum recurso pago diretamente por este ADR (VPC em si não tem custo).
  - Escala/tráfego/RTO/RPO/compliance: não informados pelo usuário: não aplicável a este ADR de rede básica; deverão ser levantados em ADRs futuros que adicionem subnets, computação ou dados.

## Alternativas consideradas

### Alternativa A — Arquivos múltiplos "flat" no root do módulo (`network/*.tf`)

Todos os recursos residem diretamente em `network/`, divididos por responsabilidade em arquivos separados (`versions.tf`, `providers.tf`, `variables.tf`, `vpc.tf`, `outputs.tf`), sem submódulos. Este é o "Standard Module Structure" recomendado pela documentação oficial do Terraform para módulos raiz simples.

- **Prós**: simplicidade máxima; baixo custo de manutenção; fácil auditoria; adequado ao escopo atual (uma única VPC, sem necessidade de reuso).
- **Contras**: se no futuro for necessário criar múltiplas VPCs (multi-conta/multi-região) reutilizando a mesma lógica, será preciso refatorar para um módulo.
- **Impacto Well-Architected**:
  - Excelência Operacional: alto ganho (simples de operar, revisar em PR, baixo overhead cognitivo).
  - Segurança: neutro (mesmas garantias de segurança independem da estrutura de arquivos).
  - Confiabilidade: neutro.
  - Eficiência de Performance: não aplicável (não há carga de execução relevante).
  - Otimização de Custo: alto ganho (menor esforço de desenvolvimento/manutenção).
  - Sustentabilidade: neutro.
- **Estimativa de custo mensal**: US$ 0,00 (aws_vpc não tem custo direto; ver seção de custo).

### Alternativa B — Módulo local reutilizável (`network/modules/vpc/` + root `network/main.tf` chamando o módulo)

O root module (`network/`) apenas instância um módulo local em `network/modules/vpc/` que encapsula o recurso `aws_vpc` (com variáveis e outputs próprios). O root teria `providers.tf`, `versions.tf`, `variables.tf`, `main.tf` (chamada ao módulo) e `outputs.tf`.

- **Prós**: preparado para reuso futuro (múltiplas VPCs, múltiplos ambientes chamando o mesmo módulo com inputs diferentes); força uma interface clara (variáveis/outputs do módulo).
- **Contras**: introduz uma camada de abstração e indireção desnecessária para um único recurso; mais arquivos e mais complexidade de navegação para quem for revisar/operar; overengineering para o escopo solicitado (YAGNI).
- **Impacto Well-Architected**:
  - Excelência Operacional: penaliza no curto prazo (mais complexidade para operar algo simples); beneficia no longo prazo se houver reuso real.
  - Segurança: neutro.
  - Confiabilidade: neutro.
  - Eficiência de Performance: não aplicável.
  - Otimização de Custo: penaliza (mais tempo de desenvolvimento agora para um benefício especulativo).
  - Sustentabilidade: neutro.
- **Estimativa de custo mensal**: US$ 0,00 (mesmo recurso final, mesma ausência de custo direto).

### Alternativa C (descartada sem aprofundamento) — Módulo comunitário `terraform-aws-modules/vpc/aws`

Versão mais recente confirmada via MCP Terraform (`mcp__terraform__get_latest_module_version`): **6.6.1**. Este módulo provisiona por padrão subnets públicas/privadas, route tables, IGW, e opcionalmente NAT Gateways — muito além do que foi solicitado ("provisionar uma VPC"). Foi descartada nesta ADR por gerar escopo maior que o requisitado (mais recursos, mais custo potencial com NAT Gateway, menos transparência sobre o que é criado) e não foi avaliada em detalhe pelos pilares Well-Architected. Pode ser reconsiderada em ADR futuro se o requisito evoluir para uma topologia completa de subnets/roteamento.

## Decisão

**Alternativa A — arquivos múltiplos "flat" em `network/`** é a escolhida.

Justificativa: o requisito atual é estritamente "uma VPC com boas práticas de organização de arquivos", não reuso multi-ambiente. A Alternativa B introduziria uma camada de indireção (módulo local) sem benefício concreto agora — violaria o princípio de simplicidade (YAGNI) e aumentaria o custo de manutenção sem ganho compensatório, dado que não há hoje um segundo consumidor da "VPC module". A estrutura padrão de módulo raiz (`versions.tf`, `providers.tf`, `variables.tf`, `vpc.tf`, `outputs.tf`) já atende ao requisito de "arquivos quebrados seguindo boas práticas" e é o padrão consagrado pela documentação oficial do Terraform. Se, em ADR futuro, surgir necessidade de múltiplas VPCs reutilizando a mesma lógica, recomenda-se então migrar para a Alternativa B (extração de módulo local), preservando o mesmo `cidr_block`/tags via variáveis.

## Especificação de implementação (para o agente DevOps)

### 1. Estrutura de diretório e arquivos a criar

Caminho exato: `network/` (raiz do repositório, ao lado de `.claude/`, `.mcp.json`, etc.)

```
network/
├── versions.tf
├── providers.tf
├── variables.tf
├── terraform.tfvars
├── vpc.tf
└── outputs.tf
```

Nenhum outro arquivo `.tf` deve ser criado nesta ADR (sem subnets, sem IGW, sem NAT, sem security groups adicionais — fora de escopo, ver Premissas #5).

> **Atualização pós-aprovação**: após a criação da regra de convenções
> `.claude/rules/terraform-naming.md`, esta stack foi refatorada para segui-la
> (variáveis agrupadas por domínio em vez de soltas, sem `default` em
> `variables.tf`, valores em `terraform.tfvars`, resource renomeado de
> `aws_vpc.main` para `aws_vpc.this` com um bloco `moved` para preservar o
> recurso já aplicado). Os blocos de código abaixo já refletem essa
> estrutura; a versão original (pré-convenção) fica preservada no histórico
> do Git.

### 2. `network/versions.tf`

Fixa a versão do Terraform core e do provider AWS. Versão do provider **validada via MCP Terraform** (`mcp__terraform__get_latest_provider_version`, namespace `hashicorp`, name `aws` → **6.53.0**, a mais recente disponível no momento deste ADR).

```hcl
terraform {
  required_version = ">= 1.9.0" # A VALIDAR: confirmar versão do binário Terraform instalado no executor (terraform version)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.53.0" # validado via MCP Terraform: hashicorp/aws latest = 6.53.0
    }
  }
}
```

### 3. `network/providers.tf`

Configuração do provider AWS, validada com base na documentação oficial do provider (`mcp__terraform__get_provider_details`, providerDocID do overview do provider `hashicorp/aws`). Região definida via variável (sem hardcode), `default_tags` aplicado a todos os recursos do provider (estratégia de tagging obrigatória, conforme premissas de segurança padrão).

```hcl
provider "aws" {
  region = var.project.aws_region

  default_tags {
    tags = {
      Project     = var.project.name
      Environment = var.project.environment
      ManagedBy   = "terraform"
      Repository  = "Devops-IA"
    }
  }
}
```

Nota para o agente de implementação: **não** adicionar `access_key`/`secret_key` neste arquivo. Credenciais devem vir de variáveis de ambiente (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`), de um profile nomeado (`AWS_PROFILE`), ou de OIDC/IRSA, conforme o ambiente de execução do pipeline. Se possível, usar `allowed_account_ids` no bloco do provider para travar a conta de destino, após confirmar o Account ID esperado (ponto **A VALIDAR** — decisão humana antes do `apply`).

### 4. `network/variables.tf`

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
```

Valores concretos (sem `default` em `variables.tf`, conforme
`.claude/rules/terraform-naming.md`):

```hcl
# network/terraform.tfvars
project = {
  name        = "devops-ia"
  environment = "dev"
  aws_region  = "us-east-1" # premissa assumida; confirmar disponibilidade do serviço na região desejada antes de alterar
}

vpc = {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}
```

### 5. `network/vpc.tf`

Argumentos validados via MCP Terraform (`mcp__terraform__get_provider_details`, providerDocID `12705644`, resource `aws_vpc`, provider `hashicorp/aws` v6.53.0): `cidr_block`, `enable_dns_support`, `enable_dns_hostnames`, `instance_tenancy`, `tags` são todos argumentos documentados e suportados nesta versão.

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc.cidr_block
  instance_tenancy     = "default"
  enable_dns_support   = var.vpc.enable_dns_support
  enable_dns_hostnames = var.vpc.enable_dns_hostnames

  tags = {
    Name = "${var.project.name}-${var.project.environment}-vpc"
  }
}
```

### 6. `network/outputs.tf`

Atributos exportados confirmados no schema do recurso (`mcp__terraform__get_provider_details`, mesmo providerDocID): `id`, `arn`, `cidr_block`, `default_security_group_id`, `default_route_table_id`, `default_network_acl_id`, `main_route_table_id`.

```hcl
output "vpc_id" {
  description = "ID da VPC provisionada."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN da VPC provisionada."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 da VPC."
  value       = aws_vpc.this.cidr_block
}

output "default_security_group_id" {
  description = "ID do security group default criado automaticamente pela VPC."
  value       = aws_vpc.this.default_security_group_id
}

output "default_route_table_id" {
  description = "ID da route table default criada automaticamente pela VPC."
  value       = aws_vpc.this.default_route_table_id
}

output "default_network_acl_id" {
  description = "ID da network ACL default criada automaticamente pela VPC."
  value       = aws_vpc.this.default_network_acl_id
}
```

### 7. Rede

- Nenhuma subnet, gateway ou security group adicional é criado por este ADR (fora de escopo — ver Premissas #5).
- A VPC criará automaticamente: default security group, default route table e default network ACL (comportamento nativo da AWS, refletido nos outputs acima). O agente de implementação **não deve** modificar o default security group para liberar tráfego (ele deve permanecer restritivo/sem regras customizadas), conforme premissa de isolamento de rede mínimo.

### 8. IAM (least privilege para o executor do Terraform)

A role/usuário que executa `terraform plan/apply` nesta stack precisa, no mínimo, das seguintes permissões IAM. `Resource: "*"` é necessário e justificado porque as ações de API do EC2 para VPC (`CreateVpc`, `DescribeVpcs`, `ModifyVpcAttribute`, `DeleteVpc`) **não suportam restrição por ARN de recurso específico** na API da AWS (limitação documentada da IAM policy do EC2) — únicas ações neste conjunto que suportam condição por tag são as de `CreateTags`/`DeleteTags`, aqui restritas por condição de tag.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VpcCoreActions",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:DescribeTags"
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
      "Resource": "arn:aws:ec2:*:*:vpc/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "devops-ia"
        }
      }
    }
  ]
}
```

Permissões opcionais (recomendadas pela própria documentação do recurso `aws_vpc` para limpeza automática de recursos gerenciados pelo GuardDuty durante `destroy`, caso o GuardDuty esteja habilitado na conta): `ec2:DescribeVpcEndpoints`, `ec2:DescribeSecurityGroups` (recurso `*`), e `ec2:DeleteVpcEndpoints`, `ec2:ModifyVpcEndpoint`, `ec2:DeleteSecurityGroup` restritas a recursos com tag `GuardDutyManaged=true`. Incluir apenas se o GuardDuty estiver habilitado na conta de destino — **A VALIDAR** pelo agente de implementação.

### 9. Dependências e ordem de execução

1. Criar a estrutura de diretório e os 5 arquivos `.tf` exatamente como especificado acima.
2. `cd network/`
3. `terraform init` (deve baixar `hashicorp/aws` ~> 6.53.0 sem erros).
4. `terraform fmt -check` (deve retornar sem diferenças; se houver, aplicar `terraform fmt` antes de seguir).
5. `terraform validate` (deve retornar `Success!`).
6. `terraform plan -out=tfplan` — revisar o plano: deve mostrar exatamente **1 resource to add** (`aws_vpc.this`), **0 to change**, **0 to destroy**.
7. **Ponto de decisão humana obrigatório**: qualquer `terraform apply` (deste ou de qualquer plano) deve ser aprovado explicitamente por um humano antes de ser executado pelo `aws-devops-engineer`, mesmo em conta de dev. Este agente planejador não aprova nem executa o apply.
8. Após aprovação humana, o `aws-devops-engineer` executa `terraform apply tfplan`.

### 10. Parâmetros validados via MCP vs. A VALIDAR

| Parâmetro | Valor | Validado via | Status |
|---|---|---|---|
| Versão provider `hashicorp/aws` | 6.53.0 | `mcp__terraform__get_latest_provider_version` | Validado |
| Existência/schema do recurso `aws_vpc` | argumentos `cidr_block`, `tags`, `enable_dns_support`, `enable_dns_hostnames`, `instance_tenancy`; atributos `id`, `arn`, `default_security_group_id`, `default_route_table_id`, `default_network_acl_id` | `mcp__terraform__get_provider_details` (providerDocID 12705644) | Validado |
| Configuração do bloco `provider "aws"` (region, default_tags) | sintaxe e argumentos | `mcp__terraform__search_providers` (overview do provider) | Validado |
| Disponibilidade do serviço VPC na região `us-east-1` | `isAvailableIn` | `mcp__aws-mcp__aws___get_regional_availability` (filtro "Amazon Virtual Private Cloud (VPC)") | Validado |
| CIDR recomendado para VPC de ambiente Dev | `10.0.0.0/16` alinhado a padrão AWS | `mcp__aws-mcp__aws___search_documentation` (AWS Well-Architected — "Implementation priorities" / "REL02-BP03") | Validado (referência de boas práticas, não obrigatoriedade) |
| Versão do módulo comunitário `terraform-aws-modules/vpc/aws` (para descarte informado da Alternativa C) | 6.6.1 | `mcp__terraform__get_latest_module_version` | Validado |
| Versão do binário Terraform CLI no ambiente de execução | `>= 1.9.0` (assumido) | Não validável via MCP disponível | **A VALIDAR** pelo agente de implementação |
| Account ID de destino | não informado | Não validável sem input do usuário | **A VALIDAR** — decisão humana antes do apply |
| Backend de state remoto (S3/DynamoDB) | não configurado nesta ADR | N/A | **A VALIDAR** — decisão humana se uso for além de teste individual |
| GuardDuty habilitado na conta (permissões IAM extras) | desconhecido | N/A | **A VALIDAR** pelo agente de implementação |

## Consequências

**Positivas**
- Estrutura de arquivos clara, no padrão oficial de módulo Terraform, fácil de revisar em PR e de estender.
- Nenhuma credencial hardcoded; tagging obrigatório via `default_tags` garante rastreabilidade de custo desde o primeiro recurso.
- Escopo mínimo e auditável: um único recurso (`aws_vpc.this`), risco de blast radius baixo.
- Versão do provider fixada de forma restritiva (`~> 6.53.0`), evitando quebras por upgrades maiores não testados.

**Negativas / riscos e mitigação**
- **State local**: sem backend remoto, há risco de perda de state ou de execuções concorrentes conflitantes. Mitigação: uso individual/dev apenas nesta fase; migrar para backend S3+DynamoDB antes de uso em equipe ou produção (ADR futuro).
- **Sem subnets/roteamento**: a VPC criada é funcionalmente inútil para hospedar workloads até que subnets sejam adicionadas. Mitigação: já sinalizado como próximo ADR natural.
- **CIDR fixo `/16`**: se no futuro for necessário peering com outra VPC/rede on-premises que já use `10.0.0.0/16`, haverá conflito. Mitigação: documentado como premissa; validar sobreposição de CIDR antes de qualquer peering futuro.
- **Conta de destino não confirmada**: risco de aplicar na conta AWS errada. Mitigação: `allowed_account_ids` recomendado e confirmação humana obrigatória antes do apply.

**Impactos operacionais**
- Monitoramento: nenhum recurso de logging é criado por este ADR (ex.: VPC Flow Logs não solicitado nem incluído — fora de escopo; recomenda-se avaliar em ADR futuro quando subnets/ENIs existirem).
- Backup: não aplicável (VPC não tem dados a backupear).
- Manutenção: atualização do provider deve seguir a constraint `~> 6.53.0`; upgrades de minor/major do provider exigem novo ADR ou registro de mudança explícito.

## Estimativa de custo

**US$ 0,00/mês** para os recursos especificados nesta ADR. O recurso `aws_vpc` (e seus componentes default: route table, network ACL, security group) não gera cobrança direta na AWS. Nenhum NAT Gateway, VPC Endpoint, Elastic IP ou instância de tenancy dedicada é criado. Caso ADRs futuros adicionem NAT Gateway, VPC Endpoints de interface, ou IPs elásticos, esses passarão a ser os principais drivers de custo da stack de rede.

## Estratégia de rollback

1. Como há um único recurso gerenciado (`aws_vpc.this`) e nenhuma dependência downstream nesta ADR, o rollback é direto: `terraform destroy` (ou `terraform destroy -target=aws_vpc.this`) dentro de `network/`.
2. Antes de qualquer `destroy`, fazer backup do arquivo de state (`terraform.tfstate` e `terraform.tfstate.backup`, se backend local) para permitir reconstrução do histórico caso necessário.
3. Se o `apply` falhar parcialmente (cenário improvável para um único recurso, mas aplicável a ADRs futuros com mais recursos), usar `terraform plan` para diagnosticar o estado real vs. desejado antes de qualquer ação destrutiva.
4. Qualquer `destroy` em ambiente compartilhado ou que já tenha sido usado por outros recursos dependentes exige aprovação humana explícita antes da execução pelo `aws-devops-engineer`.

## Critérios de aceite

- [ ] Diretório `network/` existe na raiz do repositório contendo exatamente os arquivos: `versions.tf`, `providers.tf`, `variables.tf`, `terraform.tfvars`, `vpc.tf`, `outputs.tf`.
- [ ] `terraform init` executa sem erros e resolve o provider `hashicorp/aws` na constraint `~> 6.53.0`.
- [ ] `terraform fmt -check` não reporta diferenças.
- [ ] `terraform validate` retorna `Success!`.
- [ ] `terraform plan` mostra exatamente 1 recurso a ser criado (`aws_vpc.this`) e 0 a alterar/destruir.
- [ ] Nenhum arquivo `.tf` contém `access_key`, `secret_key` ou qualquer credencial literal.
- [ ] Após `apply` aprovado por humano: `aws_vpc.this` existe na conta/região de destino com `cidr_block = 10.0.0.0/16`, tags `Project`, `Environment`, `ManagedBy`, `Repository` e `Name` presentes.
- [ ] Outputs `vpc_id`, `vpc_arn`, `vpc_cidr_block`, `default_security_group_id`, `default_route_table_id`, `default_network_acl_id` retornam valores não vazios após `apply`.
- [ ] Nenhum recurso além de `aws_vpc.this` foi criado (sem subnets, IGW, NAT, security groups adicionais).

## Referências

- MCP Terraform — `mcp__terraform__get_latest_provider_version` (namespace `hashicorp`, name `aws`) → versão 6.53.0.
- MCP Terraform — `mcp__terraform__get_provider_capabilities` (hashicorp/aws v6.53.0) → confirmação de 1672 resources incluindo `vpc`.
- MCP Terraform — `mcp__terraform__search_providers` (service_slug `vpc`, resources) → providerDocID 12705644 (`aws_vpc`); (service_slug `aws`, overview) → doc do provider AWS.
- MCP Terraform — `mcp__terraform__get_provider_details` (providerDocID 12705644) → schema completo do recurso `aws_vpc`.
- MCP Terraform — `mcp__terraform__get_latest_module_version` (terraform-aws-modules/vpc/aws) → versão 6.6.1 (usada para descarte informado da Alternativa C).
- MCP AWS — `mcp__aws-mcp__aws___get_regional_availability` (resource_type `product`, region `us-east-1`, filtro `Amazon Virtual Private Cloud (VPC)`) → `isAvailableIn`.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` (tópico `general`, busca "Amazon VPC best practices CIDR design tagging") → AWS Well-Architected Framework, páginas "Implementation priorities" e "REL02-BP03 Ensure IP subnet allocation accounts for expansion and availability".
- Documentação oficial HashiCorp — Standard Module Structure (estrutura de arquivos `versions.tf`/`providers.tf`/`variables.tf`/`main.tf`/`outputs.tf`), aplicada por conhecimento geral do agente (não há MCP específico para validar convenções de nomenclatura de arquivos).
