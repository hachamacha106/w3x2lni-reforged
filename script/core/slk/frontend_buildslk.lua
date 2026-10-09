local w2l

local abilitybuffdata = {
    {'alias',   'code', 'comments', 'isEffect', 'version', 'useInEditor', 'sort', 'race' , 'InBeta'},
    ['Bdbl'] = {'Bdbl', 'YDWE'    ,  0        ,  1       ,  1           , 'hero', 'human',  1      },
    ['Bdbm'] = {'Bdbm', 'YDWE'    ,  0        ,  1       ,  1           , 'hero', 'human',  1      },
    ['BHtb'] = {'BHtb', 'YDWE'    ,  0        ,  1       ,  1           , 'unit', 'other',  1      },
    ['Bsta'] = {'Bsta', 'YDWE'    ,  0        ,  1       ,  1           , 'unit', 'orc'  ,  1      },
    ['Bdbb'] = {'Bdbb', 'YDWE'    ,  0        ,  1       ,  1           , 'hero', 'human',  1      },
    ['BIpb'] = {'BIpb', 'YDWE'    ,  0        ,  1       ,  1           , 'item', 'other',  1      },
    ['BIpd'] = {'BIpd', 'YDWE'    ,  0        ,  1       ,  1           , 'item', 'other',  1      },
    ['Btlf'] = {'Btlf', 'YDWE'    ,  0        ,  1       ,  1           , 'unit', 'other',  1      },
}

local function merge_slk(t, fix)
    for k, v in pairs(fix) do
        if k ~= 1 then
            t[k] = {}
            for i, key in ipairs(fix[1]) do
                if i ~= 1 then
                    t[k][key] = v[i-1]
                end
            end
        end
    end
end

local miscdata = {
    ['Misc'] = {
        ['GoldTextHeight']             = {'0.024'},
        ['GoldTextVelocity']           = {'0', '0.03'},
        ['LumberTextHeight']           = {'0.024'},
        ['LumberTextVelocity']         = {'0', '0.03'},
        ['BountyTextHeight']           = {'0.024'},
        ['BountyTextVelocity']         = {'0', '0.03'},
        ['MissTextHeight']             = {'0.024'},
        ['MissTextVelocity']           = {'0', '0.03'},
        ['CriticalStrikeTextHeight']   = {'0.024'},
        ['CriticalStrikeTextVelocity'] = {'0', '0.04'},
        ['ShadowStrikeTextHeight']     = {'0.024'},
        ['ShadowStrikeTextVelocity']   = {'0', '0.04'},
        ['ManaBurnTextHeight']         = {'0.024'},
        ['ManaBurnTextVelocity']       = {'0', '0.04'},
        ['BashTextVelocity']           = {'0', '0.04'},
    },
    ['Terrain'] = {
        ['MaxSlope']                   = {'90'},
        ['MaxHeight']                  = {'1920'},
        ['MinHeight']                  = {'-1920'},
    },
    ['FontHeights'] = {
        ['ToolTipName']                = {'0.011'},
        ['ToolTipDesc']                = {'0.011'},
        ['ToolTipCost']                = {'0.011'},
        ['ChatEditBar']                = {'0.013'},
        ['CommandButtonNumber']        = {'0.009'},
        ['WorldFrameMessage']          = {'0.015'},
        ['WorldFrameTopMessage']       = {'0.024'},
        ['WorldFrameUnitMessage']      = {'0.015'},
        ['WorldFrameChatMessage']      = {'0.013'},
        ['Inventory']                  = {'0.011'},
        ['LeaderBoard']                = {'0.007'},
        ['PortraitStats']              = {'0.011'},
        ['UnitTipPlayerName']          = {'0.011'},
        ['UnitTipDesc']                = {'0.011'},
        ['ScoreScreenNormal']          = {'0.011'},
        ['ScoreScreenLarge']           = {'0.011'},
        ['ScoreScreenTeam']            = {'0.009'},
    },
}

local function merge_txt(t, fix)
    for name, data in pairs(fix) do
        name = name:lower()
        if not t[name] then
            t[name] = {}
        end
        for k, v in pairs(data) do
            k = k:lower()
            t[name][k] = v
        end
    end
end

return function (_w2l, load_map)
    w2l = _w2l
    
    local slk = w2l.parse_slk
    local txt = w2l.parse_txt
    
    local hook
    local native_profile_base
    local native_profile_strings
    local string_profiles = {}
    for _, filenames in pairs(w2l.info.profile_strings or {}) do
        for _, filename in ipairs(filenames) do string_profiles[filename] = true end
    end
    local profile_schema = load_map and w2l:keydata()
    function w2l:parse_slk(...)
        if hook then
            local r = slk(self, ...)
            hook(r)
            hook = nil
            return r
        end
        return slk(self, ...)
    end

    function w2l:parse_txt(buffer, filename, destination)
        local r
        if native_profile_base ~= nil then
            local base = native_profile_base
            local strings = native_profile_strings
            native_profile_base = nil
            native_profile_strings = nil
            r = txt(self, base, filename, destination)
            -- Parsing into an existing table appends property arrays. Native
            -- map profiles override whole properties, including empty values.
            local overrides = txt(self, buffer, filename)
            for name, fields in pairs(overrides) do
                r[name] = r[name] or {}
                for key, values in pairs(fields) do
                    -- An empty localized skin value explicitly clears its
                    -- stock text. Keep it representable in table/txt.ini.
                    if strings and #values == 0 then values = {''} end
                    r[name][key] = values
                end
            end
        else
            r = txt(self, buffer, filename, destination)
        end
        if hook then
            hook(r)
            hook = nil
        end
        return r
    end
    
    local result = w2l:frontend_slk(function(name)
        if name:lower() == 'units\\abilitybuffdata.slk' then
            function hook(t)
                merge_slk(t, abilitybuffdata)
            end
        end
        if name:lower() == 'ui\\miscdata.txt' then
            function hook(t)
                merge_txt(t, miscdata)
            end
        end
        if load_map then
            local buf = w2l:file_load('map', name)
            if buf then
                local filename = name:lower()
                if filename:sub(-4) == '.txt' and profile_schema[filename] then
                    native_profile_base = w2l:mpq_load(name) or ''
                    native_profile_strings = string_profiles[filename]
                end
                return buf
            end
        end
        return w2l:mpq_load(name)
    end)

    w2l.parse_slk = slk
    w2l.parse_txt = txt
    return result
end
