local lang = require 'share.lang'
local ui = require 'gui.new.template'
local theme = require 'gui.new.theme'

local template = ui.container {
    style = { FlexGrow = 1, Padding = 24, JustifyContent = 'center' },
    font = { name = 'Segoe UI', size = 14 },
    ui.container {
        color = theme.surface,
        style = { Padding = 24, MarginBottom = 24 },
        ui.label {
            text = lang.ui.DRAG_MAP,
            style = { Height = 48 },
            font = { name = 'Segoe UI', size = 22, weight = 'bold' },
        },
        ui.label {
            text = lang.ui.DRAG_MAP_HINT,
            text_color = theme.muted,
            style = { Height = 48 },
        },
    },
    ui.button {
        title = lang.ui.VERSION .. (require 'share.changelog')[1].version,
        color = theme.raised,
        style = { Height = 40, Width = 180, AlignSelf = 'center' },
        on = { click = function() window:show_page('about') end },
    },
}
local view = ui.create(template, {})
return view
