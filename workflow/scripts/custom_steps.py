"""Config-driven custom analysis steps.

A project can bolt its own downstream analyses onto the pipeline without
editing any rule, by listing them under ``custom`` in its config::

    custom:
      - name: fork_probs                 # rule/output name, [A-Za-z][A-Za-z0-9_-]*
        scope: sample                    # sample (default) | project
        requires: [final_bam]            # upstream artifacts to wait for
        command: >
          python scripts/custom/extract_probs.py
            --bam {bam} --reference {reference} --out {outdir}/{sample}.probs.tsv.gz
        outputs: ["{sample}.probs.tsv.gz"]   # must exist in {outdir} afterwards
        threads: 4
        mem_mb: 16000
        prefix: ""                       # e.g. "module load R/4.5.1 &&"

``command`` is a Python format string. Placeholders available to a
sample-scoped step: ``{sample} {bam} {bai} {reference} {outdir} {threads}
{pipeline_dir} {results_dir}`` plus, when listed in ``requires``,
``{pileup}`` (modkit bedMethyl), ``{read_summary}`` and ``{dnascent_bam}``.
A project-scoped step runs once and gets ``{samples}`` and ``{bams}``
(space-separated) instead of the per-sample ones. Relative paths in the
command are resolved from the pipeline directory, which is where snakemake
runs.

Outputs land in ``<output_directory>/summary/custom/<name>/<sample>/`` (or
``.../<name>/project/``); the rule records a ``.done`` sentinel and fails if
any declared output is missing, so a step that silently produced nothing is
caught.
"""

from __future__ import annotations

import re

STEP_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
SCOPES = ("sample", "project")
REQUIRES = ("final_bam", "modkit_pileup", "read_summary", "dnascent_bam")
DEFAULTS = {
    "scope": "sample",
    "requires": ["final_bam"],
    "outputs": [],
    "threads": 4,
    "mem_mb": 16000,
    "prefix": "",
}


class CustomStepError(Exception):
    """A ``custom`` entry that cannot be turned into a rule."""


def parse_custom_steps(config: dict) -> dict[str, dict]:
    """Validate ``config['custom']`` and return ``{name: spec}`` with defaults filled."""
    steps: dict[str, dict] = {}
    for idx, raw in enumerate(config.get("custom") or []):
        if not isinstance(raw, dict):
            raise CustomStepError(
                f"custom[{idx}] must be a mapping, got {type(raw).__name__}"
            )
        name = raw.get("name")
        if not name or not STEP_NAME_RE.match(str(name)):
            raise CustomStepError(
                f"custom[{idx}]: 'name' must match {STEP_NAME_RE.pattern}, got {name!r}"
            )
        if name in steps:
            raise CustomStepError(f"custom step {name!r} defined twice")
        if not raw.get("command"):
            raise CustomStepError(f"custom step {name!r}: 'command' is required")
        spec = {**DEFAULTS, **raw}
        spec["name"] = str(name)
        spec["command"] = " ".join(str(spec["command"]).split())
        if spec["scope"] not in SCOPES:
            raise CustomStepError(
                f"custom step {name!r}: scope must be one of {SCOPES}, got {spec['scope']!r}"
            )
        if isinstance(spec["requires"], str):
            spec["requires"] = [spec["requires"]]
        unknown = [r for r in spec["requires"] if r not in REQUIRES]
        if unknown:
            raise CustomStepError(
                f"custom step {name!r}: unknown requires {unknown}; choose from {REQUIRES}"
            )
        if "final_bam" not in spec["requires"]:
            spec["requires"] = ["final_bam", *spec["requires"]]
        if isinstance(spec["outputs"], str):
            spec["outputs"] = [spec["outputs"]]
        spec["threads"] = int(spec["threads"])
        spec["mem_mb"] = int(spec["mem_mb"])
        steps[spec["name"]] = spec
    return steps


def render_command(spec: dict, **values) -> str:
    """Fill the command template; an unknown placeholder is an error, not ''."""
    try:
        body = spec["command"].format(**values)
    except KeyError as exc:
        raise CustomStepError(
            f"custom step {spec['name']!r}: command uses placeholder {exc} which is not "
            f"available for scope {spec['scope']!r} with requires {spec['requires']}"
        ) from None
    prefix = str(spec.get("prefix") or "").strip()
    return f"{prefix} {body}".strip() if prefix else body


def render_outputs(spec: dict, **values) -> list[str]:
    try:
        return [str(o).format(**values) for o in spec["outputs"]]
    except KeyError as exc:
        raise CustomStepError(
            f"custom step {spec['name']!r}: outputs use unknown placeholder {exc}"
        ) from None
