# Samples file

The samples file names each sample and where its data is. Its extension picks
the format: `.tsv` (or anything not `.yml`/`.yaml`) for the two-column table,
`.yml` for the structured form.

## TSV

No header. Two or three whitespace-separated columns:

```
# sample_id   run_path                                   [reference]
wt_rep1       /beevol/data/nanopore/20260901_gDNA_wt
wt_rep1       /beevol/data/nanopore/20260908_gDNA_wt_topup
mut_rep1      /beevol/data/nanopore/20260901_gDNA_mut    /beevol/data/ref/other.fa
```

- `run_path` is a run directory (POD5 found under `pod5_pass`, `pod5_fail`,
  `pod5`, `pod5_skip`, recursively), a directory holding `.pod5` files
  directly, or a single `.pod5` file.
- A sample id on several lines has several inputs; they are basecalled
  together.
- The optional third column overrides `reference.fasta` for that sample.

## YAML

```yaml
runs:
  # Pooled run the pipeline basecalls: one dorado pass with --kit-name, then demux.
  - path: /beevol/data/nanopore/20260901_pooled
    kit: SQK-NBD114-24
    reference: /beevol/data/ref/chm13v2.0.fa          # optional: for every sample of this run
    samples:
      wt_rep1: barcode01
      mut_rep1: {barcode: barcode02, reference: /beevol/data/ref/other.fa}

  # MinKNOW live-basecalled run: bam_pass/<barcode>/*.bam used as-is.
  - path: /beevol/data/nanopore/20260910_pooled_live/results
    basecalled: true
    samples:
      fork_12: barcode12
      fork_15: barcode15

  # Unbarcoded run: the whole run is one sample.
  - path: /beevol/data/nanopore/20260815_gDNA
    samples:
      control: ~
```

| Key | Meaning |
|---|---|
| `path` | run directory (as for TSV) |
| `kit` | dorado `--kit-name`; required when the run's samples carry barcodes and the pipeline basecalls |
| `basecalled` | `true`: skip dorado, collect MinKNOW's `bam_pass` (and `bam_fail` with `minknow.include_fail`) |
| `reference` | per-run reference override; a sample can override again |
| `samples` | `name: barcode`, `name: {barcode, reference}`, or `name: ~` for the whole run |

## Modes

Every sample resolves to exactly one mode, printed at startup
(`Samples: wt_rep1 [basecall], ...`):

| Mode | Input | Rules |
|---|---|---|
| `basecall` | POD5 per sample | `link_sample_pod5` → `basecall` |
| `demux` | POD5 per barcoded run | `link_run_pod5` → `basecall_run` → `demux_run` → `collect_demuxed_sample` |
| `prebasecalled` | MinKNOW BAMs | `collect_minknow_bams` (POD5 is still linked, for DNAscent) |

A sample cannot mix modes (one input barcoded, another not); split it into two
samples. A `prebasecalled` sample with a null barcode on a barcoded run takes
only the BAMs directly under `bam_pass/`, never the per-barcode
subdirectories, so barcodes are never pooled by accident.

Sample ids must match `[A-Za-z0-9][A-Za-z0-9._-]*`; they become file and
directory names.
