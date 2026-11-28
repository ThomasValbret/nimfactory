# Qualification transfert — candidat `d519d49`

Date : 2026-11-24  
Candidat : `d519d49ac8c149186d873fa9d6470ce8d0974c04`  
Empreintes gel (`ENGINE_PILOT.md` @ `1503725`) :

| Binaire | sha256 |
| --- | --- |
| CLI | `58e92444ba99a4aede714f8ac64a2c9035a50c4a6ffe442af8475603fdeaf665` |
| Studio | `f20aff2eaf59c818601b4422ce01fd9426aaab48fd0140cf482c7291a2aafc62` |

Précontrôle avant lancement : **CLI=yes · Studio=yes** (binaires `/opt/nimFactory-engine-pilot/build/…`).  
Journaux gel : missions réservées **non jouées** sur ce candidat → essais neufs sous `/tmp/qual_d519d49/` (pas de rejeu de reçu d519).

## 1. Attribution des essais déjà réalisés (pré-gel)

Ces essais datent de `feature/studio-proof` @ `4aca865` (avant merge d519).  
Exécutable : `/opt/nimFactory-studio-proof/build/nimfactory`  
Empreinte complète encore lisible sur le fichier :  
`8f4e87d0bf0ed9bd6dc13ba4306a905d1647519d3eebb1063374526cc21e2373`  
(≠ empreinte gel d519). Tip Git de l’époque : `4aca865`.

| Essai | Commande | Fournisseur | Coût | Verdict |
| --- | --- | --- | --- | --- |
| empty_ledger first | `project run --route api --command-id transfer-empty-1` cwd vide | api non appelé (context) | **$0** · 0 appels | `context_failed` (AGENTS/src manquants) |
| foreign_inventory first | `project run --route api --command-id transfer-foreign-1` seed YAML | api non appelé | **$0** · 0 appels | `context_failed` (AGENTS/src manquants) |

### Essai assisté (séparé)

Humain a ajouté `AGENTS.md`, puis révision « note obligatoire », puis reprise.

| Étape | command_id | Coût (usage rôles) | Verdict |
| --- | --- | --- | --- |
| after AGENTS | `transfer-empty-2` | ~$0.000792 · 3 appels | `step_ceiling` / `revise_plan_needed` |
| revise | `transfer-empty-revise-1` | cumul ~$0.001428 | `plan_revised` v1→v2 |
| resume | `transfer-empty-resume-1` | cumul ~$0.001798 | `step_ceiling` · pas d’arbre accepté |

Si l’on exige l’identité **stricte** du binaire au moment T sans journal sha256 plein : la coupe 16 hex `8f4e87d0bf0ed9bd` était notée ; le fichier présent porte le SHA-256 complet ci-dessus. Ce n’est **pas** le binaire gelé d519.

## 2. Essais d519 (route production)

Demande + ressources normales livrées au builder ; assertions restées sous `/tmp/qual_d519d49/eval/` (évaluateur).

### Rejeux de transfert déjà révélés (ne pas recompter comme découverte d519)

- Cwd vide **sans** AGENTS sur binaire pré-d519 → `context_failed`
- Dépôt foreign **sans** AGENTS sur binaire pré-d519 → `context_failed`
- Assisté AGENTS + revise note obligatoire (pré-d519)

### Variante inédite réservée au prochain candidat

Foreign avec `AGENTS.md` minimal + objectif export/expédition, **worktree neuf** après un premier `missing_edits`, pour obtenir un premier fichier réellement écrit (scénario non clos sur d519).

## 3. Première décision qui change le résultat (d519)

