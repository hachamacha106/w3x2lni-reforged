local lang = require 'lang'
local wct
local unpack_index
local chunk

local function unpack(fmt)
    local result
    result, unpack_index = ('<' .. fmt):unpack(wct, unpack_index)
    return result
end

local function read_head()
    local ver = unpack 'I4'
    if ver > 1 then
        assert(ver == 0x80000004, lang.script.UNSUPPORTED_WCT)
        chunk.format_version = ver
        ver = unpack 'I4'
    end
    assert(ver == 1, lang.script.UNSUPPORTED_WCT)
end

local function read_code()
    local size = unpack 'I4'
    if size == 0 then
        return ''
    end
    local code = unpack('c' .. (size - 1))
    assert(unpack 'c1' == '\0', 'Invalid WCT code terminator')
    return code
end

local function read_custom()
    chunk.custom = {}
    chunk.custom.comment = unpack 'z'
    chunk.custom.code = read_code()
end

local function read_triggers()
    chunk.triggers = {}
    local count = unpack 'i4'
    assert(count >= 0, 'Invalid WCT trigger count')
    for i = 1, count do
        chunk.triggers[i] = read_code()
    end
end

local function read_triggers_new()
    chunk.triggers = {}
    while unpack_index <= #wct do
        chunk.triggers[#chunk.triggers+1] = read_code()
    end
end

return function (w2l, wct_)
    wct = wct_
    unpack_index = 1
    chunk = {}

    read_head()
    read_custom()
    if chunk.format_version then
        read_triggers_new()
    else
        read_triggers()
    end

    assert(unpack_index == #wct + 1, 'Unparsed war3map.wct data')

    return chunk
end
