#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# =============================================================================
# Usage:
#   ./build-rpm.sh --tarball <path> --spec <path> [OPTIONS]
#
# Options:
#   -t, --tarball  <file>     Source tarball (required)
#   -s, --spec     <file>     RPM spec file  (required)
#   -o, --output   <dir>      Output directory (default: ./output)
#       --macros   <string>   Extra rpmbuild --define strings
#       --extra-rpms <rpms>   Space-separated list of local RPM file paths to
#                             install before running dnf builddep. Useful for
#                             pre-built dependency RPMs not in any repository.
#                             (e.g. "output/foo-1.0.rpm output/foo-devel-1.0.rpm")
#       --base-image <image>  Override the builder base image
#                             (default: quay.io/centos/centos:stream10)
#       --extra-repo <url>    URL of an existing dnf repository (e.g. Artifactory)
#                             to register inside the build container. Packages
#                             from this repo are available to satisfy
#                             BuildRequires (via dnf builddep).
#   -h, --help                Show this help
#
# Examples:
#   # Basic build
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec
#
#   # Custom output directory and extra macros
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec \
#                  --output ./rpms \
#                  --macros "--define 'debug_package %{nil}'"
#
#   # Pre-install local dependency RPMs before the build
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec \
#                  --extra-rpms "output/foo-1.0.rpm output/foo-devel-1.0.rpm"
#
#   # Register an extra dnf repository (e.g. Artifactory) for BuildRequires resolution
#   ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec \
#                  --extra-repo https://artifactory.example.com/artifactory/my-rpm-repo/
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TARBALL=""
SPEC_FILE=""
OUTPUT_DIR="./output"
RPM_MACROS=""
EXTRA_RPMS=""
EXTRA_REPO_DIR=""
BASE_IMAGE="quay.io/centos/centos:stream10"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | sed 's/^# \?//' | sed -n '/^Usage:/,/^====/p' | head -n -1
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tarball)     TARBALL="$2";        shift 2 ;;
        -s|--spec)        SPEC_FILE="$2";      shift 2 ;;
        -o|--output)      OUTPUT_DIR="$2";     shift 2 ;;
        --macros)         RPM_MACROS="$2";     shift 2 ;;
        --extra-rpms)     EXTRA_RPMS="$2";     shift 2 ;;
        --extra-repo)     EXTRA_REPO_DIR="$2"; shift 2 ;;
        --base-image)     BASE_IMAGE="$2";     shift 2 ;;
        -h|--help)        usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate inputs ────────────────────────────────────────────────────────────
if [[ -z "${TARBALL}" ]]; then
    echo "ERROR: --tarball is required." >&2; exit 1
fi
if [[ -z "${SPEC_FILE}" ]]; then
    echo "ERROR: --spec is required." >&2; exit 1
fi
if [[ ! -f "${TARBALL}" ]]; then
    echo "ERROR: Tarball not found: ${TARBALL}" >&2; exit 1
fi
if [[ ! -f "${SPEC_FILE}" ]]; then
    echo "ERROR: Spec file not found: ${SPEC_FILE}" >&2; exit 1
fi
if [[ -n "${EXTRA_REPO_DIR}" && ! "${EXTRA_REPO_DIR}" =~ ^https?:// ]]; then
    echo "ERROR: --extra-repo must be an HTTP/HTTPS URL." >&2; exit 1
fi

# ── Resolve absolute paths ─────────────────────────────────────────────────────
TARBALL_ABS="$(realpath "${TARBALL}")"
SPEC_ABS="$(realpath "${SPEC_FILE}")"

# The build context is the directory containing this script (where Dockerfile lives).
# Both the tarball and spec file must reside inside the build context.
BUILD_CONTEXT="${SCRIPT_DIR}"

CLEANUP_TARBALL=false
CLEANUP_SPEC=false

if [[ "${TARBALL_ABS}" != "${BUILD_CONTEXT}"/* ]]; then
    echo "INFO: Copying tarball into build context..."
    cp "${TARBALL_ABS}" "${BUILD_CONTEXT}/"
    TARBALL_ABS="${BUILD_CONTEXT}/$(basename "${TARBALL_ABS}")"
    CLEANUP_TARBALL=true
fi

if [[ "${SPEC_ABS}" != "${BUILD_CONTEXT}"/* ]]; then
    echo "INFO: Copying spec file into build context..."
    cp "${SPEC_ABS}" "${BUILD_CONTEXT}/"
    SPEC_ABS="${BUILD_CONTEXT}/$(basename "${SPEC_ABS}")"
    CLEANUP_SPEC=true
fi

# Paths relative to the build context (passed as Docker build args)
TARBALL_REL="${TARBALL_ABS#${BUILD_CONTEXT}/}"
SPEC_REL="${SPEC_ABS#${BUILD_CONTEXT}/}"

# ── Prepare output directory ───────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
OUTPUT_ABS="$(realpath "${OUTPUT_DIR}")"

# ── Cleanup trap ───────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${CLEANUP_TARBALL}" == true ]]; then
        rm -f "${BUILD_CONTEXT}/$(basename "${TARBALL_ABS}")"
    fi
    if [[ "${CLEANUP_SPEC}" == true ]]; then
        rm -f "${BUILD_CONTEXT}/$(basename "${SPEC_ABS}")"
    fi
}
trap cleanup EXIT

# ── Run the build ──────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " RPM Builder"
echo "============================================================"
echo " Tarball   : ${TARBALL_REL}"
echo " Spec file : ${SPEC_REL}"
echo " Output    : ${OUTPUT_ABS}"
echo " Base image: ${BASE_IMAGE}"
[[ -n "${RPM_MACROS}" ]] && echo " Macros    : ${RPM_MACROS}"
[[ -n "${EXTRA_RPMS}" ]] && echo " Extra RPMs: ${EXTRA_RPMS}"
[[ -n "${EXTRA_REPO_DIR}" ]] && echo " Extra repo: ${EXTRA_REPO_DIR}"
echo "============================================================"
echo ""

docker build \
    --build-arg "TARBALL=${TARBALL_REL}" \
    --build-arg "SPEC_FILE=${SPEC_REL}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    ${RPM_MACROS:+--build-arg "RPM_MACROS=${RPM_MACROS}"} \
    ${EXTRA_RPMS:+--build-arg "EXTRA_RPMS=${EXTRA_RPMS}"} \
    ${EXTRA_REPO_DIR:+--build-arg "EXTRA_REPO_DIR=${EXTRA_REPO_DIR}"} \
    --output "type=local,dest=${OUTPUT_ABS}" \
    --target artifacts \
    "${BUILD_CONTEXT}"

echo ""
echo "============================================================"
echo " Build complete. Packages written to: ${OUTPUT_ABS}"
echo "============================================================"
ls -lh "${OUTPUT_ABS}/"
