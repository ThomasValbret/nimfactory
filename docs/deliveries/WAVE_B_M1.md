# Vague B — M1 requalifié

Date : 2026-11-19  
Dépôt : https://github.com/ThomasValbret/nimfactory  
Branche : `feature/wave-b-m1`  
PR : https://github.com/ThomasValbret/nimfactory/pull/2 (restée ouverte)  
SHA fonctionnel qualifié : `dd4fcf57e801c69cf0257edf06c140ef5a37b235`  
SDK : `bf22665ece77d7149dbe61df959a6024bf6b26f3` (`pin_verified=yes`)  
Nim : 2.4.0  

## Verdict

**M1 requalifié** pour le SHA fonctionnel ci-dessus, après rejeu indépendant depuis un worktree propre détaché sur ce commit (pas une réutilisation des logs livraison).

La tête documentaire / preuve observée au départ de la qualification était `6d4a75b9f106aa016c8f3b4d26d6912565eb020a` (stamp docs uniquement : +2 lignes sur F5 / WAVE_B_M1). Diff fonctionnel candidat→cette tête : vide hors docs.

## Périmètre

F5 (exécuteur), parcours CLI F16, preuves F17. F2 / F13 / LLM hors passe. Fusion et lot suivant réservés à la revue humaine.

## Inventaire d’environnement (nouvelle exécution)

Voir `docs/qa/m1_requal_2026-11-19/env_inventory.txt`.

| Champ | Valeur |
| --- | --- |
| Worktree | `/opt/nimFactory-m1-qual-dd4fcf5` @ `dd4fcf5` |
| SDK | `bf22665…` match pin |
| Git status au départ | propre + dossier requal untracked |

## Suites rejouées (nouvelles — distinctes des traces `011d7f6`)

| Commande | Exit | Journal nouveau |
| --- | --- | --- |
| `./scripts/test_wave_a.sh` | 0 | `docs/qa/m1_requal_2026-11-19/test_wave_a.log` |
| `./scripts/test_wave_b_m1.sh` | 0 | `docs/qa/m1_requal_2026-11-19/test_wave_b_m1.log` |
| `./scripts/m1_resume_recipe.sh` | 0 | `docs/qa/m1_requal_2026-11-19/m1_resume_recipe.log` |
| `./scripts/m1_pipe_backpressure_cli.sh` | 0 | `docs/qa/m1_requal_2026-11-19/m1_pipe_backpressure_cli.log` |

Traces historiques de livraison (ex. logs mentionnant `011d7f6`) : conservées sous `docs/qa/m1_wave_*.log` antérieurs — **non** utilisées comme preuve de cette requalification.

## Contre-épreuve F5 (interfaces publiques)

Journal : `docs/qa/m1_requal_2026-11-19/counterproof_f5.jsonl` — `failures=0`.

Points critiques observés à nouveau :

- wait cap1 seq/conc : `waited>=1`, completed, branches oracle `left,right`
- reject CLI : **exit exactement 4**
- spill : `spilled>=1`, mêmes branches
- `timed_out` interne ≠ harness `124` ; wait sous `timeout 8s` → exit 0
- witness seq/conc : `run_id`/`epoch` = SQLite ; conc `peak>=2`
- witness après reprise : `epoch_interrupt=2` → `epoch_after_resume=3`, témoins `[3,3]` (détecte une epoch figée à 2)
- checkpoints 1–5 durables + 2ᵉ reprise sans réinvocation ; `run_id` inconnu sans création de ligne

## Alignement script reject

`scripts/m1_pipe_backpressure_cli.sh` exige désormais `reject` exit **4** (plus « tout non-zéro »). Recheck : `docs/qa/m1_requal_2026-11-19/pipe_cli_reject4_recheck.log`.

## Jalon

| Objet | Verdict |
| --- | --- |
| M0 | Conservé |
| **M1** | **Requalifié** @ `dd4fcf5` |
| Fusion PR #2 | **Non** — revue humaine |
| Lot suivant | **Non ouvert** |

LLM : **0**.
