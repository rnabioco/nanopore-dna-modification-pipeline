#!/bin/bash
# One-time tool setup: pixi run setup            (everything)
#                      pixi run setup dorado     (one component)
#
# Components: dorado | models | escpod | all
#
# Extra arguments are passed to the model resolver, so a project config's
# model stack can be installed with
#   pixi run install-models --configfile config/my-project.yml
#
# Run this from ONE node before submitting cluster jobs. It writes into
# resources/tools and resources/models, which are on the shared filesystem, and
# two GPU jobs downloading the same model at once corrupt each other.
#
# DNAscent is NOT installed here: it is optional and 5 GB. See
# scripts/install-dnascent.sh (`pixi run install-dnascent`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

COMPONENT="${1:-all}"
shift || true
CONFIG_ARGS=("$@")
MODELS_PY="python workflow/scripts/models.py"

cfg() { ${MODELS_PY} "${CONFIG_ARGS[@]}" get "$1"; }

DORADO_VERSION="$(cfg dorado.version)"
ESCPOD_VERSION="$(cfg escpod_version)"
MODELS_DIR="$(cfg models.directory)"
[[ "${MODELS_DIR}" = /* ]] || MODELS_DIR="${REPO_ROOT}/${MODELS_DIR}"
DORADO_DIR="${REPO_ROOT}/resources/tools/dorado/${DORADO_VERSION}"
ESCPOD_DIR="${REPO_ROOT}/resources/tools/escpod/${ESCPOD_VERSION}"

# ---------------------------------------------------------------------------
# Pinned checksums.
#
# ONT publishes no checksums for dorado tarballs, so these were computed from
# the first download of each release. A mismatch means the CDN re-published
# the artifact under the same name; stop and look rather than trusting it.
# An unlisted version downloads with a warning and prints its checksum so it
# can be added here.
# ---------------------------------------------------------------------------
declare -A DORADO_SHA256=(
    # dorado-2.1.2-linux-x64.tar.gz, 3,466,666,099 bytes, CDN Last-Modified
    # 2026-08-26; computed from the first download on 2026-09-04.
    ["2.1.2-linux-x64"]="f4ed83acfb75cf07ffe8a0fc78e26828fc911fcfc8177920be6104e1d0e02485"
)

# escpod checksums come from the release's SHA256SUMS.txt (rnabioco/escapepod-rs).
declare -A ESCPOD_SHA256=(
    ["0.20.0-x86_64-unknown-linux-musl"]="bc4f8143c967ba08a448bed391e50c79acf39b489137b26368d4608f6ceec873"
    ["0.20.0-aarch64-unknown-linux-musl"]="26fdc1e5cde6d92f283f865de4d9fa4b476ef80c5a7143eb4eaa6e95baa84922"
    ["0.20.0-x86_64-apple-darwin"]="98935fdb32c90e463863b93eeacd74bced9ea6143fd5433aafaf3b2f5822dfeb"
    ["0.20.0-aarch64-apple-darwin"]="3c2c3d79e0f93693d809fcf2dafbb5b8446e4764688bb320c041d7074db6142b"
)

# Downloads are staged on node-local disk when there is one (Bodhi's /tmp is
# a 400 GB local disk; a 3.4 GB tarball has no business on BeeGFS twice).
STAGE="$(mktemp -d -p "${TMPDIR:-/tmp}" dnamod-setup.XXXXXX)"
trap 'rm -rf "${STAGE}"' EXIT

detect_platform() {
    local system machine
    system=$(uname -s | tr '[:upper:]' '[:lower:]')
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "${machine}" in
        arm64|aarch64) arch="arm64" ;;
        x86_64|amd64|x64) arch="x64" ;;
        *) echo "Error: unsupported architecture ${machine}" >&2; return 1 ;;
    esac
    case "${system}" in
        linux) echo "linux-${arch}|tar.gz" ;;
        darwin) echo "osx-${arch}|zip" ;;
        *) echo "Error: unsupported OS ${system}" >&2; return 1 ;;
    esac
}

verify_sha256() {
    # verify_sha256 FILE EXPECTED LABEL. Empty EXPECTED = unpinned: warn.
    local file="$1" expected="$2" label="$3" actual
    actual=$(sha256sum "${file}" | awk '{print $1}')
    if [ -z "${expected}" ]; then
        echo "WARNING: no pinned checksum for ${label}; downloaded sha256 is" >&2
        echo "  ${actual}" >&2
        echo "  Add it to scripts/setup-tools.sh once you trust this download." >&2
        return 0
    fi
    if [ "${actual}" != "${expected}" ]; then
        echo "Error: checksum mismatch for ${label}" >&2
        echo "  expected ${expected}" >&2
        echo "  actual   ${actual}" >&2
        return 1
    fi
    echo "  sha256 OK (${label})"
}

install_dorado() {
    if [ -x "${DORADO_DIR}/bin/dorado" ]; then
        echo "dorado ${DORADO_VERSION} already installed at ${DORADO_DIR}"
        return 0
    fi
    local platform os_suffix file_ext url tarball
    platform=$(detect_platform)
    os_suffix="${platform%|*}"
    file_ext="${platform#*|}"
    url="https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_VERSION}-${os_suffix}.${file_ext}"
    tarball="${STAGE}/dorado.${file_ext}"
    echo "Downloading dorado ${DORADO_VERSION} (${os_suffix}) from ${url}"
    curl -fL -sS --retry 3 -o "${tarball}" "${url}"
    verify_sha256 "${tarball}" "${DORADO_SHA256[${DORADO_VERSION}-${os_suffix}]:-}" "dorado-${DORADO_VERSION}-${os_suffix}"
    mkdir -p "${DORADO_DIR}"
    if [ "${file_ext}" = "tar.gz" ]; then
        tar -xzf "${tarball}" -C "${DORADO_DIR}" --strip-components=1
    else
        unzip -q -o "${tarball}" -d "${STAGE}/dorado-unzip"
        mv "${STAGE}"/dorado-unzip/*/* "${DORADO_DIR}/"
    fi
    chmod +x "${DORADO_DIR}/bin/dorado"
    echo "dorado installed to ${DORADO_DIR}: $("${DORADO_DIR}/bin/dorado" --version 2>&1)"
}

install_models() {
    if [ ! -x "${DORADO_DIR}/bin/dorado" ]; then
        echo "Error: dorado ${DORADO_VERSION} is not installed; run 'pixi run install-dorado' first" >&2
        return 1
    fi
    mkdir -p "${MODELS_DIR}"
    # The resolver knows which ONT names the config stacks (simplex + every
    # modified-base model, short codes expanded to pinned versions). It skips
    # models already present and refuses an invalid stack before downloading.
    PATH="${DORADO_DIR}/bin:${PATH}" ${MODELS_PY} "${CONFIG_ARGS[@]}" download
}

escpod_target() {
    local system machine
    system=$(uname -s | tr '[:upper:]' '[:lower:]')
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "${machine}" in
        arm64|aarch64) machine="aarch64" ;;
        x86_64|amd64|x64) machine="x86_64" ;;
        *) echo "Error: unsupported architecture ${machine}" >&2; return 1 ;;
    esac
    case "${system}" in
        linux) echo "${machine}-unknown-linux-musl" ;;
        darwin) echo "${machine}-apple-darwin" ;;
        *) echo "Error: unsupported OS ${system}" >&2; return 1 ;;
    esac
}

