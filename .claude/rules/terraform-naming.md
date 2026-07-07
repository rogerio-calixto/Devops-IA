---
paths:
  - "**/*.tf"
  - "**/*.tfvars"
---

# Convenções de Terraform deste projeto

Regras aplicáveis a todo código Terraform criado ou alterado neste
repositório (hoje: `network/`). Baseadas em
https://www.terraform-best-practices.com/naming, com três desvios
deliberados definidos pelo time (marcados como "Regra do projeto" abaixo).
Os agentes `aws-solution-architect` (nos ADRs) e `aws-devops-engineer` (na
implementação) devem seguir estas convenções.

## 1. Nomenclatura de identificadores (resources, data sources, variáveis, outputs)

- Use `_` (underscore) em nomes de resource, data source, variável e output —
  nunca `-` (hífen). Hífen só é permitido dentro de **valores** (ex.: tags,
  `Name = "meu-projeto-dev-vpc"`) e em nomes de arquivo (seção 2).
- Prefira minúsculas e números.
- Não repita o tipo do recurso no nome do resource local:
  - Certo: `resource "aws_route_table" "public" {}`
  - Errado: `resource "aws_route_table" "public_route_table" {}`
- Use `this` como nome do resource/data source quando não houver um nome
  mais descritivo (ex.: recurso único do módulo).
- Nomes de resource/data source no singular.
- Ordem dos argumentos dentro de um bloco: `count`/`for_each` primeiro,
  argumentos normais no meio, `tags` por último, `depends_on`/`lifecycle`
  depois de `tags`.
- Prefira condições booleanas simples a `length(...)` ou expressões
  complexas em `count`/`for_each`.
- Outputs: nome no formato `{name}_{type}_{attribute}` (ex.: `vpc_id`,
  `public_subnet_ids`); plural quando o valor for uma lista; sempre com
  `description`; evite `sensitive = true` a menos que o valor realmente
  precise ser protegido.

## 2. Nomenclatura de arquivos — **Regra do projeto**

Arquivos são organizados por domínio, no padrão `<dominio>.tf` para o
recurso principal do domínio e `<dominio>.<descricao-do-recurso>.tf`
(kebab-case na parte descritiva) para recursos secundários do mesmo
domínio:

```
network/
├── vpc.tf                          # recurso principal do domínio "vpc" (aws_vpc)
├── vpc.public-subnets.tf           # subnets públicas da vpc
├── vpc.private-subnets.tf          # subnets privadas da vpc
├── vpc.internet-gateway.tf         # internet gateway da vpc
├── vpc.public-route-table.tf       # route table pública da vpc
├── vpc.private-route-table.tf      # route table privada da vpc
├── variables.tf                    # declaração de variáveis (sem default — ver seção 4)
├── terraform.tfvars                # valores das variáveis (ver seção 4)
├── outputs.tf
├── providers.tf
└── versions.tf
```

Regras:
- Um arquivo nunca mistura recursos de domínios diferentes (ex.: não
  colocar `aws_security_group` de uma stack de compute dentro de um
  arquivo `vpc.*.tf`).
- `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf` continuam
  como arquivos únicos e transversais ao domínio, conforme o Standard
  Module Structure do Terraform.

## 3. Variáveis com atributos agrupados — **Regra do projeto**

O guia terraform-best-practices.com recomenda tipos primitivos simples em
vez de `object(...)` para variáveis. Este projeto opta deliberadamente
pelo oposto: agrupe em uma única variável (tipo `object`) todos os
atributos relacionados a um mesmo domínio, em vez de criar várias
variáveis soltas. Objetivo: reduzir o número de variáveis top-level e
manter coeso tudo que descreve um mesmo recurso lógico.

Errado (variáveis soltas):
```hcl
variable "vpc_name" { ... }
variable "vpc_cidr" { ... }
variable "public_subnet_cidrs" { ... }
variable "private_subnet_cidrs" { ... }
```

Certo (variável com atributos, agrupando tudo que é "vpc"):
```hcl
variable "vpc" {
  description = "Configuração da VPC e das subnets associadas."
  type = object({
    name                 = string
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
}
```

Uso no resource (`vpc.tf`):
```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc.cidr_block
  enable_dns_support   = var.vpc.enable_dns_support
  enable_dns_hostnames = var.vpc.enable_dns_hostnames

  tags = {
    Name = var.vpc.name
  }
}
```

Continuam valendo as demais regras de variável do guia: `description`
sempre presente; ordem dos argumentos do bloco `description`, `type`,
`validation`; nomes no plural quando o atributo for lista/map (ex.:
`public_subnets`); evite dupla negativa (`enable_x`, não `disable_x`);
use `nullable = false` quando o valor nunca pode ser nulo.

## 4. Sem `default` em `variables.tf` — valores em arquivo separado — **Regra do projeto**

Nenhuma `variable` neste projeto declara o argumento `default`. Os
valores concretos ficam em um arquivo `.tfvars` dedicado, um por stack
(diretório de módulo raiz), carregado automaticamente pelo Terraform:

```hcl
# network/terraform.tfvars
vpc = {
  name                 = "devops-ia-dev-vpc"
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  public_subnets = [
    { name = "public-a", cidr_block = "10.0.0.0/20", availability_zone = "us-east-1a" },
    { name = "public-b", cidr_block = "10.0.16.0/20", availability_zone = "us-east-1b" },
  ]
  private_subnets = [
    { name = "private-a", cidr_block = "10.0.128.0/20", availability_zone = "us-east-1a" },
    { name = "private-b", cidr_block = "10.0.144.0/20", availability_zone = "us-east-1b" },
  ]
}
```

Importante:
- **Nunca** coloque segredos (senhas, chaves, tokens) em um `.tfvars`.
  Segredos continuam vindo de Secrets Manager/SSM, nunca de arquivo
  versionado — isso não muda com esta regra.
- O `.gitignore` deste repositório ignora `*.tfvars` por padrão (prática
  recomendada, pois `.tfvars` costuma conter segredos). Como aqui o
  arquivo guarda apenas configuração não sensível e precisa ser
  versionado, é necessário abrir uma exceção explícita para
  `terraform.tfvars` no `.gitignore`. Se algum dia um valor sensível
  precisar entrar em um `.tfvars`, ele não deve usar esse nome de
  exceção; crie um `.tfvars` à parte e deixe-o ignorado.
- Para múltiplos ambientes (dev/staging/prod) na mesma stack, use um
  arquivo por ambiente (ex.: `dev.tfvars`, `prod.tfvars`) e passe
  explicitamente com `terraform plan -var-file=dev.tfvars` — nesse caso
  também abra a exceção correspondente no `.gitignore`.

## Referências

- https://www.terraform-best-practices.com/naming
- Standard Module Structure — documentação oficial HashiCorp
