# References

Reference genomes are pointed at from the config (`reference.fasta`), never
copied here. The pipeline links each reference into
`<output_directory>/reference/<name>-<hash>/genome.fa`, indexes it there
(faidx, minimap2 .mmi, chrom.sizes), and leaves the source untouched.

On Bodhi shared references live under `/beevol/data`; on Alpine put them on
`/projects/$USER` or `/pl/active/<allocation>`.
