# Novel follow-call case (next API lot)

**Not executed with a paid API in the oracle-phase lot.** Reserved for a real
`mission-fix --route api` run with `gpt-4o-mini` when the key/budget allow.

- Pilot symptom: `SYMPTOM.md`
- Public reproducer in context: `repo/src/repro.nim` (+ `cart`, `catalog`, `money`)
- Cause: extra `unit` add after the qty loop in `cart.lineTotal`
- Oracle (private): `oracle/test_cart_total.nim`
- Expected intervention: revise `src/cart.nim` (follow call from `cartTotal` → `lineTotal`)

If the planned API is unavailable at execution time, mark the model decision
untested and keep independent inject/oracle checks.
