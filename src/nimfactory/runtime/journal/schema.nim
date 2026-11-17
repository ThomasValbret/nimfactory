## SQLite schema for NimFactory RunStore (F3).

import ./sqlite_ffi

const schemaStatements* = @[
  "PRAGMA journal_mode=WAL;",
  "CREATE TABLE IF NOT EXISTS nf_runs (" &
    "run_id TEXT PRIMARY KEY, " &
    "epoch INTEGER NOT NULL DEFAULT 1, " &
    "owner_token TEXT NOT NULL DEFAULT '', " &
    "state_json TEXT NOT NULL DEFAULT '{}', " &
    "event_seq INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE IF NOT EXISTS nf_events (" &
    "run_id TEXT NOT NULL, " &
    "seq INTEGER NOT NULL, " &
    "message_id TEXT, " &
    "event_json TEXT NOT NULL, " &
    "PRIMARY KEY (run_id, seq))",
  "CREATE UNIQUE INDEX IF NOT EXISTS nf_events_msg " &
    "ON nf_events(run_id, message_id) " &
    "WHERE message_id IS NOT NULL AND message_id != ''",
  "CREATE TABLE IF NOT EXISTS nf_activations (" &
    "run_id TEXT NOT NULL, " &
    "activation_id TEXT NOT NULL, " &
    "state_json TEXT NOT NULL, " &
    "epoch INTEGER NOT NULL, " &
    "invocation_validated INTEGER NOT NULL DEFAULT 0, " &
    "PRIMARY KEY (run_id, activation_id))",
  "CREATE TABLE IF NOT EXISTS nf_attempts (" &
    "run_id TEXT NOT NULL, " &
    "activation_id TEXT NOT NULL, " &
    "attempt_id TEXT NOT NULL, " &
    "state_json TEXT NOT NULL, " &
    "PRIMARY KEY (run_id, activation_id, attempt_id))",
  "CREATE TABLE IF NOT EXISTS nf_external_effects (" &
    "run_id TEXT NOT NULL, " &
    "effect_id TEXT NOT NULL, " &
    "activation_id TEXT NOT NULL, " &
    "attempt_id TEXT NOT NULL, " &
    "status TEXT NOT NULL, " &
    "receipt_ref TEXT, " &
    "PRIMARY KEY (run_id, effect_id))",
  "CREATE TABLE IF NOT EXISTS nf_outbox (" &
    "run_id TEXT NOT NULL, " &
    "message_id TEXT NOT NULL, " &
    "payload_json TEXT NOT NULL, " &
    "status TEXT NOT NULL DEFAULT 'pending', " &
    "created_seq INTEGER NOT NULL, " &
    "PRIMARY KEY (run_id, message_id))",
  "CREATE TABLE IF NOT EXISTS nf_inbound_consumed (" &
    "run_id TEXT NOT NULL, " &
    "message_id TEXT NOT NULL, " &
    "PRIMARY KEY (run_id, message_id))",
  "CREATE TABLE IF NOT EXISTS nf_transitions (" &
    "run_id TEXT NOT NULL, " &
    "transition_id TEXT NOT NULL, " &
    "transition_json TEXT NOT NULL, " &
    "PRIMARY KEY (run_id, transition_id))",
]

proc applySchema*(db: SqliteDb) =
  for stmt in schemaStatements:
    execSql(db, stmt)