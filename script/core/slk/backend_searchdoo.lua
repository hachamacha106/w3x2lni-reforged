-- Layouts: HiveWE src/base/doodads.ixx,
-- 36898a50f6bf808871c8b95de3f48f0b64f80fdc (versions 7, 8 and 13).
local lang = require 'lang'

local function scan(buf, has_skin)
    local pos = 1
    local function read(format)
        local value
        value, pos = string.unpack('<' .. format, buf, pos)
        return value
    end
    local function skip(size)
        assert(size >= 0 and size <= #buf - pos + 1, 'Truncated war3map.doo record')
        pos = pos + size
    end
    local function count(min_size)
        local value = read 'I4'
        assert(value <= (#buf - pos + 1) // min_size, 'Invalid war3map.doo record count')
        return value
    end

    assert(read 'c4' == 'W3do', 'Invalid war3map.doo signature')
    local version = read 'I4'
    assert(version == 7 or version == 8 or version == 13,
        ('Unsupported war3map.doo version: %d'):format(version))
    local subversion = read 'I4'
    assert(subversion == 9 or subversion == 11,
        ('Unsupported war3map.doo subversion: %d'):format(subversion))

    local destructable, doodad, items = {}, {}, {}
    for _ = 1, count(42) do
        local id = read 'c4'
        destructable[id] = true
        skip(32) -- variation, position, angle and scale
        if has_skin then
            local skin = read 'c4'
            if skin ~= '\0\0\0\0' then
                destructable[skin] = true
            end
        end
        if version >= 13 then
            skip(4) -- group ID
        end
        skip(2) -- state and life
        if version >= 8 then
            skip(4) -- random item table ID
            for _ = 1, count(4) do
                for _ = 1, count(8) do
                    local item = read 'c4'
                    if item ~= '\0\0\0\0' then
                        items[item] = true
                    end
                    skip(4) -- chance
                end
            end
        end
        if version >= 13 then
            skip(4) -- additional v13 field, not interpreted
        end
        skip(4) -- creation number
        if version >= 13 then
            skip(8) -- roll and pitch
            skip(count(36) * 36) -- light index, shadow flag, RGBA and six floats
        end
    end
    assert(read 'I4' == 0, 'Unsupported war3map.doo terrain doodad version')
    for _ = 1, count(16) do
        doodad[read 'c4'] = true
        skip(12) -- variation and grid position
    end
    assert(pos == #buf + 1, 'Unparsed war3map.doo data')
    return destructable, doodad, items
end

local function skin_layout(w2l)
    local info = w2l.slk and w2l.slk.w3i
    local map = info and info[lang.w3i.MAP]
    if not map then
        return nil
    end
    local version = map[lang.w3i.WAR3_VERSION]
    if version and version[1] and version[2] then
        return version[1] > 1 or version[1] == 1 and version[2] >= 32
    end
    local file_version = map[lang.w3i.FILE_VERSION]
    if file_version == 18 or file_version == 25 or file_version == 26 then
        return false
    end
    return nil
end

return function(w2l)
    local buf = w2l:file_load('map', 'war3map.doo')
    if not buf then
        return
    end
    local has_skin = skin_layout(w2l)
    if has_skin ~= nil then
        local ok, destructable, doodad, items = pcall(scan, buf, has_skin)
        if ok then
            return destructable, doodad, items
        end
        return nil, nil, nil, destructable
    end

    -- Missing map metadata: accept only complete parses of the known layouts.
    -- If both layouts happen to fit, retain the union of their references.
    local old_ok, old_destructable, old_doodad, old_items = pcall(scan, buf, false)
    local new_ok, new_destructable, new_doodad, new_items = pcall(scan, buf, true)
    if old_ok and new_ok then
        for id in pairs(new_destructable) do old_destructable[id] = true end
        for id in pairs(new_doodad) do old_doodad[id] = true end
        for id in pairs(new_items) do old_items[id] = true end
        return old_destructable, old_doodad, old_items
    elseif old_ok then
        return old_destructable, old_doodad, old_items
    elseif new_ok then
        return new_destructable, new_doodad, new_items
    end
    return nil, nil, nil, new_destructable
end
