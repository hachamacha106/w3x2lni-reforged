# Warcraft III compatibility in W3x2lni Reforged 1.0

W3x2lni Reforged 1.0 retains the LNI, OBJ, and SLK workflows and updates their
handling of modern Warcraft III map and object data. Its initial source base is
upstream commit `82916514a12b7edb15252d42225cd8cc8ce61cfd`.

The development map fixture was saved by **Warcraft III 3.0.1.24342**, editor
**7003**, with **W3I format 39**. The supplied base dataset is complete for the
importer's required files and is selected in the portable release. Its exact
extraction build and locale remain unverified in the source manifest; the map's
recorded build is not assigned to the raw data by assumption.

## Supported behavior

| Area | Behavior in 1.0 |
| --- | --- |
| Object data | Reads and writes object formats 1, 2, and 3 for all seven object kinds, preserving v3 integer arrays and unknown modifications. |
| Binary skins | Preserves the seven `war3mapskin.w3*` sidecars, their object identities, field levels, and precedence through LNI. |
| SLK | Uses the selected source table's columns, including six ability levels and extended data columns; retains unsupported changes in binary object data. |
| Native profiles | Routes fields to their declared profiles, including unit/item skins and unit weapon functions; preserves explicit zero and empty overrides. |
| Skin localization | Loads optional skin string profiles and alternate-skin names while retaining ordinary unit-name routing. |
| Models | Handles three indexed unit model paths and metadata-aware migration of older LNI model fields. |
| Map information | Handles known W3I versions 18, 25–33, and 39. Exports descriptive keys and preserves current fog, water, camera, HUD, graphics, and priority fields. Unsupported format versions fail explicitly. |
| GUI triggers | Handles deleted entries, root-level elements, custom-script alignment, and argument caching in WTG/WCT/LML conversion. |
| Placement references | Recognizes known layouts 7, 8, and 13, including separate skin IDs and newer fields; retains original placement bytes. |
| Scripts and strings | Supports current JASS native definitions in optimization/obfuscation; preserves Lua scripts and sparse WTS IDs, including IDs referenced by native conversation data. |
| Object removal | Retains objects with a diagnostic when references cannot be analyzed reliably. Analyzable JASS still supports unused-object pruning. |
| Archives and imports | Recognizes Lua, skin sidecars, current lighting/group files, and conversation data; classifies native files separately from custom imports and preserves newer outer-header flag bits. |
| Game-data extraction | Includes additional source tables and fixes CASC handle cleanup and failed-open handling. |
| Data selection | Invalidates cached metadata, strings, trigger definitions, and defaults when the dataset or balance version changes. |
| Diagnostics | Displays and saves full errors when the bundled Windows runtime inserts NUL separators into error fragments. |
| Report UI | Resizable main window and wrapped, scrollable, selectable reports with complete-log copying. |

Unknown object modifications and v3 arrays are retained. Because their contents
can hide references, their presence can prevent unused-object pruning. Lua,
dynamic rawcode creation, or unreadable placement data can cause the same
conservative behavior. The conversion report explains when it is applied.

Modern model files bypass the existing native model optimizer through its
version guard; very short model files also bypass it safely. This release does
not add an HD model compressor or a Lua script optimizer.

### W3I field names

All numbered `unknown_1` through `unknown_13` keys have descriptive names.
Unsigned graphics, data-version, and player-priority values retain all 32 bits.
The v39 reader and writer correctly order fog heights, linear settings, opacity,
drawing over the sky, and weather. Minimap alpha-tile colors and loading-screen
race HUD values are also named. Reserved bits without a verified meaning remain
in `unknown_flags`.

See [W3I field names and values](w3i-fields.md) for the complete mapping and
reference evidence. Projects exported by development previews 4 and 5 already
use these names. Earlier testing schemas have no alias/migration layer: re-export
from the original map to obtain the current `table/w3i.ini` and locale dictionary.

### Report window

The main window uses native Windows resize borders and minimize, maximize, and
close controls. The report fills the available space, with **Copy all** and
**Back** below it.

