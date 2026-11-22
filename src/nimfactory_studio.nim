## Native loopback companion to nimfactory. Built by the "studio" Nimble task.
import std/[asynchttpserver, asyncdispatch, httpcore, os, strutils, json, uri]
import nimfactory/application/project_view
import nimfactory/application/project_command
import nimfactory/project/pipeline
import nimfactory/studio/sources

const
  sourceDir = currentSourcePath().parentDir
  html = staticRead(sourceDir / "nimfactory/studio/shell.html")
  css = staticRead(sourceDir / "nimfactory/studio/studio.css")
  client = staticRead(sourceDir / "../build/studio/client.js")

type Config = object
  store, project, trees, cwd, route, inject, artifactDir: string
  port: int

proc options(): Config =
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["-h", "--help"]:
    quit("nimfactory-studio --store PATH --project-id ID [--trees DIR] [--port N] " &
         "[--cwd DIR] [--route api|inject] [--inject PATH] [--artifact-dir DIR]", 0)
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
    of "--artifact-dir": result.artifactDir = value
    else: raise newException(ValueError, "Unknown option " & args[i])
    i += 2
  if result.store.len == 0 or result.project.len == 0:
    raise newException(ValueError, "Supply --store PATH and --project-id ID")
  if result.route == "inject" and result.inject.len == 0:
    ## Write commands stay disabled until an inject payload is configured.
    discard

proc localRequest(req: Request): bool =
  let authority = req.headers.getOrDefault("Host").string.toLowerAscii
  let parts = authority.split(':')
  if parts.len notin 1..2 or parts[0] notin ["127.0.0.1", "localhost"]: return false
  if parts.len == 2 and (parts[1].len == 0 or not parts[1].allCharsInSet(Digits)): return false
  let origin = req.headers.getOrDefault("Origin").string
  origin.len == 0 or origin == "http://" & authority

proc baseProjectRequest(config: Config): ProjectRequest =
  result = defaultProjectRequest()
  result.storePath = config.store
  result.projectId = config.project
  result.cwd = config.cwd
  result.route = config.route
  result.injectPath = config.inject
  result.artifactDir = config.artifactDir

proc run(config: Config) =
  discard readProjectView(config.store, config.project)
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
          let snapshot = readProjectView(config.store, config.project)
          headers["X-Studio-Sources"] = if config.trees.len > 0: "1" else: "0"
          let canWrite = config.route == "api" or
            (config.route == "inject" and config.inject.len > 0)
          headers["X-Studio-Writes"] = if canWrite: "1" else: "0"
          reply(Http200, "application/json", $snapshot)
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
        if config.route == "inject" and config.inject.len == 0:
          reply(Http503, "application/json",
            "{\"ok\":false,\"verdict\":\"writes_disabled\",\"message\":\"Studio write route requires --inject\"}")
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
        if command != project_command.RevisePlanCommand:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"unsupported_command\",\"message\":\"Only revise_plan is available\"}")
          return
        if body{"command_id"}.getStr.len == 0:
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"command_id required\"}")
          return
        if not body.hasKey("expected_plan_version"):
          reply(Http400, "application/json",
            "{\"ok\":false,\"verdict\":\"invalid\",\"message\":\"expected_plan_version required\"}")
          return
        var preq = parseStudioCommand(body, baseProjectRequest(config))
        var prep: ProjectReport
        {.cast(gcsafe).}:
          prep = executeRevisePlan(preq)
        let code =
          if prep.ok: Http200
          elif prep.verdict in ["stale_plan_version", "command_active", "invalid", "missing"]:
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
  server.listen(Port(config.port), "127.0.0.1")
  echo "NimFactory Studio  http://127.0.0.1:", config.port
  while true:
    waitFor server.acceptRequest(serveRequest)

when isMainModule:
  try: run(options())
  except CatchableError as error:
    stderr.writeLine(error.msg)
    quit(1)
