# DNAscent

[DNAscent](https://dnascent.readthedocs.io) detects the thymidine analogues
BrdU and EdU in R10.4.1 reads from the raw signal and calls replication
origins, terminations and fork direction from them. It is optional
(`dnascent.enabled: true`) and adds four rules per sample after the final BAM:

```
pod5 links ──► dnascent_index ─┐
bam/final ─────────────────────┴► dnascent_detect (GPU) ──► dnascent_sort ──► dnascent_per_read
                                        └──────────────────► dnascent_forksense
```

| Output | Content |
|---|---|
| `dnascent/<s>/index.dnascent` | read id → POD5 map |
| `dnascent/<s>/<s>.detect.bam` | detect output: input records with `MM:Z:N+b?` (BrdU) / `N+e?` (EdU) and `ML` = round(p·255) at thymidines |
| `dnascent/<s>/<s>.detect.sorted.bam(.bai)` | coordinate-sorted copy for IGV / pysam |
| `dnascent/<s>/<s>.per_read.tsv.gz` | per read: n calls, mean and fraction-above-threshold for BrdU and EdU (`per_read_probs_full: true` adds the vectors) |
| `dnascent/<s>/forksense/<s>.forkSense` + `*_DNAscent_forkSense.bed` | origins, terminations, left/right forks, analogue tracks, stress signatures |

## How it runs

DNAscent is a C++ binary linked against TensorFlow 2.4 and CUDA 11, not on
conda, so it runs from the maintainers' Singularity image:

```bash
pixi run install-dnascent     # pulls library://mboemo/dnascent/dnascent:4.2.1 (5 GB, pinned by digest)
```

into `resources/tools/dnascent/4.2.1/DNAscent.sif`. Alternatives:

```yaml
dnascent:
  sif: /cluster/singularity_images/DNAscent.sif    # Bodhi's own image (4.1.1; what `module load DNAscent` points at)
  command: /path/to/DNAscent/bin/DNAscent          # a native build; takes precedence over sif
  singularity_setup: "module load singularity"     # Alpine
  singularity_bind: [/pl/active/mylab]             # /beevol, /scratch/alpine, /projects, /pl are bound automatically
```

`dnascent.gpu: true` adds `--GPU 0` and `--nv`; the cluster profiles put
`dnascent_detect` on the GPU partition. On CPU (`gpu: false`) detect took
about a day at 8 threads for one barcode of a P2 flowcell, so also move the
rule to a CPU partition with more cores in the profile.

Requirements DNAscent imposes: reads must be aligned (the pipeline's final
BAM), the reference must be the plain FASTA the BAM was aligned to (the
pipeline hands it the staged copy), and reads shorter than `min_length`
(1000) or below `min_mapq` (20) are skipped. 5–10% of reads typically fail
event alignment and carry no calls; they appear in the per-read table with
`n_calls = 0`.

## Mapping from the manual workflow

The lab's manual fork-stalling scripts (`run_*_DNAscent.sh`, one per barcode) do,
per barcode: `samtools merge` of MinKNOW's `bam_pass/<barcode>/*.bam` →
`dorado aligner` against CHM13 → `samtools sort` → `DNAscent index -f
pod5_pass/<barcode>` → `DNAscent detect -t 8` → a per-read probability
extractor → `DNAscent forkSense --order EdU,BrdU --markAnalogues
--markOrigins --markTerminations --markForks --makeSignatures`.

The same run is expressed as `config/examples/fork-stalling-pilot.yml`: a
`basecalled: true` run with four barcodes, `dnascent.enabled: true`, forkSense
order `EdU,BrdU`. `dnascent_per_read.py` replaces the extractor (it uses
pysam's modBAM parser and scales by 255, which is what DNAscent writes).

## Re-basecalling before DNAscent

DNAscent only needs an alignment; it recomputes its own signal alignment from
POD5. Setting `basecalled: false` re-basecalls with the configured stack
(e.g. `sup@v5.2.0` + `6mA`) and DNAscent runs on that BAM instead. Either way
the 6mA (or 5mC) calls from dorado stay on the records and modkit summarises
them alongside.
