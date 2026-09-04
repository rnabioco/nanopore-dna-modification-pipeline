"""Parse the samples file and locate each sample's POD5 (and MinKNOW BAM) files.

Two formats, chosen by extension.

TSV (no header), two or three whitespace-separated columns::

    sample_id    /path/to/run_dir_or_pod5_dir_or_file    [/path/to/reference.fa]

A sample_id repeated on several rows has several input runs, which are
basecalled together. The optional third column overrides ``reference.fasta``
for that sample.

YAML, for barcoded (multiplexed) runs, already-basecalled runs, and per-run
settings::

    runs:
      - path: /path/to/pooled/run           # run directory
        kit: SQK-NBD114-24                  # dorado --kit-name (barcoded runs)
        reference: /ref/genome.fa           # optional, applies to the run's samples
        samples:
          wt_rep1: barcode01
          mut_rep1: {barcode: barcode02, reference: /ref/other.fa}
      - path: /path/to/minknow/run/results  # MinKNOW live-basecalled
        basecalled: true                    # use bam_pass/<barcode>/*.bam, skip dorado
        samples:
          fork_15: barcode15
      - path: /path/to/unbarcoded/run
        samples:
          control: ~                        # null barcode = the whole run

Each sample resolves to one of three modes:

``basecall``       POD5 -> dorado basecaller (the default),
``demux``          barcoded run -> one dorado basecall per run with
                   --kit-name, then ``dorado demux`` into samples,
``prebasecalled``  MinKNOW's BAMs are collected as-is; POD5 is still located
                   (per barcode, under pod5_pass/<barcode>) for signal-level
                   steps such as DNAscent.

POD5 files are found under the usual MinKNOW subdirectories (``pod5_pass``,
``pod5_fail``, ``pod5``, ``pod5_skip``), searched recursively; a directory
holding .pod5 files directly, or a single .pod5 file, also works. Files are
only ever referenced by absolute path: the pipeline links them into its
output tree and never copies them.
"""

from __future__ import annotations

import glob
import os
import re

import yaml

POD5_SUBDIRS = ("pod5_pass", "pod5_fail", "pod5", "pod5_skip")
POD5_PASS_SUBDIRS = ("pod5_pass", "pod5")
BAM_SUBDIRS = ("bam_pass", "bam_fail")
BAM_PASS_SUBDIRS = ("bam_pass",)
SAMPLE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
BARCODE_RE = re.compile(r"^[A-Za-z0-9_-]+$")
MODES = ("basecall", "demux", "prebasecalled")


class SampleError(Exception):
    """The samples file cannot be turned into a runnable sample set."""


def _rglob(directory: str, ext: str) -> list[str]:
    return glob.glob(os.path.join(directory, "**", f"*{ext}"), recursive=True)


def _collect(
    path: str,
    ext: str,
    subdirs: tuple[str, ...],
    barcode: str | None,
    prefer_direct: bool = False,
) -> list[str]:
    """Files with ``ext`` under ``path``: in the MinKNOW subdirs (per barcode
    when given), else directly under ``path``.

    ``prefer_direct``: when a subdir holds files at its top level, take only
    those instead of recursing. Used for MinKNOW BAMs, where a barcoded run's
    per-barcode subdirectories are separate samples and a null barcode must
    not silently pool them. POD5 is always collected recursively: signal for
    every read of the run is what dorado (and DNAscent's index) should see.
    """
    p = os.path.abspath(path)
    if os.path.isfile(p):
        if p.endswith(ext):
            return [os.path.realpath(p)]
        raise SampleError(f"not a {ext} file: {p}")
    if not os.path.isdir(p):
        raise SampleError(f"input path does not exist: {p}")
    found: list[str] = []
    for sub in subdirs:
        d = os.path.join(p, sub, barcode) if barcode else os.path.join(p, sub)
        if not os.path.isdir(d):
            continue
        direct = glob.glob(os.path.join(d, f"*{ext}")) if prefer_direct else []
        found.extend(direct or _rglob(d, ext))
    if not found and not barcode:
        found = _rglob(p, ext)
    return sorted({os.path.realpath(f) for f in found})


