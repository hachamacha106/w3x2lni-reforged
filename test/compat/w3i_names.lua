-- Independent W3I v39 fixtures for descriptive field names. These checks use
-- the real converters and both bundled W3I dictionaries. They do not migrate
-- old LNI keys; fresh exports use the current schema during the preview phase.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local factory = context.core()
local lang = require 'share.lang'

-- Values deliberately cover the entire unsigned range; these fields must not
-- become a smaller enum, a Boolean or a player list during a naming change.
local function fixture(flags, modes, game_data, enemy_low, enemy_high)
    local bytes = {}
    local function add(format, ...)
        bytes[#bytes + 1] = string.pack('<' .. format, ...)
    end
    add('i4i4i4i4i4i4i4', 39, 1, 7003, 3, 0, 1, 24342)
    add('zzzz', 'W3I field names', 'Author', 'Description', '1 player')
    add('ffffffff', -512, -512, 512, 512, -512, 512, 512, -512)
    add('i4i4i4i4i4i4I4c1', 0, 0, 0, 0, 32, 32, flags, 'L')
    add('i4I4zzzz', -1, 128, '', '', '', '')
    add('i4zzzz', 0, '', '', '', '')
    add('i4fffBBBB', 0, 0, 1, 0, 1, 2, 3, 4)
    -- War3Net v39: height range, linear range, opacity, draw-over-sky, then
    -- weather. The weather field is not before the extended fog parameters.
    add('fffffi4c4', -125.5, 767.25, 250, 1750, 0.75, 1, 'RAhr')
    add('zc1BBBB', 'Default', 'L', 13, 47, 192, 255)
    add('i4I4I4I4I4I4', 0, modes, game_data, 1350, 3000, 600)
    add('I4I4I4I4I4I4I4I4I4I4', 0, 100, 25, 5, 33, 22, 99, 0xFFC08020, 123, 0xFF332211)
    add('i4', 1)
    add('i4i4i4I4i4zffI4I4I4I4', 0, 1, 1, 64, 1, 'Player 1', 128, -64,
        0x80000001, 0x00800000, enemy_low, enemy_high)
    add('i4I4I4z', 1, 0, 0xFFFFFFFF, 'Force 1')
    add('i4i4i4i4', 0, 0, 0, 0)
    return table.concat(bytes)
end

local function equal_bytes(expected, actual, context_name)
    if expected == actual then return end
    local offset = 1
    while offset <= #expected and expected:byte(offset) == actual:byte(offset) do
        offset = offset + 1
    end
    error(('%s differs at byte %d (lengths %d and %d)'):format(
        context_name, offset, #expected, #actual))
end

local function round_trip(w2l, data, expected, context_name)
    equal_bytes(expected, w2l:backend_w3i(data), context_name .. ' binary')
    local lni = w2l:backend_w3i2lni(data)
    local parsed = w2l:parse_lni(lni, 'w3i-names')
    equal_bytes(expected, w2l:backend_w3i(parsed), context_name .. ' LNI')
    return lni, parsed
end

local flag_names = {
    {'USE_TERRAIN_FOG', 'use_terrain_fog', 13},
    {'REQUIRES_EXPANSION', 'requires_expansion', 14},
    {'USE_ITEM_CLASSIFICATION', 'use_item_classification', 15},
    {'USE_WATER_TINTING', 'use_water_tinting', 16},
    {'ACCURATE_PROBABILITY', 'accurate_probability', 17},
    {'CUSTOM_ABILITY_SKINS', 'custom_ability_skins', 18},
    {'DISABLE_DENY_ICON', 'disable_deny_icon', 19},
    {'FORCE_DEFAULT_ZOOM', 'force_default_zoom', 20},
    {'FORCE_MAX_ZOOM', 'force_max_zoom', 21},
}
local scalar_names = {
    {'SUPPORTED_GRAPHICS_MODES', 'supported_graphics_modes'},
    {'GAME_DATA_VERSION', 'game_data_version'},
    {'ENEMY_LOW_PRIORITY_FLAGS', 'enemy_low_priority_flags'},
    {'ENEMY_HIGH_PRIORITY_FLAGS', 'enemy_high_priority_flags'},
}
local recent_names = {
    {'HEIGHT_START', 'height_start'},
    {'HEIGHT_END', 'height_end'},
    {'DRAW_OVER_SKY', 'draw_over_sky'},
    {'MINIMAP_ALPHA_TILE_COLOR', 'minimap_alpha_tile_color'},
    {'LOADING_SCREEN_RACE_HUD', 'race_hud'},
}

local function assert_label(locale, token, english)
    local actual = rawget(lang.w3i, token)
    assert(type(actual) == 'string' and actual ~= '', locale .. ' missing ' .. token)
    if locale == 'enUS' then
        assert(actual == english, 'Incorrect English field name for ' .. token)
    else
        assert(actual:find('[\128-\255]'), 'Missing Chinese translation for ' .. token)
    end
    return actual
end

local function assert_export(lni)
    assert(not lni:match('unknown_%d+%s*='), 'English export still contains a numbered unknown')
    assert(not lni:match('未知%d+%s*='), 'Chinese export still contains a numbered unknown')
    assert(not lni:match('unknown_fog_%d+%s*='), 'Export still contains a numbered fog unknown')
    assert(not lni:match('unknown_post_water%s*='), 'Export still contains an unknown water suffix')
    for _, group in ipairs {flag_names, scalar_names, recent_names} do
        for _, field in ipairs(group) do
            assert(lni:find('\n' .. lang.w3i[field[1]] .. ' = ', 1, true),
                'Export omitted readable key ' .. field[1])
        end
    end
end

local function assert_recent_fields(data)
    local fog = data[lang.w3i.FOG]
    assert(fog[lang.w3i.HEIGHT_START] == -125.5, 'Incorrect fog height start')
    assert(fog[lang.w3i.HEIGHT_END] == 767.25, 'Incorrect fog height end')
    assert(fog[lang.w3i.LINEAR_START] == 250 and fog[lang.w3i.LINEAR_END] == 1750)
    assert(fog[lang.w3i.MAX_OPACITY] == 0.75 and fog[lang.w3i.DRAW_OVER_SKY] == 1)
    assert(data[lang.w3i.ENVIRONMENT][lang.w3i.WEATHER] == 'RAhr',
        'Weather must follow the extended fog fields')
    assert(data[lang.w3i.ENVIRONMENT][lang.w3i.MINIMAP_ALPHA_TILE_COLOR] == 0xFF332211,
        'Minimap alpha tile color must preserve all packed BGRA bytes')
    assert(data[lang.w3i.LOADING_SCREEN][lang.w3i.LOADING_SCREEN_RACE_HUD] == 128)
end

for _, locale in ipairs {'enUS', 'zhCN'} do
    lang:set_lang(locale)
    local w2l = factory()
    for _, group in ipairs {flag_names, scalar_names, recent_names} do
        for _, field in ipairs(group) do assert_label(locale, field[1], field[2]) end
    end
    for _, field in ipairs(flag_names) do
        local mask = 1 << field[3]
        local expected = fixture(mask, 3, 1, 0x80800000, 0xFFFFFFFF)
        local data = w2l:frontend_w3i(expected)
        assert_recent_fields(data)
        for _, other in ipairs(flag_names) do
            local want = other == field and 1 or 0
            assert(data[lang.w3i.CONFIG][lang.w3i[other[1]]] == want,
                ('%s: bit %d decoded as the wrong option'):format(locale, field[3]))
        end
        local lni = round_trip(w2l, data, expected, locale .. ' ' .. field[1])
        assert_export(lni)

        -- Independently authored expected bytes also prove that editing each
        -- named option writes its own bit and leaves the other options clear.
        data[lang.w3i.CONFIG][lang.w3i[field[1]]] = 0
        round_trip(w2l, data, fixture(0, 3, 1, 0x80800000, 0xFFFFFFFF),
            locale .. ' clear ' .. field[1])
    end
    print('PASS ' .. locale .. ' descriptive W3I names and all nine option bits')

    for _, values in ipairs {
        {0, 0, 0, 0},
        {3, 1, 0x80800000, 0xFFFFFFFF},
        {0x80000000, 0x80000000, 0xFFFFFFFF, 0x80000001},
        {0xFFFFFFFF, 0xFFFFFFFF, 0x80000000, 0xFFFFFFFF},
    } do
        local expected = fixture(0xFFFFFFFF, table.unpack(values))
        local data = w2l:frontend_w3i(expected)
        assert_recent_fields(data)
        local map, player = data[lang.w3i.MAP], data[lang.w3i.PLAYER .. 1]
        assert(map[lang.w3i.SUPPORTED_GRAPHICS_MODES] == values[1])
        assert(map[lang.w3i.GAME_DATA_VERSION] == values[2])
        assert(player[lang.w3i.ENEMY_LOW_PRIORITY_FLAGS] == values[3])
        assert(player[lang.w3i.ENEMY_HIGH_PRIORITY_FLAGS] == values[4])
        assert(data[lang.w3i.CONFIG][lang.w3i.UNKNOWN_FLAGS] == 0xFC000000,
            'Reserved map flag bits were changed by descriptive names')
        local lni = round_trip(w2l, data, expected, locale .. ' unsigned W3I values')
        assert_export(lni)
    end
    print('PASS ' .. locale .. ' full 32-bit graphics modes, game data and enemy masks')
    print('PASS ' .. locale .. ' fog layout, weather, minimap BGRA color and loading HUD names')
end
