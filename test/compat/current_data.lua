local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local directory = source:match('^(.*)/[^/]+$')
local context = dofile(directory .. '/bootstrap.lua')
local core = context.core()
local importer = require 'prebuilt.directory'
local parser = require 'w3xparser'
local schema = require 'core.slk.schema'
local raw_directory = context.root .. '/data/warcraft-current/mpq/'
local function loader(name)
    local file = io.open(raw_directory .. name, 'rb')
    if not file then return nil end
    local content = file:read 'a'
    file:close()
    return content
end
local function options(w2l, read)
    return {
        name = 'warcraft-current', loader = read or loader,
        fixer = w2l:parse_lni(assert(io.load(context.root .. '/script/core/defined/metadata.ini'))),
    }
end
-- Deliberately hide the localization files from the earlier incomplete export.
-- Keep the negative tests independent of whether the real dataset is complete.
local localization_files = {
    'ui/triggerstrings.txt', 'ui/worldeditstrings.txt', 'ui/worldeditgamestrings.txt',
    'units/campaignabilitystrings.txt', 'units/campaignunitstrings.txt',
    'units/campaignupgradestrings.txt', 'units/commonabilitystrings.txt',
    'units/humanabilitystrings.txt', 'units/humanunitstrings.txt', 'units/humanupgradestrings.txt',
    'units/itemabilitystrings.txt', 'units/itemstrings.txt',
    'units/neutralabilitystrings.txt', 'units/neutralunitstrings.txt', 'units/neutralupgradestrings.txt',
    'units/nightelfabilitystrings.txt', 'units/nightelfunitstrings.txt', 'units/nightelfupgradestrings.txt',
    'units/orcabilitystrings.txt', 'units/orcunitstrings.txt', 'units/orcupgradestrings.txt',
    'units/undeadabilitystrings.txt', 'units/undeadunitstrings.txt', 'units/undeadupgradestrings.txt',
}
local hidden = {}
for _, filename in ipairs(localization_files) do
    assert(loader(filename), 'Complete raw dataset is missing ' .. filename)
    hidden[filename] = true
end
local function without_localization(name)
    if hidden[name] then return nil end
    return loader(name)
