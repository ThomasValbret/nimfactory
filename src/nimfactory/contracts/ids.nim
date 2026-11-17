## Distinct opaque identifier types for NimFactory.
## Do not conflate ArtifactRef with handler/instruction registry refs.

type
  ArtifactRef* = distinct string
  HandlerRef* = distinct string
  InstructionRef* = distinct string
  SkillRef* = distinct string
  SchemaName* = distinct string

  SchemaId* = object
    name*: string
    version*: string

proc `$`*(a: ArtifactRef): string = a.string
proc `$`*(a: HandlerRef): string = a.string
proc `$`*(a: InstructionRef): string = a.string
proc `$`*(a: SkillRef): string = a.string

proc artifactRef*(s: string): ArtifactRef = ArtifactRef(s)
proc handlerRef*(s: string): HandlerRef = HandlerRef(s)
proc instructionRef*(s: string): InstructionRef = InstructionRef(s)
proc skillRef*(s: string): SkillRef = SkillRef(s)

proc `==`*(a, b: ArtifactRef): bool {.borrow.}
proc `==`*(a, b: HandlerRef): bool {.borrow.}
proc `==`*(a, b: InstructionRef): bool {.borrow.}
proc `==`*(a, b: SkillRef): bool {.borrow.}

proc schemaId*(name, version: string): SchemaId =
  SchemaId(name: name, version: version)

proc `$`*(s: SchemaId): string = s.name & "/" & s.version
