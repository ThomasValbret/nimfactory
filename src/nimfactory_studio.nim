## Native loopback companion to nimfactory. Built by the "studio" Nimble task.
import std/[asynchttpserver, asyncdispatch, httpcore, os, strutils, json, uri]
import nimfactory/application/project_view
import nimfactory/application/project_command
import nimfactory/project/[pipeline, store]
import nimfactory/studio/sources

const
  sourceDir = currentSourcePath().parentDir
  html = staticRead(sourceDir / "nimfactory/studio/shell.html")
  css = staticRead(sourceDir / "nimfactory/studio/studio.css")
  client = staticRead(sourceDir / "../build/studio/client.js")

type
  Config = object
    store, project, trees, cwd, route, inject, injectDir, artifactDir, objective, refinement: string
    port: int

  WorkerArgs = object
    command: string
    req: ProjectRequest

var workerThreads: seq[Thread[ptr WorkerArgs]]

proc options(): Config =
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["-h", "--help"]:
    quit("nimfactory-studio --store PATH --project-id ID [--trees DIR] [--port N] " &
         "[--cwd DIR] [--route api|inject] [--inject PATH] [--inject-dir DIR] " &
         "[--artifact-dir DIR] [--objective TEXT] [--refinement TEXT]", 0)
  result.port = 8085
  result.route = "inject"
  var i = 0
  while i < args.len:
    if i + 1 == args.len: raise newException(ValueError, "Missing value for " & args[i])
    let value = args[i+1]
    case args[i]
    of "--store": result.store = value
    of "--project-id": result.project = value
    of "--trees":
      if not dirExists(value): raise newException(ValueError, "Unknown trees directory")
      result.trees = expandFilename(value).normalizedPath
    of "--port":
      result.port = parseInt(value)
      if result.port notin 1..65535: raise newException(ValueError, "Invalid port")
    of "--cwd": result.cwd = value
    of "--route": result.route = value
    of "--inject": result.inject = value
    of "--inject-dir": result.injectDir = value
    of "--artifact-dir": result.artifactDir = value
    of "--objective": result.objective = value
    of "--refinement": result.refinement = value
    else: raise newException(ValueError, "Unknown option " & args[i])
    i += 2
  if result.store.len == 0 or result.project.len == 0:
    raise newException(ValueError, "Supply --store PATH and --project-id ID")

proc allowedHosts(): seq[string] =
  result = @["127.0.0.1", "localhost"]
  let extra = getEnv("NIMFACTORY_STUDIO_ALLOW_HOSTS")
  if extra.len > 0:
    for h in extra.split(','):
      let t = h.strip().toLowerAscii
      if t.len > 0: result.add(t)

proc localRequest(req: Request): bool =
  let authority = req.headers.getOrDefault("Host").string.toLowerAscii
  let parts = authority.split(':')
  if parts.len notin 1..2 or parts[0] notin allowedHosts(): return false
  if parts.len == 2 and (parts[1].len == 0 or not parts[1].allCharsInSet(Digits)): return false
  let origin = req.headers.getOrDefault("Origin").string
  origin.len == 0 or origin == "http://" & authority

proc listenAddr(): string =
  let raw = getEnv("NIMFACTORY_STUDIO_BIND")
  if raw.len > 0: return raw
  "127.0.0.1"

proc baseProjectRequest(config: Config): ProjectRequest =
  result = defaultProjectRequest()
  result.storePath = config.store
  result.projectId = config.project
  result.cwd = config.cwd
  result.route = config.route
  result.injectPath = config.inject
  result.injectDir = config.injectDir
  result.artifactDir = config.artifactDir
  result.objective = config.objective
  result.refinement = config.refinement

proc demoWorkerDelayMs(): int =
  ## Optional pause so dual-tab consultation stays observable during inject demos.
  let raw = getEnv("NIMFACTORY_STUDIO_DEMO_DELAY_MS")
  if raw.len == 0: return 0
  try: result = parseInt(raw)
  except CatchableError: result = 0

