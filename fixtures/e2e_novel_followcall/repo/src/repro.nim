## Public reproducer — safe to show the model (no oracle assertions).

import ./cart
import ./money

proc demoTwoLineTotal*(): int =
  ## bread×2 + milk×1. Expected cents: 2*120 + 95 = 335.
  let lines = [
    Line(skuId: "bread", qty: 2),
    Line(skuId: "milk", qty: 1)
  ]
  result = cartTotal(lines)

when isMainModule:
  echo "demo_total_cents=", demoTwoLineTotal()
  echo "demo_total_euros=", formatCents(demoTwoLineTotal())
