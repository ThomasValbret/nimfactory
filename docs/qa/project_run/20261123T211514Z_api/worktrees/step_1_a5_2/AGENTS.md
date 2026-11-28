# Agents — demo_tasks_cli

Petit CLI Nim de liste de tâches.

## Consignes
- Préserver le comportement d'affichage par défaut (`list`) sauf demande explicite.
- Les changements d'export doivent être opt-in (drapeau CLI), pas remplacer `list`.
- L'export CSV s'écrit sur la **sortie standard** (stdout), jamais dans un fichier.
- Les titres peuvent contenir des virgules ; un export CSV doit les quotter correctement.
- Helpers CSV (`formatCsv` / `csvQuote`) vivent dans `src/tasks.nim` ; le câblage
  CLI (`export-csv`) dans `src/demo_tasks.nim` — une étape = un fichier.
- Préférer de petites modifications localisées sous `src/`.
