# Décision — Backends Vague A

Date : 2026-11-17

## Contexte

Les lots F3 et F14 ont besoin d’un stockage transactionnel local. Le paquet
`db_connector` / `std/db_sqlite` n’est pas disponible sur le PATH de build
imposé (`--path:src --path:/opt/NimAgentLibrary/src` uniquement).

## Décision

| Lot | Backend | Motif |
| --- | --- | --- |
| F3 RunStore | SQLite via FFI `libsqlite3.so.0` | Disponible système ; pas de dépendance nimble |
| F14 BudgetLedger | Journal fichier NDJSON + snapshot atomique `state.json` | Backend **fichier** (`FileBudgetLedger`, `fileBudgetLedgerCapabilities()`). Les symboles `SqliteBudgetLedger` / `openSqliteBudgetLedger` sont des alias **dépréciés** — pas SQLite |
| F1 Artefacts | Répertoire d’objets content-addressed SHA-256 | Conforme au lot |
| F4 Graphe | Validation pure en mémoire + registre simulé | Pas d’exécuteur (F5) |

## Conséquences

- F14 : autorité partagée **in-process** sur un même `*.ledger/` ; pas de verrou multi-processus fiable. Reprise : snapshot + replay du tail journal.
- Une future unification journal/ledger sous SQLite partagé reste possible ; la
  réconciliation croisée reste par `inference_attempt_id` (pas de XA).
- La façade `import nimfactory` réexporte F0 + F1 + F3 + F4 + F14.
