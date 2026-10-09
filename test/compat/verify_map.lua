-- Semantic checks for the supplied current-editor JASS fixture after a full
-- conversion. Raw MPQ preservation and unknown members are checked in Python.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local factory = context.core()
local lang = require 'share.lang'
lang:set_lang 'enUS'
local original_directory = assert(arg[1])
local converted_directory = assert(arg[2])
local optimized = arg[3] == 'optimized'

local function read(directory, name)
    local file = io.open(directory .. '/' .. name, 'rb')
    if not file then return nil end
    local bytes = assert(file:read 'a')
    assert(file:close())
    return bytes
end
local function same(a, b, where)
    assert(type(a) == type(b), where .. ': type differs')
    if type(a) ~= 'table' then
        assert(a == b, where .. ': ' .. tostring(a) .. ' differs from ' .. tostring(b))
        return
    end
    for key, value in pairs(a) do same(value, b[key], where .. '.' .. tostring(key)) end
    for key in pairs(b) do assert(a[key] ~= nil, where .. ': unexpected ' .. tostring(key)) end
end
local w2l = factory()
w2l:set_setting {mode = 'obj', data = 'warcraft-current', data_meta = '${DATA}',
    data_ui = '${DATA}', data_wes = '${DATA}'}
local original_wts = w2l:frontend_wts(assert(read(original_directory, 'war3map.wts')))
local converted_wts = w2l:frontend_wts(assert(read(converted_directory, 'war3map.wts')))
for id, value in pairs(original_wts) do
    if type(id) == 'number' then
        assert(converted_wts[id] and converted_wts[id].text == value.text,
            'Current conversation string-table reference lost original WTS ID ' .. id)
    end
end
local original_info = w2l:frontend_w3i(assert(read(original_directory, 'war3map.w3i')), original_wts)
local converted_info = w2l:frontend_w3i(assert(read(converted_directory, 'war3map.w3i')), converted_wts)
same(original_info, converted_info, 'W3I')
w2l.slk = {w3i = original_info}
if not optimized then
    -- The existing WTG writer replaces its editor-generated root label with
    -- the actual map title. LML also supplies the flattened object list that
    -- backend_wtg requires. Normalize both through that complete same path.
    local function canonical_wtg(directory)
        local parsed = w2l:frontend_wtg(assert(read(directory, 'war3map.wtg')))
        local custom = w2l:frontend_wct(assert(read(directory, 'war3map.wct')))
        local files = w2l:backend_lml(parsed, custom)
        local rebuilt = w2l:frontend_lml(function(name) return files[name] end)
        return w2l:backend_wtg(rebuilt)
    end
    assert(canonical_wtg(original_directory) == canonical_wtg(converted_directory),
        'Trigger hierarchy, events/actions, flags or scripts changed')
    assert(read(original_directory, 'war3map.wct') == read(converted_directory, 'war3map.wct'),
        'Custom trigger script bytes changed')
end

package.path = context.root .. '/script/core/?.lua;' .. package.path
package.loaded.lang = lang
local parser = require 'parser.init'
local options = {}
parser.parser(assert(io.load(context.root .. '/data/warcraft-current/mpq/scripts/common.j')), 'common.j', options)
parser.parser(assert(io.load(context.root .. '/data/warcraft-current/mpq/scripts/blizzard.j')), 'blizzard.j', options)
local jass = assert(read(converted_directory, 'war3map.j'))
local ast, _, diagnostics = parser.parser(jass, 'converted-map.j', options)
assert(ast, 'Rebuilt JASS did not parse')
for _, diagnostic in ipairs(diagnostics or {}) do
    assert(diagnostic.level ~= 'error', tostring(diagnostic.err))
end
assert(jass:find('function main takes', 1, true) and jass:find('function config takes', 1, true))
assert(jass:find('SetHDWaterParamsEx', 1, true), 'Current water initialization was removed')
assert(jass:find('SetPlayerRaceSkin', 1, true), 'Current race-skin initialization was removed')
assert(jass:find('DefineStartLocation', 1, true), 'Player start location was removed')
if not optimized then
    local function without_stamp(text)
        return (text:gsub('//W3x2lni Data:[^\r\n]*\r?\n', ''))
    end
    assert(without_stamp(jass) == without_stamp(assert(read(original_directory, 'war3map.j'))),
        'Unoptimized JASS changed beyond the existing converter timestamp comment')
end
local imp = read(converted_directory, 'war3map.imp')
if imp then
    -- Read the serialized import list directly: backend_imp filters by files
    -- available through a converter proxy, which this semantic checker lacks.
    local version, count, position = string.unpack('<i4i4', imp)
    assert(version == 1 and count >= 0)
    for _ = 1, count do
        local flag, name
        flag, name, position = string.unpack('<Bz', imp, position)
        local lower = name:lower()
        assert(lower ~= 'conversation.json' and lower ~= 'war3map.w3l' and lower ~= 'war3map.w3grp',
            'Native current-editor file incorrectly marked as custom import: ' .. name)
    end
    assert(position == #imp + 1, 'Unexpected trailing import-list bytes')
end
print('PASS current-map semantics: W3I settings, original WTS IDs, current native calls, valid JASS'
    .. (optimized and ', optimized output' or ', GUI triggers and original script behavior'))
