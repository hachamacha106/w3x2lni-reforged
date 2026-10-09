local gui = require 'yue.gui'
local ca = require 'gui.new.common_attribute'

-- A native single-line input, with user edits flowing back to the binding.
return function(t, data)
    local entry = gui.Entry.create()
    local updating = false
    local binding
    local function set_text(value)
        updating = true
        entry:settext(value)
        updating = false
    end
    if t.bind and t.bind.text then
        binding = data:bind(t.bind.text, function() set_text(binding:get()) end)
        function entry:ontextchange()
            if not updating then binding:set(self:gettext()) end
        end
        set_text(binding:get())
    else
        set_text(t.text or '')
    end
    function entry:onkeydown(event)
        if event.key:lower() == 'tab'
            and event.modifiers & (gui.Event.maskcontrol | gui.Event.maskalt | gui.Event.maskmeta) == 0
            and t.on and t.on.tab then
            t.on.tab(self, event)
            return true
        end
        return false
    end
    if t.style then entry:setstyle(t.style) end
    ca.font(entry, t)
    ca.visible(entry, t, data, {})
    return entry
end
