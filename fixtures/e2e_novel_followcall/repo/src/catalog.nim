## Catalog prices in cents.

type
  Sku* = object
    id*: string
    unitCents*: int

proc sku*(id: string; unitCents: int): Sku =
  Sku(id: id, unitCents: unitCents)

proc lookupUnitCents*(id: string): int =
  case id
  of "bread": 120
  of "milk": 95
  of "eggs": 210
  else: 0
