# Developer setup and the 1.0 release process

This guide describes the source and release setup for
[hachamacha106/w3x2lni-Reforged](https://github.com/hachamacha106/w3x2lni-reforged).
The product name is **W3x2lni Reforged**, the first release title is
**W3x2lni Reforged 1.0**, its application version is **`1.0.0`**, and its tag is
**`v1.0.0`**.

## Release files

| File | Purpose |
| --- | --- |
| `release.json` | Machine-readable release version, tag, repository, and asset naming. |
| `script/share/changelog.lua` | Application version and in-app change history. |
| `CHANGELOG.md` | Public history of the fork. |
| `docs/releases/1.0.0.md` | The body used for the GitHub release draft. |
| `make/package-release.py` | Portable packaging, source/runtime provenance, checksum checks, and validation gates. |
| `.github/workflows/build.yml` | Linux package validation, Windows native CLI checks, and draft-release creation. |

The portable asset is **`w3x2lni-reforged-1.0.0-windows-x86.zip`**. Its top-level
directory is **`w3x2lni-reforged-1.0.0`**. Keep the existing executable names:
`w3x2lni.exe` for the GUI, `w2l.exe` for the CLI, and
`bin/w3x2lni-lua.exe` for the bundled interpreter.

## First-time fork setup

On GitHub, open this fork's
[Actions page](https://github.com/hachamacha106/w3x2lni-reforged/actions). If
GitHub asks you to enable workflows for the fork, enable them. The workflow is
named **Reforged release checks**. It declares the permissions required by each
job and uses GitHub's normal workflow token; no personal token is needed for
draft creation.

Enable **Issues** in the repository's settings if it is not already enabled so
the README's bug-report link and issue form are available. A suitable About
description is:

> Warcraft III Reforged map converter for LNI, OBJ, and SLK workflows.

The source change set must be pushed to the fork before its workflows and
release notes are available there. A local bundle, source archive, or local
commit does not change the GitHub repository by itself.

## Integrate the release branch

If the prepared changes are on local branch `release/reforged-1.0.0`, first
push that branch for review:

```sh
git push -u origin release/reforged-1.0.0
```

Merge it into the fork's default branch on GitHub, or use the following from
your local clone when `master` can advance directly to the release branch:

```sh
git switch master
git pull --ff-only origin master
git merge --ff-only release/reforged-1.0.0
git push origin master
```

If your default branch is `main`, substitute `main` in those commands. Check the
**Reforged release checks** run for that branch. The workflow builds and validates
an artifact on pushes to `master` / `main`, pull requests to those branches, and
manual runs. A manual run validates the selected branch or tag; it does not
create a release.

## Create the 1.0 draft

Once the integrated source passes the checks, create the version tag from that
exact commit and push the tag:

```sh
git tag -a v1.0.0 -m "W3x2lni Reforged 1.0"
git push origin v1.0.0
```

The tag name must match `release.json`. The workflow rejects a mismatched
`v*` tag. A matching tag pushed to this fork runs the following sequence:

1. Verify release metadata and the official native-runtime download.
2. Build a portable candidate from the committed source and supplied data.
3. Run all 14 compatibility groups from that extracted candidate, including the
   eight actual-map conversion paths and six MPQ archive checks.
4. Produce the final ZIP with the tested runtime/data fingerprint and its
   checksum evidence.
5. Run the exact ZIP on a Windows runner using the packaged executables and
   native modules. Check OBJ, LNI, LNI-to-OBJ, and SLK conversion reports and
   rebuilt archive semantics.
6. Create a **draft** release with the prepared notes, portable ZIP, external
   ZIP checksum, and `WINDOWS_SMOKE.json`.

Both test jobs must succeed before the draft job runs. The workflow does not
publish the draft automatically.

### Review and publish

Open the draft under
[Releases](https://github.com/hachamacha106/w3x2lni-reforged/releases). Download
its ZIP, extract it into a fresh directory on Windows, and confirm the application
shows **W3x2lni Reforged 1.0.0**. Test the GUI, report resizing and clipboard, and
representative maps in your World Editor and game. The automated Windows CLI
checks do not exercise those interactions or real CASC game-data extraction.

Review the release notes and assets, then use GitHub's **Publish release** action
when the draft is ready. The 1.0 tag should identify the exact source associated
with the released assets; use a new version for subsequent published fixes.

## Reproduce the Linux package checks

Use Python 3.10 or later, Git, GCC, G++, and curl on Linux. Clone the repository
and initialize its pinned dependencies:

```sh
git clone --recurse-submodules https://github.com/hachamacha106/w3x2lni-reforged.git
cd w3x2lni-Reforged
git submodule update --init --recursive
```

Work from the release source commit. The packager normally requires a clean,
committed checkout so `BUILD_INFO.json` can identify the exact source. Its
`--allow-dirty` option is only for development candidates and is not part of the
release workflow.

### Build the test runtime and obtain the native package

```sh
mkdir -p build/release-check
python3 -B test/compat/build_runtime.py "$PWD/build/compat-runtime"
python3 -B test/compat/mpq_archive.py build 3rd/stormlib "$PWD/build/mpq-runtime"
export W2L_TEST_RUNTIME="$PWD/build/compat-runtime"
curl --fail --location --output build/upstream-2.7.3.zip \
  https://github.com/sumneko/w3x2lni/releases/download/2.7.3/w3x2lni-2.7.3.zip
```

The packager requires the official archive's SHA-256:

```text
58c6523b6d34fea55b6904f40298b24f72367f7d975494cb7dff23cb1241c440
```

It also verifies that all 22 native executables and DLLs are unchanged. The Linux
runtime built above is used only for tests and is not shipped as the Windows
runtime.

### Build a candidate and test its actual contents

The output directories below must be new; the test runners refuse to reuse an
existing validation directory. The fixture is committed at
`test/fixtures/HiTestMapFromWorldEditor.w3x` and has a fixed input hash.

```sh
python3 -B test/compat/user_map.py \
  --map test/fixtures/HiTestMapFromWorldEditor.w3x \
  --library "$PWD/build/mpq-runtime/libstorm.so" \
  --output "$PWD/build/release-check/seed-maps"

python3 -B make/package-release.py \
  --upstream build/upstream-2.7.3.zip \
  --output build/release-check/candidate.zip \
  --map-validation build/release-check/seed-maps

python3 -B test/compat/verify_package.py \
  --archive build/release-check/candidate.zip \
  --workdir "$PWD/build/release-check/verified" \
  --runtime "$PWD/build/compat-runtime" \
  --stormlib "$PWD/build/mpq-runtime/libstorm.so" \
  --source "$PWD" \
  --upstream build/upstream-2.7.3.zip
```

The verification report is written to
`build/release-check/verified/VALIDATION.json`. Review its results before creating
the final ZIP. Build the final artifact from that run's map outputs and validation:

```sh
python3 -B make/package-release.py \
  --upstream build/upstream-2.7.3.zip \
  --output build/release-check/w3x2lni-reforged-1.0.0-windows-x86.zip \
  --map-validation build/release-check/verified/map-validation \
  --validation build/release-check/verified/VALIDATION.json
```

Final packaging fails if the runtime/data payload differs from the tested
candidate. The release workflow additionally supplies `--expected-tag` to check
the tag against release metadata. The Windows job and draft-release job use the
final artifact from this validation chain; they do not rebuild an unrelated ZIP.

### Run the Windows CLI smoke test locally

On Windows, use Python 3.10 or later and run the following from the source
checkout. Place the portable ZIP and its `.sha256` file in `build/release-check`
first, and use a new output directory for each run:

```bat
python -B test/release/windows_smoke.py ^
  --archive build/release-check/w3x2lni-reforged-1.0.0-windows-x86.zip ^
  --checksum build/release-check/w3x2lni-reforged-1.0.0-windows-x86.zip.sha256 ^
  --workdir build/windows-smoke
```

The test uses the runtime inside that ZIP. Results are written beneath
`build/windows-smoke/evidence`, including `WINDOWS_SMOKE.json`. This checks the
native CLI and archive processing; test GUI resizing and clipboard interaction
in the application itself.

## Native build versus release packaging

The 1.0 release process deliberately uses the official upstream 2.7.3 Windows
runtime. Its scripts, configuration, data, and documentation come from the fork's
release commit. The project still retains its original `make.lua` native build
definitions and dependency sources, but running those is a separate development
operation, not the provenance claimed for the portable 1.0 asset.

Keep the upstream license and attribution with the distribution. The
[credits document](credits.md) identifies the original runtime release and
dependency projects. The [compatibility notes](current-warcraft.md) describe
the raw data, synthetic fixtures, actual-map coverage, and remaining game checks.
