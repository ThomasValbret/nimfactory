# Mission inconnue — premier essai (sans réparation)

Date : 2026-11-24  
Classe : `unknown_first_trial` · réparations : **aucune**  
Journaux : `/tmp/qual_unknown_067e6a4/`

## Identité d’exécution

| | |
| --- | --- |
| SHA source | `49ba13529484f156491d4c1abdd631328779aa76` (`docs: pin integrable SHA b2b6b66…`) |
| CLI | `/opt/nimFactory-engine-pilot/build/nimfactory` · sha256 `24c768f61763325b54748fcb8dcacc322ce3db70b906a98934fbf2f16e5197e0` |
| Studio binaire | sha256 `619a83bc00d8ba42dc8e347dc6b89d466ce1b859770ad365d3b10470d1493d74` (≠ gel d519 `f20aff2e…`) |
| Route | `api` · `command_id=qual-unknown-word-tally-1` · `--pause-after-step` |
| Gel d519 | **non** — fiche gel absente pour le tip ; essai hors protocole « prochain gel » |

## Demande (builder)

> Je veux un outil Python `tally.py` qui lit un fichier texte passé en argument et affiche sur une seule ligne le nombre de lignes, de mots et de caractères, séparés par des espaces.

Cwd builder : vide (`/tmp/qual_unknown_067e6a4/builder/word_tally`).  
Assertions réservées : `/tmp/qual_unknown_067e6a4/eval/word_tally_assert.py`.

## Premier essai

| Champ | Valeur |
| --- | --- |
| Verdict | `paused_after_step` · `last_verdict=step_pass` |
| Coût | **$0.00053** · 2 appels (planner + implementer, gpt-4o-mini) |
| Provenance | `diff_origin=model` |
| 1ᵉʳ fichier | `tally.py` · fingerprint `7B3167304F266B1C` · `before=811C9DC5` → `after=9475319C` · `mode=patched_content` |
| Worktree | `/tmp/qual_unknown_067e6a4/wt/nf_mission_FESOdyDi` |

## Arbre affiché (projection Studio / `project status`)

Studio HTTP a segfaulté sur ce store (`SIGSEGV` / nil) ; projection prise via `project status` (mêmes champs d’arbre que Studio).

| | |
| --- | --- |
| `accepted_tree_ref` | `/tmp/qual_unknown_067e6a4/art/trees/step1` |
| `accepted_tree_hash` / `proof_tree_hash` | `AAB37878B03070F9` |
| `files_current_hash` | `AAB37878B03070F9` |
| `proof_freshness` | `fresh` |
| Fichiers | `tally.py` seul |

## Évaluateur indépendant

```json
{
  "ok": false,
  "checks": [
    {"name": "tally_py_present", "ok": true},
    {"name": "program_runs", "ok": true, "stdout": "Lines: 2\\nWords: 4\\nCharacters: 21"},
    {"name": "stdout_three_ints", "ok": false}
  ]
}
```

## Ce que l’utilisateur peut lancer

```bash
cd /tmp/qual_unknown_067e6a4/art/trees/step1
python3 tally.py mon_fichier.txt
```

Sortie observée (forme réelle) :

```
Lines: 2
Words: 4
Characters: 21
```

Ce n’est **pas** la ligne unique `2 4 21` demandée. Aucune réparation n’a été tentée sur cet essai.
