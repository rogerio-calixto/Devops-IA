# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An AWS infrastructure-as-code repository managed entirely through Terraform, operated via a two-agent architect/executor workflow with mandatory Architecture Decision Records (ADRs). There is no application code — every top-level directory with `*.tf` files is an independent Terraform "stack" with its own state. Today the only stack is `network/`.

## The architect/executor workflow (read this before touching any `.tf` file)

This repo enforces a strict separation between deciding architecture and implementing it:

- **`aws-solution-architect`** agent (`.claude/agents/aws-solution-architect.md`) — PLANNER only. Produces ADRs in `docs/adr/`. Never edits `.tf` files, never runs `terraform plan/apply`. If critical info is missing (RTO/RPO, budget, compliance, scale), it stops and asks rather than assuming; every assumption it does make is written into the ADR's "Premissas" section, with unresolved items flagged `A VALIDAR`.
- **`aws-devops-engineer`** agent (`.claude/agents/aws-devops-engineer.md`) — EXECUTOR only. Implements exactly what an accepted ADR specifies. Never redecides architecture; if it disagrees with an ADR, it objects and escalates rather than silently deviating. Stops and escalates to a human on: any unresolved `A VALIDAR` in the ADR, ambiguity/contradiction in the spec, or a destructive/high-risk action — even if the ADR nominally covers it.
- The **ADR is the only contract** between the two agents — it must be self-sufficient and unambiguous, since the agents don't converse directly.

Practical implication for any change to `network/` (or a future stack): a nontrivial architectural change should go through a new ADR (see `docs/adr/ADR-001..003` for the template and style) before code changes, not as an ad hoc edit.

## Terraform conventions (`.claude/rules/terraform-naming.md`)

These are project-specific deviations from `terraform-best-practices.com` — don't "correct" them back to the generic guide:

1. **Naming**: `_` in resource/data source/variable/output names, never `-` (hyphens only in tag *values* and file names). Don't repeat the resource type in the local name (`aws_route_table.public`, not `.public_route_table`). Use `this` when there's no more descriptive name. Argument order in a block: `count`/`for_each` → normal args → `tags` → `depends_on`/`lifecycle`.
2. **File layout is domain-based, not type-based**: `<domain>.tf` for the domain's primary resource, `<domain>.<kebab-case-description>.tf` for secondary resources of the same domain (e.g. `vpc.tf`, `vpc.public-subnets.tf`, `vpc.nat-gateway.tf`). A file never mixes resources from different domains. `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf` stay as single cross-cutting files.
3. **Variables are grouped by domain into `object` types**, deliberately opposite of the general best-practices guide — e.g. one `vpc` variable holding CIDR, DNS settings, and subnet lists, rather than many flat variables. Keeps everything describing one logical resource together.
4. **No `default` in `variables.tf`**, ever. Concrete values live in a stack-local `terraform.tfvars` (or `<env>.tfvars` per environment, passed via `-var-file`). This repo's `.gitignore` ignores `*.tfvars` by default but has an explicit exception for the literal name `terraform.tfvars` (versioned, since it holds only non-sensitive config) — if a value in it ever needs to be sensitive, put it in a differently-named, still-ignored `.tfvars` instead.

## Deploying (`terraform-deploy` skill)

Use the `terraform-deploy` skill for any "apply/deploy/update infra" request — don't run raw `terraform apply` by hand for routine changes. Key behaviors baked into it (see `.claude/skills/terraform-deploy/SKILL.md`):

- Discovers stacks via `scripts/discover_stacks.sh` — any top-level dir with `*.tf` files, alphabetical order, excluding a stack literally named `remote-backend` (which must always be applied manually, never through this skill or automation, due to bootstrap ordering).
- Per stack: `fmt` → `init -upgrade=false` (never silently upgrades a locked provider version) → `validate` → `plan -out=tfplan` → classify the plan via `scripts/plan_is_destructive.py` → apply.
- **Safety gate**: a plan containing only create/update is applied automatically. A plan containing any destroy/replace is never auto-applied — the specific resources to be destroyed are shown and explicit human confirmation is required, even if the user already asked to "deploy everything." This exists because a past CIDR migration turned into an unplanned 11-resource replacement (see ADR-003).
- Always applies the saved `tfplan` file (never a bare `apply -auto-approve`), so what's approved is exactly what's applied.
- Stops the entire remaining queue on the first real error in a stack (not just "files need formatting").

## Current infrastructure state (`network/` stack)

- VPC `aws_vpc.this`, CIDR `10.0.0.0/24` (resized from `/16` per ADR-003), region `us-east-1`, account `508591324807`.
- 4 subnets across 2 AZs (`us-east-1a`/`us-east-1b`): `public-a`/`public-b`/`private-a`/`private-b`, each a `/26` (59 usable IPs) — **the `/24` is fully consumed by these 4 subnets; there is no free CIDR space left for new subnets** without a secondary CIDR block or another resize.
- Internet Gateway attached; public/private route tables with associations.
- `nat_gateway.enabled = false` (deliberately disabled to avoid recurring cost — see ADR-002 "Decisão", reconfirmed 2026-07-08) — **private subnets currently have no internet egress**. Toggling this to `true` is the intended path to add NAT egress later.
- No remote backend configured (local state) — flagged as an open risk in every ADR so far, especially given the `/24` resize showed how a full-stack destroy/recreate can happen from what looks like a small tfvars change.
- Provider `hashicorp/aws ~> 6.53.0`, Terraform core `>= 1.9.0`.

Before assuming any of the above, check `network/terraform.tfvars` (not committed to git in general, but this repo's exception makes it present) and the latest ADR in `docs/adr/` — these values change via ADR, and the ADRs are the authoritative history of *why* each value is what it is.

## MCP servers

- `terraform` MCP server (`hashicorp/terraform-mcp-server` via Docker) — used by both agents to validate provider/module versions, schemas, and registry docs before writing HCL. Query it before hand-writing version constraints or resource arguments from memory.
- `aws-mcp` — proxies AWS APIs/docs (regional availability, docs search, `call_aws`, etc.) for validating assumptions (e.g. AZ availability, CIDR immutability) instead of guessing.
