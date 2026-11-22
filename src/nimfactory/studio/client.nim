## Browser entry point. All application interaction is implemented in Nim.
import std/[dom, json, strutils, sequtils]

type
  View = enum workflow, ide, plans
  CodeTab = enum diff, source, receipt
  HttpRead = ref object of RootObj
    status: int
    responseText: cstring
    timeout: int
    onload, onerror, ontimeout: proc()

proc newGet(): HttpRead {.importjs: "new XMLHttpRequest()".}
proc open(req: HttpRead; meth, url: cstring) {.importjs: "#.open(#,#,true)".}
proc send(req: HttpRead) {.importjs: "#.send()".}
proc sendBody(req: HttpRead; body: cstring) {.importjs: "#.send(#)".}
proc setRequestHeader(req: HttpRead; key, value: cstring) {.importjs: "#.setRequestHeader(#,#)".}
proc header(req: HttpRead; name: cstring): cstring {.importjs: "#.getResponseHeader(#)".}
proc uriPart(text: cstring): cstring {.importjs: "encodeURIComponent(#)".}
proc actionTarget(node: Node): Element {.importjs: "#.closest?.('[data-action]')".}
proc activeId(): cstring {.importjs: "(document.activeElement?.id || '')".}
proc fieldValue(id: cstring): cstring {.importjs: "(document.getElementById(#)?.value || '')".}
proc mintCommandId(): cstring {.importjs: "('studio-revise-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10))".}

var
  model: JsonNode
  view = workflow
  tab = diff
  selection, lastBody, sourceText, sourceMsg: string
  sourceRequest = 0
  canReadSources, canWrite, pendingRefresh, showAllEvents, reviseBusy: bool
  draftRefinement, reviseStatus: string
  lastReceipt: JsonNode
  activeCommandId: string

proc html(s: string): string =
  s.multiReplace(("&","&amp;"), ("<","&lt;"), (">","&gt;"), ("\"","&quot;"), ("'","&#39;"))

proc put(id, content: string) =
  getElementById(cstring(id)).innerHTML = cstring(content)

proc button(action, label, cls: string; active = false; disabled = false): string =
  result = "<button data-action='" & html(action) & "' id='action-" & html(action) &
    "' aria-pressed='" & $active & "' class='" & cls & "'"
  if disabled: result.add(" disabled")
  result.add(">" & html(label) & "</button>")

proc selected(): JsonNode =
  for step in model{"steps"}.getElems:
    if step{"id"}.getStr == selection: return step

proc detailLine(label, value: string): string =
  if value.len > 0:
    result = "<div class='row'><span>" & html(label) & "</span><span class='value'>" & html(value) & "</span></div>"

proc stateLabel(state: string): string =
  case state
  of "done": "✓ Terminée"
  of "running": "▶ En cours"
  of "interrupted": "Ⅱ Interrompue"
  of "pending": "○ En attente"
  of "blocked": "◇ Bloquée"
  of "": "État inconnu"
  else: state

proc hasTab(step: JsonNode; which: CodeTab): bool =
  if step.isNil: return false
  case which
  of diff: step{"readable_diff"}.getStr.len > 0
  of receipt: step{"verify"} != nil
  of source: canReadSources and step{"accepted_tree_hash"}.getStr.len > 0 and
    step{"change","target_file"}.getStr.len > 0 and step{"change","after_hash"}.getStr.len > 0

proc hasIde(step: JsonNode): bool = step.hasTab(diff) or step.hasTab(source) or step.hasTab(receipt)

proc canRevise(): bool =
  if model.isNil or not canWrite: return false
  let caps = model{"capabilities","commands"}.getElems
  caps.anyIt(it.getStr == "revise_plan")

proc captureDraft() =
  let value = $fieldValue("revise-text")
  if getElementById("revise-text") != nil:
    draftRefinement = value

proc resetSource() =
  inc sourceRequest
  sourceText = ""
  sourceMsg = ""

proc deltaList(items: JsonNode; emptyLabel: string): string =
  if items.isNil or items.len == 0:
    return "<p class='fine'>" & html(emptyLabel) & "</p>"
  result = "<ul class='delta'>"
  for item in items:
    result.add("<li><code>" & html(item{"id"}.getStr) & "</code> " &
      html(item{"title"}.getStr) & "</li>")
  result.add("</ul>")

