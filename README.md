# qcom-rpm-utils

Shared tooling and **reusable GitHub Actions workflows** for building and releasing RPM packages, targeting Qualcomm® Linux platforms.

This repository is the central home for the build scripts, container image, composite action, and `workflow_call` workflows used by RPM packaging repositories (`pkg-rpm-*`). A packaging repo holds only a single `*.spec` file and a dist-git `sources` pointer; the workflows here turn that into built — and, on release, published — RPMs.

---

## Contents

| Path | Role |
|---|---|
| [`scripts/build-rpm.sh`](scripts/build-rpm.sh) | Runs the prebuilt `rpm-builder` container over a bind-mounted workspace (builds for the runner's host architecture). |
| [`scripts/build-in-container.sh`](scripts/build-in-container.sh) | The per-package build that runs *inside* the container: `dnf builddep` + `rpmbuild -ba`. |
| [`docker/Dockerfile.rpm-builder`](docker/Dockerfile.rpm-builder) | The `rpm-builder` toolchain image, published to GHCR by [`publish-rpm-builder.yml`](.github/workflows/publish-rpm-builder.yml). |
| [`scripts/resolve-sources.sh`](scripts/resolve-sources.sh) | dist-git `sources` resolver: cache lookup → upstream fallback → checksum verify → cache-back. |
| [`.github/actions/rpm-artifactory-upload`](.github/actions/rpm-artifactory-upload/action.yml) | Composite action that uploads RPMs/SRPMs (and source tarballs) to JFrog Artifactory. |
| [`.github/workflows/pkg-build-reusable-workflow.yml`](.github/workflows/pkg-build-reusable-workflow.yml) | `workflow_call` build workflow. |
| [`.github/workflows/pkg-release-reusable-workflow.yml`](.github/workflows/pkg-release-reusable-workflow.yml) | `workflow_call` release (build + publish) workflow. |

See [`docs/reusable-workflows.md`](docs/reusable-workflows.md) for the deep-dive reference.

---

## Requirements

**To run the scripts locally:**
- `bash` and docker — `build-rpm.sh` runs the prebuilt `rpm-builder` container, so `rpmbuild` and the build toolchain come from the image, not the host. Override with `--builder-image` or `$RPM_BUILDER_IMAGE`.
- `rpm`/`rpmspec` on the host if you use `resolve-sources.sh` directly.

---

## Local usage

Resolve sources (query cache, fall back to the spec's `SourceN:` URL, verify checksums):

```bash
./scripts/resolve-sources.sh \
  --sources sources \
  --spec mypackage.spec \
  --cache-base-url https://<artifactory-host>/artifactory/<repo>/sources \
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
