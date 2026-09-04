# Outputs

Everything lands under `output_directory`. `<s>` is a sample id.

## Per sample

| Path | Rule | Content |
|---|---|---|
| `bam/final/<s>/<s>.bam`, `.bai` | `finalize_bam` | aligned, coordinate-sorted, primary alignments only (`align.exclude_flags`); dorado's `MM`/`ML` modbase tags, `mv` move table, `RG` and per-read tags all preserved |
| `summary/modkit/<s>/<s>.pileup.bed.gz`, `.tbi` | `modkit_pileup` | bedMethyl (below) |
| `summary/modkit/<s>/<s>.modkit_summary.tsv` | `modkit_summary` | per mod code: pass threshold, fraction modified over a read sample |
| `summary/modkit/<s>/<s>.mod_calls.tsv.gz` | `modkit_extract_calls` (opt) | one row per read per called site |
| `summary/modkit/<s>/<s>.<code>.bw` | `modkit_bigwig` (opt) | fraction modified per site, one file per mod code |
| `summary/qc/<s>/<s>.flagstat.tsv` | `samtools_qc` | `samtools flagstat -O tsv` |
| `summary/qc/<s>/<s>.stats.txt` | `samtools_qc` | `samtools stats` |
| `summary/qc/<s>/<s>.mosdepth.summary.txt`, `.mosdepth.global.dist.txt` | `mosdepth` | depth per contig, cumulative depth distribution |
| `summary/tables/<s>/<s>.read_summary.tsv.gz` | `dorado_read_summary` | `dorado summary`: per read length, mean qscore, alignment fields |
| `summary/custom/<step>/<s>/` | `custom_sample_step` | whatever the step declared |
| `dnascent/<s>/...` | DNAscent rules | see [DNAscent](../dnascent.md) |

Intermediates (removed by `pixi run clean`):

| Path | Content |
|---|---|
| `pod5/samples/<s>/pod5/`, `pod5_files.txt` | links to the input POD5 and a manifest of real paths |
| `pod5/runs/<run>/...` | same, per barcoded run |
| `bam/basecall/<s>/<s>.bam` | dorado's unaligned output (or MinKNOW's, concatenated) |
| `bam/basecall_run/<run>/<run>.bam`, `demux/<run>/` | barcoded runs: the run basecall and its demux |
| `bam/aligned/<s>/<s>.bam` | the aligned BAM `bam/final` hardlinks |

## Per project

| Path | Content |
|---|---|
| `summary/samples_summary.tsv` | one row per sample: total/primary/mapped reads, mapped fraction, mean depth, read N50 and mean length, mean qscore, total bases, `modkit_<base>_<code>_pass_frac` per mod code |
| `summary/dmr/<contrast>.dmr.bed` | `modkit dmr pair` output per `dmr.contrasts` entry |
| `summary/custom/<step>/project/` | project-scoped custom steps |
| `reference/<name>-<hash>/genome.fa`, `.fai`, `.mmi`, `genome.chrom.sizes` | the staged reference and its indexes |
| `manifest.json` | git commit/branch/dirty flag, the merged config, the resolved model stack with paths, sample inputs, tool versions, host, user, start/end time, status |
| `logs/<rule>/...` | tool logs |

## bedMethyl columns

`modkit pileup` writes the bedMethyl described in the modkit README. The
columns that matter most:

| Column | Meaning |
|---|---|
| 1–3 | chrom, start, end (0-based, half-open, one base) |
| 4 | mod code: `m` 5mC, `h` 5hmC, `a` 6mA, `21839` 4mC |
| 5 | valid coverage (score column) |
| 6 | strand (`+`/`-`; `.` when strands are combined) |
| 10 | N valid coverage |
| 11 | fraction modified, 0–100 |
| 12–18 | N mod, N canonical, N other mod, N delete, N fail, N diff, N no-call |

With `modkit.cpg: true` and `combine_strands: true`, the two strands of each
CpG are one row.

## DNAscent

| Path | Content |
|---|---|
| `dnascent/<s>/index.dnascent` | read id → POD5 map |
| `dnascent/<s>/<s>.detect.bam` | detect output: `MM:Z:N+b?` (BrdU) / `N+e?` (EdU), `ML` = round(p·255) |
| `dnascent/<s>/<s>.detect.sorted.bam`, `.bai` | sorted, indexed copy |
| `dnascent/<s>/<s>.per_read.tsv.gz` | per read: n calls, mean and fraction-above-threshold for BrdU and EdU |
| `dnascent/<s>/forksense/<s>.forkSense` + `*_DNAscent_forkSense.bed` | forkSense calls: origins, terminations, left/right forks, analogue tracks, stress signatures |
