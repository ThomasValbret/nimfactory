#!/usr/bin/env python3
"""Oracle — démarre/redémarre le squelette et vérifie une modification Studio.

Rôles :
  skeleton : démarrage technique (app.py + schema.sql)
  builder  : fonctions métier (ex. POST /loans/{id}/return)
  oracle   : ce script (+ optionnellement le navigateur Studio)
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKELETON = ROOT / "skeleton" / "app.py"
PORT = int(os.environ.get("LOAN_PORT", "18181"))
BASE = f"http://127.0.0.1:{PORT}"
PID_FILE = Path(os.environ.get("LOAN_PID", ROOT / "data" / "server.pid"))
DB_PATH = Path(os.environ.get("LOAN_DB", ROOT / "data" / "loans.sqlite"))
STUDIO_URL = os.environ.get("STUDIO_URL", "").rstrip("/")


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


def start_server() -> subprocess.Popen:
    stop_server()
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    env = os.environ.copy()
    env["LOAN_PORT"] = str(PORT)
    env["LOAN_DB"] = str(DB_PATH)
    proc = subprocess.Popen(
        [sys.executable, str(SKELETON)],
        cwd=str(SKELETON.parent),
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
    raise RuntimeError("server failed to start")


def studio_snapshot() -> dict | None:
    if not STUDIO_URL:
        return None
    req = urllib.request.Request(STUDIO_URL + "/api/snapshot")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    report: dict = {"ok": False, "checks": [], "role": "oracle", "studio": None}
    proc = None
    try:
        proc = start_server()
        report["checks"].append({"name": "server_starts", "ok": True})

        code, created = http_json(
            "POST",
            "/loans",
            {
                "borrower": "Ada",
                "amount_cents": 1500,
                "lent_on": "2026-11-22",
                "note": "book",
            },
        )
        loan_id = created.get("id")
        report["checks"].append({"name": "create_loan", "ok": code == 201 and loan_id})

        code, listed = http_json("GET", "/loans")
        report["checks"].append(
            {
                "name": "list_loan",
                "ok": code == 200
                and any(l.get("borrower") == "Ada" for l in listed.get("loans", [])),
            }
        )

        # Optional Studio observation (Nouveau projet / aperçu).
        try:
            snap = studio_snapshot()
            if snap is not None:
                report["studio"] = {
                    "project_id": snap.get("project_id"),
                    "plan_version": snap.get("current_plan_version"),
                    "bootstrap": snap.get("bootstrap", False),
                    "next_action": snap.get("next_action"),
                    "last_verdict": snap.get("last_verdict"),
                }
                report["checks"].append(
                    {
                        "name": "studio_reachable",
                        "ok": snap.get("schema") == "nimfactory.studio/v1",
                    }
                )
        except Exception as exc:
            report["checks"].append(
                {"name": "studio_reachable", "ok": False, "detail": str(exc)}
            )

        # Restart then verify Studio-requested builder change: mark returned.
        stop_server()
        if proc.poll() is None:
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()
        proc = start_server()
        report["checks"].append({"name": "server_restart", "ok": True})

        # Recreate loan after DB wipe on restart.
        code, created = http_json(
            "POST",
            "/loans",
            {
                "borrower": "Ada",
                "amount_cents": 1500,
                "lent_on": "2026-11-22",
                "note": "book",
            },
        )
        loan_id = created.get("id")
        try:
            code, body = http_json("POST", f"/loans/{loan_id}/return", {})
            ok = code == 200 and body.get("ok") is True
            report["checks"].append(
                {
                    "name": "studio_change_mark_returned",
                    "ok": ok,
                    "detail": body if ok else "missing /return — apply builder step from Studio",
                }
            )
        except urllib.error.HTTPError as exc:
            report["checks"].append(
                {
                    "name": "studio_change_mark_returned",
                    "ok": False,
                    "detail": f"HTTP {exc.code} — modification Studio absente",
                }
            )

        require = os.environ.get("LOAN_REQUIRE_RETURN", "1") == "1"
        if require:
            report["ok"] = all(c["ok"] for c in report["checks"])
        else:
            report["ok"] = all(
                c["ok"]
                for c in report["checks"]
                if c["name"] != "studio_change_mark_returned"
            )
    except Exception as exc:
        report["error"] = str(exc)
        report["ok"] = False
    finally:
        stop_server()
        if proc is not None and proc.poll() is None:
            proc.terminate()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
