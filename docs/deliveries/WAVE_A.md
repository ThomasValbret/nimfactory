# Vague A — Intégration
Date : 2026-11-17
Périmètre : F0 + F1 + F3 + F4 + F14 + début F17
Base : `/opt/nimFactory` (non versionné Git)
Nim : 2.4.0 · NimAgent : `bf22665ece77d7149dbe61df959a6024bf6b26f3`

## Réalisé

| Lot | Agent | Reçu | Tests |
| --- | --- | --- | --- |
| F0 | intégrateur | [F0.md](F0.md) | ok |
| F1 | [F1 artefacts](709fc415-1f16-46d9-b499-e0467ba588ac) | [F1.md](F1.md) | ok |
| F3 | [F3 journal](9d1d0f36-2f9f-4aa0-b5ca-b7a002753491) | [F3.md](F3.md) | ok |
| F4 | [F4 graphe](5970dbc4-0fda-4932-883a-b246c458fdfa) | [F4.md](F4.md) | ok |
| F14 | [F14 budget](992d59fc-2711-4a80-8168-ab7a9b36dd88) | [F14.md](F14.md) | ok |
| F17 début | [F17 qualification](76665c0d-24f7-4071-a663-6cb986ded00a) | [F17.md](F17.md) | ok |

Intégrateur : façade `src/nimfactory.nim` réexporte artefacts, journal, graph, budget.
Correctif F4 `agg` dans `controlInputPorts` conservé.
Isolation temp F1 renforcée.

## Non-fork Message

Seul `src/nimfactory/adapters/nimagent/message_codec.nim` sérialise `Message`.
Aucun lot A n’a introduit de codec concurrent.

## Vérification (observée)

```bash
export PATH="/root/.nimble/bin:$PATH"
cd /opt/nimFactory
# 8/8 ok — F0×3, F1, F3, F4, F14, F17
```

Appels LLM : **0**.

## Jalons

- **M0** : **requalifié en A.1** — avis favorable [WAVE_A_1_ACCEPTANCE_REVIEW.md](../qa/WAVE_A_1_ACCEPTANCE_REVIEW.md) ; reçu [WAVE_A_1.md](WAVE_A_1.md) (preuves codeur ≠ exécutions indépendantes).
- **M1** : **non atteint** (pas d’exécuteur F5 ni CLI F16).

## Limites restantes

- Composition applicative / CLI : F16
- Exécuteur et tuyaux : F5
- Chambres : F2
- Préparateurs / seed / broker : vague C + F13
- F17 : oracles simulés seulement ; pas de campagne M4
- `nimble test*` peut échouer sur résolution `nimagent` ; utiliser `nim c -r --path:...`

## État
Conformité composants Vague A : **oui**
Intégration façade : **oui** (exports)
Parcours complet bout-en-bout : **non**
