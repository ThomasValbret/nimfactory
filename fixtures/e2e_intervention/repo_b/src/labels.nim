import ./textutil

const GuestLabel* = "guest"

proc formatUserLabel*(name: string): string =
  result = trimText(name)
