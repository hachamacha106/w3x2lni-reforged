# W3I field names in W3x2lni Reforged

Release: **W3x2lni Reforged 1.0** (`1.0.0`).

The numbered `unknown_1` through `unknown_13` keys now have descriptive names.
English and Chinese exports use the same semantic fields. Numeric values and
unidentified flag bits are retained; changing a name does not reset a setting.

The release uses the descriptive names directly, as did previews 4 and 5.
For LNI projects exported by earlier previews, re-export from the original
`.w3x` or `.w3m` with this release to obtain the new `table/w3i.ini` and its
matching locale dictionary. Numbered preview keys are not migrated.

## Numbered fields

| Previous key | New English key | Section | Meaning |
| --- | --- | --- | --- |
| `unknown_1` | `use_terrain_fog` | `config` | Enable the map's terrain fog; map flag bit 13. |
| `unknown_2` | `requires_expansion` | `config` | Expansion-required flag; bit 14. |
| `unknown_3` | `use_item_classification` | `config` | Enable item classification; bit 15. |
| `unknown_4` | `use_water_tinting` | `config` | Enable the map's water tint; bit 16. |
| `unknown_5` | `accurate_probability` | `config` | Use accurate probability for calculations; bit 17. |
| `unknown_6` | `custom_ability_skins` | `config` | Custom ability skins; bit 18. |
| `unknown_7` | `disable_deny_icon` | `config` | Disable the deny icon; bit 19. |
| `unknown_8` | `force_default_zoom` | `config` | Enable the configured default camera zoom; bit 20. |
| `unknown_9` | `force_max_zoom` | `config` | Enable the configured maximum camera zoom; bit 21. |
| `unknown_10` | `supported_graphics_modes` | `map` | Supported graphics-mode bitmask. |
| `unknown_11` | `game_data_version` | `map` | Game-data version ID. This is separate from `config.game_data_setting`. |
| `unknown_12` | `enemy_low_priority_flags` | `playerN` | Enemy start-location low-priority player-slot bitmap. |
| `unknown_13` | `enemy_high_priority_flags` | `playerN` | Enemy start-location high-priority player-slot bitmap. |

The nine `config` fields are numeric switches: `0` clears the corresponding bit
and `1` sets it. Their bit positions are unchanged. The graphics modes,
game-data version and enemy masks use unsigned 32-bit values so their highest
bit remains readable and all original bits survive rebuilding.

### Supported graphics modes

This value combines independent bits:

| Bit value | Mode |
| --- | --- |
| `1` | SD / Classic |
| `2` | HD / Reforged |
| `4` | DE / Definitive Edition |

For example, `supported_graphics_modes = 3` combines SD and HD. `7` combines all
three currently named bits. The converter does not clamp the value to `1`–`3`
or discard unrecognized higher bits.

The supplied map contains:

```ini
[map]
supported_graphics_modes = 3
game_data_version = 2
```

### Game-data version

The supplied current `WorldEditStrings.txt` labels the editor's version IDs:

| Value | Current supplied editor label |
| --- | --- |
| `0` | Reign of Chaos |
| `1` | The Frozen Throne |
| `2` | Forsaken Kingdom |

Older reference implementations used `2` as `Unset`. Its label is therefore
dependent on the editor/game version. This release preserves the numeric ID.
The explanatory comment in a W3I v39 export uses the current supplied labels;
earlier format exports do not assign the new label to every historical value.

`game_data_setting` remains a separate field selecting default/custom/melee
balance data. Do not substitute one of these fields for the other.

### Enemy priorities

These values are bitmaps for start-location priorities, not lists of player
numbers or alliance settings. Bit 0 represents zero-based player slot 0, bit 1
represents slot 1, and so on. For example, `enemy_low_priority_flags = 5` sets
bits 0 and 2. A value of `0` sets no slots in that priority mask.

## Newly identified W3I v39 fields

The older HiveWE reference used before preview 4 placed weather before
the new fog fields. The newer War3Net reader and writer identify this sequence
after the existing fog color:

