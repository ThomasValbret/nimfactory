# Provenance — haltcase/glob leading shallow magic

- Repository: https://github.com/haltcase/glob
- Bug report: https://github.com/haltcase/glob/issues/29
- Fix commit: https://github.com/haltcase/glob/commit/1fa54df5fa57e38adc43de2cb050c7748c305047
- Pre-fix (faulty) SHA: `589671a897c12398113605193130d1c60ffab282`
- Pre-fix URL: https://github.com/haltcase/glob/commit/589671a897c12398113605193130d1c60ffab282
- Parent of fix (= faulty tip used as fixture): same as above

Keep this directory, the historical diff, and the fixed body **out of model context**.
The public symptom and `repo/src/**` alone are authorized for `buildApiContext`.

Historical cause (do not put in SYMPTOM.md): `walkGlobKinds` only descended when
`**` was present (`isRec`), so a one-level pattern like `*/a.txt` never entered
sibling directories and returned an empty match list.
