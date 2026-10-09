-- Integration checks for dataset changes and archive save/discovery. The archive
-- is in memory; the real converter proxies and native model parser are used.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local core = context.core()

local w2l = core()
w2l:set_setting { mode = 'obj', data = 'enUS-1.27.1', version = 'Custom' }
local cached = { sentinel = true }
for _, key in ipairs {'cache_metadata', 'cache_keydata', 'cache_slktitle',
    'default_data', 'editstring', 'editstring_reported', 'trg', 'ydwe_ui'} do
    w2l[key] = cached
end
w2l:set_setting(w2l.setting)
assert(w2l.default_data == cached, 'Unchanged settings should keep cached defaults')
w2l.setting.version = 'Melee'
w2l:set_setting(w2l.setting)
for _, key in ipairs {'cache_metadata', 'cache_keydata', 'cache_slktitle',
    'default_data', 'editstring', 'editstring_reported', 'trg', 'ydwe_ui'} do
    assert(rawget(w2l, key) == nil, 'In-place balance change left stale ' .. key)
end
local paths = {}
w2l.mpq_path:each_path(function(path) paths[#paths + 1] = path end)
assert(#paths == 1 and paths[1] == '')
w2l.default_data = cached
w2l.setting.data = 'warcraft-current'
w2l:set_setting(w2l.setting)
assert(w2l.default_data == nil, 'In-place dataset change left stale defaults')
print('PASS dataset and balance changes invalidate caches, including in-place settings')

local function archive(files, storage)
    local object = {}
    function object:get(name) return files[name:lower()] end
    function object:has(name) return files[name:lower()] ~= nil end
    function object:set(name, content) files[name:lower()] = content end
    function object:remove(name) files[name:lower()] = nil end
    function object:get_type() return storage or 'mpq' end
    function object:number_of_files()
        local n = 0
        for _ in pairs(files) do n = n + 1 end
        return n
    end
    return setmetatable(object, {__pairs = function() return next, files, nil end})
end

local known = {
    ['war3map.lua'] = 'function main() end\n',
    ['scripts\\war3map.lua'] = 'function config() end\n',
    ['scripts\\war3map.j'] = 'function main takes nothing returns nothing\nendfunction',
    ['units\\unitskin.txt'] = '[hfoo]\nfile=test.mdl\n',
    ['units\\unitweaponsfunc.txt'] = '[hfoo]\nlaunchX=5\n',
    ['war3map.w3grp'] = string.rep('\0', 12),
    ['war3map.w3l'] = 'W3L!' .. string.pack('<i4', 3) .. string.rep('\0', 14),
    ['conversation.json'] = '{"stringTablePath":"war3map.wts","conversation":{}}',
}
for _, extension in ipairs {'a', 'b', 'd', 'h', 'q', 't', 'u'} do
    known['war3mapskin.w3' .. extension] = string.pack('<i4i4i4', 3, 0, 0)
end
package.loaded.lang = require 'share.lang'
local load_archive = assert(loadfile(context.root .. '/script/core/map-builder/load.lua'))()
local loaded = load_archive(core(), archive(known))
for name, content in pairs(known) do
    assert(loaded[name] == content, 'Archive without listfile lost known file ' .. name)
end
print('PASS discovery of Lua scripts, skin sidecars and native profiles without an MPQ listfile')

local hd_model = 'MDLXVERS' .. string.pack('<i4i4', 4, 1100) .. 'UNKN' .. string.pack('<i4', 5) .. 'bytes'
local tiny_model = 'MDLX'
local files = {
    ['war3map.lua'] = 'function main() end\n',
    ['war3mapskin.w3u'] = known['war3mapskin.w3u'],
    ['war3mapunits.doo'] = 'placement bytes retained by save',
    ['units\\unitskin.txt'] = known['units\\unitskin.txt'],
    ['units\\unitweaponsfunc.txt'] = known['units\\unitweaponsfunc.txt'],
    ['war3map.w3grp'] = known['war3map.w3grp'],
    ['war3map.w3l'] = known['war3map.w3l'],
    ['conversation.json'] = known['conversation.json'],
    ['models\\hd.mdx'] = hd_model,
    ['models\\tiny.mdx'] = tiny_model,
    ['textures\\sample.dds'] = 'DDS opaque bytes',
    ['ui\\custom.fdf'] = 'Frame "TEXT" "Sample" { Text "*/" }',
}
local names = {}
for name in pairs(files) do names[#names + 1] = name end
table.sort(names)
files['(listfile)'] = table.concat(names, '\r\n')
local output = {}
w2l = core()
w2l:set_setting {mode = 'obj', data = 'enUS-1.27.1', remove_we_only = false, mdx_squf = true}
w2l.input_ar = archive(files)
w2l.output_ar = archive(output)
w2l.input_mode = 'obj'
w2l:save()
for name, content in pairs(files) do
    if name ~= '(listfile)' then
        assert(output[name] == content, 'Archive save changed or lost ' .. name)
    end
end
local imports = w2l:parse_lni(w2l:backend_imp(assert(output['war3map.imp']))).import
local imported = {}
for _, name in ipairs(imports) do imported[name:lower()] = true end
assert(imported['models\\hd.mdx'] and imported['models\\tiny.mdx'])
assert(imported['textures\\sample.dds'] and imported['ui\\custom.fdf'])
assert(not imported['war3map.lua'] and not imported['war3mapskin.w3u'])
assert(not imported['units\\unitskin.txt'] and not imported['units\\unitweaponsfunc.txt'])
assert(not imported['war3map.w3grp'] and not imported['war3map.w3l'])
assert(not imported['conversation.json'])
print('PASS archive asset preservation, HD/short model guards and rebuilt import classification')
