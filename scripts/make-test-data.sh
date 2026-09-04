#!/bin/bash
# Build a small, REAL test fixture from a run without copying the run:
#
#   pixi run make-test-data <run_dir_or_pod5_dir> <name> [n_reads] [aligned.bam] [region]
#
# Subsets n_reads (default 200) reads into .tests/fixtures/<name>/pod5_pass/
# with `escpod filter`. When an aligned BAM and a region (e.g. chr1:1000000-
# 1500000) are given, the reads are the primary alignments in that region and
# a matching sub-reference is cut with `samtools faidx` (renamed <chrom>_sub),
# so the fixture aligns to a few-MB reference instead of a whole genome.
#
# This reads every POD5 of the run once; run it in an allocation, not in a
# session shell:
#   srun -p rna -c 8 --mem 16G -t 2:00:00 -J make-test-data --comment=make-test-data -- \
#       pixi run make-test-data /path/to/run mini 200 /path/to/aligned.bam chr1:1000000-1500000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

RUN="${1:?run directory or POD5 directory}"
NAME="${2:?fixture name}"
N_READS="${3:-200}"
BAM="${4:-}"
REGION="${5:-}"

command -v escpod >/dev/null || { echo "escpod not on PATH; run 'pixi run install-escpod'" >&2; exit 1; }

FIX="${REPO_ROOT}/.tests/fixtures/${NAME}"
mkdir -p "${FIX}/pod5_pass"
IDS="${FIX}/read_ids.txt"

if [ -n "${BAM}" ] && [ -n "${REGION}" ]; then
    echo "selecting up to ${N_READS} primary reads in ${REGION} from ${BAM}"
    samtools view -F 0x904 -q 20 "${BAM}" "${REGION}" | cut -f1 | sort -u | head -n "${N_READS}" > "${IDS}"
    REF=$(samtools view -H "${BAM}" | grep -m1 '^@PG' | grep -o -E '\S+\.(fa|fasta|mmi)(\.gz)?' | head -1 || true)
    echo "  ${IDS}: $(wc -l < "${IDS}") reads"
    if [ -n "${6:-}" ] || [ -n "${REFERENCE_FASTA:-}" ]; then
        FA="${6:-${REFERENCE_FASTA}}"
        chrom="${REGION%%:*}"
        mkdir -p "${FIX}/ref"
        samtools faidx "${FA}" "${REGION}" | sed "1s/.*/>${chrom}_sub ${REGION}/" > "${FIX}/ref/${NAME}.fa"
        echo "  sub-reference: ${FIX}/ref/${NAME}.fa"
    else
        echo "  (pass the reference FASTA as a 6th argument, or REFERENCE_FASTA=, to cut a sub-reference)"
    fi
else
    echo "selecting the first ${N_READS} read ids from ${RUN}"
    find "${RUN}" -name '*.pod5' | head -50 | xargs -I{} escpod view {} 2>/dev/null \
        | grep -v '^read_id' | cut -f1 | head -n "${N_READS}" > "${IDS}"
fi

POD5_INPUTS=$(find "${RUN}" -name '*.pod5' | sort)
[ -n "${POD5_INPUTS}" ] || { echo "no POD5 under ${RUN}" >&2; exit 1; }
echo "subsetting into ${FIX}/pod5_pass/${NAME}.pod5"
# shellcheck disable=SC2086
escpod filter --ids "${IDS}" --force -t 8 -o "${FIX}/pod5_pass/${NAME}.pod5" ${POD5_INPUTS}
escpod summary "${FIX}/pod5_pass/${NAME}.pod5"

cat > "${FIX}/README.md" <<README
# Test fixture: ${NAME}

Built $(date -I) by scripts/make-test-data.sh from
\`${RUN}\` (${N_READS} reads${REGION:+, region ${REGION}}).
Read ids in read_ids.txt. Reference: ${REGION:+ref/${NAME}.fa (sub-reference)}${REGION:-the run's own genome (not included)}.
README
echo "fixture written to ${FIX}; point a config's samples file at it"
