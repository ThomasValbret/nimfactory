import nimagent/[normalization,messages]
import std/json
for s in ["""{ "x":"a", }""", """{ /*c*/ "x":"a" }""", "{\"x\":\"a\nb\"}", """{"x":01}""", """{"x":NaN}""", """{"x":"\x61"}"""]:
  let r = defaultNormalization().normalizeCall(ToolCall(name:"n",arguments:s), %*{"type":"object"})
  echo %*[s,r.refusal]
