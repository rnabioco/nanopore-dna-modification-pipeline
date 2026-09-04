# nanopore-dna-modification-pipeline

[![CI](https://github.com/rnabioco/nanopore-dna-modification-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/rnabioco/nanopore-dna-modification-pipeline/actions/workflows/ci.yml)
[![Lint](https://github.com/rnabioco/nanopore-dna-modification-pipeline/actions/workflows/lint.yml/badge.svg)](https://github.com/rnabioco/nanopore-dna-modification-pipeline/actions/workflows/lint.yml)
[![Docs](https://github.com/rnabioco/nanopore-dna-modification-pipeline/actions/workflows/docs.yml/badge.svg)](https://rnabioco.github.io/nanopore-dna-modification-pipeline/)

From a directory of Oxford Nanopore **DNA** POD5 files to aligned modBAMs,
per-site modification tables and QC, on the cluster, from one config file.

**Documentation:** <https://rnabioco.github.io/nanopore-dna-modification-pipeline/>
— start with the [walkthrough](https://rnabioco.github.io/nanopore-dna-modification-pipeline/getting-started/walkthrough/)
if you have a run directory in hand.

```
POD5 run ──► dorado basecaller ──► dorado aligner ──► bam/final ──► modkit pileup · summary · DMR
             simplex + stacked        (minimap2)          │          samtools · mosdepth · summary table
             mod models (GPU)                             ├──► DNAscent: index → detect (GPU) → forkSense
MinKNOW bam_pass (already basecalled) ────────────────────┘└──► custom steps (your scripts)
```

## Features

- **dorado 2.1.2** with a config-resolved model stack: one simplex model plus
  ONT modified-base models (`5mC_5hmC`, `5mCG_5hmCG`, `4mC_5mC`, `6mA`, by
  short code or full name) and your own dorado-format models, checked for
  conflicts before any GPU time is spent.
- **Three kinds of input**: plain POD5 runs, barcoded runs (one dorado pass
  with `--kit-name`, then `dorado demux`), and MinKNOW live-basecalled runs
  used as-is. POD5 is linked, never copied.
- **Downstream**: alignment with every tag preserved, modkit pileup /
  summary / per-read calls / bigWig / pairwise DMR, samtools and mosdepth QC,
  one summary table per project, a provenance manifest.
- **DNAscent** (optional): BrdU/EdU detection, a per-read table, forkSense
  origins and forks, from the maintainers' Singularity image.
- **Custom steps**: your commands as first-class rules with the pipeline's
  outputs as placeholders.
- **Clusters**: Slurm profiles for Bodhi and Alpine; dorado and DNAscent on
  the GPU queues. Everything installed and run through [pixi](https://pixi.sh).

## Quick start

```bash
git clone https://github.com/rnabioco/nanopore-dna-modification-pipeline.git
cd nanopore-dna-modification-pipeline
pixi install                    # snakemake, samtools, minimap2, modkit, mosdepth ...
pixi run setup                  # dorado 2.1.2 + the configured models + escpod (once, from one node)
pixi run dl-test-data && pixi run dry-run     # 5 MB synthetic fixture; builds the DAG
```

Then a samples file and a project config:

```
# config/gdna-samples.tsv
wt_rep1    /beevol/data/nanopore/20260901_gDNA_wt
mut_rep1   /beevol/data/nanopore/20260901_gDNA_mut
```

```yaml
# config/gdna.yml
samples: config/gdna-samples.tsv
output_directory: /beevol/home/me/results/gdna-2026-09
reference:
  fasta: /beevol/data/ref/chm13v2.0.fa
models:
  simplex: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  modified_bases: [5mC_5hmC, 6mA]
```

```bash
pixi run list-models --configfile config/gdna.yml         # what will be stacked
pixi run snakemake -n --configfile config/gdna.yml        # dry run
pixi run run-bodhi  --configfile config/gdna.yml          # or run-alpine, or run (local GPU)
```

Outputs land under `output_directory`: `bam/final/<sample>.bam`,
`summary/modkit/<sample>/<sample>.pileup.bed.gz`, `summary/qc/`,
`summary/samples_summary.tsv`, `manifest.json`.

## Documentation map

| Page | For |
|---|---|
| [Installation](docs/getting-started/installation.md) | pixi, `setup`, DNAscent image, checking the install |
| [Walkthrough](docs/getting-started/walkthrough.md) | step by step from a run directory to results |
| [Samples file](docs/user-guide/samples.md), [Configuration](docs/user-guide/configuration.md), [Models](docs/user-guide/models.md) | the inputs |
| [Running and monitoring](docs/user-guide/running.md), [Outputs](docs/user-guide/outputs.md) | the run |
| [DNAscent](docs/dnascent.md), [Custom steps](docs/custom-steps.md) | the optional stages |
| [Bodhi](docs/cluster/bodhi.md), [Alpine](docs/cluster/alpine.md) | site specifics |
| [Architecture](docs/development/architecture.md), [Contributing](docs/development/contributing.md) | for developers; `CLAUDE.md` for the conventions |

## License

MIT (see `LICENSE`). DNAscent is GPL-3.0 and is used as an external tool.
