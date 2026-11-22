# Project step — diagnostic de récupération + revise_plan effectif

Date : 2026-11-22  
Branche : `feature/project-cli-journey` (PR #5 brouillon)  
**SHA du code exécuté** : `0e759098667d19c705b7c12c9e3f09ec92cfe5b0`

## Objectif

L'implémenteur produit une étape compilable, ou transmet au réviseur le
prérequis qui l'en empêche (`revise_plan`).

## Corrections

1. **Contexte de récupération** — une seule copie fidèle de la réponse brute
   (y compris bloc malformé) ; pour chaque édition lisible, compte des
   occurrences de `oldText` dans le fichier ciblé de l'arbre courant ; extraits
   si ancre ambiguë ; diagnostic **sans écriture**.
2. **`revise_plan` effectif** — motif persisté (`revise_plan_pending` / reason /
   step / version) ; `status` et `resume` indiquent `action=revise` ; `step`
   rend la main sans appel fournisseur ; `project revise` reçoit le motif et,
   une fois accepté, rouvre le travail.

## Vérifications hors API

```
nim c -r --path:src --path:vendor/NimAgentLibrary/src tests/project/test_step_contract.nim
bash scripts/replay_archived_recovery_offline.sh
```

Archive offline : `docs/qa/project_cli_journey/offline_archive_replay_20261122T154518Z`

| Cas | Archive source | Résultat |
| --- | --- | --- |
| A | `recovery_replay_20261122T152200Z` raw | recovery → `revise_plan_needed` ; status/resume=`revise` ; step bloqué 0 call ; revise inject → step helpers `pass` |
| B | `recovery_replay_20261122T152308Z` raw | recovery → helpers ; compile+list `pass` (partial) |

## Appel API réel (un seul)

Archive : `docs/qa/project_cli_journey/recovery_replay_20261122T154538Z`  
Plan v2 historique + raw `20261122T150522Z` ; ask/revise inject ($0).

| Champ | Valeur |
| --- | --- |
| Décision modèle | édition unique `src/demo_tasks.nim` avec `oldText: "else:"` (pas de `revise_plan`) |
| Action suivante | `step` (refuse residual ; pas de revise pending) |
| Appels | `api_calls_this_command=1` (recovery only) ; historical first = 0 bill |
| Jetons | prompt **1673**, completion **78**, `gpt-4o-mini` |
| Coût estimé | **≈ $0.000298** |
| Diff appliqué | **aucun** (`wrote: false`, `recovery_exhausted`) |
| Compile / oracle | non exécutés (apply refusé après diagnostic) |

Premier résultat conservé tel quel.

## Limites

- Le modèle ignore encore les extraits d'ambiguïté et repropose `else:`.
- Un second tour de recovery n'est pas autorisé ; `revise_plan` reste la voie
  pour un prérequis multi-fichiers.

## Concurrence

Correctif de lease concurrent : commit distinct antérieur `34719f8` (non
mélangé).