def find_pod5_files(
    path: str, barcode: str | None = None, include_fail: bool = True
) -> list[str]:
    """Every POD5 under a run directory (absolute, sorted, deduplicated)."""
    return _collect(
        path, ".pod5", POD5_SUBDIRS if include_fail else POD5_PASS_SUBDIRS, barcode
    )


def find_minknow_bams(
    path: str, barcode: str | None = None, include_fail: bool = False
) -> list[str]:
    """MinKNOW's basecalled BAMs for a run (per barcode when given)."""
    return _collect(
        path,
        ".bam",
        BAM_SUBDIRS if include_fail else BAM_PASS_SUBDIRS,
        barcode,
        prefer_direct=True,
    )


def _check_name(name: str, what: str) -> str:
    if not SAMPLE_NAME_RE.match(name):
        raise SampleError(
            f"{what} {name!r} must match {SAMPLE_NAME_RE.pattern} (letters, digits, '.', '_', '-'; no spaces)"
        )
    return name


def _run_id(path: str, taken: dict[str, str]) -> str:
    """Stable id for a run: the directory basename, disambiguated if reused."""
    base = os.path.basename(os.path.abspath(path).rstrip("/")) or "run"
    base = re.sub(r"[^A-Za-z0-9._-]", "_", base)
    base = base.removesuffix(".pod5")
    rid, n = base, 1
    while rid in taken and taken[rid] != os.path.abspath(path):
        n += 1
        rid = f"{base}-{n}"
    taken[rid] = os.path.abspath(path)
    return rid


def _new_sample() -> dict:
    return {"inputs": [], "reference": None}


def _set_reference(entry: dict, sample: str, reference: str | None, where: str) -> None:
    if reference:
        if entry["reference"] not in (None, reference):
            raise SampleError(
                f"{where}: sample {sample!r} given two different references"
            )
        entry["reference"] = reference


def parse_samples_tsv(path: str) -> tuple[dict, dict]:
    samples: dict[str, dict] = {}
    run_paths: dict[str, str] = {}
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) not in (2, 3):
                raise SampleError(
                    f"{path}:{lineno}: expected 2 or 3 whitespace-separated columns "
                    f"(sample_id, path[, reference]); got {len(fields)}"
                )
            sample = _check_name(fields[0], "sample id")
            entry = samples.setdefault(sample, _new_sample())
            _set_reference(
                entry,
                sample,
                fields[2] if len(fields) == 3 else None,
                f"{path}:{lineno}",
            )
            entry["inputs"].append(
                {
                    "run_id": _run_id(fields[1], run_paths),
                    "path": fields[1],
                    "barcode": None,
                    "basecalled": False,
                }
            )
    return samples, {}


def parse_samples_yaml(path: str, default_kit: str | None = None) -> tuple[dict, dict]:
    with open(path) as fh:
        data = yaml.safe_load(fh) or {}
    if "runs" not in data or not isinstance(data["runs"], list):
        raise SampleError(
            f"{path}: YAML samples file must have a top-level 'runs' list"
        )

    samples: dict[str, dict] = {}
    runs: dict[str, dict] = {}
    run_paths: dict[str, str] = {}
    for idx, run in enumerate(data["runs"]):
        if not isinstance(run, dict) or "path" not in run or "samples" not in run:
            raise SampleError(f"{path}: run #{idx} needs 'path' and 'samples'")
        run_path = run["path"]
        rid = _run_id(run_path, run_paths)
        kit = run.get("kit", default_kit)
        basecalled = bool(run.get("basecalled", False))
        run_ref = run.get("reference")
        barcoded_here: dict[str, str] = {}
        for sample, value in (run["samples"] or {}).items():
            sample = _check_name(str(sample), "sample id")
            barcode, reference = None, run_ref
            if isinstance(value, dict):
                barcode = value.get("barcode")
                reference = value.get("reference", run_ref)
            elif value is not None:
                barcode = str(value)
            if barcode is not None:
                barcode = str(barcode)
                if not BARCODE_RE.match(barcode):
                    raise SampleError(
                        f"{path}: barcode {barcode!r} for sample {sample!r} has unexpected characters"
                    )
                if barcode in barcoded_here:
                    raise SampleError(
                        f"{path}: barcode {barcode!r} assigned twice in run {run_path}"
                    )
                barcoded_here[barcode] = sample
                if not kit and not basecalled:
                    raise SampleError(
                        f"{path}: run {run_path} assigns barcodes but names no 'kit' "
                        "(dorado --kit-name, e.g. SQK-NBD114-24)"
                    )
            entry = samples.setdefault(sample, _new_sample())
            _set_reference(entry, sample, reference, path)
            entry["inputs"].append(
                {
                    "run_id": rid,
                    "path": run_path,
                    "barcode": barcode,
                    "basecalled": basecalled,
                }
            )
        if barcoded_here and not basecalled:
            runs[rid] = {"path": run_path, "kit": kit, "samples": barcoded_here}
    return samples, runs


