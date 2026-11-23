#!/usr/bin/env python3
"""Oracle carnet de prêts — avant/après sur l'arbre NimFactory.

Avant  : squelette initial → la fonction demandée (/return) échoue.
         Crée un prêt identifiable ; conserve la même base SQLite.
Après  : démarre l'app depuis l'arbre accepté NimFactory (même LOAN_DB)
         → retrouve le prêt sans le recréer ; /return réussit.

Variables :
  LOAN_APP   chemin de l'app (défaut : skeleton/app.py)
  LOAN_DB    fichier SQLite partagé (conservé entre redémarrages)
  LOAN_PORT  port HTTP
  TREE_SHA   hash d'arbre servi (renseigné dans le rapport)
"""
from __future__ import annotations

import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SKELETON = ROOT / "skeleton" / "app.py"
PORT = int(os.environ.get("LOAN_PORT", "18181"))
BASE = f"http://127.0.0.1:{PORT}"
PID_FILE = Path(os.environ.get("LOAN_PID", ROOT / "data" / "server.pid"))
DB_PATH = Path(os.environ.get("LOAN_DB", ROOT / "data" / "loans.sqlite"))
LOAN_NOTE = os.environ.get("LOAN_NOTE", "oracle-ident-20261123T1958Z")
TREE_SHA = os.environ.get("TREE_SHA", "")


def http_json(method: str, path: str, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=3) as resp:
        return resp.status, json.loads(resp.read().decode("utf-8"))


def stop_server() -> None:
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.3)
        except (OSError, ValueError):
            pass
        PID_FILE.unlink(missing_ok=True)


def start_server(app: Path, *, wipe_db: bool) -> subprocess.Popen:
    """Start HTTP app. wipe_db=False keeps the identifiable loan across restarts."""
    stop_server()
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if wipe_db and DB_PATH.exists():
        DB_PATH.unlink()
    if not app.is_file():
        raise FileNotFoundError(f"app not found: {app}")
    env = os.environ.copy()
    env["LOAN_PORT"] = str(PORT)
    env["LOAN_DB"] = str(DB_PATH)
    proc = subprocess.Popen(
        [sys.executable, str(app)],
        cwd=str(app.parent),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(proc.pid))
    for _ in range(40):
        try:
            code, body = http_json("GET", "/health")
            if code == 200 and body.get("ok"):
                return proc
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"server failed to start from {app}")


def try_return(loan_id: int) -> tuple[bool, object]:
    try:
        code, body = http_json("POST", f"/loans/{loan_id}/return", {})
        return code == 200 and body.get("ok") is True, body
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read().decode("utf-8"))
        except Exception:
            detail = {"http": exc.code}
        return False, detail
    except Exception as exc:
        return False, {"error": str(exc)}


def find_loan_by_note(note: str) -> dict | None:
    code, listed = http_json("GET", "/loans")
    if code != 200:
        return None
    for loan in listed.get("loans", []):
        if loan.get("note") == note:
            return loan
    return None


def probe(phase: str, app: Path, *, wipe_db: bool, expect_return: bool,
          loan_id: int | None = None, create: bool = False) -> dict:
    """Run one phase; returns check dict + optional loan_id."""
    out: dict = {
        "phase": phase,
        "app": str(app),
        "tree_sha": TREE_SHA if phase.startswith("after") else "",
        "expect_return": expect_return,
        "checks": [],
    }
    proc = start_server(app, wipe_db=wipe_db)
    out["checks"].append({"name": "server_starts", "ok": True})
    try:
        if create:
            code, created = http_json(
                "POST",
                "/loans",
                {
                    "borrower": "Ada Lovelace",
                    "amount_cents": 4200,
                    "lent_on": "2026-11-23",
                    "note": LOAN_NOTE,
                },
            )
            loan_id = created.get("id")
            out["checks"].append(
                {
                    "name": "create_identifiable_loan",
                    "ok": code == 201 and bool(loan_id),
                    "loan_id": loan_id,
                    "note": LOAN_NOTE,
                }
            )
        else:
            found = find_loan_by_note(LOAN_NOTE)
            ok = found is not None and (
                loan_id is None or found.get("id") == loan_id
            )
            out["checks"].append(
                {
                    "name": "find_loan_without_recreate",
                    "ok": ok,
                    "found": found,
                    "expected_note": LOAN_NOTE,
                    "expected_id": loan_id,
                }
            )
            if found is not None:
                loan_id = found.get("id")
                out["checks"].append({
                    "name": "loan_initially_open",
                    "ok": "returned_on" in found and found["returned_on"] is None,
                })

        if loan_id is None:
            out["checks"].append(
                {"name": "mark_returned_control", "ok": False, "detail": "no loan id"}
            )
        else:
            ok, detail = try_return(int(loan_id))
            # Control: fail on skeleton (expect_return=False), succeed on tree.
            control_ok = ok if expect_return else (not ok)
            out["checks"].append(
                {
                    "name": "mark_returned_control",
                    "ok": control_ok,
                    "return_succeeded": ok,
                    "expected_success": expect_return,
                    "detail": detail,
                    "loan_id": loan_id,
                }
            )
        out["loan_id"] = loan_id
        out["ok"] = all(c["ok"] for c in out["checks"])
    finally:
        stop_server()
        if proc.poll() is None:
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()
    return out


