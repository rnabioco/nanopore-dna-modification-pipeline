# nanopore-dna-modification-pipeline

A Snakemake pipeline for Oxford Nanopore **DNA** sequencing: dorado
basecalling with a configurable stack of modified-base models (ONT's and your
own), genome alignment, modkit summaries, optional
[DNAscent](https://dnascent.readthedocs.io) BrdU/EdU detection and replication
fork analysis, and config-driven custom downstream steps. Everything is
installed and run through [pixi](https://pixi.sh); cluster profiles are
provided for Bodhi and Alpine, with dorado and DNAscent on the GPU queues.

```
POD5 ──► dorado basecaller ──► dorado aligner ──► bam/final ──► modkit pileup / summary / DMR
         (simplex + stacked      (minimap2)          │            samtools / mosdepth QC
          mod models, GPU)                           ├──► DNAscent index → detect (GPU) → forkSense
                                                     └──► custom steps (your scripts)
MinKNOW bam_pass ──────────────────────┘ (already-basecalled runs skip dorado)
```

## Quick start

```bash
git clone <this repo> && cd nanopore-dna-modification-pipeline
pixi install                    # tools from conda-forge/bioconda
pixi run setup                  # dorado 2.1.2 + the configured models + escpod (run from ONE node)
pixi run install-dnascent       # optional, 5 GB Singularity image
pixi run dl-test-data           # tiny synthetic fixture
pixi run dry-run                # build the DAG
pixi run list-models            # what the config resolves to
```

Then write a project config and samples file (see `config/README.md`) and run:

```bash
pixi run run-bodhi  --configfile config/my-project.yml     # Bodhi (rna + gpu)
pixi run run-alpine --configfile config/my-project.yml     # Alpine (acpu + aa100)
pixi run run        --configfile config/my-project.yml     # local machine with a GPU
```

## What you configure

| Config key | What it drives |
|---|---|
| `dorado.version` | The dorado release `pixi run setup` installs (2.1.2). |
| `models.simplex`, `models.modified_bases`, `models.custom` | The basecalling model and the modified-base models stacked on it: ONT names (short codes like `5mC_5hmC` expand to pinned versions) plus local dorado-format model directories. |
| samples file | POD5 runs, barcoded runs (`kit:`), MinKNOW-basecalled runs (`basecalled: true`), per-sample references. |
| `align.tool` | `dorado` aligner (default, keeps every tag) or `minimap2`. |
| `modkit.*`, `dmr.contrasts` | Pileup thresholds, motifs/CpG, per-read calls, bigWigs, pairwise DMR. |
| `dnascent.*` | Enable DNAscent, run on GPU/CPU, image or binary, forkSense options. |
| `custom` | Your own per-sample or per-project commands, run on the final BAM (and pileups / DNAscent output). |

`config/config-base.yml` documents every key; a project config only states what
differs.

## Outputs (`output_directory/`)

```
bam/final/<s>/<s>.bam(.bai)              aligned, sorted, MM/ML + mv tags preserved
summary/modkit/<s>/<s>.pileup.bed.gz     bedMethyl (+ .tbi), <s>.modkit_summary.tsv, optional mod_calls / bigWigs
summary/qc/<s>/                          flagstat, samtools stats, mosdepth
summary/tables/<s>/<s>.read_summary.tsv.gz   dorado per-read summary
summary/dmr/<contrast>.dmr.bed           modkit dmr pair
summary/custom/<step>/<s>/               your custom step outputs
summary/samples_summary.tsv              one row per sample
dnascent/<s>/                            detect modBAM (sorted), per_read.tsv.gz, forksense/ BEDs
manifest.json                            what ran: commit, config, models, tool versions
```

## Documentation

- `config/README.md`: config keys and the samples file formats
- `cluster/README.md`, `docs/cluster/bodhi.md`, `docs/cluster/alpine.md`: running on Slurm
- `docs/dnascent.md`: the DNAscent path and how it maps to the manual workflow
- `docs/custom-steps.md`: adding your own downstream analyses
- `docs/dev-notes/dnascent-onnx-escpod.md`: feasibility notes on running the DNAscent model through escpod
- `CLAUDE.md`: architecture and conventions for contributors

## License

MIT (see `LICENSE`). DNAscent is GPL-3.0 and is used as an external tool.
