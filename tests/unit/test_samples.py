import pytest
import samples
import yaml


def _touch(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")
    return path


@pytest.fixture
def run(tmp_path):
    """A MinKNOW-like run with pass/fail POD5 and BAMs, barcoded and not."""
    root = tmp_path / "run"
    _touch(root / "pod5_pass" / "a_0.pod5")
    _touch(root / "pod5_fail" / "a_1.pod5")
    _touch(root / "pod5_pass" / "barcode15" / "bc15_0.pod5")
    _touch(root / "pod5_fail" / "barcode15" / "bc15_1.pod5")
    _touch(root / "bam_pass" / "barcode15" / "bc15_0.bam")
    _touch(root / "bam_fail" / "barcode15" / "bc15_1.bam")
    _touch(root / "bam_pass" / "plain_0.bam")
    return root


def test_find_pod5_recursive_and_pass_only(run):
    files = samples.find_pod5_files(str(run))
    assert [f.split("/")[-1] for f in files] == [
        "a_1.pod5",
        "bc15_1.pod5",
        "a_0.pod5",
        "bc15_0.pod5",
    ]
    assert len(samples.find_pod5_files(str(run), include_fail=False)) == 2
    assert len(samples.find_pod5_files(str(run), barcode="barcode15")) == 2
    assert (
        len(samples.find_pod5_files(str(run), barcode="barcode15", include_fail=False))
        == 1
    )


def test_find_pod5_plain_dir_and_file(tmp_path):
    d = tmp_path / "flat"
    _touch(d / "x.pod5")
    assert samples.find_pod5_files(str(d)) == [str((d / "x.pod5").resolve())]
    assert samples.find_pod5_files(str(d / "x.pod5")) == [str((d / "x.pod5").resolve())]
    with pytest.raises(samples.SampleError):
        samples.find_pod5_files(str(tmp_path / "missing"))


def test_tsv_merges_runs_and_reference(tmp_path, run):
    other = tmp_path / "run2"
    _touch(other / "pod5" / "b.pod5")
    tsv = tmp_path / "samples.tsv"
    tsv.write_text(f"# comment\ns1 {run}\ns1 {other} /ref/x.fa\ns2 {other}\n")
    parsed, runs = samples.parse_samples(str(tsv))
    assert runs == {}
    assert parsed["s1"]["mode"] == "basecall"
    assert len(parsed["s1"]["inputs"]) == 2
    assert len(parsed["s1"]["pod5_files"]) == 5
    assert parsed["s1"]["reference"] == "/ref/x.fa"
    assert parsed["s2"]["reference"] is None


def test_tsv_rejects_bad_rows(tmp_path):
    tsv = tmp_path / "s.tsv"
    tsv.write_text("one\n")
    with pytest.raises(samples.SampleError, match="2 or 3"):
        samples.parse_samples(str(tsv))
    tsv.write_text("bad name /x\n")
    with pytest.raises(samples.SampleError):
        samples.parse_samples(str(tsv))


def test_yaml_barcoded_run_needs_kit(tmp_path, run):
    y = tmp_path / "s.yml"
    y.write_text(
        yaml.safe_dump({"runs": [{"path": str(run), "samples": {"a": "barcode01"}}]})
    )
    with pytest.raises(samples.SampleError, match="kit"):
        samples.parse_samples(str(y))


def test_yaml_demux_mode(tmp_path, run):
    y = tmp_path / "s.yml"
    y.write_text(
        yaml.safe_dump(
            {
                "runs": [
                    {
                        "path": str(run),
                        "kit": "SQK-NBD114-24",
                        "reference": "/ref/run.fa",
                        "samples": {
                            "a": "barcode01",
                            "b": {"barcode": "barcode02", "reference": "/ref/b.fa"},
                        },
                    }
                ]
            }
        )
    )
    parsed, runs = samples.parse_samples(str(y))
    assert parsed["a"]["mode"] == "demux" and parsed["a"]["pod5_files"] == []
    assert parsed["a"]["reference"] == "/ref/run.fa"
    assert parsed["b"]["reference"] == "/ref/b.fa"
    ((rid, info),) = runs.items()
    assert rid == "run"
    assert info["kit"] == "SQK-NBD114-24"
    assert info["samples"] == {"barcode01": "a", "barcode02": "b"}
    assert len(info["pod5_files"]) == 4


def test_yaml_prebasecalled_collects_minknow_bams(tmp_path, run):
    y = tmp_path / "s.yml"
    y.write_text(
        yaml.safe_dump(
            {
                "runs": [
                    {
                        "path": str(run),
                        "basecalled": True,
                        "samples": {"f15": "barcode15", "whole": None},
                    }
                ]
            }
        )
    )
    parsed, runs = samples.parse_samples(str(y))
    assert runs == {}
    assert parsed["f15"]["mode"] == "prebasecalled"
    assert [p.split("/")[-1] for p in parsed["f15"]["pod5_files"]] == ["bc15_0.pod5"]
    assert [p.split("/")[-1] for p in parsed["f15"]["bam_files"]] == ["bc15_0.bam"]
    parsed_fail, _ = samples.parse_samples(str(y), include_fail=True)
    assert len(parsed_fail["f15"]["pod5_files"]) == 2
    assert len(parsed_fail["f15"]["bam_files"]) == 2
    # unbarcoded prebasecalled sample: bam_pass/*.bam, pod5 pass only
    assert [p.split("/")[-1] for p in parsed["whole"]["bam_files"]] == ["plain_0.bam"]


def test_mixed_modes_rejected(tmp_path, run):
    y = tmp_path / "s.yml"
    y.write_text(
        yaml.safe_dump(
            {
                "runs": [
                    {
                        "path": str(run),
                        "basecalled": True,
                        "samples": {"x": "barcode15"},
                    },
                    {"path": str(run), "samples": {"x": None}},
                ]
            }
        )
    )
    with pytest.raises(samples.SampleError, match="mixes input kinds"):
        samples.parse_samples(str(y))


def test_run_id_disambiguation(tmp_path):
    a = tmp_path / "a" / "run"
    b = tmp_path / "b" / "run"
    _touch(a / "pod5" / "x.pod5")
    _touch(b / "pod5" / "y.pod5")
    tsv = tmp_path / "s.tsv"
    tsv.write_text(f"s1 {a}\ns2 {b}\n")
    parsed, _ = samples.parse_samples(str(tsv))
    assert parsed["s1"]["inputs"][0]["run_id"] == "run"
    assert parsed["s2"]["inputs"][0]["run_id"] == "run-2"
