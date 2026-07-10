# ADR-005: Migração da Stack `network/` para Backend Remoto S3 (Locking Nativo via `use_lockfile`)

## Status
Proposto — todas as premissas de negócio que estavam **A VALIDAR** (Premissas #7, #8 e #11) foram confirmadas pelo solicitante em **2026-07-10** (ver "Premissas" e seção "Decisão"). Este ADR está **pronto para execução**, mas continua **aguardando aprovação humana explícita antes de qualquer comando** (edição de `network/versions.tf`, `terraform init -migrate-state`, resposta ao prompt de migração) — gate mantido, ver "Decisão". Este ADR cobre **exclusivamente** a migração da stack `network/`. **Não aplicado.**

## Contexto

O ADR-004 criou e já aplicou com sucesso a stack `remote-backend/`, que provisionou o bucket S3 `devops-ia-tfstate-508591324807-us-east-1` como backend remoto de state Terraform para este repositório, com locking nativo via `use_lockfile` (sem DynamoDB). O próprio ADR-004 foi explícito em deixar a migração de qualquer stack consumidora fora do seu escopo:

> "Escopo explicitamente fora deste ADR: a migração da stack `network/` (hoje com state local) para efetivamente usar este backend (`terraform init -migrate-state` em `network/`). Essa migração é uma operação de alto risco sobre uma stack já aplicada [...] e, por isso, decidiu-se tratá-la como matéria de **um ADR futuro e dedicado (candidato a ADR-005)**."

Este ADR é esse ADR dedicado. Segue o mesmo padrão já estabelecido pelo ADR-003 (uma mudança de alto risco sobre infraestrutura já aplicada — ali, um resize de CIDR que acabou substituindo 12 recursos; aqui, uma migração de mecanismo de persistência de state — merece seu próprio contrato, com seu próprio gate de aprovação, em vez de ser anexada a um ADR de escopo diferente).

Hoje a stack `network/` tem state **local** (`network/terraform.tfstate`, em disco no executor) e **12 recursos já aplicados**: `aws_vpc.this`, 4× `aws_subnet` (2 públicas + 2 privadas), `aws_internet_gateway.this`, 2× `aws_route_table` (pública/privada) e 4× `aws_route_table_association` (confirmado por leitura de `network/outputs.tf`/`network/variables.tf` — `nat_gateway.enabled = false` hoje, portanto `aws_eip.nat`/`aws_nat_gateway.this` têm `count = 0` e não existem no state atual). Qualquer operação sobre o mecanismo de state desses 12 recursos é, por definição, uma operação de alto risco: um erro de procedimento pode deixar a stack sem um state válido em lugar nenhum (nem local, nem remoto), o que tornaria a infraestrutura já aplicada na AWS órfã de rastreamento pelo Terraform.

**Este agente (`aws-solution-architect`) é exclusivamente planejador**: não cria, não edita e não aplica nenhum arquivo `.tf`, e não executa `terraform init/plan/apply`. Todo o código e todos os comandos abaixo são especificação de referência para o agente de implementação (`aws-devops-engineer`), que deve executá-los manualmente, exatamente como descrito na seção "Especificação de implementação".

**Escopo explicitamente coberto por este ADR**: migração do backend de state da stack `network/` de local para S3 (`bucket = devops-ia-tfstate-508591324807-us-east-1`, `key = network/terraform.tfstate`, locking via `use_lockfile`), incluindo o bloco `backend "s3"` em `network/versions.tf`, a policy IAM real para a stack `network/`, o procedimento exato de migração (`terraform init -migrate-state`), a verificação pós-migração e o tratamento de falhas/lock travado.

**Escopo explicitamente fora deste ADR**: (a) qualquer alteração na stack `remote-backend/` — ela **permanece com state local, propositalmente, por bootstrap** (ver ADR-004, "Contexto"); (b) qualquer alteração de recurso de infraestrutura de rede em `network/` (VPC, subnets, IGW, route tables, NAT Gateway) — este é, deliberadamente, um ADR de migração **pura** de backend, sem mudança de infraestrutura; (c) migração de qualquer outra stack futura para o backend remoto (cada uma, se/quando existir, deve ter seu próprio ADR de migração, seguindo o mesmo padrão).

## Premissas

Assumidas por ausência de informação de negócio explícita; todas as premissas que estavam marcadas **A VALIDAR** na versão original deste ADR (#7, #8 e #11) foram confirmadas pelo solicitante em **2026-07-10** — ver o texto de confirmação em cada item abaixo.

1. **Fatos já confirmados e reaproveitados do ADR-004 (não revalidados nesta sessão, apenas referenciados)**: bucket `devops-ia-tfstate-508591324807-us-east-1` existe e está aplicado (ARN `arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1`, região `us-east-1`), versionado, SSE-S3/`AES256`, Public Access Block total (4 flags `true`), `BucketOwnerEnforced`, bucket policy negando tráfego não-TLS, lifecycle de 90 dias para versões não-atuais.
2. **Convenção de `key`**: um bucket único compartilhado por todas as stacks, diferenciadas por `key` — já registrada no ADR-004 ("Decisão"). Esta ADR usa `network/terraform.tfstate`, conforme o exemplo já citado no próprio ADR-004.
3. **Versão do Terraform CLI no executor**: confirmado `v1.15.5` em 2026-07-10 (mesma verificação já usada para resolver a Premissa #6 do ADR-004), acima do mínimo `>= 1.11.0` exigido para `use_lockfile` ser suportado nativamente sem fallback para `dynamodb_table`. Válido para o executor verificado nesta data — se a migração ocorrer em um executor diferente ou muito tempo depois, a versão deve ser reconfirmada antes do `terraform init -migrate-state` (mesma ressalva já registrada no ADR-004).
4. **Sem DynamoDB**: consistente com a decisão já tomada no ADR-004 (Alternativa A), o bloco `backend "s3"` desta ADR **não** declara `dynamodb_table`.
5. **Policy IAM de referência do ADR-004 (seção 14.2) como ponto de partida**: este ADR promove essa policy de "referência, não aplicada" para "real, criada e anexada" (ver Premissa #11 e seção "IAM"), substituindo `<stack>` por `network`.
6. **Nenhuma mudança de recurso de infraestrutura é esperada**: esta é uma migração pura de mecanismo de state. O único arquivo `.tf` alterado é `network/versions.tf` (adição do bloco `backend` e elevação de `required_version`). `terraform plan`, executado imediatamente após a migração, deve reportar **"No changes."** — esse é o critério de aceite central deste ADR (ver "Critérios de aceite").
7. **Janela de manutenção — confirmado pelo solicitante em 2026-07-10**: a migração pode ocorrer imediatamente, sem necessidade de janela de manutenção formal. Justificativa registrada pelo solicitante: nenhuma stack de compute depende de `network/` hoje (nenhuma outra stack existe ainda no repositório) e a migração não altera nenhum recurso de infraestrutura de rede — apenas o mecanismo de persistência do state.
8. **Execução concorrente — confirmado pelo solicitante em 2026-07-10**: o solicitante é o único operando o repositório atualmente; não há outra pessoa/processo rodando `terraform plan`/`apply` em `network/` durante a janela desta migração. Isso elimina o risco específico descrito na versão original desta premissa (divergência de state por escrita concorrente durante a janela de transição entre backend local e remoto).
9. **A execução desta migração é estritamente manual, fora da skill `terraform-deploy`** — ver "Decisão" e seção 0 da especificação de implementação para a justificativa detalhada.
10. **Credenciais AWS**: mesma premissa padrão dos ADRs anteriores — nunca hardcoded; vêm de variáveis de ambiente, profile nomeado ou OIDC/IRSA. A identidade IAM usada para rodar Terraform em `network/` tem, adicionalmente, a policy da seção "IAM" deste ADR anexada desde 2026-07-10 (ver Premissa #11).
11. **Mecanismo de anexação da policy IAM — resolvido e confirmado em 2026-07-10**: a policy real da seção "IAM" (`network-tfstate-access-policy`, ARN `arn:aws:iam::508591324807:policy/network-tfstate-access-policy`) foi criada via `aws iam create-policy`, com o JSON exato da seção "IAM" deste ADR (sem alterações), e anexada à role `tf_devops_admin-role` via `aws iam attach-role-policy` — confirmado via `aws iam list-attached-role-policies` (ações realizadas fora do escopo de ferramentas deste agente planejador, relatadas pelo solicitante). **Nota informativa não bloqueante**: antes dessa criação, verificou-se que a role `tf_devops_admin-role` já possuía, via a policy `futura-s3-policy`, uma statement `GeneralPermission` com `s3:PutObject`/`s3:GetObject`/`s3:ListBucket` em `Resource: "*"` — permissão ampla que já seria suficiente, isoladamente, para evitar `AccessDenied` nesta migração. Mesmo assim, o solicitante optou por criar e anexar também a policy least-privilege escopada a `network/*`, consistente com a premissa de segurança padrão deste repositório (least privilege em toda policy IAM) — este ADR reflete essa escolha como a configuração vigente, não apenas a permissão ampla preexistente.
12. **Convenção de nomenclatura**: este ADR segue integralmente `.claude/rules/terraform-naming.md`.
13. **Backend Terraform não aceita interpolação de variáveis** (`var.*`, `local.*`, expressões) — é uma limitação arquitetural conhecida do Terraform core: o bloco `backend` é processado antes de o motor de interpolação estar disponível. Por isso os valores de `bucket`/`key`/`region` no bloco `backend "s3"` abaixo são literais fixos, não `var.project.aws_region` — isso é uma exceção deliberada e tecnicamente obrigatória à convenção geral do projeto de evitar valores hardcoded fora de `.tfvars` (ver seção 2 da especificação de implementação para o detalhe).

## Requisitos considerados

- **Funcional**: a stack `network/` passa a usar `backend "s3"` (bucket `devops-ia-tfstate-508591324807-us-east-1`, `key = network/terraform.tfstate`, `region = us-east-1`, `encrypt = true`, `use_lockfile = true`, sem `dynamodb_table`), preservando integralmente o state dos 12 recursos já aplicados — nenhuma mudança de infraestrutura.
- **Não-funcional**:
  - **Segurança**: policy IAM least-privilege escopada exclusivamente ao prefixo `network/*` do bucket (nunca ao bucket inteiro) para a identidade que executa Terraform em `network/`; criptografia em repouso (herdada do bucket, SSE-S3) e em trânsito (`encrypt = true` + bucket policy que já nega tráfego não-TLS); nenhuma credencial hardcoded.
  - **Confiabilidade/recuperação**: backup do state local **antes** de qualquer comando; verificação pós-migração via `terraform plan` (deve reportar "No changes."); versionamento já habilitado no bucket (ADR-004) cobre recuperação de versões futuras do state remoto; procedimento de rollback documentado para o cenário de falha no meio da migração.
  - **Disponibilidade/concorrência**: locking nativo (`use_lockfile`) protege contra execuções concorrentes de Terraform *após* a migração; a garantia operacional de exclusividade durante a própria janela de migração foi confirmada pelo solicitante (Premissa #8).
  - **Auditabilidade/rastreabilidade**: nenhuma tag nova é necessária (esta migração não cria recursos AWS novos); a mudança em si é rastreada pelo histórico do repositório (commit do `versions.tf`) e por este ADR.
  - **Custo**: US$ 0,00 adicional — reaproveita integralmente o bucket já existente e já pago (ADR-004).
  - Escala, RTO/RPO formal, compliance, multi-região: não informados; não aplicável a este ADR de migração de mecanismo de state.

## Alternativas consideradas

O eixo de decisão aqui não é "qual backend" (já decidido no ADR-004: S3 + `use_lockfile`, sem DynamoDB) — é **qual procedimento de migração** usar para mover o state já aplicado de `network/` do backend local para o backend remoto com segurança.

### Alternativa A — `terraform init -migrate-state` interativo (RECOMENDADA)

Fluxo padrão do Terraform para trocar de backend preservando o state: ao rodar `terraform init -migrate-state` após adicionar o bloco `backend "s3"` a `versions.tf`, o Terraform detecta a mudança de backend, copia o conteúdo do state local para o novo backend e **pergunta interativamente** ("Do you want to copy existing state to the new backend?") antes de efetivar a cópia — a resposta precisa ser digitada explicitamente (`yes`).

- **Prós**: fluxo oficial e nativo do Terraform, desenhado exatamente para este cenário; a confirmação interativa funciona como um gate humano adicional embutido no próprio comando (o operador vê o prompt e só prossegue deliberadamente); baixo risco de erro humano de digitação de comandos manuais de cópia de objeto.
- **Contras**: exige que o operador (humano ou o agente de implementação, sob supervisão humana) esteja presente para responder ao prompt — não é adequado para automação não supervisionada (mas isso é, aqui, uma vantagem de segurança, não uma limitação).
- **Impacto Well-Architected**:
  - Excelência Operacional: positivo (procedimento padrão, bem documentado, menos passos manuais sujeitos a erro).
  - Segurança: positivo (prompt de confirmação funciona como gate adicional; sem exposição do state fora do fluxo do próprio Terraform).
  - Confiabilidade: positivo (o próprio Terraform valida a integridade da cópia; falha de rede/permissão durante a cópia é reportada claramente, sem deixar o state em local ambíguo — o Terraform não sobrescreve o state local até confirmar sucesso da escrita remota).
  - Eficiência de Performance: neutro (operação única, poucos KB de dados).
  - Otimização de Custo: neutro (mesma alternativa em todos os cenários — sem custo de migração em si).
  - Sustentabilidade: neutro.
- **Estimativa de custo mensal adicional**: US$ 0,00 (procedimento único, sem recurso novo).

### Alternativa B — `terraform init -migrate-state -force-copy` (sem prompt)

Mesmo mecanismo da Alternativa A, mas com a flag `-force-copy`, que suprime o prompt interativo e assume automaticamente a resposta "yes".

- **Prós**: útil para automação não supervisionada (ex.: pipelines de CI que não têm terminal interativo).
- **Contras**: remove exatamente o gate humano embutido que a Alternativa A oferece "de graça" — numa operação de alto risco sobre state já aplicado de 12 recursos, suprimir a única confirmação nativa do próprio comando não se justifica aqui (não há requisito de pipeline não supervisionado neste repositório; a skill `terraform-deploy` já é semiautomática, mas esta migração está deliberadamente fora dela — ver "Decisão").
- **Impacto Well-Architected**:
  - Excelência Operacional: neutro/levemente negativo (remove uma camada de verificação sem ganho operacional real neste contexto).
  - Segurança: negativo em relação à Alternativa A (menos um ponto de confirmação humana num fluxo que já tem poucos).
  - Confiabilidade: neutro (mecanismo de cópia subjacente é o mesmo).
  - Demais pilares: neutro, equivalente à Alternativa A.
- **Estimativa de custo mensal adicional**: US$ 0,00.

### Alternativa C — Migração manual via `aws s3 cp` + `terraform init -reconfigure` (descartada)

Copiar manualmente o arquivo `network/terraform.tfstate` para `s3://devops-ia-tfstate-508591324807-us-east-1/network/terraform.tfstate` via AWS CLI, e então rodar `terraform init -reconfigure` (que **não** tenta migrar state, apenas assume o novo backend "do zero").

- **Por que foi descartada**: `-reconfigure` existe justamente para o caso oposto (abandonar o state antigo, não preservá-lo) — usá-la aqui exigiria confiar inteiramente na cópia manual via `aws s3 cp` para preservar a integridade do state, sem nenhuma validação nativa do Terraform de que a cópia é consistente com o que o backend espera (formato, serial, lineage). Isso introduz risco de erro humano (caminho errado, arquivo desatualizado, encoding) sem nenhum ganho compensatório sobre a Alternativa A. Não avaliada em profundidade pelos pilares Well-Architected por esse motivo — é estritamente dominada pela Alternativa A em todos os pilares relevantes (Confiabilidade e Excelência Operacional, em particular).
- **Estimativa de custo mensal adicional**: US$ 0,00 (não avaliada em detalhe).

## Decisão

**Alternativa A — `terraform init -migrate-state` interativo, executado manualmente pelo agente de implementação sob supervisão humana, fora da skill `terraform-deploy`.**

Justificativa: (1) é o fluxo oficial do Terraform para exatamente este cenário (troca de backend preservando state existente), com validação nativa de integridade da cópia; (2) o prompt interativo funciona como um gate humano embutido adicional, coerente com a postura de todo o repositório desde o ADR-001 de nunca aplicar automaticamente uma operação de alto risco sobre infraestrutura já existente; (3) ao contrário da Alternativa B, não há requisito de automação não supervisionada que justifique suprimir esse prompt; (4) a Alternativa C introduz risco de erro humano sem necessidade, já que a Alternativa A já resolve o problema de forma mais seleção e mais segura.

**Sobre o uso da skill `terraform-deploy`: decisão explícita — NÃO USAR.** A suspeita registrada no pedido está correta e é confirmada por este ADR:
1. `-migrate-state` é uma flag especial de `terraform init` que a skill não está preparada para passar — o passo 2 do fluxo da skill (`.claude/skills/terraform-deploy/SKILL.md`) roda exatamente `terraform init -upgrade=false`, sem qualquer parametrização para `-migrate-state`, e não há mecanismo na skill para injetar essa flag ad hoc.
2. Mesmo que a flag pudesse ser injetada, a skill foi desenhada para o ciclo `fmt → init → validate → plan → apply` de **mudanças de infraestrutura**, com um gate de segurança específico para planos destrutivos (`scripts/plan_is_destructive.py`). Uma migração de backend não é uma mudança de infraestrutura via `plan`/`apply` — é uma operação sobre o *mecanismo de persistência do state em si*, que precisa ocorrer **antes** de qualquer `plan`/`apply` rodar contra o novo backend, e que tem seu próprio prompt de confirmação nativo (não capturado pela classificação SAFE/DESTRUCTIVE da skill, que analisa apenas o JSON de um `terraform plan`).
3. Por isso, todos os comandos desta migração devem ser executados **manualmente, passo a passo, dentro de `network/`**, por um humano ou pelo `aws-devops-engineer` sob acompanhamento humano direto — nunca através de uma invocação da skill `terraform-deploy`, mesmo que o usuário peça para "aplicar tudo" ou "atualizar a stack network". Uma vez concluída esta migração, o uso *rotineiro* subsequente de `terraform-deploy` sobre `network/` volta a funcionar normalmente e de forma transparente (o `terraform init -upgrade=false` da skill simplesmente inicializará contra o backend S3 já configurado, sem necessitar de `-migrate-state` novamente).

**GATE DE APROVAÇÃO HUMANA OBRIGATÓRIO**: mesmo com custo US$ 0,00 e nenhuma mudança de recurso de infraestrutura esperada, esta é uma operação sobre o mecanismo de persistência de state de uma stack já aplicada com 12 recursos reais na AWS. As três premissas que bloqueavam o início da execução — (a) janela de manutenção e ausência de execução concorrente (Premissas #7 e #8) e (b) policy IAM anexada à identidade executora (Premissa #11) — foram confirmadas pelo solicitante em **2026-07-10** (ver Premissas correspondentes). Isso resolve a pendência de validação de negócio/operacional, mas **não dispensa** o gate de aprovação humana para a execução em si: nenhum comando desta migração — nem a edição de `network/versions.tf`, nem o `terraform init -migrate-state`, nem a resposta ao prompt de confirmação — deve ser executado sem (c) confirmação de que o backup do state local (seção "Especificação de implementação", passo 4.1) foi concluído com sucesso **antes** de qualquer edição em `versions.tf`, e sem um humano acompanhando a execução e revisando o resultado da verificação pós-migração (seção 4.5, `terraform plan` → "No changes.") antes de considerar a migração concluída. Este gate permanece válido mesmo após a confirmação de todas as premissas registrada em 2026-07-10.

## Especificação de implementação (para o agente DevOps)

### 0. Instrução crítica sobre a skill `terraform-deploy` — leia antes de tudo

**Esta migração nunca deve ser executada através da skill `terraform-deploy`.** Ver "Decisão" para a justificativa completa. Todos os passos abaixo são manuais, executados dentro do diretório `network/`, um de cada vez, com verificação do resultado de cada comando antes de prosseguir para o próximo. Se o `aws-devops-engineer` for solicitado a "aplicar tudo" ou "atualizar a stack network" antes desta migração estar concluída, a skill continuará rodando o fluxo padrão contra o backend **local** (que ainda é o backend vigente até a migração ser efetivada) — isso não é um erro em si, mas não deve ser confundido com a execução desta migração.

### 1. Escopo de arquivos alterados

Apenas **um** arquivo é alterado nesta ADR:

```
network/
└── versions.tf   # ALTERAR: adicionar bloco backend "s3", elevar required_version
```

Nenhum outro arquivo `.tf` de `network/` é criado, alterado ou removido. Nenhum arquivo de `remote-backend/` é tocado.

### 2. `network/versions.tf` (arquivo completo após a alteração)

Backend `"s3"` validado via WebFetch da documentação oficial (`developer.hashicorp.com/terraform/language/backend/s3`, ver "Referências" — não há tool MCP dedicado a schema de backend Terraform, mesma limitação já registrada no ADR-004): argumentos `bucket`, `key`, `region`, `encrypt` e `use_lockfile` confirmados como suportados pela versão atual do backend `s3`; `use_lockfile` confirmado como estável desde o Terraform 1.11 (experimental desde 1.10); `dynamodb_table` confirmado como deprecado (ainda funcional, mas emite aviso de depreciação e será removido em versão minor futura) — por isso **não** é declarado aqui, consistente com a decisão já tomada no ADR-004.

```hcl
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
```

### 3. IAM — policy real para a stack `network/` (least-privilege, escopo `network/*`)

Promovida da "policy de referência para stacks consumidoras" do ADR-004 (seção 14.2), substituindo `<stack>` por `network`. Concede acesso apenas ao objeto de state e ao lockfile desta stack específica — nunca ao bucket inteiro nem a qualquer outro prefixo (`remote-backend/*` ou de outra stack futura permanecem inacessíveis por esta policy).

**Status: já criada e anexada em 2026-07-10** (ver Premissa #11) — policy gerenciada `network-tfstate-access-policy`, ARN `arn:aws:iam::508591324807:policy/network-tfstate-access-policy`, anexada à role `tf_devops_admin-role`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1/network/terraform.tfstate",
        "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1/network/terraform.tfstate.tflock"
      ]
    },
    {
      "Sid": "TerraformStateBucketListing",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["network/*"]
        }
      }
    }
  ]
}
```

**Dependência já satisfeita (ver Premissa #11)**: esta policy foi criada via `aws iam create-policy` (ARN `arn:aws:iam::508591324807:policy/network-tfstate-access-policy`) com o JSON exato acima, sem alterações, e anexada à role `tf_devops_admin-role` via `aws iam attach-role-policy` em 2026-07-10 — confirmado via `aws iam list-attached-role-policies`. Nenhuma ação adicional de IAM é necessária antes do passo "Migração" (4.4). **Nota informativa não bloqueante**: a role `tf_devops_admin-role` já possuía, antes desta anexação, uma permissão ampla via a policy `futura-s3-policy` (`s3:PutObject`/`s3:GetObject`/`s3:ListBucket`, `Resource: "*"`) que teria sido suficiente, isoladamente, para evitar `AccessDenied` nesta migração — mas o solicitante optou por manter também a policy least-privilege escopada a `network/*` como camada adicional, consistente com a premissa de segurança padrão deste repositório (least privilege em toda policy IAM).

### 4. Procedimento exato de migração

Executar **dentro de `network/`**, um passo de cada vez, na ordem abaixo. Nenhum passo deve ser pulado ou reordenado.

**4.0 — Pré-condições (checklist antes de iniciar)**

- [x] Janela de manutenção: confirmado pelo solicitante em 2026-07-10 que a migração pode ocorrer imediatamente, sem necessidade de janela formal (Premissa #7).
- [x] Execução concorrente: confirmado pelo solicitante em 2026-07-10 que ele é o único operando o repositório atualmente — nenhuma execução concorrente de Terraform em `network/` (Premissa #8).
- [x] Policy IAM da seção 3 (`network-tfstate-access-policy`) criada e anexada à role `tf_devops_admin-role` em 2026-07-10 (Premissa #11).
- [ ] Confirmar, no momento da execução, que `terraform version` no executor ainda retorna `>= 1.11.0` (referência: `v1.15.5` confirmado em 2026-07-10 — reconfirmar se o executor tiver mudado desde então).

**4.1 — Backup do state local (antes de qualquer edição de arquivo)**

```bash
cd network/
mkdir -p /caminho/seguro/fora-do-repo/backups-terraform-state
cp terraform.tfstate "/caminho/seguro/fora-do-repo/backups-terraform-state/network.terraform.tfstate.$(date +%Y%m%dT%H%M%S).bak"
# Se existir um terraform.tfstate.backup de uma operação anterior, copiar também:
[ -f terraform.tfstate.backup ] && cp terraform.tfstate.backup "/caminho/seguro/fora-do-repo/backups-terraform-state/network.terraform.tfstate.backup.$(date +%Y%m%dT%H%M%S).bak"
```

**Importante**: o diretório de destino do backup **não pode** ser rastreado pelo Git deste repositório (arquivos de state podem conter dados sensíveis dependendo dos recursos gerenciados — hoje são apenas metadados de rede, mas a prática deve ser tratada como padrão independentemente do conteúdo atual). Use um diretório fora da árvore de trabalho do repositório, ou um diretório já coberto por uma exceção de `.gitignore` distinta de `terraform.tfvars`.

**4.2 — Editar `network/versions.tf`**

Substituir o conteúdo atual pelo especificado na seção 2 acima (bloco `backend "s3"` adicionado, `required_version` elevado para `>= 1.11.0`).

**4.3 — `terraform fmt -check` e `terraform validate` (pré-migração, contra o backend ainda local)**

```bash
terraform fmt -check
terraform validate
```

`validate` deve retornar `Success!`. Se falhar, **não prosseguir** — reverter `versions.tf` para o conteúdo original e investigar antes de tentar novamente.

**4.4 — Migração propriamente dita**

```bash
terraform init -migrate-state
```

O Terraform detecta a mudança de backend (ausência de bloco `backend` → `backend "s3"`) e exibirá um prompt semelhante a:

```
Initializing the backend...
Terraform detected that the backend type changed from "local" to "s3".

Do you want to copy existing state to the new backend?
  ...
  Enter a value:
```

Responder **`yes`** apenas após confirmar que o passo 4.1 (backup) foi concluído com sucesso. **Não usar `-force-copy`** (suprimiria este prompt — ver "Alternativas", Alternativa B, descartada) e **não usar `-reconfigure`** (não migraria o state, apenas o abandonaria — ver Alternativa C, descartada).

Se o comando falhar por `AccessDenied`: com a policy `network-tfstate-access-policy` já anexada à role `tf_devops_admin-role` (Premissa #11), essa falha não é mais o cenário mais provável — mas, se ocorrer mesmo assim (ex.: a role usada na execução real não for de fato `tf_devops_admin-role`), não prosseguir tentando novamente sem antes confirmar qual identidade está executando o comando e se ela tem a permissão necessária; escalar para humano se a causa não for imediatamente óbvia.

**4.5 — Verificação pós-migração**

```bash
terraform plan
```

**Critério de aceite central desta ADR**: a saída deve ser exatamente **"No changes. Your infrastructure matches the configuration."** (ou texto equivalente da versão do Terraform instalada). Qualquer `to add`/`to change`/`to destroy` reportado aqui é um sinal de que algo divergiu — **não aplicar** nada nesse cenário; escalar para investigação antes de qualquer `apply`.

Verificações adicionais recomendadas:

```bash
# Confirma que o objeto de state existe no novo backend:
aws s3 ls s3://devops-ia-tfstate-508591324807-us-east-1/network/

# Confirma que o versionamento do bucket já está gravando versões do novo objeto:
aws s3api list-object-versions \
  --bucket devops-ia-tfstate-508591324807-us-east-1 \
  --prefix network/terraform.tfstate
```

- [ ] `terraform plan` reporta "No changes."
- [ ] `aws s3 ls` mostra o objeto `network/terraform.tfstate` no bucket.
- [ ] `terraform.tfstate` local (o arquivo em disco dentro de `network/`) não é mais atualizado por operações subsequentes — o Terraform, a partir daqui, lê/escreve exclusivamente contra o backend S3. O arquivo local remanescente (e o `.terraform/` local) deve ser tratado como artefato histórico da migração, não como state vigente.

### 5. Risco de state lock travado (stale lock) — decisão e procedimento

**Decisão**: aceitar o risco residual, com procedimento de remediação documentado — não é viável eliminar completamente o risco de um processo Terraform ser interrompido (crash, `Ctrl+C`, queda de rede) enquanto segura o lock, e isso é verdade tanto para o mecanismo local quanto para qualquer mecanismo de state remoto (DynamoDB incluso), não é uma desvantagem específica do `use_lockfile`.

**Mecanismo**: com `use_lockfile = true`, o Terraform cria um objeto `network/terraform.tfstate.tflock` no bucket no início de operações que precisam de lock (`plan`, `apply`, e alguns outros comandos) e o remove ao final. Como objetos S3 não expiram por conta própria, se o processo for interrompido no meio, o objeto `.tflock` permanece — um lock "travado" (stale).

**Como detectar**: uma operação subsequente falhará com uma mensagem de erro contendo informações do lock (`Lock Info`: ID, Path, Operation, Who, Version, Created), em vez de prosseguir normalmente.

**Procedimento de remediação**:
1. **Confirmar antes de tudo, com um humano, que o processo referenciado no campo `Who`/`Created` do erro de lock não está de fato mais em execução.** Esta confirmação é obrigatória e não pode ser assumida — remover um lock que protege uma operação genuinamente em andamento pode causar escrita concorrente e corrupção de state.
2. Somente após essa confirmação, rodar, dentro de `network/`:
   ```bash
   terraform force-unlock <LOCK_ID>
   ```
   usando o `LOCK_ID` exato reportado na mensagem de erro.
3. `force-unlock` apenas remove o lock (deleta o objeto `.tflock` no S3) — não modifica nenhuma infraestrutura nem o conteúdo do state em si.
4. Após o `force-unlock`, rodar `terraform plan` novamente para confirmar que o state está íntegro antes de prosseguir com qualquer `apply`.

**Este procedimento é uma ação de risco/ambígua por natureza** (exige julgamento humano sobre se um processo "realmente" não está mais rodando) — consistente com a regra geral deste repositório (`aws-devops-engineer` deve escalar para humano antes de ações destrutivas ou ambíguas), `terraform force-unlock` **nunca** deve ser executado sem essa confirmação humana explícita, mesmo que pareça óbvio que o lock está travado.

### 6. O que fazer se a migração falhar no meio do caminho

**Cenário A — falha antes de qualquer escrita bem-sucedida no S3** (ex.: prompt do passo 4.4 respondido com algo diferente de `yes`; falha de credenciais/permissão; erro de rede antes da cópia completar): o state local permanece intacto e autoritativo — nada foi migrado. Corrigir a causa raiz (permissão IAM, conectividade) e repetir o passo 4.4 (`terraform init -migrate-state`) do zero. Não é necessário reverter `versions.tf` neste cenário, pois o Terraform não terá efetivado a troca de backend sem uma cópia bem-sucedida.

**Cenário B — falha após início da cópia, mas com resultado incerto** (ex.: conexão cai no meio da transferência do objeto para o S3): não presumir que o state remoto está correto ou incorreto sem checar.
1. Rodar `terraform plan` — se ele reportar erro de backend (ex.: não conseguir ler o state do S3), o objeto remoto provavelmente não foi gravado com sucesso; se ele reportar "No changes.", a migração provavelmente completou apesar da falha aparente — mas trate esse resultado com ceticismo e prossiga para o passo 2 mesmo assim.
2. Comparar explicitamente o conteúdo do state remoto (`aws s3 cp s3://devops-ia-tfstate-508591324807-us-east-1/network/terraform.tfstate -` para imprimir, ou baixar para um arquivo temporário) com o backup local feito no passo 4.1 — os `serial`/`lineage` (campos internos do JSON de state) devem ser consistentes (o `lineage` deve ser idêntico ao do backup; o `serial` do remoto deve ser igual ou maior).
3. Se o state remoto estiver ausente, corrompido, ou inconsistente: reverter `network/versions.tf` para o conteúdo original (sem bloco `backend`, `required_version = ">= 1.9.0"`), rodar `terraform init -reconfigure` (força o Terraform a "esquecer" a tentativa de backend S3 e voltar a usar o state local em disco, sem tentar migrar novamente), e confirmar com `terraform plan` que o resultado é "No changes." contra o state local original (restaurado do backup do passo 4.1, se o arquivo local em disco também tiver sido corrompido/alterado). Somente após confirmar essa consistência, escalar para investigação da causa raiz antes de tentar a migração novamente.

**Cenário C — rollback deliberado após migração já concluída com sucesso** (ex.: decisão de negócio de voltar atrás, não uma falha técnica): mesmo procedimento do Cenário B, item 3 (reverter `versions.tf`, `terraform init -reconfigure`, restaurar/confirmar state local a partir do backup do passo 4.1) — mas como isso reverte uma migração que funcionou, exige a mesma aprovação humana explícita que a migração original exigiu (ver "Decisão", gate de aprovação).

Em todos os cenários, **o backup do passo 4.1 é o ponto de recuperação de última instância** — nunca prosseguir com qualquer tentativa de correção sem ele disponível e íntegro.

### 7. Dependências e ordem de execução (resumo)

1. Confirmar pré-condições da seção 4.0 (checklist) — Premissas #7, #8 e #11 já confirmadas em 2026-07-10; resta apenas reconfirmar a versão do Terraform CLI no momento da execução.
2. Backup do state local (seção 4.1).
3. Editar `network/versions.tf` (seção 4.2).
4. `terraform fmt -check` + `terraform validate` (seção 4.3).
5. `terraform init -migrate-state`, respondendo `yes` ao prompt (seção 4.4).
6. Verificação pós-migração: `terraform plan` deve mostrar "No changes." + checagens adicionais (seção 4.5).
7. **Ponto de decisão humana obrigatório**: revisar o resultado da verificação (passo 6) antes de considerar a migração concluída. Se qualquer divergência aparecer, seguir a seção 6 (não prosseguir silenciosamente).
8. A partir daqui, `network/` pode voltar a ser operada normalmente pela skill `terraform-deploy` para futuras mudanças de infraestrutura (a skill passará a inicializar contra o backend S3 já configurado, sem necessidade de qualquer flag especial).

### 8. Parâmetros validados via MCP/WebFetch vs. A VALIDAR

| Parâmetro | Valor | Validado via | Status |
|---|---|---|---|
| Argumentos do backend `s3`: `bucket`, `key`, `region`, `encrypt`, `use_lockfile` | suportados pela versão atual do backend `s3` | WebFetch (`developer.hashicorp.com/terraform/language/backend/s3`) | Validado |
| `use_lockfile` — versão mínima do Terraform CLI | estável desde 1.11 (experimental desde 1.10) | WebFetch + WebSearch (múltiplas fontes independentes, mesma linha do tempo já citada no ADR-004) | Validado (reaproveitado do ADR-004) |
| `dynamodb_table` — status de depreciação | deprecado, ainda funcional mas com aviso; remoção planejada em versão minor futura; pode coexistir com `use_lockfile` durante uma migração (não usado nesta ADR) | WebFetch (`developer.hashicorp.com/terraform/language/backend/s3`) | Validado |
| Backend não aceita interpolação de variáveis (`var.*`) — apenas literais ou `-backend-config` | confirmado — limitação arquitetural do Terraform core (backend processado antes do motor de interpolação) | WebSearch (issues/documentação oficial hashicorp/terraform) | Validado |
| `terraform init -migrate-state` — comportamento (copia state existente, prompt interativo) vs. `-reconfigure` (não migra, assume backend do zero) vs. `-force-copy` (suprime prompt) | confirmado conforme descrito nas seções "Alternativas" e "Especificação de implementação" | WebFetch (`developer.hashicorp.com/terraform/cli/commands/init`) | Validado |
| `terraform force-unlock` — remove apenas o lock (`.tflock`), não modifica infraestrutura nem state | confirmado | WebSearch (`developer.hashicorp.com/terraform/cli/commands/force-unlock` + fontes secundárias) | Validado |
| Versão do Terraform CLI no executor | `v1.15.5`, confirmado em 2026-07-10 (reaproveitado do ADR-004) | Verificação direta anterior, referenciada nesta ADR | Validado (para o executor verificado nesta data — reconfirmar se mudar) |
| Bucket/ARN/configuração de `remote-backend/` (versionamento, SSE-S3, Public Access Block, `BucketOwnerEnforced`, bucket policy, lifecycle) | reaproveitado integralmente do ADR-004, já aplicado | ADR-004 (`docs/adr/ADR-004-remote-backend.md`) | Validado (reaproveitado, não revalidado nesta sessão) |
| Contagem de recursos já aplicados em `network/` (12) | `aws_vpc.this` (1) + `aws_subnet` públicas/privadas (4) + `aws_internet_gateway.this` (1) + `aws_route_table` pública/privada (2) + `aws_route_table_association` (4) = 12; `aws_eip.nat`/`aws_nat_gateway.this` com `count = 0` (NAT desabilitado) | Leitura direta de `network/outputs.tf`, `network/variables.tf`, `network/terraform.tfvars` | Validado |
| Janela de manutenção necessária | Não é necessária — migração pode ocorrer imediatamente | Confirmação direta do solicitante, 2026-07-10 | Confirmado (Premissa #7) |
| Execução concorrente de Terraform em `network/` durante a migração | Nenhuma — solicitante é o único operador do repositório no momento | Confirmação direta do solicitante, 2026-07-10 | Confirmado (Premissa #8) |
| Mecanismo de anexação da policy IAM da seção 3 à identidade executora | Policy gerenciada `network-tfstate-access-policy` (ARN `arn:aws:iam::508591324807:policy/network-tfstate-access-policy`) criada e anexada à role `tf_devops_admin-role` | `aws iam create-policy` + `aws iam attach-role-policy`, confirmado via `aws iam list-attached-role-policies` (2026-07-10, fora do escopo de ferramentas deste agente planejador, relatado pelo solicitante) | Confirmado (Premissa #11) |
| Permissão ampla preexistente na role `tf_devops_admin-role` (`futura-s3-policy`, `Resource: "*"`) | Já cobriria `s3:PutObject`/`s3:GetObject`/`s3:ListBucket` sobre qualquer recurso, tornando a policy escopada não estritamente necessária para evitar `AccessDenied` | Verificação relatada pelo solicitante, 2026-07-10 | Confirmado — informativo, não bloqueante (a policy escopada foi criada mesmo assim, por preferência de least privilege) |

## Consequências

**Positivas**
- A stack `network/`, com 12 recursos reais já aplicados, deixa de depender de um único arquivo em disco (`network/terraform.tfstate`) como fonte de verdade do state — resolvendo a pendência "backend de state remoto" registrada como risco crescente em todos os ADRs anteriores (ADR-001 a ADR-004).
- Locking nativo (`use_lockfile`) passa a proteger `network/` contra execuções concorrentes de `plan`/`apply`, o que o backend local nunca ofereceu.
- Versionamento do bucket (já habilitado pelo ADR-004) passa a cobrir também o state de `network/` — qualquer `apply` futuro problemático pode, em tese, ter uma versão anterior do state recuperada via S3.
- Nenhuma mudança de infraestrutura de rede é introduzida — risco desta ADR fica inteiramente contido ao mecanismo de state, não aos 12 recursos AWS em si.
- Policy IAM real, escopada exclusivamente a `network/*`, já criada e anexada, reduz a superfície de acesso ao bucket compartilhado em relação a depender apenas da permissão ampla preexistente (`futura-s3-policy`, `Resource: "*"`).
- Todas as premissas de negócio/operacionais que estavam em aberto (janela de manutenção, execução concorrente, anexação de policy IAM) foram confirmadas em 2026-07-10 — nenhuma pendência de validação bloqueia mais o início da execução, restando apenas o gate de aprovação humana para a execução em si.

**Negativas / riscos e mitigação**
- **Operação de alto risco sobre state já aplicado**: um erro de procedimento poderia, em tese, deixar `network/` sem state válido em nenhum lugar. Mitigação: backup obrigatório do state local antes de qualquer edição (seção 4.1), verificação pós-migração via "No changes." (seção 4.5), e procedimento de rollback detalhado para múltiplos cenários de falha (seção 6).
- **Stale lock (lock travado)**: se um processo for interrompido segurando o lock, operações subsequentes falham até o lock ser removido. Mitigação: procedimento de `force-unlock` documentado (seção 5), sempre com confirmação humana explícita antes de remover o lock — nunca uma ação automática.
- **`network/terraform.tfstate` local remanescente após a migração**: o arquivo local não é automaticamente apagado pelo `terraform init -migrate-state` — ele permanece em disco como artefato histórico, podendo gerar confusão futura sobre qual é a fonte de verdade. Mitigação: seção 4.5 já deixa explícito que o local deve ser tratado como histórico, não vigente; recomenda-se (fora do escopo obrigatório deste ADR) considerar adicionar `network/terraform.tfstate*` a uma exceção de `.gitignore` local se ainda não estiver coberto, para evitar commit acidental do artefato remanescente.
- **Elevação de `required_version` para `>= 1.11.0`**: qualquer executor futuro com Terraform CLI mais antigo não conseguirá mais rodar `plan`/`apply` em `network/` (o Terraform recusa a execução se a versão não satisfizer a constraint). Mitigação: constraint reflete um requisito técnico real (`use_lockfile`), não uma escolha arbitrária — é a mesma lógica que o ADR-004 já registrou para stacks consumidoras futuras.
- **Duas policies IAM concedendo acesso sobreposto ao bucket** (`futura-s3-policy`, ampla, `Resource: "*"`, e `network-tfstate-access-policy`, escopada): a policy ampla preexistente não foi removida por este ADR (fora de escopo — pertence à gestão de IAM da conta, não a esta migração) e continua concedendo mais acesso do que o estritamente necessário. Mitigação: registrado como observação não bloqueante; se uma revisão de hardening de IAM for desejada no futuro, avaliar a remoção/restrição de `futura-s3-policy` deve ser tratada como um ADR ou mudança de IAM à parte, fora do escopo desta migração.

**Impactos operacionais**
- Monitoramento: nenhum recurso de logging/alarme adicional é criado por este ADR (mesma pendência já registrada no ADR-004 — logging de acesso ao bucket fora de escopo).
- Backup: a partir desta migração, o "backup" contínuo do state de `network/` passa a ser responsabilidade do versionamento do bucket (ADR-004) — o backup manual local (seção 4.1) é um ponto único de recuperação apenas para a própria janela de migração, não uma estratégia de backup recorrente.
- Manutenção: qualquer mudança futura de `key`, `bucket` ou do mecanismo de locking desta stack deve passar por um novo ADR (mudança arquitetural sobre o mecanismo de state, não ajuste operacional trivial).

## Estimativa de custo

| Item | Custo |
|---|---|
| Reuso do bucket já existente (ADR-004) — sem recurso AWS novo criado por esta ADR | US$ 0,00 |
| Armazenamento adicional do objeto `network/terraform.tfstate` (poucos KB) | desprezível, já coberto pela estimativa "< US$ 0,01/mês" do ADR-004 |
| Locking nativo via `use_lockfile` (objeto `.tflock`, poucos bytes, efêmero) | US$ 0,00 |
| Policy IAM `network-tfstate-access-policy` (recurso IAM, sem cobrança direta) | US$ 0,00 |
| **Total estimado desta ADR** | **US$ 0,00/mês adicional** |

## Estratégia de rollback

Ver seção "Especificação de implementação", item 6 ("O que fazer se a migração falhar no meio do caminho") para o procedimento detalhado por cenário. Resumo:

1. Antes de qualquer coisa: backup do state local (seção 4.1) — é o ponto de recuperação de última instância para todos os cenários de rollback.
2. Falha antes de qualquer escrita no S3: nada precisa ser revertido; corrigir a causa raiz e repetir `terraform init -migrate-state`.
3. Falha após início da cópia, com resultado incerto: comparar `lineage`/`serial` do state remoto (se existir) com o backup local; se inconsistente, reverter `network/versions.tf` ao conteúdo original, rodar `terraform init -reconfigure`, restaurar o state local a partir do backup se necessário, e confirmar "No changes." antes de qualquer nova tentativa.
4. Rollback deliberado após sucesso (decisão de negócio, não falha técnica): mesmo procedimento do item 3, com a mesma exigência de aprovação humana explícita que a migração original teve.
5. Em nenhum cenário o bucket `devops-ia-tfstate-508591324807-us-east-1` em si é destruído ou alterado por este ADR — qualquer rollback aqui afeta apenas o `versions.tf` e o mecanismo de backend de `network/`, nunca a infraestrutura do backend remoto criada pelo ADR-004. A policy IAM `network-tfstate-access-policy` também não precisa ser removida em um rollback de backend — pode permanecer anexada sem efeito colateral caso a stack volte a usar state local.

## Critérios de aceite

- [x] Checklist da seção 4.0 (pré-condições): janela de manutenção (Premissa #7) e ausência de execução concorrente (Premissa #8) confirmadas pelo solicitante em 2026-07-10; policy IAM anexada (Premissa #11) confirmada em 2026-07-10 (`network-tfstate-access-policy` → `tf_devops_admin-role`). Pendente apenas reconfirmar `terraform version >= 1.11.0` no momento da execução.
- [ ] Backup do state local de `network/` realizado e armazenado fora da árvore de trabalho do repositório, antes de qualquer edição de arquivo.
- [ ] `network/versions.tf` contém o bloco `backend "s3"` exatamente como especificado na seção 2 (`bucket`, `key = "network/terraform.tfstate"`, `region`, `encrypt = true`, `use_lockfile = true`, sem `dynamodb_table`) e `required_version = ">= 1.11.0"`.
- [ ] Nenhum outro arquivo `.tf` de `network/` foi criado, alterado ou removido por esta ADR.
- [ ] Nenhum arquivo de `remote-backend/` foi criado, alterado ou removido por esta ADR — a stack permanece com state local.
- [ ] `terraform fmt -check` não reporta diferenças em `network/`.
- [ ] `terraform validate` retorna `Success!` em `network/` (antes e depois da migração).
- [ ] `terraform init -migrate-state` executado manualmente (fora da skill `terraform-deploy`), com resposta explícita `yes` ao prompt de cópia de state, após confirmação do backup.
- [ ] `terraform plan`, executado imediatamente após a migração, reporta **"No changes. Your infrastructure matches the configuration."** — nenhum recurso a adicionar, alterar ou destruir.
- [ ] `aws s3 ls s3://devops-ia-tfstate-508591324807-us-east-1/network/` confirma a existência do objeto `terraform.tfstate`.
- [x] Policy IAM da seção 3 (escopada a `network/*`, `network-tfstate-access-policy`) está criada e anexada à identidade executora (`tf_devops_admin-role`) desde 2026-07-10, sem conceder acesso a nenhum outro prefixo do bucket.
- [ ] Nenhum arquivo `.tf` contém `access_key`, `secret_key` ou qualquer credencial literal.
- [ ] O procedimento de `force-unlock` (seção 5) e o de tratamento de falha parcial (seção 6) estão documentados e foram lidos pelo operador antes da execução, mesmo que não precisem ser usados nesta migração específica.
- [ ] **Aprovação humana registrada** para toda a operação (edição de `versions.tf`, resposta ao prompt de migração, e qualquer eventual `force-unlock` ou rollback).

## Referências

- ADR-004 (`docs/adr/ADR-004-remote-backend.md`) — criação e aplicação do bucket `devops-ia-tfstate-508591324807-us-east-1`; decisão de locking nativo via `use_lockfile` sem DynamoDB; convenção de `key` por stack; policy IAM de referência (seção 14.2), promovida a real e efetivamente criada/anexada nesta ADR-005; registro explícito de que a migração de `network/` ficaria para "um ADR futuro e dedicado (candidato a ADR-005)".
- ADR-003 (`docs/adr/ADR-003-network-cidr-resize.md`) — precedente de tratar uma mudança de alto risco sobre infraestrutura já aplicada como ADR dedicado, com gate de aprovação próprio.
- WebFetch — `developer.hashicorp.com/terraform/language/backend/s3` — argumentos do backend `s3` (`bucket`, `key`, `region`, `encrypt`, `use_lockfile`, `dynamodb_table`), status de depreciação do `dynamodb_table`, possibilidade de coexistência dos dois mecanismos durante uma migração (não usada nesta ADR).
- WebFetch — `developer.hashicorp.com/terraform/cli/commands/init` — comportamento de `-migrate-state` (copia state, prompt interativo), `-reconfigure` (não migra, assume backend do zero) e `-force-copy` (suprime o prompt).
- WebSearch — `developer.hashicorp.com/terraform/cli/commands/force-unlock` e fontes secundárias (spacelift.io, oneuptime.com, encore.dev) — comportamento de `terraform force-unlock`, natureza de locks travados (stale) em backends S3 com `use_lockfile`, confirmação de que objetos `.tflock` não expiram automaticamente.
- WebSearch — issues/documentação oficial `hashicorp/terraform` (GitHub) — confirmação de que blocos `backend` não aceitam interpolação de variáveis, apenas literais ou parametrização via `-backend-config`.
- Leitura direta de `network/versions.tf`, `network/providers.tf`, `network/variables.tf`, `network/terraform.tfvars`, `network/outputs.tf` — estado atual da stack (12 recursos aplicados, `nat_gateway.enabled = false`) usado para confirmar que nenhuma mudança de infraestrutura é esperada por este ADR.
- Confirmação direta do solicitante, **2026-07-10**: Premissa #7 (dispensa de janela de manutenção formal), Premissa #8 (ausência de execução concorrente — solicitante é o único operador do repositório) e Premissa #11 (criação da policy `network-tfstate-access-policy`, ARN `arn:aws:iam::508591324807:policy/network-tfstate-access-policy`, via `aws iam create-policy` com o JSON exato da seção "IAM", e anexação à role `tf_devops_admin-role` via `aws iam attach-role-policy`, confirmada via `aws iam list-attached-role-policies`; e verificação, também relatada pelo solicitante, de que a role já possuía a permissão ampla `futura-s3-policy` — ações realizadas fora do escopo de ferramentas deste agente planejador).
- `.claude/rules/terraform-naming.md` — convenções de nomenclatura aplicadas integralmente nesta ADR.
- `.claude/skills/terraform-deploy/SKILL.md` — fluxo `fmt → init -upgrade=false → validate → plan → apply` e o motivo pelo qual esta migração não pode ser executada por ele.
- CLAUDE.md (raiz do repositório) — regra de bootstrap da stack `remote-backend` (sempre manual, nunca via skill) e histórico do estado atual de `network/`.
