-- Independent binary fixtures based on WC3MapSpecification/Info/0-33.md and
-- War3Net Serialization/Binary/Info/MapInfo.cs
-- (18e88f0e1f67e6b16870dcbcd827740275fe2173).
-- The v39 fixtures exercise fields before and after the player block so a
-- reader and writer that omit the same new fields cannot pass by coincidence.
local lang = require 'share.lang'
local w2l = w3x2lni()

local function fixture(version, script_type)
    local bytes = {}
    local function add(format, ...)
        bytes[#bytes+1] = string.pack('<' .. format, ...)
    end
    add('i4i4i4', version, 123, 7000)
    if version >= 27 then
        add('i4i4i4i4', 3, 0, 1, 24342)
    end
    add('zzzz', 'Compatibility fixture', 'Author', 'Map description', '2 players')
    add('ffffffff', -1024.125, -2048.25, 1024.5, 2048.125, -1024.125, 2048.125, 1024.5, -2048.25)
    add('i4i4i4i4', 6, 6, 4, 8)
    add('i4i4I4c1', 52, 52, 0xFFFFFFFF, 'L')
    add('i4', -1)
    if version >= 25 then
        if version >= 39 then
            add('I4', 128)
        end
        add('zzzz', 'UI\\Loading\\Custom.mdl', 'Loading text', 'Loading title', 'Loading subtitle')
        add('i4', 2)
        add('zzzz', 'UI\\Loading\\Prologue.mdl', 'Prologue text', 'Prologue title', 'Prologue subtitle')
        add('i4fffBBBB', 0, 0.12345679, 0.9876543, 0.00432109, 1, 2, 3, 4)
        if version >= 39 then
            -- New fog fields precede weather. Nonzero height/sky/weather values
            -- detect an incorrect layout even if its reader and writer agree.
            add('fffffI4', 0.125, 4096.75, 250.321098, 1750.765432, 0.75, 1)
        end
        add('c4', 'RAhr')
        add('zc1BBBB', 'Default', 'L', 13, 47, 192, 255)
        if version >= 28 then
            add('i4', script_type or 1)
        end
        if version >= 29 then
            add('i4', 3)
        end
        if version >= 30 then
            add('i4', 1)
        end
        if version >= 32 then
            add('I4I4', 1350, 3000)
            if version >= 33 then
                add('I4', 600)
            end
        end
        if version >= 39 then
            add('I4I4I4I4I4I4I4I4I4I4', 0, 100, 25, 5, 33, 22, 99, 0xFFC08020, 123, 0xEA39C671)
        end
    else
        add('zzz', 'Loading text', 'Loading title', 'Loading subtitle')
        add('i4zzz', 7, 'Prologue text', 'Prologue title', 'Prologue subtitle')
    end

    add('i4', 2)
    for i = 1, 2 do
        add('i4i4i4', i == 1 and 0 or 23, i, i == 1 and 0 or 4)
        if version >= 39 then
            add('I4', i == 1 and 64 or 4)
        end
        add('i4zffI4I4', i, 'Player ' .. i, 128.123456 * i, -64.765432 * i, 0x80000001, 0x00800000)
        if version >= 31 then
            add('I4I4', 0x80800000, 0xFFFFFFFF)
        end
    end
    add('i4', 2)
    add('I4I4z', 0xFFFFFFC7, 0x80000001, 'Force 1')
    add('I4I4z', 0x3B, 0x01800000, 'Force 2')
    add('i4I4c4i4i4', 1, 0xFFFFFFFF, 'Rhme', 2, 2)
    add('i4I4c4', 1, 0x80000000, 'hfoo')
    add('i4i4zi4i4i4i4i4c4c4', 1, 17, 'Spawn', 2, 0, 2, 1, 100, 'hfoo', 'ratf')
    if version >= 25 then
        add('i4i4zi4i4i4c4i4i4c4i4c4', 1, 29, 'Loot', 2, 1, 33, 'ratf', 2, 25, 'gold', 75, 'lmbr')
    end
    if version == 26 or version == 27 then
        add('i4', script_type or 1)
    end
    return table.concat(bytes)
end

local function equal_bytes(expected, actual, context)
    if expected == actual then
        return
    end
    local offset = 1
    while offset <= #expected and expected:byte(offset) == actual:byte(offset) do
        offset = offset + 1
    end
    error(('%s differs at byte %d (lengths %d and %d)'):format(context, offset, #expected, #actual))
end

for _, version in ipairs {18, 25, 26, 27, 28, 29, 30, 31, 32, 33, 39} do
    local binary = fixture(version)
    local data = w2l:frontend_w3i(binary)
    assert(data[lang.w3i.MAP][lang.w3i.FILE_VERSION] == version)
    assert(data[lang.w3i.PLAYER .. 2][lang.w3i.PLAYER] == 23)
    assert(data[lang.w3i.RANDOM_GROUP .. 1].ID == 17)
    if version >= 25 then
        assert(data[lang.w3i.RANDOM_ITEM .. 1].ID == 29)
        assert(data[lang.w3i.ENVIRONMENT][lang.w3i.WEATHER] == 'RAhr')
    end
    if version >= 32 then
        assert(data[lang.w3i.CAMERA][lang.w3i.DEFAULT_CAMERA_ZOOM] == 1350)
        assert(data[lang.w3i.CAMERA][lang.w3i.MAX_CAMERA_ZOOM] == 3000)
    end
    if version >= 33 then
        assert(data[lang.w3i.CAMERA][lang.w3i.MIN_CAMERA_ZOOM] == 600)
    end
    if version == 39 then
        assert(data[lang.w3i.LOADING_SCREEN][lang.w3i.LOADING_SCREEN_RACE_HUD] == 128)
        assert(data[lang.w3i.FOG][lang.w3i.HEIGHT_START] == 0.125)
        assert(data[lang.w3i.FOG][lang.w3i.HEIGHT_END] == 4096.75)
        assert(data[lang.w3i.FOG][lang.w3i.LINEAR_START] == string.unpack('<f', string.pack('<f', 250.321098)))
        assert(data[lang.w3i.FOG][lang.w3i.LINEAR_END] == string.unpack('<f', string.pack('<f', 1750.765432)))
        assert(data[lang.w3i.FOG][lang.w3i.MAX_OPACITY] == 0.75)
        assert(data[lang.w3i.FOG][lang.w3i.DRAW_OVER_SKY] == 1)
        assert(data[lang.w3i.ENVIRONMENT][lang.w3i.WATER_WAVES_NORMAL_STRENGTH] == 99)
        assert(data[lang.w3i.ENVIRONMENT][lang.w3i.MINIMAP_ALPHA_TILE_COLOR] == 0xEA39C671)
        assert(data[lang.w3i.PLAYER .. 1][lang.w3i.HUD_SKIN] == 64)
        assert(data[lang.w3i.PLAYER .. 2][lang.w3i.HUD_SKIN] == 4)
    end
    equal_bytes(binary, w2l:backend_w3i(data), 'W3I v' .. version .. ' binary round trip')
    local lni = w2l:backend_w3i2lni(data)
    local rebuilt = w2l:parse_lni(lni, 'w3i-modern')
    equal_bytes(binary, w2l:backend_w3i(rebuilt), 'W3I v' .. version .. ' LNI round trip')

    local ok, err = pcall(w2l.frontend_w3i, w2l, binary .. '\x01')
    assert(not ok and tostring(err):find('Unparsed war3map.w3i', 1, true))
end

for _, version in ipairs {19, 34, 38, 40} do
    local ok, err = pcall(w2l.frontend_w3i, w2l, string.pack('<i4', version))
    assert(not ok and tostring(err):find('Unsupported war3map.w3i format version', 1, true))
    local data = w2l:frontend_w3i(fixture(39))
    data[lang.w3i.MAP][lang.w3i.FILE_VERSION] = version
    ok, err = pcall(w2l.backend_w3i, w2l, data)
    assert(not ok and tostring(err):find('Unsupported war3map.w3i format version', 1, true))
end

for _, version in ipairs {26, 27, 28, 39} do
    local ok, err = pcall(w2l.frontend_w3i, w2l, fixture(version, 2))
    assert(not ok and tostring(err):find('Unsupported war3map.w3i script language', 1, true))
end
