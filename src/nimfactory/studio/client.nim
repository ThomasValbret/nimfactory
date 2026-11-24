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
proc mintCommandId(prefix: cstring): cstring {.importjs: "(# + '-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10))".}

var
  model: JsonNode
  view = workflow
  tab = diff
  selection, lastBody, sourceText, sourceMsg: string
  sourceRequest = 0
  canReadSources, canWrite, pendingRefresh, showAllEvents, commandBusy: bool
  draftRefinement, draftObjective, commandStatus: string
  lastReceipt: JsonNode
  activeCommandId, pendingCommandKind: string

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

proc hasCmd(name: string): bool =
  if model.isNil or not canWrite: return false
  model{"capabilities","commands"}.getElems.anyIt(it.getStr == name)

proc hasTab(step: JsonNode; which: CodeTab): bool =
  if step.isNil: return false
  case which
  of diff: step{"readable_diff"}.getStr.len > 0
  of receipt: step{"verify"} != nil
  of source: canReadSources and step{"accepted_tree_hash"}.getStr.len > 0 and
    step{"change","target_file"}.getStr.len > 0 and step{"change","after_hash"}.getStr.len > 0

proc hasIde(step: JsonNode): bool = step.hasTab(diff) or step.hasTab(source) or step.hasTab(receipt)

proc captureDraft() =
  if getElementById("revise-text") != nil:
    draftRefinement = $fieldValue("revise-text")
  if getElementById("ask-objective") != nil:
    draftObjective = $fieldValue("ask-objective")

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

proc proofList(items: JsonNode; emptyLabel: string): string =
  if items.isNil or items.len == 0:
    return "<p class='fine'>" & html(emptyLabel) & "</p>"
  result = "<ul class='delta'>"
  for item in items:
    var line = "<code>" & html(item{"id"}.getStr) & "</code>"
    if item{"file"}.getStr.len > 0: line.add(" · " & html(item{"file"}.getStr))
    if item{"title"}.getStr.len > 0: line.add(" — " & html(item{"title"}.getStr))
    if item{"reason"}.getStr.len > 0: line.add(" (" & html(item{"reason"}.getStr) & ")")
    result.add("<li>" & line & "</li>")
  result.add("</ul>")

proc receiptPanel(): string =
  if lastReceipt.isNil: return ""
  let ok = lastReceipt{"ok"}.getBool
  let replayed = lastReceipt{"replayed"}.getBool
  let cls = if ok: "receipt ok" else: "receipt bad"
  result = "<div class='" & cls & "'><div class='small-title'>Reçu du moteur</div>"
  result.add("<p><strong>" & html(lastReceipt{"command"}.getStr) & " · " &
    html(lastReceipt{"verdict"}.getStr) & "</strong>")
  if replayed: result.add(" · retransmission")
  result.add("</p>")
  result.add("<p class='fine'>" & html(lastReceipt{"message"}.getStr) & "</p>")
  if lastReceipt.hasKey("from_version"):
    result.add("<p class='fine'>Plan v" & $lastReceipt{"from_version"}.getInt &
      " → v" & $lastReceipt{"to_version"}.getInt & "</p>")
  result.add("<p class='fine'>Appels nouveaux · " & $lastReceipt{"new_provider_calls"}.getInt &
    " · historiques · " & $lastReceipt{"historical_provider_calls"}.getInt &
    " · API nouvelles · " & $lastReceipt{"new_api_calls"}.getInt & "</p>")
  if lastReceipt{"proof_kept"} != nil:
    result.add("<div class='small-title'>Preuves conservées</div>" &
      proofList(lastReceipt{"proof_kept"}, "Aucune"))
  if lastReceipt{"proof_dropped"} != nil:
    result.add("<div class='small-title'>Preuves invalidées</div>" &
      proofList(lastReceipt{"proof_dropped"}, "Aucune"))
  let delta = lastReceipt{"plan_delta"}
  if delta != nil:
    result.add("<div class='small-title'>Étapes ajoutées</div>" & deltaList(delta{"added"}, "Aucune"))
    result.add("<div class='small-title'>Étapes retirées</div>" & deltaList(delta{"removed"}, "Aucune"))
  if lastReceipt{"blocked"} != nil:
    result.add("<p class='message'>Blocage · " &
      html(lastReceipt{"blocked","kind"}.getStr) & " · " &
      html(lastReceipt{"blocked","message"}.getStr) & "</p>")
  result.add("</div>")

