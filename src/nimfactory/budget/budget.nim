## F14 budget module — public exports.

import ./types
export types

import ./file_ledger
export file_ledger

proc defineNestedScopes*(l: FileBudgetLedger; leafScope: string;
                          ceilingMicroUsd: string; maxSends: int) =
  ## Register every prefix of leafScope with the same ceiling (typical run setup).
  for sp in scopeChain(leafScope):
    l.defineScope(sp, ceilingMicroUsd, maxSends)