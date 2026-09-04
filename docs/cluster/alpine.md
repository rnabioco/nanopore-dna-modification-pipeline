# Running on Alpine (CU Boulder / CURC)

```bash
pixi run run-alpine --configfile config/my-project.yml
```

Profile: `cluster/alpine/config.yaml`. CPU rules go to `acpu` with QOS
`cpu-normal` (24 h; use `cpu-long` for up to 7 d), GPU rules to `aa100` with
`gpu-normal` (24 h; `gpu-long` 7 d). Account `amc-general`. QOS is set per
rule (`qos:` resource), so a rule can be moved to a long QOS by editing its
`set-resources` entry.

Site rules that matter here:

- **`$HOME` is 2 GB.** Clone the pipeline under `/projects/$USER`, and put
  `output_directory` on `/scratch/alpine/$USER` (purged after ~90 days
  untouched: copy results worth keeping to `/projects` or PetaLibrary).
  `scripts/setup-env.sh` points the pixi, uv and singularity caches at
  scratch automatically when `/scratch/alpine` exists; export
  `PIXI_CACHE_DIR=/scratch/alpine/$USER/.cache/pixi` before the first
  `pixi install` as well, since activation has not happened yet then.
- **Memory is coupled to CPUs** on `acpu` (3840 MB per CPU); the profile sizes
  `cpus_per_task` to cover `mem_mb`.
- **Singularity needs `module load singularity`.** Set
  `dnascent.singularity_setup: "module load singularity"` in the project
  config, and run `module load singularity` before `pixi run install-dnascent`.
- Builds (none are needed for this pipeline) belong on `acompile`.
- No dorado module: `pixi run setup` installs it under the repo.

A whole PromethION flowcell of sup basecalling can exceed `gpu-normal`'s 24 h
on one A100. Either split the run into samples, or move `basecall` /
`basecall_run` to `qos: gpu-long`. `dorado.resume` keeps the partial output
so a re-queued job continues where it stopped.
