# Livraison — done ↔ fraîcheur de preuve + stdout exact

Date : 2026-11-24  
Branche : `fix/engine-pilot-done-freshness`  
Base : `1503725590595440b5ed59d36d4971e085394f7c`  
Tip figé Studio (inchangé, qualification parallèle) : `d519d49ac8c149186d873fa9d6470ce8d0974c04`

État Git au moment de ce reçu : **modifications non commitées** sur la branche de correction (base ci-dessus).

## Périmètre

1. **Décision `done` / fraîcheur** — `incompletePlanReason` et fin de `projectRun` comparent l’empreinte live de l’arbre livré à `acceptedTreeHash`. Nouvelle commande sur plan terminé avec arbre muté → `proof_stale` après `recheckDeliveredTree` (ou refresh du hash si les critères tiennent encore). Reçu historique (`command_id`) : coût nul, chemin/empreinte lisibles, fraîcheur live annotée.
2. **Stdout exact** — `stdout_exact:` vs `stdout_contains:` ; coercion « affiche exactement … » ; `program_runs` (exit) séparé de la règle de sortie. Contrôles portent `expected` / `observed` / `comparison_rule`.

Qualification carnet (`loan_*` dans les régressions) **préservée**. Cas publics uniquement.

## Empreintes

| Artefact | sha256 |
| --- | --- |
| `build/nimfactory` | `a71ff3c89e79a22de54ad67ef004ba1efb850d68d1139542dde03a4a187051d7` |
| `src/nimfactory/project/pipeline.nim` | `d758b93c2e89f7e9e5985136052c437c32c25cbf9652517b3037ef361fb58b7e` |
| `src/nimfactory/project/verify.nim` | `562e246b09baef778aedef04ab64fd7d16ce8539867b8ce8c375974f85820e3b` |
| `src/nimfactory/application/project_command.nim` | `4c1d2d605e35343a72f7e21717c34eea397470654e35bad0a75d7d39592acfa6` |
| `tests/project/test_project_run_regressions.nim` | `b8345d17c5d7cd3eac5583e34de1d8d091509ca87b450d07972b1de6fc0a9636` |

Fixtures : `fixtures/hello_exact/`, `fixtures/salut_exact/`.

## Commandes

```bash
export PATH="/root/.nimble/bin:/root/.choosenim/toolchains/nim-2.4.0/bin:$PATH"
nim c -r --path:src --path:vendor/NimAgentLibrary/src \
  tests/project/test_project_run_regressions.nim
# → … stale_done_requires_recheck: ok / exact_stdout_three_programs: ok / ALL … passed

nim c -d:release -d:ssl --path:src --path:vendor/NimAgentLibrary/src \
  -o:build/nimfactory src/nimfactory_cli.nim
```

## CLI — linked_two_files (avant → après)

Protocole : `project run` → muter seulement `src/greet.py` sur l’arbre livré → exec échoue → `project status` → rejeu même `command_id` → `project run` nouvel id.

| Étape | Avant (binaire tip `1503725`) | Après (binaire corrigé) |
| --- | --- | --- |
| run1 | `done` · hash `519F448E96939159…` | `done` · `proof_freshness=fresh` · même hash |
| status (après mutation) | `proof_freshness=stale` | `stale` · proof `519F…` ≠ live `F233…` |
| replay `command_id` | `historical_receipt` · `new_provider_calls=0` · **path/hash absents** | hist + coût 0 · `proof_tree_ref` + `proof_tree_hash` + `files_current_hash` · `fresh=stale` |
| nouvel id | **`done` (bug)** | **`proof_stale`** · `verify_recheck.ok=false` · `program_runs` exit=1 |

## CLI — stdout exact

| Cas | Résultat |
| --- | --- |
| `fixtures/hello_exact` (`stdout_exact:bonjour`) | `done` · control `expected=bonjour` `observed=bonjour` `comparison_rule=exact` |
| muter → `print("hello")` puis nouvel id | `proof_stale` · `program_runs` ok · `stdout_exact:bonjour` fail (`observed=hello`) |
| muter → `print("je dis bonjour")` | `proof_stale` · `program_runs` ok · exact fail (`observed=je dis bonjour`) ; contains réussirait |
| `fixtures/salut_exact` (`stdout_exact:merci`, fichier `salut.py`) | `done` · hash `884C2F62F5319245…` |

## Régressions ciblées

- `stale_done_requires_recheck`
- `exact_stdout_three_programs`
- suite complète `test_project_run_regressions.nim` : **ALL passed** (incl. `loan_static_witnesses`, `loan_project_run_inject`)

## Limites

- Pas de commit sur cette branche dans ce reçu ; SHA de base = `1503725…`.
- Studio / binaires figés `d519d49` non reconstruits ici (qualification parallèle).
- Coûts : 0 appel fournisseur réel (route inject).
