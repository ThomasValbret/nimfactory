## Shopping cart aggregation. Calls into catalog for unit prices.

import ./catalog

type
  Line* = object
    skuId*: string
    qty*: int

proc lineTotal*(line: Line): int =
  ## Intended: unit price × quantity.
  ## Current: adds the unit price one extra time after the loop.
  let unit = lookupUnitCents(line.skuId)
  var total = 0
  var i = 0
  while i < line.qty:
    total += unit
    inc i
  total += unit
  result = total

proc cartTotal*(lines: openArray[Line]): int =
  var sum = 0
  for line in lines:
    sum += lineTotal(line)
  result = sum
