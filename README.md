# qcom-rpm-utils

Shared tooling and **reusable GitHub Actions workflows** for building and releasing RPM packages, targeting Qualcomm® Linux platforms.

This repository is the central home for the build scripts, container image, composite action, and `workflow_call` workflows used by RPM packaging repositories (`pkg-rpm-*`). A packaging repo holds only a single `*.spec` file and a dist-git `sources` pointer; the workflows here turn that into built — and, on release, published — RPMs.

---

## Contents

| Path | Role |
|---|---|
| [`scripts/build-rpm.sh`](scripts/build-rpm.sh) | Containerised `rpmbuild` driver (builds for the runner's host architecture). |
| [`scripts/Dockerfile`](scripts/Dockerfile) | The RPM builder image used by `build-rpm.sh`. |
| [`scripts/resolve-sources.sh`](scripts/resolve-sources.sh) | dist-git `sources` resolver: cache lookup → upstream fallback → checksum verify → cache-back. |
| [`.github/actions/rpm-artifactory-upload`](.github/actions/rpm-artifactory-upload/action.yml) | Composite action that uploads RPMs/SRPMs (and source tarballs) to JFrog Artifactory. |
| [`.github/workflows/pkg-build-reusable-workflow.yml`](.github/workflows/pkg-build-reusable-workflow.yml) | `workflow_call` build workflow. |
| [`.github/workflows/pkg-release-reusable-workflow.yml`](.github/workflows/pkg-release-reusable-workflow.yml) | `workflow_call` release (build + publish) workflow. |

See [`docs/reusable-workflows.md`](docs/reusable-workflows.md) for the deep-dive reference.

---

## How the pieces fit together

```
pkg-rpm-<component> (caller)                 qcom-rpm-utils (this repo)
  build-on-pr.yml  ──uses──▶  pkg-build-reusable-workflow.yml
  pkg-release.yml  ──uses──▶  pkg-release-reusable-workflow.yml
                                     │
                                     ├─ resolve-sources.sh   (cache → upstream → verify)
                                     ├─ build-rpm.sh + Dockerfile  (host-arch rpmbuild)
                                     └─ rpm-artifactory-upload     (QSC key → token → jf rt upload)
```

- **Build** resolves the source tarball(s), builds the RPM(s) in a container, and uploads them as a GitHub build artifact.
- **Release** runs the same build, then — behind a manual approval gate — publishes the RPMs to JFrog Artifactory and caches any upstream-fetched source tarballs back.

---

## The `sources` / lookaside cache model

Packaging repos follow the Fedora/CentOS **dist-git** model: git tracks the spec and a small `sources` file (checksum + filename); the tarball itself is **never committed** — it lives in an Artifactory lookaside cache, keyed by its checksum.

`resolve-sources.sh` processes each `sources` entry:

1. **Cache lookup** — compute the lookaside path under `CACHE_BASE_URL` (default `{filename}/{hashtype}/{hash}/{filename}`) and `HEAD` it.
2. **Hit** → download from the cache. **Miss** → read the matching `SourceN:` URL from the spec and download from **upstream**.
3. **Verify** the tarball's checksum against `sources`; a mismatch fails the build.
4. **Cache-back** (release only) — an upstream-fetched tarball is uploaded to `<repo>/sources/...` so the next build is a cache hit.

---

## Reusable workflow reference

### `pkg-build-reusable-workflow.yml`

Builds the RPM(s). Used by the PR workflow and internally by the release workflow.

| Input | Req | Default | Purpose |
|---|---|---|---|
| `cache-base-url` | **yes** | — | Base URL of the Artifactory lookaside cache. |
| `qcom-rpm-utils-ref` | no | `main` | Git ref of this repo to pin the tooling to. |
| `base-image` | no | `""` | Override the rpmbuild base image. |
| `extra-repo` | no | `""` | Extra dnf repo URL for `BuildRequires` resolution. |
| `release` | no | `false` | Cache verified upstream tarballs back to Artifactory. |
| `cache-path-template` | no | `{filename}/{hashtype}/{hash}/{filename}` | Lookaside path layout. |
| `target-repo` | no | `qualcomm-dnf-repo` | Artifactory repo for source cache-back. |

| Secret | Req | Purpose |
|---|---|---|
| `QSC_API_KEY` | no | Needed only when `release: true`, to cache tarballs back. |

**Outputs:** `artifact-name`, `pkg-name`, `pkg-version`.

### `pkg-release-reusable-workflow.yml`

Builds, then publishes to Artifactory behind the **`pkg-release-approval`** environment.

| Input | Req | Default | Purpose |
|---|---|---|---|
| `cache-base-url` | **yes** | — | Base URL of the lookaside cache. |
| `qcom-rpm-utils-ref` | no | `main` | Tooling ref. |
| `server-url` | no | `https://qartifactory.qualcomm.com` | Artifactory server. |
| `target-repo` | no | `qualcomm-dnf-repo` | Repo to publish into. |
| `base-image` / `extra-repo` / `cache-path-template` | no | (as build) | Forwarded to the build. |

| Secret | Req | Purpose |
|---|---|---|
| `QSC_API_KEY` | **yes** | Exchanged for a short-lived JFrog token to publish. |

**Published layout** (defaults): RPMs → `qualcomm-dnf-repo/<pkg>/<version>/…` (SRPM under `…/src/`); cached tarballs → `qualcomm-dnf-repo/sources/<filename>/<hashtype>/<hash>/<filename>`.

---

## Authentication

The `rpm-artifactory-upload` action authenticates to Artifactory by exchanging the **`QSC_API_KEY`** for a short-lived **JFrog access token** (via the QSC token endpoint), then running `jf rt upload`. The token's service account must have **Deploy + Annotate** permission on the backing local repo behind `qualcomm-dnf-repo` (e.g. `qsc-rpm-local`). No JFrog credentials are stored in the repo.

---

## Requirements

**To call the reusable workflows:**
- A self-hosted GitHub Actions runner (the workflows use `runs-on: [self-hosted]`) with **Docker** available.
- The workflows install the `rpm` package on the runner and pull the builder base image on demand.

**To run the scripts locally:**
- `bash` and Docker — `build-rpm.sh` builds inside a container (default base image `quay.io/centos/centos:stream10`), so `rpmbuild` and build dependencies come from the image, not the host.
- `rpm`/`rpmspec` on the host if you use `resolve-sources.sh` directly.

---

## Local usage

Resolve sources (query cache, fall back to the spec's `SourceN:` URL, verify checksums):

```bash
./scripts/resolve-sources.sh \
  --sources sources \
  --spec mypackage.spec \
  --cache-base-url https://qartifactory.qualcomm.com/artifactory/qualcomm-dnf-repo/sources \
  --dest ./sources-cache
```

Build the RPM(s):

```bash
./scripts/build-rpm.sh \
  --tarball ./sources-cache/mypackage-1.0.tar.gz \
  --spec mypackage.spec \
  --output ./output          # builds for the runner's host architecture
```

---

## Branches

**main**: Primary development branch. Develop against `main` and open pull requests to it.

## Development

Improvements to the build scripts, composite action, or reusable workflows are welcome. Please develop against `main` and open a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Getting in Contact

* [Report an Issue on GitHub](../../issues)
* [Open a Discussion on GitHub](../../discussions)

## License

*qcom-rpm-utils* is licensed under the [BSD-3-clause License](https://spdx.org/licenses/BSD-3-Clause.html). See [LICENSE.txt](LICENSE.txt) for the full license text.
