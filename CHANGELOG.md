# Changelog

This file tracks **W3x2lni Reforged** releases. The original project's detailed
history remains in [`script/share/changelog.lua`](script/share/changelog.lua).

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
