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
