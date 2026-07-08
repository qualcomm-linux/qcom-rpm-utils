#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# =============================================================================
# resolve-sources.sh — dist-git "sources + lookaside cache" resolver for RPM
# packaging repos.
# =============================================================================
# Given a dist-git `sources` file and the package `.spec`, this makes every
# source tarball available locally for the build, following the Fedora/CentOS
# dist-git model.
#
# Usage:
#   resolve-sources.sh --sources <file> --spec <file> --cache-base-url <url> \
#                      [--dest <dir>] [--name <pkg>] \
#                      [--path-template <tmpl>] [--emit-cache-uploads]
#
# Options:
#   --sources <file>        Path to the dist-git `sources` file (required).
#   --spec <file>           Path to the package `.spec` file (required; used to
#                           resolve SourceN: URLs on a cache miss).
#   --cache-base-url <url>  Base URL of the lookaside cache (required).
#   --dest <dir>            Directory to stage tarballs into (default: ./sources-cache).
#   --name <pkg>            Lookaside namespace / package name. Defaults to
#                           $GITHUB_REPOSITORY basename, else the spec's Name:.
#   --path-template <tmpl>  Lookaside path template appended to the base URL.
#                           Placeholders: {name} {filename} {hashtype} {hash}.
#                           Default: {filename}/{hashtype}/{hash}/{filename}
#   --emit-cache-uploads    Emit "localpath<TAB>cache-relative-path" lines (for
#                           tarballs fetched from upstream) so the caller can
#                           upload them back to the cache.
#   -h, --help              Show this help.
#
# Outputs:
#   * Writes resolved values to $GITHUB_OUTPUT when set (CI), else to stdout:
#       tarball=<primary tarball path>          (first, sorted)
#       tarballs=<space-separated tarball paths>
#   * With --emit-cache-uploads, writes a manifest of tarballs that were fetched
#     from upstream (and therefore should be cached back) to
#     "<dest>/.cache-uploads" as TAB-separated "localpath<TAB>cache-rel-path".
# =============================================================================
set -euo pipefail

SOURCES_FILE=""
SPEC_FILE=""
CACHE_BASE_URL=""
DEST_DIR="./sources-cache"
PKG_NAME=""
PATH_TEMPLATE='{filename}/{hashtype}/{hash}/{filename}'
EMIT_CACHE_UPLOADS=false

usage() {
    grep '^#' "$0" | sed 's/^# \?//' | sed -n '/^Usage:/,/^====/p' | head -n -1
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sources)             SOURCES_FILE="$2";   shift 2 ;;
        --spec)                SPEC_FILE="$2";      shift 2 ;;
        --cache-base-url)      CACHE_BASE_URL="$2"; shift 2 ;;
        --dest)                DEST_DIR="$2";       shift 2 ;;
        --name)                PKG_NAME="$2";       shift 2 ;;
        --path-template)       PATH_TEMPLATE="$2";  shift 2 ;;
        --emit-cache-uploads)  EMIT_CACHE_UPLOADS=true; shift ;;
        -h|--help)             usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${SOURCES_FILE}" ]]; then
    echo "ERROR: --sources is required." >&2; exit 1
fi
if [[ ! -f "${SOURCES_FILE}" ]]; then
    echo "ERROR: sources file not found: ${SOURCES_FILE}" >&2; exit 1
fi
if [[ -z "${SPEC_FILE}" ]]; then
    echo "ERROR: --spec is required." >&2; exit 1
fi
if [[ ! -f "${SPEC_FILE}" ]]; then
    echo "ERROR: spec file not found: ${SPEC_FILE}" >&2; exit 1
fi
if [[ -z "${CACHE_BASE_URL}" ]]; then
    echo "ERROR: --cache-base-url is required (or set the CACHE_BASE_URL variable)." >&2; exit 1
fi

if [[ -z "${PKG_NAME}" ]]; then
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        PKG_NAME="${GITHUB_REPOSITORY##*/}"
    elif command -v rpmspec >/dev/null 2>&1; then
        PKG_NAME="$(rpmspec -q --srpm --qf '%{name}\n' "${SPEC_FILE}" 2>/dev/null | head -n1 || true)"
    fi
fi
if [[ -z "${PKG_NAME}" ]]; then
    echo "ERROR: could not determine package name; pass --name." >&2; exit 1
fi

BASE="${CACHE_BASE_URL%/}"
mkdir -p "${DEST_DIR}"
CACHE_UPLOADS_MANIFEST="${DEST_DIR}/.cache-uploads"
: > "${CACHE_UPLOADS_MANIFEST}"


render_cache_path() {
    local filename="$1" hashtype="$2" hexdigest="$3"
    local rel="${PATH_TEMPLATE}"
    rel="${rel//\{name\}/${PKG_NAME}}"
    rel="${rel//\{filename\}/${filename}}"
    rel="${rel//\{hashtype\}/${hashtype}}"
    rel="${rel//\{hash\}/${hexdigest}}"
    printf '%s' "${rel}"
}

