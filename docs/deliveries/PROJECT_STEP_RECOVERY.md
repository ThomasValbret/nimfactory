# Project step — contrat plan↔exécution + récupération bornée

Date : 2026-11-22  
Branche : `feature/project-cli-journey` (PR #5 brouillon)  
Base : tip `30a410f` · code `8fd6fb2` · docs (ce commit)

## Périmètre

1. Contrat explicite : chaque étape doit laisser un arbre compilable ; tant que
   `project step` n'applique qu'un fichier, une réponse à plusieurs
   `target_file` est refusée **avant toute écriture**. L'agent peut reformuler
   ou signaler `revise_plan`.
2. Récupération bornée (1 tour) branchée sur project step : proposition exacte,
   motif, contextes d'ancre ambiguë ; choix fichier/correctif laissé au modèle.
3. Rejeu VPS de `20261122T150522Z` : plan v2 + raw historique, un seul nouvel
   appel `gpt-4o-mini` (recovery), sans repayer ask/revise.

## Vérifications hors API

```
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/project/test_step_contract.nim
```

Cas : multi refuse sans écriture ; plafond d'un tour de recovery ; recovery →
`revise_plan` ; ambiguous → helpers acceptés.

## Campagne recovery

| Archive | Rôle | api_calls | Motif recovery | Décision modèle | Apply | Oracle |
| --- | --- | --- | --- | --- | --- | --- |
| `docs/qa/.../recovery_replay_20261122T152200Z` | 1er essai (2e JSON historique illisible → multi non compté) | 1 | `anchor_ambiguous` | reformule `else:` | refuse ambiguous | n/a |
| `docs/qa/.../recovery_replay_20261122T152308Z` | après correctif comptage multi (cible) | 1 | `multi_proposal` | 1 fichier, ancre `else:` | refuse ambiguous | n/a |

### Résultat retenu (152308Z)

- Décision modèle : une proposition `src/demo_tasks.nim` avec `oldText: "else:"`
  (pas de `revise_plan`).
- Diff appliqué : **aucun** (refuse avant/après écriture ; hashes identiques).
- Compilation / oracle : non exécutés (apply_failed).
- Jetons recovery : prompt **1090**, completion **78**, modèle `gpt-4o-mini`.
- Coût estimé recovery : **≈ $0.000210** (list gpt-4o-mini).
- Ask/revise : inject historique, **$0** API.

Provenance conservée : `historical_provenance.json` +
`--historical-provenance` pointant `20261122T150522Z`.

## Fichiers principaux

- `src/nimfactory/mission/apply.nim` — multi-proposal, `parseRevisePlan`, findings
- `src/nimfactory/project/{pipeline,plan_context}.nim` — gates + recovery
- `src/nimfactory/cli/cli.nim` — `--replay-first`, `--inject-recovery`
- `tests/project/test_step_contract.nim`
- `scripts/replay_project_step_recovery.sh`

## Limites

- Le modèle a échoué deux fois sur l'ancre `else:` ; le plafond d'un tour empêche
  une seconde recovery automatique.
- Concurrence (`already_running` / lease pid) : commit distinct antérieur
  `34719f8`, non mélangé ici.

## Coûts

Appels payants de ce lot : **2** recovery (`gpt-4o-mini`), total ≈ **$0.00043**.
Budget restant largement sous $2.
