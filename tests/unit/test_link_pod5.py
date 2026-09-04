import os

import link_pod5


def test_stage_links_and_manifest(tmp_path):
    src_a = tmp_path / "runA" / "pod5_pass"
    src_b = tmp_path / "runB" / "pod5_pass"
    src_a.mkdir(parents=True)
    src_b.mkdir(parents=True)
    (src_a / "x_0.pod5").write_bytes(b"A")
    (src_b / "x_0.pod5").write_bytes(b"B")  # same basename, different run
    out = tmp_path / "links"
    manifest = tmp_path / "pod5_files.txt"
    assert (
        link_pod5.stage(
            [str(src_a / "x_0.pod5"), str(src_b / "x_0.pod5")], str(out), str(manifest)
        )
        == 0
    )
    staged = sorted(os.listdir(out))
    assert staged == ["00000_x_0.pod5", "00001_x_0.pod5"]
    assert (out / "00000_x_0.pod5").read_bytes() == b"A"
    assert (out / "00001_x_0.pod5").read_bytes() == b"B"
    # same filesystem -> hardlinks, no extra copies
    assert os.stat(out / "00000_x_0.pod5").st_nlink == 2
    lines = manifest.read_text().splitlines()
    assert len(lines) == 2 and lines[0].split("\t")[1] == str(
        (src_a / "x_0.pod5").resolve()
    )
    # re-staging is idempotent (stale links removed, no duplicates)
    assert link_pod5.stage([str(src_a / "x_0.pod5")], str(out), str(manifest)) == 0
    assert sorted(os.listdir(out)) == ["00000_x_0.pod5"]


def test_missing_input_fails(tmp_path):
    assert (
        link_pod5.stage(
            [str(tmp_path / "nope.pod5")], str(tmp_path / "o"), str(tmp_path / "m.txt")
        )
        == 1
    )
