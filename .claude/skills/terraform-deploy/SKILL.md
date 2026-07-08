---
name: terraform-deploy
description: Faz o deploy (fmt, validate, plan, apply) de uma ou de todas as stacks Terraform deste repositório. Use SEMPRE que o usuário pedir para aplicar/subir/atualizar infraestrutura via Terraform — frases como "dá um apply", "sobe a stack de network", "faz o deploy de tudo", "aplica as mudanças de infra", "roda o terraform" — mesmo que a palavra "deploy" ou o nome exato da skill não apareça. Também use quando o usuário citar o nome de uma stack específica (ex. "network") junto com um pedido de aplicar/atualizar. Nunca aplica uma stack chamada "remote-backend" — ela é sempre ignorada, mesmo se pedida explicitamente.
---

# Terraform Deploy

Automatiza o ciclo `fmt → init → validate → plan → apply` para as stacks
Terraform deste repositório (cada diretório de primeiro nível com arquivos
`*.tf` é uma stack independente, com seu próprio state — ver
`.claude/rules/terraform-naming.md`).

## Por que este fluxo existe

Um `terraform apply` mal revisado pode destruir recursos em produção sem
ninguém perceber até ser tarde demais — isso já aconteceu neste próprio
repositório (a migração de CIDR da VPC virou uma substituição completa de
11 recursos que ninguém tinha planejado literalmente daquela forma). Por
isso esta skill nunca aplica um plano destrutivo às cegas: ela distingue
planos que só criam/atualizam recursos (seguros para aplicar automaticamente)
de planos que destroem ou substituem algo (que exigem que um humano olhe o
plano antes de continuar).

## Descobrindo quais stacks rodar

Use `scripts/discover_stacks.sh <raiz-do-repo>` para listar as stacks
disponíveis, em ordem alfabética. O script já exclui diretórios ocultos e
qualquer diretório chamado exatamente `remote-backend`.

- **Se o usuário informou o nome de uma ou mais stacks** (ex.: "network"),
  rode apenas essas — desde que estejam na lista retornada pelo script. Se o
  usuário pedir uma stack que não aparece na lista (por não existir, ou por
  ser a `remote-backend`), avise antes de fazer qualquer coisa: se for a
  `remote-backend`, explique que ela é intencionalmente excluída deste fluxo
  (stacks de backend remoto costumam ter um problema de ordem de bootstrap —
  precisam existir antes de qualquer state remoto poder ser usado — e por
  isso não fazem sentido num loop genérico de deploy; se o usuário realmente
  precisar aplicá-la, isso deve ser um passo manual e deliberado, fora desta
  skill).
- **Se o usuário não informou nenhuma stack**, rode todas as retornadas pelo
  script, na ordem em que aparecem (alfabética). Hoje só existe `network/`,
  mas conforme o repositório crescer, novas stacks aparecerão automaticamente
  nessa lista sem precisar tocar nesta skill.

## Para cada stack, nesta ordem

Rode os passos abaixo dentro do diretório da stack (`cd <stack>/`). Se
qualquer passo falhar (erro real, não apenas "há mudanças a formatar"), pare
imediatamente **essa stack e todas as seguintes** da fila e reporte o erro —
não faz sentido continuar aplicando outras stacks quando uma já mostrou um
problema, especialmente se houver dependência implícita entre elas (a ordem
alfabética não garante independência).

1. **`terraform fmt`** — formata os arquivos `.tf` no lugar. Se o comando
   listar arquivos alterados, mencione isso no relatório final (é informação
   útil para o usuário, não um erro).

2. **`terraform init -upgrade=false`** — necessário antes de `validate`/
   `plan` funcionarem (baixa/verifica providers e módulos). Use
   `-upgrade=false` para nunca trocar a versão de um provider já travada no
   lockfile só por rodar esta skill — upgrade de provider é uma decisão que
   merece ser deliberada, não um efeito colateral de um deploy de rotina.

