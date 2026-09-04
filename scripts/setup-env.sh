#!/bin/bash
# pixi activation script: puts the pinned tools on PATH. Does NOT install
# anything; that is `pixi run setup`.
#
# The Snakefile's `onstart` also prepends these directories to PATH for every
# job, because a cluster job need not have gone through pixi activation. This
# script is what makes `dorado` resolve in a `pixi shell`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Versions come from config/config-base.yml. The keys are nested (dorado:
# version:), so the awk reads the first `version:` after the `dorado:` header
# rather than a top-level key.
DORADO_VERSION="${DORADO_VERSION:-$(awk '/^dorado:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  version:/{gsub(/"/,"",$2);print $2;exit}' "${REPO_ROOT}/config/config-base.yml")}"
ESCPOD_VERSION="${ESCPOD_VERSION:-$(awk '/^escpod_version:/ {gsub(/"/,"",$2); print $2}' "${REPO_ROOT}/config/config-base.yml")}"

export DORADO_DIR="${REPO_ROOT}/resources/tools/dorado/${DORADO_VERSION}"
export ESCPOD_DIR="${REPO_ROOT}/resources/tools/escpod/${ESCPOD_VERSION}"
export PATH="${DORADO_DIR}/bin:${ESCPOD_DIR}/bin:${PATH}"

# Use the pixi libstdc++ rather than the (older) system one; dorado and modkit
# both want a recent GLIBCXX.
if [ -n "${CONDA_PREFIX:-}" ]; then
    export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

# Alpine (CU Boulder / CURC): $HOME is 2 GB, so every cache goes to scratch.
# Bodhi has a roomy shared home and needs none of this.
if [ -d /scratch/alpine ] && [ -n "${USER:-}" ]; then
    export PIXI_CACHE_DIR="${PIXI_CACHE_DIR:-/scratch/alpine/${USER}/.cache/pixi}"
    export UV_CACHE_DIR="${UV_CACHE_DIR:-/scratch/alpine/${USER}/.cache/uv}"
    export SINGULARITY_CACHEDIR="${SINGULARITY_CACHEDIR:-/scratch/alpine/${USER}/.cache/singularity}"
    export SINGULARITY_TMPDIR="${SINGULARITY_TMPDIR:-/scratch/alpine/${USER}/.cache/singularity/tmp}"
    export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-${SINGULARITY_CACHEDIR}}"
    export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${SINGULARITY_TMPDIR}}"
fi
