-- Executes the actual outer HM3W header writer against an explicitly mocked
-- filesystem/StormLib boundary. This proves header bytes and dispatch, not the
-- Windows DLL ABI, MPQ packing, GUI operation, or Warcraft/World Editor loading.
-- Run with a normal Lua 5.4 interpreter; no platform bootstrap is used, so native
-- long width cannot hide incorrect four-byte header serialization.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/archive_header.lua$'),
    'Run archive_header.lua by its absolute path')

local lang = {w3i = setmetatable({}, {__index = function(_, key) return key end}),
    script = {CREATE_MAP_FAILED = 'CREATE_MAP_FAILED'}}
local written, created, closes
local stormlib = {
    open = function() return nil end,
    create = function(path, count, encrypt)
        assert(written and written.path == path, 'Header must be written before MPQ creation')
        created = {count = count, encrypt = encrypt}
        return {close = function() closes = closes + 1 end}
    end,
}
local dependencies = {['share.lang'] = lang, ['ffi.stormlib'] = stormlib}
local environment = setmetatable({
    require = function(name) return assert(dependencies[name], 'Unexpected dependency: ' .. name) end,
    io = {save = function(path, bytes) written = {path = path, bytes = bytes} end},
}, {__index = _G})
local archive_mpq = assert(loadfile(root .. '/script/map-builder/archive_mpq.lua', 't', environment))()

local function path(extension)
    return {extension = function() return {string = function() return extension end} end}
end

local legacy_fields = {
    'DISABLE_PREVIEW', 'CUSTOM_ALLY', 'MELEE_MAP', 'LARGE_MAP',
    'MASKED_AREA_SHOW_TERRAIN', 'FIX_FORCE_SETTING', 'CUSTOM_FORCE',
    'CUSTOM_TECHTREE', 'CUSTOM_ABILITY', 'CUSTOM_UPGRADE', 'MAP_MENU_MARK',
    'SHOW_WAVE_ON_CLIFF', 'SHOW_WAVE_ON_ROLLING',
    'USE_TERRAIN_FOG', 'REQUIRES_EXPANSION', 'USE_ITEM_CLASSIFICATION',
    'USE_WATER_TINTING', 'ACCURATE_PROBABILITY', 'CUSTOM_ABILITY_SKINS',
    'DISABLE_DENY_ICON', 'FORCE_DEFAULT_ZOOM', 'FORCE_MAX_ZOOM',
}
local function map()
    local config = {}
    for _, key in ipairs(legacy_fields) do config[key] = 0 end
    config.DISABLE_PREVIEW, config.MELEE_MAP, config.FORCE_MAX_ZOOM = 1, 1, 1
    return {CONFIG = config, MAP = {FILE_VERSION = 39, MAP_NAME = 'Current map: hráč'},
        PLAYER = {PLAYER_COUNT = 3},
        PLAYER1 = {TYPE = 1}, PLAYER2 = {TYPE = 2}, PLAYER3 = {TYPE = 1}}
end

local function check(data, expected_flags, args)
    written, created, closes = nil, nil, 0
    local target = path('.w3x')
    local archive = archive_mpq(target, false)
    assert(archive:save(target, data, nil, 17, args))
    local expected = 'HM3W' .. string.rep('\0', 4) .. data.MAP.MAP_NAME .. '\0'
        .. string.pack('<I4i4', expected_flags, 2)
    assert(written.bytes == expected, ('Incorrect HM3W bytes for flags 0x%08X'):format(expected_flags))
    assert(created.count == 20 and created.encrypt == (args and args.encrypt))
    archive:close()
    assert(closes == 1)
end

-- The same bit meanings are used by backend_w3i.lua and HiveWE map_info.ixx
-- (36898a50f6bf808871c8b95de3f48f0b64f80fdc). The outer header carries MapFlags
-- unchanged in War3Net's MapInfoExtensions.WriteArchiveHeaderToStream.
check(map(), 0x00200005)
for index = 14, #legacy_fields do
    local data = map()
    for clear_index = 14, #legacy_fields do
        data.CONFIG[legacy_fields[clear_index]] = 0
    end
    data.CONFIG[legacy_fields[index]] = 1
    check(data, 0x00000005 | (1 << (index - 1)))
end
for _, case in ipairs {
    {'FORCE_MIN_ZOOM', 0x00400000},
    {'OVERRIDE_HD_WATER_COLOR', 0x00800000},
    {'ALPHA_TILE_MINIMAP_COLOR', 0x01000000},
    {'DYNAMIC_MINIMAP', 0x02000000},
} do
    local data = map()
    data.CONFIG[case[1]] = 1
    check(data, 0x00200005 | case[2])
end

-- Opaque high bits survive, while opaque data cannot overwrite named low bits.
local unknown = map()
unknown.CONFIG.UNKNOWN_FLAGS = 0xFFFFFFFF
check(unknown, 0xFC200005)
local all = map()
for _, key in ipairs(legacy_fields) do all.CONFIG[key] = 1 end
all.CONFIG.FORCE_MIN_ZOOM, all.CONFIG.OVERRIDE_HD_WATER_COLOR = 1, 1
all.CONFIG.ALPHA_TILE_MINIMAP_COLOR, all.CONFIG.DYNAMIC_MINIMAP = 1, 1
all.CONFIG.UNKNOWN_FLAGS = 0xFC000000
check(all, 0xFFFFFFFF, {encrypt = true})
print('PASS HM3W legacy, current and unknown map flags use exact little-endian 32-bit bytes')

-- Campaign and raw-MPQ modes retain their existing header behavior.
written, created, closes = nil, nil, 0
local campaign_path = path('.w3n')
local campaign = archive_mpq(campaign_path, false)
assert(campaign:save(campaign_path, nil, {campaign_name = 'Campaign'}, 0))
assert(written.bytes == 'HM3W' .. string.rep('\0', 4) .. 'Campaign\0' .. string.pack('<I4i4', 0, 1))
campaign:close()
written, created, closes = nil, nil, 0
local raw_path = path('.mpq')
local raw = archive_mpq(raw_path, false)
assert(raw:save(raw_path, map(), nil, 0, {as_mpq = true}))
assert(written.bytes == '')
raw:close()
print('PASS campaign header and raw-MPQ header bypass')