- Select report text and press **Ctrl+C** to copy a selection.
- Press **Ctrl+A**, then **Ctrl+C** to select and copy the displayed report.
- Click **Copy all** to copy the entire loaded log, independent of the selection
  or scroll position.
- Use **Tab** and **Shift+Tab** to move between the report and its buttons.

The report is read-only and uses native Windows text-control colors. Reopening
it reloads `log/report.log`, starts at the top, and focuses the text area. Copy
all uses the original loaded text, preserving long Unicode reports. The Win32
read-only adapter and Lua fallback do not require a replacement native DLL.

## Included game data

`data/warcraft-current/mpq` contains **111 raw files** from the supplied base
export. Their original bytes, sizes, and SHA-256 hashes are recorded in
`data/warcraft-current/source-manifest.json`. A complete import generated the
metadata and selectable dataset marker.

| Object kind | Base entries |
| --- | ---: |
| Abilities | 1,556 |
| Buffs | 328 |
| Units | 928 |
| Items | 649 |
| Upgrades | 90 |
| Doodads | 771 |
| Destructables | 344 |

Melee and Custom prebuilt defaults are both generated from that supplied base.
No separate `Custom_V1` balance override or graphics-specific data layer was
supplied. These generated variants do not establish that the game's balance
modes or graphics-specific defaults are identical.

### Configuration

The portable release already selects the following settings. No import or
configuration step is needed for its included dataset. In Windows Command Prompt,
the equivalent commands are:

```bat
w2l.exe config global.data=warcraft-current
w2l.exe config global.data_meta=${DATA}
w2l.exe config global.data_ui=${DATA}
w2l.exe config global.data_wes=${DATA}
w2l.exe config lni.read_slk=true
w2l.exe config obj.read_slk=true
```

The last two settings allow LNI and OBJ conversion to read existing map SLK tables
and native text-profile overrides. Map-specific configuration can override global
settings; `w2l.exe config` displays the effective source of each setting.

### Rebuilding data

After replacing extracted files with a matching complete export, run this from
the application folder in Windows Command Prompt. Substitute the confirmed build
and locale of your export:

```bat
bin\w3x2lni-lua.exe make\import-game-data.lua data\warcraft-current\mpq warcraft-current --build YOUR_BUILD --locale YOUR_LOCALE
```

The importer stages metadata and both default sets before writing. Missing
required files produce an error, exit status 2, and no generated output. A
complete import writes the normal dataset marker; its result is recorded in
`data/warcraft-current/import-report.txt`.

`--allow-partial` is for developer QA: it omits the selectable marker and refuses
to replace an existing selectable dataset with incomplete inputs. Import success
checks the inputs and generation process; actual maps still provide separate
behavioral validation.

## Validation scope

The portable package includes `TEST_RESULTS.txt`, `PACKAGE_VERIFICATION.json`,
and the map conversion records under `map-validation/`. `BUILD_INFO.json`
records the source and native-runtime provenance. `CHECKSUMS.sha256` covers the
packaged files.

The release pipeline verifies a complete byte snapshot of the source and data,
then runs tests from a fresh extraction of the candidate ZIP. Final packaging
requires the same runtime/data fingerprint as the tested candidate. This avoids
a packaging problem identified during preview testing, where older upstream
scripts remained in the distributed archive despite tests passing in the source
checkout.

### Linux compatibility checks

The 14 test groups use the actual Lua converter and parsers built from the
repository's pinned sources. The harness adapts Windows paths, 32-bit Windows
`long` values, and UI-locale calls. Explicit mocks cover the Windows-only GUI,
Win32, and CASC boundaries; those tests do not claim native execution.

The suite covers original regression fixtures, independently encoded modern
objects/maps/triggers/placements, real supplied tables and defaults, current
JASS definitions, Lua/WTS preservation, archive/import behavior, complete crash
diagnostics, W3I fields, and report interactions. The W3I tests use distinct
nonzero fog/weather values and full unsigned masks, so a reader/writer with the
same incorrect interpretation cannot pass merely by round-tripping zero values.

