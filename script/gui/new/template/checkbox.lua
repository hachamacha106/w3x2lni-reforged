local gui = require 'yue.gui'
local ca = require 'gui.new.common_attribute'
local theme = require 'gui.new.theme'
local key_activation = require 'gui.new.key_activation'

-- Native checkboxes provide a visible checkmark, keyboard activation and focus.
return function(t, data)
    local button = gui.Button.create { type = 'checkbox', title = t.text }
    local bind = {}
    button:setstyle { Height = 30 }
    if t.style then button:setstyle(t.style) end
    ca.font(button, t)
    ca.text_color(button, t, data, bind)
    ca.button_color(button, button, {color = theme.background, color_hover = theme.surface}, data, {})
    if t.bind and t.bind.value then
        bind.value = data:bind(t.bind.value, function() button:setchecked(bind.value:get()) end)
        button:setchecked(bind.value:get())
    else
        button:setchecked(t.value or false)
    end
    local clear_key = key_activation(button, function()
        button:setchecked(not button:ischecked())
        if bind.value then bind.value:set(button:ischecked()) end
    end)
    function button:onclick()
        clear_key()
        if self:isenabled() and bind.value then bind.value:set(self:ischecked()) end
    end
    ca.event(button, t, data, 'mouseenter')
    ca.event(button, t, data, 'mouseleave')
    ca.visible(button, t, data, bind)
    ca.enabled(button, t, data, bind)
    return button
end
