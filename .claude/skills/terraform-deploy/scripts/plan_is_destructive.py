#!/usr/bin/env python3
"""Classifica um plano Terraform como SAFE (só cria/atualiza) ou DESTRUCTIVE
(destrói ou substitui pelo menos um recurso).

Um "replace" no Terraform aparece no JSON como um resource_change cujas
`actions` incluem tanto "delete" quanto "create" — por isso basta checar se
"delete" está presente em qualquer resource_change para cobrir destroy puro
e replace, sem precisar diferenciar os dois casos aqui.

Uso:
    terraform show -json tfplan | python3 plan_is_destructive.py

Saída (stdout):
    Linha 1: "SAFE" ou "DESTRUCTIVE"
    Se DESTRUCTIVE, uma linha por recurso afetado: "<address> <ações>"

O script sempre sai com código 0 — quem chama decide o que fazer com o
resultado (é uma classificação, não uma validação que deveria falhar o
comando).
"""
import json
import sys


def main() -> None:
    data = json.load(sys.stdin)

    destructive = []
    for change in data.get("resource_changes", []):
        actions = change.get("change", {}).get("actions", [])
        if "delete" in actions:
            destructive.append((change.get("address", "?"), actions))

    if destructive:
        print("DESTRUCTIVE")
        for address, actions in destructive:
            print(f"{address} {'+'.join(actions)}")
    else:
        print("SAFE")


if __name__ == "__main__":
    main()