proc receiptPanel(): string =
  if lastReceipt.isNil: return ""
  let fromV = lastReceipt{"from_version"}.getInt
  let toV = lastReceipt{"to_version"}.getInt
  let verdict = lastReceipt{"verdict"}.getStr
  let ok = lastReceipt{"ok"}.getBool
  let replayed = lastReceipt{"replayed"}.getBool
  let cls = if ok: "receipt ok" else: "receipt bad"
  result = "<div class='" & cls & "'><div class='small-title'>Reçu du moteur</div>"
  result.add("<p><strong>" & html(verdict) & "</strong>")
  if replayed: result.add(" · retransmission")
  result.add("</p>")
  if ok:
    result.add("<p class='fine'>Plan v" & $fromV & " → v" & $toV & "</p>")
  else:
    result.add("<p class='fine'>" & html(lastReceipt{"message"}.getStr) & "</p>")
  let delta = lastReceipt{"plan_delta"}
  if delta != nil:
    result.add("<div class='small-title'>Étapes ajoutées</div>" &
      deltaList(delta{"added"}, "Aucune"))
    result.add("<div class='small-title'>Étapes retirées</div>" &
      deltaList(delta{"removed"}, "Aucune"))
    result.add("<div class='small-title'>Étapes conservées</div>" &
      deltaList(delta{"kept"}, "Aucune"))
    let dropped = delta{"accepted_steps_dropped"}
    if dropped != nil and dropped.len > 0:
      result.add("<p class='message'>Des étapes déjà acceptées quittent le plan.</p>" &
        deltaList(dropped, ""))
  result.add("</div>")

proc revisePanel(): string =
  if not canRevise() and lastReceipt.isNil: return ""
  let caps = model{"capabilities"}
  let pending = caps{"revise_plan_pending"}.getBool
  result = "<section class='panel revise'><div class='ph'><span>Réviser le plan</span><small>Plan v" &
    $model{"current_plan_version"}.getInt & "</small></div><div class='revise-body'>"
  if pending:
    result.add("<p class='message'>Le moteur demande une révision : " &
      html(caps{"revise_plan_reason"}.getStr) & "</p>")
  let plan = model{"plan_versions"}
  if plan != nil and plan.len > 0:
    let current = plan[plan.len - 1]
    result.add("<p class='fine'><strong>Plan courant</strong> — " &
      html(current{"summary"}.getStr) & "</p>")
  if canRevise():
    result.add("<label class='small-title' for='revise-text'>Précision</label>")
    result.add("<textarea id='revise-text' rows='4' placeholder='Décrire la précision à intégrer…'>" &
      html(draftRefinement) & "</textarea>")
    if reviseStatus.len > 0:
      result.add("<p class='fine' id='revise-status'>" & html(reviseStatus) & "</p>")
    result.add(button("revise-submit",
      if reviseBusy: "Révision en cours…" else: "Soumettre la révision",
      "cta wide", disabled = reviseBusy))
  result.add(receiptPanel())
  result.add("</div></section>")

proc graph(): string =
  let steps = model{"steps"}.getElems
  result = "<section class='panel'><div class='ph'><span>Graphe d’exécution</span><small>Plan v" &
    $model{"current_plan_version"}.getInt & "</small></div><div class='graph'>"
  let refinements = model{"refinements"}.getElems
  let mandate = if refinements.len > 0: refinements[^1].getStr else: model{"objective"}.getStr
  result.add("<div class='mandate'><strong>Mandat du projet</strong>" & html(mandate) & "</div><div class='steps-grid'>")
  var dependencies = 0
  for step in steps:
    let id = step{"id"}.getStr
    let deps = step{"depends_on"}.getElems.mapIt(it.getStr)
    dependencies += deps.len
    let cls = if id == selection: "node selected" else: "node"
    result.add("<button class='" & cls & "' data-action='step' id='step-" & html(id) &
      "' data-step='" & html(id) & "' aria-pressed='" & $(id == selection) &
      "'><strong class='display-label'>" & html(step{"title"}.getStr(id)) & "</strong><code>" & html(id) & "</code>")
    if deps.len > 0:
      result.add("<span class='dependency'>← " & html(deps.join(", ")) & "</span>")
    let state = step{"status"}.getStr
    let stateClass = if state in ["blocked", "interrupted"]: "st attn" else: "st"
    result.add("<span class='" & stateClass & "'>" & html(stateLabel(state)) & "</span></button>")
  if steps.len == 0: result.add("<p class='fine'>Le projet ne contient encore aucune étape.</p>")
  result.add("</div></div><div class='strip'><span>Étapes · " & $steps.len & "</span><span>Dépendances · " & $dependencies & "</span></div></section>")

