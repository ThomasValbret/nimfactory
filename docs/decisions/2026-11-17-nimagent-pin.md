# Décision — Pin NimAgent et toolchain

Date : 2026-11-17

## Contexte

F0 doit rattacher Message et le codec à une révision SDK exacte. Le système
disposait de Nim 1.6.14, insuffisant pour `nimagent` (`requires nim >= 2.4.0`).

## Décision

- Toolchain : **Nim 2.4.0** via choosenim (`/root/.nimble/bin` en tête de PATH).
- SDK : `/opt/NimAgentLibrary` @ `bf22665ece77d7149dbe61df959a6024bf6b26f3`
  (`v0.2.1-30-gbf22665`), pas `nimagent-cz-mission`.
- Dépendance : path local (`config.nims` / `--path:/opt/NimAgentLibrary/src`).
- Codec Message factory : `messageToFactoryJson` / `messageFromFactoryJson`
  (superset lossless du helper session SDK, qui omet cache/reasoning/finishReason).
- Métadonnées factory : compagnon `FactoryMeta` dans l'enveloppe
  `{factory, message, payload?}` — Message nimagent n'est pas étendu.

## Conséquences

Les lots suivants importent `nimfactory` et ne re-sérialisent pas Message
avec un codec divergent. Une évolution incompatible du mapping Message
passe par une proposition F0 + fixtures de compatibilité.