proc statusStrip(): string =
  let wf = model{"workflow"}
  let cost = model{"cost"}
  let active = wf{"active_step"}
  let decision = wf{"next_decision"}.getStr
  let proposal = wf{"engine_proposal"}.getStr
  result = "<section class='panel status-strip'><div class='ph'><span>Situation</span><small>" &
    html(if model{"run_lease","status"}.getStr == "active": "Worker actif" else: "Observateur") &
    "</small></div><div class='status-grid'>"
  result.add("<div><div class='small-title'>Objectif</div><p>" &
    html(wf{"objective"}.getStr(model{"objective"}.getStr)) & "</p></div>")
  result.add("<div><div class='small-title'>Étape active</div><p>" &
    (if active.isNil or active.kind == JNull: "—"
     else: html(active{"title"}.getStr) & " <code>" & html(active{"id"}.getStr) &
           "</code> · " & html(stateLabel(active{"status"}.getStr))) & "</p></div>")
  result.add("<div><div class='small-title'>Preuve obtenue</div>")
  result.add(proofList(wf{"obtained_proofs"}, "Aucune preuve acceptée"))
  result.add("</div><div><div class='small-title'>En attente de vérification</div>")
  result.add(proofList(wf{"awaiting_verification"}, "Rien en attente"))
  result.add("</div><div><div class='small-title'>Coût connu</div><p>" &
    $(if cost.isNil: 0.0 else: cost{"estimated_usd"}.getFloat) & " USD · " &
    $(if cost.isNil: 0 else: cost{"calls"}.getInt) & " appels</p></div>")
  result.add("<div><div class='small-title'>Prochaine décision</div><p><strong>" &
    html(decision) & "</strong>")
  if proposal.len > 0: result.add("<br><span class='fine'>" & html(proposal) & "</span>")
  result.add("</p></div>")
  let ev = wf{"engine_verdict"}
  if ev != nil:
    result.add("<div><div class='small-title'>Verdict moteur</div><p><strong>" &
      html(ev{"last_verdict"}.getStr(model{"last_verdict"}.getStr)) & "</strong>")
    if ev{"output_incorrect"}.getBool:
      result.add("<br><span class='message'>Sortie non vide incorrecte · " &
        html(ev{"incorrect_detail"}.getStr) & "</span>")
    elif ev{"proposal"}.getStr.len > 0 and ev{"proposal"}.getStr != proposal:
      result.add("<br><span class='fine'>" & html(ev{"proposal"}.getStr) & "</span>")
    result.add("</p></div>")
  result.add("</div>")
  if commandStatus.len > 0:
    result.add("<p class='fine' id='command-status'>" & html(commandStatus) & "</p>")
  result.add("<div class='command-bar'>")
  if hasCmd("run"):
    result.add(button("run", if commandBusy and pendingCommandKind == "run": "Lancement…" else: "Lancer",
      "cta", disabled = commandBusy))
  if hasCmd("pause_after_step"):
    result.add(button("pause-after-step",
      if commandBusy and pendingCommandKind == "pause_after_step": "Pause…" else: "Pause après l’étape",
      "secondary", disabled = commandBusy))
  if hasCmd("resume"):
    result.add(button("resume",
      if commandBusy and pendingCommandKind == "resume": "Reprise…" else: "Reprendre",
      "secondary", disabled = commandBusy))
  result.add("</div></section>")

