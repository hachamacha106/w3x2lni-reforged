-- Headless checks with the packaged x86 Lua/FFI and real GUI worker process.
-- The Save As call boundary is injected; no interactive dialog is displayed.
return function(directory, lni_directory)
    local ffi = require 'ffi'
    local fs = require 'bee.filesystem'
    local unicode = require 'ffi.unicode'
    local choose = require 'ffi.save_file_dialog'
    local root = fs.current_path():parent_path()
    local output = fs.path(directory)
    assert(ffi.sizeof('wchar_t') == 2 and ffi.sizeof('W2L_OPENFILENAMEW') == 88)
    for name, offset in pairs {lpstrFile=28, lpstrInitialDir=44, lpstrTitle=48,
        Flags=52, lpstrDefExt=60, lCustData=64, FlagsEx=84} do
        assert(ffi.offsetof('W2L_OPENFILENAMEW', name) == offset, 'Save As layout: ' .. name)
    end
    assert(ffi.load('comdlg32').GetSaveFileNameW and ffi.load('comdlg32').CommDlgExtendedError)
    local user = ffi.load('user32')
    assert(user.GetActiveWindow)
    user.GetActiveWindow() -- Real noninteractive HWND query with the declared x86 calling convention.
    local function text(pointer)
        local count = 0
        while pointer[count] ~= 0 do count = count + 1; assert(count < 32768) end
        return unicode.w2u(pointer, count)
    end
    local options = {filename='地图 hráč.optimized.w3x', folder=output:string(), title='Save 优化 hráč 😀'}
    local destination = (output / '选择 hráč 😀.optimized.w3x'):string()
    local owner = ffi.cast('void*', 123)
    local called = false
    local selected = choose(options, {owner=function() return owner end, valid=function() return true end, error=function() error('Unexpected error query') end,
        show=function(record)
            collectgarbage('collect') -- Pointer targets must remain rooted across the native call.
            local value = record[0]
            assert(value.lStructSize == 88 and value.hwndOwner == owner and value.nMaxFile == 32768)
            assert(text(value.lpstrTitle) == options.title and text(value.lpstrInitialDir) == options.folder)
            assert(text(value.lpstrFile) == options.filename and text(value.lpstrDefExt) == 'w3x')
            assert(value.nFilterIndex == 1 and text(value.lpstrFilter) == 'Warcraft III maps')
            local count = 0
            while value.lpstrFilter[count] ~= 0 do count = count + 1 end
            local pattern = value.lpstrFilter + count + 1
            assert(text(pattern) == '*.w3x;*.w3m')
            assert(pattern[11] == 0 and pattern[12] == 0, 'Filter must end in two wide NULs')
            assert(value.Flags & 0x00080000 ~= 0 and value.Flags & 0x00000008 ~= 0)
            assert(value.Flags & 0x00000800 ~= 0 and value.Flags & 0x00010000 ~= 0)
            assert(value.Flags & 0x00000002 == 0 and tonumber(ffi.cast('uintptr_t', value.lpfnHook)) == 0)
            local wide, length = unicode.u2w(destination)
            ffi.copy(value.lpstrFile, wide, (length + 1) * 2)
            called = true
            return 1
        end})
    assert(called and selected == destination and not fs.exists(fs.path(destination)))
    local function rejected(code)
        return choose(options, {owner=function() return nil end, show=function() return 0 end,
            error=function() return code end})
    end
    local cancelled, cancel_error = rejected(0)
    assert(cancelled == nil and cancel_error == nil)
    local failed, diagnostic = rejected(0x3003)
    assert(failed == nil and diagnostic:find('0x3003', 1, true))
    local function retry_case(first_error, second_error, invalid)
        local calls, error_calls, record_one = 0, 0
        local selected, diagnostic = choose(options, {
            owner=function() return owner end,
            valid=function(value) assert(value == owner); return not invalid end,
            error=function() error_calls = error_calls + 1; return calls == 1 and first_error or second_error end,
            show=function(record)
                calls = calls + 1
                if calls == 1 then
                    record_one = record
                    assert(text(record[0].lpstrFile) == options.filename)
                    if invalid then assert(tonumber(ffi.cast('uintptr_t', record[0].hwndOwner)) == 0)
                    else assert(record[0].hwndOwner == owner) end
                    record[0].lpstrFile[0] = 88 -- A failure must not leak a partial name into retry.
                    return 0
                end
                assert(calls == 2 and record ~= record_one)
                collectgarbage('collect')
                assert(tonumber(ffi.cast('uintptr_t', record[0].hwndOwner)) == 0)
                assert(text(record[0].lpstrFile) == options.filename)
                assert(text(record[0].lpstrInitialDir) == options.folder and text(record[0].lpstrTitle) == options.title)
                return 0
            end})
        assert(selected == nil and calls == error_calls)
        return calls, diagnostic
    end
    local count, retry_error = retry_case(0xFFFF, 0)
    assert(count == 2 and retry_error == nil, 'Owner creation failure must retry once; cancellation stays cancellation')
    count, retry_error = retry_case(0xFFFF, 0xFFFF)
    assert(count == 2 and retry_error:find('0xFFFF', 1, true), 'Persistent creation failure must stop and remain visible')
    for _, code in ipairs {0, 0x3003} do
        count, retry_error = retry_case(code, 0)
        assert(count == 1 and (code ~= 0 or retry_error == nil), 'Cancellation and other errors must not retry')
    end
    count, retry_error = retry_case(0xFFFF, 0, true)
    assert(count == 1 and retry_error:find('0xFFFF', 1, true), 'Invalid owners must be discarded before the first call')
    local attempts, error_reads = 0, 0
    local retried = choose(options, {owner=function() return owner end, valid=function() return true end,
        error=function() error_reads = error_reads + 1; return 0xFFFF end,
        show=function(record)
            attempts = attempts + 1
            if attempts == 1 then record[0].lpstrFile[0] = 88; return 0 end
            assert(attempts == 2 and tonumber(ffi.cast('uintptr_t', record[0].hwndOwner)) == 0)
            assert(text(record[0].lpstrFile) == options.filename)
            local wide, length = unicode.u2w(destination)
            ffi.copy(record[0].lpstrFile, wide, (length + 1) * 2)
            return 1
        end})
    assert(retried == destination and attempts == 2 and error_reads == 1 and not fs.exists(fs.path(destination)))
    local null_calls = 0
    local null_result, null_error = choose(options, {owner=function() return ffi.cast('void*', 0) end,
        valid=function() error('NULL owner must not require validation') end,
        error=function() return 0xFFFF end,
        show=function(record)
            null_calls = null_calls + 1
            assert(tonumber(ffi.cast('uintptr_t', record[0].hwndOwner)) == 0)
            return 0
        end})
    assert(null_result == nil and null_calls == 1 and null_error:find('0xFFFF', 1, true))
    assert(not pcall(choose, {filename='bad\0name'}, {}))
    for _, malformed in ipairs {'empty', 'unterminated'} do
        local accepted = pcall(choose, options, {owner=function() return nil end,
            error=function() error('Unexpected error query') end,
            show=function(record)
                if malformed == 'empty' then record[0].lpstrFile[0] = 0
                else for i = 0, 32767 do record[0].lpstrFile[i] = 65 end end
                return 1
            end})
        assert(not accepted, 'Malformed Save As result was accepted: ' .. malformed)
    end
    print('PASS x86 Win32 Save As ABI, rooted Unicode buffers, cancellation and extended errors (headless boundary)')

    local backend = require 'gui.backend'
    local clock, thread = require 'bee.time', require 'bee.thread'
    backend:init(root / 'bin' / 'w3x2lni-lua.exe', root / 'script')
    local function run(entry, arguments)
        local saved_report = root / 'log' / 'report.log'
        if fs.exists(saved_report) then assert(fs.remove(saved_report)) end
        local worker = assert(backend:open(entry, arguments))
        local deadline = clock.monotonic() + 90000
        while not worker.exited do
            if clock.monotonic() > deadline then worker.process:kill(); error('GUI worker timed out') end
            worker:update()
            if not worker.exited then thread.sleep(0.01) end
        end
        assert(worker.closed and backend.lastword, 'Worker lost its final report/result')
        assert(not worker.cancel_folder or not fs.exists(worker.cancel_folder), 'Worker left its cancellation directory')
        assert(not worker.spool_folder or not fs.exists(worker.spool_folder), 'Worker left its output capture directory')
        return io.load(saved_report)
    end
    local before = assert(io.load(output / '地图 hráč' / '来源 hráč.w3x'))
    local report = run('backend/init.lua', {'analyze', lni_directory})
    assert(backend.lastword.type == 'success' and backend.report_text == nil,
        backend.report_text or report or 'Missing GUI worker diagnostics')
    assert(report:find('LNI project size', 1, true) and report:find('Analyze input: Passed', 1, true))
    assert(next(backend.report) and report:find('optimization: analysis only', 1, true))
    local marker_report = run('backend/init.lua', {'analyze', (fs.path(lni_directory) / '.w3x'):string()})
    assert(backend.lastword.type == 'success' and marker_report:find('LNI project size', 1, true))
    local gui_lni = output / 'GUI conversion LNI'
    report = run('backend/init.lua', {'lni', (root / 'test' / 'fixtures' / 'HiTestMapFromWorldEditor.w3x'):string(), gui_lni:string()})
    assert(backend.lastword.type == 'success' and backend.report_text == nil,
        backend.report_text or report or 'GUI conversion result missing')
    assert(fs.exists(gui_lni / '.w3x') and fs.exists(gui_lni / 'map' / 'war3map.j'))
    local archive = output / '地图 hráč' / '来源 hráč.w3x'
    local optimized = output / 'GUI worker 优化.w3x'
    assert(not fs.exists(optimized))
    report = run('backend/init.lua', {'optimize', archive:string(), optimized:string()})
    assert(backend.lastword.type == 'success' and backend.report_text == nil,
        backend.report_text or report or 'Missing GUI worker diagnostics')
    assert(fs.exists(optimized) and #assert(io.load(optimized)) < #before)
    assert(report:find('Optimize input: Passed', 1, true) and report:find('Optimize output: Passed', 1, true))
    assert(io.load(archive) == before)
    assert(io.load(optimized):sub(1, 512) == before:sub(1, 512), 'GUI worker changed the map header')
    local storm = require 'ffi.stormlib'
    local original, reopened = assert(storm.open(archive, true)), assert(storm.open(optimized, true))
    local checked = 0
    for name in assert(original:load_file('(listfile)')):gmatch('[^\r\n]+') do
        local payload = assert(original:load_file(name), 'Unreadable GUI input payload: ' .. name)
        assert(payload == reopened:load_file(name), 'GUI worker changed payload: ' .. name)
        checked = checked + 1
    end
    assert(checked > 0 and original:load_file('(attributes)') == reopened:load_file('(attributes)'))
    assert(original:close() and reopened:close())
    -- A handled archive error still writes its report and delivers the error frame.
    report = run('backend/init.lua', {'optimize', lni_directory, (output / 'Rejected folder.w3x'):string()})
    assert(backend.lastword.type == 'error' and report:find('Optimize requires a packed', 1, true))
    assert(not fs.exists(output / 'Rejected folder.w3x'))
    -- A native/host worker failure may never write report.log: retain current diagnostics in memory.
    local failure = output / 'worker-failure.lua'
    assert(io.save(failure, "io.stderr:write('WORKER_STDERR\\n'); error('WORKER_EXCEPTION')\n"))
    assert(not run(failure:string(), {}), 'Host failure unexpectedly retained a saved report')
    assert(backend.lastword.type == 'error' and backend.report_text:find('WORKER_STDERR', 1, true))
    assert(backend.report_text:find('WORKER_EXCEPTION', 1, true) and not backend.report_text:find('\0', 1, true))
    assert(io.load(archive) == before)
    -- Capture multiple chunks written while polling is paused, including the final
    -- result and stderr after the child has already exited. Pipe read-ahead in
    -- the retained runtime must not make these bytes disappear from the report.
    local tail_script, tail_ready, release = output / 'worker-tail.lua', output / 'tail-ready', output / 'tail-release'
    assert(io.save(tail_script, [[
local fs, thread = require 'bee.filesystem', require 'bee.thread'
local message = require 'share.messager'
message.progress(0)
local ready = assert(io.open(arg[2], 'wb')); assert(ready:write('waiting')); assert(ready:close())
while not fs.exists(fs.path(arg[3])) do thread.sleep(0.01) end
message.report('Capture regression', 8, string.rep('C', 150000), 'COMPLETE_REPORT_TAIL')
io.stderr:write(string.rep('D', 70000) .. '\nCOMPLETE_STDERR_TAIL\n'); io.stderr:flush()
message.exit('success', 'Completed tail worker')
]]))
    local tail = assert(backend:open(tail_script:string(), {'analyze', tail_ready:string(), release:string()}))
    local tail_deadline = clock.monotonic() + 10000
    while not fs.exists(tail_ready) do
        assert(clock.monotonic() < tail_deadline and not tail.exited, 'Tail worker did not start')
        tail:update(); thread.sleep(0.01)
    end
    assert(io.save(release, 'continue'))
    assert(tail.process:wait() == 0) -- Deliberately resume polling only after all output is written.
    while not tail.exited do assert(clock.monotonic() < tail_deadline); tail:update() end
    assert(backend.lastword.type == 'error') -- stderr remains visible despite the child success frame.
    assert(#backend.report['8Capture regression'][1][1] == 150000)
    assert(backend.report_text:find('COMPLETE_REPORT_TAIL', 1, true))
    assert(backend.report_text:find('COMPLETE_STDERR_TAIL', 1, true), 'Final diagnostics were lost')
    assert(tail.error:find(string.rep('D', 70000), 1, true), 'Diagnostic capture skipped middle bytes')
    assert(not fs.exists(tail.cancel_folder), 'Tail worker capture was not cleaned up')

    -- A GUI update error must cancel/reap its owned child before allowing retry.
    local cooperative, ready = output / 'worker-cooperative.lua', output / 'worker-ready'
    assert(io.save(cooperative, [[
local fs, thread = require 'bee.filesystem', require 'bee.thread'
local marker
for _, argument in ipairs(arg) do marker = argument:match('^%-cancel%-file=(.*)') or marker end
assert(marker)
local ready = assert(io.open(arg[2], 'wb')); assert(ready:write('waiting')); assert(ready:close())
while not fs.exists(fs.path(marker)) do thread.sleep(0.01) end
io.stderr:write('RECOVERY_FINAL_DIAGNOSTIC\n'); io.stderr:flush()
require 'share.messager'.exit('success', 'Late success must not hide recovery failure')
]]))
    local failed_worker = assert(backend:open(cooperative:string(), {'analyze', ready:string()}))
    local deadline = clock.monotonic() + 10000
    while not fs.exists(ready) do
        assert(clock.monotonic() < deadline and not failed_worker.exited, 'Cooperative worker did not start')
        failed_worker:update(); thread.sleep(0.01)
    end
    failed_worker:recover('Native GUI update failure fixture')
    assert(failed_worker.cancel_requested and fs.exists(failed_worker.cancel_file))
    while not failed_worker.exited do
        assert(clock.monotonic() < deadline, 'Cooperative recovery did not finish')
        failed_worker:drain_failure(); if not failed_worker.exited then thread.sleep(0.01) end
    end
    assert(not failed_worker.forced_termination and failed_worker.closed)
    assert(not failed_worker.out_rd and not failed_worker.err_rd and not fs.exists(failed_worker.cancel_folder))
    assert(backend.lastword.type == 'error' and backend.report_text:find('Native GUI update failure fixture', 1, true))
    assert(backend.report_text:find('RECOVERY_FINAL_DIAGNOSTIC', 1, true), 'Recovery lost final worker diagnostics')
    report = run('backend/init.lua', {'analyze', lni_directory})
    assert(backend.lastword.type == 'success' and backend.report_text == nil and report:find('LNI project size', 1, true))
    assert(io.load(archive) == before)
    print('GUI_ARCHIVE_ACTIONS|passed')
    print('PASS native GUI workers: LNI folder/marker Analyze, Optimize, handled rejection, host failure reports and cooperative recovery/retry')
end
