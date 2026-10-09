local lni = require 'lni'
local string_lower = string.lower
local pairs = pairs

local w2l
local default

local function normalize_indexed_profiles(obj, metadata)
    local aliases = {}
    for key, value in pairs(obj) do
        if key:sub(1, 1) ~= '_' and not metadata[key] then
            local field, suffix = key:match('^(.-)(:[%w]+)$')
            field, suffix = field or key, suffix or ''
            local target = field .. '_1' .. suffix
            local meta = metadata[target]
            -- An editor can expand a scalar profile into indexed columns.
            -- Only migrate when the current schema proves the first column
            -- is the same profile key. Explicit current-format data wins.
            if meta and meta.profile and meta.index == 1 and meta.key == key then
                aliases[#aliases+1] = {key, target, value}
            end
        end
    end
    for _, alias in ipairs(aliases) do
        local key, target, value = table.unpack(alias)
        if obj[target] == nil then
            obj[target] = value
        end
        obj[key] = nil
    end
end

local function add_obj(type, name, level_key, obj, metadata)
    local new_obj = {}
    for key, value in pairs(obj) do
        new_obj[string_lower(key)] = value
    end
    normalize_indexed_profiles(new_obj, metadata)
    new_obj._id = name
    new_obj._max_level = obj[level_key]
    new_obj._type = type
    new_obj._obj = true
    if not default or not default[new_obj._parent] then
        w2l.force_slk = true
    end
    return new_obj
end

return function (w2l_, type, buf, filename)
    w2l = w2l_
    default = w2l:get_default()[type]
    local tbl = lni(buf, filename)
    local metadata = w2l:metadata()[type]
    local level_key = w2l.info.key.max_level[type]
    if level_key then
        level_key = metadata[level_key].field
    end
    local data = {}
    for name, obj in pairs(tbl) do
        data[name] = add_obj(type, name, level_key, obj, metadata)
    end
    return data
end
