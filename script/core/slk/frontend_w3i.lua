-- v32/33: WC3MapSpecification/Info/0-33.md.
-- v39: War3Net Serialization/Binary/Info/MapInfo.cs,
-- 18e88f0e1f67e6b16870dcbcd827740275fe2173. Extended fog precedes weather.
local lang = require 'lang'
local select = select

local w2l

local function unpack_flag(flag)
    local tbl = {}
    for i = 0, 64 do
        local n = 1 << i
        if n > flag then
            break
        end
        if flag & n ~= 0 then
            tbl[#tbl+1] = i + 1
        end
    end
    return tbl
end

local function pack(...)
    local tbl = {...}
    tbl[#tbl] = nil
    return tbl
end

local mt = {}
mt.__index = mt

function mt:set_index(...)
    self.index = select(-1, ...)
    return ...
end

function mt:unpack(str)
    return self:set_index(('<' .. str):unpack(self.content, self.index))
end

function mt:is_finish()
    return self.index > #self.content
        or self.index == #self.content and self.content:byte(self.index) == 0xFF
end

function mt:get_version(chunk)
    local version = self:unpack 'i4'
    assert(version == 18 or version >= 25 and version <= 33 or version == 39,
        ('Unsupported war3map.w3i format version: %d'):format(version))
    return version
end

function mt:add_head(chunk, version)
    if version >= 27 then
        chunk[lang.w3i.MAP] = {
            [lang.w3i.FILE_VERSION] = version,
            [lang.w3i.MAP_VERSION]  = self:unpack 'i4',
            [lang.w3i.WE_VERSION]   = self:unpack 'i4',
            [lang.w3i.WAR3_VERSION] = {
                [1] = self:unpack 'i4',
                [2] = self:unpack 'i4',
                [3] = self:unpack 'i4',
                [4] = self:unpack 'i4',
            },
            [lang.w3i.MAP_NAME]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.AUTHOR_NAME]  = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.MAP_DESC]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.PLAYER_DESC]  = w2l:load_wts(self.wts, (self:unpack 'z')),
        }
    else
        chunk[lang.w3i.MAP] = {
            [lang.w3i.FILE_VERSION] = version,
            [lang.w3i.MAP_VERSION]  = self:unpack 'i4',
            [lang.w3i.WE_VERSION]   = self:unpack 'i4',
            [lang.w3i.MAP_NAME]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.AUTHOR_NAME]  = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.MAP_DESC]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.PLAYER_DESC]  = w2l:load_wts(self.wts, (self:unpack 'z')),
        }
    end
    
    chunk[lang.w3i.CAMERA] = {
        [lang.w3i.CAMERA_BOUND]      = pack(self:unpack 'ffffffff'),
        [lang.w3i.CAMERA_COMPLEMENT] = pack(self:unpack 'i4i4i4i4'),
    }

    chunk[lang.w3i.MAP_INFO] = {
        [lang.w3i.MAP_WIDTH]  = self:unpack 'i4',
        [lang.w3i.MAP_HEIGHT] = self:unpack 'i4',
    }

    local flag = self:unpack 'I4'
    chunk[lang.w3i.CONFIG] = {
        [lang.w3i.DISABLE_PREVIEW]          = flag >> 0 & 1,
        [lang.w3i.CUSTOM_ALLY]              = flag >> 1 & 1,
        [lang.w3i.MELEE_MAP]                = flag >> 2 & 1,
        [lang.w3i.LARGE_MAP]                = flag >> 3 & 1,
        [lang.w3i.MASKED_AREA_SHOW_TERRAIN] = flag >> 4 & 1,
        [lang.w3i.FIX_FORCE_SETTING]        = flag >> 5 & 1,
        [lang.w3i.CUSTOM_FORCE]             = flag >> 6 & 1,
        [lang.w3i.CUSTOM_TECHTREE]          = flag >> 7 & 1,
        [lang.w3i.CUSTOM_ABILITY]           = flag >> 8 & 1,
        [lang.w3i.CUSTOM_UPGRADE]           = flag >> 9 & 1,
        [lang.w3i.MAP_MENU_MARK]            = flag >> 10 & 1,
        [lang.w3i.SHOW_WAVE_ON_CLIFF]       = flag >> 11 & 1,
        [lang.w3i.SHOW_WAVE_ON_ROLLING]     = flag >> 12 & 1,
        [lang.w3i.USE_TERRAIN_FOG]                = flag >> 13 & 1,
        [lang.w3i.REQUIRES_EXPANSION]                = flag >> 14 & 1,
        [lang.w3i.USE_ITEM_CLASSIFICATION]                = flag >> 15 & 1,
        [lang.w3i.USE_WATER_TINTING]                = flag >> 16 & 1,
        [lang.w3i.ACCURATE_PROBABILITY]                = flag >> 17 & 1,
        [lang.w3i.CUSTOM_ABILITY_SKINS]                = flag >> 18 & 1,
        [lang.w3i.DISABLE_DENY_ICON]                = flag >> 19 & 1,
        [lang.w3i.FORCE_DEFAULT_ZOOM]                = flag >> 20 & 1,
        [lang.w3i.FORCE_MAX_ZOOM]                = flag >> 21 & 1,
        [lang.w3i.FORCE_MIN_ZOOM]           = flag >> 22 & 1,
        [lang.w3i.OVERRIDE_HD_WATER_COLOR]  = flag >> 23 & 1,
        [lang.w3i.ALPHA_TILE_MINIMAP_COLOR] = flag >> 24 & 1,
        [lang.w3i.DYNAMIC_MINIMAP]          = flag >> 25 & 1,
        [lang.w3i.UNKNOWN_FLAGS]           = flag & 0xFC000000,
    }

    chunk[lang.w3i.MAP_INFO][lang.w3i.MAP_MAIN_GROUND] = self:unpack 'c1'

    if version >= 25 then
        chunk[lang.w3i.LOADING_SCREEN] = {
            [lang.w3i.ID]       = self:unpack 'i4',
            [lang.w3i.LOADING_SCREEN_RACE_HUD] = version >= 39 and self:unpack 'I4' or nil,
            [lang.w3i.PATH]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TEXT]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TITLE]    = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SUBTITLE] = w2l:load_wts(self.wts, (self:unpack 'z')),
        }

        chunk[lang.w3i.CONFIG][lang.w3i.GAME_DATA_SETTING] = self:unpack 'i4'
    
        chunk[lang.w3i.PROLOGUE] = {
            [lang.w3i.PATH]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TEXT]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TITLE]    = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SUBTITLE] = w2l:load_wts(self.wts, (self:unpack 'z')),
        }
    
        chunk[lang.w3i.FOG] = {
            [lang.w3i.TYPE]    = self:unpack 'i4',
            [lang.w3i.START_Z] = self:unpack 'f',
            [lang.w3i.END_Z]   = self:unpack 'f',
            [lang.w3i.DENSITY] = self:unpack 'f',
            [lang.w3i.COLOR]   = pack(self:unpack 'BBBB'),
        }
        
        local environment = {}
        chunk[lang.w3i.ENVIRONMENT] = environment

        -- Warcraft III 3.0 (W3I v39): the six added fog fields precede weather.
        if version >= 39 then
            local fog = chunk[lang.w3i.FOG]
            fog[lang.w3i.HEIGHT_START] = self:unpack 'f'
            fog[lang.w3i.HEIGHT_END] = self:unpack 'f'
            fog[lang.w3i.LINEAR_START] = self:unpack 'f'
            fog[lang.w3i.LINEAR_END] = self:unpack 'f'
            fog[lang.w3i.MAX_OPACITY] = self:unpack 'f'
            fog[lang.w3i.DRAW_OVER_SKY] = self:unpack 'I4'
        end

        environment[lang.w3i.WEATHER] = self:unpack 'c4'
        environment[lang.w3i.SOUND] = w2l:load_wts(self.wts, (self:unpack 'z'))
        environment[lang.w3i.LIGHT] = self:unpack 'c1'
        environment[lang.w3i.WATER_COLOR] = pack(self:unpack 'BBBB')

        if version >= 28 then
            local scriptType = self:unpack 'i4'
            assert(scriptType == 0 or scriptType == 1, 'Unsupported war3map.w3i script language')
            chunk[lang.w3i.MAP][lang.w3i.SCRIPT_TYPE] = scriptType == 0 and 'JASS' or 'Lua'
        end

        -- Keep the full numeric IDs/bitmasks, including unrecognized future bits.
        if version >= 29 then
            chunk[lang.w3i.MAP][lang.w3i.SUPPORTED_GRAPHICS_MODES] = self:unpack 'I4'
        end
        if version >= 30 then
            chunk[lang.w3i.MAP][lang.w3i.GAME_DATA_VERSION] = self:unpack 'I4'
        end
        if version >= 32 then
            local camera = chunk[lang.w3i.CAMERA]
            camera[lang.w3i.DEFAULT_CAMERA_ZOOM] = self:unpack 'I4'
            camera[lang.w3i.MAX_CAMERA_ZOOM] = self:unpack 'I4'
            if version >= 33 then
                camera[lang.w3i.MIN_CAMERA_ZOOM] = self:unpack 'I4'
            end
        end
        if version >= 39 then
            environment[lang.w3i.WATER_MIN_OPACITY] = self:unpack 'I4'
            environment[lang.w3i.WATER_MAX_OPACITY] = self:unpack 'I4'
            environment[lang.w3i.WATER_REFLECTIVITY] = self:unpack 'I4'
            environment[lang.w3i.WATER_EMISSIVITY] = self:unpack 'I4'
            environment[lang.w3i.WATER_EDGE_SOFTNESS] = self:unpack 'I4'
            environment[lang.w3i.WATER_WAVES_DISPLACEMENT] = self:unpack 'I4'
            environment[lang.w3i.WATER_WAVES_NORMAL_STRENGTH] = self:unpack 'I4'
            environment[lang.w3i.WATER_TINTING_COLOR] = self:unpack 'I4'
            environment[lang.w3i.WATER_ENV_REFLECTIVITY] = self:unpack 'I4'
            environment[lang.w3i.MINIMAP_ALPHA_TILE_COLOR] = self:unpack 'I4'
        end
    elseif version == 18 then
        chunk[lang.w3i.LOADING_SCREEN] = {
            [lang.w3i.ID]          = self:unpack 'i4',
            [lang.w3i.TEXT]        = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TITLE]       = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SUBTITLE]    = w2l:load_wts(self.wts, (self:unpack 'z')),
        }

        chunk[lang.w3i.PROLOGUE] = {
            [lang.w3i.ID]          = self:unpack 'i4',
            [lang.w3i.TEXT]     = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.TITLE]    = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SUBTITLE] = w2l:load_wts(self.wts, (self:unpack 'z')),
        }
    end