proc inspector(step: JsonNode): string =
  if step.isNil: return ""
  let provider = step{"provider","status"}.getStr
  result = "<aside class='panel inspect'><div class='inspect-head'><div class='kicker'>INSPECTEUR</div><h2 class='display-label'>" &
    html(step{"title"}.getStr(selection)) & "</h2></div><div class='inspect-body'><div class='rows'>" &
    detailLine("État", stateLabel(step{"status"}.getStr)) & detailLine("Mandat", step{"mandate_key"}.getStr) &
    detailLine("Route", step{"provider","route"}.getStr) & detailLine("Fichier", step{"change","target_file"}.getStr) &
    detailLine("Arbre accepté", step{"accepted_tree_hash"}.getStr) & "</div>"
  if provider == "unknown": result.add("<p class='message'>Issue fournisseur inconnue.</p>")
  let dependencies = step{"depends_on"}.getElems
  if dependencies.len > 0:
    result.add("<div class='small-title'>Prérequis</div><div class='prerequisites'>")
    for dep in dependencies:
      let id = dep.getStr
      result.add("<button class='hlink' data-action='prerequisite' data-step='" &
        html(id) & "'>" & html(id) & "</button>")
    result.add("</div>")
  if step{"verify"} != nil:
    result.add("<p class='small-title'>Vérification</p><p class='fine'>" & html(step{"verify","message"}.getStr) & "</p>")
  if view != ide and step.hasIde: result.add(button("open-ide","Ouvrir dans l’IDE →","cta wide"))
  elif view == ide: result.add(button("back-flow","Revenir au workflow ←","secondary wide"))
  result.add("</div></aside>")

proc journal(): string =
  let events = model{"events"}.getElems
  result = "<section class='panel journal'><div class='ph'><span>Journal d’exécution</span>"
  if events.len > 4: result.add(button("journal", if showAllEvents: "Réduire" else: "Voir les " & $events.len & " derniers", "more"))
  result.add("</div>")
  if events.len == 0: result.add("<p class='pane-body fine'>Aucun événement enregistré.</p>")
  for i in countdown(events.high, if showAllEvents: 0 else: max(0, events.len-4)):
    let e = events[i]
    result.add("<div class='ev'><span class='evnum'>" & $e{"seq"}.getBiggestInt &
      "</span><strong class='display-label'>" & html(e{"kind"}.getStr) & "</strong><span class='evkind'>" &
      html(e{"step_id"}.getStr) & "</span></div>")
  result.add("</section>")

proc planHistory(): string =
  result = "<section class='plan-list'>"
  for p in model{"plan_versions"}.getElems:
    result.add("<article class='panel planbox'><div class='kicker'>PLAN V" & $p{"version"}.getInt &
      "</div><h3>" & html(p{"summary"}.getStr) & "</h3><ol>")
    for s in p{"steps"}.getElems: result.add("<li>" & html(s{"title"}.getStr) & "</li>")
    result.add("</ol></article>")
  result.add("</section>")

