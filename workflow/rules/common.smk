"""Sample set, model stack, reference bookkeeping, and the final target list."""

import hashlib
import os
import re
import sys

from custom_steps import CustomStepError, parse_custom_steps
from models import ModelError
from models import resolve as resolve_models
from models import validate as validate_models
from samples import SampleError, parse_samples

outdir = config["output_directory"]
OUTDIR_ABS = os.path.abspath(outdir)

# Which cluster this DAG is being built on. Only used for defaults that are a
# property of the site (singularity bind mounts); scheduling lives in the
# cluster profiles.
if os.path.isdir("/scratch/alpine"):
    CLUSTER = "alpine"
elif os.path.isdir("/beevol"):
    CLUSTER = "bodhi"
else:
    CLUSTER = "unknown"


# ---------------------------------------------------------------------------
# Samples
# ---------------------------------------------------------------------------
try:
    samples, barcoded_runs = parse_samples(
        config["samples"],
        default_kit=config["dorado"].get("kit"),
        include_fail=bool(config.get("minknow", {}).get("include_fail", False)),
    )
except SampleError as exc:
    sys.exit(f"samples file error: {exc}")

SAMPLES = list(samples)


def samples_in_mode(mode):
    return [s for s, info in samples.items() if info["mode"] == mode]


def mode_constraint(*modes):
    """A wildcard regex matching exactly the samples in the given modes.

    Three rules write bam/basecall/{sample}/{sample}.bam (dorado basecall,
    demux collection, MinKNOW collection); constraining each to its own
    samples is what keeps the DAG unambiguous. A never-matching pattern is
    returned when no sample is in the mode, so the rule is simply inert.
    """
    names = [s for m in modes for s in samples_in_mode(m)]
    return "|".join(re.escape(s) for s in names) if names else "__no_sample__"


def run_constraint():
    return (
        "|".join(re.escape(r) for r in barcoded_runs) if barcoded_runs else "__no_run__"
    )


# ---------------------------------------------------------------------------
# Models (only needed when something is basecalled)
# ---------------------------------------------------------------------------
NEEDS_BASECALL = bool(samples_in_mode("basecall") or samples_in_mode("demux"))
MODEL_STACK = None
if NEEDS_BASECALL:
    try:
        MODEL_STACK = resolve_models(config, PIPELINE_DIR)
        for warning in validate_models(MODEL_STACK):
            logger.warning(f"models: {warning}")
    except ModelError as exc:
        sys.exit(f"model stack error: {exc}")
    _missing = MODEL_STACK.missing
    if _missing:
        for m in _missing:
            hint = (
                "pixi run install-models"
                if m.source == "ont"
                else "check models.custom"
            )
            logger.warning(f"model not installed: {m.name} -> {m.path} ({hint})")


def model_inputs():
    """Files that pin the model stack into the DAG (a swapped model reruns basecalling)."""
    if MODEL_STACK is None:
        return []
    return [os.path.join(m.path, "config.toml") for m in MODEL_STACK.all if m.present]


# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------
def _ref_key(fasta):
    stem = os.path.basename(fasta)
    for ext in (".gz", ".fasta", ".fa", ".fna"):
        if stem.endswith(ext):
            stem = stem[: -len(ext)]
    digest = hashlib.sha1(os.path.abspath(fasta).encode()).hexdigest()[:8]
    return f"{re.sub(r'[^A-Za-z0-9._-]', '_', stem)}-{digest}"


def reference_for(sample):
    """Absolute path of the genome FASTA a sample aligns to."""
    fasta = samples[sample].get("reference") or config["reference"].get("fasta")
    if not fasta:
        sys.exit(
            f"no reference for sample {sample!r}: set reference.fasta in the config "
            "or a per-sample reference in the samples file"
        )
    fasta = fasta if os.path.isabs(fasta) else os.path.join(PIPELINE_DIR, fasta)
    if not os.path.exists(fasta):
        sys.exit(f"reference FASTA not found: {fasta}")
    return os.path.abspath(fasta)


REFERENCES = {}
for _s in SAMPLES:
    _fa = reference_for(_s)
    REFERENCES[_ref_key(_fa)] = _fa


def ref_key_for(sample):
    return _ref_key(reference_for(sample))


def ref_dir(key):
    return os.path.join(outdir, "reference", key)


def staged_fasta(sample):
    return os.path.join(ref_dir(ref_key_for(sample)), "genome.fa")


def staged_fai(sample):
    return staged_fasta(sample) + ".fai"


def staged_sizes(sample):
    return os.path.join(ref_dir(ref_key_for(sample)), "genome.chrom.sizes")


def staged_mmi(sample):
    return os.path.join(ref_dir(ref_key_for(sample)), "genome.mmi")


# ---------------------------------------------------------------------------
# Custom steps
# ---------------------------------------------------------------------------
try:
    CUSTOM_STEPS = parse_custom_steps(config)
except CustomStepError as exc:
    sys.exit(f"custom steps error: {exc}")


