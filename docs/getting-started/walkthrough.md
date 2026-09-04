# Walkthrough: from POD5 to modification calls

This is the path for someone who has just finished a sequencing run and has a
directory of POD5 files. By the end you will have aligned modBAMs, per-site
modification tables and QC for every sample, produced on the cluster from one
config file. Each step says what to do, what to check, and what can go wrong.

The example throughout is a MinION/PromethION gDNA run of two samples,
`wt_rep1` and `mut_rep1`, aligned to CHM13v2.0 with 5mC/5hmC and 6mA called.
Adapt the names and paths.

!!! tip "Already basecalled by MinKNOW?"
    If MinKNOW basecalled the run live with the models you want, you can skip
    dorado entirely: see [step 3](#3-write-the-samples-file) and set
    `basecalled: true`. Everything else is identical.

## 0. Before you start

You need:

- [x] The pipeline installed with `pixi install` and `pixi run setup`
      ([Installation](installation.md)).
- [x] The run directory (or directories) on a filesystem the compute nodes can
      read.
- [x] A reference genome FASTA (plain or bgzipped).
- [x] A place for the outputs: anywhere under `/beevol/home/$USER` on Bodhi;
      `/scratch/alpine/$USER/...` on Alpine (never `$HOME` there).
- [x] For a barcoded run, the barcoding kit name (e.g. `SQK-NBD114-24`) and
      which barcode is which sample.

## 1. Look at the run directory

MinKNOW writes a run like this:

```
/beevol/data/nanopore/20260901_gDNA/
├── pod5_pass/            <- what the pipeline uses
│   ├── PAX12345_pass_0.pod5
│   └── ...
├── pod5_fail/            <- also used: dorado re-decides pass/fail
├── bam_pass/             <- only if MinKNOW basecalled live
├── sequencing_summary_*.txt
└── final_summary_*.txt
```

A **barcoded** run has one subdirectory per barcode instead:
`pod5_pass/barcode01/`, `pod5_pass/barcode02/`, ... and `bam_pass/barcode01/`
if it was basecalled live.

Check what you have:

```bash
ls /beevol/data/nanopore/20260901_gDNA/pod5_pass | head
du -sh /beevol/data/nanopore/20260901_gDNA/pod5_pass
pixi run escpod summary /beevol/data/nanopore/20260901_gDNA/pod5_pass/PAX12345_pass_0.pod5
```

`escpod summary` prints the flow cell, kit, sample rate and read count of a
file. The pipeline needs **R10.4.1, 5 kHz** data (kit SQK-LSK114 or a
barcoding kit of that generation) for the default `dna_r10.4.1_e8.2_400bps`
models. A 4 kHz file (2022 and earlier) needs a v4.x model instead.

Decide which of the three shapes each sample is:

| You have | Mode | What the pipeline does |
|---|---|---|
| POD5 for one sample, one or more run directories | `basecall` | dorado basecaller per sample |
| One pooled run, barcoded, not basecalled with the models you want | `demux` | one dorado pass with `--kit-name`, then `dorado demux` |
| MinKNOW `bam_pass` already basecalled with the models you want | `prebasecalled` | BAMs used as-is; POD5 only needed for DNAscent |

!!! note "The pipeline never copies POD5"
    Files are hard-linked (or symlinked across filesystems) into
    `<output_directory>/pod5/`. A 500 GB run costs nothing extra.

## 2. Pick the reference

Any FASTA works. Put it somewhere shared and stable; the pipeline links it
into the output tree and builds its own indexes there (`.fai`, minimap2 `.mmi`,
chrom sizes), so the source directory can be read-only.

```bash
ls -la /beevol/data/ref/chm13v2.0.fa
```

If different samples need different references (a spike-in, another
organism), the samples file can say so per sample.

## 3. Write the samples file

=== "TSV (plain runs)"

    `config/gdna-samples.tsv`, no header, whitespace-separated. A sample id
    repeated on several lines has several run directories (they are
    basecalled together).

    ```
    wt_rep1     /beevol/data/nanopore/20260901_gDNA_wt
    wt_rep1     /beevol/data/nanopore/20260908_gDNA_wt_topup
    mut_rep1    /beevol/data/nanopore/20260901_gDNA_mut
    ```

    A third column overrides the reference for that sample.

=== "YAML (barcoded run)"

    `config/gdna-samples.yml`. `kit` is what dorado uses to classify barcodes.

    ```yaml
    runs:
      - path: /beevol/data/nanopore/20260901_pooled
        kit: SQK-NBD114-24
        samples:
          wt_rep1: barcode01
          mut_rep1: barcode02
    ```

=== "YAML (MinKNOW already basecalled)"

    `basecalled: true` means dorado is not run; MinKNOW's
    `bam_pass/<barcode>/*.bam` are concatenated per sample. Whatever models
    MinKNOW ran are what you get (the `@RG` line in the BAM says which).

    ```yaml
    runs:
      - path: /beevol/data/nanopore/20260901_pooled
        basecalled: true
        samples:
          wt_rep1: barcode01
          mut_rep1: barcode02
    ```

Sample ids become directory and file names: letters, digits, `.`, `_`, `-`;
no spaces. The full format, including per-sample references and mixing
barcoded and unbarcoded runs, is in [Samples file](../user-guide/samples.md).

## 4. Write the project config

`config/gdna.yml`. Only what differs from `config/config-base.yml` needs to be
here; everything else takes the documented default.

```yaml
samples: config/gdna-samples.tsv
output_directory: /beevol/home/me/results/gdna-2026-09

reference:
  fasta: /beevol/data/ref/chm13v2.0.fa

models:
  simplex: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  modified_bases: [5mC_5hmC, 6mA]

modkit:
  cpg: true               # CpG-context 5mC table with strands combined;
  combine_strands: true   # drop both for all-context C and A calls
```

Choices worth a moment:

- **Which modifications.** `5mC_5hmC` (all-context C), `5mCG_5hmCG`
  (CpG only, a little more accurate there), `4mC_5mC`, `6mA`. At most one
  model per canonical base: `5mC_5hmC` + `6mA` stack, `5mC_5hmC` + `4mC_5mC`
  do not. Short codes expand to pinned versions; see
  [Models](../user-guide/models.md).
- **Whole-genome or CpG pileup.** `modkit.cpg: true` restricts the bedMethyl
  to CpG sites and needs a C model. Leave it off for 6mA-only work or
  all-context analyses.
- **Output directory.** A new directory per project. On Alpine it must be on
  `/scratch/alpine`.

Now check that the config resolves to the models you expect, and install any
that are missing:

```bash
pixi run list-models --configfile config/gdna.yml
pixi run install-models --configfile config/gdna.yml     # only if something is MISSING
```

```
simplex    present  dna_r10.4.1_e8.2_400bps_sup@v5.2.0
ont_mod    present  dna_r10.4.1_e8.2_400bps_sup@v5.2.0_5mC_5hmC@v2 (canonical C)
ont_mod    present  dna_r10.4.1_e8.2_400bps_sup@v5.2.0_6mA@v1 (canonical A)
```

## 5. Dry run

Always. It costs seconds and catches most config mistakes before any GPU time
is spent:

```bash
pixi run snakemake -n --configfile config/gdna.yml
```

Read the top of the output and the job table at the bottom:

```
Samples: wt_rep1 [basecall], mut_rep1 [basecall]
Model stack: dna_r10.4.1_e8.2_400bps_sup@v5.2.0 + ..._5mC_5hmC@v2 + ..._6mA@v1
...
Job stats:
job                    count
-------------------  -------
link_sample_pod5           2
stage_reference            1
basecall                   2
mm2_index                  1
align                      2
finalize_bam               2
samtools_qc                2
mosdepth                   2
dorado_read_summary        2
modkit_pileup              2
modkit_summary             2
samples_summary            1
all                        1
total                     22
```

Things the dry run tells you:

- **`samples file error: no POD5 files found ...`**: the run path is wrong,
  or a barcoded run was given without a barcode. Fix the samples file.
- **`model stack error: ... both call canonical base C`**: two C models are
  listed; drop one.
- **`model not installed: ...`** (a warning): run `install-models`.
- **`dorado 2.1.2 is not installed`** (a warning): run `pixi run setup`.
- The `Samples:` line shows the mode each sample resolved to. If a sample you
  expected to be `demux` shows `basecall`, the samples file gave it no
  barcode.

## 6. Launch on the cluster

The Snakemake controller submits one Slurm job per rule and waits. Run it
from a login shell or an `sinteractive` session, inside something that
survives you logging out (`tmux`, `screen`, or the sinteractive session
itself). Do **not** run it inside a GPU allocation.

=== "Bodhi"

    ```bash
    scontrol show reservation            # a maintenance window? see below
    pixi run run-bodhi --configfile config/gdna.yml
    ```

    Basecalling goes to the `gpu` partition (account `gpu_rbi`, 2 A30s per
    job), everything else to `rna`. Details: [Bodhi](../cluster/bodhi.md).

=== "Alpine"

    ```bash
    pixi run run-alpine --configfile config/gdna.yml
    ```

    Basecalling goes to `aa100` with QOS `gpu-normal` (24 h cap; the profile
    comments say how to move to `gpu-long`), everything else to `acpu`.
    Details: [Alpine](../cluster/alpine.md).

=== "A workstation with a GPU"

    ```bash
    pixi run run --configfile config/gdna.yml --cores 16
    ```

!!! warning "Maintenance reservations"
    A job that asks for more walltime than remains before a maintenance
    reservation is silently deferred until after it. `scontrol show
    reservation` shows what is scheduled; the profile's `runtime` for
    `basecall` is 36 h on Bodhi.

How long? dorado sup basecalling with two modification models runs at very
roughly 1.5 to 2 million reads per hour per pair of A30s. A 10 Gb sample is
an hour or two; a full PromethION flowcell is most of a day. If the
basecall job is killed at its walltime, just relaunch: the partial output is
kept and dorado resumes from it.

## 7. Monitor

```bash
squeue --me -o "%.10i %.28j %.10P %.10M %.8T %R"      # the jobs Snakemake submitted
tail -f /beevol/home/me/results/gdna-2026-09/logs/basecall/wt_rep1.log
```

Job names carry the rule and sample. Logs live in two places:

| Where | What |
|---|---|
| `<output_directory>/logs/<rule>/<sample>.log` | the tool's own stderr (dorado progress, modkit log) |
| `logs/slurm/` in the pipeline directory | Slurm's stdout/stderr per job; kept for failed jobs |

If a job fails, Snakemake keeps going with everything that does not depend on
it (`keep-going: true`) and exits non-zero at the end. Read the log, fix the
cause, and run the same command again: finished outputs are not redone.

## 8. What you get

```
/beevol/home/me/results/gdna-2026-09/
├── bam/final/wt_rep1/wt_rep1.bam(.bai)         aligned, sorted; MM/ML modbase tags and mv move table kept
├── summary/
│   ├── modkit/wt_rep1/
│   │   ├── wt_rep1.pileup.bed.gz(.tbi)         bedMethyl: one row per site, strand and mod code
│   │   └── wt_rep1.modkit_summary.tsv          fraction modified per mod code, sampled
│   ├── qc/wt_rep1/                             flagstat.tsv, stats.txt, mosdepth.summary.txt
│   ├── tables/wt_rep1/wt_rep1.read_summary.tsv.gz   per read: length, qscore, alignment
│   └── samples_summary.tsv                     one row per sample
├── reference/chm13v2.0-<hash>/                 genome.fa (link), .fai, .mmi, chrom.sizes
├── pod5/samples/wt_rep1/pod5/                  links to the input POD5
├── bam/basecall/wt_rep1/wt_rep1.bam            dorado's unaligned output (large; see cleanup)
├── logs/
└── manifest.json                               commit, config, resolved models, tool versions
```

First things to look at:

```bash
column -t summary/samples_summary.tsv
zcat summary/modkit/wt_rep1/wt_rep1.pileup.bed.gz | head -3
```

A bedMethyl row is `chrom start end mod_code valid_coverage strand ... N_valid
fraction_modified N_mod N_canonical ...`; `m` is 5mC, `h` 5hmC, `a` 6mA. The
[Outputs](../user-guide/outputs.md) page lists every file and column.

To view in IGV, load `bam/final/<sample>.bam` (IGV colours modified bases from
the MM/ML tags) or set `modkit.bigwig: true` for one bigWig of modification
fraction per mod code.

## 9. Common next steps

- **Compare two samples**: add a `dmr.contrasts` entry
  (`{name: mut_vs_wt, a: mut_rep1, b: wt_rep1, base: C}`) and rerun; you get
  `summary/dmr/mut_vs_wt.dmr.bed` from `modkit dmr pair`.
- **Per-read calls**: `modkit.extract_calls: true` (large tables).
- **Thresholds**: `modkit.filter_threshold` / `modkit.mod_thresholds`, or
  restrict to motifs with `modkit.motifs: ["GATC,1"]`.
- **BrdU/EdU and replication forks**: `dnascent.enabled: true`; see
  [DNAscent](../dnascent.md).
- **Your own analysis on every final BAM**: a `custom:` entry; see
  [Custom steps](../custom-steps.md).
- **Reclaim space** once you are done with the raw basecalls:
  `pixi run clean --configfile config/gdna.yml` removes the unaligned BAMs
  and POD5 links and keeps `bam/final` and `summary/`. Set
  `cleanup_intermediates: true` in the config to do this automatically during
  the run.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `no POD5 files found for sample` | wrong path, or a barcoded run without a barcode | check `ls <run>/pod5_pass`; give the barcode in a YAML samples file |
| `dorado` job fails immediately with a CUDA error | the job did not get a GPU, or ran on a CPU partition | check the profile's `basecall` entry; `nvidia-smi` in the job log |
| basecall killed at walltime | run larger than the profile's `runtime` | relaunch (resumes), or raise `runtime` for `basecall` |
| `modkit pileup` finds no modification calls | the BAM has no MM/ML tags: MinKNOW basecalled without mod models | set `basecalled: false` to re-basecall, or accept no mod tables |
| Everything ran but `samples_summary.tsv` shows 0 mapped reads | wrong reference, or 4 kHz data with a 5 kHz model | `escpod summary` on a POD5; check `summary/qc/<s>/<s>.flagstat.tsv` |
| Controller "hangs" after the first batch on Bodhi | `sacct` unreachable from the node | the profile already uses `slurm-status-command: squeue`; make sure you use it |