proc editor(step: JsonNode): string =
  if not step.hasIde:
    let message = if step.isNil: "Les fichiers apparaîtront à la première modification du projet."
                  else: "Cette étape ne fournit encore aucun changement de fichier ni reçu de vérification."
    return "<section class='panel'><div class='ph'>Fichiers du projet</div><p class='pane-body fine'>" &
      message & "</p></section>"
  if not step.hasTab(tab):
    for option in [diff, receipt, source]:
      if step.hasTab(option):
        tab = option
        break
  result = "<section class='panel'><div class='ph'><span>Fichier de l’étape</span><small>" &
    html(step{"accepted_tree_hash"}.getStr) & "</small></div><div class='filebar'>" &
    html(step{"change","target_file"}.getStr) & "<div class='seg'>"
  for (key, label) in [(diff,"Diff"),(source,"Code"),(receipt,"Vérification")]:
    if step.hasTab(key): result.add(button($key,label,"",tab == key))
  result.add("</div></div>")
  case tab
  of diff, source:
    let code = if tab == diff: step{"readable_diff"}.getStr else: sourceText
    if tab == source and sourceMsg.len > 0:
      result.add("<p class='pane-body'>" & html(sourceMsg) & "</p>")
    else:
      result.add("<div tabindex='0' class='editor' aria-label='Contenu'>")
      var i = 0
      for line in code.splitLines:
        inc i
        let cls = if tab == diff and line.startsWith("+"): " plus" elif tab == diff and line.startsWith("-"): " minus" else: ""
        result.add("<div class='ln" & cls & "'><i>" & $i & "</i><span>" & html(line) & "</span></div>")
      result.add("</div>")
  of receipt:
    let check = step["verify"]
    result.add("<div class='pane-body'><h3>" & html(check{"kind"}.getStr("Vérification")) & "</h3><p>" &
      html(check{"message"}.getStr) & "</p>")
    for (key,label) in [("list_out","Sortie liste"),("csv_out","Sortie CSV")]:
      if check{key}.getStr.len > 0: result.add("<p class='small-title'>" & label & "</p><pre class='log'>" & html(check[key].getStr) & "</pre>")
    result.add("</div>")
  result.add("</section>")

proc render() =
  if model.isNil: return
  captureDraft()
  let focus = $activeId()
  let step = selected()
  let hasPlans = model{"plan_versions"}.getElems.len > 0
  if not hasPlans and view == plans: view = workflow
  put("modes", button("workflow","Workflow","",view != ide) & button("ide","IDE","",view == ide))
  put("sidebar", button("overview","Exécution","",view == workflow) &
    (if hasPlans: button("plans","Versions du plan","",view == plans) else: ""))
  let foot = getElementById("session-foot")
  if foot != nil:
    foot.textContent = cstring(if canWrite: "Commandes locales" else: "Consultation en direct")
  let project = model{"project_id"}.getStr
  getElementById("project-name").textContent = cstring(project)
  let title = case view
    of workflow: "Workflow du projet"
    of ide: "Atelier de code"
    of plans: "Versions du plan"
  let hero = "<div class='hero'><div><div class='crumb'>" & html(project) &
    "</div><h1>" & title & "</h1><p class='sub'>" & html(model{"objective"}.getStr) & "</p></div></div>"
  let body = case view
    of workflow: "<div class='body-grid'><div>" & graph() & revisePanel() & journal() & "</div>" & inspector(step) & "</div>"
    of ide: "<div class='body-grid'><div>" & editor(step) & "</div>" & inspector(step) & "</div>"
    of plans: planHistory()
  put("app", hero & body)
  if focus.len > 0:
    let element = getElementById(cstring(focus))
    if element != nil: element.focus()

proc loadSource() =
  let step = selected()
  if not step.hasTab(source): return
  resetSource()
  let serial = sourceRequest
  sourceMsg = "Lecture du fichier…"
  let req = newGet()
  let url = "/api/source?step=" & $uriPart(cstring(selection)) &
    "&tree=" & $uriPart(cstring(step{"accepted_tree_hash"}.getStr))
  req.open("GET", cstring(url))
  req.timeout = 6000
  proc finish() =
    if serial != sourceRequest: return
    sourceMsg = "Source indisponible pour cet arbre."
    if req.status == 200:
      try:
        sourceText = parseJson($req.responseText)["text"].getStr
        sourceMsg = ""
      except CatchableError: discard
    render()
  req.onload = finish
  req.onerror = finish
  req.ontimeout = finish
  req.send()

