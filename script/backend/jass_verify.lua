-- pjass diagnostics are report-only. Process access stays outside core.
local fs = require 'bee.filesystem'
local root = require 'backend.w2l_path'
local lang = require 'share.lang'

local M = {
    release = 'release-2026-06-15',
    source_commit = '378a1ca9af3848fbc3be3d17069bcdb6a940ee32',
    windows_sha256 = 'e6384d68fbaf4950d68e174945377dbd8b3b7c310c59122651d5a95ec0fb37d6',
}
local sequence = 0

local function diagnostic(result, text)
    result.diagnostics[#result.diagnostics + 1] = text
end

local function read(path)
    local file = assert(io.open(path:string(), 'rb'))
    local bytes = file:read 'a'
    file:close()
    return bytes
end

local function write(path, bytes)
    local file = assert(io.open(path:string(), 'wb'))
    local ok, err = file:write(bytes)
    file:close()
    assert(ok, err)
end

local function validation_copy(bytes)
    -- Only temporary checker inputs change; no map is saved here.
    return (bytes:gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n'))
end

local function temp_folder(sp)
    -- The Windows temp API may include a trailing separator.
    local base = fs.absolute(fs.temp_directory_path() / 'w2l-pjass-parent'):parent_path()
    for _ = 1, 100 do
        sequence = sequence + 1
        local folder = base / ('w2l-pjass-%d-%d-%d'):format(sp.get_id(), os.time(), sequence)
        if fs.create_directory(folder) then return folder, base end
    end
    error('Cannot create a temporary pjass directory')
end

local function capture(executable, arguments, folder, options, modules)
    local stdout_path, stderr_path = folder / 'stdout.txt', folder / 'stderr.txt'
    local stdout, stderr, process
    local ok, result = xpcall(function()
        stdout = assert(io.open(stdout_path:string(), 'wb'))
        stderr = assert(io.open(stderr_path:string(), 'wb'))
        local command = {executable}
        for _, argument in ipairs(arguments) do command[#command + 1] = argument end
        command.cwd, command.hideWindow = folder, true
        command.stdout, command.stderr = stdout, stderr
        local err
        process, err = modules.sp.spawn(command)
        stdout:close()
        stderr:close()
        if not process then
            return {status = 'Unavailable', diagnostics = {'Cannot start pjass: ' .. tostring(err)}, raw_output = ''}
        end
        local start = modules.time.monotonic()
        local reason
        while process:is_running() do
            if options.cancelled and options.cancelled() then
                reason = 'pjass was cancelled; the map conversion is unaffected.'
                break
            end
            if modules.time.monotonic() - start >= (options.timeout_ms or 30000) then
                reason = 'pjass timed out; the map conversion is unaffected.'
                break
            end
            modules.thread.sleep(0.01)
        end
        if reason then process:kill() end
        local exit_code = process:wait()
        local out, errout = read(stdout_path), read(stderr_path)
        local raw = out .. (out ~= '' and errout ~= '' and '\n' or '') .. errout
        return {exit_code = exit_code, stdout = out, stderr = errout, raw_output = raw,
            status = reason and 'Unavailable' or nil, diagnostics = reason and {reason} or {}}
    end, debug.traceback)
    if stdout then pcall(stdout.close, stdout) end
    if stderr then pcall(stderr.close, stderr) end
    if not ok then
        if process then
            pcall(process.kill, process)
            pcall(process.wait, process)
        end
        return {status = 'Unavailable', diagnostics = {'pjass could not run: ' .. tostring(result)}, raw_output = ''}
    end
    return result
end

local function classify(result)
    result.diagnostics = result.diagnostics or {}
    result.raw_output = result.raw_output or ''
    if result.status then return result end
    local raw = result.raw_output or ''
    local ignored = 0
    for count in raw:gmatch('(%d+)%s+errors?%s+ignored') do ignored = ignored + tonumber(count) end
    result.ignored_errors = ignored
    local parsed = raw:find('Parse successful:', 1, true)
    local errors = raw:find('Parse failed', 1, true) or raw:match('failed with %d+ errors?')
    for line in raw:gmatch('[^\r\n]+') do
        if line:match('^.-:%d+:') or line:match('^.-%(%d+%):') then
            diagnostic(result, line)
            errors = true
        end
    end
    if ignored > 0 then
        diagnostic(result, ('pjass ignored %d error(s) through source annotations; this is not a verification pass.'):format(ignored))
    end
    if result.exit_code ~= 0 or errors or ignored > 0 then
        result.status = 'Failed'
        if #result.diagnostics == 0 then diagnostic(result, 'pjass rejected the script; see its raw output.') end
    elseif not parsed then
        result.status = 'Unavailable'
        diagnostic(result, 'pjass returned no recognizable successful parse result.')
    else
        result.status = 'Passed'
    end
    return result
end

local function selected_script(w2l, provider, options, result)
    local jass, nested = provider('war3map.j'), provider('scripts\\war3map.j')
    local lua = provider('war3map.lua') or provider('scripts\\war3map.lua')
    local script_type = options.script_type
    if not script_type then
        local w3i = provider('war3map.w3i')
        if w3i then
            local ok, info = pcall(w2l.frontend_w3i, w2l, w3i)
            if not ok then
                result.status = 'Skipped'
                diagnostic(result, 'The map script language could not be read from war3map.w3i: ' .. tostring(info))
                return
            end
            script_type = info[lang.w3i.MAP] and info[lang.w3i.MAP][lang.w3i.SCRIPT_TYPE]
        end
    end
    if script_type and tostring(script_type):lower() == 'lua' then
        result.status = 'Skipped'
        diagnostic(result, 'pjass does not check Lua map scripts.')
        return
    end
    if script_type and tostring(script_type):lower() ~= 'jass' then
        result.status = 'Skipped'
        diagnostic(result, 'The map declares an unsupported script language: ' .. tostring(script_type))
        return
    end
    if not script_type and lua then
        result.status = 'Skipped'
        diagnostic(result, (jass or nested) and 'Both Lua and JASS scripts are present without authoritative script-language metadata.'
            or 'pjass does not check Lua map scripts.')
        return
    end
    if jass and nested and jass ~= nested then
        result.status = 'Skipped'
        diagnostic(result, 'war3map.j and scripts\\war3map.j differ; neither script was selected for verification.')
        return
    end
    result.script_path = jass and 'war3map.j' or (nested and 'scripts\\war3map.j' or nil)
    if not result.script_path then
        result.status = 'Skipped'
        diagnostic(result, 'No JASS map script is available for pjass.')
        return
    end
    return jass or nested
end

local function declarations(provider, name)
    local a, b = provider(name), provider('scripts\\' .. name)
    if a and b and a ~= b then return nil, true end
    return a or b, false
end

function M.verify(w2l, provider, phase, options)
    options = options or {}
    local result = {status = 'Unavailable', phase = phase or 'Map', dataset = w2l.setting.data,
        diagnostics = {}, raw_output = '', expected_release = M.release, source_commit = M.source_commit}
    local folder, base
    local ok, err = xpcall(function()
        result.status = nil
        local script = selected_script(w2l, provider, options, result)
        if not script then return end
        local common = w2l:mpq_load('scripts\\common.j')
        local blizzard = w2l:mpq_load('scripts\\blizzard.j')
        if not common or not blizzard then
            result.status = 'Unavailable'
            diagnostic(result, 'The selected game dataset is missing common.j or blizzard.j.')
            return
        end
        local executable = options.executable or (root / 'bin' / 'pjass.exe')
        executable = fs.absolute(fs.path(tostring(executable)))
        result.executable = executable:string()
        if not options.run and not fs.is_regular_file(executable) then
            result.status = 'Unavailable'
            diagnostic(result, 'The pjass executable is unavailable: ' .. executable:string())
            return
        end
        local run
        if options.run then
            -- Deterministic regression seam; production uses the process adapter.
            run = options.run
        else
            local modules = {sp = require 'bee.subprocess', time = require 'bee.time', thread = require 'bee.thread'}
            folder, base = temp_folder(modules.sp)
            run = function(sources)
                for name, bytes in pairs(sources) do write(folder / name, validation_copy(bytes)) end
                return capture(executable, {'common.j', 'blizzard.j', 'war3map.j'}, folder, options, modules)
            end
            local version = capture(executable, {'-v'}, folder, options, modules)
            if version.status or version.exit_code ~= 0 or version.raw_output == '' then
                result.status = 'Unavailable'
                diagnostic(result, 'The pjass version could not be read.')
                for _, text in ipairs(version.diagnostics) do diagnostic(result, text) end
                result.raw_output = version.raw_output
                return
            end
            result.checker_version = version.raw_output:gsub('[\r\n]+$', '')
        end
        result.references = {common_bytes = #common, blizzard_bytes = #blizzard}
        result.target = classify(run({['common.j'] = common, ['blizzard.j'] = blizzard, ['war3map.j'] = script}))
        result.status, result.raw_output = result.target.status, result.target.raw_output
        for _, text in ipairs(result.target.diagnostics) do diagnostic(result, text) end
        local map_common, common_conflict = declarations(provider, 'common.j')
        local map_blizzard, blizzard_conflict = declarations(provider, 'blizzard.j')
        if common_conflict or blizzard_conflict then
            diagnostic(result, 'Map declaration copies differ; the separate map-declarations check was skipped.')
            result.map_declarations = {status = 'Skipped', diagnostics = {}, raw_output = ''}
        elseif map_common or map_blizzard then
            result.map_declarations = classify(run({['common.j'] = map_common or common,
                ['blizzard.j'] = map_blizzard or blizzard, ['war3map.j'] = script}))
            diagnostic(result, 'Map-bundled declarations were checked separately and do not replace the target-dataset result.')
        end
    end, debug.traceback)
    if folder and base and folder:parent_path():string() == base:string() then
        local removed, remove_error = pcall(fs.remove_all, folder)
        if not removed then diagnostic(result, 'Could not remove pjass temporary files: ' .. tostring(remove_error)) end
    end
    if not ok then
        result.status = 'Unavailable'
        diagnostic(result, 'pjass verification could not complete: ' .. tostring(err))
    end
    return result
end

function M.report(w2l, result)
    local emit = w2l.messager.report
    local title = 'JASS verification (pjass)'
    emit(title, 8, ('%s: %s'):format(result.phase, result.status),
        ('Report only; conversion result is unaffected. Dataset: %s; script: %s'):format(
            tostring(result.dataset), result.script_path or 'none'))
    if result.checker_version then emit(title, 8, result.checker_version, '') end
    for _, text in ipairs(result.diagnostics) do emit(title, 8, text, '') end
    if result.raw_output ~= '' then emit(title, 8, 'Target dataset: pjass raw output', result.raw_output) end
    if result.map_declarations then
        local map = result.map_declarations
        emit(title, 8, 'Map declarations: ' .. map.status, map.raw_output)
        for _, text in ipairs(map.diagnostics) do emit(title, 8, text, '') end
    end
end

function M.check(w2l, archive, phase, options)
    local result
    local ok, err = xpcall(function()
        local function load(name)
            -- Archive:get caches reads and changes retained member spelling.
            -- Diagnostics must leave that bookkeeping untouched as well.
            local key = name:lower()
            local cases, cache = archive.case, archive.cache
            local previous_case = cases and cases[key]
            local previous_cache = cache and cache[key]
            local loaded, bytes = pcall(archive.get, archive, name)
            if cases then cases[key] = previous_case end
            if cache then cache[key] = previous_cache end
            if not loaded then error(bytes) end
            return bytes
        end
        local lni = load('.w3x') ~= nil
        result = M.verify(w2l, function(name)
            local bytes = load(name)
            if not bytes and lni then bytes = load('map\\' .. name) end
            return bytes
        end, phase, options)
    end, debug.traceback)
    if not ok then
        result = {status = 'Unavailable', phase = phase or 'Map',
            dataset = w2l.setting and w2l.setting.data, diagnostics = {
                'pjass verification could not read the archive: ' .. tostring(err)}, raw_output = ''}
    end
    -- Reporting must not turn an optional checker into a conversion failure.
    local reported, report_error = pcall(M.report, w2l, result)
    if not reported then result.reporting_error = tostring(report_error) end
    return result
end

return M
