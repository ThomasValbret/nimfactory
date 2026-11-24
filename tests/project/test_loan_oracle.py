"""Public loan oracle witnesses — durable return vs false positives."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


FIXTURE = Path(__file__).resolve().parents[2] / "fixtures" / "loan_notebook"


def _patch_app(addition: str) -> Path:
    """Build a candidate tree with `addition` inserted after the inject anchor."""
    edit = json.loads((FIXTURE / "builder/inject/step_mark_returned.json").read_text())["edits"][0]
    anchor = edit["insertAfter"]
    skeleton = (FIXTURE / "skeleton/app.py").read_text()
    root = Path(tempfile.mkdtemp(prefix="loan-wit-"))
    target = root / "skeleton"
    shutil.copytree(FIXTURE / "skeleton", target)
    (target / "app.py").write_text(skeleton.replace(anchor, anchor + addition))
    return root


def _run_oracle(app_after: Path, *, mode: str = "full") -> tuple[int, dict]:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = str(listener.getsockname()[1])
    root = app_after.parent.parent
    # Keep DB/pid outside the candidate tree so served_tree.hash is app-only.
    side = Path(tempfile.mkdtemp(prefix="loan-side-"))
    env = dict(
        os.environ,
        LOAN_PORT=port,
        LOAN_PID=str(side / "pid"),
        LOAN_DB=str(side / "loans.sqlite"),
        LOAN_ORACLE_MODE=mode,
        LOAN_APP_BEFORE=str(FIXTURE / "skeleton/app.py"),
        LOAN_APP_AFTER=str(app_after),
        LOAN_NOTE="oracle-witness-shared",
    )
    run = subprocess.run(
        [sys.executable, str(FIXTURE / "oracle/verify_studio_change.py")],
        env=env,
        capture_output=True,
        text=True,
        timeout=45,
    )
    report = json.loads(run.stdout)
    return run.returncode, report


def _case_summary(name: str, report: dict) -> dict:
    after = report.get("after") or report.get("adapter") or {}
    restart = report.get("restart") or {}
    served = report.get("served_tree") or after.get("served_tree") or {}
    loan_id = after.get("loan_id") or (report.get("before") or {}).get("loan_id")
    returned = None
    for check in restart.get("checks") or []:
        if check.get("name") == "sqlite_same_loan_returned":
            returned = check.get("returned_on")
    return {
        "name": name,
        "ok": report.get("ok"),
        "loan_id": loan_id,
        "returned_on_after_restart": returned,
        "served_tree_hash": served.get("hash"),
        "controls": report.get("controls"),
    }


class LoanOracleTest(unittest.TestCase):
    def test_return_requires_a_durable_change(self):
        edit = json.loads((FIXTURE / "builder/inject/step_mark_returned.json").read_text())["edits"][0]
        anchor = edit["insertAfter"]
        correct = edit["newText"]
        no_change = correct.replace("returned_on = date('now')", "returned_on = returned_on")
        # Abort after UPDATE: HTTP 200 but transaction rolled back → not persisted.
        abort_tx = correct.replace(
            "conn.commit()\n                if cur.rowcount == 0:",
            "conn.rollback()\n                if cur.rowcount == 0:",
        )
        # CURRENT_DATE is an accepted durable SQL form when persistence holds.
        current_date = correct.replace("date('now')", "CURRENT_DATE")
        self.assertNotEqual(correct, no_change)
        self.assertNotEqual(correct, abort_tx)
        self.assertNotEqual(correct, current_date)
        skeleton = (FIXTURE / "skeleton/app.py").read_text()
        self.assertEqual(skeleton.count(anchor), 1)

        cases = [
            ("comment", "        # /loans/{id}/return\n", False),
            ("no_change", no_change, False),
            ("abort_tx", abort_tx, False),
            ("current_date", current_date, True),
            ("correct", correct, True),
        ]
        summaries = []
        for name, addition, success in cases:
            with self.subTest(name=name):
                root = _patch_app(addition)
                try:
                    code, report = _run_oracle(root / "skeleton" / "app.py")
                    self.assertNotIn("error", report, report)
                    self.assertTrue(report["before"]["ok"], report)
                    self.assertEqual(code, 0 if success else 1, report)
                    self.assertEqual(report["ok"], success, report)
                    if name != "comment":
                        self.assertTrue(report["after"]["ok"], report)
                        self.assertEqual(report["restart"]["ok"], success, report)
                        self.assertEqual(
                            report["restart"]["loan_id"], report["before"]["loan_id"], report
                        )
                    # Skipped persistence stays not_run when effect failed early.
                    controls = {c["name"]: c["status"] for c in report.get("controls") or []}
                    if name == "comment":
                        self.assertEqual(controls.get("mark_returned_effect"), "failed")
                        self.assertEqual(controls.get("persistence_after_restart"), "not_run")
                    elif not success:
                        self.assertEqual(controls.get("persistence_after_restart"), "failed")
                    else:
                        self.assertEqual(controls.get("persistence_after_restart"), "passed")
                    summaries.append(_case_summary(name, report))
                finally:
                    shutil.rmtree(root, ignore_errors=True)

        # Emit a compact table for the delivery receipt (stdout captured by runners).
        print(json.dumps({"witness_summaries": summaries}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    unittest.main()
