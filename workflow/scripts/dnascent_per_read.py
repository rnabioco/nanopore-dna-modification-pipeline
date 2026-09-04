"""Per-read BrdU/EdU summaries from a DNAscent detect modBAM.

DNAscent 4 writes its calls as modBAM tags on the input records:
``MM:Z:N+b?,...`` (BrdU) and ``MM:Z:N+e?,...`` (EdU), with ``ML`` holding
``round(p * 255)`` for each call, at thymidine positions. Reads DNAscent
skipped (mapq, length, failed event alignment) keep whatever MM/ML they came
in with (e.g. dorado's 6mA ``A+a``) and carry no ``N+b``/``N+e`` group, so
they are reported with n_calls = 0 rather than dropped.

Output (TSV, gzip): one row per alignment record with
read_id, chrom, start, end, strand, mapq, read_length, n_calls,
brdu_mean, brdu_frac_above, edu_mean, edu_frac_above
and, with --probs, the full comma-separated probability vectors.
"""

from __future__ import annotations

import argparse
import gzip
import sys

import pysam

BRDU = ("N", 0, "b")
EDU = ("N", 0, "e")


def _calls(read: pysam.AlignedSegment, key: tuple) -> list[float]:
    """Probabilities for one modification key from pysam's modified_bases."""
    mods = read.modified_bases or {}
    for k, values in mods.items():
        # pysam keys are (canonical_base, strand, code); code may be int (ChEBI) or str
        if k[0] == key[0] and k[1] == key[1] and str(k[2]) == key[2]:
            return [q / 255.0 for _, q in values]
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bam")
    parser.add_argument("--output", required=True, help="output .tsv.gz")
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="p above which a call counts as analogue",
    )
    parser.add_argument(
        "--probs",
        action="store_true",
        help="also write the per-call probability vectors",
    )
    parser.add_argument(
        "--mapped-only", action="store_true", help="skip unmapped records"
    )
    args = parser.parse_args(argv)

    header = [
        "read_id",
        "chrom",
        "start",
        "end",
        "strand",
        "mapq",
        "read_length",
        "n_calls",
        "brdu_mean",
        "brdu_frac_above",
        "edu_mean",
        "edu_frac_above",
    ]
    if args.probs:
        header += ["brdu_probs", "edu_probs"]

    n_records = n_called = 0
    with (
        pysam.AlignmentFile(args.bam, "rb", check_sq=False) as bam,
        gzip.open(args.output, "wt") as out,
    ):
        out.write("\t".join(header) + "\n")
        for read in bam.fetch(until_eof=True):
            if args.mapped_only and read.is_unmapped:
                continue
            n_records += 1
            brdu = _calls(read, BRDU)
            edu = _calls(read, EDU)
            n = max(len(brdu), len(edu))
            if n:
                n_called += 1
            row = [
                read.query_name,
                read.reference_name if not read.is_unmapped else "",
                read.reference_start if not read.is_unmapped else "",
                read.reference_end if not read.is_unmapped else "",
                "-" if read.is_reverse else "+",
                read.mapping_quality,
                read.query_length,
                n,
                f"{sum(brdu) / len(brdu):.4f}" if brdu else "",
                f"{sum(p > args.threshold for p in brdu) / len(brdu):.4f}"
                if brdu
                else "",
                f"{sum(edu) / len(edu):.4f}" if edu else "",
                f"{sum(p > args.threshold for p in edu) / len(edu):.4f}" if edu else "",
            ]
            if args.probs:
                row += [
                    ",".join(f"{p:.3f}" for p in brdu),
                    ",".join(f"{p:.3f}" for p in edu),
                ]
            out.write("\t".join(str(x) for x in row) + "\n")
    print(
        f"{n_records} records, {n_called} with DNAscent calls -> {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
