# ADR-004: Stack `remote-backend/` — Bucket S3 para State Remoto Terraform (Locking Nativo via `use_lockfile`)

## Status
Proposto — todas as premissas de negócio que estavam marcadas **A VALIDAR** (Premissas #4, #5, #8, #9) foram confirmadas pelo solicitante em **2026-07-10**, e os itens puramente factuais de validação técnica que também estavam **A VALIDAR** (Premissas #6, #13, #15) foram confirmados na mesma data por verificação direta no ambiente do executor (fora do escopo de ferramentas deste agente planejador). O único item correlato ainda em aberto (checagem de CloudTrail a nível de conta, ligada à Premissa #9) não bloqueia este ADR — ver Premissa #9 e seção 16. Este ADR está **pronto para implementação**, mas continua **aguardando aprovação humana explícita antes de qualquer `terraform apply`** (gate mantido — ver "Decisão"), e continua sujeito à restrição de aplicação **exclusivamente manual, fora da skill `terraform-deploy`** (ver seção 0). **Não aplicado.** A migração da stack `network/` para consumir este backend **não está coberta por este ADR** (ver "Contexto" e "Consequências").

## Contexto

Desde o ADR-001, toda ADR desta stack de rede reafirma a mesma pendência em aberto: **não existe backend remoto de state Terraform neste repositório** — cada stack usa state local (`terraform.tfstate` em disco), e isso já foi registrado como risco crescente à medida que a stack `network/` acumulou mais recursos e mais operações destrutivas (ADR-003 chegou a substituir 12 recursos em um único `apply`, com state local como único ponto de recuperação).

O dono do repositório solicitou agora a criação de uma **nova stack Terraform independente**, com state e ciclo de vida próprios, cujo único propósito é provisionar a infraestrutura AWS necessária para um backend remoto de state (bucket S3 versionado e criptografado, com locking) que **outras stacks do repositório** (a começar por `network/`) poderão passar a usar depois, via bloco `backend "s3" { ... }` em seus próprios `versions.tf`.

**Restrição crítica de nomenclatura e de fluxo de aplicação, definida a nível de repositório (não deste ADR) e que este ADR deve apenas respeitar e tornar explícita**: esta stack **precisa se chamar exatamente `remote-backend`** (nome do diretório, `remote-backend/`, sem variação de maiúsculas/hífen/underscore). Dois mecanismos já existentes no repositório dependem desse nome literal:

1. `.claude/skills/terraform-deploy/scripts/discover_stacks.sh` — o script que a skill `terraform-deploy` usa para descobrir quais stacks existem contém uma exclusão hardcoded: `if [ "$name" = "remote-backend" ]; then continue; fi`. Qualquer stack com esse nome exato nunca aparece na lista de stacks a serem processadas pela skill, mesmo se o usuário pedir explicitamente ("aplica tudo", "sobe o remote-backend").
2. `.claude/skills/terraform-deploy/SKILL.md` reforça isso em texto: *"Nunca aplica uma stack chamada 'remote-backend' — ela é sempre ignorada, mesmo se pedida explicitamente"*.

A razão dessa exclusão é uma questão de **ordem de bootstrap**: o backend remoto não pode depender de si mesmo para ser criado. Enquanto o bucket S3 desta stack ainda não existe, não há onde armazenar o state *desta própria stack* remotamente — ela precisa, necessariamente, usar state local para si mesma, para sempre (ou até uma futura reestruturação de "bootstrap do bootstrap", explicitamente não recomendada e fora de escopo aqui). Por isso a skill `terraform-deploy` (que roda `fmt → init → validate → plan → apply` de forma semiautomática, com um gate de segurança para planos destrutivos) nunca deve tocar nesta stack — ela precisa ser sempre aplicada manualmente, por um humano, fora do fluxo automatizado.

Este agente (`aws-solution-architect`) é exclusivamente planejador: **não cria, não edita e não aplica** nenhum arquivo `.tf`, e **não executa** `terraform init/plan/apply`. Todo o código abaixo é especificação de referência para o agente de implementação (`aws-devops-engineer`), que deve aplicá-lo manualmente, exatamente como descrito na seção "Especificação de implementação", nunca através da skill `terraform-deploy`.

**Escopo explicitamente coberto por este ADR**: apenas a criação da stack `remote-backend/` e da infraestrutura AWS que ela provisiona (bucket S3 + configurações associadas). **Escopo explicitamente fora deste ADR**: a migração da stack `network/` (hoje com state local) para efetivamente usar este backend (`terraform init -migrate-state` em `network/`). Essa migração é uma operação de alto risco sobre uma stack já aplicada (mexe no mecanismo de persistência do state de 12 recursos já em produção-dev) e, por isso, decidiu-se tratá-la como matéria de **um ADR futuro e dedicado (candidato a ADR-005)** — ver justificativa detalhada na seção "Decisão" e o detalhamento do que essa migração exigirá na seção "Consequências". Isso segue o mesmo padrão já estabelecido neste repositório pelo ADR-003 (uma mudança de alto risco sobre infraestrutura já aplicada merece seu próprio ADR dedicado, com seu próprio gate de aprovação, em vez de ser anexada a um ADR de escopo diferente).

## Premissas

Assumidas por ausência de informação de negócio explícita; todas as premissas de negócio e os itens factuais que estavam marcados **A VALIDAR** na versão original deste ADR foram confirmados pelo solicitante/pela sessão de validação em **2026-07-10** — ver o texto de confirmação em cada item abaixo. O único ponto que permanece parcialmente em aberto (checagem de CloudTrail, Premissa #9) é explicitamente não bloqueante.

1. **Ambiente**: greenfield para esta stack — `remote-backend/` não existe hoje no repositório (confirmado por varredura: `docs/adr/`, `network/` e os diretórios `.claude/` são os únicos relevantes; não há `remote-backend/*.tf`).
2. **Nome da stack**: `remote-backend` (fixo, não negociável — ver "Contexto"). Este ADR usa esse nome exato em todos os caminhos de arquivo especificados.
3. **Conta/região**: mesma conta e região já usadas por `network/` — conta `508591324807`, região `us-east-1` (reaproveitado do estado já confirmado nos ADR-001/002/003, sem nova informação em contrário).
4. **Reuso do padrão de tags/variáveis da stack `network/`, com um ajuste deliberado**: esta stack reaproveita a mesma estrutura de variável `project` (`name`, `environment`, `aws_region`) e o mesmo bloco `default_tags` (`Project`, `Environment`, `ManagedBy`, `Repository`) já usados em `network/providers.tf`, para manter uma convenção de tagging única no repositório. **Ajuste**: `project.environment = "shared"` nesta stack, em vez de `"dev"` (valor usado em `network/`). Justificativa: o bucket de backend remoto é infraestrutura transversal — vai armazenar o state de *todas* as stacks e *todos* os ambientes que existirem no repositório no futuro (hoje só há "dev", mas isso pode mudar), não é um recurso "de ambiente dev" que faça sentido destruir/recriar junto com um eventual ciclo de vida de ambiente de teste. **Confirmado pelo solicitante em 2026-07-10**: `"shared"` é de fato o valor de tag desejado para esta stack (não `"dev"`).
5. **Um único bucket compartilhado por todas as stacks/ambientes, diferenciado por `key` (caminho do objeto)**, em vez de um bucket por stack ou por ambiente. Ver justificativa detalhada na seção "Decisão". **Confirmado pelo solicitante em 2026-07-10**: não há, hoje, requisito de isolar prod/dev (ou qualquer outro ambiente futuro) em buckets/contas separados — um único bucket compartilhado, diferenciado por `key`, está aprovado. Se um requisito real de isolamento forte por ambiente/conta surgir no futuro (ex.: exigência de compliance de segregar completamente state de prod do de dev), este ADR precisará ser revisto antes de o backend ganhar um segundo ambiente — mas isso não é uma pendência em aberto hoje.
6. **Mecanismo de locking: nativo via S3 (`use_lockfile`), sem DynamoDB** — decisão tomada nesta ADR (ver "Decisão" e "Alternativas"). Isso implica uma dependência de versão do Terraform CLI (`>= 1.11.0`) **apenas para as stacks que vierem a *consumir* este backend** (ex.: `network/`, quando migrada) — não para a criação do bucket em si, que não usa esse backend para si mesma. **Confirmado em 2026-07-10** (verificação direta no terminal do executor, fora do escopo de ferramentas deste agente planejador): `terraform version` → **v1.15.5**, acima do mínimo `>= 1.11.0` — o locking nativo (`use_lockfile`) é totalmente suportado nesse executor, sem necessidade de fallback para `dynamodb_table`. Esta confirmação vale para o executor verificado nesta data; se a migração futura de `network/` (ou de qualquer outra stack) ocorrer em um executor diferente, a versão deve ser reconfirmada naquele momento (ver também "Consequências").
7. **Object Lock (WORM) não é usado nesta stack**: deliberadamente não habilitado (`object_lock_enabled` não definido, default `false`). Justificativa: Object Lock impede sobrescrita/exclusão de objetos dentro do período de retenção, o que é incompatível com o padrão de escrita do backend `s3` do Terraform (que sobrescreve o objeto de state a cada `apply`) a menos que se use apenas modo `GOVERNANCE` com bypass em toda operação — complexidade desnecessária dado que **versionamento de bucket** (habilitado nesta ADR) já garante recuperação de versões anteriores do state sem bloquear escritas.
8. **Criptografia**: SSE-S3 (`AES256`), não SSE-KMS. Justificativa: nenhum requisito de compliance ou de uso de CMK (Customer Master Key) foi informado; SSE-S3 é gratuita e suficiente para o requisito padrão de "criptografia em repouso" desta organização (premissa de segurança padrão do agente planejador). **Confirmado pelo solicitante em 2026-07-10**: SSE-S3/`AES256` é de fato a opção desejada (sem KMS). Se, no futuro, surgir um requisito de compliance que exija chave gerenciada pelo cliente (KMS) com rotação/auditoria própria, este ADR precisará ser revisado (troca de `sse_algorithm` para `aws:kms` e adição de `kms_master_key_id`, com custo adicional de ~US$ 1/mês pela chave KMS + custo por request) — não é uma pendência aberta hoje.
9. **Logging de acesso ao bucket de state (S3 access logs ou CloudTrail data events dedicados) fica fora de escopo desta ADR** — **confirmado pelo solicitante em 2026-07-10**, na mesma linha de raciocínio que os ADR-001/002 deixaram VPC Flow Logs fora de escopo: não foi solicitado, e adicionar um segundo bucket (destino de access logs) só para este propósito seria desproporcional ao escopo de bootstrap desta stack. **Item técnico correlato, não bloqueante**: em 2026-07-10 tentou-se confirmar, via `aws cloudtrail describe-trails` (terminal local, role `tf_devops_admin-role`), se CloudTrail já está habilitado a nível de conta/organização — a chamada retornou `AccessDeniedException`, então não foi possível confirmar nesta sessão se o management-event trail padrão já cobre as chamadas de API de gerenciamento do S3 (`CreateBucket`/`PutBucketPolicy` etc.). Como a decisão de negócio (logging dedicado fora de escopo) já foi confirmada independentemente disso, essa checagem não bloqueia este ADR — fica registrada como item a revisitar em um eventual ADR futuro de observabilidade/auditoria, junto com a decisão sobre *data events* dedicados de leitura/escrita do state.
10. **`force_destroy = false`** no bucket: decisão deliberada e restritiva — um `terraform destroy` desta stack **falhará** se o bucket não estiver vazio (o que sempre será o caso depois do primeiro state remoto gravado nele). Isso é intencional: este bucket, por natureza, se torna um recurso de altíssimo blast radius (guarda o state de todas as demais stacks) e não deve ser destrutível "sem fricção".
11. **Convenção de nomenclatura**: este ADR segue integralmente `.claude/rules/terraform-naming.md` — variáveis agrupadas por domínio em `object`, sem `default` em `variables.tf`, valores em `terraform.tfvars`, arquivos nomeados por domínio (`bucket.tf`, `bucket.versioning.tf`, `bucket.server-side-encryption.tf`, `bucket.public-access-block.tf`, `bucket.ownership-controls.tf`, `bucket.policy.tf`, `bucket.lifecycle.tf`).
12. **Versão do provider AWS**: `hashicorp/aws ~> 6.54.0`, **validada via MCP Terraform** (`mcp__terraform__get_latest_provider_version`, namespace `hashicorp`, name `aws` → `6.54.0`, mais recente no momento deste ADR — uma versão acima da `6.53.0` fixada em `network/`). Como `remote-backend/` é uma stack Terraform independente, com seu próprio `versions.tf` e seu próprio lockfile de providers, ela pode adotar a versão mais recente do provider sem qualquer impacto sobre `network/` — não há necessidade de manter as duas stacks na mesma versão de provider. **Observação registrada, não bloqueante**: isso introduz uma pequena divergência de versão de provider entre stacks do mesmo repositório; se isso for indesejável por política interna (ainda não formalizada), a versão poderia ser alinhada manualmente para `~> 6.53.0` — decisão de baixo impacto, não bloqueante.
13. **Versão do Terraform core desta stack**: `>= 1.9.0`, a mesma baseline já usada em `network/` (sem necessidade de elevá-la *para esta stack*, já que ela não usa `backend "s3"`/`use_lockfile` para si mesma — ver Premissa #6). **Confirmado em 2026-07-10**: `terraform version` no executor → v1.15.5, portanto acima também desta baseline (`>= 1.9.0`) — sem qualquer incompatibilidade. Mesma verificação usada para resolver a Premissa #6.
14. **Credenciais AWS**: mesma premissa padrão dos ADRs anteriores — nunca hardcoded; vêm de variáveis de ambiente, profile nomeado ou OIDC/IRSA.
15. **Nome do bucket**: nomes de bucket S3 são globalmente únicos entre todas as contas AWS do mundo. O nome proposto (`devops-ia-tfstate-508591324807-us-east-1`) incorpora o Account ID e a região para minimizar risco de colisão de nome global, seguindo prática comum. **Confirmado em 2026-07-10**: `aws s3api head-bucket --bucket devops-ia-tfstate-508591324807-us-east-1` retornou `404 Not Found`, ou seja, o nome está disponível globalmente no momento desta verificação. **Observação que permanece válida**: como o namespace de nomes de bucket S3 é global e mutável por qualquer conta a qualquer momento, essa disponibilidade poderia, em teoria, mudar entre esta verificação e o `apply` efetivo (janela de corrida improvável, mas não nula); se o `apply` ainda assim falhar por nome já em uso, o tratamento é o descrito na seção "Estratégia de rollback" (ajustar `terraform.tfvars` e reexecutar `plan`/`apply`).

## Requisitos considerados

- **Funcional**: um bucket S3 existe, versionado, criptografado em repouso, com bloqueio total de acesso público, pronto para ser referenciado como `backend "s3"` por outras stacks Terraform deste repositório (a começar por `network/`, em ADR futuro). Locking de state via mecanismo nativo do backend `s3` (`use_lockfile`), sem depender de uma tabela DynamoDB adicional.
- **Não-funcional**:
  - **Segurança**: least privilege em toda policy IAM; sem wildcard `*` de recurso onde a API permite escopo (aqui, ao contrário das ADRs de rede, o nome do bucket é conhecido antecipadamente, então a maioria das ações pode ser restrita ao ARN exato do bucket); bloqueio de acesso público total; criptografia em repouso (SSE-S3) e em trânsito (política de bucket nega requests não-TLS); nenhuma credencial hardcoded.
  - **Confiabilidade/recuperação**: versionamento habilitado (permite recuperar uma versão anterior do state em caso de corrupção ou de um `apply` malsucedido futuro); lifecycle rule limita o crescimento indefinido do histórico de versões (expira versões não-atuais após um número configurável de dias).
  - **Bootstrap/ordem de execução**: esta stack nunca pode usar, para si mesma, o backend remoto que ela cria (dependência circular impossível) — deve permanecer com state local para sempre, e deve ser sempre aplicada manualmente, nunca via skill `terraform-deploy` (o próprio nome `remote-backend` já garante essa exclusão, conforme "Contexto").
  - **Custo**: deve permanecer efetivamente gratuita/desprezível — nenhum requisito de negócio justificaria custo recorrente relevante para um bucket que guarda alguns arquivos de state de poucos KB/MB.
  - Escala, RTO/RPO, compliance formal, multi-região: não informados pelo usuário; tratados como não aplicáveis a este ADR de bootstrap, à exceção do que já foi registrado como premissa acima.

## Alternativas consideradas

Eixo principal de comparação: **mecanismo de locking de state**, já que a arquitetura de "bucket S3 versionado e criptografado" é comum a todas as alternativas viáveis dentro do pedido original (o pedido já especificou S3 como armazenamento de state).

### Alternativa A — S3 + locking nativo via `use_lockfile` (RECOMENDADA)

O backend `s3` do Terraform core suporta, desde a versão 1.10 (lançado como recurso experimental) e como recurso estável/recomendado a partir da versão 1.11, um argumento `use_lockfile = true` que implementa locking de state usando **escritas condicionais do próprio S3** (sem necessidade de tabela DynamoDB). Um arquivo de lock (mesmo nome do state, com sufixo `.tflock`) é criado no início da maioria das operações e removido ao final. O caminho legado (`dynamodb_table`) está oficialmente **deprecado** pela HashiCorp e será removido em uma versão minor futura do Terraform.

- **Prós**: nenhum recurso AWS adicional além do próprio bucket (menos peças móveis, menos superfície de IAM); custo adicional zero (o locking usa o mesmo bucket S3, sem tabela paga); é o caminho oficialmente recomendado pela HashiCorp daqui para frente (o caminho DynamoDB está em rota de remoção); simplifica a migração futura de `network/` (só precisa do bloco `backend "s3"` com `bucket`, `key`, `region`, `encrypt`, `use_lockfile` — sem provisionar/gerenciar uma segunda peça de infraestrutura).
- **Contras**: exige Terraform CLI `>= 1.11.0` em **toda stack que for consumir** este backend (não nesta stack de criação do bucket em si) — uma dependência de versão que precisa ser reconfirmada no executor antes de qualquer migração futura (ver Premissa #6, já confirmada para o executor verificado em 2026-07-10); é um recurso relativamente recente (GA desde o final de 2025), com menos histórico de produção em comparação ao padrão DynamoDB, que é usado há anos pela comunidade.
- **Impacto Well-Architected**:
  - Excelência Operacional: positivo (menos recursos para operar e auditar; um único bucket concentra toda a superfície da stack).
  - Segurança: neutro/positivo (menor superfície de IAM — sem permissões de DynamoDB a gerenciar/auditar).
  - Confiabilidade: neutro (mecanismo de lock via escrita condicional do S3 é funcionalmente equivalente ao lock via DynamoDB para o caso de uso de Terraform).
  - Eficiência de Performance: neutro (sem diferença perceptível de performance para o volume de uso — alguns `apply`s por dia, no máximo).
  - Otimização de Custo: máximo (US$ 0,00 adicional; um recurso a menos para cobrar, mesmo que marginalmente).
  - Sustentabilidade: neutro/positivo (menos recursos provisionados e ociosos).
- **Estimativa de custo mensal adicional pelo locking**: US$ 0,00 (usa o mesmo bucket já necessário para o state).

### Alternativa B — S3 + tabela DynamoDB dedicada para locking (padrão clássico)

Padrão amplamente usado historicamente: uma tabela DynamoDB (`billing_mode = "PAY_PER_REQUEST"`, chave de partição obrigatoriamente nomeada `LockID`, tipo `S`, por convenção exigida pelo mecanismo legado do backend `s3` do Terraform) armazena o lock de cada operação, referenciada via `dynamodb_table` no bloco `backend "s3"`.

- **Prós**: padrão maduro, testado em produção por anos em toda a comunidade Terraform; não depende de uma versão mínima recente do Terraform CLI (funciona desde versões muito antigas do backend `s3`); mais familiar para times que já operam outras stacks com esse padrão.
- **Contras**: recurso AWS adicional a provisionar, ter uma política IAM própria e manter (mais superfície de auditoria); a HashiCorp já **deprecou oficialmente** esse caminho (`dynamodb_table`) com plano de remoção em versão minor futura — adotar este padrão agora significa herdar uma migração futura obrigatória mais cedo ou mais tarde; custo adicional, embora muito baixo em modo `PAY_PER_REQUEST` para o volume de uso esperado (poucos `apply`s por dia).
- **Impacto Well-Architected**:
  - Excelência Operacional: neutro/levemente negativo (mais um recurso e uma policy IAM a versionar e revisar).
  - Segurança: neutro (mesma postura de acesso, apenas mais uma superfície de permissões a auditar).
  - Confiabilidade: neutro (equivalente à Alternativa A para o propósito de lock).
  - Eficiência de Performance: neutro.
  - Otimização de Custo: bom, mas não ótimo (custo não-zero, ainda que muito baixo).
  - Sustentabilidade: levemente pior (mais um recurso provisionado e sempre ativo, mesmo que quase sem uso).
- **Estimativa de custo mensal adicional pelo locking**: da ordem de poucos centavos de dólar por mês para o volume de uso esperado (dezenas de operações de `plan`/`apply` por mês, cada uma gerando poucas leituras/escritas de 1 item na tabela) — baseado em conhecimento geral de precificação on-demand do DynamoDB (cobrança por *read/write request unit*, sem tarifa fixa mensal); o valor exato em US$/milhão de requests **não foi reconfirmado com uma cifra específica via MCP nesta sessão** (não bloqueia a decisão, pois esta alternativa não foi a escolhida — ver "Decisão").

### Alternativa C (descartada rapidamente) — Backend gerenciado HCP Terraform / Terraform Cloud

Em vez de S3, usar o backend remoto gerenciado pela própria HashiCorp (HCP Terraform, antigo Terraform Cloud), que oferece state remoto, locking e histórico de runs como serviço SaaS, fora da conta AWS.

- **Por que foi descartada sem aprofundamento**: o pedido explícito do solicitante já especificou "bucket S3 para state + DynamoDB para lock, ou lock via S3 nativo" — ou seja, a decisão de usar S3/AWS como armazenamento já foi tomada fora deste ADR. Adicionalmente, HCP Terraform exigiria uma conta/organização separada fora do perímetro AWS já estabelecido, tokens de API adicionais a gerenciar como segredo, e squeeze de custo dependendo do tier (grátis até um certo número de recursos gerenciados, pago acima disso) — uma mudança de superfície de confiança e de modelo operacional desproporcional ao que foi pedido. Não avaliada em detalhe pelos pilares Well-Architected por esse motivo.
- **Estimativa de custo mensal**: não avaliada (fora de escopo).

## Decisão

**Alternativa A — S3 com locking nativo via `use_lockfile`, sem DynamoDB.**

Justificativa: (1) a HashiCorp já sinalizou a descontinuação do caminho DynamoDB (`dynamodb_table` deprecado, remoção planejada em versão minor futura) — adotar DynamoDB agora significa migrar de novo em breve; (2) este repositório já demonstrou, em ADRs anteriores (ADR-002, decisão de manter `nat_gateway.enabled = false` para evitar custo recorrente), uma preferência clara por minimizar recursos e custo recorrente quando não há requisito de negócio que justifique o contrário — o locking nativo elimina um recurso inteiro (tabela + policy IAM) sem nenhuma perda funcional relevante para o volume de uso esperado (uma stack de infraestrutura interna, não um pipeline de CI de alta concorrência); (3) o único custo dessa escolha — a exigência de Terraform CLI `>= 1.11.0` nas stacks consumidoras — é um custo *de versão*, não financeiro, e já foi confirmado como atendido no executor verificado em 2026-07-10 (`v1.15.5`).

**Sub-decisão — um único bucket compartilhado, não um bucket por stack/ambiente**: o bucket `devops-ia-tfstate-508591324807-us-east-1` guardará o state de **todas** as stacks Terraform deste repositório, diferenciadas pela `key` do objeto (caminho dentro do bucket, ex.: `network/terraform.tfstate` para a stack `network/`). Justificativa: (a) hoje há uma única conta AWS e um único ambiente lógico ("dev") em uso — criar múltiplos buckets antecipando uma segregação de ambiente/conta que ainda não existe seria over-engineering (mesmo princípio de YAGNI já aplicado no ADR-001 para descartar um módulo local prematuro); (b) um bucket único com prefixos por stack é o padrão idiomático mais comum para repositórios Terraform de porte pequeno/médio com uma conta AWS; (c) se no futuro surgir um requisito real de multi-conta ou de isolamento forte por ambiente (ex.: prod totalmente segregada de dev), a migração para múltiplos buckets é direta (criar novo bucket, `key` diferente, sem impacto no bucket existente) e deve ser tratada, quando chegar, como um ADR próprio — não antecipada aqui sem requisito. Esta sub-decisão foi confirmada pelo solicitante em 2026-07-10 (Premissa #5).

**GATE DE APROVAÇÃO HUMANA OBRIGATÓRIO**: mesmo com custo estimado em US$ 0,00/mês e sem nenhuma operação destrutiva sobre recursos já existentes (esta é uma stack inteiramente nova, greenfield), o `apply` desta ADR cria um recurso de altíssimo blast radius futuro (o bucket que passará a guardar o state de toda a infraestrutura do repositório). Nenhum `terraform apply` desta ADR pode ser executado pelo `aws-devops-engineer` sem confirmação humana explícita, e — reforçando o ponto mais crítico deste ADR — **sem que essa aplicação seja feita manualmente, fora da skill `terraform-deploy`** (que já ignora esta stack por nome, mas a instrução vale mesmo que, por engano, alguém tente rodá-la de outra forma automatizada). Este gate permanece válido mesmo após a confirmação de todas as premissas de negócio e técnicas registrada em 2026-07-10.

## Especificação de implementação (para o agente DevOps)

### 0. Instrução crítica sobre a skill `terraform-deploy` — leia antes de tudo

**Esta stack nunca deve ser aplicada através da skill `terraform-deploy`.** O script `.claude/skills/terraform-deploy/scripts/discover_stacks.sh` já exclui, por nome de diretório, qualquer stack chamada exatamente `remote-backend`. Isso só funciona se o diretório desta stack for nomeado **exatamente** `remote-backend` (não `remote_backend`, não `terraform-backend`, não `bootstrap`) — ver seção 1 abaixo. Se o `aws-devops-engineer` for solicitado a "aplicar tudo" ou "rodar o deploy", esta stack deve ser pulada pelo fluxo automatizado (comportamento já garantido pela skill) e aplicada apenas pelos passos manuais descritos na seção 9 deste ADR, com um humano acompanhando cada etapa.

### 1. Estrutura de diretório e arquivos a criar

Caminho exato: `remote-backend/` (raiz do repositório, ao lado de `network/`).

```
remote-backend/
├── versions.tf
├── providers.tf
├── variables.tf
├── terraform.tfvars
├── bucket.tf
├── bucket.versioning.tf
├── bucket.server-side-encryption.tf
├── bucket.public-access-block.tf
├── bucket.ownership-controls.tf
├── bucket.policy.tf
├── bucket.lifecycle.tf
└── outputs.tf
```

**Nenhum arquivo desta stack deve conter um bloco `backend "s3"` (ou qualquer outro bloco `backend`)** — ver "Contexto"/Premissa de bootstrap. O state desta stack permanece local.

### 2. `remote-backend/versions.tf`

Versão do provider validada via MCP Terraform (`mcp__terraform__get_latest_provider_version`, namespace `hashicorp`, name `aws` → **6.54.0**, mais recente no momento deste ADR). Versão do Terraform CLI do executor confirmada em 2026-07-10 (`terraform version` → v1.15.5, acima da baseline exigida abaixo).

```hcl
terraform {
  required_version = ">= 1.9.0" # confirmado em 2026-07-10: terraform version no executor = v1.15.5 (acima do mínimo exigido)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54.0" # validado via MCP Terraform: hashicorp/aws latest = 6.54.0
    }
  }

  # Nenhum bloco `backend` é declarado propositalmente nesta stack. Esta é a
  # própria stack que cria o backend remoto de state usado por outras stacks
  # do repositório — ela não pode depender de si mesma (bootstrap). O state
  # desta stack permanece local para sempre, ou até uma futura reestruturação
  # de "bootstrap do bootstrap" (não recomendada, fora de escopo). Ver ADR-004.
}
```

### 3. `remote-backend/providers.tf`

Mesmo padrão de `network/providers.tf` (região via variável, `default_tags` obrigatório), com `environment = "shared"` (ver Premissa #4, confirmada pelo solicitante em 2026-07-10).

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

### 4. `remote-backend/variables.tf`

Argumentos validados via MCP Terraform (`mcp__terraform__get_provider_details`, providerDocIDs `12782741` `aws_s3_bucket`, `12782762` `aws_s3_bucket_versioning`, `12782761` `aws_s3_bucket_server_side_encryption_configuration`, `12782758` `aws_s3_bucket_public_access_block`, `12782756` `aws_s3_bucket_ownership_controls`, `12782757` `aws_s3_bucket_policy`, `12782749` `aws_s3_bucket_lifecycle_configuration`, provider `hashicorp/aws` v6.54.0).

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

variable "state_bucket" {
  description = "Configuração do bucket S3 usado como backend remoto de state Terraform, compartilhado por todas as stacks deste repositório."
  type = object({
    name                                = string
    force_destroy                       = bool
    noncurrent_version_expiration_days  = number
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
```

### 5. `remote-backend/terraform.tfvars`

```hcl
project = {
  name        = "devops-ia"
  environment = "shared" # ver ADR-004, Premissa #4 — confirmado pelo solicitante em 2026-07-10 (infraestrutura cross-ambiente, não "dev")
  aws_region  = "us-east-1"
}

state_bucket = {
  # Nome globalmente único; inclui Account ID e região para evitar colisão de
  # namespace global do S3. Disponibilidade confirmada em 2026-07-10 via
  # `aws s3api head-bucket` (404 Not Found = nome livre) — ver ADR-004, Premissa #15.
  name                                = "devops-ia-tfstate-508591324807-us-east-1"
  force_destroy                       = false
  noncurrent_version_expiration_days  = 90
}
```

### 6. `remote-backend/bucket.tf`

```hcl
resource "aws_s3_bucket" "this" {
  bucket        = var.state_bucket.name
  force_destroy = var.state_bucket.force_destroy

  tags = {
    Name = var.state_bucket.name
  }
}
```

### 7. `remote-backend/bucket.versioning.tf`

Versionamento obrigatório (premissa de recuperação de state — ver "Requisitos considerados").

```hcl
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

### 8. `remote-backend/bucket.server-side-encryption.tf`

SSE-S3 (`AES256`), decisão registrada na Premissa #8 (confirmada pelo solicitante em 2026-07-10) — sem KMS, por ausência de requisito de compliance que justifique o custo/complexidade adicional.

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

### 9. `remote-backend/bucket.public-access-block.tf`

Bloqueio total de acesso público — premissa de segurança padrão (isolamento de rede/acesso mínimo).

```hcl
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### 10. `remote-backend/bucket.ownership-controls.tf`

`BucketOwnerEnforced` desabilita ACLs por completo (recomendação atual da AWS para buckets novos, simplifica a superfície de controle de acesso para depender exclusivamente de bucket policy/IAM).

```hcl
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
```

### 11. `remote-backend/bucket.policy.tf`

Nega qualquer requisição não-TLS ao bucket (criptografia em trânsito obrigatória — premissa de segurança padrão).

```hcl
data "aws_iam_policy_document" "deny_insecure_transport" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.deny_insecure_transport.json
}
```

**A VALIDAR** (não bloqueante para este `apply`): esta policy não restringe *quais* principals/roles podem ler ou escrever objetos no bucket (além da restrição de transporte) — essa restrição normalmente viria via IAM policy anexada à role/usuário que executa o Terraform de cada stack consumidora (ver seção 13, "Policy de referência para stacks consumidoras"), não via bucket policy. Se, no futuro, for necessário também negar acesso de contas/principals fora desta conta AWS diretamente na bucket policy (defesa em profundidade), isso pode ser adicionado como uma statement adicional em um ADR de hardening subsequente — não incluído aqui por não haver ARNs de roles/contas conhecidas a essa altura.

### 12. `remote-backend/bucket.lifecycle.tf`

Expira versões não-atuais do state após `var.state_bucket.noncurrent_version_expiration_days` dias, para limitar o crescimento indefinido do histórico de versões (e, por consequência, o custo de storage).

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_bucket.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
```

### 13. `remote-backend/outputs.tf`

```hcl
output "state_bucket_id" {
  description = "Nome (ID) do bucket S3 usado como backend remoto de state Terraform."
  value       = aws_s3_bucket.this.id
}

output "state_bucket_arn" {
  description = "ARN do bucket S3 usado como backend remoto de state Terraform."
  value       = aws_s3_bucket.this.arn
}

output "state_bucket_region" {
  description = "Região AWS onde o bucket de state reside."
  value       = aws_s3_bucket.this.bucket_region
}
```

### 14. IAM (least privilege)

#### 14.1 Policy para o executor desta stack (`remote-backend/`) — criação/gestão do bucket

Diferente das ADRs de rede (ADR-001/002), aqui o nome do recurso (bucket) é conhecido antecipadamente via `terraform.tfvars`, então a policy pode ser restrita ao ARN exato do bucket, sem necessidade de `Resource: "*"`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketLifecycleActions",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketOwnershipControls",
        "s3:PutBucketOwnershipControls",
        "s3:GetBucketPolicy",
        "s3:PutBucketPolicy",
        "s3:DeleteBucketPolicy",
        "s3:GetLifecycleConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:GetBucketTagging",
        "s3:PutBucketTagging"
      ],
      "Resource": "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1"
    }
  ]
}
```

#### 14.2 Policy de referência para stacks consumidoras (ex.: `network/`, quando migrada — NÃO aplicar agora)

Incluída aqui apenas como especificação de referência para o futuro ADR de migração (fora de escopo deste ADR — ver "Contexto"/"Consequências"). Concede acesso apenas ao objeto de state e ao lockfile da stack específica (`<stack>`), nunca ao bucket inteiro.

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
        "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1/<stack>/terraform.tfstate",
        "arn:aws:s3:::devops-ia-tfstate-508591324807-us-east-1/<stack>/terraform.tfstate.tflock"
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
          "s3:prefix": ["<stack>/*"]
        }
      }
    }
  ]
}
```

`<stack>` deve ser substituído pelo nome do diretório da stack consumidora (ex.: `network`) no momento em que essa policy for de fato criada/anexada, no ADR de migração correspondente.

### 15. Dependências e ordem de execução

1. Criar a estrutura de diretório e os 11 arquivos `.tf` exatamente como especificado nas seções 2 a 13.
2. **Não** rodar isso via skill `terraform-deploy` (ver seção 0). Todos os passos abaixo são manuais.
3. `cd remote-backend/`
4. `terraform init` (state local — nenhum backend remoto configurado para esta própria stack; deve baixar `hashicorp/aws` `~> 6.54.0` sem erros).
5. `terraform fmt -check` — corrigir com `terraform fmt` se houver diferenças.
6. `terraform validate` — deve retornar `Success!`.
7. `terraform plan -out=tfplan` — revisar cuidadosamente. Plano esperado: **7 resources to add** (`aws_s3_bucket.this`, `aws_s3_bucket_versioning.this`, `aws_s3_bucket_server_side_encryption_configuration.this`, `aws_s3_bucket_public_access_block.this`, `aws_s3_bucket_ownership_controls.this`, `aws_s3_bucket_policy.this`, `aws_s3_bucket_lifecycle_configuration.this`) mais a leitura do data source `aws_iam_policy_document.deny_insecure_transport` (não conta como recurso gerenciado), **0 to change, 0 to destroy**.
8. **Ponto de decisão humana obrigatório**: apresentar o plano completo (`terraform show tfplan`) a um humano responsável e obter aprovação explícita antes de qualquer `apply`. Este agente planejador não aprova nem executa o `apply`.
9. Após aprovação humana, o `aws-devops-engineer` executa `terraform apply tfplan` **manualmente**, dentro de `remote-backend/`.
10. Imediatamente após o `apply`, executar `terraform output` e registrar `state_bucket_id`/`state_bucket_arn`/`state_bucket_region` — esses valores serão necessários no bloco `backend "s3"` de qualquer stack futura que consumir este backend.
11. **Não** prosseguir, nesta mesma tarefa, para migrar `network/` (ou qualquer outra stack) a usar este backend — isso é fora de escopo deste ADR (ver "Contexto"). Se solicitado, escalar para que um novo ADR dedicado (ADR-005 ou posterior) seja criado antes de qualquer `terraform init -migrate-state`.

### 16. Parâmetros validados via MCP vs. A VALIDAR

| Parâmetro | Valor | Validado via | Status |
|---|---|---|---|
| Versão provider `hashicorp/aws` | 6.54.0 | `mcp__terraform__get_latest_provider_version` | Validado |
| Schema do recurso `aws_s3_bucket` | argumentos `bucket`, `force_destroy`, `tags`; atributos `id`, `arn`, `bucket_region` | `mcp__terraform__get_provider_details` (providerDocID 12782741) | Validado |
| Schema do recurso `aws_s3_bucket_versioning` | argumentos `bucket`, `versioning_configuration.status` | `mcp__terraform__get_provider_details` (providerDocID 12782762) | Validado |
| Schema do recurso `aws_s3_bucket_server_side_encryption_configuration` | argumentos `bucket`, `rule.apply_server_side_encryption_by_default.sse_algorithm` (`AES256`/`aws:kms`/`aws:kms:dsse`) | `mcp__terraform__get_provider_details` (providerDocID 12782761) | Validado |
| Schema do recurso `aws_s3_bucket_public_access_block` | argumentos `bucket`, `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` | `mcp__terraform__get_provider_details` (providerDocID 12782758) | Validado |
| Schema do recurso `aws_s3_bucket_ownership_controls` | argumento `rule.object_ownership` (`BucketOwnerEnforced`/`BucketOwnerPreferred`/`ObjectWriter`) | `mcp__terraform__get_provider_details` (providerDocID 12782756) | Validado |
| Schema do recurso `aws_s3_bucket_policy` | argumentos `bucket`, `policy` | `mcp__terraform__get_provider_details` (providerDocID 12782757) | Validado |
| Schema do recurso `aws_s3_bucket_lifecycle_configuration` | argumentos `bucket`, `rule.id`, `rule.status`, `rule.filter`, `rule.noncurrent_version_expiration.noncurrent_days` | `mcp__terraform__get_provider_details` (providerDocID 12782749) | Validado |
| Schema do recurso `aws_dynamodb_table` (avaliado para a Alternativa B, descartada) | argumentos `name`, `billing_mode`, `hash_key`, `attribute` | `mcp__terraform__get_provider_details` (providerDocID 12781997) | Validado |
| Backend `s3` — argumento `use_lockfile` (locking nativo) | introduzido experimentalmente no Terraform 1.10, recomendado/estável a partir do 1.11; `dynamodb_table` deprecado, remoção planejada em versão minor futura | Pesquisa web (developer.hashicorp.com/terraform/language/backend/s3; múltiplas fontes independentes corroborando a mesma linha do tempo — ver "Referências") | Validado (não há tool MCP dedicado a schema de backend Terraform; backend não é um "provider" no sentido do MCP Terraform) |
| Disponibilidade de "Amazon Simple Storage Service (S3)" e "Amazon DynamoDB" em `us-east-1` | `isAvailableIn` para ambos | `mcp__aws-mcp__aws___get_regional_availability` | Validado |
| Preço de storage S3 Standard (primeiro tier) | US$ 0,023/GB/mês (primeiros 50 TB) | `mcp__aws-mcp__aws___search_documentation` (AWS Billing/Cost docs) | Validado |
| Preço de request unit do DynamoDB on-demand (para a Alternativa B, descartada) | ordem de grandeza "poucos centavos/mês" para o volume esperado; cifra exata em US$/milhão de requests não reconfirmada nesta sessão | `mcp__aws-mcp__aws___search_documentation` (retornou o modelo de cobrança, não a tabela de preços numérica exata) | Parcialmente validado — não bloqueante (alternativa não escolhida) |
| Account ID / nome exato do bucket disponível globalmente | `508591324807` (reaproveitado); nome `devops-ia-tfstate-508591324807-us-east-1` confirmado disponível (`head-bucket` → `404 Not Found`) | Informado pelo solicitante (Account ID); disponibilidade do nome verificada em 2026-07-10 via terminal local/`mcp__aws-mcp__aws___call_aws` (`aws s3api head-bucket`) | Validado |
| Versão do binário Terraform CLI instalado no executor | `v1.15.5` confirmada — acima da baseline `>= 1.9.0` desta stack e do mínimo `>= 1.11.0` exigido para `use_lockfile` em futuras stacks consumidoras | Verificação direta em 2026-07-10 (`terraform version` no terminal do executor) | Validado |
| CloudTrail habilitado a nível de conta/organização (item correlato à Premissa #9, não bloqueante) | Não confirmado — tentativa de checagem retornou `AccessDeniedException` na role `tf_devops_admin-role` | Tentativa via `aws cloudtrail describe-trails` (terminal local) em 2026-07-10 | **A VALIDAR** — não bloqueante (decisão de negócio da Premissa #9 já confirmada independentemente); candidato a ADR futuro de observabilidade |

## Consequências

**Positivas**
- O repositório passa a ter, pela primeira vez, a infraestrutura necessária para state remoto — resolvendo a pendência "A VALIDAR: backend de state remoto" registrada em todos os ADRs anteriores (ADR-001, ADR-002, ADR-003).
- Escolha do locking nativo via `use_lockfile` remove a necessidade de uma tabela DynamoDB (menos recursos, menos IAM, menos custo, alinhado à direção oficial da HashiCorp).
- Bucket com postura de segurança forte por padrão: bloqueio total de acesso público, criptografia em repouso e em trânsito, ACLs desabilitadas (`BucketOwnerEnforced`), versionamento habilitado.
- Nome do bucket conhecido antecipadamente permite policies IAM restritas ao ARN exato do recurso (melhoria de least privilege em relação às ADRs de rede, onde as ações de API do EC2 não suportam esse nível de restrição).
- Escopo estritamente contido: nenhuma stack existente (`network/`) é tocada por este ADR — zero risco sobre infraestrutura já aplicada.
- Todas as premissas de negócio e os itens factuais técnicos que estavam em aberto foram confirmados em 2026-07-10 (ver Premissas #4, #5, #6, #8, #9, #13, #15) — o único ponto residual (checagem de CloudTrail) é explicitamente não bloqueante.

**Negativas / riscos e mitigação**
- **Esta stack em si permanece com state local para sempre** (não pode usar o backend que ela mesma cria) — continua exposta ao mesmo risco de perda/corrupção de state local que as demais stacks tinham antes deste ADR, mas o blast radius aqui é menor (um único bucket, recurso idempotente e barato de recriar caso o state se perca — o bucket físico na AWS não seria perdido, apenas precisaria ser reimportado). Mitigação: tratar `remote-backend/terraform.tfstate` como um arquivo especialmente crítico para backup manual (fora do escopo de automação deste ADR).
- **Dependência de versão do Terraform CLI (`>= 1.11.0`) para qualquer stack que vier a consumir este backend com locking nativo** — confirmado em 2026-07-10 que o executor atual roda `v1.15.5` (acima do mínimo), mas essa confirmação vale para o executor verificado nesta data; se a migração futura de `network/` ocorrer em um executor diferente (ou muito tempo depois, após possíveis trocas de ambiente/ferramenta), a versão deve ser reconfirmada antes daquele `apply` — caso contrário a migração falharia ou exigiria fallback para `dynamodb_table`. Mitigação: reconfirmação de versão deve constar explicitamente no ADR de migração futuro.
- **Nome de bucket pode já estar em uso globalmente por outra conta AWS** (namespace global do S3) — confirmado disponível em 2026-07-10 (`head-bucket` → `404 Not Found`), mas essa é uma checagem pontual: se o `apply` ocorrer muito tempo depois desta verificação, outra conta poderia, em teoria, registrar o mesmo nome antes disso (janela de corrida improvável). Mitigação: nome inclui Account ID + região para minimizar a chance; se ainda assim colidir no momento do `apply`, ajustar `terraform.tfvars` e reexecutar o `plan`/`apply` (mudança de baixo risco, sem impacto em recursos já criados).
- **Bucket único compartilhado por todas as stacks/ambientes é um ponto de concentração de risco**: uma política ou permissão mal configurada no bucket afeta o state de todas as stacks presentes e futuras. Mitigação: bucket policy restritiva (nega tráfego não-TLS), `BucketOwnerEnforced`, bloqueio público total, e a recomendação de que cada stack consumidora receba uma policy IAM object-level restrita ao seu próprio prefixo (`<stack>/*`), nunca acesso ao bucket inteiro (ver seção 14.2).
- **Ausência de logging/auditoria dedicado de acesso ao bucket de state** (fora de escopo, ver Premissa #9): reduz a visibilidade sobre quem lê/escreve o state ao longo do tempo. A tentativa de confirmar se o CloudTrail de management events já cobre a conta a nível de organização falhou por falta de permissão (`AccessDeniedException` na role `tf_devops_admin-role`, checagem de 2026-07-10) — o estado real de CloudTrail na conta permanece desconhecido. Mitigação: sinalizado como candidato a ADR futuro de observabilidade, que deve incluir a reconfirmação desse ponto com uma role com permissão de leitura sobre CloudTrail.
- **Divergência de versão de provider AWS entre stacks** (`network/` em `~> 6.53.0`, `remote-backend/` em `~> 6.54.0`): sem impacto funcional conhecido (cada stack tem seu próprio lockfile), mas é uma pequena inconsistência de repositório. Mitigação: aceitável para esta ADR; pode ser unificada manualmente no futuro se uma política de versão única for adotada.

**Impactos operacionais**
- Monitoramento: nenhum recurso de logging/alarme é criado por este ADR (ver Premissa #9). Recomenda-se abrir um ADR específico se houver necessidade de auditoria fina de acesso ao state, incluindo a reconfirmação do status do CloudTrail na conta.
- Backup: o versionamento do bucket + a lifecycle rule de expiração de versões não-atuais (90 dias, configurável) funcionam como a estratégia de "backup" do próprio state remoto, uma vez que outras stacks passem a usá-lo. O state local desta própria stack (`remote-backend/terraform.tfstate`) não tem backup automatizado — deve ser tratado manualmente com o mesmo cuidado que qualquer state local crítico do repositório.
- Manutenção: qualquer mudança de nome de bucket, algoritmo de criptografia, ou política de lifecycle deve passar por um novo ADR (mudança arquitetural, não ajuste operacional trivial), dado o papel central que este bucket passa a ter no repositório.

## Estimativa de custo

Valores validados via MCP AWS (`mcp__aws-mcp__aws___search_documentation`, Amazon S3 pricing/billing docs) onde indicado; demais valores por conhecimento geral consolidado, sem cifra exata reconfirmada nesta sessão (marcado abaixo).

| Recurso | Custo unitário | Estimativa para este caso de uso |
|---|---|---|
| Armazenamento S3 Standard | US$ 0,023/GB/mês (primeiro tier, validado via MCP) | Arquivos de state Terraform tipicamente pesam de poucos KB a poucos MB cada; mesmo com histórico de versões de múltiplas stacks acumulado por meses, o total fica muito abaixo de 1 GB — custo efetivo **< US$ 0,01/mês** |
| Requests (PUT/GET/LIST) contra o bucket | cobrança por request, ordem de fração de centavo por milhares de requests (não reconfirmado com cifra exata nesta sessão) | Para o volume esperado (dezenas de `plan`/`apply` por mês, cada um gerando poucas dezenas de requests) o total é irrisório — estimado em **< US$ 0,01/mês** |
| Locking nativo via `use_lockfile` | US$ 0,00 (usa o mesmo bucket, sem tabela adicional) | US$ 0,00 |
| Public Access Block, Ownership Controls, Bucket Policy, Lifecycle Configuration | sem cobrança direta | US$ 0,00 |
| **Total estimado** | — | **efetivamente US$ 0,00/mês** (abaixo de US$ 0,01/mês mesmo em uso contínuo) |

Não há, portanto, nenhum driver de custo relevante introduzido por este ADR. Caso a Alternativa B (DynamoDB) fosse escolhida no lugar, o custo adicional seria da ordem de poucos centavos de dólar por mês — ainda assim baixo, mas não zero, e não escolhido nesta ADR.

## Estratégia de rollback

1. Como esta é uma stack nova (greenfield) e nenhuma outra stack do repositório depende dela ainda (a migração de `network/` está fora de escopo — ver "Contexto"), o rollback é direto: `terraform destroy` dentro de `remote-backend/`.
2. **Atenção**: com `force_destroy = false` (Premissa #10), o `destroy` **falhará** se o bucket já tiver algum objeto (ex.: se uma stack já tiver sido migrada para usar este backend, mesmo que por engano ou fora do processo previsto por este ADR). Isso é intencional — funciona como uma proteção adicional contra destruição acidental de um bucket que já esteja em uso real. Se o `destroy` for de fato necessário e intencional mesmo com objetos presentes, o agente de implementação deve escalar para decisão humana explícita antes de alterar `force_destroy` para `true` e reaplicar.
3. Antes de qualquer `destroy`, fazer backup do arquivo de state local desta stack (`remote-backend/terraform.tfstate`/`.backup`).
4. Se o `apply` falhar parcialmente (ex.: nome de bucket já em uso globalmente — ver Premissa #15), nenhum recurso terá sido criado com sucesso (a criação do bucket é o primeiro recurso e todos os demais dependem dele); um novo `terraform plan` após corrigir `terraform.tfvars` deve refletir isso corretamente antes de qualquer novo `apply`.
5. Qualquer `destroy` desta stack, uma vez que ela já tenha sido usada como backend por qualquer outra stack do repositório, exige aprovação humana explícita e uma análise de impacto equivalente à de uma ADR própria — destruir este bucket nesse cenário destruiria o state remoto de todas as stacks consumidoras.

## Critérios de aceite

- [ ] Diretório `remote-backend/` existe na raiz do repositório contendo exatamente os 11 arquivos especificados na seção "Estrutura de diretório e arquivos a criar".
- [ ] Nenhum arquivo desta stack contém um bloco `backend "s3"` (ou qualquer bloco `backend`).
- [ ] `terraform init` executa sem erros (state local, provider `hashicorp/aws` resolvido em `~> 6.54.0`).
- [ ] `terraform fmt -check` não reporta diferenças.
- [ ] `terraform validate` retorna `Success!`.
- [ ] `terraform plan` mostra exatamente 7 recursos a serem criados (listados na seção 15, passo 7), 0 a alterar, 0 a destruir.
- [ ] Nenhum arquivo `.tf` contém `access_key`, `secret_key` ou qualquer credencial literal.
- [ ] **Aprovação humana registrada** para o `apply`, e o `apply` foi executado **manualmente**, fora da skill `terraform-deploy`.
- [ ] Após `apply`: o bucket `devops-ia-tfstate-508591324807-us-east-1` existe, com versionamento `Enabled`, SSE-S3 (`AES256`) configurado, Public Access Block com as 4 flags `true`, Ownership Controls em `BucketOwnerEnforced`, bucket policy negando tráfego não-TLS, e lifecycle rule expirando versões não-atuais após 90 dias.
- [ ] Outputs `state_bucket_id`, `state_bucket_arn`, `state_bucket_region` retornam valores não vazios após `apply`, e foram registrados para uso em um ADR futuro de migração.
- [ ] Nenhuma stack existente (`network/`) foi modificada por este ADR — `network/terraform.tfstate` permanece local e intacto.
- [ ] `.claude/skills/terraform-deploy/scripts/discover_stacks.sh` continua excluindo `remote-backend` da lista de stacks (checagem de que o nome do diretório não foi alterado por engano).

## Referências

- MCP Terraform — `mcp__terraform__get_latest_provider_version` (namespace `hashicorp`, name `aws`) → versão 6.54.0.
- MCP Terraform — `mcp__terraform__search_providers` + `mcp__terraform__get_provider_details` → schemas de `aws_s3_bucket` (providerDocID 12782741), `aws_s3_bucket_versioning` (12782762), `aws_s3_bucket_server_side_encryption_configuration` (12782761), `aws_s3_bucket_public_access_block` (12782758), `aws_s3_bucket_ownership_controls` (12782756), `aws_s3_bucket_policy` (12782757), `aws_s3_bucket_lifecycle_configuration` (12782749), `aws_dynamodb_table` (12781997, avaliado para a Alternativa B descartada).
- WebSearch/WebFetch — developer.hashicorp.com/terraform/language/backend/s3 e múltiplas fontes independentes (Medium "Goodbye DynamoDB — Terraform S3 Backend Now Supports Native Locking"; bschaatsbergen.com "S3 native state locking"; tinfoilcipher.co.uk "Terraform – AWS S3 Native State Locking"; dev.to "Terraform state with native s3 locking") — confirmação de que `use_lockfile` foi introduzido experimentalmente no Terraform 1.10 e passou a estável/recomendado a partir do 1.11, e de que `dynamodb_table` está oficialmente deprecado com remoção planejada em versão minor futura.
- MCP AWS — `mcp__aws-mcp__aws___get_regional_availability` (resource_type `product`, region `us-east-1`, filtros "Amazon Simple Storage Service (S3)" e "Amazon DynamoDB") → `isAvailableIn` para ambos.
- MCP AWS — `mcp__aws-mcp__aws___search_documentation` (tópico `reference_documentation`) → preço de storage S3 Standard (US$ 0,023/GB/mês, primeiro tier) e modelo de cobrança on-demand do DynamoDB (read/write request units, sem confirmação de cifra exata nesta sessão).
- Verificação direta do solicitante/sessão de validação, **2026-07-10** (terminal local do executor + `mcp__aws-mcp__aws___call_aws`, fora do escopo de ferramentas deste agente planejador): `terraform version` → `v1.15.5`; `aws s3api head-bucket --bucket devops-ia-tfstate-508591324807-us-east-1` → `404 Not Found`; `aws cloudtrail describe-trails` (role `tf_devops_admin-role`) → `AccessDeniedException` (não confirmado, não bloqueante). Usados para resolver as Premissas #6, #13 e #15, e para registrar o item correlato em aberto da Premissa #9.
- Confirmação de negócio do solicitante, **2026-07-10**: Premissas #4 (`environment = "shared"`), #5 (bucket único, sem isolamento de ambiente exigido hoje), #8 (SSE-S3/AES256) e #9 (logging dedicado fora de escopo).
- `.claude/rules/terraform-naming.md` — convenção de nomenclatura de arquivos/variáveis, aplicada integralmente nesta ADR.
- CLAUDE.md (raiz do repositório) — regra de bootstrap da stack `remote-backend` (nome fixo, exclusão hardcoded em `discover_stacks.sh`, aplicação sempre manual).
- ADR-001 (`docs/adr/ADR-001-network-vpc.md`), ADR-002 (`docs/adr/ADR-002-network-subnets.md`), ADR-003 (`docs/adr/ADR-003-network-cidr-resize.md`) — pendência de backend de state remoto registrada e reafirmada em todos, resolvida (para infraestrutura de suporte) por este ADR; migração efetiva de `network/` permanece como trabalho futuro dedicado.
