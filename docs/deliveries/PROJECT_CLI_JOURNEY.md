# Reçu — PROJECT_CLI_JOURNEY (concurrence + oracle + API)

## Lot

Suite PR #5 depuis `239fb34` :

1. Reprise concurrente : `owner_pid` ; resume=`active` si vivant ; second step=`already_running` (0 appel) ; après kill → `interrupted` + unknown
2. Banc CSV : no-args / list / export admis ; négatif via `project step` → `verify_failed`/`list_mismatch` ; noms de fonctions libres pour l’API
3. Campagne API réelle tentée ; premier échec DNS archivé

## SHA

Tip testé après commit de ce lot (voir push). Inject : `docs/qa/project_cli_journey/20261122T014259Z`. API : `docs/qa/project_cli_journey/api_20261122T014323Z`.

## Commandes

```bash
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# API :
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
```

## Rôles (inject)

| Rôle | Appels | Jetons | Coût | Résultat |
| --- | --- | --- | --- | --- |
| planner | 0 | 0 | 0 | inject (non qualifié modèle) |
| reviser | 0 | 0 | 0 | inject |
| implementer | 0 | 0 | 0 | inject |

## API

Indisponible : `curl: (6) Could not resolve host: api.openai.com` ; message CLI `Name or service not known`. Aucun appel facturable. Rôles non testés : planner, reviser, implementer.
