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
   (default `{name}/{filename}/{hashtype}/{hash}/{filename}`, `{name}` = repo
   name) under `--cache-base-url` and `HEAD`-query it.
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
`cache-path-template`, `builder-image`, `extra-repo`, `release`,
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
`server-url`, `target-repo` (default `qualcomm-dnf-repo`), `target-subpath`
(default `10-stream/BaseOS/Packages`). **Secrets:** `ARTIFACTORY_ACCESS_TOKEN`
and/or `QSC_API_KEY` (**at least one required** — see
[Authentication](#authentication)).

All built RPMs are uploaded flat into `<target-repo>/<target-subpath>/`, i.e.
`qualcomm-dnf-repo/10-stream/BaseOS/Packages/`. Binary and source RPMs alike are
dumped directly into that directory — no `src/` or `output/` subfolders. The YUM
`repodata/` is **not** uploaded by the workflow — Artifactory's YUM indexer
calculates it. Setting the repo's **YUM Metadata Folder Depth to `2`** will write
metadata to `qualcomm-dnf-repo/10-stream/BaseOS/repodata/`, alongside the
`Packages/` dir.

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

> **Current recommendation:** configure **`ARTIFACTORY_ACCESS_TOKEN`** only. The
> `QSC_API_KEY` flow is wired up but not yet the recommended path; this doc will
> be updated to prefer it once the QSC key issue is resolved.

Whichever credential is used, the account behind it must have Deploy permission
on the target repo and must be a member of the
[`centos.rpm.devs`](https://lists.qualcomm.com/ListManager?id=centos.rpm.devs)
Qualcomm list, or the upload will be rejected.

## Required configuration (in the calling repo)

| Name | Kind | Purpose |
|---|---|---|
| `CACHE_BASE_URL` | Actions **variable** | Base URL of the lookaside cache (e.g. the Artifactory `qualcomm-dnf-repo/sources` base). |
| `ARTIFACTORY_ACCESS_TOKEN` | Actions **secret** | Pre-generated Artifactory access token for publishing / cache-back. Release only. **Currently the recommended credential.** |
| `QSC_API_KEY` | Actions **secret** | QSC API key exchanged for an Artifactory token; takes precedence over `ARTIFACTORY_ACCESS_TOKEN` when set. Release only. (Not yet the recommended path.) |
| `centos.rpm.devs` membership | Qualcomm list | The publishing account must belong to [`centos.rpm.devs`](https://lists.qualcomm.com/ListManager?id=centos.rpm.devs) for uploads to be accepted. |
| `pkg-release-approval` | Environment | Approval gate for the publish job. Add required reviewers. |
