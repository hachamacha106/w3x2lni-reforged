-- Exercise the actual report page, window, templates, data bindings and locale
-- files with a strict Yue boundary. The simulated controls retain the strings
-- passed to native widgets and emit change signals synchronously. This checks
-- the Lua contract, not Windows painting, layout, keyboard dispatch or the
-- operating-system clipboard; those still need a practical Windows check.
-- Run: lua /absolute/path/to/w3x2lni/test/compat/gui_report.lua
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/gui_report.lua$'),
    'Run gui_report.lua by its absolute path')

local function equal(actual, expected, message)
    assert(actual == expected, message or 'Unexpected value')
end

local path_mt = {}
path_mt.__index = path_mt
local function path(value) return setmetatable({value = value}, path_mt) end
function path_mt:string() return self.value end
function path_mt:__tostring() return self.value end
function path_mt:__div(suffix) return path(self.value .. '/' .. tostring(suffix)) end
function path_mt:parent_path() return path(assert(self.value:match('^(.*)/[^/]+$'))) end
function path_mt:filename() return path(assert(self.value:match('[^/]+$'))) end

local function create_app(locale)
    local observed = {controls = {}, windows = {}, clipboard = {}, selection_copies = {},
        readonly_calls = {}, report_reads = 0, getfocus_calls = 0}
    local methods = {}
    local function control(kind)
        local view = setmetatable({kind = kind, children = {}, style = {}, visible = true},
            {__index = methods})
        view.hwnd = {} -- An opaque handle, never a title/window search result.
        observed.controls[#observed.controls + 1] = view
        return view
    end
    function methods:setstyle(style)
        for key, value in pairs(style) do self.style[key] = value end
    end
    function methods:setbackgroundcolor(color) self.background = color end
    function methods:setcolor(color) self.color = color end
    function methods:setfont(font) self.font = font end
    function methods:setalign(align) self.align = align end
    function methods:setvalign(align) self.valign = align end
    function methods:setvisible(visible) self.visible = visible end
    function methods:settitle(title) self.title = title end
    function methods:addchildview(child)
        if child.parent then child.parent:removechildview(child) end
        self.children[#self.children + 1] = child
        child.parent = self
    end
    function methods:removechildview(child)
        for i, value in ipairs(self.children) do
            if value == child then
                table.remove(self.children, i)
                child.parent = nil
                return
            end
        end
        error('Cannot remove a child that is not attached')
    end
    function methods:setcontentview(child)
        self.contentview = child
        self:addchildview(child)
    end
    function methods:getcontentview() return self.contentview end
    function methods:setcontentsize(size)
        self.contentsize = {width = size.width, height = size.height}
        self.size_changes = (self.size_changes or 0) + 1
    end
    function methods:setcontentsizeconstraints(minimum, maximum)
        self.minimum = minimum
        self.maximum = maximum
    end
    function methods:sethasshadow(value) self.hasshadow = value end
    function methods:setresizable(value) self.resizable = value end
    function methods:setmaximizable(value) self.maximizable = value end
    function methods:setminimizable(value) self.minimizable = value end
    function methods:center() self.centered = true end
    function methods:activate() self.activated = true end
    function methods:close() self.closed = true; self:onclose() end
    function methods:focus() observed.focused = self end
    function methods:hasfocus() return observed.focused == self end
    function methods:settext(text)
        assert(type(text) == 'string', 'Native text controls require a string')
        self.text = text
        self.settext_calls = (self.settext_calls or 0) + 1
        if self.ontextchange then
            self.change_depth = (self.change_depth or 0) + 1
            assert(self.change_depth < 5, 'Recursive report restoration did not terminate')
            self:ontextchange()
            self.change_depth = self.change_depth - 1
        end
    end
    function methods:gettext()
        error('The complete report must not pass through the old native gettext length limit')
    end
    function methods:selectrange(first, last)
        self.selection = {first, last}
        self.selected_all = false
    end
    function methods:getselectionrange()
        local selection = self.selection or {0, 0}
        return selection[1], selection[2]
    end
    function methods:selectall()
        self.selected_all = true
        self.selectall_calls = (self.selectall_calls or 0) + 1
    end
    function methods:copy()
        local first, last = self:getselectionrange()
        -- Range examples below use the ASCII prefix. This mock deliberately
        -- makes no claim about native Unicode selection-index conversion.
        local selected = self.selected_all and self.text or self.text:sub(first + 1, last)
        observed.selection_copies[#observed.selection_copies + 1] = selected
        observed.clipboard[#observed.clipboard + 1] = selected
    end
    function methods:setscrollbarpolicy(horizontal, vertical)
        self.hpolicy, self.vpolicy = horizontal, vertical
    end

    local default_font = {
        getname = function() return 'Segoe UI' end,
        getsize = function() return 12 end,
    }
    local clipboard = {settext = function(_, text)
        assert(type(text) == 'string')
        observed.clipboard[#observed.clipboard + 1] = text
    end}
    local gui = {
        app = {
            getdefaultfont = function() return default_font end,
            getclipboard = function(_, kind)
                equal(kind, 'copy-paste', 'Copy all must use the normal system clipboard')
                return clipboard
            end,
        },
        Font = {create = function(name, size, weight, style)
            return {name = name, size = size, weight = weight, style = style}
        end},
        Container = {create = function() return control('Container') end},
        Label = {create = function(text)
            local view = control('Label'); view:settext(text); return view
        end},
        Button = {create = function(title)
            local view = control('Button'); view:settitle(title); return view
        end},
        TextEdit = {create = function(options)
            local view = control('TextEdit'); view.options = options; return view
        end},
        Scroll = {create = function() return control('Scroll') end},
        Event = {maskshift = 2, maskcontrol = 4, maskalt = 8, maskmeta = 16},
        Window = {create = function(options)
            local win = control('Window')
            win.options = options
            observed.windows[#observed.windows + 1] = win
            return win
        end},
        MessageLoop = {
            run = function() observed.loop_run = true end,
            quit = function() observed.loop_quit = true end,
        },
    }
    local fs = {
        path = path,
        current_path = function() return path(root .. '/script') end,
        exe_path = function() return path(root .. '/bin/w3x2lni-lua.exe') end,
        exists = function(value)
            local filename = value:string()
            assert(filename == root .. '/script/locale/enUS'
                or filename == root .. '/script/locale/zhCN', 'Unexpected filesystem query')
            return true
        end,
    }
    local convert = control('ConvertBoundary')
    function convert:on_show() self.shows = (self.shows or 0) + 1 end
    local ext = {
        register_window = function(title) equal(title, 'w3x2lni'); observed.registered = true end,
        set_icon = function(filename)
            equal(filename, root .. '/bin/w3x2lni.ico'); observed.icon_set = true
        end,
    }
    local null_handle = {} -- luaffi's NULL is cdata, distinct from Lua nil.
    local ffi = {
        NULL = null_handle,
        cdef = function() observed.ffi_declared = true end,
        C = {
            GetFocus = function()
                observed.getfocus_calls = observed.getfocus_calls + 1
                local focused = observed.focused
                if observed.lose_focus then observed.focused = nil end
                if observed.null_focus == 'sentinel' then return null_handle end
                if observed.null_focus then return nil end
                return focused and focused.hwnd
            end,
            SendMessageW = function(hwnd, message, wparam, lparam)
                local focused = assert(observed.focused, 'Read-only message sent without focus')
                equal(focused.kind, 'TextEdit', 'Read-only message addressed a different control')
                equal(hwnd, focused.hwnd, 'Read-only message addressed the wrong native handle')
                equal(message, 0x00CF, 'Expected EM_SETREADONLY')
                equal(wparam, 1, 'The native edit control must become read-only')
                equal(lparam, 0)
                observed.readonly_calls[#observed.readonly_calls + 1] = hwnd
                return observed.send_result or 1
            end,
        },
    }
    local dependencies = {
        ffi = ffi,
        ['yue.gui'] = gui,
        ['yue-ext'] = ext,
        ['bee.filesystem'] = fs,
        ['gui.backend'] = {},
        ['gui.new.page.convert'] = convert,
        ['share.config'] = {global = {lang = locale}},
        ['backend.w2l_path'] = path(root),
        utility = true,
    }
    local environment = setmetatable({arg = {}, io = {}}, {__index = _G})
    function environment.io.load(value)
        local filename = tostring(value)
        if filename == root .. '/log/report.log' then
            observed.report_reads = observed.report_reads + 1
            return observed.report
        end
        assert(filename == root .. '/script/locale/enUS/ui.lng'
            or filename == root .. '/script/locale/zhCN/ui.lng',
            'Unexpected file read: ' .. filename)
        local file = assert(io.open(filename, 'rb'))
        local text = assert(file:read('a'))
        file:close()
        return text
    end
    local actual_modules = {
        ['gui.new.main'] = true,
        ['gui.new.page.index'] = true,
        ['gui.new.page.report'] = true,
        ['gui.new.template'] = true,
        ['gui.new.databinding'] = true,
        ['gui.new.common_attribute'] = true,
        ['gui.new.template.container'] = true,
        ['gui.new.template.label'] = true,
        ['gui.new.template.button'] = true,
        ['gui.new.template.textedit'] = true,
        ['gui.new.template.scroll'] = true,
        ['gui.event'] = true,
        ['gui.timer'] = true,
        ['share.lang'] = true,
        ['share.changelog'] = true,
        ['share.brand'] = true,
        ['ffi.textedit_readonly'] = true,
    }
    local loaded = {}
    function environment.require(name)
        if dependencies[name] ~= nil then return dependencies[name] end
        if loaded[name] ~= nil then return loaded[name] end
        assert(actual_modules[name], 'Unmocked external dependency: ' .. name)
        local filename = root .. '/script/' .. name:gsub('%.', '/') .. '.lua'
        local result = assert(loadfile(filename, 't', environment))()
        loaded[name] = result == nil and true or result
        return loaded[name]
    end
    observed.require = environment.require
    observed.environment = environment
    observed.convert = convert
    observed.ext = ext
    observed.gui = gui
    environment.require('gui.new.main')
    observed.window = environment.window
    observed.lang = environment.require('share.lang')
    return observed
end

local function descendants(view, kind)
    local found = {}
    local function visit(node)
        if node.kind == kind then found[#found + 1] = node end
        for _, child in ipairs(node.children) do visit(child) end
    end
    visit(view)
    return found
end

local function button_named(view, title)
    for _, button in ipairs(descendants(view, 'Button')) do
        if button.title == title then return button end
    end
    error('Missing button: ' .. tostring(title))
end

local function click(button)
    assert(type(button.onclick) == 'function',
        'Buttons must use native click activation, including the keyboard')
    button:onclick()
end

-- Deliberately exceed 64 KiB and include one very long unbroken Unicode path.
-- A short first/last-line comparison could miss truncated middle diagnostics.
local report_text = table.concat({
    'Input path: E:/WTF2TEST/地图/Příliš_žluťoučký_测试.w3x\r\n',
    'Result: 0 errors, 1 warnings\r\n',
    string.rep('路径_Žluťoučký_', 7000) .. '_END_OF_LONG_PATH\n',
    'Other (1)\nAll objects were retained because preserved data may contain references.\n',
    'Warn (1)\r\nId [brpb] is conflicted between different objects:\r\n',
    '  [Buff] Replenish → [Item] Replenish\n',
    '\tDetails: Ελληνικά; 日本語; 中文; čeština; emoji 🗺️\n',
    'FINAL_DIAGNOSTIC_LINE\n',
})
assert(#report_text > 65536)

for _, locale in ipairs {'enUS', 'zhCN'} do
    local app = create_app(locale)
    equal(#app.windows, 1, 'The application must create one main window')
    local native, window = app.windows[1], app.window
    equal(native.options.frame, true, 'The main window needs a native resize frame')
    assert(native.resizable and native.maximizable and native.minimizable,
        'Native resize, maximize and minimize must all be enabled')
    equal(native.minimum.width, 400, 'Minimum content width changed unexpectedly')
    equal(native.minimum.height, 600, 'Minimum content height changed unexpectedly')
    equal(native.contentsize.width, 720, 'Use a wider initial report window')
    equal(native.contentsize.height, 600)
    assert(app.registered and app.icon_set and app.loop_run)
    local index_page = window._page
    assert(index_page.visible)

    app.report = report_text
    window:show_page('report')
    local report_page = window._page
    assert(report_page ~= index_page and not index_page.visible and report_page.visible,
        'Opening the report did not switch the visible page')
    local text_controls = descendants(report_page, 'TextEdit')
    equal(#text_controls, 1, 'The report must expose its text in a selectable multiline control')
    local edit = text_controls[1]
    equal(edit.text, report_text, 'Opening the report truncated or changed diagnostics')
    equal(app.focused, edit, 'The report must receive keyboard focus when opened')
    assert(edit.style.FlexGrow and edit.style.FlexGrow > 0,
        'The report text area must grow with the window')
    assert(edit.style.Width == nil and edit.style.Height == nil,
        'The report text area must not have a fixed width or line-count height')
    equal(edit.hpolicy, 'never', 'Report lines must wrap instead of scrolling horizontally')
    equal(edit.vpolicy, 'automatic', 'A long report must have vertical scrolling')
    equal(edit.selection[1], 0)
    equal(edit.selection[2], 0, 'A reopened report must begin at the start')
    assert(app.ffi_declared and #app.readonly_calls == 1,
        'Opening the report must request native read-only mode on its focused control')

    local labels = app.lang.ui
    assert(rawget(labels, 'COPY_ALL'), locale .. ' is missing the Copy all translation')
    local copy_button = button_named(report_page, labels.COPY_ALL)
    local back_button = button_named(report_page, labels.BACK)
    click(copy_button)
    equal(app.clipboard[#app.clipboard], report_text,
        'Copy all did not send the complete original report to the clipboard')
    print('PASS ' .. locale .. ' complete Unicode/multiline report over 64 KiB and Copy all')

    local modifiers = app.gui.Event
    assert(type(edit.onkeydown) == 'function')
    for _, key in ipairs {'c', 'C', 'Insert', 'INSERT'} do
        edit:selectrange(0, 10)
        local copies = #app.selection_copies
        equal(edit:onkeydown {key = key, modifiers = modifiers.maskcontrol}, true)
        equal(#app.selection_copies, copies + 1, 'Copy shortcut did not invoke native selection copy')
        equal(app.clipboard[#app.clipboard], 'Input path',
            'Copy selection unexpectedly copied the whole report')
    end
    local selections = edit.selectall_calls or 0
    equal(edit:onkeydown {key = 'A', modifiers = modifiers.maskcontrol}, true)
    equal(edit.selectall_calls, selections + 1, 'Ctrl+A did not select the entire report')
    equal(edit:onkeydown {key = 'c', modifiers = modifiers.maskcontrol}, true)
    equal(app.clipboard[#app.clipboard], report_text)
    for _, event in ipairs {
        {key = 'c', modifiers = 0},
        {key = 'Insert', modifiers = 0},
        {key = 'c', modifiers = modifiers.maskcontrol | modifiers.maskalt},
        {key = 'A', modifiers = modifiers.maskcontrol | modifiers.maskmeta},
        {key = 'Left', modifiers = 0},
    } do
        local copies = #app.selection_copies
        local selections = edit.selectall_calls
        equal(edit:onkeydown(event), false, 'Unrelated key was consumed as a report command')
        equal(#app.selection_copies, copies)
        equal(edit.selectall_calls, selections)
    end
    equal(edit:onkeydown {key = 'Tab', modifiers = 0}, true)
    equal(app.focused, copy_button, 'Tab must move from report text to Copy all')
    equal(edit:onkeydown {key = 'TAB', modifiers = modifiers.maskshift}, true)
    equal(app.focused, back_button, 'Shift+Tab must move from report text to Back')
    equal(edit:onkeydown {key = 'Tab', modifiers = modifiers.maskcontrol}, false)
    equal(app.focused, back_button, 'Modified Tab unexpectedly changed focus')
    print('PASS ' .. locale .. ' selection copy, Ctrl+A/C/Insert, Tab and button activation')

    local set_readonly = app.require('ffi.textedit_readonly')
    local readonly_calls, focus_calls = #app.readonly_calls, app.getfocus_calls
    app.focused = nil
    equal(set_readonly(edit), false)
    equal(app.getfocus_calls, focus_calls, 'Unfocused read-only setup must stop before GetFocus')
    equal(#app.readonly_calls, readonly_calls)

    edit:focus()
    for _, null_kind in ipairs {'nil', 'sentinel'} do
        app.null_focus = null_kind
        equal(set_readonly(edit), false)
        equal(#app.readonly_calls, readonly_calls, 'A null native handle must never receive a message')
    end
    app.null_focus = false
    app.lose_focus = true
    equal(set_readonly(edit), false)
    equal(#app.readonly_calls, readonly_calls, 'Focus loss must prevent a read-only message')
    app.lose_focus = false
    edit:focus()
    app.send_result = 0
    equal(set_readonly(edit), false, 'A rejected native read-only request must report failure')
    equal(#app.readonly_calls, readonly_calls + 1)
    -- Keep native failure enabled for the reload/edit checks below: the Lua
    -- guard must retain canonical text even when native setup cannot succeed.

    -- Native text-change signals are synchronous in this boundary, including
    -- those caused by the restoration itself. Editing must not overwrite the
    -- canonical report or recurse indefinitely.
    assert(type(edit.ontextchange) == 'function', 'The report is missing its edit guard')
    for _, replacement in ipairs {'Attempted replacement', '', report_text .. '\nInjected text'} do
        edit.text = replacement
        edit:ontextchange()
        equal(edit.text, report_text, 'An attempted edit changed the displayed report')
        click(copy_button)
        equal(app.clipboard[#app.clipboard], report_text,
            'An attempted edit changed the report copied to the clipboard')
    end
    assert(type(edit.shouldinsertnewline) == 'function')
    equal(edit:shouldinsertnewline(), false, 'Return must not append editable report content')

    -- A resize belongs to the window, so switching pages and reloading the log
    -- must not reset the user's size or recreate a second report control.
    native:setcontentsize {width = 1280, height = 900}
    local size_changes = native.size_changes
    click(back_button)
    equal(window._page, app.convert, 'Back must return to conversion')
    assert(app.convert.visible and app.convert.shows == 1 and not report_page.visible)
    window:set_theme('W3x2Slk', '#00AD3C')
    equal(native.title, 'W3x2lni Reforged - SLK',
        'The native titlebar must identify the fork and conversion mode')

    local reads = app.report_reads
    for _, fixture in ipairs {
        {text = 'Second report ✓\r\nAnother warning\nLAST_SECOND_REPORT'},
        {text = ''},
        {text = false}, -- A missing log must clear the previous report.
        {text = report_text},
    } do
        app.report = fixture.text
        window:show_page('report')
        local expected = fixture.text or ''
        equal(window._page, report_page, 'Report navigation unexpectedly replaced the page')
        equal(edit.text, expected, 'Reopening the report retained stale or truncated text')
        equal(app.focused, edit)
        click(copy_button)
        equal(app.clipboard[#app.clipboard], expected,
            'Copy all retained a previous report after reload')
        edit.text = 'Attempted edit after reload'
        edit:ontextchange()
        equal(edit.text, expected, 'The edit guard retained stale report data')
        click(copy_button)
        equal(app.clipboard[#app.clipboard], expected)
    end
    equal(app.report_reads - reads, 4, 'Each report visit must reread the latest log')
    equal(native.size_changes, size_changes, 'Page navigation reset the resized window')
    equal(native.contentsize.width, 1280)
    equal(native.contentsize.height, 900)
    assert(not app.convert.visible and report_page.visible)
    native:close()
    assert(app.loop_quit, 'The native close action must still quit the application')
    print('PASS ' .. locale .. ' guarded diagnostics, reload/empty/missing logs and page navigation')
    print('PASS ' .. locale .. ' focused Win32 read-only request and safe failure paths (mock boundary)')
    print('PASS ' .. locale .. ' native resize/maximize/minimize settings and retained window size')
end