proc refresh() =
  if pendingRefresh: return
  pendingRefresh = true
  let req = newGet()
  req.open("GET","/api/snapshot")
  req.timeout = 6000
  proc unavailable() =
    pendingRefresh = false
    getElementById("connection").textContent = "Connexion interrompue"
    if model.isNil: put("app","<p>Projet indisponible. Nouvelle lecture automatique…</p>")
  req.onerror = unavailable
  req.ontimeout = unavailable
  req.onload = proc() =
    if req.status != 200:
      unavailable()
      return
    pendingRefresh = false
    getElementById("connection").textContent = "Lecture en direct"
    let body = $req.responseText
    let available = $req.header("X-Studio-Sources") == "1"
    let writes = $req.header("X-Studio-Writes") == "1"
    if body == lastBody and available == canReadSources and writes == canWrite: return
    try:
      let next = parseJson(body)
      if next{"schema"}.getStr != "nimfactory.studio/v1":
        unavailable()
        return
      let previous = if model == nil: nil else: selected()
      let previousId = selection
      let previousTree = previous{"accepted_tree_hash"}.getStr
      model = next
      canReadSources = available
      canWrite = writes
      if selected().isNil:
        let steps = model{"steps"}.getElems
        selection = if steps.len > 0: steps[0]{"id"}.getStr else: ""
      let tree = selected(){"accepted_tree_hash"}.getStr
      if tree != previousTree or selection != previousId:
        resetSource()
        if view == ide and tab == source: loadSource()
      lastBody = body
      render()
    except CatchableError: unavailable()
  req.send()

proc submitRevise() =
  if reviseBusy or not canRevise(): return
  captureDraft()
  if draftRefinement.strip.len == 0:
    reviseStatus = "Saisir une précision avant de soumettre."
    render()
    return
  if activeCommandId.len == 0:
    activeCommandId = $mintCommandId()
  reviseBusy = true
  reviseStatus = "Envoi de la révision…"
  render()
  let payload = %*{
    "command": "revise_plan",
    "project_id": model{"project_id"}.getStr,
    "expected_plan_version": model{"current_plan_version"}.getInt,
    "refinement": draftRefinement,
    "command_id": activeCommandId
  }
  let req = newGet()
  req.open("POST", "/api/command")
  req.setRequestHeader("Content-Type", "application/json")
  req.timeout = 120000
  proc finish() =
    reviseBusy = false
    try:
      lastReceipt = parseJson($req.responseText)
    except CatchableError:
      lastReceipt = %*{
        "ok": false, "verdict": "transport_error",
        "message": "Réponse illisible du serveur",
        "from_version": model{"current_plan_version"}.getInt,
        "to_version": model{"current_plan_version"}.getInt
      }
    if lastReceipt{"ok"}.getBool:
      reviseStatus = "Plan révisé."
      draftRefinement = ""
      activeCommandId = ""
      lastBody = ""
      refresh()
      ## refresh→render may re-read the old textarea before it is replaced.
      draftRefinement = ""
      render()
    else:
      reviseStatus = lastReceipt{"message"}.getStr
      if lastReceipt{"verdict"}.getStr != "command_active":
        ## Keep the same command_id only while the attempt is still open.
        if lastReceipt{"verdict"}.getStr in ["stale_plan_version"]:
          activeCommandId = ""
      render()
  req.onload = finish
  req.onerror = finish
  req.ontimeout = finish
  req.sendBody(cstring($payload))

document.addEventListener("click", proc(e: Event) =
  let target = actionTarget(e.target)
  if target.isNil or model.isNil: return
  case $target.getAttribute("data-action")
  of "ide", "open-ide":
    view = ide
    if tab == source or (not selected().hasTab(diff) and not selected().hasTab(receipt)): loadSource()
  of "workflow", "overview", "back-flow": view = workflow
  of "plans": view = plans
  of "step", "prerequisite":
    let wanted = $target.getAttribute("data-step")
    if not model{"steps"}.getElems.anyIt(it{"id"}.getStr == wanted): return
    view = workflow
    selection = wanted
    tab = diff
    resetSource()
  of "journal": showAllEvents = not showAllEvents
  of "diff": tab = diff
  of "receipt": tab = receipt
  of "source":
    tab = source
    loadSource()
  of "revise-submit":
    submitRevise()
    return
  else: return
  render()
)
refresh()
discard setInterval(refresh, 2000)
