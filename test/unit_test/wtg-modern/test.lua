-- Modern WTG tombstones must not break the category tree, skip surviving
-- variables, or shift surviving custom scripts to another WCT slot.
local w2l = w3x2lni()
local action_name = 'BlzSetHDWaterMinOpacityBJ'

local function use_ui(arg_count)
    local args = {}
    for i = 1, arg_count do args[i] = {type = 'integer'} end
    local state = {ui = {
        event = {}, condition = {}, call = {},
        action = {[action_name] = {name = action_name, args = args}},
    }}
    function w2l:frontend_trg() return state end
end

local function fixture(arg_count)
    local bytes = {}
    local function add(format, ...)
        bytes[#bytes+1] = string.pack('<' .. format, ...)
    end
    add('c4I4I4', 'WTG!', 0x80000004, 7)
    add('I4I4I4I4', 1, 2, 123, 124) -- map count and deleted map IDs
    add('I4I4I4', 0, 1, 199) -- library count and deleted library ID
    add('I4I4I4', 2, 1, 2) -- categories, deleting category 2
    add('I4I4I4', 5, 1, 32) -- triggers, deleting trigger 32
    add('I4I4', 0, 0) -- comments
    add('I4I4', 0, 0) -- standalone scripts
    add('I4I4I4', 4, 1, 16) -- variables, deleting variable 16
    add('I4I4', 0, 0)
    add('i4i4', 2, 4) -- trigger definitions, variable definitions
    local function variable(name, id, category)
        add('zzi4i4i4i4zI4I4', name, 'integer', 1, 0, 1, 1, '42', id, category)
    end
    variable('DeletedVar', 0x06000010, 0x02000001)
    variable('LiveVar', 0x06000011, 0x02000001)
    variable('DeletedChildVar', 0x06000012, 0x02000002)
    variable('RootVar', 0x06000013, 7)

    add('I4I4i4zi4i4i4', 12, 1, 7, 'Modern triggers', 0, 0, -1)
    local function category(name, id)
        add('I4i4zi4i4I4', 4, id, name, 0, 1, 7)
    end
    local function variable_element(name, id, parent)
        add('I4I4zI4', 64, id, name, parent)
    end
    local function trigger(name, id, parent, custom)
        add('I4zzi4I4i4i4i4i4i4i4', 8, name, '', 0, id, 1, custom and 1 or 0, 0, 0, parent, custom and 0 or 1)
        if not custom then
            add('i4zi4', 2, action_name, 1)
            for i = 1, arg_count do
                add('i4zi4i4', 3, tostring(i * 10), 0, 0)
            end
            add('i4', 0) -- child ECAs
        end
    end
    category('Live', 0x02000001)
    variable_element('DeletedVar', 0x06000010, 0x02000001)
    variable_element('LiveVar', 0x06000011, 0x02000001)
    trigger('DeletedTrigger', 0x03000020, 0x02000001, true)
    trigger('LiveTrigger', 0x03000021, 0x02000001, true)
    category('DeletedCategory', 0x02000002)
    variable_element('DeletedChildVar', 0x06000012, 0x02000002)
    trigger('DeletedChildTrigger', 0x03000022, 0x02000002, true)
    trigger('RootTrigger', 0x03000023, 7, true)
    variable_element('RootVar', 0x06000013, 7)
    trigger('RootGuiTrigger', 0x03000024, 7, false)
    return table.concat(bytes)
end

local function wct_fixture()
    local chunks = {string.pack('<I4I4z', 0x80000004, 1, 'Map script comment')}
    local function code(text)
        chunks[#chunks+1] = string.pack('<I4', #text > 0 and #text + 1 or 0)
        if #text > 0 then chunks[#chunks+1] = text .. '\0' end
    end
    code('-- map code')
    code('-- deleted code')
    code('-- live code')
    code('-- deleted category code')
    code('-- root code')
    code('')
    return table.concat(chunks)
end

for _, arg_count in ipairs {1, 2} do
    -- The second UI definition deliberately changes an existing action's
    -- signature, as changing installed trigger data can do between maps.
    use_ui(arg_count)
    local binary = fixture(arg_count)
    local triggers = w2l:frontend_wtg(binary)
    local custom = w2l:frontend_wct(wct_fixture())
    assert(#triggers.categories == 1 and triggers.categories[1].name == 'Live')
    assert(#triggers.vars == 2 and triggers.vars[1][1] == 'LiveVar' and triggers.vars[2][1] == 'RootVar')
    assert(#triggers.triggers == 3)
    assert(triggers.triggers[1].name == 'LiveTrigger' and triggers.triggers[1].wct_index == 2)
    assert(triggers.triggers[2].name == 'RootTrigger' and triggers.triggers[2].wct_index == 4)
    assert(triggers.deleted_maps[2] == 124 and triggers.deleted_libraries[1] == 199)

    local files = w2l:backend_lml(triggers, custom)
    local scripts = {}
    for name, content in pairs(files) do
        assert(not name:find('Deleted', 1, true))
        if name:sub(-2) == '.j' then scripts[content] = true end
    end
    assert(scripts['-- live code'] and scripts['-- root code'] and scripts['-- map code'])
    assert(not scripts['-- deleted code'] and not scripts['-- deleted category code'])
    local rebuilt, rebuilt_custom = w2l:frontend_lml(function(name) return files[name] end)
    local serialized = w2l:backend_wtg(rebuilt)
    local parsed = w2l:frontend_wtg(serialized)
    assert(parsed.unknown8 == 7)
    assert(#parsed.categories == 1 and #parsed.vars == 2 and #parsed.triggers == 3)
    assert(parsed.deleted_maps[1] == 123 and parsed.deleted_libraries[1] == 199)
    local custom_binary = w2l:backend_wct(rebuilt_custom)
    local custom_parsed = w2l:frontend_wct(custom_binary)
    assert(custom_parsed.triggers[1] == '-- live code')
    assert(custom_parsed.triggers[2] == '-- root code')
    assert(custom_parsed.triggers[3] == '')
    assert(custom_binary == w2l:backend_wct(custom_parsed))

    local ok, err = pcall(w2l.frontend_wtg, w2l, binary .. '\x01')
    assert(not ok and tostring(err):find('Unparsed war3map.wtg', 1, true))
end

local legacy_wct = string.pack('<I4zi4i4', 1, '', 0, 0)
local ok, err = pcall(w2l.frontend_wct, w2l, legacy_wct .. '\x01')
assert(not ok and tostring(err):find('Unparsed war3map.wct', 1, true))

local bad_terminator = string.pack('<I4zI4', 1, '', 4) .. 'code'
ok, err = pcall(w2l.frontend_wct, w2l, bad_terminator)
assert(not ok and tostring(err):find('Invalid WCT code terminator', 1, true))