proc newProjectPanel(): string =
  ## Parcours « Nouveau projet → demande → aperçu local ».
  if not hasCmd("ask_plan") and not model{"bootstrap"}.getBool: return ""
  result = "<section class='panel revise'><div class='ph'><span>Nouveau projet</span><small>Demande → aperçu local</small></div><div class='revise-body'>"
  result.add("<p class='fine'>Le squelette démarre le projet. La demande produit un aperçu local du plan, sans lancer d’étapes.</p>")
  result.add("<label class='small-title' for='ask-objective'>Demande</label>")
  result.add("<textarea id='ask-objective' rows='4' placeholder='Décrire l’objectif du projet…'>" &
    html(if draftObjective.len > 0: draftObjective else: model{"objective"}.getStr) & "</textarea>")
  result.add(button("ask-submit",
    if commandBusy and pendingCommandKind == "ask_plan": "Aperçu…" else: "Obtenir l’aperçu local",
    "cta wide", disabled = commandBusy))
  if model{"current_plan_version"}.getInt >= 1:
    result.add("<div class='small-title'>Aperçu local · plan v" &
      $model{"current_plan_version"}.getInt & "</div>")
    result.add("<p class='fine'>next_action · " & html(model{"next_action"}.getStr) &
      " · verdict · " & html(model{"last_verdict"}.getStr) & "</p>")
  if lastReceipt != nil and lastReceipt{"command"}.getStr == "ask_plan":
    result.add(receiptPanel())
    let preview = lastReceipt{"preview"}
    if preview != nil:
      result.add("<div class='small-title'>Étapes proposées</div>")
      result.add(deltaList(preview{"steps"}, "Aucune étape"))
  result.add("</div></section>")

