# Custom steps

Project-specific downstream analyses are declared in the config and run by
the pipeline as first-class rules, with their inputs wired to the pipeline's
outputs and their resources routed through the cluster profile.

```yaml
custom:
  - name: fork_probs                       # rule name and output directory
    scope: sample                          # sample (default) | project
    requires: [dnascent_bam]               # final_bam is always there; add modkit_pileup, read_summary, dnascent_bam
    command: >
      python scripts/custom/fork_probs.py --bam {dnascent_bam} --reference {reference}
        --out {outdir}/{sample}.fork_probs.tsv.gz --threads {threads}
    outputs: ["{sample}.fork_probs.tsv.gz"]  # checked after the command; missing = failure
    threads: 4
    mem_mb: 16000
    prefix: ""                             # e.g. "module load R/4.5.1 &&"

  - name: cohort_table
    scope: project                         # runs once, after every sample's final BAM
    command: "python scripts/custom/cohort.py --bams {bams} --out {outdir}/cohort.tsv"
    outputs: ["cohort.tsv"]
```

Placeholders:

| scope | placeholders |
|---|---|
| sample | `{sample} {bam} {bai} {reference} {outdir} {threads} {pipeline_dir} {results_dir}` and, when required, `{pileup}` `{read_summary}` `{dnascent_bam}` |
| project | `{samples} {bams} {outdir} {threads} {pipeline_dir} {results_dir}` |

Outputs land in `output_directory/summary/custom/<name>/<sample>/` (or
`.../project/`), with a `.done` sentinel and a log under `logs/custom/`. The
command runs from the pipeline directory, so a script under `scripts/custom/`
can be named relatively. Commands run inside the pixi environment; anything
else goes in `prefix`.

Cluster resources come from the profile's `custom_sample_step` /
`custom_project_step` entries (walltime, partition) and from the step's own
`threads` / `mem_mb`.

The test config exercises two trivial steps; see `config/config-test.yml`.
