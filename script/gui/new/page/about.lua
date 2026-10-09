local lang = require 'share.lang'
local ui = require 'gui.new.template'
local ev = require 'gui.event'
local brand = require 'share.brand'
local theme = require 'gui.new.theme'

local template = ui.container {
    style = { FlexGrow = 1, Padding = 16 },
    font = { name = 'Segoe UI', size = 14 },
    ui.container {
        style = { FlexGrow = 1 },
        ui.label {
            text = brand.name .. ' ' .. (require 'share.changelog')[1].version,
            text_color = theme.text,
            style = { MarginTop = 12, Height = 28 },
        },
        ui.label {
            text = lang.ui.MAINTAINER:gsub('%s+$', '') .. ' ' .. brand.maintainer,
            text_color = theme.muted,
            style = { Height = 28 },
        },
        ui.label {
            text = lang.ui.AUTHOR,
            text_color = theme.text,
            style = { MarginTop = 20, Height = 28, Width = 240 },
            bind = {
                color = 'theme'
            }
        },
        ui.label {
            text = lang.ui.FRONTEND .. 'actboy168',
            text_color = theme.muted,
            style = { MarginTop = 5, Height = 28, Width = 240 }
        },
        ui.label {
            text = lang.ui.BACKEND .. lang.ui.SUMNEKO,
            text_color = theme.muted,
            style = { Height = 28, Width = 240 }
        },
        ui.label {
            text = 'Research inspiration: devoltzz / Devo Map Doctor',
            text_color = theme.muted,
            style = { Height = 28 },
        },
        ui.label {
            text = 'JASS verification: pjass (Rudi Cilibrasi, lep and contributors)',
            text_color = theme.muted,
            style = { Height = 28 },
        },
        ui.label {
            text = 'Archive: StormLib / Ladislav Zezula',
            text_color = theme.muted, style = { Height = 28 },
        },
        ui.label {
            text = 'Compression: zlib / Jean-loup Gailly and Mark Adler',
            text_color = theme.muted, style = { Height = 28 },
        },
        ui.label {
            text = lang.ui.CHANGE_LOG,
            text_color = theme.text,
            style = { Height = 28, Width = 240 },
            bind = {
                color = 'theme'
            }
        },
        ui.scroll {
            style = { FlexGrow = 1 },
            hpolicy = 'never',
            vpolicy = 'automatic',
            width = 0,
            bind = {
                height = 'height'
            },
            ui.container {
                id = 'changelog',
            }
        },
    },
    ui.button {
        title = lang.ui.BACK,
        style = { Height = 40, MarginTop = 12, FlexShrink = 0 },
        bind = {
            color = 'theme'
        },
        on = {
            click = function()
                window:show_page('index')
            end
        }
    }
}

local template_version = ui.label {
    style = { Margin = 3, Height = 25 },
    color = theme.raised,
    text_color = theme.muted,
    font = { size = 16 },
    bind = {
        text = 'version'
    }
}

local template_changelog = ui.container {
    style = { Height = 31, FlexDirection = 'row' },
    color = theme.background,
    color_hover = theme.raised,
    ui.label {
        style = { Margin = 3, Width = 40 },
        font = { name = 'Consolas', size = 18 },
        bind = {
            text = 'type.text',
            color = 'type.color'
        }
    },
    ui.label {
        style = { Margin = 3, FlexGrow = 1, FlexBasis = 0 },
        text_color = theme.muted,
        font = { size = 16 },
        align = 'start',
        bind = {
            text = 'text'
        }
    }
}

local color  = {
    NEW = theme.modes.slk,
    CHG = theme.modes.obj,
    FIX = theme.error,
    UI = '#584780',
}

local view, data, element = ui.create(template, {
    theme = window._color,
    height = 0
})

local log = element.changelog
local height = 0
for _, v in ipairs(require 'share.changelog') do
    local version = ui.create(template_version, {
        version = v.version
    })
    log:addchildview(version)
    height = height + 31

    for _, l in ipairs(v) do
        local changelog = ui.create(template_changelog, {
            type = {
                text = l[1],
                color = color[l[1]]
            },
            text = l[2]
        })
        log:addchildview(changelog)
        height = height + 31
    end
end

data.height = height
ev.on('update theme', function()
    data.theme = window._color
end)

return view