proc revisePanel(): string =
  if not hasCmd("revise_plan") and lastReceipt.isNil: return ""
  let caps = model{"capabilities"}
  result = "<section class='panel revise'><div class='ph'><span>Réviser le plan</span><small>Plan v" &
    $model{"current_plan_version"}.getInt & "</small></div><div class='revise-body'>"
  if caps{"revise_plan_pending"}.getBool or caps{"recovery_exhausted"}.getBool:
    result.add("<p class='message'>" & html(caps{"revise_plan_reason"}.getStr(
      caps{"recovery_exhausted_reason"}.getStr)) & "</p>")
  if hasCmd("revise_plan"):
    result.add("<label class='small-title' for='revise-text'>Précision</label>")
    result.add("<textarea id='revise-text' rows='4' placeholder='Décrire la précision à intégrer…'>" &
      html(draftRefinement) & "</textarea>")
    result.add(button("revise-submit",
      if commandBusy and pendingCommandKind == "revise_plan": "Révision…" else: "Soumettre la révision",
      "cta wide", disabled = commandBusy))
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
    detailLine("Arbre accepté", step{"accepted_tree_hash"}.getStr) &
    detailLine("Refus", step{"refuse_code"}.getStr) & "</div>"
  if provider == "unknown": result.add("<p class='message'>Issue fournisseur inconnue.</p>")
  if step{"change_origin"} != nil:
    let origin = step["change_origin"]
    result.add("<div class='small-title'>Changement du builder</div><p class='fine'>" &
      html(origin{"target_file"}.getStr) &
      (if origin{"route"}.getStr.len > 0: " · route " & html(origin{"route"}.getStr) else: "") &
      (if origin{"before_hash"}.getStr.len > 0:
         " · " & html(origin{"before_hash"}.getStr) & " → " & html(origin{"after_hash"}.getStr)
       else: "") & "</p>")
  if step{"served_tree"} != nil and step{"served_tree","hash"}.getStr.len > 0:
    result.add("<div class='small-title'>Arbre prévisualisé (recalculé)</div><p class='fine'><code>" &
      html(step{"served_tree","hash"}.getStr) & "</code> · " &
      $step{"served_tree","file_count"}.getInt & " fichiers</p>")
  elif step{"accepted_tree_hash"}.getStr.len > 0:
    result.add("<div class='small-title'>Arbre accepté</div><p class='fine'><code>" &
      html(step{"accepted_tree_hash"}.getStr) & "</code></p>")
  if step{"controls_executed"} != nil and step{"controls_executed"}.len > 0:
    result.add("<div class='small-title'>Contrôles du projet</div><ul class='delta'>")
    for c in step{"controls_executed"}:
      let st = c{"status"}.getStr
      let label =
        if st == "passed": "passé"
        elif st == "failed": "échec"
        elif st in ["not_run", "unexecuted"]: "non exécuté"
        elif c{"ok"}.getBool: "ok"
        else: "échec"
      var obs = c{"message"}.getStr
      let observation = c{"observation"}
      if obs.len == 0 and observation != nil:
        if observation.kind == JObject: obs = $observation
        else: obs = observation.getStr
      result.add("<li><code>" & html(c{"name"}.getStr) & "</code> · " & html(label) &
        (if obs.len > 0: " — " & html(obs) else: "") & "</li>")
    result.add("</ul>")
  if step{"verify"} != nil:
    result.add("<p class='small-title'>Vérification</p><p class='fine'>" & html(step{"verify","message"}.getStr) & "</p>")
    if step{"output_incorrect"}.getBool:
      result.add("<p class='message'>Contrôle en échec · " &
        html(step{"verify","message"}.getStr) & "</p>")
  let proposal = model{"workflow","engine_proposal"}.getStr
  let activeStatus = step{"status"}.getStr
  if (activeStatus in ["blocked", "interrupted"] or
      model{"last_verdict"}.getStr == "verify_failed") and proposal.len > 0:
    result.add("<p class='message'>Proposition du moteur · " & html(proposal) & "</p>")
  let afterFail = model{"workflow","after_failure"}
  if afterFail != nil and afterFail.len > 0:
    var acts: seq[string] = @[]
    for a in afterFail: acts.add(a.getStr)
    result.add("<p class='message'>Conduite après échec · " & html(acts.join(", ")) & "</p>")
  result.add("<p class='fine'>Verdict · " & html(model{"last_verdict"}.getStr) &
    " · dépense " & $(if model{"cost"}.isNil: 0.0 else: model{"cost","estimated_usd"}.getFloat) &
    " USD</p>")
  if view != ide and step.hasIde:
    result.add(button("open-ide-diff","Ouvrir le diff →","cta wide"))
    if step.hasTab(receipt):
      result.add(button("open-ide-verify","Ouvrir la vérification →","secondary wide"))
  elif view == ide:
    result.add(button("back-flow","Revenir au workflow ←","secondary wide"))
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
    if step{"controls_executed"} != nil and step{"controls_executed"}.len > 0:
      result.add("<p class='small-title'>Contrôles</p><ul class='delta'>")
      for c in step{"controls_executed"}:
        let st = c{"status"}.getStr
        result.add("<li><code>" & html(c{"name"}.getStr) & "</code> · " &
          html(if st.len > 0: st elif c{"ok"}.getBool: "passed" else: "failed") & "</li>")
      result.add("</ul>")
    if step{"served_tree","hash"}.getStr.len > 0:
      result.add("<p class='small-title'>Identité arbre servi</p><pre class='log'>" &
        html(step{"served_tree","hash"}.getStr) & "</pre>")
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
    foot.textContent = cstring(
      if model{"run_lease","status"}.getStr == "active": "Worker en cours — consultation libre"
      elif canWrite: "Commandes locales"
      else: "Consultation en direct")
  let project = model{"project_id"}.getStr
  getElementById("project-name").textContent = cstring(project)
  let title = case view
    of workflow: "Workflow du projet"
    of ide: "Atelier de code"
    of plans: "Versions du plan"
  let hero = "<div class='hero'><div><div class='crumb'>" & html(project) &
    "</div><h1>" & title & "</h1><p class='sub'>" & html(model{"objective"}.getStr) & "</p></div></div>"
  let body = case view
    of workflow: "<div class='body-grid'><div>" & statusStrip() & newProjectPanel() &
      graph() & revisePanel() & journal() &
      "</div>" & inspector(step) & "</div>"
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

proc refresh()
proc pollCommandReceipt()

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
    if body == lastBody and available == canReadSources and writes == canWrite:
      if commandBusy: pollCommandReceipt()
      return
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
      if commandBusy: pollCommandReceipt()
    except CatchableError: unavailable()
  req.send()

