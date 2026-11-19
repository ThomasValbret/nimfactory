#!/usr/bin/env python3
"""Replay recorded API decisions on the opposite repo (no new model spend).

Reads api_repo_{a,b}.json from NF_CAMPAIGN_OUT (or legacy docs/qa/e2e_intervention).
"""
from __future__ import annotations
import json, os, re, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "fixtures" / "e2e_intervention"
BIN = ROOT / "build" / "nimfactory"
QA = Path(os.environ.get("NF_CAMPAIGN_OUT", str(ROOT / "docs" / "qa" / "e2e_intervention")))


def decision_payload(trial_path: Path) -> dict:
    trial = json.loads(trial_path.read_text())
    # Prefer last attempt with effective change; else last decision with content.
    attempts = trial.get("attempts") or []
    for a in reversed(attempts):
        if a.get("effective_change") and (a.get("decision") or {}).get("patched_len", 0) > 0:
            raw = (a.get("provider") or {}).get("raw_text") or ""
            m = re.search(r"\{[\s\S]*\}", raw)
            if m:
                obj = json.loads(m.group(0))
                if not obj.get("cannot_fix"):
                    return obj
    raw = trial["provider"]["raw_text"]
    m = re.search(r"\{[\s\S]*\}", raw)
    if not m:
        raise SystemExit(f"no JSON object in {trial_path}")
    return json.loads(m.group(0))


def run_cross(name: str, trial: Path, repo: Path) -> None:
    if not trial.exists():
        print(f"skip {name}: missing {trial}")
        return
    payload = decision_payload(trial)
    if payload.get("cannot_fix"):
        out = {
            "ok": False,
            "verdict": "model_cannot_fix",
            "warning": "source trial concluded cannot_fix; cross skipped",
            "provider_calls": 0,
        }
        (QA / f"{name}.json").write_text(json.dumps(out, indent=2) + "\n")
        print(name, "skipped cannot_fix")
        return
    inj = Path(tempfile.mkdtemp(prefix="nf_inj_")) / f"{name}.json"
    inj.write_text(json.dumps(payload, indent=2))
    wt = Path(tempfile.mkdtemp(prefix=f"nf_{name}_"))
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
        "target", (result.get("decision") or {}).get("target_file"),
        "ok", result.get("ok"),
        "calls", result.get("provider_calls"),
    )


def main() -> None:
    QA.mkdir(parents=True, exist_ok=True)
    run_cross("cross_a_on_b", QA / "api_repo_a.json", FIX / "repo_b")
    run_cross("cross_b_on_a", QA / "api_repo_b.json", FIX / "repo_a")


if __name__ == "__main__":
    main()
