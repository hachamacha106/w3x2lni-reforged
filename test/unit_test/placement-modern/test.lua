local lang = require 'share.lang'

local function fixture(version, skinned)
    local bytes = {}
    local function add(format, ...)
        bytes[#bytes+1] = string.pack('<' .. format, ...)
    end
    add('c4I4I4I4', 'W3do', version, version == 7 and 9 or 11, 2)
    for i = 1, 2 do
        add('c4I4fffffff', i == 1 and 'B000' or 'D000', 2, 128, 256, 0, 0.25, 1, 1, 1)
        if skinned then
            add('c4', i == 1 and 'B001' or 'D001')
        end
        if version >= 13 then
            add('I4', 777)
        end
        add('BB', 2, 100)
        if version >= 8 then
            add('i4I4', -1, i == 1 and 1 or 0)
            if i == 1 then
                add('I4c4I4', 1, 'I001', 100)
            end
        end
        if version >= 13 then
            add('I4', 0xDEADBEEF)
        end
        add('I4', i + 12)
        if version >= 13 then
            add('ffI4', 0.125, 0.375, i == 1 and 1 or 0)
            if i == 1 then
                add('I4I4BBBBffffff', 3, 1, 255, 128, 64, 255, 1, 100, 1000, 0.01, 0.1, 0.8)
            end
        end
    end
    add('I4I4c4I4I4I4', 0, 1, 'DT00', 2, 20, 30)
    return table.concat(bytes)
end

local function context(files, skinned)
    local w2l = w3x2lni()
    w2l.slk = {w3i = {
        [lang.w3i.MAP] = {
            [lang.w3i.FILE_VERSION] = skinned and 39 or 25,
            [lang.w3i.WAR3_VERSION] = skinned and {3, 0, 1, 24342} or nil,
        },
    }}
    function w2l:file_load(_, name) return files[name:lower()] end
    return w2l
end

for _, pair in ipairs {{7, false}, {8, false}, {8, true}, {13, true}} do
    local version, skinned = pair[1], pair[2]
    local binary = fixture(version, skinned)
    local files = {['war3map.doo'] = binary}
    local w2l = context(files, skinned)
    for _, with_metadata in ipairs {true, false} do
        if not with_metadata then w2l.slk.w3i = nil end
        local destructable, doodad, items, err = w2l:backend_searchdoo()
        assert(not err, err)
        assert(destructable.B000 and destructable.D000 and doodad.DT00)
        assert(not skinned or destructable.B001 and destructable.D001)
        assert(version < 8 or items.I001)
        assert(files['war3map.doo'] == binary)
    end
end

local function objects()
    local slk = {}
    local ids = {
        ability = {'A001'}, buff = {'Bf01'}, unit = {'h001', 'h002'},
        item = {'I001', 'I002'}, upgrade = {'R001'},
        destructable = {'B000', 'B001'}, doodad = {'D000', 'D001', 'DT00'},
        misc = {'CustomMisc'}, txt = {'customtxt'},
    }
    for type, list in pairs(ids) do
        slk[type] = {}
        for _, id in ipairs(list) do
            slk[type][id] = {_type = type, _id = id, name = type == 'upgrade' and {id} or id}
        end
    end
    slk.item.I001.pickrandom = 0
    slk.item.I002.pickrandom = 1
    return slk
end

local jass = "function main takes nothing returns nothing\ncall CreateUnit(Player(0), 'h001', 0, 0, 0)\nendfunction"

local function mark(files, opaque_key)
    local w2l = context(files, true)
    local info = w2l.slk.w3i
    local slk = objects()
    if opaque_key then
        slk.unit.h001[opaque_key] = {string.unpack('>I4', 'h002')}
    end
    slk.w3i = info
    w2l.slk = slk
    function w2l:data_load() return '' end
    function w2l:call_plugin() return nil end
    local warnings = {}
    w2l.messager = {report = function(_, _, message) warnings[message] = true end}
    w2l:backend_mark(slk)
    return slk, warnings
end

local good_doo = fixture(13, true)
local slk = mark {['war3map.j'] = jass, ['war3map.doo'] = good_doo}
assert(slk.unit.h001._mark and not slk.unit.h002._mark)
assert(slk.destructable.B000._mark and slk.destructable.B001._mark)
assert(slk.doodad.D000._mark and slk.doodad.D001._mark and slk.doodad.DT00._mark)
assert(slk.item.I001._mark and not slk.item.I002._mark)

-- New filtered selection keeps eligible random items; the includes variants
-- can also return items excluded by pickrandom. Other object pruning still works.
for _, selection in ipairs {
    {'ChooseRandomItem', '1'},
    {'ChooseRandomItemExBJ', '1, ITEM_TYPE_ANY'},
    {'ChooseRandomItemExWithFilter', 'ITEM_TYPE_ANY, 1, EQUIPMENT_TYPE_ANY, ITEMTAG_TYPE_ANY'},
    {'ChooseRandomItemExWithFilterBJ', '1, ITEM_TYPE_ANY, EQUIPMENT_TYPE_ANY, ITEMTAG_TYPE_ANY'},
    {'ChooseRandomItemExWithFilterAndIncludes', 'ITEM_TYPE_ANY, 1, EQUIPMENT_TYPE_ANY, ITEMTAG_TYPE_ANY, true, true', true},
    {'ChooseRandomItemExWithFilterAndIncludesBJ', '1, ITEM_TYPE_ANY, EQUIPMENT_TYPE_ANY, ITEMTAG_TYPE_ANY, true, true', true},
} do
    local body = ("function main takes nothing returns nothing\nlocal integer choice = %s(%s)\ncall CreateUnit(Player(0), 'h001', 0, 0, 0)\nendfunction"):format(selection[1], selection[2])
    local data, warnings = mark {['war3map.j'] = body}
    assert(data.item.I002._mark, selection[1] .. ' pruned an eligible item')
    assert(not not data.item.I001._mark == not not selection[3], selection[1] .. ' mishandled pickrandom = 0')
    assert(data.unit.h001._mark and not data.unit.h002._mark)
    assert(not warnings[lang.report.RETAIN_UNKNOWN_SCRIPT])
    assert(warnings[selection[3] and lang.report.RETAIN_ALL_ITEMS or lang.report.RETAIN_RANDOM_ITEM])
end

local function all_retained(slk)
    for _, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade', 'destructable', 'doodad', 'misc', 'txt'} do
        for id, object in pairs(slk[type]) do
            assert(object._mark, type .. ' ' .. id .. ' was incorrectly pruned')
        end
    end
end

for _, binary in ipairs {
    'W3do' .. string.pack('<I4', 14) .. good_doo:sub(9),
    good_doo:sub(1, -4),
    good_doo .. '\x01',
} do
    local data, warnings = mark {['war3map.j'] = jass, ['war3map.doo'] = binary}
    all_retained(data)
    assert(warnings[lang.report.RETAIN_UNKNOWN_DOO])
end

for _, scripts in ipairs {
    {['war3map.lua'] = 'local name = "h" .. "002"; CreateUnit(Player(0), FourCC(name), 0, 0, 0)'},
    {['scripts\\war3map.lua'] = 'CreateUnit(Player(0), FourCC("h002"), 0, 0, 0)'},
    {},
    {['war3map.j'] = '@invalid-jass'},
    {['war3map.j'] = 'call CreateUnit(Player(0), BlzS2FourCC("h002"), 0, 0, 0)'},
    {['war3map.j'] = 'call CreateUnit(Player(0), FourCC("h002"), 0, 0, 0)'},
} do
    scripts['war3map.doo'] = good_doo
    local data, warnings = mark(scripts)
    all_retained(data)
    assert(warnings[lang.report.RETAIN_UNKNOWN_SCRIPT])
end

for _, key in ipairs {'_object_extras', '_skin_extras', '_object_data', '_skin_data'} do
    local data, warnings = mark({['war3map.j'] = jass, ['war3map.doo'] = good_doo}, key)
    all_retained(data)
    assert(warnings[lang.report.RETAIN_UNKNOWN_OBJECT_REFERENCES])
end