proc workerThread(args: ptr WorkerArgs) {.thread, gcsafe.} =
  ## Long commands run off the accept loop so GET /api/snapshot stays live.
  ## Caller already claimed command_id; we only perform + finish.
  try:
    let delayMs = demoWorkerDelayMs()
    if delayMs > 0:
      sleep(delayMs)
    var prep: ProjectReport
    var receipt: JsonNode
    {.cast(gcsafe).}:
      prep = performProjectCommand(args.command, args.req)
      receipt = finishPerformedCommand(args.command, args.req, prep)
      let store = openProjectStore(args.req.storePath)
      finishCommandRecord(store, args.req.projectId, args.req.commandId, receipt)
      closeProjectStore(store)
  except CatchableError:
    discard
  finally:
    deallocShared(args)

proc spawnCommand(command: string; preq: ProjectRequest) =
  let args = createShared(WorkerArgs)
  args[] = WorkerArgs(command: command, req: preq)
  workerThreads.add(default(Thread[ptr WorkerArgs]))
  createThread(workerThreads[^1], workerThread, args)

proc writesEnabled(config: Config): bool =
  config.route == "api" or
    (config.route == "inject" and (config.inject.len > 0 or config.injectDir.len > 0))

proc run(config: Config) =
  discard readProjectView(config.store, config.project, allowBootstrap = true,
                          objective = config.objective)
  let server = newAsyncHttpServer()
  proc serveRequest(req: Request) {.async, gcsafe.} =
    var headers = newHttpHeaders({
      "X-Content-Type-Options":"nosniff", "Cache-Control":"no-store",
      "Content-Security-Policy":"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'",
      "Referrer-Policy":"no-referrer"})
    template reply(code: HttpCode; mime, content: string) =
      headers["Content-Type"] = mime
      await req.respond(code, content, headers)
    if not localRequest(req):
      reply(Http403, "text/plain", "Local requests only")
      return
    try:
      case req.reqMethod
      of HttpGet:
        case req.url.path
        of "/": reply(Http200, "text/html; charset=utf-8", html)
        of "/studio.css": reply(Http200, "text/css; charset=utf-8", css)
        of "/studio.js": reply(Http200, "text/javascript; charset=utf-8", client)
        of "/api/snapshot":
          let snapshot = readProjectView(config.store, config.project,
            allowBootstrap = true, objective = config.objective)
          headers["X-Studio-Sources"] = if config.trees.len > 0: "1" else: "0"
          headers["X-Studio-Writes"] = if writesEnabled(config): "1" else: "0"
          reply(Http200, "application/json", $snapshot)
        of "/api/command":
          var commandId: string
          for key, value in decodeQuery(req.url.query):
            if key == "id": commandId = value
          if commandId.len == 0:
            reply(Http400, "application/json",
              "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"id required\"}")
            return
          let receipt = loadCommandReceipt(config.store, config.project, commandId)
          if receipt.isNil or receipt.kind == JNull:
            reply(Http404, "application/json",
              "{\"ok\":false,\"verdict\":\"missing\",\"message\":\"Unknown command_id\"}")
          else:
            ## Readonly retransmit view: historical spend only, no new calls.
            if receipt{"status"}.getStr == "done":
              annotateSpend(receipt, 0, 0, true)
            reply(Http200, "application/json", $receipt)
        of "/api/source":
          var stepId, treeHash: string
          for key, value in decodeQuery(req.url.query):
            case key
            of "step": stepId = value
            of "tree": treeHash = value
            else: discard
          let snapshot = readProjectView(config.store, config.project)
          for step in snapshot["steps"]:
            if step{"id"}.getStr == stepId and treeHash.len > 0 and
               step{"accepted_tree_hash"}.getStr == treeHash:
              let source = readAcceptedSource(config.trees, step)
              if source != nil:
                reply(Http200, "application/json", $source)
                return
          reply(Http404, "text/plain", "Accepted source unavailable")
        else: reply(Http404, "text/plain", "Not found")
      of HttpPost:
        if req.url.path != "/api/command":
          reply(Http404, "text/plain", "Not found")
          return
        if not writesEnabled(config):
          reply(Http503, "application/json",
            "{\"ok\":false,\"verdict\":\"writes_disabled\",\"message\":\"Studio write route requires --inject or --inject-dir\"}")
          return
        if req.body.len > 1_000_000:
          reply(Http413, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"Body too large\"}")
          return
        var body: JsonNode
        try:
          body = parseJson(req.body)
        except CatchableError:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"JSON body required\"}")
          return
        let command = body{"command"}.getStr
        if command notin [AskPlanCommand, RevisePlanCommand, RunCommand, ResumeCommand,
                          PauseAfterStepCommand]:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"unsupported_command\",\"message\":\"Unsupported command\"}")
          return
        if body{"command_id"}.getStr.len == 0:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"command_id required\"}")
          return
        if command == RevisePlanCommand and not body.hasKey("expected_plan_version"):
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"expected_plan_version required\"}")
          return
        var preq = parseStudioCommand(body, baseProjectRequest(config))
        if command == AskPlanCommand and preq.objective.len == 0:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"objective required for ask_plan\"}")
          return
        let existing = loadCommandReceipt(config.store, config.project, preq.commandId)
        if existing != nil and existing.kind != JNull:
          if existing{"status"}.getStr == "done":
            annotateSpend(existing, 0, 0, true)
            reply(Http200, "application/json", $existing)
            return
          if existing{"status"}.getStr == "active":
            reply(Http202, "application/json", $existing)
            return
        let longRunning = command in [RunCommand, ResumeCommand, PauseAfterStepCommand]
        if longRunning:
          var claimedBody: JsonNode
          {.cast(gcsafe).}:
            let storeHandle = openProjectStore(preq.storePath)
            let claimed = claimCommandActive(
              storeHandle, preq.projectId, preq.commandId, command,
              preq.expectedPlanVersion, preq.refinement)
            closeProjectStore(storeHandle)
            case claimed.phase
            of cpDone:
              let prep = reportFromReceipt(claimed.body)
              reply(Http200, "application/json", $prep.report)
              return
            of cpActive:
              reply(Http202, "application/json", $claimed.body)
              return
            of cpFresh, cpAbsent:
              claimedBody = claimed.body
              spawnCommand(command, preq)
          var accepted =
            if claimedBody.isNil or claimedBody.kind != JObject: newJObject()
            else: claimedBody.copy()
          accepted["schema"] = %CommandSchema
          accepted["status"] = %"active"
          accepted["command"] = %command
          accepted["command_id"] = %preq.commandId
          accepted["project_id"] = %preq.projectId
          accepted["accepted"] = %true
          reply(Http202, "application/json", $accepted)
          return
        var prep: ProjectReport
        {.cast(gcsafe).}:
          prep = executeProjectCommand(command, preq)
        let code =
          if prep.ok: Http200
          elif prep.verdict in ["stale_plan_version", "command_active", "invalid",
                                "missing", "already_running"]:
            Http409
          else: Http422
        reply(code, "application/json", $prep.report)
      of HttpOptions:
        headers["Allow"] = "GET, POST, OPTIONS"
        reply(Http204, "text/plain", "")
      else:
        headers["Allow"] = "GET, POST, OPTIONS"
        reply(Http405, "text/plain", "Method not allowed")
    except ProjectMissing:
      reply(Http404, "text/plain", "Project unavailable")
    except CatchableError:
      reply(Http503, "text/plain", "Unable to serve project")
  let bindHost = listenAddr()
  server.listen(Port(config.port), bindHost)
  echo "NimFactory Studio  http://", bindHost, ":", config.port
  while true:
    waitFor server.acceptRequest(serveRequest)

when isMainModule:
  try: run(options())
  except CatchableError as error:
    stderr.writeLine(error.msg)
    quit(1)