end

function mt:add_player(chunk, version)
    chunk[lang.w3i.PLAYER] = {
        [lang.w3i.PLAYER_COUNT] = self:unpack 'i4',
    }

    for i = 1, chunk[lang.w3i.PLAYER][lang.w3i.PLAYER_COUNT] do
        chunk[lang.w3i.PLAYER..i] = {
            [lang.w3i.PLAYER]             = self:unpack 'i4',
            [lang.w3i.TYPE]               = self:unpack 'i4',
            [lang.w3i.RACE]               = self:unpack 'i4',
            [lang.w3i.HUD_SKIN]           = version >= 39 and self:unpack 'I4' or nil,
            [lang.w3i.FIX_START_POSITION] = self:unpack 'i4',
            [lang.w3i.NAME]               = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.START_POSITION]     = pack(self:unpack 'ff'),
            [lang.w3i.ALLY_LOW_FLAG]      = unpack_flag(self:unpack 'I4'),
            [lang.w3i.ALLY_HIGH_FLAG]     = unpack_flag(self:unpack 'I4'),
        }

        if version >= 31 then
            -- Enemy start-location priorities use the same player-slot bitmaps.
            chunk[lang.w3i.PLAYER..i][lang.w3i.ENEMY_LOW_PRIORITY_FLAGS] = self:unpack 'I4'
            chunk[lang.w3i.PLAYER..i][lang.w3i.ENEMY_HIGH_PRIORITY_FLAGS] = self:unpack 'I4'
        end
    end
