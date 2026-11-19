# Real unknown-module case (haltcase/glob)

Question: can NimFactory repair a real defect when the pilot can reproduce it
but does not know which module is responsible?

| Item | Value |
| --- | --- |
| Upstream | https://github.com/haltcase/glob |
| Faulty SHA | `589671a897c12398113605193130d1c60ffab282` |
| Fix commit | `1fa54df5fa57e38adc43de2cb050c7748c305047` |
| Layout | original `src/glob.nim` + nested `src/glob/regexer.nim` |

- Pilot symptom: `SYMPTOM.md` (no culprit file)
- Public reproducer: `public/repro.nim` (outside `repo/src`, not in model context)
- Model sources: whatever `buildApiContext` collects under `repo/src/` (must include nested modules)
- Private oracle: `oracle/test_walk_shallow.nim`
- Historical fix / diff / annotations: `reference/` only

Requires the `regex` Nimble package (declared in `repo/glob.nimble`).