def verify_persistence(app: Path, loan_id: int | None) -> dict:
    """Read the same loan after a fresh process opens the same database."""
    out = {"phase": "after_restart", "loan_id": loan_id, "checks": []}
    proc = start_server(app, wipe_db=False)
    try:
        loan = find_loan_by_note(LOAN_NOTE)
        returned = loan.get("returned_on") if loan else None
        out["checks"].append({
            "name": "http_same_loan_returned_after_restart",
            "ok": bool(loan and loan["id"] == loan_id and returned),
            "returned_on": returned,
        })
        with sqlite3.connect(DB_PATH.resolve().as_uri() + "?mode=ro", uri=True) as conn:
            row = conn.execute(
                "SELECT returned_on FROM loans WHERE id = ? AND note = ?",
                (loan_id, LOAN_NOTE),
            ).fetchone()
        out["checks"].append({
            "name": "sqlite_same_loan_returned",
            "ok": bool(row and row[0] and row[0] == returned),
            "returned_on": row[0] if row else None,
        })
        out["ok"] = all(check["ok"] for check in out["checks"])
    finally:
        stop_server()
        proc.wait(timeout=3)
    return out


def main() -> int:
    before_app = Path(os.environ.get("LOAN_APP_BEFORE", str(DEFAULT_SKELETON)))
    after_app = Path(os.environ.get("LOAN_APP_AFTER", ""))
    mode = os.environ.get("LOAN_ORACLE_MODE", "full")  # before | after | full

    report: dict = {
        "ok": False,
        "role": "oracle",
        "loan_note": LOAN_NOTE,
        "db": str(DB_PATH),
        "tree_sha": TREE_SHA,
        "before": None,
        "after": None,
    }

    try:
        loan_id = None
        if mode in ("before", "full"):
            before = probe(
                "before_skeleton",
                before_app,
                wipe_db=True,
                expect_return=False,
                create=True,
            )
            report["before"] = before
            loan_id = before.get("loan_id")
            if mode == "before":
                report["ok"] = before.get("ok", False)
                print(json.dumps(report, ensure_ascii=False, indent=2))
                return 0 if report["ok"] else 1

        if mode in ("after", "full"):
            if not after_app or not after_app.is_file():
                raise FileNotFoundError(
                    "LOAN_APP_AFTER must point to skeleton/app.py in the accepted tree"
                )
            # Same DB: wipe_db=False — must find the loan without recreating.
            after = probe(
                "after_accepted_tree",
                after_app,
                wipe_db=False,
                expect_return=True,
                loan_id=loan_id if mode == "full" else None,
                create=False,
            )
            report["after"] = after
            report["tree_sha"] = TREE_SHA or after.get("tree_sha", "")
            if after["ok"]:
                report["restart"] = verify_persistence(after_app, after["loan_id"])
                report["ok"] = report["restart"]["ok"] and (mode == "after" or report["before"]["ok"])
    except Exception as exc:
        report["error"] = str(exc)
        report["ok"] = False
    finally:
        stop_server()

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
