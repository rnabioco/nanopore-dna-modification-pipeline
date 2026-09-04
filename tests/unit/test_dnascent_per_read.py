import gzip
from array import array

import dnascent_per_read as dpr
import pysam


def _write_bam(path):
    header = {
        "HD": {"VN": "1.6", "SO": "coordinate"},
        "SQ": [{"SN": "chr1", "LN": 1000}],
    }
    with pysam.AlignmentFile(str(path), "wb", header=header) as bam:
        # A read DNAscent scored: 3 thymidines, BrdU/EdU probabilities as ML bytes.
        r = pysam.AlignedSegment()
        r.query_name = "scored"
        r.query_sequence = "ACGTTGCATGCATTGCA"
        r.flag = 0
        r.reference_id = 0
        r.reference_start = 10
        r.mapping_quality = 60
        r.cigartuples = [(0, len(r.query_sequence))]
        r.query_qualities = pysam.qualitystring_to_array("I" * len(r.query_sequence))
        # T positions: 3, 4, 8, 12, 13 -> use every T for both mods (5 calls each)
        r.set_tag("MM", "N+b?,3,0,3,3,0;N+e?,3,0,3,3,0;")
        r.set_tag("ML", array("B", [255, 0, 128, 255, 0, 0, 255, 26, 0, 255]))
        bam.write(r)
        # A read DNAscent skipped: carries dorado's 6mA tag only.
        s = pysam.AlignedSegment()
        s.query_name = "skipped"
        s.query_sequence = "AAAACCCC"
        s.flag = 0
        s.reference_id = 0
        s.reference_start = 100
        s.mapping_quality = 5
        s.cigartuples = [(0, 8)]
        s.query_qualities = pysam.qualitystring_to_array("I" * 8)
        s.set_tag("MM", "A+a.,0,0;")
        s.set_tag("ML", array("B", [10, 20]))
        bam.write(s)
    pysam.index(str(path))


def test_per_read_table(tmp_path):
    bam = tmp_path / "detect.bam"
    _write_bam(bam)
    out = tmp_path / "per_read.tsv.gz"
    assert dpr.main([str(bam), "--output", str(out), "--probs"]) == 0
    with gzip.open(out, "rt") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        rows = [
            dict(zip(header, line.rstrip("\n").split("\t"), strict=True)) for line in fh
        ]
    by_name = {r["read_id"]: r for r in rows}
    scored = by_name["scored"]
    assert scored["n_calls"] == "5"
    assert scored["brdu_mean"] == f"{(255 + 0 + 128 + 255 + 0) / 5 / 255:.4f}"
    assert (
        scored["brdu_frac_above"] == "0.6000"
    )  # 255, 128 (0.502), 255 of five are above 0.5
    assert scored["edu_frac_above"] == "0.4000"
    assert scored["brdu_probs"].startswith("1.000,0.000,0.502")
    assert scored["chrom"] == "chr1" and scored["strand"] == "+"
    skipped = by_name["skipped"]
    assert skipped["n_calls"] == "0" and skipped["brdu_mean"] == ""


def test_mapped_only_skips_unmapped(tmp_path):
    bam = tmp_path / "u.bam"
    header = {"HD": {"VN": "1.6", "SO": "unsorted"}, "SQ": [{"SN": "chr1", "LN": 1000}]}
    with pysam.AlignmentFile(str(bam), "wb", header=header) as fh:
        r = pysam.AlignedSegment()
        r.query_name = "unmapped"
        r.query_sequence = "ACGT"
        r.flag = 4
        r.query_qualities = pysam.qualitystring_to_array("IIII")
        fh.write(r)
    out = tmp_path / "o.tsv.gz"
    assert dpr.main([str(bam), "--output", str(out), "--mapped-only"]) == 0
    with gzip.open(out, "rt") as fh:
        assert len(fh.readlines()) == 1  # header only
