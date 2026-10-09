# W3x2lni Reforged

**A community fork of [sumneko/w3x2lni](https://github.com/sumneko/w3x2lni), updated for modern Warcraft III map development and distribution.**

Convert Warcraft III maps between editable text projects, World Editor object
data, and optimized SLK maps. W3x2lni Reforged keeps the original GUI and command
line workflows, adds support for current map formats and game data, and improves
conversion reports.

[Downloads](https://github.com/hachamacha106/w3x2lni-Reforged/releases)
· [Report a bug](https://github.com/hachamacha106/w3x2lni-Reforged/issues)
· [Release checks](https://github.com/hachamacha106/w3x2lni-Reforged/actions)
· [Changelog](CHANGELOG.md)

## Choose a format

| Format | Use it for |
| --- | --- |
| **LNI** | Working on a map as an organized directory of text and asset files, suitable for Git and text editors. |
| **OBJ** | Rebuilding a map for Warcraft III and the World Editor. |
| **SLK** | Preparing a map for play and distribution, with configurable object and JASS optimizations. |

Keep an OBJ map or LNI project as your editable source. Default SLK settings remove
editor-only information, which cannot be restored by converting the result back.

## Download and run

1. Open [Releases](https://github.com/hachamacha106/w3x2lni-Reforged/releases) and
   download the portable Windows package. For version 1.0, the asset is named
   **`w3x2lni-reforged-1.0.0-windows-x86.zip`**.
2. Extract the entire ZIP into a new folder. Keep `bin`, `script`, and `data`
   alongside the executables.
3. Open **`w3x2lni.exe`**, drag in a `.w3x` / `.w3m` map or LNI project, and choose
   **LNI**, **OBJ**, or **SLK**.
4. Review the conversion report. Resize or maximize the window to give the report
   more space. Select text and press **Ctrl+C**, or use **Copy all** for the full
   report.

This is a portable Windows application with an x86 runtime. The release package
includes its selected `warcraft-current` dataset; no separate data import is
needed to start using that dataset. GitHub's automatically generated **Source
code** downloads are for development and do not include the packaged runtime.

### Command line

Run these commands in Windows Command Prompt from the extracted application
folder. Use distinct output paths to retain your original map.

```bat
w2l.exe version
w2l.exe lni "C:\Maps\MyMap.w3x" "C:\Maps\MyMap-lni"
w2l.exe obj "C:\Maps\MyMap-lni" "C:\Maps\MyMap-rebuilt.w3x"
w2l.exe slk "C:\Maps\MyMap-lni" "C:\Maps\MyMap-release.w3x"
w2l.exe help
```

`w2l.exe help lni`, `w2l.exe help obj`, and `w2l.exe help slk` describe each
conversion command. `w2l.exe config` shows the active settings; for example,
`w2l.exe config slk.confused=true` enables JASS obfuscation when JASS optimization
is enabled. `w2l.exe log` displays the last conversion report.

## What's included in 1.0

- **Modern map information:** W3I format 39 handling, descriptive `w3i.ini`
  fields, and corrected fog, weather, minimap color, and loading-screen HUD data.
- **Current object data:** version 3 object records, binary skin sidecars,
  extended ability levels and SLK columns, skin localization, and native profile
  routing.
- **Map preservation:** fixes for GUI triggers, placement references, Lua
  scripts, string-table IDs, imports, and current native map files.
- **Existing optimization workflows:** JASS optimization and obfuscation, with
  conservative object retention when references cannot be analyzed reliably.
- **Usable reports:** resizable windows and wrapped, scrollable, selectable
  reports with a full-report copy button.
- **Verified packaging:** per-file checksums, source and runtime provenance,
  compatibility tests run from the extracted release candidate, and a Windows
  CLI smoke-test gate before a release draft is created.

The development map fixture was saved by **Warcraft III 3.0.1.24342**, using
**W3I format 39**. The compatibility suite includes 14 test groups and eight
conversion paths for that fixture. This establishes coverage for the tested
formats and sample; custom editor extensions and individual maps can require
additional testing. Read the [compatibility notes](docs/en-us/current-warcraft.md)
for the data provenance, test scope, and remaining limits.

The 1.0 Windows package reuses the 22 native executables and DLLs from the
official upstream **2.7.3** release. The updated converter and UI are delivered
as Lua scripts. These are not newly compiled Windows binaries.

## Documentation

- [Current Warcraft III support and game-data setup](docs/en-us/current-warcraft.md)
- [W3I field names and values](docs/en-us/w3i-fields.md)
- [W3x2lni Reforged 1.0 release notes](docs/releases/1.0.0.md)
- [Developer setup and release process](docs/en-us/reforged-release.md)
- [Original English documentation](https://sumneko.github.io/w3x2lni/#/en-us/)
- [原版中文文档](https://sumneko.github.io/w3x2lni/#/zh-cn/)

## Reporting a problem

Open an [issue in this fork](https://github.com/hachamacha106/w3x2lni-Reforged/issues)
with the application version, Warcraft III / editor build, conversion mode,
steps to reproduce, and relevant settings. Attach the full conversion report
from **Copy all** or `log/report.log`. For a crash, include the corresponding
file from `log/error`. A small map demonstrating the problem is especially
useful when you can share it.

## Credits and license

W3x2lni was created by **sumneko**, with the original frontend by
**actboy168**. This fork is maintained by
[hachamacha106](https://github.com/hachamacha106).

The project retains its upstream [GNU GPL v3 license](LICENSE.txt).
[Credits and runtime provenance](docs/en-us/credits.md) identify the original
project and dependencies. Warcraft III and its game data belong to Blizzard
Entertainment; this is an independent community project.