| Position | New field | Type |
| --- | --- | --- |
| 1 | `fog.height_start` | 32-bit floating-point number |
| 2 | `fog.height_end` | 32-bit floating-point number |
| 3 | `fog.linear_start` | 32-bit floating-point number |
| 4 | `fog.linear_end` | 32-bit floating-point number |
| 5 | `fog.max_opacity` | 32-bit floating-point number |
| 6 | `fog.draw_over_sky` | 32-bit integer switch |
| 7 | `environment.weather` | Four-byte weather rawcode |

The correction introduced in preview 4 is retained in this release. In exports
from earlier previews, `environment.weather` actually contained the height-start bytes,
`unknown_fog_1` contained height-end bytes, `unknown_fog_2` contained the sky
switch, and `unknown_fog_3` contained weather bytes. The original sample's
zero defaults did not distinguish these fields. New independent fixtures use
distinct nonzero heights, sky settings and `RAhr` weather and check exact bytes.

Two other v39 names are now explicit:

- `environment.minimap_alpha_tile_color` replaces `unknown_post_water`. It is
  the packed color used for alpha terrain tiles on the minimap, represented as
  an unsigned integer `0xAARRGGBB` and written in BGRA byte order.
- `loading_screen.race_hud` replaces the vague `source` field. It stores the
  loading-screen race HUD value. Player records retain their separate `hud_skin`.

The supplied editor strings and JASS definitions also identify the new fog
controls, including height start/end and drawing fog over the sky.

## Why `unknown_flags` remains

Some bits still have no verified function. This field preserves those bits:

- In `config`, it retains map-flag bits 26 through 31.
- In each `forceN` section, it retains the bits outside the known alliance,
  shared-vision and shared-control settings, using mask `0xFFFFFFC4`.

An `unknown_flags = 0` line is normal. It says that none of those unidentified
bits is set. A nonzero value is retained exactly; the converter does not invent
an editor option name for it.

## Validation

`test/compat/w3i_names.lua` checks both languages, all nine renamed map option
bits independently, complete unsigned masks, the corrected fog/weather layout,
loading HUD and minimap color. It performs 44 binary/LNI round trips against
independently constructed expected bytes. `archive_header.lua` verifies the
same named option bits in the outer map header. The modern-format fixture also
checks exact binary/LNI rebuilding for every supported W3I format version.

The actual supplied map is regenerated through the eight conversion paths in
the package's `map-validation` folder. `TEST_RESULTS.txt` records the complete
extracted-package test run. Windows GUI/game execution remains separate from
these automated checks.

## Sources

- [WC3MapSpecification, map information and flags](https://github.com/ChiefOfGxBxL/WC3MapSpecification/blob/68fbff92d11429898b256f33c25216bba7ef4479/Info/0-33.md)
- [War3Net W3I binary reader and writer](https://github.com/Drake53/War3Net/blob/18e88f0e1f67e6b16870dcbcd827740275fe2173/src/War3Net.Build.Core/Serialization/Binary/Info/MapInfo.cs)
- [War3Net map flags](https://github.com/Drake53/War3Net/blob/18e88f0e1f67e6b16870dcbcd827740275fe2173/src/War3Net.Build.Core/Info/MapFlags.cs)
- [War3Net graphics modes](https://github.com/Drake53/War3Net/blob/18e88f0e1f67e6b16870dcbcd827740275fe2173/src/War3Net.Build.Core/Info/SupportedModes.cs)
- [War3Net historical game-data version enum](https://github.com/Drake53/War3Net/blob/18e88f0e1f67e6b16870dcbcd827740275fe2173/src/War3Net.Build.Core/Info/GameDataVersion.cs)
- Supplied `data/warcraft-current/mpq/ui/worldeditstrings.txt`: the
  `WESTRING_GAMEDATAVERSION_V0`/`V1`/`V2`, supported-mode and new fog-control labels.
- Supplied `data/warcraft-current/mpq/scripts/common.j`: current fog native definitions.
