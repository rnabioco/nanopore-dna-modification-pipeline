#!/bin/bash
# Fetch the tiny CI fixture: dorado's synthetic 5 kHz R10.4.1 test POD5s (one
# read each, 16 KB) laid out as three MinKNOW-style runs, plus the lambda +
# E. coli reference from dorado's aligner tests. ~5 MB total.
#
# These reads are synthetic and will not align; the fixture exists so the DAG
# builds in CI and every rule can be smoke-tested on a GPU node. Build a real
# fixture from a run with `pixi run make-test-data`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BASE="https://raw.githubusercontent.com/nanoporetech/dorado/release-v2.1/tests/data"
POD5_DIR="pod5/dna_r10.4.1_e8.2_400bps_5khz"
declare -A FILES=(
    [run1]="dna_r10.4.1_e8.2_400bps_5khz-FLO_PRO114M-SQK_LSK114_XL-5000.pod5"
    [run2]="dna_r10.4.1_e8.2_400bps_5khz-FLO_PRO114M-SQK_MLK114_96_XL-5000.pod5"
    [run3]="dna_r10.4.1_e8.2_400bps_5khz-FLO_PRO114M-SQK_RAD114-5000.pod5"
)

for run in run1 run2 run3; do
    dest="data/synthetic/${run}/pod5_pass"
    mkdir -p "${dest}"
    if [ ! -s "${dest}/${FILES[$run]}" ]; then
        echo "fetching ${FILES[$run]} -> ${dest}"
        curl -fsSL --retry 3 -o "${dest}/${FILES[$run]}" "${BASE}/${POD5_DIR}/${FILES[$run]}"
    fi
done

mkdir -p data/ref
if [ ! -s data/ref/lambda_ecoli.fasta ]; then
    echo "fetching lambda_ecoli.fasta"
    curl -fsSL --retry 3 -o data/ref/lambda_ecoli.fasta "${BASE}/aligner_test/lambda_ecoli.fasta"
fi
echo "test data ready under .tests/data"

# --- Layouts for the demux and MinKNOW-basecalled modes (config-test-modes.yml) ---
# The same synthetic reads, arranged the way MinKNOW writes a barcoded run.
POOLED="data/synthetic/pooled/pod5_pass"
MINKNOW="data/synthetic/minknow"
mkdir -p "${POOLED}/barcode01" "${POOLED}/barcode02" "${MINKNOW}/pod5_pass/barcode03" "${MINKNOW}/bam_pass/barcode03"
cp -n "data/synthetic/run1/pod5_pass/${FILES[run1]}" "${POOLED}/barcode01/"
cp -n "data/synthetic/run2/pod5_pass/${FILES[run2]}" "${POOLED}/barcode02/"
cp -n "data/synthetic/run3/pod5_pass/${FILES[run3]}" "${MINKNOW}/pod5_pass/barcode03/"
if [ ! -s "${MINKNOW}/bam_pass/barcode03/synthetic_barcode03_0.bam" ]; then
    # A header-only unaligned BAM stands in for MinKNOW's live basecalls.
    printf '@HD\tVN:1.6\tSO:unknown\n@RG\tID:synthetic_barcode03\tSM:barcode03\tPL:ONT\n' \
        | samtools view -b -o "${MINKNOW}/bam_pass/barcode03/synthetic_barcode03_0.bam" -
fi
echo "mode fixtures ready under .tests/data/synthetic/{pooled,minknow}"
