# Configuration

A run is `config/config-base.yml` (every key, with its default and a comment)
plus a project config passed with `--configfile`, deep-merged over it. A
project config states only what differs.

```bash
pixi run run-bodhi --configfile config/my-project.yml
pixi run snakemake -n --configfile config/my-project.yml            # dry run
pixi run list-models --configfile config/my-project.yml
```

Two project configs can be layered (`--configfile a.yml b.yml`); later files
win key by key.

## Keys

### Inputs and outputs

| Key | Default | Notes |
|---|---|---|
| `samples` | `config/samples.tsv` | see [Samples file](samples.md) |
| `output_directory` | `results` | everything is written under here; Alpine: on `/scratch/alpine` |
| `reference.fasta` | `null` | genome FASTA, plain or bgzipped; required unless every sample overrides it |
| `reference.preset` | `lr:hq` | minimap2 preset for the index and alignment |

### dorado

| Key | Default | Notes |
|---|---|---|
| `dorado.version` | `"2.1.2"` | the release `pixi run setup` installs |
| `dorado.device` | `cuda:all` | every GPU in the allocation |
| `dorado.emit_moves` | `true` | keep the `mv` move table (needed by signal-level tools; ~2× BAM size) |
| `dorado.min_qscore` | `0` | drop reads below this mean Q at basecall time |
| `dorado.trim` | `all` | `all`, `adapters`, `none` |
| `dorado.barcode_both_ends` | `false` | barcoded runs only |
| `dorado.resume` | `true` | keep `<bam>.partial` and pass `--resume-from` on retry |
| `dorado.extra_opts` | `""` | anything else, verbatim |

### models

See [Models](models.md).

| Key | Default |
|---|---|
| `models.directory` | `resources/models` |
| `models.simplex` | `dna_r10.4.1_e8.2_400bps_sup@v5.2.0` |
| `models.modified_bases` | `[5mC_5hmC, 6mA]` |
| `models.custom` | `[]` |
| `models.mod_versions` | pinned versions per simplex model |

### minknow

| Key | Default | Notes |
|---|---|---|
| `minknow.include_fail` | `false` | for `basecalled: true` runs, also collect `bam_fail` / `pod5_fail` |

### align

| Key | Default | Notes |
|---|---|---|
| `align.tool` | `dorado` | `dorado` (dorado aligner, keeps every tag) or `minimap2` (`samtools fastq -T '*'` → `minimap2 -y`) |
| `align.mm2_opts` | `""` | extra minimap2 options |
| `align.exclude_flags` | `0x904` | `samtools view -F`: unmapped, secondary, supplementary |
| `align.min_mapq` | `0` | `samtools view -q` |

### modkit

| Key | Default | Notes |
|---|---|---|
| `modkit.pileup` | `true` | bedMethyl per sample |
| `modkit.filter_threshold` | `null` | pass threshold; null = modkit's estimate |
| `modkit.mod_thresholds` | `{}` | e.g. `{m: 0.8, a: 0.9}` |
| `modkit.cpg` | `false` | CpG sites only (`--cpg`) |
| `modkit.combine_strands` | `false` | with `cpg` or a motif |
| `modkit.motifs` | `[]` | `["GATC,1"]` → `--motif GATC 1` |
| `modkit.extra_opts` | `""` | |
| `modkit.summary` | `true` | `modkit summary --tsv` |
| `modkit.extract_calls` | `false` | per-read, per-site calls (large) |
| `modkit.bigwig` | `false` | one bigWig of fraction modified per mod code |
| `dmr.contrasts` | `[]` | `[{name, a, b, base}]` → `modkit dmr pair` |

### qc

| Key | Default |
|---|---|
| `qc.mosdepth` | `true` |
| `qc.read_summary` | `true` (dorado summary per read) |

### dnascent

See [DNAscent](../dnascent.md). `enabled`, `version`, `sif`, `command`,
`singularity_bind`, `singularity_setup`, `gpu`, `min_mapq`, `min_length`,
`per_read_probs`, `forksense.{enabled, order, opts}`.

### custom

See [Custom steps](../custom-steps.md).

### Housekeeping

| Key | Default | Notes |
|---|---|---|
| `cleanup_intermediates` | `false` | `true` or a list of tiers (`basecall`, `demux`) to `temp()` during the run |
| `escpod_version` | `"0.20.0"` | POD5 tooling used by `make-test-data` |

`pixi run clean --configfile <project.yml>` is the on-demand superset: it
removes `pod5/` links, `bam/basecall`, `bam/basecall_run`, `demux/` and
`bam/aligned`, keeping `bam/final`, `summary/`, `reference/`, `dnascent/`.
