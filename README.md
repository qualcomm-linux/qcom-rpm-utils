# qcom-rpm-utils

Shared tooling and **reusable GitHub Actions workflows** for building and releasing RPM packages, targeting Qualcomm® Linux platforms.

This repository is the central home for the build scripts, container images, composite actions, and `workflow_call` workflows used by RPM packaging repositories (`pkg-rpm-*`). Packaging repos hold only a single `*.spec` file and a dist-git `sources` pointer; the workflows here turn that into built — and, on release, published — RPMs.

## Reusable workflows for building and releasing RPMs

This repo holds reusable CI/CD workflows so that individual packaging repositories don't each reinvent their build and release pipelines. A `pkg-rpm-*` repo simply calls into these workflows via `uses:` and passes a small set of inputs.

| Path | Role |
|---|---|
| [`scripts/build-rpm.sh`](scripts/build-rpm.sh) | Containerised multi-arch (`amd64` + `arm64`) `rpmbuild` driver. |
| [`scripts/Dockerfile`](scripts/Dockerfile) | The RPM builder image used by `build-rpm.sh`. |
| [`scripts/resolve-sources.sh`](scripts/resolve-sources.sh) | dist-git `sources` resolver: cache lookup → upstream fallback → checksum verify → cache-back. |
| [`.github/actions/rpm-artifactory-upload`](.github/actions/rpm-artifactory-upload/action.yml) | Composite action that uploads RPMs (and source tarballs) to JFrog Artifactory. |
| [`.github/workflows/pkg-build-reusable-workflow.yml`](.github/workflows/pkg-build-reusable-workflow.yml) | `workflow_call` build workflow. |
| [`.github/workflows/pkg-release-reusable-workflow.yml`](.github/workflows/pkg-release-reusable-workflow.yml) | `workflow_call` release (build + publish) workflow. |

See [`docs/reusable-workflows.md`](docs/reusable-workflows.md) for full usage, inputs/outputs, the `sources`/lookaside cache model, and caller examples.

Example caller (PR build):

```yaml
jobs:
  build:
    uses: qualcomm-linux/qcom-rpm-utils/.github/workflows/pkg-build-reusable-workflow.yml@main
    with:
      cache-base-url: ${{ vars.CACHE_BASE_URL }}
```

## Branches

**main**: Primary development branch. Contributors should develop submissions based on this branch, and submit pull requests to this branch.

## Requirements

**To call the reusable workflows:**
- A self-hosted GitHub Actions runner (the workflows run on `runs-on: [self-hosted]`) with Docker available or personalised AWS runners.
- The workflows install the `rpm` package on the runner and pull the builder base image on demand.

**To run the scripts locally:**
- `bash` and Docker — `build-rpm.sh` builds inside a container (default base image `quay.io/centos/centos:stream10`), so `rpmbuild` and build dependencies are provided by the image, not the host.
- `rpm`/`rpmspec` on the host if you use `resolve-sources.sh` or otherwise inspect the spec directly.

## Usage

The primary way to use this repo is by calling its reusable workflows from a packaging repo — see the section above and [`docs/reusable-workflows.md`](docs/reusable-workflows.md).

To build a package locally with the same tooling:

```bash
./scripts/build-rpm.sh --tarball <source.tar.gz> --spec <package.spec> --output ./output
```

## Development

Improvements to the build scripts, composite actions, or reusable workflows are welcome. Please develop against `main` and open a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Getting in Contact

* [Report an Issue on GitHub](../../issues)
* [Open a Discussion on GitHub](../../discussions)

## License

*qcom-rpm-utils* is licensed under the [BSD-3-clause License](https://spdx.org/licenses/BSD-3-Clause.html). See [LICENSE.txt](LICENSE.txt) for the full license text.
