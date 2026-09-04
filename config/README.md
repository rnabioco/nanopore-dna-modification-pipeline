# Configuring a run

A run is a project config (YAML) layered over `config/config-base.yml`, plus
a samples file. The base file documents every key with its default; a project
config states only what differs:

```yaml
# config/my-project.yml
samples: config/my-project-samples.yml
output_directory: /beevol/home/me/results/my-project     # Alpine: /scratch/alpine/$USER/...
reference:
  fasta: /beevol/data/ref/chm13v2.0.fa
models:
  simplex: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  modified_bases: [5mC_5hmC, 6mA]
modkit:
  cpg: true
  combine_strands: true
```

```bash
pixi run list-models  --configfile config/my-project.yml   # what will be stacked
pixi run install-models --configfile config/my-project.yml # fetch anything missing
pixi run run-bodhi    --configfile config/my-project.yml
```

## Samples file

### TSV: plain runs

Two or three whitespace-separated columns, no header. A sample id repeated on
several rows spans several runs.

```
wt_rep1    /beevol/data/nanopore/20260901_wt        # run dir: pod5_pass/, pod5_fail/, pod5/ searched
wt_rep1    /beevol/data/nanopore/20260908_wt_again
mut_rep1   /beevol/data/nanopore/20260901_mut       /beevol/data/ref/other.fa   # per-sample reference
```

### YAML: barcoded runs, MinKNOW-basecalled runs

```yaml
runs:
  - path: /beevol/data/nanopore/20260901_pooled
    kit: SQK-NBD114-24            # dorado --kit-name: the run is basecalled once, then demuxed
    reference: /beevol/data/ref/chm13v2.0.fa
    samples:
      wt_rep1: barcode01
      mut_rep1: {barcode: barcode02, reference: /beevol/data/ref/other.fa}
  - path: /beevol/home/someone/Nanopore/run/results
    basecalled: true              # MinKNOW live basecalling: bam_pass/<barcode>/*.bam used as-is
    samples:
      fork_15: barcode15
  - path: /beevol/data/nanopore/20260815_gDNA
    samples:
      control: ~                  # unbarcoded: the whole run is one sample
```

Each sample ends up in one of three modes, reported at startup:

| mode | input | what runs |
|---|---|---|
| `basecall` | POD5 per sample | `dorado basecaller` per sample |
| `demux` | POD5 per barcoded run | one `dorado basecaller --kit-name` per run, `dorado demux`, per-sample collection |
| `prebasecalled` | MinKNOW `bam_pass` (+ `bam_fail` with `minknow.include_fail`) | BAMs concatenated; POD5 still located under `pod5_pass/<barcode>` for DNAscent |

POD5 is never copied: it is hard-linked (same filesystem) or symlinked into
`output_directory/pod5/`.

## Model stack

```yaml
models:
  simplex: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  modified_bases: [5mC_5hmC, 6mA]                  # short codes -> pinned via mod_versions
  # or full names: [dna_r10.4.1_e8.2_400bps_sup@v5.2.0_5mCG_5hmCG@v2]
  custom:
    - resources/models/custom/my_model@v0.1.0      # dorado-format directory (e.g. remora model export)
    - {name: lab6mA, path: /beevol/data/models/lab_6mA_v3}
```

Rules enforced at DAG construction (`workflow/scripts/models.py`):

- a modified-base model must belong to the configured simplex model;
- at most one model per canonical base (`5mC_5hmC` and `4mC_5mC` both call C
  and cannot be stacked; `5mC_5hmC` + `6mA` can);
- custom models are checked through their `config.toml` motif.

Available ONT modifications for `sup@v5.2.0`: `4mC_5mC`, `5mC_5hmC`,
`5mCG_5hmCG`, `6mA`. Switching the simplex model (e.g. to `hac@v6.0.0`) needs
matching `mod_versions` entries; the base config carries them for v5.0.0,
v5.2.0 and hac v6.0.0.

## Key sections

| Section | Notes |
|---|---|
| `dorado` | `version` (installed by setup), `device`, `emit_moves`, `min_qscore`, `trim`, `resume`, `extra_opts`. |
| `align` | `tool: dorado` (keeps all tags) or `minimap2`; `mm2_opts`; `exclude_flags` (default drops unmapped/secondary/supplementary); `min_mapq`. |
| `modkit` | `filter_threshold` / `mod_thresholds`, `cpg` + `combine_strands`, `motifs: ["GATC,1"]`, `extract_calls`, `bigwig`. |
| `dmr` | `contrasts: [{name, a, b, base}]` for `modkit dmr pair`. |
| `dnascent` | see `docs/dnascent.md`. |
| `custom` | see `docs/custom-steps.md`. |
| `cleanup_intermediates` | `false`, `true`, or tiers `[basecall, demux]`; `snakemake clean` is the on-demand superset. |
