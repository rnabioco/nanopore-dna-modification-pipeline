"""Fold per-sample QC into one table: summary/samples_summary.tsv.

Reads whatever of these exist for each sample under the output directory and
leaves a column empty when an input is missing rather than failing:

- summary/qc/<s>/<s>.flagstat.tsv        (samtools flagstat -O tsv)
- summary/qc/<s>/<s>.mosdepth.summary.txt
- summary/tables/<s>/<s>.read_summary.tsv.gz   (dorado summary)
- summary/modkit/<s>/<s>.modkit_summary.tsv    (modkit summary --tsv)
"""

from __future__ import annotations

import argparse
import csv
import gzip
import os
import statistics
import sys


def read_flagstat(path: str) -> dict:
    out: dict[str, float] = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            passed, _failed, label = parts[0], parts[1], parts[2]
            key = label.split(" (")[0].strip().replace(" ", "_")
            try:
                out[key] = float(passed)
            except ValueError:
                continue
    return out


def read_mosdepth_summary(path: str) -> dict:
    out: dict[str, float] = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            if row.get("chrom") == "total":
                out["mean_depth"] = float(row["mean"])
                out["ref_length"] = float(row["length"])
    return out


def n50(lengths: list[int]) -> int | None:
    if not lengths:
        return None
    total = sum(lengths)
    acc = 0
    for x in sorted(lengths, reverse=True):
        acc += x
        if acc * 2 >= total:
            return x
    return None


def read_dorado_summary(path: str) -> dict:
    out: dict[str, float | int | None] = {}
    if not os.path.exists(path):
        return out
    lengths: list[int] = []
    qscores: list[float] = []
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            try:
                lengths.append(int(row["sequence_length_template"]))
                qscores.append(float(row["mean_qscore_template"]))
            except (KeyError, ValueError):
                continue
    if lengths:
        out["n_reads_summary"] = len(lengths)
        out["read_n50"] = n50(lengths)
        out["read_mean_length"] = round(statistics.fmean(lengths), 1)
        out["mean_qscore"] = round(statistics.fmean(qscores), 2)
        out["total_bases"] = sum(lengths)
    return out


def read_modkit_summary(path: str) -> dict:
    """modkit summary --tsv: rows of base/code/pass_count/pass_frac/all_count/all_frac."""
    out: dict[str, float] = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 6 or parts[0] == "base":
                continue
            base, code = parts[0], parts[1]
            try:
                out[f"modkit_{base}_{code}_pass_frac"] = float(parts[3])
            except ValueError:
                continue
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", required=True, help="pipeline output_directory")
    parser.add_argument("--samples", nargs="+", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)

    rows = []
    for s in args.samples:
        row: dict = {"sample": s}
        fs = read_flagstat(
            os.path.join(args.outdir, "summary", "qc", s, f"{s}.flagstat.tsv")
        )
        row["reads_total"] = fs.get("total")
        row["reads_primary"] = fs.get("primary")
        row["reads_primary_mapped"] = fs.get("primary_mapped")
        if fs.get("primary"):
            row["primary_mapped_frac"] = round(
                fs.get("primary_mapped", 0) / fs["primary"], 4
            )
        row.update(
            read_mosdepth_summary(
                os.path.join(
                    args.outdir, "summary", "qc", s, f"{s}.mosdepth.summary.txt"
                )
            )
        )
        row.update(
            read_dorado_summary(
                os.path.join(
                    args.outdir, "summary", "tables", s, f"{s}.read_summary.tsv.gz"
                )
            )
        )
        row.update(
            read_modkit_summary(
                os.path.join(
                    args.outdir, "summary", "modkit", s, f"{s}.modkit_summary.tsv"
                )
            )
        )
        rows.append(row)

    columns: list[str] = ["sample"]
    for row in rows:
        for k in row:
            if k not in columns:
                columns.append(k)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter="\t", restval="")
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {args.output} ({len(rows)} samples)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
