-- Run by windows_smoke.py with the actual packaged Windows Lua executable.
-- No native APIs are mocked. GUI rendering, game execution and CASC storage
-- extraction are outside this smoke test.
local root = assert(arg[1], 'Package root required'):gsub('\\', '/')
local action = assert(arg[2], 'Action required')
assert(package.config:sub(1, 1) == '\\', 'This helper requires native Windows Lua')
package.path = root .. '/script/?.lua;' .. root .. '/script/?/init.lua;' .. package.path
package.cpath = root .. '/bin/?.dll;' .. package.cpath
local fs = require 'bee.filesystem'
fs.current_path(fs.path(root .. '/script'))
require 'utility'
local lang = require 'share.lang'
lang:set_lang 'enUS'
local ffi = require 'ffi'
assert(ffi.sizeof('void*') == 4, 'The release runtime must be Windows x86')
assert(string.packsize('l') == 4, 'Windows binary long width changed')

local function read_path(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local content = assert(file:read 'a')
    assert(file:close())
    return content
end

local function same(a, b, label)
    assert(type(a) == type(b), label .. ': value type changed')
    if type(a) ~= 'table' then
        assert(a == b, label .. ': value changed')
        return
    end
    for key, value in pairs(a) do same(value, b[key], label .. '.' .. tostring(key)) end
    for key in pairs(b) do assert(a[key] ~= nil, label .. ': unexpected field ' .. tostring(key)) end
end

if action == 'runtime' then
    for _, name in ipairs {'bee.subprocess', 'w3xparser', 'lni', 'lml', 'lpeglabel',
                           'ffi.stormlib', 'ffi.casclib'} do
        assert(require(name), 'Native module failed to load: ' .. name)
    end
    assert((require 'share.changelog')[1].version == assert(arg[3]), 'Wrong application version')
    local config = require 'share.config'
    assert(config.global.data == 'warcraft-current', 'The selected dataset is not current')
    assert(config.lni.read_slk and config.obj.read_slk, 'Current SLK-reading defaults are missing')
    -- Capture the actual CLI version protocol without the launcher's console
    -- rendering, which uses WriteConsoleW and may not survive stdout redirection.
    local lines = {}
    package.loaded['share.messager'] = {raw = function(text) lines[#lines + 1] = text end}
    require 'backend.cli.version' ()
    local text = table.concat(lines)
    assert(text:find(arg[3], 1, true), 'The CLI did not report the release version')
    print(text)
    print('PASS packaged Windows x86 Lua, native parsers, MPQ/CASC module loading and current-data defaults')
    return
end

if action == 'lni' then
    local directory = assert(arg[3]):gsub('\\', '/')
    assert((require 'share.check_lni_mark')(read_path(directory .. '/.w3x')), 'Invalid or missing LNI marker')
    local ini = assert(read_path(directory .. '/table/w3i.ini'), 'LNI map settings missing')
    assert(#ini > 0 and not ini:find('unknown_%d+'), 'Numbered unknown W3I fields remain')
    assert(read_path(directory .. '/map/war3map.j'), 'LNI JASS script missing')
    assert(read_path(directory .. '/w3x2lni/version/lml'), 'LNI trigger-version marker missing')
    print('PASS native CLI LNI output, map settings, script and trigger marker')
    return
end

assert(action == 'archive', 'Unknown Windows smoke action')
local storm = require 'ffi.stormlib'
local original = assert(storm.open(fs.path(assert(arg[3])), true), 'Cannot open original MPQ')
local converted = assert(storm.open(fs.path(assert(arg[4])), true), 'Cannot reopen rebuilt MPQ')
local optimized = arg[5] == 'optimized'
local function before(name) return original:load_file(name) end
local function after(name) return converted:load_file(name) end
local core = require 'backend.sandbox_core'
local w2l = core()
w2l:set_setting {mode = 'obj', data = 'warcraft-current', data_meta = '${DATA}',
    data_ui = '${DATA}', data_wes = '${DATA}'}
local old_wts = w2l:frontend_wts(assert(before('war3map.wts')))
local new_wts = w2l:frontend_wts(assert(after('war3map.wts')))
for id, value in pairs(old_wts) do
    if type(id) == 'number' then
        assert(new_wts[id] and new_wts[id].text == value.text, 'Original WTS ID changed: ' .. id)
    end
end
local old_info = w2l:frontend_w3i(assert(before('war3map.w3i')), old_wts)
local new_info = w2l:frontend_w3i(assert(after('war3map.w3i')), new_wts)
same(old_info, new_info, 'W3I')
w2l.slk = {w3i = old_info}

local ignored = {['(listfile)'] = true, ['(attributes)'] = true, ['(signature)'] = true}
local rewritten = {['war3map.w3i'] = true, ['war3map.wts'] = true,
    ['war3map.wtg'] = true, ['war3map.wct'] = true, ['war3map.j'] = true}
local editor_files = {['war3map.wtg'] = true, ['war3map.wct'] = true,
    ['war3map.w3c'] = true, ['war3map.w3r'] = true, ['war3map.w3s'] = true,
    ['war3mapunits.doo'] = true}
local preserved = 0
for name in assert(before('(listfile)'), 'Original map listfile missing'):gmatch('[^\r\n]+') do
    local key = name:lower()
    if optimized and editor_files[key] then
        assert(not after(name), 'Optimized map retained removed editor file: ' .. name)
    elseif not ignored[key] and not rewritten[key] then
        assert(before(name) == after(name), 'Native map member changed or was lost: ' .. name)
        preserved = preserved + 1
    end
end
assert(preserved > 0, 'No native map members were checked')

if not optimized then
    local function canonical_wtg(read)
        local parsed = w2l:frontend_wtg(assert(read('war3map.wtg')))
        local custom = w2l:frontend_wct(assert(read('war3map.wct')))
        local files = w2l:backend_lml(parsed, custom)
        return w2l:backend_wtg(w2l:frontend_lml(function(name) return files[name] end))
    end
    assert(canonical_wtg(before) == canonical_wtg(after), 'GUI trigger semantics changed')
    assert(before('war3map.wct') == after('war3map.wct'), 'Custom trigger bytes changed')
else
    assert(after('units\\abilitydata.slk') and after('units\\unitdata.slk'), 'SLK tables were not generated')
end

package.path = root .. '/script/core/?.lua;' .. package.path
package.loaded.lang = lang
local parser = require 'parser.init'
local options = {}
parser.parser(assert(read_path(root .. '/data/warcraft-current/mpq/scripts/common.j')), 'common.j', options)
parser.parser(assert(read_path(root .. '/data/warcraft-current/mpq/scripts/blizzard.j')), 'blizzard.j', options)
local jass = assert(after('war3map.j'), 'Rebuilt JASS missing')
local ast, _, diagnostics = parser.parser(jass, 'windows-output.j', options)
assert(ast, 'Rebuilt JASS did not parse')
for _, diagnostic in ipairs(diagnostics or {}) do
    assert(diagnostic.level ~= 'error', tostring(diagnostic.err))
end
for _, text in ipairs {'function main takes', 'function config takes',
                      'SetHDWaterParamsEx', 'SetPlayerRaceSkin', 'DefineStartLocation'} do
    assert(jass:find(text, 1, true), 'Current initialization was lost: ' .. text)
end
if not optimized then
    local function without_stamp(text)
        return (text:gsub('//W3x2lni Data:[^\r\n]*\r?\n', ''))
    end
    assert(without_stamp(jass) == without_stamp(assert(before('war3map.j'))),
        'Unoptimized JASS changed beyond the converter timestamp')
end
local imports = after('war3map.imp')
if imports then
    local version, count, position = string.unpack('<i4i4', imports)
    assert(version == 1 and count >= 0)
    for _ = 1, count do
        local _, name
        _, name, position = string.unpack('<Bz', imports, position)
        local key = name:lower()
        assert(key ~= 'conversation.json' and key ~= 'war3map.w3l' and key ~= 'war3map.w3grp',
            'Native current-editor file incorrectly treated as a custom import: ' .. name)
    end
    assert(position == #imports + 1, 'Unexpected import-list trailing bytes')
end
converted:close()
original:close()
print('PASS native MPQ reopen, W3I/WTS, JASS, trigger/editor settings and '
    .. preserved .. ' unchanged native members (' .. (optimized and 'SLK' or 'OBJ') .. ')')
