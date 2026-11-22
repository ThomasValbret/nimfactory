## Minimal SQLite3 FFI for F3 RunStore (links libsqlite3 dynamically).


const
  SqliteLib* =
    when defined(windows): "sqlite3.dll"
    elif defined(macosx): "libsqlite3.dylib"
    else: "libsqlite3.so.0"

  SQLITE_OK* = 0'i32
  SQLITE_ROW* = 100'i32
  SQLITE_DONE* = 101'i32

type
  SqliteDb* = pointer
  SqliteStmt* = pointer
  SqliteDestructor* = pointer

const SQLITE_TRANSIENT* = cast[SqliteDestructor](-1)

proc sqlite3_open*(filename: cstring, ppDb: ptr SqliteDb): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_open_v2*(filename: cstring, ppDb: ptr SqliteDb, flags: int32, zVfs: cstring): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_close*(db: SqliteDb): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_errmsg*(db: SqliteDb): cstring {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_exec*(
  db: SqliteDb,
  sql: cstring,
  callback: pointer,
  arg: pointer,
  errmsg: ptr cstring
): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_prepare_v2*(
  db: SqliteDb,
  zSql: cstring,
  nByte: int32,
  ppStmt: ptr SqliteStmt,
  pzTail: ptr cstring
): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_bind_text*(
  stmt: SqliteStmt,
  idx: int32,
  val: cstring,
  nByte: int32,
  destructor: SqliteDestructor
): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_bind_int64*(
  stmt: SqliteStmt,
  idx: int32,
  val: int64
): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_step*(stmt: SqliteStmt): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_finalize*(stmt: SqliteStmt): int32 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_column_text*(stmt: SqliteStmt, iCol: int32): cstring {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_column_int64*(stmt: SqliteStmt, iCol: int32): int64 {.cdecl, dynlib: SqliteLib, importc.}
proc sqlite3_changes*(db: SqliteDb): int32 {.cdecl, dynlib: SqliteLib, importc.}

type JournalStorageError* = object of CatchableError

proc sqliteErr*(db: SqliteDb, context: string): string =
  if db != nil:
    let raw = sqlite3_errmsg(db)
    if raw != nil:
      return context & ": " & $raw
  context

proc execSql*(db: SqliteDb, sql: string) =
  let rc = sqlite3_exec(db, sql.cstring, nil, nil, nil)
  if rc != SQLITE_OK:
    raise newException(JournalStorageError, sqliteErr(db, "SQLite exec failed"))

proc runPrepared*(db: SqliteDb, sql: string, params: openArray[string]) =
  var stmt: SqliteStmt = nil
  let prepRc = sqlite3_prepare_v2(db, sql.cstring, int32(sql.len), addr stmt, nil)
  if prepRc != SQLITE_OK:
    raise newException(JournalStorageError, sqliteErr(db, "SQLite prepare failed"))
  defer:
    discard sqlite3_finalize(stmt)
  for i, p in params:
    let bindRc = sqlite3_bind_text(stmt, int32(i + 1), p.cstring, int32(p.len), SQLITE_TRANSIENT)
    if bindRc != SQLITE_OK:
      raise newException(JournalStorageError, sqliteErr(db, "SQLite bind failed"))
  let stepRc = sqlite3_step(stmt)
  if stepRc != SQLITE_DONE:
    raise newException(JournalStorageError, sqliteErr(db, "SQLite step failed"))

proc queryAll*(db: SqliteDb, sql: string, params: openArray[string]): seq[string] =
  var stmt: SqliteStmt = nil
  let prepRc = sqlite3_prepare_v2(db, sql.cstring, int32(sql.len), addr stmt, nil)
  if prepRc != SQLITE_OK:
    raise newException(JournalStorageError, sqliteErr(db, "SQLite query prepare failed"))
  defer:
    discard sqlite3_finalize(stmt)
  for i, p in params:
    let bindRc = sqlite3_bind_text(stmt, int32(i + 1), p.cstring, int32(p.len), SQLITE_TRANSIENT)
    if bindRc != SQLITE_OK:
      raise newException(JournalStorageError, sqliteErr(db, "SQLite query bind failed"))
  while true:
    let stepRc = sqlite3_step(stmt)
    if stepRc == SQLITE_ROW:
      let colPtr = sqlite3_column_text(stmt, 0)
      if colPtr != nil:
        result.add($colPtr)
      else:
        result.add("")
    elif stepRc == SQLITE_DONE:
      break
    else:
      raise newException(JournalStorageError, sqliteErr(db, "SQLite query step failed"))