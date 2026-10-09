local gui = require 'yue.gui'

-- The retained Yue build emits these signals without activating a button.
-- Consume activation keys and invoke once on release, including autorepeat.
return function(view, activate)
    local keyboard_key
    local function activation(event)
        local key = event.key:lower()
        if key == 'return' then key = 'enter' end
        local plain = event.modifiers & (gui.Event.maskcontrol | gui.Event.maskalt | gui.Event.maskmeta) == 0
        return key, plain and (key == 'space' or key == 'enter')
    end
    function view:onkeydown(event)
        local key, active = activation(event)
        if active then keyboard_key = key; return true end
        keyboard_key = nil
        return false
    end
    function view:onkeyup(event)
        local key, active = activation(event)
        local armed = keyboard_key == key
        keyboard_key = nil
        if active then
            if armed and self:isenabled() then activate() end
            return true
        end
        return false
    end
    return function() keyboard_key = nil end
end
