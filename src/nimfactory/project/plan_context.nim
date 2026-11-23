## Context constructors for project plan / revise (French pilot requests).

import std/[os, strutils, sequtils, algorithm, json]

type
  ProjectSource* = object
    relPath*: string
    content*: string

  PlanContext* = object
    ok*: bool
    error*: string
    agentsMd*: string
    sources*: seq[ProjectSource]
    systemPrompt*: string
    userPrompt*: string
    sourceIds*: seq[string]

const
  PlanSystemPrompt* = """
Tu es le planificateur NimFactory pour un petit projet logiciel.
Lis les consignes locales (AGENTS.md) et les sources fournies.
Propose un plan d'étapes bornées pour satisfaire la demande du pilote.
Une étape = un fichier. Pour un export CSV: d'abord helpers dans tasks.nim
(postconditions compile+list+csv_helpers: csvQuote ET formatCsv obligatoires),
puis câblage CLI dans demo_tasks.nim
(postconditions compile+list+export_command). CSV sur stdout.
Distingue clairement:
  - final_criteria: critères d'acceptation du livrable final (ex. export CSV),
  - postconditions: ce que chaque étape doit laisser vrai.
Tu peux poser une question d'architecture facultative OU annoncer une hypothèse.
Ne code pas. Réponds UNIQUEMENT en JSON avec les clés:
  summary (string),
  hypothesis (string, peut être vide),
  optional_question (string, peut être vide),
  final_criteria (string[]),
  steps (array de {id, title, depends_on: string[], postconditions: string[]}),
  mandate_sketch (object: {goal, constraints: string[], files_likely: string[]}).
""".strip()

  ReviseSystemPrompt* = """
Tu es le planificateur NimFactory en révision de plan.
Le pilote a précisé sa demande, ou un motif d'implémenteur bloque l'étape.
Mets à jour le plan et le mandat. Si le motif décrit un collage de tokens ou
une insertion textuelle fautive, change la façon de traiter le blocage
(étapes/postconditions/contraintes), pas seulement le libellé.
Distingue final_criteria (livrable) et postconditions (par étape).
Ne code pas. Réponds UNIQUEMENT en JSON avec les clés:
  summary, hypothesis, optional_question, final_criteria,
  steps (array de {id, title, depends_on, postconditions}),
  mandate_sketch ({goal, constraints, files_likely}),
  change_notes (string: ce qui change dans le traitement du blocage).
""".strip()

  ImplementSystemPrompt* = """
Tu es l'agent de réalisation NimFactory pour une étape bornée.
Contrat plan↔exécution: chaque étape doit laisser un arbre compilable.
UNE seule proposition JSON (un target_file). Toutes les ancres doivent
appartenir à CE fichier ; si un helper vit ailleurs (ex. tasks.nim),
traite-le dans une étape dédiée — ne mélange pas les fichiers.
Si un prérequis hors mandat impose de revoir le plan, retourne:
  {"revise_plan": true, "decision": "<motif>"}.
Sinon edits (contrat multi-langage, texte brut):
  - remplacement: {oldText, newText}
  - insertion textuelle: {insertBefore|insertAfter, newText}
  - insertion de ligne: {insertLineBefore|insertLineAfter, newText}
Pour ajouter un proc après un autre: préférer oldText/newText sur tout
le proc précédent, ou insertLineAfter sur sa DERNIÈRE ligne de corps
(ex. lines.join(...)) — jamais insertLineAfter sur le seul en-tête
`proc foo*... =` (casse l'indentation / le corps existant).
Étape helpers (tasks.nim): définir csvQuote* ET formatCsv* (en-tête
id,title ; titres avec virgule quotés). Ne pas s'arrêter à csvQuote seul.
Syntaxe Nim: concaténer avec & (pas +) ; littéraux caractère entre apostrophes.
Étape câblage (demo_tasks.nim): ajouter une branche case distincte
  of "export-csv":
    echo formatCsv(loadTasks())
sans if collé dans le else (qui tomberait dans unknown/quit).
Réutiliser formatCsv de tasks.nim — ne pas le redéfinir dans demo_tasks.
Respecte les postconditions exécutables de l'étape et la contrainte
stdout (export CSV sur la sortie standard, pas un fichier).
Les ancres oldText / insert* doivent être des sous-chaînes EXACTES
copiées depuis la section Sources (ne pas inventer de signatures).
JSON strict. Retourne: target_file, decision, edits: [...].
""".strip()

  ProjectRecoverySystemPrompt* = """
Tu récupères une proposition d'édition refusée avant écriture.
Le diagnostic indique pour chaque ancre le fichier où elle a été trouvée
(found_in_file). Si une ancre est dans un autre fichier que target_file,
reformule UNE proposition pour ce fichier-là, ou revise_plan pour
séparer helper et CLI. Une seule proposition JSON (un target_file).
Sinon: oldText/newText, insertBefore/After, ou insertLineBefore/After.
""".strip()

  ProjectCompileRepairSystemPrompt* = """
Tu répares un candidat déjà appliqué qui a échoué à la compilation.
On t'a donné: le candidat rejeté (proposition exacte), son diff lisible,
et un diagnostic localisé (chemin/ligne/colonne + extrait) — formats
compilateur variés, reste sur du texte.
Si l'identifiant manquant est formatCsv/csvQuote (helpers tasks.nim),
retourne revise_plan plutôt que de les redéfinir dans demo_tasks.nim.
Corrige sans recommencer tout le plan. Préfère insertLineBefore/After ou
un remplacement oldText/newText local. Une seule proposition JSON
(un target_file). Si le prérequis impose de réviser le plan:
  {"revise_plan": true, "decision": "<motif>"}.
""".strip()
proc collectProjectSources*(cwd: string; maxFiles = 12; maxBytes = 80_000): seq[ProjectSource] =
  let srcDir = cwd / "src"
  if not dirExists(srcDir):
    return @[]
  var paths: seq[string] = @[]
  for path in walkDirRec(srcDir):
    if path.endsWith(".nim") and fileExists(path):
      paths.add(path)
  paths.sort()
  var total = 0
  for p in paths:
    if result.len >= maxFiles: break
    let body = readFile(p)
    if total + body.len > maxBytes: break
    let rel = relativePath(p, cwd).replace('\\', '/')
    result.add(ProjectSource(relPath: rel, content: body))
    total += body.len

