local lang = require 'share.lang'
local ui = require 'gui.new.template'
local theme = require 'gui.new.theme'

local function format(mode, token, title, description)
    return ui.container {
        color = theme.surface,
        style = { Padding = 12, MarginBottom = 12 },
        ui.button {
            id = 'to_' .. mode,
            title = lang.ui.CONVERT_TO .. title,
            color = theme.modes[mode],
            style = { Height = 42 },
            font = { name = 'Segoe UI', size = 17, weight = 'bold' },
            on = { click = function()
                window._mode = mode
                window:set_theme(token, theme.modes[mode])
                window:show_page 'convert'
                window:set_theme(token, theme.modes[mode])
            end },
        },
        ui.label {
            text = description,
            text_color = theme.muted,
            align = 'start',
            style = { Height = 26, MarginTop = 6 },
            font = { name = 'Segoe UI', size = 13 },
        },
    }
end

local template = ui.container {
    style = { FlexGrow = 1, Padding = 16 },
    font = { name = 'Segoe UI', size = 14 },
    ui.container {
        color = theme.surface,
        style = { Height = 48, Padding = 10, MarginBottom = 16, FlexShrink = 0 },
        ui.label {
            id = 'filename',
            align = 'start',
            style = { FlexGrow = 1 },
            bind = { text = 'filename' },
        },
    },
    ui.label {
        id = 'format_heading',
        text = lang.ui.CHOOSE_FORMAT,
        align = 'start',
        style = { Height = 32, MarginBottom = 8 },
        font = { name = 'Segoe UI', size = 18, weight = 'bold' },
    },
    format('lni', 'W3x2Lni', 'LNI', lang.ui.LNI_DESCRIPTION),
    format('obj', 'W3x2Obj', 'OBJ', lang.ui.OBJ_DESCRIPTION),
    format('slk', 'W3x2Slk', 'SLK', lang.ui.SLK_DESCRIPTION),
}

local view, data = ui.create(template, { filename = '' })
function view:on_show()
    window:set_theme('W3x2Lni', theme.modes.lni)
    data.filename = window._filename:filename():string()
end
return view
