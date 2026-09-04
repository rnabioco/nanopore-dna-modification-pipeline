#!/bin/bash
# Pull the pinned DNAscent Singularity image: pixi run install-dnascent
#
# DNAscent is not on conda and builds against a TensorFlow 2.4 C library plus
# CUDA 11 / cuDNN 8, so the maintainers' Singularity image is the supported
# way to run it on both clusters (Bodhi's own DNAscent module is the same
# thing: it just points $SIFPATH at /cluster/singularity_images/DNAscent.sif).
#
# The image is ~5 GB. It lands in resources/tools/dnascent/<version>/ and is
# verified against the image sha256 the Sylabs library reports for the tag.
#
# Alpine: run `module load singularity` first, and keep SINGULARITY_CACHEDIR on
# scratch (scripts/setup-env.sh does that on activation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

DNASCENT_VERSION="${DNASCENT_VERSION:-$(python workflow/scripts/models.py "$@" get dnascent.version)}"
DEST_DIR="${REPO_ROOT}/resources/tools/dnascent/${DNASCENT_VERSION}"
SIF="${DEST_DIR}/DNAscent.sif"

# sha256 of the image file for each pinned tag, as reported by
# https://library.sylabs.io/v1/images/mboemo/dnascent/dnascent:<tag>
declare -A DNASCENT_SHA256=(
    ["4.2.1"]="25d40838e459c8e658d432d632b70adf88af15a05e30ce8f2a1bbfa40ea64016"
)

if [ -s "${SIF}" ]; then
    echo "DNAscent ${DNASCENT_VERSION} image already present at ${SIF}"
    exit 0
fi

if ! command -v singularity >/dev/null 2>&1 && ! command -v apptainer >/dev/null 2>&1; then
    echo "Error: neither singularity nor apptainer is on PATH (Alpine: module load singularity)" >&2
    exit 1
fi
SING="$(command -v singularity || command -v apptainer)"

expected="${DNASCENT_SHA256[${DNASCENT_VERSION}]:-}"
mkdir -p "${DEST_DIR}"
if [ -n "${expected}" ]; then
    # Pulling by digest rather than tag: a re-pushed tag cannot change what we get.
    src="library://mboemo/dnascent/dnascent:sha256.${expected}"
else
    echo "WARNING: no pinned digest for DNAscent ${DNASCENT_VERSION}; pulling by tag" >&2
    src="library://mboemo/dnascent/dnascent:${DNASCENT_VERSION}"
fi
echo "Pulling ${src} -> ${SIF}"
"${SING}" pull --arch amd64 "${SIF}" "${src}"

actual=$(sha256sum "${SIF}" | awk '{print $1}')
if [ -n "${expected}" ] && [ "${actual}" != "${expected}" ]; then
    echo "Error: DNAscent image checksum mismatch" >&2
    echo "  expected ${expected}" >&2
    echo "  actual   ${actual}" >&2
    rm -f "${SIF}"
    exit 1
fi
echo "DNAscent image sha256 ${actual}"
echo "Installed: $("${SING}" run "${SIF}" --version 2>/dev/null | grep -i version || true)"