proc loadAgentsMd*(cwd: string): string =
  let p = cwd / "AGENTS.md"
  if fileExists(p): readFile(p) else: ""

proc renderSources(sources: seq[ProjectSource]): string =
  var parts: seq[string] = @[]
  for s in sources:
    parts.add("### FILE " & s.relPath & "\n```nim\n" & s.content & "\n```")
  parts.join("\n\n")

proc buildAskContext*(cwd, objective: string): PlanContext =
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  if result.sources.len == 0 and result.agentsMd.len == 0:
    result.ok = false
    result.error = "no AGENTS.md and no src/*.nim under project cwd"
    return
  result.ok = true
  result.systemPrompt = PlanSystemPrompt
  result.userPrompt =
    "Demande du pilote:\n" & objective.strip() & "\n\n" &
    "AGENTS.md:\n" & (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nSources:\n\n" & renderSources(result.sources) &
    "\n\nProduis le JSON du plan maintenant."

proc buildReviseContext*(
    cwd, objective: string; refinements: seq[string];
    priorPlanJson: string; implementerReason = ""): PlanContext =
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  result.ok = true
  result.systemPrompt = ReviseSystemPrompt
  let implBlock =
    if implementerReason.len > 0:
      "Motif transmis par l'implémenteur (prérequis bloquant l'étape):\n" &
      implementerReason.strip() & "\n\n"
    else:
      ""
  result.userPrompt =
    "Demande initiale:\n" & objective.strip() & "\n\n" &
    implBlock &
    "Précisions du pilote:\n- " &
    (if refinements.len > 0: refinements.join("\n- ") else: "(aucune)") & "\n\n" &
    "Plan précédent (JSON):\n```json\n" & priorPlanJson & "\n```\n\n" &
    "AGENTS.md:\n" & (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nSources:\n\n" & renderSources(result.sources) &
    "\n\nProduis le JSON du plan révisé maintenant."

proc buildImplementContext*(
    cwd: string; mandate: JsonNode; stepTitle: string;
    postconditions: seq[string] = @[];
    stdoutConstraint = ""): PlanContext =
  ## postconditions = executable step checks; stdoutConstraint = CSV-on-stdout rule.
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  result.ok = true
  result.systemPrompt = ImplementSystemPrompt
  var postBlock = ""
  if postconditions.len > 0:
    postBlock =
      "Postconditions exécutables de cette étape (oracle):\n- " &
      postconditions.join("\n- ") & "\n\n"
  let stdoutBlock =
    if stdoutConstraint.len > 0: stdoutConstraint.strip() & "\n\n"
    else:
      "Contrainte stdout: si l'étape touche l'export, écrire le CSV sur la " &
      "sortie standard (pas un fichier). Garder list/défaut intact.\n\n"
  result.userPrompt =
    "Étape: " & stepTitle & "\n\n" &
    postBlock &
    stdoutBlock &
    "Mandat borné (JSON):\n```json\n" & pretty(mandate) & "\n```\n\n" &
    "Extraits AGENTS.md utiles:\n" &
    (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nSources autorisées:\n\n" & renderSources(result.sources) &
    "\n\nProduis les edits JSON maintenant (un seul target_file)."

proc buildProjectRecoveryContext*(
    cwd: string; mandate: JsonNode; stepTitle: string;
    priorTarget, priorDecision, finding, rawFaithful: string): PlanContext =
  ## Bounded recovery: faithful raw (one copy) + read-only diagnosis finding.
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  result.ok = true
  result.systemPrompt = ProjectRecoverySystemPrompt
  result.userPrompt =
    "Tour de récupération (un seul autorisé).\n" &
    "Étape: " & stepTitle & "\n" &
    "Cible précédente (si unique): " & priorTarget & "\n" &
    "Décision précédente: " & priorDecision & "\n\n" &
    "Diagnostic produit (sans écriture):\n" & finding & "\n\n" &
    "Réponse brute fidèle (une seule copie):\n```\n" & rawFaithful & "\n```\n\n" &
    "Mandat borné (JSON):\n```json\n" & pretty(mandate) & "\n```\n\n" &
    "Sources autorisées (arbre courant):\n\n" & renderSources(result.sources) &
    "\n\nProduis UNE proposition JSON (ou revise_plan) maintenant."

proc buildCompileRepairContext*(
    rejectedTree: string; mandate: JsonNode; stepTitle: string;
    rejectedCandidate, readableDiff, localizedFinding: string): PlanContext =
  ## Post-compile repair: rejected candidate + diff + localized diagnosis.
  ## Sources come from the rejected tree (broken candidate), not pristine cwd.
  result.agentsMd = loadAgentsMd(rejectedTree)
  if result.agentsMd.len == 0:
    result.agentsMd = loadAgentsMd(rejectedTree / "..")
  result.sources = collectProjectSources(rejectedTree)
  result.sourceIds = result.sources.mapIt(it.relPath)
  result.ok = true
  result.systemPrompt = ProjectCompileRepairSystemPrompt
  result.userPrompt =
    "Tour de réparation post-compilation (un seul autorisé).\n" &
    "Étape: " & stepTitle & "\n\n" &
    "Candidat rejeté (proposition exacte):\n```json\n" &
    rejectedCandidate & "\n```\n\n" &
    "Diff du candidat:\n```\n" & readableDiff & "\n```\n\n" &
    "Diagnostic localisé:\n" & localizedFinding & "\n\n" &
    "Mandat borné (JSON):\n```json\n" & pretty(mandate) & "\n```\n\n" &
    "Sources du candidat rejeté:\n\n" & renderSources(result.sources) &
    "\n\nProduis UNE proposition JSON de réparation (ou revise_plan)."
