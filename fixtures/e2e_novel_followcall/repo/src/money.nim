## Currency helpers used by the checkout path.

proc cents*(euros: int): int =
  euros * 100

proc formatCents*(cents: int): string =
  let sign = if cents < 0: "-" else: ""
  let v = if cents < 0: -cents else: cents
  let whole = v div 100
  let frac = v mod 100
  result = sign & $whole & "." & (if frac < 10: "0" & $frac else: $frac)
