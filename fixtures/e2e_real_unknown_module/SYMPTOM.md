When matching files with a one-level glob from a directory that contains
several sibling folders, the walk returns no hits.

Command (package sources on `--path`, reproducer beside the package):

```
nim c -r --hints:off --warnings:off --path:repo/src public/repro.nim
```

Input filesystem under a temporary root:

- `foo/a.txt`
- `bar/a.txt`
- `baz/a.txt`

Pattern: `*/a.txt`

Observed output:

```
observed=@[]
```

Expected output (order may vary; the three paths must all appear):

```
observed=@["bar/a.txt", "baz/a.txt", "foo/a.txt"]
```

The public entry point that performs the walk lives in this package and calls
into other modules for pattern compilation. The responsible module is unknown
to the pilot.