# ---------------------------------------------------------------------------
# Cleanup tiers
# ---------------------------------------------------------------------------
_CLEANUP_TIERS = {"basecall", "demux"}


def _enabled_cleanup_tiers():
    cfg = config.get("cleanup_intermediates", False)
    if cfg is True:
        return set(_CLEANUP_TIERS)
    if not cfg:
        return set()
    return set(cfg) & _CLEANUP_TIERS


def maybe_temp(path, tier):
    return temp(path) if tier in _enabled_cleanup_tiers() else path


# ---------------------------------------------------------------------------
# Paths shared between rule files
# ---------------------------------------------------------------------------
def basecall_bam(sample):
    return os.path.join(outdir, "bam", "basecall", sample, f"{sample}.bam")


def final_bam(sample):
    return os.path.join(outdir, "bam", "final", sample, f"{sample}.bam")


def sample_pod5_dir(sample):
    return os.path.join(outdir, "pod5", "samples", sample, "pod5")


def sample_pod5_manifest(sample):
    return os.path.join(outdir, "pod5", "samples", sample, "pod5_files.txt")


def pileup_bed(sample):
    return os.path.join(outdir, "summary", "modkit", sample, f"{sample}.pileup.bed.gz")


def read_summary(sample):
    return os.path.join(
        outdir, "summary", "tables", sample, f"{sample}.read_summary.tsv.gz"
    )


def dnascent_bam(sample):
    return os.path.join(outdir, "dnascent", sample, f"{sample}.detect.bam")


# ---------------------------------------------------------------------------
# Final targets
# ---------------------------------------------------------------------------
def pipeline_outputs():
    outs = []
    for s in SAMPLES:
        outs.append(final_bam(s))
        outs.append(final_bam(s) + ".bai")
        outs.append(os.path.join(outdir, "summary", "qc", s, f"{s}.flagstat.tsv"))
        outs.append(os.path.join(outdir, "summary", "qc", s, f"{s}.stats.txt"))
        if config["qc"].get("mosdepth", True):
            outs.append(
                os.path.join(outdir, "summary", "qc", s, f"{s}.mosdepth.summary.txt")
            )
        if config["qc"].get("read_summary", True):
            outs.append(read_summary(s))
        if config["modkit"].get("pileup", True):
            outs.append(pileup_bed(s))
            outs.append(pileup_bed(s) + ".tbi")
        if config["modkit"].get("summary", True):
            outs.append(
                os.path.join(outdir, "summary", "modkit", s, f"{s}.modkit_summary.tsv")
            )
        if config["modkit"].get("extract_calls", False):
            outs.append(
                os.path.join(outdir, "summary", "modkit", s, f"{s}.mod_calls.tsv.gz")
            )
        if config["modkit"].get("bigwig", False):
            outs.append(
                os.path.join(outdir, "summary", "modkit", s, f"{s}.bigwig.done")
            )
    for c in config.get("dmr", {}).get("contrasts") or []:
        outs.append(os.path.join(outdir, "summary", "dmr", f"{c['name']}.dmr.bed"))
    if config["dnascent"]["enabled"]:
        for s in SAMPLES:
            outs.append(os.path.join(outdir, "dnascent", s, f"{s}.detect.sorted.bam"))
            if config["dnascent"].get("per_read_probs", True):
                outs.append(os.path.join(outdir, "dnascent", s, f"{s}.per_read.tsv.gz"))
            if config["dnascent"]["forksense"].get("enabled", True):
                outs.append(
                    os.path.join(outdir, "dnascent", s, "forksense", f"{s}.forkSense")
                )
    for name, spec in CUSTOM_STEPS.items():
        if spec["scope"] == "sample":
            outs += [
                os.path.join(outdir, "summary", "custom", name, s, ".done")
                for s in SAMPLES
            ]
        else:
            outs.append(
                os.path.join(outdir, "summary", "custom", name, "project", ".done")
            )
    outs.append(os.path.join(outdir, "summary", "samples_summary.tsv"))
    return outs


wildcard_constraints:
    sample="|".join(re.escape(s) for s in SAMPLES),
    ref="|".join(re.escape(k) for k in REFERENCES),


def report_metadata():
    try:
        from git import Repo

        commit = Repo(PIPELINE_DIR).head.commit
        logger.info(f"Pipeline commit: {commit}")
    # No checkout, no git binary, empty repository: none of these should stop a run.
    except Exception:  # noqa: BLE001
        logger.warning("Pipeline commit: unable to resolve git commit")
    logger.info(f"Cluster: {CLUSTER}; output_directory: {OUTDIR_ABS}")
    logger.info(
        "Samples: " + ", ".join(f"{s} [{info['mode']}]" for s, info in samples.items())
    )
    if MODEL_STACK is not None:
        logger.info("Model stack: " + " + ".join(m.name for m in MODEL_STACK.all))
    if config["dnascent"]["enabled"]:
        logger.info("DNAscent: enabled")
