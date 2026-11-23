"""Run the public loan recipe's HTTP oracle against three candidate apps."""
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


class LoanOracleTest(unittest.TestCase):
    def test_return_requires_a_durable_change(self):
        edit = json.loads((FIXTURE / "builder/inject/step_mark_returned.json").read_text())["edits"][0]
        anchor = edit["insertAfter"]
        correct = edit["newText"]
        no_change = correct.replace("returned_on = date('now')", "returned_on = returned_on")
        self.assertNotEqual(correct, no_change)
        skeleton = (FIXTURE / "skeleton/app.py").read_text()
        self.assertEqual(skeleton.count(anchor), 1)
        for name, addition, success in [
            ("comment", "        # /loans/{id}/return\n", False),
            ("no_change", no_change, False),
            ("correct", correct, True),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / "skeleton"
                shutil.copytree(FIXTURE / "skeleton", target)
                (target / "app.py").write_text(skeleton.replace(anchor, anchor + addition))
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    port = str(listener.getsockname()[1])
                env = dict(os.environ, LOAN_PORT=port, LOAN_PID=str(root / "pid"),
                           LOAN_DB=str(root / "loans.sqlite"), LOAN_ORACLE_MODE="full",
                           LOAN_APP_BEFORE=str(FIXTURE / "skeleton/app.py"),
                           LOAN_APP_AFTER=str(target / "app.py"))
                run = subprocess.run([sys.executable, str(FIXTURE / "oracle/verify_studio_change.py")],
                                     env=env, capture_output=True, text=True, timeout=30)
                report = json.loads(run.stdout)
                self.assertNotIn("error", report, report)
                self.assertTrue(report["before"]["ok"], report)
                self.assertEqual(run.returncode, 0 if success else 1, report)
                self.assertEqual(report["ok"], success)
                if name != "comment":
                    self.assertTrue(report["after"]["ok"])
                    self.assertEqual(report["restart"]["ok"], success)
                    self.assertEqual(report["restart"]["loan_id"], report["before"]["loan_id"])


if __name__ == "__main__":
    unittest.main()