| Mission | Découverte planificateur | Premier fichier créé/modifié | Provenance | Premier échec / preuve | Oracle indépendant | Coût essai |
| --- | --- | --- | --- | --- | --- | --- |
| **empty_ledger** | Plan 6 étapes Flask/SQLite (env → app → DB → CRUD → rendu → tests) | `requirements.txt` **nouveau** (`811C9DC5`→`2D541171`, contenu `flask`/`flask_sqlalchemy`) | `diff_origin=model` · api | `verify_failed` : `file_exists` / `program_runs` (pas d’entrypoint) | **failed** (`python_present=false`) sur worktree step1 | ~$0.00052 · 2 appels API |
| **foreign_inventory** | Plan 4 étapes (init → export CSV → expédition → docs) | **aucun** (pas d’écriture) | tentative model · api | `recovery_exhausted` : `missing_edits; no write` | **failed** sur seed seul (`export_or_csv_mentioned=false`) | ~$0.00069 · 3 appels API |

### empty_ledger — revise puis reprise (après conservation du 1er essai)

| Étape | Verdict | Effet |
| --- | --- | --- |
| revise `qual-d519-empty-revise-1` | `plan_revised` v1→v2 | contrainte note obligatoire ; preuves 0/0 |
| resume `qual-d519-empty-resume-1` | `apply_failed` | worktree `step_step1_a1_0` déjà occupé — **aucun nouveau fichier** ; 1er essai intact |

Coût cumulé campagnes d519 (empty+foreign+revise+resume) ≈ **$0.0035** · ~12 appels rôle · 6 API command-counted.

## Tableau livrable

| Mission | Quel binaire a travaillé ? | Qu’a-t-il effectivement produit ? | Qu’a vérifié l’évaluateur sur cet arbre ? |
| --- | --- | --- | --- |
| empty_ledger (historique pré-gel) | `/opt/nimFactory-studio-proof/build/nimfactory` · sha256 `8f4e87d0…21e2373` (≠ gel) | rien (arrêt `context_failed`) | non exécuté (pas d’arbre) |
| foreign_inventory (historique pré-gel) | idem | rien (`context_failed`) | non exécuté |
| empty_ledger **assisté** (pré-gel) | idem | plan v1→v2 après AGENTS+revise ; **pas** d’arbre accepté | non exécuté |
| empty_ledger (**d519** premier essai) | `/opt/nimFactory-engine-pilot/build/nimfactory` · **`58e92444…deaf665`** (gel OK) | plan v1 + **`requirements.txt`** dans worktree step1 ; verify moteur failed | oracle `empty_ledger_assert` → **failed** (pas de `.py`) |
| foreign_inventory (**d519** premier essai) | même binaire gelé | plan v1 seulement ; **zéro diff appliqué** | oracle `foreign_inventory_assert` sur seed → **failed** (pas d’export/CSV) |
| empty_ledger (**d519** revise+resume) | même binaire gelé | plan v2 ; reprise bloquée `apply_failed` (worktree occupé) ; produit step1 **conservé** | inchangé / failed |

Journaux : `/tmp/qual_d519d49/logs/` · builder : `/tmp/qual_d519d49/builder/` · eval : `/tmp/qual_d519d49/eval/`.

## 4. Trace `foreign_inventory` (premier essai d519, conservée)

Sources : `/tmp/qual_d519d49/logs/foreign_first.json`, `foreign.sqlite` (events), `foreign_art/{plan_v1,mandate}.json`.  
Assertions réservées : uniquement côté évaluateur (`/tmp/qual_d519d49/eval/`, `docs/qa/transfer_reserved/sealed/`) — **jamais** copiées dans le cwd builder.

