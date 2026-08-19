#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# =============================================================================
# Usage:
#   ./build-rpm.sh --tarball <path> --spec <path> [OPTIONS]
#
# Builds RPM + SRPM packages by running the prebuilt `rpm-builder` toolchain
# container (ghcr.io/<owner>/rpm-builder:centos10) over a bind-mounted
# workspace. The container already provides rpm-build, compilers, and CRB+EPEL,
# so no toolchain install happens per build; only the spec's BuildRequires are
# resolved at build time (dnf builddep). The per-package build logic lives in
# scripts/build-in-container.sh, which runs inside the container.
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
#       --builder-image <ref> Toolchain image to run
#                             (default: $RPM_BUILDER_IMAGE, else
#                              ghcr.io/qualcomm-linux/rpm-builder:centos10)
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
#
#   # Override the toolchain image
#   RPM_BUILDER_IMAGE=ghcr.io/myorg/rpm-builder:centos10 \
#     ./build-rpm.sh --tarball mypackage-1.0.tar.gz --spec mypackage.spec
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TARBALL=""
SPEC_FILE=""
OUTPUT_DIR="./output"
RPM_MACROS=""
EXTRA_RPMS=""
EXTRA_REPO_DIR=""
BUILDER_IMAGE="${RPM_BUILDER_IMAGE:-ghcr.io/qualcomm-linux/rpm-builder:centos10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | sed 's/^# \?//' | sed -n '/^Usage:/,/^====/p' | head -n -1
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tarball)       TARBALL="$2";        shift 2 ;;
        -s|--spec)          SPEC_FILE="$2";      shift 2 ;;
        -o|--output)        OUTPUT_DIR="$2";     shift 2 ;;
        --macros)           RPM_MACROS="$2";     shift 2 ;;
        --extra-rpms)       EXTRA_RPMS="$2";     shift 2 ;;
        --extra-repo)       EXTRA_REPO_DIR="$2"; shift 2 ;;
        --builder-image)    BUILDER_IMAGE="$2";  shift 2 ;;
        -h|--help)          usage ;;
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
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found in PATH." >&2; exit 1
fi

# ── Build a self-contained workspace ────────────────────────────────────────────
TARBALL_ABS="$(realpath "${TARBALL}")"
SPEC_ABS="$(realpath "${SPEC_FILE}")"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_ABS="$(realpath "${OUTPUT_DIR}")"

WORKSPACE="$(mktemp -d)"
cleanup() { rm -rf "${WORKSPACE}" 2>/dev/null || true; }
trap cleanup EXIT

cp "${TARBALL_ABS}" "${WORKSPACE}/"
cp "${SPEC_ABS}"    "${WORKSPACE}/"
TARBALL_BASE="$(basename "${TARBALL_ABS}")"
SPEC_BASE="$(basename "${SPEC_ABS}")"

SPEC_DIR="$(dirname "${SPEC_ABS}")"
for patch in "${SPEC_DIR}"/*.patch; do
    [[ -f "${patch}" ]] && cp "${patch}" "${WORKSPACE}/"
done

CONTAINER_EXTRA_RPMS=""
if [[ -n "${EXTRA_RPMS}" ]]; then
    for rpm in ${EXTRA_RPMS}; do
        if [[ ! -f "${rpm}" ]]; then
            echo "ERROR: --extra-rpms entry not found: ${rpm}" >&2; exit 1
        fi
        cp "$(realpath "${rpm}")" "${WORKSPACE}/"
        CONTAINER_EXTRA_RPMS="${CONTAINER_EXTRA_RPMS:+${CONTAINER_EXTRA_RPMS} }$(basename "${rpm}")"
    done
fi

# ── Run the build inside the toolchain container ─────────────────────────────────
echo ""
echo "============================================================"
echo " RPM Builder (container)"
echo "============================================================"
echo " Tarball   : ${TARBALL_BASE}"
echo " Spec file : ${SPEC_BASE}"
echo " Output    : ${OUTPUT_ABS}"
echo " Image     : ${BUILDER_IMAGE}"
[[ -n "${RPM_MACROS}" ]]           && echo " Macros    : ${RPM_MACROS}"
[[ -n "${CONTAINER_EXTRA_RPMS}" ]] && echo " Extra RPMs: ${CONTAINER_EXTRA_RPMS}"
[[ -n "${EXTRA_REPO_DIR}" ]]       && echo " Extra repo: ${EXTRA_REPO_DIR}"
echo "============================================================"
echo ""


docker pull "${BUILDER_IMAGE}" || echo "WARN: could not pull ${BUILDER_IMAGE}; using local copy if present."

docker run --rm \
    -v "${WORKSPACE}:/workspace" \
    -v "${SCRIPT_DIR}/build-in-container.sh:/usr/local/bin/build-in-container.sh:ro" \
    -e "TARBALL=${TARBALL_BASE}" \
    -e "SPEC_FILE=${SPEC_BASE}" \
    -e "RPM_MACROS=${RPM_MACROS}" \
    -e "EXTRA_RPMS=${CONTAINER_EXTRA_RPMS}" \
    -e "EXTRA_REPO_DIR=${EXTRA_REPO_DIR}" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    "${BUILDER_IMAGE}" \
    bash /usr/local/bin/build-in-container.sh

if [[ -d "${WORKSPACE}/output" ]]; then
    cp -a "${WORKSPACE}/output/." "${OUTPUT_ABS}/"
fi

echo ""
echo "============================================================"
echo " Build complete. Packages written to: ${OUTPUT_ABS}"
echo "============================================================"
ls -lh "${OUTPUT_ABS}/"
