# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.
The global rules in `~/.claude/CLAUDE.md` (never copy POD5/BAM into the tree,
write tables compressed, nothing in `~/.cache`) apply on top of this.

## What this is

A Snakemake 9 pipeline for Oxford Nanopore **DNA** runs: dorado basecalling
with a config-resolved stack of modified-base models (ONT + custom), genome
alignment, modkit summaries, optional DNAscent (BrdU/EdU, replication forks),
and config-driven custom steps. pixi manages everything; Slurm profiles exist
for Bodhi and Alpine with dorado and DNAscent on the GPU queues. It is
modelled on `rnabioco/aa-tRNA-seq-pipeline` (same layout, same conventions).

## Setup and running

```bash
pixi install                      # conda-forge/bioconda tools (pixi.lock is committed)
pixi run setup                    # dorado 2.1.2 + configured models + escpod -> resources/ (ONE node, once)
pixi run install-dnascent         # optional 5 GB Singularity image
pixi run dl-test-data             # synthetic CI fixture
pixi run dry-run                  # DAG of config/config-test.yml
pixi run list-models  --configfile config/x.yml
pixi run run-bodhi    --configfile config/x.yml   # or run-alpine / run
pixi run lint && pixi run -e test test-unit       # what CI runs
```

Heavy work (setup downloads, real runs, fixture building) goes in its own
Slurm allocation, never the session shell. `pixi run fmt` before committing.

## Layout

```
workflow/Snakefile              onstart PATH prefix (dorado, escpod) + strict-mode shell prefix, includes, rule all
workflow/rules/common.smk       samples + modes, model stack, references, cleanup tiers, pipeline_outputs()
workflow/rules/basecall.smk     POD5 staging (links), basecall / basecall_run+demux / MinKNOW collection
workflow/rules/align.smk        stage_reference, mm2_index, align (dorado aligner | minimap2), finalize_bam
workflow/rules/modcall.smk      modkit pileup / summary / extract calls / bigwig / dmr
workflow/rules/qc.smk           samtools, mosdepth, dorado summary, samples_summary
workflow/rules/dnascent.smk     index, detect (GPU), sort, per-read table, forkSense (only if enabled)
workflow/rules/custom.smk       generic {step} rules driven by config `custom:`
workflow/rules/clean.smk        `snakemake clean`
workflow/scripts/models.py      THE model resolver (also the CLI behind list-/check-/install-models)
workflow/scripts/samples.py     samples file parser: TSV / YAML, modes basecall | demux | prebasecalled
workflow/scripts/custom_steps.py, link_pod5.py, dnascent_per_read.py, summarize_samples.py, generate_manifest.py
config/config-base.yml          every key, documented; projects layer over it
cluster/bodhi, cluster/alpine   Slurm profiles (partition/account/qos/gres per rule)
scripts/setup-tools.sh          dorado/models/escpod install with pinned checksums; install-dnascent.sh
tests/unit                      pytest over the scripts (no data needed)
docs/                           dnascent.md, custom-steps.md, cluster/*.md, dev-notes/dnascent-onnx-escpod.md
```

## Key design points

- **Three input modes**, decided per sample by the samples file: `basecall`
  (POD5 → dorado per sample), `demux` (barcoded run → one dorado pass with
  `--kit-name`, then `dorado demux --no-classify`), `prebasecalled` (MinKNOW
  `bam_pass` used as-is; POD5 still located per barcode for DNAscent). Three
  rules write `bam/basecall/{sample}/{sample}.bam`; `mode_constraint()`
  keeps them disjoint.
- **POD5 is never copied.** `link_pod5.py` hardlinks (same filesystem) or
  symlinks into `output_directory/pod5/`. dorado and DNAscent read that
  directory.
- **Model stack** = `models.simplex` + `models.modified_bases` (short codes
  expanded through `models.mod_versions` to pinned ONT names) +
  `models.custom` (local dorado-format directories). `models.py` refuses two
  models on one canonical base and mod models from another simplex model.
  The resolved `config.toml` files are rule inputs, so swapping a model
  reruns basecalling. Passed to dorado as `--modified-bases-models a,b,c`.
- **dorado.resume**: the basecall writes `<out>.bam.partial` outside the
  declared outputs and passes `--resume-from` on retry.
- **Alignment** keeps every tag (`dorado aligner --no-sort | samtools view -F
  0x904 | samtools sort`); `bam/final` is a hardlink of `bam/aligned`.
- **DNAscent** runs through Singularity (`--nv -B /beevol ...`) or a native
  binary (`dnascent.command`); all paths handed to it are absolute; forkSense
  runs inside `dnascent/<s>/forksense/` because it writes fixed-name BEDs to
  cwd. modBAM codes: `N+b` BrdU, `N+e` EdU, `ML = p*255`.
- **Custom steps**: `custom:` entries become `custom_sample_step` /
  `custom_project_step` instances with `{bam} {reference} {outdir} ...`
  placeholders, a `.done` sentinel and an output-existence check.
- **Cluster**: per-rule `qos` resource (Alpine) rather than profile-wide
  `slurm-qos`; `slurm-status-command: squeue` (Bodhi); GPU rules are
  `basecall`, `basecall_run`, `dnascent_detect`.
- `shell.prefix()` in `onstart` REPLACES snakemake's default prefix; the `set
  -euo pipefail` there is load-bearing.

## Conventions

- Conventional Commits; branch per change in `.claude/worktrees/`; land via
  PR (see the user's git-workflow skill). Bump `pixi.toml` version + CHANGELOG
  on release.
- Lint gates: `snakefmt --check workflow/`, `ruff check`/`format --check` on
  `workflow/scripts tests`, `yamllint config/ cluster/ .github/`. ruff is
  pinned to a minor and the rule set is explicit in `ruff.toml`.
- Anything that measures a cluster resource belongs as a comment next to the
  number in the profile (what was measured, when, on what).
- Tabular outputs are gzipped (`.tsv.gz`, bgzip+tabix for BEDs).

## Testing

- `pixi run -e test test-unit`: parsers and resolver, no data.
- `pixi run dry-run`: DAG over the synthetic fixture (`.tests/data`, from
  `dl-test-data`). Runs in CI without dorado.
- `pixi run test`: executes the DAG on the synthetic reads (needs a GPU;
  outputs are nearly empty because the reads are synthetic).
- A real fixture: `pixi run make-test-data <run> <name> [n] [bam] [region]`
  in an allocation, then a config pointing `samples` at
  `.tests/fixtures/<name>`.
