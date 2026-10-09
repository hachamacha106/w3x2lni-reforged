-- Actual common-dialog calls in a child on an owned non-input desktop.
-- windows_save_dialog.py never displays that desktop and cancels only this PID.
local root = assert(arg[1]):gsub('\\', '/')
local scenario = assert(arg[2])
package.path = root .. '/script/?.lua;' .. root .. '/script/?/init.lua;' .. package.path
package.cpath = root .. '/bin/?.dll;' .. package.cpath
local ffi = require 'ffi'
local choose = require 'ffi.save_file_dialog'
local unicode = require 'ffi.unicode'
assert(ffi.sizeof('void*') == 4 and ffi.sizeof('W2L_OPENFILENAMEW') == 88)
ffi.cdef[[
    void* __stdcall CreateWindowExW(unsigned int exstyle, const wchar_t* cls,
        const wchar_t* title, unsigned int style, int x, int y, int width,
        int height, void* parent, void* menu, void* instance, void* param);
    int __stdcall DestroyWindow(void* hwnd);
    void* __stdcall FindWindowW(const wchar_t* cls, const wchar_t* title);
]]
local user, common = ffi.load('user32'), ffi.load('comdlg32')
local options = {filename='地图 hráč 😀.optimized.w3x', folder=root, title='Save 优化 hráč 😀'}
local invalid = ffi.cast('void*', 0x1234)
assert(user.IsWindow(invalid) == 0, 'Control HWND unexpectedly exists')
local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
local function text(pointer)
    local count = 0
    while pointer[count] ~= 0 do count = count + 1; assert(count < 32768) end
    return unicode.w2u(pointer, count)
end
local function validate(record)
    collectgarbage('collect')
    local value = record[0]
    assert(value.lStructSize == 88 and value.nMaxFile == 32768)
    assert(value.Flags & 0x20 == 0, 'This test must call the unmodified dialog without an OFN hook')
    assert(text(value.lpstrFile) == options.filename and text(value.lpstrTitle) == options.title)
    assert(text(value.lpstrInitialDir) == options.folder and text(value.lpstrDefExt) == 'w3x')
    assert(text(value.lpstrFilter) == 'Warcraft III maps')
end
local native_owner, gui, gui_window
if scenario == 'yue_callback' then
    gui = require 'yue.gui'
    gui_window = gui.Window.create {frame=true}
    gui_window:settitle('W2L private native dialog test')
    gui_window:setcontentsize {width=400, height=300}
    -- The whole process lives on a desktop the controller never displays.
    gui_window:activate()
    native_owner = user.FindWindowW(nil, (unicode.u2w('W2L private native dialog test')))
else
    native_owner = user.CreateWindowExW(0, unicode.u2w('STATIC'),
        unicode.u2w('W2L hidden owned dialog test'), 0x80000000,
        0, 0, 0, 0, nil, nil, nil, nil)
end
assert(native_owner ~= nil and address(native_owner) ~= 0 and user.IsWindow(native_owner) == 1,
    'No valid owned native owner window was created')
local function verify()
    if scenario == 'invalid_owner_control' then
        -- Bypass the adapter deliberately for the control: a real invalid owner
        -- must reproduce the user's exact native creation error before any UI.
        local alive = {file=ffi.new('wchar_t[32768]'), folder=unicode.u2w(options.folder),
            title=unicode.u2w(options.title), extension=unicode.u2w('w3x'),
            filter=unicode.u2w('Warcraft III maps\0*.w3x;*.w3m\0\0')}
        local name, length = unicode.u2w(options.filename)
        ffi.copy(alive.file, name, (length + 1) * 2)
        local record = ffi.new('W2L_OPENFILENAMEW[1]')
        record[0].lStructSize, record[0].hwndOwner = 88, invalid
        record[0].lpstrFile, record[0].nMaxFile = alive.file, 32768
        record[0].lpstrFilter, record[0].nFilterIndex = alive.filter, 1
        record[0].lpstrTitle, record[0].lpstrInitialDir = alive.title, alive.folder
        record[0].lpstrDefExt, record[0].Flags = alive.extension, 0x0289080C
        validate(record)
        local accepted = common.GetSaveFileNameW(record)
        local code = tonumber(common.CommDlgExtendedError())
        assert(accepted == 0 and code == 0xFFFF, 'Invalid owner did not reproduce CDERR_DIALOGFAILURE')
        print('PASS real invalid owner control: CDERR_DIALOGFAILURE 0xFFFF')
        return
    end
    local calls, codes, records = 0, {}, {}
    local selected, diagnostic = choose(options, {
        owner=function() return scenario == 'invalid_owner_adapter' and invalid or native_owner end,
        -- Use the actual Windows predicate rather than a mock validity answer.
        valid=user.IsWindow,
        show=function(record)
            calls = calls + 1
            records[calls] = record
            validate(record)
            if scenario == 'invalid_owner_adapter' or (scenario == 'owner_retry' and calls == 2) then
                assert(address(record[0].hwndOwner) == 0, 'Adapter failed to remove unusable owner')
            else
                assert(record[0].hwndOwner == native_owner, 'Adapter changed a valid owner')
            end
            if scenario == 'owner_retry' and calls == 1 then
                -- A valid HWND may become unsuitable between validation and the
                -- OS call. Force that exact race at the real native boundary.
                record[0].hwndOwner = invalid
            end
            local accepted = common.GetSaveFileNameW(record)
            codes[calls] = tonumber(common.CommDlgExtendedError()) -- Capture before other OS calls.
            if scenario == 'owner_retry' and calls == 1 then
                assert(accepted == 0 and codes[calls] == 0xFFFF)
                record[0].lpstrFile[0] = 65
                record[0].Flags = 0
            end
            return accepted
        end,
        error=function() return codes[calls] end,
    })
    assert(selected == nil and diagnostic == nil, 'Native cancellation failed: ' .. tostring(diagnostic))
    if scenario == 'owner_retry' then
        assert(calls == 2 and codes[1] == 0xFFFF and codes[2] == 0, 'Owner retry did not recover once')
        assert(records[1] ~= records[2], 'Retry reused its mutated OPENFILENAME record')
    else
        assert(calls == 1 and codes[1] == 0, 'Cancellation was retried or treated as an error')
    end
    print('PASS real native Unicode dialog creation/cancellation: ' .. scenario .. ', calls=' .. calls)
end
local ok, failure
if gui then
    gui.MessageLoop.posttask(function()
        ok, failure = xpcall(verify, debug.traceback)
        gui.MessageLoop.quit()
    end)
    gui.MessageLoop.run()
else
    ok, failure = xpcall(verify, debug.traceback)
end
-- This is the exact owned HWND created above, on this child thread.
assert(user.DestroyWindow(native_owner) ~= 0, 'Failed to destroy own test owner')
assert(ok, failure)
print('SAVE_DIALOG_NATIVE|' .. scenario .. '|passed')