install_escpod() {
    if [ -x "${ESCPOD_DIR}/bin/escpod" ]; then
        echo "escpod ${ESCPOD_VERSION} already installed at ${ESCPOD_DIR}"
        return 0
    fi
    local target url tarball
    target=$(escpod_target)
    url="https://github.com/rnabioco/escapepod-rs/releases/download/v${ESCPOD_VERSION}/escpod-v${ESCPOD_VERSION}-${target}.tar.gz"
    tarball="${STAGE}/escpod.tar.gz"
    echo "Downloading escpod ${ESCPOD_VERSION} (${target})"
    curl -fL -sS --retry 3 -o "${tarball}" "${url}"
    verify_sha256 "${tarball}" "${ESCPOD_SHA256[${ESCPOD_VERSION}-${target}]:-}" "escpod-${ESCPOD_VERSION}-${target}"
    mkdir -p "${ESCPOD_DIR}/bin"
    tar -xzf "${tarball}" -C "${ESCPOD_DIR}/bin"
    chmod +x "${ESCPOD_DIR}/bin/escpod"
    echo "escpod installed to ${ESCPOD_DIR}: $("${ESCPOD_DIR}/bin/escpod" --version)"
}

case "${COMPONENT}" in
    dorado) install_dorado ;;
    models) install_models ;;
    escpod) install_escpod ;;
    all)
        echo "=== dorado ==="; install_dorado
        echo "=== models ==="; install_models
        echo "=== escpod ==="; install_escpod
        echo "=== setup complete ==="
        echo "DNAscent is optional: 'pixi run install-dnascent' if dnascent.enabled will be true."
        ;;
    *) echo "usage: $0 [dorado|models|escpod|all] [--configfile FILE ...]" >&2; exit 2 ;;
esac
