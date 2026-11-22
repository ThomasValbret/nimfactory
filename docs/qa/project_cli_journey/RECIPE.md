# Recette VPS — parcours projet CLI (concurrence + oracle CSV)

## Base

| Champ | Valeur |
| --- | --- |
| Branche | `feature/project-cli-journey` |
| Fixture | `fixtures/demo_tasks_cli/` (+ `recipe.json` → `verify=csv_journey`) |
| Négatif | `fixtures/demo_tasks_cli_neg/` (noms de fonctions alternatifs) |
| Modèle | `gpt-4o-mini` (`planner` / `reviser` / `implementer`) |

## Prérequis

```bash
cd /opt/nimFactory
export PATH="/root/.nimble/bin:${PATH:-}"
NF_PROJECT_ROUTE=inject bash scripts/e2e_project_cli_journey.sh
# Mission réelle (une campagne) :
NF_PROJECT_ROUTE=api bash scripts/e2e_project_cli_journey.sh
```

## Contrôles hors API

1. `{}` → `plan_failed`
2. **Concurrence** : step vivant (pause) + second processus sur le même store
   - `resume` → `verdict=active`, `action=wait`
   - second `step` → `already_running`, `provider_calls_this_command=0`
3. Kill du premier → `resume` → `interrupted` + `provider_attempt_unknown` + `retry_step`
4. Étapes chaînées sur `accepted_tree_ref` ; oracle comportemental (pas de noms de fonctions imposés)
5. Binaire : sans argument / `list` / `export-csv` (ou `list --format=csv`)
6. Négatif via `project step` sur `demo_tasks_cli_neg` → `verify_failed` / `list_mismatch`

## Transcription inject (vérifié)

Campagne : `docs/qa/project_cli_journey/20261122T014259Z`

| Étape | Verdict |
| --- | --- |
| empty `{}` | `plan_failed` |
| resume while alive | `active` |
| concurrent step | `already_running` (0 appel) |
| resume after kill | `interrupted` / `retry_step` |
| step1+step2 | `pass` (arbre chaîné + CSV) |
| neg step | `verify_failed` / `list_mismatch` |

## API — passer nativement via Tailscale (comme la console)

### Diagnostic

Le shell **sandboxé** Cursor : netns isolé (`lo` seul), `CapEff=0`, proxy allowlist **sans** `api.openai.com` → CONNECT 403.  
L’hôte a `eth0` + `tailscale0` (daemon `tailscaled`). Les collègues en console sont déjà dans ce netns.

### Manipulation agent

1. Exécuter le Shell **hors sandbox** (`required_permissions: ["all"]` — carte d’approbation).
2. Entrer le netns de Tailscale/hôte, **sans** proxy Cursor :

```bash
source scripts/lib_load_openai_key.sh && load_openai_key
bash scripts/with_host_net.sh -- env NF_PROJECT_ROUTE=api PATH="/root/.nimble/bin:$PATH" \
  OPENAI_API_KEY="$OPENAI_API_KEY" bash scripts/e2e_project_cli_journey.sh
# équivalent :
# nsenter -t "$(pgrep -x tailscaled)" -n -m -- env -u HTTP_PROXY -u HTTPS_PROXY \
#   -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy ...
```

`with_host_net.sh` : si `eth0`/`tailscale0` déjà visibles → exec direct ; sinon `nsenter -t $tailscaled -n -m`.

### Première campagne live (réseau OK)

| Champ | Valeur |
| --- | --- |
| SHA | `3fbd08e` |
| Campagne | `docs/qa/project_cli_journey/20261122T142352Z` |
| Réseau | nsenter/tailscaled → OpenAI 200 |
| ask / revise | OK (`plan_v1`→`plan_v2`, 5 steps) |
| step1 | **`apply_failed`** — 2 blocs JSON markdown ; parse EOF (1er résultat conservé) |

| Rôle | calls | tokens (prompt+compl) | est. USD | résultat |
| --- | ---: | --- | ---: | --- |
| planner | 1 | 562+363 | ~0.00030 | plan_ready |
| reviser | 1 | 949+489 | ~0.00044 | plan_revised |
| implementer | 1 | 899+258 | ~0.00029 | apply_failed |
