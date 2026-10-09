local gui = require 'yue.gui'
local ca = require 'gui.new.common_attribute'
local theme = require 'gui.new.theme'
local key_activation = require 'gui.new.key_activation'

return function (t, data)
    local btn = gui.Button.create('')
    local bind = {}
    if t.bind and t.bind.title then
        local bind_title
        bind_title = data:bind(t.bind.title, function()
            btn:settitle(bind_title:get())
        end)
        btn:settitle(bind_title:get())
    else
        btn:settitle(t.title or '')
    end
    if t.style then
        btn:setstyle(t.style)
    end
    local function click()
        if btn:isenabled() and t.on and t.on.click then t.on.click(btn, t) end
    end
    local clear_key = key_activation(btn, click)
    function btn:onclick()
        clear_key()
        click()
    end
    btn:setbackgroundcolor(theme.raised)
    ca.font(btn, t)
    ca.text_color(btn, t, data, bind)
    ca.button_color(btn, btn, t, data, bind)
    ca.visible(btn, t, data, bind)
    ca.enabled(btn, t, data, bind)
    return btn
end
