local select = select
local string_unpack = string.unpack
local string_match = string.match
local w3xparser = require 'w3xparser'

local w2l
local wts
local default
local has_level
local unpack_buf
local unpack_pos
local version

local function set_pos(...)
    unpack_pos = select(-1, ...)
    return ...
end

local function unpack(str)
    return set_pos(string_unpack('<' .. str, unpack_buf, unpack_pos))
end

local function read_count(description, minimum_size)
    local count = unpack 'i4'
    if count < 0 or count > (#unpack_buf - unpack_pos + 1) // minimum_size then
        error(('Invalid %s count %d in object data at byte %d.'):format(description, count, unpack_pos - 4))
    end
    return count
end

local function read_data(obj)
    local id = string_match(unpack 'c4', '^[^\0]+')
    local value_type = unpack 'i4'
    local level = 0
    local pointer = 0

    --是否包含等级信息
    if has_level then
        level = unpack 'i4'
        pointer = unpack 'i4'
    end

    local value
    if value_type == 0 then
        value = unpack 'i4'
    elseif value_type == 1 or value_type == 2 then
        value = w3xparser.bin2float(unpack 'c4')
    elseif value_type == 3 then
        local str = unpack 'z'
        value = w2l:load_wts(wts, str)
    elseif version >= 3 then
        error(('Unsupported object value type %d at byte %d.'):format(value_type, unpack_pos))
    end

    local terminal = unpack 'i4'

    -- 没有取到值说明是垃圾，忽略掉
    -- Older protected maps can contain payload-free garbage modifications.
    -- Retain the legacy filter for those files, without guessing new v3 types.
    if not value or not id then
        return
    end

    local modifications = obj._object_modifications
    modifications[#modifications+1] = {id, value_type, level, pointer, value, terminal}

    if level == 0 then
        level = 1
    end
    if not obj[id] then
        obj[id] = {}
    end
    obj[id][level] = value
end

local function read_obj(chunk, type)
    local parent, name = unpack 'c4c4'
    local original = name == '\0\0\0\0'
    if original then
        name = parent
    end
    local obj = {
        _id = name,
        _parent = parent,
        _type = type,
        _obj = true,
        _object_version = version,
        _object_original = original,
        _object_modifications = {},
    }

    -- Patch 1.33 introduced a counted Int32 array between the IDs and the
    -- modifications. Its meaning is unknown, so keep it through every mode.
    if version == 3 then
        obj._object_data = {}
        local count = read_count('v3 object header', 4)
        for i = 1, count do
            obj._object_data[i] = unpack 'i4'
        end
        if count > 0 then
            obj._keep_obj = true
        end
    end

    local count = read_count('modification', has_level and 20 or 12)
    for i = 1, count do
        read_data(obj)
    end
    if not default or not default[parent] then
        w2l.force_slk = true
    end
    chunk[name] = obj
    return obj
end

local function read_chunk(chunk, type)
    if version < 3 and unpack_pos > #unpack_buf then
        return
    end
    local count = read_count('object', version == 3 and 16 or 12)
    for i = 1, count do
        read_obj(chunk, type)
    end
end

return function (w2l_, type, buf, wts_)
    w2l = w2l_
    if type == 'misc' then
        return w2l:frontend_misc(buf)
    end
    wts = wts_
    default = w2l:get_default()[type]
    has_level = w2l.info.key.max_level[type]
    unpack_buf = buf
    unpack_pos = 1
    local data    = {}
    -- 版本号
    version = unpack 'i4'
    if version ~= 1 and version ~= 2 and version ~= 3 then
        error(('Unsupported %s object data version %d (supported: 1, 2, 3).'):format(type, version))
    end
    -- 默认数据
    read_chunk(data, type)
    -- 自定义数据
    read_chunk(data, type)
    return data
end
