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
Lis les consignes locales (AGENTS.md), la recette (recipe.json) et les
sources fournies sous budget. Propose un plan d'étapes bornées.
Une étape = un fichier (un target_file). Un dépôt vide peut recevoir ses
premiers fichiers ; un dépôt existant peut être dans un autre langage.
Distingue clairement:
  - final_criteria: critères d'acceptation du livrable final,
  - postconditions: ce que chaque étape doit laisser vrai (tokens exécutables
    de la recette quand ils existent).
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
Contrat plan↔exécution: chaque étape doit laisser un arbre cohérent.
UNE seule proposition JSON (un target_file). Toutes les ancres doivent
appartenir à CE fichier ; un prérequis hors fichier → revise_plan.
Si un prérequis hors mandat impose de revoir le plan, retourne:
  {"revise_plan": true, "decision": "<motif>"}.
Sinon:
  - fichier existant: edits {oldText,newText} | insertBefore/After |
    insertLineBefore/After (jamais insertLineAfter sur un seul en-tête
    `proc/def … =` / `:` — sauter le corps indenté),
  - fichier absent: {"target_file","decision","patched_content": "<corps complet>"}.
Respecte les postconditions exécutables de l'étape et les contraintes
de la recette (ex. stdout si export CSV). Ancres = sous-chaînes EXACTES
des Sources. JSON strict: target_file, decision, edits ou patched_content.
""".strip()

  ProjectRecoverySystemPrompt* = """
Tu récupères une proposition d'édition refusée avant écriture.
Le diagnostic indique pour chaque ancre le fichier où elle a été trouvée
(found_in_file). Si une ancre est dans un autre fichier que target_file,
reformule UNE proposition pour ce fichier-là, ou revise_plan pour
séparer les fichiers. Une seule proposition JSON (un target_file).
Sinon: oldText/newText, insertBefore/After, ou insertLineBefore/After.
""".strip()

  ProjectCompileRepairSystemPrompt* = """
Tu répares un candidat déjà appliqué qui a échoué à la compilation.
On t'a donné: le candidat rejeté (proposition exacte), son diff lisible,
et un diagnostic localisé (chemin/ligne/colonne + extrait) — formats
compilateur variés, reste sur du texte.
Si l'identifiant manquant appartient à un autre fichier du plan,
retourne revise_plan plutôt que de le redéfinir ici.
Corrige sans recommencer tout le plan. Une seule proposition JSON
(un target_file). Si le prérequis impose de réviser le plan:
  {"revise_plan": true, "decision": "<motif>"}.
