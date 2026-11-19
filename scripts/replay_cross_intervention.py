#!/usr/bin/env python3
"""Replay recorded API decisions on the opposite repo (no new model spend)."""
from __future__ import annotations
import json, re, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "fixtures" / "e2e_intervention"
QA = ROOT / "docs" / "qa" / "e2e_intervention"
BIN = ROOT / "build" / "nimfactory"


def decision_payload(trial_path: Path) -> dict:
    trial = json.loads(trial_path.read_text())
    raw = trial["provider"]["raw_text"]
    m = re.search(r"\{[\s\S]*\}", raw)
    if not m:
        raise SystemExit(f"no JSON object in {trial_path}")
    return json.loads(m.group(0))


def run_cross(name: str, trial: Path, repo: Path) -> None:
    payload = decision_payload(trial)
    inj = Path(tempfile.mkdtemp(prefix="nf_inj_")) / f"{name}.json"
    inj.write_text(json.dumps(payload, indent=2))
    wt = Path(tempfile.mkdtemp(prefix=f"nf_{name}_"))
    # occupied check: mkdtemp creates non-empty? it creates empty dir — occupied if any entry.
    # empty dir is allowed by allocateWorktree; remove and recreate as non-existent path
    wt.rmdir()
    out = QA / f"{name}.json"
    cmd = [
        str(BIN), "mission-fix",
        "--repo", str(repo),
        "--symptom", str(FIX / "SYMPTOM.md"),
        "--oracle", str(FIX / "oracle"),
        "--route", "inject",
        "--inject", str(inj),
        "--worktree", str(wt),
    ]
    with out.open("w") as fh:
        proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.PIPE, text=True)
    result = json.loads(out.read_text())
    print(
        name,
        "exit", proc.returncode,
        "verdict", result.get("verdict"),
        "target", result.get("decision", {}).get("target_file"),
        "ok", result.get("ok"),
    )


def main() -> None:
    run_cross("cross_a_on_b", QA / "api_repo_a.json", FIX / "repo_b")
    run_cross("cross_b_on_a", QA / "api_repo_b.json", FIX / "repo_a")


if __name__ == "__main__":
    main()