| Question | Fait vérifiable |
| --- | --- |
| Qu’a reçu le modèle (planificateur) ? | Demande export CSV + marquage expédié ; sources découvertes `inventory.yaml` (+ `bin/list_open.sh` via collect) ; `AGENTS.md` absent (`agents_md_excerpt=""`). Mandate step1 : `source_ids=["inventory.yaml"]`, `files_likely=["export_inventory.py","update_inventory.py","README.md"]`, postconditions `file_exists`/`program_runs`. |
| Forme de la 1ʳᵉ proposition (implémenteur) ? | **Texte brut non journalisé** dans le reçu ni dans `nf_attempts` (table vide). Dernier fait : `provider_attempt.status=completed`, route `api`, `started_at=2026-11-24T02:31:18Z`, modèle usage `gpt-4o-mini`. |
| Qu’a reconnu l’applicateur ? | `refuse_code=missing_edits` · `apply.ok=false` · `wrote=false` · `targets=["inventory.yaml"]` · `prior_refuse=missing_edits`. Aucun worktree de step créé. |
| Réparation tentée ? | **Oui** : `recovery_triggered=true`, `recovery_attempted=true`, `recovery_reason=missing_edits` ; puis `recovery_exhausted=true` avec message `recovery still refused (missing_edits); no write`. Empreinte d’épuisement `missing_edits:missing_edits`. `revise_plan_pending=true`. |
| Verdict run | `step_ceiling` après épuisement (max-steps / pending) · coût essai ~$0.00069 · 3 appels rôle |

**Limite de trace :** le corps JSON/edits renvoyé par le modèle à l’étape 1 n’a pas été persisté (`first_faulty_raw` absent du reçu `command_id`). On ne peut pas qualifier la *forme* (edits vs patched_content vs prose) au-delà du refus `missing_edits` répété après recovery.

## 5. Protocole « prochain gel » (prêt, non exécuté)

`ENGINE_PILOT.md` pointe toujours `d519d49` + sha256 CLI `58e92444…` / Studio `f20aff2e…`.  
Tip moteur observé ensuite : `49ba135` (après `067e6a4` worktree frais + `b2b6b66` bind `file_exists`) — **pas** de nouvelle fiche d’empreintes gel. Le binaire CLI gelé `58e92444…` n’est plus présent sur disque (reconstructions non bit-identique).

Au gel suivant, enchaîner **avant** toute autre campagne :

1. Comparer CLI/Studio aux empreintes publiées.
2. Rejouer `empty_ledger` et `foreign_inventory` depuis cwd initiaux neufs ; **même** `--worktree` root entre échec et relance.
3. Essai **assisté** AGENTS : deux copies initiales identiques, seule la présence de `AGENTS.md` varie ; classer `assisted`.

La mission inconnue (étape 4 du protocole) a été livrée séparément ci-dessous, hors gel, pour clôturer le lot courant.

## 6. Mission inconnue — premier essai (séparé des réparations)

Reçu détaillé : [UNKNOWN_FIRST_TRIAL.md](UNKNOWN_FIRST_TRIAL.md) · journaux `/tmp/qual_unknown_067e6a4/`.

| Champ | Valeur |
| --- | --- |
| Mission | `word_tally` (inconnue du builder ; hors empty/foreign/loan/csv) |
| SHA source | `49ba13529484f156491d4c1abdd631328779aa76` |
| CLI sha256 | `24c768f61763325b54748fcb8dcacc322ce3db70b906a98934fbf2f16e5197e0` |
| Coût | **~$0.00053** · 2 appels API · `diff_origin=model` |
| 1ᵉʳ fichier utile | `tally.py` (`7B3167304F266B1C`) · mode `patched_content` |
| Arbre (status / Studio) | `art/trees/step1` · hash `AAB37878B03070F9` · fichiers : `tally.py` · `proof_freshness=fresh` |
| Verdict moteur | `paused_after_step` / `step_pass` (pause après step1 ; pas de réparation) |
| Évaluateur | **failed** : `tally_py_present`+`program_runs` ok ; `stdout_three_ints` ko (sortie multi-lignes `Lines:/Words:/Characters:`) |
| Lançable | `python3 tally.py <fichier.txt>` depuis l’arbre → compteurs libellés, **pas** la ligne `N N N` demandée |

Assertions : uniquement `/tmp/qual_unknown_067e6a4/eval/` (jamais dans le cwd builder).
