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
function path_mt:is_absolute() return self.value:sub(1, 1) == '/' or self.value:match('^%a:[/\\]') ~= nil end

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
    function methods:setenabled(enabled) self.enabled = enabled end
    function methods:isenabled() return self.enabled ~= false end
    function methods:setchecked(checked) self.checked = checked end
    function methods:ischecked() return self.checked or false end
    function methods:schedulepaint() self.paints = (self.paints or 0) + 1 end
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
        Button = {create = function(options)
            local view = control('Button')
            view.options = type(options) == 'table' and options or {}
            view:settitle(type(options) == 'table' and options.title or options)
            return view
        end},
        Entry = {create = function()
            local view = control('Entry')
            function view:gettext()
                observed.entry_reads = (observed.entry_reads or 0) + 1
                return self.text
            end
            return view
        end},
        TextEdit = {create = function(options)
            local view = control('TextEdit'); view.options = options; return view
        end},
        Scroll = {create = function() return control('Scroll') end},
        Canvas = {createformainscreen = function(size)
            local painter = {}
            for _, method in ipairs {'setfillcolor', 'beginpath', 'moveto', 'lineto', 'closepath', 'fill', 'drawcanvas'} do
                painter[method] = function() end
            end
            return {getpainter = function() return painter end, size = size}
        end},
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
        ['gui.new.theme'] = true,
        ['gui.new.key_activation'] = true,
        ['gui.new.page.select'] = true,
        ['gui.new.template.container'] = true,
        ['gui.new.template.label'] = true,
        ['gui.new.template.button'] = true,
        ['gui.new.template.checkbox'] = true,
        ['gui.new.template.tree'] = true,
        ['gui.new.template.progress'] = true,
        ['gui.new.template.textedit'] = true,
        ['gui.new.template.entry'] = true,
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
    if button.options and button.options.type == 'checkbox' then button:setchecked(not button:ischecked()) end
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
    assert(native.minimum.width >= 400, 'Keep a usable minimum content width')
    assert(native.minimum.height >= 600, 'Keep a usable minimum content height')
    assert(native.contentsize.width >= 720, 'Use a wide initial report window')
    assert(native.contentsize.height >= 600, 'Use a tall initial conversion window')
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
    window:set_theme('W3x2Slk', app.require('gui.new.theme').modes.slk)
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


-- The actual widget factories must apply foreground and visibility defaults.
-- In particular, hiding a parent container must not leave an archive output
-- label/entry on unrelated conversion pages.
local function contrast(first, second)
    local function luminance(color)
        assert(type(color) == 'string' and color:match('^#%x%x%x%x%x%x$'),
            'Readable theme colors must use explicit RGB values')
        local values = {}
        for i = 2, 6, 2 do
            local value = tonumber(color:sub(i, i + 1), 16) / 255
            values[#values + 1] = value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055)^2.4
        end
        return values[1] * 0.2126 + values[2] * 0.7152 + values[3] * 0.0722
    end
    local a, b = luminance(first), luminance(second)
    return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05)
end

