## Context constructors for the software-fix mission (API vs local routes).
## Oracle / reception tests are never included in model context.

import std/[os, strutils, sequtils, algorithm, json]

type
  SourceFile* = object
    relPath*: string
    content*: string

  MissionContext* = object
    route*: string           ## "api" | "local"
    symptom*: string
    sources*: seq[SourceFile]
    systemPrompt*: string
    userPrompt*: string
    sourceIds*: seq[string]  ## relative paths actually supplied

const
  ApiSystemPrompt* = """
You are the software_fix role for NimFactory.
Examine the supplied repository sources and the symptom.
Choose exactly one file to change and produce a complete corrected file body.
Do not invent files. Do not touch unrelated helpers unless they are the true cause.
If the file uses strip or other strutils helpers, keep `import std/strutils`.
Return ONLY a JSON object with keys:
  target_file (string, path relative to repo root),
  decision (short string naming the cause),
  patched_content (full new file text).
""".strip()

  LocalSystemPrompt* = """
You perform a bounded local micro-patch.
Given candidate source files and a symptom, pick the one broken file and rewrite it so the stated spec holds.
Keep needed imports (e.g. std/strutils for strip).
Return ONLY JSON: target_file, decision, patched_content.
""".strip()

proc collectSrcNim*(repoRoot: string): seq[SourceFile] =
  let srcDir = repoRoot / "src"
  if not dirExists(srcDir):
    return @[]
  var paths: seq[string] = @[]
  for kind, path in walkDir(srcDir):
    if kind == pcFile and path.endsWith(".nim"):
      paths.add(path)
  paths.sort()
  for p in paths:
    let rel = relativePath(p, repoRoot)
    # Never pull oracle or reception tests into model context.
    if rel.contains("oracle") or rel.contains("test_"):
      continue
    result.add(SourceFile(relPath: rel, content: readFile(p)))

proc renderSources(sources: seq[SourceFile]): string =
  var parts: seq[string] = @[]
  for s in sources:
    parts.add("### FILE " & s.relPath & "\n```nim\n" & s.content & "\n```")
  parts.join("\n\n")

proc buildApiContext*(repoRoot, symptomPath: string): MissionContext =
  ## Full API-route context: symptom + every src/*.nim candidate.
  let symptom =
    if symptomPath.len > 0 and fileExists(symptomPath): readFile(symptomPath)
    elif fileExists(repoRoot / "SYMPTOM.md"): readFile(repoRoot / "SYMPTOM.md")
    else: "normalize must map empty/whitespace to EMPTY and otherwise return trimmed text."
  let sources = collectSrcNim(repoRoot)
  result.route = "api"
  result.symptom = symptom
  result.sources = sources
  result.sourceIds = sources.mapIt(it.relPath)
  result.systemPrompt = ApiSystemPrompt
  result.userPrompt =
    "Symptom:\n" & symptom.strip() & "\n\nRepository sources:\n\n" &
    renderSources(sources) &
    "\n\nProduce the JSON patch decision now."

proc buildLocalMicroPatchContext*(repoRoot, symptomPath: string): MissionContext =
  ## Dedicated local constructor: tighter prompt, same source selection rules,
  ## never the API prompt verbatim or truncated.
  let symptom =
    if symptomPath.len > 0 and fileExists(symptomPath): readFile(symptomPath)
    elif fileExists(repoRoot / "SYMPTOM.md"): readFile(repoRoot / "SYMPTOM.md")
    else: "Spec: empty/whitespace → EMPTY; else trimmed."
  let sources = collectSrcNim(repoRoot)
  result.route = "local"
  result.symptom = symptom
  result.sources = sources
  result.sourceIds = sources.mapIt(it.relPath)
  result.systemPrompt = LocalSystemPrompt
  result.userPrompt =
    "Local micro-patch task.\nSymptom: " & symptom.strip() &
    "\nCandidates:\n" & renderSources(sources) &
    "\nJSON only."

proc contextToJson*(ctx: MissionContext): JsonNode =
  %*{
    "route": ctx.route,
    "source_ids": ctx.sourceIds,
    "system_prompt": ctx.systemPrompt,
    "user_prompt": ctx.userPrompt,
    "symptom": ctx.symptom
  }
