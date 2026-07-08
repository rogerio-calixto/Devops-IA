# ADR-003: Redimensionamento do CIDR da VPC (`/16` → `/24`) e das Subnets (`/20` → `/26`) — Pasta `network/`

## Status
Proposto — aguardando aprovação humana explícita antes de qualquer `terraform apply` (ver seção "Decisão" e gate de aprovação). **Não aplicado.**

## Contexto

O dono do repositório solicitou que o endereçamento da stack `network/` — hoje aplicada com sucesso e sem divergências (confirmado em 2026-07-08) — seja alterado para:

- CIDR da VPC (`aws_vpc.this`, hoje `vpc-0f312e3252e7b82fe`): de `10.0.0.0/16` para `10.0.0.0/24`.
- Subnets públicas: de `10.0.0.0/20` / `10.0.16.0/20` para `10.0.0.0/26` / `10.0.0.64/26`.
- Subnets privadas: de `10.0.128.0/20` / `10.0.144.0/20` para `10.0.0.128/26` / `10.0.0.192/26`.

Este é o terceiro ADR da stack de rede. O ADR-001 criou a `aws_vpc.this` (CIDR `/16`); o ADR-002 (Aceito, aplicado) adicionou 4 subnets, Internet Gateway, route tables e associations, com `nat_gateway.enabled = false`. Este ADR **não é uma revisão do ADR-002** — o ADR-002 já foi aceito e aplicado com sucesso, e seu conteúdo histórico não deve ser reescrito. Este é um novo ADR (ADR-003) que **substitui a decisão de endereçamento** tomada no ADR-002 (CIDRs da VPC e das 4 subnets), mantendo inalteradas as demais decisões daquele ADR (topologia de 2 AZs, 1 subnet pública + 1 privada por AZ, `nat_gateway.enabled = false`, ausência de Security Groups/VPC Endpoints/Flow Logs).

**Ponto crítico identificado e validado nesta ADR**: o argumento `cidr_block` do recurso `aws_vpc` é o CIDR **primário** da VPC e é **imutável a nível de API da AWS** — não existe operação de API para "modificar" o CIDR primário de uma VPC já criada. Isso significa que a mudança solicitada (`/16` → `/24`) **não pode ser aplicada como update in-place**; ela força a **substituição completa** (destroy + create) do recurso `aws_vpc.this`. Como as 4 subnets, o Internet Gateway, as route tables e as associations dependem de `aws_vpc.this.id` (e as subnets, adicionalmente, têm seus próprios `cidr_block` alterados, também imutável para `aws_subnet`), a substituição da VPC força uma **cascata de destroy + create de absolutamente todos os 12 recursos hoje geridos pela stack `network/`** — nenhum recurso escapa dessa cascata, mesmo os que não mudam de valor nenhum (ex.: o Internet Gateway não muda nenhum atributo próprio, mas depende de `vpc_id`, que é `ForceNew`, e portanto é destruído e recriado também).

Este agente (`aws-solution-architect`) é exclusivamente planejador: **não edita nenhum arquivo `.tf`, não executa `terraform plan/apply`**. Todo o código abaixo é especificação de referência para o agente de implementação (`aws-devops-engineer`), que é quem efetivamente altera os arquivos e roda os comandos Terraform, sempre após o gate de aprovação humana descrito na seção "Decisão".

## Premissas

