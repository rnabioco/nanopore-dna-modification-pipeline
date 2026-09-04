# Cluster profiles

Each directory is a Snakemake profile (`snakemake --profile cluster/<name>`),
wired to the pixi tasks `run-bodhi` and `run-alpine`:

```bash
pixi run run-bodhi  --configfile config/my-project.yml
pixi run run-alpine --configfile config/my-project.yml
```

| Profile | CPU partition | GPU partition | Account / QOS |
|---|---|---|---|
| `bodhi`  | `rna` | `gpu` (4x A30 per node) | `rbi` / `gpu_rbi`; no QOS needed |
| `alpine` | `acpu` | `aa100` (A100) | `amc-general`; `cpu-normal` / `gpu-normal` |

GPU rules: `basecall`, `basecall_run` (dorado) and `dnascent_detect`. Everything
else is CPU. Per-rule memory, CPUs and walltime live in `set-resources`; the
comments beside each value say where the number came from. Right-size from
`sacct -j <id> --format=JobID,JobName%20,ReqMem,MaxRSS,AllocCPUS,Elapsed,State`
after a first run rather than from the defaults.

Run the controller from a login shell or an sinteractive session, never from
inside the GPU allocation: it only submits and polls. Before a long basecall,
check `scontrol show reservation`: a job whose walltime crosses a maintenance
window is silently deferred until after it.

See `docs/cluster/bodhi.md` and `docs/cluster/alpine.md` for the site details
(storage, modules, singularity).
