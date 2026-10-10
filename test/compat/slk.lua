local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local directory = source:match('^(.*)/[^/]+$')
local context = dofile(directory .. '/bootstrap.lua')
local core = context.core()
local schema = require 'core.slk.schema'
local parser = require 'w3xparser'

local function read(path)
    return assert(io.load(context.root .. '/' .. path))
end

local current = 'data/warcraft-current/mpq/'
local ability_titles = schema.titles(read(current .. 'units/abilitydata.slk'))
local ability_columns = schema.columns(ability_titles)
assert(ability_columns.cool5 and ability_columns.cool6)
assert(ability_columns.datat6)
assert(not schema.columns(schema.titles(read(current .. 'units/unitui.slk'))).file)
assert(not schema.columns(schema.titles(read(current .. 'units/itemdata.slk'))).file)

local types = {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable', 'misc'}
local function converter()
    local w2l = core()
    w2l.cache_metadata = {}
    w2l.cache_keydata = {}
    w2l.cache_slktitle = {}
    local defaults = {}
    for _, name in ipairs(types) do
        w2l.cache_metadata[name] = {}
        w2l.cache_keydata[name] = {}
        defaults[name] = {}
    end
    w2l.setting.remove_unuse_object = false
    w2l.setting.slk_doodad = true
    function w2l:get_default() return defaults end
    function w2l:isreforge() return false end
    return w2l
end

local filename = 'units\\abilitydata.slk'
local function ability_converter(titles)
    local w2l = converter()
    w2l.cache_metadata.ability = {
        cool = {id = 'acdn', field = 'Cool', key = 'Cool', type = 2, ['repeat'] = 4},
        targs = {id = 'atar', field = 'targs', key = 'targs', type = 3, ['repeat'] = 4},
        levels = {id = 'alev', field = 'levels', key = 'levels', type = 0},
    }
    w2l.cache_metadata.A000 = {
        datat = {id = 'T001', field = 'DataT', key = 'Data', type = 1, ['repeat'] = 4},
    }
    w2l.cache_keydata[filename] = {'cool', 'targs', 'levels'}
    w2l.cache_slktitle[filename] = titles
    return w2l
end

local function export_ability(w2l)
    local input = {
        A000 = {
            _id = 'A000', _code = 'A000', _type = 'ability', _parent = 'A000',
            levels = 7, cool = {1, 2, 3, 4, 5, 6, 7},
            targs = {'air', 'ground', '', '', '', ''},
            datat = {10, 11, 12, 13, 14, 15, 16},
        },
    }
    local remainder = {}
    local output = w2l:backend_slk('ability', filename, input, {n = 0}, remainder, {ability = input})
    return output, remainder.A000
end

local modern = ability_converter(ability_titles)
local modern_buffer, modern_remainder = export_ability(modern)
local row = parser.slk(modern_buffer).A000
assert(row.Cool5 == 5 and row.Cool6 == 6)
assert(row.DataT5 == 14 and row.DataT6 == 15)
assert(row.targs5 == '_' and row.targs6 == '_')
assert(modern_remainder.cool[5] == nil and modern_remainder.cool[6] == nil)
assert(modern_remainder.cool[7] == 7 and modern_remainder.datat[7] == 16)
local modern_read = modern:frontend_slk(function(path)
    if path == filename then return modern_buffer end
    return path:match '%.slk$' and 'ID;PWXL;N;E\r\nB;X1;Y1;D0\r\nC;X1;Y1;K"id"\r\nE' or ''
end)
assert(#modern_read.ability.A000.cool == 6)
assert(modern_read.ability.A000.cool[6] == 6)
assert(modern_read.ability.A000.datat[6] == 15)

local classic_titles = {'alias', 'code', 'levels'}
for i = 1, 4 do
    classic_titles[#classic_titles + 1] = 'Cool' .. i
    classic_titles[#classic_titles + 1] = 'targs' .. i
end
local classic = ability_converter(classic_titles)
local classic_buffer, classic_remainder = export_ability(classic)
assert(not schema.columns(schema.titles(classic_buffer)).cool5)
assert(classic_remainder.cool[5] == 5 and classic_remainder.cool[6] == 6)
assert(classic_remainder.datat[1] == 10 and classic_remainder.datat[6] == 15)
local classic_read = classic:frontend_slk(function(path)
    if path == filename then return classic_buffer end
    return path:match '%.slk$' and 'ID;PWXL;N;E\r\nB;X1;Y1;D0\r\nC;X1;Y1;K"id"\r\nE' or ''
end)
assert(#classic_read.ability.A000.cool == 4)
assert(classic_read.ability.A000.cool[4] == 4)

local profiles = converter()
function profiles:isreforge() return true end
local function field(kind, key, output_field, index, tp, reforge)
    profiles.cache_metadata[kind][key] = {
        key = output_field:lower(), field = output_field, type = tp,
        index = index, profile = true, reforge = reforge,
    }
    if index then
        local base, suffix = output_field:match '^([^:]+)(.*)$'
        profiles.cache_metadata[kind][key].field = base .. '_' .. index .. suffix
    end
    table.insert(profiles.cache_keydata[kind], key)
end
field('unit', 'name', 'Name', nil, 3)
for i = 1, 3 do
    field('unit', 'file_' .. i, 'file', i, 3)
    field('unit', 'file_' .. i .. ':hd', 'file:hd', i, 3, 'file_' .. i)
end
field('item', 'file', 'file', nil, 3)
field('ability', 'buttonpos_1', 'Buttonpos', 1, 0)
field('ability', 'buttonpos_2', 'Buttonpos', 2, 0)
field('ability', 'buttonpos_1:hd', 'Buttonpos:hd', 1, 0, 'buttonpos_1')
field('ability', 'buttonpos_2:hd', 'Buttonpos:hd', 2, 0, 'buttonpos_2')
profiles.cache_keydata['units\\unitskin.txt'] = {'file', 'file:hd', 'file:de'}
profiles.cache_keydata['units\\itemskin.txt'] = {'file'}
local slk, object = {txt = {}}, {}
for _, kind in ipairs(types) do
    slk[kind], object[kind] = {}, {}
end
slk.unit.U000 = {
    _id = 'U000', name = 'Three models', file_1 = 'base.mdl', file_2 = 'alternate.mdl',
    file_3 = 'third.mdl', ['file_2:hd'] = 'alternate-hd.mdl',
}
slk.item.I000 = {_id = 'I000', file = 'item.mdl'}
slk.ability.A000 = {
    _id = 'A000', buttonpos_1 = 0, buttonpos_2 = -11,
    ['buttonpos_2:hd'] = -12,
}
slk.txt.u000 = {['file:de'] = {'enhanced.mdl'}}
object.unit.U000, object.item.I000, object.ability.A000 = {}, {}, {}
local text, skins = profiles:backend_txt(slk, {n = 0}, object)
local unit_skin = parser.txt(skins['units\\unitskin.txt']).u000
local item_skin = parser.txt(skins['units\\itemskin.txt']).i000
local ability_text = parser.txt(text.ability).a000
assert(unit_skin.file[1] == 'base.mdl' and unit_skin.file[2] == 'alternate.mdl')
assert(unit_skin.file[3] == 'third.mdl')
assert(unit_skin['file:hd'][1] == 'base.mdl')
assert(unit_skin['file:hd'][2] == 'alternate-hd.mdl')
assert(unit_skin['file:hd'][3] == 'third.mdl')
assert(unit_skin['file:de'][1] == 'enhanced.mdl')
assert(item_skin.file[1] == 'item.mdl')
assert(not text.unit:find('\r\nfile=', 1, true))
assert(text.ability:find('Buttonpos=0,-11', 1, true))
assert(text.ability:find('Buttonpos:hd=0,-12', 1, true))
assert(ability_text.buttonpos[1] == '0' and ability_text.buttonpos[2] == '-11')

profiles.cache_keydata['units\\unitskin.txt'] = nil
profiles.cache_keydata['units\\itemskin.txt'] = nil
function profiles:isreforge() return false end
local legacy_text, legacy_skins = profiles:backend_txt(slk, {n = 0}, object)
assert(next(legacy_skins) == nil)
assert(parser.txt(legacy_text.unit).u000.file[3] == 'third.mdl')
assert(parser.txt(legacy_text.item).i000.file[1] == 'item.mdl')

print('PASS: SLK schema, six levels, DataT, classic overflow, skin routing, three model slots, graphics variants, and zero button coordinates')


-- Rawcodes are exact four-byte identifiers. Only native TXT section storage
-- folds their casing, so SLK output must keep affected values in binary data.
local lang = require 'share.lang'
local empty_objects = string.pack('<i4i4i4', 2, 0, 0)
local function string_modification(field, value)
    return string.pack('<c4i4zi4', field, 3, value, 0)
end
local function unit_record(id, name, hp)
    return string.pack('<c4c4i4', 'hfoo', id, 2)
        .. string_modification('unam', name)
        .. string.pack('<c4i4i4i4', 'uhpm', 0, hp, 0)
end
local case_units = string.pack('<i4i4i4', 2, 0, 2)
    .. unit_record('H0BC', 'Upper-case rawcode unit', 707)
    .. unit_record('h0BC', 'Lower-case rawcode unit', 808)
local shared_profile_buff = string.pack('<i4i4c4c4i4', 2, 1, 'Brpb', '\0\0\0\0', 1)
    .. string_modification('ftip', 'Buff-specific Replenish') .. string.pack('<i4', 0)
local shared_profile_item = string.pack('<i4i4i4c4c4i4', 2, 0, 1, 'ratf', 'brpb', 2)
    .. string_modification('unam', 'Item-specific plated boots')
    .. string_modification('utip', 'Item-specific tooltip')

local function rawcode_converter(mode, dataset, input)
    local w2l, storage, diagnostics = core(), {}, {}
    for name, value in pairs(input) do storage[name:lower()] = value end
    w2l:set_setting {
        mode = mode, data = dataset, data_meta = dataset, data_wes = '${DEFAULT}',
        version = 'Custom', read_slk = true, remove_same = true,
        remove_unuse_object = false, optimize_jass = false,
        remove_we_only = true, computed_text = false,
        slk_doodad = true, extra_check = false,
    }
    w2l:set_messager(function(kind, ...)
        if kind == 'report' then diagnostics[#diagnostics + 1] = {...} end
    end)
    function w2l:file_load(kind, name) return storage[(kind .. '/' .. name):lower()] end
    function w2l:file_save(kind, name, value) storage[(kind .. '/' .. name):lower()] = value end
    function w2l:file_remove(kind, name) storage[(kind .. '/' .. name):lower()] = nil end
    return w2l, storage, diagnostics
end

local function object_records(w2l, storage, kind)
    return w2l:frontend_obj(kind, storage[('map/' .. w2l.info.obj[kind]):lower()] or empty_objects)
end
local function binary_output(w2l, storage, mode, dataset)
    if mode == 'lni' then
        local rebuilt, files = rawcode_converter('obj', dataset, storage)
        rebuilt:frontend()
        rebuilt:backend()
        return rebuilt, files
    end
    return w2l, storage
end
local function collision_diagnostic(diagnostics, key, id1, id2)
    local template = assert(lang.report[key], 'Missing collision diagnostic: ' .. key)
    local prefix = assert(template:match('^([^%%]+)'), 'Collision diagnostic needs a readable prefix')
    for _, diagnostic in ipairs(diagnostics) do
        local message = diagnostic[3] or ''
        local detail = diagnostic[4] or ''
        if message:sub(1, #prefix) == prefix
            and (message .. detail):find(id1, 1, true)
            and (message .. detail):find(id2, 1, true) then
            assert(diagnostic[1] == lang.report.WARN and diagnostic[2] == 2,
                'Storage-collision diagnostics must retain warning severity')
            return true
        end
    end
    return false
end

for _, dataset in ipairs {'enUS-1.27.1', 'warcraft-current'} do
    for _, mode in ipairs {'lni', 'obj', 'slk'} do
        local w2l, storage, diagnostics = rawcode_converter(mode, dataset, {
            ['map/war3map.w3u'] = case_units,
        })
        w2l:frontend()
        if mode == 'slk' then
            assert(w2l.slk.unit.H0BC._keep_obj and w2l.slk.unit.h0BC._keep_obj,
                'Both case-distinct rawcodes must use binary object fallback')
        end
        w2l:backend()
        local output, files = binary_output(w2l, storage, mode, dataset)
        local units = object_records(output, files, 'unit')
        assert(units.H0BC and units.h0BC, 'A case-distinct rawcode was renamed or lost')
        assert(units.H0BC.unam[1] == 'Upper-case rawcode unit' and units.H0BC.uhpm[1] == 707)
        assert(units.h0BC.unam[1] == 'Lower-case rawcode unit' and units.h0BC.uhpm[1] == 808)
        local warned = collision_diagnostic(diagnostics, 'CASE_ONLY_ID_COLLISION', 'H0BC', 'h0BC')
        assert(warned == (mode == 'slk'), 'Case-storage diagnostic must apply only to SLK output')
        if mode == 'slk' then
            for _, filename in ipairs(w2l.info.slk.unit) do
                local rows = parser.slk(storage[('map/' .. filename):lower()])
                assert(not rows.H0BC and not rows.h0BC, 'Case-distinct binary objects leaked into SLK')
            end
            local txt = parser.txt(storage[('map/' .. w2l.info.txt_out.unit):lower()])
            assert(not txt.h0bc, 'Case-distinct binary objects leaked into a shared TXT section')
        end

        local shared, shared_files, shared_diagnostics = rawcode_converter(mode, dataset, {
            ['map/war3map.w3h'] = shared_profile_buff,
            ['map/war3map.w3t'] = shared_profile_item,
        })
        shared:frontend()
        shared:backend()
        local rebuilt, rebuilt_files = binary_output(shared, shared_files, mode, dataset)
        local items = object_records(rebuilt, rebuilt_files, 'item')
        local buffs = object_records(rebuilt, rebuilt_files, 'buff')
        assert(items.brpb and items.brpb.unam[1] == 'Item-specific plated boots',
            'Shared profile key must preserve the exact item ID and binary name')
        assert(items.brpb.utip[1] == 'Item-specific tooltip', 'Shared profile key lost the item tooltip')
        if mode == 'slk' then
            local txt = parser.txt(shared_files[('map/' .. shared.info.txt_out.buff):lower()])
            assert(txt.brpb and txt.brpb.bufftip[1] == 'Buff-specific Replenish',
                'Shared profile key lost the distinct buff tooltip')
        else
            assert(buffs.Brpb and buffs.Brpb.ftip[1] == 'Buff-specific Replenish',
                'Shared profile key lost the exact buff ID or its distinct tooltip')
        end
        local shared_warned = collision_diagnostic(shared_diagnostics,
            'TXT_PROFILE_ID_COLLISION', 'Brpb', 'brpb')
        assert(shared_warned == (mode == 'slk'), 'Shared-profile diagnostic must apply only to SLK output')
        print(('PASS rawcode storage: %s %s preserves case-distinct units and buff/item values'):format(dataset, mode))
    end
end
