## Reference fix for lineTotal (kept out of model context).

import ./catalog

type
  Line* = object
    skuId*: string
    qty*: int

proc lineTotal*(line: Line): int =
  let unit = lookupUnitCents(line.skuId)
  var total = 0
  var i = 0
  while i < line.qty:
    total += unit
    inc i
  result = total

proc cartTotal*(lines: openArray[Line]): int =
  var sum = 0
  for line in lines:
    sum += lineTotal(line)
  result = sum