for _, locale in ipairs {'enUS', 'zhCN'} do
    local app = create_app(locale)
    local ui = app.require('gui.new.template')
    local palette = app.require('gui.new.theme')
    for _, background in ipairs {palette.background, palette.surface, palette.raised,
        palette.hover, palette.error, palette.warning} do
        assert(contrast(palette.text, background) >= 4.5,
            'Primary text needs readable contrast on every control surface')
    end
    for _, background in pairs(palette.modes) do
        assert(contrast(palette.text, background) >= 4.5, 'Every format accent must support readable text')
    end
    assert(contrast(palette.muted, palette.background) >= 4.5, 'Hints must remain readable')
    local activations = 0
    local view, data, elements = ui.create(ui.container {
        id = 'parent', bind = {visible = 'panel.visible'},
        ui.label {id = 'caption', text = 'Visible state', bind = {visible = 'caption.visible'}},
        ui.container {id = 'static_parent', visible = false},
        ui.label {id = 'static_label', text = 'Hidden label', visible = false},
        ui.label {id = 'color_label', text = 'Bound color', bind = {text_color = 'foreground'}},
        ui.button {id = 'button', title = 'Readable action', bind = {enabled = 'action.enabled'},
            on = {click = function() activations = activations + 1 end}},
        ui.checkbox {id = 'checkbox', text = 'Readable setting', bind = {value = 'setting'}},
        ui.checkbox {id = 'checkbox_mirror', text = 'Shared setting', bind = {value = 'setting'}},
        ui.tree {id = 'tree', text = 'Readable advanced settings'},
    }, {panel = {visible = false}, caption = {visible = false}, action = {enabled = false}, setting = false, foreground = palette.muted})
    assert(not view.visible and not elements.caption.visible,
        'Real container and label factories must honor initial false visibility')
    assert(not elements.static_parent.visible and not elements.static_label.visible,
        'Static visibility must use the same widget contract')
    data.panel.visible, data.caption.visible = true, true
    assert(view.visible and elements.caption.visible)
    data.panel.visible, data.caption.visible = false, false
    assert(not view.visible and not elements.caption.visible,
        'Visibility bindings must update real native-boundary widgets')
    equal(elements.color_label.color, palette.muted, 'Explicit text-color bindings must override the default')
    data.foreground = palette.text
    equal(elements.color_label.color, palette.text, 'Text-color binding updates must reach the real label factory')
    equal(elements.caption.color, palette.text, 'Plain labels must use an explicit readable foreground')
    equal(elements.button.color, palette.text, 'Plain buttons must use an explicit readable foreground')
    assert(not elements.button.enabled, 'A bound unavailable action must disable its native button')
    data.action.enabled = true
    assert(elements.button.enabled)
    data.action.enabled = false
    assert(not elements.button.enabled, 'Enabled bindings must update the actual native-boundary button')
    for _, label in ipairs(descendants(elements.checkbox, 'Label')) do
        if label.text ~= '' then equal(label.color, palette.text, 'Checkbox text must use readable foreground') end
    end
    for _, label in ipairs(descendants(elements.tree, 'Label')) do
        if label.text ~= '' then equal(label.color, palette.text, 'Advanced headers must use readable foreground') end
    end
    if elements.button.onmouseenter then elements.button:onmouseenter() end
    equal(elements.button.color, palette.text, 'Hover must not reset button text to native black')
    assert(contrast(elements.button.color, elements.button.background) >= 4.5)
    if elements.button.onmouseleave then elements.button:onmouseleave() end
    assert(contrast(elements.button.color, elements.button.background) >= 4.5)
    local action = elements.button
    equal(action:onkeydown {key = 'Space', modifiers = 0}, true)
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    action:onclick()
    equal(activations, 0, 'Disabled action must ignore keyboard and click activation')
    data.action.enabled = true
    for _ = 1, 4 do
        equal(action:onkeydown {key = 'SPACE', modifiers = 0}, true)
        equal(activations, 0, 'Action Space autorepeat must wait for release')
    end
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    equal(activations, 1, 'Action Space release must activate exactly once')
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    equal(activations, 1, 'Action release without a press must not activate')
    equal(action:onkeydown {key = 'Return', modifiers = 0}, true)
    equal(action:onkeyup {key = 'Enter', modifiers = 0}, true)
    equal(activations, 2, 'Ordinary action must support Return/Enter alias activation')
    equal(action:onkeydown {key = 'Enter', modifiers = 0}, true)
    equal(action:onkeyup {key = 'Return', modifiers = 0}, true)
    equal(activations, 3)
    equal(action:onkeydown {key = 'Space', modifiers = app.gui.Event.maskcontrol}, false)
    equal(action:onkeyup {key = 'Space', modifiers = app.gui.Event.maskcontrol}, false)
    equal(activations, 3, 'Modified action keys must not activate')
    equal(action:onkeydown {key = 'Space', modifiers = 0}, true)
    data.action.enabled = false
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    equal(activations, 3, 'Disabling an action between press/release must prevent activation')
    data.action.enabled = true
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    equal(activations, 3, 'A disabled release must clear the armed key before enabling again')
    equal(action:onkeydown {key = 'Space', modifiers = 0}, true)
    action:onclick()
    equal(activations, 4, 'Ordinary mouse click must still activate the action')
    equal(action:onkeyup {key = 'Space', modifiers = 0}, true)
    equal(activations, 4, 'Mouse activation must not leave an armed ordinary-button key')
    local checkbox_buttons = descendants(elements.checkbox, 'Button')
    assert(#checkbox_buttons >= 1)
    if checkbox_buttons[1].onclick then click(checkbox_buttons[1])
    else assert(checkbox_buttons[1].onmousedown); checkbox_buttons[1]:onmousedown() end
    equal(data.setting, true, 'Readable checkbox styling must preserve two-way option binding')
    equal(checkbox_buttons[1].color, palette.text, 'Native checkbox titles must use readable foreground')
    data.setting = false
    assert(not checkbox_buttons[1]:ischecked(), 'Programmatic checkbox changes must update the native checkmark')
    local checkbox = checkbox_buttons[1]
    local mirror = descendants(elements.checkbox_mirror, 'Button')[1]
    assert(mirror and checkbox.onkeydown and checkbox.onkeyup,
        'The retained native checkbox needs explicit keyboard activation')
    local function checked(value, message)
        equal(data.setting, value, message)
        equal(checkbox:ischecked(), value, 'Keyboard activation must update the source checkmark')
        equal(mirror:ischecked(), value, 'Keyboard activation must update another binding subscriber')
    end
    for _ = 1, 4 do
        equal(checkbox:onkeydown {key = 'SPACE', modifiers = 0}, true)
        checked(false, 'Space keydown/autorepeat must not toggle before release')
    end
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'One Space release must toggle exactly once after autorepeat')
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'Release without a fresh press must not toggle')
    equal(checkbox:onkeydown {key = 'Return', modifiers = 0}, true)
    checked(true, 'Return keydown must wait for release')
    equal(checkbox:onkeyup {key = 'ENTER', modifiers = 0}, true)
    checked(false, 'Return/Enter aliases must share one activation')
    equal(checkbox:onkeydown {key = 'Enter', modifiers = 0}, true)
    equal(checkbox:onkeyup {key = 'return', modifiers = 0}, true)
    checked(true)
    for _, modifier in ipairs {app.gui.Event.maskcontrol, app.gui.Event.maskalt, app.gui.Event.maskmeta,
        app.gui.Event.maskcontrol | app.gui.Event.maskshift} do
        equal(checkbox:onkeydown {key = 'Space', modifiers = modifier}, false)
        equal(checkbox:onkeyup {key = 'Space', modifiers = modifier}, false)
        checked(true, 'Modified activation keys must not change the option')
    end
    equal(checkbox:onkeydown {key = 'Space', modifiers = 0}, true)
    equal(checkbox:onkeyup {key = 'Space', modifiers = app.gui.Event.maskcontrol}, false)
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'A modified release must disarm the pending plain activation')
    equal(checkbox:onkeydown {key = 'Space', modifiers = 0}, true)
    equal(checkbox:onkeydown {key = 'Tab', modifiers = 0}, false)
    equal(checkbox:onkeyup {key = 'Tab', modifiers = 0}, false)
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'Unrelated Tab navigation must neither toggle nor retain a pending activation')
    equal(checkbox:onkeydown {key = 'Space', modifiers = 0}, true)
    equal(checkbox:onkeyup {key = 'Enter', modifiers = 0}, true)
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'Mismatched activation-key releases must clear the pending press')
    equal(checkbox:onkeydown {key = 'Space', modifiers = app.gui.Event.maskshift}, true)
    equal(checkbox:onkeyup {key = 'Space', modifiers = app.gui.Event.maskshift}, true)
    checked(false, 'Shift alone must not block checkbox activation')
    equal(checkbox:onkeydown {key = 'Space', modifiers = 0}, true)
    click(checkbox)
    checked(true, 'Mouse activation must retain shared option binding')
    equal(checkbox:onkeyup {key = 'Space', modifiers = 0}, true)
    checked(true, 'Mouse activation must clear an armed keyboard toggle')
    print('PASS ' .. locale .. ' actual visibility, readable theme, button/checkbox keyboard and shared binding')

    local window = app.window
    window._filename = path(root .. '/_NarutoRPGPlus1.131testv2_editor3')
    window:show_page('select')
    local selection = window._page
    equal(#descendants(selection, 'Entry'), 0, 'Selection must not offer an archive output field')
    local choices = descendants(selection, 'Button')
    equal(#choices, 3, 'Selection must offer exactly the three existing conversion formats')
    local found = {}
    for _, choice in ipairs(choices) do
        local mode = assert(choice.title:lower():match('(lni)$') or choice.title:lower():match('(slk)$')
            or choice.title:lower():match('(obj)$'), 'Unexpected/retired selection action')
        assert(not found[mode], 'Conversion choice duplicated')
        found[mode] = true
        assert(contrast(choice.color, choice.background) >= 4.5, 'Conversion buttons need readable text')
        if choice.onmouseenter then choice:onmouseenter() end
        assert(contrast(choice.color, choice.background) >= 4.5, 'Hover must preserve conversion action contrast')
        if choice.onmouseleave then choice:onmouseleave() end
        local filename = window._filename
        click(choice)
        equal(window._mode, mode, 'Existing format choice must select its conversion mode')
        equal(window._filename, filename, 'Format choice must preserve LNI folder input')
        equal(window._page, app.convert)
        window:show_page('select')
    end
    assert(found.lni and found.slk and found.obj)
    for _, label in ipairs(descendants(selection, 'Label')) do
        if label.text ~= '' then assert(label.color and label.color ~= '#000', 'Selection labels must not inherit native black') end
    end
    print('PASS ' .. locale .. ' only LNI/OBJ/SLK selection actions, folder preservation and readable labels')
end

-- The reusable Entry template must read user edits back into the binding without
-- touching the report TextEdit's unsafe complete-log getter or recursing on
-- programmatic settext signals.
do
    local app = create_app('enUS')
    local ui = app.require('gui.new.template')
    local tab_events = {}
    local _, data, elements = ui.create(ui.container {
        ui.entry {id = 'output', bind = {text = 'output.text', visible = 'output.visible'},
            on = {tab = function(control, event) tab_events[#tab_events + 1] = {control, event} end}},
        ui.entry {id = 'mirror', bind = {text = 'output.text'}},
    }, {output = {text = root .. '/地图 hráč.optimized.w3x', visible = true}})
    equal(elements.output.text, data.output.text)
    equal(elements.mirror.text, data.output.text)
    equal(app.entry_reads, nil, 'Programmatic entry loads must not read the native text back')
    local edited = root .. '/Edited path/优化 hráč 😀.w3m'
    elements.output:settext(edited)
    equal(data.output.text, edited, 'An editable output must update its binding')
    equal(elements.mirror.text, edited, 'User edits must update another binding subscriber')
    equal(app.entry_reads, 1, 'User edits must read the entry once without recursive signals')
    data.output.text = root .. '/Programmatic next output.w3x'
    equal(elements.output.text, data.output.text)
    equal(elements.mirror.text, data.output.text)
    equal(app.entry_reads, 1, 'Programmatic binding changes must not echo into native reads')
    data.output.visible = false
    assert(not elements.output.visible)
    data.output.visible = true
    assert(elements.output.visible)
    assert(elements.output:onkeydown {key = 'Tab', modifiers = 0})
    assert(elements.output:onkeydown {key = 'tAB', modifiers = app.gui.Event.maskshift})
    equal(#tab_events, 2)
    equal(tab_events[1][1], elements.output)
    equal(tab_events[2][2].modifiers, app.gui.Event.maskshift)
    for _, modifier in ipairs {app.gui.Event.maskcontrol, app.gui.Event.maskalt, app.gui.Event.maskmeta,
        app.gui.Event.maskcontrol | app.gui.Event.maskshift} do
        assert(not elements.output:onkeydown {key = 'Tab', modifiers = modifier})
    end
    assert(not elements.output:onkeydown {key = 'Enter', modifiers = 0})
    assert(not elements.mirror:onkeydown {key = 'Tab', modifiers = 0}, 'Entry without a Tab destination must not consume Tab')
    equal(#tab_events, 2, 'Modified Tab and other keys must not call the focus destination')
    equal(data.output.text, root .. '/Programmatic next output.w3x', 'Keyboard focus navigation must not change output text')
    print('PASS reusable Entry Unicode round-trip, shared binding, visibility, keyboard navigation and recursion guard')
end

-- Exercise the ordinary conversion handlers with a strict path/worker
-- boundary. Retired archive actions have no controls; existing conversion,
-- diagnostics, recovery and process lifecycle coverage remains active.
for _, locale in ipairs {'enUS', 'zhCN'} do
    local app = create_app(locale)
    local labels = app.lang.ui
    local palette = app.require('gui.new.theme')
    local observed = {opens = {}, errors = {}, events = {}, loops = 0, timers = {}, settings = {}}
    local ui = {}
    for _, kind in ipairs {'container', 'button', 'label', 'progress', 'checkbox', 'tree', 'entry', 'scroll'} do
        ui[kind] = function(template) template.class = kind; return template end
    end
    local captured, captured_data = {}, {}
    local elements = {
        config = {addchildview = function() end},
        start = {focus = function() observed.focus = 'start' end},
        filename = {focus = function() observed.focus = 'filename' end},
        change_format = {focus = function() observed.focus = 'change_format' end},
    }
    function ui.create(template, data)
        captured[#captured + 1] = template
        captured_data[#captured_data + 1] = data
        return {setvisible = function() end}, data, elements
    end
    function ui.createEx(template, binding)
        local view = {setvisible = function(self, value) self.visible = value end}
        observed.settings[#observed.settings + 1] = {template = template, binding = binding, view = view}
        return view
    end
    local window = app.window
    window._filename, window._color = path(root .. '/Maps with spaces/input.w3x'), palette.modes.lni
    function window:set_theme(title, color)
        self._color = color
        for _, listener in ipairs(observed.events) do listener(color, title) end
    end
    function window:show_page(name) self.page = name end
    local worker = {exited = true, cancel_file = true}
    function worker:cancel() observed.cancels = (observed.cancels or 0) + 1; return true end
    local backend = {init = function() end}
    function backend:clean()
        self.message, self.progress, self.lastword, self.report_text = '', nil, nil, nil
    end
    function backend:failure(details)
        observed.failures = (observed.failures or 0) + 1
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
    local configuration = {
        lni = {read_slk = true, export_lua = false, extra_check = false},
        obj = {read_slk = true, extra_check = false},
        slk = {remove_unuse_object = true, optimize_jass = false, mdx_squf = false,
            remove_we_only = true, slk_doodad = false, confused = false, extra_check = false},
    }
    local dependencies = {
        ['yue.gui'] = app.gui, ['gui.new.theme'] = palette,
        ['gui.backend'] = backend,
        ['gui.timer'] = {loop = function(_, callback)
            observed.loops = observed.loops + 1
            observed.timers[#observed.timers + 1] = callback
        end},
        ['ffi.messagebox'] = function(...) observed.errors[#observed.errors + 1] = {...} end,
        ['share.lang'] = {ui = labels}, ['share.config'] = configuration,
        ['gui.push_error'] = function() error('Unexpected worker error') end,
        ['gui.new.template'] = ui,
        ['gui.new.databinding'] = function(data) return {proxy = data} end,
        ['gui.event'] = {on = function(_, listener) observed.events[#observed.events + 1] = listener end},
        ['bee.filesystem'] = {path = path, current_path = function() return path(root .. '/script') end},
    }
    local environment = setmetatable({window = window, arg = {[0] = root .. '/bin/w3x2lni-lua.exe'},
        require = function(name) return assert(dependencies[name], 'Unmocked action dependency: ' .. name) end},
        {__index = _G})
    local convert = assert(loadfile(root .. '/script/gui/new/page/convert.lua', 't', environment))()
    local conversion_template, conversion_data = captured[1], captured_data[1]
    local function identified(template, id)
        if template.id == id then return template end
        for _, child in ipairs(template) do
            local found = identified(child, id)
            if found then return found end
        end
    end
    local function visit(template, callback)
        callback(template)
        for _, child in ipairs(template) do visit(child, callback) end
    end
    assert(not identified(conversion_template, 'output_path'), 'Conversion must not retain the retired archive output Entry')
    visit(conversion_template, function(control)
        assert(control.class ~= 'entry', 'Ordinary conversion pages must have no archive destination input')
        assert(control.text ~= rawget(labels, 'OPTIMIZE_SAVE') or control.text == nil,
            'An archive-only label must never appear in SLK/LNI/OBJ')
    end)
    local start_template = assert(identified(conversion_template, 'start'))
    local change_format_template = assert(identified(conversion_template, 'change_format'))
    equal(start_template.bind.enabled, 'actions.enabled', 'Start must expose native busy-state availability')
    equal(start_template.bind.title, 'actions.start_text', 'Start must expose localized processing status')
    equal(change_format_template.bind.enabled, 'actions.enabled', 'Format change must expose native busy-state availability')
    local start = start_template.on.click
    local change_format = change_format_template.on.click
    assert(type(start) == 'function' and type(change_format) == 'function')
    assert(loadfile(root .. '/script/gui/new/page/select.lua', 't', environment))()
    local select_template = captured[2]
    local expected_bindings = {
        lni = {'config.lni.read_slk', 'config.lni.export_lua', 'config.lni.extra_check'},
        obj = {'config.obj.read_slk', 'config.obj.extra_check'},
        slk = {'config.slk.remove_unuse_object', 'config.slk.optimize_jass', 'config.slk.mdx_squf',
            'config.slk.remove_we_only', 'config.slk.slk_doodad', 'config.slk.confused', 'config.slk.extra_check'},
    }
    local actions = {}
    visit(select_template, function(control)
        if control.on and control.on.click then actions[#actions + 1] = control end
    end)
    equal(#actions, 3, 'Only the three conversion actions must remain available')
    local source = window._filename
    for _, mode in ipairs {'lni', 'slk', 'obj'} do
        local choice = assert(identified(select_template, 'to_' .. mode))
        choice.on.click()
        convert:on_show()
        equal(window._mode, mode); equal(window.page, 'convert')
        equal(window._filename, source, 'Changing format must preserve the selected map')
        equal(conversion_data.filename, source:filename():string())
        assert(conversion_data.output == nil, 'Retired output state must not survive on ordinary conversion pages')
        local settings = assert(observed.settings[#observed.settings])
        equal(settings.binding.proxy.config, configuration, 'Option bindings must preserve the original configuration object')
        local bound = {}
        visit(settings.template, function(control)
            if control.bind and control.bind.value then
                bound[control.bind.value] = true
                equal(control.bind.enabled, 'enabled', 'Conversion options must disable while processing')
            end
        end)
        for _, binding in ipairs(expected_bindings[mode]) do
            assert(bound[binding], 'Existing conversion option was lost: ' .. binding)
            bound[binding] = nil
        end
        assert(next(bound) == nil, 'Unexpected conversion option was added')
        assert(settings.view.visible, 'Selected format options must be visible')
        start()
        equal(observed.opens[#observed.opens][1], mode)
        equal(observed.opens[#observed.opens][2], source:string())
        equal(#observed.opens[#observed.opens], 2, 'Ordinary conversion must keep its original default output routing')
    end
    equal(#observed.opens, 3); equal(observed.loops, 3)
    assert(configuration.lni.read_slk and not configuration.lni.export_lua and not configuration.lni.extra_check)
    assert(configuration.slk.remove_unuse_object and configuration.slk.remove_we_only and not configuration.slk.optimize_jass)
    print('PASS ' .. locale .. ' retired archive controls absent; LNI/OBJ/SLK routing and existing options retained')

    -- Read-only report visits and repeated on_show must preserve diagnostics.
    backend.message = 'Existing conversion report'
    backend.lastword = {type = 'warning', content = 'Existing compatibility warning'}
    conversion_data.message = backend.message
    convert:on_show()
    equal(conversion_data.message, backend.message)
    assert(conversion_data.report.visible, 'Returning from a report must keep its report action visible')
    worker.exited = false
    convert:on_show()
    assert(not conversion_data.actions.enabled, 'Busy conversion actions must disable')
    equal(conversion_data.actions.start_text, labels.PROCESSING)
    assert(not observed.settings[#observed.settings].binding.proxy.enabled, 'Busy conversion settings must disable')
    local opens_before_busy, loops_before_busy = #observed.opens, observed.loops
    start()
    equal(#observed.opens, opens_before_busy, 'A running conversion must not start a second worker')
    equal(observed.loops, loops_before_busy)
    window.page = 'convert'
    change_format()
    equal(window.page, 'convert', 'A running conversion must not change formats')
    app.ext.on_dropfile(root .. '/Never read this busy dropped map.w3x')
    equal(window._filename, source, 'A running conversion must reject map drops')

    worker.exited = true
    change_format()
    equal(window.page, 'select', 'Idle conversion must allow choosing another format')
    equal(window._filename, source)
    window.page = 'convert'
    observed.spawn_failure = true
    start()
    equal(#observed.opens, opens_before_busy)
    assert(backend.report_text:find('native spawn failed', 1, true))
    assert(conversion_data.report.visible and not conversion_data.progress.visible)
    equal(conversion_data.report.color, palette.error, 'Failure reports must use the readable error surface')
    observed.spawn_failure = false
    start()
    assert(backend.report_text == nil, 'A successful retry must clear previous diagnostics')
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
    assert(conversion_data.report.visible, 'A timer failure must keep the diagnostic report accessible')
    equal(observed.recoveries, 1); equal(observed.cancels, 1)
    local opens_before_retry = #observed.opens
    start()
    equal(#observed.opens, opens_before_retry, 'Recovery must not start a concurrent worker')
    change_format()
    equal(window.page, 'convert', 'Recovery must not permit a concurrent format change')
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(not removed and not worker.exited, 'Recovery must continue polling until the worker finishes')
    observed.recovery_completed = true
    observed.timers[#observed.timers]({remove = function() removed = true end})
    assert(removed and worker.exited)
    assert(conversion_data.actions.enabled, 'Finished recovery must enable conversion actions')
    equal(conversion_data.actions.start_text, labels.START)
    assert(observed.settings[#observed.settings].binding.proxy.enabled, 'Finished recovery must enable settings')
    start()
    equal(#observed.opens, opens_before_retry + 1, 'A completed recovery must permit a fresh retry')
    assert(backend.report_text == nil, 'Retry must clear the previous failure report')
    assert(not app.loop_quit, 'A startup or update error must not close the application')
    print('PASS ' .. locale .. ' existing reports, spawn/update failures, recovery polling and safe retry')

    local opens_before_close, errors_before_close = #observed.opens, #observed.errors
    local closing_cancelled = false
    window._worker = {exited = false, cancel_file = true, cancel = function() closing_cancelled = true end}
    app.windows[1]:close()
    assert(window._closing and app.loop_quit and closing_cancelled)
    start(); change_format()
    app.ext.on_dropfile(root .. '/Never read this closing map.w3x')
    equal(#observed.opens, opens_before_close, 'Closing application must not launch a worker')
    equal(#observed.errors, errors_before_close, 'Closing application must not touch validation UI')
    equal(window.page, 'convert', 'Closing application must not navigate formats')
    equal(window._filename, source, 'Closing map drop changed the selected input')
    print('PASS ' .. locale .. ' running/closing Start, format-change and map-drop guards preserve source selection')
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
