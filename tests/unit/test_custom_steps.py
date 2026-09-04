import custom_steps as cs
import pytest


def test_parse_defaults_and_requires():
    steps = cs.parse_custom_steps(
        {
            "custom": [
                {
                    "name": "s1",
                    "command": "echo {sample} > {outdir}/x",
                    "requires": "modkit_pileup",
                }
            ]
        }
    )
    spec = steps["s1"]
    assert spec["scope"] == "sample"
    assert spec["requires"] == ["final_bam", "modkit_pileup"]
    assert spec["threads"] == 4 and spec["mem_mb"] == 16000


def test_parse_rejects_bad_entries():
    with pytest.raises(cs.CustomStepError, match="name"):
        cs.parse_custom_steps({"custom": [{"name": "1bad", "command": "x"}]})
    with pytest.raises(cs.CustomStepError, match="command"):
        cs.parse_custom_steps({"custom": [{"name": "ok"}]})
    with pytest.raises(cs.CustomStepError, match="scope"):
        cs.parse_custom_steps(
            {"custom": [{"name": "ok", "command": "x", "scope": "nope"}]}
        )
    with pytest.raises(cs.CustomStepError, match="unknown requires"):
        cs.parse_custom_steps(
            {"custom": [{"name": "ok", "command": "x", "requires": ["bogus"]}]}
        )
    with pytest.raises(cs.CustomStepError, match="twice"):
        cs.parse_custom_steps(
            {"custom": [{"name": "a", "command": "x"}, {"name": "a", "command": "y"}]}
        )


def test_render_command_and_outputs():
    steps = cs.parse_custom_steps(
        {
            "custom": [
                {
                    "name": "s",
                    "command": "tool --bam {bam} -o {outdir}/{sample}.tsv",
                    "outputs": ["{sample}.tsv"],
                    "prefix": "module load R &&",
                }
            ]
        }
    )
    cmd = cs.render_command(steps["s"], bam="/b.bam", outdir="/o", sample="x")
    assert cmd == "module load R && tool --bam /b.bam -o /o/x.tsv"
    assert cs.render_outputs(steps["s"], sample="x") == ["x.tsv"]


def test_render_unknown_placeholder_is_an_error():
    steps = cs.parse_custom_steps(
        {"custom": [{"name": "s", "command": "tool {dnascent_bam}"}]}
    )
    with pytest.raises(cs.CustomStepError, match="placeholder"):
        cs.render_command(steps["s"], bam="/b.bam")
