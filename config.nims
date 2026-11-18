# Prefer local NimAgent sources during development.
# Override with -d:nimagentSrc=/path or env-free relative vendor pin.
switch("path", "src")

const nimagentSrc {.strdefine.}: string = "vendor/NimAgentLibrary/src"
switch("path", nimagentSrc)
