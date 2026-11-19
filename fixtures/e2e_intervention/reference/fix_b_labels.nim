import ./textutil

const GuestLabel* = "guest"

proc formatUserLabel*(name: string): string =
  if isBlank(name):
    return GuestLabel
  result = trimText(name)