def _mode_of(sample: str, entry: dict) -> str:
    modes = set()
    for inp in entry["inputs"]:
        if inp["basecalled"]:
            modes.add("prebasecalled")
        elif inp["barcode"] is not None:
            modes.add("demux")
        else:
            modes.add("basecall")
    if len(modes) != 1:
        raise SampleError(
            f"sample {sample!r} mixes input kinds {sorted(modes)}; split it into one sample per kind"
        )
    return modes.pop()


def parse_samples(
    path: str, default_kit: str | None = None, include_fail: bool = False
) -> tuple[dict, dict]:
    """Parse a samples file. Returns ``(samples, barcoded_runs)``.

    ``samples[name]`` has ``inputs`` (list of ``{run_id, path, barcode,
    basecalled}``), ``reference`` (str | None), ``mode`` (see module doc),
    ``pod5_files`` (empty for ``demux`` samples, whose signal belongs to the
    run) and ``bam_files`` (``prebasecalled`` only).

    ``barcoded_runs[run_id]`` (``demux`` runs only) has ``path``, ``kit``,
    ``samples`` (``{barcode: sample}``) and ``pod5_files``.

    ``include_fail`` controls whether MinKNOW's *_fail directories are used
    for prebasecalled runs (POD5 is always taken from pass+fail for runs the
    pipeline basecalls itself, because dorado re-decides pass/fail).
    """
    if path.endswith((".yml", ".yaml")):
        samples, runs = parse_samples_yaml(path, default_kit)
    else:
        samples, runs = parse_samples_tsv(path)
    if not samples:
        raise SampleError(f"no samples found in {path}")

    for name, entry in samples.items():
        mode = _mode_of(name, entry)
        entry["mode"] = mode
        entry["bam_files"] = []
        if mode == "demux":
            entry["pod5_files"] = []
            continue
        pod5: list[str] = []
        bams: list[str] = []
        for inp in entry["inputs"]:
            if mode == "prebasecalled":
                pod5.extend(
                    find_pod5_files(
                        inp["path"], inp["barcode"], include_fail=include_fail
                    )
                )
                bams.extend(
                    find_minknow_bams(
                        inp["path"], inp["barcode"], include_fail=include_fail
                    )
                )
            else:
                pod5.extend(find_pod5_files(inp["path"]))
        entry["pod5_files"] = sorted(set(pod5))
        entry["bam_files"] = sorted(set(bams))
        where = ", ".join(
            i["path"] + (f" [{i['barcode']}]" if i["barcode"] else "")
            for i in entry["inputs"]
        )
        if not entry["pod5_files"]:
            raise SampleError(f"no POD5 files found for sample {name!r} under {where}")
        if mode == "prebasecalled" and not entry["bam_files"]:
            raise SampleError(
                f"no MinKNOW BAM files (bam_pass) found for sample {name!r} under {where}"
            )

    for rid, run in runs.items():
        run["pod5_files"] = find_pod5_files(run["path"])
        if not run["pod5_files"]:
            raise SampleError(f"no POD5 files found for run {rid} under {run['path']}")
    return samples, runs
