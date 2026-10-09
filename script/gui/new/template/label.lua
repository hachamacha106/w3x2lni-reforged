local gui = require 'yue.gui'
local ca = require 'gui.new.common_attribute'

return function (t, data)
    local label = gui.Label.create('')
    if t.bind and t.bind.text then
        local bind_text
        bind_text = data:bind(t.bind.text, function()
            label:settext(bind_text:get())
        end)
        label:settext(bind_text:get())
    else
        label:settext(t.text or '')
    end
    if t.style then
        label:setstyle(t.style)
    end
    if t.align then
        label:setalign(t.align)
    end
    if t.valign then
        label:setvalign(t.valign)
    end
    local bind = {}
    ca.text_color(label, t, data, bind)
    ca.font(label, t)
    ca.label_color(label, t, data, bind)
    ca.visible(label, t, data, bind)
    return label
end
