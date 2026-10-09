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
function path_mt:extension() return path(self.value:match('(%.[^/%.]+)$') or '') end
function path_mt:stem() return path(self:filename():string():gsub('%.[^%.]+$', '')) end

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
    local backend = app.require('gui.backend')
    backend.report_text = 'Current GUI startup failure ✓\r\nFull worker diagnostics'
    local failure_reads = app.report_reads
    window:show_page('report')
    equal(edit.text, backend.report_text, 'A startup failure must not display the previous map report')
    click(copy_button)
    equal(app.clipboard[#app.clipboard], backend.report_text)
    equal(app.report_reads, failure_reads, 'An in-memory failure must not read a stale report.log')
    backend.report_text = nil

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


-- Exercise the actual action/Save As handlers with a strict dialog/worker
-- boundary. No native GUI is opened and no map files are written.
for _, locale in ipairs {'enUS', 'zhCN'} do
    local app = create_app(locale)
    local labels = app.lang.ui
    equal(app.require('share.brand').window_title('Analyze'), 'W3x2lni Reforged - Analyze')
    equal(app.require('share.brand').window_title('Optimize'), 'W3x2lni Reforged - Optimize')
    local observed = {opens = {}, dialogs = {}, errors = {}, events = {}, loops = 0, timers = {}}
    local ui = {}
    for _, kind in ipairs {'container', 'button', 'label', 'progress', 'checkbox', 'tree'} do
        ui[kind] = function(template) return template end
    end
    local captured, captured_data = {}, {}
    function ui.create(template, data)
        captured[#captured + 1] = template
        captured_data[#captured_data + 1] = data
        return {setvisible = function() end}, data, {config = {addchildview = function() end}}
    end
    ui.createEx = function() return {} end
    local native_window = {} -- Deliberately distinct from the controller table.
    local window = {_filename = path(root .. '/Maps with spaces/input.w3x'),
        _window = native_window, _color = '#00ADD9'}
    function window:set_theme(title, color)
        self._color = color
        for _, listener in ipairs(observed.events) do listener(color, title) end
    end
    function window:show_page(name) self.page = name end
    local worker = {exited = true}
    function worker:cancel() observed.cancels = (observed.cancels or 0) + 1; return true end
    local backend = {init = function() end}
    function backend:clean()
        self.message, self.progress, self.lastword, self.report_text = '', nil, nil, nil
    end
    function backend:failure(details)
        self.message, self.lastword = labels.FAILED, {type = 'error', content = labels.FAILED}
        self.report_text = tostring(details)
    end
    function worker:recover(details)
        if observed.recovery_setup_failure then error('recovery setup fixture failure') end
        observed.recoveries = (observed.recoveries or 0) + 1
        backend:failure(details)
        self:cancel()
    end
    function worker:drain_failure()
        observed.recovery_polls = (observed.recovery_polls or 0) + 1
        if observed.recovery_completed then self.exited = true; return true end
        return false
    end
    function backend:open(filename, arguments)
        equal(filename, 'backend\\init.lua')
        if observed.spawn_failure then return nil, 'native spawn failed' end
        self:clean()
        observed.opens[#observed.opens + 1] = arguments
        return worker
    end
    local function save_dialog(options)
        observed.dialogs[#observed.dialogs + 1] = options
        if observed.dialog_failure then return nil, 'dialog fixture failure' end
        if not observed.accept_dialog then return nil end
        return observed.destination
    end
    local dependencies = {
        ['ffi.save_file_dialog'] = save_dialog,
        ['gui.backend'] = backend,
        ['gui.timer'] = {loop = function(_, callback)
            observed.loops = observed.loops + 1
            observed.timers[#observed.timers + 1] = callback
        end},
        ['ffi.messagebox'] = function(...) observed.errors[#observed.errors + 1] = {...} end,
        ['share.lang'] = {ui = labels}, ['share.config'] = {},
        ['gui.push_error'] = function() error('Unexpected worker error') end,
        ['gui.new.template'] = ui,
        ['gui.new.databinding'] = function(data) return {proxy = data} end,
        ['gui.event'] = {on = function(_, listener) observed.events[#observed.events + 1] = listener end},
        ['bee.filesystem'] = {path = path, current_path = function() return path(root .. '/script') end,
            exists = function(value) return value:string() == observed.existing end},
    }
    local environment = setmetatable({window = window, arg = {[0] = root .. '/bin/w3x2lni-lua.exe'},
        require = function(name) return assert(dependencies[name], 'Unmocked action dependency: ' .. name) end},
        {__index = _G})
    local convert = assert(loadfile(root .. '/script/gui/new/page/convert.lua', 't', environment))()
    local conversion_template = captured[1]
    local function handler(template, title)
        if template.title == title and template.on and template.on.click then return template.on.click end
        for _, child in ipairs(template) do
            local found = handler(child, title)
            if found then return found end
        end
    end
    local start = assert(handler(conversion_template, labels.START))
    assert(loadfile(root .. '/script/gui/new/page/select.lua', 't', environment))()
    local select_template = captured[2]
    assert(handler(select_template, labels.ANALYZE_MAP))()
    equal(window._mode, 'analyze'); equal(window.page, 'convert')
    start()
    equal(#observed.dialogs, 0, 'Analyze must not ask for an output path')
    equal(#observed.opens, 1)
    equal(observed.opens[1][1], 'analyze'); equal(#observed.opens[1], 2)
    equal(observed.opens[1][2], window._filename:string())
    assert(handler(select_template, labels.OPTIMIZE_MAP))()
    equal(window._mode, 'optimize')
    observed.accept_dialog = false
    start()
    equal(#observed.opens, 1, 'Cancelling Save As must not start a worker')
    local dialog = observed.dialogs[1]
    equal(dialog.title, labels.OPTIMIZE_SAVE)
    equal(dialog.filename, 'input.optimized.w3x')
    equal(dialog.folder, window._filename:parent_path():string())
    observed.accept_dialog = true
    observed.destination = window._filename:string()
    observed.existing = observed.destination
    start()
    equal(#observed.opens, 1, 'Optimize must reject the source or any existing destination')
    equal(#observed.errors, 1)
    observed.destination = root .. '/Maps with spaces/optimized.w3x'
    start()
    equal(#observed.opens, 2)
    equal(observed.opens[2][1], 'optimize')
    equal(observed.opens[2][2], window._filename:string())
    equal(observed.opens[2][3], observed.destination)
    worker.exited = false
    local dialogs = #observed.dialogs
    start()
    equal(#observed.opens, 2, 'A running operation must not start a second worker')
    equal(#observed.dialogs, dialogs)
    equal(observed.loops, 2)
    assert(handler(conversion_template, labels.CANCEL_OPERATION))()
    equal(observed.cancels, 1, 'Cancel must request cooperative worker cleanup')

    local conversion_data = captured_data[1]
    worker.exited = true
    observed.dialog_failure = true
    start()
    equal(#observed.opens, 2, 'A failing picker must not start a worker')
    assert(backend.report_text:find('dialog fixture failure', 1, true))
    assert(conversion_data.report.visible and conversion_data.report.color == '#C33')
    assert(not conversion_data.cancel.visible)
    observed.dialog_failure, observed.spawn_failure = false, true
    start()
    equal(#observed.opens, 2)
    assert(backend.report_text:find('native spawn failed', 1, true))
    assert(conversion_data.report.visible and not conversion_data.progress.visible)
    observed.spawn_failure = false
    start()
    worker.exited = false
    function worker:update() error('timer fixture failure') end
    local removed = false
    observed.recovery_setup_failure = true
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(not removed and backend.report_text:find('recovery setup fixture failure', 1, true))
    assert(backend.report_text:find('timer fixture failure', 1, true))
    observed.recovery_setup_failure = false
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(not removed and backend.report_text:find('timer fixture failure', 1, true))
    assert(conversion_data.report.visible and conversion_data.cancel.visible,
        'A timer failure must keep Report and cooperative cancellation accessible')
    equal(observed.recoveries, 1); equal(observed.cancels, 2)
    local opens_before_retry = #observed.opens
    start()
    equal(#observed.opens, opens_before_retry, 'Recovery must not start a concurrent worker')
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(not removed and not worker.exited, 'Recovery must continue polling until the worker finishes')
    observed.recovery_completed = true
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(removed and worker.exited and not conversion_data.cancel.visible)
    start()
    equal(#observed.opens, opens_before_retry + 1, 'A completed recovery must permit a fresh retry')
    assert(backend.report_text == nil, 'Retry must clear the previous failure report')
    assert(not app.loop_quit, 'A startup or update error must not close the application')

    local closing_cancelled = false
    app.window._worker = {exited = false, cancel_file = true, cancel = function() closing_cancelled = true end}
    app.windows[1]:close()
    assert(closing_cancelled, 'Closing the app must request cancellation of a new archive action')
    print('PASS ' .. locale .. ' Analyze/Optimize routing, guarded Save As, cancellation and no overwrite')
end


-- Actual GUI worker lifecycle with independent named-file readers. All file
-- and process boundaries are simulated; no user files or processes are touched.
do
    local files, folders, observed = {}, {}, {active_readers = 0, readers = 0, writers = {}}
    local fs = {absolute = function(value) return value end,
        temp_directory_path = function() return path(root .. '/Temporary folder') end,
        exists = function(value) local name = value:string(); return files[name] ~= nil or folders[name] ~= nil end,
        create_directory = function(value)
            local name = value:string(); if folders[name] then return false end
            folders[name] = true; return true
        end,
        remove = function(value)
            local name = value:string()
            if name == observed.remove_failure or observed.remove_failure_suffix
                and name:sub(-#observed.remove_failure_suffix) == observed.remove_failure_suffix then
                return false, 'cleanup fixture failure'
            end
            if files[name] ~= nil then files[name] = nil; return true end
            if folders[name] then
                for filename in pairs(files) do
                    if filename:sub(1, #name + 1) == name .. '/' then return false, 'Directory not empty' end
                end
                folders[name] = nil; return true
            end
            return false
        end}
    local mock_io = {}
    function mock_io.open(filename, mode)
        assert(filename:match('/w2l%-worker%-%d+%-%d+%-%d+/[%a]+$'))
        if observed.open_failure and filename:find(observed.open_failure, 1, true) then
            return nil, 'open fixture failure'
        end
        if mode == 'rb' and files[filename] == nil then return nil, 'Missing capture' end
        assert(mode == 'wb' or mode == 'rb')
        local file = {filename = filename, mode = mode, position = 0}
        if mode == 'wb' then files[filename] = ''; observed.writers[#observed.writers + 1] = file
        else observed.readers = observed.readers + 1; observed.active_readers = observed.active_readers + 1 end
        function file:write(bytes)
            assert(self.mode == 'wb' and not self.closed)
            if observed.write_failure and self.filename:match('/cancel$') then return nil, 'write failed' end
            files[self.filename] = files[self.filename] .. bytes
            self.position = self.position + #bytes
            observed.writes = (observed.writes or 0) + 1
            return self
        end
        function file:seek(whence, offset)
            assert(self.mode == 'rb' and not self.closed, 'Parent must never seek the child writer handle')
            if whence == 'end' then
                local length = #files[self.filename]
                self.position = length
                if self.filename:match('/stdout$') and observed.race_on_seek then
                    files[self.filename] = files[self.filename] .. observed.race_on_seek
                    observed.race_on_seek = nil
                end
                return length
            end
            equal(whence, 'set'); assert(offset >= 0 and offset <= #files[self.filename])
            self.position = offset; return offset
        end
        function file:read(size)
            assert(self.mode == 'rb' and not self.closed)
            assert(type(size) == 'number' and size > 0 and size <= 64 * 1024,
                'GUI capture reads must be bounded byte counts')
            if self.filename == observed.read_failure then error('capture fixture failure') end
            local bytes = files[self.filename]:sub(self.position + 1, self.position + size)
            self.position = self.position + #bytes
            return bytes
        end
        function file:close()
            assert(not self.closed, 'Capture handle closed twice')
            self.closed = true
            if self.mode == 'rb' then observed.active_readers = observed.active_readers - 1 end
            if self.mode == 'wb' and observed.writer_close_failures and observed.writer_close_failures > 0 then
                observed.writer_close_failures = observed.writer_close_failures - 1
                return nil, 'writer close fixture failure: ' .. self.filename
            end
            return true
        end
        return file
    end
    local process = {get_id = function() return 1234 end}
    function process.peek() error('GUI workers must not use kernel pipe peek') end
    function process.filemode() error('GUI captures are already opened as standard binary files') end
    function process.spawn(command)
        observed.spawn = command
        assert(type(command.stdout) == 'table' and command.stdout.mode == 'wb')
        assert(type(command.stderr) == 'table' and command.stderr.mode == 'wb')
        if observed.spawn_failure then return nil, 'spawn fixture failure' end
        if observed.spawn_exception then error('spawn fixture exception') end
        files[command.stdout.filename] = observed.stdout or ''
        files[command.stderr.filename] = observed.stderr or ''
        local native = {running = true, outname = command.stdout.filename, errname = command.stderr.filename,
            stdout = command.stdout, stderr = command.stderr}
        function native:is_running()
            if observed.poll_failure then error('status fixture failure') end
            if not self.running and observed.final_stderr_on_exit then
                files[self.errname] = files[self.errname] .. observed.final_stderr_on_exit
                observed.final_stderr_on_exit = nil
            end
            return self.running
        end
        function native:wait()
            if observed.awaiting_marker then assert(files[observed.awaiting_marker], 'Marker removed before worker reaping') end
            assert(files[self.outname] ~= nil and files[self.errname] ~= nil, 'Capture removed before worker reaping')
            observed.waits = (observed.waits or 0) + 1
            return observed.exit_code or 0
        end
        function native:kill()
            observed.kills = (observed.kills or 0) + 1
            if observed.kill_failure then return false end
            self.running = false; return true
        end
        function native:close() observed.process_closes = (observed.process_closes or 0) + 1 end
        return native
    end
    local protocol = assert(loadfile(root .. '/script/share/protocol.lua'))()
    local dependencies = {['bee.subprocess'] = process, ['bee.filesystem'] = fs,
        ['share.protocol'] = protocol, ['share.lang'] = {ui = {FAILED = 'failed'}},
        ['bee.time'] = {monotonic = function() return observed.now or 0 end}}
    local environment = setmetatable({io = mock_io, require = function(name) return assert(dependencies[name], name) end},
        {__index = _G})
    local backend = assert(loadfile(root .. '/script/gui/backend.lua', 't', environment))()
    backend:init(path(root .. '/bin/host.exe'), path(root .. '/script'))
    local function finish(worker)
        worker.process.running = false
        for _ = 1, 128 do if worker:update() then return end end
        error('Mock worker did not complete its bounded drains')
    end
    local function clean()
        assert(next(files) == nil and next(folders) == nil, 'Worker left an owned capture or directory')
        equal(observed.active_readers, 0, 'Capture readers must close after each poll')
        for _, file in ipairs(observed.writers) do assert(file.closed, 'Parent writer handle was retained') end
    end
    local function frame(value) return ('Content-Length: %d\r\n%s'):format(#value, value) end
    local final = frame('{type="report",args={type="Archive",level=8,content="Final inventory",tip="full details"}}')
        .. frame('{type="exit",args={type="success",content="Optimization complete"}}')
    local original = {'optimize', 'input.w3x', 'output.w3x'}
    local worker = assert(backend:open('backend/init.lua', original))
    equal(#original, 3, 'Worker must not mutate caller arguments')
    equal(observed.spawn[6][4], '-cancel-file=' .. worker.cancel_file:string())
    assert(folders[worker.spool_folder:string()] and worker.process.stdout.closed and worker.process.stderr.closed)
    observed.write_failure = true
    equal(worker:cancel(), false, 'Cancellation write failure must be visible')
    observed.write_failure = false
    assert(worker:cancel()); assert(worker:cancel())
    equal(observed.writes, 1, 'Repeated cancellation must be idempotent')
    equal(files[worker.cancel_file:string()], 'cancel')
    finish(worker); clean()
    local plain = assert(backend:open('backend/init.lua', {'obj', 'input.w3x', 'output.w3x'}))
    assert(plain.spool_folder and not plain.cancel_file and not plain:cancel(), 'Plain conversions own captures without a cancel marker')
    finish(plain); clean()
    for _, failure in ipairs {'spawn_failure', 'spawn_exception'} do
        observed[failure] = true
        local failed, err = backend:open('backend/init.lua', {'analyze', 'input.w3x'})
        assert(not failed and err:find('spawn fixture', 1, true))
        observed[failure] = nil; clean()
    end
    observed.open_failure = '/stderr'
    local failed, err = backend:open('backend/init.lua', {'analyze', 'input.w3x'})
    assert(not failed and err:find('open fixture failure', 1, true))
    observed.remove_failure_suffix = '/stdout'
    failed, err = backend:open('backend/init.lua', {'analyze', 'input.w3x'})
    assert(not failed and err:find('open fixture failure', 1, true)
        and err:find('Could not remove owned worker output', 1, true), 'Startup cleanup errors were hidden')
    observed.open_failure, observed.remove_failure_suffix = nil, nil
    for filename in pairs(files) do assert(fs.remove(path(filename))) end
    for folder in pairs(folders) do assert(fs.remove(path(folder))) end
    clean()
    print('PASS GUI named captures, binary redirects, archive cancellation and setup/spawn cleanup')

    -- Append after the reader takes its size snapshot: a fresh next reader
    -- must collect the tail instead of closing because the kernel pipe ended.
    observed.stdout, observed.stderr = final:sub(1, 4), ''
    local finished = assert(backend:open('backend/init.lua', {'optimize', 'in.w3x', 'out.w3x'}))
    observed.race_on_seek = final:sub(5)
    finish(finished)
    equal(backend.lastword.type, 'success')
    equal(backend.report['8Archive'][1][1], 'Final inventory')
    assert(backend.report_text == nil and finished.out_path == nil and finished.err_path == nil)
    clean()
    observed.stdout, observed.stderr = final, 'native worker error\0traceback after NUL'
    local crashed = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
    assert(not crashed:update())
    assert(crashed.out_path and crashed.err_path, 'stderr must not discard captured stdout')
    finish(crashed)
    equal(backend.lastword.type, 'error')
    assert(backend.report_text:find('native worker error', 1, true))
    assert(backend.report_text:find('traceback after NUL', 1, true) and not backend.report_text:find('\0', 1, true))
    assert(backend.report_text:find('Final inventory - full details', 1, true)); clean()
    for _, bytes in ipairs {'Invalid protocol\r\n', final .. 'Content-Length: 100\r\n{'} do
        observed.stdout, observed.stderr = bytes, ''
        local corrupt = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
        finish(corrupt)
        equal(backend.lastword.type, 'error')
        assert(backend.report_text:find('protocol', 1, true)); clean()
    end
    observed.stdout, observed.stderr, observed.exit_code = '', '', 7
    local no_result = assert(backend:open('backend/init.lua', {'obj', 'in.w3x', 'out.w3x'}))
    finish(no_result)
    assert(backend.report_text:find('exit code 7', 1, true)); clean()
    observed.exit_code = 0
    local huge = ('x'):rep(2 * 1024 * 1024)
    observed.stdout = frame('{type="report",args={type="Archive",level=8,content=' .. ('%q'):format(huge) .. ',tip=""}}') .. final
    local large = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
    large.process.running = false
    assert(not large:update() and not large.exited and files[large.out_path:string()], 'Large final drains must yield without cleanup')
    finish(large)
    equal(backend.report['8Archive'][1][1], huge, 'Bounded multi-tick final drain lost payload bytes'); clean()
    print('PASS GUI fresh-reader offsets, raced final tail, complete large reports, malformed/incomplete protocol and diagnostics')

    observed.stdout, observed.stderr = final, 'stderr during recovery'
    local recovering = assert(backend:open('backend/init.lua', {'optimize', 'in.w3x', 'out.w3x'}))
    observed.read_failure = recovering.out_path:string()
    local marker, writes = recovering.cancel_file:string(), observed.writes
    recovering:recover('timer lifecycle failure'); recovering:recover('duplicate recovery request')
    equal(observed.writes, writes + 1, 'Recovery must request cooperative cancellation exactly once')
    assert(files[marker] == 'cancel' and not recovering:drain_failure() and not recovering.exited)
    assert(backend.report_text:find('timer lifecycle failure', 1, true))
    assert(backend.report_text:find('stderr during recovery', 1, true), 'One failed capture prevented draining the other')
    equal(observed.active_readers, 0, 'Read failures must still close the capture reader')
    assert(files[marker], 'A running recovery lost its cancellation marker')
    recovering.process.running = false
    observed.final_stderr_on_exit, observed.awaiting_marker = 'final stderr after status', marker
    assert(recovering:drain_failure() and recovering.exited)
    observed.awaiting_marker, observed.read_failure = nil, nil
    assert(backend.report_text:find('final stderr after status', 1, true))
    assert(backend.lastword.type == 'error', 'A late success frame replaced the recovery failure'); clean()
    observed.stdout, observed.stderr = final, ''
    local retried = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
    assert(retried.process ~= recovering.process and backend.report_text == nil)
    finish(retried); clean()
    observed.stdout, observed.stderr, observed.now = '', '', 0
    local forced = assert(backend:open('backend/init.lua', {'optimize', 'in.w3x', 'out.w3x'}))
    forced:recover('unrecoverable polling failure'); marker = forced.cancel_file:string()
    observed.poll_failure, observed.kill_failure, observed.now = true, true, 30001
    local waits = observed.waits
    assert(not forced:drain_failure() and not forced.exited)
    equal(observed.waits, waits, 'Failed termination must not block in wait() or permit retry')
    assert(files[marker], 'Failed termination discarded its active marker/captures')
    observed.kill_failure, observed.awaiting_marker = false, marker
    assert(forced:drain_failure() and forced.exited)
    observed.awaiting_marker, observed.poll_failure = nil, false
    assert(forced.forced_termination and backend.report_text:find('temporary candidate cleanup could not be verified', 1, true)); clean()
    print('PASS GUI recovery preserves failure, cancels once, drains independently, reaps before cleanup and permits retry')

    observed.stdout, observed.stderr, observed.writer_close_failures = final, '', 2
    local close_failed = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
    assert(close_failed.process.running, 'Post-spawn close failure must retain ownership of the active child')
    finish(close_failed)
    assert(backend.report_text:find('writer close fixture failure', 1, true)
        and backend.report_text:find('/stdout', 1, true) and backend.report_text:find('/stderr', 1, true),
        'Both parent writer close failures must remain visible'); clean()
    local cleanup_failed = assert(backend:open('backend/init.lua', {'analyze', 'in.w3x'}))
    local kept = cleanup_failed.out_path:string()
    observed.remove_failure = kept
    finish(cleanup_failed)
    assert(backend.report_text:find('Could not remove owned worker output', 1, true) and files[kept])
    observed.remove_failure = nil
    assert(fs.remove(path(kept))); assert(fs.remove(cleanup_failed.spool_folder)); clean()
    backend:clean()
    assert(backend.report_text == nil and backend.lastword == nil)
    print('PASS GUI post-spawn handle failures remain owned and nonrecursive cleanup failures stay visible')
end
