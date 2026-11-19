## Context constructors for software_fix (API intervention choice) and
## local micro-patch (target + diagnosis already established).
## Oracle / reception tests are never included in model context.
## No default domain spec is invented when the pilot omits the symptom.

import std/[os, strutils, sequtils, algorithm, json]

type
  SourceFile* = object
    relPath*: string
    content*: string

  MissionContext* = object
    route*: string
    symptom*: string
    sources*: seq[SourceFile]
    systemPrompt*: string
    userPrompt*: string
    sourceIds*: seq[string]
    ok*: bool
    error*: string

const
  ApiSystemPrompt* = """
You are the software_fix role for NimFactory.
Examine the supplied repository sources and the pilot symptom.
Choose exactly one existing file to change and produce its complete corrected body.
Do not invent files. Prefer the smallest change that addresses the symptom.
Keep required imports for the language of the file.
Return ONLY a JSON object with keys:
  target_file (string, path relative to repo root),
  decision (short string naming the cause you chose),
  patched_content (full new file text).
""".strip()

  LocalMicroPatchSystemPrompt* = """
You perform a bounded local micro-patch.
The intervention target and diagnosis are already established.
Rewrite only the supplied extract so the stated constraint holds.
Do not change unrelated files. Return ONLY JSON:
  target_file, decision, patched_content.
""".strip()

  ApiRecoverySystemPrompt* = """
You are the software_fix role for NimFactory on a recovery turn.
Your previous patch did not resolve the public symptom.
You may follow calls between functions, choose a different existing file, revise the same file,
or conclude you cannot propose a correction.
Do not invent files. The product will not reveal expected targets or private reception checks.
Return ONLY a JSON object with either:
  {"cannot_fix": true, "decision": "<why>"},
or the usual keys target_file, decision, patched_content.
""".strip()

proc collectSrcNim*(repoRoot: string): seq[SourceFile] =
  ## Collect every `.nim` under `src/` recursively (nested packages included).
  ## Does not flatten paths and does not hand-pick a culprit file.
  let srcDir = repoRoot / "src"
  if not dirExists(srcDir):
    return @[]
  var paths: seq[string] = @[]
  for path in walkDirRec(srcDir):
    if path.endsWith(".nim") and fileExists(path):
      paths.add(path)
  paths.sort()
  for p in paths:
    let rel = relativePath(p, repoRoot)
    let norm = rel.replace('\\', '/')
    if norm.contains("/oracle/") or norm.contains("oracle/") or
       "/test_" in ("/" & norm) or norm.extractFilename.startsWith("test_"):
      continue
    result.add(SourceFile(relPath: norm, content: readFile(p)))

proc renderSources*(sources: seq[SourceFile]): string =
  var parts: seq[string] = @[]
  for s in sources:
    parts.add("### FILE " & s.relPath & "\n```nim\n" & s.content & "\n```")
  parts.join("\n\n")

proc loadSymptom*(repoRoot, symptomPath: string): tuple[ok: bool; text: string; err: string] =
  if symptomPath.len > 0:
    if not fileExists(symptomPath):
      return (false, "", "symptom file not found: " & symptomPath)
    return (true, readFile(symptomPath), "")
  let fallback = repoRoot / "SYMPTOM.md"
  if fileExists(fallback):
    return (true, readFile(fallback), "")
  (false, "", "symptom required (pass --symptom or provide repo/SYMPTOM.md); no default domain spec")

proc buildApiContext*(repoRoot, symptomPath: string): MissionContext =
  ## API-route context: pilot symptom + every src/*.nim candidate. No invented spec.
  result.route = "api"
  let sym = loadSymptom(repoRoot, symptomPath)
  if not sym.ok:
    result.ok = false
    result.error = sym.err
    return
  let sources = collectSrcNim(repoRoot)
  if sources.len == 0:
    result.ok = false
    result.error = "no source files under repo/src"
    return
  result.ok = true
  result.symptom = sym.text
  result.sources = sources
  result.sourceIds = sources.mapIt(it.relPath)
  result.systemPrompt = ApiSystemPrompt
  result.userPrompt =
    "Symptom (from pilot):\n" & sym.text.strip() & "\n\nRepository sources:\n\n" &
    renderSources(sources) &
    "\n\nProduce the JSON patch decision now."

proc buildRecoveryContext*(
    base: MissionContext;
    priorTarget, priorDecision, priorPatchedContent, finding: string): MissionContext =
  ## Recovery turn: public symptom, authorized sources, first decision + proposed body,
  ## and a product finding. Never includes oracle text, expected target, or variant id.
  result = base
  result.route = "api"
  result.systemPrompt = ApiRecoverySystemPrompt
  result.userPrompt =
    "Recovery turn.\n" &
    "First decision target: " & priorTarget & "\n" &
    "First decision summary: " & priorDecision & "\n" &
    "Finding: " & finding & "\n" &
    "First proposed file body (`" & priorTarget & "`):\n```nim\n" &
    priorPatchedContent & "\n```\n\n" &
    "Symptom (from pilot):\n" & base.symptom.strip() & "\n\n" &
    "Authorized repository sources (current originals):\n\n" &
    renderSources(base.sources) &
    "\n\nProduce the JSON response now."

proc buildNoOpRecoveryContext*(base: MissionContext; chosenTarget: string): MissionContext =
  ## Compatibility wrapper for identical-content recovery.
  buildRecoveryContext(
    base, chosenTarget, "", "",
    "proposed content identical to the original")

proc buildLocalMicroPatchContext*(
    repoRoot, symptomPath, targetFile, diagnosis, constraint: string): MissionContext =
  ## Dedicated local constructor: target and diagnosis already known.
  result.route = "local"
  if targetFile.len == 0:
    result.ok = false
    result.error = "local micro-patch requires an established --target"
    return
  if diagnosis.len == 0:
    result.ok = false
    result.error = "local micro-patch requires an established --diagnosis"
    return
  let absTarget = repoRoot / targetFile
  if not fileExists(absTarget):
    result.ok = false
    result.error = "local micro-patch target missing: " & targetFile
    return
  let sym = loadSymptom(repoRoot, symptomPath)
  let symptomText = if sym.ok: sym.text else: ""
  let constraintText =
    if constraint.len > 0: constraint
    else: "Preserve public signatures; fix only the diagnosed defect."
  let body = readFile(absTarget)
  result.ok = true
  result.symptom = symptomText
  result.sources = @[SourceFile(relPath: targetFile, content: body)]
  result.sourceIds = @[targetFile]
  result.systemPrompt = LocalMicroPatchSystemPrompt
  result.userPrompt =
    "Established target: " & targetFile & "\n" &
    "Established diagnosis: " & diagnosis & "\n" &
    "Constraint to preserve: " & constraintText & "\n" &
    (if symptomText.len > 0: "Pilot symptom (background):\n" & symptomText.strip() & "\n" else: "") &
    "Extract:\n```nim\n" & body & "\n```\nJSON only."

proc contextToJson*(ctx: MissionContext): JsonNode =
  %*{
    "ok": ctx.ok,
    "error": ctx.error,
    "route": ctx.route,
    "source_ids": ctx.sourceIds,
    "system_prompt": ctx.systemPrompt,
    "user_prompt": ctx.userPrompt,
    "symptom": ctx.symptom
  }
