# Installation

## Prerequisites

- Linux x86_64. The clusters this is built for are Bodhi and Alpine; a
  workstation with an NVIDIA GPU also works for small runs.
- An NVIDIA GPU for dorado basecalling (and DNAscent detect). Everything
  downstream is CPU.
- About 12 GB of disk for tools and models: dorado 2.1.2 is 3.4 GB, the
  three default models 380 MB, the optional DNAscent image 5 GB.
- Network access from the node you run setup on: the ONT CDN, GitHub and the
  Sylabs library.

## 1. Install pixi

```bash
curl -fsSL https://pixi.sh/install.sh | sh
source ~/.bashrc
pixi --version
```

!!! warning "Alpine: nothing goes in $HOME"
    `$HOME` on Alpine is 2 GB. Clone the pipeline under `/projects/$USER`
    and point pixi's cache at scratch **before** the first install:

    ```bash
    export PIXI_CACHE_DIR=/scratch/alpine/$USER/.cache/pixi
    ```

    See [Alpine](../cluster/alpine.md).

## 2. Clone and install the environment

```bash
git clone https://github.com/rnabioco/nanopore-dna-modification-pipeline.git
cd nanopore-dna-modification-pipeline
pixi install
```

`pixi install` creates `.pixi/envs/default` from the committed `pixi.lock`:
snakemake, the Slurm executor, samtools, minimap2, modkit, mosdepth and the
Python libraries. It takes a few minutes and about 1.4 GB.

## 3. Install dorado, the models and escpod

```bash
pixi run setup
```

This runs once, from **one node**, and puts everything under `resources/`
(gitignored):

| What | Where | Notes |
|---|---|---|
| dorado 2.1.2 | `resources/tools/dorado/2.1.2/` | checksum pinned in `scripts/setup-tools.sh` |
| models named by the config | `resources/models/` | `dorado download` by name; see [Models](../user-guide/models.md) |
| escpod 0.20.0 | `resources/tools/escpod/0.20.0/` | POD5 tooling used to build test fixtures |

Re-running `pixi run setup` is a no-op for anything already present. A
project config that names other models installs them with
`pixi run install-models --configfile config/my-project.yml`.

!!! note "Run setup from a compute node, not in parallel"
    The downloads write to the shared filesystem. Two GPU jobs downloading the
    same model at once corrupt each other, which is why the pipeline never
    downloads inside a job.

## 4. Optional: DNAscent

Only if you will set `dnascent.enabled: true`:

```bash
pixi run install-dnascent         # Alpine: module load singularity first
```

Pulls the DNAscent 4.2.1 Singularity image (5 GB) by digest into
`resources/tools/dnascent/4.2.1/`. On Bodhi you can instead point
`dnascent.sif` at the cluster's own image; see [DNAscent](../dnascent.md).

## 5. Check the installation

```bash
pixi run dl-test-data     # 5 MB synthetic fixture + lambda/E. coli reference
pixi run dry-run          # builds the DAG for config/config-test.yml
pixi run list-models      # the model stack the base config resolves to
```

The dry run should end with a job table of 27 jobs and no errors. `list-models`
should show every model as `present`.

With a GPU available, `pixi run test` executes the whole DAG on the synthetic
reads in a few minutes. The reads are synthetic, so the outputs are nearly
empty; the point is that every rule's command runs.

Next: the [walkthrough](walkthrough.md).