spec_source_url_for() {
    local want="$1"
    local lister=""
    if command -v spectool >/dev/null 2>&1; then
        lister="spectool"
    elif command -v rpmdev-spectool >/dev/null 2>&1; then
        lister="rpmdev-spectool"
    fi

    local urls=""
    if [[ -n "${lister}" ]]; then
        urls="$("${lister}" -l -S "${SPEC_FILE}" 2>/dev/null \
            | sed -E 's/^[[:space:]]*[Ss]ource[0-9]*:[[:space:]]*//')"
    elif command -v rpmspec >/dev/null 2>&1; then
        # rpmspec -P expands macros (%{name}, %{version}, ...) in the spec, so the
        # printed SourceN: lines carry fully-resolved URLs.
        urls="$(rpmspec -P "${SPEC_FILE}" 2>/dev/null \
            | grep -iE '^\s*Source[0-9]*:' \
            | sed -E 's/^[[:space:]]*[Ss]ource[0-9]*:[[:space:]]*//')"
    else
        echo "ERROR: neither spectool nor rpmspec found; cannot resolve upstream URL for ${want}." >&2
        return 1
    fi

    while IFS= read -r url; do
        [[ -z "${url}" ]] && continue
        if [[ "${url##*/}" == "${want}" ]]; then
            printf '%s\n' "${url}"
            return 0
        fi
    done <<< "${urls}"
}

declare -a TARBALLS=()

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ ! "$line" =~ ^([A-Za-z0-9]+)\ \((.+)\)\ =\ ([0-9A-Fa-f]+)$ ]]; then
        echo "ERROR: Malformed line in 'sources': ${line}" >&2
        echo "Expected: HASHTYPE (filename) = hexdigest   (e.g. SHA512 (foo-1.0.tar.gz) = abc123...)" >&2
        exit 1
    fi
    hashtype_raw="${BASH_REMATCH[1]}"
    filename="${BASH_REMATCH[2]}"
    hexdigest="${BASH_REMATCH[3]}"

    hashtype="$(echo "${hashtype_raw}" | tr '[:upper:]' '[:lower:]')"
    sum_tool="${hashtype}sum"
    if ! command -v "${sum_tool}" >/dev/null 2>&1; then
        echo "ERROR: Unsupported hash type '${hashtype_raw}' (no ${sum_tool} available)." >&2
        exit 1
    fi

    rel="$(render_cache_path "${filename}" "${hashtype}" "${hexdigest}")"
    url="${BASE}/${rel}"
    dest="${DEST_DIR}/${filename}"
    from_upstream=false

    echo "::group::Resolving ${filename}"
    if curl -fsI --retry 3 "${url}" >/dev/null 2>&1; then
        echo "Cache HIT: ${url}"
        if ! curl -fsSL --retry 3 -o "${dest}" "${url}"; then
            echo "ERROR: Failed to download ${filename} from the cache: ${url}" >&2
            exit 1
        fi
    else
        echo "Cache MISS: ${url}"
        echo "Resolving upstream URL from the spec's SourceN: directives..."
        upstream="$(spec_source_url_for "${filename}")"
        if [[ -z "${upstream}" ]]; then
            echo "ERROR: ${filename} is not in the cache and no matching SourceN: URL" >&2
            echo "       was found in ${SPEC_FILE}. Add the source to the cache or to the spec." >&2
            exit 1
        fi
        if [[ ! "${upstream}" =~ ^https?:// && ! "${upstream}" =~ ^ftp:// ]]; then
            echo "ERROR: SourceN: for ${filename} is not a downloadable URL: ${upstream}" >&2
            echo "       Pre-populate the cache for sources that are not fetchable URLs." >&2
            exit 1
        fi
        echo "Downloading from upstream: ${upstream}"
        if ! curl -fsSL --retry 3 -o "${dest}" "${upstream}"; then
            echo "ERROR: Failed to download ${filename} from upstream: ${upstream}" >&2
            exit 1
        fi
        from_upstream=true
    fi

    if ! echo "${hexdigest}  ${dest}" | "${sum_tool}" -c - >/dev/null 2>&1; then
        echo "ERROR: Checksum mismatch for ${filename}." >&2
        echo "       Expected ${hashtype} ${hexdigest}" >&2
        echo "       Got      $(${sum_tool} "${dest}" | awk '{print $1}')" >&2
        if [[ "${from_upstream}" == true ]]; then
            echo "       The upstream tarball does not match 'sources'. Update the SHA in" >&2
            echo "       'sources' (and the spec version) or fix the SourceN: URL." >&2
        else
            echo "       The cached tarball is corrupt or tampered. Re-upload the correct tarball." >&2
        fi
        exit 1
    fi
    echo "Verified ${hashtype} checksum for ${filename}"

    if [[ "${from_upstream}" == true && "${EMIT_CACHE_UPLOADS}" == true ]]; then
        printf '%s\t%s\n' "$(realpath "${dest}")" "${rel}" >> "${CACHE_UPLOADS_MANIFEST}"
        echo "Queued for cache-back: ${rel}"
    fi
    echo "::endgroup::"

    TARBALLS+=("${dest}")
done < "${SOURCES_FILE}"

if [[ "${#TARBALLS[@]}" -eq 0 ]]; then
    echo "ERROR: 'sources' produced no tarballs." >&2
    exit 1
fi

mapfile -t SORTED < <(printf '%s\n' "${TARBALLS[@]}" | sort)
PRIMARY="${SORTED[0]}"
ALL="${SORTED[*]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "tarball=${PRIMARY}"
        echo "tarballs=${ALL}"
    } >> "${GITHUB_OUTPUT}"
fi
echo "Primary tarball: ${PRIMARY}"
echo "All tarballs:    ${ALL}"
if [[ "${EMIT_CACHE_UPLOADS}" == true && -s "${CACHE_UPLOADS_MANIFEST}" ]]; then
    echo "Cache-back manifest: ${CACHE_UPLOADS_MANIFEST}"
fi
