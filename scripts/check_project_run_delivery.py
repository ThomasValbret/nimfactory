"""Independent acceptance check for the CSV project-run recipe."""
import csv
import io
import json
import subprocess
import tempfile
from pathlib import Path


def tree_fingerprint(root):
    """Match the engine's existing 64-bit FNV receipt for source snapshots."""
    files = (path for path in root.rglob("*") if path.is_file()
             and not {"build", "nimcache"}.intersection(path.relative_to(root).parts[:-1]))
    value = 14695981039346656037
    for path in sorted(files, key=lambda item: item.as_posix()):
        name = path.relative_to(root).as_posix().encode()
        for byte in name + b"\n" + path.read_bytes() + b"\n":
            value = ((value ^ byte) * 1099511628211) & 0xffffffffffffffff
    return f"{value:016X}"


def check_delivery(tree, expected_hash, fixture):
    proof = {"ok": False, "tree": tree, "expected_hash": expected_hash, "behaviour": {}}
    if not tree or not expected_hash or not Path(tree).is_dir():
        proof["error"] = "missing delivered tree or fingerprint"
        return proof
    root = Path(tree).resolve()
    try:
        proof["observed_hash"] = tree_fingerprint(root)
        if proof["observed_hash"] != expected_hash:
            proof["error"] = "delivered tree fingerprint mismatch"
            return proof
        tasks = json.loads((fixture / "data/tasks.json").read_text())
        listed = [f"{task['id']}. {task['title']}" for task in tasks]
        exported = [["id", "title"], *[[str(task["id"]), task["title"]] for task in tasks]]
        with tempfile.TemporaryDirectory(prefix="nf-csv-proof-") as build:
            binary = Path(build) / "demo_tasks"
            comp = subprocess.run(
                ["nim", "c", "-d:release", "--hints:off", "--nimcache:" + build + "/cache",
                 "-o:" + str(binary), "src/demo_tasks.nim"],
                cwd=root, capture_output=True, text=True, timeout=120)
            proof["compile_exit"] = comp.returncode
            if comp.returncode:
                proof["error"] = comp.stderr[-2000:]
                return proof
            probes = [("no_args", []), ("list", ["list"]), ("export_csv", ["export-csv"])]
            for name, args in probes:
                run = subprocess.run([binary, *args], cwd=root, capture_output=True,
                                     text=True, timeout=15)
                if name == "export_csv" and (run.returncode or not run.stdout.startswith("id,title")):
                    args = ["list", "--format=csv"]
                    run = subprocess.run([binary, *args], cwd=root, capture_output=True,
                                         text=True, timeout=15)
                output = run.stdout
                if name == "export_csv":
                    valid = list(csv.reader(io.StringIO(output), strict=True)) == exported
                else:
                    valid = output.splitlines() == listed
                proof["behaviour"][name] = {
                    "argv": args, "exit": run.returncode, "out": output.rstrip("\n")[:500],
                    "ok": run.returncode == 0 and valid,
                }
        proof["ok"] = all(row["ok"] for row in proof["behaviour"].values())
    except (OSError, ValueError, csv.Error, subprocess.TimeoutExpired) as exc:
        proof["error"] = str(exc)
    return proof
