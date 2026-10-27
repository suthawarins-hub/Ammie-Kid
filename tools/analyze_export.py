#!/usr/bin/env python3
"""Local, privacy-preserving descriptive trends from Pregnant Manager Pro JSON.
No clinical thresholds, diagnoses, external requests, dependencies or medical claims.
Usage: python tools/analyze_export.py pregnant-manager-pro-backup-YYYY-MM-DD.json
"""
import csv
import json
import math
import sys
from pathlib import Path
from statistics import mean

SOURCES = {
    "prenatal_weight_kg": ("prenatalVisits", "weight", "date"),
    "maternal_bp_systolic_mmhg": ("prenatalVisits", "sys", "date"),
    "maternal_bp_diastolic_mmhg": ("prenatalVisits", "dia", "date"),
    "self_reported_mood": ("symptoms", "mood", "date"),
    "baby_weight_kg": ("growth", "weight", "date"),
    "baby_length_cm": ("growth", "length", "date"),
}


def numeric(value):
    if value is None or str(value).strip() == "":
        return None
    try:
        n = float(value)
        return n if math.isfinite(n) else None
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) != 2:
        print("Usage: python tools/analyze_export.py <export.json>")
        raise SystemExit(2)
    path = Path(sys.argv[1]).expanduser()
    data = json.loads(path.read_text(encoding="utf-8"))
    folder = path.parent / (path.stem + "_descriptive_trends")
    folder.mkdir(exist_ok=True)
    summary = []
    for name, (collection, value_key, date_key) in SOURCES.items():
        rows = []
        for entry in data.get(collection, []):
            n = numeric(entry.get(value_key))
            if n is not None:
                rows.append((str(entry.get(date_key) or entry.get('createdAt') or '')[:10], n))
        rows.sort()
        with (folder / f"{name}.csv").open("w", encoding="utf-8-sig", newline="") as f:
            wr = csv.writer(f)
            wr.writerow(["date", name])
            wr.writerows(rows)
        values = [n for _, n in rows]
        summary.append({
            "series": name,
            "count": len(values),
            "first": values[0] if values else "",
            "last": values[-1] if values else "",
            "change": round(values[-1] - values[0], 3) if len(values) > 1 else "",
            "average": round(mean(values), 3) if values else "",
        })
    with (folder / "summary.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    print(f"Saved descriptive CSV summaries to: {folder}")
    print("These calculations do not indicate whether any measurement is medically normal or safe.")


if __name__ == "__main__":
    main()
