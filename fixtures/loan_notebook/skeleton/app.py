#!/usr/bin/env python3
"""Skeleton technique — démarrage local du carnet de prêts (SQLite).

Le squelette fournit HTTP + schéma. La restitution (/loans/{id}/return)
est une fonction métier demandée : elle doit manquer ici et apparaître
dans l'arbre produit par NimFactory / Studio.
"""
from __future__ import annotations

import json
import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
DB = Path(os.environ.get("LOAN_DB", ROOT / "data" / "loans.sqlite"))
SCHEMA = Path(__file__).resolve().parent / "schema.sql"
PORT = int(os.environ.get("LOAN_PORT", "18181"))


def connect() -> sqlite3.Connection:
    DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA.read_text(encoding="utf-8"))
    return conn


def list_loans(conn: sqlite3.Connection):
    rows = conn.execute(
        "SELECT id, borrower, amount_cents, lent_on, due_on, returned_on, note "
        "FROM loans ORDER BY id"
    ).fetchall()
    return [dict(r) for r in rows]


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/health"):
            self._json(200, {"ok": True, "service": "loan_notebook_skeleton", "db": str(DB)})
            return
        if path == "/loans":
            with connect() as conn:
                self._json(200, {"loans": list_loans(conn)})
            return
        self._json(404, {"ok": False, "message": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "message": "invalid json"})
            return
        if path == "/loans":
            # Builder will supply business validation; skeleton accepts minimal insert.
            required = ("borrower", "amount_cents", "lent_on")
            if any(k not in data for k in required):
                self._json(400, {"ok": False, "message": "missing fields"})
                return
            with connect() as conn:
                cur = conn.execute(
                    "INSERT INTO loans(borrower, amount_cents, lent_on, due_on, note) "
                    "VALUES(?,?,?,?,?)",
                    (
                        data["borrower"],
                        int(data["amount_cents"]),
                        data["lent_on"],
                        data.get("due_on"),
                        data.get("note", ""),
                    ),
                )
                conn.commit()
                self._json(201, {"ok": True, "id": cur.lastrowid})
            return
        self._json(404, {"ok": False, "message": "not found"})

    def log_message(self, fmt, *args):
        return


def main():
    connect().close()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"loan_notebook skeleton http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
