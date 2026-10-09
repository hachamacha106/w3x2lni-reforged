local fs = require 'bee.filesystem'
local gui = require 'yue.gui'
local backend = require 'gui.backend'
local lang = require 'share.lang'
local ui = require 'gui.new.template'
local ev = require 'gui.event'
local set_readonly = require 'ffi.textedit_readonly'
local theme = require 'gui.new.theme'
local root = fs.current_path()
local view, data, element

local template = ui.container {
    style = { FlexGrow = 1, FlexBasis = 0, MinHeight = 0, Padding = 16 },
    font = { size = 13 },
    ui.textedit {
        id = 'report_text',
        style = { FlexGrow = 1, FlexBasis = 0, MinHeight = 0 },
        readonly = true,
        -- Retain native text/background colors for the old RichEdit control.
        font = { name = 'Consolas', size = 13 },
        bind = {
            text = 'report.text'
        },
        on = {
            tab = function(_, event)
                if event.modifiers & gui.Event.maskshift ~= 0 then
                    element.back:focus()
                else
                    element.copy_report:focus()
                end
            end,
        },
    },
    ui.label {
        text = lang.ui.COPY_HINT,
        text_color = theme.muted,
        align = 'start',
        font = { size = 12 },
        style = { Height = 20, FlexShrink = 0, MarginTop = 4 },
    },
    ui.container {
        style = { Height = 40, FlexShrink = 0, FlexDirection = 'row', MarginTop = 4 },
        ui.button {
            id = 'copy_report',
            title = lang.ui.COPY_ALL,
            style = { FlexGrow = 1, FlexBasis = 0, MarginRight = 4 },
            bind = {
                color = 'theme'
            },
            on = {
                click = function()
                    -- Copy the complete log, independent of selection, wrapping
                    -- or the native control's representation of line endings.
                    gui.app:getclipboard('copy-paste'):settext(data.report.text)
                end
            }
        },
        ui.button {
            id = 'back',
            title = lang.ui.BACK,
            style = { FlexGrow = 1, FlexBasis = 0, MarginLeft = 4 },
            bind = {
                color = 'theme'
            },
            on = {
                click = function()
                    window:show_page('convert')
                end
            },
        },
    },
}

view, data, element = ui.create(template, {
    theme = window._color,
    report = {
        text = '',
    }
})

ev.on('update theme', function()
    data.theme = window._color
end)

function view:on_show()
    local text = backend.report_text
    if text == nil then text = io.load(root:parent_path() / 'log' / 'report.log') or '' end
    data.report.text = text
    data.theme = window._color
    element.report_text:selectrange(0, 0)
    element.report_text:focus()
    set_readonly(element.report_text)
end

return view