1. **Ambiente**: brownfield — todos os 12 recursos hoje geridos pela stack (`aws_vpc.this`, 4× `aws_subnet`, `aws_internet_gateway.this`, 2× `aws_route_table`, 4× `aws_route_table_association`) já estão aplicados e existem na conta `508591324807`, região `us-east-1`, sem divergência de state (confirmado pelo solicitante em 2026-07-08). `aws_eip.nat` e `aws_nat_gateway.this` têm `count = 0` (não existem instâncias, pois `nat_gateway.enabled = false`).
2. **Nenhum outro consumidor no repositório**: varredura do repositório (`grep` por `vpc-0f312e3252e7b82fe` e pelos CIDRs `/20` atuais) confirma que a única stack Terraform existente é `network/`; não há stack de computação, EKS, RDS ou qualquer outro `.tf` fora de `network/` referenciando esses IDs ou CIDRs. **Consequência prática**: o "blast radius" desta mudança está contido integralmente dentro da stack `network/`; não há workload real rodando sobre essas subnets hoje (a VPC segue "funcionalmente inútil para hospedar workload", conforme já registrado no ADR-002, já que nenhuma instância/ENI foi criada). Isso reduz o risco funcional da operação a zero no momento presente, mas não muda a natureza destrutiva da operação em si (ver "Consequências").
3. **Imutabilidade do CIDR primário da VPC — validada via documentação AWS (MCP AWS, `mcp__aws-mcp__aws___search_documentation`)**: a página "VPC CIDR blocks" (docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) e "Add or remove a CIDR block from your VPC" (docs.aws.amazon.com/vpc/latest/userguide/add-ipv4-cidr.html) confirmam textualmente: *"You cannot remove the primary IPv4 CIDR block"* e *"You cannot increase or decrease the size of an existing CIDR block"*. Não existe operação de API `ModifyVpc`/`ModifyVpcCidr` para o bloco primário — apenas `AssociateVpcCidrBlock`/`DisassociateVpcCidrBlock` para blocos **secundários**. Isso é a causa raiz, a nível de API da AWS, do comportamento de `ForceNew` do provider Terraform para o argumento `cidr_block` de `aws_vpc`.
4. **Imutabilidade do CIDR de uma subnet já criada — validada via documentação AWS**: a ação `ModifySubnetAttribute` (docs.aws.amazon.com/cli/latest/reference/ec2/modify-subnet-attribute.html), confirmada via MCP AWS, só suporta atributos como `map-public-ip-on-launch` e `assign-ipv6-address-on-creation` — **não existe** operação de API para alterar o `cidr_block` IPv4 de uma subnet já criada. Alterar o CIDR de uma subnet exige deletá-la e recriá-la.
5. **Limitação de ferramentas nesta sessão — registrada explicitamente**: o MCP Server Terraform (`mcp__terraform__get_provider_details`, usado nos ADR-001/ADR-002 para inspecionar o schema de `aws_vpc`/`aws_subnet`/`aws_internet_gateway`/`aws_route_table`/`aws_route_table_association` e confirmar seus argumentos `ForceNew`) **não estava disponível nesta sessão de planejamento**. A conclusão de que `cidr_block` (em `aws_vpc` e `aws_subnet`) e `vpc_id` (em `aws_internet_gateway` e `aws_route_table`) são `ForceNew` no provider `hashicorp/aws` é sustentada por: (a) o fato de nível de API da AWS descrito nas Premissas #3 e #4 (não há operação de API de update para esses atributos — logo o provider não pode fazer senão destroy+create); (b) o schema desses mesmos recursos já validado nos ADR-001/ADR-002 (mesma versão do provider, `~> 6.53.0`), que já listava esses argumentos sem qualquer menção de suporte a update in-place; (c) o comportamento consolidado e publicamente documentado do provider `hashicorp/aws` para esses recursos. **Ponto de reconfirmação final, não-opcional**: o `terraform plan` do agente de implementação (seção "Dependências e ordem de execução") reportará explicitamente `# forced replacement` para cada atributo/recurso afetado — esse plano é a fonte de verdade final antes do `apply` e deve ser conferido linha a linha contra o plano esperado descrito abaixo.
6. **`10.0.0.0/24` esgota inteiramente o espaço de endereçamento da VPC entre as 4 subnets solicitadas**: `10.0.0.0/24` cobre exatamente `10.0.0.0`–`10.0.0.255` (256 endereços). Os 4 blocos `/26` propostos (`10.0.0.0/26`, `10.0.0.64/26`, `10.0.0.128/26`, `10.0.0.192/26`) somam exatamente `4 × 64 = 256` endereços, sem sobreposição entre si e sem sobra. **Não resta nenhum CIDR livre dentro do `/24` para subnets futuras** (nova AZ, subnet isolada de banco de dados, etc.) — isso é uma redução drástica de margem de crescimento em relação ao estado atual (blocos `/20` de 4096 endereços cada, com faixas `/20` inteiras ainda livres em `10.0.0.0/16`, conforme documentado na Premissa #6 do ADR-002). Ver "Consequências" para o detalhamento e mitigação (blocos CIDR secundários).
7. **Capacidade por subnet cai de ~4091 para 59 endereços utilizáveis**: cada subnet AWS reserva 5 endereços (rede, roteador da VPC, DNS, reservado para uso futuro, broadcast). Um `/20` (4096 endereços) tem 4091 utilizáveis; um `/26` (64 endereços) tem **59 utilizáveis**. Isso é suficiente para cargas pequenas (poucas instâncias EC2, um ALB, um RDS de instância única) mas é uma restrição relevante para cargas maiores (ex.: um cluster EKS com muitos nós/pods usando ENIs por subnet). Como o CIDR exato foi especificado numericamente e de forma explícita pelo solicitante (dono do repositório), esta ADR trata isso como requisito confirmado, não como lacuna a bloquear o planejamento — mas o registra como consequência não-funcional relevante a ser conhecida antes da aprovação do `apply`.
8. **NAT Gateway (`nat_gateway.enabled = false`, decisão do ADR-002) não é afetado por esta mudança**: confirmado por inspeção do código — a variável `nat_gateway` e os recursos `aws_eip.nat`/`aws_nat_gateway.this` usam `count = var.nat_gateway.enabled ? 1 : 0` e não referenciam `cidr_block` da VPC ou das subnets em nenhuma lógica condicional além do `subnet_id` (que, se o NAT viesse a ser habilitado, apontaria para a subnet `public-a`, apenas com um CIDR/ID diferente). Como `nat_gateway.enabled` permanece `false` nesta ADR, `aws_eip.nat` e `aws_nat_gateway.this` continuam com `count = 0` — nenhuma instância desses recursos existe antes ou depois desta mudança. **A decisão de custo do ADR-002 (NAT Gateway desabilitado) é integralmente preservada.**
9. **Ambiente/perfil**: `dev`/baixo custo, mesma premissa herdada do ADR-001/ADR-002 — nenhuma mudança de ambiente lógico foi solicitada.
10. **Região/conta**: inalteradas — `us-east-1`, conta `508591324807` (Account ID agora confirmado pelo estado aplicado, resolvendo a pendência "A VALIDAR" registrada nos ADR-001/ADR-002).
11. **Backend de state**: continua não configurado (backend local), mesma pendência **A VALIDAR** herdada dos ADRs anteriores — agravada aqui, pois um `apply` que destrói e recria 12 recursos simultaneamente é o cenário de maior risco de corrupção/perda de state local até agora nesta stack. Reforça-se fortemente a recomendação de migrar para backend remoto (S3 + DynamoDB lock) **antes** deste `apply`, não depois — ver "Consequências".
12. **Convenção de nomenclatura**: este ADR não introduz nenhum arquivo `.tf` novo nem renomeia recursos — segue integralmente `.claude/rules/terraform-naming.md` sem alterações à estrutura já estabelecida. A única alteração de código é de **valores** em `network/terraform.tfvars`; nenhum arquivo `.tf` de recurso precisa ser modificado (ver "Especificação de implementação").
13. **IPv6**: fora de escopo, inalterado.
14. **Versões**: Terraform core `>= 1.9.0` e provider `hashicorp/aws ~> 6.53.0` reaproveitados sem alteração dos ADR-001/ADR-002 (nenhuma mudança de versão necessária para esta ADR).

## Requisitos considerados

- **Funcional**: CIDR da `aws_vpc.this` passa a ser `10.0.0.0/24`; as 4 subnets passam a ter os CIDRs `/26` especificados pelo solicitante, mantendo a mesma distribuição de AZs e papéis (`public-a`/`us-east-1a`, `public-b`/`us-east-1b`, `private-a`/`us-east-1a`, `private-b`/`us-east-1b`) e a mesma decisão de NAT Gateway (`enabled = false`).
- **Não-funcional**:
  - **Determinismo e auditabilidade**: o plano de `terraform plan` deve corresponder exatamente ao previsto nesta ADR (12 recursos substituídos, 0 recursos adicionados de forma isolada, 0 recursos removidos sem substituição).
  - **Gate de aprovação humana para operação destrutiva**: obrigatório e reforçado nesta ADR (ver "Decisão"), pois, diferente do ADR-002 (que era estritamente aditivo), esta ADR destrói e recria a **totalidade** dos recursos já aplicados da stack.
  - **Continuidade da decisão de custo do NAT Gateway**: não deve haver reintrodução acidental de custo recorrente (`nat_gateway.enabled` deve permanecer `false`).
  - **Rastreabilidade**: nenhuma alteração de tagging é necessária (as tags são geradas a partir de `var.project`/nomes de subnet, inalterados).
  - Escala de tráfego, RTO/RPO e compliance: não informados; mesma premissa de não-aplicabilidade herdada dos ADRs anteriores para esta stack de rede pura.

## Alternativas consideradas

### Alternativa A — Substituição completa em uma única stack/apply (RECOMENDADA)

Alterar apenas os valores em `network/terraform.tfvars` (CIDR da VPC e das 4 subnets) e aplicar um único `terraform apply` na stack `network/` já existente, usando os **mesmos endereços de recurso** (`aws_vpc.this`, `aws_subnet.public["public-a"]`, etc.). O Terraform detecta os atributos `ForceNew` alterados e executa a cascata de destroy + create de todos os 12 recursos automaticamente, na ordem correta de dependências (destrói dependentes antes da VPC, cria a VPC antes dos novos dependentes).

- **Prós**: cumpre literalmente o pedido (o CIDR *da própria VPC*, não um CIDR secundário, passa a ser `/24`); menor diff possível — nenhum arquivo `.tf` de recurso precisa ser tocado, apenas `terraform.tfvars`; mantém uma única stack, um único state, um único conjunto de outputs — sem duplicação de infraestrutura; não há workload real dependente hoje, portanto o "downtime de rede" da cascata destroy/create não afeta nada em produção.
- **Contras**: operação destrutiva sobre infraestrutura já aplicada — todos os 12 recursos recebem **novos IDs AWS** (o `vpc-0f312e3252e7b82fe` atual deixa de existir permanentemente); irreversível quanto à identidade dos recursos (um rollback de configuração não restaura os IDs originais); zero margem de CIDR livre dentro do novo `/24` para crescimento futuro dentro da própria VPC (mitigável via CIDR secundário, ver Premissa #6); qualquer referência externa manual ao ID antigo da VPC/subnets (ex.: anotações, exceções de firewall externas, bookmarks do console) quebra.
- **Impacto Well-Architected**:
  - Excelência Operacional: negativo no momento da execução (exige revisão cuidadosa do plano e aprovação humana explícita, maior risco de erro humano em um `apply` que destrói tudo); neutro/positivo depois (stack única, sem duplicação, fácil de auditar).
  - Segurança: neutro (mesma postura de rede é recriada de forma idêntica — mesmo IGW, mesmas route tables, mesma ausência de Security Groups customizados).
  - Confiabilidade: negativo transitório (janela de rede indisponível durante a cascata — irrelevante hoje por não haver workload, mas seria crítico se houvesse); neutro após a conclusão.
  - Eficiência de Performance: neutro.
  - Otimização de Custo: neutro/positivo — nenhum custo recorrente novo (todos os recursos envolvidos são gratuitos: VPC, subnets, IGW, route tables, associations; NAT permanece desabilitado).
  - Sustentabilidade: neutro (mesmo volume final de recursos; sem infraestrutura duplicada ou ociosa).
- **Estimativa de custo mensal adicional**: US$ 0,00 (nenhum recurso pago é criado, alterado ou mantido além do já existente; ver "Estimativa de custo").

### Alternativa B — CIDR secundário não destrutivo, mantendo o `/16` primário

Em vez de trocar o CIDR primário, manter `aws_vpc.this` com `cidr_block = 10.0.0.0/16` (sem tocar) e associar um bloco secundário via `aws_vpc_ipv4_cidr_block_association` (ex.: `10.1.0.0/24`), criando as 4 novas subnets `/26` dentro desse bloco secundário. As 4 subnets `/20` e demais recursos do ADR-002 permaneceriam intactos e em paralelo.

- **Prós**: zero downtime, zero destruição de recursos já aplicados; totalmente aditivo e reversível (basta desassociar o CIDR secundário e destruir as novas subnets); AWS permite até 4 CIDRs secundários IPv4 por VPC (validado via MCP AWS, "VPC CIDR blocks"), então essa alternativa tem espaço técnico de sobra.
- **Contras — por que não atende ao pedido literal do usuário**:
  1. O pedido foi explícito: *"CIDR da VPC passe a ser `10.0.0.0/24`"* — isto é, o **CIDR primário/próprio** da VPC. Nesta alternativa o CIDR primário da VPC **permanece `10.0.0.0/16` para sempre** (é imutável, ver Premissa #3); a VPC nunca "passa a ser" `/24` em nenhum sentido técnico — ela passa a ter *dois* CIDRs, um `/16` e um `/24` (ou outro), o que é uma resposta diferente da pergunta feita.
  2. **Tecnicamente inviável para o CIDR exato pedido**: o próprio `10.0.0.0/24` solicitado está contido dentro do `10.0.0.0/16` primário já existente. A documentação da AWS (validada via MCP, "VPC CIDR blocks") exige que *"The CIDR block must not overlap with any existing CIDR block that's associated with the VPC"* — logo a AWS **rejeitaria** a tentativa de associar `10.0.0.0/24` como bloco secundário enquanto o `10.0.0.0/16` primário existir, pois há sobreposição total. Para viabilizar esta alternativa seria necessário usar um CIDR secundário diferente do pedido (ex.: `10.1.0.0/24`), entregando um endereçamento distinto do que foi solicitado.
  3. Deixaria as 4 subnets antigas (`/20`) e todos os recursos do ADR-002 vivos e em paralelo, aumentando a complexidade da stack (2 conjuntos de subnets, potencial ambiguidade sobre qual usar em ADRs futuros de computação) em vez de simplificá-la, o que contraria o sentido de um "redimensionamento".
- **Impacto Well-Architected**: Excelência Operacional positivo (zero risco de outage); Confiabilidade máxima (nenhuma interrupção); Segurança neutra; Custo neutro (US$ 0,00). Apesar do perfil de risco favorável, esta alternativa é **descartada** por não atender ao requisito funcional literal solicitado (e ser tecnicamente bloqueada para o CIDR exato pedido).
- **Estimativa de custo mensal adicional**: US$ 0,00.

### Alternativa C — Blue/green: nova VPC paralela, cutover manual, depois destruição da antiga

Criar uma segunda VPC (`aws_vpc.this_v2` ou stack Terraform separada) já com `cidr_block = 10.0.0.0/24` e as 4 subnets `/26` solicitadas, validar a nova topologia isoladamente, e só então destruir a `aws_vpc.this` original e seus 11 dependentes, eventualmente consolidando o state (renomeando `this_v2` de volta para `this` via bloco `moved`).

- **Prós**: permite validar a nova rede antes de destruir a antiga; reduz a sensação de "ponto sem volta" ao ter as duas versões coexistindo temporariamente.
- **Contras**: o benefício central desta alternativa (evitar downtime de algo que já está em produção) **não se aplica ao estado atual do repositório** — não há nenhuma instância, ENI, ALB ou workload rodando sobre a VPC hoje (confirmado na Premissa #2); logo não há nada a "proteger" de uma janela de indisponibilidade de rede. Em troca, esta alternativa adiciona complexidade real e desnecessária: gestão manual de dois conjuntos de recursos de rede em paralelo, mais um bloco `moved` para consolidar o state depois, mais superfície para erro humano, e — ao final — os 12 recursos originais são destruídos de qualquer forma (o "risco de destruição" não é eliminado, apenas adiado e fatiado). Também exigiria, temporariamente, uma segunda VPC com CIDR não sobreposto (já que `10.0.0.0/24` sobrepõe `10.0.0.0/16`, as duas VPCs não poderiam coexistir com os CIDRs exatos pedidos sem um CIDR temporário provisório adicional).
- **Impacto Well-Architected**: Excelência Operacional negativo (mais passos manuais, mais chance de erro, sem ganho real dado o contexto); Confiabilidade neutra/positiva apenas em teoria (irrelevante sem workload real); Custo neutro (US$ 0,00, mesmos tipos de recursos gratuitos). Descartada por adicionar complexidade sem benefício mensurável no cenário atual.
- **Estimativa de custo mensal adicional**: US$ 0,00.

## Decisão

**Alternativa A — substituição completa (destroy + create em cascata) dos 12 recursos da stack `network/`, dentro do mesmo state e dos mesmos endereços de recurso, alterando exclusivamente valores em `network/terraform.tfvars`.**

Justificativa: o pedido do solicitante é inequívoco e literal — o CIDR *da VPC* (o bloco primário) deve se tornar `10.0.0.0/24`, não um bloco secundário. A Alternativa B, embora não-destrutiva, **não responde à pergunta feita** (o CIDR primário nunca mudaria) e é **tecnicamente bloqueada pela própria AWS** para o CIDR exato solicitado, por sobreposição com o `/16` já existente. A Alternativa C adiciona uma camada inteira de complexidade operacional (segunda VPC temporária, gestão manual de cutover, bloco `moved` de consolidação) para mitigar um risco — indisponibilidade de workload em produção — que **não existe hoje** neste repositório, já que nenhuma carga real depende da VPC (confirmado por varredura do repositório, Premissa #2). Dado que (a) o pedido é literal e explícito, (b) não há workload real em risco, e (c) o custo mensal permanece US$ 0,00 em qualquer alternativa, a Alternativa A é a que entrega exatamente o que foi pedido com o menor custo de engenharia e a menor superfície de erro (menor diff de código: apenas `terraform.tfvars`).

**GATE DE APROVAÇÃO HUMANA — OBRIGATÓRIO E REFORÇADO NESTA ADR**: diferentemente do ADR-002 (que era estritamente aditivo sobre uma VPC já aplicada), esta ADR **destrói e recria a totalidade dos 12 recursos já aplicados** na stack `network/`, incluindo o próprio `aws_vpc.this` (`vpc-0f312e3252e7b82fe`). Isso vale mesmo em ambiente "dev" e mesmo sem custo recorrente envolvido — o risco aqui não é financeiro, é de **perda de identidade de recursos já em uso** (novos IDs AWS para tudo) e de uma janela de indisponibilidade de rede completa durante o `apply`. Nenhum `terraform apply` desta ADR pode ser executado pelo `aws-devops-engineer` sem confirmação humana explícita e documentada, que deve registrar ciência de que:
1. Todos os 12 recursos hoje existentes (`aws_vpc.this` e seus 11 dependentes) serão destruídos e recriados com novos IDs AWS;
2. Não há como reverter para os IDs AWS originais depois de destruídos, mesmo revertendo a configuração;
3. Isso é aceitável porque não há workload real dependente hoje (ver Premissa #2) — se isso deixar de ser verdade antes do `apply` (ex.: alguém já lançou uma instância manualmente nessas subnets fora do Terraform), a aprovação deve ser revisitada antes de prosseguir.

## Especificação de implementação (para o agente DevOps)

### 1. Escopo da alteração de código

**Único arquivo a ser alterado: `network/terraform.tfvars`.** Nenhum arquivo `.tf` de recurso (`vpc.tf`, `vpc.public-subnets.tf`, `vpc.private-subnets.tf`, `vpc.internet-gateway.tf`, `vpc.public-route-table.tf`, `vpc.private-route-table.tf`, `vpc.nat-gateway.tf`, `vpc.nat-gateway-eip.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf`) precisa de qualquer modificação — todos já são parametrizados via `var.vpc.cidr_block` e `var.vpc.public_subnets`/`var.vpc.private_subnets`, sem nenhum CIDR hardcoded no código de recurso. O bloco `moved { from = aws_vpc.main, to = aws_vpc.this }` em `vpc.tf` permanece inalterado (é inócuo para esta operação — o state já não contém `aws_vpc.main` desde a migração anterior).

### 2. `network/terraform.tfvars` (arquivo completo após a alteração)

```hcl
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
  # Decisão do ADR-002, preservada integralmente por esta ADR (não afetada pelo
  # redimensionamento de CIDR): desabilitado, sem custo recorrente adicional.
  enabled = false
}
```

**Diff em relação ao valor atual**: apenas os 5 valores de CIDR mudam (`vpc.cidr_block`, e os 4 `cidr_block` dentro de `public_subnets`/`private_subnets`). `project`, `nat_gateway`, nomes de subnet e `availability_zone` permanecem idênticos byte-a-byte.

### 3. Comportamento esperado do Terraform (sem alterar nenhum outro arquivo)

Como todos os recursos referenciam `var.vpc.cidr_block` (em `aws_vpc.this`) e `var.vpc.public_subnets[*].cidr_block`/`var.vpc.private_subnets[*].cidr_block` (em `aws_subnet.public`/`aws_subnet.private`, ambos `for_each`), a mudança de valores acima é suficiente para que o Terraform recalcule o grafo de dependências e determine a cascata de substituição a seguir, **sem que o agente de implementação precise adicionar `lifecycle { create_before_destroy = true }` ou qualquer outro ajuste** — o comportamento padrão (destroy dependentes → destroy VPC → create VPC → create novos dependentes) é o esperado e aceito nesta ADR.

Recursos que sofrerão substituição forçada (`-/+ destroy and then create replacement`), na ordem em que o Terraform os processará:

1. `aws_route_table_association.public["public-a"]`, `["public-b"]` — destruídos (dependem de `aws_subnet.public[*].id` e `aws_route_table.public.id`, ambos recriados).
2. `aws_route_table_association.private["private-a"]`, `["private-b"]` — destruídos (mesma razão).
3. `aws_route_table.public`, `aws_route_table.private` — destruídos (dependem de `vpc_id`, `ForceNew`).
4. `aws_internet_gateway.this` — destruído (depende de `vpc_id`, `ForceNew`).
5. `aws_subnet.public["public-a"]`, `["public-b"]`, `aws_subnet.private["private-a"]`, `["private-b"]` — destruídos (dependem de `vpc_id`, `ForceNew`, **e** têm `cidr_block` próprio alterado, também `ForceNew`).
6. `aws_vpc.this` — destruído e recriado (novo ID AWS; `cidr_block` `ForceNew`).
7. Novos `aws_subnet.public["public-a"]`, `["public-b"]`, `aws_subnet.private["private-a"]`, `["private-b"]` — criados, referenciando o novo `aws_vpc.this.id`.
8. Novo `aws_internet_gateway.this` — criado, referenciando o novo `aws_vpc.this.id`.
9. Novas `aws_route_table.public`, `aws_route_table.private` — criadas.
10. Novas `aws_route_table_association.public["public-a"]`, `["public-b"]`, `aws_route_table_association.private["private-a"]`, `["private-b"]` — criadas.

`aws_eip.nat` e `aws_nat_gateway.this` permanecem com `count = 0` durante toda a operação — **nenhuma ação sobre eles** (não aparecem no plano).

### 4. IAM (least privilege para o executor do Terraform)

**Nenhuma permissão IAM nova é necessária.** Todas as ações de API envolvidas nesta substituição (`ec2:CreateVpc`, `ec2:DeleteVpc`, `ec2:CreateSubnet`, `ec2:DeleteSubnet`, `ec2:CreateInternetGateway`, `ec2:DeleteInternetGateway`, `ec2:AttachInternetGateway`, `ec2:DetachInternetGateway`, `ec2:CreateRouteTable`, `ec2:DeleteRouteTable`, `ec2:AssociateRouteTable`, `ec2:DisassociateRouteTable`, `ec2:CreateTags`, `ec2:DeleteTags`, etc.) já estão cobertas pelas policies especificadas no ADR-001 (seção 8) e no ADR-002 (seção 12), que devem continuar anexadas à role/usuário que executa o Terraform desta stack. Nenhuma dessas policies precisa ser alterada para esta ADR.

### 5. Dependências e ordem de execução

1. **Pré-requisito obrigatório — backup do state**: antes de qualquer comando, copiar `network/terraform.tfstate` (e `terraform.tfstate.backup`, se existir) para um local seguro fora do diretório versionado (ex.: `cp network/terraform.tfstate /caminho/seguro/terraform.tfstate.pre-adr003-$(date +%Y%m%d%H%M%S)`), dado que o backend continua local (pendência **A VALIDAR** herdada dos ADR-001/002, agravada aqui pelo volume de recursos afetados simultaneamente).
2. Confirmar, via `terraform state list` dentro de `network/`, que os 12 recursos esperados estão presentes no state antes de prosseguir (`aws_vpc.this`, `aws_subnet.public["public-a"]`, `aws_subnet.public["public-b"]`, `aws_subnet.private["private-a"]`, `aws_subnet.private["private-b"]`, `aws_internet_gateway.this`, `aws_route_table.public`, `aws_route_table.private`, `aws_route_table_association.public["public-a"]`, `aws_route_table_association.public["public-b"]`, `aws_route_table_association.private["private-a"]`, `aws_route_table_association.private["private-b"]`).
3. Alterar **exclusivamente** `network/terraform.tfvars` conforme especificado na seção 2.
4. `cd network/`
5. `terraform init -upgrade=false` (nenhum provider novo é necessário).
6. `terraform fmt -check` — corrigir com `terraform fmt` se houver diferenças (não deveria haver, pois é só alteração de valor em `.tfvars`, arquivo não formatado por `terraform fmt` da mesma forma que `.tf`, mas o comando deve ser rodado por consistência do processo).
7. `terraform validate` — deve retornar `Success!`.
8. `terraform plan -out=tfplan` — **revisar linha a linha, sem exceção**. O plano esperado é:
   - **12 to add, 0 to change, 12 to destroy** (cada um dos 12 recursos aparece como `-/+ ... (forced replacement)`, contado por Terraform como 1 add + 1 destroy no resumo).
   - Todos os 12 endereços de recurso listados na seção 3 aparecem com o motivo `# forced replacement` associado a `cidr_block` (para `aws_vpc.this` e para os 4 `aws_subnet`) ou a `vpc_id` (para os demais).
   - `aws_eip.nat` e `aws_nat_gateway.this` **não aparecem no plano** (permanecem `count = 0`).
   - Nenhum recurso fora desses 12 é tocado.
   - Se o plano divergir disso (ex.: mostrar update in-place em vez de replace, ou tocar em `aws_eip`/`aws_nat_gateway`), **parar imediatamente** e não prosseguir — isso indicaria uma premissa incorreta desta ADR (ver Premissa #5) e exige nova análise antes de qualquer `apply`.
9. **Ponto de decisão humana obrigatório**: apresentar o plano completo (`terraform show tfplan`) a um humano responsável e obter aprovação explícita e documentada, incluindo ciência expressa dos 3 pontos listados na seção "Decisão" (novos IDs AWS para tudo, impossibilidade de restaurar os IDs antigos, ausência de workload real em risco hoje). Este agente planejador não aprova nem executa o `apply`.
10. Após aprovação humana, o `aws-devops-engineer` executa `terraform apply tfplan`.
11. Imediatamente após o `apply`, executar `terraform output` e registrar os novos valores de `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `internet_gateway_id`, `public_route_table_id`, `private_route_table_id` — esses são os novos identificadores AWS que substituem os anteriores (`vpc-0f312e3252e7b82fe` e demais) em qualquer documentação ou referência externa ao Terraform.

### 6. Parâmetros validados via MCP vs. A VALIDAR

| Parâmetro | Valor / Conclusão | Validado via | Status |
|---|---|---|---|
| CIDR primário de uma VPC não pode ser removido/redimensionado via API | *"You cannot remove the primary IPv4 CIDR block"*; *"You cannot increase or decrease the size of an existing CIDR block"* | `mcp__aws-mcp__aws___search_documentation` — "VPC CIDR blocks" (docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) e "Add or remove a CIDR block from your VPC" (docs.aws.amazon.com/vpc/latest/userguide/add-ipv4-cidr.html) | Validado |
| Um bloco CIDR (primário ou secundário) não pode sobrepor outro já associado à mesma VPC | *"The CIDR block must not overlap with any existing CIDR block that's associated with the VPC"* | `mcp__aws-mcp__aws___search_documentation` — "VPC CIDR blocks" | Validado (usado para descartar a Alternativa B para o CIDR exato pedido) |
| Uma VPC pode ter até 4 CIDRs secundários IPv4 além do primário | *"can add up to four (4) secondary CIDR blocks after creation of the VPC"* | `mcp__aws-mcp__aws___search_documentation` — "Amazon VPC FAQs" (aws.amazon.com/vpc/faqs) | Validado (usado como mitigação de crescimento futuro na seção "Consequências") |
| `ModifySubnetAttribute` não suporta alterar o `cidr_block` de uma subnet existente (só atributos como `map-public-ip-on-launch`, `assign-ipv6-address-on-creation`) | confirmado — lista de atributos suportados não inclui CIDR | `mcp__aws-mcp__aws___search_documentation` — "modify-subnet-attribute — AWS CLI Command Reference" (docs.aws.amazon.com/cli/latest/reference/ec2/modify-subnet-attribute.html) | Validado |
| Schema/comportamento `ForceNew` dos recursos `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_route_table`, `aws_route_table_association` no provider `hashicorp/aws` | Inferido a partir dos fatos de API acima + schema já revisado nos ADR-001/ADR-002 (mesma versão de provider `~> 6.53.0`) | **`mcp__terraform__get_provider_details` indisponível nesta sessão** — não foi possível revalidar diretamente | **A VALIDAR / reconfirmar** — o `terraform plan` do passo 8 da seção anterior é a fonte de verdade final; qualquer divergência frente ao plano esperado deve interromper a execução |
| Espaço de endereçamento: `10.0.0.0/24` = 256 endereços; 4× `/26` = 4×64 = 256 endereços, sem sobra | Aritmética CIDR padrão (RFC 4632), sem necessidade de fonte externa | Cálculo direto | Validado |
| Endereços utilizáveis por subnet AWS (`total - 5`) | `/20` → 4091; `/26` → 59 | Conhecimento consolidado do comportamento de reserva de endereços da AWS (rede, roteador, DNS, futuro, broadcast), já referenciado implicitamente no ADR-002 | Validado |
| Account ID de destino | `508591324807` (confirmado pelo estado já aplicado, resolvendo pendência dos ADR-001/002) | Informado pelo solicitante nesta tarefa | Validado |
| Versão do provider `hashicorp/aws` e do Terraform core | `~> 6.53.0` / `>= 1.9.0`, sem mudança necessária | Reaproveitado dos ADR-001/ADR-002 (`mcp__terraform__get_latest_provider_version`, sessões anteriores) | Validado (não revalidado nesta sessão por não haver mudança de versão envolvida) |
| Backend de state remoto (S3/DynamoDB) | continua não configurado | N/A | **A VALIDAR** — mesma pendência agravada, ver "Consequências" |

## Consequências

**Positivas**
- Endereçamento passa a corresponder exatamente ao especificado pelo solicitante: VPC `10.0.0.0/24`, subnets `/26` nos 4 blocos pedidos, sem ambiguidade.
- Nenhum arquivo `.tf` de recurso precisa ser alterado — o design parametrizado dos ADR-001/002 (nenhum CIDR hardcoded fora de `terraform.tfvars`) comprova seu valor aqui: o diff de código é mínimo (apenas 5 valores em um arquivo).
- Nenhuma mudança de custo: a decisão de NAT Gateway desabilitado do ADR-002 é preservada integralmente; todos os 12 recursos recriados continuam sendo gratuitos.
- Nenhuma permissão IAM nova é necessária.

**Negativas / riscos e mitigação**
- **Operação destrutiva sobre infraestrutura já aplicada**: os 12 recursos hoje existentes (incluindo `aws_vpc.this` = `vpc-0f312e3252e7b82fe`) são destruídos permanentemente e substituídos por novos, com **novos IDs AWS**. Mitigação: gate de aprovação humana obrigatório e explícito (ver "Decisão"); backup de state antes do `apply`; confirmação prévia de que não há workload real dependente (Premissa #2).
- **Irreversibilidade de identidade**: reverter `terraform.tfvars` para os valores antigos (`/16`/`/20`) e reaplicar **não restaura** o `vpc-0f312e3252e7b82fe` original nem os IDs das subnets/IGW/route tables antigas — apenas recria uma nova VPC/subnets com os valores antigos, sob novos IDs novamente. Mitigação: qualquer referência externa a esses IDs (documentação, scripts manuais, exceções de segurança fora do Terraform) deve ser atualizada após o `apply`, e um novo rollback não é "grátis" (também é uma substituição completa).
- **Zero margem de CIDR livre dentro do novo `/24` da VPC**: os 4 blocos `/26` consomem 100% do espaço de endereçamento primário. Mitigação disponível e já validada: a AWS permite associar até 4 blocos CIDR IPv4 **secundários** (`aws_vpc_ipv4_cidr_block_association`, `/28` a `/16`, não sobrepostos) a esta mesma VPC no futuro, sem precisar destruir novamente o CIDR primário — essa é a via correta para crescimento futuro, e deve ser tratada como um ADR específico quando/se a necessidade surgir.
- **Capacidade por subnet reduzida para 59 endereços utilizáveis** (de 4091): adequado para poucas instâncias/ENIs; pode ser insuficiente para cargas como um cluster EKS com muitos nós. Mitigação: nenhuma ação necessária agora (requisito explícito do solicitante); reavaliar em ADR futuro se um workload específico exigir mais endereços por subnet (nesse caso, crescer via CIDR secundário, não redimensionando novamente o `/24` primário).
- **State local com o maior volume de mudanças simultâneas desta stack até agora** (12 recursos substituídos em um único `apply`): maior risco de state corrompido/parcialmente aplicado em caso de falha a meio caminho. Mitigação: backup de state obrigatório antes do `apply` (seção "Especificação de implementação", passo 1); reforça-se a recomendação, já pendente desde o ADR-001, de migrar para backend remoto (S3 + DynamoDB) antes deste `apply`, dado que este é o cenário de maior risco enfrentado pela stack até o momento.
- **Janela de indisponibilidade de rede completa durante a cascata**: entre o destroy da VPC antiga e o create da nova, a stack fica sem nenhum recurso de rede válido. Mitigação: irrelevante no estado atual (sem workload real), mas deve ser tratado como bloqueador de aprovação caso, no momento do `apply`, já exista algum recurso de computação manual ou de outra stack dependendo desta rede (ver ponto 3 do gate de aprovação humana).

**Impactos operacionais**
- Monitoramento: nenhum recurso de logging é criado ou alterado por esta ADR (mesma ausência de VPC Flow Logs dos ADRs anteriores).
- Backup: não aplicável a dados (recursos de rede não armazenam dados), mas backup de **state** é obrigatório antes do `apply`, conforme especificado.
- Manutenção: após este `apply`, qualquer documentação, runbook ou referência manual ao `vpc-0f312e3252e7b82fe` ou aos CIDRs `/20` antigos deve ser atualizada para os novos valores (`10.0.0.0/24` e os 4 `/26`) e para os novos IDs AWS reportados nos outputs do Terraform.

## Estimativa de custo

**US$ 0,00/mês adicional.** Todos os 12 recursos envolvidos (VPC, subnets, Internet Gateway, route tables, route table associations) são gratuitos na AWS, independentemente de CIDR ou tamanho. A decisão de `nat_gateway.enabled = false` do ADR-002 é preservada integralmente — nenhum NAT Gateway ou Elastic IP é criado por esta ADR. Não há, portanto, nenhum driver de custo novo introduzido por este redimensionamento; o custo total da stack `network/` continua **US$ 0,00/mês**, exatamente como ao final do ADR-002.

## Estratégia de rollback

1. **Antes do `apply`**: se o `terraform plan` (passo 8 da seção "Dependências e ordem de execução") divergir do esperado (12 to add / 12 to destroy, exatamente os recursos listados), **não aplicar** — interromper e revisar esta ADR ou o estado real da stack antes de prosseguir.
2. **Durante/após o `apply`, se falhar parcialmente**: usar `terraform plan` para diagnosticar o estado real vs. desejado antes de qualquer ação adicional — não presumir que um recurso "provavelmente" foi criado ou destruído. Dada a ordem de dependências (seção 3), uma falha a meio caminho tende a deixar o state em um ponto identificável (ex.: subnets/route tables antigas já destruídas, VPC nova já criada, mas subnets novas ainda não criadas) — o `terraform plan` seguinte deve mostrar exatamente o que falta para completar a convergência; normalmente resolve-se com um novo `terraform apply` (sem `-target`) usando o state já parcialmente atualizado.
3. **Reversão de configuração (não restaura IDs antigos)**: para voltar aos valores de CIDR do ADR-002 (`10.0.0.0/16` / `/20`), reverter `network/terraform.tfvars` para os valores anteriores (documentados no ADR-002, seção 3) e repetir o mesmo processo de `plan`/aprovação humana/`apply` desta ADR — isso executa uma **nova** cascata de destroy + create (não é uma operação "grátis" nem instantânea), gerando **novos** IDs AWS novamente, diferentes tanto dos IDs atuais quanto dos IDs originais do ADR-002.
4. **Backup de state**: o backup feito no passo 1 da "Especificação de implementação" permite, na pior hipótese (state corrompido de forma irrecuperável), reconstruir manualmente o entendimento do que existia antes desta ADR para fins de auditoria/comparação — mas não permite "importar de volta" os recursos AWS já destruídos (eles deixam de existir fisicamente na AWS assim que destruídos; backup de state não é backup de recursos AWS).
5. Qualquer rollback desta ADR está sujeito ao mesmo gate de aprovação humana obrigatório descrito na seção "Decisão" — nenhuma reversão é menos destrutiva do que a mudança original.

## Critérios de aceite

- [ ] `network/terraform.tfvars` contém exatamente `vpc.cidr_block = "10.0.0.0/24"` e os 4 CIDRs de subnet especificados (`10.0.0.0/26`, `10.0.0.64/26`, `10.0.0.128/26`, `10.0.0.192/26`), com nomes de subnet e `availability_zone` inalterados em relação ao ADR-002.
- [ ] Nenhum arquivo `.tf` de recurso foi modificado (apenas `terraform.tfvars`).
- [ ] Backup do `terraform.tfstate` (e `.backup`, se existir) foi feito e armazenado fora do diretório versionado, antes do `apply`.
- [ ] `terraform init`, `terraform fmt -check` e `terraform validate` executam sem erros.
- [ ] `terraform plan` mostra exatamente **12 to add, 0 to change, 12 to destroy**, todos os 12 endereços de recurso listados na seção "Comportamento esperado do Terraform" com motivo `forced replacement`, e **nenhuma menção** a `aws_eip.nat`/`aws_nat_gateway.this`.
- [ ] **Aprovação humana explícita e documentada** foi registrada para este `apply`, com ciência expressa dos 3 pontos do gate de aprovação (novos IDs, irreversibilidade de identidade, ausência de workload em risco confirmada no momento do `apply`).
- [ ] Após `apply`: `aws_vpc.this` existe com `cidr_block = 10.0.0.0/24` e um novo `id` (diferente de `vpc-0f312e3252e7b82fe`).
- [ ] Após `apply`: as 4 subnets existem com os CIDRs `/26` corretos, nas AZs corretas (`public-a`/`us-east-1a`, `public-b`/`us-east-1b`, `private-a`/`us-east-1a`, `private-b`/`us-east-1b`), com tags `Project`, `Environment`, `ManagedBy`, `Repository`, `Name` e `Tier` presentes.
- [ ] Após `apply`: `aws_internet_gateway.this` está anexado (`attached`) à nova `aws_vpc.this`; a route table pública tem rota `0.0.0.0/0` → Internet Gateway e está associada às duas subnets públicas; a route table privada está associada às duas subnets privadas e não tem rota de saída além do `local` implícito (consistente com `nat_gateway.enabled = false`, decisão inalterada do ADR-002).
- [ ] Após `apply`: nenhum `aws_eip`/`aws_nat_gateway` foi criado (consistente com `nat_gateway.enabled = false`).
- [ ] Outputs `vpc_id`, `vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids`, `internet_gateway_id`, `public_route_table_id`, `private_route_table_id` retornam valores não vazios e refletem os novos IDs/CIDRs; `nat_gateway_id`/`nat_gateway_public_ip` continuam `null`.
- [ ] Os novos valores de output foram registrados/comunicados para substituir qualquer referência ao `vpc-0f312e3252e7b82fe` e aos CIDRs `/20` antigos em documentação ou uso externo ao Terraform.

## Referências

- MCP AWS — `mcp__aws-mcp__aws___search_documentation` — "VPC CIDR blocks" (docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html): confirmação de que um CIDR associado não pode ser redimensionado nem sobreposto a outro já existente na mesma VPC, e do limite de até 4 CIDRs secundários IPv4.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` — "Add or remove a CIDR block from your VPC" (docs.aws.amazon.com/vpc/latest/userguide/add-ipv4-cidr.html): confirmação de que o CIDR primário de uma VPC não pode ser removido/alterado.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` — "Amazon VPC FAQs" (aws.amazon.com/vpc/faqs): confirmação do limite de CIDRs secundários por VPC.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` — "modify-subnet-attribute — AWS CLI Command Reference" (docs.aws.amazon.com/cli/latest/reference/ec2/modify-subnet-attribute.html): confirmação de que não há suporte de API para alterar o CIDR de uma subnet já criada.
- **Limitação registrada**: o MCP Server Terraform (usado nos ADR-001/ADR-002 via `mcp__terraform__get_provider_details` para inspecionar diretamente o schema/flags `ForceNew` dos recursos `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_route_table`, `aws_route_table_association`) não estava disponível nesta sessão de planejamento. A conclusão sobre `ForceNew` foi sustentada por evidência de API AWS (acima) e pelo schema já revisado nos ADR-001/ADR-002; o `terraform plan` do agente de implementação é o ponto de reconfirmação final e não-opcional antes do `apply` (ver Premissa #5 e seção "Dependências e ordem de execução", passo 8).
- ADR-001 (`docs/adr/ADR-001-network-vpc.md`) — criação original de `aws_vpc.this` com CIDR `/16`; policies IAM base reaproveitadas sem alteração.
- ADR-002 (`docs/adr/ADR-002-network-subnets.md`) — criação das 4 subnets, IGW, route tables, associations e decisão de `nat_gateway.enabled = false`, todos preservados nesta ADR exceto os valores de CIDR.
- Estado aplicado em produção-dev, confirmado pelo solicitante em 2026-07-08: `vpc-0f312e3252e7b82fe`, conta `508591324807`, região `us-east-1`, sem divergência de state — base factual para toda a análise de impacto desta ADR.
- `.claude/rules/terraform-naming.md` — convenção de arquivos/variáveis, integralmente preservada (nenhum arquivo novo, nenhuma renomeação).
