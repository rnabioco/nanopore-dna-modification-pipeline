# Running and monitoring

## Launch

```bash
pixi run run-bodhi  --configfile config/my-project.yml     # Bodhi profile
pixi run run-alpine --configfile config/my-project.yml     # Alpine profile
pixi run run        --configfile config/my-project.yml --cores 16   # local GPU machine
```

`run-bodhi` and `run-alpine` are `snakemake --profile cluster/<site>`; the
profile sets the executor, partitions, accounts, QOS and per-rule resources.
Trailing arguments go to snakemake, so `--until modkit_pileup`,
`--forcerun basecall`, `-n` and friends all work.

The controller submits one Slurm job per rule instance and polls until the
DAG is done, so it must stay alive: run it in `tmux`/`screen` or an
`sinteractive` session, never in a GPU allocation and never on a node it
cannot submit from.

## While it runs

```bash
squeue --me -o "%.10i %.28j %.10P %.10M %.8T %R"
tail -f <output_directory>/logs/basecall/<sample>.log
```

Job names are `<rule>-<wildcards>`. Two kinds of log:

| Path | Content |
|---|---|
| `<output_directory>/logs/<rule>/<sample>.log` | the tool's stderr (dorado progress bar, modkit's log, DNAscent output) |
| `logs/slurm/<rule>/...` (pipeline directory) | Slurm job stdout/stderr; kept for failed jobs, deleted after 10 days |

`snakemake --summary --configfile ...` lists every target and whether it is
up to date.

## Failures and reruns

`keep-going: true` in the profiles means one failed job does not stop the
rest. When the controller exits non-zero, `show-failed-logs` has already
printed the failing job's log. Fix the cause and rerun the same command;
finished outputs are reused, incomplete ones (`rerun-incomplete: true`) are
redone.

Basecalling is the expensive one. With `dorado.resume: true` (default) a
killed basecall leaves `<sample>.bam.partial` next to its output and the
next attempt passes it to `dorado --resume-from`, so only the reads in
flight are repeated.

To force a stage: `--forcerun modkit_pileup`. To build only up to a stage:
`--until align`.

## Changing the config of a finished run

Snakemake reruns a rule when its parameters change (`rerun-triggers`
includes params). Changing `modkit.*` reruns modkit only; changing `models`
reruns basecalling and everything after it. A dry run shows exactly what
would rerun and why (`reason:` lines).

## Resources

Per-rule CPUs, memory, walltime and partition live in the profile's
`set-resources`. To change one for a project without editing the profile:

```bash
pixi run run-bodhi --configfile config/my-project.yml \
    --set-resources basecall:runtime=48h basecall:gres=gpu:4
```

After a first run, right-size from what was used:

```bash
sacct -S <date> --name=basecall-sample=wt_rep1 \
    --format=JobID,JobName%30,ReqMem,MaxRSS,AllocCPUS,Elapsed,State
```

`MaxRSS` is on the `.batch` step row. dorado grows to whatever memory the
cgroup allows, so its MaxRSS follows the request rather than measuring a need.

## Cleaning up

```bash
pixi run clean --configfile config/my-project.yml
```

removes the POD5 links, dorado's unaligned BAMs, per-run basecalls, demux
output and the pre-final aligned BAM (of which `bam/final` is a hardlink).
`cleanup_intermediates: true` does the `basecall` and `demux` tiers
automatically during the run.