3. **`terraform validate`** — deve retornar `Success!`. Se falhar, a stack
   tem um erro de configuração; pare e reporte, sem tentar `plan`/`apply`.

4. **`terraform plan -out=tfplan`** — gera o plano e salva em arquivo. Depois
   rode **`terraform show -no-color tfplan`** e mostre esse resultado ao
   usuário — é o "print do plano" que permite auditar o que vai acontecer
   antes de qualquer `apply`, mesmo nos casos em que a aplicação será
   automática.

5. **Classifique o plano** com
   `terraform show -json tfplan | python3 scripts/plan_is_destructive.py`
   (rode a partir do diretório da skill, ajustando o caminho do script para
   o diretório da stack, ou copie/aponte para ele com caminho absoluto). A
   primeira linha da saída é `SAFE` ou `DESTRUCTIVE`:
   - **`SAFE`** (só `create`/`update`, nenhum `delete`): siga direto para o
     apply automático (passo 6a).
   - **`DESTRUCTIVE`** (pelo menos um recurso será destruído ou substituído
     — a saída lista quais): **não aplique**. Mostre ao usuário exatamente
     quais recursos serão destruídos/substituídos (a lista que o script
     imprime) e peça confirmação explícita antes de prosseguir para essa
     stack. Isso vale mesmo que o usuário já tenha pedido para "aplicar
     tudo" — um pedido genérico de deploy não é a mesma coisa que uma
     aprovação informada de uma destruição específica que ainda nem existia
     quando o pedido foi feito. Trate essa pausa como o fim do trabalho
     desta invocação da skill para essa stack: só continue depois que o
     usuário responder.

6. **Apply**:
   - **(a) Plano `SAFE`**: `terraform apply -auto-approve tfplan`. Usar o
     arquivo de plano salvo (`tfplan`), e não `terraform apply -auto-approve`
     sem argumento, garante que o que é aplicado é exatamente o que foi
     mostrado no passo 4 — sem essa garantia, uma mudança de estado da AWS
     entre o `plan` e o `apply` poderia fazer o Terraform aplicar algo
     diferente do que foi revisado.
   - **(b) Plano `DESTRUCTIVE`, após confirmação do usuário**: mesmo comando,
     `terraform apply -auto-approve tfplan` — a diferença não é o comando, é
     que aqui ele só roda depois do humano ter visto e aprovado a
     destruição/substituição específica.

7. Depois do apply, rode `terraform output` e inclua os valores no relatório
   final — são os identificadores reais que o usuário vai precisar (IDs de
   recursos AWS, ARNs, etc.), do mesmo jeito que já é prática neste
   repositório registrar esses valores após cada apply.

## Ao final (todas as stacks processadas)

Resuma por stack: o que mudou (contagem de add/change/destroy do plano),
se houve pausa para confirmação, e os outputs relevantes. Se alguma stack
foi pulada (por erro ou por ser a `remote-backend`), deixe isso explícito —
silêncio sobre uma stack pulada passa a falsa impressão de que tudo foi
coberto.

## Limitações conhecidas

- A ordem de execução ao rodar "todas as stacks" é puramente alfabética.
  Isso é suficiente enquanto as stacks forem independentes; se uma stack
  futura depender de outra (ex.: uma stack de computação que lê outputs da
  `network/` via remote state ou data source), a ordem alfabética pode não
  bater com a ordem de dependência real. Se perceber isso acontecendo (um
  `plan`/`apply` falhando por depender de algo que outra stack ainda não
  criou), avise o usuário — pode ser sinal de que vale a pena formalizar uma
  ordem explícita em vez de depender do alfabeto.
- Um `terraform fmt` que altera arquivos deixa a stack com mudanças não
  commitadas; esta skill não commita nada automaticamente — só aplica na
  AWS. Cabe ao usuário decidir quando commitar essas mudanças de formatação.
