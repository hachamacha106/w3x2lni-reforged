local w3xparser = require 'w3xparser'
local lang = require 'lang'

local table_insert = table.insert
local table_sort   = table.sort
local table_concat = table.concat
local string_char  = string.char
local math_type    = math.type
local math_floor   = math.floor
local wtonumber = w3xparser.tonumber
local float2bin = w3xparser.float2bin
local type = type
local pairs = pairs
local setmetatable = setmetatable
local os_clock = os.clock

local w2l
local has_level
local metadata
local default
local hexs
local wts
local ttype
local output_skin
local skin_lookup
local object_version

local function format_value(value)
    if type(value) == 'table' then
        local tbl = {}
        for i = 1, 4 do
            if value[i] then
                tbl[i] = ('[%d]: %s'):format(i, tostring(value[i]):sub(1, 25):gsub('\r\n', ' '))
            end
        end
        return table_concat(tbl, ' ')
    else
        return tostring(value):sub(1, 100):gsub('\r\n', ' ')
    end
end

local function report(reason, obj, key, tip)
    w2l.messager.report(reason, 6, ('%s %s %s'):format(w2l:get_displayname(obj)), ('[%s]: %s'):format(key, format_value(tip)))
end

local function write(format, ...)
    hexs[#hexs+1] = ('<' .. format):pack(...)
end

local function should_write(obj, id, level)
    local fields = skin_lookup[obj]
    if not fields then
        fields = {}
        for _, field in ipairs(obj._skin_fields or {}) do
            fields[field] = true
        end
        skin_lookup[obj] = fields
    end
    local in_skin = fields[id .. ':' .. (level == 0 and 1 or level)] or false
    return in_skin == output_skin
end

local function write_typed_value(tp, obj, id, value)
    if tp == 0 then
        if math_type(value) ~= 'integer' then
            value = math_floor(wtonumber(value))
        end
        write('i4', value)
    elseif tp == 1 or tp == 2 then
        write('c4', float2bin(value)) -- obj 的浮点数用api转换为二进制
    else
        if type(value) ~= 'string' then
            value = ''
        end
        if value:find('\0', 1, true) then
            report(lang.report.INVALID_OBJECT_DATA, obj, id, value)
            value = ''
        end
        if #value > 1023 then
            value = w2l:save_wts(wts, value, lang.script.TEXT_TOO_LONG_IN_OBJ)
        end
        write('z', value)
    end
end

local function write_value(meta, level, obj, value)
    local id = meta.id
    local tp = meta.type
    write('c4i4', id .. ('\0'):rep(4 - #id), tp)
    if has_level then
        write('i4', level)
        write('i4', meta.data or 0)
    end
    write_typed_value(tp, obj, id, value)
    write('c4', '\0\0\0\0')
end

local function each_value(data, meta, callback)
    if meta['repeat'] then
        if type(data) ~= 'table' then
            data = {data}
        end
    end
    if type(data) == 'table' then
        local max_level = 0
        for level in pairs(data) do
            if type(level) == 'number' and level > max_level and math_type(level) == 'integer' then
                max_level = level
            end
        end
        for level = 1, max_level do
            if data[level] then
                callback(level, data[level])
            end
        end
    else
        callback(0, data)
    end
end

local function object_metadata(obj)
    local metas = {}
    local code = obj._code
    if metadata[ttype] then
        for key, meta in pairs(metadata[ttype]) do
            metas[key] = meta
        end
    end
    if metadata[code] then
        for key, meta in pairs(metadata[code]) do
            metas[key] = meta
        end
    end
    return metas
end

local function extra_modifications(obj)
    return (output_skin and obj._skin_extras or not output_skin and obj._object_extras) or {}
end

local function is_original(name, obj)
    if output_skin and obj._skin_original ~= nil then
        return obj._skin_original
    end
    local parent = obj._slk_id or obj._parent
    return (name == parent or obj._slk) and not obj._slk_id
end

local function write_object(chunk, name, obj)
    local keys = {}
    local metas = object_metadata(obj)
    for key in pairs(obj) do
        if key:sub(1, 1) ~= '_' then
            keys[#keys+1] = key
        end
    end
    table_sort(keys)

    local count = 0
    for _, key in ipairs(keys) do
        local data = obj[key]
        if data then
            if metas[key] then
                each_value(data, metas[key], function(level)
                    if should_write(obj, metas[key].id, level) then
                        count = count + 1
                    end
                end)
            elseif not output_skin then
                if type(data) == 'table' then
                    if next(data) then
                        report(lang.report.INVALID_OBJECT_DATA, obj, key, obj[key])
                    end
                else
                    report(lang.report.INVALID_OBJECT_DATA, obj, key, obj[key])
                end
            end
        end
    end
    
    local parent = output_skin and obj._skin_parent or obj._slk_id or obj._parent
    if is_original(name, obj) then
        write('c4', output_skin and parent or name)
        write('c4', '\0\0\0\0')
    else
        write('c4', parent)
        write('c4', name)
    end
    if object_version == 3 then
        local data = (output_skin and obj._skin_data or not output_skin and obj._object_data) or {}
        write('i4', #data)
        for _, value in ipairs(data) do
            write('i4', value)
        end
    end
    local extras = extra_modifications(obj)
    write('i4', count + #extras)
    for _, key in ipairs(keys) do
        local data = obj[key]
        if data then
            if metas[key] then
                each_value(data, metas[key], function(level, value)
                    if should_write(obj, metas[key].id, level) then
                        write_value(metas[key], level, obj, value)
                    end
                end)
            end
        end
    end
    for _, modification in ipairs(extras) do
        local id, tp, level, pointer, value, terminal = table.unpack(modification)
        assert(type(id) == 'string' and #id <= 4 and #id > 0 and (tp == 0 or tp == 1 or tp == 2 or tp == 3), 'Invalid preserved object modification.')
        write('c4i4', id .. ('\0'):rep(4 - #id), tp)
        if has_level then
            write('i4i4', level, pointer)
        end
        write_typed_value(tp, obj, id, value)
        write('i4', terminal)
    end
end

local function write_chunk(names, data, n, max)
    local clock = os_clock()
    write('i4', #names)
    for i, name in ipairs(names) do
        write_object(data, name, data[name])
        if os_clock() - clock > 0.1 then
            clock = os_clock()
            w2l.progress((i+n) / max)
            w2l.messager.text(lang.script.CONVERT_FILE:format(ttype, data[name]._id, i+n, max))
        end
    end
end

local function write_head()
    write('i4', object_version)
end

local function is_enable_obj(name, obj, remove_unuse_object)
    if remove_unuse_object and not obj._mark then
        return false
    end
    if #name ~= 4 then
        w2l.messager.report(lang.report.INVALID_OBJECT, 6, ('[%s] %s'):format(name, lang.report.INVALID_OBJECT_ID))
        return false
    end
    if not default[obj._parent] then
        w2l.messager.report(lang.report.INVALID_OBJECT, 6, ('[%s:%s] %s'):format(name, obj._parent, lang.report.INVALID_OBJECT_PARENT))
        return false
    end
    if output_skin then
        return obj._skin_version ~= nil
    end
    if #(obj._object_data or {}) > 0 or #extra_modifications(obj) > 0 then
        return true
    end
    if obj._skin_only then
        local metas = object_metadata(obj)
        for key, meta in pairs(metas) do
            if obj[key] then
                local found = false
                each_value(obj[key], meta, function(level)
                    found = found or should_write(obj, meta.id, level)
                end)
                if found then
                    return true
                end
            end
        end
        return false
    end
    if not obj._slk and obj._id ~= obj._parent then
        return true
    end
    if obj._slk_id then
        return true
    end
    if obj._keep_obj then
        return true
    end
    for key, value in pairs(obj) do
        if key:sub(1, 1) ~= '_' then
            if type(value) == 'table' then
                if next(value) then
                    return true
                end
            else
                return true
            end
        end
    end
    return false
end

local function sort_chunk(chunk, remove_unuse_object)
    local origin = {}
    local user = {}
    for name, obj in pairs(chunk) do
        if is_enable_obj(name, obj, remove_unuse_object) then
            if is_original(name, obj) then
                origin[#origin+1] = name
            else
                user[#user+1] = name
            end
        end
    end
    -- 大写ID的对象必须在小写ID的对象前面，否则同ID单位时，英雄的数据会出错
    table_sort(origin, function (id1, id2)
        return id1 > id2
    end)
    table_sort(user, function (id1, id2)
        return id1 > id2
    end)
    return origin, user
end

return function (w2l_, type, data, wts_, skin)
    w2l = w2l_
    if not data then
        return
    end
    if type == 'misc' then
        return w2l:backend_misc(data)
    end
    wts = wts_
    ttype = type
    has_level = w2l.info.key.max_level[type]
    metadata = w2l:metadata()
    default = w2l:get_default()[type]
    output_skin = not not skin
    skin_lookup = {}
    
    local origin_id, user_id = sort_chunk(data, w2l.setting.remove_unuse_object)
    local max = #origin_id + #user_id
    if max == 0 then
        return
    end
    object_version = 2
    for _, names in ipairs {origin_id, user_id} do
        for _, name in ipairs(names) do
            local obj = data[name]
            local version = output_skin and obj._skin_version or obj._object_version
            if version and version ~= 1 and version ~= 2 and version ~= 3 then
                error(('Unsupported %s object data version %s.'):format(type, tostring(version)))
            end
            if version == 3 then
                object_version = 3
            end
        end
    end
    hexs = {}
    write_head()
    write_chunk(origin_id, data, 0, max)
    write_chunk(user_id, data, #origin_id, max)
    return table_concat(hexs), report
end