proc pollCommandReceipt() =
  if activeCommandId.len == 0: return
  let req = newGet()
  req.open("GET", cstring("/api/command?id=" & $uriPart(cstring(activeCommandId))))
  req.timeout = 6000
  req.onload = proc() =
    if req.status != 200: return
    try:
      let receipt = parseJson($req.responseText)
      if receipt{"status"}.getStr == "done" or receipt.hasKey("ok"):
        lastReceipt = receipt
        commandBusy = false
        commandStatus =
          if receipt{"replayed"}.getBool: "Reçu rejoué — aucun nouvel appel."
          else: "Commande terminée · " & receipt{"verdict"}.getStr
        activeCommandId = ""
        pendingCommandKind = ""
        lastBody = ""
        refresh()
    except CatchableError: discard
  req.onerror = proc() = discard
  req.ontimeout = proc() = discard
  req.send()

proc postCommand(kind: string; extra: JsonNode = nil) =
  if commandBusy or not canWrite: return
  if not hasCmd(kind) and kind notin ["revise_plan", "ask_plan"]: return
  activeCommandId = $mintCommandId(cstring("studio-" & kind))
  pendingCommandKind = kind
  commandBusy = true
  commandStatus = "Commande acceptée — le plan reste consultable."
  render()
  var payload = %*{
    "command": kind,
    "project_id": model{"project_id"}.getStr,
    "command_id": activeCommandId,
    "expected_plan_version": model{"current_plan_version"}.getInt
  }
  if extra != nil:
    for k, v in extra.pairs: payload[k] = v
  let req = newGet()
  req.open("POST", "/api/command")
  req.setRequestHeader("Content-Type", "application/json")
  req.timeout = 120000
  proc finish() =
    try:
      lastReceipt = parseJson($req.responseText)
    except CatchableError:
      lastReceipt = %*{"ok": false, "verdict": "transport_error", "message": "Réponse illisible",
                       "new_provider_calls": 0, "historical_provider_calls": 0}
    if req.status == 202 or lastReceipt{"status"}.getStr == "active":
      commandStatus = "Worker lancé — consultation libre pendant l’exécution."
      render()
      pollCommandReceipt()
      return
    commandBusy = false
    if lastReceipt{"ok"}.getBool or lastReceipt{"replayed"}.getBool:
      commandStatus =
        if lastReceipt{"replayed"}.getBool: "Reçu rejoué — dépense historique seule."
        else: "Commande terminée."
      if kind == "revise_plan": draftRefinement = ""
      activeCommandId = ""
      pendingCommandKind = ""
      lastBody = ""
      refresh()
      if kind == "revise_plan":
        draftRefinement = ""
        render()
    else:
      commandStatus = lastReceipt{"message"}.getStr
      if lastReceipt{"verdict"}.getStr in ["stale_plan_version", "already_running"]:
        activeCommandId = ""
        pendingCommandKind = ""
      render()
  req.onload = finish
  req.onerror = finish
  req.ontimeout = finish
  req.sendBody(cstring($payload))

proc submitRevise() =
  captureDraft()
  if draftRefinement.strip.len == 0:
    commandStatus = "Saisir une précision avant de soumettre."
    render()
    return
  postCommand("revise_plan", %*{"refinement": draftRefinement})

proc submitAsk() =
  captureDraft()
  if draftObjective.strip.len == 0:
    commandStatus = "Saisir une demande avant l’aperçu local."
    render()
    return
  postCommand("ask_plan", %*{"objective": draftObjective})

proc openIde(which: CodeTab) =
  view = ide
  tab = which
  if which == source: loadSource()
  render()

document.addEventListener("click", proc(e: Event) =
  let target = actionTarget(e.target)
  if target.isNil or model.isNil: return
  case $target.getAttribute("data-action")
  of "ide", "open-ide":
    openIde(if selected().hasTab(diff): diff elif selected().hasTab(receipt): receipt else: source)
    return
  of "open-ide-diff":
    openIde(diff)
    return
  of "open-ide-verify":
    openIde(receipt)
    return
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
  of "ask-submit":
    submitAsk()
    return
  of "run":
    postCommand("run")
    return
  of "pause-after-step":
    postCommand("pause_after_step", %*{"pause_after_step": true})
    return
  of "resume":
    postCommand("resume")
    return
  else: return
  render()
)
refresh()
discard setInterval(refresh, 2000)
