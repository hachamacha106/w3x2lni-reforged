# Credits and runtime provenance

## Original project and this fork

[W3x2lni](https://github.com/sumneko/w3x2lni) was created by **sumneko**; its
original frontend credits **actboy168**. Their source history and notices remain
in this repository. W3x2lni Reforged is maintained by
[hachamacha106](https://github.com/hachamacha106) at
[hachamacha106/w3x2lni-Reforged](https://github.com/hachamacha106/w3x2lni-Reforged).

The fork's initial source base is upstream commit
[`82916514a12b7edb15252d42225cd8cc8ce61cfd`](https://github.com/sumneko/w3x2lni/tree/82916514a12b7edb15252d42225cd8cc8ce61cfd).
The project's original [GNU GPL v3 license](../../LICENSE.txt) is retained
verbatim. Dependencies keep their own notices and licenses; the project's license
does not replace those notices or change the ownership of game assets.

## Windows runtime used by 1.0

The portable release reuses all 22 native executable and DLL files from the
official [w3x2lni 2.7.3 Windows release](https://github.com/sumneko/w3x2lni/releases/tag/2.7.3).
Those files are checked byte-for-byte against the original archive. The release
process updates the Lua converter, GUI scripts, tests, configuration, and data;
it does not rebuild these native components.

| Item | Recorded source |
| --- | --- |
| Native release asset | [`w3x2lni-2.7.3.zip`](https://github.com/sumneko/w3x2lni/releases/download/2.7.3/w3x2lni-2.7.3.zip) |
| Native release source commit | [`05e3e371e36f078031d54bcc9783b52b9b86485a`](https://github.com/sumneko/w3x2lni/tree/05e3e371e36f078031d54bcc9783b52b9b86485a) |
| Original asset SHA-256 | `58c6523b6d34fea55b6904f40298b24f72367f7d975494cb7dff23cb1241c440` |

`BUILD_INFO.json` in the release records the fork's commit, source-tree identity,
dependency revisions, runtime origin, and packaging checks. `SOURCE_CHANGES.patch`
contains the changes from the recorded upstream source base;
`SOURCE_FILES.sha256` records the source files used to build the package.
The fork's release tag provides the full source history and submodule references.

## Dependency projects

The upstream source and build use the following projects. Their pinned source
revisions are recorded by Git submodules where applicable; consult those source
trees for the original authorship and license notices.

| Component | Project |
| --- | --- |
| Lua runtime and OS bindings | [Lua](https://www.lua.org/) and [bee.lua](https://github.com/actboy168/bee.lua) |
| GUI toolkit | [Yue](https://github.com/yue/yue) |
| LNI and LML parsers | [lni](https://github.com/actboy168/lni) and [lml](https://github.com/actboy168/lml) |
| Warcraft data/script parser | [w3xparser](https://github.com/actboy168/w3xparser) |
| Parsing expressions | [LPegLabel](https://github.com/sqmedeiros/lpeglabel) |
| MPQ archive support | [StormLib](https://github.com/ladislav-zezula/StormLib) |
| CASC game-storage support | [CascLib](https://github.com/ladislav-zezula/CascLib) |
| Lua foreign-function interface | [luaffi](https://github.com/actboy168/luaffi) |
| Compression and ZIP support | [zlib and minizip](https://github.com/madler/zlib) |

Bundled native libraries may themselves include further dependencies. Their
original source distributions and notices remain the source of that attribution.

## Warcraft data and format references

Warcraft III and its game data belong to **Blizzard Entertainment**. This is an
independent community project and is not an official Blizzard release. Raw game
files are retained with a source manifest; they are not presented as original
code authored by this fork.

The compatibility work uses community format research from
[War3Net](https://github.com/Drake53/War3Net),
[HiveWE](https://github.com/stijnherfst/HiveWE), and
[WC3MapSpecification](https://github.com/ChiefOfGxBxL/WC3MapSpecification).
The [W3I field reference](w3i-fields.md) identifies the exact source revisions
used for the current map-information fields.
