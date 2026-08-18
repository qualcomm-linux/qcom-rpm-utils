<!--
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
-->
# Reusable RPM packaging workflows

This repo hosts the shared build tooling and reusable GitHub Actions workflows
for RPM packaging repositories created from
[`pkg-rpm-template`](https://github.com/qualcomm-linux/pkg-rpm-template).

A packaging repo (`pkg-rpm-*`) holds **one `*.spec` file** and a dist-git
**`sources`** pointer file at its root; the source tarball is *not* committed.
These workflows turn that into built (and, on release, published) RPMs.

## Components

| Path | Role |
|---|---|
| [`scripts/build-rpm.sh`](../scripts/build-rpm.sh) | Runs the prebuilt `rpm-builder` container over a bind-mounted workspace (builds for the runner's host architecture). |
| [`scripts/build-in-container.sh`](../scripts/build-in-container.sh) | The per-package build that runs *inside* the container: `dnf builddep` + `rpmbuild -ba`. |
| [`docker/Dockerfile.rpm-builder`](../docker/Dockerfile.rpm-builder) | The `rpm-builder` toolchain image, published to GHCR by [`publish-rpm-builder.yml`](../.github/workflows/publish-rpm-builder.yml). |
| [`scripts/resolve-sources.sh`](../scripts/resolve-sources.sh) | dist-git `sources` resolver: cache lookup → upstream fallback → checksum verify → cache-back. |
| [`.github/actions/rpm-artifactory-upload`](../.github/actions/rpm-artifactory-upload/action.yml) | Composite action that uploads RPMs (and source tarballs) to JFrog Artifactory. |
| [`.github/workflows/pkg-build-reusable-workflow.yml`](../.github/workflows/pkg-build-reusable-workflow.yml) | `workflow_call` build workflow. |
| [`.github/workflows/pkg-release-reusable-workflow.yml`](../.github/workflows/pkg-release-reusable-workflow.yml) | `workflow_call` release (build + publish) workflow. |

## The `sources` / lookaside cache model

This follows the Fedora/CentOS
[dist-git](https://github.com/release-engineering/dist-git) model. Each line of
`sources` is the BSD `shaNsum --tag` format:

```
SHA512 (mypackage-1.0.tar.gz) = 3a7bd3e2360a3d29...
```

`resolve-sources.sh` processes each entry:

1. **Cache lookup.** Compute the lookaside path
   (default `{filename}/{hashtype}/{hash}/{filename}`)
   under `--cache-base-url` and `HEAD`-query it.
2. **Cache hit** → download the tarball from the cache.
   **Cache miss** → expand the spec (`rpmspec -P`), find the `SourceN:` URL whose
   basename matches `filename`, and download from upstream.
3. **Verify** the staged tarball against the checksum in `sources`; fail on
   mismatch (whether from cache or upstream).
4. **Cache-back** (release builds only, `--emit-cache-uploads`): record
   upstream-fetched tarballs so the caller uploads them to
   `<target-repo>/sources/<lookaside-path>` for future builds.

This means a maintainer only ever edits `sources` (and the spec version) when
bumping versions; the first release build populates the cache automatically.

## `pkg-build-reusable-workflow.yml`

Build the RPM(s). Used by the PR workflow and by the release workflow.

**Key inputs:** `qcom-rpm-utils-ref`, `cache-base-url` (**required**),
`cache-path-template`, `builder-image`, `extra-repo`, `release`, `server-url`,
`target-repo`. **Secrets:** `ARTIFACTORY_ACCESS_TOKEN` and/or `QSC_API_KEY`
(only needed when `release: true`, for source cache-back — see
[Authentication](#authentication)). **Outputs:** `artifact-name`, `pkg-name`,
`pkg-version`.

Caller example (PR build, read-only cache):

```yaml
jobs:
  build:
    uses: qualcomm-linux/qcom-rpm-utils/.github/workflows/pkg-build-reusable-workflow.yml@main
    with:
      qcom-rpm-utils-ref: main
      cache-base-url: ${{ vars.CACHE_BASE_URL }}
```

## `pkg-release-reusable-workflow.yml`

Build then publish to Artifactory. The `publish` job runs in the
**`pkg-release-approval`** environment, so a maintainer must approve the run
before anything is uploaded.

**Key inputs:** `qcom-rpm-utils-ref`, `cache-base-url` (**required**),
`server-url`, `target-repo` (default `qsc-rpm-releases-stage`), `distro`
(default `centos`), `distro-version` (default `10`), `channel` (default `os`).
**Secrets:** `ARTIFACTORY_ACCESS_TOKEN` and/or `QSC_API_KEY` (**at least one
required** — see [Authentication](#authentication)).

`target-repo` is a repo name *plus* any path prefix under it, and it is the root
that **both** the RPM upload and the source cache-back derive from — source
tarballs are cached back to `<target-repo>/sources/`. Setting it once keeps both
writes inside the same Artifactory subtree; an upload outside a permitted subtree
is rejected with `403`. Keep `cache-base-url` pointed at the matching
`<target-repo>/sources`, or cache reads will never match cache-back writes.

RPMs are published into a standard YUM tree, split by architecture:

```
<target-repo>/<distro>/<distro-version>/<channel>/
├── aarch64/Packages/     <- binary RPMs
├── noarch/Packages/
├── x86_64/Packages/
└── SRPMS/Packages/       <- source RPMs (*.src.rpm)
```

With the defaults that is `<repo>/centos/10/os/<arch>/Packages/`. Architecture is
read from each filename, and `*.src.rpm` is routed to `SRPMS/` rather than an
`src/` directory.


`yumRootDepth` is a single repo-wide setting, so every tree in the repo must
publish at the same nesting level. The layout above is deliberately uniform —
`SRPMS/` sits at the same depth as the arch directories, so one depth value
indexes both.

Caller example:

```yaml
jobs:
  release:
    uses: qualcomm-linux/qcom-rpm-utils/.github/workflows/pkg-release-reusable-workflow.yml@main
    with:
      qcom-rpm-utils-ref: main
      cache-base-url: ${{ vars.CACHE_BASE_URL }}
    secrets:
      # Provide the Artifactory access token (QSC_API_KEY flow comes later).
      ARTIFACTORY_ACCESS_TOKEN: ${{ secrets.ARTIFACTORY_ACCESS_TOKEN }}
```

## Authentication

Publishing (and release-time source cache-back) needs Artifactory credentials.
The composite action accepts **two** mutually-exclusive secrets and resolves
them in this order:

1. **`QSC_API_KEY`** — if set, it is exchanged for a short-lived Artifactory
   access token via the QSC token API. **Takes precedence** over
   `ARTIFACTORY_ACCESS_TOKEN`.
2. **`ARTIFACTORY_ACCESS_TOKEN`** — if `QSC_API_KEY` is not set, this
   pre-generated access token is used directly.
3. If **neither** is set, the publish/cache-back step fails.


## Required configuration (in the calling repo)

| Name | Kind | Purpose |
|---|---|---|
| `CACHE_BASE_URL` | Actions **variable** | Base URL of the lookaside cache. Must be `<server>/artifactory/<target-repo>/sources` so cache reads match cache-back writes. |
| `ARTIFACTORY_ACCESS_TOKEN` | Actions **secret** | Pre-generated Artifactory access token for publishing / cache-back. Release only. **Currently the recommended credential.** |
| `QSC_API_KEY` | Actions **secret** | QSC API key exchanged for an Artifactory token; takes precedence over `ARTIFACTORY_ACCESS_TOKEN` when set. Release only. (Not yet the recommended path.) |
| `pkg-release-approval` | Environment | Approval gate for the publish job. Add required reviewers. |
