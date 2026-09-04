# Running on Bodhi

```bash
pixi run run-bodhi --configfile config/my-project.yml
```

Profile: `cluster/bodhi/config.yaml`. CPU rules go to `rna` (account `rbi`),
GPU rules (`basecall`, `basecall_run`, `dnascent_detect`) to `gpu` (account
`gpu_rbi`, 3 nodes × 4 A30, 3-day limit). No QOS is needed.

- Launch the controller from a login shell or an sinteractive session (it
  only submits and polls). `slurm-status-command: squeue` is set because a
  controller inside a compute-node session cannot always reach slurmdbd.
- `pixi run setup` once, from one node, before the first submission. The
  downloads go to `resources/tools` and `resources/models` on `/beevol`.
- `output_directory` anywhere under `/beevol/home/$USER`. Node-local `/tmp`
  is used for sort scratch (`TMPDIR`).
- Before a long basecall: `scontrol show reservation`. Bodhi has a monthly
  all-node maintenance window; a job whose walltime crosses it is deferred
  until after it, silently.
- DNAscent: the cluster image `/cluster/singularity_images/DNAscent.sif`
  (4.1.1) can be used directly via `dnascent.sif`, or pull the pinned 4.2.1
  with `pixi run install-dnascent`. `singularity` is on PATH.
- Modules also exist for `dorado/2.0.0`, `modkit/0.5.1`, `minimap2/2.30`,
  `samtools/1.22.1`; the pipeline does not use them (pixi pins its own), but
  they are handy for ad-hoc checks.
