-- Synthetic format fixtures, independently encoded from the reader/writer.
-- Layout verified against War3Net 18e88f0e1f67e6b16870dcbcd827740275fe2173:
-- src/War3Net.Build.Core/Serialization/Binary/Object/*ObjectModification.cs.
-- Run: W2L_TEST_RUNTIME=/path/to/runtime lua /absolute/path/to/this/file.lua
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/object_formats.lua$'))
local boot = dofile(root .. '/test/compat/bootstrap.lua')
local core = boot.core()
local count = 0
local function test(name, fn)
    fn()
    count = count + 1
    print('PASS object formats: ' .. name)
end

local level_types = { ability = true, doodad = true, upgrade = true }
local function modification(kind, field, value_type, value, level, pointer, terminal)
    local buffer = string.pack('<c4i4', field, value_type)
    if level_types[kind] then
        buffer = buffer .. string.pack('<i4i4', level or 0, pointer or 0)
    end
    if value_type == 0 then
        buffer = buffer .. string.pack('<i4', value)
    elseif value_type == 1 or value_type == 2 then
        buffer = buffer .. string.pack('<f', value)
    else
        buffer = buffer .. string.pack('<z', value)
    end
    return buffer .. string.pack('<i4', terminal or 0)
end

local function object(version, parent, id, extra, modifications)
    local buffer = string.pack('<c4c4', parent, id or '\0\0\0\0')
    if version == 3 then
        buffer = buffer .. string.pack('<i4', #extra)
        for _, value in ipairs(extra) do
            buffer = buffer .. string.pack('<i4', value)
        end
    end
    return buffer .. string.pack('<i4', #modifications) .. table.concat(modifications)
end

local function objects(version, original, custom)
    return string.pack('<i4i4', version, #original) .. table.concat(original)
        .. string.pack('<i4', #custom) .. table.concat(custom)
end

local function new_w2l(mode, files, data)
    local w2l = core()
    local storage = {}
    for key, value in pairs(files or {}) do
        storage[key:lower()] = value
    end
    w2l:set_setting {
        mode = mode,
        data = data or 'enUS-1.27.1', data_meta = data or 'enUS-1.27.1', data_wes = '${DEFAULT}',
        version = 'Custom', read_slk = true, remove_same = true,
        remove_unuse_object = false, optimize_jass = false,
        remove_we_only = true, computed_text = false,
        slk_doodad = true, extra_check = false,
    }
    w2l:set_messager(function() end)
    function w2l:file_load(kind, name) return storage[(kind .. '/' .. name):lower()] end
    function w2l:file_save(kind, name, value) storage[(kind .. '/' .. name):lower()] = value end
    function w2l:file_remove(kind, name) storage[(kind .. '/' .. name):lower()] = nil end
    return w2l, storage
end

test('versions 1, 2 and 3, all seven object kinds', function()
    local w2l = new_w2l('obj')
    for _, version in ipairs {1, 2, 3} do
        for _, kind in ipairs {'unit', 'item', 'buff', 'destructable', 'doodad', 'ability', 'upgrade'} do
            local fields = {
                modification(kind, 'I000', 0, -42, 2, 7),
                modification(kind, 'R000', 1, 1.25, 3, 8),
                modification(kind, 'U000', 2, 0.5, 1, 9),
                modification(kind, 'S000', 3, 'a string', 0, 10),
            }
            local fixture = objects(version,
                {object(version, 'hfoo', nil, {-2147483648, 2147483647, 17}, fields)},
                {object(version, 'hfoo', 'H000', {}, fields)})
            local parsed = w2l:frontend_obj(kind, fixture)
            assert(parsed.hfoo.I000[level_types[kind] and 2 or 1] == -42)
            assert(tonumber(parsed.H000.R000[level_types[kind] and 3 or 1]) == 1.25)
            assert(tonumber(parsed.H000.U000[1]) == 0.5)
            assert(parsed.H000.S000[1] == 'a string')
            if version == 3 then
                assert(parsed.hfoo._object_data[1] == -2147483648)
                assert(parsed.hfoo._object_data[2] == 2147483647)
                assert(#parsed.H000._object_data == 0)
            end
        end
    end
end)

test('unknown versions and truncated v3 headers fail explicitly', function()
    local w2l = new_w2l('obj')
    local ok, err = pcall(w2l.frontend_obj, w2l, 'unit', objects(99, {}, {}))
    assert(not ok and err:find('Unsupported unit object data version 99', 1, true))
    ok = pcall(w2l.frontend_obj, w2l, 'unit', string.pack('<i4i4c4c4i4', 3, 1, 'hfoo', 'H000', 100))
    assert(not ok)
end)

test('v2 payload-free garbage remains readable', function()
    local w2l = new_w2l('obj')
    local fixture = assert(io.load(root .. '/test/unit_test/忽略垃圾数据/war3map_with_garbage.w3a'))
    assert(w2l:frontend_obj('ability', fixture))
end)

local original_files = {
    ['map/war3map.wts'] = 'STRING 1\n{\nSkin name\n}\nSTRING 2\n{\nUnknown\nmultiline value\n}\n',
    ['map/war3map.w3u'] = objects(3, {}, {
        object(3, 'hfoo', 'H000', {-2147483648, 17, 2147483647}, {
            modification('unit', 'uhpm', 0, 707),
            modification('unit', 'unam', 3, 'Main-file name'),
            modification('unit', 'zZ99', 3, 'TRIGSTR_002'),
        }),
    }),
    ['map/war3mapskin.w3u'] = objects(3, {
        -- An original skin record may target the main file's custom ID.
        object(3, 'H000', nil, {2, -8}, {
            modification('unit', 'unam', 3, 'TRIGSTR_001'),
            modification('unit', 'umdl', 3, 'Units\\Human\\Knight\\Knight.mdl'),
        }),
    }, {
        object(3, 'hfoo', 'H001', {}, {
            modification('unit', 'unam', 3, 'Skin-only unit'),
        }),
    }),
    ['map/war3map.w3a'] = objects(3, {}, {
        object(3, 'AHbz', 'A000', {5}, {
            modification('ability', 'alev', 0, 3),
            modification('ability', 'Hbz1', 0, 12, 2, 1),
            modification('ability', 'zZ99', 3, 'TRIGSTR_002', 7, 19, 0x12345678),
        }),
    }),
    ['map/war3mapskin.w3a'] = objects(3, {}, {
        object(3, 'AHbz', 'A000', {6}, {
            modification('ability', 'Hbz1', 0, 20, 3, 1),
            modification('ability', 'zZ98', 1, 0.125, 5, 27, 0x12345678),
        }),
    }),
}

local lni_files
test('split skins, WTS strings and opaque records survive W3X to LNI', function()
    local w2l, storage = new_w2l('lni', original_files)
    w2l:frontend()
    assert(w2l.slk.unit.H000.hp == 707)
    assert(w2l.slk.unit.H000.name == 'Skin name')
    assert(w2l.slk.unit.H000._parent == 'hfoo')
    assert(w2l.slk.unit.H001.name == 'Skin-only unit')
    assert(w2l.slk.unit.H000._object_extras[1][5] == 'Main-file name')
    w2l:backend()
    assert(not storage['map/war3mapskin.w3u'])
    assert(storage['table/unit']:find('_object_data = {%-2147483648, 17, 2147483647}'))
    local parsed = w2l:parse_lni(storage['table/unit'], 'unit')
    assert(parsed.H000._skin_parent == 'H000')
    assert(parsed.H000._skin_original == true)
    assert(parsed.H000._object_extras[2][5] == 'Unknown\nmultiline value')
    lni_files = storage
end)

local function check_rebuilt(w2l, storage)
    local base = w2l:frontend_obj('unit', assert(storage['map/war3map.w3u']))
    local skin = w2l:frontend_obj('unit', assert(storage['map/war3mapskin.w3u']))
    assert(base.H000.uhpm[1] == 707)
    assert(base.H000.unam[1] == 'Main-file name')
    assert(base.H000.zZ99[1] == 'Unknown\nmultiline value')
    assert(base.H000._object_version == 3)
    assert(base.H000._object_data[1] == -2147483648)
    assert(base.H000._object_data[3] == 2147483647)
    assert(not base.H001)
    assert(skin.H000._parent == 'H000')
    assert(skin.H000._object_original)
    assert(skin.H000.unam[1] == 'Skin name')
    assert(skin.H000.umdl[1] == 'Units\\Human\\Knight\\Knight.mdl')
    assert(skin.H000._object_data[2] == -8)
    assert(skin.H001._parent == 'hfoo')
    assert(skin.H001.unam[1] == 'Skin-only unit')
    local ability = w2l:frontend_obj('ability', assert(storage['map/war3map.w3a']))
    assert(ability.A000.Hbz1[2] == 12)
    local found
    for _, record in ipairs(ability.A000._object_modifications) do
        if record[1] == 'zZ99' then
            assert(record[3] == 7 and record[4] == 19)
            assert(record[5] == 'Unknown\nmultiline value')
            assert(record[6] == 0x12345678)
            found = true
        end
    end
    assert(found)
    local ability_skin = w2l:frontend_obj('ability', assert(storage['map/war3mapskin.w3a']))
    assert(ability_skin.A000.Hbz1[3] == 20)
    assert(not ability_skin.A000.Hbz1[2])
    assert(tonumber(ability_skin.A000.zZ98[5]) == 0.125)
    assert(ability_skin.A000._object_data[1] == 6)
    assert(ability_skin.A000._object_modifications[2][4] == 27)
end

test('LNI to OBJ preserves both split files and their original headers', function()
    local w2l, storage = new_w2l('obj', lni_files)
    w2l:frontend()
    w2l:backend()
    check_rebuilt(w2l, storage)
end)

test('LNI to SLK retains objects with skins or opaque format data', function()
    local w2l, storage = new_w2l('slk', lni_files)
    w2l:frontend()
    w2l:backend()
    check_rebuilt(w2l, storage)
    assert(storage['map/units\\unitdata.slk'])
end)

test('explicit skin defaults keep precedence over main-file values', function()
    local w2l, storage = new_w2l('obj', {
        ['map/war3map.w3u'] = objects(3, {}, {
            object(3, 'hfoo', 'H000', {}, {modification('unit', 'uhpm', 0, 900)}),
        }),
        ['map/war3mapskin.w3u'] = objects(3, {}, {
            object(3, 'hfoo', 'H000', {}, {modification('unit', 'uhpm', 0, 420)}),
        }),
    })
    -- Use the selected game data's exact stock value rather than assuming it.
    local stock = w2l:get_default().unit.hfoo.hp
    storage['map/war3mapskin.w3u'] = objects(3, {}, {
        object(3, 'hfoo', 'H000', {}, {modification('unit', 'uhpm', 0, stock)}),
    })
    w2l:frontend()
    w2l:backend()
    local base = w2l:frontend_obj('unit', storage['map/war3map.w3u'])
    local skin = w2l:frontend_obj('unit', storage['map/war3mapskin.w3u'])
    assert(base.H000.uhpm[1] == 900)
    assert(skin.H000.uhpm[1] == stock)
end)

test('editing a skin field in LNI changes its skin-file value', function()
    local files = {}
    for key, value in pairs(lni_files) do files[key] = value end
    files['table/unit'] = files['table/unit']:gsub('Skin name', 'Edited skin name')
    local w2l, storage = new_w2l('obj', files)
    w2l:frontend()
    w2l:backend()
    local skin = w2l:frontend_obj('unit', storage['map/war3mapskin.w3u'])
    local base = w2l:frontend_obj('unit', storage['map/war3map.w3u'])
    assert(skin.H000.unam[1] == 'Edited skin name')
    assert(base.H000.unam[1] == 'Main-file name')
end)

test('different SD artwork and unknown profile variants survive cleanup', function()
    local w2l, storage = new_w2l('lni', {
        ['table/unit'] = '[H000]\n_parent="hfoo"\nArt="Base.blp"\n"Art:hd"="Base.blp"\n"Art:sd"="Classic.blp"\n',
        ['table/txt'] = '[h000]\n"art:de"={"Definitive.blp"}\n',
    }, 'zhCN-1.32.8')
    w2l:frontend()
    w2l:backend()
    local unit = w2l:parse_lni(storage['table/unit'], 'unit')
    assert(unit.H000['Art:sd'] == 'Classic.blp')
    local txt = w2l:parse_lni(storage['table/txt'], 'txt')
    assert(txt.h000['art:de'] == 'Definitive.blp')
end)

print(('Object format compatibility tests passed: %d'):format(count))
