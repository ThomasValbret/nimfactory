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
Tu peux poser une question d'architecture facultative OU annoncer une hypothèse.
Ne code pas. Réponds UNIQUEMENT en JSON avec les clés:
  summary (string),
  hypothesis (string, peut être vide),
  optional_question (string, peut être vide),
  steps (array de {id, title, depends_on: string[]}),
  mandate_sketch (object: {goal, constraints: string[], files_likely: string[]}).
""".strip()

  ReviseSystemPrompt* = """
Tu es le planificateur NimFactory en révision de plan.
Le pilote a précisé sa demande. Mets à jour le plan et le mandat agent.
Montre les conséquences de la précision (export, comportement par défaut, etc.).
Ne code pas. Réponds UNIQUEMENT en JSON avec les clés:
  summary, hypothesis, optional_question,
  steps (array de {id, title, depends_on}),
  mandate_sketch ({goal, constraints, files_likely}),
  change_notes (string: ce que la précision change par rapport au plan précédent).
""".strip()

  ImplementSystemPrompt* = """
Tu es l'agent de réalisation NimFactory pour une étape bornée.
Contrat plan↔exécution: chaque étape doit laisser un arbre compilable.
Tant que project step n'applique qu'un seul fichier, retourne UNE seule
proposition JSON (un target_file). Plusieurs blocs JSON ou plusieurs
target_file = refus avant toute écriture.
Si un prérequis hors mandat impose de revoir le plan, retourne:
  {"revise_plan": true, "decision": "<motif>"}.
Sinon préfère des edits sur un fichier existant. Deux formes admises:
  - remplacement: {oldText, newText} (oldText unique dans l'arbre courant)
  - insertion: {insertBefore|insertAfter: "<ancre unique>", newText: "..."}
JSON strict uniquement (pas de \"\"\" hors chaîne JSON, pas de markdown utile).
Tu choisis librement les noms de fonctions et la structure du code ;
l'oracle de la recette vérifie le comportement du binaire (list par défaut,
export CSV opt-in), pas tes identifiants internes.
Retourne UNIQUEMENT JSON:
  target_file, decision, edits: [...].
""".strip()

  ProjectRecoverySystemPrompt* = """
Tu récupères une proposition d'édition refusée par project step.
On t'a donné: une seule copie fidèle de ta réponse brute (y compris un
bloc malformé / JSON illisible), un diagnostic sans écriture (compte
d'occurrences d'ancre par édition lisible, extraits si ancre ambiguë).
Tu choisis le fichier et le correctif. Une seule proposition JSON
(un target_file). Si un prérequis impose de réviser le plan:
  {"revise_plan": true, "decision": "<motif>"}.
Sinon JSON strict: target_file, decision, edits avec soit
  {oldText, newText} (ancre unique), soit
  {insertBefore|insertAfter, newText} sur une ancre unique vérifiée
  dans l'arbre courant. Pas de oldText vide.
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
    cwd: string; mandate: JsonNode; stepTitle: string): PlanContext =
  result.agentsMd = loadAgentsMd(cwd)
  result.sources = collectProjectSources(cwd)
  result.sourceIds = result.sources.mapIt(it.relPath)
  result.ok = true
  result.systemPrompt = ImplementSystemPrompt
  result.userPrompt =
    "Étape: " & stepTitle & "\n\n" &
    "Mandat borné (JSON):\n```json\n" & pretty(mandate) & "\n```\n\n" &
    "Extraits AGENTS.md utiles:\n" &
    (if result.agentsMd.len > 0: result.agentsMd else: "(absent)") &
    "\n\nSources autorisées:\n\n" & renderSources(result.sources) &
    "\n\nProduis les edits JSON maintenant."

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