end

function mt:unpack_player_flag(chunk)
    local flag = self:unpack 'I4'
    local tbl = unpack_flag(flag)
    local exits = {}
    for i = 1, chunk[lang.w3i.PLAYER][lang.w3i.PLAYER_COUNT] do
        local player = chunk[lang.w3i.PLAYER..i]
        local id = player[lang.w3i.PLAYER] + 1
        exits[id] = true
    end
    local result, unused = {}, {}
    for _, id in ipairs(tbl) do
        if exits[id] then
            result[#result+1] = id
        else
            unused[#unused+1] = id
        end
    end
    return result, unused
end

function mt:add_force(chunk)
    chunk[lang.w3i.FORCE] = {
        [lang.w3i.FORCE_COUNT] = self:unpack 'i4',
    }

    for i = 1, chunk[lang.w3i.FORCE][lang.w3i.FORCE_COUNT] do
        local flag = self:unpack 'I4'
        chunk[lang.w3i.FORCE..i] = {
            [lang.w3i.ALLY]          = flag >> 0 & 1,
            [lang.w3i.ALLY_WIN]      = flag >> 1 & 1,
            [lang.w3i.SHARE_VISIBLE] = flag >> 3 & 1,
            [lang.w3i.SHARE_CONTROL] = flag >> 4 & 1,
            [lang.w3i.SHARE_ADVANCE] = flag >> 5 & 1,
            [lang.w3i.UNKNOWN_FLAGS] = flag & 0xFFFFFFC4,
        }
        local force = chunk[lang.w3i.FORCE..i]
        force[lang.w3i.PLAYER_LIST], force[lang.w3i.UNUSED_PLAYER_LIST] = self:unpack_player_flag(chunk)
        force[lang.w3i.FORCE_NAME] = w2l:load_wts(self.wts, (self:unpack 'z'))
    end
end

function mt:add_upgrade(chunk)
    if self:is_finish() then
        return
    end
    local count = self:unpack 'i4'
    for i = 1, count do
        chunk[lang.w3i.UPGRADE..i] = {
            [lang.w3i.PLAYER_LIST] = unpack_flag(self:unpack 'I4'),
            ['ID']                 = self:unpack 'c4',
            [lang.w3i.LEVEL]       = self:unpack 'i4',
            [lang.w3i.AVAILABLE]   = self:unpack 'i4',
        }
    end
end

function mt:add_tech(chunk)
    if self:is_finish() then
        return
    end
    local count = self:unpack 'i4'
    for i = 1, count do
        chunk[lang.w3i.TECH..i] = {
            [lang.w3i.PLAYER_LIST] = unpack_flag(self:unpack 'I4'),
            ['ID']                 = self:unpack 'c4',
        }
    end
end

function mt:add_randomgroup(chunk)
    if self:is_finish() then
        return
    end
    local count = self:unpack 'i4'
    for i = 1, count do
        chunk[lang.w3i.RANDOM_GROUP..i] = {
            ['ID']                       = self:unpack 'i4',
            [lang.w3i.RANDOM_GROUP_NAME] = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SETTING]           = {},
        }
        local x = self:unpack 'i4'
        chunk[lang.w3i.RANDOM_GROUP..i][lang.w3i.POSITION_TYPE] = pack(self:unpack(('i4'):rep(x)))

        local y = self:unpack 'i4'
        for y = 1, y do
            chunk[lang.w3i.RANDOM_GROUP..i][lang.w3i.SETTING][y] = {
                [lang.w3i.CHANCE] = self:unpack 'i4',
                ['ID']            = pack(self:unpack(('c4'):rep(x))),
            }
        end
    end
end

function mt:add_randomitem(chunk)
    if self:is_finish() then
        return
    end
    local count = self:unpack 'i4'
    for i = 1, count do
        chunk[lang.w3i.RANDOM_ITEM..i] = {
            ['ID']                      = self:unpack 'i4',
            [lang.w3i.RANDOM_ITEM_NAME] = w2l:load_wts(self.wts, (self:unpack 'z')),
            [lang.w3i.SETTING]          = {},
        }

        --设置
        local x = self:unpack 'i4'
        for x = 1, x do
            chunk[lang.w3i.RANDOM_ITEM..i][lang.w3i.SETTING][x] = {}
            local y = self:unpack 'i4'
            for y = 1, y do
                chunk[lang.w3i.RANDOM_ITEM..i][lang.w3i.SETTING][x][y] = {
                    [lang.w3i.CHANCE] = self:unpack 'i4',
                    ['ID']            = self:unpack 'c4',
                }
            end
        end
    end
end

return function (w2l_, content, wts)
    if not content then
        return nil
    end
    w2l = w2l_
    
    local index = 1
    local tbl   = setmetatable({}, mt)
    local data  = {}

    tbl.content = content
    tbl.index   = index
    tbl.wts     = wts

    local version = tbl:get_version(data)
    if version >= 25 then
        tbl:add_head(data, version)
        tbl:add_player(data, version)
        tbl:add_force(data)
        tbl:add_upgrade(data)
        tbl:add_tech(data)
        tbl:add_randomgroup(data)
        tbl:add_randomitem(data)
        if version == 26 or version == 27 then
            local script_type = tbl:unpack 'i4'
            assert(script_type == 0 or script_type == 1, 'Unsupported war3map.w3i script language')
            data[lang.w3i.MAP][lang.w3i.SCRIPT_TYPE] = script_type == 0 and 'JASS' or 'Lua'
        end
    elseif version == 18 then
        tbl:add_head(data, version)
        tbl:add_player(data, version)
        tbl:add_force(data)
        tbl:add_upgrade(data)
        tbl:add_tech(data)
        tbl:add_randomgroup(data)
    end

    assert(tbl:is_finish(), ('Unparsed war3map.w3i data at byte %d of %d'):format(tbl.index, #content))

    return data
end