Real archive checks use Linux StormLib at commit
`8f3f327697b392014cc084f4f3a3547ddb3a1b89`. Each of six rebuilt archives is reopened;
its member names and decoded bytes are compared with the converter output.
This bridge does not execute the Windows Lua FFI or the game's runtime.

### Actual-editor fixture

`test/fixtures/HiTestMapFromWorldEditor.w3x` is a small JASS map with one standard
initialization trigger, eight GUI actions, one player, and a start marker. It has
no custom object files, binary skins, imported assets, Lua, or nonempty
conversations. Its melee-map flag is zero. These properties define the sample's
coverage; synthetic fixtures cover additional format cases.

The map suite verifies the fixture's SHA-256 before use and exercises eight
conversion paths. The six rebuilt map archive outputs are:

| Output suffix | Purpose |
| --- | --- |
| `-OBJ.w3x` | Direct OBJ conversion, retaining editor data. |
| `-LNI-OBJ.w3x` | LNI export followed by an OBJ rebuild. |
| `-SLK-editor.w3x` | SLK with GUI/editor files and unoptimized JASS retained. |
| `-SLK-LNI-OBJ.w3x` | Reimport of the editor-preserving SLK output through LNI and OBJ. |
| `-SLK.w3x` | Normal SLK optimization with editor-only removal. |
| `-SLK-obfuscated.w3x` | SLK from LNI with JASS obfuscation. |

Default optimized SLK output deliberately removes editor-only data. Use the OBJ,
LNI-OBJ, or SLK-editor variants for editor checks. Test optimized variants in the
game. Development validation of this sample produced zero conversion errors and
warnings; the corresponding package records give the exact run results.

### Windows and game checks

The GitHub release workflow runs the packaged `w2l.exe` and native modules on
Windows, checking OBJ, LNI, LNI-to-OBJ, and SLK conversions, report results, and
rebuilt archive semantics. The separate `WINDOWS_SMOKE.json` release asset records
that run. A configured test is not evidence of a successful run: consult the
[workflow results](https://github.com/hachamacha106/w3x2lni-reforged/actions) and
that record for the release you use.

The following remain practical acceptance checks:

- GUI launching, resizing, report selection, and the actual system clipboard.
- Extracting the selected game data from a real Warcraft III installation.
- Opening representative JASS and Lua rebuilds in the current World Editor and
  playing both ordinary and optimized outputs.
- Custom objects, six-level abilities, model/skin variants, imports, conversations,
  and any YDWE / KKWE / custom trigger definitions or plugins used by the project.

The package's native executables and DLLs are retained from upstream 2.7.3,
not freshly compiled. See [credits and runtime provenance](credits.md).

## Development and issue reports

The [release guide](reforged-release.md) describes reproducing the checks and
building a candidate. For a conversion issue, include the full report from
**Copy all** or `log/report.log`; for a crash, include the relevant file from
`log/error`, the exact action, settings, and a sample map when available.

## Format and implementation references

- [Upstream source base](https://github.com/sumneko/w3x2lni/tree/82916514a12b7edb15252d42225cd8cc8ce61cfd)
- [Official native release](https://github.com/sumneko/w3x2lni/releases/tag/2.7.3)
- [SLK compatibility report](https://forum.wc3edit.net/viewtopic.php?t=39987)
- [W3I source references](w3i-fields.md#sources)
- [War3Net object formats](https://github.com/Drake53/War3Net/tree/18e88f0e1f67e6b16870dcbcd827740275fe2173/src/War3Net.Build.Core/Serialization/Binary/Object)
- [HiveWE map formats](https://github.com/stijnherfst/HiveWE/tree/36898a50f6bf808871c8b95de3f48f0b64f80fdc/src/base)
- [Historical Yue TextEdit implementation](https://github.com/yue/yue/blob/0b9570e5eecc166a05068e554950221de7f54e7e/nativeui/win/text_edit_win.cc)
- [Microsoft: EM_SETREADONLY](https://learn.microsoft.com/en-us/windows/win32/controls/em-setreadonly)
- [Microsoft: GetFocus](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getfocus)
