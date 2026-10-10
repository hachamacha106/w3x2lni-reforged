local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local context = dofile(source:match('^(.*)/[^/]+$') .. '/bootstrap.lua')
local fs = context.fs
local lang = require 'share.lang'
lang:set_lang('enUS')
local checker = require 'backend.jass_verify'
local events = {}

local function converter(dataset)
    local w2l = {setting = {data = dataset or 'warcraft-current'}}
    function w2l:mpq_load(name)
        local file = io.open(context.root .. '/data/' .. self.setting.data .. '/mpq/' .. name, 'rb')
        if not file then return nil end
        local bytes = file:read 'a'
        file:close()
        return bytes
    end
    function w2l:frontend_w3i(bytes)
        if bytes == 'unreadable' then error('bad W3I') end
        return {[lang.w3i.MAP] = {[lang.w3i.SCRIPT_TYPE] = bytes}}
    end
    w2l.messager = {report = function(title, level, text, details)
        events[#events + 1] = {title = title, level = level, text = text, details = details}
    end}
    return w2l
end

local valid = 'function main takes nothing returns nothing\r\n    call BJDebugMsg("Test")\r\nendfunction\r\n'
local w2l = converter()
local files = {['war3map.j'] = '\239\187\191' .. valid}
local original = files['war3map.j']
local function provider(name) return files[name] end
local function passed(sources)
    assert(sources['war3map.j'] == original, 'The adapter must pass original bytes to its validation-only runner')
    return {exit_code = 0, raw_output = 'Parse successful: 10 lines: 10\n'}
end
local function check(options) return checker.verify(w2l, provider, 'Input', options or {run = passed}) end

local result = check()
assert(result.status == 'Passed' and result.target.status == 'Passed')
assert(result.dataset == 'warcraft-current' and result.script_path == 'war3map.j')
assert(files['war3map.j'] == original)
checker.report(w2l, result)
assert(#events > 0)
for _, event in ipairs(events) do
    assert(event.level == 8, 'pjass must not contribute conversion errors or warnings')
    assert(type(event.details) == 'string')
end

result = check {run = function()
    return {exit_code = 1, raw_output = 'war3map.j:2: Undeclared function Missing\nParse failed: 1 error total\n'}
end}
assert(result.status == 'Failed' and #result.diagnostics > 0)
assert(result.raw_output:find('Undeclared function', 1, true))
result = check {run = function()
    return {exit_code = 0, raw_output = '1 errors ignored\nParse successful: 10 lines: 10\n'}
end}
assert(result.status == 'Failed' and result.target.ignored_errors == 1,
    'Suppressed errors must never count as a verification pass')
result = check {run = function() return {exit_code = 0, raw_output = 'unexpected response'} end}
assert(result.status == 'Unavailable', 'An exit code alone cannot prove a pjass pass')
result = check {executable = context.root .. '/build/definitely-missing-pjass'}
assert(result.status == 'Unavailable')
local load = w2l.mpq_load
w2l.mpq_load = function() end
result = check()
assert(result.status == 'Unavailable' and result.diagnostics[1]:find('dataset', 1, true))
w2l.mpq_load = load

files['war3map.w3i'] = 'Lua'
files['war3map.lua'] = 'function main() end\n'
result = check {run = function() error('Lua maps must not launch pjass') end}
assert(result.status == 'Skipped')
files['war3map.w3i'] = nil
result = check()
assert(result.status == 'Skipped', 'Ambiguous scripts without W3I metadata must be explicit')
files['war3map.w3i'] = 'JASS'
result = check()
assert(result.status == 'Passed', 'The authoritative W3I language selects JASS')
files['war3map.lua'], files['war3map.w3i'] = nil, nil
files['scripts\\war3map.j'] = 'different script'
result = check()
assert(result.status == 'Skipped' and result.diagnostics[1]:find('differ', 1, true))
files['scripts\\war3map.j'] = original
result = check()
assert(result.status == 'Passed')
files['war3map.j'] = nil
result = check()
assert(result.status == 'Passed' and result.script_path == 'scripts\\war3map.j')
files['war3map.j'], files['scripts\\war3map.j'] = original, nil
files['war3map.w3i'] = 'unreadable'
result = check()
assert(result.status == 'Skipped')
files['war3map.w3i'] = nil

local run_count = 0
files['common.j'] = 'map replacement common.j'
result = check {run = function(sources)
    run_count = run_count + 1
    if run_count == 1 then
        assert(sources['common.j'] == w2l:mpq_load('scripts\\common.j'),
            'Map declarations must not mask incompatibility with the selected game dataset')
        return {exit_code = 1, raw_output = 'war3map.j:1: Unknown map native\nParse failed: 1 error total\n'}
    end
    assert(sources['common.j'] == files['common.j'])
    return {exit_code = 0, raw_output = 'Parse successful: 1 lines: 1\n'}
end}
assert(result.status == 'Failed' and result.map_declarations.status == 'Passed' and run_count == 2)
files['scripts\\common.j'] = 'conflicting map common.j'
result = check()
assert(result.status == 'Passed' and result.map_declarations.status == 'Skipped')
files['common.j'], files['scripts\\common.j'] = nil, nil

local archive = {get = function(_, name)
    if name == '.w3x' then return 'LNI marker' end
    if name == 'map\\war3map.j' then return original end
end}
result = checker.check(w2l, archive, 'LNI input', {run = passed})
assert(result.status == 'Passed' and result.phase == 'LNI input')
local bookkeeping = {case = {['war3map.j'] = 'War3Map.J'}, cache = {['sentinel'] = 'retained'}}
function bookkeeping:get(name)
    self.case[name:lower()] = name
    local bytes = name == 'war3map.j' and original or nil
    self.cache[name:lower()] = bytes or false
    return bytes
end
result = checker.check(w2l, bookkeeping, 'Input', {run = passed})
assert(result.status == 'Passed')
assert(bookkeeping.case['war3map.j'] == 'War3Map.J' and bookkeeping.cache['war3map.j'] == nil)
assert(bookkeeping.cache.sentinel == 'retained')
local n = 0; for _ in pairs(bookkeeping.case) do n = n + 1 end
assert(n == 1, 'Checker reads must not rename members or leave missing-file lookup entries')
result = checker.check(w2l, {get = function() error('archive read failed') end}, 'Input')
assert(result.status == 'Unavailable', 'Archive errors are report-only')
local emit = w2l.messager.report
w2l.messager.report = function() error('report unavailable') end
result = checker.check(w2l, archive, 'LNI input', {run = passed})
assert(result.status == 'Passed' and result.reporting_error)
w2l.messager.report = emit
assert(files['war3map.j'] == original)
print('PASS pjass statuses, byte preservation, script language and target/map declaration separation')

-- Exercise process arguments, redirected output, timeout/cancellation and cleanup.
local saved_modules = {}
for _, name in ipairs {'bee.subprocess', 'bee.time', 'bee.thread'} do saved_modules[name] = package.loaded[name] end
local native_sp = require 'bee.subprocess'
local folder = fs.absolute(fs.temp_directory_path()) / ('w2l-pjass-test-%d'):format(native_sp.get_id())
fs.create_directories(folder)
local executable = folder / 'checker-fixture'
local f = assert(io.open(executable:string(), 'wb')); f:write('fixture'); f:close()
local mode, ticks, killed, waited = 'pass', 0, 0, 0
local working_folders = {}
package.loaded['bee.time'] = {monotonic = function() ticks = ticks + 10; return ticks end}
package.loaded['bee.thread'] = {sleep = function() end}
package.loaded['bee.subprocess'] = {
    get_id = native_sp.get_id,
    spawn = function(command)
        assert(command[1] == executable and command.hideWindow == true)
        assert(command.cwd:filename():string():match('^w2l%-pjass%-%d+%-%d+%-%d+$'))
        working_folders[#working_folders + 1] = command.cwd
        local version = command[2] == '-v'
        assert(version or (#command == 4 and command[2] == 'common.j'
            and command[3] == 'blizzard.j' and command[4] == 'war3map.j'),
            'pjass must receive an argument array and fixed ASCII relative input names')
        if mode == 'spawn_error' then return nil, 'fixture spawn failed' end
        if version then
            command.stdout:write('pjass version fixture\n')
        else
            local script_file = assert(io.open((command.cwd / 'war3map.j'):string(), 'rb'))
            local script = script_file:read 'a'; script_file:close()
            assert(script == valid:gsub('\r\n', '\n'), 'Only the temporary input is normalized')
            command.stdout:write('Parse successful: 1 lines: 1\n')
            command.stderr:write('fixture stderr\n')
        end
        local running = not version and (mode == 'timeout' or mode == 'cancel')
        return {
            is_running = function() return running end,
            kill = function() killed = killed + 1; running = false; return true end,
            wait = function() waited = waited + 1; return 0 end,
        }
    end,
}
local ok, process_error = xpcall(function()
    result = check {executable = executable}
    assert(result.status == 'Passed' and result.checker_version == 'pjass version fixture')
    assert(result.raw_output:find('fixture stderr', 1, true))
    mode = 'timeout'
    result = check {executable = executable, timeout_ms = 1}
    assert(result.status == 'Unavailable' and result.diagnostics[1]:find('timed out', 1, true))
    mode = 'cancel'
    result = check {executable = executable, cancelled = function() return true end}
    assert(result.status == 'Unavailable' and result.diagnostics[1]:find('cancelled', 1, true))
    mode = 'spawn_error'
    result = check {executable = executable}
    assert(result.status == 'Unavailable')
    assert(killed == 2 and waited >= 6)
    for _, path in ipairs(working_folders) do assert(not fs.exists(path), 'Temporary checker files must be removed') end
end, debug.traceback)
for name, module in pairs(saved_modules) do package.loaded[name] = module end
for _, name in ipairs {'bee.subprocess', 'bee.time', 'bee.thread'} do
    if saved_modules[name] == nil then package.loaded[name] = nil end
end
fs.remove_all(folder)
assert(ok, process_error)
assert(files['war3map.j'] == original)
print('PASS pjass process arguments, timeout, cancellation, raw diagnostics and temporary cleanup')

-- Use the real, pinned helper when available. CI requires it, so a skip cannot pass CI.
local real_executable = os.getenv('W2L_PJASS')
if not real_executable then
    assert(os.getenv('W2L_REQUIRE_PJASS') ~= '1', 'W2L_REQUIRE_PJASS=1 but W2L_PJASS is not configured')
    print('SKIP real pjass integration: set W2L_PJASS')
else
    assert(fs.is_regular_file(fs.path(real_executable)), 'W2L_PJASS is missing')
    local function real(dataset, script)
        local c = converter(dataset)
        return checker.verify(c, function(name) if name == 'war3map.j' then return script end end,
            'Real checker', {executable = real_executable, script_type = 'JASS'})
    end
    for _, dataset in ipairs {'warcraft-current', 'enUS-1.27.1', 'zhCN-1.24.4'} do
        result = real(dataset, original)
        assert(result.status == 'Passed', dataset .. ': ' .. result.raw_output .. table.concat(result.diagnostics, '\n'))
    end
    result = real('warcraft-current', 'function main takes nothing returns nothing\n    call SetMapName(42)\nendfunction\n')
    assert(result.status == 'Failed' and #result.diagnostics > 0 and result.raw_output ~= '')
    result = real('warcraft-current', 'function main takes nothing returns nothing\n    local integer n =\nendfunction\n')
    assert(result.status == 'Failed' and #result.diagnostics > 0)
    result = real('warcraft-current', '//# +nosemanticerror\nfunction main takes nothing returns nothing\n    call MissingFunction()\nendfunction\n')
    assert(result.status == 'Failed' and result.target.ignored_errors > 0,
        'Real pjass suppression must not become a pass: ' .. result.raw_output)
    local modern = 'function main takes nothing returns nothing\n    call BlzResetUnitTalents(null)\nendfunction\n'
    result = real('warcraft-current', modern)
    assert(result.status == 'Passed', result.raw_output)
    result = real('enUS-1.27.1', modern)
    assert(result.status == 'Failed' and #result.diagnostics > 0,
        'Modern native must fail against the selected legacy declarations')
    -- Check real existing optimization and WTS expansion, without saving a map.
    local transformed = {['war3map.j'] = 'function main takes nothing returns nothing\n    call BJDebugMsg("TRIGSTR_000")\nendfunction\n'}
    local transform = context.core()()
    local transform_errors = {}
    transform:set_messager {report = function(_, level, text, detail)
        if level == 1 or level == 2 then transform_errors[#transform_errors + 1] = tostring(text) .. tostring(detail) end
    end}
    transform:set_setting {mode = 'obj', data = 'warcraft-current', optimize_jass = true,
        confused = true, confusion = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'}
    function transform:file_load(_, name) return transformed[name:lower()] end
    function transform:file_save(_, name, bytes) transformed[name:lower()] = bytes end
    function transform:mpq_load(name) return w2l:mpq_load(name) end
    transform.input_ar = {}
    assert(real('warcraft-current', transformed['war3map.j']).status == 'Passed')
    transform:backend_optimizejass()
    local wts = transform:frontend_wts('STRING 0\n{\nExpanded "quote" and \\ path\n}\n')
    transform:backend_convertjass(wts)
    assert(#transform_errors == 0, table.concat(transform_errors, '\n'))
    assert(not transformed['war3map.j']:find('TRIGSTR_000', 1, true))
    assert(transformed['war3map.j']:find('Expanded', 1, true))
    result = real('warcraft-current', transformed['war3map.j'])
    assert(result.status == 'Passed', result.raw_output)
    assert(files['war3map.j'] == original)
    print('PASS real pjass current/legacy declarations, syntax/type errors, suppressed diagnostics and transformed WTS script')

    -- Exercise real backend transformations of the same minimal regressions.
    -- These check parsing with the pinned helper in addition to explicit dynamic
    -- callback assertions; checker success alone does not prove ExecuteFunc routing.
    local obfuscation_cases = dofile(context.root .. '/test/compat/obfuscation_cases.lua')
    obfuscation_cases(function(script, setting)
        local candidate = {['war3map.j'] = script}
        local conversion = context.core()()
        local errors = {}
        conversion:set_messager {report = function(_, level, text, detail)
            if level == 1 then errors[#errors + 1] = tostring(text) .. tostring(detail) end
        end}
        conversion:set_setting {mode = 'slk', data = 'warcraft-current', optimize_jass = true,
            confused = setting.confused, confusion = setting.confusion}
        conversion.input_ar = {}
        function conversion:file_load(_, name) return candidate[name:lower()] end
        function conversion:file_save(_, name, bytes) candidate[name:lower()] = bytes end
        function conversion:mpq_load(name) return w2l:mpq_load(name) end
        conversion:backend_optimizejass()
        assert(#errors == 0, table.concat(errors, '\n'))
        return candidate['war3map.j']
    end, function(script, label)
        local checked = real('warcraft-current', script)
        assert(checked.status == 'Passed', label .. ': ' .. checked.raw_output ..
            table.concat(checked.diagnostics, '\n'))
    end)
end

-- Exercise the actual conversion orchestration without native archive writes.
local modules = {'share.messager', 'backend.sandbox_core', 'map-builder',
    'backend.unpack_setting', 'backend.plugin', 'backend.w2l_path', 'backend.jass_verify'}
local saved = {}
for _, name in ipairs(modules) do saved[name] = package.loaded[name] end
local conversion_folder = fs.absolute(fs.temp_directory_path()) / ('w2l-pjass-convert-test-%d'):format(native_sp.get_id())
fs.create_directories(conversion_folder)
local conversion_ok, conversion_error = xpcall(function()
    local input, output = conversion_folder / 'input.w3x', conversion_folder / 'output.w3x'
    local input_files = {['war3map.j'] = original, ['(listfile)'] = 'war3map.j\n'}
    local final_bytes = 'function main takes nothing returns nothing\n    call MissingAfterWTS("Expanded text")\nendfunction\n'
    local output_files, phases, exits, conversion_events = {}, {}, {}, {}
    local function ar(data)
        return {get = function(_, name) return data[name] end, get_type = function() return 'mpq' end,
            number_of_files = function() return 1 end, close = function() end}
    end
    local fake = converter()
    fake.progress = setmetatable({start = function() end, finish = function() end}, {__call = function() end})
    function fake:set_messager(value) self.messager = value end
    function fake:set_setting(value) self.setting = value; self.setting.target_storage = 'mpq' end
    function fake:add_plugin() end
    function fake:call_plugin()
        assert(#phases == 1 and phases[1].phase == 'Before conversion', 'Input verification must precede plugins')
    end
    function fake:frontend(slk) slk.w3i = {[lang.w3i.MAP] = {[lang.w3i.SCRIPT_TYPE] = 'JASS'}} end
    function fake:backend() output_files['war3map.j'] = 'intermediate TRIGSTR_1' end
    function fake:save() output_files['war3map.j'] = final_bytes end
    function fake:failed(err) error(err) end
    local logger = {}
    for _, name in ipairs {'text', 'title', 'progress'} do logger[name] = function() end end
    function logger.report(_, level, text, detail)
        conversion_events[#conversion_events + 1] = {level = level, text = text, detail = detail}
    end
    function logger.exit(status) exits[#exits + 1] = status end
    package.loaded['share.messager'] = logger
    package.loaded['backend.sandbox_core'] = function() return fake end
    package.loaded['backend.unpack_setting'] = function() return {input = input, output = output, data = 'warcraft-current', mode = 'obj'} end
    package.loaded['backend.plugin'] = function() end
    package.loaded['backend.w2l_path'] = conversion_folder
    local saved_output = false
    package.loaded['map-builder'] = {
        load = function(path, mode)
            if path == input then return ar(input_files) end
            assert(path == output)
            if mode == 'w' then return ar(output_files) end
            assert(saved_output, 'Output must be saved and reopened before final verification')
            return ar(output_files)
        end,
        save = function() saved_output = true end,
    }
    package.loaded['backend.jass_verify'] = {check = function(c, a, phase, options)
        options = options or {}
        options.run = function(sources)
            local script = sources['war3map.j']
            phases[#phases + 1] = {phase = phase, bytes = script}
            if script == original then return {exit_code = 0, raw_output = 'Parse successful: 1 lines: 1\n'} end
            assert(script == final_bytes, 'Final verification must see WTS-expanded saved bytes')
            return {exit_code = 1, raw_output = 'war3map.j:2: Undeclared function MissingAfterWTS\nParse failed: 1 error total\n'}
        end
        return checker.check(c, a, phase, options)
    end}
    local convert = assert(loadfile(context.root .. '/script/backend/convert.lua'))()
    convert('obj')
    assert(#phases == 2 and phases[2].phase == 'After conversion' and phases[2].bytes == final_bytes)
    assert(#exits == 1 and exits[1] == 'success', 'A pjass failure must not change the existing conversion exit status')
    assert(output_files['war3map.j'] == final_bytes, 'A pjass failure must not block or alter saved output')
    for _, event in ipairs(conversion_events) do assert(event.level == 8) end
end, debug.traceback)
for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
fs.remove_all(conversion_folder)
assert(conversion_ok, conversion_error)
print('PASS conversion checks before plugins and after saved WTS output; pjass failures remain report-only')
