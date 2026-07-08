#!/usr/bin/env bash
# Lista, em ordem alfabética (uma por linha), as stacks Terraform encontradas
# na raiz informada. Uma "stack" é qualquer diretório de primeiro nível que
# contenha pelo menos um arquivo *.tf. Diretórios ocultos (.git, .claude, ...)
# e a stack de remote backend (nome fixo "remote-backend") nunca são listados,
# mesmo que o chamador tente incluí-los explicitamente depois.
#
# Uso: discover_stacks.sh [raiz-do-repo]  (default: diretório atual)

set -euo pipefail

root="${1:-.}"

find "$root" -maxdepth 1 -mindepth 1 -type d -not -name ".*" | sort | while read -r dir; do
  name="$(basename "$dir")"

  if [ "$name" = "remote-backend" ]; then
    continue
  fi

  if compgen -G "${dir}/*.tf" > /dev/null 2>&1; then
    echo "$name"
  fi
done