""".strip()

const SourceExts = [
  ".nim", ".py", ".rs", ".go", ".ts", ".js", ".tsx", ".jsx",
  ".c", ".h", ".cpp", ".hpp", ".java", ".kt", ".sql", ".md",
  ".json", ".toml", ".yaml", ".yml"
]

proc fenceForPath(rel: string): string =
  let ext = splitFile(rel).ext.toLowerAscii
  case ext
  of ".py": "python"
  of ".rs": "rust"
  of ".go": "go"
  of ".ts", ".tsx": "typescript"
  of ".js", ".jsx": "javascript"
  of ".sql": "sql"
  of ".md": "markdown"
  of ".json": "json"
  of ".toml": "toml"
  of ".yaml", ".yml": "yaml"
  of ".c", ".h": "c"
  of ".cpp", ".hpp": "cpp"
  of ".java": "java"
  of ".kt": "kotlin"
  else: "text"

proc pathLooksRelevant(rel: string): bool =
  let low = rel.toLowerAscii
  if low.startsWith(".git/") or "/.git/" in low: return false
  if "/nimcache/" in low or low.endsWith(".o") or low.endsWith(".pyc"):
    return false
  if low.startsWith("build/") or low.startsWith("node_modules/"): return false
  let ext = splitFile(rel).ext.toLowerAscii
  if ext in SourceExts: return true
  # Keep recipe / agents at roots even without extension match already covered.
  extractFilename(rel) in ["AGENTS.md", "recipe.json", "RECIPE.md"]

proc collectProjectSources*(cwd: string; maxFiles = 12; maxBytes = 80_000): seq[ProjectSource] =
  ## Budget-capped discovery: AGENTS/recipe first, then source trees (any language).
  if not dirExists(cwd):
    return @[]
  var paths: seq[string] = @[]
  for name in ["AGENTS.md", "recipe.json", "RECIPE.md"]:
    let p = cwd / name
    if fileExists(p): paths.add(p)
  for rootName in ["src", "skeleton", "lib", "app"]:
    let root = cwd / rootName
    if not dirExists(root): continue
    for path in walkDirRec(root):
      if fileExists(path):
        let rel = relativePath(path, cwd).replace('\\', '/')
        if pathLooksRelevant(rel):
          paths.add(path)
  # Also shallow files under cwd (e.g. main.py) when no src/.
  if not dirExists(cwd / "src") and not dirExists(cwd / "skeleton"):
    for kind, path in walkDir(cwd):
      if kind == pcFile:
        let rel = relativePath(path, cwd).replace('\\', '/')
        if pathLooksRelevant(rel) and '/' notin rel:
          paths.add(path)
  paths.sort()
  var seen: seq[string] = @[]
  var total = 0
  for p in paths:
    let rel = relativePath(p, cwd).replace('\\', '/')
    if rel in seen: continue
    if result.len >= maxFiles: break
    let body = readFile(p)
    if total + body.len > maxBytes: break
    seen.add(rel)
    result.add(ProjectSource(relPath: rel, content: body))
    total += body.len

proc loadAgentsMd*(cwd: string): string =
  let p = cwd / "AGENTS.md"
  if fileExists(p): readFile(p) else: ""

proc loadRecipeExcerpt*(cwd: string; maxBytes = 4_000): string =
  let p = cwd / "recipe.json"
  if not fileExists(p): return ""
  let body = readFile(p)
  if body.len <= maxBytes: body else: body[0 ..< maxBytes] & "\n…"

proc renderSources(sources: seq[ProjectSource]): string =
  var parts: seq[string] = @[]
  for s in sources:
    let fence = fenceForPath(s.relPath)
    parts.add("### FILE " & s.relPath & "\n```" & fence & "\n" & s.content & "\n```")
  parts.join("\n\n")

proc buildAskContext*(cwd, objective: string): PlanContext =
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  let recipe = loadRecipeExcerpt(cwd)
  # Empty cwd is allowed: bootstrap first files from objective alone.
  if result.sources.len == 0 and result.agentsMd.len == 0 and recipe.len == 0:
    result.ok = true
    result.systemPrompt = PlanSystemPrompt
    result.userPrompt =
      "Demande du pilote:\n" & objective.strip() & "\n\n" &
      "Le dossier projet est vide (pas encore de sources). Propose un plan " &
      "qui crée les premiers fichiers nécessaires.\n\n" &
      "Produis le JSON du plan maintenant."
    return
  result.ok = true
  result.systemPrompt = PlanSystemPrompt
  result.userPrompt =
    "Demande du pilote:\n" & objective.strip() & "\n\n" &
    "AGENTS.md:\n" & (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nrecipe.json:\n" & (if recipe.len > 0: recipe else: "(absent)") &
    "\n\nSources:\n\n" &
    (if result.sources.len > 0: renderSources(result.sources) else: "(aucune)") &
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
  let recipe = loadRecipeExcerpt(cwd)
  result.userPrompt =
    "Demande initiale:\n" & objective.strip() & "\n\n" &
    implBlock &
    "Précisions du pilote:\n- " &
    (if refinements.len > 0: refinements.join("\n- ") else: "(aucune)") & "\n\n" &
    "Plan précédent (JSON):\n```json\n" & priorPlanJson & "\n```\n\n" &
    "AGENTS.md:\n" & (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nrecipe.json:\n" & (if recipe.len > 0: recipe else: "(absent)") &
    "\n\nSources:\n\n" &
    (if result.sources.len > 0: renderSources(result.sources) else: "(aucune)") &
    "\n\nProduis le JSON du plan révisé maintenant."

proc buildImplementContext*(
    cwd: string; mandate: JsonNode; stepTitle: string;
    postconditions: seq[string] = @[];
    stdoutConstraint = ""): PlanContext =
  ## postconditions = executable step checks; stdoutConstraint = optional recipe rule.
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
    else: ""
  let recipe = loadRecipeExcerpt(cwd)
  result.userPrompt =
    "Étape: " & stepTitle & "\n\n" &
    postBlock &
    stdoutBlock &
    "Mandat borné (JSON):\n```json\n" & pretty(mandate) & "\n```\n\n" &
    "Extraits AGENTS.md utiles:\n" &
    (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nrecipe.json:\n" & (if recipe.len > 0: recipe else: "(absent)") &
    "\n\nSources autorisées:\n\n" &
    (if result.sources.len > 0: renderSources(result.sources) else: "(aucune — fichier à créer)") &
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