end
local strict = core()
local missing = importer.build(strict, options(strict, without_localization))
assert(not missing.built and not missing.complete)
assert(next(missing.files) == nil)
assert(#missing.missing == 24 and #missing.missing_essential == 0)
assert(missing.report:find('Game build: unverified', 1, true))
assert(missing.report:find('ui/triggerstrings.txt', 1, true))
assert(missing.report:find('units/humanunitstrings.txt', 1, true))

local unusable = core()
local broken = options(unusable)
broken.allow_partial = true
function broken.loader(name)
    if name == 'units/unitdata.slk' then return nil end
    return loader(name)
end
local rejected = importer.build(unusable, broken)
assert(not rejected.built and #rejected.missing_essential == 1)
assert(next(rejected.files) == nil)

local partial_reader = core()
local partial = options(partial_reader, without_localization)
partial.allow_partial = true
local partial_result = importer.build(partial_reader, partial)
assert(partial_result.built and not partial_result.complete)
assert(partial_result.files.version == nil)
assert(partial_result.files['import-report.txt']:find('INCOMPLETE', 1, true))
assert(partial_result.files['ui/triggerdata.txt'] == loader('ui/triggerdata.txt'))
assert(partial_result.files['ui/triggerstrings.txt'] == nil)
assert(partial_reader:get_default().unit.hfoo.name == nil,
    'Missing localization must not be replaced by the internal UnitUI name or an old dataset')

local w2l = core()
local result = importer.build(w2l, options(w2l))
assert(result.built and result.complete and #result.missing == 0)
assert(result.files.version == table.concat(require 'share.data_version', '\r\n'))
assert(result.files['import-report.txt']:find('required input files present', 1, true))
assert(result.files['ui/triggerdata.txt'] == loader('ui/triggerdata.txt'))
assert(result.files['ui/triggerstrings.txt'] == loader('ui/triggerstrings.txt'))
assert(result.files['prebuilt/reforge.ini'] == '')
assert(not result.custom_balance)

local metadata = w2l:metadata()
assert(metadata.unit.file_1.id == 'umdl' and metadata.unit.file_1.index == 1)
assert(metadata.unit.file_2.id == 'umd1' and metadata.unit.file_2.index == 2)
assert(metadata.unit.file_3.id == 'umd2' and metadata.unit.file_3.index == 3)
assert(metadata.item.file.id == 'ifil' and metadata.item.file.index == nil)
assert(metadata.item.file.profile and metadata.item.file_0 == nil)
local data_columns = {}
for _, fields in pairs(metadata) do
    for _, meta in pairs(fields) do
        if type(meta) == 'table' and meta.data then data_columns[meta.data] = true end
    end
end
local raw_metadata = parser.slk(loader('units/abilitymetadata.slk'))
for _, meta in pairs(raw_metadata) do
    if meta.data and meta.data > 0 then
        assert(data_columns[meta.data], 'Missing declared ability data column ' .. meta.data)
    end
end
assert(data_columns[11] and data_columns[14], 'New columns beyond DataJ must be understood')

local columns = schema.columns(w2l:slktitle()['units\\abilitydata.slk'])
assert(columns.datat6 and columns.cool6)
assert(not schema.columns(w2l:slktitle()['units\\unitui.slk']).file)
assert(not schema.columns(w2l:slktitle()['units\\itemdata.slk']).file)
local skin_fields = {}
for _, key in ipairs(w2l:keydata()['units\\unitskin.txt']) do skin_fields[key] = true end
assert(skin_fields.file and skin_fields.modelscale and skin_fields['file:de'])
assert(w2l:keydata()['units\\unitweaponsfunc.txt'])
assert(w2l:keydata()['units\\unitskinstrings.txt'])

local defaults = w2l:get_default()
local native_skin = parser.txt(loader('units/unitskin.txt'))
assert(defaults.unit.hfoo.file_1 == native_skin.hfoo.file[1])
assert(defaults.item.ratf.file == parser.txt(loader('units/itemskin.txt')).ratf.file[1])
assert(defaults.unit.nwzg.launchx == tonumber(parser.txt(loader('units/unitweaponsfunc.txt')).nwzg.launchx[1]))
assert(defaults.unit.nwzg.launchx == 30)
local human_strings = parser.txt(loader('units/humanunitstrings.txt'))
assert(defaults.unit.hfoo.name == human_strings.hfoo.name[1] and defaults.unit.hfoo.name == 'Footman')
assert(defaults.unit.hfoo.ubertip == human_strings.hfoo.ubertip[1])
assert(defaults.item.ratf.name == parser.txt(loader('units/itemstrings.txt')).ratf.name[1])
assert(w2l:get_editstring('WESTRING_RACE_FORSAKEN') == 'Forsaken',
    'New editor strings must resolve from the supplied current localization')
assert(w2l:get_editstring('WESTRING_LOCALE_UNDERCITY') == 'Undercity',
    'Game-side editor strings must resolve from the supplied current localization')
local skin_strings = parser.txt(loader('units/unitskinstrings.txt'))
for id, profile in pairs(skin_strings) do
    if id ~= 'y425' then
        assert(defaults.txt[id].name[1] == profile.name[1],
            'Alternate skin name missing from defaults: ' .. id)
        for _, key in ipairs {'propernames', 'propernames:hd'} do
            if profile[key] then
                assert(table.concat(defaults.txt[id][key], ',') == table.concat(profile[key], ','),
                    'Alternate skin proper names missing from defaults: ' .. id .. '.' .. key)
            end
        end
    end
end
assert(defaults.txt.hjas.name[1] == 'Archmage')
assert(defaults.txt.hjas['propernames:hd'][1] == 'Jaina Proudmoore')
local raw_ability = parser.slk(loader('units/abilitydata.slk'))
assert(#defaults.ability.AHhb.cool == 6)
assert(defaults.ability.AHhb.cool[6] == parser.tonumber(raw_ability.AHhb.Cool6))
assert(result.counts.Melee.ability == 1556 and result.counts.Melee.unit == 928)
assert(result.counts.Melee.item == 649 and result.counts.Melee.doodad == 771)
for _, variant in ipairs {'melee', 'custom'} do
    for _, kind in ipairs {'unit', 'item', 'ability', 'buff', 'upgrade', 'doodad', 'destructable', 'misc', 'txt'} do
        assert(result.files['prebuilt/' .. variant .. '/' .. kind .. '.ini'])
    end
end

local unit_buffer = w2l:backend_obj('unit', {
    uC00 = {
        _id = 'uC00', _parent = 'hfoo', _code = 'hfoo',
        file_1 = 'first.mdl', file_2 = 'second.mdl', file_3 = 'third.mdl',
    },
})
local unit = w2l:frontend_obj('unit', unit_buffer).uC00
assert(unit.umdl[1] == 'first.mdl' and unit.umd1[1] == 'second.mdl' and unit.umd2[1] == 'third.mdl')
local item_buffer = w2l:backend_obj('item', {
    iC00 = {_id = 'iC00', _parent = 'ratf', _code = 'ratf', file = 'item.mdl'},
})
assert(w2l:frontend_obj('item', item_buffer).iC00.ifil[1] == 'item.mdl')

local function map_converter(map)
    local reader = core()
    reader:set_setting {
        mode = 'lni', data = 'warcraft-current', data_meta = '${DATA}',
        data_ui = '${DATA}', data_wes = '${DATA}', read_slk = true,
    }
    reader.data_load = w2l.data_load
    reader.input_ar = {
        get = function(_, name) return map[name:lower()] end,
        set = function() end, remove = function() end,
    }
    reader.output_ar = {get = function() end, set = function() end, remove = function() end}
    reader:frontend()
    return reader
end
local skin_only = map_converter {
    ['units\\unitskin.txt'] = '[hfoo]\r\nfile=custom-only.mdl\r\n',
}
assert(skin_only.slk.unit.hfoo.file_1 == 'custom-only.mdl', 'Skin-only map profile must be detected')
assert(skin_only.slk.unit.hfoo.art == defaults.unit.hfoo.art,
    'A native profile override must retain other stock fields in the same record')
assert(skin_only.slk.unit.Hpal.file_1 == defaults.unit.Hpal.file_1,
    'A native profile override must retain unrelated stock records')
local cleared_skin = map_converter {
    ['units\\unitskin.txt'] = '[hfoo]\r\nfile=\r\nscale=0\r\n',
}
assert(cleared_skin.slk.unit.hfoo.file_1 == nil,
    'An explicit empty native profile property must clear the stock value')
assert(cleared_skin.slk.unit.hfoo.scale == 0,
    'An explicit zero native profile property must override the stock value')
assert(cleared_skin.slk.unit.Hpal.file_1 == defaults.unit.Hpal.file_1)
local weapons_only = map_converter {
    ['units\\unitweaponsfunc.txt'] = '[hfoo]\r\nlaunchX=123\r\nlaunchY=45\r\n',
}
assert(weapons_only.slk.unit.hfoo.launchx == 123 and weapons_only.slk.unit.hfoo.launchy == 45)

local function build_obj(map, read_slk, mode, prune)
    local writer = core()
    writer:set_setting {
        mode = mode or 'obj', data = 'warcraft-current', data_meta = '${DATA}',
        data_ui = '${DATA}', data_wes = '${DATA}', read_slk = read_slk or false,
        remove_unuse_object = prune or false, remove_same = true,
        remove_we_only = true, optimize_jass = false,
    }
    writer.data_load = w2l.data_load
    local output = {}
    writer.input_ar = {
        get = function(_, name) return map[name:lower()] end,
        set = function() end, remove = function() end,
    }
    writer.output_ar = {
        get = function() end,
        set = function(_, name, content) output[name:lower()] = content end,
        remove = function(_, name) output[name:lower()] = nil end,
    }
    writer:frontend()
    writer:backend()
    return output
end
local extra_lni = '[hfoo]\r\n"file:de" = "qa-enhanced.mdl"\r\n'
local obj_output = build_obj {['table\\txt.ini'] = extra_lni}
assert(parser.txt(assert(obj_output['units\\unitskin.txt'])).hfoo['file:de'][1] == 'qa-enhanced.mdl',
    'Unknown native DE fields must have game-readable OBJ output, not only table/txt.ini')
local merged_output = build_obj {
    ['table\\txt.ini'] = extra_lni,
    ['units\\unitskin.txt'] = '[hfoo]\r\nfile:de=old-enhanced.mdl\r\nmodelScale:sd=0\r\n[other]\r\ncustomkey=keep\r\n',
}
local merged_skin = parser.txt(assert(merged_output['units\\unitskin.txt']))
assert(merged_skin.hfoo['file:de'][1] == 'qa-enhanced.mdl')
assert(merged_skin.hfoo['modelscale:sd'][1] == '0')
assert(merged_skin.other.customkey[1] == 'keep')

local stock_model = w2l:get_default().unit.hfoo.file_1
local stock_lni = ('[hfoo]\r\n_parent="hfoo"\r\nfile_1=%q\r\n'):format(stock_model)
local reset_with_de = build_obj({
    ['table\\unit.ini'] = stock_lni,
    ['table\\txt.ini'] = extra_lni,
    ['units\\unitskin.txt'] = '[hfoo]\r\nfile=stale-profile.mdl\r\nfile:de=old-enhanced.mdl\r\ncustomkey=keep\r\n[other]\r\nfile=unrelated-model.mdl\r\n',
}, true)
assert(map_converter(reset_with_de).slk.unit.hfoo.file_1 == stock_model,
    'Consumed native fields must not shadow an explicit reset to the stock model')
assert(parser.txt(reset_with_de['units\\unitskin.txt']).hfoo['file:de'][1] == 'qa-enhanced.mdl')
assert(parser.txt(reset_with_de['units\\unitskin.txt']).hfoo.customkey[1] == 'keep')
assert(parser.txt(reset_with_de['units\\unitskin.txt']).other.file[1] == 'unrelated-model.mdl')
local reset_without_de = build_obj({
    ['table\\unit.ini'] = stock_lni,
    ['units\\unitskin.txt'] = '[hfoo]\r\nfile=stale-profile.mdl\r\n',
}, true)
assert(map_converter(reset_without_de).slk.unit.hfoo.file_1 == stock_model,
    'Consumed native profiles must also be cleaned when no residual fields need updating')

local localized_map = {
    ['units\\unitskinstrings.txt'] = '[Hjas]\r\nName=QA alternate hero\r\nPropernames:hd=\r\n',
}
local localized_reader = map_converter(localized_map)
assert(localized_reader.slk.txt.hjas.name[1] == 'QA alternate hero')
assert(localized_reader.slk.txt.hjas['propernames:hd'][1] == '',
    'An explicit empty skin localization value must clear the supplied stock text')
assert(localized_reader.slk.txt.udef.name[1] == skin_strings.udef.name[1],
    'A localized map override must retain other stock skin records')
assert(localized_reader.slk.unit.hfoo.name == defaults.unit.hfoo.name)

local localized_lni = build_obj(localized_map, true, 'lni')
local localized_txt = w2l:parse_lni(assert(localized_lni['table\\txt.ini']))
assert(localized_txt.hjas.name == 'QA alternate hero')
assert(localized_txt.hjas['propernames:hd'] == '',
    'LNI must retain an explicit empty localized skin value')
for _, mode in ipairs {'obj', 'slk'} do
    local input = localized_lni
    if mode == 'slk' then
        input = {}
        for name, content in pairs(localized_lni) do input[name] = content end
        input['war3map.j'] = [[
function main takes nothing returns nothing
    call BlzCreateUnitWithSkin(Player(0), 'Hamg', 0.0, 0.0, 270.0, 'Hjas')
    call CreateUnit(Player(0), 'hfoo', 128.0, 0.0, 270.0)
endfunction
]]
    end
    local rebuilt = build_obj(input, true, mode, mode == 'slk')
    local profile = assert(rebuilt['units\\unitskinstrings.txt'], mode .. ' needs a native skin localization profile')
    local parsed = parser.txt(profile)
    assert(parsed.hjas.name[1] == 'QA alternate hero')
    assert(parsed.hjas['propernames:hd'] and #parsed.hjas['propernames:hd'] == 0,
        mode .. ' must emit the empty localized skin property')
    local reopened = map_converter(rebuilt)
    assert(reopened.slk.txt.hjas.name[1] == 'QA alternate hero')
    assert(reopened.slk.txt.hjas['propernames:hd'][1] == '')
    assert(reopened.slk.unit.hfoo.name == 'Footman')
    if mode == 'slk' then
        local unit_rows = parser.slk(assert(rebuilt['units\\unitdata.slk']))
        assert(unit_rows.Hamg and unit_rows.hfoo and unit_rows.Hblm == nil,
            'This fixture must prune unrelated units rather than retain every object')
        local ordinary = parser.txt(assert(rebuilt['units\\campaignunitstrings.txt']))
        assert(ordinary.hfoo.name[1] == 'Footman', 'Ordinary unit names must retain their original output profile')
        assert(not parsed.hfoo or parsed.hfoo.name == nil,
            'Ordinary unit names must not be rerouted into the skin localization profile')
    end
end

print('PASS: complete current raw import with selectable version marker and supplied localization, strict rejection of intentionally missing inputs, explicit partial QA without old localization fallback, extended metadata and model indices, DataT schema, native skin/weapon profiles, Melee/Custom defaults, binary model round-trips, skin-only and weapon-profile-only maps, native profile overlays with empty/zero overrides, native DE profile preservation in OBJ output, consumed-profile stock model resets, all supplied alternate skin names, and localized skin overrides including empty values through LNI/OBJ/SLK with actual JASS skin references and object pruning, without rerouting ordinary names')
