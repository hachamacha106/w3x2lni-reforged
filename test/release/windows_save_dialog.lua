-- Actual controls and common-dialog calls on an owned non-input desktop.
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
    void* __stdcall GetWindow(void* hwnd, unsigned int command);
    int __stdcall GetClassNameW(void* hwnd, wchar_t* cls, int count);
    int __stdcall GetWindowTextLengthW(void* hwnd);
    int __stdcall GetWindowTextW(void* hwnd, wchar_t* text, int count);
    int __stdcall GetWindowLongW(void* hwnd, int index);
    intptr_t __stdcall SendMessageW(void* hwnd, unsigned int message, uintptr_t wparam, intptr_t lparam);
    unsigned int __stdcall GetWindowThreadProcessId(void* hwnd, unsigned int* pid);
    unsigned int __stdcall GetCurrentProcessId(void);
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
local native_owner, gui, gui_window, entry_proxy, entry_control
local tab_events = {}
local entry_initial = root .. '/地图 hráč 😀.optimized.w3x'
if scenario == 'yue_callback' or scenario == 'output_entry' then
    gui = require 'yue.gui'
    gui_window = gui.Window.create {frame=true}
    gui_window:settitle('W2L private native dialog test')
    gui_window:setcontentsize {width=400, height=300}
    if scenario == 'output_entry' then
        -- Use the production Entry template and databinding, not a native Edit
        -- created just for this test or a mock of the template's callbacks.
        local ui = require 'gui.new.template'
        local view, proxy, controls = ui.create(ui.container {
            font={size=14}, style={FlexDirection='column'},
            ui.entry {id='output', style={Height=36}, bind={text='output.text', visible='shown'},
                on={tab=function(control, event)
                    assert(control == entry_control, 'Tab callback received another control')
                    tab_events[#tab_events+1] = event
                end}},
        }, {output={text=entry_initial}, shown=true})
        entry_proxy, entry_control = proxy, controls.output
        gui_window:setcontentview(view)
    end
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
local function verify_entry()
    local kernel = ffi.load('kernel32')
    local own_pid = tonumber(kernel.GetCurrentProcessId())
    local edit, classes = nil, {}
    local function find_edit(parent, depth)
        assert(depth < 12, 'Unexpected native Entry control depth')
        local child, siblings = user.GetWindow(parent, 5), 0 -- GW_CHILD
        while child ~= nil and address(child) ~= 0 do
            siblings = siblings + 1
            assert(siblings < 100, 'Unexpected native Entry sibling count')
            local pid = ffi.new('unsigned int[1]')
            assert(user.GetWindowThreadProcessId(child, pid) ~= 0 and tonumber(pid[0]) == own_pid,
                'Native Entry traversal reached a window not owned by this child')
            local cls = ffi.new('wchar_t[256]')
            local count = user.GetClassNameW(child, cls, 256)
            assert(count > 0, 'Cannot read own native Entry class')
            local name = unicode.w2u(cls, count)
            classes[#classes+1] = name
            if name:lower() == 'edit' or name:lower() == 'richedit50w' then
                assert(not edit, 'Entry template unexpectedly contains multiple native text controls')
                edit = child
            end
            find_edit(child, depth + 1)
            child = user.GetWindow(child, 2) -- GW_HWNDNEXT
        end
    end
    find_edit(native_owner, 0)
    assert(edit, 'No actual native Entry text control: ' .. table.concat(classes, ', '))
    local style = tonumber(user.GetWindowLongW(edit, -16)) -- GWL_STYLE
    assert(style & 0x0004 == 0 and style & 0x1000 == 0, 'Entry is multiline or traps Enter')
    local function native_text()
        local count = tonumber(user.GetWindowTextLengthW(edit))
        assert(count >= 0 and count < 32768)
        local buffer = ffi.new('wchar_t[?]', count + 1)
        assert(tonumber(user.GetWindowTextW(edit, buffer, count + 1)) == count)
        return unicode.w2u(buffer, count)
    end
    local function equal(expected, phase)
        assert(native_text() == expected, 'Native Entry text differs: ' .. phase)
        assert(entry_control:gettext() == expected, 'Native Entry getter truncates or changes text: ' .. phase)
        assert(entry_proxy.output.text == expected, 'Entry databinding differs: ' .. phase)
    end
    equal(entry_initial, 'initial Unicode binding')
    local programmatic = root .. '/输出 změna 😀.optimized.w3x'
    entry_proxy.output.text = programmatic
    equal(programmatic, 'programmatic Unicode update')
    local edited = root .. '/手动 úprava 😀.optimized.w3x'
    local wide = unicode.u2w(edited)
    assert(tonumber(user.SendMessageW(edit, 0x000C, 0,
        ffi.cast('intptr_t', wide))) ~= 0, 'Owned native Entry WM_SETTEXT failed')
    equal(edited, 'actual native Unicode edit')
    -- Long, multibyte paths reveal the retained native getter's limits instead
    -- of passing a regression that only proves ASCII/default suggestions.
    local long = root .. '/' .. ('长á😀'):rep(180) .. '.optimized.w3x'
    local long_wide = unicode.u2w(long)
    assert(tonumber(user.SendMessageW(edit, 0x000C, 0,
        ffi.cast('intptr_t', long_wide))) ~= 0)
    equal(long, 'long actual native edit')
    entry_proxy.output.text = edited
    equal(edited, 'restore before keyboard control checks')
    user.SendMessageW(edit, 0x0102, 13, 1) -- WM_CHAR Enter
    equal(edited, 'Enter remains single-line')
    user.SendMessageW(edit, 0x0100, 9, 0x000F0001) -- WM_KEYDOWN VK_TAB, real native signal
    assert(#tab_events == 1 and tab_events[1].key:lower() == 'tab',
        'Native Entry keydown signal did not forward Tab to its focus handler')
    equal(edited, 'native Tab keydown handler preserves output text')
    -- Direct WM_CHAR bypasses the keydown handler. Keep raw native edits faithful
    -- in the binding so path validation can reject pasted control characters.
    user.SendMessageW(edit, 0x00B1, 0xFFFFFFFF, -1) -- EM_SETSEL: caret at end
    user.SendMessageW(edit, 0x0102, 9, 1) -- WM_CHAR Tab, not a keyboard-navigation test
    equal(edited .. '\t', 'raw native control-character edit remains visible to validation')
    entry_proxy.output.text = edited
    equal(edited, 'restore after raw control-character test')
    print('PASS actual native Entry Unicode/long-path edit and two-way binding; Enter single-line and Tab handler consumed')
end
local function verify()
    if scenario == 'output_entry' then
        verify_entry()
        return
    end
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
