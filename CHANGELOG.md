# Changelog

This file tracks **W3x2lni Reforged** releases. The original project's detailed
history remains in [`script/share/changelog.lua`](script/share/changelog.lua).

## 1.1.5 — 2026-10-10

- Prevent generated JASS identifiers from colliding with original functions,
  globals or types, including real globals retained for variable events.
- Preserve runtime `ExecuteFunc` callback names and string prefixes when dynamic
  routes overlap, and retain callbacks reached through other dynamic dispatchers.
- Reset optimizer and serializer state between operations so earlier conversions
  cannot affect later scripts or global initializers.
- Deduplicate custom obfuscation alphabets and leave names unchanged when the
  alphabet does not contain enough distinct characters or letters.
- Clarify case-only and cross-type SLK/TXT profile warnings. Retained objects use
  binary fallback where needed; their original IDs remain unchanged.
- Add regression checks for identifier collisions, dynamic callback routing,
  repeated operations and custom alphabets, with real pjass input/output checks
  against current and legacy Warcraft declarations.

pjass remains report-only. Native dependency pins and the retained upstream
runtime remain unchanged. The maintainer reported successful gameplay with
Confuse scripts both off and on in the local preview for their tested map;
the original map from the corruption report was not available for reproduction.

## 1.1.0 — 2026-10-09

- Refresh the conversion interface with a high-contrast dark theme, clearer
  format selection, native checkboxes and Change format navigation.
- Support Space/Enter activation and prevent settings or format changes while
  conversion is running.
- Check archive create, write, finish, compact and close failures.
- Add independent report-only pjass verification against the selected Warcraft
  declarations before and after conversion. Lua maps are skipped explicitly.
- Add a pinned Windows x86 StormLib 9.40 / static zlib 1.3.2 build. Packaging
  validates retained, rebuilt and added native components separately.
- Add regression and native smoke checks and preserve upstream license notices.
- Credit devoltzz / Devo's Map Doctor for research and verification ideas.

CascLib and the remaining upstream runtime are retained pending separate validation.
Compatibility depends on the selected Warcraft dataset and the map being converted.

## 1.0.0 — W3x2lni Reforged 1.0

The first release of this fork consolidates the current-Warcraft compatibility
work and five development previews on top of upstream commit
`82916514a12b7edb15252d42225cd8cc8ce61cfd`.

### Added

- A complete, selectable `warcraft-current` dataset with matching metadata,
  trigger definitions, editor strings, and generated object defaults.
- Version 3 object records and binary skin sidecars for all seven object kinds.
- Extended ability levels and SLK data columns, native skin profiles, localized
  alternate-skin names, and indexed unit model paths.
- W3I format 39 support with descriptive map, graphics, fog, and HUD settings.
- Preservation of current native map files, Lua scripts, and string IDs used by
  conversation data.
- A release process that checks the exact portable package, records source and
  native-runtime provenance, runs compatibility tests, and requires a Windows
  CLI smoke test before creating a GitHub release draft.

### Fixed

- W3I fog height, sky, and weather ordering; minimap alpha-tile colors; loading
  screen race HUD values; and unsigned graphics/data/player-priority fields.
- GUI trigger deleted entries, root elements, custom-script alignment, and
  argument caching.
- Newer placement references, model/skin field handling, zero and empty-value
  overrides, and native text-profile routing.
- Metadata, strings, and default caches when changing datasets or balance modes.
- CASC handle cleanup and failed-open handling.
- Error text hidden by embedded NUL separators in the bundled Windows runtime.
- Packaging gaps that could leave older upstream scripts in a modified archive.
- Fixed-size, clipped report windows: the main window now resizes and maximizes,
  and reports wrap, scroll, support selection, and provide **Copy all**.

### Behavior and scope

- LNI, OBJ, and SLK remain the primary workflows. JASS optimization and
  obfuscation remain available; Lua scripts are preserved without a Lua optimizer.
- Object pruning retains objects and reports why when Lua, opaque object data,
  dynamic references, or unreadable placement data prevents reliable analysis.
- Numbered `unknown_1` through `unknown_13` W3I keys use descriptive names.
  Earlier testing schemas are not migrated; re-export those older LNI projects
  from their original maps. Projects exported by previews 4 and 5 already use
  the current names.
- Unidentified flag bits and unknown object modifications are preserved.
- Native Windows components are retained byte-for-byte from upstream 2.7.3.

See the [release notes](docs/releases/1.0.0.md) and
[compatibility notes](docs/en-us/current-warcraft.md) for installation and scope.
