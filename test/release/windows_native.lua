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
    -- Exercise the actual public dispatcher with retired names. The dormant
    -- archive library remains covered through test/release/archive_worker.lua.
    local original_command = package.loaded['backend.command']
    for _, retired in ipairs {'analyze', 'optimize'} do
        assert(not package.searchpath('backend.cli.' .. retired, package.path),
            'Retired archive command remains publicly dispatchable: ' .. retired)
        package.loaded['backend.command'] = {retired}
        lines = {}
        dofile('backend/init.lua')
        assert(#lines == 1 and lines[1] == lang.raw.INVALID:format(retired),
            'Public dispatcher did not reject retired command: ' .. retired)
    end
    package.loaded['backend.command'] = original_command
    lines = {}
    require 'backend.cli.help'
    local help = table.concat(lines)
    assert(not help:find('analyze', 1, true) and not help:find('optimize', 1, true),
        'Public help still advertises retired archive actions')
    print('PUBLIC_ARCHIVE_ACTIONS_REMOVED|passed')
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

if action == 'abi' then
    local storm = require 'ffi.stormlib'
    ffi.cdef[[
        void* __stdcall GetProcAddress(uintptr_t module, const char* name);
        struct W2L_SMOKE_FIND_DATA {
            char cFileName[260];
            char* szPlainName;
            uint32_t dwHashIndex, dwBlockIndex, dwFileSize, dwFileFlags, dwCompSize;
            uint32_t dwFileTimeLo, dwFileTimeHi, lcLocale;
        };
    ]]
    assert(ffi.sizeof('struct SFILE_CREATE_MPQ') == tonumber(arg[8]), 'Create layout differs from compiled ABI')
    assert(ffi.sizeof('struct W2L_SMOKE_FIND_DATA') == tonumber(arg[9]), 'Find layout differs from compiled ABI')
    assert(ffi.sizeof('void*') == tonumber(arg[10]) and ffi.sizeof('uint32_t') == tonumber(arg[11]),
        'Native FFI widths differ from compiled ABI')
    for _, spec in ipairs {{arg[6], 'struct SFILE_CREATE_MPQ'}, {arg[7], 'struct W2L_SMOKE_FIND_DATA'}} do
        for field, offset in spec[1]:gmatch('([%a_][%w_]*)=(%d+)') do
            assert(ffi.offsetof(spec[2], field) == tonumber(offset), 'FFI offset differs from compiled ABI: ' .. field)
        end
    end
    local module = (require 'ffi.getmodule') 'stormlib'
    assert(module ~= 0, 'Packaged StormLib was not loaded')
    local exports = 0
    for name in assert(arg[4]):gmatch('[^,]+') do
        assert(ffi.C.GetProcAddress(module, name) ~= nil, 'Packaged DLL export is missing: ' .. name)
        exports = exports + 1
    end
    local constants = {}
    for name, value in assert(arg[5]):gmatch('([%a_][%w_]*)=(%d+)') do constants[name] = tonumber(value) end
    local dll = ffi.load('stormlib')
    local map = assert(storm.open(fs.path(assert(arg[3])), true))
    local script = assert(map:load_file('war3map.j'))
    local file = assert(map:open_file('war3map.j'))
    local function query(handle, kind, ctype)
        local value = ffi.new(ctype .. '[1]')
        assert(dll.SFileGetFileInfo(handle, assert(constants[kind]), value, ffi.sizeof(value), nil),
            'Compiled information ID failed against the packaged DLL: ' .. kind)
        return value[0]
    end
    local count = query(map.handle, 'SFileMpqNumberOfFiles', 'uint32_t')
    assert(count == map:number_of_files() and count > 0, 'Native file count differs from the runtime binding')
    query(map.handle, 'SFileMpqFlags', 'uint32_t')
    assert(query(file.handle, 'SFileInfoLocale', 'uint32_t') == 0)
    assert(query(file.handle, 'SFileInfoFileIndex', 'uint32_t') < count)
    assert(query(file.handle, 'SFileInfoByteOffset', 'uint64_t') > 0)
    query(file.handle, 'SFileInfoFileTime', 'uint64_t')
    assert(query(file.handle, 'SFileInfoFileSize', 'uint32_t') == #script)
    assert(query(file.handle, 'SFileInfoCompressedSize', 'uint32_t') > 0)
    assert(query(file.handle, 'SFileInfoFlags', 'uint32_t') & 0x80000000 ~= 0)
    assert(file:close()); assert(map:close())
    print('PASS live packaged FFI widths/offsets, ' .. exports .. ' exports and compiled file-info constants')
    return
end

if action == 'gui-archive-actions' then
    assert(loadfile(root .. '/test/release/windows_gui_actions.lua'))()(assert(arg[3]), assert(arg[4]))
    return
end

if action == 'lossless' or action == 'lossless-output' then
    assert(loadfile(root .. '/test/release/windows_lossless.lua'))()(assert(arg[3]),
        action == 'lossless' and 'run' or 'verify-cli')
    return
end

-- Exercise the packaged checker through the shared backend adapter, with real
-- target declarations. Record stable, machine-readable case summaries on stdout.
if action == 'pjass' then
    local checker = require 'backend.jass_verify'
    local factory = require 'backend.sandbox_core'
    local function verify_case(name, dataset, script, script_type, expected)
        local w2l = factory()
        w2l:set_setting {mode = 'obj', data = dataset, data_meta = '${DATA}',
            data_ui = '${DATA}', data_wes = '${DATA}'}
        local result = checker.verify(w2l, function(member)
            if member == (script_type == 'Lua' and 'war3map.lua' or 'war3map.j') then return script end
        end, name, {script_type = script_type})
        assert(result.status == expected, name .. ': ' .. result.status .. '\n'
            .. result.raw_output .. table.concat(result.diagnostics, '\n'))
        if expected == 'Failed' then
            assert(#result.diagnostics > 0 and result.raw_output ~= '', 'Missing real pjass failure diagnostics')
        elseif expected == 'Passed' then
            assert(result.target.exit_code == 0 and result.target.ignored_errors == 0)
        end
        print(('PJASS_CASE|%s|%s|%s|%d|%d|%s|%d'):format(name, result.status, dataset,
            #result.diagnostics, #result.raw_output, result.target and tostring(result.target.exit_code) or 'skipped',
            result.target and result.target.ignored_errors or 0))
        if result.raw_output ~= '' then print(result.raw_output) end
        return result
    end
    local valid = '\239\187\191function main takes nothing returns nothing\r\n'
        .. '    call BJDebugMsg("Packaged validation")\r\nendfunction\r\n'
    verify_case('current-valid', 'warcraft-current', valid, 'JASS', 'Passed')
    verify_case('legacy-127-valid', 'enUS-1.27.1', valid, 'JASS', 'Passed')
    verify_case('legacy-124-valid', 'zhCN-1.24.4', valid, 'JASS', 'Passed')
    verify_case('invalid-syntax', 'warcraft-current',
        'function main takes nothing returns nothing\n    local integer n =\nendfunction\n', 'JASS', 'Failed')
    verify_case('invalid-type', 'warcraft-current',
        'function main takes nothing returns nothing\n    call SetMapName(42)\nendfunction\n', 'JASS', 'Failed')
    local suppressed = verify_case('suppressed-errors', 'warcraft-current',
        '//# +nosemanticerror\nfunction main takes nothing returns nothing\n    call MissingFunction()\nendfunction\n',
        'JASS', 'Failed')
    assert(suppressed.target.exit_code == 0 and suppressed.target.ignored_errors > 0,
        'Source-suppressed failures must not be accepted as passes')
    local modern = 'function main takes nothing returns nothing\n    call BlzResetUnitTalents(null)\nendfunction\n'
    verify_case('modern-current', 'warcraft-current', modern, 'JASS', 'Passed')
    verify_case('modern-legacy-mismatch', 'enUS-1.27.1', modern, 'JASS', 'Failed')
    verify_case('lua-skipped', 'warcraft-current', 'function main() end\n', 'Lua', 'Skipped')
    local storm = require 'ffi.stormlib'
    local fixture = assert(storm.open(fs.path(assert(arg[3])), true), 'Cannot open the current-editor fixture')
    local script = assert(fixture:load_file('war3map.j'))
    assert(fixture:close())
    verify_case('current-fixture', 'warcraft-current', script, 'JASS', 'Passed')
    -- Keep the ten machine-readable checker cases above stable. These extra
    -- regressions are mandatory assertions in this same native test process.
    local obfuscation_cases = dofile(root .. '/test/compat/obfuscation_cases.lua')
    for _, dataset in ipairs {'warcraft-current', 'enUS-1.27.1', 'zhCN-1.24.4'} do
        -- Reuse one sandbox so adjacent cases detect optimizer state leaks.
        local conversion = factory()
        obfuscation_cases(function(input, setting)
            local candidate = {['war3map.j'] = input}
            local errors = {}
            conversion:set_messager {report = function(_, level, text, detail)
                if level == 1 then errors[#errors + 1] = tostring(text) .. tostring(detail) end
            end}
            conversion:set_setting {mode = 'slk', data = dataset, data_meta = '${DATA}',
                data_ui = '${DATA}', data_wes = '${DATA}', optimize_jass = true,
                confused = setting.confused, confusion = setting.confusion}
            conversion.input_ar = {}
            function conversion:file_load(_, name) return candidate[name:lower()] end
            function conversion:file_save(_, name, bytes) candidate[name:lower()] = bytes end
            conversion:backend_optimizejass()
            assert(#errors == 0, dataset .. ': ' .. table.concat(errors, '\n'))
            return candidate['war3map.j']
        end, function(input, label)
            local w2l = factory()
            w2l:set_setting {mode = 'obj', data = dataset, data_meta = '${DATA}',
                data_ui = '${DATA}', data_wes = '${DATA}'}
            local checked = checker.verify(w2l, function(member)
                if member == 'war3map.j' then return input end
            end, label, {script_type = 'JASS'})
            assert(checked.status == 'Passed', dataset .. ' ' .. label .. ': '
                .. checked.raw_output .. table.concat(checked.diagnostics, '\n'))
            assert(checked.target.exit_code == 0 and checked.target.ignored_errors == 0)
        end)
        print('PASS packaged JASS obfuscation regressions: ' .. dataset)
    end
    print('PASS packaged pjass: current/legacy datasets, syntax/type failures, ignored errors and Lua skip')
    return
end

if action == 'pjass-fixture' then
    local source, destination = fs.path(assert(arg[3])), fs.path(assert(arg[4]))
    assert(source ~= destination and not fs.exists(destination), 'Use a fresh derived fixture path')
    assert(io.save(destination, assert(read_path(source:string()))))
    local storm = require 'ffi.stormlib'
    local map = assert(storm.open(destination, false), 'Cannot open the disposable pjass fixture')
    assert(map:save_file('war3map.j',
        'function main takes nothing returns nothing\r\n    local integer n =\r\nendfunction\r\n'
        .. 'function config takes nothing returns nothing\r\nendfunction\r\n'))
    assert(map:close())
    print('PASS disposable invalid-script fixture created without modifying the packaged map')
    return
end

if action == 'pjass-output' then
    local storm = require 'ffi.stormlib'
    local before = assert(storm.open(fs.path(assert(arg[3])), true), 'Cannot open invalid-script input')
    local after = assert(storm.open(fs.path(assert(arg[4])), true), 'Report-only conversion did not save an MPQ')
    local original = assert(before:load_file('war3map.j'))
    local converted = assert(after:load_file('war3map.j'))
    local function without_stamp(text) return (text:gsub('//W3x2lni Data:[^\r\n]*\r?\n', '')) end
    assert(without_stamp(original) == without_stamp(converted), 'pjass changed or discarded the invalid script')
    assert(before:close())
    assert(after:close())
    local w2l = (require 'backend.sandbox_core')()
    w2l:set_setting {mode = 'obj', data = 'warcraft-current'}
    local result = (require 'backend.jass_verify').verify(w2l,
        function(name) if name == 'war3map.j' then return converted end end, 'Saved output', {script_type = 'JASS'})
    assert(result.status == 'Failed' and #result.diagnostics > 0 and result.raw_output ~= '')
    print(result.raw_output)
    print('PASS native output exists and invalid-script bytes were preserved despite failed pjass verification')
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
