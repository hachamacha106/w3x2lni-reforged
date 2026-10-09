-- Legacy LNI migration against metadata generated from the supplied game data.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/legacy_profile_fields.lua$'))
local boot = dofile(root .. '/test/compat/bootstrap.lua')
local core = boot.core()
local lni = require 'lni'
local count = 0
local function test(name, fn)
    fn()
    count = count + 1
    print('PASS legacy profiles: ' .. name)
end

local function new_w2l(metadata)
    local w2l = core()
    w2l:set_setting {
        mode = 'obj', data = 'enUS-1.27.1', data_meta = 'enUS-1.27.1',
        data_wes = '${DEFAULT}', remove_unuse_object = false,
    }
    w2l:set_messager(function() end)
    w2l.cache_metadata = metadata
    w2l.default_data = {unit = {
        hfoo = {_id = 'hfoo', _parent = 'hfoo', _type = 'unit', _code = 'hfoo'},
    }}
    return w2l
end

local w2l = new_w2l()
local current_metadata = lni(require 'prebuilt.metadata'(w2l, nil, {reforge = true, casc = true}, function(name)
    return io.load(root .. '/data/warcraft-current/mpq/' .. name:gsub('\\', '/'):lower()) or nil
end))
assert(current_metadata.unit.file == nil)
assert(current_metadata.unit.file_1.id == 'umdl')
assert(current_metadata.unit.file_2.id == 'umd1')
assert(current_metadata.unit.file_3.id == 'umd2')

test('old file and HD/SD names migrate to the first indexed profile', function()
    local w2l = new_w2l(current_metadata)
    local data = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
"file:hd" = "LegacyHD.mdl"
"file:sd" = "LegacySD.mdl"
]], 'unit')
    local unit = data.H000
    assert(unit.file_1 == 'Legacy.mdl')
    assert(unit['file_1:hd'] == 'LegacyHD.mdl')
    assert(unit['file_1:sd'] == 'LegacySD.mdl')
    assert(unit.file == nil and unit['file:hd'] == nil and unit['file:sd'] == nil)
    local output = lni(w2l:backend_lni('unit', data))
    assert(output.H000.file_1 == 'Legacy.mdl')
    assert(output.H000['file_1:hd'] == 'LegacyHD.mdl')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.umdl[1] == 'Legacy.mdl')
end)

test('explicit modern model columns take priority independently', function()
    local w2l = new_w2l(current_metadata)
    local data = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
file_1 = "Current.mdl"
file_2 = "Portrait.mdl"
file_3 = "PortraitHD.mdl"
"file:hd" = "LegacyHD.mdl"
"file_1:hd" = "CurrentHD.mdl"
"file:sd" = "LegacySD.mdl"
"file_1:sd" = "CurrentSD.mdl"
]], 'unit')
    local unit = data.H000
    assert(unit.file_1 == 'Current.mdl')
    assert(unit.file_2 == 'Portrait.mdl' and unit.file_3 == 'PortraitHD.mdl')
    assert(unit['file_1:hd'] == 'CurrentHD.mdl')
    assert(unit['file_1:sd'] == 'CurrentSD.mdl')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.umdl[1] == 'Current.mdl')
    assert(raw.H000.umd1[1] == 'Portrait.mdl')
    assert(raw.H000.umd2[1] == 'PortraitHD.mdl')
end)

test('an older selected dataset retains its original field names', function()
    local metadata = lni(assert(io.load(root .. '/data/zhCN-1.32.8/prebuilt/metadata.ini')))
    local w2l = new_w2l(metadata)
    local unit = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
"file:hd" = "LegacyHD.mdl"
"file:sd" = "LegacySD.mdl"
]], 'unit').H000
    assert(unit.file == 'Legacy.mdl' and unit.file_1 == nil)
    assert(unit['file:hd'] == 'LegacyHD.mdl')
    assert(unit['file:sd'] == 'LegacySD.mdl')
end)

test('unknown ufil records remain unknown instead of becoming model aliases', function()
    local w2l = new_w2l(current_metadata)
    local fixture = string.pack('<i4i4i4c4c4i4c4i4zi4',
        2, 0, 1, 'hfoo', 'H000', 1, 'ufil', 3, 'Unknown.mdl', 0)
    local data = w2l:frontend_obj('unit', fixture)
    w2l:frontend_updateobj('unit', data, w2l:get_default().unit)
    assert(data.H000.file_1 == nil)
    assert(data.H000._object_extras[1][1] == 'ufil')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.ufil[1] == 'Unknown.mdl')
end)

print(('Legacy profile migration tests passed: %d'):format(count))
