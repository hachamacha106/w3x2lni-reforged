# Codex instructions — W3x2lni Reforged

## Project
- This is a Warcraft III map converter (LNI / OBJ / SLK) written primarily in Lua, with C++ components, Python tooling, and pinned third-party Git submodules.
- `script/`: runtime, format conversion, parsing, GUI and reports. `data/`: game-version data and metadata. `test/`: unit, integration, compatibility and release checks. `make/`: build and packaging. `c++/`: native code. `docs/`: user and maintainer docs.
- The release process currently **reuses byte-verified upstream 2.7.3 native Windows binaries**, and packages changed Lua scripts and game data. Do not claim changes to C++ are shipped unless a separate, verified native rebuild process is implemented.

## Guardrails
- Read `MAINTAINER_GUIDE.md` and the relevant code/tests before editing. Make small scoped changes and describe behavioral implications.
- Treat game-data files and binary fixtures as byte-sensitive. Do not normalize line endings, reorder SLK/INI data, regenerate snapshots or change fixed fixture hashes without explaining why and validating the result. Respect `.gitattributes` including `-text` paths.
- Keep Warcraft III compatibility across legacy/current datasets. Preserve unknown binary fields, unsupported map metadata and native sidecars rather than discarding them.
- Do not edit Git submodule commit IDs, dependency URLs, version/release metadata or distribution workflows as collateral changes.
- Never commit `bin/`, `build/`, compiled binaries, local logs, secrets or the portable release ZIP; use GitHub release assets for the distribution.
- Do not disable tests/checksum/provenance verification to make a build pass.
- Do not create tags, push branches or publish GitHub releases without the maintainer's explicit instruction; prepare the commits or commands for review first.

## Verification
- Fast local checks (Python 3.10+ and Git required):
  - `python -B test/release/release_artifact.py metadata`
  - `python -B test/compat/test_package_release.py`
  - `python -B -m compileall -q make test/compat test/release tools`
- For behavior changes, add or extend a targeted fixture/test under `test/` and explain any testing limitations.
- Release validation runs through `.github/workflows/build.yml` (Linux compatibility plus Windows CLI smoke tests). Do not assert that this full process passed without an actual successful Actions run.

## Versioning / release
- See `MAINTAINER_GUIDE.md`. For each new version, coordinate `release.json`, `script/share/changelog.lua`, `CHANGELOG.md` and `docs/releases/<version>.md`.
- A new `vX.Y.Z` Git tag should match `release.json` exactly. CI creates a **draft**, not a published release, only after passing verification. The maintainer publishes manually after GUI/map testing.
